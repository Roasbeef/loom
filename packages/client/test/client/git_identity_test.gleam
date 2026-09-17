//// Git identity is checked through the real broker and kernel jail.
//// Fixtures use an independent operator home, so a passing commit cannot
//// accidentally borrow the developer or CI runner's configured identity.

import broker/broker
import broker/budget
import broker/exec
import broker/policy
import client/catalog
import client/git_identity
import client/internal/ffi_os
import client/serve
import client/worktree_diff
import core/clock
import core/ids
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import simplifile
import tools/tool
import weft

pub fn concurrent_preparation_preserves_existing_readers_test() {
  use wiring, home <- with_fixture()
  write(
    home <> "/.gitconfig",
    "[user]\nname = Operator\nemail = operator@example.invalid\n",
  )
  git(wiring, ["init", "--quiet"])
  assert git_identity.prepare(wiring, Some(home), reading: absent) == Ok(None)

  // An existing Git writer owns the destination lock. Preparing another
  // session must neither claim that lock nor truncate the published file.
  let destination = serve.tool_home_directory(wiring.workspace) <> "/gitconfig"
  write(destination <> ".lock", "existing writer\n")
  let outcomes =
    weft.new([
      fn() {
        list.each(list.repeat(Nil, 5), fn(_) {
          assert git_identity.prepare(wiring, Some(home), reading: absent)
            == Ok(None)
        })
        Ok(Nil)
      },
      fn() {
        list.each(list.repeat(Nil, 5), fn(_) {
          assert git_identity.prepare(wiring, Some(home), reading: absent)
            == Ok(None)
        })
        Ok(Nil)
      },
      fn() {
        list.each(list.repeat(Nil, 20), fn(_) {
          assert git(wiring, ["config", "--global", "--get-regexp", "^user\\."])
            == "user.useconfigonly true\nuser.name Operator\nuser.email operator@example.invalid\n"
        })
        Ok(Nil)
      },
    ])
    |> weft.deadline(20_000)
    |> weft.start
  assert list.all(outcomes, fn(outcome) {
    case outcome {
      weft.Completed(..) -> True
      _ -> False
    }
  })
    as "both preparations and the existing reader complete"
  assert read(destination <> ".lock") == "existing writer\n"
}

pub fn global_defaults_preserve_local_identity_and_original_authors_test() {
  use wiring, home <- with_fixture()
  write(
    home <> "/.gitconfig",
    "[user]\nname = Operator\nemail = operator@example.invalid\n[core]\nhooksPath = /unavailable/hooks\n[credential]\nhelper = !touch credential-was-run\n",
  )
  git(wiring, ["init", "--quiet"])
  assert git_identity.prepare(wiring, Some(home), reading: absent) == Ok(None)
  let projected =
    read(serve.tool_home_directory(wiring.workspace) <> "/gitconfig")
  assert !string.contains(projected, "credential")
  assert !string.contains(projected, "hooksPath")
  git(wiring, ["commit", "--allow-empty", "--quiet", "-m", "operator"])
  assert git(wiring, ["show", "-s", "--format=%an <%ae>|%cn <%ce>"])
    == "Operator <operator@example.invalid>|Operator <operator@example.invalid>\n"

  // A project can choose another identity without losing the global default.
  git(wiring, ["config", "user.name", "Repository Owner"])
  git(wiring, ["config", "user.email", "repository@example.invalid"])
  git(wiring, ["commit", "--allow-empty", "--quiet", "-m", "local"])
  assert git(wiring, ["show", "-s", "--format=%an <%ae>|%cn <%ce>"])
    == "Repository Owner <repository@example.invalid>|Repository Owner <repository@example.invalid>\n"

  // Preserve somebody else's author when creating the equivalent commit.
  git(wiring, ["checkout", "--quiet", "-b", "source"])
  write(wiring.workspace <> "/change", "a real cherry-pick change\n")
  git(wiring, ["add", "change"])
  git(wiring, [
    "commit",
    "--quiet",
    "--author=Contributor <contributor@example.invalid>",
    "-m",
    "contributor",
  ])
  let source = string.trim(git(wiring, ["rev-parse", "HEAD"]))
  git(wiring, ["checkout", "--quiet", "--detach", "HEAD~1"])
  git(wiring, ["cherry-pick", source])
  assert git(wiring, ["show", "-s", "--format=%an <%ae>|%cn <%ce>"])
    == "Contributor <contributor@example.invalid>|Repository Owner <repository@example.invalid>\n"
}

pub fn absent_identity_refuses_a_commit_until_repository_configuration_test() {
  use wiring, home <- with_fixture()
  git(wiring, ["init", "--quiet"])
  assert git_identity.prepare(wiring, Some(home), reading: absent) == Ok(None)
  let failed =
    invoke(wiring, ["git", "commit", "--allow-empty", "-m", "must fail"])
  let assert broker.CallExited(report) = failed.outcome
    as "Git returns a normal refusal"
  assert report.code != 0 as "Git must not infer a hostname-based identity"
  assert string.contains(text(failed.stderr), "auto-detection is disabled")
  git(wiring, ["config", "user.name", "Explicit"])
  git(wiring, ["config", "user.email", "explicit@example.invalid"])
  git(wiring, ["commit", "--allow-empty", "--quiet", "-m", "configured"])
  assert git(wiring, ["show", "-s", "--format=%ae"])
    == "explicit@example.invalid\n"
}

pub fn conditional_global_identity_resolves_for_linked_worktrees_test() {
  use wiring, home <- with_fixture()
  git(wiring, ["init", "--quiet"])
  git(wiring, [
    "-c",
    "user.name=Setup",
    "-c",
    "user.email=setup@example.invalid",
    "commit",
    "--allow-empty",
    "--quiet",
    "-m",
    "base",
  ])
  let linked = wiring.workspace <> "/linked"
  git(wiring, ["worktree", "add", "--quiet", "-b", "linked", linked])
  write(
    home <> "/identity",
    "[user]\nname = Conditional\nemail = conditional@example.invalid\n",
  )
  write(
    home <> "/.gitconfig",
    "[user]\nname = Default\nemail = default@example.invalid\n[includeIf \"gitdir:"
      <> wiring.workspace
      <> "/.git/worktrees/\"]\npath = identity\n",
  )
  let assert Ok(Nil) =
    simplifile.create_directory_all(serve.tool_home_directory(linked))
    as "the linked tool home exists"
  let #(environment, _) =
    serve.tool_environment(
      linked,
      None,
      catalog.default_tools(),
      reading: absent,
    )
  let linked =
    worktree_diff.Wiring(..wiring, workspace: linked, env: environment)
  assert git_identity.prepare(linked, Some(home), reading: absent) == Ok(None)
  git(linked, ["commit", "--allow-empty", "--quiet", "-m", "conditional"])
  assert git(linked, ["show", "-s", "--format=%an <%ae>"])
    == "Conditional <conditional@example.invalid>\n"
}

pub fn identity_values_cannot_inject_config_or_shell_source_test() {
  use wiring, home <- with_fixture()
  let name =
    "Quote \" and \\ path\n[core]\nhooksPath = injected\n$(touch injected)"

  // Fixture setup owns this synthetic operator home; preparation below does
  // not inherit that write grant.
  let host =
    worktree_diff.Wiring(
      ..wiring,
      base_policy: policy.SandboxPolicy(..wiring.base_policy, writable_roots: [
        wiring.workspace,
        home,
      ]),
      env: [#("PATH", "/usr/bin:/bin"), #("HOME", home)],
    )
  git(host, ["config", "--global", "user.name", name])
  git(host, ["config", "--global", "user.email", "literal@example.invalid"])
  assert git_identity.prepare(wiring, Some(home), reading: absent) == Ok(None)
  assert git(wiring, ["config", "--global", "--get", "user.name"])
    == name <> "\n"
  let missing =
    invoke(wiring, ["git", "config", "--global", "--get", "core.hooksPath"])
  let assert broker.CallExited(report) = missing.outcome as "the lookup settles"
  assert report.code == 1
  assert simplifile.is_file(wiring.workspace <> "/injected") == Ok(False)
}

pub fn planted_tool_home_symlink_cannot_write_outside_the_workspace_test() {
  use wiring, home <- with_fixture()
  let target = home <> "/gitconfig"
  write(target, "untouched\n")
  let tool_home = serve.tool_home_directory(wiring.workspace)
  let assert Ok(Nil) = simplifile.delete_all([tool_home])
    as "the empty tool home can be replaced"
  let linked = invoke(wiring, ["ln", "-s", home, tool_home])
  let assert broker.CallExited(report) = linked.outcome
    as "the fixture link settles"
  assert report.code == 0
  assert result.is_error(git_identity.prepare(
    wiring,
    Some(home),
    reading: absent,
  ))
  assert read(target) == "untouched\n"
}

fn absent(_name: String) -> Result(String, Nil) {
  Error(Nil)
}

fn with_fixture(run: fn(worktree_diff.Wiring, String) -> Nil) -> Nil {
  let assert Ok(here) = simplifile.current_directory()
    as "the package has a working directory"
  let root =
    here
    <> "/build/git-identity-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let workspace = root <> "/workspace"
  let home = root <> "/operator"
  list.each(
    [workspace <> "/.blobs", serve.tool_home_directory(workspace), home],
    fn(path) {
      let assert Ok(Nil) = simplifile.create_directory_all(path)
        as "the fixture directory exists"
    },
  )
  let #(environment, _) =
    serve.tool_environment(
      workspace,
      None,
      catalog.default_tools(),
      reading: absent,
    )
  let base =
    serve.base_policy(workspace)
    |> serve.allowing_tool_tmpdir
    |> serve.merging_mounts
  let wall = clock.from_function(bootstrap.system_time_ms)
  let assert Ok(#(pool, owner)) =
    serve.start_effect_plane(
      helper: here <> "/../sandbox/loom-exec",
      base_policy: base,
      tmp_dir: root <> "/helper",
      size: 3,
      clock: wall,
    )
    as "the production broker and helper pool start"
  run(
    worktree_diff.Wiring(
      workspace:,
      broker: owner,
      base_policy: base,
      clock: wall,
      // Identity assertions do not require delegated cgroups on a Linux test
      // host. The real helper still applies its filesystem jail; the symlink
      // regression below the publication boundary requires that denial.
      demand: exec.BestEffort,
      env: environment,
      entropy: ffi_os.unique_positive_integer,
    ),
    home,
  )
  broker.stop(owner)
  assert exec.close_pool(pool, waiting: 5000) == Ok(Nil)
  let assert Ok(Nil) = simplifile.delete_all([root])
    as "the retired fixture is removable"
  Nil
}

fn invoke(
  wiring: worktree_diff.Wiring,
  arguments: List(String),
) -> tool.Collected {
  let #(now, _) = clock.read(wiring.clock)
  let #(operation, _) =
    ids.mint_op(ids.generator(wiring.clock, wiring.entropy()))
  let events = process.new_subject()
  let assert Ok(call) =
    broker.clear_call(
      wiring.broker,
      broker.CallSpec(
        op_id: operation,
        step_id: "git-identity-fixture",
        base_policy: wiring.base_policy,
        requirements: wiring.base_policy,
        grants: [],
        response: broker.RefuseNarrowed,
        demand: wiring.demand,
        argv: arguments,
        env: wiring.env,
        cwd: wiring.workspace,
        budget: budget.Budget(1, now + 10_000),
      ),
      events:,
      waiting: 5000,
    )
    as "the fixture command is admitted"
  broker.stdin(wiring.broker, call, data: <<>>, eof: True)
  let assert Ok(collected) = tool.collect_events(events, waiting: 15_000)
    as "the fixture command settles"
  collected
}

fn git(wiring: worktree_diff.Wiring, arguments: List(String)) -> String {
  let collected = invoke(wiring, ["git", ..arguments])
  let assert broker.CallExited(report) = collected.outcome
    as "Git exits normally"
  assert report.code == 0 as text(collected.stderr)
  text(collected.stdout)
}

fn write(path: String, contents: String) -> Nil {
  let assert Ok(Nil) = simplifile.write(path, contents)
    as "the fixture owns this file"
  Nil
}

fn read(path: String) -> String {
  let assert Ok(text) = simplifile.read(path) as "the fixture file is readable"
  text
}

fn text(bytes: BitArray) -> String {
  let assert Ok(text) = bit_array.to_string(bytes) as "Git output is UTF-8"
  text
}
