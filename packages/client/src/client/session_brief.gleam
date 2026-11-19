//// What a running session reports of its own recent work, for Home's inbox
//// (protocol-change/125): the resident side of the `session.brief` read.
////
//// The brief is computed by the session's own Agency actor, beside `Overview`
//// and `AttentionFeed`, from reads of its own stores. It runs no tool, opens no
//// other session and writes nothing. Everything in it is bounded, and the part
//// that a model wrote is marked as such, because Home draws it beside facts the
//// harness wrote and a reader must be able to tell them apart.
////
//// ## Flow
////
//// `read` → `of_window` → `strands` → `goal_of` → `shed`
////
//// 1. `read` finds main's leaf through `window` and scans back from it, newest
////    first, over a bounded number of message entries.
//// 2. `of_window` takes from that window the latest assistant text, the last few
////    tool steps (through `session_view/tool_activity` and
////    `session_view/step_words`, so the words are the ones the session's own
////    page uses), the peer messages after the time the page named and the last
////    shell command with its exit status.
//// 3. `strands` lists the strands from the strand-state and last-result
////    registers, working ones first, with the time each last changed state.
//// 4. `goal_of` reads the goal cell, when there is one.
//// 5. `shed` removes strands, then peers, then steps until the encoded brief
////    fits `session_brief.brief_bytes`.
////
//// ## What each word claims
////
//// A step's outcome is what its result envelope reported, and says nothing of
//// what the command meant. The last command is the last `bash` call whose result
//// carried an exit status, worded by the page as the command and the status and
//// never as the result of a check. A strand's time is the start of its open run,
//// or the time of the last entry its last run wrote. The goal's tokens are the
//// accounted total against the budget the operator pinned.

import client/attention_feed
import client/goalstate
import core/entry.{type Entry}
import core/glance
import core/ids.{type EntryId}
import core/json.{type JsonValue}
import core/message
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import machine/operation
import runtime/api
import runtime/writer
import session/session
import session_view/step_words
import session_view/tool_activity
import storage/storage
import web_view/session_brief.{type Brief}

/// How many message entries of main's branch a brief looks back over. The
/// latest text, four steps, three peer messages and a command all come from
/// this window, so what is older than it is not in the brief.
pub const scan_cap = 80

/// The main strand, which the brief's text, steps, peers and command are read
/// from. A session's other strands are in the roster.
const main_strand = "main"

/// The brief of this session as one reply object, `{"brief": {...}}`, with the
/// peer messages that arrived after `since` (Unix milliseconds; zero lists the
/// latest).
///
/// ## Examples
///
/// ```gleam
/// // session_brief.read(runtime, 0)
/// ```
pub fn read(runtime: api.Runtime, since: Int) -> Result(JsonValue, String) {
  use entries <- result.try(window(runtime))
  use roster <- result.try(strands(runtime))
  use goal <- result.map(goal_of(runtime))

  of_window(entries, since)
  |> with(roster, goal)
  |> shed
  |> session_brief.to_json
}

/// The brief of this session as a typed value, before it is shed and encoded.
///
/// ## Examples
///
/// ```gleam
/// // session_brief.build(runtime, 0)
/// ```
pub fn build(runtime: api.Runtime, since: Int) -> Result(Brief, String) {
  use entries <- result.try(window(runtime))
  use roster <- result.try(strands(runtime))
  use goal <- result.map(goal_of(runtime))
  of_window(entries, since) |> with(roster, goal) |> shed
}

/// Main's last `scan_cap` message entries, newest first, or none when main has
/// no leaf yet.
fn window(runtime: api.Runtime) -> Result(List(Entry), String) {
  use leaf <- result.try(
    session.strand_leaf(runtime.session, main_strand)
    |> result.map_error(string.inspect),
  )

  // A strand with no leaf has nothing to scan.
  case leaf {
    Some(session.Cell(value: Some(leaf), ..)) ->
      storage.scan_branch(
        runtime.session.store,
        storage.branch_scan(leaf)
          |> storage.branch_kind(storage.Message)
          |> storage.branch_limit(scan_cap),
      )
      |> result.map_error(string.inspect)
    Some(session.Cell(value: None, ..)) | None -> Ok([])
  }
}

/// What a window of main's message entries, newest first, says: the latest
/// assistant text, the steps, the peers recorded after `since` and the last
/// command, with an empty roster and no goal.
///
/// ## Examples
///
/// ```gleam
/// assert session_brief.of_window([], 0).steps == []
/// ```
pub fn of_window(newest_first: List(Entry), since: Int) -> Brief {
  let calls = tool_activity.calls(list.reverse(newest_first))
  let newest_calls = list.reverse(calls)

  session_brief.Brief(
    assistant: latest_assistant(newest_first),
    steps: newest_calls |> list.take(session_brief.max_steps) |> list.map(step),
    strands: [],
    goal: None,
    peers: peers(newest_first, since),
    command: last_command(newest_calls),
  )
}

/// The brief with its roster and goal.
fn with(
  brief: Brief,
  roster: List(session_brief.Strand),
  goal: Option(session_brief.Goal),
) -> Brief {
  session_brief.Brief(..brief, strands: roster, goal:)
}

// --- the text, the steps and the peers ------------------------------------------

/// The latest assistant message that has text, which may belong to a run that
/// is still going.
fn latest_assistant(
  newest_first: List(Entry),
) -> Option(session_brief.Assistant) {
  list.find_map(newest_first, fn(record) {
    case record {
      entry.MessageEntry(
        message: message.AssistantMessage(content:, error_message: None, ..),
        ts:,
        ..,
      ) ->
        case
          glance.clip(
            string.join(assistant_texts(content), " "),
            session_brief.assistant_bytes,
          )
        {
          "" -> Error(Nil)
          text ->
            Ok(session_brief.Assistant(
              text: session_brief.untrusted(text),
              at: ts,
            ))
        }
      _ -> Error(Nil)
    }
  })
  |> option.from_result
}

/// The text blocks of an assistant message.
fn assistant_texts(content: List(message.AssistantBlock)) -> List(String) {
  list.filter_map(content, fn(block) {
    case block {
      message.AssistantText(text:, ..) -> Ok(text)
      message.AssistantToolCall(_) | message.AssistantThinking(..) -> Error(Nil)
    }
  })
}

/// One call as a step: the words the session's own page uses for it, and how
/// it stands.
fn step(call: tool_activity.Call) -> session_brief.Step {
  let words = step_words.of_call(call)

  // A result envelope says how a call ended, and no result means it is running.
  let outcome = case call.outcome {
    None -> session_brief.Running
    Some(message.ToolResultMessage(is_error: False, ..)) ->
      session_brief.Succeeded
    Some(message.ToolResultMessage(is_error: True, ..)) -> session_brief.Failed
    Some(_) -> session_brief.Succeeded
  }

  // A call with no result is worded in the present tense, since the past tense
  // would claim an outcome it has not reached.
  let spoken = case outcome {
    session_brief.Running -> step_words.pending(words)
    session_brief.Succeeded | session_brief.Failed -> words
  }

  session_brief.Step(
    at: option.unwrap(call.asked, 0),
    tool: session_brief.untrusted(glance.clip(
      call.invocation.name,
      session_brief.tool_bytes,
    )),
    words: session_brief.untrusted(glance.clip(
      step_words.text(spoken),
      session_brief.words_bytes,
    )),
    outcome:,
  )
}

/// The peer messages recorded after `since`, newest first, at most
/// `max_peers`. A peer message is a user message whose admitted author is a peer
/// agent, so a message a person typed or a strand of this session sent is not
/// one.
fn peers(newest_first: List(Entry), since: Int) -> List(session_brief.Peer) {
  newest_first
  |> list.filter_map(fn(record) {
    case record {
      entry.MessageEntry(
        message: message.UserMessage(
          content:,
          origin: Some(message.PeerOrigin(session:, strand:)),
          ..,
        ),
        ts:,
        ..,
      )
        if ts > since
      ->
        Ok(session_brief.Peer(
          session: glance.clip(session, session_brief.strand_bytes),
          strand: glance.clip(strand, session_brief.strand_bytes),
          at: ts,
          text: session_brief.untrusted(glance.clip(
            string.join(user_texts(content), " "),
            session_brief.peer_bytes,
          )),
        ))
      _ -> Error(Nil)
    }
  })
  |> list.take(session_brief.max_peers)
}

/// The text blocks of a user message.
fn user_texts(content: List(message.UserBlock)) -> List(String) {
  list.filter_map(content, fn(block) {
    case block {
      message.UserText(text:, ..) -> Ok(text)
      message.UserImage(..) -> Error(Nil)
    }
  })
}

/// The newest `bash` call whose result carried an exit status, as the command
/// and the status and nothing more.
fn last_command(
  newest_calls: List(tool_activity.Call),
) -> Option(session_brief.Command) {
  list.find_map(newest_calls, fn(call) {
    case call.invocation.name, call.outcome {
      "bash", Some(message.ToolResultMessage(details: Some(details), ..)) ->
        case
          field(details, "exit_code"),
          field(call.invocation.arguments, "command")
        {
          Ok(json.Int(code)), Ok(json.String(command)) ->
            Ok(session_brief.Command(
              command: session_brief.untrusted(glance.clip(
                command,
                session_brief.command_bytes,
              )),
              exit: code,
              at: option.unwrap(call.asked, 0),
            ))
          _, _ -> Error(Nil)
        }
      _, _ -> Error(Nil)
    }
  })
  |> option.from_result
}

/// A member of a JSON object.
fn field(value: JsonValue, name: String) -> Result(JsonValue, Nil) {
  case value {
    json.Object(fields) -> list.key_find(fields, name)
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error(Nil)
  }
}

// --- the roster -----------------------------------------------------------------

/// The session's strands, working ones first and then by name, at most
/// `max_strands`, each with the time it last changed state. One listing of each
/// register and one batch read of the entries the idle strands' last runs ended
/// on.
fn strands(runtime: api.Runtime) -> Result(List(session_brief.Strand), String) {
  use states <- result.try(attention_feed.strand_states(runtime))
  use results <- result.try(attention_feed.last_results(runtime))

  let ordered =
    states
    |> list.sort(fn(left, right) {
      case option.is_some(left.1), option.is_some(right.1) {
        True, False -> order_before()
        False, True -> order_after()
        True, True | False, False -> string.compare(left.0, right.0)
      }
    })
    |> list.take(session_brief.max_strands)

  // The entries the idle strands' last runs ended on give their times.
  let leaves =
    list.filter_map(ordered, fn(pair) {
      case pair.1, list.key_find(results, pair.0) {
        None, Ok(last) -> leaf_of(last)
        _, _ -> Error(Nil)
      }
    })
  use found <- result.map(
    writer.get_entries(runtime.tree.writer, leaves)
    |> result.map_error(string.inspect),
  )

  list.map(ordered, fn(pair) {
    let #(name, current) = pair
    let name = glance.clip(name, session_brief.strand_bytes)

    // A working strand is dated by its open run, and any other by its last run.
    case current, list.key_find(results, pair.0) {
      Some(op), _ ->
        session_brief.Strand(
          name:,
          state: session_brief.Working,
          since: Some(ids.op_id_timestamp_ms(op)),
        )
      None, Ok(last) ->
        session_brief.Strand(
          name:,
          state: idle_state(last),
          since: leaf_of(last)
            |> result.try(fn(id) { dict.get(found, id) })
            |> result.map(fn(record) { record.ts })
            |> option.from_result,
        )
      None, Error(Nil) ->
        session_brief.Strand(name:, state: session_brief.Idle, since: None)
    }
  })
}

/// `Lt` and `Gt` named for what they mean in the roster's order.
fn order_before() -> order.Order {
  order.Lt
}

/// See `order_before`.
fn order_after() -> order.Order {
  order.Gt
}

/// Whether a strand with nothing running last failed or did not.
fn idle_state(last: operation.LastResult) -> session_brief.State {
  case last {
    operation.RunLastResult(outcome: operation.RunFailed(_), ..) ->
      session_brief.Stopped
    operation.RunLastResult(..)
    | operation.CompactionLastResult(..)
    | operation.NavigationLastResult(..) -> session_brief.Idle
  }
}

/// The entry a terminal result ended on.
fn leaf_of(last: operation.LastResult) -> Result(EntryId, Nil) {
  case last {
    operation.RunLastResult(leaf: Some(id), ..)
    | operation.CompactionLastResult(leaf: Some(id), ..)
    | operation.NavigationLastResult(leaf: Some(id), ..) -> Ok(id)
    operation.RunLastResult(leaf: None, ..)
    | operation.CompactionLastResult(leaf: None, ..)
    | operation.NavigationLastResult(leaf: None, ..) -> Error(Nil)
  }
}

// --- the goal -------------------------------------------------------------------

/// The session's goal and what it has spent, or nothing when it has none or its
/// cell does not read, which is the same to a page.
fn goal_of(runtime: api.Runtime) -> Result(Option(session_brief.Goal), String) {
  use cell <- result.map(
    api.fact(runtime, api.goal_fact_prefix <> "state")
    |> result.map_error(string.inspect),
  )

  // A goal cell that does not read is the same to a page as no goal.
  case cell |> option.map(goalstate.decode) {
    Some(Ok(goal)) ->
      Some(session_brief.Goal(
        objective: glance.clip(goal.objective, session_brief.objective_bytes),
        status: goalstate.encode_status(goal.status),
        tokens_used: int.max(goal.tokens_used, 0),
        token_budget: int.max(goal.token_budget, 0),
      ))
    Some(Error(_)) | None -> None
  }
}

// --- the bound ------------------------------------------------------------------

/// The brief with items removed until its encoding fits
/// `session_brief.brief_bytes`: the strands first, then the peers, then the
/// steps, each from the end of its list, and last the assistant's words. The
/// fixed part is far under the bound.
///
/// ## Examples
///
/// ```gleam
/// // session_brief.shed(brief)
/// ```
pub fn shed(brief: Brief) -> Brief {
  case string.byte_size(json.to_string(session_brief.to_json(brief))) {
    size if size <= session_brief.brief_bytes -> brief
    _ ->
      case brief.strands, brief.peers, brief.steps {
        [_, ..], _, _ ->
          shed(
            session_brief.Brief(
              ..brief,
              strands: list.take(brief.strands, list.length(brief.strands) - 1),
            ),
          )
        [], [_, ..], _ ->
          shed(
            session_brief.Brief(
              ..brief,
              peers: list.take(brief.peers, list.length(brief.peers) - 1),
            ),
          )
        [], [], [_, ..] ->
          shed(
            session_brief.Brief(
              ..brief,
              steps: list.take(brief.steps, list.length(brief.steps) - 1),
            ),
          )
        [], [], [] -> session_brief.Brief(..brief, assistant: None)
      }
  }
}
