//// Trial policy tests preserve native state restrictions across fresh fixtures.

import broker/policy
import client/codemode
import client/serve
import client/serve_test
import client/workspace_policy
import gleam/list
import gleam/option.{None, Some}
import gleam/result

pub fn trial_preserves_native_masks_and_network_without_broad_host_roots_test() {
  let base = workspace_policy.base_policy("/source/work")
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

pub fn trial_socket_directory_stays_reachable_under_the_source_socket_root_test() {
  let base = workspace_policy.base_policy("/source/work")
  let trials = "/state/evolution-trials"
  let sockets = "/state/run"
  let limited =
    policy.SandboxPolicy(..base, protected: [trials, sockets, "/state/token"])
  let trial =
    serve.evolution_trial_policy(limited, trials, trials <> "/one/work")
  let directory = sockets <> "/9f2b4c1d7a3e5b60"

  // The trial binds its sockets under the source's socket root, so the mask
  // over that root is the entry the launch lifts.
  let reachable = codemode.reaching_socket(trial, under: sockets, directory:)
  assert !list.any(reachable.protected, fn(entry) {
    policy.covers(root: entry, path: directory)
  })
    as "a trial's satellite socket directory is not covered by any mask"
  assert list.contains(reachable.protected, "/state/token")
    as "unrelated masks survive the reopening"

  // A socket root nested below the masked daemon root cannot lift the mask
  // above it, which refused every code-mode launch in a trial.
  let nested = sockets <> "/trial-x"
  let refused =
    codemode.reaching_socket(trial, under: nested, directory: nested <> "/ab")
  assert list.any(refused.protected, fn(entry) {
    policy.covers(root: entry, path: nested <> "/ab")
  })
    as "a nested socket root leaves the daemon's mask over the directory"
}

// A trial binds under the source's socket root, so the source's evolution
// directories enclose the trial's own workspace. The masks a trial hands the
// workspace check must therefore be empty, or the check refuses the trial's
// boot. Reading the masks off the role, not off a profile list, is what keeps
// a source session from losing its masks if profiles ever become a real
// override.
pub fn a_trial_session_passes_the_workspace_check_under_the_source_state_test() {
  let trials = "/state/evolution-trials"
  let workspace = trials <> "/one/work"
  let source =
    serve.Settings(
      ..serve_test.settings_under("build/trial-role-test"),
      codemode_sockets: Some("/state/run"),
    )
  let trial =
    serve.Settings(
      ..source,
      workspace:,
      base_policy: serve.evolution_trial_policy(
        source.base_policy,
        trials,
        workspace,
      ),
      evolution_role: serve.Trial([]),
    )

  assert serve.evolution_masks(trial) == []
    as "a trial masks nothing beyond the base it inherits"
  assert list.contains(serve.evolution_masks(source), trials)
    as "the source masks its trial parent, which encloses every trial"
  assert trial_base_fault(trial, serve.evolution_masks(trial)) == Ok(Nil)
    as "a trial-shaped settings value passes the workspace check"

  // The same trial given the source's directories is the shape that refused
  // every trial boot: the mask over the trial parent shadows the workspace.
  let sourced = serve.Settings(..trial, evolution_role: serve.Source)
  assert result.is_error(trial_base_fault(trial, serve.evolution_masks(sourced)))
    as "the source's masks over a trial workspace are not enforceable"
}

fn trial_base_fault(
  settings: serve.Settings,
  masks: List(String),
) -> Result(Nil, String) {
  let basis =
    workspace_policy.Basis(
      base_policy: settings.base_policy,
      workspace: settings.workspace,
      tools: settings.tools,
      go_caches: None,
    )
  let files =
    workspace_policy.OwnerFiles(
      index: "/state/index.db",
      memory_store: "/state/memory.db",
      rules: "/state/rules.md",
      memory_notes: "/state/notes.db",
      evolution: masks,
    )
  workspace_policy.session_base(basis, Some(files), Error("no toolchain"))
  |> workspace_policy.base_policy_fault
}
