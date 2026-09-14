//// The manifest-to-policy translation for the one field that widens a
//// scheme rather than an allowlist.
////
//// The rest of the translation is tested in `dispatch_test`, beside the
//// dispatch that consumes it. This file is separate because what it
//// checks is a refusal rather than a mapping: a credential bound to a
//// plaintext origin must not produce a policy that could put the
//// credential on a plaintext hop, and that property is worth reading on
//// its own.

import broker/egress
import client/extension/manifest
import client/extension/policy as ext_policy

/// The waved gateway's own shape: one loopback origin, plaintext, with
/// no credential bound to it.
fn waved_net() -> manifest.Net {
  manifest.Net(
    ..manifest.no_net(),
    hosts: ["localhost:10031"],
    plaintext_loopback: ["localhost:10031"],
    methods: ["GET", "POST"],
    max_response_bytes: 65_536,
    requests_per_call: 8,
  )
}

pub fn a_plaintext_loopback_entry_reaches_the_policy_test() {
  let assert ext_policy.Reaches(policy: translated) =
    ext_policy.egress_for(waved_net(), trust: egress.SystemRoots)
    as "a manifest with hosts reaches something"

  assert translated.plaintext == ["localhost:10031"]
  assert translated.hosts == ["localhost:10031"]
}

/// The manifest refuses this pairing at install by name. This is the
/// second half: whatever reached the installer, the policy that gets
/// built cannot reach the origin over `http://` at all, so there is no
/// plaintext hop for the credential to be injected on.
pub fn a_secret_bound_to_a_plaintext_origin_removes_it_test() {
  let bound =
    manifest.Net(..waved_net(), secrets: [
      manifest.Secret(
        env: "WAVED_TOKEN",
        host: "localhost:10031",
        header: "authorization",
      ),
    ])

  let assert ext_policy.Reaches(policy: translated) =
    ext_policy.egress_for(bound, trust: egress.SystemRoots)
    as "a manifest with hosts reaches something"

  assert translated.plaintext == []

  // The origin is still reachable, and only over https: the subtraction
  // narrows the scheme rather than the allowlist.
  assert translated.hosts == ["localhost:10031"]
  assert egress.request(
      translated,
      egress.Request(
        method: egress.Get,
        url: "http://localhost:10031/v1/invoices",
        headers: [],
        body: <<>>,
      ),
      secrets: fn(_name) { Ok("unused") },
    )
    == Error(egress.SchemeNotHttps("http://localhost:10031/v1/invoices"))
}
