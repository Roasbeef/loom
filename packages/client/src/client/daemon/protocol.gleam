//// The bounded version-two daemon control envelope from protocol-change/015.
////
//// Decoding proves only wire shape and scalar limits. Credential authority,
//// canonical workspace policy, epoch fencing, and lifecycle admission belong
//// to the server and its serialized manager. Conversation frames use a separate
//// codec; a control connection cannot retarget itself into a session stream.
////
//// ## Flow
////
//// `decode` bounds the envelope and passes command fields to `decode_fields`.
//// `accepted_features` bounds decoder claims; `workspace_selection` preserves
//// typed creation intent. `decode_claim` handles enrollment separately, and
//// `event` encodes control replies without granting session-stream authority.

import client/peer_mail
import core/ids
import core/json.{type JsonValue}
import core/workspace
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import storage/access
import storage/domain

/// The only control envelope version accepted by this module.
pub const version = 2

/// A complete control frame or fragmented message may contain at most 64 KiB.
pub const max_bytes = 65_536

/// The most sessions one `sessions.activity` request may name. Each answer
/// is bounded to 2,400 encoded bytes, so this many fit the 60,000-byte reply
/// budget without a page cursor.
pub const activity_limit = 24

/// Decoded requests carry no client-supplied principal or database path.
/// Whether a home link's exchange sets a browser login (protocol-change/065).
pub type Remembering {
  /// The exchange sets the login, so the next visit needs no `loom ui`.
  Remember

  /// The exchange opens the page and sets nothing: `loom ui --no-remember`.
  Forget
}

pub type Command {
  /// Reads both directions of one resident strand's operator peer grants.
  InspectPeers(
    source_session: String,
    source_strand: String,
    after: Option(String),
    epoch: String,
  )

  /// Grants exact directional peer delivery without granting join or custody.
  LinkPeers(
    source_session: String,
    source_strand: String,
    target_session: String,
    target_strand: String,
    wake: peer_mail.Wake,
    epoch: String,
  )

  /// Sends on behalf of an exact source strand after owner authorization.
  SendPeer(
    /// Resident session on whose behalf the owner sends.
    source_session: String,
    /// Source strand whose outgoing link authorizes delivery.
    source_strand: String,
    /// Resident recipient session.
    target_session: String,
    /// Exact recipient strand named by the grant.
    target_strand: String,
    /// Stable identity reused only for the same target and body.
    message_id: String,
    /// Message data, never source code or caller-supplied authority.
    text: String,
    /// Current daemon epoch, checked before resolving either session.
    epoch: String,
  )

  /// Revokes one directional peer delivery permission.
  UnlinkPeers(
    source_session: String,
    source_strand: String,
    target_session: String,
    target_strand: String,
    epoch: String,
  )

  /// Changes only display metadata under owner authority in this daemon epoch.
  RenameSession(session_id: String, name: String, epoch: String)

  /// Prospectively isolates a stopped session after explicit transcript consent.
  IsolateSession(session_id: String, epoch: String)

  /// Creates a stable member identity with one initial session membership.
  /// The member receives either a claim or the credential digest it sent
  /// (protocol-change/053); no reply carries a bearer.
  Invite(
    session_id: String,
    principal_id: String,
    name: String,
    role: access.Role,
    enrollment: Enrollment,
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

  /// Voids the open claim and revokes every credential of a member identified
  /// by its recovery ID, then issues a new claim or binds the sent digest.
  RotateCredential(principal_id: String, enrollment: Enrollment, epoch: String)

  /// Revokes all credentials of a member and voids its open claim, without
  /// deleting its identity.
  RevokeCredentials(principal_id: String, epoch: String)

  /// Lists principals after one principal ID, each with the state of its
  /// credential (protocol-change/053). Owner-only. An empty cursor starts the
  /// listing.
  ListPrincipals(after: String)

  /// Lists one principal's session memberships after one session ID.
  /// Owner-only. An empty cursor starts the listing.
  PrincipalMemberships(principal_id: String, after: String)

  /// Lists a principal's browser logins, its sign-ins, after one fingerprint
  /// (protocol-change/065, PR 8). A member omits the principal and reads its
  /// own; the owner may name any principal. An empty cursor starts the listing.
  CredentialSignins(principal_id: Option(String), after: String)

  /// Revokes one browser login, named by its fingerprint. A member omits the
  /// principal and revokes its own; the owner may name any principal. Every page
  /// the login minted ends at its next frame.
  RevokeLogin(principal_id: Option(String), fingerprint: String, epoch: String)

  /// Changes one principal's display name (protocol-change/065, PR 10). A member
  /// omits the principal and renames itself; the owner may name any member and
  /// itself. `name` is unjudged here: the catalogue trims it and applies the rule
  /// a claim's chosen name is held to, and a refused name is `invalid_name`.
  RenamePrincipal(principal_id: Option(String), name: String, epoch: String)

  /// Lists one session's members after one principal ID, each with its display
  /// name and role in that session (protocol-change/065). Owner-only. An empty
  /// cursor starts the listing.
  SessionMembers(session_id: String, after: String)

  /// Reads daemon readiness and aggregate capacity counts.
  Status

  /// Mints a single-use ticket that lets this principal's browser open the
  /// web view of one session (protocol-change/051), or, when `session_id` is
  /// `None`, the principal's home page (protocol-change/065). Served only
  /// when the daemon was started with `--ui`. `page` is the page's ceiling,
  /// from the optional `page` field: `observer` when absent, `operator` only
  /// when the launcher was asked for an operator's page. It caps the
  /// membership role and never grants one. `remember` is meaningful only for
  /// the home: it says whether the exchange sets a browser login
  /// (protocol-change/065), and absent is `Remember`.
  UiLink(
    session_id: Option(String),
    page: access.Role,
    remember: Option(Remembering),
  )

  /// Lists authorized metadata after one canonical identity.
  ListSessions(after: String, revision: Option(Int))

  /// Asks the named resident sessions what they are doing
  /// (`protocol-change/050`). Owner-only; saved sessions are never opened.
  SessionActivity(
    /// Between one and `activity_limit` distinct canonical identities, in
    /// the order the reply keeps.
    sessions: List(String),
    /// Current daemon epoch, checked before any session is resolved.
    epoch: String,
  )

  /// Lists the owner's archived metadata without admitting execution.
  ListArchivedSessions(after: String, revision: Option(Int))

  /// Preserves a stopped session outside ordinary listings.
  ArchiveSession(session_id: String, epoch: String)

  /// Makes a stopped archived session eligible for explicit admission again.
  RestoreSession(session_id: String, epoch: String)

  /// Reads one authorized registration without opening its conversation.
  GetSession(session_id: String)

  /// Reads the owner's durable workspace selection.
  WorkspaceDefault(workspace: workspace.WorkspaceKey)

  /// Changes the owner's workspace selection without starting work.
  SetDefault(workspace: workspace.WorkspaceKey, session_id: String)

  /// Reserves durable identity and explicitly initializes the new session.
  CreateSession(
    request_key: String,
    workspace: workspace.Selection,
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

/// What an invitation or rotation gives the member, as the request chose it.
pub type Enrollment {
  /// A single-use claim token living `ttl_ms` milliseconds, between
  /// `min_claim_ttl_ms` and `max_claim_ttl_ms`. The default when the request
  /// names neither field.
  IssueClaim(ttl_ms: Int)

  /// The digest of a credential the invitee drew itself (`credential_digest`);
  /// no claim is created and the reply carries no secret.
  EnrollDigest(credential: access.Digest)
}

/// A claim lives this long when the request does not set `claim_ttl_ms`.
pub const default_claim_ttl_ms = 86_400_000

/// The shortest `claim_ttl_ms` a request may set: five minutes.
pub const min_claim_ttl_ms = 300_000

/// The longest `claim_ttl_ms` a request may set: seven days.
pub const max_claim_ttl_ms = 604_800_000

/// The largest message the `/v2/claim` socket accepts. Its one command carries
/// a 64-character digest and an optional display name of at most 256 bytes,
/// so this leaves room for the envelope and the name's escapes and no more.
pub const max_claim_bytes = 1024

/// The one command `/v2/claim` accepts, decoded apart from the control
/// commands so that `credentials.claim` never reaches `/v2/control` and no
/// control command reaches `/v2/claim`.
pub type ClaimRequest {
  ClaimRequest(
    /// The client's correlation for the one reply.
    id: Int,
    /// The digest of the credential the invitee drew and stored.
    credential: access.Digest,
    /// The display name the invitee chose, unjudged: the catalogue trims and
    /// checks it in the transaction that binds, and `None` keeps the
    /// inviter's.
    name: Option(String),
  )
}

/// A positive request ID is local to one authenticated control connection.
pub type Request {
  Request(
    /// The reply correlation chosen by the client.
    id: Int,
    /// The decoded operation, before authorization or admission.
    command: Command,
    /// Up to eight distinct 1..64-byte ASCII tokens (0x21..0x7e, no spaces).
    /// These assert decoder support for this request only.
    accepts: List(String),
  )
}

/// A bounded refusal contains no input frame or credential. Protocol 055
/// permits configuration paths in authorized exact-operation startup errors.
pub type Fault {
  Fault(
    /// A valid request ID when one was available before the failure.
    reply_to: Option(Int),
    /// A stable machine-readable refusal category.
    code: String,
    /// A fixed invalid-shape diagnostic, or the authorized operation's startup
    /// reason of at most 2048 UTF-8 bytes (protocol 055).
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
///   == Ok(protocol.Request(1, protocol.Status, []))
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
  use accepts <- result.try(
    accepted_features(fields)
    |> result.map_error(fn(reason) { Fault(Some(id), "bad_request", reason) }),
  )
  Ok(Request(id, command, accepts))
}

fn decode_fields(
  fields: List(#(String, JsonValue)),
) -> Result(Command, String) {
  use name <- result.try(text_field(fields, "cmd", 64))
  use body <- result.try(required(fields, "body"))
  use fields <- result.try(object(body))
  case name {
    "peers.inspect" -> {
      use source <- result.try(text_field(fields, "source_session", 128))
      use _ <- result.try(
        ids.parse_session_id(source)
        |> result.replace_error("invalid source session id"),
      )
      use strand <- result.try(text_field(fields, "source_strand", 512))
      use after <- result.try(optional_after(fields))
      use epoch <- result.try(text_field(fields, "epoch", 256))
      Ok(InspectPeers(source, strand, after, epoch))
    }
    "peers.link" | "peers.unlink" | "peers.send" -> {
      use source <- result.try(text_field(fields, "source_session", 128))
      use _ <- result.try(
        ids.parse_session_id(source)
        |> result.replace_error("invalid source session id"),
      )
      use from <- result.try(text_field(fields, "source_strand", 512))
      use target <- result.try(text_field(fields, "target_session", 128))
      use _ <- result.try(
        ids.parse_session_id(target)
        |> result.replace_error("invalid target session id"),
      )
      use to <- result.try(text_field(fields, "target_strand", 512))
      use epoch <- result.try(text_field(fields, "epoch", 256))
      case name {
        "peers.unlink" -> Ok(UnlinkPeers(source, from, target, to, epoch))
        "peers.send" -> {
          use id <- result.try(text_field(fields, "message_id", 128))
          use text <- result.try(text_field(fields, "text", 32_768))
          Ok(SendPeer(source, from, target, to, id, text, epoch))
        }
        _ -> {
          use wake <- result.try(text_field(fields, "wake", 32))
          use wake <- result.try(case wake {
            "busy_only" -> Ok(peer_mail.BusyOnly)
            "may_wake" -> Ok(peer_mail.MayWake)
            _ -> Error("wake must be busy_only or may_wake")
          })
          Ok(LinkPeers(source, from, target, to, wake, epoch))
        }
      }
    }
    "sessions.rename" -> {
      use id <- result.try(session_id(fields))
      use name <- result.try(text_field(fields, "name", 256))
      use epoch <- result.map(text_field(fields, "epoch", 256))
      RenameSession(id, name, epoch)
    }
    "sessions.archive" -> {
      use id <- result.try(session_id(fields))
      use epoch <- result.map(text_field(fields, "epoch", 256))
      ArchiveSession(id, epoch)
    }
    "sessions.restore" -> {
      use id <- result.try(session_id(fields))
      use epoch <- result.map(text_field(fields, "epoch", 256))
      RestoreSession(id, epoch)
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
      use enrollment <- result.try(enrollment(fields))
      use epoch <- result.map(text_field(fields, "epoch", 256))
      Invite(session, principal, name, role, enrollment, epoch)
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
      use enrollment <- result.try(enrollment(fields))
      use epoch <- result.map(text_field(fields, "epoch", 256))
      RotateCredential(principal, enrollment, epoch)
    }
    "credentials.revoke" -> {
      use principal <- result.try(text_field(fields, "principal_id", 128))
      use epoch <- result.map(text_field(fields, "epoch", 256))
      RevokeCredentials(principal, epoch)
    }
    "principals.list" -> {
      use after <- result.map(case list.key_find(fields, "after") {
        Error(Nil) -> Ok("")
        Ok(_) -> text_field(fields, "after", 128)
      })
      ListPrincipals(after)
    }
    "principals.memberships" -> {
      use principal <- result.try(text_field(fields, "principal_id", 128))
      use after <- result.map(case list.key_find(fields, "after") {
        Error(Nil) -> Ok("")
        Ok(json.String(text)) -> canonical_id(text)
        Ok(_) -> Error("expected a session cursor")
      })
      PrincipalMemberships(principal, after)
    }
    "credentials.signins" -> {
      use target <- result.try(optional_principal(fields))
      use after <- result.map(case list.key_find(fields, "after") {
        Error(Nil) -> Ok("")
        Ok(json.String("")) -> Ok("")
        Ok(_) -> fingerprint_field(fields, "after")
      })
      CredentialSignins(target, after)
    }
    "principals.rename" -> {
      use target <- result.try(optional_principal(fields))
      use name <- result.try(name_field(fields))
      use epoch <- result.map(text_field(fields, "epoch", 256))
      RenamePrincipal(target, name, epoch)
    }
    "credentials.revoke_login" -> {
      use target <- result.try(optional_principal(fields))
      use fingerprint <- result.try(fingerprint_field(fields, "fingerprint"))
      use epoch <- result.map(text_field(fields, "epoch", 256))
      RevokeLogin(target, fingerprint, epoch)
    }

    "sessions.members" -> {
      use session <- result.try(session_id(fields))
      use after <- result.map(case list.key_find(fields, "after") {
        Error(Nil) -> Ok("")
        Ok(_) -> text_field(fields, "after", 128)
      })
      SessionMembers(session, after)
    }
    "status" -> Ok(Status)
    "ui.link" -> {
      use id <- result.try(optional_session_id(fields))
      use page <- result.try(page_ceiling(fields))
      use remember <- result.try(remembering(fields))
      case id, remember {
        Some(_), Some(_) ->
          Error("remember applies to the home link and not to a session's")
        _, _ -> Ok(UiLink(id, page, remember))
      }
    }
    "sessions.list" -> {
      use after <- result.try(cursor(fields))
      use revision <- result.try(optional_revision(fields))
      Ok(ListSessions(after, revision))
    }
    "sessions.activity" -> {
      use sessions <- result.try(activity_sessions(fields))
      use epoch <- result.map(text_field(fields, "epoch", 256))
      SessionActivity(sessions, epoch)
    }
    "sessions.archived" -> {
      use after <- result.try(cursor(fields))
      use revision <- result.try(optional_revision(fields))
      Ok(ListArchivedSessions(after, revision))
    }
    "sessions.get" -> result.map(session_id(fields), GetSession)
    "sessions.default" -> result.map(workspace_key(fields), WorkspaceDefault)
    "sessions.set_default" -> {
      use workspace <- result.try(workspace_key(fields))
      use id <- result.map(session_id(fields))
      SetDefault(workspace, id)
    }
    "sessions.create" -> {
      use key <- result.try(text_field(fields, "request_key", 256))
      use workspace <- result.try(workspace_selection(fields))
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

// The two optional enrollment fields are exclusive. A digest enrolls the
// invitee's own credential and creates no claim, so a lifetime for a claim
// that will not exist names nothing and is refused rather than ignored.
fn enrollment(
  fields: List(#(String, JsonValue)),
) -> Result(Enrollment, String) {
  case
    list.key_find(fields, "claim_ttl_ms"),
    list.key_find(fields, "credential_digest")
  {
    Error(Nil), Error(Nil) -> Ok(IssueClaim(default_claim_ttl_ms))
    Ok(json.Int(ttl)), Error(Nil)
      if ttl >= min_claim_ttl_ms && ttl <= max_claim_ttl_ms
    -> Ok(IssueClaim(ttl))
    Ok(_), Error(Nil) ->
      Error("claim_ttl_ms must be between 300000 and 604800000")
    Error(Nil), Ok(_) ->
      digest_field(fields, "credential_digest") |> result.map(EnrollDigest)
    Ok(_), Ok(_) ->
      Error("credential_digest and claim_ttl_ms are mutually exclusive")
  }
}

fn digest_field(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(access.Digest, String) {
  use text <- result.try(text_field(fields, key, 64))
  access.credential_digest(text)
  |> result.replace_error("expected a 64-character lowercase hex digest")
}

/// Decodes the one `/v2/claim` message without invoking any effect.
///
/// The byte bound precedes parsing, and only `credentials.claim` is
/// accepted: a control command sent here is refused as `bad_request`, and
/// `decode` refuses `credentials.claim` on the control socket.
///
/// ## Examples
///
/// ```gleam
/// let digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
/// let assert Ok(request) =
///   protocol.decode_claim(
///     "{\"v\":2,\"id\":1,\"cmd\":\"credentials.claim\",\"body\":{\"credential_digest\":\""
///     <> digest
///     <> "\"}}",
///   )
/// assert request.id == 1
/// ```
pub fn decode_claim(text: String) -> Result(ClaimRequest, Fault) {
  use Nil <- result.try(
    case bit_array.byte_size(bit_array.from_string(text)) <= max_claim_bytes {
      True -> Ok(Nil)
      False -> Error(Fault(None, "bad_request", "claim message exceeds 1 KiB"))
    },
  )

  // Every shape fault is `bad_request`, the one refusal protocol-change/053
  // gives this route for a message it cannot use.
  use value <- result.try(
    json.parse(text)
    |> result.replace_error(Fault(
      None,
      "bad_request",
      "expected a valid JSON claim envelope",
    )),
  )
  use fields <- result.try(
    object(value)
    |> result.map_error(fn(reason) { Fault(None, "bad_request", reason) }),
  )
  use id <- result.try(
    case list.key_find(fields, "v"), list.key_find(fields, "id") {
      Ok(json.Int(2)), Ok(json.Int(id)) if id > 0 -> Ok(id)
      _, _ ->
        Error(Fault(
          None,
          "bad_request",
          "expected protocol version 2 and a positive request id",
        ))
    },
  )
  let claim = {
    use name <- result.try(text_field(fields, "cmd", 64))
    use Nil <- result.try(case name {
      "credentials.claim" -> Ok(Nil)
      _other -> Error("the claim endpoint accepts only credentials.claim")
    })
    use body <- result.try(required(fields, "body"))
    use body <- result.try(object(body))
    use credential <- result.try(digest_field(body, "credential_digest"))
    use name <- result.map(case list.key_find(body, "name") {
      Error(Nil) -> Ok(None)
      Ok(json.String(chosen)) -> Ok(Some(chosen))
      Ok(_) -> Error("expected name to be text")
    })
    #(credential, name)
  }
  case claim {
    Ok(#(credential, name)) -> Ok(ClaimRequest(id, credential, name))
    Error(reason) -> Error(Fault(Some(id), "bad_request", reason))
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

// A display name as the wire carries it: any text of at most 1024 bytes, blank
// included, so that the catalogue's rule is the only one that judges it and a
// name it refuses is `invalid_name` rather than a malformed request. The bound
// only keeps a frame from carrying a megabyte to the catalogue.
fn name_field(fields: List(#(String, JsonValue))) -> Result(String, String) {
  use value <- result.try(required(fields, "name"))
  case value {
    json.String(text) ->
      case bit_array.byte_size(bit_array.from_string(text)) <= 1024 {
        True -> Ok(text)
        False -> Error("text field exceeds its byte limit")
      }
    _other -> Error("expected name to be text")
  }
}

fn optional_after(
  fields: List(#(String, JsonValue)),
) -> Result(Option(String), String) {
  case list.key_find(fields, "after") {
    Error(Nil) -> Ok(None)
    Ok(json.String(after)) if after != "" -> {
      case bit_array.byte_size(bit_array.from_string(after)) <= 4096 {
        True -> Ok(Some(after))
        False -> Error("peer cursor exceeds its byte limit")
      }
    }
    Ok(_) -> Error("expected nonempty peer cursor")
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

// A session identity that may be left out. An absent field is the request
// for a home page (protocol-change/065); a field that is present must be a
// canonical identity, so a malformed one is refused and never read as a home.
fn optional_session_id(
  fields: List(#(String, JsonValue)),
) -> Result(Option(String), String) {
  case list.key_find(fields, "session_id") {
    Error(Nil) -> Ok(None)
    Ok(_) -> session_id(fields) |> result.map(Some)
  }
}

// A principal the command names, or none when it is absent, which means the
// caller's own.
fn optional_principal(
  fields: List(#(String, JsonValue)),
) -> Result(Option(String), String) {
  case list.key_find(fields, "principal_id") {
    Error(Nil) -> Ok(None)
    Ok(_) -> text_field(fields, "principal_id", 128) |> result.map(Some)
  }
}

// A login's fingerprint: the first sixteen hexadecimal digits of its digest,
// lowercase, which is the whole of how a login is named on the wire.
fn fingerprint_field(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(String, String) {
  use text <- result.try(text_field(fields, key, 16))
  case
    bit_array.byte_size(bit_array.from_string(text)) == 16
    && list.all(string.to_graphemes(text), fn(digit) {
      string.contains("0123456789abcdef", digit)
    })
  {
    True -> Ok(text)
    False -> Error("expected a 16-digit lowercase hex fingerprint")
  }
}

// Whether a home link's exchange sets a browser login. Absent is no answer,
// which the daemon reads as `Remember`.
fn remembering(
  fields: List(#(String, JsonValue)),
) -> Result(Option(Remembering), String) {
  case list.key_find(fields, "remember") {
    Error(Nil) -> Ok(None)
    Ok(json.Bool(True)) -> Ok(Some(Remember))
    Ok(json.Bool(False)) -> Ok(Some(Forget))
    Ok(_) -> Error("remember must be true or false")
  }
}

// A page's ceiling. An absent field is an observer's page, which is what
// a launcher that predates the field asks for.
fn page_ceiling(
  fields: List(#(String, JsonValue)),
) -> Result(access.Role, String) {
  case list.key_find(fields, "page") {
    Error(Nil) -> Ok(access.Observer)
    Ok(json.String("observer")) -> Ok(access.Observer)
    Ok(json.String("operator")) -> Ok(access.Operator)
    Ok(_) -> Error("page must be \"observer\" or \"operator\"")
  }
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

// The identity list is refused whole rather than truncated or deduplicated:
// a reply shorter than the request must mean "these sessions are not
// resident", never "the server dropped some of what you asked".
fn activity_sessions(
  fields: List(#(String, JsonValue)),
) -> Result(List(String), String) {
  use values <- result.try(case list.key_find(fields, "sessions") {
    Ok(json.Array([_, ..] as values)) -> Ok(values)
    Ok(_) | Error(Nil) -> Error("expected a nonempty sessions array")
  })
  use Nil <- result.try(case list.drop(values, activity_limit) {
    [] -> Ok(Nil)
    [_, ..] -> Error("sessions names more than 24 identities")
  })
  use sessions <- result.try(
    list.try_map(values, fn(value) {
      case value {
        json.String(text) -> canonical_id(text)
        _ -> Error("expected a canonical session id")
      }
    }),
  )
  case list.length(list.unique(sessions)) == list.length(sessions) {
    True -> Ok(sessions)
    False -> Error("sessions repeats an identity")
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

// Feature support belongs to the request, so reconnect or another command
// cannot accidentally inherit permission to interpret registered identities.
fn accepted_features(
  fields: List(#(String, JsonValue)),
) -> Result(List(String), String) {
  case list.key_find(fields, "accepts") {
    Error(Nil) -> Ok([])
    Ok(json.Array(values)) -> {
      use Nil <- result.try(case list.drop(values, 8) == [] {
        True -> Ok(Nil)
        False -> Error("accepts exceeds eight features")
      })
      use names <- result.try(
        list.try_map(values, fn(value) {
          case value {
            json.String(name) -> {
              use Nil <- result.try(
                case
                  string.byte_size(name) > 0 && string.byte_size(name) <= 64
                {
                  True -> Ok(Nil)
                  False -> Error("invalid accepted feature size")
                },
              )
              use Nil <- result.try(feature_ascii(<<name:utf8>>))
              Ok(name)
            }
            _ -> Error("expected accepted feature names")
          }
        }),
      )
      case list.unique(names) == names {
        True -> Ok(names)
        False -> Error("duplicate accepted feature")
      }
    }
    Ok(_) -> Error("expected an accepts list")
  }
}

fn feature_ascii(bytes: BitArray) -> Result(Nil, String) {
  case bytes {
    <<>> -> Ok(Nil)
    <<byte, rest:bits>> if byte >= 33 && byte <= 126 -> feature_ascii(rest)
    _ -> Error("expected bounded ASCII feature name")
  }
}

fn workspace_key(
  fields: List(#(String, JsonValue)),
) -> Result(workspace.WorkspaceKey, String) {
  workspace_selection(fields) |> result.map(workspace.selection_key)
}

fn workspace_selection(
  fields: List(#(String, JsonValue)),
) -> Result(workspace.Selection, String) {
  case
    list.key_find(fields, "workspace"),
    list.key_find(fields, "workspace_selection")
  {
    Ok(_), Error(Nil) ->
      text_field(fields, "workspace", 4096)
      |> result.map(workspace.LocalDirectory)
    Error(Nil), Ok(json.Object(selected)) -> {
      use kind <- result.try(text_field(selected, "kind", 32))
      case kind {
        "local" -> {
          use Nil <- result.try(selection_fields(selected, ["kind", "path"]))
          text_field(selected, "path", 4096)
          |> result.map(workspace.LocalDirectory)
        }
        "registered" -> {
          use Nil <- result.try(
            selection_fields(selected, ["kind", "executor", "workspace"]),
          )
          use executor <- result.try(text_field(selected, "executor", 128))
          use name <- result.try(text_field(selected, "workspace", 128))
          workspace.selector(executor, name)
          |> result.map(workspace.RegisteredWorkspace)
          |> result.replace_error("invalid registered selector")
        }
        _ -> Error("unknown workspace selection")
      }
    }
    Error(Nil), Error(Nil) -> Error("expected workspace selection")
    Ok(_), Ok(_) ->
      Error("workspace and workspace_selection are mutually exclusive")
    Error(Nil), Ok(_) -> Error("expected tagged workspace selection")
  }
}

fn selection_fields(
  fields: List(#(String, JsonValue)),
  names: List(String),
) -> Result(Nil, String) {
  case
    list.length(fields) == list.length(names)
    && list.all(names, fn(name) {
      list.length(list.filter(fields, fn(field) { field.0 == name })) == 1
    })
  {
    True -> Ok(Nil)
    False -> Error("unexpected workspace selection fields")
  }
}
