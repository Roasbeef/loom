//// The operator grammar carries data while the authenticated socket owns role.

import client/evolution/cli
import client/protocol
import core/clock
import core/ids
import core/json
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

fn session() -> String {
  let #(id, _) = ids.mint_session(ids.generator(clock.fixed(1), 807))
  ids.session_id_to_string(id)
}

pub fn operator_grammar_requires_native_identity_and_admitted_action_test() {
  cli.parse(["catalogue", session()]) |> should.be_ok
  cli.parse(["status", session(), "--request-id", "publish-1"]) |> should.be_ok
  cli.parse(["select", session(), "--request-id", "publish-1"]) |> should.be_ok
  cli.parse(["unknown", session()]) |> should.be_error
  cli.parse(["catalogue", "../another-session"]) |> should.be_error
  cli.parse(["inspect", session(), "--candidate-id", "forged"])
  |> should.be_error
  cli.parse(["status", session(), "--request-id", ""]) |> should.be_error
}

pub fn argument_json_cannot_forge_authority_or_hide_duplicate_fields_test() {
  cli.admit_arguments(json.Object([#("authority", json.String("owner"))]))
  |> should.be_error
  cli.admit_arguments(json.Object([#("principal", json.String("operator"))]))
  |> should.be_error
  cli.admit_arguments(
    json.Object([
      #("request_id", json.String("one")),
      #("request_id", json.String("two")),
    ]),
  )
  |> should.be_error
  cli.admit_arguments(
    json.Object([#("reason", json.String(string.repeat("x", 49_153)))]),
  )
  |> should.be_error
  cli.admit_arguments(json.Array([])) |> should.be_error
}

pub fn attachment_fences_exact_resident_session_and_daemon_incarnation_test() {
  let metadata =
    json.Object([
      #("session_id", json.String(session())),
      #("epoch", json.String("daemon-a")),
      #("incarnation", json.String("instance-a")),
    ])
  cli.verify_attachment(metadata, session(), "daemon-a", "instance-a")
  |> should.equal(Ok(Nil))
  cli.verify_attachment(metadata, session(), "daemon-b", "instance-a")
  |> should.be_error
  cli.verify_attachment(metadata, session(), "daemon-a", "instance-b")
  |> should.be_error
  cli.verify_attachment(metadata, "another-session", "daemon-a", "instance-a")
  |> should.be_error
}

pub fn queued_receipt_is_returned_without_inferred_completion_test() {
  let receipt =
    json.Object([
      #("status", json.String("queued")),
      #("request_id", json.String("publish-1")),
    ])
  let frame =
    protocol.EventEnvelope(
      Some(2),
      None,
      protocol.SnapshotEvent(protocol.EvolutionSnapshot(receipt)),
    )
  cli.reply_value(frame) |> should.equal(Ok(receipt))
  cli.reply_value(protocol.EventEnvelope(
    Some(2),
    None,
    protocol.ErrorEvent("bad_request", "revoked", None),
  ))
  |> should.equal(Error(cli.Refused("bad_request: revoked")))
  cli.reply_value(protocol.EventEnvelope(
    Some(2),
    None,
    protocol.SnapshotEvent(protocol.ResumeSnapshot(9)),
  ))
  |> should.be_error
}
