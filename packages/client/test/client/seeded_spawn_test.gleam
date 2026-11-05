//// A spawn that carries the parent's workspace, over a real port, a real store on
//// each side and a real repository (protocol-change/107, slice 3).
////
//// The parent's side is `remote_spawner.asked_with_state`, the step the Agency's
//// spawn goes through for a request that names a state. The receiver is an
//// orchestrator port in this VM whose spawn host is the daemon's own
//// (`main.spawn_host_seeding`) with `spawn_seed.receive` as its judge, and whose
//// delegate session is a recording stub: what the Agency would be asked to start
//// is what the tests look at. The default case is here too, because the property
//// that matters most is that a spawn that asks for nothing is the spawn it was.

import broker/exec
import client/agency
import client/daemon/main
import client/delegate_host
import client/internal/ffi_os
import client/remote/address.{Address}
import client/remote/orchestrator_port
import client/remote/remote_spawner
import client/remote_spawn
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
import gleam/erlang/atom
import gleam/erlang/node
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import simplifile
import support/state_rig.{type Rig}
import support/worktree_rig
import telemetry/field
import telemetry/level
import telemetry/log
import telemetry/record.{type Record}
import tools/agent

// The receiver's machine, and the records its node wrote.
type Receiver {
  Receiver(node: state_node.StateNode, root: String, logs: Subject(Record))
}

fn receiver_at(rig: Rig) -> Receiver {
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
  let logs = process.new_subject()
  Receiver(
    node: state_node.StateNode(
      endpoint: state_service.endpoint(service),
      store: Some(store),
      git: Some(git),
      state_root: root,
      credentials: [],
      logger: log.new(sink: log.to_subject(logs), threshold: level.Info),
    ),
    root:,
    logs:,
  )
}

fn spawner(directory: String, seed: String) -> Spawner {
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
seed = \"" <> seed <> "\"
"
  let assert Ok([found]) = spawners.parse(text) as "the table parses"
  found
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

fn request(state: option.Option(State)) -> remote_spawn.Request {
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

// What the delegate session's Agency was asked to start.
fn recording(heard: Subject(remote_spawn.Request)) -> agency.DelegateEndpoint {
  agency.DelegateEndpoint(
    fresh: fn() { True },
    states: None,
    spawn: fn(_delegation, _site, request) {
      process.send(heard, request)
      Ok(remote_spawn.Spawned(
        handle: agent.Handle(strand: "sub:^main/finish-the-cache", operation: {
          let #(op, _) = ids.mint_op(ids.generator(clock.fixed(at: 1), seed: 9))
          op
        }),
        tools: ["bash"],
        model: "cheap",
        model_id: "cheap-1",
        remaining_ms: 60_000,
      ))
    },
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

fn unused() -> remote_spawn.SpawnRefusal {
  remote_spawn.StoreFailure(reason: "not under test")
}

// The receiver's port, serving spawns with the daemon's own host.
fn port_for(
  receiver: Receiver,
  table: Spawner,
  heard: Subject(remote_spawn.Request),
) -> address.Address(orchestrator_port.Message) {
  let name = process.new_name("seeded_spawn_port")
  let host =
    main.spawn_host_seeding(
      [spawners.Spawner(..table, node: node_name())],
      fn(_spawner, _parent) { Ok(recording(heard)) },
      fn(_spawner, _parent) { Ok(0) },
      fn(_spawner, _parent) { Ok(None) },
      delegate_host.no_children(),
      fn(found, parent, call_site, asked) {
        spawn_seed.land(
          receiver.node,
          delegate_host.no_children(),
          found,
          parent,
          call_site,
          asked,
        )
      },
      spawn_return.none(),
      log.discard(),
    )
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
      receiver.node.endpoint,
    )
  Address(node: node.self(), name:)
}

// The node name this VM answers to, which the port reads as the sender's.
fn node_name() -> String {
  atom.to_string(node.name(node.self()))
}

// The parent's workspace, edited and captured into its own store.
fn parent(name: String) -> #(Rig, state_store.Store, State) {
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
  let capturer =
    state_capture.new(
      rig.git,
      rig.state,
      [],
      state_service.endpoint(service),
      store,
    )
  let assert Ok(state) =
    state_capture.capture(capturer, rig.root, state_rig.identity(), Full)
  #(rig, store, state)
}

fn ask(
  store: state_store.Store,
  at: address.Address(orchestrator_port.Message),
  asked: remote_spawn.Request,
) {
  ask_logging(store, at, asked, log.discard())
}

fn ask_logging(
  store: state_store.Store,
  at: address.Address(orchestrator_port.Message),
  asked: remote_spawn.Request,
  logger: log.Logger,
) {
  remote_spawner.asked_with_state(
    Some(store),
    at,
    remote_spawn.Parent(session: "s1", strand: "main"),
    site(),
    0,
    ["bash"],
    asked,
    30_000,
    logger,
  )
}

pub fn a_spawn_with_a_state_sends_it_and_the_child_starts_from_the_copy_test() {
  let #(rig, store, state) = parent("seeded-whole")
  let receiver = receiver_at(rig)
  let directory = rig.scratch <> "/scratch-dir"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
  let heard = process.new_subject()
  let at = port_for(receiver, spawner(directory, "workspace"), heard)
  let refs = state_rig.refs(rig.root)

  // One ask, which the receiver answers with how much it holds; the sender
  // sends the rest and asks again; the second ask is answered with the child.
  let assert Ok(Ok(spawned)) = ask(store, at, request(Some(state)))
  assert spawned.model == "cheap"
  let assert Ok(started) = process.receive(heard, 1000)
  assert started.state == None
  let name = spawn_seed.name_of(site(), state)
  assert string.contains(started.brief, "seeds/" <> name)
  let copy = directory <> "/seeds/" <> name
  assert simplifile.read(copy <> "/README") == Ok("edited by the parent\n")
  assert simplifile.read(copy <> "/notes.txt") == Ok("not committed anywhere\n")

  // The state is in the receiver's store whole, and the parent's checkout is
  // exactly what it was.
  assert receiver.node.endpoint.stage(state.hash) == Ok(state_transfer.Complete)
  assert state_rig.refs(rig.root) == refs

  // The same spawn sent again is answered with the same child and makes no
  // second copy.
  let assert Ok(Ok(_again)) = ask(store, at, request(Some(state)))
  let assert Ok(resent) = process.receive(heard, 1000)
  assert resent.brief == started.brief
  state_rig.stop(rig)
}

pub fn a_spawner_whose_seed_is_none_is_refused_and_nothing_is_sent_test() {
  let #(rig, store, state) = parent("seeded-none")
  let receiver = receiver_at(rig)
  let directory = rig.scratch <> "/scratch-dir"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
  let heard = process.new_subject()
  let at = port_for(receiver, spawner(directory, "none"), heard)

  let assert Ok(Error(remote_spawn.StateRefused(reason))) =
    ask(store, at, request(Some(state)))
  assert string.contains(reason, "seed")

  // The refusal came before any byte was stored or any child asked for.
  assert receiver.node.endpoint.stage(state.hash) == Ok(state_transfer.Absent)
  assert process.receive(heard, 100) == Error(Nil)
  state_rig.stop(rig)
}

pub fn a_spawn_with_no_state_is_the_spawn_it_always_was_test() {
  let rig = state_rig.rig("seeded-default")
  let receiver = receiver_at(rig)
  let directory = rig.scratch <> "/scratch-dir"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
  let heard = process.new_subject()
  let at = port_for(receiver, spawner(directory, "none"), heard)
  let assert Ok(store) =
    state_store.open(
      state_store.directory(rig.state),
      state_store.default_limits,
    )
  let plain = request(None)
  let assert Ok(Ok(_spawned)) = ask(store, at, plain)

  // The Agency was asked for exactly the request that was sent: no state, the
  // brief as written, and no directory made.
  assert process.receive(heard, 1000) == Ok(plain)
  assert simplifile.is_directory(directory <> "/seeds") != Ok(True)
  state_rig.stop(rig)
}

pub fn a_state_the_sender_no_longer_holds_is_refused_for_good_test() {
  let #(rig, store, state) = parent("seeded-lost")
  let receiver = receiver_at(rig)
  let directory = rig.scratch <> "/scratch-dir"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
  let heard = process.new_subject()
  let at = port_for(receiver, spawner(directory, "workspace"), heard)

  // The bundle is gone from the sender's store, as retention can leave it.
  let assert Ok(Some(held)) = state_store.get(store, state.hash)
  let assert Ok(Nil) = simplifile.delete(held.path)
  let assert Ok(Error(remote_spawn.StateRefused(_))) =
    ask(store, at, request(Some(state)))
  state_rig.stop(rig)
}

// The text of one field of a record, or the empty string.
fn field_of(entry: Record, key: String) -> String {
  case list.find(entry.fields, fn(one) { one.key == key }) {
    Ok(field.Field(value: field.Text(text), ..))
    | Ok(field.Field(value: field.Ident(text), ..)) -> text
    Ok(field.Field(value: field.Count(number), ..)) -> int.to_string(number)
    _ -> ""
  }
}

// What each side says about a state that went across, once, and no more than
// the sizes and short names an operator needs to read it by.
pub fn each_side_says_once_that_the_state_arrived_test() {
  let #(rig, store, state) = parent("seeded-logs")
  let receiver = receiver_at(rig)
  let directory = rig.scratch <> "/scratch-dir"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
  let heard = process.new_subject()
  let at = port_for(receiver, spawner(directory, "workspace"), heard)
  let sender_logs = process.new_subject()
  let logger = log.new(sink: log.to_subject(sender_logs), threshold: level.Info)

  let assert Ok(Ok(_spawned)) =
    ask_logging(store, at, request(Some(state)), logger)

  // The sender's line names the state and the bytes it moved.
  let assert Ok(sent) = process.receive(sender_logs, 1000)
  assert sent.event == "remote_spawn.state_sent"
  assert field_of(sent, "state") == state_object.short(state.hash)
  assert field_of(sent, "bytes") == int.to_string(state.size)

  // The receiver's line names the same state, the spawner and the copy.
  let assert Ok(placed) = process.receive(receiver.logs, 1000)
  assert placed.event == "remote_spawn.seed_placed"
  assert field_of(placed, "state") == state_object.short(state.hash)
  assert field_of(placed, "bytes") == int.to_string(state.size)
  assert field_of(placed, "spawner") == "laptop"
  assert field_of(placed, "seed") == spawn_seed.name_of(site(), state)
  assert !string.contains(string.inspect(placed), directory)

  // A resend finds the state and the copy already there, and says nothing more.
  let assert Ok(Ok(_again)) =
    ask_logging(store, at, request(Some(state)), logger)
  assert process.receive(sender_logs, 100) == Error(Nil)
  assert process.receive(receiver.logs, 100) == Error(Nil)
  state_rig.stop(rig)
}
