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
//// `initialize` uses `pragma` only for format metadata, never data queries.

import core/entry.{MessageEntry}
import core/ids.{type EntryId, type SessionId}
import core/json
import core/message.{type AgentMessage}
import core/register
import core/remote_tool.{type ChildOrigin, type ToolKey}
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

/// A serialized handle for one session's custody database.
pub opaque type Store {
  Store(connection: sqlight.Connection, session: SessionId, limits: Limits)
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
    && payload <= 2_097_152
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
  case bit_array.byte_size(bytes) <= limits.payload {
    True -> Ok(Payload(bytes:))
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
  use Nil <- result.try(
    sqlite_policy.refusing_unopenable_path(path) |> result.map_error(Invalid),
  )
  use connection <- result.try(
    sqlight.open(path) |> result.map_error(database_error),
  )
  let store = Store(connection:, session:, limits:)
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
  admit_once(store, key, arguments, request) |> result.replace(Nil)
}

fn admit_once(
  store: Store,
  key: ToolKey,
  arguments: Payload,
  request: Payload,
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
          + store.limits.payload
          + 128
        use Nil <- result.try(reserve(store, 1, 0, reserved))
        statement(
          store,
          sql.insert_owner_tool(
            remote_tool.address(key),
            identity,
            ids.entry_id_to_string(remote_tool.result_entry(key)),
            arguments.bytes,
            request.bytes,
            reserved,
          ),
        )
        |> result.replace(Fresh)
      }
      Some(#("frozen", _row)) -> Error(Frozen)
      Some(#("retained", row)) -> {
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
  admit_once(store, key, arguments, request)
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
  use Nil <- result.try(same_session(store, remote_tool.session(key)))
  use Nil <- result.try(check_payload(store, outcome))
  transaction(store, fn() {
    use #(_state, row) <- result.try(retained_tool(store, key))
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
  use Nil <- result.try(same_session(store, remote_tool.child_session(origin)))
  use Nil <- result.try(check_payload(store, request))
  transaction(store, fn() {
    use Nil <- result.try(parent_retained(store, origin))
    use Nil <- result.try(not_cancelled(store, origin))
    use existing <- result.try(child_row(store, origin))
    case existing {
      None -> {
        let parent = remote_tool.child_parent(origin)
        use count <- result.try(
          one(query(store, sql.owner_child_count(parent))),
        )
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
  })
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
  transaction(store, fn() {
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
  })
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
  use Nil <- result.try(same_session(store, remote_tool.child_session(origin)))
  use Nil <- result.try(check_payload(store, terminal))
  transaction(store, fn() {
    use Nil <- result.try(parent_retained(store, origin))
    use row <- result.try(child_row(store, origin))
    use #(header, row) <- result.try(option.to_result(row, Missing))
    use <- bool.guard(when: header.state == "frozen", return: Error(Frozen))
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

/// Reclaims retained bytes after exact readback, leaving permanent replay fences.
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
    1_281_253_199, 2 -> Ok(Nil)
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
          "PRAGMA application_id=1281253199; PRAGMA user_version=2",
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
  sqlite_policy.configure_database(store.connection, options)
  |> result.map_error(database_error)
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
    when: budget.tools < 0 || budget.children < 0 || budget.bytes < 0,
    return: Error(Invalid("negative owner custody accounting")),
  )
  case
    budget.tools + tools <= store.limits.tools
    && budget.children + children <= store.limits.children
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
      use Nil <- result.try(header_size(header.identity_bytes, 8192))
      use Nil <- result.try(header_size(
        header.argument_bytes,
        store.limits.payload,
      ))
      use Nil <- result.try(header_size(
        header.request_bytes,
        store.limits.payload,
      ))
      use Nil <- result.try(header_size(
        header.outcome_bytes,
        store.limits.payload,
      ))
      use Nil <- result.try(check_state(header.state))

      // A terminal write consumes the allowance reserved at admission. Check
      // that unused allowance too, before a receipt can acknowledge new bytes.
      let actual =
        header.identity_bytes
        + string.byte_size(remote_tool.address(key))
        + 128
        + case header.state {
          "frozen" -> 0
          _ ->
            header.argument_bytes + header.request_bytes + store.limits.payload
        }
      use <- bool.guard(
        when: header.reserved_bytes < actual,
        return: Error(Invalid(
          "owner tool reservation is smaller than retained bytes",
        )),
      )
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
