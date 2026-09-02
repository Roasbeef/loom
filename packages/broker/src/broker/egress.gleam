//// Outbound HTTP, performed by the harness on behalf of something that
//// is not allowed to open a socket.
////
//// `broker/policy` has a `NetworkProxy` mode that `narrow_unenforceable`
//// turns into `NetworkOff` on every call, because the egress proxy
//// sidecar it was written for does not exist. This module is not that
//// sidecar and does not revive it. A sidecar is the general answer for a
//// jailed process that opens sockets itself; ADR-007's observation is
//// that the programs Loom actually needs to give the network to do not
//// want a socket, they want a request made and the response handed back.
//// So the request is made here, in the harness VM, under a `Policy` the
//// caller cannot widen, and the jail's network namespace stays empty —
//// which is the property every sandbox layer already enforces and the
//// property the proxy was meant to preserve.
////
//// Two callers share this one surface, on purpose: `net.request` for a
//// jailed extension (ADR-007 phase 2) and the archive fetch behind
//// `loom ext install` (phase 1, via `one_host`). A cap raised for one is
//// raised for both.
////
//// ## Threat model
////
//// The caller is model-influenced code running in a jail, and the
//// operator's API key is the asset. So the key is never a value the
//// caller can name: a `Secret` binds an *environment variable name* to
//// one header and one origin, exactly as `client/catalog`'s
//// `api_key_env` binds a provider key, and the value is read through the
//// injected `secrets` function at request time. It is not stored on the
//// policy, it is not returned, and no `Refusal` variant has a field it
//// could occupy — which is why `describe` cannot leak one however it is
//// called. A caller that tries to observe the key by naming its header
//// itself is refused with `HeaderReserved` before a socket exists, a
//// caller that tries to *append* one by ending a header early is refused
//// with `HeaderMalformed` in the same pass, and a binding whose variable
//// is unset is `SecretMissing` before a socket exists either, so a
//// missing key never degrades into an unauthenticated request that a
//// hostile server gets to answer.
////
//// The URL is attacker-influenced too, so every hop re-runs the whole
//// judgement — scheme, origin, method — rather than trusting that the
//// first hop's approval still holds. A redirect is a new request.
////
//// ## What this does not defend against
////
//// The response body is returned to the caller intact. `max_response_
//// bytes` bounds how *much* comes back, never what it says: a permitted
//// host can hand a jailed extension any bytes it likes, and those bytes
//// then flow wherever that extension's own capabilities allow. The
//// allowlist is the trust decision; the cap is only a resource bound.
//// Cookies are not stored (`httpc` cookie handling is disabled on the
//// broker's profile) and `Set-Cookie` is not special-cased — it is
//// returned like any other header, and it is the caller's problem if it
//// echoes one back. Nothing in the process environment steers the
//// transport: `httpc` reads no `HTTP_PROXY`, and the broker's profile
//// sets no proxy of its own.
////
//// ## Decisions recorded here
////
//// - **`Host`, `Content-Length`, `Transfer-Encoding` and `Connection`
////   are reserved to this module**, alongside every bound secret's
////   header. A caller-supplied `Host` would let the allowlist check and
////   the request the server actually sees disagree, so it is refused
////   rather than silently dropped.
//// - **Connections are not reused, and neither are TLS sessions.**
////   Every request carries `Connection: close`, because `httpc` keys a
////   pooled session on host and port and not on the TLS options that
////   opened it — a pinned-root connection could otherwise serve a
////   system-roots request to the same origin. `reuse_sessions` is off
////   for the sharper version of the same problem: `ssl`'s client
////   session cache is *node-global* and keyed on host and port alone,
////   and a resumed TLS 1.2 handshake carries no certificate at all, so
////   a session established by any other policy — or by the provider's
////   own client, which shares this node — would let a request skip the
////   verification its roots were supposed to force. A policy's roots
////   have to be applied to a full handshake every time, or they are not
////   applied at all.
//// - **A header this module cannot put on the wire never reaches the
////   socket.** `httpc` type-checks a header and does not scan it, so a
////   CR, LF or NUL in a name or a value would reach the wire verbatim
////   and let the caller append headers of its own — a second credential
////   ahead of the injected one, a different `Host`, or a whole second
////   request with a method this policy never permitted. Above latin-1
////   the failure is the mirror image: `httpc` refuses the header itself
////   and puts the offending *value* into the error term, so a credential
////   with one such character would render itself into a
////   `TransportFailed`. Every header this module sends, the caller's and
////   the injected credential's alike, is scanned for both first, and
////   `HeaderMalformed` names the header — never the value — with its
////   line endings escaped. The scan is over code points rather than
////   substrings on purpose: `string.contains` works on grapheme
////   clusters and CRLF is one cluster, so a substring scan for `"\r"`
////   misses the exact sequence an injection uses.
//// - **The size cap is enforced while the body streams**, but `httpc`
////   only streams a 200 or 206; for any other status it buffers the
////   whole body before the broker sees a byte. A declared
////   `Content-Length` over the cap is refused either way. So on a
////   non-2xx response the cap is a check rather than a brake — the
////   limit is documented rather than papered over.
//// - **A streamed response reports 200 unless it carries
////   `Content-Range`**, in which case 206. `httpc`'s stream messages
////   carry no status line, and those are the only two statuses it will
////   stream.

import broker/internal/ffi_egress
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import gleam/uri

/// The HTTP methods a policy may permit. A closed set: a method this
/// module cannot name is a method no policy can grant.
pub type Method {
  /// `GET`. The only method `one_host` permits.
  Get

  /// `POST`, sent with the caller's body.
  Post

  /// `PUT`, sent with the caller's body.
  Put

  /// `DELETE`, sent with the caller's body when it has one.
  Delete

  /// `PATCH`, sent with the caller's body.
  Patch

  /// `HEAD`. The response has no body, so the size cap never binds.
  Head
}

/// Whether a 3xx is followed, and how far.
pub type Redirects {
  /// A redirect is refused where it is found, with the target named.
  NoRedirects

  /// Follow at most `at_most` hops, and only to the origin the request
  /// was already permitted to reach. A redirect that leaves the origin
  /// is refused rather than re-judged against the allowlist, so a
  /// server cannot walk a caller across a multi-host policy.
  SameHost(at_most: Int)
}

/// Which certificate authorities a connection may chain to.
pub type Trust {
  /// The platform trust store, via `public_key:cacerts_get/0`.
  SystemRoots

  /// Exactly these DER-encoded certificates. An empty list is a valid,
  /// permanently failing pin rather than an escape hatch: nothing
  /// verifies, so every connection is `TransportFailed`.
  PinnedRoots(ders: List(BitArray))
}

/// A credential the broker injects and the caller never sees.
pub type Secret {
  Secret(
    /// The *name* of the environment variable holding the value. The
    /// value itself is read through `request`'s `secrets` argument at
    /// request time and is never stored on the policy.
    env: String,
    /// The origin this credential belongs to, in the same grammar as
    /// `Policy.hosts` — `"api.example.com"` or `"api.example.com:8443"`.
    /// The header is injected only on a hop whose origin matches, so a
    /// redirect to another permitted host does not carry it along.
    host: String,
    /// The header the value is placed in. Reserving it also refuses any
    /// caller header of the same name, case-insensitively.
    header: String,
  )
}

/// Everything one caller is permitted to do with the network.
pub type Policy {
  Policy(
    /// The origins that may be reached, exactly: no wildcards, no suffix
    /// matching. An entry is `host` or `host:port`; `:443` and an absent
    /// port mean the same thing. An entry this module cannot parse can
    /// never match, which is the fail-closed direction.
    hosts: List(String),
    /// The methods permitted, re-checked on every hop.
    methods: List(Method),
    /// The most body bytes that may be accepted, enforced while the
    /// response streams.
    max_response_bytes: Int,
    /// Whether a 3xx is followed.
    redirects: Redirects,
    /// One deadline for the whole request: connect, TLS, every hop and
    /// the body. Not a per-hop budget.
    timeout_ms: Int,
    /// The credential bindings. Every one is resolved before the first
    /// connection, so a misconfigured policy fails before it reaches a
    /// server.
    secrets: List(Secret),
    /// Which roots the TLS handshake may chain to.
    trust: Trust,
  )
}

/// What the caller asked for, before any policy is applied.
pub type Request {
  Request(
    /// The method, which must appear in `Policy.methods`.
    method: Method,
    /// An absolute `https://` URL. Userinfo in it is malformed, not a
    /// credential.
    url: String,
    /// Caller headers. A name colliding with a reserved header or a
    /// bound secret's header refuses the whole request.
    headers: List(#(String, String)),
    /// The request body, sent for `Post`, `Put`, `Patch`, and for
    /// `Delete` when it is non-empty.
    body: BitArray,
  )
}

/// A response the policy permitted, in full.
pub type Response {
  Response(
    /// The HTTP status of the last hop.
    status: Int,
    /// Response headers with lowercased names, in the order the server
    /// sent them. Not filtered: `set-cookie` and friends come back as
    /// they arrived.
    headers: List(#(String, String)),
    /// The body, at most `Policy.max_response_bytes` long.
    body: BitArray,
  )
}

/// Why a request was not performed, or not completed.
///
/// No variant carries a credential value, and that is structural rather
/// than a convention: there is no field one could be placed in, so
/// `describe` has nothing to redact.
pub type Refusal {
  /// The URL's scheme is not `https`. Plaintext is refused rather than
  /// upgraded.
  SchemeNotHttps(url: String)

  /// The URL's origin is not on the allowlist. `allowed` is the policy's
  /// list verbatim, so the refusal names what was permitted.
  HostNotAllowed(host: String, allowed: List(String))

  /// The method is not one this policy permits.
  MethodNotAllowed(method: Method)

  /// A caller header collides with a header this module owns — a bound
  /// secret's header, or one of the client-owned transport headers.
  HeaderReserved(header: String)

  /// A header name or value carries a code point this module will not
  /// send: CR, LF or NUL, which would end the header early on the wire,
  /// or one above latin-1, which `httpc` refuses in a way that renders
  /// the value into the error. The name is reported with the line
  /// endings escaped, because this text is logged; the value never
  /// appears.
  HeaderMalformed(header: String)

  /// A secret binding names an environment variable that is not set.
  /// The name is diagnostic; the value never existed to leak.
  SecretMissing(env: String)

  /// A 3xx was answered and not followed. `to` is the target, resolved
  /// against the request URL where that was possible.
  RedirectRefused(to: String, why: String)

  /// The response declared or delivered more than the cap, and was
  /// cancelled rather than drained.
  ResponseTooLarge(cap: Int)

  /// The whole-request deadline expired.
  Timeout(after_ms: Int)

  /// Connect, TLS or protocol failure, including a certificate that did
  /// not verify against the policy's roots.
  TransportFailed(reason: String)

  /// The URL did not parse, or carried userinfo, or named no host.
  MalformedUrl(url: String)
}

/// The statuses this module treats as redirects.
const redirect_statuses = [301, 302, 303, 307, 308]

/// "See other": the one redirect that changes the method.
const see_other = 303

/// Headers this module owns because the transport or the allowlist
/// depends on them. A caller naming one is refused, never overridden.
const client_owned_headers = [
  "connection", "content-length", "host", "transfer-encoding",
]

/// The code points that end a header early on the wire, each paired with
/// how it is rendered when a refusal has to name it.
///
/// `httpc` type-checks a header but does not scan it, so any of these
/// reaching the socket verbatim would let the sender append headers of
/// its own — a second credential ahead of the injected one, a different
/// `Host`, or an entire second request. One table rather than two lists
/// so that a point cannot be refused without also being printable.
const line_ending_escapes = [#(13, "\\r"), #(10, "\\n"), #(0, "\\0")]

/// The largest code point `httpc` will place in a header.
///
/// Above it, `http_request:mk_key_value_str` raises `{invalid_header,
/// {Key, Value}}`, and that term reaches the caller as a
/// `TransportFailed` carrying the offending *value* — so a credential
/// holding one character above latin-1 would render itself into a
/// refusal message. This is `httpc`'s own sendability bound, and
/// refusing it before a socket exists is both the safe answer and the
/// honest one.
const max_header_point = 255

/// The scheme's default port, normalized away so that
/// `https://example.com` and `https://example.com:443` compare equal.
const default_https_port = 443

/// One origin: a lowercased host and an explicit non-default port.
///
/// Private because it is the comparison key and nothing else. Both the
/// allowlist grammar and the URL grammar reduce to it, which is what
/// makes "same origin" one equality rather than three checks.
type Origin {
  Origin(host: String, port: Option(Int))
}

/// One hop of a request: what would be sent if it were sent now.
///
/// `count` is how many redirects have already been followed, so the hop
/// limit is a property of the walk rather than of a mutable counter
/// threaded past it.
type Hop {
  Hop(
    method: Method,
    url: String,
    headers: List(#(String, String)),
    body: BitArray,
    count: Int,
  )
}

/// A hop together with the origin it was already judged against.
///
/// The origin is carried rather than re-derived because `hop` has
/// already parsed the URL to get it; a second parse on the redirect path
/// would be a second chance to disagree with the first.
type Walk {
  Walk(attempt: Hop, origin: Origin)
}

/// Performs `request` under `policy`, reading any bound credential
/// through `secrets`.
///
/// The checks that do not depend on the URL run first — a reserved
/// header, an unset credential — so a misconfigured policy is reported
/// once rather than once per hop, and neither failure can reach a
/// server. Everything after that is re-judged on every hop, because a
/// redirect is a new request.
///
/// ## Examples
///
/// ```gleam
/// let policy = egress.one_host("example.com", max_response_bytes: 4096, timeout_ms: 5000)
/// let call = egress.Request(egress.Get, "https://example.com/x", [], <<>>)
/// egress.request(policy, call, secrets: fn(_) { Error(Nil) })
/// // -> Ok(egress.Response(status: 200, ..))
/// ```
///
pub fn request(
  policy: Policy,
  request: Request,
  secrets secrets: fn(String) -> Result(String, Nil),
) -> Result(Response, Refusal) {
  // Neither of these needs a URL, and both are properties of how the
  // caller and the policy fit together rather than of a hop.
  use _ <- result.try(check_headers(policy, request.headers))
  use bound <- result.try(resolve_secrets(policy, secrets))

  // The deadline is fixed here, once, and every hop spends against it.
  let deadline = ffi_egress.monotonic_ms() + policy.timeout_ms

  hop(
    policy,
    bound,
    deadline,
    Hop(
      method: request.method,
      url: request.url,
      headers: request.headers,
      body: request.body,
      count: 0,
    ),
  )
}

/// The install fetch policy: one host, `GET`, no credentials, system
/// roots, and the two redirect hops a code-hosting archive URL needs.
///
/// ADR-007 makes the extension archive fetch and a jailed extension's
/// `net.request` the same mechanism, so the install path is a `Policy`
/// value rather than a second client.
///
/// ## Examples
///
/// ```gleam
/// egress.one_host("codeload.github.com", max_response_bytes: 33_554_432, timeout_ms: 60_000)
/// // -> Policy(hosts: ["codeload.github.com"], methods: [Get], ..)
/// ```
///
pub fn one_host(
  host: String,
  max_response_bytes max: Int,
  timeout_ms timeout: Int,
) -> Policy {
  Policy(
    hosts: [host],
    methods: [Get],
    max_response_bytes: max,
    redirects: SameHost(at_most: 2),
    timeout_ms: timeout,
    secrets: [],
    trust: SystemRoots,
  )
}

/// Renders a refusal for a human or for a capability error message.
///
/// Safe to log and safe to place on the capability channel: the type
/// carries no credential value, so neither does the text.
///
/// ## Examples
///
/// ```gleam
/// egress.describe(egress.SecretMissing("SEARCH_API_KEY"))
/// // -> "secret binding names SEARCH_API_KEY, which is not set in the server's environment"
/// ```
///
pub fn describe(refusal: Refusal) -> String {
  case refusal {
    SchemeNotHttps(url:) ->
      "only https:// is permitted, and " <> url <> " is not"

    HostNotAllowed(host:, allowed:) ->
      "host "
      <> host
      <> " is not on this policy's allowlist ["
      <> string.join(allowed, ", ")
      <> "]"

    MethodNotAllowed(method:) ->
      "method " <> method_label(method) <> " is not permitted by this policy"

    HeaderReserved(header:) ->
      "header " <> header <> " is reserved and may not be set by the caller"

    HeaderMalformed(header:) ->
      "header "
      <> header
      <> " carries a line break, a NUL, or a character that cannot be"
      <> " placed on the wire"

    SecretMissing(env:) ->
      "secret binding names "
      <> env
      <> ", which is not set in the server's environment"

    RedirectRefused(to:, why:) -> "redirect to " <> to <> " refused: " <> why

    ResponseTooLarge(cap:) ->
      "response body exceeds the "
      <> int.to_string(cap)
      <> " byte cap and was cancelled"

    Timeout(after_ms:) ->
      "request did not complete within " <> int.to_string(after_ms) <> "ms"

    TransportFailed(reason:) -> "transport failed: " <> reason

    MalformedUrl(url:) -> "not a URL this client can request: " <> url
  }
}

/// Judges one hop and performs it.
///
/// Origin and method are checked here rather than once at the top,
/// because a redirect target has to clear the same bar the original URL
/// did. The deadline is read fresh each time, so the hops share one
/// budget instead of each getting a whole one.
fn hop(
  policy: Policy,
  bound: List(#(Secret, String)),
  deadline: Int,
  attempt: Hop,
) -> Result(Response, Refusal) {
  use origin <- result.try(parse_target(attempt.url))
  use _ <- result.try(check_host(policy, origin))
  use _ <- result.try(check_method(policy, attempt.method))
  use remaining <- result.try(remaining_ms(policy, deadline))

  // The credential is added last and only for this hop's origin, so a
  // permitted redirect to a different host cannot carry it.
  let sent =
    list.flatten([
      attempt.headers,
      [#("connection", "close")],
      injected(bound, origin),
    ])

  let outcome =
    ffi_egress.fetch(
      method_label(attempt.method),
      attempt.url,
      sent,
      attempt.body,
      policy.max_response_bytes,
      remaining,
      roots(policy.trust),
    )

  settle(policy, bound, deadline, Walk(attempt:, origin:), outcome)
}

/// Turns one hop's outcome into a response, a refusal, or another hop.
fn settle(
  policy: Policy,
  bound: List(#(Secret, String)),
  deadline: Int,
  walk: Walk,
  outcome: ffi_egress.FetchOutcome,
) -> Result(Response, Refusal) {
  case outcome {
    // A 3xx carrying a Location is the only thing that continues the
    // walk; a 3xx without one is just a response the caller reads.
    ffi_egress.Fetched(status:, headers:, body:) ->
      case location_of(status, headers) {
        Some(location) ->
          redirect(policy, bound, deadline, walk, status, location)
        None -> Ok(Response(status:, headers:, body:))
      }

    ffi_egress.FetchTooLarge(cap:) -> Error(ResponseTooLarge(cap))

    ffi_egress.FetchTimedOut -> Error(Timeout(policy.timeout_ms))

    ffi_egress.FetchFailed(reason:) -> Error(TransportFailed(reason))
  }
}

/// Decides whether a redirect may be followed, and follows it.
///
/// The order matters: the policy's own refusal to follow comes before
/// anything derived from the server's `Location`, so `NoRedirects` is
/// answered without the target having to parse.
fn redirect(
  policy: Policy,
  bound: List(#(Secret, String)),
  deadline: Int,
  walk: Walk,
  status: Int,
  location: String,
) -> Result(Response, Refusal) {
  use limit <- result.try(redirect_limit(policy, location))
  use next <- result.try(redirect_target(walk, location))
  use _ <- result.try(within_hops(walk.attempt, limit, next))

  hop(policy, bound, deadline, advance(walk.attempt, status, next))
}

/// How many hops this policy permits, or the refusal for permitting
/// none.
fn redirect_limit(policy: Policy, location: String) -> Result(Int, Refusal) {
  case policy.redirects {
    NoRedirects ->
      Error(RedirectRefused(location, "this policy does not follow redirects"))

    SameHost(at_most:) -> Ok(at_most)
  }
}

/// Resolves a `Location` against the request URL and refuses it if it
/// leaves the origin.
///
/// Resolution runs first so that a relative `Location` — which cannot
/// leave the origin by construction — and an absolute one are judged by
/// the same equality rather than by two different rules.
fn redirect_target(walk: Walk, location: String) -> Result(String, Refusal) {
  use next <- result.try(
    resolve_location(walk.attempt.url, location)
    |> result.replace_error(RedirectRefused(
      location,
      "the Location header is not a URL this client can resolve",
    )),
  )

  // `parse_target` carries the scheme check, so a Location that
  // downgrades to http:// is not this origin and is refused as a
  // redirect rather than reaching `SchemeNotHttps` on the next hop.
  case parse_target(next) == Ok(walk.origin) {
    True -> Ok(next)
    False ->
      Error(RedirectRefused(
        next,
        "the target leaves the origin the request was permitted to reach",
      ))
  }
}

/// Refuses a walk that has already used its hops.
fn within_hops(attempt: Hop, limit: Int, next: String) -> Result(Nil, Refusal) {
  case attempt.count < limit {
    True -> Ok(Nil)
    False ->
      Error(RedirectRefused(
        next,
        "more than " <> int.to_string(limit) <> " redirects",
      ))
  }
}

/// The next hop after a redirect.
///
/// 303 means "the answer is elsewhere, go and read it", so the method
/// becomes `GET` and the body is dropped — and because `hop` re-checks
/// the method, a policy that does not permit `GET` refuses the walk
/// there rather than smuggling a `POST` body somewhere new.
fn advance(attempt: Hop, status: Int, next: String) -> Hop {
  let moved = Hop(..attempt, url: next, count: attempt.count + 1)

  case status == see_other {
    True -> Hop(..moved, method: Get, body: <<>>)
    False -> moved
  }
}

/// The `Location` of a redirect, if this response is one and named it.
fn location_of(
  status: Int,
  headers: List(#(String, String)),
) -> Option(String) {
  case list.contains(redirect_statuses, status) {
    True ->
      headers
      |> list.key_find("location")
      |> option.from_result

    False -> None
  }
}

/// Resolves a possibly relative `Location` against the hop's URL.
///
/// A reference that carries its own authority replaces the base's
/// authority whole, port included, so it is not merged: `uri.merge`
/// inherits the base's port there, which would let a `Location` naming
/// the same host on the default port resolve to the base's non-default
/// one and compare as the same origin. Only a reference with no
/// authority of its own is merged, and such a reference cannot leave the
/// origin at all.
fn resolve_location(base: String, location: String) -> Result(String, Nil) {
  use here <- result.try(uri.parse(base))
  use there <- result.try(uri.parse(location))

  case there.host {
    Some(_authority) ->
      Ok(uri.to_string(
        uri.Uri(..there, scheme: option.or(there.scheme, here.scheme)),
      ))

    None -> uri.merge(here, there) |> result.map(uri.to_string)
  }
}

/// The origin a URL names, or why it cannot be requested at all.
fn parse_target(url: String) -> Result(Origin, Refusal) {
  use parsed <- result.try(
    uri.parse(url) |> result.replace_error(MalformedUrl(url)),
  )
  use _ <- result.try(check_scheme(parsed, url))
  use _ <- result.try(check_userinfo(parsed, url))

  origin_of(parsed) |> result.replace_error(MalformedUrl(url))
}

/// Refuses anything but `https`, including a URL with no scheme.
fn check_scheme(parsed: uri.Uri, url: String) -> Result(Nil, Refusal) {
  let scheme =
    parsed.scheme
    |> option.map(string.lowercase)
    |> option.unwrap("")

  case scheme == "https" {
    True -> Ok(Nil)
    False -> Error(SchemeNotHttps(url))
  }
}

/// Refuses userinfo in the URL.
///
/// `https://user:pass@host/` is a credential the caller chose, in a
/// place this module does not police; refusing the URL keeps the one
/// credential path the `Secret` bindings.
fn check_userinfo(parsed: uri.Uri, url: String) -> Result(Nil, Refusal) {
  case parsed.userinfo {
    None -> Ok(Nil)
    Some(_present) -> Error(MalformedUrl(url))
  }
}

/// The origin of a parsed URL, lowercased and port-normalized.
fn origin_of(parsed: uri.Uri) -> Result(Origin, Nil) {
  case parsed.host {
    None -> Error(Nil)
    Some("") -> Error(Nil)
    Some(host) ->
      Ok(Origin(host: string.lowercase(host), port: explicit_port(parsed.port)))
  }
}

/// The origin an allowlist entry names: `host` or `host:port`.
///
/// An entry that does not fit that grammar returns an error and is
/// dropped from the comparison set, so a typo refuses traffic rather
/// than admitting it.
fn origin_from_entry(entry: String) -> Result(Origin, Nil) {
  case string.split(entry, ":") {
    [host] -> Ok(Origin(host: string.lowercase(host), port: None))

    [host, port] ->
      int.parse(port)
      |> result.map(fn(number) {
        Origin(host: string.lowercase(host), port: explicit_port(Some(number)))
      })

    [] | [_, _, _, ..] -> Error(Nil)
  }
}

/// Drops the scheme's default port so that the two spellings of the
/// same origin compare equal.
fn explicit_port(port: Option(Int)) -> Option(Int) {
  case port {
    Some(number) if number == default_https_port -> None
    Some(number) -> Some(number)
    None -> None
  }
}

/// Refuses an origin the policy does not name.
fn check_host(policy: Policy, origin: Origin) -> Result(Nil, Refusal) {
  let allowed = list.filter_map(policy.hosts, origin_from_entry)

  case list.contains(allowed, origin) {
    True -> Ok(Nil)
    False -> Error(HostNotAllowed(render_origin(origin), policy.hosts))
  }
}

/// Refuses a method the policy does not name.
fn check_method(policy: Policy, method: Method) -> Result(Nil, Refusal) {
  case list.contains(policy.methods, method) {
    True -> Ok(Nil)
    False -> Error(MethodNotAllowed(method))
  }
}

/// Refuses a caller header this module owns or cannot safely send.
///
/// This runs before anything is resolved or connected, so a caller
/// cannot use a collision to learn whether a credential exists. The
/// shape check comes first because a name carrying a line break would
/// not match the reserved name it is trying to smuggle past.
fn check_headers(
  policy: Policy,
  headers: List(#(String, String)),
) -> Result(Nil, Refusal) {
  let reserved =
    policy.secrets
    |> list.map(fn(secret) { string.lowercase(secret.header) })
    |> list.append(client_owned_headers)

  list.try_each(headers, fn(header) {
    let #(name, value) = header

    use _ <- result.try(check_header_shape(name, value))

    case list.contains(reserved, string.lowercase(name)) {
      True -> Error(HeaderReserved(name))
      False -> Ok(Nil)
    }
  })
}

/// Refuses a header whose name or value this module cannot send.
fn check_header_shape(name: String, value: String) -> Result(Nil, Refusal) {
  case unsendable(name) || unsendable(value) {
    True -> Error(HeaderMalformed(escape_line_endings(name)))
    False -> Ok(Nil)
  }
}

/// How one code point is rendered, if it is one that ends a header.
fn line_ending_escape(point: UtfCodepoint) -> Result(String, Nil) {
  list.key_find(line_ending_escapes, string.utf_codepoint_to_int(point))
}

/// Whether a string carries a code point this module will not send.
///
/// Two reasons a point is refused, and they are different failures. CR,
/// LF and NUL would reach the wire verbatim and let the sender append
/// headers of its own; anything above `max_header_point` `httpc` refuses
/// itself, in a way that puts the value into the error term.
///
/// Code points, not substrings, because Gleam's `string.contains` and
/// `string.replace` work on grapheme clusters and **CRLF is a single
/// cluster** — `string.contains("a\r\nb", "\r")` is `False`. A substring
/// scan would therefore miss the one sequence a smuggled header actually
/// uses, which is the whole point of the check.
fn unsendable(text: String) -> Bool {
  text
  |> string.to_utf_codepoints
  |> list.any(fn(point) { refuses_point(string.utf_codepoint_to_int(point)) })
}

/// Whether one code point is one of the two kinds this module refuses.
fn refuses_point(value: Int) -> Bool {
  value > max_header_point
  || result.is_ok(list.key_find(line_ending_escapes, value))
}

/// Renders the offending code points visibly, so a refusal that reaches
/// a log cannot forge a line there the way the header would have forged
/// one on the wire.
fn escape_line_endings(text: String) -> String {
  text
  |> string.to_utf_codepoints
  |> list.map(fn(point) {
    line_ending_escape(point)
    |> result.lazy_unwrap(fn() { string.from_utf_codepoints([point]) })
  })
  |> string.concat
}

/// Reads every bound credential before the first connection.
///
/// All of them, not just the ones this URL's origin would use: a policy
/// with an unset variable is broken for the whole call, and finding
/// that out on hop three would mean a request had already been made
/// under a policy that could not be satisfied.
fn resolve_secrets(
  policy: Policy,
  secrets: fn(String) -> Result(String, Nil),
) -> Result(List(#(Secret, String)), Refusal) {
  list.try_map(policy.secrets, fn(secret) {
    use value <- result.try(
      secrets(secret.env) |> result.replace_error(SecretMissing(secret.env)),
    )

    // The value is operator-supplied rather than caller-supplied, so this
    // is a configuration error and not an attack — but checking it here
    // is what makes "no header this module sends can end early" a
    // property of every header rather than of the caller's half. The
    // refusal names the header, never the value.
    use _ <- result.try(check_header_shape(secret.header, value))

    Ok(#(secret, value))
  })
}

/// The credential headers this hop's origin has earned.
fn injected(
  bound: List(#(Secret, String)),
  origin: Origin,
) -> List(#(String, String)) {
  list.filter_map(bound, fn(pair) {
    let #(secret, value) = pair

    case origin_from_entry(secret.host) == Ok(origin) {
      True -> Ok(#(secret.header, value))
      False -> Error(Nil)
    }
  })
}

/// What is left of the whole-request deadline, or the timeout refusal.
fn remaining_ms(policy: Policy, deadline: Int) -> Result(Int, Refusal) {
  let left = deadline - ffi_egress.monotonic_ms()

  case int.compare(left, 0) {
    order.Gt -> Ok(left)
    order.Eq | order.Lt -> Error(Timeout(policy.timeout_ms))
  }
}

/// The FFI's spelling of a trust decision.
fn roots(trust: Trust) -> ffi_egress.Roots {
  case trust {
    SystemRoots -> ffi_egress.SystemTrust
    PinnedRoots(ders:) -> ffi_egress.PinnedTrust(ders:)
  }
}

/// An origin as the allowlist grammar spells it, for a refusal message.
fn render_origin(origin: Origin) -> String {
  case origin.port {
    None -> origin.host
    Some(number) -> origin.host <> ":" <> int.to_string(number)
  }
}

/// The lowercase method name, which is both the wire spelling the FFI
/// expects and the label a refusal reads with.
fn method_label(method: Method) -> String {
  case method {
    Get -> "get"
    Post -> "post"
    Put -> "put"
    Delete -> "delete"
    Patch -> "patch"
    Head -> "head"
  }
}
