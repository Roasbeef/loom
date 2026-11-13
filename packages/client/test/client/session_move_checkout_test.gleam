//// A session whose workspace is a directory on the source moves to an executor
//// (protocol-change/107, slice 4c).
////
//// Two registries with their own catalogues and files stand for the two
//// orchestrators, joined by the real orchestrator port. The executor is the real
//// host over the production plane, a real repository in `worktree` mode and a
//// state store, and the source has a state store and a sandboxed Git of its
//// own, so the capture, the transfer and the apply that the move runs are the
//// ones a daemon runs. The source's session is local: its registration names a
//// directory, it has never attached to an executor, and its file holds no scope
//// cell.
////
//// ## What it proves
////
//// - A dirty directory with a tracked edit and an untracked file moves, and the
////   receiver's first attach finds both in the tree, as the snapshot commit.
//// - A move that cannot carry the checkout ends with the stage named, the session
////   resident and openable on the source, and the directory as it was.
//// - A move interrupted after each part of the checkout, and after the step, is
////   completed by the next run, and a state that was half sent resumes at the
////   offset the executor holds.
//// - After the move the source answers for the session with the tombstone and
////   runs nothing.

import broker/exec
import client/catalog
import client/daemon/domain as domain_service
import client/daemon/manager
import client/executor_plane
import client/executors
import client/internal/ffi_os
import client/jobs
import client/move_checkout
import client/orchestrators.{CheckoutTarget}
import client/remote/address.{type Address}
import client/remote/host
import client/remote/orchestrator_port
import client/remote/owner_port
import client/remote/protocol
import client/remote/remote_census.{type RemoteCensus}
import client/remote/scope
import client/remote/state_link
import client/remote/workspace
import client/roster
import client/session_directory
import client/session_importer
import client/session_move
import client/session_mover.{Aborted, Finished, Stalled}
import client/state_capture
import client/state_object
import client/state_service
import client/state_store
import client/state_transfer.{type Link, Link}
import client/workspaces
import client/worktree_git
import core/clock
import gleam/bit_array
import gleam/erlang/atom
import gleam/erlang/node
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/string
import host/bootstrap
import provider/secret
import session/session
import simplifile
import storage/access
import storage/catalogue
import storage/domain
import storage/exec_ledger
import support/remote_orchestrator as host_rig
import support/state_rig
import support/worktree_rig.{git, write}
import telemetry/field
import telemetry/level
import telemetry/log
import telemetry/record

const stage_ms = 2000

const op = "0192f3c1-7b0e-7d2a-9c11-4f5a6b7c8d9e"

// --- the executor ----------------------------------------------------------------

// The executor: a host over the production plane, with the store a transfer
// lands in and the means to apply what it holds. It is the shape of
// `executor_capture_test`'s plane, which proves the host side of the apply.
type Plane {
  Plane(
    rig: worktree_rig.Rig,
    host_pid: process.Pid,
    address: Address(protocol.HostMessage(RemoteCensus)),
    store: state_store.Store,
  )
}

fn helper() -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner has a working directory"
  here <> "/../sandbox/loom-exec"
}

fn machine(rig: worktree_rig.Rig) -> executor_plane.Machine {
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

// A node's state store, the one process that owns it, and the sandboxed Git that
// captures and applies through it.
fn state_node(
  state: String,
) -> #(state_store.Store, state_transfer.Endpoint, state_capture.Capturer) {
  let assert Ok(store) =
    state_store.open(state_store.directory(state), state_store.default_limits)
  let assert Ok(service) =
    state_service.start(store, fn() { ffi_os.system_time_ms() / 1000 })
  let endpoint = state_service.endpoint(service)
  let assert Ok(runner) =
    worktree_git.start(worktree_git.Config(
      helper_path: helper(),
      scratch: state <> "/state-git",
      state_root: state,
      credentials: [],
      demand: exec.BestEffort,
    ))
    as "the sandboxed Git starts"
  #(store, endpoint, state_capture.new(runner, state, [], endpoint, store))
}

fn serve(name: String, served: Served) -> Plane {
  let rig = worktree_rig.rig(name)
  let served_workspaces = case served {
    InWorktrees -> [rig.workspace]
    Shared -> [workspaces.shared("repo", rig.root)]
  }
  let #(store, endpoint, capturer) = state_node(rig.state)
  let assert Ok(started) =
    host.start(host.Config(
      name: process.new_name("move_checkout_host"),
      ledger_path: rig.ledger_path,
      limits: exec_ledger.default_limits(),
      max_result_bytes: host.default_max_result_bytes,
      execution_result_bytes: host.default_execution_result_bytes,
      states: endpoint,
      clock: clock.from_function(ffi_os.system_time_ms),
      factory: executor_plane.factory_capturing(
        machine(rig),
        served_workspaces,
        rig.trees,
        Some(capturer),
      ),
    ))
    as "the host starts"
  Plane(rig:, host_pid: started.pid, address: started.data, store:)
}

// How the executor serves the workspace: a linked worktree for each session, or
// one shared checkout.
type Served {
  InWorktrees
  Shared
}

fn tree_of(plane: Plane, session: String) -> String {
  plane.rig.state <> "/worktrees/repo/" <> session
}

// --- the orchestrators ---------------------------------------------------------------

type Daemon {
  Daemon(
    name: String,
    directory: String,
    store: catalogue.Catalogue,
    registry: manager.Manager(String),
    port: Address(orchestrator_port.Message),
    owner: access.Digest,
  )
}

fn node_name() -> String {
  atom.to_string(node.name(node.self()))
}

fn daemon(directory: String, name: String, peer: String) -> Daemon {
  let own = directory <> "/" <> name
  let assert Ok(Nil) = bootstrap.ensure_private_directory(own)
    as "the daemon's state root exists"
  let assert Ok(Nil) = simplifile.create_directory_all(own <> "/sessions")
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let assert Ok(owner) = access.credential_digest(string.repeat("a", 64))
  let assert Ok(_) = access.bootstrap_owner(store, "owner", "Owner", owner)
  let assert Ok(registry) =
    manager.start(
      store,
      manager.Assembly(
        domain_build: fn(_, _, _) { Ok(domain_service.inert()) },
        build: fn(record, _domain, _services, _owner, _directory) {
          Ok(record.id)
        },
        drain: fn(_, _) { Nil },
        fatal: fn(_) { [] },
      ),
      epoch: "move-test",
      limit: 2,
    )
    as "the registry starts"
  let context =
    session_importer.Context(
      ownership: None,
      registry:,
      state_root: own,
      sessions_directory: own <> "/sessions",
      domain_configuration: "",
      clock: clock.fixed(at: 5000),
      orchestrators: roster.fixed([orchestrators.plain(peer, node_name())]),
      executors: roster.fixed([
        executors.plain("box", "box@10.0.0.9"),
      ]),
      logger: log.discard(),
    )
  let port_name = process.new_name("move_checkout_port_" <> name)
  let held = fn(id) {
    case manager.get(registry, id) {
      Ok(_) ->
        case manager.custody(registry, id) {
          Ok(catalogue.Moved(to:, ..)) -> Ok(orchestrator_port.Moved(to:))
          _ -> Ok(orchestrator_port.Owned)
        }
      Error(manager.Catalogue(catalogue.Missing)) ->
        Ok(orchestrator_port.NotOwned)
      Error(_) -> Error(Nil)
    }
  }
  let assert Ok(_) =
    orchestrator_port.start_importing(
      port_name,
      held,
      session_importer.new(context),
    )
    as "the port starts"
  Daemon(
    name:,
    directory: own,
    store:,
    registry:,
    port: address.Address(node: node.self(), name: port_name),
    owner:,
  )
}

fn stop_daemon(daemon: Daemon) -> Nil {
  let watch = process.monitor(manager.pid(daemon.registry))
  manager.shutdown(daemon.registry)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(3000)
    as "the registry retires within the test deadline"
  let _closed = catalogue.close(daemon.store)
  Nil
}

// --- the rig ---------------------------------------------------------------------------

type Rig {
  Rig(
    directory: String,
    plane: Plane,
    // The source's own node: its store, and the means to capture into it.
    store: state_store.Store,
    capturer: state_capture.Capturer,
    // The directory the session works in, on the source.
    local: String,
    source: Daemon,
    target: Daemon,
    session: String,
  )
}

// What the source's directory holds when the move begins: the executor's
// repository plus a commit of its own, a tracked file edited and not committed,
// and a file git does not know.
const edited = "edited in the source\n"

const untracked = "carried along\n"

fn start(label: String, served: Served, padding: Int) -> Rig {
  let plane = serve(label, served)
  let assert Ok(here) = simplifile.current_directory()
    as "the working directory is known"
  let directory =
    here
    <> "/build/test_db/checkout-"
    <> label
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let _removed = simplifile.delete_all([directory])
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)

  // The source orchestrator's own state root, laid out as a daemon leaves it.
  let state = directory <> "/source-state"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(state)
  worktree_rig.establish(state)
  let #(store, _endpoint, capturer) = state_node(state)

  // The directory the session works in: a clone of the executor's repository
  // with a commit of its own and uncommitted work.
  let local = directory <> "/local"
  let _ = git(directory, ["clone", "--quiet", plane.rig.root, local])
  write(local <> "/feature.txt", "committed in the source\n")
  let _ = git(local, ["add", "feature.txt"])
  let _ = git(local, ["commit", "--quiet", "-m", "feature"])
  write(local <> "/README", edited)
  write(local <> "/notes/untracked.txt", untracked)
  write(local <> "/padding.bin", "")
  pad_directory(local, padding)
  let assert Ok(local) = bootstrap.canonical_directory(local)

  let source = daemon(directory, "alpha", "bravo")
  let target = daemon(directory, "bravo", "alpha")
  let session = worktree_rig.session(1)
  let path = source.directory <> "/sessions/" <> session <> ".db"
  let record =
    catalogue.Registration(
      id: session,
      path:,
      workspace: local,
      name: "the moving session",
      configuration: "",
      profile: None,
      model: None,
      executor: "",
      pool: "",
      created_at: 1_700_000_000_000,
      request_key: "key-" <> session,
      state: catalogue.Reserved,
      subtitle: None,
    )
  let selected = manager.session_only_domain(record, "", source.directory)
  let assert Ok(_) = domain.reserve_session(source.store, record, selected)
  let assert Ok(_) = catalogue.confirm(source.store, session)

  // The session ran locally: its file exists and holds no scope cell.
  let assert Ok(opened) =
    session.open_sqlite(
      path:,
      owner: "runtime",
      lease_ttl_ms: 30_000,
      clock: clock.fixed(at: 1000),
    )
    as "the source session opens"
  let assert Ok(Nil) = session.close(opened)
  Rig(directory:, plane:, store:, capturer:, local:, source:, target:, session:)
}

// Fills the directory with a file of bytes that do not compress, so that the
// bundle needs several pieces. The bytes come from a fixed generator, so every
// run sends the same ones.
fn pad_directory(local: String, bytes: Int) -> Nil {
  case bytes {
    0 -> Nil
    _ -> {
      let assert Ok(Nil) =
        simplifile.write_bits(local <> "/padding.bin", noise(bytes, 7))
        as "the padding is written"
      Nil
    }
  }
}

fn noise(bytes: Int, seed: Int) -> BitArray {
  noise_from(bytes / 8, seed, [])
  |> bit_array.concat
}

fn noise_from(words: Int, state: Int, made: List(BitArray)) -> List(BitArray) {
  case words {
    0 -> made
    _ -> {
      let next =
        { state * 6_364_136_223_846_793_005 + 1_442_695_040_888_963_407 }
        % 18_446_744_073_709_551_616
      noise_from(words - 1, next, [<<next:size(64)>>, ..made])
    }
  }
}

fn finish(rig: Rig) -> Nil {
  stop_daemon(rig.source)
  stop_daemon(rig.target)
  process.unlink(rig.plane.host_pid)
  process.kill(rig.plane.host_pid)
  let _removed = simplifile.delete_all([rig.directory])
  Nil
}

fn source_file(rig: Rig) -> String {
  rig.source.directory <> "/sessions/" <> rig.session <> ".db"
}

fn target_file(rig: Rig) -> String {
  rig.target.directory <> "/sessions/" <> rig.session <> ".db"
}

fn custody(daemon: Daemon, session: String) -> catalogue.Custody {
  let assert Ok(custody) = manager.custody(daemon.registry, session)
  custody
}

// --- the mover ---------------------------------------------------------------------------

// The ports of a source whose daemon can capture, link to the executor and land
// a state there. `after` is told after each part of the checkout, and `through`
// wraps the link a transfer runs over.
fn ports(
  rig: Rig,
  after: fn(move_checkout.Progress) -> Nil,
  through: fn(Link) -> Link,
) -> move_checkout.Ports {
  ports_logging(rig, after, through, log.discard())
}

// `ports`, with the executor's landing logging into `logger`.
fn ports_logging(
  rig: Rig,
  after: fn(move_checkout.Progress) -> Nil,
  through: fn(Link) -> Link,
  logger: log.Logger,
) -> move_checkout.Ports {
  let candidate =
    host_rig.candidate_over(
      "box",
      workspace.Reach(
        address: rig.plane.address,
        connect: fn() { Ok(Nil) },
        attach_within_ms: 120_000,
      ),
    )
  move_checkout.Ports(
    capture: fn(directory) {
      state_capture.capture(
        rig.capturer,
        directory,
        state_rig.identity(),
        state_object.Full,
      )
    },
    store: rig.store,
    link: fn(_executor) {
      Ok(through(state_link.via_host(rig.plane.address, 30_000)))
    },
    land: move_checkout.landing(
      fn(_executor) { host_rig.placement_of([candidate], fn(_) { Nil }) },
      logger,
    ),
    after:,
  )
}

fn direct(link: Link) -> Link {
  link
}

fn silently(_progress: move_checkout.Progress) -> Nil {
  Nil
}

// The orchestrator row the source lists for the receiver, with the place a
// checkout lands or without one.
fn receiver(place: option.Option(orchestrators.CheckoutTarget)) {
  orchestrators.Orchestrator(
    name: "bravo",
    node: node_name(),
    address: None,
    checkout: place,
  )
}

fn box_repo() {
  Some(CheckoutTarget(executor: "box", workspace: "repo"))
}

fn environment(
  rig: Rig,
  checkout: option.Option(move_checkout.Ports),
  place: option.Option(orchestrators.CheckoutTarget),
  after: fn(session_move.Step) -> Nil,
) -> session_mover.Environment(String) {
  session_mover.Environment(
    authority: session_mover.Rows,
    registry: rig.source.registry,
    orchestrators: roster.fixed([receiver(place)]),
    directory: session_directory.none()
      |> session_directory.activating(fn(_receiver, activation) {
        orchestrator_port.ask_activation(rig.target.port, activation, 20_000)
      }),
    courier: session_directory.Courier(
      send: fn(_receiver, chunk) {
        orchestrator_port.send_chunk(rig.target.port, chunk, 5000)
      },
      stage: fn(_receiver, session, op) {
        orchestrator_port.ask_stage(rig.target.port, session, op, stage_ms)
      },
    ),
    close: fn(_executor, session, named, incarnation) {
      workspace.close_stopped(
        workspace.Reach(
          address: rig.plane.address,
          connect: fn() { Ok(Nil) },
          attach_within_ms: 2000,
        ),
        session,
        named,
        incarnation,
      )
    },
    checkout:,
    clock: clock.fixed(at: 5000),
    node: node_name(),
    budget: session_mover.Budget(
      drain_ms: 5000,
      checkout_ms: 120_000,
      close_ms: 5000,
      cut_ms: 10_000,
      send_ms: 20_000,
      activate_ms: 30_000,
      quick_ms: 5000,
    ),
    after:,
    logger: log.discard(),
  )
}

fn plain(rig: Rig) -> session_mover.Environment(String) {
  environment(rig, Some(ports(rig, silently, direct)), box_repo(), fn(_) { Nil })
}

fn begin(rig: Rig) -> catalogue.Pending {
  let assert Ok(moving) =
    manager.begin_move_from(
      rig.source.registry,
      rig.source.owner,
      "move-test",
      rig.session,
      to: "bravo",
      op:,
      departure: manager.WithLocalCheckout,
    )
    as "the owner begins the move"
  assert moving == catalogue.Moving(op:, to: "bravo")
  catalogue.Pending(session: rig.session, op:, to: "bravo")
}

// --- what a finished move leaves ---------------------------------------------------------

fn assert_moved(rig: Rig) -> Nil {
  assert custody(rig.source, rig.session) == catalogue.Moved(op:, to: "bravo")
  assert custody(rig.target, rig.session)
    == catalogue.Imported(op:, from: "alpha")
  assert simplifile.is_file(source_file(rig)) == Ok(False)
  assert simplifile.is_file(source_file(rig) <> ".moved") == Ok(True)

  // The source answers for the session with the tombstone and runs nothing.
  assert manager.open(rig.source.registry, rig.session)
    == Error(manager.SessionMoved(to: "bravo"))

  // The receiver registered the session on the executor, in the workspace the
  // source's table named, not in the directory it came from.
  let assert Ok(view) = manager.get(rig.target.registry, rig.session)
  assert view.registration.executor == "box"
  assert view.registration.workspace == "repo"
  assert view.registration.state == catalogue.Saved
  Nil
}

// The directory the session came from is as it was: Loom does not write it.
fn assert_directory_untouched(rig: Rig) -> Nil {
  assert simplifile.read(rig.local <> "/README") == Ok(edited)
  assert simplifile.read(rig.local <> "/notes/untracked.txt") == Ok(untracked)
  let status = git(rig.local, ["status", "--porcelain"])
  assert string.contains(status, "README")
  assert string.contains(status, "notes/")
  Nil
}

// The receiver opens the session on the executor, as the daemon would, and the
// tree it finds there.
fn attach_on_receiver(rig: Rig) -> workspace.Hands {
  let assert Ok(opened) =
    session.open_sqlite(
      path: target_file(rig),
      owner: "runtime",
      lease_ttl_ms: 30_000,
      clock: clock.fixed(at: 6000),
    )
  let assert Ok(arrived) =
    workspace.attach(workspace.Registered(
      placement: host_rig.placement_of(
        [
          host_rig.candidate_over(
            "box",
            workspace.Reach(
              address: rig.plane.address,
              connect: fn() { Ok(Nil) },
              attach_within_ms: 120_000,
            ),
          ),
        ],
        fn(_) { Nil },
      ),
      session: rig.session,
      workspace: "repo",
      opened:,
      owner: host_rig.quiet(),
      clock: clock.fixed(at: 6000),
      reconcile_every_ms: 60_000,
      executions: owner_port.no_executions(),
      mcp: protocol.empty_mcp_plan(),
      git_identity: None,
      logger: log.discard(),
    ))
    as "the receiver attaches to the executor"
  let assert Ok(Nil) = session.close(opened)
  arrived
}

// --- the happy path ----------------------------------------------------------------------

pub fn a_dirty_directory_moves_to_an_executor_and_the_receiver_finds_it_there_test() {
  let rig = start("happy", InWorktrees, 0)
  let move = begin(rig)
  assert session_mover.drive(plain(rig), move) == Finished
  assert_moved(rig)
  assert_directory_untouched(rig)

  // The source's checkout step closed its scope at incarnation one, so the
  // receiver attaches at two and finds the branch the apply put the state on.
  let arrived = attach_on_receiver(rig)
  assert arrived.incarnation == 2
  let tree = tree_of(rig.plane, rig.session)
  assert simplifile.read(tree <> "/README") == Ok(edited)
  assert simplifile.read(tree <> "/notes/untracked.txt") == Ok(untracked)
  assert simplifile.read(tree <> "/feature.txt")
    == Ok("committed in the source\n")

  // The uncommitted work arrives as committed content: one snapshot commit on
  // top of the source's history, with nothing left over in the tree.
  assert git(tree, ["log", "-1", "--format=%s"]) == "Working snapshot"
  assert git(tree, ["status", "--porcelain"]) == ""
  assert git(tree, ["branch", "--show-current"]) == "loom/" <> rig.session
  finish(rig)
}

// Every record the logger's subject holds, in the order it was written.
fn drained(records: process.Subject(record.Record)) -> List(record.Record) {
  case process.receive(records, 0) {
    Ok(next) -> [next, ..drained(records)]
    Error(Nil) -> []
  }
}

// What the logs let an operator follow: one line for each stage of the
// checkout, naming the session, the operation, the state's short hash and its
// size and how long the stage took, and nothing of either machine's paths.
pub fn each_stage_of_the_checkout_logs_one_line_with_its_sizes_test() {
  let rig = start("stages", InWorktrees, 0)
  let move = begin(rig)
  let records = process.new_subject()
  let logger = log.new(sink: log.to_subject(records), threshold: level.Info)
  let environment =
    session_mover.Environment(
      ..environment(
        rig,
        Some(ports_logging(rig, silently, direct, logger)),
        box_repo(),
        fn(_) { Nil },
      ),
      logger:,
    )
  assert session_mover.drive(environment, move) == Finished

  let stages =
    drained(records)
    |> list.filter(fn(entry) {
      string.starts_with(entry.event, "daemon.move_checkout_")
    })
  assert list.map(stages, fn(entry) { entry.event })
    == [
      "daemon.move_checkout_captured",
      "daemon.move_checkout_sent",
      "daemon.move_checkout_applied",
      "daemon.move_checkout_closed",
    ]

  // Each line names the same session, operation and state, with a size and a
  // duration, and no value holds a path.
  list.each(stages, fn(entry) {
    let fields = entry.fields
    assert list.contains(fields, field.ident("session", rig.session))
    assert list.contains(fields, field.ident("op", op))
    let assert Ok(field.Field(value: field.Ident(hash), ..)) =
      list.find(fields, fn(found) { found.key == "state" })
    assert string.length(hash) == 8
    let assert Ok(field.Field(value: field.Count(bytes), ..)) =
      list.find(fields, fn(found) { found.key == "bytes" })
    assert bytes > 0
    let assert Ok(field.Field(value: field.Count(elapsed), ..)) =
      list.find(fields, fn(found) { found.key == "elapsed_ms" })
    assert elapsed >= 0
    assert !list.any(fields, fn(found) {
      case found.value {
        field.Text(text) | field.Ident(text) -> string.contains(text, "/")
        field.Count(_) | field.Flag(_) | field.Redacted -> False
      }
    })
  })
  finish(rig)
}

pub fn a_checkout_that_was_placed_leaves_a_clean_close_for_the_six_steps_test() {
  let rig = start("cell", InWorktrees, 0)
  let move = begin(rig)
  assert session_mover.drive(plain(rig), move) == Finished
  let assert Ok(cell) =
    scope.read_at(target_file(rig), "inspector", clock.fixed(at: 9000))
  assert cell == Some(scope.Scope(1, Some(protocol.AllRetired), Some("box")))
  finish(rig)
}

// --- refusals ----------------------------------------------------------------------------

// A move that ended in a refusal leaves the session where it was: resident, with
// its file, openable on the source as before, and its directory untouched.
fn assert_stays_on_source(rig: Rig) -> Nil {
  assert custody(rig.source, rig.session) == catalogue.Resident
  assert simplifile.is_file(source_file(rig)) == Ok(True)
  let assert Ok(_) = manager.open(rig.source.registry, rig.session)

  // The file opens for another reader, so no lease of the move is left on it.
  let assert Ok(_) =
    scope.read_at(source_file(rig), "inspector", clock.fixed(at: 9000))
  assert_directory_untouched(rig)
}

pub fn a_destination_with_no_place_for_the_checkout_leaves_the_session_here_test() {
  let rig = start("no-place", InWorktrees, 0)
  let move = begin(rig)
  let none =
    environment(rig, Some(ports(rig, silently, direct)), None, fn(_) { Nil })
  let assert Aborted(reason) = session_mover.drive(none, move)
  assert string.contains(reason, "checkout_executor")
  assert_stays_on_source(rig)
  finish(rig)
}

pub fn a_daemon_that_cannot_capture_does_not_move_a_local_session_test() {
  let rig = start("no-capture", InWorktrees, 0)
  let move = begin(rig)
  let unable = environment(rig, None, box_repo(), fn(_) { Nil })
  let assert Aborted(reason) = session_mover.drive(unable, move)
  assert string.contains(reason, "cannot capture")
  assert_stays_on_source(rig)
  finish(rig)
}

pub fn a_shared_workspace_on_the_executor_refuses_the_state_test() {
  let rig = start("shared", Shared, 0)
  let move = begin(rig)
  let assert Aborted(reason) = session_mover.drive(plain(rig), move)

  // The refusal names the stage and carries the executor's own words about the
  // two modes, and the scope it attached for the apply is closed again.
  assert string.contains(reason, "putting the checkout in the executor's tree")
  assert string.contains(reason, "worktree")
  assert_stays_on_source(rig)
  let assert Ok(Some(cell)) =
    scope.read_at(source_file(rig), "inspector", clock.fixed(at: 9000))
  assert cell.closed == Some(protocol.AllRetired)
  finish(rig)
}

pub fn a_scope_record_from_an_earlier_move_keeps_the_checkout_on_its_executor_test() {
  let rig = start("stale-record", Shared, 0)
  let move = begin(rig)
  let assert Aborted(_) = session_mover.drive(plain(rig), move)

  // The abandoned move left a record naming `box`. Asking again with a place on
  // another executor is refused, because the attach would follow the record and
  // put the checkout on `box` while the receiver was told `other`.
  let move = begin(rig)
  let elsewhere =
    environment(
      rig,
      Some(ports(rig, silently, direct)),
      Some(CheckoutTarget(executor: "other", workspace: "repo")),
      fn(_) { Nil },
    )
  let assert Aborted(reason) = session_mover.drive(elsewhere, move)
  assert string.contains(reason, "from an earlier move")
  assert_stays_on_source(rig)
  finish(rig)
}

pub fn a_directory_that_cannot_be_captured_ends_the_move_naming_the_stage_test() {
  let rig = start("uncapturable", InWorktrees, 0)
  let move = begin(rig)

  // A content filter is one the capture refuses rather than carry bytes it
  // might change.
  write(rig.local <> "/.gitattributes", "notes/untracked.txt filter=lfs\n")
  let assert Aborted(reason) = session_mover.drive(plain(rig), move)
  assert string.contains(reason, "capturing the workspace")
  assert_stays_on_source(rig)
  finish(rig)
}

// --- interruptions -----------------------------------------------------------------------

// Runs the mover in a process the test can lose: the `after` hook kills it the
// moment `lose_after` is reported, as a crash does, and nothing else of the run
// is left behind. The result is whether the run was cut short.
fn lost_after(rig: Rig, lose_after: session_move.Step) -> Bool {
  let move = catalogue.Pending(session: rig.session, op:, to: "bravo")
  let ended = process.new_subject()
  let environment =
    environment(rig, Some(ports(rig, silently, direct)), box_repo(), fn(step) {
      case step == lose_after {
        True -> process.kill(process.self())
        False -> Nil
      }
    })
  let pid =
    process.spawn_unlinked(fn() {
      let outcome = session_mover.drive(environment, move)
      process.send(ended, outcome)
    })
  let watch = process.monitor(pid)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(60_000)
    as "the run ends"
  process.receive(ended, 0) == Error(Nil)
}

pub fn a_source_lost_after_the_checkout_completes_the_move_when_it_returns_test() {
  let rig = start("lost-step", InWorktrees, 0)
  let _move = begin(rig)
  assert lost_after(rig, session_move.Checkout)
  let move = catalogue.Pending(session: rig.session, op:, to: "bravo")
  assert session_mover.drive(plain(rig), move) == Finished
  assert_moved(rig)
  let _arrived = attach_on_receiver(rig)
  let tree = tree_of(rig.plane, rig.session)
  assert simplifile.read(tree <> "/README") == Ok(edited)
  assert simplifile.read(tree <> "/notes/untracked.txt") == Ok(untracked)
  finish(rig)
}

// Loses the checkout's process the moment `progress` is reported, which is how a
// crash after that part is durable looks to the mover: the run ends as a stall.
// The next run then completes the move from what is on disk.
fn crash_inside_then_complete(
  label: String,
  progress: move_checkout.Progress,
) -> Nil {
  let rig = start(label, InWorktrees, 0)
  let move = begin(rig)
  let crashing =
    environment(
      rig,
      Some(ports(
        rig,
        fn(reported) {
          case reported == progress {
            True -> process.kill(process.self())
            False -> Nil
          }
        },
        direct,
      )),
      box_repo(),
      fn(_) { Nil },
    )
  let assert Stalled(reason) = session_mover.drive(crashing, move)
  assert string.contains(reason, "the checkout")
  assert custody(rig.source, rig.session) == catalogue.Moving(op:, to: "bravo")
  assert session_mover.drive(plain(rig), move) == Finished
  assert_moved(rig)
  let _arrived = attach_on_receiver(rig)
  let tree = tree_of(rig.plane, rig.session)
  assert simplifile.read(tree <> "/README") == Ok(edited)
  assert simplifile.read(tree <> "/notes/untracked.txt") == Ok(untracked)
  finish(rig)
}

pub fn a_run_lost_after_the_capture_completes_the_move_test() {
  crash_inside_then_complete("lost-captured", move_checkout.Captured)
}

pub fn a_run_lost_after_the_send_completes_the_move_test() {
  crash_inside_then_complete("lost-sent", move_checkout.Sent)
}

pub fn a_run_lost_after_the_checkout_was_placed_completes_the_move_test() {
  crash_inside_then_complete("lost-placed", move_checkout.Placed)
}

pub fn a_run_lost_between_the_apply_and_its_record_applies_again_harmlessly_test() {
  let rig = start("lost-record", InWorktrees, 0)
  let move = begin(rig)

  // The landing runs to its end, scope closed, and the process is lost before the
  // step records that it was done. The next run lands again: the tree already has
  // the tip, which the executor answers without changing anything.
  let real = ports(rig, silently, direct)
  let landed_once = times(1)
  let crashing =
    move_checkout.Ports(..real, land: fn(arrival) {
      let landed = real.land(arrival)
      case landed_once() {
        True -> process.kill(process.self())
        False -> Nil
      }
      landed
    })
  let assert Stalled(_) =
    session_mover.drive(
      environment(rig, Some(crashing), box_repo(), fn(_) { Nil }),
      move,
    )
  assert session_mover.drive(plain(rig), move) == Finished
  assert_moved(rig)

  // Two landings closed two scopes, so the receiver attaches at three.
  let arrived = attach_on_receiver(rig)
  assert arrived.incarnation == 3
  let tree = tree_of(rig.plane, rig.session)
  assert simplifile.read(tree <> "/README") == Ok(edited)
  finish(rig)
}

// --- a transfer that is cut short ------------------------------------------------------------

// A count kept in a process of its own, because the mover asks from processes the
// test cannot read a subject of.
type Tally {
  Add
  Total(reply: process.Subject(Int))
}

fn tally() -> process.Subject(Tally) {
  let assert Ok(started) =
    actor.new(0)
    |> actor.on_message(fn(count, message) {
      case message {
        Add -> actor.continue(count + 1)
        Total(reply:) -> {
          process.send(reply, count)
          actor.continue(count)
        }
      }
    })
    |> actor.start
    as "the tally starts"
  started.data
}

type Quota {
  Take(reply: process.Subject(Bool))
}

fn times(count: Int) -> fn() -> Bool {
  let assert Ok(started) =
    actor.new(count)
    |> actor.on_message(fn(left, message) {
      let Take(reply:) = message
      case left > 0 {
        True -> {
          process.send(reply, True)
          actor.continue(left - 1)
        }
        False -> {
          process.send(reply, False)
          actor.continue(left)
        }
      }
    })
    |> actor.start
    as "the quota starts"
  fn() { process.call(started.data, 1000, Take) }
}

pub fn a_state_cut_short_by_a_dropped_link_resumes_at_the_executors_offset_test() {
  // Bytes that do not compress, so the bundle is several pieces.
  let rig = start("drop", InWorktrees, 900_000)
  let move = begin(rig)

  // The link carries one piece and then goes silent, as a connection that broke.
  let allowed = times(1)
  let broken = fn(link: Link) {
    Link(..link, piece: fn(piece) {
      case allowed() {
        True -> link.piece(piece)
        False -> Error(Nil)
      }
    })
  }
  let cut_short =
    environment(rig, Some(ports(rig, silently, broken)), box_repo(), fn(_) {
      Nil
    })
  let assert Stalled(reason) = session_mover.drive(cut_short, move)
  assert string.contains(reason, "sending the state to the executor")
  assert custody(rig.source, rig.session) == catalogue.Moving(op:, to: "bravo")

  // The next run sends from the executor's offset: it asks how far the state
  // got, and the pieces it sends are the rest and not the whole.
  let counted = tally()
  let counting = fn(link: Link) {
    Link(..link, piece: fn(piece) {
      process.send(counted, Add)
      link.piece(piece)
    })
  }
  let resumed =
    environment(rig, Some(ports(rig, silently, counting)), box_repo(), fn(_) {
      Nil
    })
  assert session_mover.drive(resumed, move) == Finished
  assert_moved(rig)
  let sent_again = process.call(counted, 1000, Total)

  // The bundle the executor holds is one file; the pieces it takes are chunks of
  // it, one of which it already had.
  let assert Ok(names) =
    simplifile.read_directory(rig.plane.rig.state <> "/states")
  let assert [bundle] =
    list.filter(names, fn(name) { string.ends_with(name, ".bundle") })
  let assert Ok(info) =
    simplifile.file_info(rig.plane.rig.state <> "/states/" <> bundle)
  let pieces =
    { info.size + state_transfer.chunk_bytes - 1 } / state_transfer.chunk_bytes
  assert pieces >= 3
  assert sent_again == pieces - 1

  let _arrived = attach_on_receiver(rig)
  let tree = tree_of(rig.plane, rig.session)
  assert simplifile.read(tree <> "/README") == Ok(edited)
  finish(rig)
}
