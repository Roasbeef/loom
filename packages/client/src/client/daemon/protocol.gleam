//// The bounded version-two daemon control envelope from protocol-change/015.
////
//// Decoding proves only wire shape and scalar limits. Credential authority,
//// canonical workspace policy, epoch fencing, and lifecycle admission belong
//// to the server and its serialized manager. Conversation frames use a separate
//// codec; a control connection cannot retarget itself into a session stream.

import core/ids
import core/json.{type JsonValue}
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import storage/access
import storage/domain

/// The only control envelope version accepted by this module.
pub const version = 2

/// A complete control frame or fragmented message may contain at most 64 KiB.
pub const max_bytes = 65_536

/// Decoded requests carry no client-supplied principal or database path.
pub type Command {
  /// Changes only display metadata under owner authority in this daemon epoch.
  RenameSession(session_id: String, name: String, epoch: String)

  /// Prospectively isolates a stopped session after explicit transcript consent.
  IsolateSession(session_id: String, epoch: String)

  /// Creates a stable member identity with one initial session membership.
  Invite(
    session_id: String,
    principal_id: String,
    name: String,
    role: access.Role,
    epoch: String,
  )

  /// Changes one member's session role.
  SetRole(
    session_id: String,
    principal_id: String,
    role: access.Role,
    epoch: String,
  )

  /// Removes one membership without affecting other sessions.
  RevokeMembership(session_id: String, principal_id: String, epoch: String)

  /// Replaces all credentials of a member identified by its recovery ID.
  RotateCredential(principal_id: String, epoch: String)

  /// Revokes all credentials of a member without deleting its identity.
  RevokeCredentials(principal_id: String, epoch: String)

  /// Reads daemon readiness and aggregate capacity counts.
  Status

  /// Lists authorized metadata after one canonical identity.
  ListSessions(after: String, revision: Option(Int))

  /// Reads one authorized registration without opening its conversation.
  GetSession(session_id: String)

  /// Reads the owner's durable workspace selection.
  WorkspaceDefault(workspace: String)

  /// Changes the owner's workspace selection without starting work.
  SetDefault(workspace: String, session_id: String)

  /// Reserves durable identity and explicitly initializes the new session.
  CreateSession(
    request_key: String,
    workspace: String,
    name: String,
    configuration: String,
    domain_scope: domain.Scope,
  )

  /// Explicitly requests execution in the named daemon epoch.
  OpenSession(session_id: String, epoch: String)

  /// Requests ordered cleanup without deleting the conversation.
  StopSession(session_id: String, epoch: String)

  /// Removes a stopped registration and its conversation database.
  DeleteSession(session_id: String, epoch: String)

  /// Observes only the named operation, never a replacement incarnation.
  GetOperation(session_id: String, operation: String, epoch: String)

  /// Requests owner-authorized daemon drain.
  Shutdown(epoch: String)
}

/// A positive request ID is local to one authenticated control connection.
pub type Request {
  Request(
    /// The reply correlation chosen by the client.
    id: Int,
    /// The decoded operation, before authorization or admission.
    command: Command,
  )
}

/// A bounded refusal contains no input frame, credential, or private path.
pub type Fault {
  Fault(
    /// A valid request ID when one was available before the failure.
    reply_to: Option(Int),
    /// A stable machine-readable refusal category.
    code: String,
    /// A fixed diagnostic naming the invalid shape, not its supplied value.
    message: String,
  )
}

/// Decodes a complete bounded control message without invoking any effect.
///
/// The byte bound precedes parsing. The shared JSON parser also rejects duplicate
/// keys and excessive nesting, so downstream field lookup has one interpretation.
///
/// ## Examples
///
/// ```gleam
/// assert protocol.decode("{\"v\":2,\"id\":1,\"cmd\":\"status\",\"body\":{}}")
///   == Ok(protocol.Request(1, protocol.Status))
/// ```
pub fn decode(text: String) -> Result(Request, Fault) {
  use Nil <- result.try(within_limit(text, None))
  use value <- result.try(
    json.parse(text)
    |> result.replace_error(Fault(
      None,
      "malformed",
      "expected a valid JSON control envelope",
    )),
  )
  use fields <- result.try(
    object(value)
    |> result.map_error(fn(reason) { Fault(None, "bad_envelope", reason) }),
  )
  let reply_to = case list.key_find(fields, "id") {
    Ok(json.Int(id)) if id > 0 -> Some(id)
    Ok(_) | Error(Nil) -> None
  }
  use Nil <- result.try(case list.key_find(fields, "v") {
    Ok(json.Int(2)) -> Ok(Nil)
    Ok(_) | Error(Nil) ->
      Error(Fault(
        reply_to,
        "unsupported_version",
        "expected protocol version 2",
      ))
  })
  use id <- result.try(case reply_to {
    Some(id) -> Ok(id)
    None -> Error(Fault(None, "bad_envelope", "expected a positive request id"))
  })
  use command <- result.try(
    decode_fields(fields)
    |> result.map_error(fn(reason) { Fault(Some(id), "bad_request", reason) }),
  )
  Ok(Request(id, command))
}

fn decode_fields(
  fields: List(#(String, JsonValue)),
) -> Result(Command, String) {
  use name <- result.try(text_field(fields, "cmd", 64))
  use body <- result.try(required(fields, "body"))
  use fields <- result.try(object(body))
  case name {
    "sessions.rename" -> {
      use id <- result.try(session_id(fields))
      use name <- result.try(text_field(fields, "name", 256))
      use epoch <- result.map(text_field(fields, "epoch", 256))
      RenameSession(id, name, epoch)
    }
    "sessions.isolate" -> {
      use id <- result.try(session_id(fields))
      use transcript <- result.try(text_field(fields, "transcript", 32))
      use Nil <- result.try(case transcript {
        "share_existing" -> Ok(Nil)
        _other ->
          Error(
            "explicit share_existing transcript acknowledgement is required",
          )
      })
      use epoch <- result.map(text_field(fields, "epoch", 256))
      IsolateSession(id, epoch)
    }
    "sessions.invite" -> {
      use session <- result.try(session_id(fields))
      use principal <- result.try(text_field(fields, "principal_id", 128))
      use name <- result.try(text_field(fields, "name", 256))
      use role <- result.try(member_role(fields))
      use epoch <- result.map(text_field(fields, "epoch", 256))
      Invite(session, principal, name, role, epoch)
    }
    "sessions.set_role" -> {
      use session <- result.try(session_id(fields))
      use principal <- result.try(text_field(fields, "principal_id", 128))
      use role <- result.try(member_role(fields))
      use epoch <- result.map(text_field(fields, "epoch", 256))
      SetRole(session, principal, role, epoch)
    }
    "sessions.revoke" -> {
      use session <- result.try(session_id(fields))
      use principal <- result.try(text_field(fields, "principal_id", 128))
      use epoch <- result.map(text_field(fields, "epoch", 256))
      RevokeMembership(session, principal, epoch)
    }
    "credentials.rotate" -> {
      use principal <- result.try(text_field(fields, "principal_id", 128))
      use epoch <- result.map(text_field(fields, "epoch", 256))
      RotateCredential(principal, epoch)
    }
    "credentials.revoke" -> {
      use principal <- result.try(text_field(fields, "principal_id", 128))
      use epoch <- result.map(text_field(fields, "epoch", 256))
      RevokeCredentials(principal, epoch)
    }
    "status" -> Ok(Status)
    "sessions.list" -> {
      use after <- result.try(cursor(fields))
      use revision <- result.try(optional_revision(fields))
      Ok(ListSessions(after, revision))
    }
    "sessions.get" -> result.map(session_id(fields), GetSession)
    "sessions.default" ->
      result.map(text_field(fields, "workspace", 4096), WorkspaceDefault)
    "sessions.set_default" -> {
      use workspace <- result.try(text_field(fields, "workspace", 4096))
      use id <- result.map(session_id(fields))
      SetDefault(workspace, id)
    }
    "sessions.create" -> {
      use key <- result.try(text_field(fields, "request_key", 256))
      use workspace <- result.try(text_field(fields, "workspace", 4096))
      use name <- result.try(text_field(fields, "name", 256))
      use configuration <- result.try(configuration_field(fields))
      use scope <- result.map(domain_scope(fields))
      CreateSession(key, workspace, name, configuration, scope)
    }
    "sessions.open" -> {
      use id <- result.try(session_id(fields))
      use epoch <- result.map(text_field(fields, "epoch", 256))
      OpenSession(id, epoch)
    }
    "sessions.stop" -> {
      use id <- result.try(session_id(fields))
      use epoch <- result.map(text_field(fields, "epoch", 256))
      StopSession(id, epoch)
    }
    "sessions.delete" -> {
      use id <- result.try(session_id(fields))
      use epoch <- result.map(text_field(fields, "epoch", 256))
      DeleteSession(id, epoch)
    }
    "operations.get" -> {
      use id <- result.try(session_id(fields))
      use operation <- result.try(text_field(fields, "operation", 512))
      use epoch <- result.map(text_field(fields, "epoch", 256))
      GetOperation(id, operation, epoch)
    }
    "daemon.shutdown" -> result.map(text_field(fields, "epoch", 256), Shutdown)
    _unknown -> Error("unsupported control command")
  }
}

fn domain_scope(fields) {
  case list.key_find(fields, "domain_scope") {
    Error(Nil) | Ok(json.String("workspace_private")) ->
      Ok(domain.WorkspacePrivate)
    Ok(json.String("session_only")) -> Ok(domain.SessionOnly)
    Ok(_) -> Error("expected workspace_private or session_only domain_scope")
  }
}

fn member_role(fields) {
  use text <- result.try(text_field(fields, "role", 16))
  case text {
    "operator" -> Ok(access.Operator)
    "observer" -> Ok(access.Observer)
    _other -> Error("expected operator or observer")
  }
}

fn object(value: JsonValue) -> Result(List(#(String, JsonValue)), String) {
  case value {
    json.Object(fields) -> Ok(fields)
    _other -> Error("expected a JSON object")
  }
}

fn required(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(JsonValue, String) {
  list.key_find(fields, key) |> result.map_error(fn(_) { "missing " <> key })
}

fn text_field(
  fields: List(#(String, JsonValue)),
  key: String,
  limit: Int,
) -> Result(String, String) {
  use value <- result.try(required(fields, key))
  case value {
    json.String(text) if text != "" -> {
      case bit_array.byte_size(bit_array.from_string(text)) <= limit {
        True -> Ok(text)
        False -> Error("text field exceeds its byte limit")
      }
    }
    _other -> Error("expected nonempty text field")
  }
}

// An empty registration selects the daemon's runtime defaults. Keep this
// exception on the configuration field, not on identities or display names.
fn configuration_field(
  fields: List(#(String, JsonValue)),
) -> Result(String, String) {
  case list.key_find(fields, "configuration") {
    Ok(json.String("")) -> Ok("")
    Ok(_) | Error(Nil) -> text_field(fields, "configuration", 4096)
  }
}

fn session_id(fields: List(#(String, JsonValue))) -> Result(String, String) {
  use text <- result.try(text_field(fields, "session_id", 64))
  canonical_id(text)
}

fn canonical_id(text: String) -> Result(String, String) {
  ids.parse_session_id(text)
  |> result.replace(text)
  |> result.replace_error("expected a canonical session id")
}

fn cursor(fields: List(#(String, JsonValue))) -> Result(String, String) {
  case list.key_find(fields, "after") {
    Ok(json.String("")) -> Ok("")
    Ok(json.String(text)) -> canonical_id(text)
    Ok(_) | Error(Nil) -> Error("expected a session cursor")
  }
}

fn optional_revision(
  fields: List(#(String, JsonValue)),
) -> Result(Option(Int), String) {
  case list.key_find(fields, "revision") {
    Error(Nil) -> Ok(None)
    Ok(json.Int(revision)) if revision >= 0 -> Ok(Some(revision))
    Ok(_) -> Error("expected a nonnegative catalogue revision")
  }
}

/// Encodes one version-two event, refusing an oversized outbound message.
///
/// Callers build authorized metadata first. The encoder cannot redact a record
/// that the caller should never have read or selected.
///
/// ## Examples
///
/// ```gleam
/// // protocol.event(Some(1), "status", json.Object([]))
/// ```
pub fn event(
  reply_to: Option(Int),
  name: String,
  body: JsonValue,
) -> Result(String, Fault) {
  let correlation = case reply_to {
    None -> []
    Some(id) -> [#("reply_to", json.Int(id))]
  }
  let text =
    json.to_string(
      json.Object([
        #("v", json.Int(version)),
        #("event", json.String(name)),
        #("body", body),
        ..correlation
      ]),
    )
  use Nil <- result.map(within_limit(text, reply_to))
  text
}

fn within_limit(text: String, reply_to: Option(Int)) -> Result(Nil, Fault) {
  case bit_array.byte_size(bit_array.from_string(text)) <= max_bytes {
    True -> Ok(Nil)
    False ->
      Error(Fault(reply_to, "too_large", "control message exceeds 64 KiB"))
  }
}
