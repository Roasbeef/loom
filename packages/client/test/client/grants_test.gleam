//// The grant-JSON bridge: internal escalation vocabulary ↔ typed
//// `broker/policy.Grant` ↔ the protocol's wire vocabulary.

import broker/escalation
import broker/policy
import client/grants
import client/protocol
import core/json
import gleam/list
import gleam/option.{None, Some}

fn all_grants() -> List(policy.Grant) {
  [
    policy.GrantWritableRoot(path: "/work/out"),
    policy.GrantReadableRoot(path: "/usr/share"),
    policy.GrantNetwork(network: policy.NetworkOff),
    policy.GrantNetwork(network: policy.NetworkFull),
    policy.GrantNetwork(network: policy.NetworkProxy(
      allow: ["registry.npmjs.org"],
      proxy: "127.0.0.1:3128",
    )),
    policy.GrantEnv(name: "PATH"),
    policy.GrantLimit(field: policy.CpuSeconds, value: 600),
    policy.GrantLimit(field: policy.WallSeconds, value: 0),
    policy.GrantLimit(field: policy.MemBytes, value: 1024),
    policy.GrantLimit(field: policy.Pids, value: 64),
    policy.GrantLimit(field: policy.FsizeBytes, value: 1),
    policy.GrantLimit(field: policy.OutputBytes, value: 2),
    policy.GrantScratch(scratch: policy.ScratchTmpfs),
    policy.GrantScratch(scratch: policy.ScratchPath(path: "/scratch")),
  ]
}

pub fn internal_vocabulary_roundtrips_test() {
  all_grants()
  |> list.each(fn(grant) {
    assert grants.decode(grants.encode(grant)) == Ok(grant)
  })
}

pub fn wire_vocabulary_roundtrips_test() {
  all_grants()
  |> list.each(fn(grant) {
    assert protocol.decode_grant(protocol.encode_grant(grant)) == Ok(grant)
  })
}

// The two vocabularies are distinct on the wire: the internal form is
// `grant`-discriminated, the protocol form `type`-discriminated.
pub fn vocabularies_differ_test() {
  let grant = policy.GrantEnv(name: "PATH")
  assert grants.encode(grant) != protocol.encode_grant(grant)
}

pub fn malformed_grant_is_corruption_test() {
  let assert Error(_report) =
    grants.decode(json.Object([#("grant", json.String("teleport"))]))
  let assert Error(_report) = grants.decode(json.String("nope"))
}

pub fn denial_roundtrips_test() {
  let wanted = [
    policy.GrantNetwork(network: policy.NetworkProxy(
      allow: ["registry.npmjs.org"],
      proxy: "127.0.0.1:3128",
    )),
  ]
  let stored =
    grants.encode_denial(
      reason: "connect blocked by policy",
      source: escalation.PolicyDenial,
      wanted:,
    )
  assert grants.decode_denial(stored)
    == Ok(grants.DecodedDenial(
      reason: "connect blocked by policy",
      source: escalation.PolicyDenial,
      wanted:,
    ))
}

pub fn first_unwanted_bounds_approvals_test() {
  let wanted = [policy.GrantEnv(name: "PATH")]
  assert grants.first_unwanted([policy.GrantEnv(name: "PATH")], wanted:) == None
  assert grants.first_unwanted([policy.GrantEnv(name: "HOME")], wanted:)
    == Some(policy.GrantEnv(name: "HOME"))
}
