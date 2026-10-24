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
import tui/placement

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

  /// The daemon serves the view under this route prefix. `origins` are the
  /// `https` origins the owner listed in `[daemon] ui_origins`
  /// (protocol-change/052), as the daemon normalized them; empty when none
  /// is listed or the daemon predates the field.
  WebViewAt(path: String, origins: List(String))
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

  /// Asks for a link that signs another device in to this principal's home:
  /// `ui.link` with `"device": true` (protocol-change/052, the addendum). The
  /// ticket lives ten minutes rather than sixty seconds and always sets a
  /// browser login, which is what `loom ui --device` prints.
  UiDeviceLink(
    /// The most the page may do, as for `UiLink`.
    page: WebPage,
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

  /// Hands a session to another orchestrator (protocol-change/078, phase 5).
  /// The reply says the move is in flight; the daemon carries it to its end.
  MoveSession(
    /// Canonical registration selected by the owner.
    session_id: String,
    /// The destination, named as the daemon's `[orchestrators.<name>]` table
    /// names it.
    to: String,
  )

  /// Gives up the move of a session now (protocol-change/083 and 085). It is
  /// the same wire command as `MoveSession`, `sessions.move`, with the member
  /// `abandon` set; only a directory member accepts it, and a receiver that has
  /// already taken the session makes the move finish instead.
  AbandonMove(
    /// Canonical registration whose move is given up.
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

  /// Asks which of the nodes the daemon is configured with answer its own
  /// connection attempts and report, and which executors and pools a session
  /// may be placed on (`protocol-change/085`). Owner-only. With a `node` it asks
  /// about the one configured `[executors.<name>]` or `[orchestrators.<name>]`
  /// that key names and returns its long lists. A daemon built before the
  /// command existed refuses it `bad_request`.
  DeploymentStatus(
    /// The configuration key of the one node to read, or `None` for all.
    node: Option(String),
  )

  /// Asks the session directory's cluster view of a daemon that is a member
  /// (`protocol-change/083`). Owner-only. A daemon that is not a member answers
  /// `not_found`.
  DirectoryStatus

  /// Asks the daemon's other orchestrators for a page of the sessions each
  /// lists (`protocol-change/085`). Owner-only. With neither member every
  /// configured orchestrator is asked for its first page; with an
  /// `orchestrator` key and the identity of the last row of its previous page
  /// as `after`, that one is asked for the next. A daemon built before the
  /// command existed refuses it `bad_request`.
  SessionsElsewhere(
    /// The configuration key of the one orchestrator to read, or `None` for all.
    orchestrator: Option(String),
    /// The identity the page follows. Present only with an `orchestrator`.
    after: Option(String),
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

  /// A reserved identity whose start failed, with the one cleaned line the
  /// daemon kept for it and when it failed in Unix milliseconds
  /// (`protocol-change/093`). It is a `Reserved` in what a client may do: no
  /// selection can open it, and the owner may delete it or retry the creation.
  /// The daemon reports it as `reserved` with a `failure` member, so a
  /// `failure` that does not decode reads as a plain `Reserved`.
  FailedStart(reason: String, at: Int)

  /// Metadata is registered without a running session.
  Saved

  /// The session is being handed to the orchestrator `to`
  /// (`protocol-change/078`, phase 5). It is stopped, as a saved session is,
  /// and this daemon will not open it: the move ends in the session living on
  /// `to`, or in an abandoned move that makes it an ordinary saved session
  /// again. The daemon reports it as a saved session with a `moving` member,
  /// and this is how the client reads the two together, so no code that draws a
  /// row or offers an open can forget the member.
  Moving(
    /// The name of the destination in the daemon's `[orchestrators.<name>]`
    /// table. A name outside that grammar never reaches this type, so it holds
    /// no whitespace or control character.
    to: String,
  )

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

  /// A move the daemon accepted and is carrying out.
  MovedReply(
    /// The session being moved.
    session_id: String,
    /// The move's identity, which the daemon stores and a repeat of the request
    /// answers again.
    op: String,
    /// The orchestrator the session is going to.
    to: String,
  )

  /// The daemon began giving a move up. The move is carried out by its movers,
  /// so this says the abandon began and not that the move ended.
  AbandonedReply(
    /// The session whose move is being given up.
    session_id: String,
    /// The identity of the move that was in flight.
    op: String,
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

  /// What the daemon found of each node it is configured with
  /// (`protocol-change/085`). The body is kept whole: `--json` prints it as the
  /// daemon sent it, and `tui/deployment_view` reads it with a total decoder
  /// where it is drawn.
  DeploymentReply(
    /// The daemon's reply body, unread.
    document: json.JsonValue,
  )

  /// The cluster view of a directory member: its members, voters, leader and
  /// applied index. The body is kept whole for the same reason as
  /// `DeploymentReply`'s, and `tui/directory_view` reads it.
  DirectoryReply(
    /// The daemon's reply body, unread.
    document: json.JsonValue,
  )

  /// What each of the daemon's other orchestrators lists
  /// (`protocol-change/085`). The body is kept whole for the same reason as
  /// `DeploymentReply`'s, and `tui/elsewhere_view` reads it.
  ElsewhereReply(
    /// The daemon's reply body, unread.
    document: json.JsonValue,
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

  /// A correlated refusal that says where the session lives instead
  /// (protocol-change/078, phase 3): the daemon does not hold the session, and
  /// either names the orchestrator that does or the ones it could not ask.
  Redirected(
    /// Present when the server recovered a valid correlation ID.
    id: Option(Int),
    /// Where the daemon says the session is.
    redirect: Redirect,
  )
}

/// What a daemon that does not hold a session says about who does.
pub type Redirect {
  /// A configured orchestrator holds the session (`not_owner`).
  NotOwner(
    /// The orchestrator's name in the daemon's `[orchestrators.<name>]` table.
    orchestrator: String,
    /// The control address its operator configured for it, when one is.
    address: Option(String),
  )

  /// No orchestrator said it holds the session, and some could not be asked
  /// (`owner_unreachable`).
  OwnerUnreachable(
    /// The names of the orchestrators that did not answer.
    orchestrators: List(String),
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
    UiLink(..) | UiDeviceLink(..) -> "ui.link"
    WorkspaceDefault(..) -> "sessions.default"
    SetDefault(..) -> "sessions.set_default"
    CreateSession(..) -> "sessions.create"
    OpenSession(..) -> "sessions.open"
    StopSession(..) -> "sessions.stop"
    DeleteSession(..) -> "sessions.delete"
    MoveSession(..) | AbandonMove(..) -> "sessions.move"
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
    DeploymentStatus(..) -> "deployment.status"
    DirectoryStatus -> "directory.status"
    SessionsElsewhere(..) -> "sessions.elsewhere"
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
    | UiDeviceLink(..)
    | WorkspaceDefault(..)
    | GetOperation(..)
    | InspectPeers(..)
    | ListPrincipals(..)
    | PrincipalMemberships(..)
    | DeploymentStatus(..)
    | DirectoryStatus
    | SessionsElsewhere(..)
    | SessionActivity(..) -> False
    SetDefault(..)
    | RenameSession(..)
    | CreateSession(..)
    | OpenSession(..)
    | StopSession(..)
    | DeleteSession(..)
    | MoveSession(..)
    | AbandonMove(..)
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
  // Ensure request identifier is positive.
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

  // Verify encoded frame conforms to byte ceiling.
  case string.byte_size(text) <= max_bytes {
    True -> Ok(text)
    False -> Error("control request exceeds byte limit")
  }
}

// The members of a `sessions.elsewhere` request. A cursor follows one group's
// rows, so it is sent only with the group it belongs to, and each is checked
// here as the daemon will check it.
/// Encodes elsewhere command fields with optional orchestrator and cursor.
fn elsewhere_fields(
  orchestrator: Option(String),
  after: Option(String),
) -> Result(List(#(String, json.JsonValue)), String) {
  // Validate orchestrator key and pagination cursor combinations.
  case orchestrator, after {
    None, None -> Ok([])
    None, Some(_) -> Error("a cursor needs the orchestrator it follows")
    Some(key), None ->
      orchestrator_member(key) |> result.map(fn(member) { [member] })
    Some(key), Some(id) -> {
      use member <- result.try(orchestrator_member(key))
      use Nil <- result.map(valid_id(id))
      [member, #("after", json.String(id))]
    }
  }
}

/// Formats and validates the orchestrator key property.
fn orchestrator_member(
  key: String,
) -> Result(#(String, json.JsonValue), String) {
  case placement.is_orchestrator_name(key) {
    True -> Ok(#("orchestrator", json.String(key)))
    False -> Error("orchestrator must be a configuration key")
  }
}

/// Encodes command-specific payload properties based on variant and epoch.
fn command_fields(command: Command, epoch: Epoch) {
  let Epoch(epoch_value) = epoch

  // Encode specific body fields matching command variant.
  case command {
    Status | DeploymentStatus(None) | DirectoryStatus -> Ok([])
    DeploymentStatus(Some(key)) ->
      case placement.is_orchestrator_name(key) {
        True -> Ok([#("node", json.String(key))])
        False -> Error("node must be a configuration key")
      }
    SessionsElsewhere(orchestrator, after) ->
      elsewhere_fields(orchestrator, after)
    ListSessions(after, revision) | ListArchivedSessions(after, revision) -> {
      // Validate continuation token.
      use Nil <- result.try(case after {
        "" -> Ok(Nil)
        _ -> valid_id(after)
      })

      // Encode optional catalogue revision bound.
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

    // A device link is the home's link with the one field that makes it a
    // device's. A daemon that predates the field ignores it and mints an
    // ordinary sixty-second home link, which the reply's `expires_in_ms`
    // shows.
    UiDeviceLink(page) ->
      Ok([
        #("device", json.Bool(True)),
        ..case page {
          ObserverPage -> []
          OperatorPage -> [#("page", json.String("operator"))]
        }
      ])
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
    AbandonMove(id) -> {
      use fields <- result.map(identity_fields(id))
      [
        #("epoch", json.String(epoch_value)),
        #("abandon", json.Bool(True)),
        ..fields
      ]
    }
    MoveSession(id, to) -> {
      use fields <- result.try(identity_fields(id))
      use destination <- result.map(text_fields([#("to", to, 64)]))
      [#("epoch", json.String(epoch_value)), ..list.append(fields, destination)]
    }
    GetOperation(id, operation, expected) -> {
      // Ensure expected epoch matches current control epoch.
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

      // Translate wake policy to string representation.
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

      // Encode pagination cursor if specified.
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

      // Translate role variant to wire format.
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
/// Validates the list of sessions requested for activity polling.
fn activity_sessions(sessions: List(String)) {
  // Validate count bounds for requested sessions.
  use Nil <- result.try(case sessions, list.drop(sessions, activity_limit) {
    [_, ..], [] -> Ok(Nil)
    [], _ | _, [_, ..] -> Error("activity names 1 to 24 sessions")
  })

  use Nil <- result.try(list.try_each(sessions, valid_id))

  // Check for duplicate session identities in request list.
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
/// Validates and encodes a principal ID into an object field list.
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

/// Validates and encodes a peer strand name into an object property.
fn peer_strand_field(strand: String, key: String) {
  // Validate strand name length.
  use Nil <- result.try(
    case string.byte_size(strand) > 0 && string.byte_size(strand) <= 128 {
      True -> Ok(Nil)
      False -> Error("invalid peer strand")
    },
  )

  Ok([#(key, json.String(strand))])
}

/// Encodes an optional text property if present and non-empty.
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

/// Validates and encodes multiple bounded string fields.
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
  // Check raw message text byte ceiling.
  use Nil <- result.try(case string.byte_size(text) <= max_bytes {
    True -> Ok(Nil)
    False -> Error("control frame exceeds byte limit")
  })

  use value <- result.try(
    json.parse(text) |> result.replace_error("invalid control JSON"),
  )

  // Verify protocol version is 2.
  use Nil <- result.try(case field(value, "v") {
    Ok(json.Int(2)) -> Ok(Nil)
    _ -> Error("unsupported control version")
  })

  use event <- result.try(text_at(value, "event", 64))
  use body <- result.try(field(value, "body"))

  // Dispatch decoding based on control event type.
  case event {
    "hello" -> {
      // Ensure hello greeting does not carry a correlation reply ID.
      use Nil <- result.try(case field(value, "reply_to") {
        Error(_) -> Ok(Nil)
        Ok(_) -> Error("correlated hello")
      })

      // Validate protocol version in hello body.
      use Nil <- result.try(case field(body, "protocol") {
        Ok(json.Int(2)) -> Ok(Nil)
        _ -> Error("unsupported hello version")
      })

      use epoch <- result.try(text_at(body, "epoch", 256))
      use principal <- result.try(text_at(body, "principal", 256))
      use limits <- result.try(field(body, "limits"))
      use limit <- result.try(number_at(limits, "control_bytes"))

      // Check advertised control bytes limit bounds.
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

      // A redirect whose members do not decode is an ordinary refusal with its
      // code and words, never a failed frame: the client still learns that the
      // daemon refused, and loses only where it pointed.
      case redirect_at(code, body) {
        Ok(redirect) -> Redirected(id, redirect)
        Error(Nil) -> Refused(id, code, message)
      }
    }
    event -> {
      use id <- result.try(positive_at(value, "reply_to"))
      use reply <- result.map(decode_reply(event, body))
      Answer(id, event, reply)
    }
  }
}

// The members of the two redirect refusals, or `Error(Nil)` for any other code
// and for a redirect that does not carry its members in the bounded form.
/// Decodes redirect details from error body when status indicates redirection.
fn redirect_at(code: String, body: json.JsonValue) -> Result(Redirect, Nil) {
  // Match specific redirection refusal codes.
  case code {
    "not_owner" -> {
      use orchestrator <- result.try(
        text_at(body, "orchestrator", 64) |> result.replace_error(Nil),
      )

      // Extract optional orchestrator address.
      case field(body, "address") {
        Error(_) -> Ok(NotOwner(orchestrator, None))
        Ok(address) ->
          bounded_text(address, 1024)
          |> result.replace_error(Nil)
          |> result.map(fn(address) { NotOwner(orchestrator, Some(address)) })
      }
    }
    "owner_unreachable" ->
      case field(body, "orchestrators") {
        Ok(json.Array(names)) if names != [] ->
          list.try_map(names, fn(name) { bounded_text(name, 64) })
          |> result.replace_error(Nil)
          |> result.map(OwnerUnreachable)
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

/// Decodes an incoming event body into its corresponding Reply type.
fn decode_reply(event: String, body: json.JsonValue) {
  // Dispatch on reply event name to decode structured payload.
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
    "sessions.move" -> {
      use session_id <- result.try(text_at(body, "session_id", 64))
      use op <- result.try(text_at(body, "op", 64))

      // Check if move operation was abandoned or completed.
      case field(body, "state") {
        // An abandon names no destination and says `abandoning`.
        Ok(json.String("abandoning")) -> Ok(AbandonedReply(session_id, op))
        Ok(_) | Error(_) -> {
          use to <- result.map(text_at(body, "to", 64))
          MovedReply(session_id, op, to)
        }
      }
    }
    "peers.inspect" -> Ok(PeersInspectionReply(body))
    "peers.link" | "peers.unlink" -> Ok(PeersMutationReply(body))
    "principals.list" | "principals.memberships" -> Ok(AccessListingReply(body))
    "sessions.set_role" | "sessions.revoke" | "credentials.revoke" ->
      Ok(AccessChangeReply(body))
    "sessions.activity" -> result.map(activity(body), ActivityReply)
    "deployment.status" -> Ok(DeploymentReply(body))
    "directory.status" -> Ok(DirectoryReply(body))
    "sessions.elsewhere" -> Ok(ElsewhereReply(body))
    "daemon.shutdown" ->
      case field(body, "state") {
        Ok(json.String("draining")) -> Ok(ShutdownReply)
        _ -> Error("invalid shutdown acknowledgement")
      }
    _ -> Error("unknown control event")
  }
}

/// Decodes the daemon status summary metrics from response body.
fn summary(body: json.JsonValue) {
  use epoch <- result.try(text_at(body, "epoch", 256))

  // Decode readiness status indicator.
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

/// Decodes a page of listed sessions including revision and continuation.
fn page(body: json.JsonValue) {
  use revision <- result.try(number_at(body, "revision"))

  // Parse sessions array and ensure bounded length.
  use values <- result.try(case field(body, "sessions") {
    Ok(json.Array(values)) ->
      case list.drop(values, 100) {
        [] -> Ok(values)
        [_, ..] -> Error("too many sessions")
      }
    _ -> Error("invalid session page")
  })

  use decoded <- result.try(list.try_map(values, listed))
  let sessions = option.values(decoded)

  // Decode optional continuation cursor ID.
  use after <- result.try(case field(body, "after") {
    Ok(json.Null) -> Ok(None)
    Ok(json.String(id)) -> result.map(valid_id(id), fn(_) { Some(id) })
    _ -> Error("invalid continuation")
  })

  Ok(Page(revision, sessions, after))
}

// One record of a listing, or nothing for a session this daemon no longer
// serves. A record that carries `moved` is the tombstone the source keeps for a
// session another orchestrator owns now: the conversation is not here, nothing
// here can open it, and its new owner lists it. It is not a row, so the page
// leaves it out, and no consumer of a page has to remember to
// (`protocol-change/085`). The member is read as present or absent, and its
// destination is not needed, so a tombstone whose `to` is damaged is still not
// listed as a session that can be opened.
fn listed(body: json.JsonValue) -> Result(Option(Session), String) {
  case field(body, "moved") {
    Ok(_) -> Ok(None)
    Error(_) -> result.map(session(body), Some)
  }
}

/// Decodes a complete Session record from JSON representation.
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
    moving_status(body, status),
    subtitle_of(body),
    executor_of(body),
  )
}

// The optional `moving` member, which reads over the `saved` the daemon reports
// beside it. Like the subtitle it is a display aid, so a member that is not an
// object with an orchestrator name reads as absent and the row keeps the status
// it came with. The daemon refuses an open of the row either way. The name is
// held to the grammar of an `[orchestrators.<name>]` key, so it has no
// whitespace or control character: it prints into a table cell and into one
// token of the plain listing without being cleaned again.
/// Derives session moving status from payload or preserves current lifecycle.
fn moving_status(body: json.JsonValue, status: Lifecycle) -> Lifecycle {
  let destination =
    field(body, "moving")
    |> result.try(text_at(_, "to", 64))
    |> result.try(fn(to) {
      case placement.is_orchestrator_name(to) {
        True -> Ok(to)
        False -> Error("invalid orchestrator name")
      }
    })

  // Use destination moving status if decoded successfully.
  case destination {
    Ok(to) -> Moving(to)
    Error(_) -> status
  }
}

// The optional executor of a remote session. Like the subtitle it is a display
// aid, so a member that is absent, empty, too long or not a string reads as
// none and does not fail the row. `text_at` already refuses the empty string.
fn executor_of(body: json.JsonValue) -> Option(String) {
  text_at(body, "executor", 64) |> option.from_result
}

// The optional subtitle. Every way of not being a nonblank string of at most 60
// characters reads as none, rather than refusing the row it is on.
/// Extracts the optional bounded subtitle text from a session object.
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

/// Decodes a single session activity status row.
fn activity_row(row: json.JsonValue) {
  use id <- result.try(text_at(row, "session_id", 64))
  use Nil <- result.map(valid_id(id))

  // Map session activity state.
  let state = case field(row, "state") {
    Ok(json.String("needs_you")) -> NeedsYou
    Ok(json.String("working")) -> Working
    Ok(json.String("idle")) -> Idle
    _ -> Unknown
  }

  // Parse last terminal operation outcome.
  let last_outcome = case field(row, "last_outcome") {
    Ok(json.String("completed")) -> Some(LastCompleted)
    Ok(json.String("failed")) -> Some(LastFailed)
    Ok(json.String("aborted")) -> Some(LastAborted)
    _ -> None
  }

  // Parse session glance observation lines.
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
/// Decodes a glance line containing strand, title, and summary.
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

/// Decodes session lifecycle status from a JSON payload.
fn lifecycle(body: json.JsonValue) {
  use state <- result.try(text_at(body, "state", 64))

  // Parse status into domain Lifecycle variant.
  case state {
    "reserved" -> Ok(reserved(body))
    "saved" -> Ok(Saved)
    "opening" -> result.map(text_at(body, "operation", 512), Opening)
    "resident" -> result.map(text_at(body, "incarnation", 512), Resident)
    "stopping" -> result.map(text_at(body, "operation", 512), Stopping)
    "recovery_blocked" -> Ok(RecoveryBlocked)
    _ -> Error("invalid session lifecycle")
  }
}

// A reservation, and the failure the daemon kept for it when it sent one that
// is well formed: a nonblank single line of at most 512 bytes and a time. The
// member is an addition to the status object, so one that is missing or does
// not decode leaves the plain reservation an older daemon sent, and never fails
// the row (`protocol-change/093`).
/// Decodes a reserved lifecycle state with optional failure reason.
fn reserved(body: json.JsonValue) -> Lifecycle {
  let failure = {
    use kept <- result.try(field(body, "failure"))
    use reason <- result.try(text_at(kept, "reason", 512))
    use at <- result.try(number_at(kept, "at"))

    // Verify failure reason does not span multiple lines.
    case string.contains(reason, "\n") || string.contains(reason, "\r") {
      True -> Error("failure reason spans lines")
      False -> Ok(FailedStart(reason:, at:))
    }
  }
  result.unwrap(failure, Reserved)
}

/// Extracts an optional correlation reply ID if present.
fn optional_id(value: json.JsonValue) {
  case field(value, "reply_to") {
    Error(_) -> Ok(None)
    Ok(json.Int(id)) if id > 0 -> Ok(Some(id))
    Ok(_) -> Error("invalid reply id")
  }
}

/// Extracts a single field by key from a JSON object.
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
/// Decodes optional web view prefix configuration from hello body.
fn view_at(body: json.JsonValue) {
  // Extract UI property or fallback to NoWebView.
  case field(body, "ui") {
    Error(_) -> Ok(NoWebView)
    Ok(view) -> {
      use path <- result.try(text_at(view, "path", 256))
      use origins <- result.map(origins_at(view))
      WebViewAt(path, origins)
    }
  }
}

// The most listed origins a hello may name, the daemon's own bound
// (`ui_origin.max_origins`).
const max_view_origins = 16

// The listed `https` origins of the view (protocol-change/052). An absent
// field is none, as from a daemon that predates it. A present one is an array
// of at most `max_view_origins` nonempty `https://` strings, or the hello is
// refused, because `loom ui --device` builds a link on one of them.
/// Decodes web view allowed origins list from UI configuration.
fn origins_at(view: json.JsonValue) -> Result(List(String), String) {
  // Match origins array property.
  case field(view, "origins") {
    Error(_) -> Ok([])
    Ok(json.Array(items)) -> {
      // Check origins array length bound.
      use Nil <- result.try(case list.drop(items, max_view_origins) == [] {
        True -> Ok(Nil)
        False -> Error("too many web view origins")
      })

      list.try_map(items, fn(item) {
        use text <- result.try(bounded_text(item, 256))

        // Ensure each origin uses secure https scheme.
        case string.starts_with(text, "https://") {
          True -> Ok(text)
          False -> Error("a web view origin must be https")
        }
      })
    }
    Ok(_) -> Error("expected an array of web view origins")
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

/// Validates that a JSON value is a string within the specified byte limit.
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

/// Reads a positive integer field by key.
fn positive_at(value: json.JsonValue, key: String) {
  use number <- result.try(number_at(value, key))

  // Verify integer is strictly positive.
  case number > 0 {
    True -> Ok(number)
    False -> Error("expected positive request id")
  }
}
