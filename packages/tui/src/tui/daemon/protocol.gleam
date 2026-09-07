//// The terminal's independent, bounded daemon-control wire view.
////
//// This module imports no server implementation. It validates complete control
//// messages before returning metadata; decoding never opens a session. Epochs
//// come from the authenticated hello and are added to lifecycle requests here.

import core/ids
import core/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// Maximum complete control message size before JSON parsing.
pub const max_bytes = 65_536

/// One authenticated daemon lifetime, distinct from a session incarnation.
pub type Epoch {
  Epoch(
    /// Opaque server-generated daemon identity, not a timestamp.
    value: String,
  )
}

/// Server-owned identity and negotiated input limits.
pub type Hello {
  Hello(
    /// Daemon lifetime established by authenticated upgrade.
    epoch: Epoch,
    /// Server-owned principal identifier; never a supplied display name.
    principal: String,
    /// Maximum bytes accepted in one complete control request.
    control_bytes: Int,
  )
}

/// Requests are explicit; metadata reads never imply an open.
pub type Command {
  /// Reads readiness and capacity.
  Status

  /// Reads one page, optionally requiring the previous page's revision.
  ListSessions(
    /// Empty for the first page; otherwise the prior continuation identity.
    after: String,
    /// The first page's revision fences all subsequent pages.
    revision: Option(Int),
  )

  /// Reads one saved registration.
  GetSession(
    /// Canonical authorized session identity.
    session_id: String,
  )

  /// Looks up a workspace selection without starting it.
  WorkspaceDefault(
    /// Owner-selected workspace, not an attachment destination.
    workspace: String,
  )

  /// Persists the workspace selection without starting it.
  SetDefault(
    /// Workspace whose durable default is changing.
    workspace: String,
    /// Saved registration selected explicitly by the owner.
    session_id: String,
  )

  /// Explicitly creates and initializes a session under a durable retry key.
  CreateSession(
    /// Durable retry identity; retain it if the response is lost.
    request_key: String,
    /// Host workspace selected explicitly by the owner.
    workspace: String,
    /// A display label, never a database filename.
    name: String,
    /// Explicit operator configuration path.
    configuration: String,
  )

  /// Explicitly starts the selected session in this connection's epoch.
  OpenSession(
    /// Saved registration selected explicitly for execution.
    session_id: String,
  )

  /// Requests cleanup while preserving the database.
  StopSession(
    /// Runtime registration selected explicitly for cleanup.
    session_id: String,
  )

  /// Observes an operation only in the epoch where it was obtained.
  GetOperation(
    /// The authorized session whose lifecycle is being observed.
    session_id: String,
    /// The accepted operation or resident incarnation returned by the daemon.
    operation: String,
    /// The hello epoch under which that operation was obtained.
    epoch: Epoch,
  )

  /// Requests daemon drain.
  Shutdown
}

/// Lifecycle observations are transient; only Saved means no resident runtime.
pub type Lifecycle {
  /// The identity is reserved and its database was never established, so no
  /// selection can open it — only a create retry under its request key.
  Reserved

  /// Metadata is registered without a running session.
  Saved

  /// Startup has been accepted under this operation identity.
  Opening(
    /// Identity retained for an explicit operation observation.
    operation: String,
  )

  /// One runtime incarnation is available for a separate attachment.
  Resident(
    /// Identity binding the separate conversation attachment.
    incarnation: String,
  )

  /// Cleanup retains capacity until its witness completes.
  Stopping(
    /// Identity retained while ordered cleanup runs.
    operation: String,
  )

  /// Cleanup could not establish retirement.
  RecoveryBlocked
}

/// Authorized metadata without private database or credential paths.
pub type Session {
  Session(
    /// Canonical durable identity used by control and attachment routes.
    session_id: String,
    /// Canonical workspace associated with the saved registration.
    workspace: String,
    /// Display label, subject to terminal text hygiene when rendered.
    name: String,
    /// Durable creation timestamp in milliseconds.
    created_at: Int,
    /// Current registry observation, not persisted execution state.
    status: Lifecycle,
  )
}

/// At most one bounded page is returned; the caller controls accumulation.
pub type Page {
  Page(
    /// Catalogue revision used to reject mixed-revision pagination.
    revision: Int,
    /// No more than one hundred authorized records.
    sessions: List(Session),
    /// Resume cursor; None marks the end of the listing.
    after: Option(String),
  )
}

/// Admission readiness carries domain meaning instead of a Boolean polarity.
pub type Readiness {
  /// The daemon accepts lifecycle requests.
  Accepting

  /// The daemon is fencing new requests.
  Draining
}

/// Aggregate capacity counts are observations, not local admission authority.
pub type Summary {
  Summary(
    /// Must equal this connection's authenticated hello epoch.
    epoch: Epoch,
    /// Whether the daemon is still admitting lifecycle work.
    readiness: Readiness,
    /// Maximum concurrently reserved runtime slots.
    capacity: Int,
    /// Slots retained by all non-saved lifecycle states.
    occupied: Int,
    /// Sessions whose startup is underway.
    opening: Int,
    /// Available runtime incarnations.
    resident: Int,
    /// Sessions waiting for cleanup evidence.
    stopping: Int,
    /// Sessions whose retirement could not be confirmed.
    blocked: Int,
    /// Maximum retained shared-domain slots, separate from runtime capacity.
    domain_capacity: Int,
    /// All retained domain slots, including construction and cleanup.
    domain_occupied: Int,
    /// Domains blocked on failed retirement or dependency cleanup.
    domain_blocked: Int,
  )
}

/// Successful replies remain distinct from refusal and transport failure.
pub type Reply {
  /// A current daemon status.
  StatusReply(
    /// Capacity and epoch observed by the server.
    summary: Summary,
  )

  /// One bounded catalogue page.
  SessionsReply(
    /// One page, not an automatically accumulated catalogue.
    page: Page,
  )

  /// One selected or created registration.
  SessionReply(
    /// The authorized registration named by the request.
    session: Session,
  )

  /// An explicitly requested lifecycle transition.
  LifecycleReply(
    /// Accepted transition or already-resident incarnation.
    status: Lifecycle,
  )

  /// The daemon accepted its drain request.
  ShutdownReply
}

/// One validated server envelope; uncorrelated hello is the only handshake.
pub type Event {
  /// The authenticated peer identifies its daemon lifetime.
  Greeting(
    /// Identity verified before a control handle is returned.
    hello: Hello,
  )

  /// A correlated response names the command being answered.
  Answer(
    /// Positive request ID scoped to this socket.
    id: Int,
    /// Must match the command holding the outstanding response slot.
    command: String,
    /// Decoded body with bounded metadata fields.
    reply: Reply,
  )

  /// A bounded, correlated server refusal.
  Refused(
    /// Present when the server recovered a valid correlation ID.
    id: Option(Int),
    /// Stable machine-readable refusal category.
    code: String,
    /// Bounded peer diagnostic, sanitized separately when displayed.
    message: String,
  )
}

/// Names a command without exposing its body or credential.
///
/// ## Examples
///
/// ```gleam
/// assert name(Status) == "status"
/// ```
pub fn name(command: Command) -> String {
  case command {
    Status -> "status"
    ListSessions(..) -> "sessions.list"
    GetSession(..) -> "sessions.get"
    WorkspaceDefault(..) -> "sessions.default"
    SetDefault(..) -> "sessions.set_default"
    CreateSession(..) -> "sessions.create"
    OpenSession(..) -> "sessions.open"
    StopSession(..) -> "sessions.stop"
    GetOperation(..) -> "operations.get"
    Shutdown -> "daemon.shutdown"
  }
}

/// Whether losing the reply leaves a possible durable or lifecycle mutation.
///
/// ## Examples
///
/// ```gleam
/// assert !mutates(Status)
/// ```
pub fn mutates(command: Command) -> Bool {
  case command {
    Status
    | ListSessions(..)
    | GetSession(..)
    | WorkspaceDefault(..)
    | GetOperation(..) -> False
    SetDefault(..)
    | CreateSession(..)
    | OpenSession(..)
    | StopSession(..)
    | Shutdown -> True
  }
}

/// Encodes one request with this connection's authenticated epoch.
///
/// ## Examples
///
/// ```gleam
/// let request = encode(1, Status, Epoch("daemon-1"))
/// ```
pub fn encode(
  id: Int,
  command: Command,
  epoch: Epoch,
) -> Result(String, String) {
  use Nil <- result.try(case id > 0 {
    True -> Ok(Nil)
    False -> Error("invalid request id")
  })
  use fields <- result.try(command_fields(command, epoch))
  let text =
    json.to_string(
      json.Object([
        #("v", json.Int(2)),
        #("id", json.Int(id)),
        #("cmd", json.String(name(command))),
        #("body", json.Object(fields)),
      ]),
    )
  case string.byte_size(text) <= max_bytes {
    True -> Ok(text)
    False -> Error("control request exceeds byte limit")
  }
}

fn command_fields(command: Command, epoch: Epoch) {
  let Epoch(epoch_value) = epoch
  case command {
    Status -> Ok([])
    ListSessions(after, revision) -> {
      use Nil <- result.try(case after {
        "" -> Ok(Nil)
        _ -> valid_id(after)
      })
      use extra <- result.try(case revision {
        None -> Ok([])
        Some(value) if value >= 0 -> Ok([#("revision", json.Int(value))])
        Some(_) -> Error("invalid catalogue revision")
      })
      Ok([#("after", json.String(after)), ..extra])
    }
    GetSession(id) -> identity_fields(id)
    WorkspaceDefault(workspace) ->
      text_fields([#("workspace", workspace, 4096)])
    SetDefault(workspace, id) -> {
      use fields <- result.try(identity_fields(id))
      use other <- result.map(text_fields([#("workspace", workspace, 4096)]))
      list.append(fields, other)
    }
    CreateSession(key, workspace, name, configuration) ->
      text_fields([
        #("request_key", key, 256),
        #("workspace", workspace, 4096),
        #("name", name, 256),
        #("configuration", configuration, 4096),
      ])
    OpenSession(id) | StopSession(id) -> {
      use fields <- result.map(identity_fields(id))
      [#("epoch", json.String(epoch_value)), ..fields]
    }
    GetOperation(id, operation, expected) -> {
      use Nil <- result.try(case expected == epoch {
        True -> Ok(Nil)
        False -> Error("stale epoch")
      })
      use fields <- result.try(identity_fields(id))
      use other <- result.map(text_fields([#("operation", operation, 512)]))
      [#("epoch", json.String(epoch_value)), ..list.append(fields, other)]
    }
    Shutdown -> Ok([#("epoch", json.String(epoch_value))])
  }
}

fn identity_fields(id: String) {
  use Nil <- result.map(valid_id(id))
  [#("session_id", json.String(id))]
}

fn valid_id(id: String) {
  ids.parse_session_id(id)
  |> result.replace(Nil)
  |> result.replace_error("invalid session id")
}

fn text_fields(fields: List(#(String, String, Int))) {
  list.try_map(fields, fn(field) {
    let #(key, value, limit) = field
    use value <- result.map(bounded_text(json.String(value), limit))
    #(key, json.String(value))
  })
}

/// Validates an entire server frame before exposing its typed body.
///
/// ## Examples
///
/// ```gleam
/// assert decode("{}") == Error("unsupported control version")
/// ```
pub fn decode(text: String) -> Result(Event, String) {
  use Nil <- result.try(case string.byte_size(text) <= max_bytes {
    True -> Ok(Nil)
    False -> Error("control frame exceeds byte limit")
  })
  use value <- result.try(
    json.parse(text) |> result.replace_error("invalid control JSON"),
  )
  use Nil <- result.try(case field(value, "v") {
    Ok(json.Int(2)) -> Ok(Nil)
    _ -> Error("unsupported control version")
  })
  use event <- result.try(text_at(value, "event", 64))
  use body <- result.try(field(value, "body"))
  case event {
    "hello" -> {
      use Nil <- result.try(case field(value, "reply_to") {
        Error(_) -> Ok(Nil)
        Ok(_) -> Error("correlated hello")
      })
      use Nil <- result.try(case field(body, "protocol") {
        Ok(json.Int(2)) -> Ok(Nil)
        _ -> Error("unsupported hello version")
      })
      use epoch <- result.try(text_at(body, "epoch", 256))
      use principal <- result.try(text_at(body, "principal", 256))
      use limits <- result.try(field(body, "limits"))
      use limit <- result.try(number_at(limits, "control_bytes"))
      use Nil <- result.try(case limit > 0 && limit <= max_bytes {
        True -> Ok(Nil)
        False -> Error("unsupported control limit")
      })
      Ok(Greeting(Hello(Epoch(epoch), principal, limit)))
    }
    "error" -> {
      use id <- result.try(optional_id(value))
      use code <- result.try(text_at(body, "code", 64))
      use message <- result.map(text_at(body, "message", 512))
      Refused(id, code, message)
    }
    event -> {
      use id <- result.try(positive_at(value, "reply_to"))
      use reply <- result.map(decode_reply(event, body))
      Answer(id, event, reply)
    }
  }
}

fn decode_reply(event: String, body: json.JsonValue) {
  case event {
    "status" -> result.map(summary(body), StatusReply)
    "sessions.list" -> result.map(page(body), SessionsReply)
    "sessions.get"
    | "sessions.default"
    | "sessions.set_default"
    | "sessions.create"
    | "operations.get" -> result.map(session(body), SessionReply)
    "sessions.open" | "sessions.stop" ->
      result.map(lifecycle(body), LifecycleReply)
    "daemon.shutdown" ->
      case field(body, "state") {
        Ok(json.String("draining")) -> Ok(ShutdownReply)
        _ -> Error("invalid shutdown acknowledgement")
      }
    _ -> Error("unknown control event")
  }
}

fn summary(body: json.JsonValue) {
  use epoch <- result.try(text_at(body, "epoch", 256))
  use readiness <- result.try(case field(body, "ready") {
    Ok(json.Bool(True)) -> Ok(Accepting)
    Ok(json.Bool(False)) -> Ok(Draining)
    _ -> Error("invalid readiness")
  })
  use capacity <- result.try(number_at(body, "capacity"))
  use occupied <- result.try(number_at(body, "occupied"))
  use opening <- result.try(number_at(body, "opening"))
  use resident <- result.try(number_at(body, "resident"))
  use stopping <- result.try(number_at(body, "stopping"))
  use blocked <- result.try(number_at(body, "blocked"))
  use domain_capacity <- result.try(number_at(body, "domain_capacity"))
  use domain_occupied <- result.try(number_at(body, "domain_occupied"))
  use domain_blocked <- result.map(number_at(body, "domain_blocked"))
  Summary(
    Epoch(epoch),
    readiness,
    capacity,
    occupied,
    opening,
    resident,
    stopping,
    blocked,
    domain_capacity,
    domain_occupied,
    domain_blocked,
  )
}

fn page(body: json.JsonValue) {
  use revision <- result.try(number_at(body, "revision"))
  use values <- result.try(case field(body, "sessions") {
    Ok(json.Array(values)) ->
      case list.drop(values, 100) {
        [] -> Ok(values)
        [_, ..] -> Error("too many sessions")
      }
    _ -> Error("invalid session page")
  })
  use sessions <- result.try(list.try_map(values, session))
  use after <- result.try(case field(body, "after") {
    Ok(json.Null) -> Ok(None)
    Ok(json.String(id)) -> result.map(valid_id(id), fn(_) { Some(id) })
    _ -> Error("invalid continuation")
  })
  Ok(Page(revision, sessions, after))
}

fn session(body: json.JsonValue) {
  use id <- result.try(text_at(body, "session_id", 64))
  use Nil <- result.try(valid_id(id))
  use workspace <- result.try(text_at(body, "workspace", 4096))
  use name <- result.try(text_at(body, "name", 256))
  use created <- result.try(number_at(body, "created_at"))
  use status <- result.try(field(body, "status"))
  use status <- result.map(lifecycle(status))
  Session(id, workspace, name, created, status)
}

fn lifecycle(body: json.JsonValue) {
  use state <- result.try(text_at(body, "state", 64))
  case state {
    "reserved" -> Ok(Reserved)
    "saved" -> Ok(Saved)
    "opening" -> result.map(text_at(body, "operation", 512), Opening)
    "resident" -> result.map(text_at(body, "incarnation", 512), Resident)
    "stopping" -> result.map(text_at(body, "operation", 512), Stopping)
    "recovery_blocked" -> Ok(RecoveryBlocked)
    _ -> Error("invalid session lifecycle")
  }
}

fn optional_id(value: json.JsonValue) {
  case field(value, "reply_to") {
    Error(_) -> Ok(None)
    Ok(json.Int(id)) if id > 0 -> Ok(Some(id))
    Ok(_) -> Error("invalid reply id")
  }
}

fn field(value: json.JsonValue, key: String) {
  case value {
    json.Object(fields) ->
      list.key_find(fields, key)
      |> result.replace_error("missing control field")
    _ -> Error("expected control object")
  }
}

fn text_at(value: json.JsonValue, key: String, limit: Int) {
  use value <- result.try(field(value, key))
  bounded_text(value, limit)
}

fn bounded_text(value: json.JsonValue, limit: Int) {
  case value {
    json.String(text) if text != "" ->
      case string.byte_size(text) <= limit {
        True -> Ok(text)
        False -> Error("control text exceeds limit")
      }
    _ -> Error("expected nonempty control text")
  }
}

fn number_at(value: json.JsonValue, key: String) {
  case field(value, key) {
    Ok(json.Int(number)) if number >= 0 -> Ok(number)
    _ -> Error("expected nonnegative control count")
  }
}

fn positive_at(value: json.JsonValue, key: String) {
  use number <- result.try(number_at(value, key))
  case number > 0 {
    True -> Ok(number)
    False -> Error("expected positive request id")
  }
}
