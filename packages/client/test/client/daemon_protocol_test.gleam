//// Generated envelope cases pin version, correlation, and byte-bound invariants.
//// Wire examples use the accepted control vocabulary, not the conversation codec.

import client/daemon/protocol
import client/peer_mail
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
        None,
        None,
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
      "sessions.archive",
      [session, epoch],
      protocol.ArchiveSession(id, "epoch"),
    ),
    #(
      "sessions.restore",
      [session, epoch],
      protocol.RestoreSession(id, "epoch"),
    ),
    #(
      "sessions.archived",
      [#("after", json.String(""))],
      protocol.ListArchivedSessions("", None),
    ),
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
      protocol.Invite(
        id,
        "member",
        "Member",
        access.Observer,
        protocol.IssueClaim(protocol.default_claim_ttl_ms),
        "epoch",
      ),
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
      protocol.RotateCredential(
        "member",
        protocol.IssueClaim(protocol.default_claim_ttl_ms),
        "epoch",
      ),
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
        None,
        None,
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

pub fn principal_listings_decode_optional_cursors_and_refuse_malformed_ones_test() {
  assert protocol.decode(envelope(1, "principals.list", []))
    == Ok(protocol.Request(1, protocol.ListPrincipals("")))
  assert protocol.decode(
      envelope(2, "principals.list", [#("after", json.String("alice"))]),
    )
    == Ok(protocol.Request(2, protocol.ListPrincipals("alice")))
  list.each(
    [
      json.Null,
      json.Int(1),
      json.String(""),
      json.String(string.repeat("x", 129)),
      json.Array([]),
    ],
    fn(after) {
      assert result.is_error(
        protocol.decode(envelope(3, "principals.list", [#("after", after)])),
      )
    },
  )

  let session = session_id()
  assert protocol.decode(
      envelope(4, "principals.memberships", [
        #("principal_id", json.String("alice")),
      ]),
    )
    == Ok(protocol.Request(4, protocol.PrincipalMemberships("alice", "")))
  assert protocol.decode(
      envelope(5, "principals.memberships", [
        #("principal_id", json.String("alice")),
        #("after", json.String(session)),
      ]),
    )
    == Ok(protocol.Request(5, protocol.PrincipalMemberships("alice", session)))

  // The principal is required and bounded, and the cursor is a canonical
  // session ID, as it is for `sessions.list`.
  list.each(
    [
      [],
      [#("principal_id", json.String(""))],
      [#("principal_id", json.String(string.repeat("x", 129)))],
      [#("principal_id", json.Int(1))],
      [
        #("principal_id", json.String("alice")),
        #("after", json.String("not-a-session")),
      ],
      [#("principal_id", json.String("alice")), #("after", json.Null)],
    ],
    fn(fields) {
      assert result.is_error(
        protocol.decode(envelope(6, "principals.memberships", fields)),
      )
    },
  )
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

pub fn peer_controls_require_explicit_wake_and_canonical_sessions_test() {
  let fields = [
    #("source_session", json.String(session_id())),
    #("target_session", json.String(session_id())),
    #("source_strand", json.String("main")),
    #("target_strand", json.String("reviewer")),
    #("epoch", json.String("epoch")),
  ]
  assert protocol.decode(
      envelope(1, "peers.link", [#("wake", json.String("busy_only")), ..fields]),
    )
    == Ok(protocol.Request(
      1,
      protocol.LinkPeers(
        session_id(),
        "main",
        session_id(),
        "reviewer",
        peer_mail.BusyOnly,
        "epoch",
      ),
    ))
  assert result.is_error(protocol.decode(envelope(1, "peers.link", fields)))
  assert result.is_error(
    protocol.decode(
      envelope(1, "peers.link", [#("wake", json.String("implicit")), ..fields]),
    ),
  )
  assert protocol.decode(envelope(2, "peers.unlink", fields))
    == Ok(protocol.Request(
      2,
      protocol.UnlinkPeers(
        session_id(),
        "main",
        session_id(),
        "reviewer",
        "epoch",
      ),
    ))
}

pub fn peer_send_decodes_bounded_identity_and_payload_test() {
  let id = session_id()
  let coordinates = [
    #("source_session", json.String(id)),
    #("source_strand", json.String("main")),
    #("target_session", json.String(id)),
    #("target_strand", json.String("reviewer")),
    #("epoch", json.String("epoch")),
  ]
  let payload = [
    #("message_id", json.String("review-1")),
    #("text", json.String("finding")),
  ]
  assert protocol.decode(envelope(
      7,
      "peers.send",
      list.append(coordinates, payload),
    ))
    == Ok(protocol.Request(
      7,
      protocol.SendPeer(
        id,
        "main",
        id,
        "reviewer",
        "review-1",
        "finding",
        "epoch",
      ),
    ))
  list.each([#("message_id", 129), #("text", 32_769)], fn(pair) {
    list.each(["", string.repeat("x", pair.1)], fn(value) {
      let fields =
        list.map(payload, fn(field) {
          case field.0 == pair.0 {
            True -> #(field.0, json.String(value))
            False -> field
          }
        })
      assert result.is_error(
        protocol.decode(envelope(
          7,
          "peers.send",
          list.append(coordinates, fields),
        )),
      )
    })
  })
}

// `principals.rename` (protocol-change/065, the tenth pull request) decodes a
// name of any text up to 1024 bytes, blank included, so the catalogue's rule is
// the only one that judges it, and an optional principal. Every malformed shape
// is refused before the daemon acts, and no wire field can carry a different
// command's meaning.
pub fn principal_rename_decodes_a_name_and_an_optional_principal_test() {
  assert protocol.decode(
      envelope(1, "principals.rename", [
        #("name", json.String("Mira")),
        #("epoch", json.String("e1")),
      ]),
    )
    == Ok(protocol.Request(1, protocol.RenamePrincipal(None, "Mira", "e1")))
  assert protocol.decode(
      envelope(2, "principals.rename", [
        #("principal_id", json.String("guest-1a2b3c4d")),
        #("name", json.String("  Mira K  ")),
        #("epoch", json.String("e1")),
      ]),
    )
    == Ok(protocol.Request(
      2,
      protocol.RenamePrincipal(Some("guest-1a2b3c4d"), "  Mira K  ", "e1"),
    ))

  // A blank or control-bearing name is decoded as it is: refusing it is the
  // catalogue's, so the refusal is `invalid_name` and not `bad_request`.
  list.each(["", "   ", "line\nbreak", string.repeat("x", 1024)], fn(name) {
    assert protocol.decode(
        envelope(3, "principals.rename", [
          #("name", json.String(name)),
          #("epoch", json.String("e1")),
        ]),
      )
      == Ok(protocol.Request(3, protocol.RenamePrincipal(None, name, "e1")))
  })
}

pub fn principal_rename_refuses_malformed_requests_test() {
  let epoch = #("epoch", json.String("e1"))
  list.each(
    [
      // No name, a name that is not text, a name past the frame's bound.
      [epoch],
      [#("name", json.Null), epoch],
      [#("name", json.Int(1)), epoch],
      [#("name", json.Array([])), epoch],
      [#("name", json.String(string.repeat("x", 1025))), epoch],

      // A principal that is not text, empty or past its bound.
      [#("name", json.String("Mira")), #("principal_id", json.Int(1)), epoch],
      [
        #("name", json.String("Mira")),
        #("principal_id", json.String("")),
        epoch,
      ],
      [
        #("name", json.String("Mira")),
        #("principal_id", json.String(string.repeat("x", 129))),
        epoch,
      ],

      // No epoch, or one that is not text.
      [#("name", json.String("Mira"))],
      [#("name", json.String("Mira")), #("epoch", json.Int(1))],
    ],
    fn(fields) {
      assert result.is_error(
        protocol.decode(envelope(4, "principals.rename", fields)),
      )
    },
  )
}

pub fn creation_profile_is_optional_and_must_be_a_profile_name_test() {
  let fields = [
    #("request_key", json.String("key")),
    #("workspace", json.String("/workspace")),
    #("name", json.String("name")),
    #("configuration", json.String("")),
  ]
  assert protocol.decode(
      envelope(1, "sessions.create", [
        #("profile", json.String("deepseek")),
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
        Some("deepseek"),
        None,
        domain.WorkspacePrivate,
      ),
    ))

  // Anything present that is not a profile name is refused, never read as the
  // default: a misspelled profile must not create a default-roles session.
  list.each(
    [
      json.String(""),
      json.String("Deep Seek"),
      json.String("9lives"),
      json.String(string.repeat("a", 33)),
      json.Null,
      json.Int(1),
    ],
    fn(value) {
      let assert Error(_) =
        protocol.decode(
          envelope(1, "sessions.create", [#("profile", value), ..fields]),
        )
        as "profile must be a profile name"
    },
  )
}

pub fn session_creation_decodes_an_optional_model_key_test() {
  let fields = [
    #("request_key", json.String("key")),
    #("workspace", json.String("/workspace")),
    #("name", json.String("name")),
    #("configuration", json.String("")),
  ]
  assert protocol.decode(
      envelope(1, "sessions.create", [
        #("model", json.String("baseten-glm-5-3")),
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
        None,
        Some("baseten-glm-5-3"),
        domain.WorkspacePrivate,
      ),
    ))

  // A model key has no grammar beyond its bound, so a key with spaces or dots
  // is carried through and the daemon's catalogue is what judges it.
  let assert Ok(protocol.Request(
    _,
    protocol.CreateSession(model: Some("opus 4.8"), ..),
  )) =
    protocol.decode(
      envelope(1, "sessions.create", [
        #("model", json.String("opus 4.8")),
        ..fields
      ]),
    )
    as "a key is any text within its bound"

  // Anything present that is not a key is refused, never read as no choice: a
  // misspelled model must not create a default-model session.
  list.each(
    [
      json.String(""),
      json.String(string.repeat("k", 65)),
      json.Null,
      json.Int(1),
    ],
    fn(value) {
      let assert Error(_) =
        protocol.decode(
          envelope(1, "sessions.create", [#("model", value), ..fields]),
        )
        as "model must be a model key"
    },
  )
}
