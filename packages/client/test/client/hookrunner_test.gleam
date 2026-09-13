//// The imported-hook command runner against the real jailed executor:
//// one helper, one broker, real `sh -c` processes — the same fixture
//// shape the developer-environment test uses, trimmed to what the
//// runner needs.

import broker/broker
import broker/exec
import broker/policy
import broker/token
import client/hookrunner
import client/internal/ffi_os
import client/serve
import core/clock
import core/ids
import gleam/int
import gleam/option.{None, Some}
import host/bootstrap
import simplifile

pub fn shell_form_hook_runs_and_reports_test() {
  let #(ctx, _helper) = fixture()
  let cmd = hookrunner.Command("echo out; echo err >&2; exit 7", None, Some(3))
  let assert Ok(outcome) = hookrunner.run(ctx, cmd, "{}", 30)
  assert outcome.code == 7
  assert outcome.stdout == "out\n"
  assert outcome.stderr == "err\n"
  assert outcome.ending == hookrunner.RanToExit
  assert outcome.capture == hookrunner.Whole
}

pub fn stdin_reaches_the_hook_test() {
  let #(ctx, _helper) = fixture()
  let cmd = hookrunner.Command("cat", None, Some(3))
  let assert Ok(outcome) =
    hookrunner.run(ctx, cmd, "{\"prompt\":\"hello\"}", 30)
  assert outcome.code == 0
  assert outcome.stdout == "{\"prompt\":\"hello\"}"
}

pub fn exec_form_passes_arguments_without_a_shell_test() {
  let #(ctx, _helper) = fixture()
  let cmd = hookrunner.Command("printf", Some(["%s %s", "a;b", "c|d"]), Some(3))
  let assert Ok(outcome) = hookrunner.run(ctx, cmd, "{}", 30)
  assert outcome.code == 0
  assert outcome.stdout == "a;b c|d"
}

/// A `~` in an imported command means the operator's home, the way it
/// does under Claude — and it means it because the hook process runs
/// with `HOME` pointed there, not because anything rewrote the command.
/// The command reaches `sh -c` verbatim, so the shell expands the `~`
/// in every position it would expand one.
pub fn a_tilde_resolves_to_the_operator_home_test() {
  let #(ctx, _helper) = fixture()
  let cmd = hookrunner.Command("echo ~/x", None, Some(3))
  let assert Ok(outcome) = hookrunner.run(ctx, cmd, "{}", 30)
  assert outcome.code == 0
  assert outcome.stdout == operator_home(ctx.workspace) <> "/x\n"
}

/// The case the whole ruling is for: ten of the sixteen entries in the
/// reference collection name `~/.claude/hooks/...`, so the script has
/// to be found and executed where the operator keeps it. The `~` here
/// is the first character of the command, which is exactly the position
/// the deleted rewriter used to claim for the workspace.
pub fn a_script_under_the_operator_home_runs_by_tilde_path_test() {
  let #(ctx, _helper) = fixture()
  let home = operator_home(ctx.workspace)
  let assert Ok(Nil) = simplifile.create_directory_all(home <> "/hooks")
    as "the fixture's hook directory must be creatable"
  let assert Ok(Nil) =
    simplifile.write(home <> "/hooks/x.sh", "#!/bin/sh\necho ran\n")
    as "the stub hook script must be writable"
  let assert Ok(Nil) =
    simplifile.set_permissions_octal(home <> "/hooks/x.sh", 0o755)
    as "the stub hook script must be executable"

  let cmd = hookrunner.Command("~/hooks/x.sh", None, Some(3))
  let assert Ok(outcome) = hookrunner.run(ctx, cmd, "{}", 30)
  assert outcome.code == 0
  assert outcome.stdout == "ran\n"
}

/// A daemon started with `HOME` unset has no operator home to point at,
/// and `serve.resolve` records that rather than guessing one. The jail's
/// own home stands, `~` means it, and the hook still runs — a missing
/// name is not a failure here.
pub fn without_a_home_the_jail_home_stands_test() {
  let #(ctx, _helper) = fixture()
  let ctx =
    hookrunner.Context(
      ..ctx,
      env: serve.hook_environment(
        serve.session_environment(ctx.workspace, None),
        None,
        ctx.workspace,
      ),
    )
  let cmd = hookrunner.Command("echo ~/x", None, Some(3))
  let assert Ok(outcome) = hookrunner.run(ctx, cmd, "{}", 30)
  assert outcome.code == 0
  assert outcome.stdout == serve.tool_home_directory(ctx.workspace) <> "/x\n"
}

pub fn a_timed_out_hook_reports_no_output_test() {
  let #(ctx, _helper) = fixture()
  let cmd = hookrunner.Command("echo partial; sleep 30", None, Some(1))
  let started = bootstrap.monotonic_time_ms()
  let assert Ok(outcome) = hookrunner.run(ctx, cmd, "{}", 30)
  let elapsed = bootstrap.monotonic_time_ms() - started
  assert outcome.ending == hookrunner.WallCancelled
  assert outcome.stdout == ""
  assert outcome.stderr == ""
  assert elapsed < 20_000
}

pub fn an_absent_timeout_takes_the_events_default_test() {
  let #(ctx, _helper) = fixture()
  let cmd = hookrunner.Command("exit 0", None, None)
  let assert Ok(outcome) = hookrunner.run(ctx, cmd, "{}", 30)
  assert outcome.code == 0
}

pub fn the_env_allowlist_reaches_the_hook_test() {
  let #(ctx, _helper) = fixture()
  let ctx =
    hookrunner.Context(..ctx, env: [#("HOOK_MARKER", "visible"), ..ctx.env])
  let cmd = hookrunner.Command("echo $HOOK_MARKER", None, Some(3))
  let assert Ok(outcome) = hookrunner.run(ctx, cmd, "{}", 30)
  assert outcome.stdout == "visible\n"
}

/// A name in the hook's environment that the session base does not
/// allow does not reach the hook as an empty variable — it refuses the
/// call outright, before any process exists.
///
/// That is the whole reason `serve.allowing_imported_hook_env` has to
/// widen the base for `CLAUDE_PROJECT_DIR`: `call_spec` derives its
/// `env_allow` requirement from the keys of `ctx.env`, `policy.meet`
/// intersects it with the base, and the spec's `RefuseNarrowed`
/// response turns the shortfall into a refusal. This asserts the
/// mechanism is live, which the previous reading of this test — a
/// variable no environment sets, echoed with a default — could not:
/// deleting the `env_allow` requirement left that one green.
pub fn a_name_outside_the_base_allowlist_refuses_the_hook_test() {
  let #(ctx, _helper) = fixture()
  let ctx =
    hookrunner.Context(..ctx, env: [#("HOOK_UNGRANTED", "x"), ..ctx.env])
  let cmd = hookrunner.Command("echo ${HOOK_UNGRANTED:-unset}", None, Some(3))
  let assert Error(hookrunner.Refused(_denial)) =
    hookrunner.run(ctx, cmd, "{}", 30)
    as "a narrowed environment refuses rather than hiding the name"
}

/// A hook that prints past the output cap has its text discarded, the
/// same way a timed-out hook's is: a stream cut mid-object is not a
/// decision, and a clipped capture that classified as plain text would
/// read as a clean proceed.
pub fn a_hook_that_overruns_the_output_cap_reports_no_text_test() {
  let #(ctx, _helper) = fixture()
  let cmd =
    hookrunner.Command(
      "yes aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa | head -c 2000000",
      None,
      Some(30),
    )
  let assert Ok(outcome) = hookrunner.run(ctx, cmd, "{}", 30)
  assert outcome.capture == hookrunner.Clipped
  assert outcome.stdout == ""
}

// One jailed fixture: a workspace, a session-shaped base policy, the
// real helper, and a broker over it — the developer-environment
// fixture's arrangement, trimmed to what the runner needs. The helper
// outlives the test the way it does there; the workspace stays in
// `build/` and is gitignored.
fn fixture() -> #(hookrunner.Context, exec.Helper) {
  let assert Ok(here) = simplifile.current_directory()
  let workspace =
    here
    <> "/build/hookrunner-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let home = serve.tool_home_directory(workspace)
  let temp = serve.tool_tmp_directory(workspace)
  let assert Ok(Nil) = simplifile.create_directory_all(home)
  let assert Ok(Nil) = simplifile.create_directory_all(temp)
  let assert Ok(Nil) = simplifile.create_directory_all(operator_home(workspace))

  let base = serve.base_policy(workspace) |> serve.merging_mounts

  // The base grants every name these tests put in `ctx.env`, because
  // that is what the session base does: `call_spec` asks for the keys
  // of `ctx.env` and `RefuseNarrowed` refuses the call over any name
  // the base withholds. `HOOK_UNGRANTED` is deliberately absent, which
  // is what the refusal test turns on.
  let base =
    policy.SandboxPolicy(..base, env_allow: [
      "PATH", "HOME", "TMPDIR", "CLAUDE_PROJECT_DIR", "HOOK_MARKER",
    ])
  let assert Ok(helper) =
    exec.spawn_helper(exec.SpawnConfig(
      helper_path: here <> "/../sandbox/loom-exec",
      shell_path: "/bin/sh",
      base_policy: base,
      helper_args: [],
      tmp_dir: temp,
      handshake_timeout_ms: 5000,
      cancel_grace_ms: 3000,
      heartbeat_interval_ms: 0,
    ))
  let wall = clock.from_function(ffi_os.system_time_ms)
  let assert Ok(broker_actor) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: wall,
        checkout: fn() { Ok(helper) },
        checkin: fn(_helper) { Nil },
      ),
    )
  let #(op_id, _generator) = ids.mint_op(ids.generator(wall, seed: 20_260_911))

  // The enforcement demand the fixture runs under, and the one place
  // this suite deliberately does not copy production.
  // `PlatformEnforcement` refuses any run whose enforcement report
  // carries a `skip:` entry, and a test host is under no obligation to
  // supply every layer. A Linux box whose cgroup v2 root is not
  // delegated reports `skip:cgroup-v2 ... memory.max and pids.max NOT
  // applied`, so the broker settles the call as `DegradedExecution`
  // even though the hook ran and exited with the code the test asked
  // for. That reaches the runner as its blanket failure outcome — code
  // 1, no text — and every assertion here about stdin, argv, `~` and
  // exit codes then fails for a reason none of them is about.
  // `BestEffort` is what every other jailed fixture in the tree asks
  // for; the enforcement layers themselves are proven by `make
  // selftest` and the broker's own demand tests.
  let demand = exec.BestEffort
  #(
    hookrunner.Context(
      broker: broker_actor,
      base_policy: base,
      op_id:,
      step_id: "hookcompat-fixture",
      workspace:,
      env: serve.hook_environment(
        serve.session_environment(workspace, None),
        Some(operator_home(workspace)),
        workspace,
      ),
      demand:,
      clock: wall,
      session_id: "hookrunner-fixture",
      transcript_path: workspace <> "/session.db",
    ),
    helper,
  )
}

// Where this fixture puts the operator's home: beside the workspace,
// never the machine's real `HOME`. A test that read the developer's own
// home would pass on their machine for a reason it could not state, and
// the scripts it writes would land in a directory they did not ask for.
fn operator_home(workspace: String) -> String {
  workspace <> "-home"
}
