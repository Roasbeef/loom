//// What one daemon says about itself when a peer asks (protocol-change/085,
//// the orchestrator port's `Report`).
////
//// A deployment spans machines, and a machine knows several things about itself
//// that no other machine can observe: how many scopes its execution ledger
//// holds and which of them block a reopen, what its sandbox helper enforces,
//// how many sessions its catalogue owns, which moves are stalled, and whether
//// its copy of the session directory is current. `NodeReport` is that account
//// as plain data. The asking daemon never computes these facts from outside; it
//// reads what the node reports and says so.
////
//// ## Why this is a module of its own
////
//// The orchestrator port answers `Report`, and the session movers supply the
//// moves it lists. The movers import the port, because a mover sends through it,
//// so the port cannot import the movers' vocabulary without a cycle. These types
//// are therefore neither the port's nor the movers': they sit below both, and
//// each imports them.
////
//// ## What a report never holds
////
//// A report crosses the distribution connection as a term and is rendered to
//// JSON for the control socket, so it carries no pid, subject, function, path,
//// credential, key, cookie or pin. A workspace is named and never located, a
//// session is an identifier, and a failure is a short reason cut to a fixed
//// length. Each type is closed over strings, numbers and other such records,
//// so a function or a process cannot be put into one.
////
//// ## Totality at the boundary
////
//// `to_json` renders every field, and `decode` reads it back with a total
//// decoder: a field that is missing, mistyped, negative where it is a count, or
//// longer than its bound is an `Error` naming the field, and never a default. A
//// peer's report is data from another machine, and the asking daemon decides
//// what to say about that machine from it.
////
//// ## Flow
////
//// `to_json` → `decode` → `executor_json` → `orchestrator_json` →
//// `directory_json`
////
//// 1. `to_json` renders a whole report, leaving out the facts a node does not
////    have (an executor-only node has no orchestrator facts).
//// 2. `decode` reads one back, checking every bound the type documents.
//// 3. The three `_json` functions render the optional facts and are public so
////    a client that shows one part can render only that part.

import client/directory/member
import client/directory/store
import client/executors
import client/internal/ffi_khepri
import core/json.{type JsonValue}
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// The most peers a report lists.
pub const max_peers = 32

/// The most workspace names an executor lists.
pub const max_workspaces = 64

/// The most placements an orchestrator lists.
pub const max_placements = 32

/// The most moves an orchestrator lists.
pub const max_moves = 64

/// The most unclean scopes a report lists. The executor admits at most
/// `exec_ledger.max_unclean_scopes` of them, so a larger list is a fault.
pub const max_unclean = 64

/// The most members a directory status lists.
pub const max_members = 64

/// The most bytes of a move's last stall reason.
pub const max_reason_bytes = 200

/// The most bytes of any other text a report holds.
pub const max_text_bytes = 512

/// Everything one daemon says about itself.
pub type NodeReport {
  NodeReport(
    /// The node's full Erlang name.
    node: String,
    /// The build's version, as the `hello` reply states it.
    build_version: String,
    /// The build's commit, as the `hello` reply states it.
    build_commit: String,
    /// The daemon's epoch, which changes at a restart.
    epoch: String,
    /// The node's own clock at start, in Unix milliseconds. A reader computes
    /// uptime from `started_ms` and `now_ms` and never compares either with
    /// its own clock.
    started_ms: Int,
    /// The node's own clock when it answered.
    now_ms: Int,
    /// The nodes of its configured `[[distribution.peers]]`, at most
    /// `max_peers`.
    peers: List(String),
    /// What it says as an orchestrator, or `None` when it has no catalogue to
    /// describe.
    orchestrator: Option(OrchestratorFacts),
    /// What it says as an executor, or `None` when it serves no workspace.
    executor: Option(ExecutorFacts),
    /// What it says as a member of the session directory, or `None` when it is
    /// not one.
    directory: Option(DirectoryFacts),
  )
}

/// What an executor says about its machine and its execution ledger.
pub type ExecutorFacts {
  ExecutorFacts(
    /// The executor wire protocol version it speaks.
    protocol: Int,
    /// How many scopes are in each state.
    scopes: ScopeCounts,
    /// The most scopes it admits that are not cleanly closed.
    scope_limit: Int,
    /// The scopes that block a reopen: closing, or closed with unknown cleanup.
    /// They hold the limit's slots, so there are at most `scope_limit` of them.
    unclean: List(UncleanScope),
    /// The bytes the ledger's reservations and unacknowledged outcomes hold.
    ledger_bytes: Int,
    /// The most bytes it admits.
    ledger_limit: Int,
    /// The calls whose result nobody has acknowledged.
    unacknowledged: Int,
    /// The platform label, as the system prompt words it.
    platform: String,
    /// Enforcement and toolchains from the most recent attach census, or `None`
    /// until one has happened.
    observed: Option(executors.Observed),
    /// The names, never the roots, of the registered workspaces, at most
    /// `max_workspaces`.
    workspaces: List(String),
  )
}

/// How many scopes an executor holds in each state.
pub type ScopeCounts {
  ScopeCounts(
    /// Admitting calls.
    open: Int,
    /// Fenced while the host cancels live work.
    closing: Int,
    /// Closed with every child retired. A later attach reopens it.
    closed_clean: Int,
    /// Closed without proof that every child is gone. Only an operator's
    /// release frees the slot.
    closed_unknown: Int,
  )
}

/// A scope that blocks a reopen.
pub type UncleanScope {
  UncleanScope(
    /// The session the scope belongs to.
    session: String,
    /// Why it blocks.
    state: UncleanState,
  )
}

/// Why a scope blocks a reopen.
pub type UncleanState {
  /// The executor's VM ended between the fence and the close, or the close has
  /// not finished.
  Closing

  /// The host could not prove `count` children are gone.
  UnknownCleanup(count: Int)
}

/// What an orchestrator says about its capacity, its sessions and its moves.
pub type OrchestratorFacts {
  OrchestratorFacts(
    /// The most simultaneous runtime reservations.
    capacity: Int,
    /// The reservations held now, including uncertain cleanup.
    occupied: Int,
    /// The usable resident sessions.
    resident: Int,
    /// Whether it accepts sessions another orchestrator moves to it.
    imports: Imports,
    /// The node of each `[executors.<name>]` row it configures.
    executor_nodes: List(String),
    /// Sessions by executor node and residency, from the catalogue's
    /// `executor` column, at most `max_placements` rows.
    placements: List(Placement),
    /// The moves it has in flight, at most `max_moves`.
    moves: List(MoveFacts),
  )
}

/// Whether an orchestrator accepts the sessions another one moves to it.
pub type Imports {
  /// It runs an importer.
  Receiving

  /// It refuses every piece and activation.
  NotReceiving
}

/// The sessions an orchestrator has placed on one executor.
pub type Placement {
  Placement(
    /// The executor's full node name.
    executor_node: String,
    /// Sessions with a usable resident runtime.
    resident: Int,
    /// Sessions that are saved and not resident.
    saved: Int,
  )
}

/// One session move this orchestrator has in flight.
pub type MoveFacts {
  MoveFacts(
    /// The session being moved.
    session: String,
    /// The move's identity.
    op: String,
    /// The node of the orchestrator the session is moving to.
    to_node: String,
    /// Whether the move is making progress.
    phase: MovePhase,
    /// Milliseconds since the stall began, by this node's monotonic clock, when
    /// the move is stalled. It is a duration and never a timestamp.
    stalled_ms: Option(Int),
    /// The last stall reason, cut to `max_reason_bytes` bytes.
    reason: Option(String),
  )
}

/// Whether a move is progressing.
pub type MovePhase {
  /// A step of the move is running.
  Running

  /// The move is waiting to retry after a stall.
  Waiting
}

/// What a directory member says about its cluster and its own copy.
pub type DirectoryFacts {
  DirectoryFacts(
    /// The status `directory.status` reports.
    status: member.Status,
    /// Whether this node's copy is known to be current.
    copy: Copy,
  )
}

/// Whether a directory member's own copy is known to be current.
pub type Copy {
  /// A consistent read (a fence, then a read) completed within its deadline.
  Current

  /// It did not: no quorum, or the copy is too far behind to fence in time.
  Unconfirmed
}

/// Cuts a reason to `max_reason_bytes` bytes without splitting a character.
///
/// ## Examples
///
/// ```gleam
/// assert node_report.cut_reason("short") == "short"
/// ```
pub fn cut_reason(reason: String) -> String {
  cut(reason, max_reason_bytes)
}

// Keeps whole graphemes while they fit, so a multi-byte character is kept
// entire or dropped entire and the result is still valid text.
fn cut(text: String, bytes: Int) -> String {
  case byte_size(text) <= bytes {
    True -> text
    False -> {
      let #(taken, _used) =
        list.fold_until(
          string.to_graphemes(text),
          #([], 0),
          fn(state, grapheme) {
            let #(kept, used) = state
            let size = byte_size(grapheme)
            case used + size > bytes {
              True -> list.Stop(state)
              False -> list.Continue(#([grapheme, ..kept], used + size))
            }
          },
        )
      list.reverse(taken) |> string.concat
    }
  }
}

fn byte_size(text: String) -> Int {
  bit_array.byte_size(bit_array.from_string(text))
}

// --- rendering ----------------------------------------------------------------

/// Renders a whole report. The facts a node does not have are left out, so a
/// reader can tell an executor-only node from one whose catalogue is empty.
///
/// ## Examples
///
/// ```gleam
/// let report = node_report.bare("loom@box.example", "0.3.0", "abc", "e1", 0, 5)
/// assert node_report.decode(node_report.to_json(report)) == Ok(report)
/// ```
pub fn to_json(report: NodeReport) -> JsonValue {
  json.Object(
    list.flatten([
      [
        #("node", json.String(report.node)),
        #("build_version", json.String(report.build_version)),
        #("build_commit", json.String(report.build_commit)),
        #("epoch", json.String(report.epoch)),
        #("started_ms", json.Int(report.started_ms)),
        #("now_ms", json.Int(report.now_ms)),
        #("peers", strings_json(report.peers)),
      ],
      present("orchestrator", report.orchestrator, orchestrator_json),
      present("executor", report.executor, executor_json),
      present("directory", report.directory, directory_json),
    ]),
  )
}

/// A report with no orchestrator, executor or directory facts. It is what a
/// node answers when it has nothing of those kinds to describe, and the base a
/// daemon fills in.
///
/// ## Examples
///
/// ```gleam
/// let report = node_report.bare("loom@box.example", "0.3.0", "abc", "e1", 0, 5)
/// assert report.executor == None
/// ```
pub fn bare(
  node: String,
  build_version: String,
  build_commit: String,
  epoch: String,
  started_ms: Int,
  now_ms: Int,
) -> NodeReport {
  NodeReport(
    node:,
    build_version:,
    build_commit:,
    epoch:,
    started_ms:,
    now_ms:,
    peers: [],
    orchestrator: None,
    executor: None,
    directory: None,
  )
}

fn present(
  key: String,
  value: Option(a),
  render: fn(a) -> JsonValue,
) -> List(#(String, JsonValue)) {
  case value {
    Some(found) -> [#(key, render(found))]
    None -> []
  }
}

fn strings_json(items: List(String)) -> JsonValue {
  json.Array(list.map(items, json.String))
}

/// Renders an executor's facts.
///
/// ## Examples
///
/// ```gleam
/// // node_report.executor_json(facts)
/// ```
pub fn executor_json(facts: ExecutorFacts) -> JsonValue {
  json.Object(
    list.flatten([
      [
        #("protocol", json.Int(facts.protocol)),
        #("scopes", scopes_json(facts.scopes)),
        #("scope_limit", json.Int(facts.scope_limit)),
        #("unclean", json.Array(list.map(facts.unclean, unclean_json))),
        #("ledger_bytes", json.Int(facts.ledger_bytes)),
        #("ledger_limit", json.Int(facts.ledger_limit)),
        #("unacknowledged", json.Int(facts.unacknowledged)),
        #("platform", json.String(facts.platform)),
        #("workspaces", strings_json(facts.workspaces)),
      ],
      present("observed", facts.observed, observed_json),
    ]),
  )
}

fn scopes_json(counts: ScopeCounts) -> JsonValue {
  json.Object([
    #("open", json.Int(counts.open)),
    #("closing", json.Int(counts.closing)),
    #("closed_clean", json.Int(counts.closed_clean)),
    #("closed_unknown", json.Int(counts.closed_unknown)),
  ])
}

fn unclean_json(scope: UncleanScope) -> JsonValue {
  json.Object(
    list.flatten([
      [#("session", json.String(scope.session))],
      case scope.state {
        Closing -> [#("state", json.String("closing"))]
        UnknownCleanup(count:) -> [
          #("state", json.String("unknown_cleanup")),
          #("count", json.Int(count)),
        ]
      },
    ]),
  )
}

fn observed_json(observed: executors.Observed) -> JsonValue {
  json.Object([
    #("platform", json.String(observed.platform)),
    #(
      "enforcement",
      json.String(executors.enforcement_word(observed.enforcement)),
    ),
    #("toolchains", strings_json(observed.toolchains)),
  ])
}

/// Renders an orchestrator's facts.
///
/// ## Examples
///
/// ```gleam
/// // node_report.orchestrator_json(facts)
/// ```
pub fn orchestrator_json(facts: OrchestratorFacts) -> JsonValue {
  json.Object([
    #("capacity", json.Int(facts.capacity)),
    #("occupied", json.Int(facts.occupied)),
    #("resident", json.Int(facts.resident)),
    #("imports", json.String(imports_word(facts.imports))),
    #("executor_nodes", strings_json(facts.executor_nodes)),
    #("placements", json.Array(list.map(facts.placements, placement_json))),
    #("moves", json.Array(list.map(facts.moves, move_json))),
  ])
}

fn imports_word(imports: Imports) -> String {
  case imports {
    Receiving -> "receiving"
    NotReceiving -> "not_receiving"
  }
}

fn placement_json(placement: Placement) -> JsonValue {
  json.Object([
    #("executor_node", json.String(placement.executor_node)),
    #("resident", json.Int(placement.resident)),
    #("saved", json.Int(placement.saved)),
  ])
}

/// Renders one move.
///
/// ## Examples
///
/// ```gleam
/// // node_report.move_json(MoveFacts("s", "op", "loom@b", Waiting, Some(900), None))
/// ```
pub fn move_json(move: MoveFacts) -> JsonValue {
  json.Object(
    list.flatten([
      [
        #("session", json.String(move.session)),
        #("op", json.String(move.op)),
        #("to_node", json.String(move.to_node)),
        #("phase", json.String(phase_word(move.phase))),
      ],
      present("stalled_ms", move.stalled_ms, json.Int),
      present("reason", move.reason, json.String),
    ]),
  )
}

fn phase_word(phase: MovePhase) -> String {
  case phase {
    Running -> "running"
    Waiting -> "waiting"
  }
}

/// Renders a directory member's facts. The status carries the cluster as this
/// member sees it, or the reason it cannot say.
///
/// ## Examples
///
/// ```gleam
/// // node_report.directory_json(DirectoryFacts(status, node_report.Current))
/// ```
pub fn directory_json(facts: DirectoryFacts) -> JsonValue {
  let status = facts.status
  json.Object(
    list.flatten([
      [
        #("members", strings_json(status.members)),
        #("joining", json.String(joining_word(status.joining))),
        #("applied_index", json.Int(status.applied_index)),
        #("copy", json.String(copy_word(facts.copy))),
      ],
      case status.ra {
        Ok(membership) -> [#("ra", membership_json(membership))]
        Error(store.Unavailable(reason:)) -> [
          #("unavailable", json.String(reason)),
        ]
      },
    ]),
  )
}

fn joining_word(joining: member.Joining) -> String {
  case joining {
    member.Joined -> "joined"
    member.NotJoined -> "not_joined"
    member.Rejoining -> "rejoining"
  }
}

fn copy_word(copy: Copy) -> String {
  case copy {
    Current -> "current"
    Unconfirmed -> "unconfirmed"
  }
}

fn membership_json(membership: store.Membership) -> JsonValue {
  json.Object(
    list.flatten([
      [
        #(
          "members",
          json.Array(
            list.map(membership.members, fn(entry) {
              json.Object([
                #("node", json.String(entry.0)),
                #("voting", json.String(voting_word(entry.1))),
              ])
            }),
          ),
        ),
        #("up", strings_json(membership.up)),
      ],
      present("leader", membership.leader, json.String),
    ]),
  )
}

fn voting_word(voting: ffi_khepri.Voting) -> String {
  case voting {
    ffi_khepri.Voter -> "voter"
    ffi_khepri.Promoting -> "promoting"
    ffi_khepri.NonVoter -> "non_voter"
  }
}

// --- reading ------------------------------------------------------------------

/// Reads a report back. Every field is checked: counts are not negative, lists
/// and text are within their bounds, and a word outside its closed set is
/// refused. The error names the field.
///
/// ## Examples
///
/// ```gleam
/// let report = node_report.bare("loom@box.example", "0.3.0", "abc", "e1", 0, 5)
/// assert node_report.decode(node_report.to_json(report)) == Ok(report)
/// ```
pub fn decode(value: JsonValue) -> Result(NodeReport, String) {
  use fields <- result.try(object(Ok(value), "report"))
  use node <- result.try(text_of(fields, "node"))
  use build_version <- result.try(text_of(fields, "build_version"))
  use build_commit <- result.try(text_of(fields, "build_commit"))
  use epoch <- result.try(text_of(fields, "epoch"))
  use started_ms <- result.try(count_of(fields, "started_ms"))
  use now_ms <- result.try(count_of(fields, "now_ms"))
  use peers <- result.try(texts_of(fields, "peers", max_peers))
  use orchestrator <- result.try(optional_of(
    fields,
    "orchestrator",
    decode_orchestrator,
  ))
  use executor <- result.try(optional_of(fields, "executor", decode_executor))
  use directory <- result.map(optional_of(fields, "directory", decode_directory))
  NodeReport(
    node:,
    build_version:,
    build_commit:,
    epoch:,
    started_ms:,
    now_ms:,
    peers:,
    orchestrator:,
    executor:,
    directory:,
  )
}

/// Reads an executor's facts.
///
/// ## Examples
///
/// ```gleam
/// // node_report.decode_executor(node_report.executor_json(facts)) == Ok(facts)
/// ```
pub fn decode_executor(value: JsonValue) -> Result(ExecutorFacts, String) {
  use fields <- result.try(object(Ok(value), "executor"))
  use protocol <- result.try(count_of(fields, "protocol"))
  use scopes <- result.try(field_of(fields, "scopes", decode_scopes))
  use scope_limit <- result.try(count_of(fields, "scope_limit"))
  use unclean <- result.try(list_of(
    fields,
    "unclean",
    max_unclean,
    decode_unclean,
  ))
  use ledger_bytes <- result.try(count_of(fields, "ledger_bytes"))
  use ledger_limit <- result.try(count_of(fields, "ledger_limit"))
  use unacknowledged <- result.try(count_of(fields, "unacknowledged"))
  use platform <- result.try(text_of(fields, "platform"))
  use observed <- result.try(optional_of(fields, "observed", decode_observed))
  use workspaces <- result.map(texts_of(fields, "workspaces", max_workspaces))
  ExecutorFacts(
    protocol:,
    scopes:,
    scope_limit:,
    unclean:,
    ledger_bytes:,
    ledger_limit:,
    unacknowledged:,
    platform:,
    observed:,
    workspaces:,
  )
}

fn decode_scopes(value: JsonValue) -> Result(ScopeCounts, String) {
  use fields <- result.try(object(Ok(value), "scopes"))
  use open <- result.try(count_of(fields, "open"))
  use closing <- result.try(count_of(fields, "closing"))
  use closed_clean <- result.try(count_of(fields, "closed_clean"))
  use closed_unknown <- result.map(count_of(fields, "closed_unknown"))
  ScopeCounts(open:, closing:, closed_clean:, closed_unknown:)
}

fn decode_unclean(value: JsonValue) -> Result(UncleanScope, String) {
  use fields <- result.try(object(Ok(value), "unclean entry"))
  use session <- result.try(text_of(fields, "session"))
  use state <- result.try(text_of(fields, "state"))
  case state {
    "closing" -> Ok(UncleanScope(session:, state: Closing))
    "unknown_cleanup" -> {
      use count <- result.map(count_of(fields, "count"))
      UncleanScope(session:, state: UnknownCleanup(count:))
    }
    _ -> Error("unclean state is not closing or unknown_cleanup")
  }
}

fn decode_observed(value: JsonValue) -> Result(executors.Observed, String) {
  use fields <- result.try(object(Ok(value), "observed"))
  use platform <- result.try(text_of(fields, "platform"))
  use word <- result.try(text_of(fields, "enforcement"))
  use enforcement <- result.try(case word {
    "enforced" -> Ok(executors.Enforced)
    "degraded" -> Ok(executors.Degraded)
    _ -> Error("enforcement is not enforced or degraded")
  })
  use toolchains <- result.map(texts_of(fields, "toolchains", max_workspaces))
  executors.Observed(platform:, enforcement:, toolchains:)
}

/// Reads an orchestrator's facts.
///
/// ## Examples
///
/// ```gleam
/// // node_report.decode_orchestrator(node_report.orchestrator_json(facts)) == Ok(facts)
/// ```
pub fn decode_orchestrator(
  value: JsonValue,
) -> Result(OrchestratorFacts, String) {
  use fields <- result.try(object(Ok(value), "orchestrator"))
  use capacity <- result.try(count_of(fields, "capacity"))
  use occupied <- result.try(count_of(fields, "occupied"))
  use resident <- result.try(count_of(fields, "resident"))
  use word <- result.try(text_of(fields, "imports"))
  use imports <- result.try(case word {
    "receiving" -> Ok(Receiving)
    "not_receiving" -> Ok(NotReceiving)
    _ -> Error("imports is not receiving or not_receiving")
  })
  use executor_nodes <- result.try(texts_of(
    fields,
    "executor_nodes",
    max_placements,
  ))
  use placements <- result.try(list_of(
    fields,
    "placements",
    max_placements,
    decode_placement,
  ))
  use moves <- result.map(list_of(fields, "moves", max_moves, decode_move))
  OrchestratorFacts(
    capacity:,
    occupied:,
    resident:,
    imports:,
    executor_nodes:,
    placements:,
    moves:,
  )
}

fn decode_placement(value: JsonValue) -> Result(Placement, String) {
  use fields <- result.try(object(Ok(value), "placement"))
  use executor_node <- result.try(text_of(fields, "executor_node"))
  use resident <- result.try(count_of(fields, "resident"))
  use saved <- result.map(count_of(fields, "saved"))
  Placement(executor_node:, resident:, saved:)
}

/// Reads one move.
///
/// ## Examples
///
/// ```gleam
/// // node_report.decode_move(node_report.move_json(move)) == Ok(move)
/// ```
pub fn decode_move(value: JsonValue) -> Result(MoveFacts, String) {
  use fields <- result.try(object(Ok(value), "move"))
  use session <- result.try(text_of(fields, "session"))
  use op <- result.try(text_of(fields, "op"))
  use to_node <- result.try(text_of(fields, "to_node"))
  use word <- result.try(text_of(fields, "phase"))
  use phase <- result.try(case word {
    "running" -> Ok(Running)
    "waiting" -> Ok(Waiting)
    _ -> Error("phase is not running or waiting")
  })
  use stalled_ms <- result.try(optional_count(fields, "stalled_ms"))
  use reason <- result.map(optional_reason(fields, "reason"))
  MoveFacts(session:, op:, to_node:, phase:, stalled_ms:, reason:)
}

/// Reads a directory member's facts.
///
/// ## Examples
///
/// ```gleam
/// // node_report.decode_directory(node_report.directory_json(facts)) == Ok(facts)
/// ```
pub fn decode_directory(value: JsonValue) -> Result(DirectoryFacts, String) {
  use fields <- result.try(object(Ok(value), "directory"))
  use members <- result.try(texts_of(fields, "members", max_members))
  use word <- result.try(text_of(fields, "joining"))
  use joining <- result.try(case word {
    "joined" -> Ok(member.Joined)
    "not_joined" -> Ok(member.NotJoined)
    "rejoining" -> Ok(member.Rejoining)
    _ -> Error("joining is not joined, not_joined or rejoining")
  })
  use applied_index <- result.try(count_of(fields, "applied_index"))
  use copy_text <- result.try(text_of(fields, "copy"))
  use copy <- result.try(case copy_text {
    "current" -> Ok(Current)
    "unconfirmed" -> Ok(Unconfirmed)
    _ -> Error("copy is not current or unconfirmed")
  })
  use ra <- result.map(decode_ra(fields))
  DirectoryFacts(
    status: member.Status(members:, joining:, ra:, applied_index:),
    copy:,
  )
}

// A status holds either the cluster as the member sees it or the reason it
// cannot say, and exactly one of the two is written.
fn decode_ra(
  fields: List(#(String, JsonValue)),
) -> Result(Result(store.Membership, store.Unavailable), String) {
  case list.key_find(fields, "ra"), list.key_find(fields, "unavailable") {
    Ok(ra), Error(Nil) -> decode_membership(ra) |> result.map(Ok)
    Error(Nil), Ok(_) ->
      text_of(fields, "unavailable")
      |> result.map(fn(reason) { Error(store.Unavailable(reason:)) })
    Ok(_), Ok(_) | Error(Nil), Error(Nil) ->
      Error("directory holds neither or both of ra and unavailable")
  }
}

fn decode_membership(value: JsonValue) -> Result(store.Membership, String) {
  use fields <- result.try(object(Ok(value), "ra"))
  use members <- result.try(list_of(
    fields,
    "members",
    max_members,
    decode_voter,
  ))
  use up <- result.try(texts_of(fields, "up", max_members))
  use leader <- result.map(optional_text(fields, "leader"))
  store.Membership(members:, leader:, up:)
}

fn decode_voter(
  value: JsonValue,
) -> Result(#(String, ffi_khepri.Voting), String) {
  use fields <- result.try(object(Ok(value), "ra member"))
  use node <- result.try(text_of(fields, "node"))
  use word <- result.try(text_of(fields, "voting"))
  case word {
    "voter" -> Ok(#(node, ffi_khepri.Voter))
    "promoting" -> Ok(#(node, ffi_khepri.Promoting))
    "non_voter" -> Ok(#(node, ffi_khepri.NonVoter))
    _ -> Error("voting is not voter, promoting or non_voter")
  }
}

// --- the decoder's field readers ----------------------------------------------

type Fields =
  List(#(String, JsonValue))

fn object(
  value: Result(JsonValue, Nil),
  place: String,
) -> Result(Fields, String) {
  case value {
    Ok(json.Object(fields)) -> Ok(fields)
    _ -> Error(place <> " is not an object")
  }
}

fn text_of(fields: Fields, key: String) -> Result(String, String) {
  case list.key_find(fields, key) {
    Ok(json.String(text)) ->
      case byte_size(text) <= max_text_bytes {
        True -> Ok(text)
        False -> Error(key <> " is longer than the report allows")
      }
    _ -> Error(key <> " is not a string")
  }
}

fn optional_text(
  fields: Fields,
  key: String,
) -> Result(Option(String), String) {
  case list.key_find(fields, key) {
    Error(Nil) | Ok(json.Null) -> Ok(None)
    Ok(_) -> text_of(fields, key) |> result.map(Some)
  }
}

fn optional_reason(
  fields: Fields,
  key: String,
) -> Result(Option(String), String) {
  case list.key_find(fields, key) {
    Ok(json.String(text)) ->
      case byte_size(text) <= max_reason_bytes {
        True -> Ok(Some(text))
        False -> Error(key <> " is longer than the reason bound")
      }
    Error(Nil) | Ok(json.Null) -> Ok(None)
    Ok(_) -> Error(key <> " is not a string")
  }
}

fn count_of(fields: Fields, key: String) -> Result(Int, String) {
  case list.key_find(fields, key) {
    Ok(json.Int(number)) if number >= 0 -> Ok(number)
    Ok(json.Int(_)) -> Error(key <> " is a negative count")
    _ -> Error(key <> " is not an integer")
  }
}

fn optional_count(fields: Fields, key: String) -> Result(Option(Int), String) {
  case list.key_find(fields, key) {
    Error(Nil) | Ok(json.Null) -> Ok(None)
    Ok(_) -> count_of(fields, key) |> result.map(Some)
  }
}

fn texts_of(
  fields: Fields,
  key: String,
  most: Int,
) -> Result(List(String), String) {
  list_of(fields, key, most, fn(item) {
    case item {
      json.String(text) ->
        case byte_size(text) <= max_text_bytes {
          True -> Ok(text)
          False -> Error(key <> " holds text longer than the report allows")
        }
      _ -> Error(key <> " holds something that is not a string")
    }
  })
}

fn list_of(
  fields: Fields,
  key: String,
  most: Int,
  item: fn(JsonValue) -> Result(a, String),
) -> Result(List(a), String) {
  case list.key_find(fields, key) {
    Ok(json.Array(items)) ->
      case list.drop(items, most) {
        [] -> list.try_map(items, item)
        [_, ..] -> Error(key <> " holds too many entries")
      }
    _ -> Error(key <> " is not an array")
  }
}

fn field_of(
  fields: Fields,
  key: String,
  read: fn(JsonValue) -> Result(a, String),
) -> Result(a, String) {
  case list.key_find(fields, key) {
    Ok(value) -> read(value)
    Error(Nil) -> Error(key <> " is missing")
  }
}

fn optional_of(
  fields: Fields,
  key: String,
  read: fn(JsonValue) -> Result(a, String),
) -> Result(Option(a), String) {
  case list.key_find(fields, key) {
    Error(Nil) | Ok(json.Null) -> Ok(None)
    Ok(value) -> read(value) |> result.map(Some)
  }
}
