//// The web view's relay against a real session gateway: it is read-only by
//// role whatever the membership says, and every one of its four exits
//// leaves no process and no presence behind (protocol-change/051, "The
//// relay").
////
//// Presence is read as `gateway.attached`, which counts every attachment the
//// hub holds. The harness attaches one test client of its own, so each test
//// compares against the count before the relay attached.

import client/daemon/ui_relay
import client/gateway
import client/gateway_test
import client/protocol
import core/clock
import core/ids
import gleam/erlang/process.{type Subject}
import gleam/option.{None}
import gleam/otp/actor
import gleam/result
import gleam/string
import runtime/api
import session_view/connection_event
import storage/access
import weft/registry

type Answer =
  Result(#(access.Principal, access.Authority), String)

fn fixture_id(seed: Int) -> ids.SessionId {
  let #(id, _) =
    ids.mint_session(ids.generator(clock.fixed(at: 1_700_000_000_000), seed))
  id
}

fn alice() -> access.Principal {
  access.Principal("alice", "Alice", access.MemberPrincipal)
}

// The binding the daemon's router builds for an operator's page. The relay
// must cap it to observer.
fn attach(
  harness: gateway_test.Harness,
  check: fn() -> Answer,
) -> ui_relay.Attach {
  let assert Ok(digest) = access.credential_digest(string.repeat("a", 64))
    as "the fixture digest is valid"
  ui_relay.Attach(
    hub: harness.hub,
    binding: gateway.Binding(
      session_id: ids.session_id_to_string(api.session_id(harness.runtime)),
      epoch: "epoch",
      incarnation: "incarnation",
      connection_id: "page-alice",
      principal: alice(),
      authority: access.Participant(access.Operator),
      digest:,
    ),
    check:,
    failed_reader: fn() { Nil },
  )
}

fn operator() -> Answer {
  Ok(#(alice(), access.Participant(access.Operator)))
}

fn frame(id: Int, command: protocol.Command) -> String {
  protocol.encode_command(protocol.CommandEnvelope(id:, command:))
}

fn subscribe(harness: gateway_test.Harness, id: Int) -> String {
  frame(
    id,
    protocol.Subscribe(
      ids.session_id_to_string(api.session_id(harness.runtime)),
      None,
    ),
  )
}

fn next_text(inbox: Subject(connection_event.Message)) -> String {
  case process.receive(inbox, 5000) {
    Ok(connection_event.Incoming(text)) -> text
    Ok(other) -> string.inspect(other)
    Error(Nil) -> "no frame"
  }
}

// Whether the process exits within three seconds.
fn gone(pid: process.Pid) -> Bool {
  let watch = process.monitor(pid)
  let answer =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(_) { True })
    |> process.selector_receive(3000)
  answer == Ok(True)
}

fn relay_pid(relay: ui_relay.Relay) -> process.Pid {
  let assert Ok(pid) = ui_relay.pid(relay) as "a running relay has a pid"
  pid
}

type Script {
  Ask(reply: Subject(Answer))
}

// Answers each check with the next scripted answer, then refuses.
fn scripted(answers: List(Answer)) -> Subject(Script) {
  let assert Ok(started) =
    actor.new(answers)
    |> actor.on_message(fn(remaining, message) {
      let Ask(reply) = message
      case remaining {
        [answer, ..rest] -> {
          process.send(reply, answer)
          actor.continue(rest)
        }
        [] -> {
          process.send(reply, Error("unauthorized"))
          actor.continue([])
        }
      }
    })
    |> actor.start
    as "the authority script starts"
  started.data
}

pub fn a_page_is_an_observer_whatever_its_membership_test() {
  let harness = gateway_test.reserved_fixture(fixture_id(5101))
  let inbox = process.new_subject()
  let assert Ok(relay) =
    ui_relay.start(attach(harness, operator), inbox, fn(_) { Nil })
    as "the relay attaches"

  // A read is served; a mutation is refused by the gateway, because the
  // attachment it holds is an observer's even though the check says operator.
  ui_relay.transmit(relay, subscribe(harness, 1))
  let _snapshot = next_text(inbox)
  ui_relay.transmit(relay, frame(2, protocol.Prompt("main", "hello")))
  let refused = next_text(inbox)
  assert string.contains(refused, "\"error\"")
  assert string.contains(refused, "forbidden")
  ui_relay.shut(relay)
}

pub fn shut_detaches_and_leaves_no_presence_test() {
  let harness = gateway_test.reserved_fixture(fixture_id(5102))
  let before = gateway.attached(harness.hub)
  let inbox = process.new_subject()
  let assert Ok(relay) =
    ui_relay.start(attach(harness, operator), inbox, fn(_) { Nil })
    as "the relay attaches"
  assert gateway.attached(harness.hub) == before + 1

  let pid = relay_pid(relay)
  ui_relay.shut(relay)
  assert gone(pid)
  assert gateway.attached(harness.hub) == before
}

pub fn a_component_that_goes_away_ends_its_relay_test() {
  let harness = gateway_test.reserved_fixture(fixture_id(5103))
  let before = gateway.attached(harness.hub)
  let started = process.new_subject()

  // The component is the process that starts the relay. It ends normally,
  // as a Lustre runtime does on shutdown, so the relay's link does not kill
  // it: the relay must notice the monitor's report and end on its own.
  let component =
    process.spawn_unlinked(fn() {
      let inbox = process.new_subject()
      let stop = process.new_subject()
      let assert Ok(relay) =
        ui_relay.start(attach(harness, operator), inbox, fn(_) { Nil })
        as "the relay attaches"
      process.send(started, #(relay, stop))
      let _ = process.receive(stop, 10_000)
      Nil
    })
  let assert Ok(#(relay, stop)) = process.receive(started, 5000)
    as "the component reports its relay"
  let pid = relay_pid(relay)
  assert gateway.attached(harness.hub) == before + 1

  process.send(stop, Nil)
  assert gone(component)
  assert gone(pid)
  assert gateway.attached(harness.hub) == before
}

pub fn a_revoked_page_is_closed_test() {
  let harness = gateway_test.reserved_fixture(fixture_id(5104))
  let before = gateway.attached(harness.hub)
  let inbox = process.new_subject()
  let ended = process.new_subject()
  // The check allows the attach, then refuses: the credential was revoked
  // while the page was open. The answers live in an actor because the
  // gateway asks from its own process.
  let script = scripted([operator()])
  let check = fn() { process.call(script, 1000, Ask) }
  let assert Ok(relay) =
    ui_relay.start(attach(harness, check), inbox, fn(reason) {
      process.send(ended, reason)
    })
    as "the relay attaches"
  let pid = relay_pid(relay)

  // The refused check ends the attachment. The gateway answers the request
  // that met the refusal as closed, or closes the attachment first; either
  // way the relay reports the end, so the page's socket closes.
  ui_relay.transmit(relay, subscribe(harness, 1))
  let assert Ok(_reason) = process.receive(ended, 5000)
    as "the relay reports the end to the page"
  assert process.receive(inbox, 1000)
    |> result.map(fn(message) {
      case message {
        connection_event.Closed(_) -> True
        connection_event.Incoming(_)
        | connection_event.Connected
        | connection_event.NetworkFault(_) -> False
      }
    })
    == Ok(True)
  assert gone(pid)
  assert gateway.attached(harness.hub) == before
}

pub fn a_gateway_that_goes_away_ends_its_relay_test() {
  let harness = gateway_test.reserved_fixture(fixture_id(5105))
  let inbox = process.new_subject()
  let ended = process.new_subject()
  let assert Ok(relay) =
    ui_relay.start(attach(harness, operator), inbox, fn(reason) {
      process.send(ended, reason)
    })
    as "the relay attaches"
  let pid = relay_pid(relay)

  // The session's gateway stops, as it does when the session stops or the
  // daemon shuts down. It is unlinked first so that its death is the relay's
  // to observe and not this test's.
  let assert Ok(hub) = registry.lookup(harness.hub.name)
    as "the gateway is registered"
  let assert Ok(hub_pid) = process.subject_owner(hub) as "the gateway runs"
  process.unlink(hub_pid)
  process.kill(hub_pid)

  assert process.receive(ended, 5000) == Ok("the session ended")
  assert gone(pid)
  assert process.receive(inbox, 1000)
    == Ok(connection_event.Closed("the session ended"))
}
