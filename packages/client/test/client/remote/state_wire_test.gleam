//// Repository states cross the two carriers (protocol-change/107): the executor
//// host and the orchestrator port. Each carrier is started over the one process
//// that owns a real store (`client/state_service`), and the tests reach it through
//// the links a transfer drives (`client/remote/state_link`), so a piece goes
//// through the closed message type, the carrier's own run, the owner's turn and
//// the store's files. The host's attach check and its capture fence are tested
//// here too, since the version bump and the capture message are the same change.

import client/internal/ffi_os
import client/remote/address.{type Address, Address}
import client/remote/host
import client/remote/orchestrator_port
import client/remote/protocol
import client/remote/state_link
import client/state_object.{
  type State, Clean, CommittedOnly, Dirty, Full, State, Thin, WithWorkingTree,
}
import client/state_service
import client/state_store.{type Store}
import client/state_transfer.{
  type Link, Absent, Complete, Declined, Delivered, Partial, Silent,
}
import gleam/bit_array
import gleam/erlang/node
import gleam/erlang/process
import gleam/option.{type Option, None, Some}
import gleam/string
import host/bootstrap
import simplifile
import support/remote_fixtures as fixtures

const chunk = 262_144

const size = 655_360

fn now() -> Int {
  bootstrap.system_time_ms() / 1000
}

fn scratch(name: String) -> String {
  let directory =
    "build/state-wire-"
    <> name
    <> "-"
    <> string.inspect(ffi_os.unique_positive_integer())
  let _removed = simplifile.delete(directory)
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
  let assert Ok(canonical) = bootstrap.canonical_directory(directory)
  canonical
}

fn open(root: String) -> Store {
  let assert Ok(store) =
    state_store.open(
      state_store.directory(root),
      state_store.Limits(
        size_limit: 1_000_000,
        total_cap: 3_000_000,
        retain_s: 3600,
      ),
    )
  store
}

fn payload(length: Int) -> BitArray {
  let text = string.repeat("0123456789abcdef-", length / 16 + 1)
  let assert Ok(bytes) = bit_array.slice(bit_array.from_string(text), 0, length)
  bytes
}

// A state in a sender's store, put there as a capture's bundle would be.
fn held(store: Store, root: String) -> State {
  let path = root <> "/bundle"
  let assert Ok(Nil) = simplifile.write_bits(path, payload(size))
  let assert Ok(state) =
    state_store.put(
      store,
      path,
      tip: "0123456789abcdef0123456789abcdef01234567",
      base: None,
      dirty: Clean,
      now_s: now(),
    )
  state
}

// An endpoint over a store, owned by a service of its own.
fn serving(store: Store) -> state_transfer.Endpoint {
  let assert Ok(service) = state_service.start(store, now)
  state_service.endpoint(service)
}

fn local(store: Store) -> Link {
  state_transfer.Link(
    stage: fn(hash) {
      case state_transfer.stage(store, hash) {
        Ok(stage) -> Ok(stage)
        Error(_) -> Error(Nil)
      }
    },
    piece: fn(piece) { Ok(state_transfer.take(store, piece, now())) },
    fetch: fn(hash, offset) { Ok(state_transfer.serve(store, hash, offset)) },
  )
}

fn contents(store: Store, hash: String) -> BitArray {
  let assert Ok(Some(found)) = state_store.get(store, hash)
  let assert Ok(bytes) = simplifile.read_bits(found.path)
  bytes
}

// --- the host ---------------------------------------------------------------

fn started(
  states: state_transfer.Endpoint,
  factory: host.PlaneFactory(String),
) -> Address(protocol.HostMessage(String)) {
  let path = fixtures.scratch("state-host") <> "/ledger.db"
  let config = host.Config(..fixtures.host_config(path, factory), states:)
  let assert Ok(running) = host.start(config) as "the host starts"
  running.data
}

fn plain_factory() -> host.PlaneFactory(String) {
  fixtures.factory(
    fixtures.probe(fixtures.Open),
    fixtures.AsksNothing,
    protocol.AllRetired,
  )
}

fn attach(
  at: Address(protocol.HostMessage(String)),
  version: Int,
  token: BitArray,
) -> Result(protocol.Attached(String), protocol.Refusal) {
  let reply = process.new_subject()
  address.deliver(
    at,
    protocol.Attach(
      version:,
      session: "s1",
      workspace: "/work",
      incarnation: 0,
      token:,
      owner_port: fixtures.plan_port(),
      reply:,
    ),
  )
  let assert Ok(answer) = process.receive(reply, 5000)
    as "the host answers an attach"
  answer
}

fn capture(
  at: Address(protocol.HostMessage(String)),
  token: BitArray,
  basis: state_object.Basis,
) -> Result(Option(State), protocol.Refusal) {
  capture_content(at, token, basis, WithWorkingTree)
}

fn capture_content(
  at: Address(protocol.HostMessage(String)),
  token: BitArray,
  basis: state_object.Basis,
  content: state_object.Content,
) -> Result(Option(State), protocol.Refusal) {
  let reply = process.new_subject()
  address.deliver(
    at,
    protocol.StateCapture(
      session: "s1",
      incarnation: 0,
      token:,
      basis:,
      content:,
      reply:,
    ),
  )
  let assert Ok(answer) = process.receive(reply, 5000)
    as "the host answers a capture"
  answer
}

fn apply(
  at: Address(protocol.HostMessage(String)),
  incarnation: Int,
  token: BitArray,
  state: State,
) -> Result(String, protocol.Refusal) {
  let reply = process.new_subject()
  address.deliver(
    at,
    protocol.StateApply(session: "s1", incarnation:, token:, state:, reply:),
  )
  let assert Ok(answer) = process.receive(reply, 5000)
    as "the host answers an apply"
  answer
}

// Version 7 (protocol-change/110) added the host seam to the MCP plan and
// left the state messages as version 6 made them.
pub fn the_vocabulary_is_at_version_seven_test() {
  assert protocol.version == 7
}

pub fn an_attach_from_a_version_five_peer_is_refused_test() {
  let at = started(state_transfer.declining(), plain_factory())

  // A peer of the version before the state messages never gets past the attach,
  // so it never sends a message the host cannot match.
  assert attach(at, 5, <<1>>)
    == Error(protocol.VersionMismatch(supported: protocol.version))
  let assert Ok(_attached) = attach(at, protocol.version, <<1>>)
}

pub fn a_state_is_sent_to_a_host_and_held_there_test() {
  let sender_root = scratch("host-from")
  let receiver_root = scratch("host-to")
  let sender = open(sender_root)
  let receiver = open(receiver_root)
  let state = held(sender, sender_root)
  let at = started(serving(receiver), plain_factory())
  let link = state_link.via_host(at, 5000)

  assert state_transfer.send(sender, state.hash, link) == Delivered
  assert contents(receiver, state.hash) == payload(size)

  // The host also serves what it holds, so the orchestrator can relay it on.
  let pulled = open(scratch("host-pulled"))
  let endpoint = state_transfer.endpoint(pulled, now)
  assert state_transfer.pull(endpoint, state.hash, from: link) == Delivered
  assert contents(pulled, state.hash) == payload(size)
}

pub fn a_transfer_to_a_host_resumes_after_a_drop_test() {
  let sender_root = scratch("host-drop-from")
  let sender = open(sender_root)
  let receiver = open(scratch("host-drop-to"))
  let state = held(sender, sender_root)
  let at = started(serving(receiver), plain_factory())
  let live = state_link.via_host(at, 5000)

  // The link goes silent once the host holds a piece.
  let dropping =
    state_transfer.Link(..live, piece: fn(piece) {
      case state_store.staged_bytes(receiver, state.hash) {
        Ok(held) if held >= chunk -> Error(Nil)
        _ -> live.piece(piece)
      }
    })
  assert state_transfer.send(sender, state.hash, dropping) == Silent
  assert live.stage(state.hash) == Ok(Partial(chunk))
  assert state_transfer.send(sender, state.hash, live) == Delivered
  assert live.stage(state.hash) == Ok(Complete)
}

pub fn a_restarted_node_resumes_from_the_bytes_its_store_holds_test() {
  let sender_root = scratch("restart-from")
  let receiver_root = scratch("restart-to")
  let sender = open(sender_root)
  let state = held(sender, sender_root)

  // The first incarnation of the node takes the first piece and then goes away.
  let first = open(receiver_root)
  let before =
    state_link.via_host(started(serving(first), plain_factory()), 5000)
  let dropping =
    state_transfer.Link(..before, piece: fn(piece) {
      case state_store.staged_bytes(first, state.hash) {
        Ok(held) if held >= chunk -> Error(Nil)
        _ -> before.piece(piece)
      }
    })
  assert state_transfer.send(sender, state.hash, dropping) == Silent

  // The next incarnation opens the same directory under a new owner, and a host
  // of its own. What the first one wrote is what the second one reports.
  let second = open(receiver_root)
  let after =
    state_link.via_host(started(serving(second), plain_factory()), 5000)
  assert after.stage(state.hash) == Ok(Partial(chunk))
  assert state_transfer.send(sender, state.hash, after) == Delivered
  assert contents(second, state.hash) == payload(size)
}

pub fn a_host_that_keeps_no_store_refuses_every_piece_test() {
  let sender_root = scratch("host-none-from")
  let sender = open(sender_root)
  let state = held(sender, sender_root)
  let at = started(state_transfer.declining(), plain_factory())
  let link = state_link.via_host(at, 5000)

  assert link.stage(state.hash) == Ok(Absent)
  assert state_transfer.send(sender, state.hash, link)
    == Declined(state_transfer.NotServing)
}

pub fn a_capture_for_a_scope_with_no_plane_capture_is_refused_test() {
  let at = started(state_transfer.declining(), plain_factory())
  let assert Ok(_attached) = attach(at, protocol.version, <<1>>)

  let assert Error(protocol.NoStates(_)) = capture(at, <<1>>, Full)
}

pub fn a_capture_is_fenced_and_runs_the_planes_capture_test() {
  let probe = fixtures.probe(fixtures.Open)
  let base = fixtures.factory(probe, fixtures.AsksNothing, protocol.AllRetired)
  let described =
    State(
      hash: state_object.hash_of(<<"bundle">>),
      size: 6,
      tip: "0123456789abcdef0123456789abcdef01234567",
      base: Some("89abcdef0123456789abcdef0123456789abcdef"),
      dirty: Clean,
    )

  // The plane's capture answers the description for a thin basis it is given,
  // and refuses the workspace for a full one.
  let capturing =
    host.Capturing(
      capture: fn(basis, content) {
        case basis, content {
          Thin(base:), WithWorkingTree ->
            Ok(Some(State(..described, base: Some(base))))
          Thin(..), CommittedOnly -> Ok(None)
          Full, _ -> Error("the repository has a submodule")
        }
      },
      apply: fn(state) {
        case state.dirty {
          Clean -> Ok(state.tip)
          Dirty -> Error("the tree holds changes")
        }
      },
    )
  let factory = fn(spec) {
    case base(spec) {
      Ok(plane) -> Ok(host.Plane(..plane, state: Some(capturing)))
      Error(failure) -> Error(failure)
    }
  }
  let at = started(state_transfer.declining(), factory)

  // Before any attach there is no scope to capture from.
  let assert Error(_nothing) = capture(at, <<1>>, Full)
  let assert Ok(_attached) = attach(at, protocol.version, <<1>>)
  assert capture(
      at,
      <<1>>,
      Thin(base: "89abcdef0123456789abcdef0123456789abcdef"),
    )
    == Ok(Some(
      State(..described, base: Some("89abcdef0123456789abcdef0123456789abcdef")),
    ))
  assert capture(at, <<1>>, Full)
    == Error(protocol.ExecutorFault("the repository has a submodule"))

  // The content reaches the plane, and a capture of commits with nothing beyond
  // its base is an answer of no state, not a refusal.
  assert capture_content(
      at,
      <<1>>,
      Thin(base: "89abcdef0123456789abcdef0123456789abcdef"),
      CommittedOnly,
    )
    == Ok(None)

  // A request under another attach's token is from a dead runtime.
  assert capture(at, <<2>>, Full) == Error(protocol.StaleToken)
  assert capture_content(at, <<2>>, Full, CommittedOnly)
    == Error(protocol.StaleToken)
}

pub fn an_apply_for_a_scope_with_no_plane_apply_is_refused_test() {
  let at = started(state_transfer.declining(), plain_factory())
  let wanted = a_state()

  // Before any attach the scope does not exist, and after one this plane has
  // no means of applying.
  let assert Error(_nothing) = apply(at, 0, <<1>>, wanted)
  let assert Ok(_attached) = attach(at, protocol.version, <<1>>)
  let assert Error(protocol.NoStates(_)) = apply(at, 0, <<1>>, wanted)
}

pub fn an_apply_is_fenced_and_runs_the_planes_apply_test() {
  let probe = fixtures.probe(fixtures.Open)
  let base = fixtures.factory(probe, fixtures.AsksNothing, protocol.AllRetired)
  let capturing =
    host.Capturing(capture: fn(_basis, _content) { Ok(None) }, apply: fn(state) {
      case state.dirty {
        Clean -> Ok(state.tip)
        Dirty -> Error("the tree holds changes")
      }
    })
  let factory = fn(spec) {
    case base(spec) {
      Ok(plane) -> Ok(host.Plane(..plane, state: Some(capturing)))
      Error(failure) -> Error(failure)
    }
  }
  let at = started(state_transfer.declining(), factory)
  let wanted = a_state()
  let assert Ok(_attached) = attach(at, protocol.version, <<1>>)

  // The plane's tip is the answer, and its refusal is the executor's own account
  // of why the workspace would not take the state, as a refused capture is.
  assert apply(at, 0, <<1>>, wanted) == Ok(wanted.tip)
  assert apply(at, 0, <<1>>, State(..wanted, dirty: Dirty))
    == Error(protocol.ExecutorFault("the tree holds changes"))

  // A request under another attach's token, or another incarnation, is from a
  // dead runtime, and the plane is never asked.
  assert apply(at, 0, <<2>>, wanted) == Error(protocol.StaleToken)
  let assert Error(protocol.StaleIncarnation(stored: 0)) =
    apply(at, 1, <<1>>, wanted)
}

fn a_state() -> State {
  State(
    hash: state_object.hash_of(<<"bundle">>),
    size: 6,
    tip: "0123456789abcdef0123456789abcdef01234567",
    base: None,
    dirty: Clean,
  )
}

// --- the port ---------------------------------------------------------------

fn port_over(
  states: state_transfer.Endpoint,
) -> Address(orchestrator_port.Message) {
  let name = process.new_name("state_wire_port")
  let assert Ok(_started) =
    orchestrator_port.start_with_states(
      name,
      fn(_session) { Ok(orchestrator_port.NotOwned) },
      fn(_session, _command) { Error(orchestrator_port.peer_unserved) },
      fn(_session) { Error(orchestrator_port.peer_unserved) },
      orchestrator_port.declining(),
      orchestrator_port.refusing_spawns(),
      orchestrator_port.refusing_children(),
      orchestrator_port.unheld,
      orchestrator_port.unreported(),
      orchestrator_port.refusing_top(),
      states,
    )
  Address(node: node.self(), name:)
}

pub fn a_state_is_sent_to_a_port_and_held_there_test() {
  let sender_root = scratch("port-from")
  let receiver_root = scratch("port-to")
  let sender = open(sender_root)
  let receiver = open(receiver_root)
  let state = held(sender, sender_root)
  let link = state_link.via_port(port_over(serving(receiver)), 5000)

  assert link.stage(state.hash) == Ok(Absent)
  assert state_transfer.send(sender, state.hash, link) == Delivered
  assert contents(receiver, state.hash) == payload(size)
  assert link.stage(state.hash) == Ok(Complete)
}

pub fn a_port_that_keeps_no_store_refuses_every_piece_test() {
  let sender_root = scratch("port-none-from")
  let sender = open(sender_root)
  let state = held(sender, sender_root)
  let link = state_link.via_port(port_over(state_transfer.declining()), 5000)

  assert state_transfer.send(sender, state.hash, link)
    == Declined(state_transfer.NotServing)
}

pub fn a_state_is_relayed_from_a_host_to_a_port_test() {
  let sender_root = scratch("relay-from")
  let sender = open(sender_root)
  let executor = open(scratch("relay-executor"))
  let target = open(scratch("relay-target"))
  let state = held(sender, sender_root)

  // The executor captured it, so its store holds it. The orchestrator copies it
  // to the target's port one piece at a time, holding no whole bundle.
  let from =
    state_link.via_host(started(serving(executor), plain_factory()), 5000)
  assert state_transfer.send(sender, state.hash, local(executor)) == Delivered
  let to = state_link.via_port(port_over(serving(target)), 5000)

  assert state_transfer.relay(state.hash, from:, to:) == Delivered
  assert contents(target, state.hash) == payload(size)
}

pub fn a_hash_that_is_not_one_is_refused_by_both_carriers_test() {
  let receiver = open(scratch("badhash"))
  let endpoint = serving(receiver)
  let port = state_link.via_port(port_over(endpoint), 5000)
  let host_link = state_link.via_host(started(endpoint, plain_factory()), 5000)

  // A status question is a read, and a name that could be a path is an error
  // and not an absence, which the link reports as silence.
  assert port.stage("../escape") == Error(Nil)
  assert host_link.stage("../escape") == Error(Nil)
}
