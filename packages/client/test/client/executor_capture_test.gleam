//// An executor captures its scope's workspace on request, through the real host
//// and the production plane (protocol-change/107, slice 3).
////
//// Slice 2 gave the host a `StateCapture` and left every plane answering
//// `NoStates`. This is the plane that does not: a worktree workspace served by
//// the production factory over a real repository, with a store behind it. The
//// session's tree gets an edit and a new file, the orchestrator's capture
//// request reaches the plane under the scope's token, and the state that comes
//// back is in the executor's store, whole, with the tree untouched.
////
//// Slice 4a adds the two other directions through the same host. A capture of
//// `CommittedOnly` returns the scope's commits and nothing its tree holds
//// uncommitted. A `StateApply` puts a state the store already holds into the
//// scope's tree: a state captured from a source repository, with a commit, an
//// edit and an untracked file, becomes the tree's checkout; and the refusals
//// (a shared workspace, a stale fence, a state the store lacks, a `.git` that
//// is a link, a hostile configuration) each leave the tree as it was.

import broker/exec
import client/catalog
import client/executor_plane
import client/git_identity
import client/internal/ffi_os
import client/jobs
import client/remote/address
import client/remote/host
import client/remote/owner_port
import client/remote/protocol
import client/remote/remote_census.{type RemoteCensus}
import client/remote/surface
import client/state_capture
import client/state_object.{
  type State, Clean, CommittedOnly, Dirty, Full, State, Thin, WithWorkingTree,
}
import client/state_service
import client/state_store
import client/workspaces
import client/worktree_git
import core/clock
import filepath
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import provider/secret
import simplifile
import storage/exec_ledger
import support/remote_fixtures as fixtures
import support/state_rig
import support/worktree_rig.{type Rig, git, session, write}
import telemetry/log

const token = <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>

type Plane {
  Plane(
    rig: Rig,
    host_pid: process.Pid,
    address: address.Address(protocol.HostMessage(RemoteCensus)),
    port: owner_port.Port,
    store: state_store.Store,
    /// The executor's own means of capturing, which a test uses to put a state
    /// made from a source repository into the store, as a transfer would.
    capturer: state_capture.Capturer,
  )
}

fn machine(rig: Rig) -> executor_plane.Machine {
  executor_plane.Machine(
    state_root: rig.state,
    helper_path: helper(),
    helper_pool_size: 4,
    demand: exec.BestEffort,
    workspace: catalog.default_workspace(),
    tools: catalog.default_tools(),
    deactivated_tools: [],
    lsp_servers: [],
    jobs_policy: jobs.default_policy,
    codemode_seed: Some(rig.state <> "/no-such-seed"),
    secrets: secret.env(),
    home: None,
    logger: log.discard(),
    mcp_servers: [],
    credentials: [],
  )
}

fn helper() -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner has a working directory"
  here <> "/../sandbox/loom-exec"
}

// The executor, with or without the means to capture.
type Capture {
  Able
  Unable
}

fn serve(name: String, capture: Capture) -> Plane {
  let rig = worktree_rig.rig(name)
  serve_over(rig, [rig.workspace], capture)
}

// The executor over a rig, serving the workspaces given. A rig's own workspace is
// in worktree mode; a test of the shared mode serves the same directory as one.
fn serve_over(
  rig: Rig,
  served: List(workspaces.Workspace),
  capture: Capture,
) -> Plane {
  let assert Ok(store) =
    state_store.open(
      state_store.directory(rig.state),
      state_store.default_limits,
    )
  let assert Ok(service) =
    state_service.start(store, fn() { ffi_os.system_time_ms() / 1000 })
  let endpoint = state_service.endpoint(service)
  let assert Ok(git) =
    worktree_git.start(worktree_git.Config(
      helper_path: helper(),
      scratch: rig.state <> "/state-git",
      state_root: rig.state,
      credentials: [],
      demand: exec.BestEffort,
    ))
    as "the sandboxed Git starts"
  let own = state_capture.new(git, rig.state, [], endpoint, store)
  let capturer = case capture {
    Able -> Some(own)
    Unable -> None
  }
  let assert Ok(started) =
    host.start(host.Config(
      name: process.new_name("executor_capture_host"),
      ledger_path: rig.ledger_path,
      limits: exec_ledger.default_limits(),
      max_result_bytes: host.default_max_result_bytes,
      execution_result_bytes: host.default_execution_result_bytes,
      states: endpoint,
      clock: clock.from_function(ffi_os.system_time_ms),
      factory: executor_plane.factory_capturing(
        machine(rig),
        served,
        rig.trees,
        capturer,
      ),
    ))
    as "the host starts"
  let assert Ok(port) =
    owner_port.start(owner_port.Config(
      services: fixtures.quiet_services(),
      clock: clock.fixed(at: 1000),
      settled: fn(_key) { False },
      reconcile_every_ms: 60_000,
      executions: owner_port.no_executions(),
      mcp: protocol.empty_mcp_plan(),
      git_identity: Some(git_identity.Identity(
        Some("Owner"),
        Some("owner@example.invalid"),
      )),
    ))
    as "the owner port starts"
  Plane(
    rig:,
    host_pid: started.pid,
    address: started.data,
    port:,
    store:,
    capturer: own,
  )
}

fn stop(plane: Plane) -> Nil {
  process.unlink(plane.host_pid)
  process.kill(plane.host_pid)
}

fn attached(plane: Plane) -> surface.Attachment(RemoteCensus) {
  let assert Ok(attachment) =
    surface.attach(
      surface.Config(
        address: plane.address,
        session: session(1),
        workspace: "repo",
        incarnation: 0,
        port: plane.port,
        read_authority: fn(_run) { Ok(fixtures.authority()) },
        reconnect: fn() { Ok(Nil) },
        remote_tools: ["fs_write", "fs_read", "bash"],
        attach_within_ms: 120_000,
        mint_token: fn() { token },
        attached: fn(_attached) { Nil },
      ),
    )
    as "the attach succeeds"
  attachment
}

fn tree_of(plane: Plane) -> String {
  plane.rig.state <> "/worktrees/repo/" <> session(1)
}

fn capture_request(plane: Plane) {
  request_capture(plane, Full, WithWorkingTree)
}

fn request_capture(
  plane: Plane,
  basis: state_object.Basis,
  content: state_object.Content,
) {
  let reply = process.new_subject()
  address.deliver(
    plane.address,
    protocol.StateCapture(
      session: session(1),
      incarnation: 0,
      token:,
      basis:,
      content:,
      reply:,
    ),
  )
  let assert Ok(answer) = process.receive(reply, 200_000)
    as "the host answers a capture"
  answer
}

fn request_apply(
  plane: Plane,
  incarnation: Int,
  token: BitArray,
  state: state_object.State,
) {
  let reply = process.new_subject()
  address.deliver(
    plane.address,
    protocol.StateApply(
      session: session(1),
      incarnation:,
      token:,
      state:,
      reply:,
    ),
  )
  let assert Ok(answer) = process.receive(reply, 200_000)
    as "the host answers an apply"
  answer
}

// A source repository: a clone of the executor's repository with a commit made,
// and then an edit and a new file left uncommitted. Its state is captured thin
// against the commit the executor holds, into the executor's store, which is where
// a transfer would have put it.
type Source {
  Source(directory: String, base: String, committed: String, state: State)
}

fn source_of(plane: Plane, name: String) -> Source {
  captured(plane, cloned(plane, name))
}

// The clone, with its commit and its uncommitted work, before it is captured.
// Its state is not yet in any store.
type Cloned {
  Cloned(directory: String, base: String, committed: String)
}

fn cloned(plane: Plane, name: String) -> Cloned {
  let scratch = filepath.directory_name(plane.rig.root)
  let directory = scratch <> "/" <> name
  let _ = git(scratch, ["clone", "--quiet", plane.rig.root, directory])
  let base = git(directory, ["rev-parse", "HEAD"])
  write(directory <> "/feature.txt", "committed in the source\n")
  let _ = git(directory, ["add", "feature.txt"])
  let _ = git(directory, ["commit", "--quiet", "-m", "feature"])
  let committed = git(directory, ["rev-parse", "HEAD"])
  write(directory <> "/README", "edited in the source\n")
  write(directory <> "/notes/untracked.txt", "carried along\n")
  Cloned(directory:, base:, committed:)
}

// Captures a clone into the executor's store, thin against the commit the
// executor holds.
fn captured(plane: Plane, source: Cloned) -> Source {
  let assert Ok(state) =
    state_capture.capture(
      plane.capturer,
      source.directory,
      state_rig.identity(),
      Thin(source.base),
    )
  assert state.dirty == Dirty
  Source(
    directory: source.directory,
    base: source.base,
    committed: source.committed,
    state:,
  )
}

fn refs_of(directory: String) -> String {
  git(directory, ["for-each-ref", "--format=%(refname) %(objectname)"])
}

pub fn an_executor_captures_its_scopes_tree_into_its_store_test() {
  let plane = serve("capture-able", Able)
  let _attachment = attached(plane)
  let tree = tree_of(plane)
  write(tree <> "/README", "edited on the executor\n")
  write(tree <> "/new.txt", "made on the executor\n")
  let assert Ok(readme) = simplifile.read(tree <> "/README")

  let assert Ok(Some(state)) = capture_request(plane)

  // The state is in the executor's store, whole, and the tree is as it was.
  assert state.dirty == Dirty
  let assert Ok(Some(held)) = state_store.get(plane.store, state.hash)
  assert held.state == state
  assert simplifile.read(tree <> "/README") == Ok(readme)
  stop(plane)
}

pub fn an_executor_with_no_capturer_answers_that_it_cannot_test() {
  let plane = serve("capture-unable", Unable)
  let _attachment = attached(plane)
  let assert Error(protocol.NoStates(_)) = capture_request(plane)
  let state = State(..a_state(), dirty: Clean)
  let assert Error(protocol.NoStates(_)) = request_apply(plane, 0, token, state)
  stop(plane)
}

fn a_state() -> State {
  State(
    hash: state_object.hash_of(<<"bundle">>),
    size: 6,
    tip: "0123456789abcdef0123456789abcdef01234567",
    base: None,
    dirty: Dirty,
  )
}

// --- committed-only capture -------------------------------------------------

pub fn a_committed_only_capture_returns_the_commits_and_not_the_edits_test() {
  let plane = serve("capture-committed", Able)
  let _attachment = attached(plane)
  let tree = tree_of(plane)
  let base = git(tree, ["rev-parse", "HEAD"])

  // The scope commits once and then leaves an edit, a staged file and a new file.
  write(tree <> "/child.txt", "made by the child\n")
  let _ = git(tree, ["add", "child.txt"])
  let _ = git(tree, ["commit", "--quiet", "-m", "child work"])
  let tip = git(tree, ["rev-parse", "HEAD"])
  write(tree <> "/README", "never committed\n")
  write(tree <> "/staged.txt", "staged\n")
  let _ = git(tree, ["add", "staged.txt"])
  write(tree <> "/untracked.txt", "untracked\n")
  let status = git(tree, ["status", "--porcelain"])

  let assert Ok(Some(state)) = request_capture(plane, Thin(base), CommittedOnly)

  // The tip is the child's commit itself: no snapshot commit of its edits.
  assert state.tip == tip
  assert state.base == Some(base)
  assert state.dirty == Clean
  let assert Ok(Some(held)) = state_store.get(plane.store, state.hash)
  assert held.state == state
  let assert Ok(bytes) = simplifile.read_bits(held.path)
  let assert Ok(header) = state_object.parse_header(bytes)
  assert header.prerequisites == [base]
  assert git(tree, ["status", "--porcelain"]) == status
  assert simplifile.read(tree <> "/README") == Ok("never committed\n")

  // The same tree captured with its working bytes is a different, dirty state.
  let assert Ok(Some(with_edits)) =
    request_capture(plane, Thin(base), WithWorkingTree)
  assert with_edits.dirty == Dirty
  assert with_edits.tip != tip
  stop(plane)
}

pub fn a_committed_only_capture_with_nothing_new_returns_no_state_test() {
  let plane = serve("capture-nothing", Able)
  let _attachment = attached(plane)
  let tree = tree_of(plane)
  let base = git(tree, ["rev-parse", "HEAD"])
  write(tree <> "/README", "never committed\n")

  assert request_capture(plane, Thin(base), CommittedOnly) == Ok(None)
  stop(plane)
}

pub fn a_committed_only_capture_of_a_tree_that_points_elsewhere_is_refused_test() {
  let plane = serve("capture-planted", Able)
  let _attachment = attached(plane)
  let tree = tree_of(plane)
  let base = git(tree, ["rev-parse", "HEAD"])

  // The session rewrites its tree's `.git` to name another repository on the
  // machine, which has a commit of its own to offer.
  let other =
    worktree_rig.repository(filepath.directory_name(plane.rig.root) <> "/other")
  write(other <> "/secret.txt", "not this scope's\n")
  let _ = git(other, ["add", "secret.txt"])
  let _ = git(other, ["commit", "--quiet", "-m", "secret"])
  write(tree <> "/.git", "gitdir: " <> other <> "/.git\n")

  let assert Error(protocol.ExecutorFault(reason)) =
    request_capture(plane, Thin(base), CommittedOnly)
  assert string.contains(reason, "linked worktree")
  stop(plane)
}

// --- apply ------------------------------------------------------------------

pub fn an_executor_puts_a_held_state_in_its_scopes_tree_test() {
  let plane = serve("apply-able", Able)
  let _attachment = attached(plane)
  let tree = tree_of(plane)
  let root = plane.rig.root
  let source = source_of(plane, "apply-source")
  let session = session(1)
  let root_head = git(root, ["rev-parse", "HEAD"])
  let root_refs = refs_of(root)

  let assert Ok(tip) = request_apply(plane, 0, token, source.state)

  // The tree's checkout is the bundle's tip, and the source's uncommitted work
  // arrived as committed content, the untracked file included.
  assert tip == source.state.tip
  assert git(tree, ["rev-parse", "HEAD"]) == source.state.tip
  assert git(tree, ["rev-parse", "--abbrev-ref", "HEAD"]) == "loom/" <> session
  assert git(tree, ["rev-parse", "HEAD^"]) == source.committed
  assert simplifile.read(tree <> "/README") == Ok("edited in the source\n")
  assert simplifile.read(tree <> "/feature.txt")
    == Ok("committed in the source\n")
  assert simplifile.read(tree <> "/notes/untracked.txt")
    == Ok("carried along\n")
  assert git(tree, ["status", "--porcelain"]) == ""

  // In the executor's repository the state is one incoming ref and the session's
  // branch has moved. The checked-out branch and the working files are as before.
  let incoming = state_object.incoming_ref(source.state.hash)
  assert git(root, ["rev-parse", incoming]) == source.state.tip
  assert git(root, ["rev-parse", "loom/" <> session]) == source.state.tip
  assert git(root, ["rev-parse", "HEAD"]) == root_head
  assert git(root, ["status", "--porcelain"]) == ""
  let added =
    list.filter(string.split(refs_of(root), "\n"), fn(line) {
      !list.contains(string.split(root_refs, "\n"), line)
    })
  assert list.sort(added, string.compare)
    == [
      "refs/heads/loom/" <> session <> " " <> source.state.tip,
      incoming <> " " <> source.state.tip,
    ]
  assert simplifile.read(root <> "/README") == Ok("one\n")
  stop(plane)
}

pub fn applying_a_state_twice_is_the_same_answer_and_changes_nothing_test() {
  let plane = serve("apply-twice", Able)
  let _attachment = attached(plane)
  let tree = tree_of(plane)
  let source = source_of(plane, "apply-twice-source")

  let first = request_apply(plane, 0, token, source.state)
  assert first == Ok(source.state.tip)
  let refs = refs_of(plane.rig.root)

  // The resend after a lost reply, and then the resend after the session has
  // begun to work in the tree, each find the tip there and change nothing.
  assert request_apply(plane, 0, token, source.state) == first
  assert refs_of(plane.rig.root) == refs
  write(tree <> "/child.txt", "the session's own work\n")
  let _ = git(tree, ["add", "child.txt"])
  let _ = git(tree, ["commit", "--quiet", "-m", "child"])
  let child = git(tree, ["rev-parse", "HEAD"])
  write(tree <> "/README", "edited by the session\n")
  assert request_apply(plane, 0, token, source.state) == first
  assert git(tree, ["rev-parse", "HEAD"]) == child
  assert simplifile.read(tree <> "/README") == Ok("edited by the session\n")
  stop(plane)
}

pub fn a_stale_fence_never_reaches_the_tree_test() {
  let plane = serve("apply-fence", Able)
  let _attachment = attached(plane)
  let tree = tree_of(plane)
  let source = source_of(plane, "apply-fence-source")
  let head = git(tree, ["rev-parse", "HEAD"])
  let refs = refs_of(plane.rig.root)

  assert request_apply(plane, 0, <<9, 9>>, source.state)
    == Error(protocol.StaleToken)
  let assert Error(protocol.StaleIncarnation(stored: 0)) =
    request_apply(plane, 7, token, source.state)
  assert git(tree, ["rev-parse", "HEAD"]) == head
  assert refs_of(plane.rig.root) == refs
  stop(plane)
}

pub fn a_state_the_store_lacks_is_refused_and_the_tree_is_left_alone_test() {
  let plane = serve("apply-missing", Able)
  let _attachment = attached(plane)
  let tree = tree_of(plane)
  let head = git(tree, ["rev-parse", "HEAD"])

  let assert Error(protocol.ExecutorFault(reason)) =
    request_apply(plane, 0, token, a_state())
  assert string.contains(reason, "does not hold that state")
  assert git(tree, ["rev-parse", "HEAD"]) == head
  stop(plane)
}

pub fn a_shared_workspace_takes_no_state_and_says_which_mode_test() {
  let rig = worktree_rig.rig("apply-shared")
  let shared = workspaces.shared("repo", rig.root)
  let plane = serve_over(rig, [shared], Able)
  let _attachment = attached(plane)
  let root = plane.rig.root
  let source = source_of(plane, "apply-shared-source")
  let head = git(root, ["rev-parse", "HEAD"])
  let refs = refs_of(root)

  let assert Error(protocol.ExecutorFault(reason)) =
    request_apply(plane, 0, token, source.state)
  assert string.contains(reason, "mode = \"shared\"")
  assert string.contains(reason, "mode = \"worktree\"")

  // Nothing moved in the shared checkout the sessions all work in.
  assert git(root, ["rev-parse", "HEAD"]) == head
  assert refs_of(root) == refs
  assert git(root, ["status", "--porcelain"]) == ""
  stop(plane)
}

pub fn a_tree_whose_dot_git_is_a_link_takes_no_state_test() {
  let plane = serve("apply-link", Able)
  let _attachment = attached(plane)
  let tree = tree_of(plane)
  let source = source_of(plane, "apply-link-source")
  let refs = refs_of(plane.rig.root)

  // The session swaps its tree's `.git` file for a link to the same file.
  let real = plane.rig.state <> "/real-dot-git"
  let assert Ok(Nil) = simplifile.rename(tree <> "/.git", real)
  let assert Ok(Nil) = simplifile.create_symlink(real, tree <> "/.git")

  let assert Error(protocol.ExecutorFault(reason)) =
    request_apply(plane, 0, token, source.state)
  assert string.contains(reason, "plain .git file")
  assert refs_of(plane.rig.root) == refs
  stop(plane)
}

pub fn hostile_configuration_on_either_side_cannot_change_an_apply_test() {
  let plane = serve("apply-hostile", Able)
  let _attachment = attached(plane)
  let tree = tree_of(plane)
  let root = plane.rig.root
  let canary = fn(name: String) { root <> "/.git/" <> name }

  // The source is cloned first, because the executor's configuration below
  // rewrites every path to a transport and would stop the operator's own clone.
  let clone = cloned(plane, "apply-hostile-source")

  // The executor's repository names a hook, a file-system monitor and a rewrite
  // of every path to a transport, each of which would write a canary into the one
  // place the apply's Git may write.
  let hooks = root <> "/.git/hooks"
  write(
    hooks <> "/post-checkout",
    "#!/bin/sh\nprintf ran > '" <> canary("hook-ran") <> "'\nexit 0\n",
  )
  let assert Ok(Nil) =
    simplifile.set_permissions_octal(hooks <> "/post-checkout", 0o755)
  let fsmonitor = root <> "/.git/fsmonitor-program"
  write(
    fsmonitor,
    "#!/bin/sh\nprintf ran > '" <> canary("fsmonitor-ran") <> "'\nexit 0\n",
  )
  let assert Ok(Nil) = simplifile.set_permissions_octal(fsmonitor, 0o755)
  let transport = root <> "/.git/evil-transport"
  write(
    transport,
    "#!/bin/sh\nprintf ran > '" <> canary("transport-ran") <> "'\nexit 1\n",
  )
  let assert Ok(Nil) = simplifile.set_permissions_octal(transport, 0o755)
  let _ = git(root, ["config", "core.hooksPath", hooks])
  let _ = git(root, ["config", "core.fsmonitor", fsmonitor])
  let _ = git(root, ["config", "protocol.ext.allow", "always"])
  let _ = git(root, ["config", "url.ext::" <> transport <> " .insteadOf", "/"])

  // The source repository names a file-system monitor, a hook path and a
  // transport rewrite too. Its program writes a canary beside the source, which
  // the sandboxed capture may not write and the operator's Git may.
  let source_canary = filepath.directory_name(root) <> "/source-canary"
  let program = filepath.directory_name(root) <> "/source-program"
  write(program, "#!/bin/sh\nprintf ran > '" <> source_canary <> "'\nexit 1\n")
  let assert Ok(Nil) = simplifile.set_permissions_octal(program, 0o755)
  let _ = git(clone.directory, ["config", "core.fsmonitor", program])
  let _ =
    git(clone.directory, [
      "config",
      "core.hooksPath",
      clone.directory <> "/.git",
    ])
  let _ = git(clone.directory, ["config", "protocol.ext.allow", "always"])
  let _ =
    git(clone.directory, [
      "config",
      "url.ext::" <> program <> " .insteadOf",
      "/",
    ])

  // Controls: ordinary Git run by the operator starts the executor's hook and
  // monitor, so a missing canary below is the apply's doing.
  let _ =
    git(tree, [
      "-c",
      "core.hooksPath=" <> hooks,
      "checkout",
      "--quiet",
      "-b",
      "control",
      "HEAD",
    ])
  assert simplifile.is_file(canary("hook-ran")) == Ok(True)
  let _ = git(tree, ["status", "--porcelain"])
  assert simplifile.is_file(canary("fsmonitor-ran")) == Ok(True)
  let _ = git(tree, ["checkout", "--quiet", "loom/" <> session(1)])
  list.each(["hook-ran", "fsmonitor-ran"], fn(name) {
    let _ = simplifile.delete(canary(name))
  })

  // The operator's own Git starts the source's monitor too. Then the sandbox
  // captures it, and the executor applies what it captured.
  let _ = git(clone.directory, ["status", "--porcelain"])
  assert simplifile.is_file(source_canary) == Ok(True)
  let assert Ok(Nil) = simplifile.delete(source_canary)
  let source = captured(plane, clone)
  let assert Ok(tip) = request_apply(plane, 0, token, source.state)
  assert tip == source.state.tip
  assert git(tree, ["rev-parse", "HEAD"]) == source.state.tip
  assert simplifile.is_file(canary("hook-ran")) == Ok(False)
  assert simplifile.is_file(canary("fsmonitor-ran")) == Ok(False)
  assert simplifile.is_file(canary("transport-ran")) == Ok(False)
  assert simplifile.is_file(source_canary) == Ok(False)
  stop(plane)
}

pub fn a_smudge_filter_in_the_executors_config_does_not_run_on_a_bundles_files_test() {
  let plane = serve("apply-smudge", Able)
  let _attachment = attached(plane)
  let tree = tree_of(plane)
  let root = plane.rig.root
  let scratch = filepath.directory_name(root)

  // A bundle a hostile peer made by hand: a commit whose tree attaches a
  // filter to every `.txt` file. Capture refuses such a tree, so it is built
  // with the operator's Git and put in the store as a transfer would.
  let clone = scratch <> "/smudge-source"
  let _ = git(scratch, ["clone", "--quiet", root, clone])
  let base = git(clone, ["rev-parse", "HEAD"])
  write(clone <> "/.gitattributes", "*.txt filter=evil\n")
  write(clone <> "/payload.txt", "payload\n")
  let _ = git(clone, ["add", ".gitattributes", "payload.txt"])
  let _ = git(clone, ["commit", "--quiet", "-m", "attach a filter"])
  let tip = git(clone, ["rev-parse", "HEAD"])
  let _ = git(clone, ["update-ref", state_object.bundle_ref, tip])
  let bundle = scratch <> "/smudge.bundle"
  let _ =
    git(clone, [
      "bundle",
      "create",
      bundle,
      state_object.bundle_ref,
      "^" <> base,
    ])
  let assert Ok(state) =
    state_store.put(
      plane.store,
      bundle,
      tip:,
      base: Some(base),
      dirty: Clean,
      now_s: ffi_os.system_time_ms() / 1000,
    )

  // The executor's repository names the program for the filter. It writes a
  // marker in the one place the apply's Git may write, and passes the bytes on.
  let marker = root <> "/.git/smudge-ran"
  let program = scratch <> "/smudge-program"
  write(program, "#!/bin/sh\nprintf ran > '" <> marker <> "'\nexec cat\n")
  let assert Ok(Nil) = simplifile.set_permissions_octal(program, 0o755)
  let _ = git(root, ["config", "filter.evil.smudge", program])

  // Control: the operator's Git checking the same file out in the clone, with
  // the same program, starts it.
  let _ = git(clone, ["config", "filter.evil.smudge", program])
  let assert Ok(Nil) = simplifile.delete(clone <> "/payload.txt")
  let _ = git(clone, ["checkout", "--", "payload.txt"])
  assert simplifile.is_file(marker) == Ok(True)
  let assert Ok(Nil) = simplifile.delete(marker)

  let assert Ok(applied) = request_apply(plane, 0, token, state)
  assert applied == tip
  assert git(tree, ["rev-parse", "HEAD"]) == tip
  assert simplifile.read(tree <> "/payload.txt") == Ok("payload\n")
  assert simplifile.is_file(marker) == Ok(False)
  stop(plane)
}

pub fn an_apply_whose_requester_vanishes_still_finishes_test() {
  let plane = serve("apply-orphaned", Able)
  let _attachment = attached(plane)
  let tree = tree_of(plane)
  let source = source_of(plane, "apply-orphaned-source")

  // The requester sends the request and exits at once, as an orchestrator that
  // lost its connection does. The run is not cancelled with it.
  let _requester =
    process.spawn_unlinked(fn() {
      let reply = process.new_subject()
      address.deliver(
        plane.address,
        protocol.StateApply(
          session: session(1),
          incarnation: 0,
          token:,
          state: source.state,
          reply:,
        ),
      )
    })
  wait_for_head(tree, source.state.tip, 600)

  // The checkout completed, so the tree is whole and the resend is answered
  // with the tip and not refused for changes.
  assert git(tree, ["status", "--porcelain"]) == ""
  assert simplifile.read(tree <> "/notes/untracked.txt")
    == Ok("carried along\n")
  assert request_apply(plane, 0, token, source.state) == Ok(source.state.tip)
  stop(plane)
}

// Waits until the tree's `HEAD` is `tip`, looking every 50 ms for at most
// `looks` times. The checkout moves `HEAD` after it has written the tree, so
// `HEAD` at the tip means the apply is finished.
fn wait_for_head(tree: String, tip: String, looks: Int) -> Nil {
  case git(tree, ["rev-parse", "HEAD"]) == tip, looks {
    True, _ -> Nil
    False, 0 -> panic as "the orphaned apply never finished"
    False, _ -> {
      process.sleep(50)
      wait_for_head(tree, tip, looks - 1)
    }
  }
}
