//// Trial policy tests preserve native state restrictions across fresh fixtures.

import broker/policy
import client/serve
import gleam/list

pub fn trial_preserves_native_masks_and_network_without_broad_host_roots_test() {
  let base = serve.base_policy("/source/work")
  let trials = "/state/evolution-trials"
  let workspace = trials <> "/one/work"
  let masks = ["/state/owner.token", "/state/sessions", "/state/evolution"]
  let limited =
    policy.SandboxPolicy(
      ..base,
      readable_roots: ["/"],
      writable_roots: ["/state", "/source/work"],
      protected: [trials, ..masks],
      network: policy.NetworkOff,
      scratch: policy.ScratchPath("/source/scratch"),
      mounts: [
        policy.Mount("/state", policy.MountReadWrite, policy.MountRequired),
      ],
    )
  let trial = serve.evolution_trial_policy(limited, trials, workspace)
  assert list.all(masks, fn(mask) { list.contains(trial.protected, mask) })
    as "a fresh fixture cannot discard the source daemon's protected state"
  assert !list.contains(trial.protected, trials)
    as "only the native trial parent exception makes this fixture reachable"
  assert trial.readable_roots == [workspace]
    && trial.writable_roots == [workspace]
    && trial.mounts == []
    && trial.scratch == policy.ScratchTmpfs
    as "neither host reads, broad grants nor mounts reach another trial"
  assert trial.network == policy.NetworkOff
    && trial.limits == limited.limits
    && trial.env_allow == limited.env_allow
    as "fresh trial authority does not widen network or resource restrictions"
}
