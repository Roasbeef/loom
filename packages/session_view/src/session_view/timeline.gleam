//// The timeline cut: one strand's records divided into spans, each a card a
//// reader can scan instead of reading the transcript.
////
//// An owner who comes back to a finished session wants to know what the agent
//// set out to do, what it did and where it stopped, without reading every
//// record. A turn is too coarse for that (one turn can hold hundreds of
//// calls) and a record is too fine. This module cuts the records into spans
//// at points the records themselves show: a prompt, a final answer, a failed
//// command, a command run after files were written, a sub-agent's result, an
//// ask, a compaction, or a step limit. Every fact a card carries comes from
//// records and no model. A later slice adds a model's title beside a card; the
//// card never depends on it (`docs/design-notes/session-timeline.md`).
////
//// ## Prefix-stable
////
//// The cut is a function of the records already seen, and no decision looks
//// ahead. So the cards of any prefix of the records are a prefix of the cards of
//// the whole, apart from the open span at the end. That property is what lets a
//// stored card keep its key (`from_seq`) while the strand grows, and it is the
//// reason there is no per-turn cap that would merge cards after the fact. The
//// one cap, `card_cap`, depends on how many cards have closed so far, which is
//// also a function of the prefix.
////
//// ## Flow
////
//// `cut` → `step` → `prompted` / `assistant` / `result` / `compacted` → `close`
////
//// 1. `cut` folds the oldest-first records of one strand's lineage into a
////    `State` and returns the closed cards and the open span.
//// 2. `step` reads one record. A prompt, an answer and a compaction close the
////    span before them first, and then take the record into a card of their own.
//// 3. `assistant` counts the calls of a response and notes what they will do.
//// 4. `result` joins a result to its call and reads the facts: a file written,
////    a command's exit status, a sub-agent's result.
//// 5. `close` turns the open draft into a `Card` and counts it.
////
//// ## What a card claims
////
//// A command is the executable and its subcommand and nothing else (`reduced`),
//// with the exit status its result recorded. The card does not say the command
//// passed or checked anything. Every string a card holds (a path, a command, a
//// child's name, a prompt's words) is session text, which a host draws as a
//// text node and never as markup, an attribute or a key.
////
//// The module is portable: it imports `core` and other `session_view` modules,
//// holds no `@external` and performs no I/O.

import core/entry.{type Entry}
import core/ids.{type EntryId}
import core/json.{type JsonValue}
import core/message
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import session_view/composer
import session_view/step_words
import session_view/tool_activity
import session_view/transcript_lines

/// The steps after which an open span closes. The owner ruled 40
/// (`docs/design-notes/session-timeline.md`, section 9).
pub const default_step_limit = 40

/// The most cards a strand closes on a command, a sub-agent's result or the step
/// limit. A prompt, an answer, an ask and a compaction are not counted, and past
/// the cap they still close a span, so a very long strand stops producing cards
/// of its own accord while keeping the edges of every turn.
pub const card_cap = 400

/// The fewest steps a span of a command or a result needs to close on it.
/// A span with fewer joins the next one instead, because a card for two calls
/// says less than the calls do.
pub const least_steps = 3

/// The most files one card names; the count of the rest is `files_total`.
pub const named_files = 6

/// The most children one card names.
pub const named_children = 3

/// The most bytes of a prompt or an answer a card keeps.
pub const excerpt_bytes = 160

/// The most bytes of a reduced command a card keeps.
pub const command_bytes = 120

/// The most bytes of a path a card keeps. A longer path keeps its end, which is
/// the part that tells two files apart.
pub const path_bytes = 400

/// The most bytes of a sub-agent's purpose a card keeps.
pub const purpose_bytes = 60

/// What closed a card, which is also what it is about.
pub type Kind {
  /// A message a person (or a trigger) sent. It opens a turn.
  Prompted

  /// Steps that ran up to a limit or to the turn's end with no landmark of
  /// their own.
  Worked

  /// A shell command that failed, or ran after files were written.
  Ran

  /// A sub-agent's result, as an `agent_wait` returned it.
  Reported

  /// The agent asked the owner a question.
  Asked

  /// Context was compacted here.
  Compacted

  /// The strand's reply that ended a turn.
  Answered
}

/// A file a span wrote, with the lines its edits added and removed.
pub type FileFact {
  FileFact(path: String, added: Int, removed: Int)
}

/// A command a span ran, reduced, and the exit status its result recorded.
pub type Command {
  Command(text: String, exit: Int)
}

/// What a span's records say, with no model.
pub type Facts {
  Facts(
    /// Tool calls in the span.
    steps: Int,
    /// Of those, calls that only read.
    reads: Int,
    /// Tool results that reported an error or a nonzero exit.
    failed: Int,
    /// The first `named_files` files written, in order of first write.
    files: List(FileFact),
    /// How many distinct files the span wrote.
    files_total: Int,
    /// The command that closed the span, for a `Command` card.
    command: Option(Command),
    /// Up to `named_children` purposes of the sub-agents the span spawned.
    spawned: List(String),
    /// Messages from other sessions or strands inside the span.
    peers: Int,
    /// The context size a compaction replaced, for a `Compaction` card.
    tokens_before: Option(Int),
    /// The first words of a prompt or an answer.
    excerpt: Option(String),
  )
}

/// One span of a strand's records.
pub type Card {
  Card(
    kind: Kind,
    /// The sequence of the prompt that began the turn this span is in, or 0
    /// when the strand's records begin inside a turn.
    turn_seq: Int,
    /// The sequence of the span's first record. Unique among a strand's cards.
    from_seq: Int,
    /// The sequence of the span's last record.
    to_seq: Int,
    /// The id of the span's last record, from which a scan walks down the span.
    last: EntryId,
    /// Unix milliseconds of the first record.
    started_at: Int,
    /// Unix milliseconds of the last record.
    ended_at: Int,
    facts: Facts,
  )
}

/// The cards of one strand's records.
pub type Cut {
  Cut(
    /// The closed cards, oldest first.
    cards: List(Card),
    /// What has happened since the last card closed, when anything has.
    open: Option(Card),
  )
}

// A span still collecting records. The counters are folded into `Facts` when
// the span closes.
type Draft {
  Draft(
    from_seq: Int,
    started_at: Int,
    last: EntryId,
    last_seq: Int,
    last_ts: Int,
    steps: Int,
    reads: Int,
    failed: Int,
    written: List(FileFact),
    spawned: List(String),
    peers: Int,
  )
}

// What the fold carries from record to record.
type State {
  State(
    step_limit: Int,
    cards: List(Card),
    /// How many cards closed on a command, a result or the step limit, which is
    /// what `card_cap` counts.
    bounded_count: Int,
    turn_seq: Int,
    draft: Option(Draft),
    pending: Dict(String, message.ToolCall),
  )
}

/// Cuts oldest-first records into cards, closing a span after `step_limit`
/// steps. The caller hands in one strand's lineage and no other strand's
/// records, since a strand is its own parent links.
///
/// ## Examples
///
/// ```gleam
/// assert timeline.cut([], 40) == Cut([], None)
/// ```
pub fn cut(records: List(Entry), step_limit: Int) -> Cut {
  let state =
    list.fold(records, State(step_limit, [], 0, 0, None, dict.new()), step)

  Cut(list.reverse(state.cards), option.map(state.draft, open_card(state, _)))
}

/// Reads one record. A prompt, an answer and a compaction end the span before
/// them, because each is a boundary a reader looks for, and then become a card
/// of their own.
fn step(state: State, value: Entry) -> State {
  case value {
    entry.MessageEntry(message: message.UserMessage(..) as sent, ..) ->
      prompted(state, value, sent)

    entry.MessageEntry(message: message.AssistantMessage(..) as sent, ..) ->
      assistant(state, value, sent)

    entry.MessageEntry(message: message.ToolResultMessage(..) as sent, ..) ->
      result(state, value, sent)

    entry.CompactionEntry(tokens_before:, ..) ->
      compacted(state, value, tokens_before)

    entry.MessageEntry(message: message.CustomMessage(..), ..)
    | entry.BranchSummaryEntry(..)
    | entry.CustomEntry(..) -> touch(state, value)
  }
}

/// Reads a user message. It is a prompt unless the harness wrote it: an advisor
/// frame is the harness's, and a message from a peer or a sibling strand stays
/// inside the span as a count.
fn prompted(state: State, value: Entry, sent: message.AgentMessage) -> State {
  let harness = harness_written(sent)

  // The origin and the harness's own frames decide whether this is a prompt, a count or nothing.
  case sent {
    message.UserMessage(origin: Some(message.PeerOrigin(..)), ..)
    | message.UserMessage(origin: Some(message.StrandOrigin(..)), ..) ->
      touch(state, value)
      |> update(fn(draft) { Draft(..draft, peers: draft.peers + 1) })

    message.UserMessage(content:, ..) if !harness -> {
      let begun = settle(state, Worked) |> touch(value)
      let state = State(..begun, turn_seq: value.seq)
      close(
        state,
        Prompted,
        Facts(..blank(), excerpt: excerpt(user_text(content))),
      )
    }

    message.UserMessage(..)
    | message.AssistantMessage(..)
    | message.ToolResultMessage(..)
    | message.CustomMessage(..) -> touch(state, value)
  }
}

/// Whether the harness wrote a user message: an advisor frame, the strand's notes
/// at the start of a run, or the memory context it attaches to a prompt. None of
/// them is something a person asked, so none starts a turn.
pub fn harness_written(sent: message.AgentMessage) -> Bool {
  // The three frames the transcript itself draws as nothing a person said.
  transcript_lines.advisor_payload(sent) != None
  || transcript_lines.agent_notes_payload(sent) != None
  || case sent {
    message.UserMessage(content:, ..) ->
      composer.memory_context_lines(user_text(content)) != None
    message.AssistantMessage(..)
    | message.ToolResultMessage(..)
    | message.CustomMessage(..) -> False
  }
}

/// Reads a response. One with no call and some words ends a turn and is the
/// answer; one with calls adds steps and may close the span at an ask or the
/// step limit.
fn assistant(state: State, value: Entry, sent: message.AgentMessage) -> State {
  let calls = response_calls(sent)
  let words = response_text(sent)

  // Whether the response called anything, and whether it said anything.
  case calls, words {
    [], "" -> touch(state, value)

    [], _ -> {
      let settled = settle(state, Worked) |> touch(value)
      close(settled, Answered, Facts(..blank(), excerpt: excerpt(words)))
    }

    _, _ -> {
      let counted = list.fold(calls, touch(state, value), noted)

      closed_by_calls(counted, calls)
    }
  }
}

/// What a response's calls close: an ask ends the span at once, and the step
/// limit ends it when the calls have carried the count over.
fn closed_by_calls(state: State, calls: List(message.ToolCall)) -> State {
  let asked = list.any(calls, fn(call) { call.name == ask_name })

  // An ask closes the span at once; otherwise only a reached step limit does.
  case asked, steps_of(state) >= state.step_limit {
    True, _ -> close(state, Asked, blank())
    False, True -> bounded(state, Worked, blank())
    False, False -> state
  }
}

/// Reads a tool result, joining it to its call. Its facts go to the open span,
/// and a result that is a landmark may close the span.
fn result(state: State, value: Entry, sent: message.AgentMessage) -> State {
  let touched = touch(state, value)

  // A tool result matters only as the answer to a call still waiting.
  case sent {
    message.ToolResultMessage(tool_call_id:, ..) ->
      case dict.get(touched.pending, tool_call_id) {
        Ok(call) ->
          State(..touched, pending: dict.delete(touched.pending, tool_call_id))
          |> landmark(call, sent, value.id)
        Error(Nil) -> touched
      }

    message.UserMessage(..)
    | message.AssistantMessage(..)
    | message.CustomMessage(..) -> touched
  }
}

/// Reads what a finished call did to the span: a file written, a command's exit
/// status, a sub-agent's result.
fn landmark(
  state: State,
  call: message.ToolCall,
  sent: message.AgentMessage,
  source: EntryId,
) -> State {
  let failed = tool_failed(sent) || nonzero_exit(sent)

  // A failed call counts against the span once, whatever the call was and
  // whether the result said so by its error flag or by its exit status.
  let state = case failed {
    True ->
      update(state, fn(draft) { Draft(..draft, failed: draft.failed + 1) })
    False -> state
  }

  // The tool's name decides which fact the result adds.
  case call.name {
    "fs_edit" | "fs_write" -> wrote(state, call, sent, source)
    "bash" -> ran(state, call, sent)
    "agent_wait" if !failed -> reported(state, sent)
    _ -> state
  }
}

/// Adds the path of a successful file write, and its edit's line counts, to the
/// open span.
fn wrote(
  state: State,
  call: message.ToolCall,
  sent: message.AgentMessage,
  source: EntryId,
) -> State {
  case path_written(call, sent, source) {
    Some(file) -> update(state, add_file(_, file))
    None -> state
  }
}

/// Reads an `agent_wait` result. A child that returned closes the span; a wait
/// that ran out its deadline with children still working says nothing returned.
fn reported(state: State, sent: message.AgentMessage) -> State {
  // A pending answer is no card.
  case still_pending(sent) {
    True -> state
    False -> bounded(state, Reported, blank())
  }
}

/// Reads a command's result. A command that recorded an exit status closes the
/// span when it failed, or when the span has already written files, which is
/// how a run of edits meets the command that tries them.
fn ran(
  state: State,
  call: message.ToolCall,
  sent: message.AgentMessage,
) -> State {
  // A command's result counts only when it recorded both a status and a command.
  case exit_status(sent), field_text(call.arguments, "command") {
    Some(code), Some(text) -> {
      let fact = Command(reduced(text), code)

      // A failed command, or one that follows edits, is a landmark.
      case code != 0 || wrote_any(state) {
        True -> bounded(state, Ran, Facts(..blank(), command: Some(fact)))
        False -> state
      }
    }

    _, _ -> state
  }
}

/// Reads a compaction, which ends the span before it and is a card of its own.
fn compacted(state: State, value: Entry, tokens_before: Int) -> State {
  let settled = settle(state, Worked) |> touch(value)

  close(
    settled,
    Compacted,
    Facts(..blank(), tokens_before: Some(tokens_before)),
  )
}

// --- spans --------------------------------------------------------------------

/// Takes a record into the open span, opening one when none is, so that the
/// span's range always runs from its first record to its latest.
fn touch(state: State, value: Entry) -> State {
  // A span is extended when one is open and opened by this record when not.
  let draft = case state.draft {
    Some(draft) ->
      Draft(..draft, last: value.id, last_seq: value.seq, last_ts: value.ts)
    None ->
      Draft(
        from_seq: value.seq,
        started_at: value.ts,
        last: value.id,
        last_seq: value.seq,
        last_ts: value.ts,
        steps: 0,
        reads: 0,
        failed: 0,
        written: [],
        spawned: [],
        peers: 0,
      )
  }

  State(..state, draft: Some(draft))
}

/// Applies a change to the open span, when there is one.
fn update(state: State, change: fn(Draft) -> Draft) -> State {
  State(..state, draft: option.map(state.draft, change))
}

/// Ends the span before a boundary, as `kind`, when it holds a step. A span of
/// no step has nothing to say and is taken into the card that follows it.
fn settle(state: State, kind: Kind) -> State {
  case steps_of(state) {
    0 -> state
    _ -> close(state, kind, blank())
  }
}

/// Closes the span on a landmark the strand may choose not to honour: it joins
/// the next span when it holds too few steps, or when the strand already closed
/// `card_cap` cards this way.
fn bounded(state: State, kind: Kind, facts: Facts) -> State {
  // Too few steps, or a strand at its cap, leaves the span open.
  case steps_of(state) >= least_steps && state.bounded_count < card_cap {
    True ->
      State(..close(state, kind, facts), bounded_count: state.bounded_count + 1)
    False -> state
  }
}

/// Turns the open span into a closed card of `kind`, so the next record opens a
/// new span. With no open span there is nothing to close.
fn close(state: State, kind: Kind, extra: Facts) -> State {
  case state.draft {
    Some(draft) ->
      State(
        ..state,
        cards: [card_of(state, draft, kind, extra), ..state.cards],
        draft: None,
      )
    None -> state
  }
}

/// Builds the card a draft becomes, folding the draft's counters and written
/// files into `Facts` and adding what the closing record contributed in
/// `extra`.
fn card_of(state: State, draft: Draft, kind: Kind, extra: Facts) -> Card {
  let facts =
    Facts(
      ..extra,
      steps: draft.steps,
      reads: draft.reads,
      failed: draft.failed,
      files: list.take(list.reverse(draft.written), named_files),
      files_total: list.length(draft.written),
      spawned: list.take(list.reverse(draft.spawned), named_children),
      peers: draft.peers,
    )

  Card(
    kind:,
    turn_seq: state.turn_seq,
    from_seq: draft.from_seq,
    to_seq: draft.last_seq,
    last: draft.last,
    started_at: draft.started_at,
    ended_at: draft.last_ts,
    facts:,
  )
}

/// The open span as a card, so a host can say where the strand is.
fn open_card(state: State, draft: Draft) -> Card {
  card_of(state, draft, Worked, blank())
}

fn steps_of(state: State) -> Int {
  case state.draft {
    Some(draft) -> draft.steps
    None -> 0
  }
}

fn wrote_any(state: State) -> Bool {
  case state.draft {
    Some(draft) -> draft.written != []
    None -> False
  }
}

/// Adds a file to a span, keeping one entry per path and summing the lines of
/// its edits, so a file edited ten times is one fact.
fn add_file(draft: Draft, file: FileFact) -> Draft {
  // A path already in the span has its lines summed; a new path is added.
  let merged = case
    list.find(draft.written, fn(have) { have.path == file.path })
  {
    Ok(have) -> {
      let total =
        FileFact(
          file.path,
          have.added + file.added,
          have.removed + file.removed,
        )

      list.map(draft.written, fn(other) {
        case other.path == file.path {
          True -> total
          False -> other
        }
      })
    }
    Error(Nil) -> [file, ..draft.written]
  }

  Draft(..draft, written: merged)
}

/// Counts one call of a response, remembers it until its result arrives, and
/// notes a sub-agent's purpose when the call spawns one.
fn noted(state: State, call: message.ToolCall) -> State {
  // Only a spawn names a purpose.
  let spawned = case call.name {
    "agent_spawn" -> field_text(call.arguments, "purpose")
    _ -> None
  }

  State(..state, pending: dict.insert(state.pending, call.id, call))
  |> update(fn(draft) {
    Draft(
      ..draft,
      steps: draft.steps + 1,
      reads: draft.reads + read_count(call.name),
      spawned: case spawned {
        Some(purpose) -> [clip(purpose, purpose_bytes), ..draft.spawned]
        None -> draft.spawned
      },
    )
  })
}

// --- facts from records -------------------------------------------------------

/// The tool name the harness gives the ask tool, as a call carries it.
const ask_name = "ask"

const read_tools = ["fs_read", "read", "grep", "fs_list", "history_search"]

fn read_count(name: String) -> Int {
  case list.contains(read_tools, name) {
    True -> 1
    False -> 0
  }
}

/// The facts of nothing: the starting point a closing record adds its own fact
/// to.
fn blank() -> Facts {
  Facts(
    steps: 0,
    reads: 0,
    failed: 0,
    files: [],
    files_total: 0,
    command: None,
    spawned: [],
    peers: 0,
    tokens_before: None,
    excerpt: None,
  )
}

/// The tool calls a response carries, in the order the model emitted them.
fn response_calls(sent: message.AgentMessage) -> List(message.ToolCall) {
  case sent {
    message.AssistantMessage(content:, ..) ->
      list.filter_map(content, fn(block) {
        case block {
          message.AssistantToolCall(call) -> Ok(call)
          message.AssistantText(..) | message.AssistantThinking(..) ->
            Error(Nil)
        }
      })
    message.UserMessage(..)
    | message.ToolResultMessage(..)
    | message.CustomMessage(..) -> []
  }
}

/// The words of a response, joined and trimmed, which are empty when the
/// response only reasoned or only called tools.
fn response_text(sent: message.AgentMessage) -> String {
  case sent {
    message.AssistantMessage(content:, ..) ->
      list.filter_map(content, fn(block) {
        case block {
          message.AssistantText(text:, ..) -> Ok(text)
          message.AssistantThinking(..) | message.AssistantToolCall(..) ->
            Error(Nil)
        }
      })
      |> string.join("\n")
      |> string.trim
    message.UserMessage(..)
    | message.ToolResultMessage(..)
    | message.CustomMessage(..) -> ""
  }
}

/// The text blocks of a user message, joined, leaving images out.
fn user_text(content: List(message.UserBlock)) -> String {
  list.filter_map(content, fn(block) {
    case block {
      message.UserText(text:, ..) -> Ok(text)
      message.UserImage(..) -> Error(Nil)
    }
  })
  |> string.join("\n")
}

fn excerpt(text: String) -> Option(String) {
  case string.trim(text) {
    "" -> None
    words -> Some(clip(words, excerpt_bytes))
  }
}

/// The first line of `text`, cut so that it and its ellipsis fit in `limit`
/// bytes, at a character boundary, so a card never carries a paragraph.
fn clip(text: String, limit: Int) -> String {
  // The first line is the card's words; an empty text has none.
  let line = case string.split(text, "\n") {
    [first, ..] -> string.trim(first)
    [] -> ""
  }

  // A line over the limit is cut and marked as cut.
  case string.byte_size(line) > limit {
    True -> take_bytes(string.to_graphemes(line), limit - 3, "") <> "…"
    False -> line
  }
}

/// The characters of `graphemes`, in order, as many as fit in `budget` bytes.
fn take_bytes(graphemes: List(String), budget: Int, kept: String) -> String {
  // Characters are taken until the next one would not fit.
  case graphemes {
    [next, ..rest] ->
      case string.byte_size(next) <= budget {
        True -> take_bytes(rest, budget - string.byte_size(next), kept <> next)
        False -> kept
      }
    [] -> kept
  }
}

/// A path cut to `limit` bytes keeping its end, which is the part that tells two
/// files apart.
fn clip_path(path: String) -> String {
  // A path within the limit is kept whole.
  case string.byte_size(path) > path_bytes {
    True ->
      "…"
      <> take_bytes(list.reverse(string.to_graphemes(path)), path_bytes - 3, "")
      |> string.to_graphemes
      |> list.reverse
      |> string.concat
    False -> path
  }
}

/// Whether a result recorded a nonzero exit status, which `bash` also reports as
/// an error but a fixture or another tool may not.
fn nonzero_exit(sent: message.AgentMessage) -> Bool {
  // No recorded status is no failure.
  case exit_status(sent) {
    Some(code) -> code != 0
    None -> False
  }
}

/// Whether an `agent_wait` result says some child had not answered when the
/// deadline passed. That is an answer, but no sub-agent returned.
fn still_pending(sent: message.AgentMessage) -> Bool {
  // The result's details say so in a `pending` flag.
  case sent {
    message.ToolResultMessage(details: Some(details), ..) ->
      field(details, "pending") == Some(json.Bool(True))
    message.UserMessage(..)
    | message.AssistantMessage(..)
    | message.ToolResultMessage(..)
    | message.CustomMessage(..) -> False
  }
}

/// Whether a tool result reported an error in band.
fn tool_failed(sent: message.AgentMessage) -> Bool {
  case sent {
    message.ToolResultMessage(is_error:, ..) -> is_error
    message.UserMessage(..)
    | message.AssistantMessage(..)
    | message.CustomMessage(..) -> False
  }
}

/// The exit status a `bash` result recorded in its details, when it recorded
/// one.
fn exit_status(sent: message.AgentMessage) -> Option(Int) {
  case sent {
    message.ToolResultMessage(details: Some(details), ..) ->
      case field(details, "exit_code") {
        Some(json.Int(code)) -> Some(code)
        _ -> None
      }
    message.UserMessage(..)
    | message.AssistantMessage(..)
    | message.ToolResultMessage(..)
    | message.CustomMessage(..) -> None
  }
}

/// The file a successful `fs_edit` or `fs_write` wrote, with its line counts,
/// or nothing for a result that failed or named no path.
fn path_written(
  call: message.ToolCall,
  sent: message.AgentMessage,
  source: EntryId,
) -> Option(FileFact) {
  case sent {
    message.ToolResultMessage(is_error: False, details: Some(details), ..) ->
      case field_text(details, "path") {
        Some(path) -> Some(file_fact(clip_path(path), call, sent, source))
        None -> None
      }
    message.UserMessage(..)
    | message.AssistantMessage(..)
    | message.ToolResultMessage(..)
    | message.CustomMessage(..) -> None
  }
}

/// The lines an edit changed, as the step words count them from the result's
/// own diff, so a card and the transcript agree.
fn file_fact(
  path: String,
  call: message.ToolCall,
  sent: message.AgentMessage,
  source: EntryId,
) -> FileFact {
  let joined =
    tool_activity.Call(
      source:,
      invocation: call,
      outcome: Some(sent),
      result_source: None,
      asked: None,
    )

  // A diff the step words can count gives the lines; none gives zero.
  case step_words.of_call(joined).change {
    Some(step_words.Change(added:, removed:)) -> FileFact(path, added, removed)
    None -> FileFact(path, 0, 0)
  }
}

/// The executable and subcommand of a shell command, and nothing after them.
/// Leading `NAME=value` assignments and `cd`, `export` and `set` segments are
/// skipped, so `cd x && make check-storage` reads `make check-storage`. An
/// argument tail can hold a token or a header, so it is never kept.
///
/// ## Examples
///
/// ```gleam
/// assert timeline.reduced("curl -H 'Authorization: Bearer x' https://a") == "curl"
/// assert timeline.reduced("cd p && make check-storage -j4") == "make check-storage"
/// ```
pub fn reduced(command: String) -> String {
  let segments =
    command
    |> string.replace("&&", ";")
    |> string.replace("||", ";")
    |> string.replace("|", ";")
    |> string.replace("\n", ";")
    |> string.split(";")
    |> list.map(string.trim)
    |> list.filter(fn(segment) { segment != "" })

  // The first segment that is not setup is the command. When every segment is
  // setup, only the executable of the first is kept, never its arguments.
  case list.filter(segments, fn(segment) { !setup(segment) }), segments {
    [first, ..], _ -> words_of(first)
    [], [first, ..] -> words_of(first) |> first_word
    [], [] -> ""
  }
}

/// Whether a segment only prepares the environment for the one after it.
fn setup(segment: String) -> Bool {
  string.starts_with(segment, "cd ")
  || string.starts_with(segment, "export ")
  || string.starts_with(segment, "set ")
}

/// The words before the first space, which is the executable of a reduced
/// command.
fn first_word(words: String) -> String {
  // A reduced command is the executable and at most one subcommand.
  case string.split(words, " ") {
    [first, ..] -> first
    [] -> ""
  }
}

/// The first word of a command segment, and the second when it looks like a
/// subcommand, after leading assignments and an `env` prefix. A second word that
/// holds `=`, a slash, a digit or a capital is an argument, and is left out
/// because an argument can be a token.
fn words_of(segment: String) -> String {
  let words =
    string.split(segment, " ")
    |> list.filter(fn(word) { word != "" })
    |> list.drop_while(fn(word) { string.contains(word, "=") || word == "env" })

  // Two words give the executable and a subcommand when the second reads as one.
  case words {
    [first, second, ..] ->
      case subcommand(second) {
        True -> clip(first <> " " <> second, command_bytes)
        False -> clip(first, command_bytes)
      }
    [first] -> clip(first, command_bytes)
    [] -> ""
  }
}

/// Whether a word reads as a subcommand: lowercase letters, `-` and `_`, and
/// short. A flag, a path, an assignment and a token do not.
fn subcommand(word: String) -> Bool {
  let allowed = string.to_graphemes("abcdefghijklmnopqrstuvwxyz-_")

  string.byte_size(word) <= 24
  && !string.starts_with(word, "-")
  && list.all(string.to_graphemes(word), fn(letter) {
    list.contains(allowed, letter)
  })
}

// --- JSON ---------------------------------------------------------------------
/// A member of a JSON object, or nothing for a value that is not an object.
fn field(value: JsonValue, name: String) -> Option(JsonValue) {
  case value {
    json.Object(fields) -> option.from_result(list.key_find(fields, name))
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> None
  }
}

fn field_text(value: JsonValue, name: String) -> Option(String) {
  case field(value, name) {
    Some(json.String(text)) -> Some(text)
    _ -> None
  }
}

/// The word for a kind, for a host that lists them.
///
/// ## Examples
///
/// ```gleam
/// assert timeline.kind_word(Prompted) == "prompt"
/// ```
pub fn kind_word(kind: Kind) -> String {
  case kind {
    Prompted -> "prompt"
    Worked -> "work"
    Ran -> "command"
    Reported -> "result"
    Asked -> "ask"
    Compacted -> "compaction"
    Answered -> "answer"
  }
}

/// The kind a word names, the inverse of `kind_word`, or nothing for a word a
/// host does not know.
///
/// ## Examples
///
/// ```gleam
/// assert timeline.kind_of_word("prompt") == Ok(Prompted)
/// ```
pub fn kind_of_word(word: String) -> Result(Kind, Nil) {
  // Each word is the one `kind_word` gives its kind.
  case word {
    "prompt" -> Ok(Prompted)
    "work" -> Ok(Worked)
    "command" -> Ok(Ran)
    "result" -> Ok(Reported)
    "ask" -> Ok(Asked)
    "compaction" -> Ok(Compacted)
    "answer" -> Ok(Answered)
    _ -> Error(Nil)
  }
}

/// The steps a card is about, for a host that totals them.
pub fn total_steps(cards: List(Card)) -> Int {
  list.fold(cards, 0, fn(sum, card) { sum + card.facts.steps })
}

/// A card's duration in milliseconds, from its first record to its last.
pub fn duration_ms(card: Card) -> Int {
  int.max(0, card.ended_at - card.started_at)
}
