//// Bounded reads for a client snapshot, separate from the frozen Storage API.
////
//// A cut copies mutable register metadata and the durable high-water in one
//// backend dispatch. Later reads name immutable entries below that high-water;
//// they retain no transaction, cursor, process, or history-sized list. The
//// gateway owns transfer credit, deadlines, authorization and incarnation.
//// This reader does not assign entries to strands or interpret machine state.
////
//// Every call accepts its remaining wait budget, capped at five seconds.
//// ReadTimedOut does not cancel the queued or running read. The caller must
//// fail the original gateway/session without retrying; session custody must
//// drain the original store or retain RecoveryBlocked before reopening it.
////
//// Register plans are declarative. Reference expansion follows a named JSON
//// field in already bounded source cells, so storage need not import machine
//// or run caller callbacks while it owns the database. Invalid fields fail
//// explicitly rather than omitting metadata from an apparently complete cut.

import core/corruption
import core/ids.{type EntryId}
import core/json
import core/register.{type RegisterNs}
import gleam/bool
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import storage/storage.{type Register, type SessionStats, type StorageError}

/// Maximum copied metadata, including cell identifiers and framing allowance.
pub const metadata_bytes_limit = 1_048_576

/// Maximum copied cells, including exact-key reference expansion.
pub const metadata_cells_limit = 1024

/// A page cannot return a history-sized descriptor list.
pub const page_limit = 100

/// Raw bytes leave room for base64 and an envelope below 256 KiB.
pub const fragment_bytes_limit = 194_560

/// A receiver must refuse a larger record before allocating its reassembly.
pub const record_bytes_limit = 33_554_432

/// Read-only capabilities closed over one concrete backend handle.
@internal
pub type Reader {
  Reader(
    /// Copies metadata and recent descriptors; the final argument is wait ms.
    capture: fn(Plan, Int) -> Result(Cut, Error),
    /// Reads ascending descriptors between bounds; the final argument is wait ms.
    page: fn(Int, Int, Int, Int) -> Result(List(Descriptor), Error),
    /// Reads bytes at an offset, then wait ms; EOF is an empty byte array.
    fragment: fn(Descriptor, Int, Int) -> Result(BitArray, Error),
  )
}

/// A bounded projection, not a query language or a callback into the actor.
@internal
pub type Plan {
  Plan(
    /// At most sixteen prefix or exact-key selections.
    selections: List(Selection),
    /// At most sixteen one-level reference expansions over selected cells.
    references: List(Reference),
    /// Initial history window, between zero and one hundred recent entries.
    recent_entries: Int,
  )
}

/// Cells selected by namespace and literal prefix or exact key.
@internal
pub type Selection {
  Selection(
    /// The closed core namespace.
    namespace: RegisterNs,
    /// A literal prefix; SQL wildcard characters carry no special meaning.
    prefix: String,
    /// Optional equality on a top-level JSON string field.
    predicate: Predicate,
  )

  /// One exact cell; a missing key contributes no cell to the cut. Callers
  /// compare requested keys with returned cells to report explicit absences.
  ExactKey(
    /// The closed core namespace.
    namespace: RegisterNs,
    /// One exact key, never interpreted as a prefix or SQL pattern.
    key: String,
  )
}

/// Missing or malformed predicate fields are corruption, not a non-match.
@internal
pub type Predicate {
  /// Select every cell under the namespace and prefix.
  All

  /// Select a field's exact string value, after validating its shape.
  StringFieldEquals(field: String, expected: String)
}

/// One nullable string field names an exact cell in another namespace.
@internal
pub type Reference {
  FromField(
    /// Only cells in this namespace contribute references.
    source: RegisterNs,
    /// A required field whose value is null or a nonempty string key.
    field: String,
    /// The namespace owning the referenced cell.
    target: RegisterNs,
  )
}

/// One copied register and its namespace/key address.
@internal
pub type Cell {
  Cell(
    /// The namespace that owns the payload codec.
    namespace: RegisterNs,
    /// Its exact register key.
    key: String,
    /// The payload and cell sequence captured together.
    register: Register,
  )
}

/// One immutable serialized entry; payload bytes are deliberately absent.
@internal
pub type Descriptor {
  Descriptor(
    /// The canonical immutable entry identity.
    id: EntryId,
    /// The entry's durable sequence, below the captured high-water.
    seq: Int,
    /// The complete core-codec JSON payload size, before base64 wrapping.
    byte_length: Int,
  )
}

/// Mutable metadata and initial entry inventory from the same instant.
@internal
pub type Cut {
  Cut(
    /// Every entry in this snapshot has a sequence strictly below this value.
    next_seq: Int,
    /// Statistics from the same transaction as the cells.
    stats: SessionStats,
    /// Complete selected metadata; never silently truncated.
    cells: List(Cell),
    /// Accounted encoded payload and identifier bytes, not BEAM heap usage.
    metadata_bytes: Int,
    /// At most the requested recent entries, in ascending sequence order.
    recent: List(Descriptor),
  )
}

/// Refusals preserve the distinction between resource limits and corruption.
@internal
pub type Error {
  /// The wait expired; the read may still be queued or running. Never retry.
  ReadTimedOut

  /// The actor was absent or died before replying. Session custody still owns it.
  ReaderUnavailable

  /// The ordinary backend read failed, including a sealed handle.
  StorageFailure(error: StorageError)

  /// A trusted caller supplied an invalid plan, range or fragment offset.
  InvalidRequest

  /// The complete selected metadata exceeds its byte or cell budget.
  MetadataTooLarge

  /// This immutable record exceeds the advertised reassembly bound.
  RecordTooLarge(id: EntryId, byte_length: Int)

  /// An exact descriptor or referenced cell no longer matches the store.
  MissingRecord
}

/// A payload-free register address used to account before fetching bytes.
@internal
pub type Header {
  Header(
    /// The namespace used by the subsequent exact lookup.
    namespace: RegisterNs,
    /// The exact key, admitted within the header byte budget.
    key: String,
    /// The cell sequence that the subsequent payload lookup must match.
    seq: Int,
    /// Encoded JSON payload bytes, without fetching the payload itself.
    byte_length: Int,
  )
}

/// Backend primitives used only within one storage dispatch/transaction.
@internal
pub type Source {
  Source(
    /// Returns at most 1025 headers, including malformed predicate candidates.
    headers: fn(RegisterNs, String, Predicate) -> Result(List(Header), Error),
    /// Resolves an exact reference without copying its payload.
    header: fn(RegisterNs, String) -> Result(Header, Error),
    /// Fetches and totally decodes a cell whose header was admitted.
    cell: fn(Header) -> Result(Cell, Error),
  )
}

/// Validates the plan before any backend query is issued.
///
/// ## Examples
///
/// ```gleam
/// assert snapshot.validate(snapshot.Plan([], [], 50)) == Ok(Nil)
/// ```
@internal
pub fn validate(plan: Plan) -> Result(Nil, Error) {
  use <- bool.guard(
    list.drop(plan.selections, 16) != []
      || list.drop(plan.references, 16) != []
      || plan.recent_entries < 0
      || plan.recent_entries > page_limit,
    Error(InvalidRequest),
  )
  use _ <- result.try(
    list.try_map(plan.selections, fn(selection) {
      case selection {
        ExactKey(_, key) -> check_budget(1, string.byte_size(key) + 65)
        Selection(_, _, All) -> Ok(Nil)
        Selection(_, _, StringFieldEquals(field, _)) -> validate_field(field)
      }
    }),
  )
  list.try_map(plan.references, fn(reference) {
    validate_field(reference.field)
  })
  |> result.replace(Nil)
}

fn validate_field(field: String) -> Result(Nil, Error) {
  case
    field != ""
    && string.byte_size(field) <= 128
    && list.all(string.to_graphemes(field), fn(character) {
      string.contains(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_",
        character,
      )
    })
  {
    True -> Ok(Nil)
    False -> Error(InvalidRequest)
  }
}

/// Reads a whole bounded metadata projection using backend-owned primitives.
///
/// The source must remain on one coherent backend state for the whole call.
/// The returned tuple is the copied cells and their accounted byte total.
///
/// ## Examples
///
/// ```gleam
/// // snapshot.collect(plan, source, initial_bytes: usage_bytes)
/// ```
@internal
pub fn collect(
  plan: Plan,
  source: Source,
  initial_bytes initial_bytes: Int,
) -> Result(#(List(Cell), Int), Error) {
  use Nil <- result.try(validate(plan))
  use Nil <- result.try(check_budget(0, initial_bytes))
  use #(headers, bytes) <- result.try(
    list.try_fold(
      plan.selections,
      #(dict.new(), initial_bytes),
      fn(acc, selection) {
        use selected <- result.try(selection_headers(source, selection))
        add_headers(acc, selected)
      },
    ),
  )
  use cells <- result.try(list.try_map(dict.values(headers), source.cell))

  // Validate predicates even though SQLite already filtered valid values.
  // Malformed candidates remain visible so they cannot become silent omissions.
  use _ <- result.try(
    list.try_map(cells, fn(cell) { validate_predicates(plan.selections, cell) }),
  )
  use referenced <- result.try(reference_headers(plan.references, cells, source))
  use #(all_headers, bytes) <- result.try(add_headers(
    #(headers, bytes),
    referenced,
  ))
  let additional =
    dict.values(all_headers)
    |> list.filter(fn(header) { !dict.has_key(headers, header_key(header)) })
  use extra <- result.map(list.try_map(additional, source.cell))
  #(list.append(cells, extra), bytes)
}

// Exact-key lookups reuse the indexed primitive used by reference expansion.
// Unlike a required reference, an explicitly requested missing cell is an
// absence in this cut, not corruption. All other failures remain failures.
fn selection_headers(
  source: Source,
  selection: Selection,
) -> Result(List(Header), Error) {
  case selection {
    Selection(namespace, prefix, predicate) ->
      source.headers(namespace, prefix, predicate)
    ExactKey(namespace, key) ->
      case source.header(namespace, key) {
        Ok(header) -> Ok([header])
        Error(MissingRecord) -> Ok([])
        Error(error) -> Error(error)
      }
  }
}

fn validate_predicates(
  selections: List(Selection),
  cell: Cell,
) -> Result(Nil, Error) {
  list.try_fold(selections, Nil, fn(_, selection) {
    case selection {
      ExactKey(_, _) -> Ok(Nil)
      Selection(namespace, prefix, predicate) -> {
        use <- bool.guard(
          namespace != cell.namespace || !string.starts_with(cell.key, prefix),
          Ok(Nil),
        )
        matches(predicate, cell.register.value.payload) |> result.replace(Nil)
      }
    }
  })
}

/// Evaluates a validated predicate for the in-memory backend.
///
/// ## Examples
///
/// ```gleam
/// assert snapshot.matches(snapshot.All, json.Null) == Ok(True)
/// ```
@internal
pub fn matches(
  predicate: Predicate,
  payload: json.JsonValue,
) -> Result(Bool, Error) {
  case predicate {
    All -> Ok(True)
    StringFieldEquals(field, expected) -> {
      use value <- result.try(field_value(payload, field))
      case value {
        json.String(actual) -> Ok(actual == expected)
        json.Null
        | json.Bool(_)
        | json.Int(_)
        | json.Float(_)
        | json.Array(_)
        | json.Object(_) -> corrupt("a string predicate field")
      }
    }
  }
}

fn reference_headers(
  references: List(Reference),
  cells: List(Cell),
  source: Source,
) -> Result(List(Header), Error) {
  use nested <- result.map(
    list.try_map(references, fn(reference) {
      let selected =
        list.filter(cells, fn(cell) { cell.namespace == reference.source })
      use keys <- result.try(
        list.try_map(selected, fn(cell) {
          use value <- result.try(field_value(
            cell.register.value.payload,
            reference.field,
          ))
          case value {
            json.Null -> Ok(None)
            json.String(key) if key != "" -> Ok(Some(key))
            _ -> corrupt("a nullable nonempty reference key")
          }
        }),
      )
      keys
      |> list.filter_map(option.to_result(_, Nil))
      |> list.unique
      |> list.try_map(fn(key) { source.header(reference.target, key) })
    }),
  )
  list.flatten(nested)
}

fn field_value(
  payload: json.JsonValue,
  field: String,
) -> Result(json.JsonValue, Error) {
  case payload {
    json.Object(fields) ->
      list.key_find(fields, field)
      |> result.map_error(fn(_) { corruption_error("a present JSON field") })
    json.Null
    | json.Bool(_)
    | json.Int(_)
    | json.Float(_)
    | json.String(_)
    | json.Array(_) -> corrupt("a JSON object")
  }
}

fn add_headers(
  acc: #(dict.Dict(String, Header), Int),
  headers: List(Header),
) -> Result(#(dict.Dict(String, Header), Int), Error) {
  list.try_fold(headers, acc, fn(acc, header) {
    let #(seen, bytes) = acc
    let key = header_key(header)
    case dict.has_key(seen, key) {
      True -> Ok(acc)
      False -> {
        let bytes = bytes + header.byte_length + string.byte_size(key) + 64
        use Nil <- result.try(check_budget(dict.size(seen) + 1, bytes))
        use <- bool.lazy_guard(header.byte_length < 0 || header.seq < 1, fn() {
          corrupt("a valid register header")
        })
        Ok(#(dict.insert(seen, key, header), bytes))
      }
    }
  })
}

fn header_key(header: Header) -> String {
  register.ns_to_string(header.namespace) <> "/" <> header.key
}

/// Checks accounting without allocating the corresponding payload.
///
/// ## Examples
///
/// ```gleam
/// assert snapshot.check_budget(1025, 0) == Error(snapshot.MetadataTooLarge)
/// ```
@internal
pub fn check_budget(cells: Int, bytes: Int) -> Result(Nil, Error) {
  case cells > metadata_cells_limit || bytes > metadata_bytes_limit {
    True -> Error(MetadataTooLarge)
    False -> Ok(Nil)
  }
}

/// Validates bounded inventory range arguments before a backend query.
///
/// ## Examples
///
/// ```gleam
/// assert snapshot.validate_page(0, 10, 100) == Ok(Nil)
/// ```
@internal
pub fn validate_page(
  after: Int,
  before: Int,
  limit: Int,
) -> Result(Nil, Error) {
  case after >= 0 && before > after && limit > 0 && limit <= page_limit {
    True -> Ok(Nil)
    False -> Error(InvalidRequest)
  }
}

/// Rejects an oversized record before any payload query or reassembly.
///
/// ## Examples
///
/// ```gleam
/// // snapshot.validate_descriptor(descriptor)
/// ```
@internal
pub fn validate_descriptor(
  descriptor: Descriptor,
) -> Result(Descriptor, Error) {
  use <- bool.guard(
    descriptor.seq < 1 || descriptor.byte_length < 1,
    Error(InvalidRequest),
  )
  case descriptor.byte_length > record_bytes_limit {
    True -> Error(RecordTooLarge(descriptor.id, descriptor.byte_length))
    False -> Ok(descriptor)
  }
}

/// Validates a fragment offset without fetching the immutable payload.
///
/// ## Examples
///
/// ```gleam
/// // snapshot.validate_fragment(descriptor, offset: 0)
/// ```
@internal
pub fn validate_fragment(
  descriptor: Descriptor,
  offset: Int,
) -> Result(Nil, Error) {
  use _ <- result.try(validate_descriptor(descriptor))
  case offset >= 0 && offset <= descriptor.byte_length {
    True -> Ok(Nil)
    False -> Error(InvalidRequest)
  }
}

fn corrupt(expected: String) -> Result(a, Error) {
  Error(corruption_error(expected))
}

fn corruption_error(expected: String) -> Error {
  StorageFailure(
    storage.CorruptRow(corruption.report(
      at: "storage/snapshot",
      on: "metadata",
      expected:,
      context: "invalid snapshot metadata",
    )),
  )
}
