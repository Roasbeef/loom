//// A session whose workspace *is* the daemon's state root, through the
//// daemon's own resolution path and then into a real jail.
////
//// The failure this file exists for was measured on the shipped daemon.
//// `resolve_managed` added the whole state root to `base_policy.protected`,
//// so an operator who opened a session on `~/.loom` — to edit `loom.toml`,
//// which is a reasonable thing to want Loom's help with — got a Seatbelt
//// profile denying reads over the jail's own working directory. Every
//// jailed `bash` printed `getcwd: cannot access parent directories:
//// Operation not permitted`, `ls` in the workspace printed nothing, and the
//// code-mode satellite could not open `.`. The tool results carried
//// `seatbelt-fs:rw=4,mask=11`.
////
//// So the fixture asks for both halves at once, because either alone is a
//// policy somebody could ship by accident. A jailed command in that
//// workspace must see the workspace — `pwd` prints it, and the operator's
//// `loom.toml` is readable. And the daemon's own secrets must stay gone:
//// `cat owner.token` in the same jail, by the same helper, in the same
//// session, must fail. A mask that protected nothing and a mask that
//// protected everything both pass one of those and neither passes both.
////
//// The verdict is measured rather than assumed. A host whose helper cannot
//// enforce a policy proves nothing about masking, so the jailed half
//// declines with the shipped fixtures' own probe and reason
//// (`support/enforcement`); the resolution half is pure and always runs.

import broker/exec
import broker/policy
import client/catalog
import client/daemon/main as entrypoint
import client/memory
import client/owned_assembly_test
import client/serve
import core/clock
import core/ids
import filepath
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
import host/bootstrap as native
import simplifile
import storage/catalogue
import storage/domain
import support/enforcement
import weft/poll

// --- resolution -------------------------------------------------------------

pub fn explicit_lockdown_flags_reach_managed_session_policy_test() {
  let root = fake_state_root("lockdown")
  let workspace = fixture_workspace("lockdown")
  let assert Ok(flags) =
    entrypoint.parse(["--read-scope", "workspace", "--network", "off"])
    as "the daemon accepts explicit restrictions"
  let settings = resolved_with(root, workspace, flags.session_defaults)
  assert settings.base_policy.readable_roots == [workspace]
  assert settings.base_policy.writable_roots == [workspace]
  assert serve.under_tools_config(settings.base_policy, settings.tools).network
    == policy.NetworkOff
  assert settings.tools.network == catalog.ToolNetworkOff
  assert list.contains(settings.base_policy.protected, root <> "/owner.token")

  // A session without overrides gets the developer defaults, while an
  // explicit flag takes precedence over the selected file in either direction.
  let ordinary = resolved(root, workspace: workspace)
  assert ordinary.base_policy.readable_roots == ["/"]
  assert serve.under_tools_config(ordinary.base_policy, ordinary.tools).network
    == policy.NetworkFull
  let assert Ok(Nil) =
    simplifile.write(
      root <> "/loom.toml",
      catalogue_document
        <> "\n[workspace]\nread_scope = \"workspace\"\n[tools]\nnetwork = \"off\"\n",
    )
    as "the operator can persist a restricted profile"
  let restricted = resolved(root, workspace: workspace)
  assert restricted.base_policy.readable_roots == [workspace]
  assert serve.under_tools_config(restricted.base_policy, restricted.tools).network
    == policy.NetworkOff
  let explicit =
    resolved_with(root, workspace, ["--read-scope", "host", "--network", "full"])
  assert explicit.base_policy.readable_roots == ["/"]
  assert serve.under_tools_config(explicit.base_policy, explicit.tools).network
    == policy.NetworkFull
}

pub fn the_daemon_masks_its_secrets_and_not_its_root_test() {
  let root = fake_state_root("resolution")
  let settings = resolved(root, workspace: root)
  let protected = settings.base_policy.protected

  // The bug, pinned: the root itself is not a mask, so nothing shadows
  // the workspace a session was opened on.
  assert !list.contains(protected, root)
    as "the state root is not masked wholesale"

  // The half that must survive the fix.
  list.each(["/owner.token", "/catalogue.db", "/sessions", "/tokens"], fn(leaf) {
    assert list.contains(protected, root <> leaf)
      as { "the daemon still masks " <> leaf }
  })

  // And the policy is one this server will boot on, which the whole-root
  // mask was not for this workspace.
  assert serve.base_policy_fault(settings.base_policy) == Ok(Nil)
}

pub fn a_session_on_a_masked_entry_is_refused_at_creation_test() {
  // The other side of the grain. `sessions/` holds every session's
  // database, so it stays masked — and a workspace *there* is refused
  // where the operator can act on it, rather than becoming a live
  // session whose every tool call fails on its own directory.
  let root = fake_state_root("refusal")
  let settings = resolved(root, workspace: root <> "/sessions")
  let assert Error(reason) = serve.base_policy_fault(settings.base_policy)
    as "a workspace on the sessions directory is refused"
  assert string.contains(reason, root <> "/sessions")
  assert string.contains(reason, "Choose another directory")
}

pub fn an_ordinary_workspace_still_masks_the_lazy_entries_test() {
  // The regression this test pins. The lazily created entries were once
  // masked only where a writable root reached them, and an ordinary
  // workspace outside the state root grants no such root — so a jail
  // that could read `/` at all read the launcher's bearer tokens, the
  // catalogue WAL and every other workspace's memory store. Existence is
  // the real condition, because a mask over a path that is there needs
  // nothing from its parent.
  let root = fake_state_root("outside")
  let workspace = fixture_workspace("outside")
  let settings = resolved(root, workspace: workspace)
  let protected = settings.base_policy.protected

  list.each(
    ["/tokens", "/locks", "/workspaces", "/domains", "/catalogue.db-wal"],
    fn(leaf) {
      assert list.contains(protected, root <> leaf)
        as { "an ordinary workspace still masks " <> leaf }
    },
  )

  // And the fix bought that back without reinstating the whole-root mask
  // the branch exists to remove.
  assert !list.contains(protected, root)
    as "the state root is still not masked wholesale"
  assert serve.base_policy_fault(settings.base_policy) == Ok(Nil)
}

// A workspace outside the state root: the ordinary arrangement, where no
// writable root reaches `~/.loom` and existence is the only thing that
// can make the lazy masks apply.
fn fixture_workspace(label: String) -> String {
  let path =
    "build/state-masks-workspace-"
    <> label
    <> "-"
    <> int.to_string(native.current_process_id())
    <> "-"
    <> int.to_string(native.system_time_ms())
  let assert Ok(Nil) = native.ensure_private_directory(path)
    as "the fixture owns its ordinary workspace"
  let assert Ok(path) = native.canonical_directory(path)
    as "every policy path is absolute"
  path
}

// --- the real jail ----------------------------------------------------------

pub fn a_jail_on_the_state_root_sees_the_workspace_and_not_the_secrets_test() {
  // The probe locates `loom-exec` beside the launcher it is given, so
  // the anchor is the built launcher rather than a server this fixture
  // never starts.
  let anchor = filepath.join(repository_root(), "bin/loom")
  case enforcement.probe(anchor, "daemon state-root masking") {
    enforcement.EnforcementAbsent -> Nil
    enforcement.EnforcementLive -> {
      let root = fake_state_root("jailed")
      let settings = resolved(root, workspace: root)
      jailed_readings(settings.base_policy, root)
    }
  }
}

// The two readings, taken from one helper so no difference between them
// can be a difference of host, policy composition or spawn.
fn jailed_readings(base: policy.SandboxPolicy, root: String) -> Nil {
  let helper_path =
    filepath.join(repository_root(), "bin/loom-exec")
    |> native.find_executable
  let assert Ok(helper_path) = helper_path
    as "the jailed reading needs the built loom-exec"
  let assert Ok(helper) =
    exec.spawn_helper(exec.SpawnConfig(
      helper_path: helper_path,
      shell_path: serve.shell_path,
      base_policy: base,
      helper_args: exec.unenforced_helper_args(exec.host_platform()),
      tmp_dir: root <> "/.tmp",
      handshake_timeout_ms: 5000,
      cancel_grace_ms: 3000,
      heartbeat_interval_ms: 0,
    ))
    as "the masking fixture's helper must start"

  // The workspace is the state root and the jail is standing in it. This
  // is the reading that failed before the fix, with `getcwd: cannot
  // access parent directories` on stderr and no path on stdout.
  let #(code, text) = jailed(helper, base, root, "pwd")
  assert code == 0 as "a jailed command in the state root workspace succeeds"
  assert string.contains(text, root)
    as "the jail's working directory is the workspace it was given"

  // The operator's reason for opening the session at all.
  let #(code, text) = jailed(helper, base, root, "cat loom.toml")
  assert code == 0 as "the operator's catalogue is readable from the jail"
  assert string.contains(text, "loom-1")
    as "the catalogue's own bytes come back"

  // And the daemon's credential is gone from that same jail. The mask
  // shadows reads as well as writes, so this is a failure, not empty
  // output that a later change could turn back into the token.
  let #(code, text) = jailed(helper, base, root, "cat owner.token")
  assert code != 0 as "the owner token is unreadable from the jail"
  assert !string.contains(text, credential)
    as "no byte of the credential reaches the jail"

  let retired = exec.close(helper, waiting: 5000)
  assert retired == Ok(Nil) as "the masking fixture retires its helper"
}

// One jailed shell command, as its exit code and its whole output. Both
// streams are folded together because the interesting failure — the
// `getcwd` refusal — arrives on stderr while the interesting success
// arrives on stdout.
fn jailed(
  helper: exec.Helper,
  base: policy.SandboxPolicy,
  cwd: String,
  command: String,
) -> #(Int, String) {
  let events = process.new_subject()
  let assert Ok(Nil) =
    exec.run(
      helper,
      exec.ExecRequest(
        argv: [serve.shell_path, "-c", command],
        env: [],
        cwd: cwd,
        policy: Some(base),
        token: <<0:size(32)-unit(8)>>,
        demand: exec.PlatformEnforcement,
      ),
      events: events,
      waiting: 5000,
    )
    as "the jailed reading dispatches"
  drain(events, "")
}

// Output is not completion: a launch path may report diagnostics before
// its verdict, so the fold runs to the terminal event under one deadline.
fn drain(
  events: process.Subject(exec.ExecEvent),
  collected: String,
) -> #(Int, String) {
  let outcome =
    poll.fold_until(
      clock: poll.monotonic(),
      within: 15_000,
      every: poll.Fixed(1),
      from: collected,
      attempt: fn(text) {
        case process.receive(events, 0) {
          Error(Nil) -> poll.Pending(text)
          Ok(exec.Output(data: data, ..)) ->
            poll.Pending(text <> chunk_text(data))
          Ok(exec.Exited(result)) -> poll.Settled(#(result.code, text))
          Ok(exec.Failed(reason)) ->
            poll.Settled(#(-1, text <> string.inspect(reason)))
        }
      },
    )
  case outcome {
    poll.Answer(answer) -> answer
    poll.RanOut(text) -> #(-1, text)
    poll.Failure(reason) -> #(-1, reason)
  }
}

fn chunk_text(data: BitArray) -> String {
  case bit_array.to_string(data) {
    Ok(text) -> text
    Error(Nil) -> ""
  }
}

// --- the fixture's state root ----------------------------------------------

// The credential the fixture plants, so the negative reading can assert
// on bytes rather than on an exit code alone.
const credential = "fixture-owner-credential"

// A state root with the layout the daemon writes: the entries the masks
// name, and the operator's catalogue beside them. The files hold fixture
// bytes; nothing here opens a real catalogue, because what is under test
// is which paths a policy names.
fn fake_state_root(label: String) -> String {
  let root =
    "build/state-masks-"
    <> label
    <> "-"
    <> int.to_string(native.current_process_id())
    <> "-"
    <> int.to_string(native.system_time_ms())
  let assert Ok(Nil) = native.ensure_private_directory(root)
    as "the fixture owns a private state root"
  let assert Ok(root) = native.canonical_directory(root)
    as "every policy path is absolute"

  list.each(
    ["sessions", "tokens", "locks", "workspaces", "domains", ".tmp"],
    fn(name) {
      let assert Ok(Nil) = native.ensure_private_directory(root <> "/" <> name)
        as "the fixture's state root has the daemon's directories"
    },
  )
  list.each(
    [
      #("owner.token", credential),
      #("catalogue.db", "fixture"),

      // The catalogue runs in WAL mode, so the recent rows a jail could
      // read live here as much as in the database itself.
      #("catalogue.db-wal", "fixture-wal"),
      #("daemon.lock", ""),
      #("loom.toml", catalogue_document),
    ],
    fn(entry) {
      let assert Ok(Nil) = simplifile.write(root <> "/" <> entry.0, entry.1)
        as "the fixture's state root has the daemon's files"
    },
  )
  root
}

// The operator's catalogue: the file the whole grain question is about,
// and the one the jailed reading proves is still theirs to edit.
const catalogue_document = "
[models.acme]
dialect = \"anthropic\"
api_key_env = \"UNUSED_TEST_KEY\"
model_id = \"loom-1\"
context_window = 1000
max_output_tokens = 100
[roles]
main = [\"acme\"]
"

// The daemon's own resolution, not a hand-built policy: the composition
// under test is the one `client/daemon/manager` performs when it admits a
// registration, and a fixture that assembled the policy itself would
// prove nothing about that path.
fn resolved(root: String, workspace workspace: String) -> serve.Settings {
  resolved_with(root, workspace, [])
}

fn resolved_with(
  root: String,
  workspace: String,
  overrides: List(String),
) -> serve.Settings {
  let fixture = owned_assembly_test.settings()
  let #(id, _) = ids.mint_session(ids.generator(clock.fixed(1), 909))
  let id = ids.session_id_to_string(id)
  let record =
    catalogue.Registration(
      id,
      root <> "/sessions/" <> id <> ".db",
      workspace,
      "State root",
      root <> "/loom.toml",
      1,
      "masking",
      catalogue.Saved,
    )
  let selected =
    domain.Domain(
      domain.key(domain.SessionOnly, workspace, id),
      domain.SessionOnly,
      workspace,
      "",
      root <> "/domains/sessions/" <> id <> "/" <> memory.memory_file,
      root <> "/domains/sessions/" <> id <> "/loom-search.db",
    )
  let assert Ok(settings) =
    serve.resolve_managed(
      ["--helper", fixture.helper_path, ..overrides],
      record,
      selected,
      root,
    )
    as "the daemon resolves a session on its own state root"
  settings
}

fn repository_root() -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner must have a working directory"
  let assert Ok(root) = native.canonical_directory(here <> "/../..")
    as "the checkout root is two levels above the package"
  root
}
