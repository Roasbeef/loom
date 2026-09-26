//// The repeated-failure guard: what clearance does with a tool call the
//// model has already made, arguments and all, and watched fail.
////
//// # Why the harness has to decide this
////
//// A refusal a tool writes is only as good as the model reading it. A
//// GLM-5.3 session called `history_search` twenty times with the same
//// arguments and no `query`; every call earned the same in-band refusal
//// naming the missing field, and the model, by then answering in 23
//// tokens with no reasoning at all, sent the call again. Nothing in the
//// run could stop it: the tool had said everything it could, and the
//// drive's fuel is ten thousand steps. Only an advisor strand, where one
//// was attached, broke the loop.
////
//// So clearance asks one question before a call runs: how many times in
//// a row has this exact call just failed? The answer is read from the
//// branch, which makes it the same after a crash as before one, and it
//// takes three steps:
////
//// 1. Below `refuse_after` the call clears as it always did. Two
////    failures are an ordinary retry.
//// 2. At `refuse_after` the call is refused without running, in words
////    the model has not seen yet: that it is repeating itself, that the
////    arguments are the problem, and that one more repeat ends the run.
//// 3. At `end_after` — the model has repeated the call past that refusal
////    too — the call is refused and the run ends. Nothing the model could
////    be shown next differs from what it just ignored.
////
//// # What counts as the same call, and as a streak
////
//// The same call is the same tool name with the same arguments after
//// `core/json.canonical`, so a provider that streams keys in a different
//// order does not reset the count. Error text is deliberately not part
//// of it: a `bash` failure's output carries timestamps and pids, so a
//// loop on one would never repeat byte for byte.
////
//// A streak is the run of the model's most recent turns that made this
//// call and nothing else, every copy of it failing. It ends at the first
//// turn that did anything besides the call, and at a turn in which it
//// succeeded. A turn that edited a file beside re-running a failing test
//// changed the world the test runs in, so it is progress rather than a
//// loop; it is also a batch the planner could not end, since a run ends
//// only when every call in its batch says so. It ends at any user message
//// too: an operator's reply, a steer or an advisor's nudge is new input,
//// and new input is a reason to let the model try again. The guard's own
//// refusals are failed results, so they extend the streak that caused
//// them, which is what lets the third step be reached.

import core/json
import core/message.{
  type AgentMessage, type ToolCall, AssistantMessage, AssistantText,
  AssistantThinking, AssistantToolCall, CustomMessage, ToolResultMessage,
  UserMessage,
}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import machine/planner

/// How many consecutive failed turns of one call its next repeat is
/// refused after. Three: one failure is information, two is a retry, and
/// a third identical failure is a pattern.
pub const refuse_after = 3

/// How many consecutive failed turns, the guard's own refusal among them,
/// end the run. One past `refuse_after`: the refusal is the one warning.
pub const end_after = 4

/// How many of the branch's newest message entries the guard reads. A
/// streak long enough to end a run is `end_after` turns of at least two
/// messages each, so this leaves room for wide batches beside the call
/// while keeping the read bounded however long the session grows.
pub const window = 64

/// What clearance does with a call.
pub type Verdict {
  /// The call has no streak worth stopping; clear it as usual.
  Proceed

  /// Refuse the call without running it. `reason` is the model-facing
  /// text, and `ending` says whether the run ends with this batch.
  Refuse(reason: String, ending: planner.RefusalEnding)
}

/// The verdict for `call`, given the branch's messages newest first. The
/// current batch's own assistant message may be among them; it is the one
/// carrying `call.id`, and it is skipped, since its results do not exist
/// yet.
///
/// ## Examples
///
/// ```gleam
/// // repeat_guard.judge(call, newest_first)
/// // -> Refuse(reason: "...", ending: planner.RefusalContinues)
/// ```
///
pub fn judge(call: ToolCall, newest_first: List(AgentMessage)) -> Verdict {
  let count = streak(call, newest_first)
  case count >= end_after, count >= refuse_after {
    True, _ ->
      Refuse(reason: ended(call, count), ending: planner.RefusalEndsRun)
    False, True ->
      Refuse(reason: warned(call, count), ending: planner.RefusalContinues)
    False, False -> Proceed
  }
}

/// How many of the model's most recent turns, before the one carrying
/// `call`, made this same call and saw every copy of it fail.
///
/// ## Examples
///
/// ```gleam
/// assert repeat_guard.streak(call, []) == 0
/// ```
///
pub fn streak(call: ToolCall, newest_first: List(AgentMessage)) -> Int {
  let key = identity(call)
  count(newest_first, call.id, key, dict.new(), 0)
}

// The walk meets a turn's results before the turn itself, because it runs
// newest first, so it carries what it has seen as it goes: each result's
// failure flag by call id, read when the assistant message that made the
// calls arrives.
fn count(
  messages: List(AgentMessage),
  current: String,
  key: #(String, String),
  failed: Dict(String, Bool),
  total: Int,
) -> Int {
  case messages {
    [] -> total

    // New input from anyone but the model ends the streak.
    [UserMessage(..), ..] -> total

    [ToolResultMessage(tool_call_id:, is_error:, ..), ..rest] ->
      count(
        rest,
        current,
        key,
        dict.insert(failed, tool_call_id, is_error),
        total,
      )

    [CustomMessage(..), ..rest] -> count(rest, current, key, failed, total)

    [AssistantMessage(content:, ..), ..rest] -> {
      let calls = calls_in(content)
      let matching = list.filter(calls, fn(made) { identity(made) == key })
      case list.any(calls, fn(made) { made.id == current }), matching {
        // The batch being cleared: its results are not in the tree yet.
        True, _ -> count(rest, current, key, failed, total)

        // A turn that did anything besides this call breaks the streak,
        // as does one where any copy of it succeeded.
        False, _ ->
          case
            matching != []
            && list.length(matching) == list.length(calls)
            && list.all(matching, fn(made) {
              dict.get(failed, made.id) == Ok(True)
            })
          {
            True -> count(rest, current, key, failed, total + 1)
            False -> total
          }
      }
    }
  }
}

fn calls_in(content: List(message.AssistantBlock)) -> List(ToolCall) {
  list.filter_map(content, fn(block) {
    case block {
      AssistantToolCall(call:) -> Ok(call)
      AssistantText(..) | AssistantThinking(..) -> Error(Nil)
    }
  })
}

fn identity(call: ToolCall) -> #(String, String) {
  #(call.name, json.to_string(json.canonical(call.arguments)))
}

// --- the words ---------------------------------------------------------------

fn warned(call: ToolCall, count: Int) -> String {
  "loom refused this call without running it. `"
  <> call.name
  <> "` has failed "
  <> int.to_string(count)
  <> " times in a row with exactly these arguments, and repeating it "
  <> "unchanged tells you nothing new. Read the last error, then change the "
  <> "arguments or take a different step. Sending this same call again ends "
  <> "the run."
}

fn ended(call: ToolCall, count: Int) -> String {
  "loom refused this call and ended the run. `"
  <> call.name
  <> "` failed "
  <> int.to_string(count)
  <> " times in a row with exactly these arguments, the last after loom "
  <> "had already refused it for repeating."
}
