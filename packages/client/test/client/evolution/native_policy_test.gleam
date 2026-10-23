//// Native artifact access narrows the OS jail instead of unmasking state.
//// Caller grants and filesystem authority remain on capability calls alone.

import broker/budget
import broker/exec
import broker/policy
import client/evolution/native
import codemode/identity
import codemode/satellite
import core/clock
import core/ids
import core/msgpack
import gleam/list
import gleeunit/should

pub fn broad_session_state_roots_do_not_enter_native_artifact_jail_test() {
  let base =
    policy.SandboxPolicy(
      ..policy.workspace_default("/work"),
      readable_roots: ["/", "/state"],
      writable_roots: ["/state", "/work"],
      protected: ["/state/evolution", "/state/evolution/run/session"],
      mounts: [
        policy.Mount("/state", policy.MountReadWrite, policy.MountRequired),
      ],
    )
  let mounts = [
    policy.Mount("/opt/loom", policy.MountReadOnly, policy.MountRequired),
  ]
  let directory = "/state/evolution/run/session/candidate"
  let owned = native.owned_policy(base, "/state/evolution", directory, mounts)
  owned.writable_roots |> should.equal([directory])
  native.readonly_node(owned).writable_roots |> should.equal([])
  owned.mounts |> should.equal(mounts)
  list.any(owned.readable_roots, fn(root) {
    policy.covers(root, "/state/evolution/run/other-session/source.gleam")
  })
  |> should.be_false()
  list.any(owned.readable_roots, fn(root) { policy.covers(root, directory) })
  |> should.be_true()
  list.any(owned.readable_roots, fn(root) {
    policy.covers(root, "/opt/loom/bin/erl")
  })
  |> should.be_true()
}

pub fn capability_router_restores_original_policy_cwd_and_granted_identity_test() {
  let #(op, _) = ids.mint_op(ids.generator(clock.fixed(0), 807))
  let execution =
    identity.for_execution(op, "program", budget.Budget(2, 60_000))
    |> identity.widened_by([policy.GrantReadableRoot("/approved")])
  let caller_phase = identity.run_phase(execution)
  let launch_phase = identity.run_phase(native.node_identity(execution))
  identity.grants(launch_phase) |> should.equal([])
  identity.ledger_key(launch_phase)
  |> should.equal(identity.ledger_key(caller_phase))
  let base =
    policy.SandboxPolicy(..policy.workspace_default("/work"), protected: [
      "/state/evolution",
    ])
  let router =
    native.caller_router(
      fn(request) {
        request.base_policy |> should.equal(base)
        request.cwd |> should.equal("/work")
        request.identity |> should.equal(caller_phase)
        request.ordinal |> should.equal(3)
        Error(satellite.CapDenial("inspected", "caller retained"))
      },
      base,
      "/work",
      caller_phase,
    )
  router(satellite.CapRequest(
    cap: "proc.run",
    args: msgpack.NilValue,
    identity: launch_phase,
    base_policy: policy.workspace_default("/private/artifact"),
    demand: exec.BestEffort,
    env: [],
    cwd: "/private/artifact",
    ordinal: 3,
  ))
  |> should.equal(Error(satellite.CapDenial("inspected", "caller retained")))
}
