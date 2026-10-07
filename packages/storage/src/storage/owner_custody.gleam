//// Owner-held immutable outgoing requests and exact final tool outcomes.
////
//// This database is separate from frozen session SQLite. A serialized owner
//// uses one handle: it commits admission before making bytes sendable, commits
//// terminal child bytes before a receipt, and commits the final opaque outcome
//// before returning from the live callback. Child evidence never reconstructs
//// the final report. Collection reads the reserved session entry and validates
//// that exact outcome before replacing retained bytes with permanent fences.
////
//// Handles contain no network and create no processes. The assembly must keep
//// a handle on one serialized custodian, and invoke it from an effect, never a
//// strand handler. Every transaction uses the existing sqlight binding and
//// named Parrot queries. Header reads and persistent reservations bound payload
//// materialization before the binding or an outcome decoder sees any blob.
////
//// ## Flow
////
//// `open` → `initialize` → `admit_fresh` → `admit_once` → `finish` → `lookup`
////
//// `tool_row` and `child_row` validate headers and the full unused payload
//// allowance before named value queries. `admit_child` freezes the original
//// UUID and request; `cancel_child` uses `cancellation_bytes` to reserve a
//// bounded origin fence before a UUID exists. `receive_child` retains exact
//// output and terminal bytes before receipt. `validate_request` compares full
//// immutable scope without admitting missing evidence. `verify_commit` reads
//// actual reserved session storage before `collect` freezes permanent fences.
//// `service_request` → `admit_service_child` → `admit_offer` →
//// `admit_command_child` retains exact service/offer/native associations.
//// `command_offer_for_origin` reads the indexed historical mapping;
//// `check_offer_header` guards value loading and `check_offer_ref` checks linkage.
//// `cancel_service` fences them in one transaction. `collection_ready` defers
//// deletion even with no offer, until physical recovery custody is transferred.
//// `discharge` releases run custody only after exact live outcome and drain.
//// `admit_fresh_with_profile` reserves report custody before any effect.
//// `retain_report` commits checked bytes before `finish_with_reference`.
//// `validate_report_rows` checks one original report at a time before open.
//// `validate_finals` checks runtime associations before actor publication.
//// `read_report_chunk` exposes only committed immutable aligned slices.
//// `check_tool_header` bounds profile, reservation and every payload projection.
//// `initialize` uses `pragma` only for configuration metadata, never data queries.
//// `profile_name` gives the immutable final profile its persisted schema tag.

import core/command
import core/entry.{MessageEntry}
import core/ids.{type EntryId, type SessionId}
import core/json
import core/message.{type AgentMessage}
import core/register
import core/remote_tool.{type ChildOrigin, type ToolKey}
import core/report_value
import gleam/bit_array
import gleam/bool
import gleam/dict
import gleam/dynamic/decode.{type Decoder}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import parrot/dev
import sqlight
import storage/owner_custody_schema
import storage/sql
import storage/sqlite_policy
import storage/storage.{type Storage} as session_storage_api

/// Validated journal ceilings, persisted and compared on every reopen.
pub opaque type Limits {
  Limits(tools: Int, children: Int, bytes: Int, payload: Int)
}

/// Bytes whose maximum size was checked before journal mutation.
/// Payload contents remain opaque to storage, including runtime ToolOutcome.
pub opaque type Payload {
  Payload(bytes: BitArray)
}

/// A bounded semantic invocation admitted only through workspace child methods.
pub opaque type WorkspaceRequest {
  /// Exact bytes, with no ephemeral content references.
  WorkspaceRequest(
    /// Exact bytes admitted under the configured invocation ceiling.
    payload: Payload,
  )
}

/// A bounded semantic completion admitted only through workspace receipt methods.
pub opaque type WorkspaceCompletion {
  /// Exact bytes retained before durable acknowledgement.
  WorkspaceCompletion(
    /// Exact bytes admitted under the configured completion ceiling.
    payload: Payload,
  )
}

/// Complete bounded outer service identity and exact input bytes.
pub opaque type ServiceRequest {
  /// Constructed only after framing the complete bounded original identity.
  ServiceRequest(
    /// Full original parent, scope, coordinates and service UUID.
    key: command.ServiceKey,
    /// Complete bounded envelope, never a partial native request.
    request: WorkspaceRequest,
  )
}

/// Immutable bounded offer bytes, with their original service/command link.
/// Storage preserves content; broker acceptance owns policy and purpose checks.
pub opaque type CommandOfferPayload {
  /// Immutable offer custody supplies no broker clearance or send permission.
  CommandOfferPayload(
    /// Original service and its closed native command purpose.
    ref: command.CommandRef,
    /// Caller-computed canonical digest, checked for bounded spelling.
    digest: String,
    /// Complete bounded opaque offer content.
    bytes: BitArray,
  )
}

/// A serialized handle for one session's custody database.
pub opaque type Store {
  Store(
    connection: sqlight.Connection,
    session: SessionId,
    limits: Limits,
    reports: ReportHash,
  )
}

/// Trusted assembly selects the immutable final quota before any effect.
pub type FinalProfile {
  /// Ordinary tools retain their configured existing opaque final allowance.
  OrdinaryFinal

  /// Complete code-mode reports reserve the complete bundle and bounded final.
  CodeModeReportV1
}

/// The exact report, bounded final message and stored profile bookkeeping charge.
pub const report_final_allowance = 17_301_648

/// One checked aligned report slice; the reference never grants read authority.
pub type ReportChunk {
  /// A slice checked against the original stored digest, length and identity.
  ReportChunk(
    /// Original session, result entry, canonical digest and complete byte length.
    reference: report_value.ReportRef,
    /// Checked aligned offset into this immutable bundle.
    offset: Int,
    /// At most 65,536 bytes, with the final slice possibly shorter.
    bytes: BitArray,
  )
}

type ReportHash {
  OrdinaryStore
  ReportsEnabled(sha256: fn(BitArray) -> BitArray)
}

/// A refusal always leaves previous durable evidence intact.
pub type Error {
  /// A supplied identity, request, outcome or journal binding changed.
  Conflict

  /// No evidence has been admitted under this identity.
  Missing

  /// Capacity is exhausted; admission has not mutated storage.
  Capacity

  /// Evidence is frozen and can never authorize another send.
  Frozen

  /// An input exceeds its declared bound or a persisted row is malformed.
  Invalid(reason: String)

  /// Physical service recovery has not transferred to independently retained custody.
  CollectionPending

  /// SQLite refused the transaction or read.
  Unavailable(reason: String)
}

/// The only final recovery authority is the exact finalized payload.
pub type Evidence {
  /// The original request and arguments survive, but no final tool report does.
  AwaitingFinal(request: Payload, arguments: Payload, child_count: Int)

  /// The final tool outcome survived independently of the original callback.
  FinalOutcome(outcome: Payload)

  /// Collection committed after reserved-entry readback; sending is fenced.
  Collected
}

/// The session entry's durable termination disposition.
pub type Termination {
  /// The finalized result permits the operation to continue.
  Continues

  /// The finalized result terminates its operation.
  Terminates
}

/// The exact message and termination flag read from the reserved session entry.
pub type ResultReadback {
  ResultReadback(
    /// The committed finalized tool-result message.
    message: AgentMessage,
    /// The committed entry's termination disposition.
    termination: Termination,
  )
}

/// A readback proof bound to this key and the exact final outcome bytes.
/// Only verify_commit constructs it; a broker release supplies no evidence.
pub opaque type CommittedResult {
  CommittedResult(key: ToolKey, outcome: Payload)
}

/// Fresh dispatch permission is distinct from an exact retained retry.
pub type Admission {
  /// This transaction created the immutable reservation.
  Fresh

  /// The existing immutable reservation matched; execution is forbidden.
  Retained
}

/// Run ownership is independent of retained or collected recovery evidence.
pub type RunCustody {
  /// Outstanding work prevents discharge and survives owner restart.
  Unreleased

  /// The live owner observed exact outcome commit and complete run delivery.
  Released
}

type ReceiptPolicy {
  NativeReceipt
  WorkspaceReceipt
}

/// Checks finite per-session row, byte and per-payload ceilings.
/// Frozen fences count toward row and byte quotas and are never evicted.
///
/// ## Examples
///
/// ```gleam
/// assert owner_custody.limits(8, 64, 1_048_576, 65_536) != Error(owner_custody.Capacity)
/// ```
pub fn limits(
  tools: Int,
  children: Int,
  bytes: Int,
  payload: Int,
) -> Result(Limits, Error) {
  case
    tools > 0
    && tools <= 4096
    && children > 0
    && children <= 65_536
    && payload > 0
    && payload <= 33_554_432
    && bytes > 0
    && bytes <= 268_435_456
  {
    True -> Ok(Limits(tools:, children:, bytes:, payload:))
    False -> Error(Invalid("invalid owner custody ceilings"))
  }
}

/// Refuses oversized bytes before they can enter a journal mutation.
///
/// ## Examples
///
/// ```gleam
/// // owner_custody.payload(limits, bytes)
/// ```
pub fn payload(limits: Limits, bytes: BitArray) -> Result(Payload, Error) {
  use <- bool.guard(
    when: bit_array.bit_size(bytes) % 8 != 0,
    return: Error(Invalid("owner payload must contain whole bytes")),
  )
  case
    bit_array.byte_size(bytes) <= limits.payload
    && bit_array.byte_size(bytes) <= 2_097_152
  {
    True -> Ok(Payload(bytes:))
    False -> Error(Capacity)
  }
}

/// Checks the configured quota and nine-MiB invocation limit before mailbox send.
///
/// ## Examples
///
/// A smaller configured quota still refuses a larger workspace invocation.
pub fn workspace_request(
  limits: Limits,
  bytes: BitArray,
) -> Result(WorkspaceRequest, Error) {
  use value <- result.try(workspace_payload(limits, bytes, 9_437_184))
  Ok(WorkspaceRequest(value))
}

/// Checks the configured quota and thirty-two-MiB completion limit.
///
/// ## Examples
///
/// `workspace_completion(limits, bytes)` never enlarges persisted limits.
pub fn workspace_completion(
  limits: Limits,
  bytes: BitArray,
) -> Result(WorkspaceCompletion, Error) {
  use value <- result.try(workspace_payload(limits, bytes, 33_554_432))
  Ok(WorkspaceCompletion(value))
}

fn workspace_payload(
  limits: Limits,
  bytes: BitArray,
  maximum: Int,
) -> Result(Payload, Error) {
  use <- bool.guard(
    when: bit_array.bit_size(bytes) % 8 != 0,
    return: Error(Invalid("workspace payload must contain whole bytes")),
  )
  case
    bit_array.byte_size(bytes) <= limits.payload
    && bit_array.byte_size(bytes) <= maximum
  {
    True -> Ok(Payload(bytes))
    False -> Error(Capacity)
  }
}

/// Gives an admitted payload to its bounded total decoder or transport writer.
///
/// ## Examples
///
/// ```gleam
/// // owner_custody.bytes(payload)
/// ```
pub fn bytes(payload: Payload) -> BitArray {
  payload.bytes
}

/// Opens only this database format, binding the session and ceilings durably.
/// The caller owns serialization and close; open never migrates session SQLite.
///
/// ## Examples
///
/// ```gleam
/// // owner_custody.open(path, session_id, limits)
/// ```
pub fn open(
  path: String,
  session: SessionId,
  limits: Limits,
) -> Result(Store, Error) {
  open_store(path, session, limits, OrdinaryStore)
}

/// Opens the same owner format with trusted SHA-256 supplied by host assembly.
/// Every existing report is checked before a serialized handle is returned.
///
/// ## Examples
///
/// `open_with_reports(path, session, limits, bootstrap.sha256)` adds no host dependency.
pub fn open_with_reports(
  path: String,
  session: SessionId,
  limits: Limits,
  sha256: fn(BitArray) -> BitArray,
) -> Result(Store, Error) {
  open_store(path, session, limits, ReportsEnabled(sha256))
}

fn open_store(
  path: String,
  session: SessionId,
  limits: Limits,
  reports: ReportHash,
) -> Result(Store, Error) {
  use Nil <- result.try(
    sqlite_policy.refusing_unopenable_path(path) |> result.map_error(Invalid),
  )
  use connection <- result.try(
    sqlight.open(path) |> result.map_error(database_error),
  )
  let store = Store(connection:, session:, limits:, reports:)
  case initialize(store) {
    Ok(Nil) -> Ok(store)
    Error(error) -> {
      let _closed = sqlight.close(connection)
      Error(error)
    }
  }
}

/// Closes the serialized handle after its owner has stopped using it.
///
/// ## Examples
///
/// ```gleam
/// // owner_custody.close(store)
/// ```
pub fn close(store: Store) -> Result(Nil, Error) {
  sqlight.close(store.connection) |> result.map_error(database_error)
}

/// Commits exact immutable tool content and reserves the full final payload.
/// A successful return is the admission barrier before any possible send.
/// Exact retries are readbacks; changed identity or payload fails closed.
///
/// ## Examples
///
/// ```gleam
/// // owner_custody.admit(store, key, arguments, outgoing_request)
/// ```
pub fn admit(
  store: Store,
  key: ToolKey,
  arguments: Payload,
  request: Payload,
) -> Result(Nil, Error) {
  admit_once(store, key, arguments, request, OrdinaryFinal)
  |> result.replace(Nil)
}

fn admit_once(
  store: Store,
  key: ToolKey,
  arguments: Payload,
  request: Payload,
  profile: FinalProfile,
) -> Result(Admission, Error) {
  use Nil <- result.try(same_session(store, remote_tool.session(key)))
  use Nil <- result.try(check_payload(store, arguments))
  use Nil <- result.try(check_payload(store, request))
  transaction(store, fn() {
    use existing <- result.try(tool_row(store, key))
    case existing {
      None -> {
        let identity = identity_bytes(key)
        let reserved =
          bit_array.byte_size(identity)
          + string.byte_size(remote_tool.address(key))
          + bit_array.byte_size(arguments.bytes)
          + bit_array.byte_size(request.bytes)
          + final_allowance(store, profile)
          + 128
        use Nil <- result.try(report_enabled(store, profile))
        use Nil <- result.try(reserve(store, 1, 0, reserved))
        statement(
          store,
          sql.insert_owner_tool(
            remote_tool.address(key),
            identity,
            ids.entry_id_to_string(remote_tool.result_entry(key)),
            arguments.bytes,
            request.bytes,
            profile_name(profile),
            final_allowance(store, profile),
            reserved,
          ),
        )
        |> result.replace(Fresh)
      }
      Some(#("frozen", _row)) -> Error(Frozen)
      Some(#("retained", row)) -> {
        use retained_profile <- result.try(final_profile(store, key))
        use <- bool.guard(
          when: retained_profile != profile,
          return: Error(Conflict),
        )
        use Nil <- result.try(equal(row.arguments, arguments.bytes))
        equal(row.request, request.bytes) |> result.replace(Retained)
      }
      Some(#(_, _)) -> Error(Invalid("invalid owner tool state"))
    }
  })
}

/// Atomically reserves once and reports whether a runner may begin.
///
/// ## Examples
///
/// ```gleam
/// // owner_custody.admit_fresh(store, key, arguments, request)
/// ```
pub fn admit_fresh(
  store: Store,
  key: ToolKey,
  arguments: Payload,
  request: Payload,
) -> Result(Admission, Error) {
  admit_fresh_with_profile(store, key, arguments, request, OrdinaryFinal)
}

/// Reserves the trusted immutable profile before Fresh can start a worker.
/// Retained retries must match the original profile and cannot rerun effects.
///
/// ## Examples
///
/// `admit_fresh_with_profile(store, key, args, request, CodeModeReportV1)` reserves 17,301,648 final bytes.
pub fn admit_fresh_with_profile(
  store: Store,
  key: ToolKey,
  arguments: Payload,
  request: Payload,
  profile: FinalProfile,
) -> Result(Admission, Error) {
  admit_once(store, key, arguments, request, profile)
}

/// Reads complete evidence; it never reconstructs an outcome from children.
/// A missing managed record must be reported unknown by the binding adapter.
///
/// ## Examples
///
/// ```gleam
/// // owner_custody.lookup(store, key)
/// ```
pub fn lookup(store: Store, key: ToolKey) -> Result(Evidence, Error) {
  use Nil <- result.try(same_session(store, remote_tool.session(key)))
  transaction(store, fn() {
    use row <- result.try(required_tool(store, key))
    case row {
      #("frozen", _) -> Ok(Collected)
      #("retained", row) ->
        case row.outcome {
          Some(outcome) -> Ok(FinalOutcome(Payload(outcome)))
          None -> {
            use count <- result.try(
              one(query(store, sql.owner_child_count(remote_tool.address(key)))),
            )
            use <- bool.guard(
              when: count.children > 64,
              return: Error(Invalid("owner child count exceeds bound")),
            )
            Ok(AwaitingFinal(
              Payload(row.request),
              Payload(row.arguments),
              count.children,
            ))
          }
        }
      #(_, _) -> Error(Invalid("invalid owner tool state"))
    }
  })
}

/// Validates immutable scope and argument bytes without admitting a missing key.
///
/// ## Examples
///
/// ```gleam
/// // owner_custody.validate_request(store, key, arguments, request)
/// ```
pub fn validate_request(
  store: Store,
  key: ToolKey,
  arguments: Payload,
  request: Payload,
) -> Result(Nil, Error) {
  use Nil <- result.try(same_session(store, remote_tool.session(key)))
  use Nil <- result.try(check_payload(store, arguments))
  use Nil <- result.try(check_payload(store, request))
  transaction(store, fn() {
    use #(_state, row) <- result.try(retained_tool(store, key))
    use Nil <- result.try(equal(row.arguments, arguments.bytes))
    equal(row.request, request.bytes)
  })
}

/// Commits an exact final outcome before the live tool callback may return.
/// A lost reply can safely retry with the same payload; another payload conflicts.
///
/// ## Examples
///
/// ```gleam
/// // owner_custody.finish(store, key, exact_outcome)
/// ```
pub fn finish(
  store: Store,
  key: ToolKey,
  outcome: Payload,
) -> Result(Nil, Error) {
  use profile <- result.try(final_profile(store, key))
  use <- bool.guard(when: profile != OrdinaryFinal, return: Error(Conflict))
  finish_with_reference(store, key, outcome, None)
}

/// Commits final bytes only after matching the already committed original report.
/// A missing report never authorizes a fabricated complete-result reference.
///
/// ## Examples
///
/// `finish_with_reference(store, key, final, Some(reference))` checks prior report custody.
pub fn finish_with_reference(
  store: Store,
  key: ToolKey,
  outcome: Payload,
  reference: Option(report_value.ReportRef),
) -> Result(Nil, Error) {
  use Nil <- result.try(same_session(store, remote_tool.session(key)))
  use Nil <- result.try(check_final_payload(store, key, outcome))
  transaction(store, fn() {
    use #(_state, row) <- result.try(retained_tool(store, key))
    use retained <- result.try(report_reference(store, key))
    use <- bool.guard(when: retained != reference, return: Error(Conflict))
    case row.outcome {
      Some(existing) -> equal(existing, outcome.bytes)
      None ->
        statement(
          store,
          sql.finish_owner_tool(Some(outcome.bytes), remote_tool.address(key)),
        )
    }
  })
}

/// Reads a bounded existence probe for unresolved work on owner startup.
/// Historical outcome bytes supply no release authority.
///
/// ## Examples
///
/// `unreleased(store)` returns `Released` only when every admitted run discharged.
pub fn unreleased(store: Store) -> Result(RunCustody, Error) {
  use row <- result.try(one(query(store, sql.owner_unreleased_run())))
  case row.unreleased {
    0 -> Ok(Released)
    1 -> Ok(Unreleased)
    _ -> Error(Invalid("invalid owner run existence result"))
  }
}

/// Releases only the exact committed outcome after the caller observes live drain.
/// The custodian owns that observation; recovery paths must never call this API.
///
/// ## Examples
///
/// `discharge(store, key, outcome)` retains custody when bytes differ or are missing.
pub fn discharge(
  store: Store,
  key: ToolKey,
  outcome: Payload,
) -> Result(Nil, Error) {
  use Nil <- result.try(same_session(store, remote_tool.session(key)))
  use Nil <- result.try(check_final_payload(store, key, outcome))
  transaction(store, fn() {
    use #(_state, row) <- result.try(retained_tool(store, key))
    use retained <- result.try(option.to_result(row.outcome, Missing))
    use Nil <- result.try(equal(retained, outcome.bytes))
    statement(
      store,
      sql.discharge_owner_run(remote_tool.address(key), Some(outcome.bytes)),
    )
  })
}

/// Reserves a stable UUIDv7 child link before a connection can submit it.
/// The caller mints once outside connections and persists the exact request.
/// Reopen reads that same link with child; compile, launch, cap and system
/// origins have disjoint typed namespaces and request IDs are globally unique.
///
/// ## Examples
///
/// ```gleam
/// // owner_custody.admit_child(store, origin, reserved_request_id, request)
/// ```
pub fn admit_child(
  store: Store,
  origin: ChildOrigin,
  request_id: EntryId,
  request: Payload,
) -> Result(Nil, Error) {
  use Nil <- result.try(check_payload(store, request))
  admit_child_payload(store, origin, request_id, request)
}

/// Reserves the full configured result allowance before workspace effects.
/// Exact UUID and complete invocation bytes must match on every retained retry.
///
/// ## Examples
///
/// `admit_workspace_child(store, origin, id, request)` commits before send.
pub fn admit_workspace_child(
  store: Store,
  origin: ChildOrigin,
  request_id: EntryId,
  request: WorkspaceRequest,
) -> Result(Nil, Error) {
  use _ <- result.try(workspace_request(store.limits, request.payload.bytes))
  admit_child_payload(store, origin, request_id, request.payload)
}

fn admit_child_payload(
  store: Store,
  origin: ChildOrigin,
  request_id: EntryId,
  request: Payload,
) -> Result(Nil, Error) {
  use Nil <- result.try(same_session(store, remote_tool.child_session(origin)))
  transaction(store, fn() {
    admit_child_inside(store, origin, request_id, request)
  })
}

fn admit_child_inside(
  store: Store,
  origin: ChildOrigin,
  request_id: EntryId,
  request: Payload,
) -> Result(Nil, Error) {
  use Nil <- result.try(parent_retained(store, origin))
  use Nil <- result.try(not_cancelled(store, origin))
  use existing <- result.try(child_row(store, origin))
  case existing {
    None -> {
      let parent = remote_tool.child_parent(origin)
      use count <- result.try(one(query(store, sql.owner_child_count(parent))))
      use <- bool.guard(when: count.children >= 64, return: Error(Capacity))
      let address = remote_tool.child_address(origin)
      let reserved =
        string.byte_size(address)
        + string.byte_size(parent)
        + 164
        + bit_array.byte_size(request.bytes)
        + store.limits.payload
      use Nil <- result.try(reserve(store, 0, 1, reserved))
      statement(
        store,
        sql.insert_owner_child(
          address,
          parent,
          Some(ids.entry_id_to_string(request_id)),
          request.bytes,
          reserved,
        ),
      )
    }
    Some(#(header, row)) -> {
      use <- bool.guard(when: header.state == "frozen", return: Error(Frozen))
      use Nil <- result.try(equal_string(
        header.request_id,
        ids.entry_id_to_string(request_id),
      ))
      equal(row.request, request.bytes)
    }
  }
}

/// Durably fences an original child before or after its UUID reservation.
/// A placeholder has no invented request ID. Existing links and bytes survive.
/// Capacity refusal must stop managed dispatch; it is not a cancellation receipt.
///
/// ## Examples
///
/// ```gleam
/// // owner_custody.cancel_child(store, original_origin)
/// ```
pub fn cancel_child(store: Store, origin: ChildOrigin) -> Result(Nil, Error) {
  use Nil <- result.try(same_session(store, remote_tool.child_session(origin)))
  transaction(store, fn() { cancel_child_inside(store, origin) })
}

fn cancel_child_inside(
  store: Store,
  origin: ChildOrigin,
) -> Result(Nil, Error) {
  use Nil <- result.try(parent_retained(store, origin))
  use headers <- result.try(query(
    store,
    sql.owner_child_header(remote_tool.child_address(origin)),
  ))
  use Nil <- result.try(case headers {
    [] -> {
      use count <- result.try(
        one(query(
          store,
          sql.owner_child_count(remote_tool.child_parent(origin)),
        )),
      )
      use <- bool.guard(when: count.children >= 64, return: Error(Capacity))
      reserve(store, 0, 1, cancellation_bytes(origin))
    }
    [_] -> Ok(Nil)
    [_, _, ..] -> Error(Invalid("duplicate child cancellation origin"))
  })
  statement(
    store,
    sql.cancel_owner_child(
      remote_tool.child_address(origin),
      remote_tool.child_parent(origin),
      cancellation_bytes(origin),
    ),
  )
}

fn cancellation_bytes(origin: ChildOrigin) -> Int {
  string.byte_size(remote_tool.child_address(origin))
  + string.byte_size(remote_tool.child_parent(origin))
  + 164
}

fn not_cancelled(store: Store, origin: ChildOrigin) -> Result(Nil, Error) {
  use headers <- result.try(query(
    store,
    sql.owner_child_header(remote_tool.child_address(origin)),
  ))
  case headers {
    [header] if header.state == "cancelled" -> Error(Frozen)
    [] | [_] -> Ok(Nil)
    [_, _, ..] -> Error(Invalid("duplicate child origin"))
  }
}

/// Retrieves the stable request ID, exact outgoing request and terminal bytes.
/// The caller must query/replay this ID after lost replies, never allocate another.
///
/// ## Examples
///
/// ```gleam
/// // owner_custody.child(store, origin)
/// ```
pub fn child(
  store: Store,
  origin: ChildOrigin,
) -> Result(#(EntryId, Payload, Option(Payload)), Error) {
  use Nil <- result.try(same_session(store, remote_tool.child_session(origin)))
  transaction(store, fn() {
    use Nil <- result.try(parent_retained(store, origin))
    use row <- result.try(child_row(store, origin))
    use #(header, row) <- result.try(option.to_result(row, Missing))
    use <- bool.guard(when: header.state == "frozen", return: Error(Frozen))
    use id <- result.try(
      ids.parse_entry_id(header.request_id)
      |> result.map_error(fn(_) { Invalid("invalid child request UUIDv7") }),
    )
    Ok(#(id, Payload(row.request), option.map(row.terminal, Payload)))
  })
}

/// Persists exact child terminal bytes before advertising a durable receipt.
/// This is evidence for reconciliation, never a final ToolOutcome.
///
/// ## Examples
///
/// ```gleam
/// // owner_custody.receive_child(store, origin, request_id, terminal)
/// ```
pub fn receive_child(
  store: Store,
  origin: ChildOrigin,
  request_id: EntryId,
  terminal: Payload,
) -> Result(Nil, Error) {
  use Nil <- result.try(check_payload(store, terminal))
  receive_child_payload(store, origin, request_id, terminal, NativeReceipt)
}

/// Commits complete workspace evidence; cancellation refuses a late receipt.
/// This grants child custody only, never final ToolOutcome custody.
///
/// ## Examples
///
/// `receive_workspace_child(store, origin, id, completion)` is idempotent exactly.
pub fn receive_workspace_child(
  store: Store,
  origin: ChildOrigin,
  request_id: EntryId,
  terminal: WorkspaceCompletion,
) -> Result(Nil, Error) {
  use _ <- result.try(workspace_completion(store.limits, terminal.payload.bytes))
  receive_child_payload(
    store,
    origin,
    request_id,
    terminal.payload,
    WorkspaceReceipt,
  )
}

fn receive_child_payload(
  store: Store,
  origin: ChildOrigin,
  request_id: EntryId,
  terminal: Payload,
  policy: ReceiptPolicy,
) -> Result(Nil, Error) {
  use Nil <- result.try(same_session(store, remote_tool.child_session(origin)))
  transaction(store, fn() {
    use Nil <- result.try(parent_retained(store, origin))
    use row <- result.try(child_row(store, origin))
    use #(header, row) <- result.try(option.to_result(row, Missing))
    use <- bool.guard(when: header.state == "frozen", return: Error(Frozen))
    use Nil <- result.try(case policy, header.state {
      WorkspaceReceipt, "cancelled" -> Error(Frozen)
      NativeReceipt, _ | WorkspaceReceipt, _ -> Ok(Nil)
    })
    use Nil <- result.try(equal_string(
      header.request_id,
      ids.entry_id_to_string(request_id),
    ))
    case row.terminal {
      Some(existing) -> equal(existing, terminal.bytes)
      None ->
        statement(
          store,
          sql.finish_owner_child(
            Some(terminal.bytes),
            remote_tool.child_address(origin),
          ),
        )
    }
  })
}

/// Mints collection authority only from an actual reserved session entry read.
/// The injected total validator interprets the opaque outcome and verifies its
/// exact finalized message; storage never depends on runtime. A staged pending
/// entry, a release or a successful write without readback grants no authority.
///
/// ## Examples
///
/// ```gleam
/// // owner_custody.verify_commit(store, key, session_storage, validate_outcome)
/// ```
pub fn verify_commit(
  store: Store,
  key: ToolKey,
  session_storage: Storage(handle),
  validate: fn(Payload, ResultReadback) -> Result(Nil, String),
) -> Result(CommittedResult, Error) {
  use evidence <- result.try(lookup(store, key))
  use outcome <- result.try(case evidence {
    FinalOutcome(outcome) -> Ok(outcome)
    AwaitingFinal(..) -> Error(Missing)
    Collected -> Error(Frozen)
  })
  use identity <- result.try(
    session_storage_api.get_register(
      session_storage,
      register.FactCustom,
      "session/id",
    )
    |> result.map_error(fn(_) {
      Unavailable("session identity readback failed")
    }),
  )
  use identity <- result.try(option.to_result(identity, Missing))
  use Nil <- result.try(case identity.value.payload {
    json.String(value) ->
      equal_string(value, ids.session_id_to_string(store.session))
    _ -> Error(Conflict)
  })
  let entry_id = remote_tool.result_entry(key)
  use entries <- result.try(
    session_storage_api.get_entries(session_storage, [entry_id])
    |> result.map_error(fn(_) {
      Unavailable("reserved result-entry readback failed")
    }),
  )
  use entry <- result.try(
    dict.get(entries, entry_id) |> result.map_error(fn(_) { Missing }),
  )
  use message <- result.try(case entry {
    MessageEntry(id:, message:, terminate:, ..) if id == entry_id -> {
      let termination = case terminate {
        True -> Terminates
        False -> Continues
      }
      Ok(ResultReadback(message:, termination:))
    }
    _ -> Error(Conflict)
  })
  use Nil <- result.try(validate(outcome, message) |> result.map_error(Invalid))
  Ok(CommittedResult(key:, outcome:))
}

/// Reclaims ordinary retained bytes after exact readback, leaving replay fences.
/// Compile/Launch service rows or any command offer defer ALL parent collection;
/// final Failed/Unknown results do not prove transfer of physical recovery duties.
/// The proof is rechecked against current immutable final bytes in one transaction.
///
/// ## Examples
///
/// ```gleam
/// // owner_custody.collect(store, verified_result)
/// ```
pub fn collect(store: Store, proof: CommittedResult) -> Result(Nil, Error) {
  use Nil <- result.try(same_session(store, remote_tool.session(proof.key)))
  transaction(store, fn() {
    use #(state, row) <- result.try(required_tool(store, proof.key))
    use Nil <- result.try(collection_ready(store, proof.key))
    case state {
      "frozen" -> Ok(Nil)
      "retained" -> {
        use outcome <- result.try(option.to_result(row.outcome, Missing))
        use Nil <- result.try(equal(outcome, proof.outcome.bytes))
        use Nil <- result.try(statement(
          store,
          sql.freeze_owner_children(remote_tool.address(proof.key)),
        ))
        statement(store, sql.freeze_owner_tool(remote_tool.address(proof.key)))
      }
      _ -> Error(Invalid("invalid owner tool state"))
    }
  })
}

/// Frames the complete original service header before its opaque input.
/// The bounded header is decoded before any later service-specific decoder.
///
/// ## Examples
///
/// `service_request(limits, key, input)` allocates no execution identity.
pub fn service_request(
  limits: Limits,
  key: command.ServiceKey,
  input: BitArray,
) -> Result(ServiceRequest, Error) {
  use _ <- result.try(workspace_request(limits, input))
  use envelope <- result.try(frame_header(command.encode_service(key), input))
  use request <- result.try(workspace_request(limits, envelope))
  Ok(ServiceRequest(key:, request:))
}

/// Returns exact retained envelope bytes for a service sender.
///
/// ## Examples
///
/// `service_content(request)` includes the original UUID and complete header.
pub fn service_content(request: ServiceRequest) -> BitArray {
  request.request.payload.bytes
}

/// Projects the exact canonical body without exposing storage's private frame codec.
/// Both the full decoded identity and exact re-framed bytes must match this opaque
/// request. This is historical data only, with no send or preparation authority.
/// It performs no actor ask and never normalizes source or input bytes.
///
/// ## Examples
///
/// ```gleam
/// assert owner_custody.service_input(request) == Ok(original_input_bytes)
/// ```
@internal
pub fn service_input(request: ServiceRequest) -> Result(BitArray, Error) {
  use #(identity, input) <- result.try(unframe_header(service_content(request)))
  let expected = command.encode_service(request.key)
  use Nil <- result.try(equal_json(identity, expected))
  use canonical <- result.try(frame_header(expected, input))
  use Nil <- result.try(equal(canonical, service_content(request)))
  Ok(input)
}

/// Returns the validated original service identity without granting send rights.
///
/// ## Examples
///
/// `service_identity(request)` survives reconnect with both original epochs.
pub fn service_identity(request: ServiceRequest) -> command.ServiceKey {
  request.key
}

/// Commits a complete outer Compile/Launch request before preparation or send.
///
/// ## Examples
///
/// An exact duplicate matches; changed immutable input returns Conflict.
pub fn admit_service_child(
  store: Store,
  request: ServiceRequest,
) -> Result(Nil, Error) {
  use Nil <- result.try(check_compile_predecessor(store, request.key))
  admit_workspace_child(
    store,
    command.service_origin(request.key),
    command.request_id(request.key),
    request.request,
  )
}

/// Reads the original exact service and optional separately retained completion.
/// Missing or cancelled evidence cannot grant fresh execution permission.
///
/// ## Examples
///
/// `service_child(store, key)` validates the entire retained original key.
pub fn service_child(
  store: Store,
  key: command.ServiceKey,
) -> Result(#(ServiceRequest, Option(Payload)), Error) {
  use Nil <- result.try(check_compile_predecessor(store, key))
  use Nil <- result.try(same_session(
    store,
    remote_tool.session(command.parent(key)),
  ))
  transaction(store, fn() { service_inside(store, key) })
}

/// Bounds an immutable offer before the custodian mailbox receives it.
/// The caller supplies a computed digest; this boundary validates spelling only.
///
/// ## Examples
///
/// `command_offer_payload(limits, ref, digest, bytes)` refuses oversized content.
pub fn command_offer_payload(
  limits: Limits,
  ref: command.CommandRef,
  digest: String,
  bytes: BitArray,
) -> Result(CommandOfferPayload, Error) {
  use Nil <- result.try(command.digest(digest) |> result.map_error(Invalid))
  use _ <- result.try(workspace_payload(limits, bytes, 262_144))
  use <- bool.guard(
    when: bytes == <<>>,
    return: Error(Invalid("empty command offer")),
  )
  use _ <- result.try(frame_header(command.encode_ref(ref), <<>>))
  Ok(CommandOfferPayload(ref:, digest:, bytes:))
}

/// Projects the original deterministic reference and canonical offer digest.
///
/// ## Examples
///
/// `offer_identity(offer)` supplies no native request UUID.
pub fn offer_identity(
  offer: CommandOfferPayload,
) -> #(command.CommandRef, String) {
  #(offer.ref, offer.digest)
}

/// Projects the immutable offer bytes admitted under the original reference.
///
/// ## Examples
///
/// `offer_content(offer)` never normalizes argv or policy requirements.
pub fn offer_content(offer: CommandOfferPayload) -> BitArray {
  offer.bytes
}

/// Commits an exact offer only after comparing the complete original service.
/// A retained duplicate is readback, not permission to rerun any physical work.
///
/// ## Examples
///
/// Changed offer bytes reach the same address and return Conflict.
pub fn admit_offer(
  store: Store,
  original: ServiceRequest,
  offer: CommandOfferPayload,
) -> Result(Admission, Error) {
  use _ <- result.try(command_offer_payload(
    store.limits,
    offer.ref,
    offer.digest,
    offer.bytes,
  ))
  use Nil <- result.try(same_session(
    store,
    remote_tool.session(command.parent(original.key)),
  ))
  transaction(store, fn() {
    use Nil <- result.try(equal_service(
      original.key,
      command.service(offer.ref),
    ))
    use retained <- result.try(service_inside(store, original.key))
    use Nil <- result.try(equal(
      service_content(retained.0),
      service_content(original),
    ))
    use Nil <- result.try(not_cancelled(
      store,
      command.service_origin(original.key),
    ))
    use existing <- result.try(offer_row(store, offer.ref))
    case existing {
      Some(#(state, stored)) -> {
        use <- bool.guard(when: state != "retained", return: Error(Frozen))
        use Nil <- result.try(equal_offer(stored, offer))
        Ok(Retained)
      }
      None -> {
        let parent = remote_tool.address(command.parent(original.key))
        use count <- result.try(
          one(query(store, sql.owner_command_offer_count(parent))),
        )
        use <- bool.guard(when: count.offers >= 3, return: Error(Capacity))
        let identity = ref_bytes(offer.ref)
        let reserved =
          offer_reservation(
            offer.ref,
            offer.digest,
            bit_array.byte_size(identity),
            offer_allowance(store),
          )
        use Nil <- result.try(reserve_offer(store, reserved))
        use Nil <- result.try(statement(
          store,
          sql.insert_owner_command_offer(
            command.command_address(offer.ref),
            parent,
            remote_tool.child_address(command.service_origin(original.key)),
            ids.entry_id_to_string(command.request_id(original.key)),
            identity,
            remote_tool.child_address(command.native_origin(offer.ref)),
            offer.digest,
            offer.bytes,
            reserved,
          ),
        ))
        Ok(Fresh)
      }
    }
  })
}

/// Reads original immutable offer evidence after checking header reservations.
///
/// ## Examples
///
/// `offer(store, ref)` refuses collected or cancelled execution authority.
pub fn offer(
  store: Store,
  ref: command.CommandRef,
) -> Result(CommandOfferPayload, Error) {
  use Nil <- result.try(same_session(
    store,
    remote_tool.session(command.parent(command.service(ref))),
  ))
  transaction(store, fn() {
    use _ <- result.try(service_inside(store, command.service(ref)))
    use Nil <- result.try(not_cancelled(
      store,
      command.service_origin(command.service(ref)),
    ))
    use row <- result.try(offer_row(store, ref))
    use #(state, retained) <- result.try(option.to_result(row, Missing))
    use <- bool.guard(when: state != "retained", return: Error(Frozen))
    Ok(retained)
  })
}

/// Resolves a lifetime-unique native origin to its complete historical offer.
/// Cancelled evidence remains readable for cancellation and recovery; this read
/// grants no clearance, reservation or fresh native execution. Frozen evidence
/// and collected parents refuse. The caller's full parent survives address lookup.
///
/// ## Examples
///
/// `command_offer_for_origin(store, command.native_origin(ref))` returns exact
/// retained bytes even after `cancel_service`; `admit_command_child` still refuses.
pub fn command_offer_for_origin(
  store: Store,
  origin: ChildOrigin,
) -> Result(CommandOfferPayload, Error) {
  use Nil <- result.try(same_session(store, remote_tool.child_session(origin)))
  use role <- result.try(
    remote_tool.child_role(origin)
    |> result.replace_error(Invalid("command origin requires managed parent")),
  )
  use <- bool.guard(
    when: role != remote_tool.CompileCommand
      && role != remote_tool.CompileRewriteCommand
      && role != remote_tool.SatelliteCommand,
    return: Error(Invalid("origin is not a physical command")),
  )
  transaction(store, fn() {
    use Nil <- result.try(reserve(store, 0, 0, 0))
    use Nil <- result.try(parent_retained(store, origin))
    use Nil <- result.try(check_offer_count(
      store,
      remote_tool.child_parent(origin),
    ))
    use headers <- result.try(query(
      store,
      sql.owner_command_offer_header_by_native_origin(remote_tool.child_address(
        origin,
      )),
    ))
    case headers {
      [] -> Error(Missing)
      [indexed] -> {
        // The index returns only guarded scalars. Full allowance is checked
        // before the separate named value query transfers any offer bytes.
        let header =
          sql.OwnerCommandOfferHeader(
            parent: indexed.parent,
            service_origin: indexed.service_origin,
            service_id: indexed.service_id,
            native_origin: indexed.native_origin,
            offer_digest: indexed.offer_digest,
            identity_bytes: indexed.identity_bytes,
            offer_bytes: indexed.offer_bytes,
            state: indexed.state,
            reserved_bytes: indexed.reserved_bytes,
          )
        use <- bool.guard(
          when: indexed.address == "",
          return: Error(Invalid("invalid command offer address")),
        )
        use Nil <- result.try(header_size(
          string.byte_size(indexed.address),
          8192,
        ))
        use Nil <- result.try(check_offer_header(store, indexed.address, header))
        use <- bool.guard(when: header.state == "frozen", return: Error(Frozen))
        use Nil <- result.try(equal_string(
          header.parent,
          remote_tool.child_parent(origin),
        ))
        use Nil <- result.try(equal_string(
          header.native_origin,
          remote_tool.child_address(origin),
        ))
        use value <- result.try(offer_value(store, indexed.address))
        use ref <- result.try(decode_offer_ref(value.identity))

        // Logical addresses omit immutable parent content. Exact origin and
        // retained service checks prevent that omission from becoming authority.
        use <- bool.guard(
          when: command.native_origin(ref) != origin,
          return: Error(Conflict),
        )
        use Nil <- result.try(equal_string(
          indexed.address,
          command.command_address(ref),
        ))
        use Nil <- result.try(check_offer_ref(header, ref))
        use _ <- result.try(service_inside(store, command.service(ref)))
        offer_payload(store, ref, header, value)
      }
      [_, _, ..] -> Error(Invalid("duplicate command native origin"))
    }
  })
}

/// Atomically joins exact service/offer custody with a complete native request.
/// UUID allocation belongs to the caller's post-clearance Prepared reservation.
/// A duplicate ignores a new candidate ID and returns the ORIGINAL UUID.
///
/// ## Examples
///
/// Changed offer or native bytes refuse without replacing the retained child.
pub fn admit_command_child(
  store: Store,
  accepted: CommandOfferPayload,
  candidate: EntryId,
  request: Payload,
) -> Result(#(EntryId, Payload), Error) {
  use Nil <- result.try(check_payload(store, request))
  use _ <- result.try(command_offer_payload(
    store.limits,
    accepted.ref,
    accepted.digest,
    accepted.bytes,
  ))
  let key = command.service(accepted.ref)
  use Nil <- result.try(same_session(
    store,
    remote_tool.session(command.parent(key)),
  ))
  use envelope <- result.try(command_envelope(store, accepted, request))
  transaction(store, fn() {
    use _ <- result.try(service_inside(store, key))
    use Nil <- result.try(not_cancelled(store, command.service_origin(key)))
    use row <- result.try(offer_row(store, accepted.ref))
    use #(state, retained) <- result.try(option.to_result(row, Missing))
    use <- bool.guard(when: state != "retained", return: Error(Frozen))
    use Nil <- result.try(equal_offer(retained, accepted))
    let origin = command.native_origin(accepted.ref)
    use existing <- result.try(child_row(store, origin))
    let id = case existing {
      None -> Ok(candidate)
      Some(#(header, value)) -> {
        use <- bool.guard(
          when: header.state != "retained",
          return: Error(Frozen),
        )
        use Nil <- result.try(equal(value.request, envelope.bytes))
        ids.parse_entry_id(header.request_id)
        |> result.replace_error(Invalid("invalid native UUID"))
      }
    }
    use id <- result.try(id)
    use Nil <- result.try(admit_child_inside(store, origin, id, envelope))
    Ok(#(id, request))
  })
}

/// Reads the complete original native content and its separately retained receipt.
/// Recovery uses the original UUID and never re-clears uncertain work.
///
/// ## Examples
///
/// `command_child(store, ref)` retains exact post-clearance content.
pub fn command_child(
  store: Store,
  ref: command.CommandRef,
) -> Result(#(EntryId, Payload, Option(Payload)), Error) {
  use Nil <- result.try(same_session(
    store,
    remote_tool.session(command.parent(command.service(ref))),
  ))
  transaction(store, fn() {
    use _ <- result.try(service_inside(store, command.service(ref)))
    use row <- result.try(offer_row(store, ref))
    use #(_, retained) <- result.try(option.to_result(row, Missing))
    use existing <- result.try(child_row(store, command.native_origin(ref)))
    use #(header, value) <- result.try(option.to_result(existing, Missing))
    use <- bool.guard(when: header.state == "frozen", return: Error(Frozen))
    use id <- result.try(
      ids.parse_entry_id(header.request_id)
      |> result.replace_error(Invalid("invalid native UUID")),
    )
    use #(identity, input) <- result.try(unframe_header(value.request))
    use Nil <- result.try(equal_json(identity, command_header(retained)))
    use payload <- result.try(payload(store.limits, input))
    Ok(#(id, payload, option.map(value.terminal, fn(bytes) { Payload(bytes:) })))
  })
}

/// Atomically fences an outer service, its offers and any allocated native child.
/// Original evidence remains available for reconciliation and late native receipt.
///
/// ## Examples
///
/// `cancel_service(store, key)` before an offer prevents later native allocation.
pub fn cancel_service(
  store: Store,
  key: command.ServiceKey,
) -> Result(Nil, Error) {
  use Nil <- result.try(same_session(
    store,
    remote_tool.session(command.parent(key)),
  ))
  let origin = command.service_origin(key)
  let role = case command.service_role(key) {
    command.CompileService -> command.CompileCommand
    command.LaunchService -> command.SatelliteCommand
  }
  use ref <- result.try(
    command.command_ref(key, role) |> result.map_error(Invalid),
  )
  transaction(store, fn() {
    use Nil <- result.try(parent_retained(store, origin))
    use headers <- result.try(query(
      store,
      sql.owner_child_header(remote_tool.child_address(origin)),
    ))
    use existing <- result.try(case headers {
      [header] if header.state == "cancelled" && header.request_id == "" ->
        Ok(None)
      _ -> child_row(store, origin)
    })
    use Nil <- result.try(case existing {
      None -> Ok(Nil)
      Some(_) -> service_inside(store, key) |> result.replace(Nil)
    })
    use retained <- result.try(offer_row(store, ref))
    use native <- result.try(child_row(store, command.native_origin(ref)))
    use Nil <- result.try(case native, retained {
      None, _ -> Ok(Nil)
      Some(#(_, row)), Some(#(_, offer)) -> {
        use #(identity, _) <- result.try(unframe_header(row.request))
        equal_json(identity, command_header(offer))
      }
      Some(_), None ->
        Error(Invalid("native child lacks original command offer"))
    })
    use Nil <- result.try(cancel_child_inside(store, origin))
    use Nil <- result.try(statement(
      store,
      sql.cancel_owner_command_offers(remote_tool.child_address(origin)),
    ))
    statement(
      store,
      sql.cancel_owner_allocated_child(
        remote_tool.child_address(command.native_origin(ref)),
      ),
    )
  })
}

fn service_inside(
  store: Store,
  key: command.ServiceKey,
) -> Result(#(ServiceRequest, Option(Payload)), Error) {
  let origin = command.service_origin(key)
  use Nil <- result.try(parent_retained(store, origin))
  use row <- result.try(child_row(store, origin))
  use #(header, value) <- result.try(option.to_result(row, Missing))
  use <- bool.guard(when: header.state == "frozen", return: Error(Frozen))
  use Nil <- result.try(equal_string(
    header.request_id,
    ids.entry_id_to_string(command.request_id(key)),
  ))
  use #(identity, input) <- result.try(unframe_header(value.request))
  use Nil <- result.try(equal_json(identity, command.encode_service(key)))
  use request <- result.try(service_request(store.limits, key, input))
  use Nil <- result.try(equal(service_content(request), value.request))
  Ok(#(request, option.map(value.terminal, fn(bytes) { Payload(bytes:) })))
}

fn command_header(offer: CommandOfferPayload) -> json.JsonValue {
  json.Array([
    json.Int(1),
    command.encode_ref(offer.ref),
    json.String(offer.digest),
  ])
}

fn command_envelope(
  store: Store,
  offer: CommandOfferPayload,
  request: Payload,
) -> Result(Payload, Error) {
  use bytes <- result.try(frame_header(command_header(offer), request.bytes))
  payload(store.limits, bytes)
}

fn frame_header(
  value: json.JsonValue,
  input: BitArray,
) -> Result(BitArray, Error) {
  let header = bit_array.from_string(json.to_string(value))
  let size = bit_array.byte_size(header)
  use Nil <- result.try(header_size(size, 8192))
  Ok(<<size:size(32), header:bits, input:bits>>)
}

fn unframe_header(
  bytes: BitArray,
) -> Result(#(json.JsonValue, BitArray), Error) {
  case bytes {
    <<size:size(32), rest:bytes>> -> {
      use Nil <- result.try(header_size(size, 8192))
      case rest {
        <<header:bytes-size(size), input:bytes>> -> {
          use text <- result.try(
            bit_array.to_string(header)
            |> result.replace_error(Invalid("invalid command header UTF-8")),
          )
          use value <- result.try(
            json.parse(text)
            |> result.replace_error(Invalid("invalid command header JSON")),
          )
          Ok(#(value, input))
        }
        _ -> Error(Invalid("truncated command header"))
      }
    }
    _ -> Error(Invalid("missing command header"))
  }
}

fn ref_bytes(ref: command.CommandRef) -> BitArray {
  command.encode_ref(ref) |> json.to_string |> bit_array.from_string
}

fn equal_json(
  expected: json.JsonValue,
  actual: json.JsonValue,
) -> Result(Nil, Error) {
  case expected == actual {
    True -> Ok(Nil)
    False -> Error(Conflict)
  }
}

fn equal_service(
  expected: command.ServiceKey,
  actual: command.ServiceKey,
) -> Result(Nil, Error) {
  case expected == actual {
    True -> Ok(Nil)
    False -> Error(Conflict)
  }
}

fn equal_offer(
  expected: CommandOfferPayload,
  actual: CommandOfferPayload,
) -> Result(Nil, Error) {
  case expected == actual {
    True -> Ok(Nil)
    False -> Error(Conflict)
  }
}

fn offer_allowance(store: Store) -> Int {
  case store.limits.payload < 262_144 {
    True -> store.limits.payload
    False -> 262_144
  }
}

fn offer_reservation(
  ref: command.CommandRef,
  digest: String,
  identity_size: Int,
  allowance: Int,
) -> Int {
  let key = command.service(ref)
  identity_size
  + string.byte_size(command.command_address(ref))
  + string.byte_size(remote_tool.address(command.parent(key)))
  + string.byte_size(remote_tool.child_address(command.service_origin(key)))
  + string.byte_size(ids.entry_id_to_string(command.request_id(key)))
  + string.byte_size(remote_tool.child_address(command.native_origin(ref)))
  + string.byte_size(digest)
  + 128
  + allowance
}

fn reserve_offer(store: Store, bytes: Int) -> Result(Nil, Error) {
  use Nil <- result.try(reserve(store, 0, 0, bytes))
  use budget <- result.try(one(query(store, sql.owner_custody_budget())))
  case budget.offers < store.limits.children {
    True -> Ok(Nil)
    False -> Error(Capacity)
  }
}

fn offer_row(
  store: Store,
  ref: command.CommandRef,
) -> Result(Option(#(String, CommandOfferPayload)), Error) {
  use Nil <- result.try(reserve(store, 0, 0, 0))
  use Nil <- result.try(check_offer_count(
    store,
    remote_tool.address(command.parent(command.service(ref))),
  ))
  use headers <- result.try(query(
    store,
    sql.owner_command_offer_header(command.command_address(ref)),
  ))
  case headers {
    [] -> Ok(None)
    [header] -> {
      use Nil <- result.try(check_offer_header(
        store,
        command.command_address(ref),
        header,
      ))
      use Nil <- result.try(check_offer_ref(header, ref))
      use value <- result.try(offer_value(store, command.command_address(ref)))
      use offer <- result.try(offer_payload(store, ref, header, value))
      Ok(Some(#(header.state, offer)))
    }
    [_, _, ..] -> Error(Invalid("duplicate command offer identity"))
  }
}

fn check_offer_count(store: Store, parent: String) -> Result(Nil, Error) {
  use count <- result.try(
    one(query(store, sql.owner_command_offer_count(parent))),
  )
  use <- bool.guard(
    when: count.offers < 0 || count.offers > 3,
    return: Error(Invalid("command offer count exceeds fixed service purposes")),
  )
  Ok(Nil)
}

fn check_offer_header(
  store: Store,
  address: String,
  header: sql.OwnerCommandOfferHeader,
) -> Result(Nil, Error) {
  use Nil <- result.try(header_size(header.identity_bytes, 8192))
  use Nil <- result.try(header_size(header.offer_bytes, offer_allowance(store)))
  use Nil <- result.try(check_state(header.state))
  use Nil <- result.try(
    command.digest(header.offer_digest) |> result.map_error(Invalid),
  )
  let allowance = case header.state {
    "frozen" -> 0
    _ -> offer_allowance(store)
  }

  // All lengths describe guarded scalar headers, plus the entire unused
  // configured allowance. A short reservation refuses before the value query.
  let actual =
    header.identity_bytes
    + string.byte_size(address)
    + string.byte_size(header.parent)
    + string.byte_size(header.service_origin)
    + string.byte_size(header.service_id)
    + string.byte_size(header.native_origin)
    + string.byte_size(header.offer_digest)
    + 128
    + allowance
  use <- bool.guard(
    when: header.reserved_bytes < actual,
    return: Error(Invalid(
      "command offer reservation is smaller than retained bytes",
    )),
  )
  Ok(Nil)
}

fn check_offer_ref(
  header: sql.OwnerCommandOfferHeader,
  ref: command.CommandRef,
) -> Result(Nil, Error) {
  let key = command.service(ref)
  use Nil <- result.try(equal_string(
    header.parent,
    remote_tool.address(command.parent(key)),
  ))
  use Nil <- result.try(equal_string(
    header.service_origin,
    remote_tool.child_address(command.service_origin(key)),
  ))
  use Nil <- result.try(equal_string(
    header.service_id,
    ids.entry_id_to_string(command.request_id(key)),
  ))
  equal_string(
    header.native_origin,
    remote_tool.child_address(command.native_origin(ref)),
  )
}

fn offer_value(
  store: Store,
  address: String,
) -> Result(sql.OwnerCommandOfferValue, Error) {
  one(query(
    store,
    sql.owner_command_offer_value(address, offer_allowance(store)),
  ))
}

fn decode_offer_ref(bytes: BitArray) -> Result(command.CommandRef, Error) {
  use text <- result.try(
    bit_array.to_string(bytes)
    |> result.replace_error(Invalid("invalid command reference UTF-8")),
  )
  use value <- result.try(
    json.parse(text)
    |> result.replace_error(Invalid("invalid command reference JSON")),
  )
  use ref <- result.try(
    command.decode_ref(value)
    |> result.replace_error(Invalid("invalid command reference")),
  )
  use Nil <- result.try(equal(bytes, ref_bytes(ref)))
  Ok(ref)
}

fn offer_payload(
  store: Store,
  ref: command.CommandRef,
  header: sql.OwnerCommandOfferHeader,
  value: sql.OwnerCommandOfferValue,
) -> Result(CommandOfferPayload, Error) {
  use Nil <- result.try(equal(value.identity, ref_bytes(ref)))
  case header.state {
    "frozen" -> {
      use Nil <- result.try(equal(value.offer, <<>>))
      Ok(CommandOfferPayload(ref, header.offer_digest, <<>>))
    }
    "retained" | "cancelled" ->
      command_offer_payload(store.limits, ref, header.offer_digest, value.offer)
    _ -> Error(Invalid("invalid command offer state"))
  }
}

fn decode_run_custody(value: String) -> Result(RunCustody, Error) {
  case value {
    "unreleased" -> Ok(Unreleased)
    "released" -> Ok(Released)
    _ -> Error(Invalid("invalid owner run custody"))
  }
}

fn collection_ready(store: Store, key: ToolKey) -> Result(Nil, Error) {
  use header <- result.try(
    one(query(store, sql.owner_tool_header(remote_tool.address(key)))),
  )
  use run <- result.try(decode_run_custody(header.run_custody))
  use <- bool.guard(when: run != Released, return: Error(CollectionPending))
  use compile <- result.try(
    remote_tool.tool_child(key, remote_tool.Compile)
    |> result.map_error(Invalid),
  )
  use rewrite <- result.try(
    remote_tool.tool_child(key, remote_tool.CompileRewrite)
    |> result.map_error(Invalid),
  )
  use launch <- result.try(
    remote_tool.tool_child(key, remote_tool.Launch) |> result.map_error(Invalid),
  )
  use compile_rows <- result.try(query(
    store,
    sql.owner_child_header(remote_tool.child_address(compile)),
  ))
  use launch_rows <- result.try(query(
    store,
    sql.owner_child_header(remote_tool.child_address(launch)),
  ))
  use rewrite_rows <- result.try(query(
    store,
    sql.owner_child_header(remote_tool.child_address(rewrite)),
  ))
  use offers <- result.try(
    one(query(store, sql.owner_command_offer_count(remote_tool.address(key)))),
  )
  case
    compile_rows == []
    && rewrite_rows == []
    && launch_rows == []
    && offers.offers == 0
  {
    True -> Ok(Nil)
    False -> Error(CollectionPending)
  }
}

fn initialize(store: Store) -> Result(Nil, Error) {
  let defaults = sqlite_policy.defaults()
  let options =
    sqlite_policy.Options(
      ..defaults,
      busy_timeout_ms: 100,
      foreign_keys: sqlite_policy.Enabled,
    )
  use Nil <- result.try(
    sqlite_policy.configure_connection(store.connection, options)
    |> result.map_error(database_error),
  )
  use application <- result.try(pragma(store, "PRAGMA application_id"))
  use version <- result.try(pragma(store, "PRAGMA user_version"))
  use Nil <- result.try(case application, version {
    1_281_253_199, 5 -> Ok(Nil)
    0, 0 -> {
      use tables <- result.try(pragma(store, "PRAGMA schema_version"))
      use <- bool.guard(
        when: tables != 0,
        return: Error(Invalid("refusing unrelated owner custody database")),
      )
      transaction(store, fn() {
        use Nil <- result.try(execute(store, owner_custody_schema.schema))
        use Nil <- result.try(statement(
          store,
          sql.initialize_owner_custody(
            ids.session_id_to_string(store.session),
            store.limits.tools,
            store.limits.children,
            store.limits.bytes,
            store.limits.payload,
          ),
        ))
        execute(
          store,
          "PRAGMA application_id=1281253199; PRAGMA user_version=5",
        )
      })
    }
    _, _ -> Error(Invalid("unsupported owner custody database"))
  })
  use metadata <- result.try(one(query(store, sql.owner_custody_metadata())))
  use <- bool.guard(
    when: metadata
      != sql.OwnerCustodyMetadata(
      ids.session_id_to_string(store.session),
      store.limits.tools,
      store.limits.children,
      store.limits.bytes,
      store.limits.payload,
    ),
    return: Error(Conflict),
  )
  use Nil <- result.try(reserve(store, 0, 0, 0))
  use Nil <- result.try(
    sqlite_policy.configure_database(store.connection, options)
    |> result.map_error(database_error),
  )
  use Nil <- result.try(execute(store, "PRAGMA synchronous=FULL"))
  use sync <- result.try(pragma(store, "PRAGMA synchronous"))
  use <- bool.guard(
    when: sync != 2,
    return: Error(Invalid("owner requires synchronous FULL")),
  )
  use Nil <- result.try(validate_header_rows(store, "", store.limits.tools))
  validate_report_rows(store, "", store.limits.tools)
}

// The budget is checked before header or payload reads. Final and terminal
// payload allowances were reserved at admission, so receiving them needs no
// eviction or new capacity and can never discard the only durable copy.
fn reserve(
  store: Store,
  tools: Int,
  children: Int,
  bytes: Int,
) -> Result(Nil, Error) {
  use budget <- result.try(one(query(store, sql.owner_custody_budget())))
  use <- bool.guard(
    when: budget.tools < 0
      || budget.children < 0
      || budget.offers < 0
      || budget.bytes < 0,
    return: Error(Invalid("negative owner custody accounting")),
  )
  case
    budget.tools + tools <= store.limits.tools
    && budget.children + children <= store.limits.children
    && budget.offers <= store.limits.children
    && budget.bytes + bytes <= store.limits.bytes
  {
    True -> Ok(Nil)
    False -> Error(Capacity)
  }
}

fn tool_row(
  store: Store,
  key: ToolKey,
) -> Result(Option(#(String, sql.OwnerToolValue)), Error) {
  use Nil <- result.try(reserve(store, 0, 0, 0))
  use headers <- result.try(query(
    store,
    sql.owner_tool_header(remote_tool.address(key)),
  ))
  case headers {
    [] -> Ok(None)
    [header] -> {
      use Nil <- result.try(check_tool_header(
        store,
        remote_tool.address(key),
        header,
      ))
      use Nil <- result.try(equal_string(
        header.result_entry,
        ids.entry_id_to_string(remote_tool.result_entry(key)),
      ))
      use row <- result.try(
        one(query(
          store,
          sql.owner_tool_value(remote_tool.address(key), store.limits.payload),
        )),
      )
      use Nil <- result.try(equal(row.identity, identity_bytes(key)))
      Ok(Some(#(header.state, row)))
    }
    [_, _, ..] -> Error(Invalid("duplicate owner tool identity"))
  }
}

/// Checks final bytes under the already selected profile without expanding it.
///
/// ## Examples
///
/// `final_payload(limits, CodeModeReportV1, bytes)` retains the 256-KiB final ceiling.
pub fn final_payload(
  limits: Limits,
  profile: FinalProfile,
  bytes: BitArray,
) -> Result(Payload, Error) {
  case profile {
    OrdinaryFinal -> payload(limits, bytes)
    CodeModeReportV1 -> {
      use <- bool.guard(
        when: bit_array.bit_size(bytes) % 8 != 0
          || bit_array.byte_size(bytes) > 262_144,
        return: Error(Capacity),
      )
      Ok(Payload(bytes))
    }
  }
}

/// Reads the immutable final profile after scalar quota/header validation.
///
/// ## Examples
///
/// `final_profile(store, key)` never upgrades an original ordinary reservation.
pub fn final_profile(
  store: Store,
  key: ToolKey,
) -> Result(FinalProfile, Error) {
  use header <- result.try(checked_tool_header(store, key))
  decode_profile(header.final_profile)
}

/// Commits the canonical complete bundle before returning its original reference.
/// Exact repeated bytes are readback; a changed report cannot replace history.
///
/// ## Examples
///
/// `retain_report(store, original_key, checked_report)` supplies no final-outcome authority.
pub fn retain_report(
  store: Store,
  key: ToolKey,
  report: report_value.CompleteReport,
) -> Result(report_value.ReportRef, Error) {
  use Nil <- result.try(same_session(store, remote_tool.session(key)))
  let bytes = report_value.bytes(report)
  use _ <- result.try(
    report_value.decode(bytes)
    |> result.replace_error(Invalid("invalid complete report")),
  )
  use digest <- result.try(report_digest(store, bytes))
  transaction(store, fn() {
    use #(_state, row) <- result.try(retained_tool(store, key))
    use header <- result.try(checked_tool_header(store, key))
    use <- bool.guard(
      when: header.final_profile != "code_mode_report_v1",
      return: Error(Conflict),
    )

    // A lost COMMIT reply may retry only these exact already committed bytes.
    // An unrelated final or a changed report never opens another write window.
    use Nil <- result.try(case header.report_bytes {
      0 -> {
        use <- bool.guard(when: row.outcome != None, return: Error(Conflict))
        statement(
          store,
          sql.retain_owner_report(
            Some(bytes),
            Some(digest),
            remote_tool.address(key),
          ),
        )
      }
      _ -> {
        use retained <- result.try(report_bytes_at(
          store,
          remote_tool.address(key),
        ))
        use Nil <- result.try(equal(retained, bytes))
        equal_string(header.report_digest, digest)
      }
    })
    reference_for(store, key, digest, bit_array.byte_size(bytes))
  })
}

/// Reads the original committed report relation without loading its BLOB.
/// A report-only row remains AwaitingFinal and cannot reconstruct final authority.
///
/// ## Examples
///
/// `report_reference(store, key)` can return history before a final is committed.
pub fn report_reference(
  store: Store,
  key: ToolKey,
) -> Result(Option(report_value.ReportRef), Error) {
  use header <- result.try(checked_tool_header(store, key))
  case header.report_bytes {
    0 -> Ok(None)
    _ ->
      reference_for(store, key, header.report_digest, header.report_bytes)
      |> result.map(Some)
  }
}

/// Reads bounded original request bytes for the final call-identity startup pass.
/// It never admits missing custody or reconstructs a finalized message.
///
/// ## Examples
///
/// `original_request(store, key)` retains the original provider call envelope.
pub fn original_request(store: Store, key: ToolKey) -> Result(Payload, Error) {
  use #(_state, row) <- result.try(required_tool(store, key))
  Ok(Payload(row.request))
}

/// Reads the already committed terminal for final error-polarity validation.
/// This full bounded read is for commit/startup validation, never chunk serving.
///
/// ## Examples
///
/// `report_outcome(store, key)` returns no terminal when report custody is absent.
pub fn report_outcome(
  store: Store,
  key: ToolKey,
) -> Result(Option(report_value.Outcome), Error) {
  use header <- result.try(checked_tool_header(store, key))
  case header.report_bytes {
    0 -> Ok(None)
    _ -> {
      use bytes <- result.try(report_bytes_at(store, remote_tool.address(key)))
      use report <- result.try(
        report_value.decode(bytes)
        |> result.replace_error(Invalid("invalid complete report")),
      )
      Ok(Some(report_value.outcome(report)))
    }
  }
}

/// Reads one committed report chunk after checking session and original identity.
/// Offsets must be aligned, nonnegative and strictly inside the immutable bundle.
///
/// ## Examples
///
/// `read_report_chunk(store, reference, 0)` returns at most 65,536 bytes.
pub fn read_report_chunk(
  store: Store,
  reference: report_value.ReportRef,
  offset: Int,
) -> Result(ReportChunk, Error) {
  use Nil <- result.try(same_session(store, report_value.ref_session(reference)))
  use <- bool.guard(
    when: offset < 0
      || offset % 65_536 != 0
      || offset >= report_value.ref_byte_length(reference),
    return: Error(Invalid("invalid report chunk offset")),
  )
  use Nil <- result.try(reserve(store, 0, 0, 0))
  use identity <- result.try(
    one(query(
      store,
      sql.owner_report_identity(
        ids.entry_id_to_string(report_value.ref_result_entry(reference)),
      ),
    )),
  )
  use key <- result.try(decode_identity(
    store,
    identity.address,
    identity.identity,
  ))
  use retained <- result.try(report_reference(store, key))
  use <- bool.guard(when: retained != Some(reference), return: Error(Conflict))
  use chunk <- result.try(
    one(query(
      store,
      sql.owner_report_chunk(
        offset,
        remote_tool.address(key),
        report_value.ref_byte_length(reference),
        Some(report_value.ref_digest(reference)),
      ),
    )),
  )
  let remaining = report_value.ref_byte_length(reference) - offset
  let expected = case remaining > 65_536 {
    True -> 65_536
    False -> remaining
  }
  use <- bool.guard(
    when: bit_array.byte_size(chunk.chunk) != expected,
    return: Error(Invalid("truncated report chunk")),
  )
  Ok(ReportChunk(reference, offset, chunk.chunk))
}

/// Checks every retained final association through the caller's runtime decoder.
/// This finite pass must succeed before an owner actor publishes its door.
///
/// ## Examples
///
/// `validate_finals(store, validate)` never synthesizes a missing final from a report.
pub fn validate_finals(
  store: Store,
  validate: fn(ToolKey, FinalProfile, Option(report_value.ReportRef), Payload) ->
    Result(Nil, String),
) -> Result(Nil, Error) {
  validate_final_rows(store, "", store.limits.tools, validate)
}

fn validate_final_rows(
  store: Store,
  after: String,
  remaining: Int,
  validate: fn(ToolKey, FinalProfile, Option(report_value.ReportRef), Payload) ->
    Result(Nil, String),
) -> Result(Nil, Error) {
  use addresses <- result.try(query(store, sql.owner_tool_next(after)))
  case addresses {
    [] -> Ok(Nil)
    [row] if remaining > 0 && row.address != "" -> {
      use key <- result.try(key_at(store, row.address))
      use evidence <- result.try(lookup(store, key))
      use Nil <- result.try(case evidence {
        FinalOutcome(payload) -> {
          use profile <- result.try(final_profile(store, key))
          use reference <- result.try(report_reference(store, key))
          validate(key, profile, reference, payload)
          |> result.map_error(Invalid)
        }
        AwaitingFinal(..) | Collected -> Ok(Nil)
      })
      validate_final_rows(store, row.address, remaining - 1, validate)
    }
    _ -> Error(Invalid("invalid final row census"))
  }
}

fn validate_report_rows(
  store: Store,
  after: String,
  remaining: Int,
) -> Result(Nil, Error) {
  use addresses <- result.try(query(store, sql.owner_tool_next(after)))
  case addresses {
    [] -> Ok(Nil)
    [row] if remaining > 0 && row.address != "" -> {
      use key <- result.try(key_at(store, row.address))
      use header <- result.try(checked_tool_header(store, key))
      use Nil <- result.try(case header.report_bytes {
        0 -> Ok(Nil)
        _ -> {
          use bytes <- result.try(report_bytes_at(store, row.address))
          use _ <- result.try(
            report_value.decode(bytes)
            |> result.replace_error(Invalid("invalid canonical retained report")),
          )
          use digest <- result.try(report_digest(store, bytes))
          equal_string(header.report_digest, digest)
        }
      })
      validate_report_rows(store, row.address, remaining - 1)
    }
    _ -> Error(Invalid("invalid report row census"))
  }
}

fn validate_header_rows(
  store: Store,
  after: String,
  remaining: Int,
) -> Result(Nil, Error) {
  use addresses <- result.try(query(store, sql.owner_tool_next(after)))
  case addresses {
    [] -> Ok(Nil)
    [row] if remaining > 0 && row.address != "" -> {
      use header <- result.try(
        one(query(store, sql.owner_tool_header(row.address))),
      )
      use Nil <- result.try(check_tool_header(store, row.address, header))
      validate_header_rows(store, row.address, remaining - 1)
    }
    _ -> Error(Invalid("invalid owner scalar row census"))
  }
}

fn key_at(store: Store, address: String) -> Result(ToolKey, Error) {
  use Nil <- result.try(reserve(store, 0, 0, 0))
  use header <- result.try(one(query(store, sql.owner_tool_header(address))))
  use Nil <- result.try(check_tool_header(store, address, header))
  use row <- result.try(one(query(store, sql.owner_tool_identity(address))))
  decode_identity(store, address, row.identity)
}

fn decode_identity(
  store: Store,
  address: String,
  bytes: BitArray,
) -> Result(ToolKey, Error) {
  use text <- result.try(
    bit_array.to_string(bytes)
    |> result.replace_error(Invalid("invalid tool identity UTF-8")),
  )
  use value <- result.try(
    json.parse(text)
    |> result.replace_error(Invalid("invalid tool identity JSON")),
  )
  use fields <- result.try(
    json.parse(address)
    |> result.replace_error(Invalid("invalid tool address JSON")),
  )
  case value, fields {
    json.Array([
      json.String(stored_address),
      json.String(digest),
      json.String(entry),
    ]),
      json.Array([
        json.String(session),
        json.String(operation),
        json.String(step),
        json.Int(index),
      ])
    -> {
      use session <- result.try(
        ids.parse_session_id(session)
        |> result.replace_error(Invalid("invalid tool session")),
      )
      use operation <- result.try(
        ids.parse_op_id(operation)
        |> result.replace_error(Invalid("invalid tool operation")),
      )
      use entry <- result.try(
        ids.parse_entry_id(entry)
        |> result.replace_error(Invalid("invalid tool result entry")),
      )
      use key <- result.try(
        remote_tool.key(session, operation, step, index, digest, entry)
        |> result.map_error(Invalid),
      )
      use Nil <- result.try(same_session(store, session))
      use Nil <- result.try(equal_string(stored_address, address))
      use Nil <- result.try(equal_string(remote_tool.address(key), address))
      use Nil <- result.try(equal(identity_bytes(key), bytes))
      Ok(key)
    }
    _, _ -> Error(Invalid("invalid complete tool identity"))
  }
}

fn checked_tool_header(
  store: Store,
  key: ToolKey,
) -> Result(sql.OwnerToolHeader, Error) {
  use Nil <- result.try(same_session(store, remote_tool.session(key)))
  use Nil <- result.try(reserve(store, 0, 0, 0))
  use headers <- result.try(query(
    store,
    sql.owner_tool_header(remote_tool.address(key)),
  ))
  use header <- result.try(case headers {
    [] -> Error(Missing)
    [header] -> Ok(header)
    [_, _, ..] -> Error(Invalid("duplicate owner tool identity"))
  })
  use Nil <- result.try(check_tool_header(
    store,
    remote_tool.address(key),
    header,
  ))
  use Nil <- result.try(equal_string(
    header.result_entry,
    ids.entry_id_to_string(remote_tool.result_entry(key)),
  ))
  use identity <- result.try(
    one(query(store, sql.owner_tool_identity(remote_tool.address(key)))),
  )
  use Nil <- result.try(equal(identity.identity, identity_bytes(key)))
  Ok(header)
}

fn check_tool_header(
  store: Store,
  address: String,
  header: sql.OwnerToolHeader,
) -> Result(Nil, Error) {
  use Nil <- result.try(header_size(header.identity_bytes, 8192))
  use Nil <- result.try(header_size(header.argument_bytes, store.limits.payload))
  use Nil <- result.try(header_size(header.request_bytes, store.limits.payload))
  use profile <- result.try(decode_profile(header.final_profile))
  use <- bool.guard(
    when: header.final_allowance != final_allowance(store, profile),
    return: Error(Invalid("changed owner final allowance")),
  )
  let final_ceiling = case profile {
    OrdinaryFinal -> store.limits.payload
    CodeModeReportV1 -> 262_144
  }
  use Nil <- result.try(header_size(header.outcome_bytes, final_ceiling))
  use Nil <- result.try(header_size(
    header.report_bytes,
    report_value.max_bundle_bytes,
  ))
  use Nil <- result.try(check_state(header.state))
  use _ <- result.try(decode_run_custody(header.run_custody))
  use _ <- result.try(
    ids.parse_entry_id(header.result_entry)
    |> result.replace_error(Invalid("invalid tool result entry")),
  )

  // Null report and null digest form one absence state. A present report must
  // fit its original profile and fixed digest before any BLOB is selected.
  use Nil <- result.try(
    case header.report_bytes, header.report_digest, profile {
      0, "", _ -> Ok(Nil)
      size, digest, CodeModeReportV1 if size >= 18 ->
        command.digest(digest) |> result.map_error(Invalid)
      _, _, _ -> Error(Invalid("invalid report profile or digest"))
    },
  )
  let final_charge = case header.state {
    "frozen" ->
      case header.report_bytes {
        0 -> 0
        _ -> header.report_bytes + 128
      }
    _ -> header.argument_bytes + header.request_bytes + header.final_allowance
  }
  let minimum =
    header.identity_bytes + string.byte_size(address) + 128 + final_charge
  use <- bool.guard(
    when: header.reserved_bytes < minimum,
    return: Error(Invalid(
      "owner tool reservation is smaller than retained bytes",
    )),
  )
  Ok(Nil)
}

fn report_bytes_at(store: Store, address: String) -> Result(BitArray, Error) {
  use row <- result.try(one(query(store, sql.owner_report_value(address))))
  option.to_result(row.report, Missing)
}

fn report_digest(store: Store, bytes: BitArray) -> Result(String, Error) {
  case store.reports {
    OrdinaryStore -> Error(Invalid("owner report hashing is not configured"))
    ReportsEnabled(sha256) -> {
      let digest = sha256(bytes)
      use <- bool.guard(
        when: bit_array.byte_size(digest) != 32
          || bit_array.bit_size(digest) != 256,
        return: Error(Invalid("invalid host SHA-256 result")),
      )
      Ok(digest |> bit_array.base16_encode |> string.lowercase)
    }
  }
}

fn reference_for(
  store: Store,
  key: ToolKey,
  digest: String,
  length: Int,
) -> Result(report_value.ReportRef, Error) {
  report_value.reference(
    store.session,
    remote_tool.result_entry(key),
    digest,
    length,
  )
  |> result.replace_error(Invalid("invalid report reference"))
}

fn report_enabled(store: Store, profile: FinalProfile) -> Result(Nil, Error) {
  case store.reports, profile {
    OrdinaryStore, CodeModeReportV1 ->
      Error(Invalid("owner report hashing is not configured"))
    _, _ -> Ok(Nil)
  }
}

fn decode_profile(name: String) -> Result(FinalProfile, Error) {
  case name {
    "ordinary" -> Ok(OrdinaryFinal)
    "code_mode_report_v1" -> Ok(CodeModeReportV1)
    _ -> Error(Invalid("invalid final profile"))
  }
}

fn profile_name(profile: FinalProfile) -> String {
  case profile {
    OrdinaryFinal -> "ordinary"
    CodeModeReportV1 -> "code_mode_report_v1"
  }
}

fn final_allowance(store: Store, profile: FinalProfile) -> Int {
  case profile {
    OrdinaryFinal -> store.limits.payload
    CodeModeReportV1 -> report_final_allowance
  }
}

fn check_final_payload(
  store: Store,
  key: ToolKey,
  payload: Payload,
) -> Result(Nil, Error) {
  use profile <- result.try(final_profile(store, key))
  final_payload(store.limits, profile, payload.bytes) |> result.replace(Nil)
}

fn required_tool(
  store: Store,
  key: ToolKey,
) -> Result(#(String, sql.OwnerToolValue), Error) {
  use row <- result.try(tool_row(store, key))
  option.to_result(row, Missing)
}

fn retained_tool(
  store: Store,
  key: ToolKey,
) -> Result(#(String, sql.OwnerToolValue), Error) {
  use row <- result.try(required_tool(store, key))
  use <- bool.guard(when: row.0 == "frozen", return: Error(Frozen))
  Ok(row)
}

fn parent_retained(store: Store, origin: ChildOrigin) -> Result(Nil, Error) {
  case remote_tool.child_tool(origin) {
    Error(Nil) -> Ok(Nil)
    Ok(key) -> retained_tool(store, key) |> result.replace(Nil)
  }
}

fn child_row(
  store: Store,
  origin: ChildOrigin,
) -> Result(Option(#(sql.OwnerChildHeader, sql.OwnerChildValue)), Error) {
  use Nil <- result.try(reserve(store, 0, 0, 0))
  use headers <- result.try(query(
    store,
    sql.owner_child_header(remote_tool.child_address(origin)),
  ))
  case headers {
    [] -> Ok(None)
    [header] -> {
      use <- bool.guard(
        when: header.state == "cancelled" && header.request_id == "",
        return: Error(Frozen),
      )
      use _id <- result.try(
        ids.parse_entry_id(header.request_id)
        |> result.map_error(fn(_) { Invalid("invalid child UUIDv7") }),
      )
      use Nil <- result.try(header_size(
        header.request_bytes,
        store.limits.payload,
      ))
      use Nil <- result.try(header_size(
        header.terminal_bytes,
        store.limits.payload,
      ))
      use Nil <- result.try(check_state(header.state))

      // Cancellation retains an existing UUID and the same terminal allowance.
      // Only collection replaces that reservation with a smaller frozen fence.
      let actual =
        string.byte_size(remote_tool.child_address(origin))
        + string.byte_size(remote_tool.child_parent(origin))
        + 164
        + case header.state {
          "frozen" -> 0
          _ -> header.request_bytes + store.limits.payload
        }
      use <- bool.guard(
        when: header.reserved_bytes < actual,
        return: Error(Invalid(
          "owner child reservation is smaller than retained bytes",
        )),
      )
      use row <- result.try(
        one(query(
          store,
          sql.owner_child_value(
            remote_tool.child_address(origin),
            store.limits.payload,
          ),
        )),
      )
      Ok(Some(#(header, row)))
    }
    [_, _, ..] -> Error(Invalid("duplicate owner child origin"))
  }
}

fn header_size(size: Int, limit: Int) -> Result(Nil, Error) {
  case size >= 0 && size <= limit {
    True -> Ok(Nil)
    False ->
      Error(Invalid("owner payload exceeds bound before materialization"))
  }
}

fn check_state(state: String) -> Result(Nil, Error) {
  case state {
    "retained" | "frozen" | "cancelled" -> Ok(Nil)
    _ -> Error(Invalid("invalid owner evidence state"))
  }
}

fn same_session(store: Store, session: SessionId) -> Result(Nil, Error) {
  case store.session == session {
    True -> Ok(Nil)
    False -> Error(Conflict)
  }
}

fn check_payload(store: Store, value: Payload) -> Result(Nil, Error) {
  payload(store.limits, value.bytes) |> result.replace(Nil)
}

fn identity_bytes(key: ToolKey) -> BitArray {
  remote_tool.encode(key) |> json.to_string |> bit_array.from_string
}

fn equal(expected: BitArray, actual: BitArray) -> Result(Nil, Error) {
  case expected == actual {
    True -> Ok(Nil)
    False -> Error(Conflict)
  }
}

fn equal_string(expected: String, actual: String) -> Result(Nil, Error) {
  case expected == actual {
    True -> Ok(Nil)
    False -> Error(Conflict)
  }
}

fn transaction(
  store: Store,
  run: fn() -> Result(a, Error),
) -> Result(a, Error) {
  use Nil <- result.try(execute(store, "BEGIN IMMEDIATE"))
  let result =
    run()
    |> result.try(fn(value) {
      execute(store, "COMMIT") |> result.replace(value)
    })
  case result {
    Ok(value) -> Ok(value)
    Error(error) -> {
      let _rollback = execute(store, "ROLLBACK")
      Error(error)
    }
  }
}

fn pragma(store: Store, pragma: String) -> Result(Int, Error) {
  sqlight.query(pragma, store.connection, [], decode.at([0], decode.int))
  |> result.map_error(database_error)
  |> one
}

fn execute(store: Store, sql: String) -> Result(Nil, Error) {
  sqlight.exec(sql, store.connection) |> result.map_error(database_error)
}

fn query(
  store: Store,
  statement: #(String, List(dev.Param), Decoder(a)),
) -> Result(List(a), Error) {
  let #(text, parameters, decoder) = statement
  use parameters <- result.try(list.try_map(parameters, parameter))
  sqlight.query(text, store.connection, parameters, decoder)
  |> result.map_error(database_error)
}

fn statement(
  store: Store,
  statement: #(String, List(dev.Param)),
) -> Result(Nil, Error) {
  let #(text, parameters) = statement
  query(store, #(text, parameters, decode.success(Nil))) |> result.replace(Nil)
}

fn one(rows: Result(List(a), Error)) -> Result(a, Error) {
  use rows <- result.try(rows)
  case rows {
    [row] -> Ok(row)
    [] | [_, _, ..] -> Error(Invalid("expected exactly one owner custody row"))
  }
}

fn database_error(error: sqlight.Error) -> Error {
  case sqlight.error_code_to_int(error.code) % 256 == 19 {
    True -> Conflict
    False -> Unavailable(error.message)
  }
}

fn parameter(value: dev.Param) -> Result(sqlight.Value, Error) {
  case value {
    dev.ParamInt(value) -> Ok(sqlight.int(value))
    dev.ParamString(value) -> Ok(sqlight.text(value))
    dev.ParamBitArray(value) -> Ok(sqlight.blob(value))
    dev.ParamNullable(Some(value)) -> parameter(value)
    dev.ParamNullable(None) -> Ok(sqlight.null())
    dev.ParamFloat(_)
    | dev.ParamBool(_)
    | dev.ParamTimestamp(_)
    | dev.ParamDate(_)
    | dev.ParamList(_)
    | dev.ParamDynamic(_) ->
      Error(Invalid("unsupported owner custody query parameter"))
  }
}

// Structural lineage is independently enforced without a code-mode dependency.
// Semantic diagnostic and vetting checks belong to the checked owner custodian.
fn check_compile_predecessor(
  store: Store,
  key: command.ServiceKey,
) -> Result(Nil, Error) {
  case command.compile_predecessor(key) {
    None -> Ok(Nil)
    Some(previous) -> {
      use retained <- result.try(service_child(store, previous))
      option.to_result(retained.1, Conflict) |> result.replace(Nil)
    }
  }
}
