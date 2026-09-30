//// Caller-owned message inspection and authorized resident peer delivery.
////
//// The host still owns authority, queue membership, pagination and admission.
//// This boundary decodes stable envelopes once so scripts cannot confuse JSON
//// text with a receipt, a cursor from another journal, or an absent message.
//// Message payloads and model-authored observations remain open report values.

import cap/internal/channel
import cap/internal/dispatch
import cap/internal/wire
import cap/report.{type Value} as cap_report
import cap/strand
import core/ids
import core/msgpack
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// A canonical session identity, usable without importing core.
pub type SessionId =
  ids.SessionId

/// A durable message entry identity, usable from the peer module alone.
pub type EntryId =
  ids.EntryId

/// A durable operation identity, usable from the peer module alone.
pub type OpId =
  ids.OpId

/// A pending input cursor belongs only to the caller's live input set.
pub opaque type PendingCursor {
  PendingCursor(
    /// The persisted position in this cursor domain.
    value: String,
  )
}

/// A transcript cursor belongs only to the caller's materialized branch.
pub opaque type HistoryCursor {
  HistoryCursor(
    /// The persisted position in this cursor domain.
    value: Int,
  )
}

/// A receipt cursor orders hash keys, never arrival times.
pub opaque type ReceiptCursor {
  ReceiptCursor(
    /// The persisted position in this cursor domain.
    value: String,
  )
}

/// Categories a caller can distinguish without parsing diagnostic prose.
pub type PeerError {
  /// The host refused under this denial code.
  PeerDenied(
    /// The stable host denial code.
    code: String,
    /// The host denial explanation.
    message: String,
  )

  /// The capability channel could not carry the request.
  PeerUnavailable(
    /// The explanatory diagnostic.
    reason: String,
  )

  /// A successful host response violated the stable envelope contract.
  PeerResultMalformed(
    /// The explanatory diagnostic.
    reason: String,
  )

  /// A persisted selector is not valid in this cursor or identity domain.
  InvalidSelector(
    /// The explanatory diagnostic.
    reason: String,
  )
}

/// The durable queue which currently owns an input.
pub type Queue {
  /// Input waiting for the next operation.
  NextRun

  /// Steering waiting at an active checkpoint.
  Steer

  /// Follow-up input for the active operation.
  FollowUp

  /// Steering retained by cancellation cleanup.
  CancelledSteer

  /// Follow-up input retained by cancellation cleanup.
  CancelledFollowUp
}

/// A caller-owned input; bodies retain their existing extensible codecs.
pub type Input {
  /// The pending payload is a machine pending-entry value.
  Pending(
    /// The durable entry identity.
    id: EntryId,
    /// The current owning input queue.
    queue: Queue,
    /// The complete extensible pending-entry value.
    payload: Value,
  )

  /// The materialized payload is a core entry value on the caller's branch.
  Materialized(
    /// The durable entry identity.
    id: EntryId,
    /// The complete extensible materialized-entry value.
    entry: Value,
  )
}

/// One coherent live-set page, which may be short after concurrent consumption.
pub type InboxPage {
  InboxPage(
    /// The ownership snapshot revision.
    revision: Int,
    /// The caller-owned rows copied from this window.
    items: List(Input),
    /// The membership count at the ownership cut.
    total: Int,
    /// The exclusive continuation, including empty scanned windows.
    next: Option(PendingCursor),
  )
}

/// Materialized inputs with a cursor advancing over all scanned message entries.
pub type HistoryPage {
  HistoryPage(
    /// The caller-owned rows copied from this window.
    items: List(Input),
    /// The exclusive continuation, including empty scanned windows.
    next: Option(HistoryCursor),
  )
}

/// A stable retry identity and the complete admitted body.
pub type Request {
  Request(
    /// The authenticated sending session.
    source_session: SessionId,
    /// The authenticated sending strand.
    source_strand: String,
    /// The granted recipient strand.
    target_strand: String,
    /// The sender-chosen stable retry identity.
    message_id: String,
    /// The complete admitted text.
    body: String,
  )
}

/// An admission receipt proves durable acceptance, never consumption or reading.
pub type Receipt {
  Admitted(
    /// The exact admitted identity and body.
    request: Request,
    /// Observed source metadata, absent when the host supplied null.
    source: Option(Metadata),
  )
}

/// One retained receipt and its position in the global bounded scan.
pub type ReceivedReceipt {
  ReceivedReceipt(
    /// The global scanned receipt position.
    cursor: ReceiptCursor,
    /// The retained admission record.
    receipt: Receipt,
  )
}

/// Foreign-only pages still carry the cursor needed to make progress.
pub type ReceiptPage {
  ReceiptPage(
    /// The caller-owned rows copied from this window.
    items: List(ReceivedReceipt),
    /// The exclusive continuation, including empty scanned windows.
    next: Option(ReceiptCursor),
  )
}

/// Owner-granted permission to wake an idle recipient.
pub type Wake {
  /// Delivery requires an already active recipient.
  BusyOnly

  /// Delivery may start a new recipient operation.
  MayWake
}

/// Catalogue lifecycle observations are separate from model activity.
pub type Lifecycle {
  /// The catalogue holds a reservation without an initialized store.
  Reserved

  /// The saved session is not currently resident.
  Saved

  /// A manager operation is assembling the resident.
  Opening(
    /// The observed operation or manager transition identity.
    operation: String,
  )

  /// The resident is identified by its manager incarnation.
  Resident(
    /// The resident process incarnation token.
    incarnation: String,
  )

  /// A manager operation is stopping the resident.
  Stopping(
    /// The observed operation or manager transition identity.
    operation: String,
  )

  /// Recovery requires operator intervention.
  RecoveryBlocked
}

/// Catalogue metadata has a closed envelope; custom host metadata remains open.
pub type Metadata {
  Catalogue(
    /// The canonical session identity.
    session: SessionId,
    /// The catalogue workspace path.
    workspace: String,
    /// The catalogue display name.
    name: String,
    /// The recorded creation timestamp.
    created_at: Int,
    /// The catalogue lifecycle observation.
    status: Lifecycle,
  )

  /// Catalogue lookup failed without removing the outgoing link.
  MetadataUnavailable(
    /// The explanatory diagnostic.
    reason: String,
  )

  /// A custom host supplies an intentionally extensible metadata value.
  CustomMetadata(
    /// The host-provided custom metadata value.
    value: Value,
  )
}

/// One terminal observation; outcome remains host-rendered diagnostic text.
pub type Terminal {
  Terminal(
    /// The durable observation revision.
    commit_sequence: Int,
    /// The observed operation or manager transition identity.
    operation: OpId,
    /// The host-rendered terminal diagnostic.
    outcome: String,
  )
}

/// A model claim is attributed separately from host-observed state.
pub type ModelClaim {
  ModelClaim(
    /// The claim attribution supplied by the host.
    author: String,
    /// The open model-authored description.
    description: Value,
  )
}

/// Stable observed activity with open model claims and git observation payloads.
pub type Activity {
  Activity(
    /// The observed or exported strand name.
    strand: String,
    /// The durable strand-state revision.
    state_commit_sequence: Int,
    /// The active operation, if one exists.
    current_operation: Option(OpId),
    /// The latest terminal observation, if any.
    last_terminal: Option(Terminal),
    /// The separately attributed model observation.
    model_claim: ModelClaim,
    /// The open git-observation payload.
    git_observation: Value,
  )
}

/// One strand explicitly exported to this sender.
pub type Export {
  Export(
    /// The observed or exported strand name.
    strand: String,
    /// The observed parent strand, if present.
    parent: Option(String),
    /// The active operation, if one exists.
    current_operation: Option(OpId),
    /// The owner-granted idle wake permission.
    wake: Wake,
    /// The host-observed activity envelope.
    activity: Activity,
  )
}

/// Resident resolution can fail without removing an authorized link.
pub type Exports {
  /// The resident returned its authorized strand exports.
  Exported(
    /// The explicitly exported strands.
    strands: List(Export),
  )

  /// No current resident was resolved.
  NotResident

  /// The resident endpoint refused export discovery.
  ExportsUnavailable(
    /// The explanatory diagnostic.
    reason: String,
  )
}

/// One authorized outgoing link, never an inbound mailbox row.
pub type Link {
  Link(
    /// The canonical session identity.
    session: SessionId,
    /// The granted recipient strand.
    target_strand: String,
    /// The catalogue or custom host metadata.
    metadata: Metadata,
    /// The resident export observation.
    exports: Exports,
  )
}

/// Parses a canonical session identity for sending or exact receipt lookup.
///
/// ## Examples
///
/// ```gleam
/// // peer.parse_session_id(saved_session)
/// ```
pub fn parse_session_id(text: String) -> Result(SessionId, PeerError) {
  ids.parse_session_id(text)
  |> result.replace_error(InvalidSelector("invalid session ID"))
}

/// Renders an identity for persistence or display.
///
/// ## Examples
///
/// ```gleam
/// // peer.session_id_to_string(session)
/// ```
pub fn session_id_to_string(id: SessionId) -> String {
  ids.session_id_to_string(id)
}

/// Starts a fresh traversal of current pending inputs.
///
/// ## Examples
///
/// ```gleam
/// peer.first_pending()
/// ```
pub fn first_pending() -> PendingCursor {
  PendingCursor("")
}

/// Restores a pending cursor from a valid entry identity.
///
/// ## Examples
///
/// ```gleam
/// // peer.pending_after(entry)
/// ```
pub fn pending_after(entry: EntryId) -> PendingCursor {
  PendingCursor(strand.entry_id_to_string(entry))
}

/// Starts from the caller's current transcript leaf.
///
/// ## Examples
///
/// ```gleam
/// peer.first_history()
/// ```
pub fn first_history() -> HistoryCursor {
  HistoryCursor(0)
}

/// Restores a positive exclusive transcript sequence cursor.
///
/// ## Examples
///
/// ```gleam
/// peer.history_before(42)
/// ```
pub fn history_before(sequence: Int) -> Result(HistoryCursor, PeerError) {
  case sequence > 0 {
    True -> Ok(HistoryCursor(sequence))
    False -> Error(InvalidSelector("history cursor must be positive"))
  }
}

/// Starts a fresh scan; receipt hash cursors are not arrival watermarks.
///
/// ## Examples
///
/// ```gleam
/// peer.first_receipt()
/// ```
pub fn first_receipt() -> ReceiptCursor {
  ReceiptCursor("")
}

/// Restores one exact receipt-key cursor without admitting arbitrary prefixes.
///
/// ## Examples
///
/// ```gleam
/// // peer.receipt_after(saved_cursor)
/// ```
pub fn receipt_after(text: String) -> Result(ReceiptCursor, PeerError) {
  let prefix = "client/peers/receipt/sha256-"
  let suffix = string.drop_start(text, string.length(prefix))
  case
    string.starts_with(text, prefix)
    && string.length(suffix) == 64
    && list.all(string.to_utf_codepoints(suffix), fn(point) {
      let n = string.utf_codepoint_to_int(point)
      n >= 48 && n <= 57 || n >= 97 && n <= 102
    })
  {
    True -> Ok(ReceiptCursor(text))
    False -> Error(InvalidSelector("invalid receipt cursor"))
  }
}

/// Renders a receipt cursor for persistence without changing its meaning.
///
/// ## Examples
///
/// ```gleam
/// peer.receipt_cursor_text(peer.first_receipt()) == ""
/// ```
pub fn receipt_cursor_text(cursor: ReceiptCursor) -> String {
  let ReceiptCursor(text) = cursor
  text
}

/// Returns authorized outgoing links; an empty list says nothing about inboxes.
///
/// ## Examples
///
/// ```gleam
/// peer.roster()
/// ```
pub fn roster() -> Result(List(Link), PeerError) {
  use value <- result.try(call("peer.roster", wire.args([])))
  decode_list(value, decode_link) |> result.map_error(PeerResultMalformed)
}

/// Admits a stable retry identity; reuse it only for the same recipient and body.
///
/// ## Examples
///
/// ```gleam
/// // peer.send(session: recipient, strand: "main", message_id: "review-1", text: "Ready.")
/// ```
pub fn send(
  session session: SessionId,
  strand strand: String,
  message_id id: String,
  text body: String,
) -> Result(Receipt, PeerError) {
  use value <- result.try(call(
    "peer.send",
    wire.args([
      #("session", wire.string(session_id_to_string(session))),
      #("strand", wire.string(strand)),
      #("message_id", wire.string(id)),
      #("text", wire.string(body)),
    ]),
  ))
  decode_receipt(value) |> result.map_error(PeerResultMalformed)
}

/// Pages current pending inputs without consuming them; follow next on empty pages.
///
/// ## Examples
///
/// ```gleam
/// peer.inbox(after: peer.first_pending(), limit: 12)
/// ```
pub fn inbox(
  after after: PendingCursor,
  limit limit: Int,
) -> Result(InboxPage, PeerError) {
  let PendingCursor(after) = after
  use value <- result.try(call(
    "peer.inbox",
    wire.args([#("after", wire.string(after)), #("limit", wire.int(limit))]),
  ))
  decode_inbox(value) |> result.map_error(PeerResultMalformed)
}

/// Reads a caller-owned pending or materialized input; absence is None.
///
/// ## Examples
///
/// ```gleam
/// // peer.inbox_get(id: entry)
/// ```
pub fn inbox_get(id id: EntryId) -> Result(Option(Input), PeerError) {
  use value <- result.try(call(
    "peer.inbox_get",
    wire.args([#("id", wire.string(strand.entry_id_to_string(id)))]),
  ))
  decode_optional(value, decode_input) |> result.map_error(PeerResultMalformed)
}

/// Pages materialized inputs; scanned assistant messages may produce empty pages.
///
/// ## Examples
///
/// ```gleam
/// peer.history(before: peer.first_history(), limit: 64)
/// ```
pub fn history(
  before before: HistoryCursor,
  limit limit: Int,
) -> Result(HistoryPage, PeerError) {
  let HistoryCursor(before) = before
  use value <- result.try(call(
    "peer.history",
    wire.args([#("before", wire.int(before)), #("limit", wire.int(limit))]),
  ))
  use items <- result.try(
    wire.array_of(value, "items", decode_materialized)
    |> result.map_error(PeerResultMalformed),
  )
  use next <- result.try(
    optional_field(value, "next", decode_history_cursor)
    |> result.map_error(PeerResultMalformed),
  )
  Ok(HistoryPage(items:, next:))
}

/// Pages durable admission receipts; rescan and reconcile IDs for new admissions.
///
/// ## Examples
///
/// ```gleam
/// peer.received(after: peer.first_receipt(), limit: 64)
/// ```
pub fn received(
  after after: ReceiptCursor,
  limit limit: Int,
) -> Result(ReceiptPage, PeerError) {
  let ReceiptCursor(after) = after
  use value <- result.try(call(
    "peer.received",
    wire.args([#("after", wire.string(after)), #("limit", wire.int(limit))]),
  ))
  use items <- result.try(
    wire.array_of(value, "items", decode_received)
    |> result.map_error(PeerResultMalformed),
  )
  use next <- result.try(
    optional_field(value, "next", decode_receipt_cursor)
    |> result.map_error(PeerResultMalformed),
  )
  Ok(ReceiptPage(items:, next:))
}

/// Looks up an existing receipt only when addressed to the caller; absence is None.
///
/// ## Examples
///
/// ```gleam
/// // peer.received_get(source_session: source, source_strand: "reviewer", message_id: "review-1")
/// ```
pub fn received_get(
  source_session source: SessionId,
  source_strand strand: String,
  message_id id: String,
) -> Result(Option(Receipt), PeerError) {
  receipt_call(
    "peer.received_get",
    wire.args([
      #("source_session", wire.string(session_id_to_string(source))),
      #("source_strand", wire.string(strand)),
      #("message_id", wire.string(id)),
    ]),
  )
}

/// Reads a linked resident recipient's receipt with host-bound sender identity.
///
/// ## Examples
///
/// ```gleam
/// // peer.sent_receipt(session: recipient, message_id: "review-1")
/// ```
pub fn sent_receipt(
  session session: SessionId,
  message_id id: String,
) -> Result(Option(Receipt), PeerError) {
  receipt_call(
    "peer.sent_receipt",
    wire.args([
      #("session", wire.string(session_id_to_string(session))),
      #("message_id", wire.string(id)),
    ]),
  )
}

fn receipt_call(
  name: String,
  args: Value,
) -> Result(Option(Receipt), PeerError) {
  use value <- result.try(call(name, args))
  decode_optional(value, decode_receipt)
  |> result.map_error(PeerResultMalformed)
}

// JSON is the existing host transport, decoded once before exposing any fields.
fn call(name: String, args: Value) -> Result(Value, PeerError) {
  use value <- result.try(
    dispatch.call(name, args) |> result.map_error(map_error),
  )
  case value {
    msgpack.StringValue(text) ->
      cap_report.decode_json(text) |> result.map_error(PeerResultMalformed)
    _ -> Error(PeerResultMalformed("expected JSON response text"))
  }
}

fn map_error(error: channel.CallError) -> PeerError {
  case error {
    channel.Denied(code:, message:) -> PeerDenied(code:, message:)
    channel.Unreachable(reason:) -> PeerUnavailable(reason:)
  }
}

fn decode_inbox(value: Value) -> Result(InboxPage, String) {
  use revision <- result.try(nonnegative(value, "revision"))
  use total <- result.try(nonnegative(value, "total"))
  use items <- result.try(wire.array_of(value, "items", decode_pending))
  use next <- result.try(optional_field(value, "next", decode_pending_cursor))
  Ok(InboxPage(revision:, items:, total:, next:))
}

fn decode_input(value: Value) -> Result(Input, String) {
  use queue <- result.try(wire.string_field(value, "queue"))
  case queue {
    "materialized" -> decode_materialized(value)
    _ -> decode_pending(value)
  }
}

fn decode_pending(value: Value) -> Result(Input, String) {
  use id <- result.try(entry_field(value, "id"))
  use queue <- result.try(wire.string_field(value, "queue"))
  use queue <- result.try(case queue {
    "next_run" -> Ok(NextRun)
    "steer" -> Ok(Steer)
    "follow_up" -> Ok(FollowUp)
    "cancelled_steer" -> Ok(CancelledSteer)
    "cancelled_follow_up" -> Ok(CancelledFollowUp)
    _ -> Error("unknown pending queue")
  })
  use payload <- result.try(wire.field(value, "payload"))
  Ok(Pending(id:, queue:, payload:))
}

fn decode_materialized(value: Value) -> Result(Input, String) {
  use queue <- result.try(wire.string_field(value, "queue"))
  use _ <- result.try(case queue == "materialized" {
    True -> Ok(Nil)
    False -> Error("expected materialized input")
  })
  use id <- result.try(entry_field(value, "id"))
  use entry <- result.try(wire.field(value, "entry"))
  Ok(Materialized(id:, entry:))
}

fn decode_receipt(value: Value) -> Result(Receipt, String) {
  use admitted <- result.try(wire.bool_field(value, "admitted"))
  use _ <- result.try(case admitted {
    True -> Ok(Nil)
    False -> Error("receipt was not admitted")
  })
  use request <- result.try(wire.field(value, "request"))
  use source_session <- result.try(session_field(request, "source_session"))
  use source_strand <- result.try(wire.string_field(request, "source_strand"))
  use target_strand <- result.try(wire.string_field(request, "target_strand"))
  use message_id <- result.try(wire.string_field(request, "message_id"))
  use body <- result.try(wire.string_field(request, "body"))
  use source <- result.try(wire.field(value, "source"))
  use source <- result.try(decode_optional(source, decode_metadata))
  Ok(Admitted(
    Request(source_session:, source_strand:, target_strand:, message_id:, body:),
    source:,
  ))
}

/// Observed source metadata, absent when the host supplied null.
fn decode_received(value: Value) -> Result(ReceivedReceipt, String) {
  use cursor <- result.try(wire.field(value, "cursor"))
  use cursor <- result.try(decode_receipt_cursor(cursor))
  use receipt <- result.try(wire.field(value, "receipt"))
  use receipt <- result.try(decode_receipt(receipt))
  Ok(ReceivedReceipt(cursor:, receipt:))
}

fn decode_link(value: Value) -> Result(Link, String) {
  use session <- result.try(session_field(value, "session"))
  use target_strand <- result.try(wire.string_field(value, "target_strand"))
  use metadata <- result.try(wire.field(value, "metadata"))
  use metadata <- result.try(decode_metadata(metadata))
  use exports <- result.try(wire.field(value, "exported_strands"))
  use exports <- result.try(case exports {
    msgpack.NilValue -> Ok(NotResident)
    msgpack.ArrayValue(_) ->
      decode_list(exports, decode_export) |> result.map(Exported)
    _ ->
      wire.string_field(exports, "unavailable")
      |> result.map(ExportsUnavailable)
  })
  Ok(Link(session:, target_strand:, metadata:, exports:))
}

fn decode_metadata(value: Value) -> Result(Metadata, String) {
  // Metadata is open JSON; only complete known envelopes claim a typed shape.
  let known = case value {
    msgpack.MapValue([_]) ->
      wire.string_field(value, "unavailable") |> result.map(MetadataUnavailable)
    msgpack.MapValue([_, _, _, _, _]) -> decode_catalogue(value)
    _ -> Error("custom metadata")
  }
  case known {
    Ok(metadata) -> Ok(metadata)
    Error(_) -> Ok(CustomMetadata(value))
  }
}

fn decode_catalogue(value: Value) -> Result(Metadata, String) {
  use session <- result.try(session_field(value, "session_id"))
  use workspace <- result.try(wire.string_field(value, "workspace"))
  use name <- result.try(wire.string_field(value, "name"))
  use created_at <- result.try(nonnegative(value, "created_at"))
  use status <- result.try(wire.field(value, "status"))
  use status <- result.try(decode_lifecycle(status))
  Ok(Catalogue(session:, workspace:, name:, created_at:, status:))
}

fn decode_lifecycle(value: Value) -> Result(Lifecycle, String) {
  use state <- result.try(wire.string_field(value, "state"))
  case state {
    "reserved" -> Ok(Reserved)
    "saved" -> Ok(Saved)
    "opening" -> wire.string_field(value, "operation") |> result.map(Opening)
    "resident" ->
      wire.string_field(value, "incarnation") |> result.map(Resident)
    "stopping" -> wire.string_field(value, "operation") |> result.map(Stopping)
    "recovery_blocked" -> Ok(RecoveryBlocked)
    _ -> Error("unknown peer lifecycle")
  }
}

fn decode_export(value: Value) -> Result(Export, String) {
  use strand <- result.try(wire.string_field(value, "strand"))
  use parent <- result.try(optional_field(value, "parent", as_text))
  use current_operation <- result.try(optional_field(
    value,
    "current_operation",
    as_op,
  ))
  use wake <- result.try(wire.string_field(value, "wake"))
  use wake <- result.try(case wake {
    "busy_only" -> Ok(BusyOnly)
    "may_wake" -> Ok(MayWake)
    _ -> Error("unknown peer wake permission")
  })
  use activity <- result.try(wire.field(value, "activity"))
  use activity <- result.try(decode_activity(activity))
  Ok(Export(strand:, parent:, current_operation:, wake:, activity:))
}

fn decode_activity(value: Value) -> Result(Activity, String) {
  use strand <- result.try(wire.string_field(value, "strand"))
  use state_commit_sequence <- result.try(nonnegative(
    value,
    "state_commit_sequence",
  ))
  use current_operation <- result.try(optional_field(
    value,
    "current_operation",
    as_op,
  ))
  use last_terminal <- result.try(optional_field(
    value,
    "last_terminal",
    decode_terminal,
  ))
  use model_claim <- result.try(wire.field(value, "model_claim"))
  use author <- result.try(wire.string_field(model_claim, "author"))
  use description <- result.try(wire.field(model_claim, "description"))
  use git_observation <- result.try(wire.field(value, "git_observation"))
  Ok(Activity(
    strand:,
    state_commit_sequence:,
    current_operation:,
    last_terminal:,
    model_claim: ModelClaim(author:, description:),
    git_observation:,
  ))
}

/// The observed or exported strand name.
/// The durable strand-state revision.
/// The active operation, if one exists.
/// The latest terminal observation, if any.
/// The separately attributed model observation.
/// The open git-observation payload.
fn decode_terminal(value: Value) -> Result(Terminal, String) {
  use commit_sequence <- result.try(nonnegative(value, "commit_sequence"))
  use operation <- result.try(wire.field(value, "operation"))
  use operation <- result.try(as_op(operation))
  use outcome <- result.try(wire.string_field(value, "outcome"))
  Ok(Terminal(commit_sequence:, operation:, outcome:))
}

// Required optional fields distinguish explicit absence from malformed envelopes.
fn optional_field(
  value: Value,
  key: String,
  decode: fn(Value) -> Result(a, String),
) -> Result(Option(a), String) {
  use found <- result.try(wire.field(value, key))
  decode_optional(found, decode)
}

fn decode_optional(
  value: Value,
  decode: fn(Value) -> Result(a, String),
) -> Result(Option(a), String) {
  case value {
    msgpack.NilValue -> Ok(None)
    _ -> decode(value) |> result.map(Some)
  }
}

fn decode_list(
  value: Value,
  decode: fn(Value) -> Result(a, String),
) -> Result(List(a), String) {
  case value {
    msgpack.ArrayValue(items) -> list.try_map(items, decode)
    _ -> Error("expected array")
  }
}

fn as_text(value: Value) -> Result(String, String) {
  case value {
    msgpack.StringValue(text) -> Ok(text)
    _ -> Error("expected text")
  }
}

fn as_op(value: Value) -> Result(OpId, String) {
  use text <- result.try(as_text(value))
  strand.parse_op_id(text)
}

fn session_field(value: Value, key: String) -> Result(SessionId, String) {
  use text <- result.try(wire.string_field(value, key))
  ids.parse_session_id(text) |> result.replace_error("invalid session ID")
}

fn entry_field(value: Value, key: String) -> Result(EntryId, String) {
  use text <- result.try(wire.string_field(value, key))
  strand.parse_entry_id(text)
}

fn decode_pending_cursor(value: Value) -> Result(PendingCursor, String) {
  use text <- result.try(as_text(value))
  strand.parse_entry_id(text) |> result.map(pending_after)
}

fn decode_history_cursor(value: Value) -> Result(HistoryCursor, String) {
  case value {
    msgpack.IntValue(sequence) if sequence > 0 -> Ok(HistoryCursor(sequence))
    _ -> Error("invalid history cursor")
  }
}

fn decode_receipt_cursor(value: Value) -> Result(ReceiptCursor, String) {
  use text <- result.try(as_text(value))
  receipt_after(text) |> result.replace_error("invalid receipt cursor")
}

fn nonnegative(value: Value, key: String) -> Result(Int, String) {
  use n <- result.try(wire.int_field(value, key))
  case n >= 0 {
    True -> Ok(n)
    False -> Error("negative " <> key)
  }
}

/// Parses a persisted message identity without importing another capability.
///
/// ## Examples
///
/// ```gleam
/// // peer.parse_entry_id(saved_entry)
/// ```
pub fn parse_entry_id(text: String) -> Result(EntryId, PeerError) {
  ids.parse_entry_id(text)
  |> result.replace_error(InvalidSelector("invalid entry ID"))
}

/// Renders a message identity for persistence.
///
/// ## Examples
///
/// ```gleam
/// // peer.entry_id_to_string(entry)
/// ```
pub fn entry_id_to_string(entry: EntryId) -> String {
  ids.entry_id_to_string(entry)
}

/// Parses an observed operation identity.
///
/// ## Examples
///
/// ```gleam
/// // peer.parse_op_id(saved_operation)
/// ```
pub fn parse_op_id(text: String) -> Result(OpId, PeerError) {
  ids.parse_op_id(text)
  |> result.replace_error(InvalidSelector("invalid operation ID"))
}

/// Renders an observed operation identity for persistence.
///
/// ## Examples
///
/// ```gleam
/// // peer.op_id_to_string(operation)
/// ```
pub fn op_id_to_string(operation: OpId) -> String {
  ids.op_id_to_string(operation)
}

/// Renders a pending cursor for persistence; empty means a fresh scan.
///
/// ## Examples
///
/// ```gleam
/// peer.pending_cursor_text(peer.first_pending()) == ""
/// ```
pub fn pending_cursor_text(cursor: PendingCursor) -> String {
  let PendingCursor(text) = cursor
  text
}

/// Renders the transcript sequence for persistence; zero means the current leaf.
///
/// ## Examples
///
/// ```gleam
/// peer.history_sequence(peer.first_history()) == 0
/// ```
pub fn history_sequence(cursor: HistoryCursor) -> Int {
  let HistoryCursor(sequence) = cursor
  sequence
}
