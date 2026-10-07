//// The web view's relay against a real session gateway: it acts with the
//// membership role capped by the page's ceiling and by Operator, it opens
//// without holding its caller while the gateway attaches, and every one of
//// its four exits leaves no process and no presence behind
//// (protocol-change/051, "The relay" and the operator addendum). A page's
//// check also ends it when its UI session expires, and a newer link for the
//// same principal leaves it open.
////
//// Presence is read as `gateway.attached`, which counts every attachment the
//// hub holds. The harness attaches one test client of its own, so each test
//// compares against the count before the relay attached.

import broker/token
import client/daemon/ui_relay
import client/daemon/ui_sessions
import client/gateway
import client/gateway_test
import client/protocol
import core/clock
import core/ids
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/time/timestamp
import runtime/api
import session_view/connection_event
import storage/access
import web_view/ending
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

// The binding the daemon's router builds for an operator's membership,
// under an observer's page unless a test asks for another ceiling.
fn attach(
  harness: gateway_test.Harness,
  check: fn() -> Answer,
) -> ui_relay.Attach {
  attach_under(harness, check, access.Observer)
}

fn attach_under(
  harness: gateway_test.Harness,
  check: fn() -> Answer,
  ceiling: access.Role,
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
      signin: None,
    ),
    check:,
    ceiling:,
    failed_reader: fn() { Nil },
  )
}

// Starts a relay for the calling process and waits for the attach's
// answer, as the component does through its selector.
fn start(
  attach: ui_relay.Attach,
  inbox: Subject(connection_event.Message),
  ended: fn(ending.Ending) -> Nil,
) -> Result(ui_relay.Relay, String) {
  let opened = process.new_subject()
  ui_relay.start(attach, inbox, process.self(), opened, ended)
  process.receive(opened, 5000)
  |> result.unwrap(Error("the relay did not answer"))
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

// A subscribe hands the page two frames: the reply, and the roster the hub
// pushes to every subscribed peer when one joins, the page included
// (`protocol-change/054`). They leave the gateway by different paths, so
// either may come first. Answers the reply, after checking that the other
// frame is a roster with no `reply_to` that names this page.
fn subscribed(inbox: Subject(connection_event.Message)) -> String {
  let first = next_text(inbox)
  let second = next_text(inbox)
  let #(reply, roster) = case is_roster(first) {
    True -> #(second, first)
    False -> #(first, second)
  }
  let assert Ok(protocol.EventEnvelope(
    reply_to: None,
    event: protocol.PresenceEvent(_),
    ..,
  )) = protocol.decode_event(roster)
    as "a subscribe pushes the page its own join"
  assert string.contains(roster, "\"page-alice\"")
  reply
}

fn is_roster(text: String) -> Bool {
  case protocol.decode_event(text) {
    Ok(protocol.EventEnvelope(event: protocol.PresenceEvent(_), ..)) -> True
    Ok(_) | Error(_) -> False
  }
}

// Whether the process exits within three seconds.
fn gone(pid: process.Pid) -> Bool {
  gone_within(pid, 3000)
}

// Whether the process exits within `ms` milliseconds.
fn gone_within(pid: process.Pid, ms: Int) -> Bool {
  let watch = process.monitor(pid)
  let answer =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(_) { True })
    |> process.selector_receive(ms)
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

// The ceiling caps and never grants, and no page carries Owner.
pub fn a_page_acts_with_the_least_of_membership_ceiling_and_operator_test() {
  let observer = access.Participant(access.Observer)
  let operator = access.Participant(access.Operator)
  assert ui_relay.capped(access.Owner, access.Observer) == observer
  assert ui_relay.capped(operator, access.Observer) == observer
  assert ui_relay.capped(observer, access.Observer) == observer
  assert ui_relay.capped(access.Owner, access.Operator) == operator
  assert ui_relay.capped(operator, access.Operator) == operator
  assert ui_relay.capped(observer, access.Operator) == observer
}

pub fn an_operators_page_reaches_the_session_test() {
  let harness = gateway_test.reserved_fixture(fixture_id(5108))
  let inbox = process.new_subject()
  let assert Ok(relay) =
    start(attach_under(harness, operator, access.Operator), inbox, fn(_) { Nil })
    as "the relay attaches"
  ui_relay.transmit(relay, subscribe(harness, 1))
  let _snapshot = subscribed(inbox)
  ui_relay.transmit(relay, frame(2, protocol.Prompt("main", "hello")))
  let answered = next_text(inbox)
  assert !string.contains(answered, "forbidden")
  ui_relay.shut(relay)
}

// An owner's page is an operator's: the relay's check answers with the
// capped role, so the gateway's equality check keeps the attachment open.
pub fn an_owners_page_is_an_operators_and_stays_open_test() {
  let harness = gateway_test.reserved_fixture(fixture_id(5109))
  let inbox = process.new_subject()
  let owner = fn() { Ok(#(alice(), access.Owner)) }
  let assert Ok(relay) =
    start(attach_under(harness, owner, access.Operator), inbox, fn(_) { Nil })
    as "the relay attaches"
  ui_relay.transmit(relay, subscribe(harness, 1))
  let snapshot = subscribed(inbox)
  assert string.contains(snapshot, "\"role\":\"operator\"")
  ui_relay.shut(relay)
}

// Lustre bounds a component's start at one second, and the relay is started
// from inside it. `start` returns before the gateway's attach, and the
// attach's answer arrives as a message when it is done.
pub fn a_slow_attach_does_not_hold_the_caller_test() {
  let harness = gateway_test.reserved_fixture(fixture_id(5110))
  let slow = fn() {
    process.sleep(1500)
    operator()
  }
  let opened = process.new_subject()
  let before = monotonic_ms()
  ui_relay.start(
    attach(harness, slow),
    process.new_subject(),
    process.self(),
    opened,
    fn(_) { Nil },
  )
  assert monotonic_ms() - before < 500
  assert process.receive(opened, 100) == Error(Nil)
  let assert Ok(Ok(relay)) = process.receive(opened, 5000)
    as "the attach answers once it is done"
  ui_relay.shut(relay)
}

fn monotonic_ms() -> Int {
  let #(seconds, nanoseconds) =
    timestamp.to_unix_seconds_and_nanoseconds(timestamp.system_time())
  seconds * 1000 + nanoseconds / 1_000_000
}

pub fn a_page_is_an_observer_whatever_its_membership_test() {
  let harness = gateway_test.reserved_fixture(fixture_id(5101))
  let inbox = process.new_subject()
  let assert Ok(relay) = start(attach(harness, operator), inbox, fn(_) { Nil })
    as "the relay attaches"

  // A read is served; a mutation is refused by the gateway, because the
  // attachment it holds is an observer's even though the check says operator.
  ui_relay.transmit(relay, subscribe(harness, 1))
  let _snapshot = subscribed(inbox)
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
  let assert Ok(relay) = start(attach(harness, operator), inbox, fn(_) { Nil })
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
        start(attach(harness, operator), inbox, fn(_) { Nil })
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
    start(attach(harness, check), inbox, fn(reason) {
      process.send(ended, reason)
    })
    as "the relay attaches"
  let pid = relay_pid(relay)

  // The refused check ends the attachment. The gateway answers the request
  // that met the refusal as closed, or closes the attachment first; either
  // way the relay reports the end, so the page's socket closes.
  ui_relay.transmit(relay, subscribe(harness, 1))
  let assert Ok(reason) = process.receive(ended, 5000)
    as "the relay reports the end to the page"

  // The gateway does not say why it closed, so the relay asks the check
  // again. A credential that no longer authenticates is a revoked access,
  // in the page's words and at the socket, which closes with 1000.
  assert reason == ending.AccessRevoked
  assert process.receive(inbox, 1000)
    == Ok(connection_event.Closed(ending.reason(ending.AccessRevoked)))
  assert gone(pid)
  assert gateway.attached(harness.hub) == before
}

// Demoting the principal while an operator's page is open closes it at the
// next frame: the check's capped answer no longer equals the binding's.
pub fn a_demoted_operators_page_is_closed_test() {
  let harness = gateway_test.reserved_fixture(fixture_id(5111))
  let ended = process.new_subject()
  let script =
    scripted([operator(), Ok(#(alice(), access.Participant(access.Observer)))])
  let check = fn() { process.call(script, 1000, Ask) }
  let assert Ok(relay) =
    start(
      attach_under(harness, check, access.Operator),
      process.new_subject(),
      fn(reason) { process.send(ended, reason) },
    )
    as "the relay attaches as an operator"
  let pid = relay_pid(relay)
  ui_relay.transmit(relay, subscribe(harness, 1))
  let assert Ok(reason) = process.receive(ended, 5000)
    as "the demoted page ends"
  assert reason == ending.AccessRevoked
  assert gone(pid)
}

pub fn a_gateway_that_goes_away_ends_its_relay_test() {
  let harness = gateway_test.reserved_fixture(fixture_id(5105))
  let inbox = process.new_subject()
  let ended = process.new_subject()
  let assert Ok(relay) =
    start(attach(harness, operator), inbox, fn(reason) {
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

  assert process.receive(ended, 5000) == Ok(ending.SessionStopped)
  assert gone(pid)
  assert process.receive(inbox, 1000)
    == Ok(connection_event.Closed("the session ended"))
}

fn page_grant(session: String) -> ui_sessions.Grant {
  ui_sessions.Grant(
    ui_sessions.Session(session),
    digest(),
    "alice",
    access.Observer,
    ui_sessions.OneSession,
    ui_sessions.Fresh,
    ui_sessions.Forgotten,
  )
}

fn digest() -> access.Digest {
  let assert Ok(digest) = access.credential_digest(string.repeat("c", 64))
    as "the fixture digest is valid"
  digest
}

type Clock {
  Read(reply: Subject(Int))
  Advance(by: Int)
}

fn clock() -> Subject(Clock) {
  let assert Ok(started) =
    actor.new(0)
    |> actor.on_message(fn(now, message) {
      case message {
        Read(reply) -> {
          process.send(reply, now)
          actor.continue(now)
        }
        Advance(by) -> actor.continue(now + by)
      }
    })
    |> actor.start
    as "the test clock starts"
  started.data
}

// A page's relay whose check runs the UI session's liveness, as the daemon's
// page socket builds it, over a table on the test's clock.
fn page(
  harness: gateway_test.Harness,
  session: String,
) -> #(
  ui_relay.Relay,
  Subject(ending.Ending),
  Subject(Clock),
  ui_sessions.Sessions,
  String,
) {
  let time = clock()
  let assert Ok(tables) =
    ui_sessions.start(ui_sessions.Settings(
      now: fn() { process.call(time, 1000, Read) },
      wall: fn() { process.call(time, 1000, Read) },
      entropy: token.production_entropy(),
      ticket_ms: 60_000,
      device_ms: 600_000,
      session_ms: 28_800_000,
    ))
    as "the table starts"
  let grant = page_grant(session)
  let assert Ok(issued) = ui_sessions.mint(tables, grant) as "a ticket"
  let assert Ok(redeemed) =
    ui_sessions.redeem(
      tables,
      issued.ticket,
      ui_sessions.SessionExchange(session),
    )
    as "the ticket is redeemed"
  let ended = process.new_subject()
  let open = ui_sessions.still_open(tables, redeemed.cookie, grant)
  let assert Ok(relay) =
    start(
      attach(harness, ui_relay.while_open(operator, open)),
      process.new_subject(),
      fn(reason) { process.send(ended, reason) },
    )
    as "the relay attaches"
  #(relay, ended, time, tables, redeemed.cookie)
}

pub fn an_expired_ui_session_ends_an_open_page_test() {
  let harness = gateway_test.reserved_fixture(fixture_id(5106))
  let session = ids.session_id_to_string(api.session_id(harness.runtime))
  let #(relay, ended, time, _, _) = page(harness, session)
  let pid = relay_pid(relay)

  process.send(time, Advance(28_800_000))
  ui_relay.transmit(relay, subscribe(harness, 1))
  let assert Ok(reason) = process.receive(ended, 5000)
    as "the expired page ends"

  // A page whose UI session is gone says so, and not that access was
  // revoked: the person's fix is a fresh link, not a conversation with the
  // owner.
  assert reason == ending.PageEnded
  assert gone(pid)
}

// A newer ticket for the same principal and session adds a page beside the
// open one (protocol-change/051, the addendum on several pages). The open
// page's own check still passes, and its next frame does not end it.
pub fn a_newer_link_leaves_an_open_page_open_test() {
  let harness = gateway_test.reserved_fixture(fixture_id(5107))
  let session = ids.session_id_to_string(api.session_id(harness.runtime))
  let #(relay, ended, _, tables, cookie) = page(harness, session)
  let pid = relay_pid(relay)

  let assert Ok(issued) = ui_sessions.mint(tables, page_grant(session))
    as "a second ticket"
  let assert Ok(second) =
    ui_sessions.redeem(
      tables,
      issued.ticket,
      ui_sessions.SessionExchange(session),
    )
    as "the second ticket opens a second page"
  assert second.cookie != cookie
  ui_relay.transmit(relay, subscribe(harness, 1))

  // The frame was answered by the open page, so the check that decides
  // whether it ends has run against the table that now holds both pages.
  assert ui_sessions.still_open(tables, cookie, page_grant(session))()
    == Ok(Nil)
  assert process.receive(ended, 500) == Error(Nil)
  assert !gone_within(pid, 100)
}

// The page that a fifth link displaces ends as `PageEnded` at its next
// frame, like any page whose UI session is gone.
pub fn a_displaced_page_ends_as_an_ended_page_test() {
  let harness = gateway_test.reserved_fixture(fixture_id(5108))
  let session = ids.session_id_to_string(api.session_id(harness.runtime))
  let #(relay, ended, _, tables, _) = page(harness, session)
  let pid = relay_pid(relay)

  // The relay's page is the principal's first. Three more fill the bound.
  list.each(list.repeat(Nil, ui_sessions.max_pages - 1), fn(_) {
    let assert Ok(issued) = ui_sessions.mint(tables, page_grant(session))
      as "a ticket"
    let assert Ok(_) =
      ui_sessions.redeem(
        tables,
        issued.ticket,
        ui_sessions.SessionExchange(session),
      )
      as "a page under the bound"
  })
  ui_relay.transmit(relay, subscribe(harness, 1))
  assert process.receive(ended, 500) == Error(Nil)

  let assert Ok(issued) = ui_sessions.mint(tables, page_grant(session))
    as "the displacing ticket"
  let assert Ok(_) =
    ui_sessions.redeem(
      tables,
      issued.ticket,
      ui_sessions.SessionExchange(session),
    )
    as "the displacing page"
  ui_relay.transmit(relay, subscribe(harness, 2))
  let assert Ok(reason) = process.receive(ended, 5000)
    as "the displaced page ends"
  assert reason == ending.PageEnded
  assert gone(pid)
}

// An attach the gateway refuses is reported the way a later end is: the
// component is told the ending in the fixed words and never the gateway's
// own, and the page's socket is told to close. A refusal that names no
// ending is a session that is not open, which the socket retries.
pub fn a_refused_attach_names_its_ending_and_closes_the_page_test() {
  let harness = gateway_test.reserved_fixture(fixture_id(5121))
  let ended = process.new_subject()
  let refuse = fn() { Error("the gateway's own words") }
  let assert Error(refusal) =
    start(attach(harness, refuse), process.new_subject(), fn(reason) {
      process.send(ended, reason)
    })
    as "the gateway refuses the attach"
  assert refusal == ending.reason(ending.NotOpen)
  assert process.receive(ended, 1000) == Ok(ending.NotOpen)
}

// An attach refused because the page's UI session is already gone, as it is
// when its eight hours ran out before its socket opened, says so.
pub fn an_attach_by_an_ended_page_says_the_page_ended_test() {
  let harness = gateway_test.reserved_fixture(fixture_id(5122))
  let ended = process.new_subject()
  let check = ui_relay.while_open(operator, fn() { Error(Nil) })
  let assert Error(refusal) =
    start(attach(harness, check), process.new_subject(), fn(reason) {
      process.send(ended, reason)
    })
    as "the ended page's attach is refused"
  assert refusal == ending.reason(ending.PageEnded)
  assert process.receive(ended, 1000) == Ok(ending.PageEnded)
}

// The gateway closes an attachment for reasons of its own as well as
// because the check refused: a failed snapshot reader closes them all and
// stops the incarnation. When the re-check passes with the authority the
// attach held, the page says the session stopped, not that access changed.
// The check answers as an operator, except that once the test arms it, its
// next answer demotes the page, which closes it at a push without a request,
// and every answer after that is the original authority again.
type Toggle {
  Demote
  Answer(reply: Subject(Answer))
}

fn demotable() -> Subject(Toggle) {
  let assert Ok(started) =
    actor.new(False)
    |> actor.on_message(fn(armed, message) {
      case message {
        Demote -> actor.continue(True)
        Answer(reply) -> {
          case armed {
            True -> {
              process.send(
                reply,
                Ok(#(alice(), access.Participant(access.Observer))),
              )
              actor.continue(False)
            }
            False -> {
              process.send(reply, operator())
              actor.continue(False)
            }
          }
        }
      }
    })
    |> actor.start
    as "the demotable check starts"
  started.data
}

pub fn a_close_with_an_unchanged_authority_is_a_stopped_session_test() {
  let harness = gateway_test.reserved_fixture(fixture_id(5123))
  let ended = process.new_subject()
  let inbox = process.new_subject()
  let toggle = demotable()
  let check = fn() { process.call(toggle, 1000, Answer) }
  let assert Ok(relay) =
    start(attach_under(harness, check, access.Operator), inbox, fn(reason) {
      process.send(ended, reason)
    })
    as "the relay attaches as an operator"
  ui_relay.transmit(relay, subscribe(harness, 1))
  let _ = subscribed(inbox)

  // Another page joining is a push to the first, whose check now demotes it.
  process.send(toggle, Demote)
  let other = attach_under(harness, operator, access.Operator)
  let joiner =
    ui_relay.Attach(
      ..other,
      binding: gateway.Binding(..other.binding, connection_id: "page-bob"),
    )
  let assert Ok(second) = start(joiner, process.new_subject(), fn(_) { Nil })
    as "a second page attaches"
  ui_relay.transmit(second, subscribe(harness, 1))
  assert process.receive(ended, 5000) == Ok(ending.SessionStopped)
}

// The same close, with a re-check that answers a different capped
// authority, is a role change and says so.
pub fn a_close_with_a_changed_authority_is_revoked_access_test() {
  let harness = gateway_test.reserved_fixture(fixture_id(5124))
  let ended = process.new_subject()
  let observer = Ok(#(alice(), access.Participant(access.Observer)))
  let script = scripted([operator(), observer, observer])
  let check = fn() { process.call(script, 1000, Ask) }
  let assert Ok(relay) =
    start(
      attach_under(harness, check, access.Operator),
      process.new_subject(),
      fn(reason) { process.send(ended, reason) },
    )
    as "the relay attaches as an operator"
  ui_relay.transmit(relay, subscribe(harness, 1))
  assert process.receive(ended, 5000) == Ok(ending.AccessRevoked)
}

// The page socket's own check answers a refused authorization with the
// access ending's reason, so an attach it refuses is a revoked access (final)
// and not a session that is not open (retried).
pub fn an_attach_refused_for_authorization_is_revoked_access_test() {
  let harness = gateway_test.reserved_fixture(fixture_id(5125))
  let ended = process.new_subject()
  let refuse = fn() { Error(ending.reason(ending.AccessRevoked)) }
  let assert Error(refusal) =
    start(attach(harness, refuse), process.new_subject(), fn(reason) {
      process.send(ended, reason)
    })
    as "the attach is refused"
  assert refusal == ending.reason(ending.AccessRevoked)
  assert process.receive(ended, 1000) == Ok(ending.AccessRevoked)
}
