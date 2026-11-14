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
import client/workspace_policy
import core/clock
import core/ids
import filepath
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap as native
import simplifile
import storage/catalogue
import storage/domain
import support/enforcement
import telemetry/log
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
  assert workspace_policy.under_tools_config(
      settings.base_policy,
      settings.tools,
    ).network
    == policy.NetworkOff
  assert settings.tools.network == catalog.ToolNetworkOff
  assert list.contains(settings.base_policy.protected, root <> "/owner.token")

  // A session without overrides gets the developer defaults, while an
  // explicit flag takes precedence over the selected file in either direction.
  let ordinary = resolved(root, workspace: workspace)
  assert ordinary.base_policy.readable_roots == ["/"]
  assert workspace_policy.under_tools_config(
      ordinary.base_policy,
      ordinary.tools,
    ).network
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
  assert workspace_policy.under_tools_config(
      restricted.base_policy,
      restricted.tools,
    ).network
    == policy.NetworkOff
  let explicit =
    resolved_with(root, workspace, ["--read-scope", "host", "--network", "full"])
  assert explicit.base_policy.readable_roots == ["/"]
  assert workspace_policy.under_tools_config(
      explicit.base_policy,
      explicit.tools,
    ).network
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
  list.each(
    ["/owner.token", "/catalogue.db", "/sessions", "/tokens", "/browser.key"],
    fn(leaf) {
      assert list.contains(protected, root <> leaf)
        as { "the daemon still masks " <> leaf }
    },
  )

  // And the policy is one this server will boot on, which the whole-root
  // mask was not for this workspace.
  assert workspace_policy.base_policy_fault(settings.base_policy) == Ok(Nil)
}

pub fn a_session_on_a_masked_entry_is_refused_at_creation_test() {
  // The other side of the grain. `sessions/` holds every session's
  // database, so it stays masked — and a workspace *there* is refused
  // where the operator can act on it, rather than becoming a live
  // session whose every tool call fails on its own directory.
  let root = fake_state_root("refusal")
  let settings = resolved(root, workspace: root <> "/sessions")
  let assert Error(reason) =
    workspace_policy.base_policy_fault(settings.base_policy)
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
  assert workspace_policy.base_policy_fault(settings.base_policy) == Ok(Nil)
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
      shell_path: workspace_policy.shell_path,
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

  // A different session must not read captured repository bytes either.
  let #(code, text) =
    jailed(helper, base, root, "cat repository-snapshots/canary")
  assert code != 0 as "repository snapshots are unreadable from the jail"
  assert !string.contains(text, "snapshot-private-canary")
    as "snapshot bytes stay out of the jail"

  // Nor may a session's tool read a bundle in the state store: a state is the
  // whole history and working files of some workspace, sent here or captured
  // here, and the jail that runs a model's commands must not carry it away
  // (protocol-change/107, "Safety"). The sandboxed Git that applies one is the
  // only reader, through a grant the runner gives it and a session never gets.
  let #(code, text) = jailed(helper, base, root, "cat states/canary.bundle")
  assert code != 0 as "the state store is unreadable from the jail"
  assert !string.contains(text, "stored-bundle-private-canary")
    as "bundle bytes stay out of the jail"

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
        argv: [workspace_policy.shell_path, "-c", command],
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
    [
      "sessions",
      "tokens",
      "locks",
      "workspaces",
      "domains",
      "repository-snapshots",
      "states",
      ".tmp",
    ],
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
      #("repository-snapshots/canary", "snapshot-private-canary"),
      #("states/canary.bundle", "stored-bundle-private-canary"),
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
const catalogue_document =
  "
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
      profile: option.None,
      model: option.None,
      executor: "",
      pool: "",
      subtitle: option.None,
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

// --- the microVM home -------------------------------------------------------

pub fn the_vm_directories_are_named_from_home_and_state_root_test() {
  assert workspace_policy.vm_home_directories(Some("/home/o"), "/state")
    == workspace_policy.VmHomes(
      state: "/state/vm",
      home: Some("/home/o/.loom/vm"),
    )

  // A daemon with no `HOME` names only the state root's directory, and an
  // empty `HOME` is no home rather than a directory at the filesystem root.
  assert workspace_policy.vm_home_directories(None, "/state")
    == workspace_policy.VmHomes(state: "/state/vm", home: None)
  assert workspace_policy.vm_home_directories(Some(""), "/state")
    == workspace_policy.VmHomes(state: "/state/vm", home: None)
}

pub fn the_start_step_creates_missing_directories_and_spares_existing_ones_test() {
  let home = fixture_workspace("vm-create-home")
  let root = fixture_workspace("vm-create-root")

  // The home's directory already exists with a mode the owner chose.
  let existing = home <> "/.loom/vm"
  let assert Ok(Nil) = simplifile.create_directory_all(existing)
    as "the owner's directory exists"
  let assert Ok(Nil) = simplifile.set_permissions_octal(existing, 0o750)
    as "the owner's mode is not 0700"

  let assert Ok(directories) =
    entrypoint.ensure_vm_homes(Some(home), root, log.discard())
    as "the start step succeeds"
  let assert Ok(state_directory) = native.canonical_path(root <> "/vm")
    as "the state root's directory resolves"
  let assert Ok(home_directory) = native.canonical_path(existing)
    as "the home's directory resolves"
  assert directories == [state_directory, home_directory]
    as "both directories exist, so both are answered as canonical paths"
  let assert Ok(kept) = simplifile.file_info(existing)
    as "the existing directory is readable"
  assert int.bitwise_and(kept.mode, 0o777) == 0o750
    as "an existing directory is left exactly as it was"
  let assert Ok(made) = simplifile.file_info(root <> "/vm")
    as "the state root's directory was created"
  assert int.bitwise_and(made.mode, 0o777) == 0o700
    as "a created directory is private"
}

pub fn a_file_in_the_way_of_the_state_roots_directory_fails_the_start_test() {
  let root = fixture_workspace("vm-refuse-state")
  let assert Ok(Nil) = simplifile.write(root <> "/vm", "a file in the way")
    as "a file occupies the path"
  let assert Error(reason) =
    entrypoint.ensure_vm_homes(None, root, log.discard())
    as "a start failure, not a warning"
  assert string.contains(reason, root <> "/vm")
}

pub fn a_file_in_the_way_of_the_homes_directory_does_not_fail_the_start_test() {
  let home = fixture_workspace("vm-refuse-home")
  let root = fixture_workspace("vm-refuse-home-root")
  let assert Ok(Nil) = simplifile.write(home <> "/.loom", "a file in the way")
    as "a file occupies the home's .loom"
  let assert Ok(answered) =
    entrypoint.ensure_vm_homes(Some(home), root, log.discard())
    as "the start step succeeds"
  let assert Ok(state_directory) = native.canonical_path(root <> "/vm")
    as "the state root's directory resolves"
  assert answered == [state_directory]
    as "only the state root's directory is answered, since the home's is absent"
  assert simplifile.is_directory(home <> "/.loom/vm") != Ok(True)
    as "nothing was created for the home"
  assert simplifile.is_directory(root <> "/vm") == Ok(True)
    as "the state root's directory was still created"
}

// Whether the daemon's start step ran before the policy was built.
type StartStep {
  StartStepRan
  StartStepSkipped
}

pub fn a_jail_built_after_the_start_step_cannot_read_the_vm_home_test() {
  case vm_home_probe() {
    enforcement.EnforcementAbsent -> Nil
    enforcement.EnforcementLive -> {
      let #(code, text) = read_vm_secret(StartStepRan)
      assert code != 0 as "the secret is unreadable from the jail"
      assert !string.contains(text, vm_secret)
        as "no byte of the secret reaches the jail"
    }
  }
}

pub fn without_the_start_step_a_later_vm_home_is_readable_test() {
  // The control: the same policy, built while the directory is missing, does
  // not mask it, so the test above can tell the start step from its absence.
  case vm_home_probe() {
    enforcement.EnforcementAbsent -> Nil
    enforcement.EnforcementLive -> {
      let #(code, text) = read_vm_secret(StartStepSkipped)
      assert code == 0 as "an unmasked directory is readable"
      assert string.contains(text, vm_secret) as "the secret comes back"
    }
  }
}

const vm_secret = "fixture-vm-link-key"

fn vm_home_probe() -> enforcement.Enforcement {
  enforcement.probe(
    filepath.join(repository_root(), "bin/loom"),
    "microVM home masking",
  )
}

// Builds a policy the way a session does, in a temporary home and state root,
// then creates a secret under the home's `.loom/vm` and reads it from a jail.
fn read_vm_secret(start: StartStep) -> #(Int, String) {
  let home = fixture_workspace("vm-home")
  let root = fake_state_root("vm-probe")
  let workspace = fixture_workspace("vm-workspace")
  case start {
    StartStepRan -> {
      let assert Ok(_) =
        entrypoint.ensure_vm_homes(Some(home), root, log.discard())
        as "the start step runs"
      Nil
    }
    StartStepSkipped -> Nil
  }
  let base =
    workspace_policy.protecting_state_root_at(
      workspace_policy.base_policy(workspace),
      root,
      Some(home),
    )

  // `loom vm up` makes the directory and its files after the session began.
  let assert Ok(Nil) = simplifile.create_directory_all(home <> "/.loom/vm")
    as "the guest's directory appears"
  let secret = home <> "/.loom/vm/link.key"
  let assert Ok(Nil) = simplifile.write(secret, vm_secret)
    as "the key is written"

  let assert Ok(helper_path) =
    filepath.join(repository_root(), "bin/loom-exec")
    |> native.find_executable
    as "the jailed reading needs the built loom-exec"
  let assert Ok(helper) =
    exec.spawn_helper(exec.SpawnConfig(
      helper_path: helper_path,
      shell_path: workspace_policy.shell_path,
      base_policy: base,
      helper_args: exec.unenforced_helper_args(exec.host_platform()),
      tmp_dir: root <> "/.tmp",
      handshake_timeout_ms: 5000,
      cancel_grace_ms: 3000,
      heartbeat_interval_ms: 0,
    ))
    as "the helper starts"
  let reading = jailed(helper, base, workspace, "cat " <> secret)
  let assert Ok(Nil) = exec.close(helper, waiting: 5000) as "the helper retires"
  reading
}
