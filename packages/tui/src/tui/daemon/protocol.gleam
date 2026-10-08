//// The terminal's independent, bounded daemon-control wire view.
////
//// This module imports no server implementation. It validates complete control
//// messages before returning metadata; decoding never opens a session. Epochs
//// come from the authenticated hello and are added to lifecycle requests here.
////
//// ## Flow
////
//// `encode` → `command_fields` → `decode` → `decode_reply` → `summary`
////
//// 1. `encode` refuses a non-positive request id, asks `command_fields` for the
////    body of one `Command` (validating every identifier and bound, and adding the
////    authenticated epoch to lifecycle requests), wraps it with `name`, and
////    refuses a frame over the byte limit.
//// 2. `decode` takes what the daemon sends back: it bounds the frame, parses
////    it, checks the control version, and dispatches on the event name.
//// 3. A hello is validated field by field (`build_at`, `view_at`) into a
////    greeting, and an error into a refusal carrying the optional request id.
//// 4. Every other event must correlate to a request through a positive
////    reply_to field and is turned into a typed `Reply` by `decode_reply`.
//// 5. `decode_reply` hands the body to the reply's own decoder (`summary`, `page`,
////    `session`, `lifecycle`, `deletion`, `activity`), all built from the bounded
////    readers `field`, `text_at`, `number_at` and `positive_at`.
//// 6. `mutates` says whether losing a command's reply may hide a durable change,
////    which is what a caller must know before it resends.

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

/// The running daemon's build, as it introduced itself in the hello.
///
/// Two opaque comparison strings and nothing more: this module does not
/// order versions, so it needs no version grammar. `None` in a `Hello`
/// means the daemon omitted build identity. The terminal leaves that case
/// silent and accepts the handshake; absence cannot establish a mismatch.
/// Explicit identities are compared only after authentication.
pub type Build {
  Build(
    /// The daemon's release version, or `dev` for a tree built ad hoc.
    version: String,
    /// The commit the daemon's tree was built from, or `unknown`.
    commit: String,
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
    /// The daemon's build, when it named one.
    build: Option(Build),
    /// Whether the daemon serves the web view (protocol-change/051).
    view: WebView,
  )
}

/// Whether a daemon serves the web view, as its `hello` says.
pub type WebView {
  /// The `hello` names no view: the daemon was started without `--ui`.
  NoWebView

  /// The daemon serves the view under this route prefix.
  WebViewAt(path: String)
}

/// Idle delivery policy attached to a directional peer grant.
pub type PeerWake {
  /// Delivery is allowed only during an active target run.
  BusyOnly

  /// Delivery may start an idle target strand.
  MayWake
}

/// The two roles a member can hold in a session, as `sessions.set_role`
/// names them. The owner holds neither; it has no memberships.
pub type MemberRole {
  /// May answer the session's escalations and send prompts.
  OperatorRole

  /// May read the session and nothing more.
  ObserverRole
}

/// Whether the home's `ui.link` exchange also sets a browser login, so the next
/// visit needs no `loom ui` (protocol-change/065).
pub type Remembering {
  /// Set the login: the default.
  Remember

  /// Open the page and set none: `loom ui --no-remember`.
  Forget
}

/// Requests are explicit; metadata reads never imply an open.
/// What a web page may do: the ceiling `ui.link` asks for. An operator's
/// page is asked for only with `loom ui --operate`.
pub type WebPage {
  /// A page that follows the session and sends nothing.
  ObserverPage

  /// A page with a composer and approval buttons, for a principal whose
  /// membership is an operator's or the owner's.
  OperatorPage
}

pub type Command {
  /// Renames the active session without changing its identity or lifetime.
  RenameSession(
    /// Canonical session identity selected by the owner.
    session_id: String,
    /// New nonempty display label, bounded to 256 UTF-8 bytes.
    name: String,
  )

  /// Reads readiness and capacity.
  Status

  /// Reads one page, optionally requiring the previous page's revision.
  ListSessions(
    /// Empty for the first page; otherwise the prior continuation identity.
    after: String,
    /// The first page's revision fences all subsequent pages.
    revision: Option(Int),
  )

  /// Reads one owner archive page without opening a conversation.
  ListArchivedSessions(
    /// Empty for the first page; otherwise the prior continuation identity.
    after: String,
    /// The first page's revision fences subsequent pages.
    revision: Option(Int),
  )

  /// Preserves a stopped session outside ordinary listings.
  ArchiveSession(
    /// Canonical registration selected by the owner.
    session_id: String,
  )

  /// Makes a preserved session eligible for explicit admission again.
  RestoreSession(
    /// Canonical archived registration selected by the owner.
    session_id: String,
  )

  /// Reads one saved registration.
  GetSession(
    /// Canonical authorized session identity.
    session_id: String,
  )

  /// Asks for a single-use link that opens one session's web view in this
  /// principal's browser (protocol-change/051), or, with no session, the
  /// principal's home page (protocol-change/065).
  UiLink(
    /// Canonical authorized session identity, or `None` for the home.
    session_id: Option(String),
    /// The most the page may do. It caps the principal's membership role in
    /// the session and never grants one.
    page: WebPage,
    /// Whether the exchange also sets a browser login, which only the home's
    /// link may decline (`loom ui --no-remember`). A session's link is always
    /// `Remember`, which is never sent.
    remember: Remembering,
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
    /// The model profile to create the session under, or empty for the
    /// configuration's default roles (protocol-change/076).
    profile: String,
    /// The executor `workspace` is registered on, or empty when `workspace` is
    /// a path on the daemon's host (protocol-change/078). With an executor the
    /// workspace is a registered name, which the daemon keeps exactly as sent.
    executor: String,
    /// The pool of executors `workspace` is registered on, or empty
    /// (protocol-change/078). Exclusive with `executor`: the daemon picks the
    /// executor when the session first opens.
    pool: String,
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

  /// Removes a stopped registration and its conversation database.
  DeleteSession(
    /// Saved registration selected explicitly for removal.
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

  /// Inspects the directional peer grants for one resident strand.
  InspectPeers(
    /// Canonical resident source session selected by the owner.
    source_session: String,
    /// Exact source strand whose incoming and outgoing grants are inspected.
    source_strand: String,
    /// Opaque continuation returned by the previous bounded inspection page.
    after: Option(String),
  )

  /// Creates one exact directional peer grant.
  LinkPeers(
    /// Canonical resident source session selected by the owner.
    source_session: String,
    /// Exact sending strand.
    source_strand: String,
    /// Canonical resident recipient session.
    target_session: String,
    /// Exact recipient strand.
    target_strand: String,
    /// Recipient's independent idle-wake permission.
    wake: PeerWake,
  )

  /// Removes one exact directional peer grant.
  UnlinkPeers(
    /// Canonical resident source session selected by the owner.
    source_session: String,
    /// Exact sending strand.
    source_strand: String,
    /// Canonical recipient session, which may be unavailable.
    target_session: String,
    /// Exact recipient strand.
    target_strand: String,
  )

  /// Lists one page of principals and their credential state
  /// (`protocol-change/053`). Owner-only; a member is refused `forbidden`.
  ListPrincipals(
    /// The last principal of the previous page, absent for the first.
    after: Option(String),
  )

  /// Lists one page of the sessions a principal holds a role in
  /// (`protocol-change/053`). Owner-only.
  PrincipalMemberships(
    /// The principal whose memberships are listed.
    principal: String,
    /// The last session of the previous page, absent for the first.
    after: Option(String),
  )

  /// Sets a member's role in one session, adding the membership if the
  /// member has none there. Owner-only.
  SetMemberRole(
    /// Canonical session whose membership changes.
    session_id: String,
    /// The member whose role changes.
    principal: String,
    /// The role the member holds afterwards.
    role: MemberRole,
  )

  /// Removes a member's role in one session. Owner-only.
  RevokeMembership(
    /// Canonical session the member leaves.
    session_id: String,
    /// The member who leaves it.
    principal: String,
  )

  /// Revokes every credential of a member, and any open claim. Owner-only.
  RevokeCredentials(
    /// The member whose credentials are revoked.
    principal: String,
  )

  /// Asks what the named resident sessions are doing (`protocol-change/050`).
  /// Owner-only. Sessions that are not resident are absent from the reply.
  SessionActivity(
    /// One to `activity_limit` distinct canonical identities; the reply
    /// keeps their order.
    sessions: List(String),
  )
}

/// The most sessions one `SessionActivity` request may name.
pub const activity_limit = 24

/// What one resident session is doing, as `sessions.activity` reports it.
pub type Activity {
  Activity(
    /// Canonical identity of the resident session this row describes.
    session_id: String,
    /// The session's overall state, derived by the daemon.
    state: ActivityState,
    /// How many strands the session has.
    strands: Int,
    /// How many strands have an operation open.
    working: Int,
    /// How many approvals are waiting on the operator.
    approvals: Int,
    /// How main's last run ended, when its last terminal result was a run.
    last_outcome: Option(LastOutcome),
    /// Main's final assistant text, collapsed to one line of at most 280
    /// bytes.
    last_message: Option(String),
    /// Main's configured model identity.
    model: Option(String),
    /// Up to four sub-agent glances, newest first.
    glances: List(GlanceLine),
  )
}

/// The daemon's reading of a resident session.
pub type ActivityState {
  /// An approval is pending, or main's last run failed and main has stopped.
  NeedsYou

  /// Some strand has an operation open.
  Working

  /// Nothing is running and nothing is waiting on the operator.
  Idle

  /// The session did not answer in time, or reported a state this terminal
  /// does not know.
  Unknown
}

/// How a main-strand run ended.
pub type LastOutcome {
  /// The run finished normally.
  LastCompleted

  /// The run failed.
  LastFailed

  /// The run was cancelled.
  LastAborted
}

/// One sub-agent's glance: what it is working on and what it is doing now.
pub type GlanceLine {
  GlanceLine(
    /// The strand the glance describes.
    strand: String,
    /// A few words naming the task.
    title: String,
    /// One line on the latest activity; empty until first summarized.
    summary: String,
  )
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
    /// The first line of the owner's first prompt, at most 60 characters
    /// (`protocol-change/067`). Absent from an older daemon's frames and from a
    /// session no prompt has reached; a present value that is not a bounded
    /// string reads as absent, since a display aid must not fail a listing.
    subtitle: Option(String),
    /// The executor the session's workspace is registered on
    /// (protocol-change/078), present only for a remote session, whose
    /// `workspace` is then a registered name and not a path. A local session's
    /// frame has no such member, and so does an older daemon's. A present value
    /// that is not a bounded string reads as absent, as the subtitle does.
    executor: Option(String),
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
  /// A web view link: a path on the daemon's listener carrying a
  /// single-use ticket, and how long the ticket lasts.
  UiLinkReply(
    /// The path, which the caller joins to the address it connected to.
    path: String,
    /// The ticket's remaining lifetime in milliseconds, a duration.
    expires_in_ms: Int,
  )

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

  /// The registration named here no longer exists.
  DeletedReply(
    /// The identity that was removed, echoed for the caller's own listing.
    session_id: String,
  )

  /// The daemon accepted its drain request.
  ShutdownReply

  /// One owner-authorized inspection document for an exact resident strand.
  PeersInspectionReply(
    /// Bounded JSON returned by the daemon's resident-only peer directory.
    document: json.JsonValue,
  )

  /// One peer-link mutation acknowledgement, including partial revocation.
  PeersMutationReply(
    /// Bounded JSON retaining the server's per-direction result.
    document: json.JsonValue,
  )

  /// One page of the owner's access listing, either principals or one
  /// principal's memberships. The body is checked by `host/access` where it
  /// is drawn, not here.
  AccessListingReply(
    /// The daemon's reply body, unread.
    document: json.JsonValue,
  )

  /// One acknowledged access change: a role set, a membership revoked, or
  /// credentials revoked. The body names the principal and never a secret.
  AccessChangeReply(
    /// The daemon's reply body, unread.
    document: json.JsonValue,
  )

  /// What each resident session named by `SessionActivity` is doing, in
  /// request order. A requested session missing here is not resident.
  ActivityReply(
    /// One row per resident session.
    activity: List(Activity),
  )
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
    RenameSession(..) -> "sessions.rename"
    Status -> "status"
    ListSessions(..) -> "sessions.list"
    ListArchivedSessions(..) -> "sessions.archived"
    ArchiveSession(..) -> "sessions.archive"
    RestoreSession(..) -> "sessions.restore"
    GetSession(..) -> "sessions.get"
    UiLink(..) -> "ui.link"
    WorkspaceDefault(..) -> "sessions.default"
    SetDefault(..) -> "sessions.set_default"
    CreateSession(..) -> "sessions.create"
    OpenSession(..) -> "sessions.open"
    StopSession(..) -> "sessions.stop"
    DeleteSession(..) -> "sessions.delete"
    GetOperation(..) -> "operations.get"
    InspectPeers(..) -> "peers.inspect"
    LinkPeers(..) -> "peers.link"
    UnlinkPeers(..) -> "peers.unlink"
    ListPrincipals(..) -> "principals.list"
    PrincipalMemberships(..) -> "principals.memberships"
    SetMemberRole(..) -> "sessions.set_role"
    RevokeMembership(..) -> "sessions.revoke"
    RevokeCredentials(..) -> "credentials.revoke"
    SessionActivity(..) -> "sessions.activity"
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
    | ListArchivedSessions(..)
    | GetSession(..)
    | UiLink(..)
    | WorkspaceDefault(..)
    | GetOperation(..)
    | InspectPeers(..)
    | ListPrincipals(..)
    | PrincipalMemberships(..)
    | SessionActivity(..) -> False
    SetDefault(..)
    | RenameSession(..)
    | CreateSession(..)
    | OpenSession(..)
    | StopSession(..)
    | DeleteSession(..)
    | ArchiveSession(..)
    | RestoreSession(..)
    | LinkPeers(..)
    | UnlinkPeers(..)
    | SetMemberRole(..)
    | RevokeMembership(..)
    | RevokeCredentials(..)
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
    ListSessions(after, revision) | ListArchivedSessions(after, revision) -> {
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
    GetSession(id) | UiLink(Some(id), ObserverPage, _) -> identity_fields(id)

    // An observer's page is the default, and its request is the one this
    // launcher sent before the field existed; only an operator's page names
    // it, which a daemon that predates the field ignores and serves as an
    // observer's (protocol-change/051, the operator addendum).
    UiLink(Some(id), OperatorPage, _) -> {
      use fields <- result.map(identity_fields(id))
      list.append(fields, [#("page", json.String("operator"))])
    }

    // A link to the home names no session, which is the whole of what makes it
    // one (protocol-change/065). A daemon that predates the home refuses the
    // request for want of a session, and the launcher says so.
    //
    // The login is set unless the person declined it, and only a decline is
    // sent: a daemon that predates the field sets none, and its absence is the
    // default.
    UiLink(None, page, remember) ->
      Ok(
        list.append(
          case page {
            ObserverPage -> []
            OperatorPage -> [#("page", json.String("operator"))]
          },
          case remember {
            Remember -> []
            Forget -> [#("remember", json.Bool(False))]
          },
        ),
      )
    WorkspaceDefault(workspace) ->
      text_fields([#("workspace", workspace, 4096)])
    RenameSession(id, name) -> {
      use fields <- result.try(identity_fields(id))
      use other <- result.map(text_fields([#("name", name, 256)]))
      [#("epoch", json.String(epoch.value)), ..list.append(fields, other)]
    }
    SetDefault(workspace, id) -> {
      use fields <- result.try(identity_fields(id))
      use other <- result.map(text_fields([#("workspace", workspace, 4096)]))
      list.append(fields, other)
    }
    CreateSession(key, workspace, name, configuration, profile, executor, pool) -> {
      use fields <- result.try(
        text_fields([
          #("request_key", key, 256),
          #("workspace", workspace, 4096),
          #("name", name, 256),
        ]),
      )

      // Empty configuration preserves daemon defaults; other control text is
      // still nonempty. The same byte ceiling applies to an explicit path.
      use configuration <- result.try(case configuration {
        "" -> Ok("")
        path -> bounded_text(json.String(path), 4096)
      })

      // An empty profile is the default roles and is not sent, so a daemon
      // that predates profiles receives exactly the request it always did.
      use profile <- result.try(case profile {
        "" -> Ok([])
        name -> text_fields([#("profile", name, 64)])
      })

      // The executor is absent for a workspace on the daemon's host, for the
      // same reason, and present only beside a registered workspace name.
      use executor <- result.try(case executor {
        "" -> Ok([])
        name -> text_fields([#("executor", name, 64)])
      })

      // A pool is absent for the same reason, and the daemon refuses a request
      // that carries both, so this client never sends one.
      use pool <- result.map(case pool {
        "" -> Ok([])
        name -> text_fields([#("pool", name, 64)])
      })
      [
        #("configuration", json.String(configuration)),
        ..list.append(fields, list.flatten([profile, executor, pool]))
      ]
    }
    OpenSession(id)
    | StopSession(id)
    | DeleteSession(id)
    | ArchiveSession(id)
    | RestoreSession(id) -> {
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
    InspectPeers(source, strand, after) -> {
      use fields <- result.try(peer_session_field(source, "source_session"))
      use other <- result.try(peer_strand_field(strand, "source_strand"))
      use cursor <- result.try(optional_text_field(after, "after", 4096))
      Ok([
        #("epoch", json.String(epoch_value)),
        ..list.append(fields, list.append(other, cursor))
      ])
    }
    LinkPeers(source, from, target, to, wake) -> {
      use source_fields <- result.try(peer_session_field(
        source,
        "source_session",
      ))
      use from_field <- result.try(peer_strand_field(from, "source_strand"))
      use target_fields <- result.try(peer_session_field(
        target,
        "target_session",
      ))
      use to_field <- result.try(peer_strand_field(to, "target_strand"))
      let wake = case wake {
        BusyOnly -> "busy_only"
        MayWake -> "may_wake"
      }
      Ok([
        #("epoch", json.String(epoch_value)),
        ..list.append(
          source_fields,
          list.append(
            from_field,
            list.append(
              target_fields,
              list.append(to_field, [#("wake", json.String(wake))]),
            ),
          ),
        )
      ])
    }
    ListPrincipals(after) -> optional_text_field(after, "after", 128)
    PrincipalMemberships(principal, after) -> {
      use identity <- result.try(principal_field(principal))
      use cursor <- result.try(case after {
        None -> Ok([])
        Some(id) -> {
          use Nil <- result.try(valid_id(id))
          Ok([#("after", json.String(id))])
        }
      })
      Ok(list.append(identity, cursor))
    }
    SetMemberRole(id, principal, role) -> {
      use session <- result.try(identity_fields(id))
      use identity <- result.try(principal_field(principal))
      let role = case role {
        OperatorRole -> "operator"
        ObserverRole -> "observer"
      }
      Ok([
        #("epoch", json.String(epoch_value)),
        ..list.append(
          session,
          list.append(identity, [#("role", json.String(role))]),
        )
      ])
    }
    RevokeMembership(id, principal) -> {
      use session <- result.try(identity_fields(id))
      use identity <- result.try(principal_field(principal))
      Ok([
        #("epoch", json.String(epoch_value)),
        ..list.append(session, identity)
      ])
    }
    RevokeCredentials(principal) -> {
      use identity <- result.try(principal_field(principal))
      Ok([#("epoch", json.String(epoch_value)), ..identity])
    }
    SessionActivity(sessions) -> {
      use Nil <- result.try(activity_sessions(sessions))
      Ok([
        #("sessions", json.Array(list.map(sessions, json.String))),
        #("epoch", json.String(epoch_value)),
      ])
    }
    UnlinkPeers(source, from, target, to) -> {
      use source_fields <- result.try(peer_session_field(
        source,
        "source_session",
      ))
      use from_field <- result.try(peer_strand_field(from, "source_strand"))
      use target_fields <- result.try(peer_session_field(
        target,
        "target_session",
      ))
      use to_field <- result.try(peer_strand_field(to, "target_strand"))
      Ok([
        #("epoch", json.String(epoch_value)),
        ..list.append(
          source_fields,
          list.append(from_field, list.append(target_fields, to_field)),
        )
      ])
    }
  }
}

// The daemon refuses the whole request for any of these, so they are
// refused here instead of spending a round trip on a known refusal.
fn activity_sessions(sessions: List(String)) {
  use Nil <- result.try(case sessions, list.drop(sessions, activity_limit) {
    [_, ..], [] -> Ok(Nil)
    [], _ | _, [_, ..] -> Error("activity names 1 to 24 sessions")
  })
  use Nil <- result.try(list.try_each(sessions, valid_id))
  case list.length(list.unique(sessions)) == list.length(sessions) {
    True -> Ok(Nil)
    False -> Error("activity repeats a session")
  }
}

fn peer_session_field(id: String, key: String) {
  use Nil <- result.try(valid_id(id))
  Ok([#(key, json.String(id))])
}

// A principal ID is 1 to 128 bytes of the daemon's identifier alphabet. The
// daemon applies the same rule and answers `bad_request`, so a value that
// fails it here is refused without a round trip.
fn principal_field(principal: String) {
  case
    string.byte_size(principal) > 0
    && string.byte_size(principal) <= 128
    && list.all(string.to_graphemes(principal), fn(char) {
      string.contains(principal_alphabet, char)
    })
  {
    True -> Ok([#("principal_id", json.String(principal))])
    False -> Error("invalid principal id")
  }
}

const principal_alphabet =
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-."

fn peer_strand_field(strand: String, key: String) {
  use Nil <- result.try(
    case string.byte_size(strand) > 0 && string.byte_size(strand) <= 128 {
      True -> Ok(Nil)
      False -> Error("invalid peer strand")
    },
  )
  Ok([#(key, json.String(strand))])
}

fn optional_text_field(value: Option(String), key: String, limit: Int) {
  case value {
    None -> Ok([])
    Some(text) ->
      case string.byte_size(text) > 0 {
        True -> {
          use text <- result.try(bounded_text(json.String(text), limit))
          Ok([#(key, json.String(text))])
        }
        False -> Error("invalid empty cursor")
      }
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
      use build <- result.try(build_at(body))
      use view <- result.try(view_at(body))
      Ok(Greeting(Hello(Epoch(epoch), principal, limit, build, view)))
    }
    "error" -> {
      use id <- result.try(optional_id(value))
      use code <- result.try(text_at(body, "code", 64))
      use message <- result.map(text_at(body, "message", 2048))
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
    "ui.link" -> {
      use path <- result.try(text_at(body, "path", 1024))
      use expires_in_ms <- result.map(number_at(body, "expires_in_ms"))
      UiLinkReply(path, expires_in_ms)
    }
    "sessions.list" | "sessions.archived" ->
      result.map(page(body), SessionsReply)
    "sessions.get"
    | "sessions.rename"
    | "sessions.archive"
    | "sessions.restore"
    | "sessions.default"
    | "sessions.set_default"
    | "sessions.create"
    | "operations.get" -> result.map(session(body), SessionReply)
    "sessions.open" | "sessions.stop" ->
      result.map(lifecycle(body), LifecycleReply)
    "sessions.delete" -> result.map(deletion(body), DeletedReply)
    "peers.inspect" -> Ok(PeersInspectionReply(body))
    "peers.link" | "peers.unlink" -> Ok(PeersMutationReply(body))
    "principals.list" | "principals.memberships" -> Ok(AccessListingReply(body))
    "sessions.set_role" | "sessions.revoke" | "credentials.revoke" ->
      Ok(AccessChangeReply(body))
    "sessions.activity" -> result.map(activity(body), ActivityReply)
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
  Session(
    id,
    workspace,
    name,
    created,
    status,
    subtitle_of(body),
    executor_of(body),
  )
}

// The optional executor of a remote session. Like the subtitle it is a display
// aid, so a member that is absent, empty, too long or not a string reads as
// none and does not fail the row. `text_at` already refuses the empty string.
fn executor_of(body: json.JsonValue) -> Option(String) {
  text_at(body, "executor", 64) |> option.from_result
}

// The optional subtitle. Every way of not being a nonblank string of at most 60
// characters reads as none, rather than refusing the row it is on.
fn subtitle_of(body: json.JsonValue) -> Option(String) {
  case text_at(body, "subtitle", 240) {
    Ok(text) ->
      case text != "" && string.length(text) <= 60 {
        True -> Some(text)
        False -> None
      }
    Error(_) -> None
  }
}

// The activity rows. Only the identity is required: a row the terminal
// cannot attribute is a daemon fault, and the whole reply is refused. Every
// other field is read tolerantly, because `protocol-change/050` lets a later
// daemon add states and fields — an unknown state reads as `Unknown`, and a
// missing or malformed field reads as its empty value.
fn activity(body: json.JsonValue) {
  case field(body, "activity") {
    Ok(json.Array(rows)) -> list.try_map(rows, activity_row)
    _ -> Error("invalid activity reply")
  }
}

fn activity_row(row: json.JsonValue) {
  use id <- result.try(text_at(row, "session_id", 64))
  use Nil <- result.map(valid_id(id))
  let state = case field(row, "state") {
    Ok(json.String("needs_you")) -> NeedsYou
    Ok(json.String("working")) -> Working
    Ok(json.String("idle")) -> Idle
    _ -> Unknown
  }
  let last_outcome = case field(row, "last_outcome") {
    Ok(json.String("completed")) -> Some(LastCompleted)
    Ok(json.String("failed")) -> Some(LastFailed)
    Ok(json.String("aborted")) -> Some(LastAborted)
    _ -> None
  }
  let glances = case field(row, "glances") {
    Ok(json.Array(values)) -> list.filter_map(values, glance_line)
    _ -> []
  }
  Activity(
    session_id: id,
    state:,
    strands: count_or_zero(row, "strands"),
    working: count_or_zero(row, "working"),
    approvals: count_or_zero(row, "approvals"),
    last_outcome:,
    last_message: text_at(row, "last_message", 1024) |> option.from_result,
    model: text_at(row, "model", 256) |> option.from_result,
    glances:,
  )
}

// A glance's summary is empty until its first refresh, so its text fields
// may be empty, unlike the nonempty control text elsewhere in this module.
fn glance_line(value: json.JsonValue) {
  case field(value, "strand"), field(value, "title"), field(value, "summary") {
    Ok(json.String(strand)), Ok(json.String(title)), Ok(json.String(summary))
      if strand != ""
    ->
      case
        string.byte_size(strand) <= 256
        && string.byte_size(title) <= 256
        && string.byte_size(summary) <= 512
      {
        True -> Ok(GlanceLine(strand:, title:, summary:))
        False -> Error("glance text exceeds limit")
      }
    _, _, _ -> Error("invalid glance")
  }
}

fn count_or_zero(value: json.JsonValue, key: String) -> Int {
  number_at(value, key) |> result.unwrap(0)
}

fn deletion(body: json.JsonValue) {
  use id <- result.try(text_at(body, "session_id", 64))
  use Nil <- result.map(valid_id(id))
  id
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

// The web view's route prefix, when the daemon serves the view. An absent
// field is a daemon started without `--ui`; a present one must be well
// formed, because a client acts on it.
fn view_at(body: json.JsonValue) {
  case field(body, "ui") {
    Error(_) -> Ok(NoWebView)
    Ok(view) -> result.map(text_at(view, "path", 256), WebViewAt)
  }
}

// The hello's build identity, or `None` when the daemon did not send one.
//
// Absence is not an error: an older daemon's hello predates these two
// fields, and a new client must still attach to it and report that it is
// old rather than refusing the frame for a missing field. Both fields
// must be present and non-empty together, or the answer is `None` — a
// half identity is no more an identity than an absent one, and reading
// it as `Some(Build("0.1.0", ""))` would put a blank commit in a
// diagnostic the operator is meant to compare.
fn build_at(body: json.JsonValue) {
  case text_at(body, "build_version", 128), text_at(body, "build_commit", 128) {
    Ok(version), Ok(commit) -> Ok(Some(Build(version, commit)))
    _, _ -> Ok(None)
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
