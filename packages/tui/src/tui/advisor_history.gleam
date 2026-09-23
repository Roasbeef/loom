//// The main transcript can show the advisor's own settled commentary.
////
//// The advisor's branch may inherit primary entries at its fork. This pure
//// projection walks the captured ancestry of both strands and keeps only
//// advisor assistant text outside the known primary ancestry. It does not
//// turn a requested verdict into a claim that the primary received it: the
//// tool result and the delivery guard own that fact. The bounded snapshot
//// window can omit older ancestors, so its missing edge stays visible.

import core/entry
import core/ids
import core/json
import core/message
import gleam/list
import gleam/option.{type Option}
import tui/snapshot
import tui/snapshot_view

/// One verdict requested by the advisor in the same settled response.
///
/// The tool result may later report a downgrade or a duplicate, so these
/// labels describe the request only. An ambiguous or malformed call has no
/// annotation.
pub type Annotation {
  /// No single valid `advise` request was captured with this text.
  AdvisorUpdate

  /// The advisor requested no delivery.
  RequestedQuiet

  /// The advisor requested a deferred nudge.
  RequestedNudge

  /// The advisor requested an immediate block.
  RequestedBlock

  /// The advisor requested another goal run.
  RequestedContinue

  /// The advisor requested goal completion.
  RequestedComplete
}

/// One complete assistant text block in a settled advisor entry.
pub type Item {
  Item(
    /// Durable entry identity, stable across snapshot replacement.
    entry_id: String,
    /// Durable sequence for ordering alongside primary transcript rows.
    seq: Int,
    /// Text block's position within that assistant response.
    block_index: Int,
    /// Full captured text, never an excerpt of its first line.
    text: String,
    /// A request inferred only from the same captured assistant response.
    annotation: Annotation,
  )
}

/// Advisor commentary in the current bounded capture.
pub type Board {
  Board(
    /// Oldest-first text blocks from the loaded advisor suffix.
    items: List(Item),
    /// The exact older parent missing from the captured advisor branch.
    unloaded: Option(String),
  )
}

/// Projects settled advisor commentary into the main transcript.
///
/// Only loaded advisor ancestry is considered. A record also found in the
/// captured primary ancestry is inherited and is not repeated here. If an
/// older parent is missing, `unloaded` explains why this is not the complete
/// advisor history.
///
/// ## Examples
///
/// ```gleam
/// // advisor_history.project(view, window)
/// ```
pub fn project(view: snapshot_view.View, window: snapshot.Window) -> Board {
  let advisor = snapshot_view.branch(view, window, "advisor")
  let primary = snapshot_view.branch(view, window, "main")
  let primary_ids = list.map(primary.records, fn(record) { record.entry.id })

  let items =
    advisor.records
    |> list.reverse
    |> list.filter(fn(record) { !list.contains(primary_ids, record.entry.id) })
    |> list.flat_map(fn(record) { text_blocks(record.entry) })

  Board(items, advisor.unloaded)
}

fn text_blocks(value: entry.Entry) -> List(Item) {
  case value {
    entry.MessageEntry(
      id:,
      seq:,
      message: message.AssistantMessage(content:, ..),
      ..,
    ) -> {
      let annotation = annotation(content)
      list.index_map(content, fn(block, index) {
        case block {
          message.AssistantText(text:, ..) -> [
            Item(ids.entry_id_to_string(id), seq, index, text, annotation),
          ]
          message.AssistantThinking(..) | message.AssistantToolCall(..) -> []
        }
      })
      |> list.flatten
    }
    entry.MessageEntry(..)
    | entry.CompactionEntry(..)
    | entry.BranchSummaryEntry(..)
    | entry.CustomEntry(..) -> []
  }
}

// A tool call records the requested verdict. The host may reject, drop or
// downgrade it, and that later result cannot be inferred from this entry.
fn annotation(content: List(message.AssistantBlock)) -> Annotation {
  let requests =
    list.filter_map(content, fn(block) {
      case block {
        message.AssistantToolCall(call) if call.name == "advise" ->
          Ok(call.arguments)
        message.AssistantText(..)
        | message.AssistantThinking(..)
        | message.AssistantToolCall(..) -> Error(Nil)
      }
    })
  case requests {
    [arguments] -> request(arguments)
    [] | [_, _, ..] -> AdvisorUpdate
  }
}

fn request(arguments: json.JsonValue) -> Annotation {
  case arguments {
    json.Object(fields) -> {
      let verdicts = list.filter(fields, fn(pair) { pair.0 == "verdict" })
      let texts = list.filter(fields, fn(pair) { pair.0 == "text" })
      case verdicts, texts {
        [#(_, json.String("quiet"))], []
        | [#(_, json.String("quiet"))], [#(_, json.String(""))]
        -> RequestedQuiet
        [#(_, json.String("nudge"))], [#(_, json.String(text))] if text != "" ->
          RequestedNudge
        [#(_, json.String("block"))], [#(_, json.String(text))] if text != "" ->
          RequestedBlock
        [#(_, json.String("continue"))], [#(_, json.String(text))]
          if text != ""
        -> RequestedContinue
        [#(_, json.String("complete"))], [#(_, json.String(text))]
          if text != ""
        -> RequestedComplete
        _, _ -> AdvisorUpdate
      }
    }
    json.Array(..)
    | json.String(..)
    | json.Int(..)
    | json.Float(..)
    | json.Bool(..)
    | json.Null -> AdvisorUpdate
  }
}
