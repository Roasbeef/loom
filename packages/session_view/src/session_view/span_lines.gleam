//// The records of one timeline span, as the lines a reader scans
//// (`docs/design-notes/session-timeline.md`, section 6, "Open in transcript").
////
//// A card says what a span was about. A reader who wants to know more asks for
//// the span's records, and wants them as a short list in the order they
//// happened, not as the transcript's full rows: a person's words, the agent's
//// words, one line for each tool call and how it ended, and a compaction. This
//// module turns the records of a span, oldest first, into that list. The steps
//// are worded by `step_words`, so a line reads as the session's own page words
//// the same call, and the module performs no I/O.
////
//// ## Flow
////
//// `of_records` → `said` / `step` → `bounded`
////
//// 1. `of_records` reads the records once for the lines each says by itself and
////    once, through `tool_activity.calls`, for the tool calls joined to their
////    results.
//// 2. `bounded` keeps the newest hundred lines in order and counts the rest, so a
////    long span is a bounded list with an honest count of what was left out.
////
//// ## What a line claims
////
//// A step's outcome is what its result envelope reported and says nothing of what
//// the command meant. Every line's words are session text: an agent, a tool or a
//// person wrote them, so a host draws them as text nodes and never as markup, an
//// attribute or a key. The module is portable: it imports `core`, other
//// `session_view` modules and the standard library, and holds no `@external`.

import core/entry.{type Entry}

import core/message
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/string
import session_view/step_words
import session_view/timeline
import session_view/tool_activity

/// The most lines one span answers with.
pub const max_lines = 100

/// The most bytes of the words of one line.
pub const words_bytes = 200

/// What a line is.
pub type Kind {
  /// A message a person sent.
  Prompted

  /// What the agent said.
  Said

  /// A tool call.
  Step

  /// A compaction.
  Compacted
}

/// How a step stands.
pub type Outcome {
  /// The line is not a step.
  NoOutcome

  /// The call has no result in the span.
  Running

  /// The call's result reported success. It says nothing of what the command
  /// meant.
  Succeeded

  /// The call's result reported a failure.
  Failed
}

/// One line of a span.
pub type Line {
  Line(
    /// The sequence of the record the line is about.
    seq: Int,
    /// Unix milliseconds of that record.
    at: Int,
    kind: Kind,
    /// The line's words, session text, at most `words_bytes`.
    words: String,
    outcome: Outcome,
  )
}

/// The lines of a span's records, oldest first, at most `max_lines` of them, and
/// how many were left out. The records are the span's own, oldest first.
///
/// ## Examples
///
/// ```gleam
/// assert span_lines.of_records([]) == #([], 0)
/// ```
pub fn of_records(records: List(Entry)) -> #(List(Line), Int) {
  let sequences =
    dict.from_list(list.map(records, fn(each) { #(each.id, each) }))
  let steps =
    list.filter_map(tool_activity.calls(records), fn(call) {
      // A call is placed where the response that asked for it was written.
      case dict.get(sequences, call.source) {
        Ok(record) -> Ok(step(record, call))
        Error(Nil) -> Error(Nil)
      }
    })
  let spoken = list.flat_map(records, said)

  bounded(
    list.sort(list.append(spoken, steps), fn(left, right) {
      case left.seq == right.seq {
        True -> kind_order(left.kind, right.kind)
        False -> compare_ints(left.seq, right.seq)
      }
    }),
  )
}

/// Keeps the newest `max_lines` lines in order and counts the rest.
fn bounded(lines: List(Line)) -> #(List(Line), Int) {
  let left_out = list.length(lines) - max_lines

  // Only a list over the bound loses its oldest lines.
  case left_out > 0 {
    True -> #(list.drop(lines, left_out), left_out)
    False -> #(lines, 0)
  }
}

/// The lines a record says by itself: a person's words, the agent's words, a
/// compaction. A tool call and its result are the steps' business.
fn said(record: Entry) -> List(Line) {
  // Only a message with words, or a compaction, says something alone.
  case record {
    entry.MessageEntry(
      message: message.UserMessage(content:, origin:, ..) as sent,
      seq:,
      ts:,
      ..,
    ) ->
      case origin, timeline.harness_written(sent) {
        Some(message.PeerOrigin(..)), _
        | Some(message.StrandOrigin(..)), _
        | _, True
        -> []
        None, False
        | Some(message.Origin(..)), False
        | Some(message.TriggerOrigin(..)), False
        -> words_line(seq, ts, Prompted, user_text(content))
      }
    entry.MessageEntry(
      message: message.AssistantMessage(content:, ..),
      seq:,
      ts:,
      ..,
    ) -> words_line(seq, ts, Said, assistant_text(content))
    entry.CompactionEntry(seq:, ts:, ..) -> [
      Line(seq, ts, Compacted, "Context compacted", NoOutcome),
    ]
    entry.MessageEntry(..)
    | entry.BranchSummaryEntry(..)
    | entry.CustomEntry(..) -> []
  }
}

/// A line of the first words of some text, or none for text with no words.
fn words_line(seq: Int, at: Int, kind: Kind, text: String) -> List(Line) {
  // Text with no words makes no line.
  case string.trim(text) {
    "" -> []
    words -> [Line(seq, at, kind, first_line(words), NoOutcome)]
  }
}

/// One tool call as a line, worded as the session's own page words it.
fn step(record: Entry, call: tool_activity.Call) -> Line {
  let words = step_words.of_call(call)

  // A result envelope says how a call ended, and no result means it is running.
  let outcome = case call.outcome {
    None -> Running
    Some(message.ToolResultMessage(is_error: False, ..)) -> Succeeded
    Some(message.ToolResultMessage(is_error: True, ..)) -> Failed
    Some(_) -> Running
  }

  // A call with no result is worded in the present tense, since the past tense
  // would claim an outcome it has not reached.
  let spoken = case outcome {
    Running -> step_words.pending(words)
    Succeeded | Failed | NoOutcome -> words
  }

  Line(record.seq, record.ts, Step, clip(step_words.text(spoken)), outcome)
}

/// The text blocks of a user message, joined.
fn user_text(content: List(message.UserBlock)) -> String {
  list.filter_map(content, fn(block) {
    case block {
      message.UserText(text:, ..) -> Ok(text)
      message.UserImage(..) -> Error(Nil)
    }
  })
  |> string.join("\n")
}

/// The text blocks of an assistant message, joined.
fn assistant_text(content: List(message.AssistantBlock)) -> String {
  list.filter_map(content, fn(block) {
    case block {
      message.AssistantText(text:, ..) -> Ok(text)
      message.AssistantThinking(..) | message.AssistantToolCall(..) ->
        Error(Nil)
    }
  })
  |> string.join("\n")
}

/// The first line of some text, clipped.
fn first_line(text: String) -> String {
  // The first line is the line's words.
  case string.split(text, "\n") {
    [first, ..] -> clip(string.trim(first))
    [] -> ""
  }
}

/// Words cut to `words_bytes` at a character boundary, marked when cut.
fn clip(words: String) -> String {
  // Words within the bound are kept whole.
  case string.byte_size(words) > words_bytes {
    True -> take(string.to_graphemes(words), words_bytes - 3, "") <> "…"
    False -> words
  }
}

/// The characters of a list that fit in a byte budget, in order.
fn take(graphemes: List(String), budget: Int, kept: String) -> String {
  // Characters are taken until the next would not fit.
  case graphemes {
    [next, ..rest] ->
      case string.byte_size(next) <= budget {
        True -> take(rest, budget - string.byte_size(next), kept <> next)
        False -> kept
      }
    [] -> kept
  }
}

/// Orders two lines of one record: the words before the calls that follow them.
fn kind_order(left: Kind, right: Kind) -> order.Order {
  compare_ints(kind_rank(left), kind_rank(right))
}

/// The place of a kind among the lines of one record.
fn kind_rank(kind: Kind) -> Int {
  // A person speaks first, then the agent's words, then its calls.
  case kind {
    Prompted -> 0
    Compacted -> 1
    Said -> 2
    Step -> 3
  }
}

fn compare_ints(left: Int, right: Int) -> order.Order {
  int.compare(left, right)
}
