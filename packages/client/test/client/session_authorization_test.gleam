//// What a session attachment's authority costs per command, and when it is
//// re-asked.
////
//// A network attachment is authorized three times over its first command: once
//// when it attaches, once when the gateway admits the command, and once
//// immediately before the reply is handed back. The last of those is the live
//// revocation boundary — the transport used to repeat it a fourth time after
//// the gateway had already answered — so these checks script the authority
//// answer and count how often it is asked rather than trusting a comment.

import client/gateway
import client/gateway_test
import client/protocol
import core/clock
import core/ids
import gleam/erlang/process.{type Subject}
import gleam/option.{None}
import gleam/otp/actor
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
        authority: access.Participant(access.Operator),
        digest:,
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

/// One command is authorized exactly twice: at admission and at delivery.
///
/// The count is what makes a third check on the transport's own side
/// redundant, and it is asserted rather than described because the transport
/// used to perform that third check on every frame.
pub fn one_command_is_authorized_at_admission_and_at_delivery_test() {
  let harness = gateway_test.reserved_fixture(fixture_id())
  let allowed =
    Ok(#(
      access.Principal("alice", "Alice", access.MemberPrincipal),
      access.Participant(access.Operator),
    ))
  let script = scripted([allowed, allowed, allowed])
  let closed = process.new_subject()
  let handle = attach(harness, script, closed)
  let attached = consumed(script)

  let assert Ok(_snapshot) =
    gateway.connection_request(handle, subscribe(harness, 900))
    as "the command is admitted and its reply delivered"
  assert consumed(script) - attached == 2
  assert process.receive(closed, 0) == Error(Nil)
}

/// A credential revoked after admission still closes the attachment, and the
/// reply the command had already produced is never handed to the socket.
///
/// This is the boundary the transport's removed check was standing in front
/// of: the gateway asks again immediately before delivery, on the same
/// evidence, and drops the encoded reply when the answer has changed.
pub fn a_revocation_between_admission_and_delivery_drops_the_reply_test() {
  let harness = gateway_test.reserved_fixture(fixture_id())
  let allowed =
    Ok(#(
      access.Principal("alice", "Alice", access.MemberPrincipal),
      access.Participant(access.Operator),
    ))
  let script = scripted([allowed, allowed, Error("revoked")])
  let closed = process.new_subject()
  let handle = attach(harness, script, closed)

  assert gateway.connection_request(handle, subscribe(harness, 901))
    == Error("revoked")
  let assert Ok(Nil) = process.receive(closed, 1000)
    as "the delivery check closes the attachment"
}
