//// Generated envelope cases pin version, correlation, and byte-bound invariants.
//// Wire examples use the accepted control vocabulary, not the conversation codec.

import client/daemon/protocol
import core/clock
import core/ids
import core/json
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import storage/access
import storage/domain

fn session_id() -> String {
  let #(id, _) = ids.mint_session(ids.generator(clock.fixed(at: 1), seed: 1))
  ids.session_id_to_string(id)
}

fn envelope(
  id: Int,
  command: String,
  fields: List(#(String, json.JsonValue)),
) -> String {
  json.to_string(
    json.Object([
      #("v", json.Int(2)),
      #("id", json.Int(id)),
      #("cmd", json.String(command)),
      #("body", json.Object(fields)),
    ]),
  )
}

pub fn creation_configuration_preserves_defaults_and_rejects_invalid_fields_test() {
  let fields = [
    #("request_key", json.String("key")),
    #("workspace", json.String("/workspace")),
    #("name", json.String("name")),
  ]
  assert protocol.decode(
      envelope(1, "sessions.create", [
        #("configuration", json.String("")),
        ..fields
      ]),
    )
    == Ok(protocol.Request(
      1,
      protocol.CreateSession(
        "key",
        "/workspace",
        "name",
        "",
        domain.WorkspacePrivate,
      ),
    ))
  let assert Error(_) = protocol.decode(envelope(1, "sessions.create", fields))
    as "configuration remains a required field even when empty"
  list.each(
    [json.Null, json.Int(1), json.String(string.repeat("x", 4097))],
    fn(value) {
      let assert Error(_) =
        protocol.decode(
          envelope(1, "sessions.create", [#("configuration", value), ..fields]),
        )
        as "configuration still requires bounded text"
    },
  )
}

pub fn every_control_command_has_one_typed_decode_test() {
  let id = session_id()
  let session = #("session_id", json.String(id))
  let epoch = #("epoch", json.String("epoch"))
  let workspace = #("workspace", json.String("/workspace"))
  let cases = [
    #(
      "sessions.rename",
      [session, epoch, #("name", json.String("review auth"))],
      protocol.RenameSession(id, "review auth", "epoch"),
    ),
    #(
      "sessions.invite",
      [
        session,
        epoch,
        #("principal_id", json.String("member")),
        #("name", json.String("Member")),
        #("role", json.String("observer")),
      ],
      protocol.Invite(id, "member", "Member", access.Observer, "epoch"),
    ),
    #(
      "sessions.set_role",
      [
        session,
        epoch,
        #("principal_id", json.String("member")),
        #("role", json.String("operator")),
      ],
      protocol.SetRole(id, "member", access.Operator, "epoch"),
    ),
    #(
      "sessions.revoke",
      [session, epoch, #("principal_id", json.String("member"))],
      protocol.RevokeMembership(id, "member", "epoch"),
    ),
    #(
      "credentials.rotate",
      [epoch, #("principal_id", json.String("member"))],
      protocol.RotateCredential("member", "epoch"),
    ),
    #(
      "credentials.revoke",
      [epoch, #("principal_id", json.String("member"))],
      protocol.RevokeCredentials("member", "epoch"),
    ),
    #("status", [], protocol.Status),
    #(
      "sessions.list",
      [#("after", json.String(""))],
      protocol.ListSessions("", None),
    ),
    #("sessions.get", [session], protocol.GetSession(id)),
    #(
      "sessions.isolate",
      [session, epoch, #("transcript", json.String("share_existing"))],
      protocol.IsolateSession(id, "epoch"),
    ),
    #("sessions.default", [workspace], protocol.WorkspaceDefault("/workspace")),
    #(
      "sessions.set_default",
      [workspace, session],
      protocol.SetDefault("/workspace", id),
    ),
    #(
      "sessions.create",
      [
        #("request_key", json.String("key")),
        workspace,
        #("name", json.String("name")),
        #("configuration", json.String("/config")),
      ],
      protocol.CreateSession(
        "key",
        "/workspace",
        "name",
        "/config",
        domain.WorkspacePrivate,
      ),
    ),
    #("sessions.open", [session, epoch], protocol.OpenSession(id, "epoch")),
    #("sessions.stop", [session, epoch], protocol.StopSession(id, "epoch")),
    #(
      "operations.get",
      [session, epoch, #("operation", json.String("epoch:1"))],
      protocol.GetOperation(id, "epoch:1", "epoch"),
    ),
    #("daemon.shutdown", [epoch], protocol.Shutdown("epoch")),
  ]
  list.each(cases, fn(example) {
    assert protocol.decode(envelope(7, example.0, example.1))
      == Ok(protocol.Request(7, example.2))
  })
}

pub fn admin_codec_refuses_owner_roles_and_unbounded_recovery_ids_test() {
  assert result.is_error(
    protocol.decode(
      envelope(1, "sessions.isolate", [
        #("session_id", json.String(session_id())),
        #("epoch", json.String("epoch")),
      ]),
    ),
  )
  let common = [
    #("session_id", json.String(session_id())),
    #("epoch", json.String("epoch")),
    #("name", json.String("Member")),
  ]
  let assert Error(_) =
    protocol.decode(
      envelope(1, "sessions.invite", [
        #("principal_id", json.String("member")),
        #("role", json.String("owner")),
        ..common
      ]),
    )
    as "a member invitation cannot mint owner authority"
  let assert Error(_) =
    protocol.decode(
      envelope(1, "sessions.invite", [
        #("principal_id", json.String(string.repeat("a", 129))),
        #("role", json.String("observer")),
        ..common
      ]),
    )
    as "recovery identifiers remain bounded before admission"
}

pub fn generated_request_ids_preserve_positive_correlation_only_test() {
  int.range(from: -100, to: 1000, with: Nil, run: fn(_, id) {
    case id > 0 {
      True -> {
        assert protocol.decode(envelope(id, "status", []))
          == Ok(protocol.Request(id, protocol.Status))
      }
      False -> {
        let assert Error(protocol.Fault(reply_to: None, ..)) =
          protocol.decode(envelope(id, "status", []))
          as "nonpositive ids never become reply correlations"
        Nil
      }
    }
  })
}

pub fn prior_version_duplicate_fields_and_unknown_commands_are_refused_test() {
  assert protocol.decode("{\"v\":1,\"id\":3,\"cmd\":\"status\",\"body\":{}}")
    == Error(protocol.Fault(
      Some(3),
      "unsupported_version",
      "expected protocol version 2",
    ))
  let assert Error(protocol.Fault(code: "malformed", ..)) =
    protocol.decode(
      "{\"v\":2,\"id\":1,\"id\":2,\"cmd\":\"status\",\"body\":{}}",
    )
    as "duplicate correlations have no interpretation"
  assert result.is_error(protocol.decode(envelope(1, "prompt", [])))
  assert result.is_error(protocol.decode(
    "{\"v\":2,\"id\":1,\"cmd\":\"status\"}",
  ))
}

pub fn request_size_is_bytes_and_is_checked_before_json_parsing_test() {
  let text = string.repeat("é", protocol.max_bytes / 2 + 1)
  assert protocol.decode(text)
    == Error(protocol.Fault(None, "too_large", "control message exceeds 64 KiB"))
  let at_limit = string.repeat(" ", protocol.max_bytes)
  let assert Error(protocol.Fault(code: "malformed", ..)) =
    protocol.decode(at_limit)
    as "an exactly bounded document reaches the total JSON parser"
  Nil
}

pub fn generated_revision_types_cannot_silently_disable_fencing_test() {
  let rejected = [
    json.Null,
    json.String("1"),
    json.Int(-1),
    json.Bool(True),
    json.Array([]),
  ]
  list.each(rejected, fn(revision) {
    assert result.is_error(
      protocol.decode(
        envelope(1, "sessions.list", [
          #("after", json.String("")),
          #("revision", revision),
        ]),
      ),
    )
  })
  int.range(from: 0, to: 100, with: Nil, run: fn(_, revision) {
    assert protocol.decode(
        envelope(1, "sessions.list", [
          #("after", json.String("")),
          #("revision", json.Int(revision)),
        ]),
      )
      == Ok(protocol.Request(1, protocol.ListSessions("", Some(revision))))
  })
}

pub fn encoded_events_preserve_version_and_correlation_within_bound_test() {
  int.range(from: 1, to: 100, with: Nil, run: fn(_, id) {
    let body = json.Object([#("count", json.Int(id))])
    let assert Ok(text) = protocol.event(Some(id), "status", body)
      as "small events fit the outbound bound"
    assert bit_array.byte_size(bit_array.from_string(text))
      <= protocol.max_bytes
    let assert Ok(json.Object(fields)) = json.parse(text)
      as "the event is valid JSON"
    assert list.key_find(fields, "v") == Ok(json.Int(2))
    assert list.key_find(fields, "reply_to") == Ok(json.Int(id))
    assert list.key_find(fields, "body") == Ok(body)
  })
  assert result.is_error(protocol.event(
    Some(1),
    "status",
    json.String(string.repeat("x", protocol.max_bytes)),
  ))
}
