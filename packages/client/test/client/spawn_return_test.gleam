//// A finished seeded child's commits go back to the parent's store, over real
//// ports, a real store on each side and a real repository (protocol-change/107,
//// slice 3b).
////
//// The parent's machine is an orchestrator port with a store and a repository;
//// the receiving machine is a second port whose spawn host is the daemon's own
//// (`main.spawn_host_seeding`) with `spawn_return.over` in the path of every join.
//// A spawn that sends the parent's workspace starts a child whose copy the test
//// then edits the way the child would: it commits twice and leaves one edit
//// uncommitted. The join that follows is what the tests look at, and then what the
//// parent's store and repository hold.

import broker/exec
import client/agency
import client/daemon/main
import client/delegate_host
import client/internal/ffi_os
import client/remote/address.{Address}
import client/remote/orchestrator_port
import client/remote/remote_spawner
import client/remote/state_link
import client/remote_child
import client/remote_spawn
import client/return_apply
import client/session_states
import client/spawn_return
import client/spawn_seed
import client/spawners.{type Spawner}
import client/state_capture
import client/state_node
import client/state_object.{type State, Full}
import client/state_service
import client/state_store
import client/state_transfer
import client/workspace_gate
import client/worktree_git
import core/clock
import core/ids
import gleam/erlang/atom
import gleam/erlang/node
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import host/bootstrap
import simplifile
import support/state_rig.{type Rig}
import support/worktree_rig
import telemetry/log
import tools/agent
import weft/registry

// The parent's machine: its repository, its store and the store's endpoint.
type Parent {
  Parent(
    rig: Rig,
    store: state_store.Store,
    endpoint: state_transfer.Endpoint,
    sent: State,
  )
}

// Everything one test drives.
type World {
  World(
    parent: Parent,
    receiver: state_node.StateNode,
    directory: String,
    at: address.Address(orchestrator_port.Message),
    handle: agent.Handle,
    copy: String,
  )
}

fn handle() -> agent.Handle {
  let #(op, _) = ids.mint_op(ids.generator(clock.fixed(at: 1), seed: 9))
  agent.Handle(
    strand: "sub:^main/finish-the-cache-0123456789abcdef",
    operation: op,
  )
}

fn site() -> remote_spawn.CallSite {
  let #(op, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 5))
  remote_spawn.CallSite(
    operation: op,
    step_id: "step-1",
    source_index: 0,
    minter: agent.ToolCall,
  )
}

fn request(state: Option(State)) -> remote_spawn.Request {
  remote_spawn.Request(
    purpose: "finish the cache",
    brief: "Finish the cache.",
    model: None,
    tools: None,
    within_ms: None,
    result_schema: None,
    detach: remote_spawn.Detached,
    state:,
  )
}

fn spawner(directory: String) -> Spawner {
  let text = "[distribution]
node = \"box@100.64.0.9\"
ca = \"/etc/loom/ca.pem\"
certificate = \"/etc/loom/cert.pem\"
key = \"/etc/loom/key.pem\"
cookie = \"/home/loom/.erlang.cookie\"

[[distribution.peers]]
node = \"laptop@100.64.0.5\"
sha256 = \"0000000000000000000000000000000000000000000000000000000000000001\"

[profiles.cheap-review.roles]
main = [\"fast\"]

[spawners.laptop]
node = \"laptop@100.64.0.5\"
profile = \"cheap-review\"
directory = \"" <> directory <> "\"
seed = \"workspace\"
"
  let assert Ok([found]) = spawners.parse(text) as "the table parses"
  found
}

// The delegate session's Agency: it starts the one child, and a join reports it
// finished with a report of its own.
fn finishing() -> agency.DelegateEndpoint {
  agency.DelegateEndpoint(
    fresh: fn() { session_states.Fresh },
    states: None,
    spawn: fn(_delegation, _site, _request) {
      Ok(remote_spawn.Spawned(
        handle: handle(),
        tools: ["bash"],
        model: "cheap",
        model_id: "cheap-1",
        remaining_ms: 60_000,
      ))
    },
    join: fn(_parent, handles, _within_ms) {
      Ok(
        list.map(handles, fn(found) {
          remote_spawn.Ready(
            handle: found,
            outcome: agent.Completed,
            report: "I finished the cache.",
            result: agent.NoResultAsked,
            notes: [],
            usage: remote_spawn.ChildUsage(
              input: 1,
              output: 1,
              cache_read: 0,
              cache_write: 0,
              cost: 0.0,
            ),
            owed: 0,
            state: None,
          )
        }),
      )
    },
    run_ended: fn(_operation) { Ok(0) },
    release: fn() { Ok(0) },
    send: fn(_parent, _child, _id, _text) { Error(unused()) },
    history: fn(_parent, _child, _cursor, _limit) { Error(unused()) },
    occupancy: fn() { agency.Vacant },
    resolve: fn(_parent, _child, _id, _decision, _seq, _decider) {
      Error(unused())
    },
  )
}

fn unused() -> remote_spawn.SpawnRefusal {
  remote_spawn.StoreFailure(reason: "not under test")
}

fn node_name() -> String {
  atom.to_string(node.name(node.self()))
}

// The parent's machine, with its workspace edited and captured into its store.
fn parent_side(name: String) -> Parent {
  let rig = state_rig.rig(name)
  let assert Ok(store) =
    state_store.open(
      state_store.directory(rig.state),
      state_store.default_limits,
    )
  let assert Ok(service) =
    state_service.start(store, fn() { ffi_os.system_time_ms() / 1000 })
  worktree_rig.write(rig.root <> "/README", "edited by the parent\n")
  worktree_rig.write(rig.root <> "/notes.txt", "not committed anywhere\n")
  let endpoint = state_service.endpoint(service)
  let capturer = state_capture.new(rig.git, rig.state, [], endpoint, store)
  let assert Ok(sent) =
    state_capture.capture(capturer, rig.root, state_rig.identity(), Full)
  Parent(rig:, store:, endpoint:, sent:)
}

// The receiving machine: a state root, a store with its service, and Git.
fn receiver_at(rig: Rig) -> state_node.StateNode {
  let root = rig.scratch <> "/receiver"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(root)
  worktree_rig.establish(root)
  let assert Ok(store) =
    state_store.open(state_store.directory(root), state_store.default_limits)
  let assert Ok(service) =
    state_service.start(store, fn() { ffi_os.system_time_ms() / 1000 })
  let assert Ok(here) = simplifile.current_directory()
  let assert Ok(git) =
    worktree_git.start(worktree_git.Config(
      helper_path: here <> "/../sandbox/loom-exec",
      scratch: root <> "/state-git",
      state_root: root,
      credentials: [],
      demand: exec.BestEffort,
    ))
  state_node.StateNode(
    endpoint: state_service.endpoint(service),
    store: Some(store),
    git: Some(git),
    state_root: root,
    credentials: [],
    logger: log.discard(),
  )
}

// A port with the given spawn host and state endpoint.
fn port(
  label: String,
  host: orchestrator_port.SpawnHost,
  states: state_transfer.Endpoint,
) -> address.Address(orchestrator_port.Message) {
  let name = process.new_name(label)
  let assert Ok(_started) =
    orchestrator_port.start_with_states(
      name,
      fn(_session) { Ok(orchestrator_port.NotOwned) },
      fn(_session, _command) { Error(orchestrator_port.peer_unserved) },
      fn(_session) { Error(orchestrator_port.peer_unserved) },
      orchestrator_port.declining(),
      host,
      orchestrator_port.refusing_children(),
      orchestrator_port.unheld,
      orchestrator_port.unreported(),
      orchestrator_port.refusing_top(),
      states,
    )
  Address(node: node.self(), name:)
}

// Whether the spawn sends the parent's workspace.
type Seeding {
  Seeded
  Unseeded
}

// Builds both machines and the spawn that starts the child, with `link_to`
// deciding whether the receiver can reach the parent's store.
fn world(
  name: String,
  seeding: Seeding,
  parents_endpoint: Option(state_transfer.Endpoint),
  link_to: fn(Parent, address.Address(orchestrator_port.Message)) ->
    fn(String) -> Option(state_transfer.Link),
) -> World {
  let parent = parent_side(name)
  let receiver = receiver_at(parent.rig)
  let directory = parent.rig.scratch <> "/scratch-dir"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
  let table = spawner(directory)

  // The parent's own port serves its store, so the receiver can send to it.
  let parents_port =
    port(
      "return_parent_port",
      main.spawn_host(
        [],
        fn(_s, _p) { Ok(finishing()) },
        fn(_s, _p) { Ok(0) },
        fn(_s, _p) { Ok(None) },
        log.discard(),
      ),
      option.unwrap(parents_endpoint, parent.endpoint),
    )
  let host =
    main.spawn_host_seeding(
      [spawners.Spawner(..table, node: node_name())],
      fn(_spawner, _parent) { Ok(finishing()) },
      fn(_spawner, _parent) { Ok(0) },
      fn(_spawner, _parent) { Ok(None) },
      delegate_host.no_children(),
      fn(found, parent, call_site, asked) {
        spawn_seed.land(
          receiver,
          delegate_host.no_children(),
          found,
          parent,
          call_site,
          asked,
        )
      },
      spawn_return.over(receiver, link_to(parent, parents_port), log.discard()),
      log.discard(),
    )
  let at = port("return_receiver_port", host, receiver.endpoint)
  let sent = case seeding {
    Seeded -> Some(parent.sent)
    Unseeded -> None
  }
  let assert Ok(Ok(_spawned)) =
    remote_spawner.asked_with_state(
      Some(parent.store),
      at,
      remote_spawn.Parent(session: "s1", strand: "main"),
      site(),
      0,
      ["bash"],
      request(sent),
      30_000,
      log.discard(),
    )
  let copy = case sent {
    Some(state) -> directory <> "/seeds/" <> spawn_seed.name_of(site(), state)
    None -> ""
  }
  World(parent:, receiver:, directory:, at:, handle: handle(), copy:)
}

// The link to the parent's port, always up.
fn connected(
  _parent: Parent,
  parents_port: address.Address(orchestrator_port.Message),
) -> fn(String) -> Option(state_transfer.Link) {
  fn(_node) { Some(state_link.via_port(parents_port, 5000)) }
}

// Waits for a condition the receiver brings about in its own process.
fn until(holds: fn() -> Bool, tries: Int) -> Nil {
  case holds(), tries > 0 {
    True, _ -> Nil
    False, True -> {
      process.sleep(200)
      until(holds, tries - 1)
    }
    False, False -> panic as "the condition never held"
  }
}

// How many files the receiver's store holds.
fn stored(world: World) -> Int {
  let assert Ok(files) =
    simplifile.read_directory(world.receiver.state_root <> "/states")
  list.length(files)
}

// What the child does in its copy: two commits, and an edit it leaves.
fn child_works(world: World) -> String {
  let _ = state_rig.commit_file(world.copy, "first.txt", "one\n", "child one")
  let tip =
    state_rig.commit_file(world.copy, "second.txt", "two\n", "child two")
  worktree_rig.write(world.copy <> "/README", "never committed\n")
  tip
}

fn ask_join(world: World) -> remote_spawn.Joined {
  let assert Ok(Ok([joined])) =
    orchestrator_port.ask_join(
      world.at,
      remote_spawn.Parent(session: "s1", strand: "main"),
      [world.handle],
      1000,
      8000,
    )
  joined
}

// Joins until the entry is a finished one, which the receiver answers `Pending`
// to while the work runs.
fn finished(world: World, tries: Int) -> remote_spawn.Joined {
  case ask_join(world) {
    remote_spawn.Ready(..) as ready -> ready
    remote_spawn.Pending(..) as pending ->
      case tries > 0 {
        True -> {
          process.sleep(300)
          finished(world, tries - 1)
        }
        False -> pending
      }
  }
}

fn report_of(joined: remote_spawn.Joined) -> String {
  let assert remote_spawn.Ready(report:, ..) = joined
  report
}

fn state_of(joined: remote_spawn.Joined) -> Option(State) {
  let assert remote_spawn.Ready(state:, ..) = joined
  state
}

pub fn a_finished_childs_commits_reach_the_parents_store_test() {
  let world = world("return-whole", Seeded, None, connected)
  let rig = world.parent.rig
  let tip = child_works(world)
  let refs = state_rig.refs(rig.root)

  let joined = finished(world, 60)
  let assert Some(state) = state_of(joined)
  assert state.tip == tip
  assert state.base == Some(world.parent.sent.tip)
  assert string.starts_with(report_of(joined), "I finished the cache.")
  assert string.contains(report_of(joined), spawn_return.uncommitted_note)

  // The bundle is whole in the parent's store, and the parent's repository has
  // not been touched by the arrival.
  assert world.parent.endpoint.stage(state.hash) == Ok(state_transfer.Complete)
  assert state_rig.refs(rig.root) == refs

  // Applied behind the parent's gate, the commits are one ref, and the child's
  // uncommitted edit is not in it. The parent's branches, HEAD and tree are as
  // they were.
  let head = worktree_rig.git(rig.root, ["rev-parse", "HEAD"])
  let status = worktree_rig.git(rig.root, ["status", "--porcelain"])
  let assert Ok(names) = registry.start()
  let assert Ok(gate) = workspace_gate.start_at(registry.new_address(names))
  let assert Ok(remote_child.Applied(ref:, commits: 2)) =
    return_apply.behind_gate(
      gate,
      1000,
      60_000,
      rig.root,
      rig.root,
      return_apply.from_store(world.parent.store, rig.git, log.discard()),
      world.parent.sent,
      state,
      world.handle.strand,
    )
  assert ref
    == "refs/loom/children/finish-the-cache-0123456789abcdef/"
    <> string.slice(tip, 0, 8)
  assert list.filter(string.split(state_rig.refs(rig.root), "\n"), fn(line) {
      !list.contains(string.split(refs, "\n"), line)
    })
    == [ref <> " " <> tip]
  assert worktree_rig.git(rig.root, ["show", tip <> ":README"])
    == "edited by the parent"
  assert worktree_rig.git(rig.root, ["rev-parse", "HEAD"]) == head
  assert worktree_rig.git(rig.root, ["status", "--porcelain"]) == status

  // The same join asked again answers the same state and sends nothing twice.
  assert state_of(finished(world, 60)) == Some(state)
  state_rig.stop(rig)
}

pub fn a_child_that_committed_nothing_returns_no_state_test() {
  let world = world("return-none", Seeded, None, connected)
  let rig = world.parent.rig
  worktree_rig.write(world.copy <> "/README", "never committed\n")

  let joined = finished(world, 60)
  assert state_of(joined) == None
  assert string.contains(report_of(joined), spawn_return.no_commits_note)
  assert string.contains(report_of(joined), spawn_return.uncommitted_note)
  state_rig.stop(rig)
}

pub fn a_child_that_was_handed_no_state_is_answered_as_it_was_test() {
  let world = world("return-unseeded", Unseeded, None, connected)
  let rig = world.parent.rig
  let joined = ask_join(world)
  assert state_of(joined) == None
  assert report_of(joined) == "I finished the cache."
  state_rig.stop(rig)
}

pub fn a_transfer_that_cannot_start_is_retried_by_the_next_join_test() {
  let world =
    world("return-resume", Seeded, None, fn(parent, parents_port) {
      // The link is down while a marker file is there.
      let marker = parent.rig.scratch <> "/link-down"
      let assert Ok(Nil) = simplifile.write(marker, "down")
      fn(_node) {
        case simplifile.is_file(marker) {
          Ok(True) -> None
          _ -> Some(state_link.via_port(parents_port, 5000))
        }
      }
    })
  let rig = world.parent.rig
  let _tip = child_works(world)
  let before = stored(world)

  // While the link is down the child is still being returned, and its commits
  // are captured into the receiver's store once, whatever the number of joins.
  let assert remote_spawn.Pending(..) = ask_join(world)
  until(fn() { stored(world) > before }, 100)
  let held = stored(world)
  let assert remote_spawn.Pending(..) = ask_join(world)
  let assert remote_spawn.Pending(..) = ask_join(world)
  assert stored(world) == held

  // When the link is back the next join delivers the state it kept.
  let assert Ok(Nil) = simplifile.delete(rig.scratch <> "/link-down")
  let joined = finished(world, 60)
  let assert Some(state) = state_of(joined)
  assert world.parent.endpoint.stage(state.hash) == Ok(state_transfer.Complete)
  assert stored(world) == held
  state_rig.stop(rig)
}

pub fn a_return_that_never_finishes_is_given_up_with_a_note_test() {
  let world =
    world("return-giveup", Seeded, None, fn(_parent, _port) {
      fn(_node) { None }
    })
  let rig = world.parent.rig
  let _tip = child_works(world)

  // Every join is one more try, and the child stays unfinished until the last.
  let joined = finished(world, 120)
  assert state_of(joined) == None
  assert string.starts_with(report_of(joined), "I finished the cache.")
  assert string.contains(report_of(joined), "did not finish after 5 tries")
  assert string.contains(report_of(joined), "state store as")

  // The matter is closed: the same answer, and no further tries.
  assert report_of(ask_join(world)) == report_of(joined)
  state_rig.stop(rig)
}

pub fn a_parent_that_declines_the_bundle_costs_the_child_nothing_test() {
  let world =
    world(
      "return-declined",
      Seeded,
      Some(state_transfer.declining()),
      connected,
    )
  let rig = world.parent.rig
  let _tip = child_works(world)

  let joined = finished(world, 60)
  assert state_of(joined) == None
  assert string.starts_with(report_of(joined), "I finished the cache.")
  assert string.contains(report_of(joined), "could not be returned")
  assert string.contains(report_of(joined), "declined")
  state_rig.stop(rig)
}

pub fn a_restart_clears_the_claims_and_keeps_the_verdicts_test() {
  let rig = state_rig.rig("return-sweep")
  let directory = rig.state <> "/" <> spawn_return.directory_name
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
  let assert Ok(Nil) = simplifile.create_directory(directory <> "/a.claim")
  let assert Ok(Nil) = simplifile.write(directory <> "/a.verdict", "{}")
  let assert Ok(Nil) = simplifile.write(directory <> "/a.copy", "{}")

  spawn_return.sweep(rig.state)
  assert simplifile.is_directory(directory <> "/a.claim") == Ok(False)
  assert simplifile.is_file(directory <> "/a.verdict") == Ok(True)
  assert simplifile.is_file(directory <> "/a.copy") == Ok(True)

  // A state root with no such directory has nothing to sweep.
  spawn_return.sweep(rig.scratch <> "/nowhere")
  state_rig.stop(rig)
}

pub fn a_refused_capture_tells_the_parent_no_path_of_this_machine_test() {
  let world = world("return-nopath", Seeded, None, connected)
  let rig = world.parent.rig

  // The child discards the history it was given, so the capture is refused.
  let _ = worktree_rig.git(world.copy, ["reset", "--hard", "--quiet", "HEAD~1"])
  let _ = state_rig.commit_file(world.copy, "other.txt", "other\n", "elsewhere")

  let joined = finished(world, 60)
  assert state_of(joined) == None
  let report = report_of(joined)
  assert string.contains(report, spawn_return.capture_refused)

  // Nothing of the receiver's directories reaches the parent's model.
  assert !string.contains(report, world.directory)
  assert !string.contains(report, world.receiver.state_root)
  assert !string.contains(report, rig.scratch)
  state_rig.stop(rig)
}

pub fn a_copy_replaced_by_a_link_is_not_followed_test() {
  let world = world("return-link", Seeded, None, connected)
  let rig = world.parent.rig
  let refs = state_rig.refs(rig.root)

  // The child swaps its copy for a link to the parent's own repository, which
  // holds the sent tip's history.
  let assert Ok(Nil) = simplifile.delete(world.copy)
  let assert Ok(Nil) = simplifile.create_symlink(rig.root, world.copy)

  let joined = finished(world, 60)
  assert state_of(joined) == None
  assert string.contains(report_of(joined), "could not be returned")
  assert state_rig.refs(rig.root) == refs
  state_rig.stop(rig)
}
