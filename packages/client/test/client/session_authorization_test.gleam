//// What a session attachment's authority costs per command, and when it is
//// re-asked.
////
//// A network attachment is authorized once when it attaches, once when the
//// gateway admits each command, and once immediately before each frame is
//// handed to it. The last of those is the live revocation boundary — the
//// transport used to repeat it after the gateway had already answered — so
//// these checks script the authority answer and count how often it is asked
//// rather than trusting a comment.
////
//// The fixtures' command is `subscribe`, and since `protocol-change/054` a
//// subscribe hands the attachment two frames rather than one: the reply, and
//// the roster the hub pushes to every subscribed peer when one joins. With
//// the attachment as the only peer, a subscribe is therefore authorized three
//// times: at admission, for its own copy of the roster, and for the reply.

import client/gateway
import client/gateway_test
import client/protocol
import core/clock
import core/ids
import core/json
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None}
import gleam/otp/actor
import gleam/result
import gleam/string
import runtime/api
import storage/access

/// What the gateway's authority capability answers with.
type Answer =
  Result(#(access.Principal, access.Authority), String)

type Script {
  /// One authorization, consuming the next scripted answer.
  Ask(Subject(Answer))

  /// How many authorizations have been asked for so far.
  Consumed(Subject(Int))
}

// The script is a list rather than a switch because the order of the answers
// is the whole point: a revocation must land between two checks of one
// command, and only a per-call script can place it there.
fn scripted(answers: List(Answer)) -> Subject(Script) {
  let assert Ok(started) =
    actor.new(#(answers, 0))
    |> actor.on_message(fn(state, message) {
      let #(remaining, asked) = state
      case message {
        Consumed(reply) -> {
          process.send(reply, asked)
          actor.continue(state)
        }
        Ask(reply) ->
          case remaining {
            [answer, ..rest] -> {
              process.send(reply, answer)
              actor.continue(#(rest, asked + 1))
            }
            [] -> {
              process.send(reply, Error("the authority script is exhausted"))
              actor.continue(#([], asked + 1))
            }
          }
      }
    })
    |> actor.start
    as "the authority script starts"
  started.data
}

fn consumed(script: Subject(Script)) -> Int {
  process.call(script, waiting: 1000, sending: Consumed)
}

fn fixture_id() -> ids.SessionId {
  let #(id, _) =
    ids.mint_session(ids.generator(clock.fixed(at: 1_700_000_000_000), 4211))
  id
}

fn attach(
  harness: gateway_test.Harness,
  script: Subject(Script),
  closed: Subject(Nil),
) -> gateway.ConnectionHandle {
  attach_as(harness, script, closed, access.Operator)
}

fn attach_as(
  harness: gateway_test.Harness,
  script: Subject(Script),
  closed: Subject(Nil),
  role: access.Role,
) -> gateway.ConnectionHandle {
  let assert Ok(digest) = access.credential_digest(string.repeat("a", 64))
    as "the fixture digest is valid"
  let assert Ok(handle) =
    gateway.attach_authenticated(
      harness.hub,
      gateway.Binding(
        session_id: ids.session_id_to_string(api.session_id(harness.runtime)),
        epoch: "epoch",
        incarnation: "incarnation",
        connection_id: "connection-alice",
        principal: access.Principal("alice", "Alice", access.MemberPrincipal),
        authority: access.Participant(role),
        digest:,
        signin: None,
      ),
      fn() { process.call(script, waiting: 1000, sending: Ask) },
      fn(frame) { process.send(harness.inbox, frame) },
      fn() { process.send(closed, Nil) },
      fn() { Nil },
      process.self(),
    )
    as "the authenticated attachment is admitted"
  handle
}

fn subscribe(harness: gateway_test.Harness, id: Int) -> String {
  protocol.encode_command(protocol.CommandEnvelope(
    id:,
    command: protocol.Subscribe(
      ids.session_id_to_string(api.session_id(harness.runtime)),
      None,
    ),
  ))
}

/// One command is authorized once at admission and once per frame delivered.
///
/// A subscribe delivers two frames, its own roster push and its reply, so it
/// is authorized three times. The count is what makes a further check on the
/// transport's own side redundant, and it is asserted rather than described
/// because the transport used to perform that check on every frame.
pub fn one_command_is_authorized_at_admission_and_at_delivery_test() {
  let harness = gateway_test.reserved_fixture(fixture_id())
  let allowed =
    Ok(#(
      access.Principal("alice", "Alice", access.MemberPrincipal),
      access.Participant(access.Operator),
    ))
  let script = scripted([allowed, allowed, allowed, allowed])
  let closed = process.new_subject()
  let handle = attach(harness, script, closed)
  let attached = consumed(script)

  let assert Ok(_snapshot) =
    gateway.connection_request(handle, subscribe(harness, 900))
    as "the command is admitted and its reply delivered"
  assert consumed(script) - attached == 3
  let assert Ok(frame) = process.receive(harness.inbox, 1000)
    as "the roster push passed its check and was delivered"
  let assert Ok(protocol.EventEnvelope(event: protocol.PresenceEvent(_), ..)) =
    protocol.decode_event(frame)
    as "the frame pushed on subscribe is the roster"
  assert process.receive(closed, 0) == Error(Nil)
}

/// A credential revoked after admission still closes the attachment, and
/// neither frame the command had already produced is handed to the socket.
///
/// This is the boundary the transport's removed check was standing in front
/// of: the gateway asks again immediately before each delivery, on the same
/// evidence, and drops the encoded frame when the answer has changed. The
/// revocation lands after admission, so the first frame out, the roster the
/// subscribe pushes, is the first to be refused, and the reply after it is
/// refused on its own check.
pub fn a_revocation_between_admission_and_delivery_drops_the_reply_test() {
  let harness = gateway_test.reserved_fixture(fixture_id())
  let allowed =
    Ok(#(
      access.Principal("alice", "Alice", access.MemberPrincipal),
      access.Participant(access.Operator),
    ))
  let script = scripted([allowed, allowed, Error("revoked"), Error("revoked")])
  let closed = process.new_subject()
  let handle = attach(harness, script, closed)

  assert gateway.connection_request(handle, subscribe(harness, 901))
    == Error("revoked")
  assert consumed(script) == 4
    as "the attach, the admission, the roster and the reply each asked once"
  let assert Ok(Nil) = process.receive(closed, 1000)
    as "the delivery check closes the attachment"
  assert process.receive(harness.inbox, 100) == Error(Nil)
    as "the revoked attachment is pushed no roster"
}

/// Idle retention ticks do not ask authority or retire a healthy attachment.
pub fn idle_maintenance_does_not_query_authority_test() {
  let harness = gateway_test.reserved_fixture(fixture_id())
  let allowed =
    Ok(#(
      access.Principal("alice", "Alice", access.MemberPrincipal),
      access.Participant(access.Operator),
    ))
  let script = scripted([allowed, allowed, allowed, allowed])
  let closed = process.new_subject()
  let handle = attach(harness, script, closed)
  let attached = consumed(script)
  let connections = gateway.attached(harness.hub)

  // Let two real maintenance periods pass without a request. The following
  // gateway call orders the observation after its queued maintenance work;
  // the script count catches probes even when they would have succeeded.
  assert process.receive(closed, 2200) == Error(Nil)
  assert gateway.attached(harness.hub) == connections
  assert consumed(script) == attached

  let assert Ok(_) = gateway.connection_request(handle, subscribe(harness, 902))
    as "the idle attachment still admits a command"
  assert consumed(script) - attached == 3
  assert process.receive(closed, 0) == Error(Nil)
}

/// Revocation during idle time is enforced before the next mutation writes.
pub fn idle_revocation_refuses_the_next_mutation_before_write_test() {
  let harness = gateway_test.reserved_fixture(fixture_id())
  let allowed =
    Ok(#(
      access.Principal("alice", "Alice", access.MemberPrincipal),
      access.Participant(access.Operator),
    ))
  let script = scripted([allowed, allowed, allowed, allowed, Error("revoked")])
  let closed = process.new_subject()
  let handle = attach(harness, script, closed)
  let assert Ok(_) = gateway.connection_request(handle, subscribe(harness, 903))
    as "subscription permits the later configuration command"
  let admitted = consumed(script)
  let connections = gateway.attached(harness.hub)

  // The next answer is already revoked, but no command is asking for it.
  // Maintenance must leave it untouched until the operator submits work.
  assert process.receive(closed, 2200) == Error(Nil)
  assert gateway.attached(harness.hub) == connections
  assert consumed(script) == admitted
  assert api.fact_cell(harness.runtime, api.run_settings_key) == Ok(None)

  let mutation =
    protocol.encode_command(protocol.CommandEnvelope(
      904,
      protocol.SetConfig(
        None,
        json.Object([#("queue_mode", json.String("one_at_a_time"))]),
      ),
    ))
  assert gateway.connection_request(handle, mutation)
    == Error("attachment is closed")
  assert process.receive(closed, 1000) == Ok(Nil)
  assert consumed(script) == admitted + 1
  assert api.fact_cell(harness.runtime, api.run_settings_key) == Ok(None)
}

fn decided(id: Int) -> String {
  protocol.encode_command(protocol.CommandEnvelope(
    id:,
    command: protocol.EscalationsDecided,
  ))
}

// Finishes the transfer a subscribe begins, which a second transfer cannot
// start until it has: the reply's snapshot identity is credited one piece at
// a time until the end arrives.
fn finish_first_transfer(
  handle: gateway.ConnectionHandle,
  reply: String,
  id: Int,
) -> Nil {
  let assert Ok(protocol.EventEnvelope(event: protocol.SnapshotBegin(body), ..)) =
    protocol.decode_event(reply)
    as "a subscribe begins a bounded transfer"
  let assert json.Object(fields) = body as "the begin body is an object"
  let assert Ok(json.String(snapshot_id)) = list.key_find(fields, "snapshot_id")
    as "the transfer is named"
  credit(handle, snapshot_id, 0, id)
}

fn credit(
  handle: gateway.ConnectionHandle,
  snapshot_id: String,
  index: Int,
  id: Int,
) -> Nil {
  let frame =
    protocol.encode_command(protocol.CommandEnvelope(
      id:,
      command: protocol.SnapshotNext(snapshot_id, index),
    ))
  let assert Ok(reply) = gateway.connection_request(handle, frame)
    as "each credit is answered"
  case protocol.decode_event(reply) {
    Ok(protocol.EventEnvelope(event: protocol.SnapshotEnd(_), ..)) -> Nil
    _ -> credit(handle, snapshot_id, index + 1, id + 1)
  }
}

/// A member whose membership ends after subscribing is refused the decided
/// approvals read, like every other command: the read has no authority of
/// its own, and no transfer starts.
pub fn a_revoked_member_is_refused_the_decided_approvals_read_test() {
  let harness = gateway_test.reserved_fixture(fixture_id())
  let allowed =
    Ok(#(
      access.Principal("alice", "Alice", access.MemberPrincipal),
      access.Participant(access.Operator),
    ))
  let revoked = Error("revoked")
  let script =
    scripted([allowed, allowed, allowed, allowed, revoked, revoked, revoked])
  let closed = process.new_subject()
  let handle = attach(harness, script, closed)
  let assert Ok(_) = gateway.connection_request(handle, subscribe(harness, 910))
    as "the subscribe is admitted while the member belongs"
  assert result.is_error(gateway.connection_request(handle, decided(990)))
  let assert Ok(Nil) = process.receive(closed, 1000)
    as "the revoked attachment is closed"
}

/// An observer may read the decided approvals: the live row shows its words
/// to every attachment, and the read is as read-only as `history`.
pub fn an_observer_may_read_the_decided_approvals_test() {
  let harness = gateway_test.reserved_fixture(fixture_id())
  let observer =
    Ok(#(
      access.Principal("alice", "Alice", access.MemberPrincipal),
      access.Participant(access.Observer),
    ))
  let script = scripted(list.repeat(observer, 40))
  let closed = process.new_subject()
  let handle = attach_as(harness, script, closed, access.Observer)
  let assert Ok(reply) =
    gateway.connection_request(handle, subscribe(harness, 920))
    as "the observer subscribes"
  finish_first_transfer(handle, reply, 921)
  let assert Ok(frame) = gateway.connection_request(handle, decided(990))
    as "the observer's read is admitted"
  let assert Ok(protocol.EventEnvelope(event: protocol.SnapshotBegin(body), ..)) =
    protocol.decode_event(frame)
    as "the reply begins a bounded transfer"
  let assert json.Object(fields) = body as "the begin body is an object"
  assert list.key_find(fields, "window") == Ok(json.String("decided"))
  assert list.key_find(fields, "role") == Ok(json.String("observer"))
}
