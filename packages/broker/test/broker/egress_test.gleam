//// The egress client's tests, split in two halves for one reason.
////
//// Everything a policy can refuse without a socket — scheme, origin,
//// method, a reserved header, an unset credential — is tested offline,
//// because those refusals must happen *before* a connection exists and a
//// test that needed a server to observe them would not be checking that.
//// Everything else runs against a real TLS origin on loopback whose
//// chain is generated at test time and whose root is pinned, so the
//// verification path the client actually uses is the one under test.
//// Nothing here relaxes verification; the untrusted-certificate case is
//// a second, unrelated root.

import broker/egress
import broker/support/origin
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/string

/// A canary that must never appear in rendered text. The value is only
/// ever handed to `request` through the `secrets` function.
const canary = "s3cr3t-canary-value"

/// The header a bound credential is injected into, and therefore the
/// header a caller may not set.
const secret_header = "x-loom-key"

/// The environment variable the bound credential names.
const secret_env = "SEARCH_API_KEY"

// ---------------------------------------------------------------------
// Offline: what is refused before a socket exists.
// ---------------------------------------------------------------------

/// A policy that permits one origin and `GET`, and whose pin can never
/// verify anything — safe precisely because none of these tests should
/// reach a connection.
fn offline_policy() -> egress.Policy {
  egress.Policy(
    hosts: ["api.example.com"],
    methods: [egress.Get],
    max_response_bytes: 1024,
    redirects: egress.NoRedirects,
    timeout_ms: 1000,
    secrets: [],
    trust: egress.PinnedRoots(ders: []),
  )
}

fn no_secrets(_name: String) -> Result(String, Nil) {
  Error(Nil)
}

fn get(url: String) -> egress.Request {
  egress.Request(method: egress.Get, url:, headers: [], body: <<>>)
}

pub fn refuses_plaintext_scheme_test() {
  let url = "http://api.example.com/search"

  assert egress.request(offline_policy(), get(url), secrets: no_secrets)
    == Error(egress.SchemeNotHttps(url))
}

pub fn refuses_userinfo_in_url_test() {
  let url = "https://user:pw@api.example.com/search"

  assert egress.request(offline_policy(), get(url), secrets: no_secrets)
    == Error(egress.MalformedUrl(url))
}

pub fn refuses_unlisted_host_test() {
  let url = "https://evil.example.com/search"

  assert egress.request(offline_policy(), get(url), secrets: no_secrets)
    == Error(egress.HostNotAllowed("evil.example.com", ["api.example.com"]))
}

pub fn refuses_explicit_port_the_allowlist_did_not_name_test() {
  let url = "https://api.example.com:8443/search"

  assert egress.request(offline_policy(), get(url), secrets: no_secrets)
    == Error(
      egress.HostNotAllowed("api.example.com:8443", [
        "api.example.com",
      ]),
    )
}

pub fn refuses_default_port_when_the_allowlist_names_another_test() {
  let policy =
    egress.Policy(..offline_policy(), hosts: ["api.example.com:8443"])

  assert egress.request(
      policy,
      get("https://api.example.com/search"),
      secrets: no_secrets,
    )
    == Error(egress.HostNotAllowed("api.example.com", ["api.example.com:8443"]))
}

/// `:443` and an absent port are the same origin. Proved without a
/// connection by emptying the method list: reaching `MethodNotAllowed`
/// means the host check already passed.
pub fn treats_explicit_443_as_the_default_port_test() {
  let policy =
    egress.Policy(
      ..offline_policy(),
      hosts: ["api.example.com:443"],
      methods: [],
    )

  assert egress.request(
      policy,
      get("https://api.example.com/search"),
      secrets: no_secrets,
    )
    == Error(egress.MethodNotAllowed(egress.Get))
}

pub fn refuses_a_method_the_policy_omits_test() {
  let post =
    egress.Request(
      method: egress.Post,
      url: "https://api.example.com/search",
      headers: [],
      body: <<"{}">>,
    )

  assert egress.request(offline_policy(), post, secrets: no_secrets)
    == Error(egress.MethodNotAllowed(egress.Post))
}

/// A policy with one credential bound to its one host.
fn bound_policy(host: String) -> egress.Policy {
  egress.Policy(..offline_policy(), secrets: [
    egress.Secret(env: secret_env, host:, header: secret_header),
  ])
}

pub fn refuses_a_caller_header_that_shadows_a_secret_test() {
  let call =
    egress.Request(
      method: egress.Get,
      url: "https://api.example.com/search",
      headers: [#("X-Loom-Key", "mine")],
      body: <<>>,
    )
  let secrets = fn(_name) { Ok(canary) }

  assert egress.request(bound_policy("api.example.com"), call, secrets:)
    == Error(egress.HeaderReserved("X-Loom-Key"))
}

pub fn refuses_a_caller_header_the_client_owns_test() {
  let call =
    egress.Request(
      method: egress.Get,
      url: "https://api.example.com/search",
      headers: [#("Host", "elsewhere.example")],
      body: <<>>,
    )

  assert egress.request(offline_policy(), call, secrets: no_secrets)
    == Error(egress.HeaderReserved("Host"))
}

pub fn refuses_a_line_break_in_a_header_name_test() {
  let call =
    egress.Request(
      method: egress.Get,
      url: "https://api.example.com/search",
      headers: [#("X-Trace\r\nX-Loom-Key", "mine")],
      body: <<>>,
    )

  assert egress.request(offline_policy(), call, secrets: no_secrets)
    == Error(egress.HeaderMalformed("X-Trace\\r\\nX-Loom-Key"))
}

pub fn refuses_a_line_break_in_a_header_value_test() {
  let call =
    egress.Request(
      method: egress.Get,
      url: "https://api.example.com/search",
      headers: [#("X-Trace", "ok\r\nHost: elsewhere.example")],
      body: <<>>,
    )

  assert egress.request(offline_policy(), call, secrets: no_secrets)
    == Error(egress.HeaderMalformed("X-Trace"))
}

/// A smuggled name must be refused for its shape, not merely fail to
/// match the reserved name it was hiding behind.
pub fn refuses_a_smuggled_credential_header_test() {
  let call =
    egress.Request(
      method: egress.Get,
      url: "https://api.example.com/search",
      headers: [#("X-Trace", "ok\r\n" <> secret_header <> ": mine")],
      body: <<>>,
    )
  let secrets = fn(_name) { Ok(canary) }

  assert egress.request(bound_policy("api.example.com"), call, secrets:)
    == Error(egress.HeaderMalformed("X-Trace"))
}

pub fn refuses_a_nul_byte_in_a_header_test() {
  let call =
    egress.Request(
      method: egress.Get,
      url: "https://api.example.com/search",
      headers: [#("X-Trace", "ok\u{0}more")],
      body: <<>>,
    )

  assert egress.request(offline_policy(), call, secrets: no_secrets)
    == Error(egress.HeaderMalformed("X-Trace"))
}

/// A credential value is operator-supplied, so this is a configuration
/// error rather than an attack — but it is refused for the same reason,
/// and the refusal names the header and never the value.
pub fn refuses_a_credential_value_that_would_end_a_header_test() {
  let policy = bound_policy("api.example.com")
  let secrets = fn(_name) { Ok("good\r\nx-injected: bad") }

  assert egress.request(policy, get("https://api.example.com/search"), secrets:)
    == Error(egress.HeaderMalformed(secret_header))
}

/// Above latin-1 `httpc` refuses the header itself, and its
/// `{invalid_header, {Key, Value}}` carries the value — so a credential
/// with one such character would print itself into a `TransportFailed`.
/// Refusing it here means the value never reaches a term at all.
pub fn refuses_a_credential_value_httpc_cannot_send_test() {
  let policy = bound_policy("api.example.com")
  let unsendable = "good\u{2028}bad"
  let secrets = fn(_name) { Ok(unsendable) }

  let outcome =
    egress.request(policy, get("https://api.example.com/search"), secrets:)

  assert outcome == Error(egress.HeaderMalformed(secret_header))

  let assert Error(refusal) = outcome as "an unsendable credential refuses"
  assert !string.contains(egress.describe(refusal), unsendable)
}

pub fn reports_an_unset_credential_before_connecting_test() {
  let policy = bound_policy("api.example.com")

  assert egress.request(
      policy,
      get("https://api.example.com/search"),
      secrets: no_secrets,
    )
    == Error(egress.SecretMissing(secret_env))
}

pub fn one_host_is_the_install_fetch_policy_test() {
  let policy =
    egress.one_host(
      "codeload.github.com",
      max_response_bytes: 33_554_432,
      timeout_ms: 60_000,
    )

  assert policy
    == egress.Policy(
      hosts: ["codeload.github.com"],
      methods: [egress.Get],
      max_response_bytes: 33_554_432,
      redirects: egress.SameHost(at_most: 2),
      timeout_ms: 60_000,
      secrets: [],
      trust: egress.SystemRoots,
    )
}

/// Every variant, with fields carrying the kind of content each one
/// really receives.
fn every_refusal() -> List(egress.Refusal) {
  [
    egress.SchemeNotHttps("http://api.example.com/search"),
    egress.HostNotAllowed("evil.example.com", ["api.example.com"]),
    egress.MethodNotAllowed(egress.Patch),
    egress.HeaderReserved(secret_header),
    egress.HeaderMalformed("x-trace\\r\\n" <> secret_header),
    egress.SecretMissing(secret_env),
    egress.RedirectRefused("https://elsewhere.example/x", "off origin"),
    egress.ResponseTooLarge(1024),
    egress.Timeout(1000),
    egress.TransportFailed("{tls_alert,{unknown_ca,\"bad certificate\"}}"),
    egress.MalformedUrl("https://user:pw@api.example.com/"),
  ]
}

pub fn describe_names_the_binding_but_never_the_value_test() {
  let rendered =
    every_refusal()
    |> list.map(egress.describe)
    |> string.join(" | ")

  assert string.contains(rendered, secret_env)
  assert string.contains(rendered, secret_header)
  assert !string.contains(rendered, canary)
}

// ---------------------------------------------------------------------
// Live: against a real TLS origin with a pinned root.
// ---------------------------------------------------------------------

fn authority(port: Int) -> String {
  "localhost:" <> int.to_string(port)
}

fn url(port: Int, path: String) -> String {
  "https://" <> authority(port) <> path
}

/// The live baseline: one pinned origin, `GET`, no redirects.
fn live_policy(port: Int, root: BitArray) -> egress.Policy {
  egress.Policy(
    hosts: [authority(port)],
    methods: [egress.Get],
    max_response_bytes: 65_536,
    redirects: egress.NoRedirects,
    timeout_ms: 10_000,
    secrets: [],
    trust: egress.PinnedRoots(ders: [root]),
  )
}

fn body_text(response: egress.Response) -> String {
  let assert Ok(text) = bit_array.to_string(response.body)
    as "the echo route answers UTF-8"

  text
}

pub fn fetches_over_a_verified_chain_test() {
  let #(server, port, root) = origin.start()
  let outcome =
    egress.request(
      live_policy(port, root),
      get(url(port, "/echo")),
      secrets: no_secrets,
    )
  origin.stop(server)

  let assert Ok(response) = outcome as "a pinned root verifies the origin"
  assert response.status == 200
  assert string.starts_with(body_text(response), "get\n")
}

pub fn returns_response_header_names_in_lower_case_test() {
  let #(server, port, root) = origin.start()
  let outcome =
    egress.request(
      live_policy(port, root),
      get(url(port, "/echo")),
      secrets: no_secrets,
    )
  origin.stop(server)

  let assert Ok(response) = outcome as "the echo route answers 200"
  assert list.key_find(response.headers, "content-type") == Ok("text/plain")
}

/// One policy, two permitted origins, one credential. The credential
/// belongs to the first origin and must not travel to the second.
pub fn injects_a_credential_only_for_the_origin_it_is_bound_to_test() {
  let #(bound_server, bound_port, root) = origin.start()
  let #(other_server, other_port, _same_root) = origin.start()
  let policy =
    egress.Policy(
      ..live_policy(bound_port, root),
      hosts: [authority(bound_port), authority(other_port)],
      secrets: [
        egress.Secret(
          env: secret_env,
          host: authority(bound_port),
          header: secret_header,
        ),
      ],
    )
  let secrets = fn(name) {
    case name == secret_env {
      True -> Ok(canary)
      False -> Error(Nil)
    }
  }

  let bound =
    egress.request(policy, get(url(bound_port, "/echo")), secrets: secrets)
  let other =
    egress.request(policy, get(url(other_port, "/echo")), secrets: secrets)
  origin.stop(bound_server)
  origin.stop(other_server)

  let assert Ok(with_key) = bound as "the bound origin answers"
  let assert Ok(without_key) = other as "the other origin answers"
  assert string.contains(body_text(with_key), secret_header <> ": " <> canary)
  assert !string.contains(body_text(without_key), secret_header)
}

pub fn follows_a_redirect_within_the_origin_test() {
  let #(server, port, root) = origin.start()
  let policy =
    egress.Policy(..live_policy(port, root), redirects: egress.SameHost(2))
  let outcome =
    egress.request(
      policy,
      get(url(port, "/redirect-same")),
      secrets: no_secrets,
    )
  origin.stop(server)

  let assert Ok(response) = outcome as "a same-origin redirect is followed"
  assert response.status == 200
  assert string.starts_with(body_text(response), "get\n")
}

pub fn resolves_a_relative_redirect_test() {
  let #(server, port, root) = origin.start()
  let policy =
    egress.Policy(..live_policy(port, root), redirects: egress.SameHost(2))
  let outcome =
    egress.request(
      policy,
      get(url(port, "/redirect-relative")),
      secrets: no_secrets,
    )
  origin.stop(server)

  let assert Ok(response) = outcome as "a relative Location cannot leave"
  assert response.status == 200
}

pub fn refuses_a_redirect_that_leaves_the_origin_test() {
  let #(server, port, root) = origin.start()
  let policy =
    egress.Policy(..live_policy(port, root), redirects: egress.SameHost(2))
  let outcome =
    egress.request(policy, get(url(port, "/redirect-off")), secrets: no_secrets)
  origin.stop(server)

  let assert Error(egress.RedirectRefused(to:, why: _)) = outcome
    as "an off-origin redirect is refused"
  assert to == "https://elsewhere.example/echo"
}

pub fn refuses_a_redirect_when_the_policy_forbids_them_test() {
  let #(server, port, root) = origin.start()
  let outcome =
    egress.request(
      live_policy(port, root),
      get(url(port, "/redirect-same")),
      secrets: no_secrets,
    )
  origin.stop(server)

  let assert Error(egress.RedirectRefused(to: _, why:)) = outcome
    as "NoRedirects refuses where the 3xx was found"
  assert string.contains(why, "does not follow redirects")
}

pub fn stops_a_redirect_walk_at_the_hop_limit_test() {
  let #(server, port, root) = origin.start()
  let policy =
    egress.Policy(..live_policy(port, root), redirects: egress.SameHost(2))
  let outcome =
    egress.request(
      policy,
      get(url(port, "/redirect-loop")),
      secrets: no_secrets,
    )
  origin.stop(server)

  let assert Error(egress.RedirectRefused(to: _, why:)) = outcome
    as "a redirect loop exhausts its hops"
  assert string.contains(why, "more than 2 redirects")
}

pub fn turns_a_303_into_a_get_without_a_body_test() {
  let #(server, port, root) = origin.start()
  let policy =
    egress.Policy(
      ..live_policy(port, root),
      methods: [egress.Post, egress.Get],
      redirects: egress.SameHost(2),
    )
  let post =
    egress.Request(
      method: egress.Post,
      url: url(port, "/see-other"),
      headers: [],
      body: <<"submitted">>,
    )

  let outcome = egress.request(policy, post, secrets: no_secrets)
  origin.stop(server)

  let assert Ok(response) = outcome as "the 303 target answers"
  assert string.starts_with(body_text(response), "get\n")
}

pub fn refuses_a_declared_content_length_over_the_cap_test() {
  let #(server, port, root) = origin.start()
  let policy =
    egress.Policy(..live_policy(port, root), max_response_bytes: 1024)
  let outcome =
    egress.request(policy, get(url(port, "/declared-big")), secrets: no_secrets)
  origin.stop(server)

  assert outcome == Error(egress.ResponseTooLarge(1024))
}

pub fn cancels_a_streamed_body_that_passes_the_cap_test() {
  let #(server, port, root) = origin.start()
  let policy =
    egress.Policy(..live_policy(port, root), max_response_bytes: 16_384)
  let outcome =
    egress.request(policy, get(url(port, "/slow")), secrets: no_secrets)
  origin.stop(server)

  assert outcome == Error(egress.ResponseTooLarge(16_384))
}

pub fn gives_up_at_the_whole_request_deadline_test() {
  let #(server, port, root) = origin.start()
  let policy = egress.Policy(..live_policy(port, root), timeout_ms: 400)
  let outcome =
    egress.request(policy, get(url(port, "/sleep")), secrets: no_secrets)
  origin.stop(server)

  assert outcome == Error(egress.Timeout(400))
}

pub fn refuses_a_chain_it_has_no_root_for_test() {
  let #(server, port, _root) = origin.start()
  let policy =
    egress.Policy(
      ..live_policy(port, <<>>),
      trust: egress.PinnedRoots(ders: [origin.foreign_root()]),
      secrets: [
        egress.Secret(
          env: secret_env,
          host: authority(port),
          header: secret_header,
        ),
      ],
    )
  let outcome =
    egress.request(policy, get(url(port, "/echo")), secrets: fn(_name) {
      Ok(canary)
    })
  origin.stop(server)

  let assert Error(egress.TransportFailed(reason:)) = outcome
    as "an unpinned chain does not verify"
  assert !string.contains(reason, canary)
}

/// The trap this closes: `ssl`'s client session cache is node-global and
/// keyed on host and port alone, and a resumed TLS 1.2 handshake sends
/// no certificate at all. Without `reuse_sessions` off, a session any
/// other policy — or the provider's own client, which shares this node —
/// had already established to the origin would carry the second request
/// past the roots it was supposed to be held to. So the pin has to
/// refuse even when a good session to the same origin exists.
///
/// The origin is pinned to TLS 1.2 because that is the only place the
/// bypass lives: 1.3 resumes through tickets, which OTP's client has off
/// by default, so a 1.3 origin would make this test pass whatever the
/// client did.
pub fn does_not_resume_a_session_established_under_other_roots_test() {
  let #(server, port, root) = origin.start_tls12()
  let trusted = live_policy(port, root)
  let pinned_elsewhere =
    egress.Policy(
      ..trusted,
      trust: egress.PinnedRoots(ders: [origin.foreign_root()]),
    )

  let first =
    egress.request(trusted, get(url(port, "/echo")), secrets: no_secrets)
  let second =
    egress.request(
      pinned_elsewhere,
      get(url(port, "/echo")),
      secrets: no_secrets,
    )
  origin.stop(server)

  let assert Ok(_established) = first
    as "the trusted fetch establishes a session"
  let assert Error(egress.TransportFailed(reason:)) = second
    as "the foreign pin refuses despite the cached session"
  assert string.contains(reason, "unknown_ca")
}

/// The certificate names `localhost` and nothing else, so the same
/// origin reached by address must fail hostname verification even though
/// the chain itself verifies.
pub fn refuses_a_certificate_that_does_not_name_the_host_test() {
  let #(server, port, root) = origin.start()
  let address = "127.0.0.1:" <> int.to_string(port)
  let policy = egress.Policy(..live_policy(port, root), hosts: [address])
  let outcome =
    egress.request(
      policy,
      get("https://" <> address <> "/echo"),
      secrets: no_secrets,
    )
  origin.stop(server)

  let assert Error(egress.TransportFailed(reason:)) = outcome
    as "a certificate for another name does not verify"
  assert string.contains(reason, "hostname_check_failed")
}

/// The refusal that comes back from a walk which had already injected
/// the credential — the one place a live value and a rendered refusal
/// meet.
pub fn a_live_refusal_after_injection_carries_no_credential_test() {
  let #(server, port, root) = origin.start()
  let policy =
    egress.Policy(
      ..live_policy(port, root),
      redirects: egress.SameHost(2),
      secrets: [
        egress.Secret(
          env: secret_env,
          host: authority(port),
          header: secret_header,
        ),
      ],
    )
  let outcome =
    egress.request(policy, get(url(port, "/redirect-off")), secrets: fn(_name) {
      Ok(canary)
    })
  origin.stop(server)

  let assert Error(refusal) = outcome as "the off-origin redirect is refused"
  assert !string.contains(egress.describe(refusal), canary)
}
