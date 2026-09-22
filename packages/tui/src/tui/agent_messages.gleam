//// A bounded, provenance-preserving view of inter-agent sends.
////
//// The conversation tree can contain inherited entries which
//// `snapshot_view.branch` presents under the selected strand. A send is
//// therefore eligible only after that strand's current operation prompt,
//// whose identity is recorded in `OpMeta`. This module keeps the projection
//// pure and leaves unavailable older history to its caller to label.

import core/entry
import core/ids.{type EntryId}
import core/json
import core/message
import core/register
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, Some}
import gleam/result
import gleam/string
import machine/codec
import machine/operation
import tui/protocol
import tui/snapshot
import tui/snapshot_view
import tui/text_hygiene

/// The delivery state visible for one captured send.
pub type State {
  /// The invocation has no matching durable result in the retained suffix.
  SendPending

  /// The matching result reports an in-band tool failure.
  SendFailed

  /// The send was accepted and steered an already-running recipient.
  Accepted

  /// The send was accepted and started a recipient operation.
  Started
}

/// Whether the retained body is complete or bounded for the workspace row.
pub type BodyExtent {
  /// The complete sanitized message body is retained.
  Complete

  /// The visible body is bounded and the transcript holds the full value.
  Excerpt
}

/// One inter-agent message projected from a current run.
pub type Item {
  Item(
    /// The durable assistant entry which carries this invocation.
    entry_id: String,
    /// The provider call identity joined to its result.
    call_id: String,
    /// The strand which owns the exact `agent_send` invocation.
    source: String,
    /// The recipient captured in the invocation arguments.
    target: String,
    /// At most 4096 characters of the sanitized message body.
    body: String,
    /// Whether `body` contains the complete captured input.
    body_extent: BodyExtent,
    /// The durable sequence of the invocation entry.
    seq: Int,
    /// The matching result state, or `SendPending` when absent.
    state: State,
  )
}

type Candidate {
  Candidate(
    entry_id: String,
    call_id: String,
    source: String,
    target: String,
    body: String,
    body_extent: BodyExtent,
    seq: Int,
    state: State,
  )
}

/// Projects at most the latest twenty current-run sends in descending order.
///
/// Results join only within the same strand and call ID. A successful result
/// whose details do not identify `steered` or `started` remains `Accepted`;
/// this names receipt and does not claim that the recipient read the body.
///
/// ## Examples
///
/// ```gleam
/// // agent_messages.observe(view, window, "main")
/// ```
///
@internal
pub fn observe(
  view: snapshot_view.View,
  window: snapshot.Window,
  selected: String,
) -> List(Item) {
  for_strand(project(view, window), selected)
}

/// Retains verified sends across captures, including after operation metadata
/// has been deleted. Current records refresh the exact item by entry and call
/// identity; older verified items remain until the twenty item bound evicts.
///
/// ## Examples
///
/// ```gleam
/// // agent_messages.capture(previous, view, window)
/// ```
@internal
pub fn capture(
  previous: List(Item),
  view: snapshot_view.View,
  window: snapshot.Window,
) -> List(Item) {
  let fresh =
    project(view, window)
    |> list.map(fn(item) {
      case list.find(previous, fn(old) { item_key(old) == item_key(item) }) {
        Ok(old) if item.state == SendPending -> Item(..item, state: old.state)
        _ -> item
      }
    })
  let fresh_keys = list.map(fresh, item_key)
  let retained =
    list.filter(previous, fn(item) {
      !list.contains(fresh_keys, item_key(item))
    })
    |> list.map(fn(item) {
      let records = snapshot_view.branch(view, window, item.source).records

      // A retained receipt can be refreshed only while its invocation is
      // still in this connected branch. Otherwise a missing reused-ID call
      // could make an unrelated later result look like this send's receipt.
      let invocation_present =
        list.any(records, fn(record) {
          ids.entry_id_to_string(record.entry.id) == item.entry_id
        })
      case invocation_present {
        False -> item
        True ->
          case outcome_state(records, item.source, item.call_id, item.seq) {
            SendPending -> item
            state -> Item(..item, state:)
          }
      }
    })
  list.append(fresh, retained)
  |> list.sort(fn(a, b) { int.compare(b.seq, a.seq) })
  |> list.take(20)
}

/// Filters a captured cache by either endpoint of the selected strand.
///
/// ## Examples
///
/// ```gleam
/// // agent_messages.for_strand(items, "sub:worker")
/// ```
@internal
pub fn for_strand(items: List(Item), selected: String) -> List(Item) {
  items
  |> list.filter(fn(item) { item.source == selected || item.target == selected })
  |> list.sort(fn(a, b) { int.compare(b.seq, a.seq) })
}

fn project(view: snapshot_view.View, window: snapshot.Window) -> List(Item) {
  view.strands
  |> list.flat_map(fn(strand) { current(view, window, strand.id) })
  |> deduplicate_candidates([])
  |> list.sort(fn(a, b) { int.compare(b.seq, a.seq) })
  |> list.take(20)
  |> list.map(to_item)
}

fn current(
  view: snapshot_view.View,
  window: snapshot.Window,
  strand: String,
) -> List(Candidate) {
  result.unwrap(current_result(view, window, strand), [])
}

fn current_result(
  view: snapshot_view.View,
  window: snapshot.Window,
  strand: String,
) -> Result(List(Candidate), Nil) {
  use operation_id <- result.try(dict.get(view.operations, strand))
  use meta_cell <- result.try(
    list.find(view.cells, fn(cell) {
      cell.namespace == register.OpMeta && cell.key == operation_id
    }),
  )
  use meta <- result.try(
    codec.decode_operation(meta_cell.value) |> result.replace_error(Nil),
  )
  let prompts = case meta.intent {
    operation.RunIntent(prompts) -> prompts
    _ -> []
  }
  case prompts {
    [] -> Ok([])
    _ -> {
      let branch = snapshot_view.branch(view, window, strand)
      let entries = branch.records
      use start <- result.try(earliest_prompt(entries, prompts))
      let suffix = list.filter(entries, fn(record) { record.entry.seq > start })
      let sends =
        suffix
        |> list.flat_map(fn(record) { invocation(record, strand) })
      Ok(
        list.map(sends, fn(candidate) {
          Candidate(
            ..candidate,
            state: outcome_state(
              suffix,
              strand,
              candidate.call_id,
              candidate.seq,
            ),
          )
        }),
      )
    }
  }
}

fn earliest_prompt(
  entries: List(protocol.EntryRecord),
  prompts: List(EntryId),
) -> Result(Int, Nil) {
  entries
  |> list.filter_map(fn(record) {
    case list.contains(prompts, record.entry.id) {
      True -> Ok(record.entry.seq)
      False -> Error(Nil)
    }
  })
  |> list.sort(int.compare)
  |> list.first
}

fn invocation(record: protocol.EntryRecord, source: String) -> List(Candidate) {
  case record.entry {
    entry.MessageEntry(
      message: message.AssistantMessage(content:, ..),
      seq: seq,
      ..,
    ) ->
      content
      |> list.filter_map(fn(block) {
        case block {
          message.AssistantToolCall(call) -> parse_call(call, source, seq)
          message.AssistantText(..) | message.AssistantThinking(..) ->
            Error(Nil)
        }
      })
      |> list.map(fn(candidate) {
        Candidate(
          ..candidate,
          entry_id: ids.entry_id_to_string(record.entry.id),
        )
      })
    _ -> []
  }
}

fn parse_call(
  call: message.ToolCall,
  source: String,
  seq: Int,
) -> Result(Candidate, Nil) {
  case call.name, call.arguments {
    "agent_send", json.Object(fields) -> {
      use target <- result.try(string_field(fields, "to"))
      use body <- result.try(string_field(fields, "message"))
      let #(body, body_extent) = bound_body(text_hygiene.multiline(body))
      Ok(Candidate(
        entry_id: "",
        source:,
        target:,
        body:,
        body_extent:,
        seq:,
        call_id: call.id,
        state: SendPending,
      ))
    }
    _, _ -> Error(Nil)
  }
}

fn outcome_state(
  records: List(protocol.EntryRecord),
  source: String,
  call_id: String,
  after: Int,
) -> State {
  // Provider call IDs may be reused on later turns. The first subsequent
  // matching invocation closes this occurrence's result interval.
  let next =
    records
    |> list.filter(fn(record) { record.entry.seq > after })
    |> list.filter(fn(record) {
      case record.entry {
        entry.MessageEntry(message: message.AssistantMessage(content:, ..), ..) ->
          list.any(content, fn(block) {
            case block {
              message.AssistantToolCall(call) -> call.id == call_id
              _ -> False
            }
          })
        _ -> False
      }
    })
    |> list.map(fn(record) { record.entry.seq })
    |> list.sort(int.compare)
    |> list.first
    |> result.unwrap(0)
  let records =
    list.filter(records, fn(record) {
      record.entry.seq > after && { next == 0 || record.entry.seq < next }
    })
  case
    list.find_map(records, fn(record) {
      case record.strand == source, record.entry {
        True,
          entry.MessageEntry(
            message: message.ToolResultMessage(
              tool_name: "agent_send",
              tool_call_id: id,
              is_error: failed,
              details: details,
              ..,
            ),
            ..,
          )
          if id == call_id
        ->
          Ok(case failed {
            True -> SendFailed
            False -> result_state(details)
          })
        _, _ -> Error(Nil)
      }
    })
  {
    Ok(state) -> state
    Error(Nil) -> SendPending
  }
}

fn result_state(details: Option(json.JsonValue)) -> State {
  case details {
    Some(json.Object(fields)) ->
      case string_field(fields, "delivery") {
        Ok("started") -> Started
        _ -> Accepted
      }
    _ -> Accepted
  }
}

fn string_field(
  fields: List(#(String, json.JsonValue)),
  name: String,
) -> Result(String, Nil) {
  case list.key_find(fields, name) {
    Ok(json.String(value)) if value != "" -> Ok(value)
    _ -> Error(Nil)
  }
}

fn deduplicate_candidates(
  candidates: List(Candidate),
  seen: List(String),
) -> List(Candidate) {
  case candidates {
    [] -> []
    [first, ..rest] -> {
      let key = first.entry_id <> "\u{0}" <> first.call_id
      case list.contains(seen, key) {
        True -> deduplicate_candidates(rest, seen)
        False -> [first, ..deduplicate_candidates(rest, [key, ..seen])]
      }
    }
  }
}

fn to_item(candidate: Candidate) -> Item {
  Item(
    entry_id: candidate.entry_id,
    call_id: candidate.call_id,
    source: candidate.source,
    target: candidate.target,
    body: candidate.body,
    body_extent: candidate.body_extent,
    seq: candidate.seq,
    state: candidate.state,
  )
}

fn item_key(item: Item) -> String {
  item.entry_id <> "\u{0}" <> item.call_id
}

fn bound_body(body: String) -> #(String, BodyExtent) {
  case string.drop_start(body, 4096) {
    "" -> #(body, Complete)
    _ -> #(string.slice(body, 0, 4096) <> "…", Excerpt)
  }
}
