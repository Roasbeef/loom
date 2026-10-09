//// Two real runtimes joined by a scripted network, for the sender outbox's
//// tests.
////
//// The sender and the recipient each answer through `peer_mail.handle`, the
//// call the Agency actor makes, so rows are written to a real session store
//// and the recipient's receipts are real. What a test scripts is the network
//// between them: a `Script` stands in for the recipient's endpoint and says,
//// per delivery, whether nobody answers, whether the recipient commits and
//// the reply is lost, or whether the call reaches it.

import client/gateway_test
import client/peer_mail.{MayWake}
import client/peer_outbox
import client/peers
import core/clock
import core/ids
import core/json.{type JsonValue}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, Some}
import runtime/api
import weft/actor

// What the network does with one delivery.
pub type Mode {
  /// The call reaches the recipient and its answer comes back.
  Pass

  /// Nobody answers: the call never reaches the recipient.
  Down

  /// The recipient commits the message and its reply is lost.
  Lose
}

// The scripted network: the modes of the next deliveries in order, the mode
/// that follows them, whether the directory finds the recipient, and what has
/// happened so far.
pub type Script {
  Script(
    modes: List(Mode),
    then: Mode,
    resident: Residency,
    deliveries: Int,
    lookups: Int,
  )
}

/// Where the directory finds the recipient.
pub type Residency {
  /// Resident: the directory resolves it to its endpoint.
  Resident

  /// Held by its owner and not resident: the directory says `NotOpen`.
  Saved

  /// Held by no catalogue: the directory refuses it.
  Gone
}

pub type Step {
  NextMode(reply: Subject(Mode))
  Lookup(reply: Subject(Residency))
  SetResident(Residency)
  SetThen(Mode)
  Count(reply: Subject(#(Int, Int)))
}

pub type Rig {
  Rig(
    sender: api.Runtime,
    recipient: api.Runtime,
    sender_name: String,
    recipient_name: String,
    script: Subject(Step),
    wiring: peers.Wiring,
    source: peer_mail.Endpoint,
    target: peer_mail.Endpoint,
  )
}

pub fn session_id(seed: Int) -> ids.SessionId {
  let #(id, _) =
    ids.mint_session(ids.generator(clock.stepping(1_756_000_000_000, 1), seed))
  id
}

pub fn start_script(modes: List(Mode), then: Mode) -> Subject(Step) {
  let assert Ok(started) =
    actor.new(Script(
      modes:,
      then:,
      resident: Resident,
      deliveries: 0,
      lookups: 0,
    ))
    |> actor.on_message(handle_step)
    |> actor.start
    as "the scripted network starts"
  started.data
}

pub fn handle_step(script: Script, step: Step) -> actor.Next(Script, Step) {
  case step {
    NextMode(reply:) -> {
      let #(mode, rest) = case script.modes {
        [mode, ..rest] -> #(mode, rest)
        [] -> #(script.then, [])
      }
      process.send(reply, mode)
      actor.continue(
        Script(..script, modes: rest, deliveries: script.deliveries + 1),
      )
    }
    Lookup(reply:) -> {
      process.send(reply, script.resident)
      actor.continue(Script(..script, lookups: script.lookups + 1))
    }
    SetResident(resident) -> actor.continue(Script(..script, resident:))
    SetThen(mode) -> actor.continue(Script(..script, then: mode))
    Count(reply:) -> {
      process.send(reply, #(script.deliveries, script.lookups))
      actor.continue(script)
    }
  }
}

// A sender and a recipient, linked `main` to `main` with wake permission,
/// over a network that follows `modes` and then `then`.
pub fn rig(seed: Int, modes: List(Mode), then: Mode) -> Rig {
  rig_on(seed, modes, then, ticking(1000))
}

// A clock that advances one millisecond on every read. A `clock.stepping`
// value is immutable, so each read of it would answer the same instant and
// the order rows were written in would be lost.
pub fn ticking(from: Int) -> clock.Clock {
  let assert Ok(counter) =
    actor.new(from)
    |> actor.on_message(fn(now, reply: Subject(Int)) {
      process.send(reply, now)
      actor.continue(now + 1)
    })
    |> actor.start
    as "the clock counter starts"
  clock.from_function(fn() {
    process.call(counter.data, waiting: 1000, sending: fn(reply) { reply })
  })
}

// The same rig with the sender's clock supplied.
pub fn rig_on(
  seed: Int,
  modes: List(Mode),
  then: Mode,
  sender_clock: clock.Clock,
) -> Rig {
  let sender_id = session_id(seed)
  attach(
    network(seed + 1, modes, then),
    gateway_test.reserved_fixture(sender_id).runtime,
    ids.session_id_to_string(sender_id),
    sender_clock,
  )
}

/// The recipient and the network in front of it, which outlive any one sender
/// session: a restarted sender is attached to the same network again.
pub type Network {
  Network(
    recipient: api.Runtime,
    recipient_name: String,
    script: Subject(Step),
    target: peer_mail.Endpoint,
  )
}

// A recipient session behind a network that follows `modes` and then `then`.
pub fn network(seed: Int, modes: List(Mode), then: Mode) -> Network {
  let recipient_id = session_id(seed)
  let recipient_name = ids.session_id_to_string(recipient_id)
  let recipient = gateway_test.reserved_fixture(recipient_id).runtime
  Network(
    recipient:,
    recipient_name:,
    script: start_script(modes, then),
    target: peer_mail.Endpoint(recipient_name, fn(command) {
      peer_mail.handle(recipient, clock.fixed(0), command)
      |> peer_mail.refused
    }),
  )
}

// A sender session over `sender`, wired to the network and linked `main` to
// `main` with wake permission. The link is idempotent, so attaching a
// reopened sender repeats it harmlessly.
pub fn attach(
  network: Network,
  sender: api.Runtime,
  sender_name: String,
  sender_clock: clock.Clock,
) -> Rig {
  let source =
    peer_mail.Endpoint(sender_name, fn(command) {
      peer_mail.handle(sender, sender_clock, command)
      |> peer_mail.refused
    })
  let script = network.script
  let target = network.target
  let wiring =
    peers.Wiring(
      own: source,
      metadata: json.Null,
      directory: Some(
        peers.Directory(
          resolve: fn(id) {
            resolve(script, source, scripted(script, target), id)
          },
          describe: fn(id) { Ok(json.Object([#("id", json.String(id))])) },
        ),
      ),
    )
  let assert Ok(_) = peers.link(source, target, "main", "main", MayWake)
    as "the owner links the pair"
  Rig(
    sender:,
    recipient: network.recipient,
    sender_name:,
    recipient_name: network.recipient_name,
    script:,
    wiring:,
    source:,
    target:,
  )
}

/// A clock a test sets: reads answer the last instant set.
pub fn settable_clock(from: Int) -> #(clock.Clock, fn(Int) -> Nil) {
  let assert Ok(cell) =
    actor.new(from)
    |> actor.on_message(fn(now, message: ClockMessage) {
      case message {
        ReadNow(reply:) -> {
          process.send(reply, now)
          actor.continue(now)
        }
        SetNow(to:) -> actor.continue(to)
      }
    })
    |> actor.start
    as "the settable clock starts"
  #(
    clock.from_function(fn() {
      process.call(cell.data, waiting: 1000, sending: ReadNow)
    }),
    fn(to) { process.send(cell.data, SetNow(to:)) },
  )
}

pub type ClockMessage {
  ReadNow(reply: Subject(Int))
  SetNow(to: Int)
}

pub fn resolve(
  script: Subject(Step),
  source: peer_mail.Endpoint,
  target: peer_mail.Endpoint,
  id: String,
) -> Result(peer_mail.Endpoint, peer_mail.Failure) {
  case id == source.session, id == target.session {
    True, _ -> Ok(source)
    False, True ->
      case process.call(script, 1000, Lookup) {
        Resident -> Ok(target)
        Saved -> Error(peer_mail.NotOpen)
        Gone -> Error(peer_mail.Refused("session does not exist"))
      }

    // Any other session is one the owner holds saved, so that a test can owe a
    // message to a second recipient whose answer differs from the first's.
    False, False -> Error(peer_mail.NotOpen)
  }
}

// The recipient's endpoint as the network presents it. Only a delivery is
// scripted; the grant and receipt commands a test makes directly reach the
// recipient as they would on one node.
pub fn scripted(
  script: Subject(Step),
  real: peer_mail.Endpoint,
) -> peer_mail.Endpoint {
  peer_mail.Endpoint(real.session, fn(command) {
    case command {
      peer_mail.Deliver(..) ->
        case process.call(script, 1000, NextMode) {
          Pass -> real.call(command)
          Down -> Error(peer_mail.Unreachable)
          Lose -> {
            let _committed = real.call(command)
            Error(peer_mail.Unreachable)
          }
        }
      _ -> real.call(command)
    }
  })
}

// Sends `id` with the text `hello`.
pub fn send(rig: Rig, id: String) -> Result(JsonValue, String) {
  peers.send(rig.wiring, "main", rig.recipient_name, "main", id, "hello")
}

// How many deliveries the network has seen and how many times the directory
/// was asked for the recipient.
pub fn counts(rig: Rig) -> #(Int, Int) {
  process.call(rig.script, 1000, Count)
}

pub fn receipts(runtime: api.Runtime) -> Int {
  let assert Ok(found) = api.reserved_facts(runtime, "client/peers/receipt/")
    as "receipts are queryable"
  list.length(found)
}

pub fn due(rig: Rig) -> List(peer_outbox.Row) {
  let assert Ok(json.Array(items)) = rig.source.call(peer_mail.OutboxDue)
    as "the due rows are a list"
  let assert Ok(rows) = list.try_map(items, peer_outbox.decode)
    as "the due rows decode"
  rows
}

// The sender's outbox row for `id`, read from the store directly so that
// reading it cannot expire it the way asking for the due rows does.
pub fn row(rig: Rig, id: String) -> Option(peer_outbox.Row) {
  let key = peer_outbox.key("main", rig.recipient_name, id)
  let assert Ok(cell) = api.fact_cell(rig.sender, key)
    as "the sender's store answers"
  option.map(cell, fn(cell) {
    let assert Ok(row) = peer_outbox.decode(cell.value)
      as "a stored row decodes"
    row
  })
}

pub fn stored_receipt(rig: Rig, id: String) -> JsonValue {
  let assert Ok(found) =
    rig.source.call(peer_mail.OutboxReceipt("main", rig.recipient_name, id))
    as "the receipt lookup answers"
  found
}

pub fn field(value: JsonValue, key: String) -> JsonValue {
  let assert json.Object(fields) = value as "an object"
  let assert Ok(found) = list.key_find(fields, key) as "the field exists"
  found
}

pub fn set_resident(rig: Rig, resident: Residency) -> Nil {
  process.send(rig.script, SetResident(resident))
}
