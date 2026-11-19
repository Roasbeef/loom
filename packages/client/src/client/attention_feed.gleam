//// What a session says it needs from a person, as the owner's inbox reads it
//// (protocol-change/120): the feed row a resident computes for itself, and the
//// shape a single record is read back in.
////
//// ## Flow
////
//// `feed` → `row_of` → `shed` → `encode`
////
//// 1. `feed` reads the ask and find prefixes, the strand-state listing and the
////    last-result listing, one listing each, so a row costs a fixed number of
////    store calls whatever the session holds.
//// 2. `stuck_strands` names the strands that stopped on a failed run and were
////    not run again, with what the failure entry and the lineage ledger say
////    about each (`Evidence`). `row_of` reduces the three kinds to counts and
////    short items.
//// 3. `shed` removes items until the encoded row fits the row bound, and
////    `encode` words it. A count is never reduced.
//// 4. `record_json` words one record for `attention.read`, from the typed
////    record, with the revision and whether the caller may act on it.
////
//// ## Why only identities and heads
////
//// A row names a record and cuts its text to a head. The questions, options
//// and reasons are read at the moment of the act, by `attention.read`, with the
//// revision the act will name. That keeps twenty-four rows inside one frame,
//// and keeps what a person acts on from being a copy that went stale.
////
//// ## What the bounds are
////
//// Every text is cut on a grapheme boundary (`glance.clip`) and the encoded row
//// is then measured, because escaping can still grow a clipped string. An
//// oversized row sheds its oldest finds first, then its oldest stuck strands,
//// then its oldest asks. The fixed part of a row, with every list empty, is far
//// under `row_bytes`, so every row can be made to fit.

import client/attention as store
import core/attention.{type Ask, type Find}
import core/entry.{type Entry}
import core/glance
import core/ids.{type EntryId, type OpId}
import core/json.{type JsonValue}
import core/message
import core/register
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import machine/codec
import machine/operation
import runtime/api
import runtime/lineage
import runtime/writer
import storage/storage

/// The encoded size a feed row never exceeds. The daemon adds the session's
/// identity and places up to 24 rows in one 60,000-byte reply, so this bound,
/// like `peer_mail.overview_row_bytes`, is what lets the reply fit without a
/// page cursor.
pub const row_bytes = 2300

/// The longest head, in bytes, of an ask or a find.
pub const head_bytes = 120

/// The primary strand, which `client/advisor.primary` also names. It is stated
/// here because the advisor's module reaches this one through `peer_mail`, and
/// a test pins the two spellings together.
pub const primary_strand = "main"

/// The advisor's strand, `client/advisor.strand`, stated here for the same
/// reason and pinned by the same test.
pub const advisor_strand = "advisor"

/// The longest strand name a row carries, in bytes, as a glance's is.
const strand_bytes = 96

/// The most items a section holds before shedding. A session holds at most 32
/// asks and 128 finds, and no row has room for that many, so the lists are cut
/// here first and the shedding loop re-encodes a short list.
const item_cap = 40

/// The longest path a row carries, in bytes. A longer one is left out with its
/// line, since a cut path is a path that does not exist.
const path_bytes = 160

/// One open ask, as a row lists it.
pub type AskItem {
  AskItem(
    /// The ask's identifier.
    id: String,
    /// The strand that asked, cut to `strand_bytes`.
    strand: String,
    /// Unix milliseconds.
    created_at: Int,
    /// The first question's prompt, cut.
    head: String,
    /// How many questions the ask holds.
    questions: Int,
  )
}

/// One open find, as a row lists it.
pub type FindItem {
  FindItem(
    /// The find's identifier.
    id: String,
    /// The strand that noticed it, cut to `strand_bytes`.
    strand: String,
    /// `risk`, `idea`, `bug` or `question`.
    kind: attention.FindKind,
    /// Unix milliseconds.
    created_at: Int,
    /// The find's text, cut.
    head: String,
    /// The path and line the find is about, when it names a path of at most
    /// `path_bytes` and has a line.
    place: Option(#(String, Option(Int))),
  )
}

/// One strand that stopped on a failed run and has not run since
/// (protocol-change/120, the addendum on stuck strands).
pub type Stuck {
  Stuck(
    /// The strand, cut to `strand_bytes`.
    strand: String,
    /// The time of the failed response entry the run ended on, in Unix
    /// milliseconds, which is when the failure was recorded. Absent when the
    /// result's leaf is not a failed response, as when the run failed before a
    /// request was made, so no time is ever a guess.
    failed_at: Option(Int),
    /// The run's error code, a fixed word of the harness (`provider_error`,
    /// `context_overflow`, ...) and never model text. A code that is not a short
    /// lower-case word is `failed`.
    reason: String,
    /// The provider's minimum wait before a retry, in milliseconds, when the
    /// failed response carries one.
    retry_after_ms: Option(Int),
    /// The strand that spawned this one, from the lineage ledger and cut to
    /// `strand_bytes`. Absent for a strand with no ledger cell.
    parent: Option(String),
  )
}

/// What a row reads beside the two registers to say more about a stuck strand:
/// the entries its failed runs ended on and the lineage ledger's parents. Both
/// are read once for the whole row, so the cost does not grow with the strands.
pub type Evidence {
  Evidence(
    /// The leaf entries of the failed results, by identifier.
    entries: Dict(EntryId, Entry),
    /// Each strand's parent, from the lineage ledger.
    parents: Dict(String, String),
  )
}

/// No evidence: a stuck strand then has no time, no retry hint and no parent.
///
/// ## Examples
///
/// ```gleam
/// assert attention_feed.no_evidence().parents == dict.new()
/// ```
pub fn no_evidence() -> Evidence {
  Evidence(entries: dict.new(), parents: dict.new())
}

/// The longest error code a stuck item carries, in bytes.
const reason_bytes = 40

/// A count of what a session holds and the items of it a row has room for.
pub type Section(item) {
  Section(
    /// Every record of the kind that was read, whether or not it is in `items`.
    count: Int,
    /// The records the row has room for, newest first.
    items: List(item),
  )
}

/// One session's row.
pub type Row {
  Row(
    /// The smallest `created_at` over the open asks routed to the owner.
    waiting_since: Option(Int),
    /// The open asks routed to the owner.
    asks: Section(AskItem),
    /// The open finds.
    finds: Section(FindItem),
    /// The stuck strands.
    stuck: Section(Stuck),
  )
}

/// Whether the caller may act on a record it reads, which the daemon decides
/// from the registry and the record's state.
pub type Handling {
  /// The caller may answer or close the record.
  CanAct

  /// The caller may read the record and do nothing else.
  ReadOnly
}

// --- the row -------------------------------------------------------------------

/// The row this session reports: its open owner-routed asks, its open finds and
/// its stuck strands, shed to fit `row_bytes` and encoded.
///
/// ## Examples
///
/// ```gleam
/// // attention_feed.feed(runtime)
/// ```
pub fn feed(runtime: api.Runtime) -> Result(JsonValue, String) {
  use asks <- result.try(store.asks(runtime))
  use finds <- result.try(store.finds(runtime))
  use states <- result.try(strand_states(runtime))
  use results <- result.map(last_results(runtime))

  // The evidence only adds a time, a hint and a parent to a stuck item. A read of
  // it that fails must not cost the row its asks, finds and stuck strands, so the
  // items are listed without it.
  let evidence =
    evidence_for(runtime, states, results)
    |> result.unwrap(no_evidence())
  row_of(asks, finds, stuck_strands(states, results, evidence))
  |> shed
  |> encode
}

/// The row of a set of records and stuck strands, with every item kept and
/// every count taken. A settled record, and an ask routed to a strand, are not
/// in it.
///
/// ## Examples
///
/// ```gleam
/// assert attention_feed.row_of([], [], []).asks.count == 0
/// ```
pub fn row_of(asks: List(Ask), finds: List(Find), stuck: List(Stuck)) -> Row {
  let owed =
    list.filter(asks, fn(ask) {
      ask.state == attention.AskOpen && ask.header.routing == attention.ToOwner
    })
  let open = list.filter(finds, fn(find) { find.state == attention.FindOpen })
  Row(
    waiting_since: oldest(list.map(owed, fn(ask) { ask.header.created_at })),
    asks: section(list.map(owed, ask_item), fn(item) { item.created_at }),
    finds: section(list.map(open, find_item), fn(item) { item.created_at }),
    stuck: Section(
      count: list.length(stuck),
      items: list.take(list.sort(stuck, newest_stuck), item_cap),
    ),
  )
}

/// A section with its items newest first.
fn section(items: List(item), at: fn(item) -> Int) -> Section(item) {
  Section(
    count: list.length(items),
    items: list.take(
      list.sort(items, fn(left, right) { int.compare(at(right), at(left)) }),
      item_cap,
    ),
  )
}

/// The smallest of some times, or none.
fn oldest(times: List(Int)) -> Option(Int) {
  list.reduce(times, int.min) |> option.from_result
}

/// Orders stuck strands newest failure first, and a strand with no time last.
fn newest_stuck(left: Stuck, right: Stuck) -> order.Order {
  case left.failed_at, right.failed_at {
    Some(a), Some(b) -> int.compare(b, a)
    Some(_), None -> order.Lt
    None, Some(_) -> order.Gt
    None, None -> string.compare(left.strand, right.strand)
  }
}

/// An ask as a row lists it.
fn ask_item(ask: Ask) -> AskItem {
  // An ask with no question, which no tool can write, has an empty head.
  let head = case ask.questions {
    [first, ..] -> first.prompt
    [] -> ""
  }

  AskItem(
    id: ask.header.id,
    strand: glance.clip(ask.header.strand, strand_bytes),
    created_at: ask.header.created_at,
    head: glance.clip(head, head_bytes),
    questions: list.length(ask.questions),
  )
}

/// A find as a row lists it. A line is kept only with its path, and a path only
/// when it fits whole.
fn find_item(find: Find) -> FindItem {
  // A path longer than the bound is left out whole, with its line.
  let place = case find.path {
    Some(path) ->
      case string.byte_size(path) <= path_bytes {
        True -> Some(#(path, find.line))
        False -> None
      }
    None -> None
  }

  FindItem(
    id: find.header.id,
    strand: glance.clip(find.header.strand, strand_bytes),
    kind: find.kind,
    created_at: find.header.created_at,
    head: glance.clip(find.text, head_bytes),
    place:,
  )
}

// --- stuck strands ---------------------------------------------------------------

/// The strands that stopped on a failed run and were not run again.
///
/// A strand is stuck when it is not `main` and not the advisor's, has no current
/// operation, and its latest terminal result is a run that failed. `main` is
/// left out because a failed main run is already `needs_you` in the session's
/// state word. The result register is overwritten by the next terminal result
/// on its strand, so "not run again" holds by construction: a later run,
/// compaction or navigation takes the strand out of the set.
///
/// ## Examples
///
/// ```gleam
/// assert attention_feed.stuck_strands([], [], attention_feed.no_evidence()) == []
/// ```
pub fn stuck_strands(
  states: List(#(String, Option(OpId))),
  results: List(#(String, operation.LastResult)),
  evidence: Evidence,
) -> List(Stuck) {
  list.filter_map(results, fn(entry) {
    let #(strand, last) = entry
    use failure <- result.map(failed_without_retry(strand, last, states))
    let #(error, leaf) = failure
    let #(failed_at, retry_after_ms) = failure_entry(evidence, leaf)
    Stuck(
      strand: glance.clip(strand, strand_bytes),
      failed_at:,
      reason: reason_word(error.code),
      retry_after_ms:,
      parent: dict.get(evidence.parents, strand)
        |> result.map(glance.clip(_, strand_bytes))
        |> option.from_result,
    )
  })
}

/// The error code as a stuck item carries it: the harness's own short word, or
/// `failed` for anything else, so no text a provider or a model chose can ride
/// in the field.
fn reason_word(code: String) -> String {
  let word =
    list.all(string.to_graphemes(code), fn(grapheme) {
      string.contains("abcdefghijklmnopqrstuvwxyz0123456789_", grapheme)
    })

  // A code that is not a short lower-case word is reported as `failed`.
  case word && code != "" && string.byte_size(code) <= reason_bytes {
    True -> code
    False -> "failed"
  }
}

/// The time and retry hint of the failed response a run ended on. Only an
/// assistant entry that records an error stands for the failure; any other
/// leaf, or one that was not read, gives neither.
fn failure_entry(
  evidence: Evidence,
  leaf: Option(EntryId),
) -> #(Option(Int), Option(Int)) {
  // Only a leaf that was read can say when the run failed.
  let found = case leaf {
    Some(id) -> dict.get(evidence.entries, id)
    None -> Error(Nil)
  }

  // An assistant entry that records an error stands for the failure.
  case found {
    Ok(entry.MessageEntry(
      message: message.AssistantMessage(
        stop_reason: message.Errored,
        diagnostics:,
        ..,
      ),
      ts:,
      ..,
    )) -> #(Some(ts), retry_after(diagnostics))
    Ok(_) | Error(Nil) -> #(None, None)
  }
}

/// The provider's wait hint in a response's diagnostics, when it is a
/// non-negative whole number.
fn retry_after(diagnostics: Option(JsonValue)) -> Option(Int) {
  case diagnostics {
    Some(json.Object(fields)) ->
      case list.key_find(fields, "retry_after_ms") {
        Ok(json.Int(delay)) if delay >= 0 -> Some(delay)
        Ok(_) | Error(Nil) -> None
      }
    Some(_) | None -> None
  }
}

/// For a strand whose last result is a failed run and that is neither `main`,
/// the advisor nor running, the run's error and its leaf entry.
fn failed_without_retry(
  strand: String,
  last: operation.LastResult,
  states: List(#(String, Option(OpId))),
) -> Result(#(operation.OperationError, Option(EntryId)), Nil) {
  // A strand that is running has moved past its last failure.
  let running = case list.key_find(states, strand) {
    Ok(Some(_)) -> True
    Ok(None) | Error(Nil) -> False
  }

  // Only a failed run of an idle strand is stuck; no other result is.
  case strand == primary_strand || strand == advisor_strand || running, last {
    False,
      operation.RunLastResult(outcome: operation.RunFailed(error:), leaf:, ..)
    -> Ok(#(error, leaf))
    True, _
    | False, operation.RunLastResult(..)
    | False, operation.CompactionLastResult(..)
    | False, operation.NavigationLastResult(..)
    -> Error(Nil)
  }
}

/// What a row reads for its stuck strands: one batch read of the entries their
/// failed runs ended on, and one listing of the lineage ledger. A session with
/// no stuck strand reads neither.
fn evidence_for(
  runtime: api.Runtime,
  states: List(#(String, Option(OpId))),
  results: List(#(String, operation.LastResult)),
) -> Result(Evidence, String) {
  case stuck_strands(states, results, no_evidence()) {
    [] -> Ok(no_evidence())
    [_, ..] -> read_evidence(runtime, results)
  }
}

/// The failed runs' leaf entries and the lineage ledger's parents.
fn read_evidence(
  runtime: api.Runtime,
  results: List(#(String, operation.LastResult)),
) -> Result(Evidence, String) {
  let leaves =
    list.filter_map(results, fn(entry) {
      case entry.1 {
        operation.RunLastResult(
          outcome: operation.RunFailed(_),
          leaf: Some(leaf),
          ..,
        ) -> Ok(leaf)
        operation.RunLastResult(..)
        | operation.CompactionLastResult(..)
        | operation.NavigationLastResult(..) -> Error(Nil)
      }
    })
  use entries <- result.try(
    writer.get_entries(runtime.tree.writer, leaves)
    |> result.map_error(string.inspect),
  )
  use cells <- result.map(
    api.reserved_facts(runtime, prefix: lineage.key_prefix)
    |> result.map_error(string.inspect),
  )

  // A ledger cell that does not decode names no parent, which is the absent
  // field and not a fault.
  let parents =
    list.filter_map(cells, fn(pair) {
      use strand <- result.try(lineage.strand_of_key(pair.0))
      use cell <- result.map(
        lineage.decode(pair.1) |> result.replace_error(Nil),
      )
      #(strand, cell.parent)
    })
  Evidence(entries:, parents: dict.from_list(parents))
}

/// Every strand's current operation, from one listing of the strand-state
/// namespace. A cell that does not decode is left out.
pub fn strand_states(
  runtime: api.Runtime,
) -> Result(List(#(String, Option(OpId))), String) {
  use cells <- result.map(
    writer.list_registers(runtime.tree.writer, register.StrandState, None)
    |> result.map_error(string.inspect),
  )
  list.filter_map(cells, fn(pair) {
    let #(strand, storage.Register(value:, ..)) = pair
    codec.decode_strand_state(value.payload)
    |> result.map(fn(state) { #(strand, state.current_operation) })
    |> result.replace_error(Nil)
  })
}

/// Every strand's latest terminal result, from one listing. A cell that does not
/// decode is left out.
pub fn last_results(
  runtime: api.Runtime,
) -> Result(List(#(String, operation.LastResult)), String) {
  use cells <- result.map(
    writer.list_registers(runtime.tree.writer, register.StrandLastResult, None)
    |> result.map_error(string.inspect),
  )
  list.filter_map(cells, fn(pair) {
    let #(strand, storage.Register(value:, ..)) = pair
    codec.decode_last_result(value.payload)
    |> result.map(fn(last) { #(strand, last) })
    |> result.replace_error(Nil)
  })
}

// --- fitting ---------------------------------------------------------------------

/// Removes items until the encoded row fits `row_bytes`: finds first, then
/// stuck strands, then asks, and in each the oldest first. Counts stay as they
/// were, so a row whose items are fewer than its count says how many it left
/// out.
///
/// ## Examples
///
/// ```gleam
/// assert attention_feed.shed(row) == row
/// ```
pub fn shed(row: Row) -> Row {
  case string.byte_size(json.to_string(encode(row))) <= row_bytes {
    True -> row
    False ->
      case without_oldest(row) {
        Ok(smaller) -> shed(smaller)
        Error(Nil) -> row
      }
  }
}

/// The row with its next item gone, or nothing when it holds none.
fn without_oldest(row: Row) -> Result(Row, Nil) {
  case row.finds.items, row.stuck.items, row.asks.items {
    [_, ..], _, _ ->
      Ok(
        Row(
          ..row,
          finds: Section(..row.finds, items: drop_last(row.finds.items)),
        ),
      )
    [], [_, ..], _ ->
      Ok(
        Row(
          ..row,
          stuck: Section(..row.stuck, items: drop_last(row.stuck.items)),
        ),
      )
    [], [], [_, ..] ->
      Ok(
        Row(..row, asks: Section(..row.asks, items: drop_last(row.asks.items))),
      )
    [], [], [] -> Error(Nil)
  }
}

/// A list without its last item, which is the oldest in a newest-first list.
fn drop_last(items: List(item)) -> List(item) {
  list.take(items, list.length(items) - 1)
}

/// The row as the reply carries it, without the session identity the daemon
/// adds.
///
/// ## Examples
///
/// ```gleam
/// // attention_feed.encode(attention_feed.row_of([], [], []))
/// ```
pub fn encode(row: Row) -> JsonValue {
  json.Object(
    list.flatten([
      [#("state", json.String("ok"))],
      case row.waiting_since {
        Some(at) -> [#("waiting_since", json.Int(at))]
        None -> []
      },
      [
        #("asks", encode_section(row.asks, ask_json)),
        #("finds", encode_section(row.finds, find_json)),
        #("stuck", encode_section(row.stuck, stuck_json)),
      ],
    ]),
  )
}

/// A section as `{"count", "items"}`.
fn encode_section(
  section: Section(item),
  encode_item: fn(item) -> JsonValue,
) -> JsonValue {
  json.Object([
    #("count", json.Int(section.count)),
    #("items", json.Array(list.map(section.items, encode_item))),
  ])
}

/// An ask item.
fn ask_json(item: AskItem) -> JsonValue {
  json.Object([
    #("id", json.String(item.id)),
    #("strand", json.String(item.strand)),
    #("created_at", json.Int(item.created_at)),
    #("head", json.String(item.head)),
    #("questions", json.Int(item.questions)),
  ])
}

/// A find item, with `path` and `line` only when it has them.
fn find_json(item: FindItem) -> JsonValue {
  json.Object(
    list.flatten([
      [
        #("id", json.String(item.id)),
        #("strand", json.String(item.strand)),
        #("kind", json.String(attention.find_kind_name(item.kind))),
        #("created_at", json.Int(item.created_at)),
        #("head", json.String(item.head)),
      ],
      case item.place {
        Some(#(path, line)) ->
          list.append([#("path", json.String(path))], case line {
            Some(number) -> [#("line", json.Int(number))]
            None -> []
          })
        None -> []
      },
    ]),
  )
}

/// A stuck item, with `failed_at`, `retry_after_ms` and `parent` only when it
/// has them.
fn stuck_json(item: Stuck) -> JsonValue {
  json.Object(
    list.flatten([
      [
        #("strand", json.String(item.strand)),
        #("reason", json.String(item.reason)),
      ],
      optional_int("failed_at", item.failed_at),
      optional_int("retry_after_ms", item.retry_after_ms),
      case item.parent {
        Some(parent) -> [#("parent", json.String(parent))]
        None -> []
      },
    ]),
  )
}

/// A member that is present only when it has a value.
fn optional_int(
  name: String,
  value: Option(Int),
) -> List(#(String, JsonValue)) {
  case value {
    Some(number) -> [#(name, json.Int(number))]
    None -> []
  }
}

// --- one record ------------------------------------------------------------------

/// A record as `attention.read` answers it: the whole record, its revision and
/// whether the caller may act on it. An observer's `may_answer` and `may_close`
/// are false whatever the record's state.
///
/// ## Examples
///
/// ```gleam
/// // attention_feed.record_json(stored, attention_feed.CanAct)
/// ```
pub fn record_json(stored: store.Stored, handling: Handling) -> JsonValue {
  case stored {
    store.StoredAsk(ask:, revision:) -> ask_record(ask, revision, handling)
    store.StoredFind(find:, revision:) -> find_record(find, revision, handling)
  }
}

/// An ask's record. `may_answer` is true only for an open ask routed to the
/// owner that the caller may act on.
fn ask_record(ask: Ask, revision: Int, handling: Handling) -> JsonValue {
  let open = ask.state == attention.AskOpen
  let owner = ask.header.routing == attention.ToOwner
  let stored = fields_of(attention.encode_ask(ask))
  json.Object(
    list.flatten([
      kept(stored, ["id", "kind"]),
      [#("revision", json.Int(revision))],
      kept(stored, ["status", "routing", "strand", "created_at", "anchor"]),
      hoisted(stored, "content", ["why", "questions"]),
      answer_of(stored),
      [#("may_answer", json.Bool(handling == CanAct && open && owner))],
    ]),
  )
}

/// A find's record. `may_close` is true only for an open find that the caller
/// may act on.
fn find_record(find: Find, revision: Int, handling: Handling) -> JsonValue {
  let open = find.state == attention.FindOpen
  let stored = fields_of(attention.encode_find(find))
  json.Object(
    list.flatten([
      kept(stored, ["id", "kind"]),
      [#("revision", json.Int(revision))],
      kept(stored, ["status", "strand", "created_at", "anchor"]),
      hoisted(stored, "content", ["find_kind", "text", "path", "line"]),
      closure_of(stored),
      [#("may_close", json.Bool(handling == CanAct && open))],
    ]),
  )
}

/// The fields of an encoded record.
fn fields_of(value: JsonValue) -> List(#(String, JsonValue)) {
  case value {
    json.Object(fields) -> fields
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> []
  }
}

/// The named fields, in the order named, of those that are present.
fn kept(
  fields: List(#(String, JsonValue)),
  names: List(String),
) -> List(#(String, JsonValue)) {
  list.filter_map(names, fn(name) {
    list.key_find(fields, name) |> result.map(fn(value) { #(name, value) })
  })
}

/// The named fields of the object under `holder`.
fn hoisted(
  fields: List(#(String, JsonValue)),
  holder: String,
  names: List(String),
) -> List(#(String, JsonValue)) {
  case list.key_find(fields, holder) {
    Ok(inner) -> kept(fields_of(inner), names)
    Error(Nil) -> []
  }
}

/// The `answer` of an answered ask: the answer object with `by` and the time it
/// was given.
fn answer_of(stored: List(#(String, JsonValue))) -> List(#(String, JsonValue)) {
  case list.key_find(stored, "answer"), list.key_find(stored, "settled_at") {
    Ok(answer), Ok(at) -> [
      #("answer", json.Object(list.append(fields_of(answer), [#("at", at)]))),
    ]
    Ok(_), Error(Nil) | Error(Nil), _ -> []
  }
}

/// The `closure` of a closed find: how, when and by whom.
fn closure_of(
  stored: List(#(String, JsonValue)),
) -> List(#(String, JsonValue)) {
  // A closed find carries its closure and the time it was settled.
  case list.key_find(stored, "closure"), list.key_find(stored, "settled_at") {
    Ok(closure), Ok(at) -> {
      let inner = fields_of(closure)
      [
        #(
          "closure",
          json.Object([
            #(
              "outcome",
              list.key_find(inner, "how") |> result.unwrap(json.Null),
            ),
            #("at", at),
            #("by", list.key_find(inner, "by") |> result.unwrap(json.Null)),
          ]),
        ),
      ]
    }
    Ok(_), Error(Nil) | Error(Nil), _ -> []
  }
}
