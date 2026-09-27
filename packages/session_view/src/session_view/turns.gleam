//// One strand's transcript as turns: each input, the work that answered
//// it folded under one divider, and the rows that stay outside the fold.
////
//// The terminal draws a strand's durable records as rows. A host with more
//// room (the web view) draws the same records as a reading lane: what a
//// person asked, the answer, and between them one divider for everything the
//// strand did to get there (`▸ worked 48s · 4 steps · 2 files`). What counts
//// as an input, what counts as work, and which rows must never be folded
//// away are decisions about what a record means, so they are made here and
//// not in the host. The host only lays the pieces out.
////
//// The pieces are built from `transcript_lines.keyed_record_blocks`, and
//// every row a piece draws comes from the transcript's own row builders.
//// Every tool call is drawn as one step joined to its result, whether the
//// terminal drew it in a compact group or inline in a response that
//// reasoned first, because two kinds of call leave the fold: an
//// `agent_spawn` becomes a spawn row naming the child, and a ready result
//// an `agent_wait` returned becomes a result card. So do
//// a delivered advisor nudge, a message from another session and a cache
//// miss, since each is something another party did or something the reader
//// may need to act on.
////
//// A turn still running is never folded, and neither is one whose strand
//// waits on an approval: the reader must be able to see the step that is
//// asking. The duration and counts a divider shows come from the records
//// (the input's and the last step's own timestamps), never from a clock.

import core/entry
import core/json
import core/message
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import session_view/agent_view
import session_view/composer
import session_view/protocol
import session_view/snapshot_view
import session_view/tool_activity
import session_view/transcript_line.{type Line}
import session_view/transcript_lines.{type Block}

/// How many strand hues there are for sub-agents before they repeat.
pub const hues = 5

/// A strand's colour, from its position among the captured strands: never
/// from its name, which the session writes.
pub type Hue {
  /// The primary strand.
  Primary

  /// The advisor.
  Advisor

  /// A sub-agent, by its position among the other strands, modulo `hues`.
  Sub(index: Int)

  /// A strand the capture does not list.
  Unplaced
}

/// Whether the last turn of a strand may be folded.
pub type Latest {
  /// The strand is running an operation or waits on an approval, so its
  /// last turn stays open.
  Running

  /// Nothing is running; every turn may fold.
  Settled
}

/// Whether a turn's work is folded under its divider or drawn open.
pub type Folding {
  /// A settled turn: collapsed under the divider until the reader opens it.
  Folded

  /// The running turn: drawn open, with no divider to collapse it.
  Open
}

/// How a tool call stands.
pub type Standing {
  /// No result yet.
  Pending

  /// The tool returned a result.
  Done

  /// The tool returned an error.
  Failed
}

/// Which advisor frame was delivered.
pub type Frame {
  /// A verdict from a review.
  Advice

  /// Queued nudges.
  Nudges
}

/// What one turn's divider says.
pub type Worked {
  Worked(
    /// Milliseconds from the input's record to the last record of the turn,
    /// when both carry a time.
    duration_ms: Option(Int),
    /// How many tool calls the work holds.
    steps: Int,
    /// How many distinct files the work wrote or edited.
    files: Int,
  )
}

/// One thing folded under a divider.
pub type Item {
  /// A block drawn as its rows: reasoning, an intermediate message, a
  /// result whose call is outside the window.
  Narrated(block: Block)

  /// One tool call.
  Step(
    /// The call's key: its group's block key and its index in the group.
    key: String,
    /// How the call stands.
    standing: Standing,
    /// The call's one-line summary (`transcript_lines.call_summary`).
    summary: String,
    /// The rows under the summary: its result, patch or program.
    detail: List(Line),
  )
}

/// One piece of a strand's reading lane, in lane order.
pub type Piece {
  /// A block drawn as its rows: an input, an answer, harness speech.
  Plain(block: Block)

  /// The work of one turn, behind one divider.
  Work(key: String, worked: Worked, items: List(Item), folding: Folding)

  /// An `agent_spawn` call: the child it started, once its result names one,
  /// and the purpose it was started for.
  Spawned(
    key: String,
    child: Option(String),
    purpose: String,
    hue: Hue,
    standing: Standing,
  )

  /// A child's result, as an `agent_wait` returned it.
  Returned(
    key: String,
    child: String,
    outcome: String,
    report: String,
    hue: Hue,
  )

  /// A delivered advisor frame, with its opening line and its whole body.
  /// It opens a turn of its own: what the strand does next answers the
  /// advisor, not the person before it.
  Nudged(key: String, frame: Frame, preview: String, body: String)

  /// The advisor's commentary board on the primary's lane: what the
  /// advisor said on its own strand, captured and not sent to the primary.
  Commentary(block: Block)

  /// A message another session's strand sent to this one. The daemon only
  /// knows it was stored, never that it was read.
  Peer(key: String, session: String, strand: String, text: String)

  /// A cache miss this client noticed after the turn that paid for it.
  Missed(key: String, text: String)
}

/// A strand's hue from its position among the captured strands.
///
/// ## Examples
///
/// ```gleam
/// assert turns.hue([], "main") == turns.Primary
/// ```
pub fn hue(strands: List(protocol.Strand), id: String) -> Hue {
  case id {
    "main" -> Primary
    "advisor" -> Advisor
    _ ->
      strands
      |> list.filter(fn(strand) {
        strand.id != "main" && strand.id != "advisor"
      })
      |> list.index_fold(Unplaced, fn(found, strand, index) {
        case strand.id == id, found {
          True, Unplaced -> Sub(index % hues)
          _, _ -> found
        }
      })
  }
}

/// Whether a strand's last turn may fold: not while the strand runs an
/// operation, and not while its agent row says it waits on an approval.
///
/// ## Examples
///
/// ```gleam
/// // turns.latest(view, rows, "main") == turns.Settled
/// ```
pub fn latest(
  view: snapshot_view.View,
  rows: List(agent_view.Row),
  strand: String,
) -> Latest {
  let waiting =
    list.any(rows, fn(row) {
      row.id == strand && row.status == agent_view.NeedsInput
    })
  case dict.has_key(view.operations, strand) || waiting {
    True -> Running
    False -> Settled
  }
}

/// The pieces of one strand's lane, in order.
///
/// ## Examples
///
/// ```gleam
/// assert turns.pieces([], [], turns.Settled) == []
/// ```
pub fn pieces(
  blocks: List(Block),
  strands: List(protocol.Strand),
  latest: Latest,
) -> List(Piece) {
  let joined = joined(blocks)
  let classified = list.flat_map(blocks, classify(_, strands, joined))
  let turns = split(classified)
  let count = list.length(turns)
  turns
  |> list.index_map(fn(turn, index) {
    let folding = case index == count - 1, latest {
      True, Running -> Open
      _, _ -> Folded
    }
    lay_out(turn, folding)
  })
  |> list.flatten
}

// What one block, or one call of a tool group, is to a turn.
type Classified {
  // Starts a turn: a person's message, another session's, a delivered
  // advisor frame, or a goal continuation the harness wrote. Each starts a
  // run the strand then answers, so each is where a turn begins.
  Input(piece: Piece, at: Option(Int))

  // A message with the strand's own prose, a candidate for the answer.
  Answer(block: Block, at: Option(Int))

  // Something folded under the divider, with the tool calls it made and
  // the paths those calls wrote.
  Doing(item: Item, at: Option(Int), steps: Int, wrote: List(String))

  // Something drawn where it stands, outside any fold.
  Outside(piece: Piece)
}

// The calls the narrative messages in the lane made and the results that
// answered them, each by the provider's call identity.
//
// A response that reasons before it calls a tool is a narrative, drawn with
// its calls inline, and each result arrives as an entry of its own. The
// lane draws such a call as one step, the way a compact tool group draws
// its calls, so the call and its result are joined here; a result whose
// call is in the window is drawn with that call and not again.
type Joined {
  Joined(
    asked: dict.Dict(String, message.ToolCall),
    results: dict.Dict(String, message.AgentMessage),
  )
}

fn joined(blocks: List(Block)) -> Joined {
  list.fold(blocks, Joined(dict.new(), dict.new()), fn(joined, block) {
    case block.source {
      transcript_lines.FromEntry(entry.MessageEntry(
        message: message.AssistantMessage(content:, ..),
        ..,
      )) ->
        Joined(
          ..joined,
          asked: list.fold(content, joined.asked, fn(asked, part) {
            case part {
              message.AssistantToolCall(call) ->
                dict.insert(asked, call.id, call)
              message.AssistantText(..) | message.AssistantThinking(..) -> asked
            }
          }),
        )
      transcript_lines.FromEntry(entry.MessageEntry(
        message: message.ToolResultMessage(tool_call_id:, ..) as outcome,
        ..,
      )) ->
        Joined(
          ..joined,
          results: dict.insert(joined.results, tool_call_id, outcome),
        )
      _ -> joined
    }
  })
}

fn classify(
  block: Block,
  strands: List(protocol.Strand),
  joined: Joined,
) -> List(Classified) {
  case block.source {
    transcript_lines.FromSpacer -> []
    transcript_lines.FromNotice -> [
      Outside(Missed(block.key, first_text(block))),
    ]
    transcript_lines.FromAdvisor -> [Outside(Commentary(block))]
    transcript_lines.FromTools(calls) ->
      calls
      |> list.index_map(fn(call, index) {
        called(block.key <> "/" <> int.to_string(index), call, strands)
      })
      |> list.flatten
    transcript_lines.FromEntry(value) ->
      entry_kind(block, value, strands, joined)
  }
}

fn entry_kind(
  block: Block,
  value: entry.Entry,
  strands: List(protocol.Strand),
  joined: Joined,
) -> List(Classified) {
  let at = Some(value.ts)
  case block.rows, value {
    // A block that draws nothing (a run's injected notes) is nothing here
    // either.
    [], _ -> []

    _,
      entry.MessageEntry(
        message: message.UserMessage(content:, origin:, ..) as sent,
        ..,
      )
    ->
      case transcript_lines.advisor_payload(sent), origin {
        Some(transcript_lines.Advice(body:)), _ -> [
          Input(nudged(block, Advice, body), at),
        ]
        Some(transcript_lines.Nudges(body:)), _ -> [
          Input(nudged(block, Nudges, body), at),
        ]
        Some(transcript_lines.Feed(..)), _
        | Some(transcript_lines.GoalFeed(..)), _
        -> [Outside(Plain(block))]
        Some(transcript_lines.Continuation(..)), _ -> [Input(Plain(block), at)]
        None, Some(message.PeerOrigin(session:, strand:)) -> [
          Input(
            Peer(
              block.key,
              session,
              strand,
              composer.transcript_text(
                transcript_lines.user_body(content),
                False,
              ),
            ),
            at,
          ),
        ]
        None, Some(message.Origin(..)) | None, None -> [Input(Plain(block), at)]
      }

    // A response is drawn as its prose, and each of its calls as a step
    // joined to its result, or as a spawn row. The prose is the answer when
    // it holds text of the strand's own; otherwise it is work.
    _,
      entry.MessageEntry(
        id: source,
        message: message.AssistantMessage(
          content:,
          stop_reason:,
          error_message:,
          ..,
        ),
        ..,
      )
    -> {
      let prose = prose(block, content, stop_reason, error_message)
      let own =
        content
        |> list.filter_map(fn(part) {
          case part {
            message.AssistantToolCall(call) -> Ok(call)
            message.AssistantText(..) | message.AssistantThinking(..) ->
              Error(Nil)
          }
        })
        |> list.index_map(fn(call, index) {
          let key = block.key <> "/" <> int.to_string(index)
          let outcome = dict.get(joined.results, call.id) |> option.from_result
          called(key, tool_activity.Call(source, call, outcome, None), strands)
        })
        |> list.flatten
      case list.any(content, speaks), prose.rows {
        True, _ -> [Answer(prose, at), ..own]
        False, [] -> own
        False, [_, ..] -> [Doing(Narrated(prose), at, 0, []), ..own]
      }
    }

    // A result is drawn with its call when the window holds the call; a
    // wait's ready results still become cards where they arrived. A result
    // whose call is outside the window is drawn as it is.
    _,
      entry.MessageEntry(
        message: message.ToolResultMessage(
          tool_call_id:,
          tool_name:,
          details:,
          is_error:,
          ..,
        ),
        ..,
      )
    -> {
      let outcome = case is_error {
        True -> Failed
        False -> Done
      }
      let details = case is_error {
        True -> None
        False -> details
      }
      case dict.has_key(joined.asked, tool_call_id), tool_name {
        True, "agent_wait" -> returned(block.key, details, strands)
        True, _ -> []
        False, "agent_spawn" -> [
          Outside(spawned(block.key, None, details, outcome, strands)),
        ]
        False, "agent_wait" -> [
          Doing(Narrated(block), at, 0, []),
          ..returned(block.key, details, strands)
        ]
        False, _ -> [Doing(Narrated(block), at, 0, [])]
      }
    }

    _, entry.MessageEntry(message: message.CustomMessage(..), ..)
    | _, entry.CompactionEntry(..)
    | _, entry.BranchSummaryEntry(..)
    | _, entry.CustomEntry(..)
    -> [Outside(Plain(block))]
  }
}

// A response's own words, without its calls: its text and reasoning, drawn
// by the transcript's own row builders, and the line its stop left when it
// did not end cleanly. The calls are drawn as steps instead.
fn prose(
  block: Block,
  content: List(message.AssistantBlock),
  stop_reason: message.StopReason,
  error_message: Option(String),
) -> Block {
  let lines =
    content
    |> list.flat_map(fn(part) {
      case part {
        message.AssistantToolCall(..) -> []

        // The digest keeps the transcript's rule for which line opens a
        // block, without the terminal's key hint: the lane's reader opens
        // reasoning with the fold, not a key.
        message.AssistantThinking(thinking:, redacted: False, ..) -> [
          transcript_line.Line(
            transcript_line.ReasoningDigest,
            transcript_lines.reasoning_opening(thinking),
          ),
        ]
        message.AssistantText(..) | message.AssistantThinking(..) ->
          transcript_lines.assistant_block_lines(part, False, None)
      }
    })
    |> list.append(transcript_lines.assistant_terminal_lines(
      stop_reason,
      error_message,
    ))
  transcript_lines.Block(
    ..block,
    rows: list.index_map(lines, fn(line, index) {
      #(block.key <> ":" <> int.to_string(index), line)
    }),
  )
}

fn speaks(block: message.AssistantBlock) -> Bool {
  case block {
    message.AssistantText(text:, ..) -> string.trim(text) != ""
    message.AssistantThinking(..) | message.AssistantToolCall(..) -> False
  }
}

// The path a call that writes a file names, which the divider counts.
fn written(call: message.ToolCall) -> Result(String, Nil) {
  case call.name {
    "fs_write" | "fs_edit" ->
      field_text(call.arguments, "path") |> option.to_result(Nil)
    _ -> Error(Nil)
  }
}

fn nudged(block: Block, frame: Frame, body: String) -> Piece {
  Nudged(block.key, frame, transcript_lines.advisor_body_preview(body), body)
}

// A spawn row from the call that asked for the child and the details its
// result returned, either of which the window may not hold.
fn spawned(
  key: String,
  call: Option(message.ToolCall),
  details: Option(json.JsonValue),
  standing: Standing,
  strands: List(protocol.Strand),
) -> Piece {
  let child = option.then(details, field_text(_, "strand"))
  Spawned(
    key,
    child,
    call
      |> option.then(fn(call) { field_text(call.arguments, "purpose") })
      |> option.unwrap(""),
    option.map(child, hue(strands, _)) |> option.unwrap(Unplaced),
    standing,
  )
}

// One call, of a compact tool group or of a narrative response, with its
// result when the window holds one. A spawn leaves the fold as a spawn row;
// a wait stays a step, and each ready result it returned leaves as a result
// card.
fn called(
  key: String,
  call: tool_activity.Call,
  strands: List(protocol.Strand),
) -> List(Classified) {
  let standing = standing(call.outcome)
  let at = case call.outcome {
    Some(message.ToolResultMessage(timestamp:, ..)) -> Some(timestamp)
    _ -> None
  }
  let wrote = written(call.invocation) |> result.map(list.wrap)
  case call.invocation.name {
    "agent_spawn" -> [
      Outside(spawned(
        key,
        Some(call.invocation),
        details(call.outcome),
        standing,
        strands,
      )),
    ]
    "agent_wait" -> [
      Doing(step(key, call, standing), at, 1, []),
      ..returned(key, details(call.outcome), strands)
    ]
    _ -> [Doing(step(key, call, standing), at, 1, result.unwrap(wrote, []))]
  }
}

fn step(key: String, call: tool_activity.Call, standing: Standing) -> Item {
  let detail = case transcript_lines.activity_call_lines(call) {
    [_, ..rest] -> rest
    [] -> []
  }
  Step(key:, standing:, summary: transcript_lines.call_summary(call), detail:)
}

fn standing(outcome: Option(message.AgentMessage)) -> Standing {
  case outcome {
    None -> Pending
    Some(message.ToolResultMessage(is_error: True, ..)) -> Failed
    Some(_) -> Done
  }
}

fn details(outcome: Option(message.AgentMessage)) -> Option(json.JsonValue) {
  case outcome {
    Some(message.ToolResultMessage(details: Some(value), is_error: False, ..)) ->
      Some(value)
    _ -> None
  }
}

// The ready results one wait returned, each a card keyed under the call.
fn returned(
  key: String,
  value: Option(json.JsonValue),
  strands: List(protocol.Strand),
) -> List(Classified) {
  case option.then(value, field(_, "results")) {
    Some(json.Array(results)) ->
      results
      |> list.index_map(fn(result, index) { #(result, index) })
      |> list.filter_map(fn(pair) {
        let #(result, index) = pair
        case field_text(result, "state"), field_text(result, "strand") {
          Some("ready"), Some(child) ->
            Ok(
              Outside(Returned(
                key <> "/" <> int.to_string(index),
                child,
                field_text(result, "outcome") |> option.unwrap("settled"),
                field_text(result, "report") |> option.unwrap(""),
                hue(strands, child),
              )),
            )
          _, _ -> Error(Nil)
        }
      })
    _ -> []
  }
}

fn field(value: json.JsonValue, name: String) -> Option(json.JsonValue) {
  case value {
    json.Object(fields) -> list.key_find(fields, name) |> option.from_result
    _ -> None
  }
}

fn field_text(value: json.JsonValue, name: String) -> Option(String) {
  case field(value, name) {
    Some(json.String(text)) -> Some(text)
    _ -> None
  }
}

fn first_text(block: Block) -> String {
  case block.rows {
    [#(_, line), ..] -> line.text
    [] -> ""
  }
}

// A turn: the input that opened it, if the window holds one, and what
// followed it in lane order.
type Turn {
  Turn(input: Option(Classified), rest: List(Classified))
}

// Splits the lane at every input. What precedes the first input (a window
// that starts mid-turn) is a turn with no input of its own.
fn split(classified: List(Classified)) -> List(Turn) {
  let #(done, current) =
    list.fold(classified, #([], Turn(None, [])), fn(acc, item) {
      let #(done, current) = acc
      case item {
        Input(..) -> #([current, ..done], Turn(Some(item), []))
        Answer(..) | Doing(..) | Outside(..) -> #(
          done,
          Turn(..current, rest: [item, ..current.rest]),
        )
      }
    })
  [current, ..done]
  |> list.reverse
  |> list.filter_map(fn(turn) {
    case turn {
      Turn(None, []) -> Error(Nil)
      Turn(input, rest) -> Ok(Turn(input, list.reverse(rest)))
    }
  })
}

// Lays one turn out. The last message with the strand's own prose is its
// answer and stays in place; every other message, and every step, goes
// under the divider, which stands where the first of them stood. Pieces
// outside the fold keep their order around it.
fn lay_out(turn: Turn, folding: Folding) -> List(Piece) {
  let indexed = list.index_map(turn.rest, fn(item, index) { #(item, index) })
  let answer =
    list.fold(indexed, None, fn(found, pair) {
      let #(item, index) = pair
      case item {
        Answer(..) -> Some(index)
        Input(..) | Doing(..) | Outside(..) -> found
      }
    })

  // Everything that is neither the answer nor drawn outside the fold is
  // work: every step, and every other message the strand wrote on the way.
  let working =
    list.filter_map(indexed, fn(pair) {
      let #(item, index) = pair
      case item {
        Doing(item:, ..) -> Ok(item)
        Answer(block:, ..) if Some(index) != answer -> Ok(Narrated(block))
        Answer(..) | Input(..) | Outside(..) -> Error(Nil)
      }
    })
  let lead = case turn.input {
    Some(Input(piece:, ..)) -> [piece]
    _ -> []
  }
  case working {
    [] -> list.append(lead, list.filter_map(turn.rest, placed))
    [first, ..] -> {
      let divider =
        Work("work:" <> item_key(first), worked(turn), working, folding)
      list.fold(indexed, #([], Undrawn), fn(acc, pair) {
        let #(out, drawn) = acc
        let #(item, index) = pair
        case folded(item, index, answer), drawn {
          Under, Drawn -> #(out, drawn)
          Under, Undrawn -> #([divider, ..out], Drawn)
          Beside, _ ->
            case placed(item) {
              Ok(piece) -> #([piece, ..out], drawn)
              Error(Nil) -> #(out, drawn)
            }
        }
      })
      |> fn(acc) { list.append(lead, list.reverse(acc.0)) }
    }
  }
}

// Whether the divider has been placed yet in a turn being laid out.
type Placing {
  Undrawn
  Drawn
}

// Where one item of a turn goes: under the divider, or beside it.
type Place {
  Under
  Beside
}

fn folded(item: Classified, index: Int, answer: Option(Int)) -> Place {
  case item {
    Doing(..) -> Under
    Answer(..) if Some(index) != answer -> Under
    Answer(..) | Input(..) | Outside(..) -> Beside
  }
}

fn placed(item: Classified) -> Result(Piece, Nil) {
  case item {
    Answer(block:, ..) -> Ok(Plain(block))
    Outside(piece:) -> Ok(piece)
    Input(piece:, ..) -> Ok(piece)
    Doing(..) -> Error(Nil)
  }
}

fn item_key(item: Item) -> String {
  case item {
    Narrated(block:) -> block.key
    Step(key:, ..) -> key
  }
}

// The divider's figures, from the records alone: from the input's time to
// the latest time any record of the turn carries, the calls it made, and
// the distinct paths it wrote.
fn worked(turn: Turn) -> Worked {
  let times =
    list.filter_map(turn.rest, fn(item) {
      case item {
        Doing(at: Some(at), ..) | Answer(at: Some(at), ..) -> Ok(at)
        Doing(at: None, ..) | Answer(at: None, ..) | Input(..) | Outside(..) ->
          Error(Nil)
      }
    })
  let start = case turn.input {
    Some(Input(at:, ..)) -> at
    _ -> list.first(times) |> option.from_result
  }
  let end = list.max(times, int.compare) |> option.from_result
  let duration_ms = case start, end {
    Some(start), Some(end) if end >= start -> Some(end - start)
    _, _ -> None
  }
  let steps =
    list.fold(turn.rest, 0, fn(total, item) {
      case item {
        Doing(steps:, ..) -> total + steps
        Answer(..) | Input(..) | Outside(..) -> total
      }
    })
  let files =
    turn.rest
    |> list.flat_map(fn(item) {
      case item {
        Doing(wrote:, ..) -> wrote
        Answer(..) | Input(..) | Outside(..) -> []
      }
    })
    |> set.from_list
    |> set.size
  Worked(duration_ms:, steps:, files:)
}

/// The divider's words: `worked 48s · 4 steps · 2 files`, leaving out a
/// figure the records did not give.
///
/// ## Examples
///
/// ```gleam
/// assert turns.divider(turns.Worked(Some(48_000), 4, 2))
///   == "worked 48s · 4 steps · 2 files"
/// ```
pub fn divider(worked: Worked) -> String {
  let time = case worked.duration_ms {
    Some(ms) -> "worked " <> span(ms)
    None -> "worked"
  }
  [
    time,
    counted(worked.steps, "step", "steps"),
    counted(worked.files, "file", "files"),
  ]
  |> list.filter(fn(part) { part != "" })
  |> string.join(" · ")
}

fn counted(count: Int, one: String, many: String) -> String {
  case count {
    0 -> ""
    1 -> "1 " <> one
    _ -> int.to_string(count) <> " " <> many
  }
}

// A duration as the divider reads it: seconds under a minute, minutes and
// seconds under an hour, then hours and minutes.
fn span(ms: Int) -> String {
  let seconds = int.max(0, ms) / 1000
  case seconds >= 3600, seconds >= 60 {
    True, _ ->
      int.to_string(seconds / 3600)
      <> "h "
      <> int.to_string(seconds % 3600 / 60)
      <> "m"
    False, True ->
      int.to_string(seconds / 60) <> "m " <> int.to_string(seconds % 60) <> "s"
    False, False -> int.to_string(seconds) <> "s"
  }
}
