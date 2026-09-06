//// A credited snapshot is assembled privately and becomes visible only at end.
////
//// The terminal owns this pure reducer and its socket inbox. Every accepted
//// chunk grants exactly one subsequent request. Metadata and entries therefore
//// share one captured cut without letting partial configuration repaint a live
//// view. Large records are validated and drained without concatenating their
//// payload; an explicit unloaded item preserves their durable identity.

import core/codec
import core/entry.{type Entry}
import core/ids
import core/json
import core/message.{type Origin}
import core/origin
import gleam/bit_array
import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// Largest raw protocol record, even when presentation does not decode it.
pub const record_limit = 33_554_432

/// Largest individual entry decoded into presentation data.
pub const presentation_limit = 4_194_304

/// Total encoded entry payload retained in the visible history window.
pub const window_limit = 8_388_608

/// Largest coherent metadata document accepted before JSON decoding.
pub const metadata_limit = 2_097_152

/// Largest decoded piece carried by one credited response.
pub const piece_limit = 24_576

/// Authority learned from this authenticated attachment, never from turn labels.
pub type Role {
  /// Daemon owner, distinct from a session-scoped operator membership.
  Owner

  /// Read-only presentation; mutation controls must remain disabled.
  Observer

  /// This attachment may explicitly submit session mutations.
  Operator
}

/// The control-selected target, checked again on every captured cut.
pub type Expected {
  Expected(
    /// Canonical durable session identity.
    session: String,
    /// Daemon lifetime authenticated by control.
    epoch: String,
    /// Explicit open's resident runtime identity.
    incarnation: String,
  )
}

/// Authenticated identity and role for one conversation socket.
pub type Attachment {
  Attachment(
    /// Immutable selected target.
    expected: Expected,
    /// Server-generated attachment identity.
    connection_id: String,
    /// Server-owned principal and display name.
    origin: Origin,
    /// Server-owned authorization role.
    role: Role,
  )
}

/// One loaded or explicitly unloaded durable record, in a bounded window.
pub type Item {
  /// Decoded through the shared core codec, without assigning a strand.
  Loaded(
    /// Complete immutable record payload.
    entry: Entry,
    /// Original encoded bytes charged against the window allowance.
    bytes: Int,
  )

  /// Payload was drained but intentionally not decoded into terminal memory.
  Unloaded(
    /// Canonical entry identity from the descriptor.
    id: String,
    /// Durable sequence from the same descriptor.
    seq: Int,
    /// Full raw record size, not a pretend truncated entry.
    bytes: Int,
  )
}

/// Retained presentation history is always partial, never the full store.
pub type Window {
  Window(
    /// Newest-first records, at most one hundred items.
    items: List(Item),
    /// Sum of Loaded bytes; unloaded payloads are not retained.
    bytes: Int,
    /// Highest sequence evicted from this local presentation window.
    evicted_through: Option(Int),
  )
}

/// One completely validated cut, suitable for atomic model adoption.
pub type Captured {
  Captured(
    /// Checked identity shared by this cut and its connection.
    attachment: Attachment,
    /// First unseen durable sequence after this captured cut.
    next_seq: Int,
    /// Coherent raw metadata, decoded by the presentation projection module.
    metadata: json.JsonValue,
    /// Bounded retained global records; missing parents remain unloaded.
    window: Window,
    /// Server's earliest descriptor in this partial response, when present.
    oldest_seq: Option(Int),
  )
}

type Part {
  Part(
    kind: String,
    id: String,
    seq: Option(Int),
    total: Int,
    offset: Int,
    chunks: List(BitArray),
  )
}

/// Uncommitted transfer state; the model must not render this as a new cut.
pub opaque type Transfer {
  Transfer(
    id: String,
    index: Int,
    attachment: Attachment,
    next_seq: Int,
    record_bytes: Int,
    piece_bytes: Int,
    oldest_seq: Option(Int),
    last_seq: Int,
    part: Option(Part),
    metadata: Option(json.JsonValue),
    window: Window,
  )
}

/// Creates the empty partial history window.
///
/// ## Examples
///
/// ```gleam
/// snapshot.empty() == snapshot.Window([], 0, None)
/// ```
pub fn empty() -> Window {
  Window([], 0, None)
}

/// Validates identity and declared limits before granting any snapshot credit.
///
/// ## Examples
///
/// ```gleam
/// // snapshot.begin(body, selected, prior_connection, prior_window, from_seq)
/// ```
pub fn begin(
  body: json.JsonValue,
  expected: Expected,
  previous: Option(Attachment),
  window: Window,
  from_seq: Int,
) -> Result(Transfer, String) {
  begin_window(body, expected, previous, window, from_seq, [
    "recent",
    "catch_up",
    "history",
  ])
}

/// Starts an exact escalation lookup without carrying the conversation window.
///
/// ## Examples
///
/// ```gleam
/// // snapshot.begin_lookup(body, selected, attachment, cursor)
/// ```
pub fn begin_lookup(
  body: json.JsonValue,
  expected: Expected,
  previous: Option(Attachment),
  from_seq: Int,
) -> Result(Transfer, String) {
  begin_window(body, expected, previous, empty(), from_seq, ["escalations"])
}

fn begin_window(body, expected, previous, window, from_seq, modes) {
  use fields <- result.try(object(body))
  use id <- result.try(text(fields, "snapshot_id"))
  use session <- result.try(text(fields, "session_id"))
  use epoch <- result.try(text(fields, "epoch"))
  use incarnation <- result.try(text(fields, "incarnation"))
  use connection_id <- result.try(text(fields, "connection_id"))
  use next_seq <- result.try(number(fields, "next_seq"))
  use oldest_seq <- result.try(optional_number(fields, "oldest_seq"))

  // The control selection and the conversation's independently authenticated
  // identity must agree before even metadata can replace the adopted view.
  use author <- result.try(
    origin.decode_field(fields)
    |> result.replace_error("invalid attachment origin")
    |> result.try(fn(author) {
      option.to_result(author, "missing attachment origin")
    }),
  )
  use role <- result.try(
    text(fields, "role")
    |> result.try(fn(role) {
      case role {
        "owner" -> Ok(Owner)
        "operator" -> Ok(Operator)
        "observer" -> Ok(Observer)
        _ -> Error("invalid attachment role")
      }
    }),
  )
  let attachment =
    Attachment(
      Expected(session, epoch, incarnation),
      connection_id,
      author,
      role,
    )
  use <- bool.guard(
    attachment.expected != expected
      || id == ""
      || string.byte_size(id) > 256
      || connection_id == ""
      || string.byte_size(connection_id) > 256
      || next_seq < from_seq,
    Error("snapshot identity or cursor does not match this attempt"),
  )
  use <- bool.guard(
    case previous {
      Some(prior) -> prior != attachment
      None -> False
    },
    Error("attachment identity changed on an existing socket"),
  )
  use #(record_bytes, piece_bytes) <- result.try(declared_limits(fields, modes))
  Ok(Transfer(
    id,
    0,
    attachment,
    next_seq,
    record_bytes,
    piece_bytes,
    oldest_seq,
    from_seq - 1,
    None,
    None,
    window,
  ))
}

fn declared_limits(fields, modes) {
  use record_bytes <- result.try(number(fields, "record_bytes_limit"))
  use fragment_bytes <- result.try(number(fields, "fragment_bytes_limit"))
  use complete <- result.try(field(fields, "complete_history"))
  use mode <- result.try(text(fields, "window"))
  use <- bool.guard(
    record_bytes <= 0
      || record_bytes > record_limit
      || fragment_bytes <= 0
      || fragment_bytes > piece_limit
      || complete != json.Bool(False)
      || !list.contains(modes, mode),
    Error("unsupported snapshot bounds or completeness claim"),
  )
  Ok(#(record_bytes, fragment_bytes))
}

/// Returns the exact credit to send after begin or one accepted chunk.
///
/// ## Examples
///
/// ```gleam
/// // snapshot.credit(transfer)
/// ```
pub fn credit(transfer: Transfer) -> #(String, Int) {
  #(transfer.id, transfer.index)
}

/// Accepts one correlated, offset-checked piece without exceeding reassembly caps.
///
/// ## Examples
///
/// ```gleam
/// // snapshot.chunk(transfer, body)
/// ```
pub fn chunk(
  transfer: Transfer,
  body: json.JsonValue,
) -> Result(Transfer, String) {
  use fields <- result.try(object(body))
  use Nil <- result.try(correlation(transfer, fields))
  use kind <- result.try(text(fields, "kind"))
  use id <- result.try(text(fields, "record_id"))
  use seq <- result.try(optional_number(fields, "record_seq"))
  use total <- result.try(number(fields, "total_bytes"))
  use offset <- result.try(number(fields, "offset"))
  use encoded <- result.try(text(fields, "data"))

  // A byte bound precedes base64 decoding; no advertised total controls an
  // allocation. Each piece is decoded independently, including split UTF-8.
  use <- bool.guard(
    string.byte_size(encoded) > 32_768,
    Error("snapshot piece exceeds encoded bound"),
  )
  use bytes <- result.try(
    bit_array.base64_decode(encoded)
    |> result.replace_error("invalid snapshot base64"),
  )
  use <- bool.guard(
    bit_array.byte_size(bytes) == 0
      || bit_array.byte_size(bytes) > transfer.piece_bytes
      || total <= 0
      || offset < 0
      || offset + bit_array.byte_size(bytes) > total,
    Error("invalid snapshot piece extent"),
  )
  use part <- result.try(continuation(
    transfer,
    Part(kind, id, seq, total, offset, []),
  ))
  let chunks = case kind == "metadata" || total <= presentation_limit {
    True -> [bytes, ..part.chunks]
    False -> []
  }
  let part = Part(..part, offset: offset + bit_array.byte_size(bytes), chunks:)
  let transfer = Transfer(..transfer, index: transfer.index + 1)
  case part.offset == part.total {
    False -> Ok(Transfer(..transfer, part: Some(part)))
    True -> complete_part(transfer, part)
  }
}

fn continuation(transfer: Transfer, incoming: Part) {
  case transfer.part {
    Some(part)
      if part.kind == incoming.kind
      && part.id == incoming.id
      && part.seq == incoming.seq
      && part.total == incoming.total
      && part.offset == incoming.offset
    -> Ok(part)
    Some(_) -> Error("snapshot record changed mid-transfer")
    None -> new_part(transfer, incoming)
  }
}

fn new_part(transfer: Transfer, part: Part) {
  use <- bool.guard(
    part.offset != 0,
    Error("snapshot record starts after zero"),
  )
  case part.kind, part.seq, transfer.metadata {
    "metadata", None, None
      if part.id == "metadata" && part.total <= metadata_limit
    -> Ok(part)
    "entry", Some(seq), Some(_)
      if seq > transfer.last_seq
      && seq < transfer.next_seq
      && part.total <= transfer.record_bytes
    -> {
      use parsed <- result.try(
        ids.parse_entry_id(part.id)
        |> result.replace_error("invalid entry descriptor identity"),
      )
      use <- bool.guard(
        ids.entry_id_to_string(parsed) != part.id,
        Error("entry descriptor identity is not canonical"),
      )
      Ok(part)
    }
    _, _, _ -> Error("invalid snapshot record order or descriptor")
  }
}

fn complete_part(transfer: Transfer, part: Part) {
  case part.kind, part.seq {
    "metadata", None -> {
      use value <- result.try(decode_part(part))
      use _fields <- result.try(object(value))
      Ok(Transfer(..transfer, part: None, metadata: Some(value)))
    }
    "entry", Some(seq) -> {
      use item <- result.try(decode_item(part, seq))
      Ok(
        Transfer(
          ..transfer,
          part: None,
          last_seq: seq,
          window: retain(transfer.window, item),
        ),
      )
    }
    _, _ -> Error("invalid completed snapshot record")
  }
}

fn decode_item(part: Part, seq: Int) {
  case part.total > presentation_limit {
    True -> Ok(Unloaded(part.id, seq, part.total))
    False -> {
      use value <- result.try(decode_part(part))
      use entry <- result.try(
        codec.decode_entry(value)
        |> result.replace_error("invalid durable entry payload"),
      )
      use <- bool.guard(
        ids.entry_id_to_string(entry.id) != part.id || entry.seq != seq,
        Error("entry payload differs from its descriptor"),
      )
      Ok(Loaded(entry, part.total))
    }
  }
}

fn decode_part(part: Part) {
  use text <- result.try(
    part.chunks
    |> list.reverse
    |> bit_array.concat
    |> bit_array.to_string
    |> result.replace_error("snapshot record is not UTF-8"),
  )
  json.parse(text) |> result.replace_error("snapshot record is invalid JSON")
}

/// Finishes only a complete cut; callers atomically apply metadata and history.
///
/// ## Examples
///
/// ```gleam
/// // snapshot.finish(transfer, body)
/// ```
pub fn finish(
  transfer: Transfer,
  body: json.JsonValue,
) -> Result(Captured, String) {
  use fields <- result.try(object(body))
  use Nil <- result.try(correlation(transfer, fields))
  use next_seq <- result.try(number(fields, "next_seq"))
  use _more <- result.try(optional_number(fields, "more_after"))
  use <- bool.guard(
    next_seq != transfer.next_seq || transfer.part != None,
    Error("snapshot ended with an incomplete record or changed cursor"),
  )
  use metadata <- result.try(option.to_result(
    transfer.metadata,
    "snapshot omitted metadata",
  ))
  Ok(Captured(
    transfer.attachment,
    next_seq,
    metadata,
    transfer.window,
    transfer.oldest_seq,
  ))
}

fn correlation(transfer: Transfer, fields) {
  use id <- result.try(text(fields, "snapshot_id"))
  use index <- result.try(number(fields, "index"))
  case id == transfer.id && index == transfer.index {
    True -> Ok(Nil)
    False -> Error("snapshot credit or identity does not match")
  }
}

fn retain(window: Window, item: Item) {
  trim(Window(
    [item, ..window.items],
    window.bytes + loaded_bytes(item),
    window.evicted_through,
  ))
}

fn trim(window: Window) {
  case window.bytes <= window_limit && list.drop(window.items, 100) == [] {
    True -> window
    False ->
      case list.reverse(window.items) {
        [] -> window
        [oldest, ..remaining] ->
          trim(Window(
            list.reverse(remaining),
            window.bytes - loaded_bytes(oldest),
            Some(sequence(oldest)),
          ))
      }
  }
}

/// Returns the descriptor sequence without requiring loaded payload data.
///
/// ## Examples
///
/// ```gleam
/// snapshot.sequence(snapshot.Unloaded("id", 12, 100)) == 12
/// ```
pub fn sequence(item: Item) -> Int {
  case item {
    Loaded(entry, _) -> entry.seq
    Unloaded(_, seq, _) -> seq
  }
}

fn loaded_bytes(item) {
  case item {
    Loaded(_, bytes) -> bytes
    Unloaded(..) -> 0
  }
}

fn object(value) {
  case value {
    json.Object(fields) -> Ok(fields)
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error("expected snapshot object")
  }
}

fn field(fields, name) {
  list.key_find(fields, name) |> result.replace_error("missing snapshot field")
}

fn text(fields, name) {
  use value <- result.try(field(fields, name))
  case value {
    json.String(text) -> Ok(text)
    json.Object(_)
    | json.Array(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error("expected snapshot string")
  }
}

fn number(fields, name) {
  use value <- result.try(field(fields, name))
  case value {
    json.Int(number) if number >= 0 -> Ok(number)
    json.Int(_)
    | json.Object(_)
    | json.Array(_)
    | json.String(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error("expected nonnegative snapshot integer")
  }
}

fn optional_number(fields, name) {
  use value <- result.try(field(fields, name))
  case value {
    json.Null -> Ok(None)
    json.Int(number) if number >= 0 -> Ok(Some(number))
    json.Int(_)
    | json.Object(_)
    | json.Array(_)
    | json.String(_)
    | json.Float(_)
    | json.Bool(_) -> Error("expected optional nonnegative snapshot integer")
  }
}
