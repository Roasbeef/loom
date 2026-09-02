//// The manifest's `[net]` table, turned into the three things a dispatch
//// needs: the `egress.Policy` every request is judged under, the
//// per-execution admission ceilings, and the vocabulary a refusal travels
//// back to the jail in.
////
//// This module is pure and holds no transport, which is the point of
//// separating it from `client/extension/seam`. What an extension may
//// reach is decided entirely by bytes an operator approved at install, so
//// the translation from those bytes to a policy value is worth being able
//// to read — and test — without a socket, a satellite or a broker
//// anywhere near it.
////
//// # Nothing here widens, and nothing here is a default
////
//// Every field of `egress.Policy` is either the manifest's or fixed by
//// this module, and the two sets do not overlap. `hosts`, `methods`,
//// `max_response_bytes` and the secret bindings are the manifest's
//// verbatim; `redirects`, `timeout_ms` and `trust` are this module's,
//// because none of the three is something an extension author should be
//// able to state about themselves. An author who could set `trust` could
//// pin a root of their own choosing; one who could set `redirects` could
//// try to walk a permitted host somewhere else; one who could set
//// `timeout_ms` could hold a harness process for as long as they liked.
////
//// A manifest with no `[net]` table decodes to `manifest.no_net()`, whose
//// `hosts` list is empty. That is `ReachesNothing` here rather than a
//// `Policy` with an empty allowlist, and the difference is the refusal an
//// author reads: an empty allowlist says "this host is not on the list"
//// about a list nobody wrote, where `network_off` says the extension
//// asked for no network at all.
////
//// # The refusal vocabulary is `cap/net`'s, and it is a contract
////
//// `cap/net.map_error` sorts a denial's *code* into `NetDenied` — the
//// four codes `denied`, `network_off`, `policy` and `not_allowed` — and
//// everything else into `NetFailed(code, message)`. That split is the
//// only thing an extension can branch on, so `denial` below assigns each
//// `egress.Refusal` to whichever side it actually belongs to: a request
//// the policy would never have permitted is a `NetDenied` however it was
//// phrased, and a request the policy permitted which then went wrong on
//// the wire is a `NetFailed` carrying a code that names the failure. A
//// refusal filed on the wrong side is not cosmetic — it is the difference
//// between an author retrying and an author reinstalling.

import broker/egress
import client/extension/manifest.{type Net}
import codemode/satellite.{type CapCeiling, type CapDenial, CapCeiling}
import gleam/int
import gleam/list
import gleam/string

/// The capability a jailed extension reaches the network through.
pub const net_cap = "net.request"

/// The capability a satellite asks for its call with, once.
pub const call_cap = "ext.call"

/// The code an extension with no `[net]` table meets on every request.
///
/// One of `cap/net.map_error`'s four denial codes, so it arrives inside
/// the jail as a `NetDenied` rather than as an unnamed failure.
pub const network_off_code = "network_off"

/// The code every policy refusal travels under: the host was not on the
/// allowlist, the method was not permitted, a header was reserved, a
/// redirect left the origin, a binding was unset.
///
/// One code rather than one per `egress.Refusal` variant, because the
/// message already names which of them it was and the *code* is what an
/// extension branches on. What it needs to branch on is one question —
/// "would this policy ever permit this request?" — and the answer is no
/// for all of them.
pub const denied_code = "not_allowed"

/// The code a permitted request that failed on the wire travels under.
///
/// Outside `cap/net.map_error`'s denial set on purpose, so it arrives as
/// `NetFailed(code, message)`: the request was allowed and something else
/// went wrong, which is a different repair from a policy refusal.
pub const failed_code = "net_failed"

/// The code a `net.request` refused by the per-execution ceiling travels
/// under.
///
/// A denial code rather than a failure code, and deliberately not
/// `denied_code`: an extension at its ceiling has hit a bound on *this
/// execution* rather than a standing policy fact, and the host's own
/// ceiling message says exactly that. Sorting it into `NetDenied` is what
/// stops a retry loop — a `NetFailed` reads as "try again".
pub const ceiling_code = "policy"

/// The code a second `ext.call` in one execution travels under.
///
/// `cap/ext` maps every denial to `CallDenied(code, message)` and has no
/// code vocabulary of its own, so this one is diagnostic rather than
/// load-bearing. The bound it names is real: a satellite is launched to
/// serve one call, and a second request would be a second admission
/// against the same token.
pub const call_ceiling_code = "ext_call_ceiling"

/// How many times one execution may ask which call it is serving.
pub const call_admissions = 1

/// How long one brokered request may take, end to end: connect, TLS,
/// every hop and the body.
///
/// A constant rather than a manifest field, and below the tool timeouts a
/// manifest realistically states, so the bound that fires first is the one
/// whose refusal an extension can read and turn into a sentence. A request
/// that outran the *tool* deadline instead takes the satellite down with
/// it, and the model reads a killed execution rather than a refusal.
pub const request_timeout_ms = 15_000

/// How far a redirect may be followed, and only within the origin already
/// judged. `egress` refuses a hop that leaves the origin rather than
/// re-judging it, so this bounds a walk that cannot change host anyway.
pub const redirect_hops = 2

/// Whether an extension may reach the network at all, and under what.
///
/// Two variants and no third: an extension either named a `[net]` table
/// at install, in which case the operator approved exactly this policy,
/// or it did not, in which case it reaches nothing. There is no third
/// state in which the policy is partly known.
pub type Egress {
  /// The manifest named a `[net]` table and the operator approved it.
  Reaches(policy: egress.Policy)

  /// No `[net]` table. Every `net.request` is refused `network_off`.
  ReachesNothing
}

/// The egress policy an installed extension's requests are judged under.
///
/// `trust` is a parameter rather than a constant so that a test can point
/// the client at a loopback origin whose chain it pinned; production
/// passes `egress.SystemRoots` and nothing else does.
///
/// ## Examples
///
/// ```gleam
/// assert policy.egress_for(manifest.no_net(), trust: egress.SystemRoots)
///   == policy.ReachesNothing
/// ```
///
pub fn egress_for(net: Net, trust trust: egress.Trust) -> Egress {
  case net.hosts {
    [] -> ReachesNothing
    [_, ..] ->
      Reaches(egress.Policy(
        hosts: net.hosts,
        methods: list.filter_map(net.methods, method),
        max_response_bytes: net.max_response_bytes,
        redirects: egress.SameHost(at_most: redirect_hops),
        timeout_ms: request_timeout_ms,
        secrets: list.map(net.secrets, secret),
        trust:,
      ))
  }
}

/// The lifetime admission ceilings one extension execution runs under.
///
/// Two, and each bounds something an execution's own loop would otherwise
/// get for free. `net.request` is the manifest's `requests_per_call`,
/// which is the ceiling shape `satellite.CapCeiling` argues for at length:
/// an implicit throttle removed has to be replaced by an explicit one, and
/// an extension that can make one request can make ten thousand inside one
/// deadline.
///
/// `ext.call` is one, because a satellite is launched to serve exactly one
/// call. A second would be a second admission against the same token, and
/// the shape that refuses it is the shape that refuses the eleventh
/// request.
///
/// An extension with no `[net]` still gets the `net.request` ceiling, at
/// zero admissions. It is unreachable — the router's own arm refuses
/// `network_off` before any ceiling is consulted — and it is stated anyway
/// so that reading the ceilings answers "how many requests may this
/// extension make" without also having to read the router.
///
/// ## Examples
///
/// ```gleam
/// assert list.length(policy.ceilings(manifest.no_net())) == 2
/// ```
///
pub fn ceilings(net: Net) -> List(CapCeiling) {
  [
    CapCeiling(
      cap: net_cap,
      admissions: net.requests_per_call,
      code: ceiling_code,
    ),
    CapCeiling(
      cap: call_cap,
      admissions: call_admissions,
      code: call_ceiling_code,
    ),
  ]
}

/// One `egress.Refusal` as the in-band denial a jailed extension reads.
///
/// The message is `egress.describe`'s, which is safe to place on the
/// capability channel by construction: no `Refusal` variant has a field a
/// credential value could occupy, so there is nothing in the text to
/// redact.
///
/// ## Examples
///
/// ```gleam
/// assert policy.denial(egress.Timeout(after_ms: 10)).code
///   == policy.failed_code
/// ```
///
pub fn denial(refusal: egress.Refusal) -> CapDenial {
  satellite.CapDenial(
    code: code_for(refusal),
    message: egress.describe(refusal),
  )
}

/// The denial an extension that named no `[net]` table meets on every
/// request.
///
/// ## Examples
///
/// ```gleam
/// assert policy.network_off("hello").code == policy.network_off_code
/// ```
///
pub fn network_off(name: String) -> CapDenial {
  satellite.CapDenial(
    code: network_off_code,
    message: "the extension `"
      <> name
      <> "` declares no [net] table in its manifest, so it reaches no host "
      <> "at all; an operator adds one and reinstalls",
  )
}

/// What a manifest's `[net]` table permits, as the one line a boot log
/// prints per extension.
///
/// The secret bindings are counted rather than named, and their *values*
/// appear nowhere at all: an operator needs to know a binding exists and
/// how many, and a log line is the last place a variable's contents should
/// be able to reach.
///
/// ## Examples
///
/// ```gleam
/// assert policy.summary(manifest.no_net()) == "no network"
/// ```
///
pub fn summary(net: Net) -> String {
  case net.hosts {
    [] -> "no network"
    hosts ->
      string.join(hosts, ", ")
      <> " ("
      <> string.join(net.methods, ", ")
      <> ", "
      <> int.to_string(net.requests_per_call)
      <> " requests per call, "
      <> int.to_string(list.length(net.secrets))
      <> " secret bindings)"
  }
}

// Which side of `cap/net.map_error`'s split a refusal belongs on.
//
// The question each arm answers is whether the policy would ever have
// permitted this request. Everything it would not have permitted is a
// denial however it was phrased — including a secret binding whose
// variable is unset, which is an operator fact the extension cannot repair
// and must not retry past. Everything else got as far as a socket and
// failed there.
fn code_for(refusal: egress.Refusal) -> String {
  case refusal {
    egress.SchemeNotHttps(..)
    | egress.HostNotAllowed(..)
    | egress.MethodNotAllowed(..)
    | egress.HeaderReserved(..)
    | egress.HeaderMalformed(..)
    | egress.SecretMissing(..)
    | egress.RedirectRefused(..)
    | egress.MalformedUrl(..) -> denied_code

    egress.ResponseTooLarge(..)
    | egress.Timeout(..)
    | egress.TransportFailed(..) -> failed_code
  }
}

/// One method name as the closed-set value `egress` judges against.
///
/// Public because the dispatch has to ask the same question of the
/// *call's* method as this module asks of the manifest's, and two tables
/// would be two chances to disagree about what `PATCH` means.
///
/// A name outside the set is `Error(Nil)` rather than a refusal, because
/// this function has no vocabulary for one — the callers compose theirs.
/// It is unreachable from a manifest, which `manifest.known_methods`
/// refuses at install, and reachable from a call, which an extension
/// composes itself.
///
/// ## Examples
///
/// ```gleam
/// assert policy.method("GET") == Ok(egress.Get)
/// ```
///
pub fn method(name: String) -> Result(egress.Method, Nil) {
  case name {
    "GET" -> Ok(egress.Get)
    "POST" -> Ok(egress.Post)
    "PUT" -> Ok(egress.Put)
    "DELETE" -> Ok(egress.Delete)
    "PATCH" -> Ok(egress.Patch)
    "HEAD" -> Ok(egress.Head)
    _unknown -> Error(Nil)
  }
}

// One manifest secret binding as an `egress.Secret`. The three fields
// carry across unchanged and none of them is the value: `env` is the
// *name* of an environment variable, which the dispatch reads through its
// injected lookup at request time.
fn secret(binding: manifest.Secret) -> egress.Secret {
  egress.Secret(env: binding.env, host: binding.host, header: binding.header)
}
