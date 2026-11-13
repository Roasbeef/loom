//// A seeded spawn whose spawner is placed on an executor, end to end
//// (protocol-change/107, slice 4b).
////
//// The parent's machine is an orchestrator port with a store and a repository.
//// The receiving machine is a second port whose spawn host is the daemon's own
//// (`main.spawn_host_seeding`) with `spawn_seed.land` as its judge and
//// `spawn_return.over` in the path of every join. The executor is the real host
//// over a worktree workspace (`support/executor_rig`), a session of it attaches
//// through the real surface, and the record of what that session can do with
//// states is the production `workspace.states_over`. Only the registry is
//// replaced: a stub `ChildSessions` hands the receiver the one session the test
//// attached and records when it is made, started and ended. The registry's own
//// keying of a session by child is tested where it lives, in
//// `delegate_host_test`.
////
//// What the tests look at is the order. The child's first turn is the Agency's
//// `spawn`, and the stub checks inside it that the tree already holds the
//// parent's work.

import broker/exec
import client/agency
import client/daemon/main
import client/delegate_host
import client/internal/ffi_os
import client/remote/address.{Address}
import client/remote/orchestrator_port
import client/remote/protocol
import client/remote/remote_spawner
import client/remote/state_link
import client/remote/workspace as remote_workspace
import client/remote_spawn
import client/return_apply
import client/session_states.{type SessionStates, SessionStates}
import client/spawn_return
import client/spawn_seed
import client/spawners.{type Spawner}
import client/state_capture
import client/state_node
import client/state_object.{type State, Full}
import client/state_service
import client/state_store
import client/state_transfer
import client/worktree_git
import core/clock
import core/ids
import core/json
import gleam/bit_array
import gleam/erlang/atom
import gleam/erlang/node
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import host/bootstrap
import simplifile
import support/cell.{type Cell}
import support/executor_rig.{type Plane}
import support/state_rig.{type Rig}
import support/worktree_rig.{session}
import telemetry/log
import tools/agent
import weft/poll

// --- the machines ---------------------------------------------------------------

// How much a parent's repository carries beyond its README. A ballast of random
// text makes the bundle several pieces long, which the resume test needs.
type Ballast {
  Small
  Large
}

type Parent {
  Parent(
    rig: Rig,
    store: state_store.Store,
    endpoint: state_transfer.Endpoint,
    sent: State,
  )
}

// What the stub registry saw, in the processes that made it see it.
type Event {
  Resolved(name: String)
  Spawned(on_the_parents_tip: Bool)
  Released(name: String)
  Ended
  Messaged(text: String)
}

// The one spawn, the machines it runs on and what the stubs recorded.
type World {
  World(
    parent: Parent,
    receiver: state_node.StateNode,
    plane: Plane,
    attached: executor_rig.Attached,
    at: address.Address(orchestrator_port.Message),
    journal: Cell(List(Event)),
    applies: Cell(Int),
    began: Cell(Bool),
    finished: Cell(Bool),
    refuse_spawn: Cell(Option(remote_spawn.SpawnRefusal)),
    refuse_resolve: Cell(Option(remote_spawn.SpawnRefusal)),
    refuse_pair: Cell(Option(remote_spawn.SpawnRefusal)),
    unreadable: Cell(Bool),
    child: String,
    handle: agent.Handle,
  )
}

// A repository whose unrelated file is the digest of the previous one, over and
// over, for as many bytes as asked. The text does not compress, so the bundle is
// at least as long, and nothing in it is random.
fn ballast_text(bytes: Int) -> String {
  ballast_loop("seed", bytes, "")
}

fn ballast_loop(previous: String, left: Int, text: String) -> String {
  case left <= 0 {
    True -> text
    False -> {
      let next = state_object.hash_of(bit_array.from_string(previous))
      ballast_loop(next, left - 64, text <> next)
    }
  }
}

fn parent_side(name: String, ballast: Ballast) -> Parent {
  let rig = state_rig.rig(name)
  let assert Ok(store) =
    state_store.open(
      state_store.directory(rig.state),
      state_store.default_limits,
    )
  let assert Ok(service) =
    state_service.start(store, fn() { ffi_os.system_time_ms() / 1000 })

  // A large repository commits the ballast, so it is history and not an edit.
  case ballast {
    Large ->
      worktree_rig.write(rig.root <> "/ballast.txt", ballast_text(2_000_000))
    Small -> Nil
  }
  let _ = worktree_rig.git(rig.root, ["add", "-A"])
  let _ =
    worktree_rig.git(rig.root, [
      "commit",
      "--quiet",
      "--allow-empty",
      "-m",
      "ballast",
    ])

  // The edit to a tracked file and the new file are left uncommitted.
  worktree_rig.write(rig.root <> "/README", "edited by the parent\n")
  worktree_rig.write(rig.root <> "/notes.txt", "not committed anywhere\n")
  let endpoint = state_service.endpoint(service)
  let capturer = state_capture.new(rig.git, rig.state, [], endpoint, store)
  let assert Ok(sent) =
    state_capture.capture(capturer, rig.root, state_rig.identity(), Full)
  Parent(rig:, store:, endpoint:, sent:)
}

// The receiving orchestrator: a state root, a store with its service, and Git.
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

fn node_name() -> String {
  atom.to_string(node.name(node.self()))
}

fn handle() -> agent.Handle {
  let #(op, _) = ids.mint_op(ids.generator(clock.fixed(at: 1), seed: 9))
  agent.Handle(
    strand: "sub:^main/finish-the-cache-0123456789abcdef",
    operation: op,
  )
}

fn site(index: Int) -> remote_spawn.CallSite {
  let #(op, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 5))
  remote_spawn.CallSite(
    operation: op,
    step_id: "step-1",
    source_index: index,
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

// The spawner of the box, placed on the executor `runner`.
fn spawner() -> Spawner {
  let text =
    "[distribution]
node = \"box@100.64.0.9\"
ca = \"/etc/loom/ca.pem\"
certificate = \"/etc/loom/cert.pem\"
key = \"/etc/loom/key.pem\"
cookie = \"/home/loom/.erlang.cookie\"

[[distribution.peers]]
node = \"laptop@100.64.0.5\"
sha256 = \"0000000000000000000000000000000000000000000000000000000000000001\"

[[distribution.peers]]
node = \"runner@100.64.0.7\"
sha256 = \"0000000000000000000000000000000000000000000000000000000000000003\"

[executors.runner]
node = \"runner@100.64.0.7\"

[profiles.cheap-review.roles]
main = [\"fast\"]

[spawners.laptop]
node = \"laptop@100.64.0.5\"
profile = \"cheap-review\"
executor = \"runner\"
workspace = \"repo\"
seed = \"workspace\"
"
  let assert Ok([found]) = spawners.parse(text) as "the table parses"
  spawners.Spawner(..found, node: node_name())
}

// The Agency of the child's own session. Its `spawn` is the child's first turn:
// it looks at the tree before it records that the child began.
fn child_endpoint(
  world: Pieces,
  tree: String,
  tip: String,
) -> agency.DelegateEndpoint {
  let fresh = fn() {
    case cell.get(world.unreadable), cell.get(world.began) {
      True, _ -> session_states.Unreadable
      False, True -> session_states.Begun
      False, False -> session_states.Fresh
    }
  }
  agency.DelegateEndpoint(
    fresh:,
    states: Some(session_states.before_first_turn(world.states, fresh)),
    spawn: fn(_delegation, _site, _request) {
      case cell.get(world.refuse_spawn), cell.get(world.began) {
        Some(refusal), _ -> Error(refusal)

        // The Agency answers the child a call site already started.
        None, True -> Ok(started())
        None, False -> {
          let on_tip = worktree_rig.git(tree, ["rev-parse", "HEAD"]) == tip
          record(world.journal, Spawned(on_tip))
          cell.update(world.began, fn(_) { True })
          Ok(started())
        }
      }
    },
    join: fn(_parent, handles, _within_ms) {
      Ok(
        list.map(handles, fn(found) {
          case cell.get(world.finished) {
            True ->
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
            False -> remote_spawn.Pending(handle: found, waited_ms: 10)
          }
        }),
      )
    },
    run_ended: fn(_operation) {
      record(world.journal, Ended)
      Ok(1)
    },
    release: fn() { Ok(0) },
    send: fn(_parent, _child, _id, text) {
      record(world.journal, Messaged(text))
      Ok(json.Null)
    },
    history: fn(_parent, _child, _cursor, _limit) { Error(unused()) },
    occupancy: fn() { agency.Vacant },
    resolve: fn(_parent, _child, _id, _decision, _seq, _decider) {
      Error(unused())
    },
  )
}

// The pair's session, which no seeded child is in: it ends a run and nothing
// else, and a message that reached it would be a message to the wrong session.
fn pair_endpoint() -> agency.DelegateEndpoint {
  agency.DelegateEndpoint(
    fresh: fn() { session_states.Fresh },
    states: None,
    spawn: fn(_delegation, _site, _request) { Error(unused()) },
    join: fn(_parent, _handles, _within_ms) { Ok([]) },
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

fn started() -> remote_spawn.Spawned {
  remote_spawn.Spawned(
    handle: handle(),
    tools: ["bash"],
    model: "cheap",
    model_id: "cheap-1",
    remaining_ms: 60_000,
  )
}

fn record(journal: Cell(List(Event)), event: Event) -> Nil {
  cell.update(journal, fn(held) { list.append(held, [event]) })
}

fn unused() -> remote_spawn.SpawnRefusal {
  remote_spawn.StoreFailure(reason: "not under test")
}

// What the stub registry and the endpoint share.
type Pieces {
  Pieces(
    states: SessionStates,
    journal: Cell(List(Event)),
    began: Cell(Bool),
    finished: Cell(Bool),
    refuse_spawn: Cell(Option(remote_spawn.SpawnRefusal)),
    refuse_resolve: Cell(Option(remote_spawn.SpawnRefusal)),
    unreadable: Cell(Bool),
  )
}

// The stub registry: a child's session exists once it has been resolved, and
// ending it is recorded.
fn children(
  pieces: Pieces,
  tree: String,
  tip: String,
  made: Cell(Bool),
) -> delegate_host.ChildSessions {
  let endpoint = child_endpoint(pieces, tree, tip)
  delegate_host.ChildSessions(
    resolve: fn(_spawner, _parent, name) {
      record(pieces.journal, Resolved(name))
      cell.update(made, fn(_) { True })

      // A registry that made the row and could not start the session refuses, and
      // the row stays.
      case cell.get(pieces.refuse_resolve) {
        Some(refusal) -> Error(refusal)
        None -> Ok(endpoint)
      }
    },
    open: fn(_spawner, _parent, _name) {
      case cell.get(made) {
        True -> Ok(Some(endpoint))
        False -> Ok(None)
      }
    },
    resident: fn(_spawner, _parent, _name) {
      case cell.get(made) {
        True -> Ok(Some(endpoint))
        False -> Ok(None)
      }
    },
    live: fn(_spawner, _parent) {
      case cell.get(made) {
        True -> Ok([endpoint])
        False -> Ok([])
      }
    },
    release: fn(_spawner, _parent, name) {
      record(pieces.journal, Released(name))
      cell.update(made, fn(_) { False })
      Ok(0)
    },
  )
}

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

// How the executor's link behaves while the receiver sends it the bundle.
type Link {
  Steady
  // Drops the second piece once, as a connection that fails in the middle does.
  DropsOnce(offsets: Cell(List(Int)))

  // The executor does not answer the request for the child's commits the first
  // `until` times it is asked, counted in `asks`.
  SilentCapture(asks: Cell(Int), until: Int)

  // The executor's store has no room for the first piece it is sent, as a store at
  // its total cap does, and has room for every later one.
  NoRoomOnce(sends: Cell(Int))

  // The first apply is answered from a fence that has moved on, which is not
  // about the state, and every later apply goes through.
  StaleFenceOnce(asks: Cell(Int))

  // Every apply is refused by the workspace, which the same state always is.
  ApplyRefused

  // The session's own check, made at the moment of the request, says the child
  // began while the apply was on its way.
  BegunAtApply
}

// Builds every machine and answers the world, before any spawn is asked.
fn world(name: String, ballast: Ballast, link: Link, shared: Bool) -> World {
  let parent = parent_side(name, ballast)
  let receiver = receiver_at(parent.rig)
  let plane = case shared {
    True -> executor_rig.serve_shared(name <> "-exec")
    False -> executor_rig.serve(name <> "-exec")
  }
  let attached = executor_rig.attach(plane, 1, "runner")
  let applies = cell.new(0)
  let counting =
    SessionStates(..attached.states, apply: fn(state) {
      cell.update(applies, fn(held) { held + 1 })
      attached.states.apply(state)
    })
  let states = case link {
    Steady -> counting
    SilentCapture(asks:, until:) ->
      SessionStates(..counting, capture: fn(basis, content) {
        let before = cell.get(asks)
        cell.update(asks, fn(held) { held + 1 })
        case before < until {
          True ->
            Error(session_states.Later("the executor did not answer in time"))
          False -> counting.capture(basis, content)
        }
      })
    NoRoomOnce(sends:) ->
      SessionStates(
        ..counting,
        link: state_transfer.Link(
          ..counting.link,
          piece: fn(piece: state_transfer.Piece) {
            let before = cell.get(sends)
            cell.update(sends, fn(held) { held + 1 })
            case before == 0 {
              True ->
                Ok(
                  state_transfer.Refused(state_transfer.NoRoom(
                    "the store is at its total cap",
                  )),
                )
              False -> counting.link.piece(piece)
            }
          },
        ),
      )
    StaleFenceOnce(asks:) ->
      SessionStates(..counting, apply: fn(state) {
        let before = cell.get(asks)
        cell.update(asks, fn(held) { held + 1 })
        case before == 0 {
          True ->
            Error(session_states.Later("the executor's fence has moved on"))
          False -> counting.apply(state)
        }
      })
    ApplyRefused ->
      SessionStates(..counting, apply: fn(_state) {
        cell.update(applies, fn(held) { held + 1 })
        Error(session_states.Final("the workspace does not take this state"))
      })
    BegunAtApply ->
      SessionStates(..counting, apply: fn(_state) {
        Error(session_states.Final(session_states.already_begun))
      })
    DropsOnce(offsets:) ->
      SessionStates(
        ..counting,
        link: state_transfer.Link(
          ..counting.link,
          piece: fn(piece: state_transfer.Piece) {
            cell.update(offsets, fn(held) { list.append(held, [piece.offset]) })
            let seen = list.length(cell.get(offsets))
            case seen == 2 {
              True -> Error(Nil)
              False -> counting.link.piece(piece)
            }
          },
        ),
      )
  }
  let journal = cell.new([])
  let began = cell.new(False)
  let finished = cell.new(False)
  let refuse_spawn = cell.new(None)
  let refuse_resolve = cell.new(None)
  let refuse_pair = cell.new(None)
  let unreadable = cell.new(False)
  let pieces =
    Pieces(
      states:,
      journal:,
      began:,
      finished:,
      refuse_spawn:,
      refuse_resolve:,
      unreadable:,
    )
  let child = spawn_seed.name_of(site(0), parent.sent)
  let sessions =
    children(
      pieces,
      executor_rig.tree_of(plane, 1),
      parent.sent.tip,
      cell.new(False),
    )

  // The parent's own port serves its store, so the receiver can send to it.
  let parents_port =
    port(
      "seed_exec_parent_port",
      main.spawn_host(
        [],
        fn(_s, _p) { Error(unused()) },
        fn(_s, _p) { Ok(0) },
        fn(_s, _p) { Ok(None) },
        log.discard(),
      ),
      parent.endpoint,
    )
  let host =
    main.spawn_host_seeding(
      [spawner()],
      fn(_spawner, _parent) {
        case cell.get(refuse_pair) {
          Some(refusal) -> Error(refusal)
          None -> Ok(pair_endpoint())
        }
      },
      fn(_spawner, _parent) { Ok(0) },
      fn(_spawner, _parent) { Ok(None) },
      sessions,
      fn(found, parent_ref, call_site, asked) {
        spawn_seed.land(receiver, sessions, found, parent_ref, call_site, asked)
      },
      spawn_return.over(
        receiver,
        fn(_node) { Some(state_link.via_port(parents_port, 5000)) },
        log.discard(),
      ),
      log.discard(),
    )
  let at = port("seed_exec_receiver_port", host, receiver.endpoint)
  World(
    parent:,
    receiver:,
    plane:,
    attached:,
    at:,
    journal:,
    applies:,
    began:,
    finished:,
    refuse_spawn:,
    refuse_resolve:,
    refuse_pair:,
    unreadable:,
    child:,
    handle: handle(),
  )
}

// The parent's spawn, asked as its Agency asks it.
fn ask_spawn(
  world: World,
) -> Result(Result(remote_spawn.Spawned, remote_spawn.SpawnRefusal), Nil) {
  remote_spawner.asked_with_state(
    Some(world.parent.store),
    world.at,
    remote_spawn.Parent(session: session(9), strand: "main"),
    site(0),
    0,
    ["bash"],
    request(Some(world.parent.sent)),
    30_000,
    log.discard(),
  )
}

fn ask_join(world: World) -> remote_spawn.Joined {
  let assert Ok(Ok([joined])) =
    orchestrator_port.ask_join(
      world.at,
      remote_spawn.Parent(session: session(9), strand: "main"),
      [world.handle],
      1000,
      8000,
    )
  joined
}

// Joins until the entry is a finished one, which the receiver answers `Pending`
// to while the commits are being captured and moved.
fn finished_entry(world: World) -> remote_spawn.Joined {
  let waited =
    poll.until(within: 60_000, every: 100, attempt: fn() {
      case ask_join(world) {
        remote_spawn.Ready(..) as ready -> poll.Done(ready)
        remote_spawn.Pending(..) -> poll.Retry
      }
    })
  let assert poll.Answered(ready) = waited as "the child's entry is finished"
  ready
}

fn stop(world: World) -> Nil {
  executor_rig.stop(world.plane)
  state_rig.stop(world.parent.rig)
}

// Whether the journal comes to hold exactly these events. The processes that
// make them are the receiver's and its tasks', and a test does not rely on their
// mailboxes being ordered against its own, so it waits for the journal to say it.
fn journal_is(world: World, expected: List(Event)) -> Bool {
  let waited =
    poll.until(within: 5000, every: 10, attempt: fn() {
      case cell.get(world.journal) == expected {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
  case waited {
    poll.Answered(Nil) -> True
    poll.Failed(_) | poll.Expired -> False
  }
}

// --- the tests ------------------------------------------------------------------

pub fn a_seeded_child_starts_in_a_worktree_holding_the_parents_work_and_returns_its_commits_test() {
  let world = world("seed-exec-whole", Small, Steady, False)
  let parent_root = world.parent.rig.root
  let parent_head = worktree_rig.git(parent_root, ["rev-parse", "HEAD"])
  let parents_refs = state_rig.refs(parent_root)
  let tree = executor_rig.tree_of(world.plane, 1)

  // The spawn goes through, and the child's first turn found its tree whole.
  let assert Ok(Ok(spawned)) = ask_spawn(world)
  assert spawned.handle == world.handle
  assert journal_is(world, [Resolved(world.child), Spawned(True)])

  // The tree is the parent's workspace as it was when it asked: the edit to a
  // tracked file and the untracked file, committed as one snapshot on top of the
  // parent's own HEAD, on the session's branch.
  assert worktree_rig.git(tree, ["rev-parse", "HEAD"]) == world.parent.sent.tip
  assert worktree_rig.git(tree, ["rev-parse", "HEAD^"]) == parent_head
  assert worktree_rig.git(tree, ["rev-parse", "--abbrev-ref", "HEAD"])
    == "loom/" <> session(1)
  assert simplifile.read(tree <> "/README") == Ok("edited by the parent\n")
  assert simplifile.read(tree <> "/notes.txt") == Ok("not committed anywhere\n")
  assert worktree_rig.git(tree, ["status", "--porcelain"]) == ""

  // The parent's own checkout and refs are untouched.
  assert state_rig.refs(parent_root) == parents_refs
  assert simplifile.read(parent_root <> "/README")
    == Ok("edited by the parent\n")

  // The child commits twice and leaves an edit.
  let _ = state_rig.commit_file(tree, "first.txt", "one\n", "child one")
  let tip = state_rig.commit_file(tree, "second.txt", "two\n", "child two")
  worktree_rig.write(tree <> "/README", "never committed\n")

  // Until it finishes the join waits, and the child's session is kept.
  assert ask_join(world) == remote_spawn.Pending(world.handle, 10)
  assert cell.get(world.journal) == [Resolved(world.child), Spawned(True)]
  cell.update(world.finished, fn(_) { True })

  // Its commits come back to the parent's store, thin against what was sent, and
  // the session is ended once, after the entry says the child is done.
  let joined = finished_entry(world)
  let assert remote_spawn.Ready(report:, state: Some(returned), ..) = joined
  assert returned.tip == tip
  assert returned.base == Some(world.parent.sent.tip)

  // Only commits come back from a workspace on an executor, and the report says
  // so, because the tree there is not looked at.
  assert string.contains(report, spawn_return.session_tree_note)
  assert journal_is(world, [
    Resolved(world.child),
    Spawned(True),
    Released(world.child),
  ])
  let assert Ok(Some(_held)) =
    state_store.get(world.parent.store, returned.hash)

  // The parent applies them as its Agency does: one ref under the child's name,
  // two commits, and the checked-out branch and its files as they were.
  let apply =
    return_apply.from_store(
      world.parent.store,
      world.parent.rig.git,
      log.discard(),
    )
  let assert Ok(#(ref, commits)) =
    apply(parent_root, world.parent.sent, returned, world.handle.strand)
  assert commits == 2
  assert string.starts_with(ref, "refs/loom/children/")
  assert string.ends_with(ref, "/" <> string.slice(tip, 0, 8))
  assert worktree_rig.git(parent_root, ["rev-parse", ref]) == tip
  assert simplifile.read(parent_root <> "/README")
    == Ok("edited by the parent\n")
  stop(world)
}

pub fn a_resend_of_a_spawn_that_began_puts_nothing_in_the_tree_again_test() {
  let world = world("seed-exec-resend", Small, Steady, False)
  let tree = executor_rig.tree_of(world.plane, 1)
  let assert Ok(Ok(first)) = ask_spawn(world)
  assert cell.get(world.applies) == 1

  // The child works in its tree, and the sender asks again because it never heard.
  let tip = state_rig.commit_file(tree, "child.txt", "mine\n", "child work")
  let assert Ok(Ok(again)) = ask_spawn(world)
  assert again == first

  // The session has begun, so the second ask sent no apply and made no session.
  assert cell.get(world.applies) == 1
  assert worktree_rig.git(tree, ["rev-parse", "HEAD"]) == tip
  assert journal_is(world, [Resolved(world.child), Spawned(True)])
  stop(world)
}

pub fn an_apply_is_refused_once_the_childs_session_has_begun_test() {
  let world = world("seed-exec-begun", Small, Steady, False)
  let tree = executor_rig.tree_of(world.plane, 1)
  let head = worktree_rig.git(tree, ["rev-parse", "HEAD"])

  // The session's record, with the fence the assembly puts on it, takes a state
  // while the session is fresh and refuses it after the first turn, without
  // asking the executor. A session that cannot be read is put off, not refused.
  let begun =
    session_states.before_first_turn(world.attached.states, fn() {
      session_states.Begun
    })
  assert begun.apply(world.parent.sent)
    == Error(session_states.Final(session_states.already_begun))
  let unreadable =
    session_states.before_first_turn(world.attached.states, fn() {
      session_states.Unreadable
    })
  assert unreadable.apply(world.parent.sent)
    == Error(session_states.Later(session_states.unreadable))
  assert worktree_rig.git(tree, ["rev-parse", "HEAD"]) == head
  stop(world)
}

pub fn a_shared_mode_workspace_is_refused_naming_the_mode_and_the_session_ended_test() {
  let world = world("seed-exec-shared", Small, Steady, True)
  let checkout = world.plane.rig.root
  let refs = state_rig.refs(checkout)

  // The census says it before any byte is sent.
  let assert Error(fit) = world.attached.states.fit
  assert string.contains(fit, "mode = \"shared\"")
  assert string.contains(fit, "mode = \"worktree\"")

  // The spawn is refused with that reason, no child began, and the session that
  // was made for it is ended.
  let assert Ok(Error(remote_spawn.StateRefused(reason))) = ask_spawn(world)
  assert string.contains(reason, "mode = \"shared\"")
  assert journal_is(world, [Resolved(world.child), Released(world.child)])
  assert state_rig.refs(checkout) == refs
  assert cell.get(world.applies) == 0
  stop(world)
}

pub fn a_spawn_the_agency_refuses_ends_the_session_made_for_it_test() {
  let world = world("seed-exec-refused", Small, Steady, False)
  cell.update(world.refuse_spawn, fn(_) {
    Some(remote_spawn.InvalidArgument(reason: "no such tool"))
  })

  // The workspace was put in place, the Agency refused for good, and a session
  // that will never run a child is not left holding a slot and a worktree.
  let assert Ok(Error(remote_spawn.InvalidArgument(reason: "no such tool"))) =
    ask_spawn(world)
  assert journal_is(world, [Resolved(world.child), Released(world.child)])
  stop(world)
}

pub fn a_transfer_cut_mid_state_resumes_where_the_executor_stands_test() {
  let offsets = cell.new([])
  let world = world("seed-exec-resume", Large, DropsOnce(offsets), False)
  let hash = world.parent.sent.hash
  assert world.parent.sent.size > state_transfer.chunk_bytes * 2

  // The second piece is lost. The ask answers that the workspace is still on its
  // way, and a session made for the spawn is kept for the next ask.
  let assert Ok(Error(remote_spawn.NotYetOpen(_))) = ask_spawn(world)
  assert journal_is(world, [Resolved(world.child)])
  assert state_transfer.stage(world.plane.store, hash)
    == Ok(state_transfer.Partial(held: state_transfer.chunk_bytes))

  // The next ask goes on from the executor's offset and not from zero, and the
  // child starts on a whole tree.
  let assert Ok(Ok(_spawned)) = ask_spawn(world)
  let sent = cell.get(offsets)
  assert list.take(sent, 3)
    == [0, state_transfer.chunk_bytes, state_transfer.chunk_bytes]
  assert state_transfer.stage(world.plane.store, hash)
    == Ok(state_transfer.Complete)
  assert journal_is(world, [Resolved(world.child), Spawned(True)])
  assert worktree_rig.git(executor_rig.tree_of(world.plane, 1), [
      "rev-parse",
      "HEAD",
    ])
    == world.parent.sent.tip
  stop(world)
}

pub fn the_end_of_a_run_and_a_message_reach_the_childs_own_session_test() {
  let world = world("seed-exec-routing", Small, Steady, False)
  let parent = remote_spawn.Parent(session: session(9), strand: "main")
  let assert Ok(Ok(_spawned)) = ask_spawn(world)

  // The run ends: the pair's session stops nothing, the child's stops one, and the
  // answer is the sum.
  let #(operation, _) = ids.mint_op(ids.generator(clock.fixed(at: 5), seed: 9))
  assert orchestrator_port.ask_run_ended(world.at, parent, operation, 5000)
    == Ok(Ok(1))

  // A message into the child goes to the session the child runs in, which the
  // pair's session would have refused.
  assert orchestrator_port.ask_send(
      world.at,
      parent,
      world.handle,
      "m1",
      "also the tests",
      5000,
    )
    == Ok(Ok(json.Null))
  assert journal_is(world, [
    Resolved(world.child),
    Spawned(True),
    Ended,
    Messaged("also the tests"),
  ])
  stop(world)
}

pub fn an_executor_that_is_silent_when_asked_for_the_commits_is_asked_again_test() {
  let asks = cell.new(0)
  let world = world("seed-exec-silent", Small, SilentCapture(asks, 2), False)
  let tree = executor_rig.tree_of(world.plane, 1)
  let assert Ok(Ok(_spawned)) = ask_spawn(world)
  let tip = state_rig.commit_file(tree, "child.txt", "mine\n", "child work")
  cell.update(world.finished, fn(_) { True })

  // Two joins get no answer from the executor and report the child unfinished,
  // with its session kept. The third gets the commits.
  let assert remote_spawn.Ready(state: Some(returned), ..) =
    finished_entry(world)
  assert returned.tip == tip
  assert cell.get(asks) == 3
  assert journal_is(world, [
    Resolved(world.child),
    Spawned(True),
    Released(world.child),
  ])
  stop(world)
}

pub fn an_executor_that_never_answers_leaves_the_child_unfinished_and_its_session_kept_test() {
  let asks = cell.new(0)
  let world = world("seed-exec-mute", Small, SilentCapture(asks, 100), False)
  let assert Ok(Ok(_spawned)) = ask_spawn(world)
  cell.update(world.finished, fn(_) { True })

  // The executor answers nothing for more tries than a directory child is given.
  // A child with a session of its own is not given up on, because giving up ends
  // the session and with it the commits that are still on the executor: it stays
  // unfinished, and its session is kept, until its run ends or its parent goes.
  let waited =
    poll.until(within: 60_000, every: 100, attempt: fn() {
      let entry = ask_join(world)
      case cell.get(asks) > spawn_return.max_attempts {
        True -> poll.Done(entry)
        False -> poll.Retry
      }
    })
  let assert poll.Answered(entry) = waited
    as "the executor was asked many times"
  assert entry == remote_spawn.Pending(world.handle, spawn_return.wait_ms)
  assert journal_is(world, [Resolved(world.child), Spawned(True)])

  // The waiting is bounded by time. Once the first verdict is older than the
  // window the join gives up with the child's report and says where the commits
  // still are, and the session is ended.
  let records = world.receiver.state_root <> "/" <> spawn_return.directory_name
  let assert Ok(names) = simplifile.read_directory(records)
  list.each(names, fn(name) {
    case string.ends_with(name, ".verdict") {
      True -> {
        let assert Ok(text) = simplifile.read(records <> "/" <> name)
        let assert [before, rest] = string.split(text, "\"since\":")
        let assert Ok(#(_old, after)) = string.split_once(rest, "}")
        let assert Ok(Nil) =
          simplifile.write(
            records <> "/" <> name,
            before <> "\"since\":1}" <> after,
          )
        Nil
      }
      False -> Nil
    }
  })
  let gave_up =
    poll.until(within: 30_000, every: 100, attempt: fn() {
      case ask_join(world) {
        remote_spawn.Ready(..) as ready -> poll.Done(ready)
        remote_spawn.Pending(..) -> poll.Retry
      }
    })
  let assert poll.Answered(remote_spawn.Ready(report:, state: None, ..)) =
    gave_up
    as "the join gives up once the window has passed"
  assert string.contains(report, "on the executor `runner`")
  assert string.contains(report, "on the branch `loom/")
  assert journal_is(world, [
    Resolved(world.child),
    Spawned(True),
    Released(world.child),
  ])
  stop(world)
}

pub fn a_session_that_cannot_be_read_is_asked_again_and_never_started_unseeded_test() {
  let world = world("seed-exec-unreadable", Small, Steady, False)
  let tree = executor_rig.tree_of(world.plane, 1)
  let head = worktree_rig.git(tree, ["rev-parse", "HEAD"])
  cell.update(world.unreadable, fn(_) { True })

  // The session's record cannot be read, so it is not known whether it has
  // begun. Nothing is applied, the child is not started, and the sender is told
  // to ask again.
  let assert Ok(Error(remote_spawn.NotYetOpen(_))) = ask_spawn(world)
  assert cell.get(world.applies) == 0
  assert worktree_rig.git(tree, ["rev-parse", "HEAD"]) == head
  assert journal_is(world, [Resolved(world.child)])

  // Once it can be read, the resend puts the workspace in and starts the child.
  cell.update(world.unreadable, fn(_) { False })
  let assert Ok(Ok(_spawned)) = ask_spawn(world)
  assert cell.get(world.applies) == 1
  assert journal_is(world, [Resolved(world.child), Spawned(True)])
  stop(world)
}

pub fn an_executor_with_no_room_is_asked_again_and_keeps_no_verdict_test() {
  let sends = cell.new(0)
  let world = world("seed-exec-noroom", Small, NoRoomOnce(sends), False)

  // The executor's store has no room for the first piece. That is not about the
  // state: the session stays, no verdict is kept, and the resend succeeds.
  let assert Ok(Error(remote_spawn.NotYetOpen(_))) = ask_spawn(world)
  assert journal_is(world, [Resolved(world.child)])
  let assert Ok(Ok(_spawned)) = ask_spawn(world)
  assert journal_is(world, [Resolved(world.child), Spawned(True)])
  stop(world)
}

pub fn a_fence_that_moved_is_asked_again_and_keeps_no_verdict_test() {
  let asks = cell.new(0)
  let world = world("seed-exec-stale", Small, StaleFenceOnce(asks), False)
  let assert Ok(Error(remote_spawn.NotYetOpen(_))) = ask_spawn(world)
  assert journal_is(world, [Resolved(world.child)])
  let assert Ok(Ok(_spawned)) = ask_spawn(world)
  assert cell.get(asks) == 2
  assert journal_is(world, [Resolved(world.child), Spawned(True)])
  stop(world)
}

pub fn a_refusal_of_the_content_is_kept_and_ends_the_session_test() {
  let world = world("seed-exec-sticks", Small, ApplyRefused, False)

  // The workspace says no to the state. The refusal is kept, so the resend is
  // answered with it and no second apply is sent, and the session is ended.
  let assert Ok(Error(remote_spawn.StateRefused(reason))) = ask_spawn(world)
  assert string.contains(reason, "does not take this state")
  assert journal_is(world, [Resolved(world.child), Released(world.child)])

  // The resend is answered with the kept refusal and applies nothing. It also ends
  // the session again, which is what an ask that arrives between the verdict and
  // the end of the session needs, and which does nothing when the session is gone.
  let assert Ok(Error(remote_spawn.StateRefused(again))) = ask_spawn(world)
  assert again == reason
  assert cell.get(world.applies) == 1
  assert journal_is(world, [
    Resolved(world.child),
    Released(world.child),
    Released(world.child),
  ])
  stop(world)
}

pub fn only_a_refusal_about_the_state_is_final_test() {
  // The workspace's own refusals are about the content, and asking again gets the
  // same.
  assert is_final(protocol.ExecutorFault("a refusal"))
  assert is_final(protocol.NoStates("no Git"))

  // A fence that moved, a scope that is closing or being built, and a plane to
  // attach again are about the session, and asking again after it attaches can
  // succeed.
  assert !is_final(protocol.StaleToken)
  assert !is_final(protocol.StaleIncarnation(stored: 3))
  assert !is_final(protocol.ScopeNotOpen)
  assert !is_final(protocol.PlaneBuilding)
  assert !is_final(protocol.NoPlane("restarted"))
}

fn is_final(refusal: protocol.Refusal) -> Bool {
  case remote_workspace.failed_by(refusal) {
    session_states.Final(..) -> True
    session_states.Later(..) -> False
  }
}

pub fn a_child_that_began_while_the_apply_was_on_its_way_is_not_refused_test() {
  let world = world("seed-exec-begun-at-apply", Small, BegunAtApply, False)

  // The check made at the request and the one made before it mean the same: the
  // session has begun, so a resend of a spawn that went through is answered, and
  // no verdict is kept and no session is ended.
  let assert Ok(Ok(_spawned)) = ask_spawn(world)
  assert cell.get(world.applies) == 0
  let assert Ok(Ok(_again)) = ask_spawn(world)
  assert !list.contains(cell.get(world.journal), Released(world.child))
  stop(world)
}

pub fn a_store_failure_after_the_spawn_was_admitted_ends_the_session_test() {
  let world = world("seed-exec-store-failure", Small, Steady, False)
  cell.update(world.refuse_spawn, fn(_) {
    Some(remote_spawn.StoreFailure(reason: "the catalogue could not answer"))
  })

  // The sender takes a store failure as final, so no ask follows to use the
  // session, and it is ended rather than held until the parent is deleted.
  let assert Ok(Error(remote_spawn.StoreFailure(..))) = ask_spawn(world)
  assert journal_is(world, [Resolved(world.child), Released(world.child)])
  stop(world)
}

pub fn a_spawn_that_asks_to_come_again_keeps_its_session_test() {
  let world = world("seed-exec-ask-again", Small, Steady, False)
  cell.update(world.refuse_spawn, fn(_) {
    Some(remote_spawn.NotYetOpen(reason: "the session is still opening"))
  })

  // The sender asks again, so the session stays for that ask.
  let assert Ok(Error(remote_spawn.NotYetOpen(..))) = ask_spawn(world)
  assert journal_is(world, [Resolved(world.child)])
  stop(world)
}

pub fn a_session_that_could_not_be_started_is_ended_unless_it_asks_to_come_again_test() {
  let world = world("seed-exec-resolve-fails", Small, Steady, False)
  cell.update(world.refuse_resolve, fn(_) {
    Some(remote_spawn.StoreFailure(reason: "the session failed to start"))
  })

  // The row exists and the session did not start, and the sender will not ask
  // again, so the row is ended.
  let assert Ok(Error(remote_spawn.StoreFailure(..))) = ask_spawn(world)
  assert journal_is(world, [Resolved(world.child), Released(world.child)])

  // A start that asks to come again leaves the row for that ask.
  cell.update(world.refuse_resolve, fn(_) {
    Some(remote_spawn.NotYetOpen(reason: "the session is opening"))
  })
  let assert Ok(Error(remote_spawn.NotYetOpen(..))) = ask_spawn(world)
  assert journal_is(world, [
    Resolved(world.child),
    Released(world.child),
    Resolved(world.child),
  ])
  stop(world)
}

pub fn the_end_of_a_run_stops_the_children_whatever_becomes_of_the_pairs_session_test() {
  let world = world("seed-exec-run-end-cap", Small, Steady, False)
  let parent = remote_spawn.Parent(session: session(9), strand: "main")
  let assert Ok(Ok(_spawned)) = ask_spawn(world)

  // Seeded children fill the spawner's cap, so the pair's session cannot be made.
  cell.update(world.refuse_pair, fn(_) {
    Some(remote_spawn.CapReached(remote_spawn.MaxSessions, 4))
  })
  let #(operation, _) = ids.mint_op(ids.generator(clock.fixed(at: 5), seed: 9))
  assert orchestrator_port.ask_run_ended(world.at, parent, operation, 5000)
    == Ok(Error(remote_spawn.CapReached(remote_spawn.MaxSessions, 4)))

  // The child was stopped all the same, and its session is kept so that a join
  // can still bring its commits back.
  assert journal_is(world, [Resolved(world.child), Spawned(True), Ended])
  stop(world)
}

pub fn applies_of_one_state_by_sessions_sharing_a_repository_all_succeed_test() {
  let world = world("seed-exec-race", Small, Steady, False)
  let state = world.parent.sent

  // Four sessions of one executor, each with a worktree of the one repository,
  // are given the one state, which several children seeded from one parent carry.
  let sessions = [
    world.attached,
    executor_rig.attach(world.plane, 2, "runner"),
    executor_rig.attach(world.plane, 3, "runner"),
    executor_rig.attach(world.plane, 4, "runner"),
  ]
  assert state_transfer.send(
      world.parent.store,
      state.hash,
      world.attached.states.link,
    )
    == state_transfer.Delivered

  // They apply at once. The ref that names the state is made once and every apply
  // finds it made, whichever got there first, so none is refused and each tree is
  // on the tip.
  let replies = process.new_subject()
  list.each(sessions, fn(each) {
    let _asker =
      process.spawn(fn() { process.send(replies, each.states.apply(state)) })
    Nil
  })
  list.each(sessions, fn(_each) {
    let assert Ok(answer) = process.receive(replies, 120_000)
      as "every apply answers"
    assert answer == Ok(state.tip)
  })
  stop(world)
}

pub fn a_failure_after_the_child_began_does_not_end_the_session_of_a_running_child_test() {
  let world = world("seed-exec-begun-failure", Small, Steady, False)
  let assert Ok(Ok(_spawned)) = ask_spawn(world)

  // The sender asks again and the Agency fails to answer with a store failure. The
  // child is running in its session, so the session is not ended: the sender is
  // asked to come again and is answered by the child it already has.
  cell.update(world.refuse_spawn, fn(_) {
    Some(remote_spawn.StoreFailure(reason: "the catalogue could not answer"))
  })
  let assert Ok(Error(remote_spawn.NotYetOpen(..))) = ask_spawn(world)
  assert !list.contains(cell.get(world.journal), Released(world.child))
  stop(world)
}
