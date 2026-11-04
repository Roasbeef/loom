//// The operator's identity is read through the sandboxed Git runner and reaches
//// an executor's tools (protocol-change/107, loom #1061). The runner, the helper
//// and Git are real, and each test has a home directory of its own, so a passing
//// read cannot borrow the developer's or the CI runner's configuration. The last
//// test follows one identity from a global gitconfig through the holder, the
//// owner port, a host's attach spec and the workspace plane's tool environment.

import broker/exec
import client/executor_plane
import client/git_identity.{Identity}
import client/internal/ffi_os
import client/owned_assembly_test
import client/owner_identity
import client/remote/address
import client/remote/host
import client/remote/owner_port
import client/remote/protocol.{GitIdentity}
import client/serve
import client/workspace_plane
import client/worktree_git
import core/clock
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import simplifile
import support/remote_fixtures as fixtures

type Rig {
  Rig(git: worktree_git.Git, home: String, scratch: String)
}

// A runner over the shipped helper, and a home directory that is empty.
fn rig(name: String) -> Rig {
  let directory =
    "build/owner-identity-"
    <> name
    <> "-"
    <> string.inspect(ffi_os.unique_positive_integer())
  let _removed = simplifile.delete(directory)
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
  let assert Ok(scratch) = bootstrap.canonical_directory(directory)
  let state = scratch <> "/state"
  let home = scratch <> "/home"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(state)
  let assert Ok(Nil) = bootstrap.ensure_private_directory(home)
  let assert Ok(here) = simplifile.current_directory()
  let assert Ok(git) =
    worktree_git.start(
      worktree_git.Config(
        helper_path: here <> "/../sandbox/loom-exec",
        scratch: state <> "/git",
        state_root: state,
        demand: exec.BestEffort,
        credentials: [],
      ),
    )
    as "the sandboxed Git starts"
  Rig(git:, home:, scratch:)
}

fn write(path: String, text: String) -> Nil {
  let assert Ok(Nil) = simplifile.write(path, text)
  Nil
}

fn absent(_name: String) -> Result(String, Nil) {
  Error(Nil)
}

const configured =
  "[user]\n\tname = Ada Lovelace\n\temail = ada@example.invalid\n"

// --- the read -------------------------------------------------------------------

pub fn a_global_identity_is_read_through_the_sandbox_test() {
  let rig = rig("read")
  write(rig.home <> "/.gitconfig", configured)

  assert owner_identity.resolve(rig.git, rig.home, absent, 20_000)
    == Ok(Identity(Some("Ada Lovelace"), Some("ada@example.invalid")))
}

pub fn the_last_value_and_an_include_win_as_they_do_for_a_session_test() {
  let rig = rig("include")
  write(
    rig.home <> "/.gitconfig",
    "[user]\n\tname = First\n[include]\n\tpath = identity\n",
  )
  write(
    rig.home <> "/identity",
    "[user]\n\tname = Included\n\temail = included@example.invalid\n",
  )

  assert owner_identity.resolve(rig.git, rig.home, absent, 20_000)
    == Ok(Identity(Some("Included"), Some("included@example.invalid")))
}

pub fn no_global_identity_is_none_end_to_end_test() {
  let rig = rig("none")
  write(rig.home <> "/.gitconfig", "[core]\n\tautocrlf = false\n")

  assert owner_identity.resolve(rig.git, rig.home, absent, 20_000)
    == Ok(Identity(None, None))
  assert owner_port.answered_identity(Some(Identity(None, None))) == None

  let name = process.new_name("owner_identity_none")
  let assert Ok(Nil) = owner_identity.start(name, rig.git, rig.home, absent)
  assert owner_identity.lookup(name, 20_000) == Some(Identity(None, None))
}

pub fn a_home_with_no_gitconfig_at_all_is_none_test() {
  let rig = rig("nofile")

  assert owner_identity.resolve(rig.git, rig.home, absent, 20_000)
    == Ok(Identity(None, None))
}

// --- what a hostile configuration can do ------------------------------------------

pub fn a_hostile_configuration_runs_no_program_test() {
  let rig = rig("hostile")
  let canary = rig.scratch <> "/canary"
  let program = "!touch " <> canary
  write(
    rig.home <> "/.gitconfig",
    string.join(
      [
        configured,
        "[core]",
        "\tpager = touch " <> canary,
        "\tfsmonitor = touch " <> canary,
        "\tsshCommand = touch " <> canary,
        "\teditor = touch " <> canary,
        "[credential]",
        "\thelper = " <> program,
        "[alias]",
        "\tconfig = " <> program,
        "[include]",
        "\tpath = /nonexistent/included",
        "[includeIf \"gitdir:/\"]",
        "\tpath = hostile",
        "",
      ],
      "\n",
    ),
  )
  write(
    rig.home <> "/hostile",
    "[core]\n\tfsmonitor = touch " <> canary <> "\n",
  )

  // The daemon's environment names a count of config pairs, a parameter string
  // and a pager. None of them is one of the two names a query takes.
  let hostile = fn(name) {
    case name {
      "GIT_CONFIG_COUNT" -> Ok("1")
      "GIT_CONFIG_KEY_0" -> Ok("user.name")
      "GIT_CONFIG_VALUE_0" -> Ok("Evil")
      "GIT_CONFIG_PARAMETERS" -> Ok("'user.name=Evil'")
      "GIT_PAGER" -> Ok("touch " <> canary)
      "GIT_SSH_COMMAND" -> Ok("touch " <> canary)
      _ -> Error(Nil)
    }
  }

  // The identity is the real assertion. The canary is a weak secondary check,
  // because the sandbox grants no write and a program could not make it anyway.
  assert owner_identity.resolve(rig.git, rig.home, hostile, 20_000)
    == Ok(Identity(Some("Ada Lovelace"), Some("ada@example.invalid")))
  assert simplifile.is_file(canary) == Ok(False)
}

pub fn the_operators_own_config_global_is_honoured_and_runs_nothing_test() {
  let rig = rig("moved")
  let canary = rig.scratch <> "/canary"
  write(rig.home <> "/.gitconfig", "[user]\n\tname = Ignored\n")
  write(
    rig.scratch <> "/moved",
    "[user]\n\tname = Moved\n\temail = moved@example.invalid\n[core]\n\tpager = touch "
      <> canary
      <> "\n",
  )
  let reading = fn(name) {
    case name {
      "GIT_CONFIG_GLOBAL" -> Ok(rig.scratch <> "/moved")
      _ -> Error(Nil)
    }
  }

  assert owner_identity.resolve(rig.git, rig.home, reading, 20_000)
    == Ok(Identity(Some("Moved"), Some("moved@example.invalid")))
  assert simplifile.is_file(canary) == Ok(False)
}

pub fn an_empty_or_control_character_value_is_not_sent_test() {
  let rig = rig("control")

  // A tab is a control character, and an empty value is empty after trimming.
  write(
    rig.home <> "/.gitconfig",
    "[user]\n\tname = \"Ada\\tLovelace\"\n\temail = a@b.invalid\n",
  )
  let assert Ok(tabbed) =
    owner_identity.resolve(rig.git, rig.home, absent, 20_000)
  assert tabbed == Identity(Some("Ada\tLovelace"), Some("a@b.invalid"))
  assert owner_port.answered_identity(Some(tabbed)) == None

  write(rig.home <> "/.gitconfig", "[user]\n\tname = \n\temail = a@b.invalid\n")
  let assert Ok(blank) =
    owner_identity.resolve(rig.git, rig.home, absent, 20_000)
  assert owner_port.answered_identity(Some(blank)) == None

  write(rig.home <> "/.gitconfig", "[user]\n\tname = Ada\n")
  let assert Ok(half) =
    owner_identity.resolve(rig.git, rig.home, absent, 20_000)
  assert owner_port.answered_identity(Some(half)) == None
}

// --- the holder -----------------------------------------------------------------

pub fn a_name_nothing_holds_answers_none_at_once_test() {
  assert owner_identity.lookup(
      process.new_name("owner_identity_nobody"),
      10_000,
    )
    == None
}

pub fn the_holder_keeps_its_answer_between_sessions_test() {
  let rig = rig("keep")
  write(rig.home <> "/.gitconfig", configured)
  let name = process.new_name("owner_identity_keep")
  let assert Ok(Nil) = owner_identity.start(name, rig.git, rig.home, absent)
  let expected =
    Some(Identity(Some("Ada Lovelace"), Some("ada@example.invalid")))
  assert owner_identity.lookup(name, 20_000) == expected

  // The file changes, and the next session still hears what was read, because a
  // read is kept for a minute and the sandbox is not asked again.
  write(
    rig.home <> "/.gitconfig",
    "[user]\n\tname = Changed\n\temail = c@d.invalid\n",
  )
  assert owner_identity.lookup(name, 20_000) == expected
}

pub fn a_read_that_fails_is_none_and_does_not_stall_test() {
  let rig = rig("failing")
  let name = process.new_name("owner_identity_failing")

  // A runner that has been stopped cannot clear a call. The lookup is none and
  // returns well inside its wait.
  let assert Ok(Nil) = worktree_git.stop(rig.git)
  let assert Ok(Nil) = owner_identity.start(name, rig.git, rig.home, absent)
  assert owner_identity.lookup(name, 20_000) == None
}

// --- end to end -----------------------------------------------------------------

pub fn a_global_identity_reaches_the_executors_tool_environment_test() {
  let rig = rig("chain")
  write(rig.home <> "/.gitconfig", configured)
  let name = process.new_name("owner_identity_chain")
  let assert Ok(Nil) = owner_identity.start(name, rig.git, rig.home, absent)

  // The owner side: what `serve` puts in the session's registration, answered
  // by the owner port when the executor's host asks.
  let assert Ok(port) =
    owner_port.start(owner_port.Config(
      services: fixtures.quiet_services(),
      clock: clock.fixed(at: 5000),
      settled: fn(_key) { False },
      reconcile_every_ms: 60_000,
      executions: owner_port.no_executions(),
      mcp: protocol.McpPlan(served: [], expected: []),
      git_identity: owner_identity.lookup(name, 20_000),
    ))
  let inbox = owner_port.inbox(port)

  // The executor side: a host builds a plane, and its factory sees the spec.
  let heard = process.new_subject()
  let probe = fixtures.probe(fixtures.Open)
  let base = fixtures.factory(probe, fixtures.AsksNothing, protocol.AllRetired)
  let factory = fn(spec: host.AttachSpec) {
    process.send(heard, spec)
    base(spec)
  }
  let path = fixtures.scratch("owner-identity-host") <> "/ledger.db"
  let assert Ok(started) = host.start(fixtures.host_config(path, factory))
  let reply = process.new_subject()
  address.deliver(
    started.data,
    protocol.Attach(
      version: protocol.version,
      session: "s1",
      workspace: "/work",
      incarnation: 0,
      token: <<1>>,
      owner_port: inbox,
      reply:,
    ),
  )
  let assert Ok(Ok(_attached)) = process.receive(reply, 10_000)
  let assert Ok(spec) = process.receive(heard, 2000)
  assert spec.git_identity
    == Some(GitIdentity("Ada Lovelace", "ada@example.invalid"))

  // The plane: the workspace is prepared with the author the spec carried, and
  // every tool's environment pins it.
  let settings = owned_assembly_test.settings()
  let assert Ok(blob_root) = serve.session_blob_root(settings)
  let planned = serve.workspace_spec(settings, None, blob_root)
  let assert Ok(prepared) =
    workspace_plane.prepare(
      workspace_plane.WorkspaceSpec(
        ..planned,
        author: executor_plane.author_of(spec),
      ),
      reading: fn(_name) { Error(Nil) },
    )
  let env = prepared.census.env
  assert list.key_find(env, "GIT_AUTHOR_NAME") == Ok("Ada Lovelace")
  assert list.key_find(env, "GIT_COMMITTER_EMAIL") == Ok("ada@example.invalid")
}
