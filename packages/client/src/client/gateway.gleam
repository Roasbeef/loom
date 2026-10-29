//// One gateway actor per resident session, with original-handle v2 attachment.
////
//// Runtime effects own executable tool registrations. The gateway's separate
//// tool view retains registered names alone: operator selection and source
//// recovery test membership, and availability lists names in sorted order.
//// An absent view remains distinct from a configured empty registry.
////
//// ## Flow
////
//// `start` → `attach_authenticated` → `connection_request` → `handle` →
//// `request_frame` → `network_dispatch` → `run_command` → `pull_and_broadcast`
//// → `deliver`
////
//// 1. `start` builds the actor from `Options`; the transport then joins it with
////    `attach_authenticated`, which records the `Binding` the upgrade router
////    resolved and never lets the socket name its own identity.
//// 2. `connection_request` sends one `Request` message and waits for one
////    bounded reply; `handle` is the actor's single entry for every message,
////    and routes it to `request_frame`.
//// 3. `request_frame` re-checks authority with `revalidate` (the admission
////    point), then `network_dispatch` decodes the frame with
////    `protocol.decode_command`.
//// 4. `network_command` keeps the bounded transfers (`begin_transfer`,
////    `advance_transfer`) to itself and sends every other command to
////    `run_command`, which refuses observers and a draining session before
////    any effect.
//// 5. `run_command` maps the command onto `runtime/api`; the commit it causes
////    comes back as a `CommitHint` or `BusHint`.
//// 6. `pull_and_broadcast` pulls what storage holds above the high-water seq
////    with `pull`, de-duplicates by seq and `broadcast`s the frames.
//// 7. `send_response` and `deliver` check the binding again (`check_binding`,
////    the delivery point) before a reply or a push reaches the socket.
//// 8. A child's request on another orchestrator is decided in two places
////    (protocol-change/089). On the laptop, `from_elsewhere` routes an `approve`
////    or `deny` that names a filed request to `start_resolve`, which sends it to
////    the box from a weft run, and `resolve_reported` answers the socket when the
////    run reports. On the box, `decide` is the hub's door for the spawner's
////    operator's decision, judged by `client/remote_decision`.
//// 9. Children on other orchestrators (protocol-change/090) reach a client two
////    ways. `push_remote_children` pushes the session's stubs, projected by
////    `remote_child.agents`, once to a client that subscribes and to every
////    subscriber when the bus says a stub changed. `begin_history` reads a
////    page of a child's transcript as an observation, in a task, so the
////    other orchestrator's answer never holds this mailbox.
////
//// ## Authenticated network delivery
////
//// A socket supplies one request and waits for one bounded reply. Coherent
//// metadata and descriptors come from the bounded storage reader; raw records
//// and metadata are fragmented under explicit client credit. Optional provider
//// previews use sixteen original observer leases and one bounded, explicitly
//// discontinuous sample.
////
//// Alongside those replies the hub *pushes* frames that answer no request
//// (`protocol-change/018`): a `committed` notice per durable emit the
//// writer's commit hint made it observe, a clipped `stream_delta` while an
//// answer is being generated, the presence roster, and a connection-scoped
//// `error`. A push carries a notice and never a durable record, so the
//// credited transfer remains the one place the 64 KiB bound and the
//// retention window are enforced; and it leaves through `deliver`, so it is
//// re-authorized per frame exactly as a reply is.
//// Authentication is rechecked before admission and delivery. A storage actor
//// that is gone, which the exchange proves by monitoring it, permanently
//// poisons this actor and invokes its exact incarnation's stop capability,
//// without waiting for the requesting gateway itself to retire. A storage
//// actor that is merely slow does not: a transfer's capture is asked of it by
//// a weft run that owns the reply subject and the deadline, so this mailbox
//// never waits for storage and a late answer dies with the run. A capture or
//// continuation that times out refuses that one request, in band, and tells
//// the client to retry; it drops that transfer and touches nothing else.
////
//// ## Authority
////
//// Nothing a client sends names a principal, a role or an origin. The
//// attachment's identity is the `Binding` the upgrade router resolved before
//// this actor saw the socket, it is immutable for the life of the
//// attachment, and every durable origin this module writes is minted from it.
//// The socket supplies frames; it does not supply who it is.
////
//// Membership can be revoked while an attachment is open, so authority is
//// resolved twice per command rather than cached at attach. `request_frame`
//// resolves it before the command is dispatched, which is the **admission**
//// point; `send_response` and `deliver` resolve it again before anything
//// leaves, which is the **delivery** point. Both go through `check_binding`,
//// which compares the freshly resolved principal and role against the ones
//// the `Binding` was admitted under and fails on any change, not only on a
//// revocation. A revocation between the two points therefore closes the
//// attachment and drops the reply: work already admitted is allowed to
//// finish — the writer has no way to un-commit it — but its answer does
//// not reach a peer that has lost the right to it, and no further command
//// from that socket is admitted.
////
//// Roles differ only in what they may ask for. An `Observer` is refused
//// before any effect: `run_command`'s first act is to reject a command that
//// `read_only` does not classify as a read, and `read_only` is exhaustive
//// over `Command`, so a command added later cannot be admitted for an
//// observer by omission.
////
//// ## Command dispatch
////
//// Commands map onto `runtime/api` (prompt/steer/follow-up/abort,
//// escalation approve/deny, idle strand creation, compaction and
//// navigation). The API builds `machine/acceptance` plans and commits
//// them through the session's one writer, sharing admission with other
//// runtime callers.
//// Nothing bypasses the writer.
////
//// ## Conversation command semantics
////
//// Five answers this module gives where the wire format alone does not
//// determine one. Each is invisible at the call site and each is what a
//// client's rendering has to be written against.
////
//// - `fork` (both scopes) forks **in place**: a new strand whose leaf
////   is the source strand's current leaf. The protocol's reply is a
////   `strands` snapshot of *this* session, which cannot name a separate
////   forked session file; `session/repo.fork` stays an admin surface.
//// - `steer`/`follow_up` acks: the queued item is durable as a pending
////   register, not yet a placed tree entry, so the ack `entry` event
////   carries the reserved id and the message with no envelope seq; the
////   placed entry is broadcast (with its real parent and seq) when the
////   run consumes it.
//// - `follow_up` on an idle strand starts a run (protocol.md open
////   question 7 answered queue-as-prompt, matching `send_to_strand`'s
////   idle behavior).
//// - `strand_result` is emitted for every operation kind — runs,
////   compactions, navigations — because all three publish
////   `strand.last_result`.
//// - Escalation `op`/`strand` come off the record's own `CallScope` —
////   the operation, strand, step, source index, and call id the denial
////   was raised for. A record raised through a door that names no call
////   reaches the client with both fields empty; nothing is inferred
////   from which strand happens to be busy.
////
//// ## Internal host fixture mode
////
//// The hub is transport-agnostic: a connection is a sink function the
//// transport registers with `attach` (the websocket server sends each
//// encoded frame down its socket; the demo and the tests collect them
//// in a subject). Inbound frames arrive as text through `handle_text`;
//// every reply and broadcast leaves through the sinks. Nothing in this
//// module knows about sockets.
////
//// ## Legacy host fixture event stream
////
//// The envelope `seq` **is the storage seq** of the write that produced
//// the event. Storage assigns strictly increasing seqs to every write —
//// entries, usage rows, and register sets share one per-session space —
//// so the gateway's stream needs no materialized side-index: it is
//// durable across gateway restarts by construction, and `catch_up`
//// rebuilds it with `scan_entries`/`scan_usage` plus register reads.
//// Two consequences, both documented protocol behavior:
////
//// - `entry` and `usage` events replay exactly (their rows are
////   immutable, scanned by seq range);
//// - register-backed events (`op_transition`, `escalation`,
////   `strand_result`) replay as *current state at current seq* —
////   registers keep no history, so a superseded phase is not
////   reconstructible. Events are hints and the snapshot carries the
////   live state, so a client that missed an intermediate phase still
////   converges; overlap and gaps are resolved by seq dedup as
////   protocol.md already requires.
////
//// Live materialization follows "events are hints; pulls are truth":
//// the runtime writer's post-commit publication (bridged in by the
//// composition layer via `commit_forwarder`) and any events-bus
//// publications both merely trigger a pull from storage above the hub's
//// high-water seq. A lost hint costs latency, never an event.
////
//// ## Internal host fixture stream deltas
////
//// `tap_provider` wraps an injected `runtime/effects.ProviderSurface`
//// so provider deltas are teed to the hub (broadcast as ephemeral
//// `stream_delta` events, never persisted, never seq'd) while the
//// runtime's effect process consumes the stream unchanged. The tap
//// lives entirely in the composition seam — the runtime is untouched.
////
//// ## Flow
////
//// `handle` dispatches `BusHint` as well as socket requests.
//// The goal hint goes through `push_to_subscribed`, then `deliver`.
//// `deliver` calls `check_binding` before an authenticated socket receives it.
//// For the resulting goal read, follow `request_frame`, `network_dispatch`,
//// `network_command`, `run_command` and `read_goal`. Bounded transcript
//// capture starts in `begin_transfer`, which returns without answering; its
//// weft run reports back as `CaptureReported`, and `capture_reported` answers
//// the held reply through `answer_capture` and `captured_transfer`, or refuses
//// it through `reader_failed`. A goal board has its own reply path.
//// `reader_failed` refuses a bounded read without treating that refusal as
//// connection loss. `reply_error` uses the same authenticated reply path.
//// For held input, start with `hold_prompt`, `release_halt` and `halted_queue`.
//// These are separate paths inside one actor, not a single call chain.

import broker/framing
import broker/internal/call
import broker/policy.{type Grant}
import client/advisor
import client/advisor_pending
import client/approval_ceiling
import client/blocksummary
import client/btw
import client/catalog
import client/daemon/transfer
import client/delegate_outbox
import client/directories
import client/escalate
import client/escalation_view
import client/evolution/control as evolution_control
import client/evolution/store as evolution_store
import client/goal_pending
import client/goalcommand
import client/grants
import client/internal/session_owner
import client/memory_overview
import client/notes_view
import client/peer_mail
import client/permissions
import client/profile_switch
import client/proposals
import client/protocol.{
  type Command, type EntryRecord, type Event as WireEvent, type EventEnvelope,
  EntryRecord, EventEnvelope, LiveOp, Strand,
}
import client/provider_relay
import client/remote_child
import client/remote_decision
import client/remote_escalation
import client/remote_escalation_store
import client/remote_reach
import client/remote_spawn
import client/schedule
import client/scheduleadmin
import client/skills
import client/wiring
import core/accounting
import core/clock
import core/codec as core_codec
import core/entry.{type Entry, type UsageRow}
import core/glance
import core/ids.{type EntryId, type OpId}
import core/json.{type JsonValue}
import core/message.{type AgentMessage, type UserBlock}
import core/origin
import core/register
import core/tx
import core/usage_evidence
import events/bus
import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import host/skill
import machine/acceptance
import machine/codec as machine_codec
import machine/operation
import machine/planner
import machine/queue
import machine/strand as machine_strand
import provider/stream
import runtime/api
import runtime/effects
import runtime/escalation as runtime_escalation
import runtime/hooks
import runtime/writer
import session/session
import session_view/btw as btw_view
import session_view/protocol as session_wire
import session_view/remote_agent
import session_view/remote_usage
import session_view/snapshot_view
import storage/access
import storage/snapshot
import storage/storage.{type EntryHead}
import telemetry/owner
import tools/agent as agent_tools
import tools/history
import tools/tool.{type Registry}
import weft
import weft/actor
import weft/registry as address

/// A running gateway hub, addressed by name so the provider tap and the
/// commit forwarder can reach it before it starts.
pub type Gateway {
  Gateway(name: address.Address(Message))
}

/// The hub either could not be reached before dispatch, or did not establish
/// the decision's outcome after dispatch. These are internal transport facts.
@internal
pub type DecisionFailure {
  /// The hub had no recipient before the decision was sent.
  HubUnavailable

  /// The hub may have committed the decision without returning its record.
  DecisionUnknown(
    /// What the hub could establish about the decision.
    reason: String,
  )
}

/// Immutable server-resolved identity of one authenticated session attachment.
pub type Binding {
  Binding(
    /// Canonical session identity, independent of names chosen by commands.
    session_id: String,
    /// Daemon lifetime identity captured by the upgrade router.
    epoch: String,
    /// Resident instance identity captured by the upgrade router.
    incarnation: String,
    /// Fresh connection identity for presence and restart fencing.
    connection_id: String,
    /// Principal identity and name authenticated at upgrade.
    principal: access.Principal,
    /// Role whose parser reservation was admitted at upgrade.
    authority: access.Authority,
    /// Credential digest, never plaintext bearer material.
    digest: access.Digest,
    /// The fingerprint of the browser sign-in this connection belongs to, when
    /// it is a web page that has one. A page opened by `loom ui` is admitted
    /// under the terminal's bearer (`digest`) and carries the login its
    /// exchange set beside it, so the digest alone would record every grant
    /// the page makes as a terminal's. The daemon copies the fingerprint from
    /// the page's own record and never from a frame, as it does `digest`.
    signin: Option(String),
    /// Which listener admitted the connection. The daemon sets it from the
    /// route that built the binding and never from a frame. It is the only
    /// thing that tells an owner page opened by `loom ui`, which has no sign-in
    /// and holds the terminal's bearer, from a terminal or `loom evolution`
    /// holding the same bearer.
    door: Door,
  )
}

/// The listener a session attachment came in through, which decides the
/// surface an evolution act is recorded as coming from (protocol-change/099,
/// ruling 5). It is a type rather than a flag so a construction site names the
/// listener it is.
pub type Door {
  /// The daemon's web page socket, including a page opened with `loom ui`.
  PageDoor

  /// The session socket that a terminal and `loom evolution` attach through.
  SocketDoor
}

/// A connection addresses its original gateway process, never a replacement.
pub opaque type ConnectionHandle {
  ConnectionHandle(subject: Subject(Message), id: Int, pid: process.Pid)
}

// How a connection was admitted, and therefore what it may be trusted with.
// This is the module's security boundary: `deliver`, `reader_failed`,
// `remove_socket` and `roster` all branch on it, so which variant a transport
// can produce is the whole of what that transport is allowed to be.
type Authentication {
  /// A trusted in-VM sink registered through `attach` — the demo, a test, an
  /// embedded host. It carries no principal, so it is in no presence roster
  /// and no durable origin is ever minted from it. Only `@internal` callers
  /// can produce it; a network listener must use `attach_authenticated`.
  HostFixture

  /// A network socket whose principal, role and credential digest were
  /// resolved by the upgrade router before this actor saw it.
  ///
  /// `binding` is that resolved identity and never changes. `check` re-asks
  /// the registry who this credential is now, and is called at admission and
  /// again at delivery. `close` retires the transport when the answer has
  /// changed. `watch` monitors the socket process, so presence is removed
  /// even when the transport's own `on_close` cannot run.
  Authenticated(
    binding: Binding,
    check: fn() -> Result(#(access.Principal, access.Authority), String),
    close: fn() -> Nil,
    watch: process.Monitor,
  )
}

/// Hub configuration.
///
/// Constructor invariants: `session_id` is the name clients subscribe
/// with; `runtime` is an open session runtime whose writer was given the
/// `commit_forwarder` subject (so commit hints reach the hub);
/// `recent_entries` bounds the full snapshot's entry window; `bus`, when
/// present, adds events-bus publications as extra pull hints; `catalog`,
/// when present, backs the `models` command and `set_config`'s
/// `model_name` key (without one the listing is empty and name switches
/// are refused in-band); `registry` is the same tool registry the
/// effect wiring dispatches through, and backs `set_config`'s
/// `active_tools` key (without one, changes to the active set are
/// refused in-band — the hub will not write a tool name it cannot
/// check); `schedules`, when present, backs the `schedules` listing and
/// `schedule_cancel` (without one the listing is empty and a
/// cancellation is refused as unsupported, because a host with no
/// scheduling plane has nothing to cancel); `effect_abort`, when
/// present, is how the `abort` command reaches the effect plane, and a
/// host with no broker supplies none.
pub type Options {
  Options(
    session_id: String,
    runtime: api.Runtime,
    recent_entries: Int,
    /// The event bus the hub listens on. A network hub joins only the
    /// `Outputs` topic — the rolling tails of running tool calls, which
    /// reach every subscribed peer as pushed `tool_output` frames
    /// (`protocol-change/031`) — because a one-session server's writer
    /// sits in the same VM as its hub, so `commit_forwarder` already
    /// carries every commit's hint and a second hint source would make
    /// the same pull happen twice. The host fixture joins every topic,
    /// which is what a host whose hint sources are *not* all its own
    /// writer needs, with `events/bus.bridge` as the seam that feeds it.
    /// `None` is a hub that pushes no tool output; `client/serve`
    /// supplies the bus the effect wiring publishes on.
    bus: Option(bus.Bus),
    catalog: Option(catalog.Catalog),
    registry: Option(Registry),
    /// Skills captured by this daemon, shared with the model load tool.
    skills: skill.Catalogue,
    /// Boot diagnostic when code mode could not be registered.
    code_mode_issue: Option(String),
    /// Bounded startup refusals for installed extensions, shared by all peers.
    extension_refusals: List(String),
    schedules: Option(scheduleadmin.Admin),
    /// The operator's half of the proposal queue, when this host has one.
    proposals: Option(proposals.Admin),
    /// The operator's read of the memory overview, when this host has one.
    memory_overview: Option(memory_overview.Admin),
    /// Operator-owned additions to this session's filesystem authority.
    directories: Option(directories.Admin),
    /// The effect plane's own sweep of an aborted operation, called by
    /// the `abort` command with the operation it just marked cancelled.
    /// `client/serve` fills it with `broker.abort`; a host assembled
    /// without an effect plane has nothing to sweep and passes `None`.
    effect_abort: Option(fn(OpId) -> Nil),
    /// The operator's goal commands over the advisor actor, when the
    /// host wired an advisor. `None` is the goal gate itself: the
    /// commands answer `unsupported`, because no advisor means no
    /// reviewer to judge the goal's completion.
    goal_control: Option(goalcommand.Seam),
    /// Authenticated evolution inspection and operator transitions. The seam
    /// rechecks scope before touching the shared catalogue or live owner.
    evolution: Option(evolution_control.Seam),
    /// The advisor actor's own notice of an aborted primary run, called
    /// by the `abort` command with the operation it just marked
    /// cancelled. An aborted run never reaches the run-end hook the
    /// advisor listens on, so this cast is the one channel the goal
    /// loop has for learning the operator stopped a run (protocol 044
    /// §4). `client/serve` fills it with the advisor's address; a host
    /// with no advisor passes `None` and the cast is simply never made.
    goal_abort: Option(fn(OpId) -> Nil),
    /// Host-supplied bounded observation capabilities.
    worktree_diff: Option(fn() -> Result(JsonValue, String)),
    /// Explicit live job reads, never invoked by ordinary transcript captures.
    live_jobs: Option(fn(String) -> Result(JsonValue, String)),
    /// Bounded context observation, sharing the managed read workers.
    context: Option(fn(String) -> Result(JsonValue, String)),
    /// Reads one page of a remote child's transcript, given the child's name
    /// as the session's remote children list it and the cursor, and answers
    /// the page as a `remote_transcript` object or the reason there is none
    /// (protocol-change/090). It runs in an observation's task, never in the
    /// hub. `None` answers every `child_history` with `unavailable`.
    child_history: Option(fn(String, Int) -> Result(JsonValue, String)),
    /// Disposable side conversations are scoped to this connection incarnation.
    btw: Option(address.Address(btw.Message)),
    /// Where the blocks a `block_summaries` read found no summary for are
    /// sent to be summarized on demand (protocol 050). `None` asks nothing.
    summary_demand: Option(fn(List(#(String, Int))) -> Nil),
    /// Told the text of the first human prompt this hub accepts on the main
    /// strand, once (`protocol-change/067`). The daemon fills it with the
    /// catalogue's subtitle write; a host with no catalogue passes `None`.
    first_prompt: Option(fn(String) -> Nil),
    /// What the hub needs from the daemon to read and switch the session's
    /// model profile (`protocol-change/082`). `None` is a session with no
    /// daemon behind it: `profile_get` and `profile_set` answer `unsupported`.
    profile: Option(profile_switch.Desk),
    /// For a delegate session: where its parent is and what the spawner's
    /// operator may approve (protocol-change/089). `None` for every other
    /// session, whose hub then takes no decision from a spawner.
    spawner: Option(delegate_outbox.SpawnerLink),
    /// How this session asks another orchestrator to apply its operator's
    /// decision about a child's request (protocol-change/089). `None` reaches
    /// none, and such a decision is refused.
    remote: Option(remote_reach.Reach),
  )
}

/// Messages understood by the hub. Opaque in spirit: callers use the
/// wrapper functions below (the constructors are exported only through
/// them).
pub opaque type Message {
  Request(connection: Int, text: String, reply: Subject(Result(String, String)))
  MaintainTransfers
  ObservationReported(connection: Int, pulled: weft.Pulled(JsonValue, String))

  /// A transfer's capture has an outcome, or its run has ended without one.
  /// The capture was asked of storage by a weft run, never by this mailbox, so
  /// this is the only way its answer, or its silence, reaches the hub.
  CaptureReported(
    capture: Int,
    pulled: weft.Pulled(snapshot.Cut, snapshot.Error),
  )
  LeasePreview(process.Pid, Int, Subject(Result(Int, String)))
  Preview(Int, String, String, String, String, Subject(Result(Nil, String)))
  ReleasePreview(Int, Subject(Nil))
  Attach(sink: fn(String) -> Nil, reply: Subject(Int))
  AttachAuthenticated(
    Binding,
    fn() -> Result(#(access.Principal, access.Authority), String),
    fn(String) -> Nil,
    fn() -> Nil,
    fn() -> Nil,
    fn(Subject(Nil)) -> Nil,
    process.Pid,
    Subject(Result(ConnectionHandle, String)),
  )
  SocketDown(process.Down)
  Attached(reply: Subject(Int))

  /// A spawner's operator's decision about a child's request in this delegate
  /// session (protocol-change/089). It is judged and committed on the hub's turn,
  /// against the same record a local operator would answer.
  DecideForSpawner(
    parent: remote_spawn.Parent,
    escalation_id: String,
    decision: remote_escalation.Decision,
    expected_seq: Int,
    decided_by: remote_escalation.Decider,
    reply: Subject(Result(remote_escalation.Answer, String)),
  )

  /// The decision of the page of the spawner that started this session, about
  /// one of its requests (protocol-change/094). It is judged and committed on the
  /// hub's turn, as a delegate session's is, against the same record a local
  /// operator would answer. The caller has already checked that the registry
  /// names this session as relayed for the spawner.
  DecideForRelayed(
    spawner: String,
    ceiling: Option(approval_ceiling.Ceiling),
    escalation_id: String,
    decision: remote_escalation.Decision,
    expected_seq: Int,
    decided_by: remote_escalation.Decider,
    reply: Subject(Result(remote_escalation.Answer, String)),
  )

  /// A stop of the main strand's run from the page of the spawner that started
  /// this session (protocol-change/094). The reply says it was taken.
  StopForRelayed(reply: Subject(Result(Nil, Nil)))

  /// What a decision this hub sent to another orchestrator came to, or that its
  /// run ended without saying.
  ResolveReported(
    resolve: Int,
    pulled: weft.Pulled(remote_escalation.Answer, peer_mail.Failure),
  )
  Detach(connection: Int)
  FromClient(connection: Int, text: String)
  CommitHint
  BusHint(published: bus.Published)
  ProviderDelta(operation: OpId, generation: String, delta: stream.Delta)
  ProviderEnded(operation: OpId, generation: String)

  /// Return every held prompt to its submitter and empty the queues, with
  /// the ack that says the walk is done.
  ///
  /// A drain is the one exit that can promise nothing about a held item:
  /// the hub is about to be torn down, so custody of every message it
  /// still holds goes back to whoever submitted it. The ack is what makes
  /// the walk observable — a caller that has received it knows every
  /// return has been emitted on the hub's own process, before the sinks it
  /// wrote to are closed.
  DrainHeld(flushed: Subject(Nil), reply: Subject(Int))

  /// The configuration file this session loads has changed and the new text
  /// loads. The session reopens to read it once no strand is running.
  ConfigChanged
}

// Whether the session owes a reopen for a configuration file that changed under
// it. `Owed` waits for every strand to go idle, because the reopen stops the
// session and a run in flight is not the reload's to interrupt; `Reopening`
// keeps a second notice from starting a second restart while the first stops
// this hub.
type Reload {
  Current
  Owed
  Reopening
}

type State {
  State(
    subject: Subject(Message),
    selector: process.Selector(Message),
    observations: Dict(Int, PendingObservation),
    // Transfer captures in flight, by capture number. A number rather than a
    // connection id, because a connection's next request can arrive before
    // the run's final word for the previous one, and the two must not share
    // a slot.
    captures: Dict(Int, PendingCapture),
    next_capture: Int,
    // Decisions sent to another orchestrator and not yet answered, by number.
    // The call is a network round trip, so it runs in a weft run that reports
    // back, as a capture does, and this mailbox never waits for it.
    resolves: Dict(Int, PendingResolve),
    next_resolve: Int,
    spawner: Option(delegate_outbox.SpawnerLink),
    remote: Option(remote_reach.Reach),
    worktree_diff: Option(fn() -> Result(JsonValue, String)),
    live_jobs: Option(fn(String) -> Result(JsonValue, String)),
    /// Bounded context observation, sharing the managed read workers.
    context: Option(fn(String) -> Result(JsonValue, String)),
    /// The transcript page reader of remote children, when the daemon has one.
    child_history: Option(fn(String, Int) -> Result(JsonValue, String)),
    /// Disposable side conversations are scoped to this connection incarnation.
    btw: Option(address.Address(btw.Message)),
    /// On-demand summarization of blocks a read found unsummarized.
    summary_demand: Option(fn(List(#(String, Int))) -> Nil),
    // The report of the first accepted main-strand prompt, until it is made.
    // `None` is both a host with no catalogue and a report already sent, so
    // the check on the hot path is one pattern match.
    first_prompt: Option(fn(String) -> Nil),
    // The daemon's door for the session's model profile, when it has one.
    profile: Option(profile_switch.Desk),
    reload: Reload,
    delivery: Delivery,
    health: Health,
    admission: Admission,
    next_transfer: Int,
    preview_sources: Dict(Int, process.Monitor),
    next_preview_source: Int,
    preview: Option(LivePreview),
    preview_revision: Int,
    session_id: String,
    runtime: api.Runtime,
    recent_entries: Int,
    connections: Dict(Int, Connection),
    next_connection: Int,
    high_water: Int,
    // strand → open operation id (as text), for terminal detection.
    live: Dict(String, String),
    // strand → prompts held for a busy strand, in arrival order at this
    // one actor, which is what makes the order total.
    held: Dict(String, HeldQueue),
    // Monotonic item identity prevents reused client request IDs from aliasing.
    next_held: Int,
    // Entry id (text) → strand and the evidence for its ownership.
    entry_strand: Dict(String, EntryAttribution),
    // The effect plane's sweep of an aborted operation, when the host
    // has an effect plane at all.
    effect_abort: Option(fn(OpId) -> Nil),
    // The operator's goal commands, when the host wired an advisor.
    goal_control: Option(goalcommand.Seam),
    // The connection's native identity crosses this seam separately from JSON.
    evolution: Option(evolution_control.Seam),
    // The advisor actor's abort notice, when the host wired an advisor.
    goal_abort: Option(fn(OpId) -> Nil),
    // The model catalogue, when the host configured one.
    catalog: Option(catalog.Catalog),
    // Operator configuration needs registered names, never tool executors.
    // Absence still refuses active-set changes; a configured empty set permits
    // clearing the selection without retaining execution authority in this slot.
    registered_tools: Option(Dict(String, Nil)),
    /// Skills captured by this daemon, shared with the model load tool.
    skills: skill.Catalogue,
    // The original boot diagnostic, not a guessed missing executable.
    code_mode_issue: Option(String),
    /// Bounded startup refusals for installed extensions, shared by all peers.
    extension_refusals: List(String),
    // The operator's scheduling door, when this host has one.
    schedules: Option(scheduleadmin.Admin),
    // The operator's half of the proposal queue, when this host has one.
    proposals: Option(proposals.Admin),
    // The operator's read of the memory overview, when this host has one.
    memory_overview: Option(memory_overview.Admin),
    /// Operator-owned additions to this session's filesystem authority.
    directories: Option(directories.Admin),
  )
}

/// Sensible defaults: a 50-entry snapshot window, no bus, no catalogue,
/// no tool registry, no scheduling plane, and no effect plane to sweep
/// on an abort.
///
/// ## Examples
///
/// ```gleam
/// // gateway.default_options("sess-01", runtime)
/// ```
///
pub fn default_options(session_id: String, runtime: api.Runtime) -> Options {
  Options(
    session_id:,
    runtime:,
    recent_entries: 50,
    bus: None,
    catalog: None,
    registry: None,
    skills: skill.empty(),
    code_mode_issue: None,
    extension_refusals: [],
    schedules: None,
    proposals: None,
    memory_overview: None,
    directories: None,
    effect_abort: None,
    goal_control: None,
    evolution: None,
    goal_abort: None,
    worktree_diff: None,
    live_jobs: None,
    context: None,
    child_history: None,
    btw: None,
    summary_demand: None,
    first_prompt: None,
    profile: None,
    spawner: None,
    remote: None,
  )
}

/// Tells a delegate session's hub where its parent is and what the spawner's
/// operator may approve, so that it can take that operator's decisions
/// (protocol-change/089).
///
/// ## Examples
///
/// ```gleam
/// // gateway.with_spawner(options, link)
/// ```
pub fn with_spawner(
  options: Options,
  link: delegate_outbox.SpawnerLink,
) -> Options {
  Options(..options, spawner: Some(link))
}

/// Gives a session's hub the means to ask another orchestrator to apply a
/// decision about a child's request that runs there (protocol-change/089).
///
/// ## Examples
///
/// ```gleam
/// // gateway.with_remote_reach(options, reach)
/// ```
pub fn with_remote_reach(
  options: Options,
  reach: remote_reach.Reach,
) -> Options {
  Options(..options, remote: Some(reach))
}

/// Captures at most 32 extension notices of 2048 UTF-8 bytes each for every
/// authenticated snapshot, so reconnecting operators receive the diagnosis.
///
/// ## Examples
///
/// ```gleam
/// // gateway.with_extension_refusals(options, ["Extension weather refused: stale record"])
/// ```
pub fn with_extension_refusals(
  options: Options,
  reasons: List(String),
) -> Options {
  Options(
    ..options,
    extension_refusals: list.map(list.take(reasons, 32), glance.clip(_, 2048)),
  )
}

/// Supplies where blocks a `block_summaries` read found no summary for are
/// sent to be summarized on demand: in `client/serve`,
/// `blocksummary.ask_for` on the session's summarizer. The read's reply
/// never waits for it.
///
/// ## Examples
///
/// ```gleam
/// // gateway.with_summary_demand(options, blocksummary.ask_for(name, _))
/// ```
pub fn with_summary_demand(
  options: Options,
  demand: fn(List(#(String, Int))) -> Nil,
) -> Options {
  Options(..options, summary_demand: Some(demand))
}

/// Supplies the report of the session's first accepted human prompt, which the
/// daemon turns into the catalogue's subtitle (`protocol-change/067`).
///
/// The hub calls it at most once, in its own process and without waiting, with
/// the prompt's first text block exactly as the person wrote it. What becomes
/// of the text is the callee's: the hub neither trims nor judges it.
///
/// ## Examples
///
/// ```gleam
/// // gateway.with_first_prompt(options, fn(text) { manager.seed_subtitle(registry, id, text) })
/// ```
pub fn with_first_prompt(
  options: Options,
  report: fn(String) -> Nil,
) -> Options {
  Options(..options, first_prompt: Some(report))
}

/// Supplies the daemon's door for reading and switching the session's model
/// profile (`protocol-change/082`).
///
/// ## Examples
///
/// ```gleam
/// // gateway.with_profile_desk(options, profile_switch.Desk(current: None, ..))
/// ```
pub fn with_profile_desk(
  options: Options,
  desk: profile_switch.Desk,
) -> Options {
  Options(..options, profile: Some(desk))
}

/// Supplies the authenticated session directory administration door.
///
/// ## Examples
///
/// ```gleam
/// // gateway.with_directories(options, admin)
/// ```
pub fn with_directories(options: Options, admin: directories.Admin) -> Options {
  Options(..options, directories: Some(admin))
}

/// Supplies the owner-only worktree reader, run outside the gateway actor.
///
/// ## Examples
///
/// ```gleam
/// // gateway.with_worktree_diff(options, capture)
/// ```
pub fn with_worktree_diff(
  options: Options,
  capture: fn() -> Result(JsonValue, String),
) -> Options {
  Options(..options, worktree_diff: Some(capture))
}

/// Supplies the read-only context inspector; no provider or hook runs here.
///
/// ## Examples
///
/// ```gleam
/// // gateway.with_context(options, read_context)
/// ```
pub fn with_context(
  options: Options,
  read_context: fn(String) -> Result(JsonValue, String),
) -> Options {
  Options(..options, context: Some(read_context))
}

/// Supplies the reader of remote children's transcript pages
/// (protocol-change/090). The hub calls it in an observation's task with the
/// child's name and the cursor a `child_history` command named.
///
/// ## Examples
///
/// ```gleam
/// // gateway.with_child_history(options, read_page)
/// ```
pub fn with_child_history(
  options: Options,
  read_page: fn(String, Int) -> Result(JsonValue, String),
) -> Options {
  Options(..options, child_history: Some(read_page))
}

/// Supplies the session-lived, tool-free side-query service.
///
/// ## Examples
///
/// ```gleam
/// // gateway.with_btw(options, name)
/// ```
pub fn with_btw(
  options: Options,
  name: address.Address(btw.Message),
) -> Options {
  Options(..options, btw: Some(name))
}

/// Supplies an explicit bounded live jobs query.
///
/// ## Examples
///
/// ```gleam
/// // gateway.with_live_jobs(options, read_jobs)
/// ```
pub fn with_live_jobs(
  options: Options,
  read_jobs: fn(String) -> Result(JsonValue, String),
) -> Options {
  Options(..options, live_jobs: Some(read_jobs))
}

/// Supplies the model catalogue the hub serves and switches by name.
///
/// ## Examples
///
/// ```gleam
/// // gateway.default_options("sess-01", runtime)
/// // |> gateway.with_catalog(catalogue)
/// ```
///
pub fn with_catalog(options: Options, catalog: catalog.Catalog) -> Options {
  Options(..options, catalog: Some(catalog))
}

/// Supplies the event bus the hub relays running tool output from. Pass
/// the very bus the effect wiring's `tool_output_observer` publishes on:
/// both sides key by the runtime's canonical session id, and a tail
/// published on another bus reaches no peer.
///
/// ## Examples
///
/// ```gleam
/// // gateway.default_options("sess-01", runtime) |> gateway.with_bus(bus)
/// ```
///
pub fn with_bus(options: Options, events_bus: bus.Bus) -> Options {
  Options(..options, bus: Some(events_bus))
}

/// Supplies the tool registry `set_config`'s `active_tools` validates
/// against. Pass the very registry the effect wiring was built with:
/// the durable active list is meaningless against any other one.
///
/// ## Examples
///
/// ```gleam
/// // gateway.default_options("sess-01", runtime)
/// // |> gateway.with_registry(the_registry_the_effect_wiring_holds)
/// ```
///
pub fn with_registry(options: Options, registry: Registry) -> Options {
  Options(..options, registry: Some(registry))
}

/// Supplies the host's code-mode discovery diagnostic for client display.
/// Registration itself still comes from the actual tool registry.
///
/// ## Examples
///
/// ```gleam
/// // gateway.with_code_mode_issue(options, Some("compiler unavailable"))
/// ```
pub fn with_code_mode_issue(
  options: Options,
  reason: Option(String),
) -> Options {
  Options(..options, code_mode_issue: reason)
}

/// Supplies the operator-facing scheduling door the `schedules` and
/// `schedule_cancel` commands answer from. Pass the admin built over
/// the very `scheduleseam.Wiring` the model's door uses: two doors onto
/// one store is the point, and two stores would let a listing disagree
/// with what actually fires.
///
/// ## Examples
///
/// ```gleam
/// // gateway.default_options("sess-01", runtime)
/// // |> gateway.with_schedules(scheduleadmin.admin(wiring))
/// ```
///
pub fn with_schedules(options: Options, admin: scheduleadmin.Admin) -> Options {
  Options(..options, schedules: Some(admin))
}

/// Supplies the operator's half of the proposal queue, which the
/// `proposals_get` and `proposal_decide` commands answer from. Pass the admin
/// built over the very `proposals.Wiring` the model's `propose` tool uses, so
/// a listing and the tool cannot disagree about what is queued
/// (protocol-change/086).
///
/// ## Examples
///
/// ```gleam
/// // gateway.default_options("sess-01", runtime)
/// // |> gateway.with_proposals(proposals.admin(wiring))
/// ```
///
pub fn with_proposals(options: Options, admin: proposals.Admin) -> Options {
  Options(..options, proposals: Some(admin))
}

/// Supplies the operator's read of the memory overview, which the
/// `memory_get` command answers from. Pass the admin built over the files
/// this host already reads for its runs, so the overview cannot describe a
/// file the runs do not (protocol-change/087).
///
/// ## Examples
///
/// ```gleam
/// // gateway.default_options("sess-01", runtime)
/// // |> gateway.with_memory_overview(memory_overview.admin(wiring))
/// ```
///
pub fn with_memory_overview(
  options: Options,
  admin: memory_overview.Admin,
) -> Options {
  Options(..options, memory_overview: Some(admin))
}

/// Supplies the effect plane's sweep of an aborted operation — in
/// `client/serve`, `broker.abort` applied to the one broker every
/// clearance goes through.
///
/// The runtime's own abort commits the cancel marker and stops the
/// strand's live effects, and that is every effect the *operation* is
/// waiting on. It is not every execution the operation started: a
/// background job runs under a sibling step of the same operation
/// (`{op_id, "job/" <> id}`) and is nobody's live effect, so nothing in
/// the runtime reaches it. The broker holds the other half of the
/// ledger, which is why an operator's abort has to pass through here as
/// well — it is what makes a job stop when the operator stops the
/// operation that started it (`docs/design-notes/background-jobs.md`,
/// decision 4).
///
/// ## Examples
///
/// ```gleam
/// // gateway.default_options("sess-01", runtime)
/// // |> gateway.with_effect_abort(broker.abort(the_broker, _))
/// ```
///
pub fn with_effect_abort(options: Options, sweep: fn(OpId) -> Nil) -> Options {
  Options(..options, effect_abort: Some(sweep))
}

/// Supplies the advisor actor's abort notice. A cast, never a call: the
/// `abort` command is not held open for the goal loop, and a notice lost
/// to a busy actor costs the loop nothing it cannot recover. It used to
/// cost a goal that stayed active until the operator's next prompt, which
/// is what the notice was for; the level read now consults the aborted
/// run's own durable terminal record, so a dropped notice costs at most
/// the delay to the next evaluation and the goal is held either way.
///
/// ## Examples
///
/// ```gleam
/// // gateway.with_goal_abort(options, notice)
/// ```
///
pub fn with_goal_abort(options: Options, notice: fn(OpId) -> Nil) -> Options {
  Options(..options, goal_abort: Some(notice))
}

/// Supplies the operator's goal commands over the advisor actor. The
/// session's one advisor owns the goal cell, so this seam is the whole
/// write path for `goal_set` and its siblings (protocol 044 §7).
///
/// ## Examples
///
/// ```gleam
/// // gateway.with_goal_control(options, goalcommand.seam(wiring))
/// ```
///
pub fn with_goal_control(options: Options, seam: goalcommand.Seam) -> Options {
  Options(..options, goal_control: Some(seam))
}

/// Supplies the host-owned evolution control door. Socket arguments never
/// supply the authority passed to this door.
///
/// ## Examples
///
/// ```gleam
/// // gateway.with_evolution(options, control)
/// ```
pub fn with_evolution(
  options: Options,
  seam: evolution_control.Seam,
) -> Options {
  Options(..options, evolution: Some(seam))
}

// Whether a connection has completed the `subscribe` handshake. It gates three
// separate things — broadcasts, the presence roster, and every command past
// `subscribe` itself — which is why it is a domain type rather than a flag: a
// `Bool` here made each of those read as a polarity to be remembered.
type Subscription {
  /// The handshake completed: durable broadcasts, presence and stream deltas
  /// reach this connection and it may issue every command its role allows.
  Subscribed

  /// Attached but not yet subscribed: it sees replies to its own requests and
  /// nothing else, and no command but `subscribe` is admitted.
  Unsubscribed
}

type Connection {
  Connection(
    /// Encoded frames leave through here; it runs on the hub process.
    sink: fn(String) -> Nil,
    /// Queues an acknowledgement behind prior pushes on the same transport.
    flush: fn(Subject(Nil)) -> Nil,
    /// The original socket whose exit cancels admitted observations.
    consumer: Option(process.Pid),
    /// Whether the `subscribe` handshake has completed.
    subscription: Subscription,
    /// How this connection was admitted, which is the module's trust boundary.
    authentication: Authentication,
    /// The authenticated principal as a durable message origin, refreshed by
    /// every revalidation so a renamed principal writes under its new name.
    origin: Option(message.Origin),
    /// At most one snapshot transfer, retained between the client's credits.
    transfer: Option(transfer.Transfer),
    /// Where the reply to the one in-flight request goes. Held only for the
    /// duration of that request: `request_frame` sets it, and clears it before
    /// returning, so nothing unsolicited can ever find a reply destination.
    response: Option(Subject(Result(String, String))),
    /// Stops this connection's exact session incarnation after the hub has
    /// judged its storage reader wedged. Supplied by the transport, because
    /// the hub must not wait on its own retirement.
    read_failed: fn() -> Nil,
  )
}

/// A preview is valid only while its original observer lease is live.
type LivePreview {
  LivePreview(source: Int, payload: JsonValue)
}

// A report channel stays selected until Weft has delivered its final word.
// Detaching suppresses delivery but never frees an occupied execution slot.
type PendingObservation {
  PendingObservation(
    request: Int,
    kind: ObservationKind,
    reports: Subject(weft.Pulled(JsonValue, String)),
    phase: ObservationPhase,
  )
}

// One transfer's capture while a weft run asks storage for it. The run owns the
// reply subject and the deadline, so a reply that arrives after the deadline
// goes to a process that has already exited and never reaches this mailbox.
// The entry stays selected until Weft has delivered its final word, so that
// word is never a stray message either.
type PendingCapture {
  PendingCapture(
    /// The attachment that asked, answered only if it is still attached.
    connection: Int,
    /// The wire request this capture answers.
    request: Int,
    /// What the transfer will carry once its cut arrives.
    window: transfer.Window,
    /// The asking request's reply capability. `request_frame` clears the
    /// connection's own copy as soon as it returns, so the capture keeps the
    /// one reply the socket is still waiting for.
    response: Subject(Result(String, String)),
    /// The monotonic instant the capture began, which opens the transfer's
    /// retention window at the same point a synchronous read would have.
    started: Int,
    reports: Subject(weft.Pulled(snapshot.Cut, snapshot.Error)),
    progress: CaptureProgress,
  )
}

type CaptureProgress {
  /// No outcome yet; a second transfer on this connection is refused.
  Awaiting

  /// The request was answered; only the run's final word is outstanding.
  Answered
}

// Worktree reads retain owner authority; context exposes session metadata. A
// remote child's transcript is a read any subscriber of the session may make,
// as a capture of a local strand is: the spawner's table on the other
// orchestrator is what decides whether it is answered at all.
type ObservationKind {
  WorktreeObservation
  ContextObservation
  HistoryObservation
}

/// Wraps an observation board into its corresponding protocol snapshot event.
fn observation_snapshot(kind: ObservationKind, board: JsonValue) {
  protocol.SnapshotEvent(case kind {
    WorktreeObservation -> protocol.WorktreeDiffSnapshot(board)
    ContextObservation -> protocol.ContextSnapshot(board)
    HistoryObservation -> protocol.ChildHistorySnapshot(board)
  })
}

/// Evaluates whether an observer connection is permitted to receive the requested observation.
fn observation_allowed(state: State, connection: Int, kind: ObservationKind) {
  case kind {
    WorktreeObservation -> worktree_owner(state, connection)
    ContextObservation | HistoryObservation ->
      case dict.get(state.connections, connection) {
        Ok(Connection(subscription: Subscribed, ..)) -> True
        _ -> False
      }
  }
}

type ObservationPhase {
  Capturing
  Reported
}

// Once shutdown starts, no later command or idle hint can start more work.
type Admission {
  Accepting
  Draining
}

// A poisoned reader is terminal in this actor. It cannot service another peer
// while the exact incarnation's original storage custody is still draining.
type Health {
  Reading
  ReaderPoisoned
}

type Delivery {
  Network
  HostOnly
}

// A branch scan proves membership, but a shared ancestor belongs to more
// than one branch. Parent and first-strand fallbacks are display hints only.
type EntryAttribution {
  BranchOwned(strand: String)
  Unverified(strand: String)
  Shared(strand: String)
}

// One materialized durable event: its storage seq plus the wire event.
// Only a usage row linked to an entry with known strand ownership may
// carry a cache observation. The legacy event can retain its display
// fallback without granting that guess authority over cache state.
type Emit {
  Emit(seq: Int, event: WireEvent, observation_strand: Option(String))
}

/// One strand's held messages together with the policy deciding how many
/// of them the next successor run receives.
///
/// The drain policy belongs to the items whose custody it changes. Removing
/// an empty queue also removes its batch intent, so a later run cannot
/// inherit it.
type HeldQueue {
  HeldQueue(
    /// Messages retain their admitted order and original author.
    items: List(Held),
    /// Explicit abort halts the existing queue; the next client submission
    /// joins it and releases the whole batch into one successor.
    drain: HeldDrain,
  )
}

/// How many held messages one successor run receives, and whether it may
/// receive any at all before a human has spoken again.
type HeldDrain {
  /// Ordinary settlement opens one successor per held prompt.
  OnlyHead

  /// A client submission released a halted queue: the successor receives
  /// every currently held message together, the release included.
  AllHeld

  /// Explicit abort. Nothing drains, however idle the strand becomes,
  /// until a client submits on it (`protocol-change/033`). Escape means
  /// "stop, and wait for me", and a queue that started a successor on its
  /// own would restart the work the operator just stopped.
  Halted
}

/// One `prompt` the hub is holding for a strand that was busy when it
/// arrived (`protocol-change/018`, ruling 3 of the live-delivery note).
///
/// **The queue is hub memory and is deliberately not durable.** A prompt
/// that survived a hub restart would need a pending-run operation in
/// `machine` — a new durable operation kind, with its own state space and
/// its own replay — bought for a convenience nothing else needs. The wire
/// says so rather than hiding it: the reply is `queued`, never
/// `admitted`, so a client is written against a queue that a restart
/// drops and clears its own local queued state when the socket closes.
type Held {
  Held(
    /// Server-minted identity, stable for exactly this held item.
    id: String,
    /// The client request ID is retained only for its original reply.
    request: Int,
    /// Stable authenticated identity captured at admission, never display origin.
    author: InputAuthor,
    /// Compare-and-replace revision, advanced in this actor with the text.
    revision: Int,
    /// Steers precede queued turns; arrival order is retained within each kind.
    order: InputOrder,
    /// The message exactly as it was built at submission, carrying the
    /// origin the submitting connection had *then*. Re-minting it at
    /// drain time would credit whoever happens to be attached when the
    /// strand goes idle, which is the wrong human.
    prompt: AgentMessage,
    /// The same message as the person typed it, before a skill expansion
    /// rewrote it. The subtitle is derived from this (protocol-change/067),
    /// so a `/skill` first prompt is not subtitled with the skill's body.
    typed: AgentMessage,
    /// Where a drain *failure* is reported. Not where the entry goes: a
    /// successful drain reaches every terminal, submitter included, as
    /// an ordinary notice. A submitter that has detached by then is an
    /// unknown connection and the report is dropped, which is why this
    /// needs no cleanup when a connection goes away.
    submitter: Int,
  )
}

// Reconnection preserves principal identity, while trusted fixtures have only
// their submitting connection to distinguish them from another in-VM caller.
type InputAuthor {
  PrincipalAuthor(id: String, kind: access.PrincipalKind)
  FixtureAuthor(connection: Int)
}

/// Human input priority belongs to the host queue, outside the operation
/// being cancelled, so stopping that operation cannot discard the next input.
type InputOrder {
  /// Run after all already submitted steers and queued turns.
  AfterTurn

  /// Interrupt the current operation and precede ordinary queued turns.
  SteerNext
}

// Each priority has its own bound. A full normal queue must still admit a
// steer, while a peer submitting repeated steers cannot grow memory forever.
const held_per_strand = 4

/// Starts the hub registered under `name`. The initial high-water is the
/// store's current tail, so a fresh gateway (or a restarted one) never
/// re-broadcasts history on its first hint — reconnecting clients pull
/// history explicitly with `catch_up`.
///
/// ## Examples
///
/// ```gleam
/// // gateway.start(gateway.default_options("sess-01", runtime), name)
/// ```
///
pub fn start(
  options: Options,
  name: address.Address(Message),
) -> actor.StartResult(Gateway) {
  start_with_delivery(options, name, Network)
}

/// Retains the historical unbounded materializer for internal host fixtures.
///
/// ## Examples
///
/// ```gleam
/// // gateway.start_host_fixture(options, name)
/// ```
@internal
pub fn start_host_fixture(
  options: Options,
  name: address.Address(Message),
) -> actor.StartResult(Gateway) {
  start_with_delivery(options, name, HostOnly)
}

/// Starts the gateway actor configured with the specified delivery mode.
fn start_with_delivery(
  options: Options,
  name: address.Address(Message),
  delivery: Delivery,
) {
  // Runtime effects own execution. The gateway's separate registry view only
  // validates membership and lists names. Initialization still receives the
  // public options, but its callback is discarded; retained state keeps names.
  let registered_tools =
    option.map(options.registry, fn(registry) {
      tool.names(registry)
      |> list.map(fn(name) { #(name, Nil) })
      |> dict.from_list
    })

  actor.new_with_initialiser(5000, fn(subject) {
    // The initialiser runs in the gateway's own process, so this label names
    // the gateway to the ownership inspector under its canonical session id.
    session_owner.label(options.runtime, owner.Gateway)

    // Evaluate control flow transition for start with delivery.
    let selector = case options.bus {
      Some(events_bus) -> {
        // Keyed by the session's *canonical* id, never by the
        // caller-supplied display name. The two key spaces are disjoint
        // by construction (`protocol-change/008`), so a hub keyed by
        // name would sit in a group no identified publisher ever
        // reaches — and the index is repository-wide, which is exactly
        // where a file-derived name collides with nothing to notice it.
        // `Options.session_id` stays the protocol's `session` field: a
        // display name, and only that.
        let key = bus.key(of: api.session_id(options.runtime))

        // Which topics depends on who else is telling this hub things.
        // The host fixture takes them all: it is the host whose hint
        // sources are not all its own writer. A network hub's commit
        // hints already arrive through `commit_forwarder`, so it joins
        // the `Outputs` feed alone — joining the hint topics too would
        // make the same pull happen twice per commit.
        case delivery {
          HostOnly -> bus.subscribe_all(events_bus, session: key)
          Network -> bus.subscribe(events_bus, session: key, topic: bus.Outputs)
        }

        // The proposal queue belongs to the domain, not to this session, so
        // its changes arrive on the domain's own key: a proposal filed or
        // decided in a sibling session reaches this hub's open pages too.
        case options.proposals {
          Some(admin) ->
            bus.subscribe(
              events_bus,
              session: admin.channel,
              topic: bus.Outputs,
            )
          None -> Nil
        }

        process.new_selector()
        |> process.select(subject)
        |> bus.select_published(BusHint)
      }
      None ->
        process.new_selector()
        |> process.select(subject)
    }

    let _reset_side_conversations =
      option.map(options.btw, fn(name) { address.send(name, btw.Reset) })

    let state =
      State(
        subject:,
        selector: process.select_monitors(selector, SocketDown),
        observations: dict.new(),
        captures: dict.new(),
        next_capture: 1,
        resolves: dict.new(),
        next_resolve: 1,
        spawner: options.spawner,
        remote: options.remote,
        worktree_diff: options.worktree_diff,
        live_jobs: options.live_jobs,
        context: options.context,
        child_history: options.child_history,
        btw: options.btw,
        summary_demand: options.summary_demand,
        first_prompt: options.first_prompt,
        profile: options.profile,
        reload: Current,
        delivery:,
        health: Reading,
        admission: Accepting,
        next_transfer: 1,
        preview_sources: dict.new(),
        next_preview_source: 1,
        preview: None,
        preview_revision: 0,
        session_id: options.session_id,
        runtime: options.runtime,
        recent_entries: options.recent_entries,
        connections: dict.new(),
        next_connection: 1,
        high_water: 0,
        live: dict.new(),
        held: dict.new(),
        next_held: 1,
        entry_strand: dict.new(),
        effect_abort: options.effect_abort,
        goal_control: options.goal_control,
        evolution: options.evolution,
        goal_abort: options.goal_abort,
        catalog: options.catalog,
        registered_tools:,
        skills: options.skills,
        code_mode_issue: options.code_mode_issue,
        extension_refusals: options.extension_refusals,
        schedules: options.schedules,
        proposals: options.proposals,
        memory_overview: options.memory_overview,
        directories: options.directories,
      )

    // Prime: advance past everything already in the store, and learn
    // the live operations so the next pull sees changes, not history.
    // Both deliveries need it now that a network hub pushes on a hint —
    // an unprimed one would answer its first commit with a notice for
    // every sequence the store already held. The prime emits nothing, so
    // it reads the entries' heads rather than decoding their payloads.
    let state = prime(state)
    actor.initialised(state)
    |> actor.selecting(process.select_monitors(selector, SocketDown))
    |> actor.returning(Gateway(name:))
    |> Ok
  })
  |> actor.addressed(name)
  |> actor.on_message(handle)
  |> actor.periodic(every: 1000, sending: MaintainTransfers)
  |> actor.start
}

/// Registers a trusted host/test sink, never an anonymous network connection.
/// Network listeners must use `attach_authenticated`. The sink
/// is called from the hub process with each encoded frame; it must not
/// block (send to the transport process, do not write sockets inline).
///
/// ## Examples
///
/// ```gleam
/// // gateway.attach(gateway, fn(frame) { process.send(out, frame) })
/// ```
///
@internal
pub fn attach(gateway: Gateway, sink: fn(String) -> Nil) -> Result(Int, Nil) {
  use subject <- result.try(address.lookup(gateway.name))
  Ok(process.call(subject, waiting: 5000, sending: Attach(sink, _)))
}

/// Attaches an authenticated socket to the original gateway incarnation.
///
/// The check capability resolves current membership at each admission. The
/// original socket monitor removes presence even when `on_close` cannot run.
/// Anonymous `attach` exists only for trusted host fixtures, never this path.
///
/// ## Examples
///
/// ```gleam
/// // gateway.attach_authenticated(gateway, binding, check, sink, close, socket_pid)
/// ```
pub fn attach_authenticated(
  gateway: Gateway,
  binding: Binding,
  check: fn() -> Result(#(access.Principal, access.Authority), String),
  sink: fn(String) -> Nil,
  close: fn() -> Nil,
  read_failed: fn() -> Nil,
  socket: process.Pid,
) -> Result(ConnectionHandle, String) {
  attach_authenticated_flushing(
    gateway,
    binding,
    check,
    sink,
    close,
    read_failed,
    fn(reply) { process.send(reply, Nil) },
    socket,
  )
}

/// Attaches a transport whose flush is ordered after this gateway's pushes.
///
/// The callback queues a marker without waiting. The drain caller owns the
/// acknowledgement subject, so the gateway can keep answering socket requests.
///
/// ## Examples
///
/// ```gleam
/// // The session socket sends Flush(reply) from this callback.
/// ```
@internal
pub fn attach_authenticated_flushing(
  gateway: Gateway,
  binding: Binding,
  check: fn() -> Result(#(access.Principal, access.Authority), String),
  sink: fn(String) -> Nil,
  close: fn() -> Nil,
  read_failed: fn() -> Nil,
  flush: fn(Subject(Nil)) -> Nil,
  socket: process.Pid,
) -> Result(ConnectionHandle, String) {
  use subject <- result.try(
    address.lookup(gateway.name) |> result.replace_error("gateway unavailable"),
  )
  call.try_call(subject, waiting: 5000, sending: AttachAuthenticated(
    binding,
    check,
    sink,
    close,
    read_failed,
    flush,
    socket,
    _,
  ))
  |> result.unwrap(Error("gateway unavailable"))
}

/// Returns the original gateway PID for the transport's lifetime monitor.
///
/// ## Examples
///
/// ```gleam
/// // process.monitor(gateway.connection_pid(connection))
/// ```
pub fn connection_pid(connection: ConnectionHandle) -> process.Pid {
  connection.pid
}

/// Sends an admitted socket frame only to its original gateway process.
///
/// ## Examples
///
/// ```gleam
/// // gateway.connection_text(connection, frame)
/// ```
pub fn connection_text(connection: ConnectionHandle, frame: String) -> Nil {
  process.send(connection.subject, FromClient(connection.id, frame))
}

/// Waits for one bounded response before the socket admits another full frame.
/// A timeout is an unknown command outcome, never permission to retry it.
///
/// ## Examples
///
/// ```gleam
/// // gateway.connection_request(connection, frame)
/// ```
pub fn connection_request(
  connection: ConnectionHandle,
  frame: String,
) -> Result(String, String) {
  call.try_call(connection.subject, waiting: 6000, sending: Request(
    connection.id,
    frame,
    _,
  ))
  |> result.map_error(fn(fault) {
    case fault {
      call.NoReply -> "gateway response timed out"
      call.CalleeGone -> "gateway process unavailable"
    }
  })
  |> result.flatten
}

/// Detaches from the original process; a replacement never sees the old ID.
///
/// ## Examples
///
/// ```gleam
/// // gateway.connection_detach(connection)
/// ```
pub fn connection_detach(connection: ConnectionHandle) -> Nil {
  process.send(connection.subject, Detach(connection.id))
}

/// How many connections are attached right now.
///
/// The honest answer to "is a human there?", which is what an escalation
/// seam needs before it holds a tool call open for a decision: a session
/// nobody is watching must record a refusal and settle it, not park on a
/// prompt that will never be answered. It is a question rather than a
/// flag so a client that disconnects mid-park is noticed at the next
/// poll.
///
/// A hub that is gone answers zero — a server without a gateway is by
/// definition not being watched — and so does a hub that does not answer
/// in a second, or that dies while being asked. That is a deliberate
/// degradation rather than a lost error: the only caller is an escalation
/// seam polling once a second from a *parked tool call's* effect process,
/// and `process.call` exits its caller on timeout rather than returning
/// one, so a hub busy behind a long pull would kill the very call it is
/// being asked about. "Nobody answered, so assume nobody is there"
/// un-parks the call and settles it in band, which is exactly what the
/// seam's doc promises happens when a client goes away.
///
/// ## Examples
///
/// ```gleam
/// // gateway.attached(gateway) == 0
/// ```
///
pub fn attached(gateway: Gateway) -> Int {
  let observed = {
    use subject <- result.try(address.lookup(gateway.name))
    use owner <- result.map(process.subject_owner(subject))
    let monitor = process.monitor(owner)
    let reply_to = process.new_subject()

    // The monitored PID is the incarnation this question belongs to. Sending
    // through the name would resolve it again and could crash or ask a
    // replacement which the monitor does not describe.
    process.send(subject, Attached(reply: reply_to))
    let answer =
      process.new_selector()
      |> process.select(reply_to)
      |> process.select_specific_monitor(monitor, fn(_down) { 0 })
      |> process.selector_receive(within: 1000)
    process.demonitor_process(monitor)
    result.unwrap(answer, 0)
  }
  result.unwrap(observed, 0)
}

/// Applies a spawner's operator's decision to a child's request in this delegate
/// session, and answers what became of it (protocol-change/089).
///
/// The hub judges the decision on its own turn, so it is serialized with the
/// session's other approvals and commits on the session's one writer. The caller
/// is the orchestrator port's task for the message, which may wait, and a hub
/// that does not answer within the bound leaves the decision outcome unknown.
///
/// ## Examples
///
/// ```gleam
/// // gateway.decide(gateway, parent, "policy-ab", remote_escalation.Deny, 3, decider)
/// ```
pub fn decide(
  gateway: Gateway,
  parent: remote_spawn.Parent,
  escalation_id: String,
  decision: remote_escalation.Decision,
  expected_seq: Int,
  decided_by: remote_escalation.Decider,
) -> Result(remote_escalation.Answer, DecisionFailure) {
  use subject <- result.try(
    address.lookup(gateway.name) |> result.replace_error(HubUnavailable),
  )
  use answer <- result.try(
    call.try_call_watching(subject, waiting: 4000, sending: fn(reply) {
      DecideForSpawner(
        parent:,
        escalation_id:,
        decision:,
        expected_seq:,
        decided_by:,
        reply:,
      )
    })
    |> result.map_error(fn(failure) {
      case failure {
        call.NoCallee -> HubUnavailable
        call.TimedOut | call.CalleeDown(_) ->
          DecisionUnknown("the delegate session's hub did not answer")
      }
    }),
  )
  answer |> result.map_error(DecisionUnknown)
}

/// Asks a relayed session's hub to judge and commit the decision of the
/// spawner's page about one of its requests (protocol-change/094). The answer is
/// the box's own, as `decide` answers a delegate session's. A hub that does not
/// answer in four seconds leaves the decision outcome unknown.
///
/// ## Examples
///
/// ```gleam
/// // gateway.decide_relayed(gateway, "laptop", Some(ceiling), "policy-ab", remote_escalation.Deny, 3, decider)
/// ```
pub fn decide_relayed(
  gateway: Gateway,
  spawner: String,
  ceiling: Option(approval_ceiling.Ceiling),
  escalation_id: String,
  decision: remote_escalation.Decision,
  expected_seq: Int,
  decided_by: remote_escalation.Decider,
) -> Result(remote_escalation.Answer, DecisionFailure) {
  use subject <- result.try(
    address.lookup(gateway.name) |> result.replace_error(HubUnavailable),
  )
  use answer <- result.try(
    call.try_call_watching(subject, waiting: 4000, sending: fn(reply) {
      DecideForRelayed(
        spawner:,
        ceiling:,
        escalation_id:,
        decision:,
        expected_seq:,
        decided_by:,
        reply:,
      )
    })
    |> result.map_error(fn(failure) {
      case failure {
        call.NoCallee -> HubUnavailable
        call.TimedOut | call.CalleeDown(_) ->
          DecisionUnknown("the session's hub did not answer")
      }
    }),
  )
  answer |> result.map_error(DecisionUnknown)
}

/// Asks a relayed session's hub to stop the main strand's run, and says whether
/// the hub took it (protocol-change/094). A session with no run is a stop that
/// succeeded; a failed strand read cannot establish that the run is idle.
///
/// ## Examples
///
/// ```gleam
/// // gateway.stop_relayed(gateway) == Ok(Nil)
/// ```
pub fn stop_relayed(gateway: Gateway) -> Result(Nil, Nil) {
  use subject <- result.try(address.lookup(gateway.name))
  use answer <- result.try(
    call.try_call(subject, waiting: 4000, sending: StopForRelayed)
    |> result.replace_error(Nil),
  )
  answer
}

/// Removes a connection; a no-op for unknown ids.
///
/// ## Examples
///
/// ```gleam
/// // gateway.detach(gateway, connection)
/// ```
///
pub fn detach(gateway: Gateway, connection: Int) -> Nil {
  send_if_alive(gateway.name, Detach(connection))
}

/// Feeds one inbound text frame from a connection into the hub.
///
/// ## Examples
///
/// ```gleam
/// // gateway.handle_text(gateway, connection, "{\"v\":1,...}")
/// ```
///
pub fn handle_text(gateway: Gateway, connection: Int, text: String) -> Nil {
  send_if_alive(gateway.name, FromClient(connection, text))
}

/// Fences new work and attempts to return held input within five seconds.
///
/// The gateway clears its queues and addresses each return only to its
/// submitter. Network transports acknowledge after the corresponding socket
/// writes; host fixtures acknowledge their direct sinks. A missing gateway,
/// a disconnected peer, or expiry leaves delivery unconfirmed. Callers with a
/// shared shutdown budget use `drain_held_within` instead.
///
/// ## Examples
///
/// ```gleam
/// // gateway.drain_held(instance.gateway)
/// ```
pub fn drain_held(gateway: Gateway) -> Nil {
  drain_held_within(gateway, 5000)
}

/// Fences mutations and gives queued socket writes one bounded flush window.
///
/// Acknowledgements confirm socket writes, not client receipt. Missing peers
/// and budget expiry remain unconfirmed; neither extends the caller's budget.
///
/// ## Examples
///
/// ```gleam
/// // gateway.drain_held_within(instance.gateway, remaining_ms)
/// ```
@internal
pub fn drain_held_within(gateway: Gateway, within_ms: Int) -> Nil {
  let deadline = bootstrap.monotonic_time_ms() + int.max(within_ms, 0)
  let flushed = process.new_subject()
  let count =
    address.lookup(gateway.name)
    |> result.try(fn(subject) {
      call.try_call(subject, waiting: int.max(within_ms, 0), sending: DrainHeld(
        flushed,
        _,
      ))
      |> result.replace_error(Nil)
    })
    |> result.unwrap(0)

  // All markers came from the same gateway as the pushes they follow. Receive
  // in the drain task, never in the gateway a socket may itself be waiting on.
  list.each(list.repeat(Nil, count), fn(_) {
    let _ack =
      process.receive(
        flushed,
        int.max(deadline - bootstrap.monotonic_time_ms(), 0),
      )
    Nil
  })
}

/// Starts a forwarder that turns the runtime writer's post-commit
/// publication into hub pull hints, registered under `as_name`.
///
/// Subscribe the writer through `writer.Routed(as_name)`, not the returned
/// incarnation-local subject. A restarted forwarder binds the same reference
/// address. A hint sent while it is absent is lost; it cannot interrupt a
/// commit, and the replacement recovers through durable pulls.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(_started) = gateway.commit_forwarder(to: name, as_name: forwarder)
/// // api.Options(..options, subscribers: [writer.Routed(forwarder)])
/// ```
///
pub fn commit_forwarder(
  to name: address.Address(Message),
  as_name as_name: address.Address(writer.Event),
) -> actor.StartResult(Subject(writer.Event)) {
  actor.new(Nil)
  |> actor.on_message(fn(_state, _event: writer.Event) {
    send_if_alive(name, CommitHint)
    actor.continue(Nil)
  })
  |> actor.addressed(as_name)
  |> actor.start
}

/// Tells the hub that the configuration file its session loads has changed and
/// the new text loads (`client/config_watch`). The hub reopens the session once
/// no strand is running, through its profile desk's restart; a hub with no desk
/// has no daemon to reopen it and ignores the notice. A hub that is not running
/// loses it, which costs nothing: its replacement's session read the file anew.
///
/// ## Examples
///
/// ```gleam
/// // gateway.configuration_changed(name)
/// ```
///
pub fn configuration_changed(name: address.Address(Message)) -> Nil {
  send_if_alive(name, ConfigChanged)
}

/// Wraps a provider surface so every streamed delta is teed to the hub
/// as an ephemeral `stream_delta` broadcast while the runtime's effect
/// process consumes the stream unchanged (same events, same terminal,
/// same timeout discipline). The shared relay forwards explicit
/// cancellation and consumer death to the inner stream.
///
/// ## Examples
///
/// ```gleam
/// // effects.Effects(..effects,
/// //   provider: gateway.tap_provider(effects.provider, to: name))
/// ```
///
pub fn tap_provider(
  surface: effects.ProviderSurface,
  to name: address.Address(Message),
) -> effects.ProviderSurface {
  tap_provider_with(surface, to: name, also: fn(_spec, _generation) {
    fn(_event) { Nil }
  })
}

/// `tap_provider` with a second observer riding the same relay.
///
/// `also` is asked once per request, with the request and the identity the
/// hub gives it — the `generation` a pushed `stream_delta` carries — and
/// the callback it returns sees every stream event after the hub's own
/// observer has. One relay serves both, so a second reader of the stream
/// costs a callback rather than a second guard process per request. The
/// block summarizer's live feed is the one production reader
/// (`client/blocksummary.observer`); passing it the hub's identity is what
/// lets a terminal match a live label to the stream it describes.
///
/// ## Examples
///
/// ```gleam
/// // gateway.tap_provider_with(surface, to: name,
/// //   also: blocksummary.observer(summaries, route.provider))
/// ```
///
pub fn tap_provider_with(
  surface: effects.ProviderSurface,
  to name: address.Address(Message),
  also also: fn(effects.RequestSpec, String) -> fn(stream.StreamEvent) -> Nil,
) -> effects.ProviderSurface {
  provider_relay.observing(surface, fn(spec) {
    let hub = observe_provider(name, spec)
    let other = also(spec, request_identity(spec))
    fn(event) {
      hub(event)
      other(event)
    }
  })
}

/// The production observer for a running tool call's output — the seam
/// `client/wiring.Config.observe_output` takes. Each tail is published on
/// the bus as `ToolOutput` under the session's canonical id, where the
/// hub's `Outputs` subscription turns it into a pushed `tool_output`
/// frame for every subscribed peer (`protocol-change/031`).
///
/// The session id is read once per run rather than once per chunk: it is
/// a register read, and a tool runs only after the runtime has minted it,
/// so in production the read succeeds and the per-chunk observer is one
/// `pg` lookup and a send. A session that somehow has no id yet is
/// observed by nobody, never published under a forged key.
///
/// ## Examples
///
/// ```gleam
/// // wiring.Config(
/// //   ..config,
/// //   observe_output: gateway.tool_output_observer(bus, opened),
/// // )
/// ```
///
pub fn tool_output_observer(
  events_bus: bus.Bus,
  opened: session.Session,
) -> fn(effects.ToolRun) -> fn(tool.OutputTail) -> Nil {
  fn(run: effects.ToolRun) {
    let message.ToolCall(id: call_id, ..) = run.call

    // Resolve the session identity for the opened session.
    case session.id(opened) {
      Ok(Some(id)) -> {
        let key = bus.key(of: id)

        // Output events need identity, not the arguments and grants carried
        // by the run. The observer crosses into the tool's collector process.
        let strand = run.strand
        let operation = run.operation
        let step_id = run.step_id
        let source_index = run.source_index
        fn(observed: tool.OutputTail) {
          bus.publish(
            events_bus,
            session: key,
            event: bus.ToolOutput(
              strand:,
              op: operation,
              step: step_id,
              source_index:,
              call_id:,
              stream: case observed.stream {
                framing.Stdout -> bus.Stdout
                framing.Stderr -> bus.Stderr
              },
              tail: observed.tail,
              total_bytes: observed.total_bytes,
            ),
          )
        }
      }
      Ok(None) | Error(_) -> tool.ignore_output()
    }
  }
}

/// Constructing the callback from the durable operation id in one place keeps
/// the immediate facade and the prepared production path observationally
/// identical.
fn observe_provider(
  name: address.Address(Message),
  spec: effects.RequestSpec,
) -> fn(stream.StreamEvent) -> Nil {
  // Parse the tool specification parameters.
  let operation = case spec {
    effects.GenerationRequest(operation:, ..) -> operation
    effects.PollRequest(operation:, ..) -> operation
    effects.SummaryRequest(operation:, ..) -> operation
  }

  let generation = request_identity(spec)
  fn(event) {
    case event {
      stream.Delta(delta:) ->
        send_if_alive(name, ProviderDelta(operation:, generation:, delta:))
      stream.Settled(..) | stream.Failed(..) ->
        send_if_alive(name, ProviderEnded(operation:, generation:))
    }
  }
}

/// Step and attempt belong to the durable request, so every observer derives
/// the same identity without minting a second counter or consulting live state.
fn request_identity(spec: effects.RequestSpec) -> String {
  // Parse the tool specification parameters.
  let parts = case spec {
    effects.GenerationRequest(step_id:, attempt:, response_entry:, ..) -> [
      json.String("generation"),
      json.String(step_id),
      json.Int(attempt),
      json.String(ids.entry_id_to_string(response_entry)),
    ]
    effects.PollRequest(step_id:, poll:, response_entry:, ..) -> [
      json.String("poll"),
      json.String(step_id),
      json.Int(poll),
      json.String(ids.entry_id_to_string(response_entry)),
    ]
    effects.SummaryRequest(task_id:, attempt:, request_index:, ..) -> [
      json.String("summary"),
      json.String(task_id),
      json.Int(attempt),
      json.Int(request_index),
    ]
  }

  json.to_string(json.Array(parts))
}

/// Adds bounded, explicitly discontinuous previews to a network gateway.
///
/// Each existing relay observer resolves one original hub and acquires one of
/// sixteen source leases. Refusal or timeout disables that source permanently;
/// it never retries against a replacement actor. Authoritative deltas still
/// reach the runtime consumer even when optional observations are omitted.
///
/// ## Examples
///
/// ```gleam
/// // gateway.tap_preview_provider(surface, to: gateway_name)
/// ```
@internal
pub fn tap_preview_provider(surface: effects.ProviderSurface, to name) {
  provider_relay.previewing(surface, fn(spec) {
    // Parse the tool specification parameters.
    let operation = case spec {
      effects.GenerationRequest(operation:, ..)
      | effects.PollRequest(operation:, ..)
      | effects.SummaryRequest(operation:, ..) -> ids.op_id_to_string(operation)
    }

    let lease = {
      use subject <- result.try(
        address.lookup(name) |> result.replace_error("hub absent"),
      )
      let expires = bootstrap.monotonic_time_ms() + 200
      use source <- result.try(
        call.try_call(subject, waiting: 200, sending: LeasePreview(
          process.self(),
          expires,
          _,
        ))
        |> result.replace_error("preview admission timed out")
        |> result.flatten,
      )
      Ok(#(subject, source))
    }
    preview_observer(lease, operation, request_identity(spec))
  })
}

/// Constructs a provider relay observation callback for live tool preview streaming.
fn preview_observer(
  lease,
  operation: String,
  generation: String,
) -> provider_relay.ObservationCallback {
  provider_relay.ObservationCallback(fn(event) {
    // Deliver only while the preview lease is active, and distinguish event kinds for the sink.
    case lease, event {
      Ok(#(subject, source)), stream.Delta(delta) -> {
        // Convert the provider delta variant to the preview protocol label and text.
        let #(kind, text) = case delta {
          stream.TextDelta(_, text) -> #("text", text)
          stream.ThinkingDelta(_, text) -> #("thinking", text)
          stream.ToolCallDelta(_, _, _, text) -> #("tool_call", text)
        }

        let sent =
          call.try_call(subject, waiting: 200, sending: Preview(
            source,
            operation,
            generation,
            kind,
            preview_text(text),
            _,
          ))
          |> result.replace_error("preview delivery timed out")
          |> result.flatten

        // Verify that the preview frame was admitted by the delivery channel.
        case sent {
          Ok(Nil) -> preview_observer(lease, operation, generation)
          Error(_) -> ignored_preview(lease)
        }
      }
      _, stream.Settled(..) | _, stream.Failed(..) -> {
        release_preview(lease)
        ignored_preview(Error("stream ended"))
      }
      Error(_), stream.Delta(_) -> ignored_preview(lease)
    }
  })
}

/// A timed-out payload still occupies its original source lease until terminal
/// release or original observer DOWN. No later delta can enqueue another one.
fn ignored_preview(lease) -> provider_relay.ObservationCallback {
  provider_relay.ObservationCallback(fn(event) {
    // Evaluate control flow transition for ignored preview.
    case event {
      stream.Delta(_) -> ignored_preview(lease)
      stream.Settled(..) | stream.Failed(..) -> {
        release_preview(lease)
        ignored_preview(Error("stream ended"))
      }
    }
  })
}

/// Releases the current live preview stream lease.
fn release_preview(lease) {
  // Evaluate active preview lease state and event status.
  case lease {
    Error(_) -> Nil
    Ok(#(subject, source)) -> {
      let _ =
        call.try_call(subject, waiting: 200, sending: ReleasePreview(source, _))
      Nil
    }
  }
}

// Reconstructing only the bounded prefix makes a small owned string, not a
// sub-binary retaining an entire provider chunk. The wire labels every sample
// discontinuous, so neither clipping nor skipped observations imply adjacency.
fn preview_text(text: String) -> String {
  let bytes = bit_array.from_string(text)
  preview_prefix(bytes, int.min(bit_array.byte_size(bytes), 24_576), 4)
}

/// Formats a bounded prefix preview string for streamed tool response data.
fn preview_prefix(bytes: BitArray, size: Int, attempts: Int) -> String {
  // Check whether preview text truncation attempts have reached the bound.
  case attempts {
    0 -> ""
    _ -> {
      let prefix =
        bit_array.slice(bytes, 0, size) |> result.try(bit_array.to_string)

      // Check whether preview text truncation attempts have reached the bound.
      case prefix {
        Ok(text) ->
          text |> string.to_utf_codepoints |> string.from_utf_codepoints
        Error(_) -> preview_prefix(bytes, int.max(0, size - 1), attempts - 1)
      }
    }
  }
}

// Resolve the hub name once, then send the tagged envelope straight to that
// PID. A second name lookup would leave an unregistration race which turns a
// lost stream hint into an observer crash and provider cancellation.
fn send_if_alive(name: address.Address(Message), message: Message) -> Nil {
  let _sent = address.send(name, message)
  Nil
}

// --- the hub loop ----------------------------------------------------------

/// Returns the next actor continuation step preserving current gateway state.
fn continue(state: State) -> actor.Next(State, Message) {
  let selector =
    dict.fold(
      state.observations,
      state.selector,
      fn(selector, connection, pending) {
        process.select_map(selector, pending.reports, fn(pulled) {
          ObservationReported(connection, pulled)
        })
      },
    )

  // Each capture's report channel is selected from admission until its final
  // word, the same lifetime an observation's is, so Weft's last message finds
  // a receiver and is not logged as an unexpected one.
  let selector =
    dict.fold(state.captures, selector, fn(selector, capture, pending) {
      process.select_map(selector, pending.reports, fn(pulled) {
        CaptureReported(capture, pulled)
      })
    })
  let selector =
    dict.fold(state.resolves, selector, fn(selector, resolve, pending) {
      process.select_map(selector, pending.reports, fn(pulled) {
        ResolveReported(resolve, pulled)
      })
    })
  actor.continue(state) |> actor.with_selector(selector)
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  continue(dispatch_message(state, message))
}

/// Routes incoming gateway messages to their specific protocol or lifecycle handlers.
fn dispatch_message(state: State, message: Message) -> State {
  case message {
    ObservationReported(connection:, pulled:) ->
      observation_reported(state, connection, pulled)
    CaptureReported(capture:, pulled:) ->
      capture_reported(state, capture, pulled)
    ResolveReported(resolve:, pulled:) ->
      resolve_reported(state, resolve, pulled)
    DecideForSpawner(
      parent:,
      escalation_id:,
      decision:,
      expected_seq:,
      decided_by:,
      reply:,
    ) -> {
      process.send(
        reply,
        decide_for_spawner(
          state,
          parent,
          escalation_id,
          decision,
          expected_seq,
          decided_by,
        ),
      )
      state
    }
    DecideForRelayed(
      spawner:,
      ceiling:,
      escalation_id:,
      decision:,
      expected_seq:,
      decided_by:,
      reply:,
    ) -> {
      let #(now, _clock) = clock.read(state.runtime.effects.clock)
      process.send(
        reply,
        remote_decision.admit_relayed(
          state.runtime,
          spawner,
          ceiling,
          escalation_id,
          decision,
          expected_seq,
          decided_by,
          now,
        ),
      )
      state
    }
    StopForRelayed(reply:) -> {
      let #(state, answer) = stop_for_relayed(state)
      process.send(reply, answer)
      state
    }
    LeasePreview(pid, expires, reply) ->
      lease_preview(state, pid, expires, reply)
    Preview(source, operation, generation, kind, text, reply) ->
      record_preview(state, source, operation, generation, kind, text, reply)
    ReleasePreview(source, reply) -> {
      let state = forget_preview(state, source)
      process.send(reply, Nil)
      state
    }
    Request(connection, text, reply) ->
      request_frame(state, connection, text, reply)

    // Idle maintenance owns retention only. Authority is checked at command
    // admission and delivery, where failure must refuse the operation; asking
    // here would let registry latency close an attachment doing no work.
    MaintainTransfers -> expire_transfers(state)
    Attach(sink:, reply:) -> {
      let id = state.next_connection
      process.send(reply, id)
      State(
        ..state,
        connections: dict.insert(
          state.connections,
          id,
          Connection(
            sink:,
            flush: fn(reply) { process.send(reply, Nil) },
            consumer: None,
            subscription: Unsubscribed,
            authentication: HostFixture,
            origin: None,
            transfer: None,
            response: None,
            read_failed: fn() { Nil },
          ),
        ),
        next_connection: id + 1,
      )
    }
    AttachAuthenticated(
      binding,
      check,
      sink,
      close,
      read_failed,
      flush,
      socket,
      reply,
    ) -> {
      // Evaluate control flow transition for dispatch message.
      let admitted = case
        binding.session_id
        == ids.session_id_to_string(api.session_id(state.runtime))
        && state.health == Reading
      {
        True -> check_binding(binding, check)
        False -> Error("attachment names a different session")
      }

      // Evaluate control flow transition for dispatch message.
      case admitted {
        Error(reason) -> {
          process.send(reply, Error(reason))
          state
        }
        Ok(principal) -> {
          let id = state.next_connection
          let link =
            Connection(
              sink:,
              flush:,
              consumer: Some(socket),
              subscription: Unsubscribed,
              authentication: Authenticated(
                binding,
                check,
                close,
                process.monitor(socket),
              ),
              origin: Some(message.Origin(principal.id, principal.display_name)),
              transfer: None,
              response: None,
              read_failed:,
            )
          let state =
            State(
              ..state,
              connections: dict.insert(state.connections, id, link),
              next_connection: id + 1,
            )
          process.send(
            reply,
            Ok(ConnectionHandle(state.subject, id, process.self())),
          )
          state
        }
      }
    }
    SocketDown(down) -> remove_socket(state, down)
    Attached(reply:) -> {
      process.send(reply, dict.size(state.connections))
      state
    }
    Detach(connection:) -> remove_connection(state, connection)
    FromClient(connection:, text:) ->
      case state.delivery {
        HostOnly -> dispatch(revalidate(state, connection), connection, text)
        Network -> remove_connection(state, connection)
      }
    CommitHint -> pull_and_broadcast(revalidate_all(state))

    // The pull that follows decides: an idle session reopens now, and a busy
    // one when the pull that sees its last run end comes round.
    ConfigChanged ->
      pull_and_broadcast(
        State(..state, reload: case state.reload {
          Current -> Owed
          owed -> owed
        }),
      )

    // A running command's tail is display state and not a hint: nothing
    // in the store moved, so there is nothing to pull, and the frame
    // leaves on the path a provider delta takes (`protocol-change/031`).
    BusHint(published: bus.Published(
      event: bus.ToolOutput(
        strand:,
        op:,
        step:,
        source_index:,
        call_id:,
        stream:,
        tail:,
        total_bytes:,
      ),
      ..,
    )) -> {
      broadcast_tool_output(
        state,
        strand,
        op,
        step,
        source_index,
        call_id,
        stream,
        tail,
        total_bytes,
      )
      state
    }

    // A summarizer label is display text on the same feed, and like a tail
    // it moves nothing a pull could find: a settled label's cell is not in
    // any capture plan, and a live one is stored nowhere (protocol 050).
    BusHint(published: bus.Published(
      event: bus.BlockSummary(subject:, text:),
      ..,
    )) -> {
      push_to_subscribed(
        state,
        protocol.BlockSummaryEvent(subject: summary_subject(subject), text:),
      )
      state
    }

    // Goal reads are auxiliary: a capture cannot refresh this reserved cell.
    // The bus carries no board to trust or project. Each subscribed peer gets
    // a data-free push through deliver, which rechecks its binding at emission.
    BusHint(published: bus.Published(event: bus.GoalChanged, ..)) -> {
      push_to_subscribed(state, protocol.GoalChanged)
      state
    }

    // The proposal queue moved: a model queued a suggestion or a person
    // decided one. The push carries nothing, and each subscribed owner reads
    // the queue again through the same bounded command.
    BusHint(published: bus.Published(event: bus.ProposalsChanged, ..)) -> {
      push_to_subscribed(state, protocol.ProposalsChanged)
      state
    }

    // The evolution catalogue, a selection or the transition queue moved. The
    // push carries nothing, and each subscribed peer reads the board again
    // through the same bounded command. The publisher sends it only after the
    // commit it announces is durable (protocol-change/099).
    BusHint(published: bus.Published(event: bus.EvolutionChanged, ..)) -> {
      push_to_subscribed(state, protocol.EvolutionChanged)
      state
    }

    // A remote child's stub changed. The stubs are read again in a weft run
    // and pushed whole to every subscribed peer, so the hub's turn never
    // waits on the store, a lost hint costs a stale strip until the next
    // change, and no pull runs: a stub is a reserved fact, which no emit
    // carries.
    BusHint(published: bus.Published(event: bus.RemoteChildrenChanged, ..)) -> {
      broadcast_remote_children(state)
      state
    }
    BusHint(published: _) -> pull_and_broadcast(revalidate_all(state))

    // No `revalidate_all` ahead of a delta: `deliver` re-checks each peer
    // as the frame leaves, and a second check on the same evidence in the
    // same turn would only double the registry calls per token per peer.
    ProviderDelta(operation:, generation:, delta:) -> {
      broadcast_delta(state, operation, generation, Some(delta))
      state
    }
    ProviderEnded(operation:, generation:) -> {
      broadcast_delta(state, operation, generation, None)
      state
    }

    // The ack follows the walk rather than preceding it, so a caller whose
    // `process.call` returned has observed every return already handed to its
    // sink. Nothing else depends on the order: a caller that stopped waiting
    // leaves the queues empty all the same, and the returns the hub did emit
    // are correct custody returns whether or not anyone counted them.
    DrainHeld(flushed:, reply:) -> {
      let state = drain_held_queues(State(..state, admission: Draining))

      // Only this actor sends pushes, so every flush marker follows all of the
      // custody returns on its socket. Waiting belongs to the caller's task.
      dict.each(state.connections, fn(_, connection) {
        connection.flush(flushed)
      })
      process.send(reply, dict.size(state.connections))
      state
    }
  }
}

// --- materializing the durable stream --------------------------------------

/// A network request owns exactly one reply destination, and holds it only for
/// the turn that answers it. What the socket also receives, since
/// `protocol-change/018`, are frames that answer no request: a `committed`
/// notice, a stream delta, the roster, a fault. Those never find this
/// destination — `response` is `Some` only between the two assignments below —
/// so the credit a request buys is still exactly one bounded reply. What they
/// carry is a *notice*, never a durable payload: the record still travels the
/// credited snapshot path, which is where the size bound and the retention
/// window are enforced.
fn request_frame(
  state: State,
  connection: Int,
  text: String,
  response: Subject(Result(String, String)),
) -> State {
  let state = expire_transfers(revalidate(state, connection))
  with_response(state, connection, response, fn(state) {
    network_dispatch(state, connection, text)
  })
}

/// Runs `answer` with the connection's one reply capability installed, then
/// takes it back. Both the request that was just admitted and a capture that
/// finishes later answer through here, so a reply can leave only while a
/// request's capability is held and no push can ever find it. An attachment
/// that is gone, was never authenticated, or belongs to a poisoned hub is told
/// it is closed instead, because the socket is still waiting for one reply.
fn with_response(
  state: State,
  connection: Int,
  response: Subject(Result(String, String)),
  answer: fn(State) -> State,
) -> State {
  // Evaluate control flow transition for with response.
  case state.health, dict.get(state.connections, connection) {
    Reading, Ok(Connection(authentication: Authenticated(..), ..) as link) -> {
      let state =
        put_connection(
          state,
          connection,
          Connection(..link, response: Some(response)),
        )
      let state = answer(state)

      // Evaluate control flow transition for with response.
      case dict.get(state.connections, connection) {
        Ok(link) ->
          put_connection(state, connection, Connection(..link, response: None))
        Error(Nil) -> state
      }
    }
    _, _ -> {
      process.send(response, Error("attachment is closed"))
      state
    }
  }
}

fn put_connection(state: State, id: Int, link: Connection) -> State {
  State(..state, connections: dict.insert(state.connections, id, link))
}

/// Cleans up expired background snapshot transfer sessions.
fn expire_transfers(state: State) -> State {
  let now = bootstrap.monotonic_time_ms()
  list.fold(dict.to_list(state.connections), state, fn(state, pair) {
    let #(id, link) = pair

    // Evaluate control flow transition for expire transfers.
    case link.transfer {
      Some(current) ->
        case transfer.expired(current, now) {
          True -> put_connection(state, id, Connection(..link, transfer: None))
          False -> state
        }
      None -> state
    }
  })
}

/// Decodes incoming wire frame text and dispatches network commands.
fn network_dispatch(state: State, connection: Int, text: String) -> State {
  case protocol.decode_command(text) {
    // A body the decoder refused is a command the client sent and the
    // server understood well enough to say what is wrong with it, so the
    // refusal carries the decoder's own sentence and the request's own id.
    // Answering "invalid v2 command" against id zero threw both away, and
    // the sentences it threw away are the ones written for an operator to
    // read: the objective's length with both counts, the budget's
    // positivity, the fields an `approve` must echo.
    Error(protocol.BadBody(id:, reason:, ..)) -> {
      reply_error(state, connection, id, protocol.code_bad_request, reason)
      state
    }

    // A frame this server cannot even place — unparseable, or with no id,
    // no command name, not an object. There is nothing to be specific about
    // and nothing to answer it against.
    Error(protocol.BadEnvelope(..)) | Error(protocol.MalformedFrame(..)) -> {
      reply_error(
        state,
        connection,
        0,
        protocol.code_bad_request,
        "invalid v2 command",
      )
      state
    }

    Ok(protocol.CommandEnvelope(id, command)) ->
      network_command(state, connection, id, command)
  }
}

/// Dispatches validated network protocol commands according to client authority.
fn network_command(
  state: State,
  connection: Int,
  id: Int,
  command: Command,
) -> State {
  case command {
    protocol.Subscribe(session_id, _) -> {
      let canonical = ids.session_id_to_string(api.session_id(state.runtime))

      // Evaluate control flow transition for network command.
      case session_id == canonical {
        // A join is announced to every subscribed peer, the newcomer
        // included, and each copy leaves through `deliver`'s per-peer
        // authority check (`protocol-change/054`). The newcomer's own copy
        // is also what moves its lane from polling to pushed at once on a
        // quiet session. The roster and the reply to this `subscribe` take
        // different paths out, so either may reach the socket first; a
        // pushed frame is order-free (`protocol-change/018`).
        True -> {
          let before = subscription_of(state, connection)
          let state = mark_subscribed(state, connection)
          announce_join(state, before)
          push_remote_children(state, connection)
          begin_transfer(state, connection, id, transfer.Recent)
        }
        False -> {
          reply_error(
            state,
            connection,
            id,
            "wrong_session",
            "attachment identity cannot change",
          )
          state
        }
      }
    }
    protocol.SnapshotNext(snapshot_id, index) ->
      advance_transfer(state, connection, id, snapshot_id, index)
    protocol.CatchUp(from_seq) ->
      begin_transfer(state, connection, id, transfer.Reconcile(from_seq))
    protocol.History(after, before) ->
      begin_transfer(state, connection, id, transfer.History(after, before))
    protocol.HistoryLineage(from) ->
      case ids.parse_entry_id(from) {
        Ok(entry) ->
          begin_transfer(state, connection, id, transfer.Lineage(entry))
        Error(_) -> {
          reply_error(
            state,
            connection,
            id,
            protocol.code_bad_request,
            "lineage must start at an entry identity",
          )
          state
        }
      }
    protocol.EscalationsGet(ids) ->
      begin_transfer(state, connection, id, transfer.Escalations(ids))
    protocol.EscalationsDecided ->
      begin_transfer(state, connection, id, transfer.Decided)

    // Everything that is not a bounded transfer goes to the shared dispatch,
    // which is where the observer guard and the subscribe gate live. The
    // variants are written out rather than swept up by a catch-all: a new
    // transfer-shaped command added above would otherwise be routed down the
    // non-transfer path silently, and the compiler is the only reader that
    // will reliably ask the question at the next protocol change.
    protocol.Prompt(..)
    | protocol.PromptContent(..)
    | protocol.Steer(..)
    | protocol.FollowUp(..)
    | protocol.RemoveQueuedInput(..)
    | protocol.EditQueuedInput(..)
    | protocol.Abort(..)
    | protocol.Approve(..)
    | protocol.ApproveForSession(..)
    | protocol.Deny(..)
    | protocol.Fork(..)
    | protocol.Navigate(..)
    | protocol.Compact(..)
    | protocol.CreateStrand(..)
    | protocol.ListModels
    | protocol.ListSkills(..)
    | protocol.WorktreeDiffGet
    | protocol.ContextGet(..)
    | protocol.ChildHistoryGet(..)
    | protocol.Btw(..)
    | protocol.LiveJobsGet(..)
    | protocol.AdvisorPendingGet
    | protocol.BlockSummariesGet(..)
    | protocol.GoalSet(..)
    | protocol.GoalCheck(..)
    | protocol.GoalGet
    | protocol.GoalClear
    | protocol.GoalPause
    | protocol.GoalResume
    | protocol.NotesGet(..)
    | protocol.QueuedInputGet(..)
    | protocol.SetConfig(..)
    | protocol.Evolution(..)
    | protocol.ListSchedules
    | protocol.CancelSchedule(..)
    | protocol.PermissionsGet
    | protocol.PermissionForget(..)
    | protocol.ProposalsGet
    | protocol.ProposalDecide(..)
    | protocol.MemoryGet
    | protocol.ProfileGet
    | protocol.ProfileSet(..)
    | protocol.UnknownCommand(..) -> run_command(state, connection, id, command)
  }
}

/// Computes a bounded snapshot capture plan for recent state history.
fn snapshot_plan(recent: Int) -> snapshot.Plan {
  snapshot.Plan(
    [
      snapshot.Selection(register.StrandConfig, "", snapshot.All),
      snapshot.Selection(register.StrandLeaf, "", snapshot.All),
      snapshot.Selection(register.StrandState, "", snapshot.All),
      snapshot.Selection(register.StrandLastResult, "", snapshot.All),
      snapshot.Selection(
        register.FactCustom,
        api.client_fact_prefix,
        snapshot.All,
      ),
      snapshot.Selection(
        register.FactCustom,
        runtime_escalation.key_prefix,
        snapshot.StringFieldEquals("status", "pending"),
      ),
      snapshot.Selection(
        register.FactCustom,
        api.remote_escalation_fact_prefix,
        snapshot.StringFieldEquals("status", "pending"),
      ),
    ],
    [
      snapshot.FromField(
        register.StrandState,
        "currentOperationId",
        register.OpState,
      ),
      snapshot.FromField(
        register.StrandState,
        "currentOperationId",
        register.OpMeta,
      ),
      // Terminal operation identity selects only its own optional stop fact.
      // A full child-run scan would grow with every resumed run in the session.
      snapshot.OptionalPrefixedField(
        register.StrandLastResult,
        "operationId",
        register.FactCustom,
        "child-run/",
      ),
    ],
    recent,
  )
}

/// Initiates an asynchronous snapshot transfer stream for an authorized client.
fn begin_transfer(
  state: State,
  connection: Int,
  id: Int,
  window: transfer.Window,
) -> State {
  use link <- or_reply(
    result.replace_error(dict.get(state.connections, connection), #(
      "closed",
      "attachment is closed",
    )),
    state,
    connection,
    id,
  )
  use <- bool.lazy_guard(
    link.transfer != None
      || link.subscription == Unsubscribed
      || capturing(state, connection),
    fn() {
      reply_error(
        state,
        connection,
        id,
        "stale_snapshot",
        "finish the current transfer or subscribe first",
      )
      state
    },
  )

  // Dispatch snapshot transfer according to the requested window shape.
  let recent = case window {
    transfer.Recent -> int.min(100, state.recent_entries)
    _ -> 0
  }

  let now = bootstrap.monotonic_time_ms()

  // Dispatch snapshot transfer according to the requested window shape.
  let plan = case window {
    transfer.Escalations(ids) ->
      // An id holding a slash may name a child's request on another
      // orchestrator, filed under `remote-escalation/`, so the lookup reads
      // both registers the id can mean and the client's validator accepts
      // either (`snapshot_view.lookup_keys`). Eight slash ids make sixteen
      // exact keys, which is `storage/snapshot.validate`'s whole selection
      // cap, so a ninth id or a third key per id would be an InvalidRequest.
      snapshot.Plan(
        list.flat_map(ids, snapshot_view.lookup_keys)
          |> list.map(snapshot.ExactKey(register.FactCustom, _)),
        [],
        0,
      )
    transfer.Decided ->
      snapshot.Plan(
        list.map(["approved", "rejected", "consumed"], fn(status) {
          snapshot.Selection(
            register.FactCustom,
            runtime_escalation.key_prefix,
            snapshot.StringFieldEquals("status", status),
          )
        }),
        [],
        0,
      )
    transfer.Lineage(_) -> snapshot.Plan([], [], 0)
    _ -> snapshot_plan(recent)
  }

  // The capture is the server's own question, funded with the reader's whole
  // budget, but this mailbox never waits for it. A weft run owns the reply
  // subject and the deadline, and hands the cut back as `CaptureReported`, so
  // a storage actor that is slow keeps this hub serving every other
  // attachment, and an answer that comes after the deadline is delivered to a
  // process that has already exited. The request's reply capability moves into
  // the pending entry, because `request_frame` clears the connection's copy
  // before this answer exists.
  use response <- or_reply(
    option.to_result(link.response, #("closed", "attachment is closed")),
    state,
    connection,
    id,
  )
  let capture = state.runtime.session.snapshot_reader.capture
  let reports = process.new_subject()
  let run =
    weft.new([fn() { capture(plan, capture_wait_ms) }])
    |> weft.deadline(capture_deadline_ms)

  // Evaluate control flow transition for begin transfer.
  let run = case link.consumer {
    Some(socket) -> weft.cancel_when_exits(run, socket)
    None -> run
  }

  let _relay = weft.start_relayed(run, to: reports)
  let pending =
    PendingCapture(
      connection:,
      request: id,
      window:,
      response:,
      started: now,
      reports:,
      progress: Awaiting,
    )
  State(
    ..state,
    captures: dict.insert(state.captures, state.next_capture, pending),
    next_capture: state.next_capture + 1,
  )
}

// How long the reader may take to answer a capture, which is the most a
// storage exchange may wait. The run's deadline is only the backstop for a
// reader that ignores its own budget, and both sit inside the six seconds the
// socket waits for its one reply.
const capture_wait_ms = 5000

const capture_deadline_ms = 5500

fn capturing(state: State, connection: Int) -> Bool {
  list.any(dict.values(state.captures), fn(pending) {
    pending.connection == connection && pending.progress == Awaiting
  })
}

/// A capture's report is one of three things: the run's one outcome, its final
/// word after that, or its final word with no outcome before it. Only the
/// first, or the third, answers the socket, and the entry is dropped only at a
/// final word so that word still has a receiver.
fn capture_reported(
  state: State,
  capture: Int,
  pulled: weft.Pulled(snapshot.Cut, snapshot.Error),
) -> State {
  case dict.get(state.captures, capture) {
    Error(Nil) -> state
    Ok(pending) ->
      case pulled {
        weft.NotYet -> state
        weft.PulledOutcome(outcome:) -> {
          let state =
            State(
              ..state,
              captures: dict.insert(
                state.captures,
                capture,
                PendingCapture(..pending, progress: Answered),
              ),
            )
          answer_capture(state, pending, capture_result(outcome))
        }
        weft.AllDelivered | weft.RunLost(..) -> {
          // Evaluate control flow transition for capture reported.
          let state = case pending.progress {
            Answered -> state

            // The run ended without saying anything, so the socket is still
            // waiting. That is a capture that did not answer, and it costs
            // this one request.
            Awaiting ->
              answer_capture(state, pending, Error(snapshot.ReadTimedOut))
          }

          State(..state, captures: dict.delete(state.captures, capture))
        }
      }
  }
}

/// What a finished run says about its one read. Only a read that returned says
/// anything about storage; a run that was cancelled, cut off by its deadline,
/// or lost its worker produced no answer, which is the same thing a timeout is.
fn capture_result(
  outcome: weft.Outcome(snapshot.Cut, snapshot.Error),
) -> Result(snapshot.Cut, snapshot.Error) {
  case outcome {
    weft.Completed(value:, ..) -> Ok(value)
    weft.Failed(error:, ..) -> Error(error)
    weft.Abandoned(..)
    | weft.NeverStarted(..)
    | weft.Crashed(..)
    | weft.DrainProofLost(..)
    | weft.CancellationUnconfirmed(..) -> Error(snapshot.ReadTimedOut)
  }
}

/// Answers the request that asked for this capture, from the hub's own
/// process. The cut is assembled with the roster, pending inputs and settings
/// as they are now, which is no staler than the synchronous read was.
fn answer_capture(
  state: State,
  pending: PendingCapture,
  captured: Result(snapshot.Cut, snapshot.Error),
) -> State {
  use state <- with_response(state, pending.connection, pending.response)

  // Evaluate control flow transition for answer capture.
  case captured {
    Ok(cut) ->
      captured_transfer(
        state,
        pending.connection,
        pending.request,
        cut,
        pending.window,
        pending.started,
      )
    Error(error) ->
      reader_failed(state, pending.connection, pending.request, error)
  }
}

/// Commits a captured snapshot cut into an active transfer state.
fn captured_transfer(
  state: State,
  connection: Int,
  id: Int,
  cut: snapshot.Cut,
  window: transfer.Window,
  now: Int,
) -> State {
  use link <- or_reply(
    result.replace_error(dict.get(state.connections, connection), #(
      "closed",
      "attachment is closed",
    )),
    state,
    connection,
    id,
  )
  let snapshot_id =
    int.to_string(connection) <> ":" <> int.to_string(state.next_transfer)

  // The decided read selects every decided escalation under the metadata
  // budget and keeps the newest here, so the transfer's size does not grow
  // with the session's approval history.
  let cut = case window {
    transfer.Decided ->
      snapshot.Cut(
        ..cut,
        cells: transfer.newest(cut.cells, transfer.decided_limit),
      )
    transfer.Recent
    | transfer.Reconcile(_)
    | transfer.History(..)
    | transfer.Lineage(_)
    | transfer.Escalations(_) -> cut
  }

  // Assemble snapshot metadata dictionary for the transfer.
  let metadata =
    json.Object([
      #(
        "missing",
        json.Array(case window {
          transfer.Escalations(ids) ->
            list.filter_map(ids, fn(id) {
              case
                list.any(cut.cells, fn(cell) {
                  list.contains(snapshot_view.lookup_keys(id), cell.key)
                })
              {
                True -> Error(Nil)
                False -> Ok(json.String(id))
              }
            })
          _ -> []
        }),
      ),
      #(
        "cells",
        json.Array(
          list.map(cut.cells, fn(cell) {
            json.Object([
              #("namespace", json.String(register.ns_to_string(cell.namespace))),
              #("key", json.String(cell.key)),
              #("seq", json.Int(cell.register.seq)),
              #("value", cell.register.value.payload),
            ])
          }),
        ),
      ),
      #("usage", core_codec.encode_usage(cut.stats.usage)),
      #("message_count", json.Int(cut.stats.message_count)),
      #(
        "host_run_settings",
        api.encode_run_defaults(state.runtime.settings, None),
      ),
      #("peers", json.Array(roster(state))),
      #("pending_inputs", json.Array(pending_inputs(state, connection))),
      #("tool_availability", case state.registered_tools {
        None -> json.Null
        Some(registry) ->
          json.Object([
            #(
              "registered",
              json.Array(
                registry
                |> dict.keys
                |> list.sort(string.compare)
                |> list.map(json.String),
              ),
            ),
            #(
              "extension_refusals",
              json.Array(list.map(state.extension_refusals, json.String)),
            ),
            #("code_mode_issue", case state.code_mode_issue {
              None -> json.Null
              Some(reason) -> json.String(reason)
            }),
          ])
      }),
      #(
        "stream_preview",
        option.map(state.preview, fn(value) { value.payload })
          |> option.unwrap(json.Null),
      ),
    ])
  use current <- or_reply(
    transfer.start(cut, metadata, snapshot_id, window, now)
      |> result.map_error(fn(reason) { #("snapshot_limit", reason) }),
    state,
    connection,
    id,
  )
  let state =
    put_connection(
      State(..state, next_transfer: state.next_transfer + 1),
      connection,
      Connection(..link, transfer: Some(current)),
    )

  // Format session binding identity fields and reply to subscriber.
  let identity = case link.authentication {
    Authenticated(binding, ..) -> [
      #("session_id", json.String(binding.session_id)),
      #("epoch", json.String(binding.epoch)),
      #("incarnation", json.String(binding.incarnation)),
      #("connection_id", json.String(binding.connection_id)),
      #("origin", origin.encode(link.origin)),
      #("role", json.String(role_text(binding.authority))),
    ]
    HostFixture -> []
  }

  // Dispatch snapshot transfer according to the requested window shape.
  let window_name = case window {
    transfer.Recent -> "recent"
    transfer.Reconcile(_) -> "catch_up"
    transfer.History(..) -> "history"
    transfer.Lineage(_) -> "lineage"
    transfer.Escalations(_) -> "escalations"
    transfer.Decided -> "decided"
  }

  reply(
    state,
    connection,
    id,
    protocol.SnapshotBegin(
      json.Object([
        #("snapshot_id", json.String(snapshot_id)),
        #("next_seq", json.Int(cut.next_seq)),
        #("window", json.String(window_name)),
        #("complete_history", json.Bool(False)),
        #("record_bytes_limit", json.Int(snapshot.record_bytes_limit)),
        #("fragment_bytes_limit", json.Int(transfer.piece_bytes)),
        #("oldest_seq", case cut.recent {
          [first, ..] -> json.Int(first.seq)
          [] -> json.Null
        }),
        ..identity
      ]),
    ),
  )
  state
}

/// Advances an active transfer stream to the requested page index.
fn advance_transfer(
  state: State,
  connection: Int,
  id: Int,
  snapshot_id: String,
  index: Int,
) -> State {
  let current = {
    use link <- result.try(dict.get(state.connections, connection))
    option.to_result(link.transfer, Nil)
  }
  let now = bootstrap.monotonic_time_ms()

  // Evaluate control flow transition for advance transfer.
  case current {
    Ok(current) ->
      case transfer.matches(current, snapshot_id, index, now) {
        True ->
          drive_transfer(
            state,
            connection,
            id,
            current,
            2,
            now + continuation_wall_ms,
          )
        False -> stale_transfer(state, connection, id)
      }
    Error(Nil) -> stale_transfer(state, connection, id)
  }
}

// One continuation may need two reader exchanges — a descriptor page, then
// the first fragment of that page's first record — and both are answered
// inside the single `connection_request` the socket waits on. That wait is
// `6000`, so the pair shares one wall a second below it: bounding each read
// alone let a slow-but-alive reader hold the gateway for ten seconds while the
// socket had already given up at six and issued `mist.stop()`, so the refusal
// the code was about to send landed in a dying mailbox and every other
// attachment on the session waited out the difference.
const continuation_wall_ms = 5000

/// Handles a transfer request against a stale or missing transfer session.
fn stale_transfer(state: State, connection: Int, id: Int) -> State {
  reply_error(
    state,
    connection,
    id,
    "stale_snapshot",
    "transfer expired or continuation does not match",
  )
  state
}

/// `until` is the instant this continuation's reads must be answered by; it is
/// established once by `advance_transfer` and threaded through the recursion so
/// the second read spends what the first left rather than a second full budget.
fn drive_transfer(
  state: State,
  connection: Int,
  id: Int,
  current: transfer.Transfer,
  reads: Int,
  until: Int,
) -> State {
  let now = bootstrap.monotonic_time_ms()
  use <- bool.lazy_guard(transfer.expired(current, now), fn() {
    stale_transfer(state, connection, id)
  })

  // Evaluate control flow transition for drive transfer.
  case transfer.step(current, now:, until:) {
    transfer.Emit(event, next) -> {
      let state = retain_transfer(state, connection, Some(next))
      reply(state, connection, id, event)
      state
    }
    transfer.End(event) -> {
      let state = retain_transfer(state, connection, None)
      reply(state, connection, id, event)
      state
    }
    transfer.Refused(reason) -> {
      reply_error(state, connection, id, "snapshot_failed", reason)
      retain_transfer(state, connection, None)
    }

    // Neither window can fund a read, so none is issued. The client's next
    // move is the same one an expired transfer asks for — capture a fresh
    // snapshot — so it gets the same refusal, and the retained state goes
    // rather than inviting a continuation that would be refused again.
    transfer.Exhausted -> {
      let state = retain_transfer(state, connection, None)
      stale_transfer(state, connection, id)
    }
    transfer.ReadPage(after, before, within) if reads > 0 -> {
      let outcome =
        state.runtime.session.snapshot_reader.page(after, before, 100, within)
      continue_read(
        state,
        connection,
        id,
        current,
        reads,
        until,
        outcome,
        transfer.accept_page,
      )
    }
    transfer.ReadLineage(from, before, within) if reads > 0 -> {
      let outcome =
        state.runtime.session.snapshot_reader.lineage(from, before, 100, within)
      continue_read(
        state,
        connection,
        id,
        current,
        reads,
        until,
        outcome,
        transfer.accept_lineage,
      )
    }
    transfer.ReadFragment(descriptor, offset, within) if reads > 0 -> {
      let outcome =
        state.runtime.session.snapshot_reader.fragment(
          descriptor,
          offset,
          within,
        )
      continue_read(
        state,
        connection,
        id,
        current,
        reads,
        until,
        outcome,
        transfer.accept_fragment,
      )
    }
    transfer.ReadPage(..)
    | transfer.ReadLineage(..)
    | transfer.ReadFragment(..) -> stale_transfer(state, connection, id)
  }
}

/// Reads the next page slice from an active snapshot reader.
fn continue_read(
  state: State,
  connection: Int,
  id: Int,
  current: transfer.Transfer,
  reads: Int,
  until: Int,
  outcome: Result(a, snapshot.Error),
  accept: fn(transfer.Transfer, a) -> Result(transfer.Transfer, String),
) -> State {
  case outcome {
    // A continuation's reads are funded from what is left of the client's own
    // retention window and of this request's wall, so an expiry here is the
    // caller's wait running out and `reader_failed` refuses only this request.
    Error(error) -> reader_failed(state, connection, id, error)
    Ok(value) -> {
      use next <- or_reply(
        accept(current, value)
          |> result.map_error(fn(reason) { #("snapshot_failed", reason) }),
        state,
        connection,
        id,
      )
      drive_transfer(state, connection, id, next, reads - 1, until)
    }
  }
}

/// Records or clears active transfer tracking for a connection.
fn retain_transfer(
  state: State,
  connection: Int,
  current: Option(transfer.Transfer),
) -> State {
  case dict.get(state.connections, connection) {
    Error(Nil) -> state
    Ok(link) ->
      put_connection(state, connection, Connection(..link, transfer: current))
  }
}

/// What a failed read says about the storage actor behind it, which is the only
/// thing that decides whether this hub is fenced.
///
/// `ReaderUnavailable` is proof: the exchange monitors the actor, so it is
/// reported only when that process is absent or died before replying. Nothing
/// can answer for it afterwards, and its custody must drain before the session
/// is reopened. `ReadTimedOut` is not proof of anything but a deadline. The
/// actor may simply be behind a long write, a startup burst or a stalled disk,
/// and every read here is asked from a process that owns its own reply subject,
/// so a late answer has nowhere to land and a repeat is safe. It therefore
/// costs the one request that waited, which is told to retry, and nothing else.
/// Reading it as a dead reader is what let one slow capture disconnect every
/// client of a session and refuse every later attach until it was reopened.
fn reader_failed(
  state: State,
  connection: Int,
  id: Int,
  error: snapshot.Error,
) -> State {
  case error {
    // Timeout does not cancel work already queued, but the actor is gone, so
    // fence this hub before requesting exact-incarnation cleanup, and never
    // synchronously await it.
    snapshot.ReaderUnavailable -> {
      let poisoned = State(..state, health: ReaderPoisoned)
      list.each(dict.values(state.connections), fn(link) {
        case link.authentication {
          Authenticated(_, _, close, _) -> close()
          HostFixture -> Nil
        }
      })

      // Evaluate control flow transition for reader failed.
      case dict.get(state.connections, connection) {
        Ok(link) -> link.read_failed()
        Error(Nil) -> Nil
      }

      State(
        ..poisoned,
        connections: dict.map_values(poisoned.connections, fn(_, link) {
          Connection(..link, transfer: None)
        }),
      )
    }

    // The request is refused in band and its transfer is dropped, so nothing
    // retries the read on this connection's behalf; the client's own retry
    // asks again. The hub and every other attachment carry on.
    snapshot.ReadTimedOut -> {
      reply_error(
        state,
        connection,
        id,
        "snapshot_failed",
        "storage did not answer in time; retry the request",
      )
      retain_transfer(state, connection, None)
    }

    // A refused bounded goal read can leave the socket attached. The client
    // must invalidate its observation on this correlated snapshot_failed;
    // waiting for transport loss would keep a stale board indefinitely.
    snapshot.StorageFailure(_)
    | snapshot.InvalidRequest
    | snapshot.MetadataTooLarge
    | snapshot.RecordTooLarge(..)
    | snapshot.MissingRecord -> {
      reply_error(
        state,
        connection,
        id,
        "snapshot_failed",
        "bounded snapshot read refused",
      )
      retain_transfer(state, connection, None)
    }
  }
}

/// Membership resolution is the admission ordering point. Work already admitted
/// may finish, but the next command or outbound batch must resolve access again.
fn check_binding(
  binding: Binding,
  check: fn() -> Result(#(access.Principal, access.Authority), String),
) {
  use #(principal, authority) <- result.try(check())

  // Inspect connection authentication credentials and binding authority.
  case principal.id == binding.principal.id && authority == binding.authority {
    True -> Ok(principal)
    False -> Error("attachment authority changed")
  }
}

/// Re-evaluates client connection authorization against the current session token.
fn revalidate(state: State, id: Int) -> State {
  case dict.get(state.connections, id) {
    Error(Nil) | Ok(Connection(authentication: HostFixture, ..)) -> state
    Ok(
      Connection(authentication: Authenticated(binding, check, close, _), ..) as link,
    ) ->
      case check_binding(binding, check) {
        Error(_) -> {
          close()
          remove_connection(state, id)
        }
        Ok(principal) ->
          State(
            ..state,
            connections: dict.insert(
              state.connections,
              id,
              Connection(
                ..link,
                origin: Some(message.Origin(
                  principal.id,
                  principal.display_name,
                )),
              ),
            ),
          )
      }
  }
}

fn revalidate_all(state: State) -> State {
  list.fold(dict.keys(state.connections), state, revalidate)
}

/// Handles a disconnected client socket monitor down event.
fn remove_socket(state: State, down: process.Down) -> State {
  let sources =
    dict.filter(state.preview_sources, fn(_, watch) { watch != down.monitor })
  let state =
    State(
      ..state,
      preview_sources: sources,
      preview: retained_preview(state.preview, sources),
    )
  list.fold(dict.to_list(state.connections), state, fn(state, pair) {
    let #(id, link) = pair

    // Inspect connection authentication credentials and binding authority.
    case link.authentication {
      Authenticated(_, _, _, watch) if watch == down.monitor ->
        remove_connection(state, id)
      Authenticated(..) | HostFixture -> state
    }
  })
}

/// Allocates a live preview streaming lease for an active operation.
fn lease_preview(state: State, pid, expires, reply) -> State {
  // Evaluate control flow transition for lease preview.
  case
    state.health == Reading
    && bootstrap.monotonic_time_ms() < expires
    && dict.size(state.preview_sources) < 16
    && !list.is_empty(roster(state))
  {
    False -> {
      process.send(reply, Error("preview source unavailable"))
      state
    }
    True -> {
      let source = state.next_preview_source
      let watch = process.monitor(pid)
      process.send(reply, Ok(source))
      State(
        ..state,
        next_preview_source: source + 1,
        preview_sources: dict.insert(state.preview_sources, source, watch),
      )
    }
  }
}

/// Records incoming live preview chunk data into gateway state.
fn record_preview(
  state: State,
  source,
  operation,
  generation,
  kind,
  text: String,
  reply,
) -> State {
  // Evaluate control flow transition for record preview.
  case
    state.health == Reading
    && dict.has_key(state.preview_sources, source)
    && bit_array.byte_size(bit_array.from_string(text)) <= 24_576
  {
    False -> {
      process.send(reply, Error("preview source refused"))
      state
    }
    True -> {
      process.send(reply, Ok(Nil))
      let revision = state.preview_revision + 1
      State(
        ..state,
        preview_revision: revision,
        preview: Some(LivePreview(
          source:,
          payload: json.Object([
            #("revision", json.Int(revision)),
            #("operation", json.String(operation)),
            #("generation", json.String(generation)),
            #("kind", json.String(kind)),
            #("text", json.String(text)),
            #("discontinuous", json.Bool(True)),
          ]),
        )),
      )
    }
  }
}

/// Cleans up active preview lease state upon stream completion.
fn forget_preview(state: State, source) -> State {
  // Evaluate control flow transition for forget preview.
  case dict.get(state.preview_sources, source) {
    Error(Nil) -> state
    Ok(watch) -> {
      process.demonitor_process(watch)
      let sources = dict.delete(state.preview_sources, source)
      State(
        ..state,
        preview_sources: sources,
        preview: retained_preview(state.preview, sources),
      )
    }
  }
}

/// Evaluates whether active preview streaming monitors remain live.
fn retained_preview(
  preview: Option(LivePreview),
  sources: Dict(Int, process.Monitor),
) -> Option(LivePreview) {
  case preview {
    None -> None
    Some(sample) ->
      case dict.has_key(sources, sample.source) {
        True -> preview
        False -> None
      }
  }
}

/// Drops an active client connection and releases its subscribed resources.
fn remove_connection(state: State, id: Int) -> State {
  // Evaluate control flow transition for remove connection.
  case dict.get(state.connections, id) {
    Error(Nil) -> state
    Ok(link) -> {
      let _forgotten =
        option.map(state.btw, fn(name) { address.send(name, btw.Forget(id)) })

      // Inspect connection authentication credentials and binding authority.
      case link.authentication {
        Authenticated(_, _, close, watch) -> {
          close()
          process.demonitor_process(watch)
        }
        HostFixture -> Nil
      }

      let state =
        State(..state, connections: dict.delete(state.connections, id))
      publish_presence(state)
      state
    }
  }
}

/// Formats an access authority tier as human-readable role text.
fn role_text(authority: access.Authority) {
  case authority {
    access.Owner -> "owner"
    access.Participant(access.Operator) -> "operator"
    access.Participant(access.Observer) -> "observer"
  }
}

/// Presence is a fact about the network protocol, so only an authenticated,
/// subscribed connection is a peer: a host fixture is a test sink with no
/// identity to publish, and an attachment that has not subscribed has not yet
/// told anyone it is here.
fn roster(state: State) {
  dict.values(state.connections)
  |> list.filter_map(fn(link) {
    case link.authentication, link.subscription {
      Authenticated(binding, _, _, _), Subscribed ->
        Ok(
          json.Object([
            #("connection_id", json.String(binding.connection_id)),
            #("origin", origin.encode(link.origin)),
            #("role", json.String(role_text(binding.authority))),
          ]),
        )
      Authenticated(..), Unsubscribed
      | HostFixture, Subscribed
      | HostFixture, Unsubscribed
      -> Error(Nil)
    }
  })
}

/// Broadcasts presence and subscription state changes to all connected peers.
fn publish_presence(state: State) {
  let event = protocol.PresenceEvent(roster(state))
  dict.each(state.connections, fn(id, link) {
    case link.authentication, link.subscription {
      Authenticated(..), Subscribed ->
        send_to(state, id, EventEnvelope(None, None, event))
      Authenticated(..), Unsubscribed
      | HostFixture, Subscribed
      | HostFixture, Unsubscribed
      -> Nil
    }
  })
}

fn connection_origin(state: State, connection: Int) {
  dict.get(state.connections, connection)
  |> result.map(fn(link) { link.origin })
  |> result.unwrap(None)
}

/// The commands that only the owner may send, beyond what an operator may. The
/// answer is what a member who sends one is told it may not do, or `None` for a
/// command a member may send. A profile switch restarts the session for everyone
/// attached and rewrites the owner's registration, so it is the owner's alone, as
/// remembering permissions is.
fn owner_only(command: Command) -> Option(String) {
  case command {
    protocol.ApproveForSession(..)
    | protocol.PermissionsGet
    | protocol.PermissionForget(..) ->
      Some("only the session owner may remember permissions for the session")
    protocol.ProfileSet(..) ->
      Some("only the session owner may switch the session's model profile")
    protocol.ProposalsGet | protocol.ProposalDecide(..) ->
      Some("only the session owner may review proposed rules")
    protocol.MemoryGet ->
      Some("only the session owner may read the memory overview")
    _ -> None
  }
}

/// Whether the connection is an authenticated member rather than the daemon's
/// owner. A host fixture carries no principal and is the trusted in-VM sink, so
/// it is not a member.
fn member_attached(state: State, connection: Int) -> Bool {
  case dict.get(state.connections, connection) {
    Ok(Connection(
      authentication: Authenticated(
        Binding(
          principal: access.Principal(kind: access.MemberPrincipal, ..),
          ..,
        ),
        ..,
      ),
      ..,
    )) -> True
    Ok(_) | Error(Nil) -> False
  }
}

/// Returns whether a connection has observer-only access permissions.
fn observer(state: State, connection: Int) {
  case dict.get(state.connections, connection) {
    Ok(Connection(
      authentication: Authenticated(
        Binding(authority: access.Participant(access.Observer), ..),
        ..,
      ),
      ..,
    )) -> True
    Ok(_) | Error(Nil) -> False
  }
}

/// Determines whether a protocol command is read-only or mutates state.
fn read_only(command: Command) {
  case command {
    protocol.Evolution(action, _) ->
      list.contains(
        ["catalogue", "inspect", "evidence", "status", "board"],
        action,
      )
    protocol.Subscribe(..)
    | protocol.CatchUp(..)
    | protocol.SnapshotNext(..)
    | protocol.History(..)
    | protocol.HistoryLineage(..)
    | protocol.EscalationsGet(..)
    | protocol.EscalationsDecided
    | protocol.ListModels
    | protocol.ListSkills(..)
    | protocol.WorktreeDiffGet
    | protocol.ContextGet(..)
    | protocol.ChildHistoryGet(..)
    | protocol.LiveJobsGet(..)
    | protocol.AdvisorPendingGet
    | protocol.BlockSummariesGet(..)
    | protocol.GoalGet
    | protocol.NotesGet(..)
    | protocol.QueuedInputGet(..)
    | protocol.ProfileGet
    | protocol.ListSchedules -> True
    protocol.Btw(..)
    | protocol.Prompt(..)
    | protocol.PromptContent(..)
    | protocol.Steer(..)
    | protocol.FollowUp(..)
    | protocol.RemoveQueuedInput(..)
    | protocol.EditQueuedInput(..)
    | protocol.Abort(..)
    | protocol.Approve(..)
    | protocol.ApproveForSession(..)
    | protocol.Deny(..)
    | protocol.Fork(..)
    | protocol.Navigate(..)
    | protocol.Compact(..)
    | protocol.CreateStrand(..)
    | protocol.SetConfig(..)
    | protocol.GoalSet(..)
    | protocol.GoalCheck(..)
    | protocol.GoalClear
    | protocol.GoalPause
    | protocol.GoalResume
    | protocol.CancelSchedule(..)
    | protocol.PermissionsGet
    | protocol.PermissionForget(..)
    | protocol.ProposalsGet
    | protocol.ProposalDecide(..)
    | protocol.MemoryGet
    | protocol.ProfileSet(..)
    | protocol.UnknownCommand(..) -> False
  }
}

/// Pulls new session journal entries and broadcasts delta events to subscribers.
fn pull_and_broadcast(state: State) -> State {
  let #(state, emits) = pull(state)

  // The pull is the one place a strand's live operation is observed to
  // have gone, so a queue whose strand just went idle drains here — after
  // `state.live` has been replaced and before anything leaves, so a drain
  // that fails reports against the state the failure was decided under.
  let state = drain_idle_strands(state) |> reopen_if_owed

  // Decide whether delivery mode is restricted to host-only or network-enabled.
  case state.delivery {
    // The host fixture stream is the whole record; it has no size bound
    // to respect and its fixtures read the entries themselves.
    HostOnly -> broadcast(state, emits)

    // A network peer gets a notice per emit and fetches records on the
    // credited path (`protocol-change/018`). A usage row also has a bounded
    // observational push (`protocol-change/047`): its fixed-shape counters
    // let a terminal assess a cache miss without guessing from session
    // totals, while the notice still drives authoritative catch-up.
    Network ->
      broadcast(
        state,
        list.flat_map(emits, fn(emit) {
          let notice =
            Emit(
              seq: emit.seq,
              event: protocol.CommittedEvent(notice_strand(state, emit.event)),
              observation_strand: None,
            )

          // Evaluate control flow transition for pull and broadcast.
          case emit.event, emit.observation_strand {
            protocol.UsageEvent(op:, usage:, last_usage:, ..), Some(strand) -> {
              let observed =
                Emit(
                  seq: emit.seq,
                  event: protocol.UsageObservationEvent(
                    strand:,
                    op:,
                    usage:,
                    last_usage:,
                  ),
                  observation_strand: None,
                )

              // Evaluate control flow transition for pull and broadcast.
              case bounded_usage_observation(observed) {
                True -> [notice, observed]
                False -> [notice]
              }
            }
            _, _ -> [notice]
          }
        }),
      )
  }

  state
}

/// A reload the configuration owes is paid here, after the pull has replaced
/// `live` and after any held prompt for an idle strand has been admitted, so a
/// queue that starts a run defers the reopen rather than being cut off by it. A
/// draining hub is already being stopped and owes nothing.
fn reopen_if_owed(state: State) -> State {
  case state.reload, state.profile, state.admission {
    Owed, Some(desk), Accepting ->
      case dict.is_empty(state.live) {
        True -> {
          desk.restart()
          State(..state, reload: Reopening)
        }
        False -> state
      }
    _, _, _ -> state
  }
}

/// The usage envelope has a fixed set of counters, but a provider can still
/// report unusually large integers. A push spends no transfer credit, so an
/// oversized observation is omitted and its committed notice still repairs
/// the authoritative session total through the bounded capture.
fn bounded_usage_observation(emit: Emit) -> Bool {
  protocol.event_value(protocol.EventEnvelope(
    reply_to: None,
    seq: Some(emit.seq),
    event: emit.event,
  ))
  |> transfer.encoded_size(65_536)
  |> result.is_ok
}

/// The strand a durable emit landed on, which is a notice's whole body.
/// Every event `pull` can produce names one; the rest are replies,
/// transfers and ephemera that never reach this function, and they are
/// listed rather than swept into a catch-all so that an emit kind added
/// later has to answer the question here instead of silently taking the
/// fallback.
fn notice_strand(state: State, event: WireEvent) -> String {
  case event {
    protocol.EntryEvent(record:) -> record.strand
    protocol.UsageEvent(strand:, ..)
    | protocol.UsageObservationEvent(strand:, ..) -> strand
    protocol.OpTransitionEvent(strand:, ..) -> strand
    protocol.EscalationEvent(record:) -> record.strand
    protocol.StrandResultEvent(strand:, ..) -> strand
    protocol.SnapshotBegin(..)
    | protocol.SnapshotChunk(..)
    | protocol.SnapshotEnd(..)
    | protocol.SnapshotEvent(..)
    | protocol.MutationOutcome(..)
    | protocol.AttachmentEvent(..)
    | protocol.PresenceEvent(..)
    | protocol.InputQueueChanged
    | protocol.HeldInputReturned(..)
    | protocol.StreamDeltaEvent(..)
    | protocol.ToolOutputEvent(..)
    | protocol.BlockSummaryEvent(..)
    | protocol.GoalChanged
    | protocol.ProposalsChanged
    | protocol.EvolutionChanged
    | protocol.CommittedEvent(..)
    | protocol.ErrorEvent(..)
    | protocol.UnknownEvent(..) -> single_live_strand(state)
  }
}

/// Reads everything above the high-water from storage and returns it as
/// seq-ordered emits, advancing the high-water. Read-only; never
/// commits.
fn pull(state: State) -> #(State, List(Emit)) {
  let hw = state.high_water
  let strands = strand_names(state)

  // 1. New entries reachable from each strand's leaf, plus a
  //    completeness pass for entries no leaf covers (e.g. a branch
  //    summary left behind by a navigation).
  let #(entry_strand, entry_emits) =
    new_entries(state.runtime.session, strands, hw, state.entry_strand)

  // 2. New usage-ledger rows.
  let usage_emits = new_usage(state, entry_strand, hw)

  // 3. Operation transitions and terminal results from the strand
  //    registers.
  let #(live, register_emits) = register_events(state, strands, hw)

  // 4. Escalation records.
  let escalation_emits = escalation_events(state, hw)
  let emits =
    [entry_emits, usage_emits, register_emits, escalation_emits]
    |> list.flatten
    |> list.filter(fn(emit) { emit.seq > hw })
    |> list.sort(fn(a, b) { int.compare(a.seq, b.seq) })
    |> dedupe_by_seq

  // The high-water advances only to the greatest seq actually emitted.
  // Register writes that produce no event (leaf moves, queue
  // bookkeeping) may sit above it — harmless, because every event
  // source is gated on its own cell/row seq exceeding the high-water,
  // so nothing re-emits and nothing is skipped. Advancing further
  // (e.g. to a register tail read *after* the scans) would race a
  // commit landing between the reads and silently drop its events.
  let high_water = greatest_seq(emits, hw)
  #(State(..state, high_water:, live:, entry_strand:), emits)
}

/// Opens a session's gateway at the end of its history: the same `high_water`,
/// `live` and `entry_strand` that `pull` at a high-water of zero would leave,
/// without building any emit.
///
/// A pull has to decode every entry because it hands each one to a peer. The
/// prime hands them to nobody, and what it keeps of an entry is its strand
/// and its seq, so the entries come from `learn_entries`, which reads only
/// their heads. On a long session the payloads are most of the bytes, and
/// decoding them was the larger part of reopening it. The usage, register and
/// escalation sources are the ones `pull` runs; the high-water is the
/// greatest seq any of them, or the entries, reached, exactly as in `pull`.
fn prime(state: State) -> State {
  let hw = state.high_water
  let strands = strand_names(state)
  let #(entry_strand, entry_top) =
    learn_entries(state.runtime.session, strands, hw, state.entry_strand)
  let usage_emits = new_usage(state, entry_strand, hw)
  let #(live, register_emits) = register_events(state, strands, hw)
  let escalation_emits = escalation_events(state, hw)
  let high_water =
    [usage_emits, register_emits, escalation_emits]
    |> list.flatten
    |> greatest_seq(entry_top)
  State(..state, high_water:, live:, entry_strand:)
}

// The greatest seq among the emits, or `floor` when none exceeds it. An emit
// at or below the floor has been reported already and never lowers it.
fn greatest_seq(emits: List(Emit), floor: Int) -> Int {
  list.fold(emits, floor, fn(highest, emit) { int.max(highest, emit.seq) })
}

/// What the entry source of a gateway's first pull leaves behind: the
/// greatest seq it reached, and each entry's attribution as an
/// `#(entry id, "kind:strand")` pair sorted by id.
///
/// Only the equivalence tests read it. The prime and the decoding pull
/// are meant to leave the same entry cache and the same entry high-water,
/// and the cache and `State` are private, so this is the narrowest view
/// that lets a test compare them.
@internal
pub type EntryHistory {
  EntryHistory(high_water: Int, attribution: List(#(String, String)))
}

/// The entry history the prime builds, from heads alone.
///
/// ## Examples
///
/// ```gleam
/// // gateway.entry_history_by_heads(runtime.session)
/// ```
@internal
pub fn entry_history_by_heads(store: session.Session) -> EntryHistory {
  let #(cache, high_water) =
    learn_entries(store, strand_names_in(store), 0, dict.new())
  render_entry_history(cache, high_water)
}

/// The entry history a decoding pull at a high-water of zero builds.
///
/// ## Examples
///
/// ```gleam
/// // gateway.entry_history_by_decoding(runtime.session)
/// ```
@internal
pub fn entry_history_by_decoding(store: session.Session) -> EntryHistory {
  let #(cache, emits) =
    new_entries(store, strand_names_in(store), 0, dict.new())
  render_entry_history(cache, greatest_seq(emits, 0))
}

/// Renders cached transcript entry attribution history for wire delivery.
fn render_entry_history(
  cache: Dict(String, EntryAttribution),
  high_water: Int,
) -> EntryHistory {
  let attribution =
    dict.to_list(cache)
    |> list.map(fn(pair) {
      // Evaluate control flow transition for render entry history.
      let label = case pair.1 {
        BranchOwned(strand:) -> "owned:" <> strand
        Unverified(strand:) -> "unverified:" <> strand
        Shared(strand:) -> "shared:" <> strand
      }

      #(pair.0, label)
    })
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  EntryHistory(high_water:, attribution:)
}

/// Deduplicates broadcast delta events by event sequence number.
fn dedupe_by_seq(emits: List(Emit)) -> List(Emit) {
  emits
  |> list.fold(#([], -1), fn(accumulator, emit) {
    let #(kept, last) = accumulator

    // Evaluate control flow transition for dedupe by seq.
    case emit.seq == last {
      True -> #(kept, last)
      False -> #([emit, ..kept], emit.seq)
    }
  })
  |> fn(accumulator) { list.reverse(accumulator.0) }
}

fn strand_names(state: State) -> List(String) {
  strand_names_in(state.runtime.session)
}

/// Lists all distinct active strand names present in the session store.
fn strand_names_in(store: session.Session) -> List(String) {
  case storage.list_registers(store.store, register.StrandConfig, None) {
    Ok(cells) ->
      cells
      |> list.map(fn(cell) { cell.0 })
      |> list.sort(string.compare)
    Error(_) -> []
  }
}

/// Every entry above the high-water is read once, and each strand's branch
/// is found among those rows rather than read again.
///
/// A branch scan answers the root path of its start (spec Part 1.2), and a
/// parent is always committed before its child, so the part of a strand's
/// path above the high-water is exactly its leaf followed back through
/// parent links for as long as the link stays above the high-water — and
/// every one of those entries is among the rows read here. The gateway used
/// to read each strand's path from storage as well, which decoded every
/// branch entry twice; the prime that opens a session reads the whole
/// history, so on a long session that second decode was a third of opening
/// it.
///
/// Who owns which entry is decided by `attribute` over the rows' heads, the
/// same function the prime applies to heads read without their payloads, so
/// the two cannot disagree about a claim. This function adds only what a
/// pull needs and the prime does not: each claim becomes an entry emit.
///
/// When the read fails nothing is claimed, and the high-water stays where
/// it was for the next pull to try again.
fn new_entries(
  store: session.Session,
  strands: List(String),
  hw: Int,
  cache: Dict(String, EntryAttribution),
) -> #(Dict(String, EntryAttribution), List(Emit)) {
  // Evaluate control flow transition for new entries.
  case
    storage.scan_entries(
      store.store,
      storage.entry_scan()
        |> storage.entry_seq_range(Some(hw + 1), None),
    )
  {
    Error(_) -> #(cache, [])
    Ok(rows) -> {
      let #(cache, attributed) =
        attribute(store, strands, list.map(rows, storage.entry_head_of), cache)

      // Every claim names a head derived from these rows a moment ago, so
      // the lookup cannot miss; `filter_map` states that by having no arm
      // that does anything with a miss.
      let by_id =
        list.fold(rows, dict.new(), fn(by_id, row) {
          dict.insert(by_id, ids.entry_id_to_string(entry_id_of(row)), row)
        })
      #(
        cache,
        list.filter_map(attributed, fn(claim) {
          dict.get(by_id, ids.entry_id_to_string(claim.head.id))
          |> result.map(entry_emit(claim.strand, _))
        }),
      )
    }
  }
}

/// What a prime keeps of the entries above the high-water: the attribution
/// cache and the greatest seq they reach, built from heads alone.
///
/// Every entry read is claimed by one of `attribute`'s two passes, so each
/// one a pull would have emitted is counted here, and the greatest of their
/// seqs is the entry source's contribution to the high-water. A failed read
/// claims nothing and leaves the cache and the high-water as they were.
fn learn_entries(
  store: session.Session,
  strands: List(String),
  hw: Int,
  cache: Dict(String, EntryAttribution),
) -> #(Dict(String, EntryAttribution), Int) {
  // Evaluate control flow transition for learn entries.
  case
    storage.scan_entry_heads(
      store.store,
      storage.entry_scan()
        |> storage.entry_seq_range(Some(hw + 1), None),
    )
  {
    Error(_) -> #(cache, hw)
    Ok(heads) -> {
      let #(cache, _attributed) = attribute(store, strands, heads, cache)
      #(
        cache,
        list.fold(heads, hw, fn(highest, head) { int.max(highest, head.seq) }),
      )
    }
  }
}

// An entry a pull would emit, with the strand it would emit it under.
type Attributed {
  Attributed(strand: String, head: EntryHead)
}

/// The claim rules, over heads: which strand each entry above the
/// high-water belongs to, and in what order the claims were made. Both a
/// pull and a prime run exactly this, so the rules exist once; the claims
/// come back newest first, as a fold leaves them.
///
/// Each strand's branch is claimed first, in strand order, and an entry
/// two branches reach becomes `Shared`. A completeness pass then claims
/// whatever no leaf covered, through its parent's attribution, falling
/// back to the first strand.
fn attribute(
  store: session.Session,
  strands: List(String),
  heads: List(EntryHead),
  cache: Dict(String, EntryAttribution),
) -> #(Dict(String, EntryAttribution), List(Attributed)) {
  // An empty entry cut has no branch to claim. In particular, an idle
  // commit hint must not read every strand's leaf merely to find no head.
  use <- bool.lazy_guard(when: list.is_empty(heads), return: fn() {
    #(cache, [])
  })
  let by_id =
    list.fold(heads, dict.new(), fn(by_id, head) {
      dict.insert(by_id, ids.entry_id_to_string(head.id), head)
    })

  // Per-strand branches above the high-water attribute entries to
  // the strand whose branch they extend.
  let #(cache, claimed) =
    list.fold(strands, #(cache, []), fn(accumulator, strand) {
      claim_branch(store, by_id, strand, accumulator)
    })

  // Completeness pass: whatever the leaves missed, attributed through
  // the parent chain (fallback: the first strand).
  let fallback = case strands {
    [first, ..] -> first
    [] -> "main"
  }

  list.fold(heads, #(cache, claimed), fn(accumulator, head) {
    claim_by_parent(accumulator, head, fallback)
  })
}

/// One strand's branch above the high-water, oldest first, folded into the
/// running cache/claims pair. A strand with no leaf, or whose leaf is at or
/// below the high-water, contributes nothing.
fn claim_branch(
  store: session.Session,
  by_id: Dict(String, EntryHead),
  strand: String,
  accumulator: #(Dict(String, EntryAttribution), List(Attributed)),
) -> #(Dict(String, EntryAttribution), List(Attributed)) {
  case session.strand_leaf(store, strand) {
    Ok(Some(session.Cell(value: Some(leaf), ..))) ->
      root_path(by_id, ids.entry_id_to_string(leaf), [], dict.size(by_id))
      |> list.fold(accumulator, fn(accumulator, head) {
        claim_row(accumulator, strand, head)
      })
    _ -> accumulator
  }
}

/// Follows parent links from `id` through `by_id`, answering the path root
/// first. It stops at the first entry the heads do not hold, and after at
/// most as many steps as there are heads, so a parent cycle in a corrupt
/// store ends the walk instead of looping.
fn root_path(
  by_id: Dict(String, EntryHead),
  id: String,
  path: List(EntryHead),
  steps: Int,
) -> List(EntryHead) {
  case steps > 0, dict.get(by_id, id) {
    True, Ok(head) ->
      case head.parent {
        Some(parent) ->
          root_path(
            by_id,
            ids.entry_id_to_string(parent),
            [head, ..path],
            steps - 1,
          )
        None -> [head, ..path]
      }
    False, _ | _, Error(Nil) -> path
  }
}

/// Claims one entry for `strand` unless the cache already has it (an entry
/// another strand's branch already attributed).
fn claim_row(
  accumulator: #(Dict(String, EntryAttribution), List(Attributed)),
  strand: String,
  head: EntryHead,
) -> #(Dict(String, EntryAttribution), List(Attributed)) {
  let #(cache, claims) = accumulator
  let id = ids.entry_id_to_string(head.id)

  // Evaluate control flow transition for claim row.
  case dict.get(cache, id) {
    Error(Nil) -> #(dict.insert(cache, id, BranchOwned(strand)), [
      Attributed(strand:, head:),
      ..claims
    ])
    Ok(BranchOwned(existing)) if existing == strand -> #(cache, claims)
    Ok(Unverified(existing)) if existing == strand -> #(
      dict.insert(cache, id, BranchOwned(strand)),
      claims,
    )
    Ok(existing) -> #(
      dict.insert(cache, id, Shared(entry_attribution_strand(existing))),
      claims,
    )
  }
}

/// Claims one entry the branch scans missed, by walking its parent's
/// attribution (or the fallback strand when the parent is unattributed
/// too).
fn claim_by_parent(
  accumulator: #(Dict(String, EntryAttribution), List(Attributed)),
  head: EntryHead,
  fallback: String,
) -> #(Dict(String, EntryAttribution), List(Attributed)) {
  let #(cache, claims) = accumulator
  let id = ids.entry_id_to_string(head.id)

  // Evaluate control flow transition for claim by parent.
  case dict.has_key(cache, id) {
    True -> #(cache, claims)
    False -> {
      // Evaluate control flow transition for claim by parent.
      let strand = case head.parent {
        Some(parent) ->
          case dict.get(cache, ids.entry_id_to_string(parent)) {
            Ok(attribution) -> entry_attribution_strand(attribution)
            Error(Nil) -> fallback
          }
        None -> fallback
      }

      #(dict.insert(cache, id, Unverified(strand)), [
        Attributed(strand:, head:),
        ..claims
      ])
    }
  }
}

fn entry_attribution_strand(attribution: EntryAttribution) -> String {
  case attribution {
    BranchOwned(strand:) | Unverified(strand:) | Shared(strand:) -> strand
  }
}

/// Maps a journal entry record into a wire emit delta event.
fn entry_emit(strand: String, row: Entry) -> Emit {
  Emit(
    seq: entry_seq_of(row),
    event: protocol.EntryEvent(record: EntryRecord(strand:, entry: row)),
    observation_strand: None,
  )
}

/// Emits usage delta accounting events for newly committed journal entries.
fn new_usage(
  state: State,
  entry_strand: Dict(String, EntryAttribution),
  hw: Int,
) -> List(Emit) {
  let store = state.runtime.session.store

  // Evaluate control flow transition for new usage.
  case
    storage.scan_usage(
      store,
      storage.usage_scan()
        |> storage.usage_seq_range(Some(hw + 1), None),
    )
  {
    Error(_) -> []
    Ok(rows) ->
      list.map(rows, fn(row: UsageRow) {
        let attribution = usage_entry_attribution(entry_strand, row.entry_id)

        // Evaluate control flow transition for new usage.
        let observation_strand = case attribution {
          Some(BranchOwned(strand)) -> Some(strand)
          Some(Unverified(_)) | Some(Shared(_)) | None -> None
        }

        // Evaluate control flow transition for new usage.
        let strand = case attribution {
          Some(attribution) -> entry_attribution_strand(attribution)
          None -> single_live_strand(state)
        }

        // Evaluate control flow transition for new usage.
        let op = case dict.get(state.live, strand) {
          Ok(op) -> Some(op)
          Error(Nil) -> None
        }

        Emit(
          seq: row.seq,
          event: protocol.UsageEvent(
            strand:,
            op:,
            usage: row.usage,
            last_usage: last_row_usage(row),
          ),
          observation_strand:,
        )
      })
  }
}

/// A usage row may carry an entry identity without the gateway having seen
/// that entry yet. Only the attribution cache can supply ownership evidence.
fn usage_entry_attribution(
  entry_strand: Dict(String, EntryAttribution),
  entry_id: Option(EntryId),
) -> Option(EntryAttribution) {
  case entry_id {
    Some(id) ->
      case dict.get(entry_strand, ids.entry_id_to_string(id)) {
        Ok(attribution) -> Some(attribution)
        Error(Nil) -> None
      }
    None -> None
  }
}

/// The strand best positioned to own an unattributable record: the one
/// with a live operation when exactly one has one, else the first.
fn single_live_strand(state: State) -> String {
  case dict.to_list(state.live) {
    [#(strand, _)] -> strand
    _ ->
      case strand_names(state) {
        [first, ..] -> first
        [] -> "main"
      }
  }
}

/// Discovers newly registered strand lifecycle events since the last high-water mark.
fn register_events(
  state: State,
  strands: List(String),
  hw: Int,
) -> #(Dict(String, String), List(Emit)) {
  let store = state.runtime.session
  list.fold(strands, #(state.live, []), fn(accumulator, strand) {
    let #(live, emits) = accumulator
    let #(current, state_seq) = current_operation(store, strand)
    let emits =
      terminal_result_emits(store, strand, current, state_seq, hw, emits)
    open_operation_phase(store, strand, current, live, emits, hw)
  })
}

/// Queries the active operation identifier and sequence number for a strand.
fn current_operation(
  store: session.Session,
  strand: String,
) -> #(Option(String), Int) {
  case session.strand_state(store, strand) {
    Ok(Some(session.Cell(value:, seq:))) -> #(
      option.map(value.current_operation, ids.op_id_to_string),
      seq,
    )
    _ -> #(None, 0)
  }
}

/// A terminal result that landed since the last pull. Keyed on the
/// `strand.last_result` register's own seq — never on the live-op diff,
/// because a fast operation can open and settle entirely between two
/// pulls.
fn terminal_result_emits(
  store: session.Session,
  strand: String,
  current: Option(String),
  state_seq: Int,
  hw: Int,
  emits: List(Emit),
) -> List(Emit) {
  // Evaluate operation result outcome.
  case session.last_result(store, strand) {
    Ok(Some(session.Cell(value:, seq:))) if seq > hw -> {
      let #(op, status, error) = result_view(value)

      // The state register clearing the operation is the `done` display
      // transition (only while no successor operation has already
      // claimed the register).
      let emits = case current, state_seq > hw {
        None, True -> [
          Emit(
            seq: state_seq,
            event: protocol.OpTransitionEvent(op:, strand:, phase: "done"),
            observation_strand: None,
          ),
          ..emits
        ]
        _, _ -> emits
      }

      [
        Emit(
          seq:,
          event: protocol.StrandResultEvent(strand:, op:, status:, error:),
          observation_strand: None,
        ),
        ..emits
      ]
    }
    _ -> emits
  }
}

/// The open operation's current phase.
fn open_operation_phase(
  store: session.Session,
  strand: String,
  current: Option(String),
  live: Dict(String, String),
  emits: List(Emit),
  hw: Int,
) -> #(Dict(String, String), List(Emit)) {
  // Evaluate control flow transition for open operation phase.
  case current {
    None -> #(dict.delete(live, strand), emits)
    Some(op_text) -> {
      let live = dict.insert(live, strand, op_text)

      // Evaluate control flow transition for open operation phase.
      case ids.parse_op_id(op_text) {
        Error(_) -> #(live, emits)
        Ok(op_id) ->
          case session.op_state(store, op_id) {
            Ok(Some(session.Cell(value:, seq:))) if seq > hw -> #(live, [
              Emit(
                seq:,
                event: protocol.OpTransitionEvent(
                  op: op_text,
                  strand:,
                  phase: phase_of(value),
                ),
                observation_strand: None,
              ),
              ..emits
            ])
            _ -> #(live, emits)
          }
      }
    }
  }
}

fn escalation_events(state: State, hw: Int) -> List(Emit) {
  list.append(
    local_escalation_events(state, hw),
    remote_escalation_events(state, fn(seq) { seq > hw }),
  )
}

/// The requests filed from other orchestrators that changed in a range of
/// register sequences, as the events the session's own records are.
fn remote_escalation_events(
  state: State,
  within: fn(Int) -> Bool,
) -> List(Emit) {
  case
    storage.list_registers(
      state.runtime.session.store,
      register.FactCustom,
      Some(api.remote_escalation_fact_prefix),
    )
  {
    Error(_) -> []
    Ok(cells) ->
      list.filter_map(cells, fn(cell) {
        let #(_key, storage.Register(value:, seq:)) = cell
        use <- bool.guard(when: !within(seq), return: Error(Nil))
        use record <- result.map(
          protocol.decode_escalation(value.payload) |> result.replace_error(Nil),
        )
        Emit(
          seq:,
          event: protocol.EscalationEvent(record:),
          observation_strand: None,
        )
      })
  }
}

/// Queries pending local permission escalation events for broadcast.
fn local_escalation_events(state: State, hw: Int) -> List(Emit) {
  let store = state.runtime.session.store

  // Evaluate control flow transition for local escalation events.
  case
    storage.list_registers(
      store,
      register.FactCustom,
      Some(runtime_escalation.key_prefix),
    )
  {
    Error(_) -> []
    Ok(cells) ->
      list.filter_map(cells, fn(cell) {
        let #(_key, storage.Register(value:, seq:)) = cell

        // Evaluate control flow transition for local escalation events.
        case seq > hw {
          False -> Error(Nil)
          True ->
            case runtime_escalation.decode(value.payload) {
              Error(_) -> Error(Nil)
              Ok(record) ->
                Ok(Emit(
                  seq:,
                  event: escalation_event(record, seq),
                  observation_strand: None,
                ))
            }
        }
      })
  }
}

fn escalation_event(
  record: runtime_escalation.Escalation,
  seq: Int,
) -> WireEvent {
  protocol.EscalationEvent(record: escalation_view.view(record, seq))
}

// --- entry field access ----------------------------------------------------

/// Extracts the durable entry identifier string from a journal row.
fn entry_id_of(row: Entry) -> EntryId {
  case row {
    entry.MessageEntry(id:, ..) -> id
    entry.CompactionEntry(id:, ..) -> id
    entry.BranchSummaryEntry(id:, ..) -> id
    entry.CustomEntry(id:, ..) -> id
  }
}

/// Extracts the sequence ordinal number from a journal row.
fn entry_seq_of(row: Entry) -> Int {
  case row {
    entry.MessageEntry(seq:, ..) -> seq
    entry.CompactionEntry(seq:, ..) -> seq
    entry.BranchSummaryEntry(seq:, ..) -> seq
    entry.CustomEntry(seq:, ..) -> seq
  }
}

// --- display views of machine state ----------------------------------------

/// The display phase label of an operation state (protocol.md's open
/// label set; `op.state` stays the truth).
fn phase_of(state: operation.OperationState) -> String {
  case state {
    operation.RunState(control:, phase:, ..) ->
      case control, phase {
        operation.CancelRequested(..), _ -> "cancel_requested"
        operation.Running, operation.Starting -> "starting"
        operation.Running, operation.Checkpoint(..) -> "checkpoint"
        operation.Running, operation.Assistant(..) -> "assistant"
        operation.Running, operation.Tools(..) -> "tools"
        operation.Running, operation.Compacting(..) -> "compacting"
        operation.Running, operation.AwaitingDeferred(..) -> "awaiting_deferred"
        operation.Running, operation.FailureDrain(..) -> "failure_drain"
      }
    operation.CompactionState(control:, ..) ->
      case control {
        operation.CancelRequested(..) -> "cancel_requested"
        operation.Running -> "compacting"
      }
    operation.NavigationState(control:, ..) ->
      case control {
        operation.CancelRequested(..) -> "cancel_requested"
        operation.Running -> "navigating"
      }
  }
}

/// The strand_result view of a terminal result: operation id text,
/// status, and the error for failures.
fn result_view(
  last: operation.LastResult,
) -> #(String, String, Option(protocol.ResultError)) {
  // Evaluate control flow transition for result view.
  case last {
    operation.RunLastResult(operation: op, outcome:, ..) -> {
      let op = ids.op_id_to_string(op)

      // Handle asynchronous task execution outcome.
      case outcome {
        operation.RunCompleted(..) -> #(op, "done", None)
        operation.RunAborted -> #(op, "aborted", None)
        operation.RunFailed(error:) -> #(
          op,
          "failed",
          Some(protocol.ResultError(code: error.code, message: error.message)),
        )
      }
    }
    operation.CompactionLastResult(operation: op, outcome:, ..) ->
      structural_view(op, outcome)
    operation.NavigationLastResult(operation: op, outcome:, ..) ->
      structural_view(op, outcome)
  }
}

/// Renders a structural operation outcome into protocol result fields.
fn structural_view(
  op: OpId,
  outcome: operation.StructuralOutcome,
) -> #(String, String, Option(protocol.ResultError)) {
  let op = ids.op_id_to_string(op)

  // Handle asynchronous task execution outcome.
  case outcome {
    operation.StructuralCompleted -> #(op, "done", None)
    operation.StructuralDeclined -> #(op, "done", None)
    operation.StructuralAborted -> #(op, "aborted", None)
    operation.StructuralFailed(error:) -> #(
      op,
      "failed",
      Some(protocol.ResultError(code: error.code, message: error.message)),
    )
  }
}

// --- sending ---------------------------------------------------------------

// Broadcasts durable emits to every subscribed connection.
fn broadcast(state: State, emits: List(Emit)) -> Nil {
  broadcast_except(state, emits, -1, None)
}

/// Sends one event to one connection.
///
/// A network attachment splits on the *envelope*, not on the connection.
/// An envelope carrying a `reply_to` is the answer to a command and owes
/// that command's one reply capability its bounded response. An envelope
/// with none answers nothing — a notice, a delta, a roster, a fault — and
/// leaves through `deliver`, which runs the same per-frame `check_binding`
/// the reply path runs and retires the attachment when the answer changed
/// (`protocol-change/018`). The explicitly admitted worktree completion uses
/// `push_worktree` after its pending acknowledgement has spent that capability.
fn send_to(state: State, connection: Int, envelope: EventEnvelope) -> Nil {
  case dict.get(state.connections, connection) {
    Ok(link) ->
      case state.delivery, link.authentication, envelope.reply_to {
        Network, Authenticated(binding, check, close, _), Some(_) ->
          send_response(link.response, envelope, binding, check, close)
        Network, Authenticated(..), None
        | Network, HostFixture, _
        | HostOnly, _, _
        -> deliver(link, protocol.encode_event(envelope))
      }
    Error(Nil) -> Nil
  }
}

/// A network attachment has one reply capability, held only during its request.
/// Authorization is checked again at this last boundary before delivery.
fn send_response(response, envelope: EventEnvelope, binding, check, close) {
  // Process response payload.
  case response, envelope.reply_to {
    Some(response), Some(_) -> {
      let outcome = {
        use _ <- result.try(check_binding(binding, check))
        bounded_response(envelope)
      }
      process.send(response, outcome)

      // Handle asynchronous task execution outcome.
      case outcome {
        Error(_) -> close()
        Ok(_) -> Nil
      }
    }
    _, _ -> Nil
  }
}

/// Serializes an event envelope into a bounded JSON text response.
fn bounded_response(envelope: EventEnvelope) -> Result(String, String) {
  // Evaluate control flow transition for bounded response.
  let event = case envelope.event {
    protocol.EntryEvent(_) | protocol.OpTransitionEvent(..) ->
      mutation_outcome("admitted")
    protocol.SnapshotEvent(protocol.ConfigSnapshot(_)) ->
      mutation_outcome("committed")
    other -> other
  }

  let value = protocol.event_value(EventEnvelope(..envelope, event:))
  use _ <- result.try(transfer.encoded_size(value, 65_536))
  Ok(json.to_string(value))
}

fn mutation_outcome(status: String) -> WireEvent {
  protocol.MutationOutcome(json.Object([#("status", json.String(status))]))
}

/// Sends an asynchronous protocol reply event to a client connection.
fn reply(state: State, connection: Int, id: Int, event: WireEvent) -> Nil {
  send_to(
    state,
    connection,
    EventEnvelope(reply_to: Some(id), seq: None, event:),
  )
}

/// Each output batch resolves membership before entering the socket mailbox.
fn deliver(link: Connection, frame: String) {
  case link.authentication {
    HostFixture -> link.sink(frame)
    Authenticated(binding, check, close, _) ->
      case check_binding(binding, check) {
        Ok(_) -> link.sink(frame)
        Error(_) -> close()
      }
  }
}

/// Sends an error event reply with code and message to a client connection.
fn reply_error(
  state: State,
  connection: Int,
  id: Int,
  code: String,
  message: String,
) -> Nil {
  reply(
    state,
    connection,
    id,
    protocol.ErrorEvent(code:, message:, details: None),
  )
}

/// Deltas go to every subscribed connection under either delivery. Under
/// `Network` this is what makes a peer see an answer being generated
/// rather than the discontinuous snapshot sample; the text is clipped to
/// the same 24 KiB `preview_text` bound that sample uses, which is what
/// keeps a pushed frame under the reply ceiling without a second size
/// mechanism (`protocol-change/018`).
fn broadcast_delta(
  state: State,
  operation: OpId,
  generation: String,
  delta: Option(stream.Delta),
) -> Nil {
  let op_text = ids.op_id_to_string(operation)
  let strand = strand_of_operation(state, operation)

  // Extract the event delta payload kind and text.
  let event = case delta {
    Some(stream.TextDelta(index: _, text:)) ->
      protocol.StreamDeltaEvent(
        strand:,
        op: op_text,
        generation: Some(generation),
        kind: protocol.TextKind,
        text: Some(preview_text(text)),
        call_id: None,
        tool_name: None,
        arguments_fragment: None,
      )
    Some(stream.ThinkingDelta(index: _, thinking:)) ->
      protocol.StreamDeltaEvent(
        strand:,
        op: op_text,
        generation: Some(generation),
        kind: protocol.ThinkingKind,
        text: Some(preview_text(thinking)),
        call_id: None,
        tool_name: None,
        arguments_fragment: None,
      )
    Some(stream.ToolCallDelta(index: _, call_id:, name:, arguments_json:)) ->
      protocol.StreamDeltaEvent(
        strand:,
        op: op_text,
        generation: Some(generation),
        kind: protocol.ToolCallKind,
        text: None,
        call_id: Some(call_id),
        tool_name: Some(name),
        arguments_fragment: Some(preview_text(arguments_json)),
      )
    None ->
      protocol.StreamDeltaEvent(
        strand:,
        op: op_text,
        generation: Some(generation),
        kind: protocol.EndKind,
        text: None,
        call_id: None,
        tool_name: None,
        arguments_fragment: None,
      )
  }

  push_to_subscribed(state, event)
}

/// The rolling tail of a running tool call, to every subscribed peer
/// (`protocol-change/031`). Unlike a delta the text needs no clipping
/// here: the collector already bounded it at `tools/tool.tail_bytes`, a
/// sixth of the preview bound a pushed frame is held to.
fn broadcast_tool_output(
  state: State,
  strand: String,
  operation: OpId,
  step: String,
  source_index: Int,
  call_id: String,
  stream: bus.OutputStream,
  tail: String,
  total_bytes: Int,
) -> Nil {
  push_to_subscribed(
    state,
    protocol.ToolOutputEvent(
      strand:,
      op: ids.op_id_to_string(operation),
      step:,
      source_index:,
      call_id:,
      stream: case stream {
        bus.Stdout -> protocol.Stdout
        bus.Stderr -> protocol.Stderr
      },
      tail:,
      total_bytes:,
    ),
  )
}

/// The bus names a summary's subject in durable types; the wire names it in
/// text, the way every other pushed frame names entries and operations.
fn summary_subject(subject: bus.SummarySubject) -> protocol.SummarySubject {
  case subject {
    bus.SettledBlock(entry:, block:) ->
      protocol.SummarizedBlock(entry: ids.entry_id_to_string(entry), block:)
    bus.LiveStream(strand:, op:, generation:) ->
      protocol.SummarizedStream(
        strand:,
        op: ids.op_id_to_string(op),
        generation:,
      )
  }
}

/// The strand a provider operation runs on, for a pushed delta that does not
/// carry one. Tool output carries its authoritative `ToolRun.strand` through
/// the bus instead of using this presentation fallback.
fn strand_of_operation(state: State, operation: OpId) -> String {
  let op_text = ids.op_id_to_string(operation)

  // Evaluate control flow transition for strand of operation.
  case
    dict.to_list(state.live)
    |> list.find(fn(pair) { pair.1 == op_text })
  {
    Ok(#(strand, _)) -> strand
    Error(Nil) ->
      case session.op_meta(state.runtime.session, operation) {
        Ok(Some(session.Cell(value:, ..))) -> value.strand
        _ -> single_live_strand(state)
      }
  }
}

/// One unsolicited frame to every subscribed connection, under either
/// delivery. `deliver` re-checks each peer's authority as the frame
/// leaves, which is what makes a push a second way out of the hub without
/// being a second, unchecked one (`protocol-change/018`).
fn push_to_subscribed(state: State, event: WireEvent) -> Nil {
  let frame =
    protocol.encode_event(EventEnvelope(reply_to: None, seq: None, event:))
  dict.each(state.connections, fn(_id, link: Connection) {
    case link.subscription {
      Subscribed -> deliver(link, frame)
      Unsubscribed -> Nil
    }
  })
}

// --- command dispatch ------------------------------------------------------

/// The hub's own error-channel combinator: run `then` on success, or send
/// `id` an error frame built from the `(code, message)` failure and leave
/// `state` unchanged. Mirrors `machine/planner`'s `or_fault` and
/// `tools/tool`'s `or_outcome` — the shape a command handler's error arm
/// always was (`reply_error` then return `state`), pulled out so a chain
/// of fallible steps reads as a chain rather than a staircase.
///
/// ## Examples
///
/// ```gleam
/// // use record <- or_reply(find_escalation(state, id), state, connection, id)
/// ```
///
fn or_reply(
  result: Result(a, #(String, String)),
  state: State,
  connection: Int,
  id: Int,
  then: fn(a) -> State,
) -> State {
  // Evaluate operation result outcome.
  case result {
    Ok(value) -> then(value)
    Error(#(code, message)) -> {
      reply_error(state, connection, id, code, message)
      state
    }
  }
}

/// Parses wire text and dispatches a validated client request frame.
fn dispatch(state: State, connection: Int, text: String) -> State {
  // Validate and execute the protocol command against subscription permissions.
  case protocol.decode_command(text) {
    Error(protocol.MalformedFrame(report:)) -> {
      send_to(
        state,
        connection,
        EventEnvelope(
          reply_to: None,
          seq: None,
          event: protocol.ErrorEvent(
            code: protocol.code_bad_request,
            message: "malformed frame: expected " <> report.expected,
            details: None,
          ),
        ),
      )
      state
    }
    Error(protocol.BadEnvelope(reason:, id:)) -> {
      send_to(
        state,
        connection,
        EventEnvelope(
          reply_to: id,
          seq: None,
          event: protocol.ErrorEvent(
            code: protocol.code_bad_request,
            message: "bad envelope: expected " <> reason,
            details: None,
          ),
        ),
      )
      state
    }
    Error(protocol.BadBody(id:, cmd:, reason:)) -> {
      reply_error(
        state,
        connection,
        id,
        protocol.code_bad_request,
        cmd <> ": " <> reason,
      )
      state
    }
    Ok(protocol.CommandEnvelope(id:, command:)) ->
      run_command(state, connection, id, command)
  }
}

/// Worktree bytes require the current owner binding, independently of the
/// general read-only command classification. A trusted host fixture is local.
fn worktree_owner(state: State, connection: Int) -> Bool {
  case dict.get(state.connections, connection) {
    Ok(Connection(authentication: HostFixture, ..)) -> True
    Ok(Connection(authentication: Authenticated(binding, ..), ..)) ->
      binding.authority == access.Owner
    Error(Nil) -> False
  }
}

/// Starts an asynchronous worktree status diff observation for an authorized client.
fn begin_worktree(state: State, connection: Int, id: Int) -> State {
  use <- bool.lazy_guard(!worktree_owner(state, connection), fn() {
    reply_error(
      state,
      connection,
      id,
      "forbidden",
      "worktree observation requires the owner",
    )
    state
  })
  begin_observation(
    state,
    connection,
    id,
    WorktreeObservation,
    state.worktree_diff,
  )
}

/// Dispatches a side-channel query action on the specified strand.
fn side_query(
  state: State,
  connection: Int,
  id: Int,
  strand: String,
  action: btw_view.Action,
) -> State {
  use <- known_strand(state, connection, id, strand)

  // Evaluate control flow transition for side query.
  let answer = case state.btw {
    None -> Error("side queries are unavailable on this daemon")
    Some(name) -> btw.query(name, connection, strand, action)
  }

  // Evaluate control flow transition for side query.
  case answer {
    Ok(board) ->
      reply(
        state,
        connection,
        id,
        protocol.SnapshotEvent(protocol.BtwSnapshot(board)),
      )
    Error(reason) -> reply_error(state, connection, id, "btw_refused", reason)
  }

  state
}

/// Starts a context observation capture for the specified strand.
fn begin_context(
  state: State,
  connection: Int,
  id: Int,
  strand: String,
) -> State {
  use <- known_strand(state, connection, id, strand)
  let capture = option.map(state.context, fn(read) { fn() { read(strand) } })
  begin_observation(state, connection, id, ContextObservation, capture)
}

/// A page of a remote child's transcript, read in an observation's task: the
/// reader asks the other orchestrator, which may be slow or away, and the hub
/// answers `pending` at once and pushes the page or the failure when the task
/// reports. The child is named as the remote children list names it, and the
/// reader finds its stub, so a name that is not a child of this session is the
/// reader's refusal, not a read of anything.
fn begin_history(
  state: State,
  connection: Int,
  id: Int,
  child: String,
  before: Int,
) -> State {
  let capture =
    option.map(state.child_history, fn(read) { fn() { read(child, before) } })
  begin_observation(state, connection, id, HistoryObservation, capture)
}

/// Pushes the session's remote children to every subscribed connection when a
/// stub changes, reading the stubs in a weft run so a slow store cannot stall
/// the hub's turn.
fn broadcast_remote_children(state: State) -> Nil {
  let subscribed =
    dict.values(state.connections)
    |> list.filter(fn(link) { link.subscription == Subscribed })

  // Evaluate control flow transition for broadcast remote children.
  case subscribed {
    [] -> Nil
    links -> {
      let runtime = state.runtime
      let hub = process.self()
      let _witnessed: weft.Witnessed =
        weft.new([
          fn() {
            let event =
              protocol.SnapshotEvent(
                protocol.RemoteChildrenSnapshot(children: remote_agents(runtime)),
              )
            let frame =
              protocol.encode_event(EventEnvelope(
                reply_to: None,
                seq: None,
                event:,
              ))
            list.each(links, deliver(_, frame))
            Ok(Nil)
          },
        ])
        |> weft.deadline(remote_children_push_ms)
        |> weft.cancel_when_exits(hub)
        |> weft.start_witnessed
      Nil
    }
  }
}

/// The session's clock, the one the Agency stamps a glance's arrival and a
/// child's deadline with, so the ages and the liveness here are read on it.
fn remote_agents(runtime: api.Runtime) -> List(remote_agent.RemoteAgent) {
  // Evaluate control flow transition for remote agents.
  case remote_child.all(runtime) {
    Ok(kept) -> {
      let #(now, _clock) = clock.read(runtime.effects.clock)
      remote_child.agents(kept, now)
    }
    Error(_) -> []
  }
}

// How long the push to a new subscriber may spend reading the stubs, in
// milliseconds. The read is a display, so a store slow enough to pass it costs
// the strip until the next stub change and nothing else.
const remote_children_push_ms = 5000

/// Pushes the session's remote children to one connection that has just
/// subscribed, so its strip lists them before any stub changes. A session with
/// no remote child pushes nothing, which a client reads as none. The push is
/// order-free with the subscription's own reply.
///
/// The stubs are read in a weft run and not on the hub's turn. The read goes to
/// the session's store with no deadline of its own, and the subscription's
/// capture is answered by a later message to this mailbox: a stalled store held
/// here would keep the capture's in-band refusal from reaching the socket before
/// it gave up. The run delivers through `deliver`, which checks the binding as
/// every push does. A push read before a stub changed may land after the push
/// that change caused, and the next change corrects the strip.
fn push_remote_children(state: State, connection: Int) -> Nil {
  // Evaluate control flow transition for push remote children.
  case dict.get(state.connections, connection) {
    Error(Nil) -> Nil
    Ok(link) -> {
      let runtime = state.runtime
      let run =
        weft.new([fn() { Ok(deliver_remote_children(runtime, link)) }])
        |> weft.deadline(remote_children_push_ms)

      // Evaluate control flow transition for push remote children.
      let run = case link.consumer {
        Some(socket) -> weft.cancel_when_exits(run, socket)
        None -> run
      }

      let _witnessed: weft.Witnessed = weft.start_witnessed(run)
      Nil
    }
  }
}

/// The body of the subscriber's push, run apart from the hub.
fn deliver_remote_children(runtime: api.Runtime, link: Connection) -> Nil {
  // Evaluate control flow transition for deliver remote children.
  case remote_agents(runtime) {
    [] -> Nil
    children -> {
      let event =
        protocol.SnapshotEvent(protocol.RemoteChildrenSnapshot(children:))
      deliver(
        link,
        protocol.encode_event(EventEnvelope(reply_to: None, seq: None, event:)),
      )
    }
  }
}

/// Initiates an asynchronous background observation task via Weft.
fn begin_observation(
  state: State,
  connection: Int,
  id: Int,
  kind: ObservationKind,
  capture: Option(fn() -> Result(JsonValue, String)),
) -> State {
  use <- bool.lazy_guard(
    dict.has_key(state.observations, connection)
      || dict.size(state.observations) >= 2,
    fn() {
      reply_error(
        state,
        connection,
        id,
        "busy",
        "an observation is already running",
      )
      state
    },
  )

  // Evaluate control flow transition for begin observation.
  case capture, dict.get(state.connections, connection) {
    Some(capture), Ok(link) -> {
      let reports = process.new_subject()
      let run = weft.new([capture]) |> weft.deadline(14_000)

      // Evaluate control flow transition for begin observation.
      let run = case link.consumer {
        Some(socket) -> weft.cancel_when_exits(run, socket)
        None -> run
      }

      let _relay = weft.start_relayed(run, to: reports)
      let pending = PendingObservation(id, kind, reports, Capturing)
      send_to(
        state,
        connection,
        EventEnvelope(
          Some(id),
          None,
          observation_snapshot(
            kind,
            json.Object([
              #("status", json.String("pending")),
              #("request_id", json.Int(id)),
            ]),
          ),
        ),
      )
      State(
        ..state,
        observations: dict.insert(state.observations, connection, pending),
      )
    }
    None, _ | Some(_), Error(Nil) -> {
      reply_error(
        state,
        connection,
        id,
        "unavailable",
        "observation is unavailable",
      )
      state
    }
  }
}

/// Handles a completed background observation task result from Weft.
fn observation_reported(
  state: State,
  connection: Int,
  pulled: weft.Pulled(JsonValue, String),
) -> State {
  case dict.get(state.observations, connection) {
    Error(Nil) -> state
    Ok(pending) ->
      case pulled {
        weft.NotYet -> state
        weft.PulledOutcome(outcome:) -> {
          let board = observation_result(pending.request, outcome)
          let state =
            push_observation(
              state,
              connection,
              pending.request,
              pending.kind,
              board,
            )
          State(
            ..state,
            observations: dict.insert(
              state.observations,
              connection,
              PendingObservation(..pending, phase: Reported),
            ),
          )
        }
        weft.AllDelivered | weft.RunLost(..) -> {
          // Evaluate control flow transition for observation reported.
          let state = case pending.phase {
            Reported -> state
            Capturing ->
              push_observation(
                state,
                connection,
                pending.request,
                pending.kind,
                failed_observation(
                  pending.request,
                  "observation ended without a result",
                ),
              )
          }

          State(
            ..state,
            observations: dict.delete(state.observations, connection),
          )
        }
      }
  }
}

/// Formats an observation outcome into structured JSON output.
fn observation_result(
  id: Int,
  outcome: weft.Outcome(JsonValue, String),
) -> JsonValue {
  case outcome {
    weft.Completed(value: json.Object(fields), ..) ->
      json.Object([
        #("status", json.String("ready")),
        #("request_id", json.Int(id)),
        ..fields
      ])
    weft.Completed(..) -> failed_observation(id, "invalid observation")
    weft.Failed(error:, ..) -> failed_observation(id, error)
    weft.Abandoned(..) | weft.NeverStarted(..) ->
      failed_observation(id, "observation was cancelled or timed out")
    weft.Crashed(..)
    | weft.DrainProofLost(..)
    | weft.CancellationUnconfirmed(..) ->
      failed_observation(id, "observation failed")
  }
}

/// Constructs a standardized failure response JSON for an observation error.
fn failed_observation(id: Int, message: String) -> JsonValue {
  json.Object([
    #("status", json.String("failed")),
    #("request_id", json.Int(id)),
    #("code", json.String("unavailable")),
    #("message", json.String(string.slice(message, 0, 512))),
  ])
}

/// This completion is a bounded push to exactly the admitting connection. Its
/// board retains request identity; reply_to is absent because the synchronous
/// pending acknowledgement already consumed that request capability.
/// Revalidation precedes serialization and delivery checks again.
fn push_observation(
  state: State,
  connection: Int,
  id: Int,
  kind: ObservationKind,
  board: JsonValue,
) -> State {
  let state = revalidate(state, connection)
  use <- bool.guard(!observation_allowed(state, connection, kind), state)
  let envelope = EventEnvelope(None, None, observation_snapshot(kind, board))

  // Process response payload.
  case dict.get(state.connections, connection), bounded_response(envelope) {
    Ok(link), Ok(frame) -> deliver(link, frame)
    Ok(link), Error(_) -> {
      let fallback =
        EventEnvelope(
          None,
          None,
          observation_snapshot(
            kind,
            failed_observation(
              id,
              "observation response exceeds its byte limit",
            ),
          ),
        )
      deliver(link, protocol.encode_event(fallback))
    }
    Error(Nil), _ -> Nil
  }

  state
}

/// Reads active background job status for the specified strand.
fn read_live_jobs(
  state: State,
  connection: Int,
  id: Int,
  strand: String,
) -> State {
  // Handle asynchronous task execution outcome.
  let outcome = case state.live_jobs {
    Some(read) -> read(strand)
    None -> Error("live jobs are unavailable")
  }

  // Handle asynchronous task execution outcome.
  case outcome {
    Ok(board) ->
      send_to(
        state,
        connection,
        EventEnvelope(
          Some(id),
          None,
          protocol.SnapshotEvent(protocol.LiveJobsSnapshot(board)),
        ),
      )
    Error(reason) -> reply_error(state, connection, id, "unavailable", reason)
  }

  state
}

/// The advisor's queued nudges, read straight from the guard cell through the
/// bounded reader. There is no host capability to inject and no actor to ask:
/// the advisor actor owns the write side, and a read that went through it
/// could be made to drain a queue the primary's next run start is entitled to.
///
/// A malformed cell is `unavailable` rather than an empty board, because an
/// empty board asserts that the advisor has nothing waiting. A refused capture
/// is the server's own reader failing on the server's own budget, so it takes
/// the same path every other capture here takes.
/// The goal status read: the exact-key observation, never a call to the
/// actor. A read that spoke to the actor could not answer while it is
/// mid-review, and the panel wants the current state, not the next one.
fn read_goal(state: State, connection: Int, id: Int) -> State {
  case goal_pending.read(state.runtime.session, bootstrap.system_time_ms()) {
    Ok(board) -> {
      reply(
        state,
        connection,
        id,
        protocol.SnapshotEvent(protocol.GoalSnapshot(board)),
      )
      state
    }

    // A malformed cell is `unavailable` rather than an empty board: an
    // empty board is the positive claim that no goal is pinned, and an
    // unreadable cell is not evidence for it.
    Error(goal_pending.Malformed(reason:)) -> {
      reply_error(state, connection, id, "unavailable", reason)
      state
    }

    Error(goal_pending.Unreadable(error:)) ->
      reader_failed(state, connection, id, error)
  }
}

/// One goal mutation, answered with `committed` when the actor took it —
/// the reply protocol 044 §7 fixes — and refused worded when the seam is
/// absent: no advisor means no reviewer, and a goal without its judge is
/// not a state the operator can steer.
/// Catalogue transitions receive the binding that passed admission. They never
/// derive an actor or a role from candidate provenance or socket arguments.
fn evolution_command(
  state: State,
  connection: Int,
  id: Int,
  action: String,
  arguments: JsonValue,
) -> State {
  let outcome = {
    use seam <- result.try(
      state.evolution
      |> option.to_result("the evolution plane is unavailable"),
    )
    use link <- result.try(
      dict.get(state.connections, connection)
      |> result.replace_error("evolution connection is unavailable"),
    )

    // Inspect connection authentication credentials and binding authority.
    let #(authority, principal, via) = case link.authentication {
      Authenticated(binding, ..) -> #(
        evolution_control.for_principal(
          binding.authority,
          binding.principal.kind,
          action,
        ),
        binding.principal.id,
        evolution_via(binding, arguments),
      )
      HostFixture -> #(access.Owner, "host-fixture", evolution_store.Cli)
    }

    seam.command(authority, principal, via, action, arguments)
  }

  // Handle asynchronous task execution outcome.
  case outcome {
    Error(reason) ->
      reply_error(state, connection, id, protocol.code_bad_request, reason)
    Ok(board) ->
      reply(
        state,
        connection,
        id,
        protocol.SnapshotEvent(protocol.EvolutionSnapshot(board)),
      )
  }

  state
}

/// The surface an evolution command came through, for the audit entry. A page
/// is known first by the door that admitted it: an owner page opened by `loom
/// ui` has no sign-in and carries the terminal's bearer, so only the listener
/// can say it is a page. After that a sign-in or a browser credential also
/// marks a page, and the daemon reads all three from the binding. Every other
/// attachment is a bearer, and a terminal and the `loom evolution` command hold
/// the same kind of bearer, so the terminal says which it is in an optional
/// `via` argument. That claim is audit text only: it can name `terminal` or
/// `cli`, never `web`, and nothing reads it for authority.
fn evolution_via(
  binding: Binding,
  arguments: JsonValue,
) -> evolution_store.Via {
  case
    binding.door,
    binding.signin,
    access.credential_kind(binding.digest),
    tool.optional_string(arguments, "via")
  {
    PageDoor, _, _, _ -> evolution_store.Web
    SocketDoor, Some(_), _, _ | SocketDoor, None, access.Browser, _ ->
      evolution_store.Web
    SocketDoor, None, access.Bearer, Ok(Some("terminal")) ->
      evolution_store.Terminal
    SocketDoor, None, access.Bearer, Ok(Some(_))
    | SocketDoor, None, access.Bearer, Ok(None)
    | SocketDoor, None, access.Bearer, Error(_)
    -> evolution_store.Cli
  }
}

/// Dispatches goal tracking commands on the active session.
fn goal_command(
  state: State,
  connection: Int,
  id: Int,
  command: GoalCommand,
) -> State {
  // Evaluate control flow transition for goal command.
  case state.goal_control {
    None -> {
      reply_error(
        state,
        connection,
        id,
        "code_unsupported",
        "this server has no advisor routed, so there is no reviewer to judge a goal",
      )
      state
    }

    Some(seam) -> {
      // Validate and execute the protocol command against subscription permissions.
      let outcome = case command {
        GoalSet(objective:, token_budget:, check:) ->
          seam.set(objective, token_budget, check)
        GoalCheck(command:) -> seam.set_check(command)
        GoalClear -> seam.clear()
        GoalPause -> seam.pause()
        GoalResume -> seam.resume()
      }

      // Handle asynchronous task execution outcome.
      case outcome {
        // The actor's refusal is the operator's answer, worded for the
        // reader: a non-positive budget, a resume of a complete goal.
        Error(reason) -> {
          reply_error(state, connection, id, "bad_request", reason)
          state
        }

        // A committed mutation answers with the fresh goal board, the
        // `cancel_schedule` precedent: one round trip renders the
        // panel's new state rather than a second read.
        Ok(Nil) -> read_goal(state, connection, id)
      }
    }
  }
}

// The five mutations the dispatch arms carry, named as a type so the
// handler stays one function rather than five near-identical ones.
type GoalCommand {
  GoalSet(objective: String, token_budget: Int, check: Option(String))
  GoalCheck(command: Option(String))
  GoalClear
  GoalPause
  GoalResume
}

/// Queries pending advisor consultation requests for the active session.
fn read_advisor_pending(state: State, connection: Int, id: Int) -> State {
  // Evaluate control flow transition for read advisor pending.
  case advisor_pending.read(state.runtime.session, bootstrap.system_time_ms()) {
    Ok(board) -> {
      reply(
        state,
        connection,
        id,
        protocol.SnapshotEvent(protocol.AdvisorPendingSnapshot(board)),
      )
      state
    }

    Error(advisor_pending.Malformed(reason:)) -> {
      reply_error(state, connection, id, "unavailable", reason)
      state
    }

    Error(advisor_pending.Unreadable(error:)) ->
      reader_failed(state, connection, id, error)
  }
}

/// Exact-key reads of stored summarizer labels (protocol 050). The protocol
/// decoder has already bounded the list and checked every entry id, so the
/// read costs at most `max_summary_blocks` cells. A store that will not
/// answer is the reader's failure, handled as every other capture's is.
fn read_block_summaries(
  state: State,
  connection: Int,
  id: Int,
  blocks: List(protocol.SummaryBlock),
) -> State {
  let wanted = list.map(blocks, fn(block) { #(block.entry, block.block) })

  // Evaluate control flow transition for read block summaries.
  case blocksummary.read(state.runtime.session, wanted) {
    Ok(blocksummary.Read(board:, missing:)) -> {
      reply(
        state,
        connection,
        id,
        protocol.SnapshotEvent(protocol.BlockSummariesSnapshot(board)),
      )

      // The reply is only what is stored. A block with no summary is handed
      // to the summarizer afterwards, as a cast, so a block from a strand
      // that is not summarized as it commits can still be summarized when a
      // terminal shows it; the result arrives as an ordinary push.
      case state.summary_demand, missing {
        Some(demand), [_, ..] -> demand(missing)
        Some(_demand), [] | None, _ -> Nil
      }

      state
    }

    Error(error) -> reader_failed(state, connection, id, error)
  }
}

/// Executes a validated protocol command against session actor state.
fn run_command(
  state: State,
  connection: Int,
  id: Int,
  command: Command,
) -> State {
  use <- bool.lazy_guard(
    when: state.admission == Draining && !read_only(command),
    return: fn() {
      reply_error(
        state,
        connection,
        id,
        "draining",
        "the session is shutting down",
      )
      state
    },
  )

  use <- bool.lazy_guard(
    when: observer(state, connection) && !read_only(command),
    return: fn() {
      reply_error(
        state,
        connection,
        id,
        "forbidden",
        "observer attachments are read-only",
      )
      state
    },
  )

  // Remembering authority for the session, and seeing or removing what the
  // session remembers, are the owner's (protocol-change/073). A member who may
  // allow once or deny may not do these: the list names the owner's grants and
  // credentials, and a member could otherwise forget the owner's grants. This
  // is the gate; the page's own offer is only a convenience over it.
  use <- bool.lazy_guard(
    when: option.is_some(owner_only(command))
      && member_attached(state, connection),
    return: fn() {
      reply_error(
        state,
        connection,
        id,
        "forbidden",
        option.unwrap(owner_only(command), ""),
      )
      state
    },
  )

  // A connection that has gone away between admission and dispatch is treated
  // as unsubscribed, which refuses the command rather than acting on it.
  let subscription = case dict.get(state.connections, connection) {
    Ok(Connection(subscription:, ..)) -> subscription
    Error(Nil) -> Unsubscribed
  }

  // Validate and execute the protocol command against subscription permissions.
  case command, subscription {
    protocol.UnknownCommand(cmd:, ..), _ -> {
      reply_error(
        state,
        connection,
        id,
        protocol.code_unsupported,
        "unknown command: " <> cmd,
      )
      state
    }
    protocol.Subscribe(session:, from_seq:), Unsubscribed ->
      subscribe(state, connection, id, session, from_seq)
    protocol.Subscribe(..), Subscribed -> {
      reply_error(
        state,
        connection,
        id,
        protocol.code_conflict,
        "this connection is already subscribed",
      )
      state
    }
    _, Unsubscribed -> {
      reply_error(
        state,
        connection,
        id,
        protocol.code_bad_request,
        "subscribe before sending commands",
      )
      state
    }
    protocol.CatchUp(from_seq:), Subscribed -> {
      let state = pull_and_broadcast(state)
      replay(state, connection, id, from_seq)
      state
    }
    protocol.SnapshotNext(..), Subscribed
    | protocol.History(..), Subscribed
    | protocol.HistoryLineage(..), Subscribed
    | protocol.EscalationsGet(..), Subscribed
    | protocol.EscalationsDecided, Subscribed
    -> {
      reply_error(
        state,
        connection,
        id,
        protocol.code_unsupported,
        "bounded transfer requires the authenticated transport",
      )
      state
    }
    protocol.Prompt(strand:, text:), Subscribed ->
      prompt(state, connection, id, strand, text)
    protocol.PromptContent(strand:, content:), Subscribed ->
      prompt_content(state, connection, id, strand, content)
    protocol.Steer(strand:, text:), Subscribed ->
      steer(state, connection, id, strand, text)
    protocol.FollowUp(strand:, text:), Subscribed ->
      follow_up(state, connection, id, strand, text)
    protocol.WorktreeDiffGet, Subscribed ->
      begin_worktree(state, connection, id)
    protocol.Btw(strand:, action:), Subscribed ->
      side_query(state, connection, id, strand, action)
    protocol.ContextGet(strand:), Subscribed ->
      begin_context(state, connection, id, strand)
    protocol.ChildHistoryGet(child:, before:), Subscribed ->
      begin_history(state, connection, id, child, before)
    protocol.LiveJobsGet(strand:), Subscribed ->
      read_live_jobs(state, connection, id, strand)
    protocol.AdvisorPendingGet, Subscribed ->
      read_advisor_pending(state, connection, id)
    protocol.BlockSummariesGet(blocks:), Subscribed ->
      read_block_summaries(state, connection, id, blocks)
    protocol.GoalGet, Subscribed -> read_goal(state, connection, id)
    protocol.Evolution(action, arguments), Subscribed ->
      evolution_command(state, connection, id, action, arguments)
    protocol.GoalSet(objective:, token_budget:, check:), Subscribed ->
      goal_command(
        state,
        connection,
        id,
        GoalSet(objective:, token_budget:, check:),
      )
    protocol.GoalCheck(command:), Subscribed ->
      goal_command(state, connection, id, GoalCheck(command:))
    protocol.GoalClear, Subscribed ->
      goal_command(state, connection, id, GoalClear)
    protocol.GoalPause, Subscribed ->
      goal_command(state, connection, id, GoalPause)
    protocol.GoalResume, Subscribed ->
      goal_command(state, connection, id, GoalResume)
    protocol.QueuedInputGet(strand:, id: input_id), Subscribed ->
      read_queued_input(state, connection, id, strand, input_id)
    protocol.RemoveQueuedInput(strand:, id: input_id, expected_revision:),
      Subscribed
    ->
      remove_queued_input(
        state,
        connection,
        id,
        strand,
        input_id,
        expected_revision,
      )
    protocol.EditQueuedInput(strand:, id: input_id, expected_revision:, text:),
      Subscribed
    ->
      edit_queued_input(
        state,
        connection,
        id,
        strand,
        input_id,
        expected_revision,
        text,
      )
    protocol.Abort(strand:), Subscribed -> abort(state, connection, id, strand)
    protocol.Approve(escalation_id:, grants:, action:, expected_seq:),
      Subscribed
    ->
      approve(
        state,
        connection,
        id,
        escalation_id,
        grants,
        action,
        expected_seq,
        Once,
      )
    protocol.ApproveForSession(escalation_id:, grants:, action:, expected_seq:),
      Subscribed
    ->
      approve(
        state,
        connection,
        id,
        escalation_id,
        grants,
        action,
        expected_seq,
        ForSession,
      )
    protocol.Deny(escalation_id:, expected_seq:), Subscribed ->
      deny(state, connection, id, escalation_id, expected_seq)
    protocol.Fork(strand:, scope: _, name:), Subscribed ->
      fork(state, connection, id, strand, name)
    protocol.Navigate(strand:, to_entry:), Subscribed ->
      navigate(state, connection, id, strand, to_entry)
    protocol.Compact(strand:, instructions:), Subscribed ->
      compact(state, connection, id, strand, instructions)
    protocol.CreateStrand(name:), Subscribed ->
      create_strand(state, connection, id, name)
    protocol.ListModels, Subscribed -> list_models(state, connection, id)
    protocol.ListSkills(offset), Subscribed -> {
      use board <- or_reply(
        skills.page(state.skills, offset)
          |> result.map_error(fn(reason) {
            #(protocol.code_bad_request, reason)
          }),
        state,
        connection,
        id,
      )
      reply(
        state,
        connection,
        id,
        protocol.SnapshotEvent(protocol.SkillsSnapshot(board)),
      )
      state
    }
    protocol.NotesGet(strand), Subscribed ->
      read_notes(state, connection, id, strand)
    protocol.SetConfig(strand:, config:), Subscribed ->
      set_config(state, connection, id, strand, config)
    protocol.ProfileGet, Subscribed -> read_profile(state, connection, id)
    protocol.ProfileSet(profile:), Subscribed ->
      set_profile(state, connection, id, profile)
    protocol.ListSchedules, Subscribed -> list_schedules(state, connection, id)
    protocol.CancelSchedule(target:, name:), Subscribed ->
      cancel_schedule(state, connection, id, target, name)
    protocol.PermissionsGet, Subscribed ->
      list_permissions(state, connection, id)
    protocol.PermissionForget(target:, expected_seq:), Subscribed ->
      forget_permissions(state, connection, id, target, expected_seq)
    protocol.ProposalsGet, Subscribed -> list_proposals(state, connection, id)
    protocol.MemoryGet, Subscribed -> read_memory(state, connection, id)
    protocol.ProposalDecide(id: proposal, decision:), Subscribed ->
      decide_proposal(state, connection, id, proposal, decision)
  }
}

// --- subscribe, snapshots, replay ------------------------------------------

/// Subscribes a client connection to live session updates from an optional sequence.
fn subscribe(
  state: State,
  connection: Int,
  id: Int,
  session_name: String,
  from_seq: Option(Int),
) -> State {
  // Evaluate control flow transition for subscribe.
  let expected_session = case dict.get(state.connections, connection) {
    Ok(Connection(authentication: Authenticated(binding, ..), ..)) ->
      binding.session_id
    Ok(_) | Error(Nil) -> state.session_id
  }

  use <- bool.lazy_guard(when: session_name != expected_session, return: fn() {
    reply_error(
      state,
      connection,
      id,
      protocol.code_unknown_session,
      "this gateway serves session " <> state.session_id,
    )
    state
  })

  // Register subscription and notify presence across connections.
  let state = pull_and_broadcast(state)
  let state = mark_subscribed(state, connection)

  // Evaluate control flow transition for subscribe.
  case dict.get(state.connections, connection) {
    Ok(Connection(authentication: Authenticated(binding, _, _, _), origin:, ..)) -> {
      send_to(
        state,
        connection,
        EventEnvelope(
          None,
          None,
          protocol.AttachmentEvent(
            json.Object([
              #("session_id", json.String(binding.session_id)),
              #("epoch", json.String(binding.epoch)),
              #("incarnation", json.String(binding.incarnation)),
              #("connection_id", json.String(binding.connection_id)),
              #("origin", origin.encode(origin)),
              #("role", json.String(role_text(binding.authority))),
              #("peers", json.Array(roster(state))),
            ]),
          ),
        ),
      )
      publish_presence(state)
    }
    Ok(_) | Error(Nil) -> Nil
  }

  // Evaluate control flow transition for subscribe.
  case from_seq {
    Some(from) if from > 0 && from <= state.high_water + 1 -> {
      reply(
        state,
        connection,
        id,
        protocol.SnapshotEvent(protocol.ResumeSnapshot(
          next_seq: state.high_water + 1,
        )),
      )
      replay_events(state, connection, from)
      state
    }
    _ -> {
      reply(state, connection, id, connection_snapshot(state, connection))
      state
    }
  }
}

// A connection the hub no longer holds reads as subscribed, so that nothing
// is announced for it.
fn subscription_of(state: State, connection: Int) -> Subscription {
  dict.get(state.connections, connection)
  |> result.map(fn(link) { link.subscription })
  |> result.unwrap(Subscribed)
}

// Only the move from unsubscribed to subscribed is a join. A second
// `subscribe` on a subscribed network connection restarts its transfer and
// changes nothing about who is here, so it pushes nothing; announcing it
// would let any attachment, an observer included, make the hub push a roster
// to every peer, and every peer's lane catch up, once per request.
fn announce_join(state: State, before: Subscription) -> Nil {
  case before {
    Unsubscribed -> publish_presence(state)
    Subscribed -> Nil
  }
}

/// Marks a connection as active subscriber in gateway state.
fn mark_subscribed(state: State, connection: Int) -> State {
  case dict.get(state.connections, connection) {
    Error(Nil) -> state
    Ok(link) ->
      State(
        ..state,
        connections: dict.insert(
          state.connections,
          connection,
          Connection(..link, subscription: Subscribed),
        ),
      )
  }
}

/// `catch_up` on a subscribed connection: resume marker plus replay
/// (protocol.md open question 5: because event seqs are storage seqs,
/// this same path pages arbitrarily far back through the transcript).
fn replay(state: State, connection: Int, id: Int, from_seq: Int) -> Nil {
  // Evaluate control flow transition for replay.
  case from_seq > 0 && from_seq <= state.high_water + 1 {
    True -> {
      reply(
        state,
        connection,
        id,
        protocol.SnapshotEvent(protocol.ResumeSnapshot(
          next_seq: state.high_water + 1,
        )),
      )
      replay_events(state, connection, from_seq)
    }
    False ->
      reply(state, connection, id, connection_snapshot(state, connection))
  }
}

/// Rebuilds the durable events with `from_seq <= seq <= high_water` from
/// storage scans and current registers, and sends them in seq order.
fn replay_events(state: State, connection: Int, from_seq: Int) -> Nil {
  let store = state.runtime.session
  let strands = strand_names(state)
  let range_top = state.high_water
  let entry_emits = replay_entry_emits(state, strands, from_seq, range_top)
  let usage_emits = replay_usage_emits(state, strands, from_seq, range_top)
  let register_emits =
    replay_register_emits(store, strands, from_seq, range_top)
  let escalation_emits = replay_escalation_emits(state, from_seq, range_top)
  [entry_emits, usage_emits, register_emits, escalation_emits]
  |> list.flatten
  |> list.sort(fn(a, b) { int.compare(a.seq, b.seq) })
  |> dedupe_by_seq
  |> list.each(fn(emit) {
    send_to(
      state,
      connection,
      EventEnvelope(reply_to: None, seq: Some(emit.seq), event: emit.event),
    )
  })
}

/// Rebuilds entry events in `[from_seq, range_top]`, attributed from the
/// cache when known, otherwise located by branch membership.
fn replay_entry_emits(
  state: State,
  strands: List(String),
  from_seq: Int,
  range_top: Int,
) -> List(Emit) {
  case
    storage.scan_entries(
      state.runtime.session.store,
      storage.entry_scan()
        |> storage.entry_seq_range(Some(from_seq), Some(range_top)),
    )
  {
    Error(_) -> []
    Ok(rows) ->
      list.map(rows, fn(row) {
        let id_text = ids.entry_id_to_string(entry_id_of(row))

        // Evaluate control flow transition for replay entry emits.
        let strand = case dict.get(state.entry_strand, id_text) {
          Ok(attribution) -> entry_attribution_strand(attribution)
          Error(Nil) -> locate_entry(state, strands, entry_id_of(row))
        }

        entry_emit(strand, row)
      })
  }
}

/// Replays historical usage accounting events within the requested sequence range.
fn replay_usage_emits(
  state: State,
  strands: List(String),
  from_seq: Int,
  range_top: Int,
) -> List(Emit) {
  case
    storage.scan_usage(
      state.runtime.session.store,
      storage.usage_scan()
        |> storage.usage_seq_range(Some(from_seq), Some(range_top)),
    )
  {
    Error(_) -> []
    Ok(rows) -> list.map(rows, replay_usage_row(state, strands, _))
  }
}

/// Formats a single historical usage row as an emit event.
fn replay_usage_row(
  state: State,
  strands: List(String),
  row: UsageRow,
) -> Emit {
  // Evaluate control flow transition for replay usage row.
  let strand = case row.entry_id {
    Some(entry_id) ->
      case dict.get(state.entry_strand, ids.entry_id_to_string(entry_id)) {
        Ok(attribution) -> entry_attribution_strand(attribution)
        Error(Nil) -> locate_entry(state, strands, entry_id)
      }
    None -> single_live_strand(state)
  }

  Emit(
    seq: row.seq,
    event: protocol.UsageEvent(
      strand:,
      op: None,
      usage: row.usage,
      last_usage: last_row_usage(row),
    ),
    observation_strand: None,
  )
}

/// Register-backed events replay as current state at current seq.
fn replay_register_emits(
  store: session.Session,
  strands: List(String),
  from_seq: Int,
  range_top: Int,
) -> List(Emit) {
  list.flat_map(strands, fn(strand) {
    let op_emit = replay_op_transition(store, strand, from_seq, range_top)
    let result_emit = replay_strand_result(store, strand, from_seq, range_top)
    list.append(op_emit, result_emit)
  })
}

/// Replays operation lifecycle phase transitions within a sequence range.
fn replay_op_transition(
  store: session.Session,
  strand: String,
  from_seq: Int,
  range_top: Int,
) -> List(Emit) {
  case session.strand_state(store, strand) {
    Ok(Some(session.Cell(value:, ..))) ->
      case value.current_operation {
        Some(op) ->
          case session.op_state(store, op) {
            Ok(Some(session.Cell(value: op_state, seq:)))
              if seq >= from_seq && seq <= range_top
            -> [
              Emit(
                seq:,
                event: protocol.OpTransitionEvent(
                  op: ids.op_id_to_string(op),
                  strand:,
                  phase: phase_of(op_state),
                ),
                observation_strand: None,
              ),
            ]
            _ -> []
          }
        None -> []
      }
    _ -> []
  }
}

/// Replays strand terminal outcome results within a sequence range.
fn replay_strand_result(
  store: session.Session,
  strand: String,
  from_seq: Int,
  range_top: Int,
) -> List(Emit) {
  // Evaluate operation result outcome.
  case session.last_result(store, strand) {
    Ok(Some(session.Cell(value:, seq:)))
      if seq >= from_seq && seq <= range_top
    -> {
      let #(op, status, error) = result_view(value)
      [
        Emit(
          seq:,
          event: protocol.StrandResultEvent(strand:, op:, status:, error:),
          observation_strand: None,
        ),
      ]
    }
    _ -> []
  }
}

/// Replays permission escalation events within a sequence range.
fn replay_escalation_emits(
  state: State,
  from_seq: Int,
  range_top: Int,
) -> List(Emit) {
  list.append(
    replay_local_escalation_emits(state, from_seq, range_top),
    remote_escalation_events(state, fn(seq) {
      seq >= from_seq && seq <= range_top
    }),
  )
}

/// Replays local escalation events within a sequence range.
fn replay_local_escalation_emits(
  state: State,
  from_seq: Int,
  range_top: Int,
) -> List(Emit) {
  case
    storage.list_registers(
      state.runtime.session.store,
      register.FactCustom,
      Some(runtime_escalation.key_prefix),
    )
  {
    Error(_) -> []
    Ok(cells) ->
      list.filter_map(cells, fn(cell) {
        let #(_key, storage.Register(value:, seq:)) = cell

        // Evaluate control flow transition for replay local escalation emits.
        case seq >= from_seq && seq <= range_top {
          False -> Error(Nil)
          True ->
            case runtime_escalation.decode(value.payload) {
              Error(_) -> Error(Nil)
              Ok(record) ->
                Ok(Emit(
                  seq:,
                  event: escalation_event(record, seq),
                  observation_strand: None,
                ))
            }
        }
      })
  }
}

/// Attributes an entry outside the cache by branch membership.
fn locate_entry(
  state: State,
  strands: List(String),
  entry_id: EntryId,
) -> String {
  let store = state.runtime.session

  // Select target strand name, falling back to primary main strand.
  case list.find(strands, entry_in_branch(store, _, entry_id)) {
    Ok(strand) -> strand
    Error(Nil) ->
      case strands {
        [first, ..] -> first
        [] -> "main"
      }
  }
}

/// Whether `entry_id` sits on `strand`'s branch: its leaf's scan, stopped
/// at that id, actually reached it.
fn entry_in_branch(
  store: session.Session,
  strand: String,
  entry_id: EntryId,
) -> Bool {
  case session.strand_leaf(store, strand) {
    Ok(Some(session.Cell(value: Some(leaf), ..))) ->
      case
        storage.scan_branch(
          store.store,
          storage.branch_scan(from: leaf)
            |> storage.branch_stop_at_id(entry_id)
            |> storage.branch_limit(1),
        )
      {
        Ok([row]) -> entry_id_of(row) == entry_id
        _ -> False
      }
    _ -> False
  }
}

/// This legacy materializer remains unbounded. The bounded reader integration
/// replaces this seam; authentication alone does not establish transfer bounds.
fn connection_snapshot(state: State, connection: Int) -> WireEvent {
  // Evaluate control flow transition for connection snapshot.
  let session_id = case dict.get(state.connections, connection) {
    Ok(Connection(authentication: Authenticated(binding, ..), ..)) ->
      binding.session_id
    _ -> state.session_id
  }

  full_snapshot(State(..state, session_id:))
}

/// Compiles a complete full-state snapshot event for a newly subscribed client.
fn full_snapshot(state: State) -> WireEvent {
  let store = state.runtime.session
  let strands = list.map(strand_names(state), strand_view(store, _))
  let entries = recent_entries(state)
  let escalations = pending_escalations(state)

  // Evaluate control flow transition for full snapshot.
  let usage = case storage.stats(store.store) {
    Ok(storage.SessionStats(usage:, ..)) -> usage
    Error(_) -> accounting.unknown_usage(usage_evidence.Other)
  }

  protocol.SnapshotEvent(protocol.FullSnapshot(
    session: state.session_id,
    next_seq: state.high_water + 1,
    strands:,
    entries:,
    escalations:,
    usage:,
    remote_usage: remote_usage_of(state.runtime),
  ))
}

/// What the settled children on other orchestrators used, from the stubs of this
/// session, for the snapshot's `remote_usage`. Stubs that cannot be read give no
/// entries, which a client draws as no remote spend: the field is a display, and
/// the budgets that depend on the figure read the stubs themselves.
fn remote_usage_of(runtime: api.Runtime) -> List(remote_usage.RemoteUsage) {
  case remote_child.all(runtime) {
    Ok(kept) ->
      remote_child.usage_by_orchestrator(kept)
      |> list.map(fn(entry) {
        remote_usage.RemoteUsage(
          orchestrator: entry.0,
          input: entry.1.input,
          output: entry.1.output,
          cache_read: entry.1.cache_read,
          cache_write: entry.1.cache_write,
          cost: entry.1.cost,
        )
      })
    Error(_) -> []
  }
}

/// One strand's snapshot row: its leaf (as text) and its live operation,
/// when it has either.
fn strand_view(store: session.Session, strand: String) -> protocol.Strand {
  // Evaluate control flow transition for strand view.
  let leaf = case session.strand_leaf(store, strand) {
    Ok(Some(session.Cell(value: Some(leaf), ..))) ->
      Some(ids.entry_id_to_string(leaf))
    _ -> None
  }

  let live_op = strand_live_op(store, strand)
  Strand(id: strand, name: Some(strand), leaf:, live_op:)
}

/// Resolves active live operation details for a strand if running.
fn strand_live_op(
  store: session.Session,
  strand: String,
) -> Option(protocol.LiveOp) {
  case session.strand_state(store, strand) {
    Ok(Some(session.Cell(value:, ..))) ->
      // Read operation phase only when the strand currently owns an operation.
      case value.current_operation {
        Some(op) -> {
          // Missing operation state is reported as the starting phase.
          let phase = case session.op_state(store, op) {
            Ok(Some(session.Cell(value: op_state, ..))) -> phase_of(op_state)
            _ -> "starting"
          }

          Some(LiveOp(op: ids.op_id_to_string(op), phase:))
        }
        None -> None
      }

    _ -> None
  }
}

/// Queries recent transcript journal entries for the full state snapshot.
fn recent_entries(state: State) -> List(EntryRecord) {
  let store = state.runtime.session.store

  // Evaluate control flow transition for recent entries.
  case
    storage.scan_entries(
      store,
      storage.entry_scan()
        |> storage.entry_order(storage.NewestFirst)
        |> storage.entry_limit(state.recent_entries),
    )
  {
    Error(_) -> []
    Ok(rows) ->
      rows
      |> list.reverse
      |> list.map(fn(row) {
        let id_text = ids.entry_id_to_string(entry_id_of(row))

        // Evaluate control flow transition for recent entries.
        let strand = case dict.get(state.entry_strand, id_text) {
          Ok(attribution) -> entry_attribution_strand(attribution)
          Error(Nil) ->
            locate_entry(state, strand_names(state), entry_id_of(row))
        }

        EntryRecord(strand:, entry: row)
      })
  }
}

/// Queries all pending permission escalations across local and remote sources.
fn pending_escalations(state: State) -> List(protocol.EscalationRecord) {
  list.append(
    local_pending_escalations(state),
    case remote_escalation_store.all(state.runtime) {
      Ok(records) ->
        list.filter(records, fn(record) { record.status == "pending" })
      Error(_) -> []
    },
  )
}

/// Queries pending local permission escalations.
fn local_pending_escalations(state: State) -> List(protocol.EscalationRecord) {
  case api.escalations(state.runtime) {
    Error(_) -> []
    Ok(records) ->
      records
      |> list.filter(fn(record) { record.status == runtime_escalation.Pending })
      |> list.filter_map(fn(record) {
        use cell <- result.try(
          api.escalation_cell(state.runtime, record.id)
          |> result.replace_error(Nil),
        )
        Ok(escalation_view.view(cell.record, cell.seq))
      })
  }
}

// --- the conversational commands -------------------------------------------

fn strand_exists(state: State, strand: String) -> Bool {
  case session.strand_configuration(state.runtime.session, strand) {
    Ok(Some(_)) -> True
    _ -> False
  }
}

fn user_message(state: State, connection: Int, text: String) -> AgentMessage {
  content_message(state, connection, [
    message.UserText(text:, text_signature: None),
  ])
}

/// Formats a sequence of user content blocks into an agent input message.
fn content_message(
  state: State,
  connection: Int,
  content: List(UserBlock),
) -> AgentMessage {
  let #(now, _clock) = clock.read(state.runtime.effects.clock)
  message.UserMessage(
    content:,
    timestamp: now,
    origin: connection_origin(state, connection),
  )
}

/// Submits plain text prompt input to the specified strand.
fn prompt(
  state: State,
  connection: Int,
  id: Int,
  strand: String,
  text: String,
) -> State {
  prompt_message(
    state,
    connection,
    id,
    strand,
    user_message(state, connection, text),
  )
}

/// Submits structured content blocks as prompt input to the specified strand.
fn prompt_content(
  state: State,
  connection: Int,
  id: Int,
  strand: String,
  content: List(UserBlock),
) -> State {
  prompt_message(
    state,
    connection,
    id,
    strand,
    content_message(state, connection, content),
  )
}

/// Submits an agent message to a strand, managing input queues and runs.
fn prompt_message(
  state: State,
  connection: Int,
  id: Int,
  strand: String,
  prompt: AgentMessage,
) -> State {
  use <- known_strand(state, connection, id, strand)
  use expanded <- or_reply(
    skills.expand_message(state.skills, prompt)
      |> result.map_error(fn(reason) { #(protocol.code_bad_request, reason) }),
    state,
    connection,
    id,
  )

  // Durable retirement can precede its commit hint in this mailbox. A new
  // normal prompt must join existing custody even when the runtime is already
  // idle, or it would bypass a held steer and the ordinary FIFO behind it.
  use <- bool.lazy_guard(dict.has_key(state.held, strand), fn() {
    hold_prompt(state, connection, id, strand, expanded, prompt, AfterTurn)
    |> pull_and_broadcast
  })
  let target = api.on_strand(state.runtime, strand)
  let admitted = api.prompt(target, [expanded])

  // Evaluate control flow transition for prompt message.
  case admitted {
    // A busy strand is a scheduling question, not a conflict. Ordinary
    // prompts and follow-ups mean "next turn", and holding them lets two
    // peers submit inside one catch-up window without either being told
    // to try again. The built message is what is held, so the entry
    // commits under the origin recorded now rather than one resolved at
    // drain time.
    Error(api.AcceptRejected(reason: acceptance.StrandBusy)) ->
      hold_prompt(state, connection, id, strand, expanded, prompt, AfterTurn)

    Ok(_) | Error(_) -> {
      use _op <- or_reply(
        result.map_error(admitted, describe_api_error(_, strand)),
        state,
        connection,
        id,
      )

      // The subtitle comes from what the person typed, before a skill
      // expansion rewrote it, and only once the runtime has accepted it.
      let state = report_first_prompt(state, strand, prompt)
      reply_with_matched(state, connection, id, fn(emit) {
        case emit.event {
          protocol.EntryEvent(record: EntryRecord(strand: on, entry:)) ->
            on == strand && is_user_entry(entry)
          _ -> False
        }
      })
    }
  }
}

/// Puts one prompt at the tail of its strand's queue, or refuses the
/// submission when the queue is full. The bound is what keeps a strand
/// whose run never settles from accumulating unbounded hub memory, and the
/// refusal is the `conflict` the whole command answered with before this
/// existed — so a client that has not learned about `queued` still sees a
/// vocabulary it knows once the queue is deep.
fn hold_prompt(
  state: State,
  connection: Int,
  id: Int,
  strand: String,
  prompt: AgentMessage,
  typed: AgentMessage,
  order: InputOrder,
) -> State {
  use author <- or_reply(input_author(state, connection), state, connection, id)
  let queued = held_items(state, strand)
  let same_priority = list.filter(queued, fn(item) { item.order == order })

  // "Is it already full?" is a question about the bound, not about the
  // length, so it is answered by dropping one short of the bound and
  // asking whether anything is left: that walks four elements however
  // many there are. A queue of exactly four leaves one behind and is
  // full; a queue of three leaves none and has room.
  let over_bound = list.drop(same_priority, held_per_strand - 1) != []

  // The bound counts messages waiting for a run, and this one ends the
  // wait: a halted queue drains on the pull that follows the submission
  // joining it. Refusing here would make Escape-then-Enter the one
  // submission a full halted queue can never accept, and nothing else
  // reaches those messages — no command shortens a queue, and a halt ends
  // no other way.
  case over_bound && !halted_queue(state, strand) {
    True -> {
      reply_error(
        state,
        connection,
        id,
        protocol.code_conflict,
        "the strand is busy and its queue is full",
      )
      state
    }
    False -> {
      reply(state, connection, id, mutation_outcome("queued"))
      let item =
        Held(
          id: int.to_string(connection) <> ":" <> int.to_string(state.next_held),
          prompt:,
          typed:,
          submitter: connection,
          request: id,
          order:,
          author:,
          revision: 0,
        )

      // Evaluate control flow transition for hold prompt.
      let queue = case order {
        AfterTurn -> list.append(queued, [item])
        SteerNext -> {
          let #(steers, turns) =
            list.split_while(queued, fn(item) { item.order == SteerNext })
          list.append(steers, [item, ..turns])
        }
      }

      let state =
        put_held(State(..state, next_held: state.next_held + 1), strand, queue)
        |> release_halt(strand)

      // Custody transfers to the queue before cancellation is requested.
      // The abort can now settle without losing the message that caused it.
      case order {
        AfterTurn -> state
        SteerNext -> {
          stop_current(state, strand)
          pull_and_broadcast(state)
        }
      }
    }
  }
}

/// A client submission is the one event that ends an Escape's halt. The
/// queue it just joined drains as one batch, so the messages held when the
/// operator stopped the run and the message they typed afterwards reach the
/// successor together and in order. Any other drain mode is left alone: an
/// ordinary busy hold keeps draining one head at a time.
fn release_halt(state: State, strand: String) -> State {
  case dict.get(state.held, strand) {
    Ok(HeldQueue(drain: Halted, ..) as queue) ->
      State(
        ..state,
        held: dict.insert(
          state.held,
          strand,
          HeldQueue(..queue, drain: AllHeld),
        ),
      )
    Ok(HeldQueue(drain: OnlyHead, ..))
    | Ok(HeldQueue(drain: AllHeld, ..))
    | Error(Nil) -> state
  }
}

/// Whether the strand is holding input that an abort halted. Its one caller
/// is the queue bound, which a release is exempt from.
fn halted_queue(state: State, strand: String) -> Bool {
  case dict.get(state.held, strand) {
    Ok(HeldQueue(drain: Halted, ..)) -> True
    Ok(HeldQueue(drain: OnlyHead, ..))
    | Ok(HeldQueue(drain: AllHeld, ..))
    | Error(Nil) -> False
  }
}

fn held_items(state: State, strand: String) -> List(Held) {
  dict.get(state.held, strand)
  |> result.map(fn(queue) { queue.items })
  |> result.unwrap([])
}

/// Return every held prompt to its submitter and empty the queues.
///
/// The walk is over the dictionary rather than over the strands, because the
/// dictionary *is* the set of strands holding something — an emptied strand
/// leaves it, so no holder is visited twice and none is missed. Each item
/// goes to `item.submitter`, which is a connection id and not an identity:
/// a submitter that detached during the drain is an unknown connection and
/// `send_to` drops the frame, exactly as the rejection path already accepts
/// (see `Held.submitter`).
///
/// The queue is emptied wholesale rather than retired item by item. A later
/// `drain_idle_strands` must find nothing, and the batch intent of a halted
/// queue must not outlive the daemon it belonged to.
fn drain_held_queues(state: State) -> State {
  dict.each(state.held, fn(strand, queue) {
    list.each(queue.items, fn(item) {
      send_to(
        state,
        item.submitter,
        EventEnvelope(
          reply_to: None,
          seq: None,
          event: held_return(strand, item),
        ),
      )
    })
  })
  broadcast_queue_changed(State(..state, held: dict.new()))
}

// The one event that says the host queue changed, sent to every attached
// connection. Both mutations of the queue — a submission entering it and a
// drain emptying it — end with it, so a client that renders a queue learns
// from a push that its next read should be a read, never that a read it
// already has is still authoritative.
fn broadcast_queue_changed(state: State) -> State {
  dict.each(state.connections, fn(id, _link) {
    send_to(state, id, EventEnvelope(None, None, protocol.InputQueueChanged))
  })
  state
}

/// One held item as the custody return a client restores a draft from. The
/// kind is the item's own order, and the text is the *complete* submitted
/// text, unlike the queue-board preview: a draft restored from a clipped
/// prefix would silently lose what the operator typed. Image blocks cannot
/// travel as text, so the count says how many the client must keep beside the
/// draft it now owns again.
fn held_return(strand: String, item: Held) -> WireEvent {
  let #(text, images) = editable_content(item.prompt)
  protocol.HeldInputReturned(
    strand:,
    id: held_id(item),
    kind: order_text(item.order),
    text:,
    attachment_count: list.length(images),
  )
}

// The two priority names the wire uses for a held item, spelled once so the
// return and the queue board cannot disagree about them.
fn order_text(order: InputOrder) -> String {
  case order {
    AfterTurn -> "queue"
    SteerNext -> "steer"
  }
}

/// Updates the held input queue for a strand in gateway state.
fn put_held(state: State, strand: String, queue: List(Held)) -> State {
  // A replacement queue inherits the strand's existing drain intent, which is
  // what lets input submitted after an abort join the batch that abort marked.
  // The intent dies only with the dictionary entry, so a caller meaning
  // "install a fresh queue" must delete the strand's entry first.
  let drain =
    dict.get(state.held, strand)
    |> result.map(fn(existing) { existing.drain })
    |> result.unwrap(OnlyHead)

  // Evaluate control flow transition for put held.
  let state = case queue {
    // An emptied strand leaves the dictionary rather than sitting in it
    // as an empty list, so `drain_idle_strands` iterates over strands
    // that actually hold something.
    [] -> State(..state, held: dict.delete(state.held, strand))
    [_, ..] ->
      State(
        ..state,
        held: dict.insert(state.held, strand, HeldQueue(queue, drain)),
      )
  }

  broadcast_queue_changed(state)
}

/// These rows are queue identities, not guessed transcript matches. Two peers
/// may submit identical text; each row retires only when its own item drains.
fn pending_inputs(state: State, connection: Int) -> List(JsonValue) {
  dict.to_list(state.held)
  |> list.flat_map(fn(pair) {
    let #(strand, queue) = pair
    list.map(queue.items, fn(item) {
      let text = pending_text(item.prompt)
      let bytes = bit_array.from_string(text)
      json.Object([
        #("id", json.String(held_id(item))),
        #("strand", json.String(strand)),
        #("revision", json.Int(item.revision)),
        #(
          "editable",
          json.Bool(input_author(state, connection) == Ok(item.author)),
        ),
        #("kind", json.String(order_text(item.order))),
        #(
          "text",
          json.String(preview_prefix(
            bytes,
            int.min(bit_array.byte_size(bytes), 512),
            4,
          )),
        ),
      ])
    })
  })
}

/// The binding was revalidated at admission. Comparing its stable identity here
/// permits a reconnect by the original author without granting owner override.
fn input_author(
  state: State,
  connection: Int,
) -> Result(InputAuthor, #(String, String)) {
  case dict.get(state.connections, connection) {
    Ok(Connection(authentication: HostFixture, ..)) ->
      Ok(FixtureAuthor(connection))
    Ok(Connection(authentication: Authenticated(binding:, ..), ..)) ->
      case binding.authority {
        access.Owner | access.Participant(access.Operator) ->
          Ok(PrincipalAuthor(binding.principal.id, binding.principal.kind))
        access.Participant(access.Observer) ->
          Error(#(
            "forbidden",
            "only the original mutable principal may edit queued input",
          ))
      }
    Error(Nil) ->
      Error(#("forbidden", "queued input requires a live attachment"))
  }
}

fn held_id(item: Held) -> String {
  item.id
}

/// Retrieves a queued input entry for operator editing.
fn editable_input(
  state: State,
  connection: Int,
  strand: String,
  input_id: String,
) -> Result(Held, #(String, String)) {
  use author <- result.try(input_author(state, connection))
  use item <- result.try(
    held_items(state, strand)
    |> list.find(fn(item) { held_id(item) == input_id })
    |> result.replace_error(#(
      protocol.code_conflict,
      "input is no longer queued",
    )),
  )

  // Evaluate control flow transition for editable input.
  case item.author == author {
    True -> Ok(item)
    False ->
      Error(#(
        "forbidden",
        "only the original principal may edit this queued input",
      ))
  }
}

/// Only complete text crosses the editing boundary. Image payloads stay in the
/// queue and their count tells the editor what it will preserve on replacement.
fn queued_board(
  strand: String,
  item: Held,
) -> Result(JsonValue, #(String, String)) {
  let #(text, images) = editable_content(item.prompt)
  let board =
    json.Object([
      #("id", json.String(held_id(item))),
      #("strand", json.String(strand)),
      #("revision", json.Int(item.revision)),
      #("kind", json.String(order_text(item.order))),
      #("text", json.String(text)),
      #("attachment_count", json.Int(list.length(images))),
    ])

  // Evaluate control flow transition for queued board.
  case string.byte_size(protocol.to_wire_text(board)) <= 48_000 {
    True -> Ok(board)
    False ->
      Error(#(
        "queued_input_too_large",
        "complete queued text exceeds the editing reply budget",
      ))
  }
}

/// Extracts editable user blocks from a prompt message.
fn editable_content(prompt: AgentMessage) -> #(String, List(UserBlock)) {
  // Evaluate control flow transition for editable content.
  case prompt {
    message.UserMessage(content:, ..) -> {
      let text =
        content
        |> list.filter_map(fn(block) {
          case block {
            message.UserText(text:, ..) -> Ok(text)
            message.UserImage(..) -> Error(Nil)
          }
        })
        |> string.join("\n")
      let images =
        list.filter(content, fn(block) {
          case block {
            message.UserText(..) -> False
            message.UserImage(..) -> True
          }
        })
      #(text, images)
    }
    message.AssistantMessage(..)
    | message.ToolResultMessage(..)
    | message.CustomMessage(..) -> #("", [])
  }
}

/// Reads the contents of a queued input entry for a client request.
fn read_queued_input(
  state: State,
  connection: Int,
  id: Int,
  strand: String,
  input_id: String,
) -> State {
  use item <- or_reply(
    editable_input(state, connection, strand, input_id),
    state,
    connection,
    id,
  )
  use board <- or_reply(queued_board(strand, item), state, connection, id)
  reply(
    state,
    connection,
    id,
    protocol.SnapshotEvent(protocol.QueuedInputSnapshot(board)),
  )
  state
}

/// Withdrawal and drain are serialized by the gateway. An admitted identity
/// conflicts rather than cancelling running work or removing a different row.
fn remove_queued_input(
  state: State,
  connection: Int,
  id: Int,
  strand: String,
  input_id: String,
  expected_revision: Int,
) -> State {
  use item <- or_reply(
    editable_input(state, connection, strand, input_id),
    state,
    connection,
    id,
  )

  // Reject stale revisions before removing the input.
  use Nil <- or_reply(
    case item.revision == expected_revision {
      True -> Ok(Nil)
      False -> Error(#(protocol.code_conflict, "queued input revision changed"))
    },
    state,
    connection,
    id,
  )

  let state =
    put_held(
      state,
      strand,
      list.filter(held_items(state, strand), fn(candidate) {
        held_id(candidate) != input_id
      }),
    )
  reply(state, connection, id, mutation_outcome("removed"))
  state
}

/// The queue and revision are replaced in one gateway turn. A prior drain has
/// removed the identity and conflicts; an edit that wins keeps the exact slot.
fn edit_queued_input(
  state: State,
  connection: Int,
  id: Int,
  strand: String,
  input_id: String,
  expected_revision: Int,
  text: String,
) -> State {
  use item <- or_reply(
    editable_input(state, connection, strand, input_id),
    state,
    connection,
    id,
  )

  // Reject stale revisions before replacing the input.
  use Nil <- or_reply(
    case item.revision == expected_revision {
      True -> Ok(Nil)
      False -> Error(#(protocol.code_conflict, "queued input revision changed"))
    },
    state,
    connection,
    id,
  )

  let #(_, images) = editable_content(item.prompt)

  // Text blocks are deliberately consolidated. Record update retains the
  // submitted timestamp and author, and image blocks retain all their fields.
  let prompt = case item.prompt {
    message.UserMessage(..) as original ->
      message.UserMessage(..original, content: [
        message.UserText(text, None),
        ..images
      ])
    other -> other
  }

  let updated =
    Held(..item, prompt:, typed: prompt, revision: item.revision + 1)
  use _board <- or_reply(queued_board(strand, updated), state, connection, id)
  let queue =
    held_items(state, strand)
    |> list.map(fn(candidate) {
      case held_id(candidate) == input_id {
        True -> updated
        False -> candidate
      }
    })
  let state = put_held(state, strand, queue)
  reply(state, connection, id, mutation_outcome("queued"))
  state
}

/// Extracts plain text representation from an agent prompt message.
fn pending_text(prompt: AgentMessage) -> String {
  case prompt {
    message.UserMessage(content:, ..) ->
      content
      |> list.filter_map(fn(block) {
        case block {
          message.UserText(text:, ..) -> Ok(text)
          message.UserImage(..) -> Ok("[image]")
        }
      })
      |> string.join("\n")
    message.AssistantMessage(..)
    | message.ToolResultMessage(..)
    | message.CustomMessage(..) -> ""
  }
}

/// Every strand holding prompts whose live operation has gone. The caller
/// has just replaced `state.live` from the registers, so "idle" is a
/// lookup rather than a diff of two pulls: a strand whose successor
/// operation is already open reads as busy and stays held.
fn drain_idle_strands(state: State) -> State {
  use <- bool.lazy_guard(when: state.admission == Draining, return: fn() {
    state
  })

  list.fold(dict.keys(state.held), state, fn(state, strand) {
    case dict.has_key(state.live, strand) {
      True -> state
      False -> drain_strand(state, strand)
    }
  })
}

/// The queue owns whether this successor receives its head, every held
/// message, or nothing at all.
fn drain_strand(state: State, strand: String) -> State {
  case dict.get(state.held, strand) {
    Ok(HeldQueue(items: [head, ..tail] as items, drain:)) ->
      case drain {
        // An operator's Escape is waiting on the operator. The strand is
        // idle and stays idle; nothing here is admitted until a client
        // submission lifts the halt. Answering with the state rather than
        // an empty batch is what keeps the refusal arm below from
        // recursing on a queue it never shortens.
        Halted -> state

        OnlyHead -> admit_held(state, strand, [head], tail)
        AllHeld -> admit_held(state, strand, items, [])
      }
    Ok(HeldQueue(items: [], ..)) | Error(Nil) -> state
  }
}

/// Hands one batch to the runtime and keeps the remainder. The gateway
/// retains every member until the admission succeeds, so a refusal loses
/// nothing it had already acknowledged.
fn admit_held(
  state: State,
  strand: String,
  batch: List(Held),
  rest: List(Held),
) -> State {
  let target = api.on_strand(state.runtime, strand)

  // Evaluate control flow transition for admit held.
  case api.prompt(target, list.map(batch, fn(item) { item.prompt })) {
    // Original queue acknowledgements already transferred custody. Each
    // admitted message now reaches the peers through ordinary notices.
    Ok(_op) ->
      case batch {
        [first, ..] ->
          report_first_prompt(state, strand, first.typed)
          |> put_held(strand, rest)
        [] -> put_held(state, strand, rest)
      }

    // Another admission can win between the register read and this call.
    // Keep both the messages and their drain policy for the next retirement.
    Error(api.AcceptRejected(reason: acceptance.StrandBusy)) -> state

    // A rejected batch cannot wait for a transition it will never cause.
    // Report the rejection to each original submitter before retiring it.
    Error(refused) -> {
      let #(code, message) = describe_api_error(refused, strand)
      list.each(batch, fn(item) {
        send_to(
          state,
          item.submitter,
          EventEnvelope(
            reply_to: None,
            seq: None,
            event: protocol.ErrorEvent(code:, message:, details: None),
          ),
        )
      })
      drain_strand(put_held(state, strand, rest), strand)
    }
  }
}

// The strand a session's own conversation runs on, which is the one whose first
// prompt names the session.
const main_strand = "main"

/// Tells the host, once, what the first accepted human prompt on the main
/// strand said. The report is cleared before it is made, so a prompt accepted
/// while the callee is slow cannot be reported twice, and a message with no
/// text block (an image alone) leaves the report waiting for one that has text.
/// The callee returns at once: the catalogue write runs on the daemon's
/// registry, never on this hub's turn.
fn report_first_prompt(
  state: State,
  strand: String,
  prompt: AgentMessage,
) -> State {
  case state.first_prompt, strand == main_strand, prompt {
    Some(report), True, message.UserMessage(content:, ..) ->
      case list.find_map(content, first_text) {
        Ok(text) -> {
          report(text)
          State(..state, first_prompt: None)
        }
        Error(Nil) -> state
      }
    Some(_), False, _ | None, _, _ -> state
    Some(_), True, _ -> state
  }
}

fn first_text(block: UserBlock) -> Result(String, Nil) {
  case block {
    message.UserText(text:, ..) -> Ok(text)
    message.UserImage(..) -> Error(Nil)
  }
}

fn is_user_entry(row: Entry) -> Bool {
  case row {
    entry.MessageEntry(message: message.UserMessage(..), ..) -> True
    _ -> False
  }
}

/// Pulls, broadcasts, and replies with the *last* emit the matcher
/// accepts (carrying its seq); replies `internal` if nothing matched.
fn reply_with_matched(
  state: State,
  connection: Int,
  id: Int,
  matcher: fn(Emit) -> Bool,
) -> State {
  use <- bool.lazy_guard(state.delivery == Network, fn() {
    reply(state, connection, id, mutation_outcome("admitted"))
    state
  })
  let #(state, emits) = pull(state)
  let matched =
    list.fold(emits, None, fn(found, emit) {
      case matcher(emit) {
        True -> Some(emit)
        False -> found
      }
    })
  broadcast_except(state, emits, connection, matched)

  // Dispatch matching event envelope or return an internal error.
  case matched {
    Some(emit) ->
      send_to(
        state,
        connection,
        EventEnvelope(
          reply_to: Some(id),
          seq: Some(emit.seq),
          event: emit.event,
        ),
      )
    None ->
      reply_error(
        state,
        connection,
        id,
        protocol.code_internal,
        "the command committed but its event was not materialized",
      )
  }

  state
}

/// Broadcasts emits to all subscribed connections, except that the
/// issuing connection's copy of the matched emit is suppressed (it
/// arrives as the reply instead, with `reply_to` and the same seq).
fn broadcast_except(
  state: State,
  emits: List(Emit),
  connection: Int,
  matched: Option(Emit),
) -> Nil {
  list.each(emits, fn(emit) {
    let frame =
      protocol.encode_event(EventEnvelope(
        reply_to: None,
        seq: Some(emit.seq),
        event: emit.event,
      ))
    dict.each(state.connections, fn(link_id, link: Connection) {
      let suppressed = link_id == connection && Some(emit) == matched

      // Evaluate control flow transition for broadcast except.
      case link.subscription, suppressed {
        Subscribed, False -> deliver(link, frame)
        Subscribed, True | Unsubscribed, False | Unsubscribed, True -> Nil
      }
    })
  })
}

/// Continues for a known strand, or replies with an `unknown_strand` error
/// frame and leaves the gateway state unchanged. The failed lookup sends
/// a response, just as `or_reply` does; it is not a pure predicate.
///
/// ## Examples
///
/// ```gleam
/// // use <- known_strand(state, connection, id, strand)
/// ```
///
fn known_strand(
  state: State,
  connection: Int,
  id: Int,
  strand: String,
  continue: fn() -> State,
) -> State {
  // Evaluate control flow transition for known strand.
  case strand_exists(state, strand) {
    True -> continue()
    False -> {
      reply_error(
        state,
        connection,
        id,
        protocol.code_unknown_strand,
        "unknown strand: " <> strand,
      )
      state
    }
  }
}

/// Submits steering input to an active running strand operation.
fn steer(
  state: State,
  connection: Int,
  id: Int,
  strand: String,
  text: String,
) -> State {
  use <- known_strand(state, connection, id, strand)
  let typed = user_message(state, connection, text)
  use message <- or_reply(
    skills.expand_message(state.skills, typed)
      |> result.map_error(fn(reason) { #(protocol.code_bad_request, reason) }),
    state,
    connection,
    id,
  )
  hold_prompt(state, connection, id, strand, message, typed, SteerNext)
}

/// Follow-up is a queued turn. It belongs outside the current operation so
/// Escape and steering cannot discard it during that operation's abort drain.
fn follow_up(
  state: State,
  connection: Int,
  id: Int,
  strand: String,
  text: String,
) -> State {
  prompt(state, connection, id, strand, text)
}

/// A human control captures its target before sending any asynchronous work.
/// The runtime marker and broker sweep must refer to that same operation.
fn stop_current(state: State, strand: String) -> Nil {
  // Evaluate control flow transition for stop current.
  case session.strand_state(state.runtime.session, strand) {
    Ok(Some(session.Cell(
      value: machine_strand.StrandState(current_operation: Some(op), ..),
      ..,
    ))) -> {
      api.abort_operation(api.on_strand(state.runtime, strand), op)
      sweep_effects(state, op)
    }
    Ok(None) | Ok(Some(_)) | Error(_) -> Nil
  }
}

/// Requests immediate cancellation and abort of an active strand operation.
fn abort(state: State, connection: Int, id: Int, strand: String) -> State {
  use <- known_strand(state, connection, id, strand)

  // Evaluate control flow transition for abort.
  case session.strand_state(state.runtime.session, strand) {
    Ok(Some(session.Cell(
      value: machine_strand.StrandState(current_operation: Some(op), ..),
      ..,
    ))) -> {
      let state = abort_run(state, strand, op)

      // The durable cancel_requested transition broadcasts when its
      // commit lands; the ack is connection-scoped.
      reply(
        state,
        connection,
        id,
        protocol.OpTransitionEvent(
          op: ids.op_id_to_string(op),
          strand:,
          phase: "cancel_requested",
        ),
      )
      state
    }
    _ -> {
      reply_error(
        state,
        connection,
        id,
        protocol.code_conflict,
        "strand " <> strand <> " has no live operation to abort",
      )
      state
    }
  }
}

/// Asks the strand's run `op` to stop, as the operator's abort does and as a
/// spawner's page does for a session it started (protocol-change/094): the one
/// body, so the two cannot mean different things by stop.
fn abort_run(state: State, strand: String, op: OpId) -> State {
  // Halt existing custody before requesting cancellation. The queue
  // keeps every message it holds and starts nothing on the idle
  // transition that follows; a later client submission on this strand
  // joins it and releases the whole batch together (`release_halt`).
  let held =
    dict.get(state.held, strand)
    |> result.map(fn(queue) {
      dict.insert(state.held, strand, HeldQueue(..queue, drain: Halted))
    })
    |> result.unwrap(state.held)
  let state = State(..state, held:)
  api.abort_operation(api.on_strand(state.runtime, strand), op)

  // And the effect plane, which the runtime cannot address. Its
  // abort stops the strand's live effects — every effect the
  // operation is *waiting* on — while an execution the operation
  // merely started and detached from, a background job, runs under
  // a sibling step of the same operation and is nobody's live
  // effect. The broker keys its ledger on the operation for exactly
  // this, so the sweep here is what makes an operator's abort mean
  // what an operator means by it.
  sweep_effects(state, op)

  // And the advisor's goal loop, for the primary only: an aborted
  // run never reaches the run-end hook the advisor listens on, so
  // this cast is the one channel that tells it the operator stopped
  // a run it may have woken (protocol 044 §4). The actor gates the
  // notice on the runs it itself opened, so an abort of the
  // operator's own run is never read as a goal event.
  case strand == advisor.primary {
    True ->
      case state.goal_abort {
        None -> Nil
        Some(notice) -> notice(op)
      }

    False -> Nil
  }

  state
}

/// Stops the main strand's run for a spawner's page, if it has one. A strand
/// with no run is a stop that has nothing to do, not a conflict, because the
/// page cannot know that the run ended a moment ago.
fn stop_for_relayed(state: State) -> #(State, Result(Nil, Nil)) {
  case session.strand_state(state.runtime.session, advisor.primary) {
    Ok(Some(session.Cell(
      value: machine_strand.StrandState(current_operation: Some(op), ..),
      ..,
    ))) -> #(abort_run(state, advisor.primary, op), Ok(Nil))
    Ok(Some(_)) | Ok(None) -> #(state, Ok(Nil))
    Error(_) -> #(state, Error(Nil))
  }
}

// Tells the effect plane an operation was aborted, when this host has
// one. A host assembled without a broker — the demo, and every gateway
// fixture that scripts no effects — has nothing to sweep, and the abort
// is complete once the runtime has taken it.
fn sweep_effects(state: State, op: OpId) -> Nil {
  case state.effect_abort {
    None -> Nil
    Some(sweep) -> sweep(op)
  }
}

// --- escalations -----------------------------------------------------------

// Remembering authority is a separate explicit decision from allowing one call.
type ApprovalLifetime {
  Once
  ForSession
}

/// One approval, decided against one read.
///
/// An approval used to be a statement about a record id: `grants: None`
/// meant "whatever this record wants", resolved when the commit ran
/// (#72). A claim refreshes a pending record's denial from the call
/// that took the claim, so between the diff a human read and the diff
/// that got committed there was a mutable value and no check — a human
/// answering `wants: wall_s 60` could commit `wants: wall_s 600`.
///
/// So the client now says what it rendered, and this reads the record
/// **once** — the cell, carrying the seq of the write that put it there
/// — checks the echoed diff and the echoed action digest against that
/// value, and commits the approval CAS-guarded at that same seq. The
/// shared read is the whole mechanism, not a tidiness: a claim is
/// exactly the event that changes what a record wants, it bumps the
/// register seq when it lands, and a claim landing between the check
/// and the commit therefore loses the commit instead of passing unseen.
/// Read twice and the check would be about a record the commit never
/// touched.
fn approve(
  state: State,
  connection: Int,
  id: Int,
  escalation_id: String,
  echoed: List(Grant),
  action: String,
  expected_seq: Int,
  lifetime: ApprovalLifetime,
) -> State {
  use <- from_elsewhere(state, escalation_id, fn(record) {
    start_resolve(
      state,
      connection,
      id,
      record,
      remote_escalation.Approve(grants: echoed, action:, scope: case lifetime {
        Once -> remote_escalation.Once
        ForSession -> remote_escalation.Session
      }),
      expected_seq,
    )
  })
  use cell <- or_refuse(
    pending_escalation_cell(state, escalation_id, expected_seq),
    state,
    connection,
    id,
  )
  let api.EscalationCell(record:, seq:) = cell
  use wanted <- or_refuse(wanted_diff(record), state, connection, id)
  use Nil <- or_refuse(
    echo_matches(record, seq, wanted, echoed, action),
    state,
    connection,
    id,
  )
  use Nil <- or_refuse(
    commit_approval(state, connection, cell, echoed, lifetime),
    state,
    connection,
    id,
  )
  reply_with_committed(state, connection, id, fn(emit) {
    escalation_emitted(emit, escalation_id, "approved")
  })
}

/// Both decisions compare the exact question the client displayed. This point
/// read retains the sequence for the final CAS; a same-action reopen is a new
/// question even though its action digest has not changed.
fn pending_escalation_cell(
  state: State,
  escalation_id: String,
  expected_seq: Int,
) -> Result(api.EscalationCell, WireEvent) {
  use cell <- result.try(
    api.escalation_cell(state.runtime, escalation_id)
    |> result.map_error(fn(_error) {
      refusal(
        protocol.code_unknown_escalation,
        "unknown escalation: " <> escalation_id,
      )
    }),
  )
  use <- bool.lazy_guard(when: cell.seq != expected_seq, return: fn() {
    Error(stale_approval(
      cell.record,
      cell.seq,
      "the displayed question has changed",
    ))
  })
  use <- bool.lazy_guard(
    when: cell.record.status != runtime_escalation.Pending,
    return: fn() {
      Error(refusal(
        protocol.code_not_pending,
        "escalation "
          <> escalation_id
          <> " is "
          <> escalation_view.status_name(cell.record.status),
      ))
    },
  )
  Ok(cell)
}

/// Validates that requested permissions form a non-empty grant set.
fn wanted_diff(
  record: runtime_escalation.Escalation,
) -> Result(List(Grant), WireEvent) {
  grants.decode_denial(record.denial)
  |> result.map(fn(decoded) { decoded.wanted })
  |> result.map_error(fn(report) {
    refusal(
      protocol.code_internal,
      "the stored denial is unreadable: " <> report.expected,
    )
  })
}

/// Whether the answer is about the record in hand.
///
/// Two echoes, two different jobs. The action digest is the link this
/// series was missing: a spend-time check binds execution to what the
/// record held at approval, and this binds the record at approval to
/// what the human was shown. The diff is the older rule — a client may
/// narrow an approval below what was asked for and never widen it past
/// it — and it is a check on staleness for free, because a refreshed
/// denial names magnitudes the rendered one did not.
///
/// The narrowing direction stays legal on purpose: a record that has
/// come to want *more* than was rendered still approves, for exactly
/// the grants the human read and no others.
fn echo_matches(
  record: runtime_escalation.Escalation,
  seq: Int,
  wanted: List(Grant),
  echoed: List(Grant),
  action: String,
) -> Result(Nil, WireEvent) {
  use <- bool.lazy_guard(
    when: option.unwrap(record.action, "") != action,
    return: fn() {
      Error(stale_approval(
        record,
        seq,
        "the action this approval names is not the one the record now "
          <> "carries; the request changed between the prompt and the answer",
      ))
    },
  )

  // Evaluate control flow transition for echo matches.
  case grants.first_unwanted(echoed, wanted:) {
    None -> Ok(Nil)
    Some(_grant) ->
      Error(stale_approval(
        record,
        seq,
        "the approved grants are not a subset of the denial's wanted diff",
      ))
  }
}

/// The approval itself: written straight through the session's one
/// writer rather than through `api.approve_escalation`, which reads the
/// record again for itself and would leave the checks above standing on
/// a value the commit never saw.
fn commit_approval(
  state: State,
  connection: Int,
  cell: api.EscalationCell,
  echoed: List(Grant),
  lifetime: ApprovalLifetime,
) -> Result(Nil, WireEvent) {
  let author = connection_origin(state, connection)

  // Evaluate operation result outcome.
  use change <- result.try(case lifetime {
    Once -> Ok(None)
    ForSession ->
      permissions.remembering_action(
        state.runtime,
        cell.record,
        echoed,
        approval_provenance(state, connection),
      )
      |> result.map(Some)
      |> result.map_error(fn(reason) {
        refusal(protocol.code_bad_request, reason)
      })
  })

  // Evaluate control flow transition for commit approval.
  let committed = case change {
    None ->
      api.approve_escalation_at(
        state.runtime,
        cell,
        list.map(echoed, grants.encode),
        author,
      )
    Some(change) ->
      api.approve_escalation_with_fact_at(
        state.runtime,
        cell,
        list.map(echoed, grants.encode),
        author,
        change,
      )
  }

  // Evaluate control flow transition for commit approval.
  case committed {
    Ok(_) -> {
      let _ =
        escalate.notify_decision(state.runtime, cell, case lifetime {
          Once -> escalate.ApprovedOnce
          ForSession -> escalate.ApprovedForSession
        })
      Ok(Nil)
    }
    Error(api.RaceLost) -> Error(moved_under_the_answer(state, cell.record.id))
    Error(error) -> {
      let #(code, text) = describe_api_error(error, "")
      Error(refusal(code, text))
    }
  }
}

fn refusal(code: String, message: String) -> WireEvent {
  protocol.ErrorEvent(code:, message:, details: None)
}

/// A refusal that hands the record back, so the client re-renders the
/// prompt from the answer to its own command instead of waiting for a
/// pull to catch up.
fn stale_approval(
  record: runtime_escalation.Escalation,
  seq: Int,
  message: String,
) -> WireEvent {
  protocol.ErrorEvent(
    code: protocol.code_stale_approval,
    message:,
    details: Some(
      protocol.stale_approval_details(escalation_view.view(record, seq)),
    ),
  )
}

/// The same refusal after a lost compare-and-set, where the record in
/// hand is by definition the stale one and the fresh copy has to be
/// read again. A failed re-read leaves the client the code alone, which
/// still says the answer had no effect.
fn moved_under_the_answer(state: State, escalation_id: String) -> WireEvent {
  let message =
    "the escalation record changed while this approval was being committed"

  // Evaluate control flow transition for moved under the answer.
  case api.escalation_cell(state.runtime, escalation_id) {
    Ok(cell) -> stale_approval(cell.record, cell.seq, message)
    Error(_error) -> refusal(protocol.code_stale_approval, message)
  }
}

/// `or_reply`'s sibling for the escalation door, where a refusal may
/// carry the record it is about: the error side is a whole event rather
/// than a code and a message.
///
/// ```gleam
/// use cell <- or_refuse(pending_escalation_cell(..), state, conn, id)
/// ```
fn or_refuse(
  result: Result(a, WireEvent),
  state: State,
  connection: Int,
  id: Int,
  then: fn(a) -> State,
) -> State {
  // Evaluate operation result outcome.
  case result {
    Ok(value) -> then(value)
    Error(event) -> {
      reply(state, connection, id, event)
      state
    }
  }
}

/// Records an explicit operator denial for a pending permission escalation.
fn deny(
  state: State,
  connection: Int,
  id: Int,
  escalation_id: String,
  expected_seq: Int,
) -> State {
  use <- from_elsewhere(state, escalation_id, fn(record) {
    start_resolve(
      state,
      connection,
      id,
      record,
      remote_escalation.Deny,
      expected_seq,
    )
  })
  use cell <- or_refuse(
    pending_escalation_cell(state, escalation_id, expected_seq),
    state,
    connection,
    id,
  )
  let outcome =
    api.deny_escalation_at(
      state.runtime,
      cell,
      connection_origin(state, connection),
    )

  // Preserve a moved-state race as a distinct refusal from other API failures.
  use _record <- or_refuse(
    case outcome {
      Ok(record) -> Ok(record)
      Error(api.RaceLost) -> Error(moved_under_the_answer(state, escalation_id))
      Error(error) -> {
        let #(code, text) = describe_api_error(error, "")
        Error(refusal(code, text))
      }
    },
    state,
    connection,
    id,
  )

  let _ = escalate.notify_decision(state.runtime, cell, escalate.Denied)
  reply_with_committed(state, connection, id, fn(emit) {
    escalation_emitted(emit, escalation_id, "rejected")
  })
}

// --- requests of children on other orchestrators (protocol-change/089) ---------

/// A request filed from another orchestrator has an identity of the form
/// `<orchestrator>/<id there>`, and a local one never contains a slash. A decision
/// about a filed request is not committed here: the question belongs to the box,
/// which judges the decision and commits it. Anything else falls through to the
/// session's own records, which answer `unknown_escalation` for an identity they
/// do not hold.
fn from_elsewhere(
  state: State,
  escalation_id: String,
  elsewhere: fn(protocol.EscalationRecord) -> State,
  here: fn() -> State,
) -> State {
  case string.contains(escalation_id, "/") {
    False -> here()
    True ->
      case remote_escalation_store.find(state.runtime, escalation_id) {
        Ok(Some(record)) -> elsewhere(record)
        Ok(None) | Error(_) -> here()
      }
  }
}

/// A decision on a request that was filed from another orchestrator.
///
/// Everything the laptop can know is checked before the network is used: the
/// question is still the one displayed, the echoed action and grants are the
/// record's, and the grants are ones the box said its ceiling admits. The box
/// checks all of it again against its own record, because the laptop's copy is
/// only the last thing it heard.
///
/// The call to the box runs in a weft run that reports back, so this mailbox never
/// waits on the network. The socket's one reply capability is kept for it, as a
/// capture's is, and the answer leaves when the run reports.
fn start_resolve(
  state: State,
  connection: Int,
  id: Int,
  record: protocol.EscalationRecord,
  decision: remote_escalation.Decision,
  expected_seq: Int,
) -> State {
  let refuse = fn(code, text) {
    reply_error(state, connection, id, code, text)
    state
  }
  let stale = fn(text) {
    reply(
      state,
      connection,
      id,
      protocol.ErrorEvent(
        code: protocol.code_stale_approval,
        message: text,
        details: Some(protocol.stale_approval_details(record)),
      ),
    )
    state
  }

  // Handle lifecycle status transition.
  case record.status, record.seq == expected_seq {
    "pending", True ->
      case echo_matches_remote(record, decision) {
        Error(Stale(text)) -> stale(text)
        Error(Outside) ->
          refuse(
            protocol.code_bad_request,
            remote_escalation.outside_the_ceiling,
          )
        Ok(Nil) -> dispatch_resolve(state, connection, id, record, decision)
      }
    "pending", False -> stale("the displayed question has changed")
    status, _ ->
      refuse(
        protocol.code_not_pending,
        "escalation " <> record.escalation_id <> " is " <> status,
      )
  }
}

type RemoteEcho {
  Stale(reason: String)
  Outside
}

/// The laptop's half of the echo checks. An approval names the record's action
/// and a subset of what was asked for, and every grant it carries is one the box
/// said its ceiling admits. A record the box sent without an `admitted` list
/// admits nothing.
fn echo_matches_remote(
  record: protocol.EscalationRecord,
  decision: remote_escalation.Decision,
) -> Result(Nil, RemoteEcho) {
  // Evaluate control flow transition for echo matches remote.
  case decision {
    remote_escalation.Deny | remote_escalation.Forget(..) -> Ok(Nil)
    remote_escalation.Approve(grants: echoed, action:, ..) -> {
      // Evaluate control flow transition for echo matches remote.
      let wanted = case record.denial {
        Some(denial) -> denial.wanted
        None -> []
      }

      let admitted = option.unwrap(record.admitted, [])

      // Evaluate control flow transition for echo matches remote.
      case
        record.action != action,
        grants.first_unwanted(echoed, wanted:),
        grants.first_unwanted(echoed, wanted: admitted)
      {
        True, _, _ ->
          Error(Stale(
            "the action this approval names is not the one the request carries",
          ))
        False, Some(_), _ ->
          Error(Stale(
            "the approved grants are not a subset of what was asked for",
          ))
        False, None, Some(_) -> Error(Outside)
        False, None, None -> Ok(Nil)
      }
    }
  }
}

/// Sends the decision to the box in a run of its own and keeps the socket's reply
/// capability until the run reports.
fn dispatch_resolve(
  state: State,
  connection: Int,
  id: Int,
  record: protocol.EscalationRecord,
  decision: remote_escalation.Decision,
) -> State {
  let refuse = fn(text) {
    reply_error(state, connection, id, protocol.code_bad_request, text)
    state
  }
  let target = {
    use placement <- result.try(option.to_result(
      record.placement,
      "that request has no placement",
    ))
    use reach <- result.try(option.to_result(
      state.remote,
      "this session cannot reach another orchestrator",
    ))
    use operation <- result.try(
      ids.parse_op_id(record.op)
      |> result.replace_error("the request names no operation"),
    )

    // Resolve matching remote child entry for the targeted placement.
    use kept <- result.try(remote_child.all(state.runtime))
    use entry <- result.map(
      list.find(kept, fn(entry) {
        entry.stub.orchestrator == placement && entry.stub.name == record.strand
      })
      |> result.replace_error(
        "the child that asked is not one of this session's",
      ),
    )
    #(
      placement,
      reach,
      remote_spawn.Parent(session: reach.session, strand: entry.stub.strand),
      agent_tools.Handle(strand: record.strand, operation:),
    )
  }

  // Evaluate control flow transition for dispatch resolve.
  case target, dict.get(state.connections, connection) {
    Error(text), _ -> refuse(text)
    Ok(_), Error(Nil) -> state
    Ok(#(placement, reach, parent, child)), Ok(link) -> {
      // Evaluate control flow transition for dispatch resolve.
      let decider = case link.origin {
        Some(message.Origin(principal:, name:)) ->
          remote_escalation.Decider(principal:, name:)
        _ -> remote_escalation.Decider(principal: "host", name: "host")
      }

      let reports = process.new_subject()
      let run =
        weft.new([
          fn() {
            reach.resolve(
              placement,
              parent,
              child,
              remote_escalation.box_id(record.escalation_id),
              decision,
              record.seq,
              decider,
            )
          },
        ])
        |> weft.deadline(resolve_deadline_ms)

      // Evaluate control flow transition for dispatch resolve.
      let run = case link.consumer {
        Some(socket) -> weft.cancel_when_exits(run, socket)
        None -> run
      }

      // Start the relay and track pending resolve operation.
      let _relay = weft.start_relayed(run, to: reports)
      let pending =
        PendingResolve(
          connection:,
          request: id,
          response: link.response,
          placement:,
          reports:,
          progress: Awaiting,
        )
      State(
        ..state,
        resolves: dict.insert(state.resolves, state.next_resolve, pending),
        next_resolve: state.next_resolve + 1,
      )
    }
  }
}

// How long the box may take to answer a decision. The socket waits six seconds
// for its one reply, and the sending end gives the box four and a half.
const resolve_deadline_ms = 5500

// A decision on its way to the box. The entry stays selected until the run has
// said its last word, as a capture's does.
type PendingResolve {
  PendingResolve(
    connection: Int,
    request: Int,
    response: Option(Subject(Result(String, String))),
    placement: String,
    reports: Subject(weft.Pulled(remote_escalation.Answer, peer_mail.Failure)),
    progress: CaptureProgress,
  )
}

/// Handles a completed remote escalation resolution response from Weft.
fn resolve_reported(
  state: State,
  resolve: Int,
  pulled: weft.Pulled(remote_escalation.Answer, peer_mail.Failure),
) -> State {
  case dict.get(state.resolves, resolve) {
    Error(Nil) -> state
    Ok(pending) ->
      case pulled {
        weft.NotYet -> state
        weft.PulledOutcome(outcome:) -> {
          let state =
            State(
              ..state,
              resolves: dict.insert(
                state.resolves,
                resolve,
                PendingResolve(..pending, progress: Answered),
              ),
            )
          answer_resolve(state, pending, resolve_result(outcome))
        }
        weft.AllDelivered | weft.RunLost(..) -> {
          // Evaluate control flow transition for resolve reported.
          let state = case pending.progress {
            Answered -> state
            Awaiting ->
              answer_resolve(state, pending, Error(peer_mail.Unreachable))
          }

          State(..state, resolves: dict.delete(state.resolves, resolve))
        }
      }
  }
}

/// Extracts the answer result from a Weft remote escalation task outcome.
fn resolve_result(
  outcome: weft.Outcome(remote_escalation.Answer, peer_mail.Failure),
) -> Result(remote_escalation.Answer, peer_mail.Failure) {
  case outcome {
    weft.Completed(value:, ..) -> Ok(value)
    weft.Failed(error:, ..) -> Error(error)
    weft.Abandoned(..)
    | weft.NeverStarted(..)
    | weft.Crashed(..)
    | weft.DrainProofLost(..)
    | weft.CancellationUnconfirmed(..) -> Error(peer_mail.Unreachable)
  }
}

/// Answers the request that sent the decision. What the box said becomes what the
/// operator is told, and the record it sent back is filed at once, so that the
/// card changes without waiting for the box's own push.
fn answer_resolve(
  state: State,
  pending: PendingResolve,
  result: Result(remote_escalation.Answer, peer_mail.Failure),
) -> State {
  let tell = fn(state: State) {
    let say = fn(event) {
      reply(state, pending.connection, pending.request, event)
    }

    // Evaluate operation result outcome.
    case result {
      Ok(remote_escalation.Decided(record:)) -> {
        file_remote(state, pending.placement, record)
        say(mutation_outcome("committed"))
      }
      Ok(remote_escalation.Forgotten) -> say(mutation_outcome("committed"))
      Ok(remote_escalation.Stale(record:, reason:)) -> {
        file_remote(state, pending.placement, record)
        say(protocol.ErrorEvent(
          code: protocol.code_stale_approval,
          message: reason,
          details: Some(
            protocol.stale_approval_details(remote_escalation.placed(
              pending.placement,
              record,
            )),
          ),
        ))
      }
      Ok(remote_escalation.Refused(reason:))
      | Error(peer_mail.Refused(reason)) ->
        say(protocol.ErrorEvent(
          code: protocol.code_bad_request,
          message: reason,
          details: None,
        ))
      Error(peer_mail.Unreachable) | Error(peer_mail.NotOpen) ->
        say(protocol.ErrorEvent(
          code: protocol.code_internal,
          message: "the orchestrator did not answer; the decision may not have been applied",
          details: None,
        ))
    }

    state
  }

  // Process response payload.
  case pending.response {
    Some(response) -> with_response(state, pending.connection, response, tell)
    None -> tell(state)
  }
}

/// Forwards an escalation record to a remote placement peer.
fn file_remote(
  state: State,
  placement: String,
  record: protocol.EscalationRecord,
) -> Nil {
  case remote_escalation_store.keep(state.runtime, placement, record) {
    Ok(Nil) | Error(_) -> Nil
  }
}

/// A spawner's operator's decision about a request in this delegate session. The
/// time is the session's own, for the provenance of a remembered grant.
fn decide_for_spawner(
  state: State,
  parent: remote_spawn.Parent,
  escalation_id: String,
  decision: remote_escalation.Decision,
  expected_seq: Int,
  decided_by: remote_escalation.Decider,
) -> Result(remote_escalation.Answer, String) {
  // Evaluate control flow transition for decide for spawner.
  case state.spawner {
    None ->
      Ok(remote_escalation.Refused(
        reason: "this session takes no decision from a spawner",
      ))
    Some(link) -> {
      let #(now, _clock) = clock.read(state.runtime.effects.clock)
      remote_decision.admit(
        state.runtime,
        link,
        parent,
        escalation_id,
        decision,
        expected_seq,
        decided_by,
        now,
      )
    }
  }
}

/// Checks whether an escalation event matches a specific target ID and status.
fn escalation_emitted(
  emit: Emit,
  escalation_id: String,
  status: String,
) -> Bool {
  case emit.event {
    protocol.EscalationEvent(record:) ->
      record.escalation_id == escalation_id && record.status == status
    _ -> False
  }
}

/// A decision acknowledgement follows its exact-cell CAS, unlike a prompt's
/// admission acknowledgement. The credited cut carries the durable result.
fn reply_with_committed(state: State, connection, id, matcher) {
  // Decide whether delivery mode is restricted to host-only or network-enabled.
  case state.delivery {
    Network -> {
      reply(state, connection, id, mutation_outcome("committed"))
      state
    }
    HostOnly -> reply_with_matched(state, connection, id, matcher)
  }
}

/// Creates a new conversation branch forking from the current session tree.
fn fork(
  state: State,
  connection: Int,
  id: Int,
  strand: String,
  name: Option(String),
) -> State {
  use <- known_strand(state, connection, id, strand)
  let store = state.runtime.session

  // Evaluate control flow transition for fork.
  let configuration = case session.strand_configuration(store, strand) {
    Ok(Some(session.Cell(value:, ..))) -> Some(value)
    _ -> None
  }

  // Evaluate control flow transition for fork.
  let leaf = case session.strand_leaf(store, strand) {
    Ok(Some(session.Cell(value:, ..))) -> value
    _ -> None
  }

  use configuration <- or_reply(
    option.to_result(configuration, #(
      protocol.code_internal,
      "the source strand's configuration is unreadable",
    )),
    state,
    connection,
    id,
  )
  let new_name =
    unique_name(state, case name {
      Some(name) -> name
      None -> strand <> "-fork"
    })
  seed_and_reply(state, connection, id, new_name, configuration, leaf)
}

/// Creates and initializes a new strand in the resident session.
fn create_strand(
  state: State,
  connection: Int,
  id: Int,
  name: Option(String),
) -> State {
  let strands = strand_names(state)

  // Evaluate control flow transition for create strand.
  let configuration = case
    session.strand_configuration(state.runtime.session, "main")
  {
    Ok(Some(session.Cell(value:, ..))) -> Some(value)
    _ ->
      case strands {
        [first, ..] ->
          case session.strand_configuration(state.runtime.session, first) {
            Ok(Some(session.Cell(value:, ..))) -> Some(value)
            _ -> None
          }
        [] -> None
      }
  }

  use configuration <- or_reply(
    option.to_result(configuration, #(
      protocol.code_internal,
      "no existing strand to copy a configuration from",
    )),
    state,
    connection,
    id,
  )
  let new_name =
    unique_name(state, case name {
      Some(name) -> name
      None -> "strand-" <> int.to_string(list.length(strands) + 1)
    })
  seed_and_reply(state, connection, id, new_name, configuration, None)
}

/// Generates a non-conflicting unique strand name based on existing names.
fn unique_name(state: State, wanted: String) -> String {
  let existing = strand_names(state)

  // Evaluate control flow transition for unique name.
  case list.contains(existing, wanted) {
    False -> wanted
    True -> unique_name_loop(existing, wanted, 2)
  }
}

/// Recursively increments a numeric suffix to find an untaken strand name.
fn unique_name_loop(existing: List(String), base: String, n: Int) -> String {
  let candidate = base <> "-" <> int.to_string(n)

  // Evaluate control flow transition for unique name loop.
  case list.contains(existing, candidate) {
    False -> candidate
    True -> unique_name_loop(existing, base, n + 1)
  }
}

/// Seeds a briefless strand (the api's `create_strand` always accepts a
/// task-brief run; protocol fork/create_strand make idle strands) through
/// `api.create_idle_strand`: the same three-register CAS-guarded commit
/// the api's own `create_strand` seeds with, then the driver via the
/// factory — just without a brief run accepted on top.
fn seed_and_reply(
  state: State,
  connection: Int,
  id: Int,
  name: String,
  copied: machine_strand.StrandConfiguration,
  leaf: Option(EntryId),
) -> State {
  let configuration = seeded_thinking(state, copied)

  // Evaluate control flow transition for seed and reply.
  case
    api.create_idle_strand(state.runtime, named: name, configuration:, at: leaf)
  {
    Error(api.StrandExists(name:)) -> {
      reply_error(
        state,
        connection,
        id,
        protocol.code_conflict,
        "a strand named " <> name <> " already exists",
      )
      state
    }
    Error(api.InvalidStrandName(name:)) -> {
      reply_error(
        state,
        connection,
        id,
        protocol.code_bad_request,
        "the strand name "
          <> name
          <> " is reserved; choose a name that does not begin with ^",
      )
      state
    }
    Error(api.UnknownForkPoint(..))
    | Error(api.SeedFailed(..))
    | Error(api.BriefRejected(..)) -> {
      reply_error(
        state,
        connection,
        id,
        protocol.code_internal,
        "seeding the strand failed",
      )
      state
    }

    // The registers are durable; the booter starts the driver on the
    // next tree boot even if `start_driver` could not right now. Report
    // nothing in-band — the strand exists (mirrors `create_strand`'s own
    // seed-then-start split: a start failure never unwinds a seed that
    // already landed).
    Ok(Nil) | Error(api.StartFailed(..)) -> {
      let state = pull_and_broadcast(state)
      reply(state, connection, id, strands_snapshot(state))
      state
    }
  }
}

/// A seeded strand's per-turn thinking level comes from the catalogue
/// entry its identity names — the entry in force for the model it will
/// dispatch to — and not from the level the source strand happened to be
/// sitting at when it was copied.
///
/// The two differ for a reason worth keeping: a strand's per-turn level is
/// a property of the conversation someone was having on it, raised or
/// lowered mid-run through `set_config`, while a *new* strand has had no
/// conversation yet. Seeding from the entry is the same rule `client/serve`
/// applies to `main` and `client/agency` applies to a spawned child, so all
/// three creation points agree. An identity the catalogue does not know —
/// or a hub serving no catalogue at all — keeps what was copied, because
/// there is nothing better to say.
fn seeded_thinking(
  state: State,
  configuration: machine_strand.StrandConfiguration,
) -> machine_strand.StrandConfiguration {
  case entry_in_force(state, configuration.model.provider) {
    Ok(entry) ->
      machine_strand.StrandConfiguration(
        ..configuration,
        thinking_level: wiring.strand_thinking_level(entry.thinking),
      )
    Error(Nil) -> configuration
  }
}

/// Compiles a snapshot event listing all active strands in the session.
fn strands_snapshot(state: State) -> WireEvent {
  use <- bool.lazy_guard(state.delivery == Network, fn() {
    mutation_outcome("committed")
  })

  // Evaluate control flow transition for strands snapshot.
  case full_snapshot(state) {
    protocol.SnapshotEvent(protocol.FullSnapshot(strands:, ..)) ->
      protocol.SnapshotEvent(protocol.StrandsSnapshot(strands:))
    other -> other
  }
}

// --- navigation and compaction ---------------------------------------------

/// Moves the session transcript pointer to the specified historical entry.
fn navigate(
  state: State,
  connection: Int,
  id: Int,
  strand: String,
  to_entry: String,
) -> State {
  use <- known_strand(state, connection, id, strand)
  use target <- or_reply(
    result.replace_error(ids.parse_entry_id(to_entry), #(
      protocol.code_bad_request,
      "to_entry is not an entry id",
    )),
    state,
    connection,
    id,
  )
  use op <- or_reply(
    result.map_error(
      api.navigate(
        api.on_strand(state.runtime, strand),
        to: Some(target),
        summarize: False,
        label: None,
        custom_instructions: None,
        preparation: None,
      ),
      describe_api_error(_, strand),
    ),
    state,
    connection,
    id,
  )

  // Unsummarized navigation involves no provider round-trip; wait
  // briefly so the reply's strand list shows the moved leaf.
  let _result =
    api.await_result(api.on_strand(state.runtime, strand), op, within_ms: 3000)
  let state = pull_and_broadcast(state)
  reply(state, connection, id, strands_snapshot(state))
  state
}

/// Requests compaction of historical context entries on the specified strand.
fn compact(
  state: State,
  connection: Int,
  id: Int,
  strand: String,
  instructions: Option(String),
) -> State {
  use <- known_strand(state, connection, id, strand)
  use op <- or_reply(
    result.map_error(
      api.compact(
        api.on_strand(state.runtime, strand),
        custom_instructions: instructions,
        preparation: compaction_preparation(state, strand),
      ),
      describe_api_error(_, strand),
    ),
    state,
    connection,
    id,
  )
  let op_text = ids.op_id_to_string(op)
  reply_with_matched(state, connection, id, fn(emit) {
    case emit.event {
      protocol.OpTransitionEvent(op: emitted, ..) -> emitted == op_text
      _ -> False
    }
  })
}

/// The compaction preparation a manual `compact` command summarizes
/// from: the strand's durable projection through the *same* builder the
/// threshold and overflow hooks use (`runtime/hooks.preparation`), so an
/// operator-requested compaction cuts where an automatic one cuts, keeps
/// what an automatic one keeps, and carries a previous summary forward
/// the same way. The run's own settings snapshot supplies the budget.
fn compaction_preparation(
  state: State,
  strand: String,
) -> Option(operation.StructuralPreparation) {
  let projected = hooks.project(state.runtime.session, strand)

  // Manual compaction has the same recall prerequisites as automatic cuts.
  // Enable source recovery before preparation so the committed tail, rather
  // than a later display-only projection, contains the exact references.
  let projected = case
    state.registered_tools,
    ids.parse_session_id(state.session_id),
    session.strand_configuration(state.runtime.session, strand)
  {
    Some(registry), Ok(session_id), Ok(Some(configuration)) ->
      case
        dict.has_key(registry, history.tool_name),
        list.contains(configuration.value.active_tool_names, history.tool_name)
      {
        True, True ->
          hooks.with_tool_references(
            projected,
            state.runtime.session,
            session_id,
          )
        _, _ -> projected
      }
    _, _, _ -> projected
  }

  let settings = state.runtime.settings.compaction

  // Evaluate control flow transition for compaction preparation.
  case
    hooks.preparation(
      projected,
      operation.CompactionSettings(..settings, enabled: True),
      hooks.estimate_message,
      tokens_before: hooks.context_tokens(projected, hooks.estimate_message),
    )
  {
    planner.Prepared(preparation:) -> Some(preparation)
    planner.EmptyPreparation -> None
  }
}

/// Shared with `describe_api_error`: an `AcceptRejected` carries one of
/// these, whether it came from `api.compact`, `api.navigate`, or a run
/// acceptance.
fn describe_reject(reason: acceptance.RejectReason) -> #(String, String) {
  case reason {
    acceptance.StrandBusy -> #(
      protocol.code_conflict,
      "the strand already has a live operation",
    )
    acceptance.InvalidMessage(reason:) -> #(protocol.code_bad_request, reason)
    acceptance.NothingToCompact -> #(
      protocol.code_conflict,
      session_wire.nothing_to_compact_message,
    )
    acceptance.InvalidNavigation(reason:) -> #(
      protocol.code_bad_request,
      reason,
    )
    acceptance.UnknownTarget -> #(
      protocol.code_bad_request,
      "the navigation target does not exist",
    )
    acceptance.QueueCorruption(report:) -> #(
      protocol.code_internal,
      "queue corruption: " <> report.expected,
    )
  }
}

// --- the model catalogue ---------------------------------------------------

/// `models`: the catalogue as a `models` snapshot. A hub without a
/// configured catalogue answers an empty listing — the honest shape for
/// "there is nothing to pick from", and the same reply a client gets
/// either way, so it needs no special case.
/// Notes have an independent bounded read. A large board can refuse this
/// auxiliary view without making the conversation itself unreadable.
fn read_notes(state: State, connection: Int, id: Int, strand: String) -> State {
  use <- known_strand(state, connection, id, strand)

  // Evaluate control flow transition for read notes.
  case notes_view.read(state.runtime.session, strand) {
    Ok(board) -> {
      reply(
        state,
        connection,
        id,
        protocol.SnapshotEvent(protocol.NotesSnapshot(board)),
      )
      state
    }
    Error(snapshot.MetadataTooLarge) -> {
      reply_error(
        state,
        connection,
        id,
        "notes_too_large",
        "notes exceed the display budget; use agent_notes with a narrower prefix",
      )
      state
    }
    Error(error) -> reader_failed(state, connection, id, error)
  }
}

/// Queries available model configurations from the provider catalog.
fn list_models(state: State, connection: Int, id: Int) -> State {
  // Evaluate control flow transition for list models.
  let models = case state.catalog {
    None -> []
    Some(catalogue) -> catalog_listing(catalogue)
  }

  reply(
    state,
    connection,
    id,
    protocol.SnapshotEvent(protocol.ModelsSnapshot(models:)),
  )
  state
}

/// One wire row per catalogue entry: its identity facts plus which role
/// chains list it and which it currently heads (and therefore resolves
/// for — every catalogue entry is a registered provider).
fn catalog_listing(catalogue: catalog.Catalog) -> List(protocol.ModelInfo) {
  list.map(catalogue.models, fn(entry) {
    protocol.ModelInfo(
      name: entry.name,
      dialect: catalog.dialect_to_string(entry.dialect),
      model_id: entry.model_id,
      roles: catalog.routed_roles(catalogue, entry.name),
      active: catalog.active_roles(catalogue, entry.name),
    )
  })
}

// --- the model profile -----------------------------------------------------

/// `profile_get`: the profile this session routes its roles by, and the profile
/// names the configuration defines now, as a `profile` snapshot. The names are
/// read from the file at each request, so a profile added while the session runs
/// is offered at once.
fn read_profile(state: State, connection: Int, id: Int) -> State {
  use desk <- or_reply(profile_desk(state), state, connection, id)
  use names <- or_reply(
    desk.names() |> result.map_error(internal_failure),
    state,
    connection,
    id,
  )
  reply(
    state,
    connection,
    id,
    protocol.SnapshotEvent(protocol.ProfileSnapshot(
      current: desk.current,
      available: names,
      switched: None,
    )),
  )
  state
}

/// Resolves the model switching profile desk from gateway state.
fn profile_desk(
  state: State,
) -> Result(profile_switch.Desk, #(String, String)) {
  option.to_result(state.profile, #(
    protocol.code_unsupported,
    "this session has no daemon behind it, so it has no model profile to read"
      <> " or switch",
  ))
}

fn internal_failure(reason: String) -> #(String, String) {
  #(protocol.code_internal, reason)
}

/// `profile_set`: saves the profile, moves the strands that followed the old
/// profile's models to the new one's, answers, and only then starts the restart
/// that builds the new profile's gateway (`protocol-change/082`).
///
/// The order is what keeps every failure harmless. Nothing is written until the
/// new catalogue has loaded and the strands to move are known. The registration
/// is saved before any strand moves, so a refused save changes nothing. A strand
/// that is moved but whose restart then fails keeps working: a model that heads
/// no role of the saved profile is dispatched as exactly that model
/// (`wiring.request_target`), and the next open resolves the saved profile.
///
/// A running strand refuses the switch outright. The restart stops the session,
/// which would end the run and resume it, and a request in flight is not ours to
/// interrupt; the operator may wait for the run to settle or abort it.
fn set_profile(
  state: State,
  connection: Int,
  id: Int,
  profile: Option(String),
) -> State {
  use desk <- or_reply(profile_desk(state), state, connection, id)

  // The busy check reads `live`, which a pull brings up to date. A run admitted
  // a moment ago is in the store before it is in `live`, and a switch must not
  // miss it.
  let state = pull_and_broadcast(state)
  use <- bool.lazy_guard(when: profile == desk.current, return: fn() {
    read_profile(state, connection, id)
  })
  use <- bool.lazy_guard(when: !dict.is_empty(state.live), return: fn() {
    reply_error(
      state,
      connection,
      id,
      protocol.code_conflict,
      "a strand is running; wait for it to finish or abort it, then switch"
        <> " the profile",
    )
    state
  })
  use entering <- or_reply(
    desk.load(profile)
      |> result.map_error(fn(reason) { #(protocol.code_bad_request, reason) }),
    state,
    connection,
    id,
  )
  use names <- or_reply(
    desk.names() |> result.map_error(internal_failure),
    state,
    connection,
    id,
  )
  use leaving <- or_reply(
    option.to_result(state.catalog, #(
      protocol.code_unsupported,
      "no model catalogue is configured",
    )),
    state,
    connection,
    id,
  )
  use moves <- or_reply(
    retarget_moves(state, catalog.retargets(leaving, entering))
      |> result.map_error(internal_failure),
    state,
    connection,
    id,
  )
  use Nil <- or_reply(
    desk.save(profile)
      |> result.map_error(fn(reason) {
        #(protocol.code_internal, "the profile could not be saved: " <> reason)
      }),
    state,
    connection,
    id,
  )

  // Evaluate control flow transition for set profile.
  case apply_moves(state, moves, connection_origin(state, connection)) {
    Error(reason) -> {
      reply_error(
        state,
        connection,
        id,
        protocol.code_internal,
        "the profile was saved, but moving strands to its models failed: "
          <> reason
          <> "; they keep their models until the session is reopened",
      )
      state
    }
    Ok(moved) -> {
      reply(
        state,
        connection,
        id,
        protocol.SnapshotEvent(protocol.ProfileSnapshot(
          current: profile,
          available: names,
          switched: Some(list.length(moves)),
        )),
      )
      desk.restart()
      State(
        ..moved,
        profile: Some(profile_switch.Desk(..desk, current: profile)),
      )
    }
  }
}

/// The strands a switch moves, each with the model it moves to. A strand follows
/// a role while its stored model is the head of that role's chain under the
/// profile being left (`catalog.retargets`); one chosen by hand with `/model` is
/// not any role's head and is left where it is. Both conclusions come from the
/// stored model alone, because that is the only record of which it was.
fn retarget_moves(
  state: State,
  retargets: List(catalog.Retarget),
) -> Result(List(#(String, catalog.CatalogModel)), String) {
  list.try_fold(strand_names(state), [], fn(moves, strand) {
    use cell <- result.try(
      session.strand_configuration(state.runtime.session, strand)
      |> result.map_error(fn(_) { "configuration could not be read" }),
    )

    // Evaluate control flow transition for retarget moves.
    case cell {
      None -> Ok(moves)
      Some(session.Cell(value:, ..)) ->
        case followed_head(retargets, value.model) {
          Ok(entry) -> Ok([#(strand, entry), ..moves])
          Error(Nil) -> Ok(moves)
        }
    }
  })
  |> result.map(list.reverse)
}

/// The entry a strand holding `model` moves to, when `model` is a head that
/// moves. Retargets are in tie-break order, so a model that heads two roles
/// moves with the first.
fn followed_head(
  retargets: List(catalog.Retarget),
  model: machine_strand.ModelIdentity,
) -> Result(catalog.CatalogModel, Nil) {
  list.find(retargets, fn(retarget) {
    retarget.from.name == model.provider
    && retarget.from.model_id == model.model_id
  })
  |> result.map(fn(retarget) { retarget.to })
}

/// Writes the moved strands' models in one commit, by the path `set_config`
/// uses, seeding the new entry's thinking level when a strand still holds its
/// previous entry's seed and leaving an operator-chosen level alone.
fn apply_moves(
  state: State,
  moves: List(#(String, catalog.CatalogModel)),
  author: Option(message.Origin),
) -> Result(State, String) {
  use <- bool.guard(list.is_empty(moves), Ok(state))
  let change = fn(plan) {
    list.fold(moves, Ok(plan), fn(plan, move) {
      use plan <- result.try(plan)
      update_configuration(plan, move.0, switch_to_entry(state, _, move.1))
    })
  }
  apply_changes(state, None, [change], author)
  |> result.map(fn(applied) { applied.0 })
}

// --- the schedule listing --------------------------------------------------

/// `schedules`: every schedule this session holds, as a `schedules`
/// snapshot. A hub with no scheduling plane answers an empty listing on
/// the `models` posture — "there is nothing here" is the honest shape and
/// the same reply either way, so a client needs no special case. A plane
/// that is present but cannot be read is a different answer: that is a
/// failure to report, not an absence.
fn list_schedules(state: State, connection: Int, id: Int) -> State {
  // Evaluate control flow transition for list schedules.
  case state.schedules {
    None -> {
      reply(
        state,
        connection,
        id,
        protocol.SnapshotEvent(protocol.SchedulesSnapshot(schedules: [])),
      )
      state
    }
    Some(admin) ->
      case admin.list() {
        Error(reason) -> {
          reply_error(state, connection, id, protocol.code_internal, reason)
          state
        }
        Ok(rows) -> {
          reply(
            state,
            connection,
            id,
            protocol.SnapshotEvent(
              protocol.SchedulesSnapshot(schedules: list.map(rows, schedule_row)),
            ),
          )
          state
        }
      }
  }
}

/// `schedule_cancel`: retire one model-created schedule and answer with
/// the listing that remains, so a client re-renders from the one reply
/// rather than following a success with a second round trip. Unsupported
/// rather than an empty success when the host has no scheduling plane: a
/// cancellation that cancelled nothing must not read as one that worked.
fn cancel_schedule(
  state: State,
  connection: Int,
  id: Int,
  target: String,
  name: String,
) -> State {
  // Evaluate control flow transition for cancel schedule.
  case state.schedules {
    None -> {
      reply_error(
        state,
        connection,
        id,
        protocol.code_unsupported,
        "this server has no scheduling plane",
      )
      state
    }
    Some(admin) ->
      case admin.cancel(target, name) {
        Ok(Nil) -> list_schedules(state, connection, id)
        Error(scheduleadmin.NotFound) -> {
          reply_error(
            state,
            connection,
            id,
            protocol.code_bad_request,
            "no schedule named "
              <> name
              <> " fires onto "
              <> target
              <> "; only a schedule a strand created can be cancelled here",
          )
          state
        }

        // A conflict rather than a refusal about authority: the operator
        // may certainly end this schedule, and the file is where they do
        // it.
        Error(scheduleadmin.OperatorConfigured) -> {
          reply_error(
            state,
            connection,
            id,
            protocol.code_conflict,
            name
              <> " is an operator [[schedule]]: operator schedules are"
              <> " edited in the configuration file and take effect on"
              <> " restart",
          )
          state
        }
        Error(scheduleadmin.Unavailable(reason:)) -> {
          reply_error(state, connection, id, protocol.code_internal, reason)
          state
        }
      }
  }
}

// --- proposed rules (protocol-change/086) -----------------------------------

/// `proposals_get`: the queue's newest proposals and the pending count, as the
/// board `client/proposals` renders. An owner's read; a session on a host with
/// no queue answers unsupported rather than an empty list, because a person
/// asked to review proposals and there is nothing that could ever hold one.
fn list_proposals(state: State, connection: Int, id: Int) -> State {
  case state.proposals {
    None -> unsupported_proposals(state, connection, id)
    Some(admin) ->
      case admin.list() {
        Ok(listing) -> {
          reply(
            state,
            connection,
            id,
            protocol.SnapshotEvent(
              protocol.ProposalsSnapshot(board: proposals.board(listing)),
            ),
          )
          state
        }
        Error(reason) -> {
          reply_error(state, connection, id, protocol.code_internal, reason)
          state
        }
      }
  }
}

/// `proposal_decide`: settle one pending proposal and answer with the queue as
/// it now stands. A proposal the file has moved away from is not an error: it
/// comes back `stale` in the board, with nothing written. A proposal that was
/// decided already is a conflict, so a second approval of one proposal applies
/// nothing twice, and so is a queue another writer holds right now: the answer
/// says to decide again, and nothing was read or written.
fn decide_proposal(
  state: State,
  connection: Int,
  id: Int,
  proposal: String,
  decision: protocol.ProposalDecision,
) -> State {
  case state.proposals {
    None -> unsupported_proposals(state, connection, id)
    Some(admin) ->
      case admin.decide(proposal, proposal_verdict(decision)) {
        Ok(_settled) -> list_proposals(state, connection, id)
        Error(proposals.NoSuchProposal) -> {
          reply_error(
            state,
            connection,
            id,
            protocol.code_bad_request,
            "no proposal has the id " <> proposal,
          )
          state
        }
        Error(proposals.AlreadyDecided(state: decided)) -> {
          reply_error(
            state,
            connection,
            id,
            protocol.code_conflict,
            "the proposal was already decided: "
              <> proposals.state_name(decided),
          )
          state
        }
        Error(proposals.Busy(owner:)) -> {
          reply_error(
            state,
            connection,
            id,
            protocol.code_conflict,
            "the proposal queue is in use by "
              <> owner
              <> "; decide again in a moment",
          )
          state
        }
        Error(proposals.CannotApply(reason:)) -> {
          reply_error(state, connection, id, protocol.code_internal, reason)
          state
        }
        Error(proposals.Unavailable(reason:)) -> {
          reply_error(state, connection, id, protocol.code_internal, reason)
          state
        }
      }
  }
}

fn proposal_verdict(decision: protocol.ProposalDecision) -> proposals.Decision {
  case decision {
    protocol.ProposalApprove -> proposals.Approve
    protocol.ProposalReject -> proposals.Reject
  }
}

/// Returns a standardized error reply for unsupported standing proposals.
fn unsupported_proposals(state: State, connection: Int, id: Int) -> State {
  reply_error(
    state,
    connection,
    id,
    protocol.code_unsupported,
    "this server has no proposal queue",
  )
  state
}

// --- the memory overview (protocol-change/087) ------------------------------

/// `memory_get`: the overview as `client/memory_overview` reads it, one
/// snapshot. An owner's read. A host with no overview answers unsupported
/// rather than an empty board, because an empty board would read as "no notes".
/// The read takes no lease and never waits on a writer, so answering it here
/// cannot hold up the strand.
fn read_memory(state: State, connection: Int, id: Int) -> State {
  // Evaluate control flow transition for read memory.
  case state.memory_overview {
    None -> {
      reply_error(
        state,
        connection,
        id,
        protocol.code_unsupported,
        "this server keeps no memory overview",
      )
      state
    }
    Some(admin) -> {
      reply(
        state,
        connection,
        id,
        protocol.SnapshotEvent(
          protocol.MemorySnapshot(board: memory_overview.board(admin.read())),
        ),
      )
      state
    }
  }
}

// --- remembered permissions (protocol-change/073) --------------------------

/// `permissions`: everything the session remembers, with who approved it. An
/// observer never reaches this (`read_only` counts it with the mutations), so
/// the listing of principals and credentials goes only to a connection that
/// may approve.
fn list_permissions(state: State, connection: Int, id: Int) -> State {
  // Evaluate control flow transition for list permissions.
  case permissions.listing(state.runtime) {
    Ok(listing) -> {
      reply(
        state,
        connection,
        id,
        protocol.SnapshotEvent(
          protocol.PermissionsSnapshot(board: permissions.board(listing)),
        ),
      )
      state
    }
    Error(reason) -> {
      reply_error(state, connection, id, protocol.code_internal, reason)
      state
    }
  }
}

/// `permission_forget`: remove remembered permissions through the session's one
/// writer, in a single transaction guarded by the sequences the listing
/// carried, and answer with the listing that remains. A guard that fails writes
/// nothing and answers a conflict, so a permission added by another operator
/// since the list was drawn is never forgotten unseen; the client reads again
/// and the operator decides again.
fn forget_permissions(
  state: State,
  connection: Int,
  id: Int,
  target: protocol.ForgetTarget,
  expected_seq: Option(Int),
) -> State {
  let forgotten = {
    use edits <- result.try(permissions.forgetting(
      state.runtime,
      target,
      expected: expected_seq,
    ))
    api.edit_reserved_facts(state.runtime, edits)
    |> result.map_error(fn(error) {
      case error {
        api.RaceLost -> permissions.Stale
        other -> permissions.Failed(describe_api_error(other, "").1)
      }
    })
  }

  // Evaluate control flow transition for forget permissions.
  case forgotten {
    Ok(Nil) -> list_permissions(state, connection, id)
    Error(permissions.Stale) -> {
      reply_error(
        state,
        connection,
        id,
        protocol.code_conflict,
        "the remembered permissions changed after they were listed, so nothing was forgotten",
      )
      state
    }
    Error(permissions.Failed(reason:)) -> {
      reply_error(state, connection, id, protocol.code_bad_request, reason)
      state
    }
  }
}

/// Who is approving, as the fact will record it. The principal and the
/// credential's kind and fingerprint come from the connection's authenticated
/// binding and nothing a client sent, so a client cannot attribute a grant to
/// someone else. A connection with no binding (a host fixture) records none.
fn approval_provenance(
  state: State,
  connection: Int,
) -> permissions.Provenance {
  let #(now, _clock) = clock.read(state.runtime.effects.clock)

  // Evaluate control flow transition for approval provenance.
  case dict.get(state.connections, connection) {
    Ok(Connection(
      authentication: Authenticated(binding, ..),
      origin: Some(by),
      ..,
    )) -> permissions.Approved(by:, via: approval_via(binding), at_ms: now)
    Ok(_) | Error(Nil) -> permissions.Unknown
  }
}

/// Which credential an approval is recorded under. A page that belongs to a
/// browser sign-in records that sign-in, because it is the thing the owner can
/// revoke and the thing the list names. Anything else records the credential it
/// was admitted under, a login's digest as a login and a bearer's as a device.
fn approval_via(binding: Binding) -> permissions.Via {
  // Inspect connection authentication credentials and binding authority.
  case binding.signin {
    Some(fingerprint) -> permissions.Login(fingerprint:)
    None -> {
      let fingerprint = access.fingerprint(binding.digest)

      // Inspect connection authentication credentials and binding authority.
      case access.credential_kind(binding.digest) {
        access.Browser -> permissions.Login(fingerprint:)
        access.Bearer -> permissions.Device(fingerprint:)
      }
    }
  }
}

/// One wire row per schedule. The wake question crosses here as the
/// protocol's own two variants; the boolean the wire carries is minted
/// inside `client/protocol`'s codec and nowhere else.
fn schedule_row(row: scheduleadmin.Row) -> protocol.ScheduleInfo {
  protocol.ScheduleInfo(
    name: row.name,
    target: row.target,
    owner: row.owner,
    when: row.when,
    wake: case row.wake {
      schedule.WakesIdle -> protocol.WakesIdle
      schedule.SteersOnly -> protocol.SteersOnly
    },
    fired: row.fired,
    body: row.body,
  )
}

// --- set_config ------------------------------------------------------------

/// The accepted key set (protocol.md open question 3, answered):
/// `queue_mode` ("consume_all" | "one_at_a_time"), `tool_execution`
/// ("sequential" | "parallel") — session-wide run settings captured into
/// subsequent acceptances — `model_name` (a catalogue name, resolved
/// server-side; with a `strand` it switches that strand, without one it
/// switches every strand) — and, with a `strand`, the durable
/// per-strand configuration keys `model` ({provider, model_id}),
/// `thinking_level`, and `active_tools` (validated against the
/// configured tool registry and stored canonically — see
/// `canonical_tool_names`). Unknown keys are refused (`bad_request`)
/// and nothing is applied.
fn set_config(
  state: State,
  connection: Int,
  id: Int,
  strand: Option(String),
  config: JsonValue,
) -> State {
  use fields <- or_reply(config_fields(config), state, connection, id)
  use #(state, committed) <- or_reply(
    result.map_error(
      apply_operator_config(state, connection, strand, fields),
      fn(message) { #(protocol.code_bad_request, message) },
    ),
    state,
    connection,
    id,
  )
  reply(
    state,
    connection,
    id,
    protocol.SnapshotEvent(protocol.ConfigSnapshot(config: committed)),
  )
  let event = protocol.SnapshotEvent(protocol.ConfigSnapshot(committed))
  dict.each(state.connections, fn(other, link) {
    case link.subscription, other == connection {
      Subscribed, False ->
        send_to(state, other, EventEnvelope(None, None, event))

      // The issuing connection already has this snapshot as its own reply.
      Subscribed, True | Unsubscribed, False | Unsubscribed, True -> Nil
    }
  })
  state
}

/// Validates and applies configuration changes submitted by an operator.
fn apply_operator_config(
  state: State,
  connection: Int,
  strand: Option(String),
  fields: List(#(String, JsonValue)),
) -> Result(#(State, JsonValue), String) {
  // Evaluate control flow transition for apply operator config.
  case list.key_find(fields, "add_directory") {
    Error(Nil) ->
      apply_config(state, strand, fields, connection_origin(state, connection))
    Ok(value) -> {
      use <- bool.guard(
        strand != None || list.length(fields) != 1,
        Error(
          "add_directory must be the only setting and must be session-scoped",
        ),
      )
      use _ <- result.try(
        input_author(state, connection)
        |> result.map_error(fn(error) { error.1 }),
      )
      use admin <- result.try(
        state.directories
        |> option.to_result("directory administration is unavailable"),
      )
      use added <- result.try(admin.add(
        value,
        connection_origin(state, connection),
      ))
      Ok(#(
        state,
        json.Object([#("directories", added), ..base_config_fields(state)]),
      ))
    }
  }
}

/// Extracts structured key-value configuration fields from JSON input.
fn config_fields(
  config: JsonValue,
) -> Result(List(#(String, JsonValue)), #(String, String)) {
  case config {
    json.Object(fields) -> Ok(fields)
    _ -> Error(#(protocol.code_bad_request, "config must be an object"))
  }
}

/// Applies validated configuration field updates to session or strand state.
fn apply_config(
  state: State,
  strand: Option(String),
  fields: List(#(String, JsonValue)),
  author: Option(message.Origin),
) -> Result(#(State, JsonValue), String) {
  // Validate everything in the caller's order before applying anything: a
  // refused key must leave no partial effect, and an explicit thinking_level
  // runs after model_name so it always overrides the entry's seed.
  use _ <- result.try(
    list.try_map(fields, fn(field) { validate_config_key(state, strand, field) }),
  )
  let #(thinking, others) =
    list.partition(fields, fn(field) { field.0 == "thinking_level" })
  use changes <- result.try(
    list.try_map(list.append(others, thinking), fn(field) {
      validate_config_key(state, strand, field)
    }),
  )
  apply_changes(state, strand, changes, author)
}

/// Stages the validated changes and commits them in one compare-and-set. It is
/// the second half of `apply_config`, separate so a change the hub makes on its
/// own account, such as moving strands after a profile switch, commits through
/// exactly the path an operator's `set_config` does.
fn apply_changes(
  state: State,
  strand: Option(String),
  changes: List(ConfigChange),
  author: Option(message.Origin),
) -> Result(#(State, JsonValue), String) {
  use defaults <- result.try(
    api.run_defaults_cell(state.runtime)
    |> result.map_error(fn(_) { "shared run settings could not be read" }),
  )

  // Refresh runtime settings from shared defaults.
  let state =
    State(
      ..state,
      runtime: api.Runtime(..state.runtime, settings: defaults.settings),
    )
  use <- bool.lazy_guard(list.is_empty(changes), fn() {
    Ok(#(state, effective_config(state, strand)))
  })

  let initial = ConfigPlan(state, dict.new(), defaults, None)
  use plan <- result.try(
    list.fold(changes, Ok(initial), fn(plan, change) {
      use plan <- result.try(plan)
      change(plan)
    }),
  )

  // All reads and validation finish before this one compare-and-set. Neither
  // a later strand failure nor a conflicting defaults write can leave a prefix.
  let transaction =
    list.fold(dict.to_list(plan.cells), tx.Tx([], []), fn(transaction, pair) {
      let #(strand, cell) = pair
      tx.Tx(
        writes: [
          tx.SetRegister(
            register.StrandConfig,
            strand,
            register.value(machine_codec.encode_configuration(cell.value)),
          ),
          tx.SetRegister(
            register.FactCustom,
            "client/config_origin/" <> strand,
            register.value(json.Object([#("origin", origin.encode(author))])),
          ),
          ..transaction.writes
        ],
        expected: [
          tx.Expect(register.StrandConfig, strand, Some(cell.seq)),
          ..transaction.expected
        ],
      )
    })

  // Execute requested side query action.
  let transaction = case plan.settings {
    None -> transaction
    Some(settings) ->
      tx.Tx(
        writes: [
          tx.SetRegister(
            register.FactCustom,
            api.run_settings_key,
            register.value(api.encode_run_defaults(settings, author)),
          ),
          ..transaction.writes
        ],
        expected: [
          tx.Expect(register.FactCustom, api.run_settings_key, defaults.seq),
          ..transaction.expected
        ],
      )
  }

  // Commit transaction to durable storage and report changed fields.
  let settings = option.unwrap(plan.settings, defaults.settings)
  let updated = State(..state, runtime: api.Runtime(..state.runtime, settings:))

  // Evaluate operation result outcome.
  use target <- result.try(case strand {
    None -> Ok([])
    Some(name) ->
      staged_configuration(plan, name)
      |> result.map(fn(cell) { strand_config_fields(updated, cell.value) })
  })

  use _ <- result.try(
    writer.commit(state.runtime.tree.writer, transaction)
    |> result.map_error(fn(_) { "the configuration commit was refused" }),
  )

  // Format changed strand configuration payload.
  let changed =
    dict.to_list(plan.cells)
    |> list.map(fn(pair) {
      let #(name, cell) = pair
      #(
        name,
        json.Object([
          #("origin", origin.encode(author)),
          ..strand_config_fields(updated, cell.value)
        ]),
      )
    })

  // Evaluate control flow transition for apply changes.
  let defaults_origin = case plan.settings {
    None -> defaults.origin
    Some(_) -> author
  }

  Ok(#(
    updated,
    json.Object(
      list.flatten([
        base_config_fields(updated),
        target,
        [
          #("origin", origin.encode(defaults_origin)),
          #("strands", json.Object(changed)),
        ],
      ]),
    ),
  ))
}

// Staging retains each original cell sequence across multiple changes to it.
// The closures below can only alter this value; they cannot commit a prefix.
type ConfigPlan {
  ConfigPlan(
    context: State,
    cells: Dict(String, session.Cell(machine_strand.StrandConfiguration)),
    defaults: api.RunDefaults,
    settings: Option(operation.RunSettings),
  )
}

type ConfigChange =
  fn(ConfigPlan) -> Result(ConfigPlan, String)

/// Validates and decodes a single configuration property update.
fn validate_config_key(
  state: State,
  strand: Option(String),
  field: #(String, JsonValue),
) -> Result(ConfigChange, String) {
  let #(key, value) = field

  // Evaluate control flow transition for validate config key.
  case key {
    "queue_mode" ->
      case value {
        json.String("consume_all") ->
          Ok(set_queue_mode(_, operation.ConsumeAll))
        json.String("one_at_a_time") ->
          Ok(set_queue_mode(_, operation.OneAtATime))
        _ -> Error("queue_mode must be consume_all or one_at_a_time")
      }
    "tool_execution" ->
      case value {
        json.String("sequential") ->
          Ok(set_tool_execution(_, operation.Sequential))
        json.String("parallel") -> Ok(set_tool_execution(_, operation.Parallel))
        _ -> Error("tool_execution must be sequential or parallel")
      }
    "model" ->
      case strand, value {
        None, _ -> Error("model requires a strand")
        Some(strand), json.Object(model_fields) ->
          model_change(strand, model_fields)
        Some(_), _ -> Error("model must be an object")
      }

    // The by-name variant of `model`: the catalogue resolves the name
    // into the durable identity, so clients never handle raw provider
    // facts. Scoped to one strand when named, to every strand (the
    // session's model) otherwise.
    "model_name" ->
      case value {
        json.String(name) -> model_name_change(state, strand, name)
        _ -> Error("model_name must be a string (a catalogue model name)")
      }
    "thinking_level" ->
      case strand, value {
        None, _ -> Error("thinking_level requires a strand")
        Some(strand), json.String(level_text) ->
          thinking_level_change(strand, level_text)
        Some(_), _ -> Error("thinking_level must be a string")
      }

    // Every name is checked against the live registry and the list is
    // stored canonically; see `canonical_tool_names`.
    "active_tools" ->
      case strand, value {
        None, _ -> Error("active_tools requires a strand")
        Some(strand), json.Array(items) ->
          active_tools_change(state, strand, items)
        Some(_), _ -> Error("active_tools must be an array of tool names")
      }
    other -> Error("unknown config key: " <> other)
  }
}

/// Decodes and validates model selection configuration updates.
fn model_change(
  strand: String,
  model_fields: List(#(String, JsonValue)),
) -> Result(ConfigChange, String) {
  use provider <- result.try(config_string(model_fields, "provider"))
  use model_id <- result.try(config_string(model_fields, "model_id"))
  Ok(
    update_configuration(_, strand, fn(configuration) {
      machine_strand.StrandConfiguration(
        ..configuration,
        model: machine_strand.ModelIdentity(provider:, model_id:),
      )
    }),
  )
}

/// Decodes and validates thinking budget level configuration updates.
fn thinking_level_change(
  strand: String,
  level_text: String,
) -> Result(ConfigChange, String) {
  use level <- result.try(parse_thinking_level(level_text))
  Ok(
    update_configuration(_, strand, fn(configuration) {
      machine_strand.StrandConfiguration(..configuration, thinking_level: level)
    }),
  )
}

/// Decodes and validates active tool allowlist configuration updates.
fn active_tools_change(
  state: State,
  strand: String,
  items: List(JsonValue),
) -> Result(ConfigChange, String) {
  use names <- result.try(list.try_map(items, json_string_item))
  use names <- result.try(canonical_tool_names(state, names))
  Ok(
    update_configuration(_, strand, fn(configuration) {
      machine_strand.StrandConfiguration(
        ..configuration,
        active_tool_names: names,
      )
    }),
  )
}

fn json_string_item(item: JsonValue) -> Result(String, String) {
  case item {
    json.String(name) -> Ok(name)
    _ -> Error("active_tools entries must be strings")
  }
}

/// `model_name`'s change: the catalogue entry's identity, applied to one
/// strand's configuration when named, or to every strand's otherwise.
///
/// When the strand's `thinking_level` still matches the previous entry's seed,
/// it moves to the new entry's declared `thinking` level; a level the operator
/// raised or lowered away from the previous seed is left alone so switching
/// model mid-run does not un-raise a budget somebody deliberately chose. A
/// client that sends both keys gets its explicit `thinking_level`.
fn model_name_change(
  state: State,
  strand: Option(String),
  name: String,
) -> Result(ConfigChange, String) {
  use catalogue <- result.try(option.to_result(
    state.catalog,
    "no model catalogue is configured",
  ))
  use entry <- result.try(
    result.map_error(catalog.find(catalogue, name), fn(_nil) {
      "unknown model name: " <> name
    }),
  )
  let change = switch_to_entry(state, _, entry)

  // Evaluate control flow transition for model name change.
  case strand {
    Some(strand) -> Ok(update_configuration(_, strand, change))
    None -> Ok(update_all_configurations(_, change))
  }
}

/// Switches a strand's model to `entry`, seeding `thinking_level` from `entry`
/// when the strand still holds its previous model's seeded level (or `off` when
/// the previous model is not in the catalogue) and leaving an operator-chosen
/// level untouched.
fn switch_to_entry(
  state: State,
  configuration: machine_strand.StrandConfiguration,
  entry: catalog.CatalogModel,
) -> machine_strand.StrandConfiguration {
  let identity =
    machine_strand.ModelIdentity(provider: entry.name, model_id: entry.model_id)

  // Evaluate control flow transition for switch to entry.
  let previous_seed = case entry_in_force(state, configuration.model.provider) {
    Ok(previous) -> wiring.strand_thinking_level(previous.thinking)
    Error(Nil) -> machine_strand.ThinkingOff
  }

  // Evaluate control flow transition for switch to entry.
  let thinking_level = case configuration.thinking_level == previous_seed {
    True -> wiring.strand_thinking_level(entry.thinking)
    False -> configuration.thinking_level
  }

  machine_strand.StrandConfiguration(
    ..configuration,
    model: identity,
    thinking_level:,
  )
}

/// Looks up the model catalog entry currently active for a provider.
fn entry_in_force(
  state: State,
  provider: String,
) -> Result(catalog.CatalogModel, Nil) {
  use catalogue <- result.try(option.to_result(state.catalog, Nil))
  catalog.find(catalogue, provider)
}

/// The durable form of an active-tools list: every name checked against
/// the live registry, then sorted with duplicates collapsed.
///
/// The sort is load-bearing, not tidiness. This list is what
/// `client/wiring.tool_specs` renders into a request's tool array, which
/// sits ahead of the system prompt in the provider's render order; the
/// prompt cache matches on an exact byte prefix, and the Anthropic
/// adapter hangs one breakpoint on the last tool definition and another
/// on the system block. A client that re-sends the same set in a new
/// order would move those bytes and pay both cache writes again, every
/// turn. `tool_specs` sorts too — belt and braces, since a durable list
/// can be written by other paths — but a strand's stored configuration
/// is the honest place for the canonical form, and it is what the
/// `config` snapshot echoes back.
///
/// Neither the sort nor the dedup moves the authorization line:
/// `wiring.clear` decides what may run by `list.contains` on this same
/// list, and set membership is blind to order and multiplicity.
///
/// An unregistered name refuses the whole command, in band and by name,
/// the way an unknown `model_name` does — a tool that does not exist has
/// no business in durable configuration, and silently dropping it would
/// leave the client believing it had enabled something.
fn canonical_tool_names(
  state: State,
  names: List(String),
) -> Result(List(String), String) {
  // Project tool reference annotations into compaction prompt.
  case state.registered_tools {
    None -> Error("no tool registry is configured")
    Some(registry) -> {
      use _known <- result.try(
        list.try_map(names, fn(name) {
          case dict.has_key(registry, name) {
            True -> Ok(name)
            False -> Error("unknown tool name: " <> name)
          }
        }),
      )
      Ok(
        names
        |> list.sort(string.compare)
        |> list.unique,
      )
    }
  }
}

/// Extracts a required string property from configuration JSON fields.
fn config_string(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(String, String) {
  case list.key_find(fields, key) {
    Ok(json.String(text)) -> Ok(text)
    _ -> Error(key <> " must be a string")
  }
}

/// Sets the input queue mode in a pending configuration plan.
fn set_queue_mode(
  plan: ConfigPlan,
  mode: operation.QueueMode,
) -> Result(ConfigPlan, String) {
  let settings = option.unwrap(plan.settings, plan.defaults.settings)
  Ok(
    ConfigPlan(
      ..plan,
      settings: Some(
        operation.RunSettings(
          ..settings,
          steering_mode: mode,
          follow_up_mode: mode,
        ),
      ),
    ),
  )
}

/// Sets the tool execution policy mode in a pending configuration plan.
fn set_tool_execution(
  plan: ConfigPlan,
  mode: operation.ToolExecution,
) -> Result(ConfigPlan, String) {
  let settings = option.unwrap(plan.settings, plan.defaults.settings)
  Ok(
    ConfigPlan(
      ..plan,
      settings: Some(operation.RunSettings(..settings, tool_execution: mode)),
    ),
  )
}

/// Applies a configuration transform to a single strand in the plan.
fn update_configuration(
  plan: ConfigPlan,
  strand: String,
  change: fn(machine_strand.StrandConfiguration) ->
    machine_strand.StrandConfiguration,
) -> Result(ConfigPlan, String) {
  use cell <- result.try(staged_configuration(plan, strand))
  Ok(
    ConfigPlan(
      ..plan,
      cells: dict.insert(
        plan.cells,
        strand,
        session.Cell(..cell, value: change(cell.value)),
      ),
    ),
  )
}

/// A second field targeting the same strand sees the staged value, not a fresh
/// read which could discard the first field or replace its original expectation.
fn staged_configuration(
  plan: ConfigPlan,
  strand: String,
) -> Result(session.Cell(machine_strand.StrandConfiguration), String) {
  // Evaluate control flow transition for staged configuration.
  case dict.get(plan.cells, strand) {
    Ok(cell) -> Ok(cell)
    Error(Nil) -> {
      use cell <- result.try(
        session.strand_configuration(plan.context.runtime.session, strand)
        |> result.map_error(fn(_) { "configuration could not be read" }),
      )
      option.to_result(cell, "unknown strand: " <> strand)
    }
  }
}

/// Applies a configuration transform across all strands in the plan.
fn update_all_configurations(
  plan: ConfigPlan,
  change: fn(machine_strand.StrandConfiguration) ->
    machine_strand.StrandConfiguration,
) -> Result(ConfigPlan, String) {
  list.fold(strand_names(plan.context), Ok(plan), fn(plan, strand) {
    use plan <- result.try(plan)
    update_configuration(plan, strand, change)
  })
}

/// Parses a thinking budget level string into its domain variant.
fn parse_thinking_level(
  text: String,
) -> Result(machine_strand.ThinkingLevel, String) {
  case text {
    "off" -> Ok(machine_strand.ThinkingOff)
    "minimal" -> Ok(machine_strand.ThinkingMinimal)
    "low" -> Ok(machine_strand.ThinkingLow)
    "medium" -> Ok(machine_strand.ThinkingMedium)
    "high" -> Ok(machine_strand.ThinkingHigh)
    "xhigh" -> Ok(machine_strand.ThinkingXHigh)
    "max" -> Ok(machine_strand.ThinkingMax)
    other -> Error("unknown thinking level: " <> other)
  }
}

/// Formats the effective configuration in force for session or strand as JSON.
fn effective_config(state: State, strand: Option(String)) -> JsonValue {
  // Evaluate control flow transition for effective config.
  let directories = case state.directories {
    None -> []
    Some(admin) ->
      case admin.read() {
        Ok(value) -> [#("directories", value)]
        Error(reason) -> [#("directories_error", json.String(reason))]
      }
  }

  let base = list.append(base_config_fields(state), directories)

  // Evaluate control flow transition for effective config.
  case strand {
    None -> json.Object(base)
    Some(strand) ->
      case session.strand_configuration(state.runtime.session, strand) {
        Ok(Some(session.Cell(value:, ..))) ->
          json.Object(list.flatten([base, strand_config_fields(state, value)]))
        _ -> json.Object(base)
      }
  }
}

/// The session-wide fields: present in every `config` snapshot, strand or
/// none.
fn base_config_fields(state: State) -> List(#(String, JsonValue)) {
  let settings = state.runtime.settings
  [
    #("queue_mode", json.String(queue_mode_text(settings.steering_mode))),
    #(
      "tool_execution",
      json.String(tool_execution_text(settings.tool_execution)),
    ),
  ]
}

fn queue_mode_text(mode: operation.QueueMode) -> String {
  case mode {
    operation.ConsumeAll -> "consume_all"
    operation.OneAtATime -> "one_at_a_time"
  }
}

fn tool_execution_text(mode: operation.ToolExecution) -> String {
  case mode {
    operation.Sequential -> "sequential"
    operation.Parallel -> "parallel"
  }
}

/// The per-strand fields, spliced onto the session-wide base.
fn strand_config_fields(
  state: State,
  value: machine_strand.StrandConfiguration,
) -> List(#(String, JsonValue)) {
  list.flatten([
    [
      #(
        "model",
        json.Object([
          #("provider", json.String(value.model.provider)),
          #("model_id", json.String(value.model.model_id)),
        ]),
      ),
    ],
    // The catalogue name rides along whenever the identity is one the
    // catalogue knows, so clients can display and re-select by the same
    // handle they switched with.
    catalog_name_of(state, value.model),
    [
      #(
        "thinking_level",
        json.String(thinking_level_text(value.thinking_level)),
      ),
      #(
        "active_tools",
        json.Array(list.map(value.active_tool_names, json.String)),
      ),
    ],
  ])
}

/// The catalogue name behind a durable identity, when there is one: the
/// entry whose name is the identity's provider and whose model id
/// matches. Zero or one field, spliced into the effective config.
fn catalog_name_of(
  state: State,
  identity: machine_strand.ModelIdentity,
) -> List(#(String, JsonValue)) {
  case state.catalog {
    None -> []
    Some(catalogue) ->
      case catalog.find(catalogue, identity.provider) {
        Ok(entry) if entry.model_id == identity.model_id -> [
          #("model_name", json.String(entry.name)),
        ]
        _ -> []
      }
  }
}

/// Renders a thinking budget level variant to its wire string name.
fn thinking_level_text(level: machine_strand.ThinkingLevel) -> String {
  case level {
    machine_strand.ThinkingOff -> "off"
    machine_strand.ThinkingMinimal -> "minimal"
    machine_strand.ThinkingLow -> "low"
    machine_strand.ThinkingMedium -> "medium"
    machine_strand.ThinkingHigh -> "high"
    machine_strand.ThinkingXHigh -> "xhigh"
    machine_strand.ThinkingMax -> "max"
  }
}

// --- error mapping ---------------------------------------------------------

/// Renders an API error into protocol error code and explanatory message.
fn describe_api_error(
  error: api.ApiError,
  strand: String,
) -> #(String, String) {
  case error {
    api.RuntimeUnavailable -> #(
      protocol.code_conflict,
      "the session writer is restarting; try again",
    )
    api.AcceptRejected(reason:) -> describe_reject(reason)
    api.QueueRejected(reason: queue.NoActiveRun) -> #(
      protocol.code_conflict,
      "strand " <> strand <> " has no live operation",
    )
    api.ReadFailed(reason:) -> #(protocol.code_internal, reason)
    api.CommitFailed(error: _) -> #(
      protocol.code_internal,
      "the admission commit failed",
    )

    // A conflict, not an internal error: the session is gone from this
    // process's hands and the caller's remedy is to reopen it, which is
    // exactly what a conflict code tells a client to consider.
    api.SessionStolen(held_by: Some(owner)) -> #(
      protocol.code_conflict,
      "the session's write lease is now held by " <> owner,
    )
    api.SessionStolen(held_by: None) -> #(
      protocol.code_conflict,
      "the session's write lease was lost",
    )
    api.RaceLost -> #(
      protocol.code_conflict,
      "the admission kept losing its seq race",
    )
    api.ReservedFactKey(key:) -> #(
      protocol.code_bad_request,
      "reserved fact key: " <> key,
    )
    api.UnreservedFactKey(key:) -> #(
      protocol.code_bad_request,
      "not a reserved fact key: " <> key,
    )
    api.EscalationExists(id:) -> #(
      protocol.code_conflict,
      "escalation " <> id <> " already exists",
    )
    api.EscalationNotFound(id:) -> #(
      protocol.code_unknown_escalation,
      "unknown escalation: " <> id,
    )
    api.EscalationWrongStatus(id:, status:) -> #(
      protocol.code_not_pending,
      "escalation " <> id <> " is " <> escalation_view.status_name(status),
    )
    api.FactConflict(key:) -> #(
      protocol.code_conflict,
      "the fact " <> key <> " moved under the write",
    )
  }
}

/// Whether the hub process is currently alive — diagnostics only.
///
/// ## Examples
///
/// ```gleam
/// // gateway.is_alive(gateway)
/// ```
///
pub fn is_alive(gateway: Gateway) -> Bool {
  address.lookup(gateway.name) |> result.is_ok
}

/// Supplies the immutable skills captured at daemon startup.
///
/// ## Examples
///
/// ```gleam
/// // gateway.with_skills(options, catalogue)
/// ```
pub fn with_skills(options: Options, catalogue: skill.Catalogue) -> Options {
  Options(..options, skills: catalogue)
}

/// The aggregate bills the request; the final attempt measures its context.
/// Malformed present details cannot silently turn a fallback total into context.
///
/// An adjustment is not a request, and an auxiliary request (a glance or a
/// block summary) runs on its own model with its own small prompt. Both still
/// reach the cost total through `usage`, but neither may supply a context,
/// output-rate or cache reading for the live strand they were attributed to.
fn last_row_usage(row: UsageRow) -> Option(message.Usage) {
  use <- bool.guard(when: row.adjustment || is_auxiliary_row(row), return: None)
  accounting.decode_row(row)
  |> result.map(accounting.last)
  |> result.unwrap(None)
  |> option.then(accounting.observed_usage)
}

/// The auxiliary writers in `client/auxiliary` commit a row with no entry and
/// name the work in a top-level `phase` detail. The planner's own
/// summary-request rows also carry no entry, but they are the strand's
/// requests and name no phase, so they keep their observation.
fn is_auxiliary_row(row: UsageRow) -> Bool {
  case row.entry_id, row.details {
    None, Some(json.Object(fields)) ->
      list.any(fields, fn(field) { field.0 == "phase" })
    None, Some(_) | None, None | Some(_), _ -> False
  }
}
