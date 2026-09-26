//// The repeated-failure guard, at two scales. The pure half pins what
//// counts as one streak: the same call by canonical arguments, every copy
//// failed, broken by a different turn, a success or any user message, and
//// blind to the batch being cleared. The driven half replays the incident
//// that motivated it — a model sending one failing call forever — through
//// a real session tree and checks the call runs three times, is refused
//// once, and ends the run on the next repeat.

import core/clock
import core/json
import core/message.{
  type AgentMessage, type ToolCall, AssistantMessage, AssistantToolCall,
  ToolCall, ToolResultMessage, ToolResultText,
}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import machine/operation.{ReplaySafe}
import machine/planner
import runtime/api
import runtime/repeat_guard
import runtime/supervisor
import session/session
import support/fake
import support/harness
import support/recorder

// --- the streak, pure ------------------------------------------------------

fn call(id: String, arguments: json.JsonValue) -> ToolCall {
  ToolCall(
    id:,
    name: "history_search",
    arguments:,
    thought_signature: None,
    namespace: None,
  )
}

fn no_query() -> json.JsonValue {
  json.Object([
    #("action", json.String("search")),
    #("limit", json.Int(15)),
    #("scope", json.String("repository")),
  ])
}

// The same arguments streamed in another key order, which a provider is
// free to do and which must not reset the count.
fn no_query_reordered() -> json.JsonValue {
  json.Object([
    #("scope", json.String("repository")),
    #("action", json.String("search")),
    #("limit", json.Int(15)),
  ])
}

fn turn(calls: List(ToolCall)) -> AgentMessage {
  let assert AssistantMessage(..) as base = fake.tool_use("again", [], 1)
  AssistantMessage(
    ..base,
    content: list.map(calls, fn(made) { AssistantToolCall(call: made) }),
  )
}

fn result(id: String, failed: Bool) -> AgentMessage {
  ToolResultMessage(
    tool_call_id: id,
    tool_name: "history_search",
    content: [ToolResultText(text: "`query` is required", text_signature: None)],
    details: None,
    usage: None,
    added_tool_names: None,
    is_error: failed,
    timestamp: 0,
  )
}

// One finished turn of the call failing, newest first as the guard reads.
fn failed_turn(id: String, arguments: json.JsonValue) -> List(AgentMessage) {
  [result(id, True), turn([call(id, arguments)])]
}

pub fn no_history_is_no_streak_test() {
  assert repeat_guard.streak(call("now", no_query()), []) == 0
  assert repeat_guard.judge(call("now", no_query()), []) == repeat_guard.Proceed
}

pub fn identical_failures_count_across_key_order_test() {
  let current = call("now", no_query())
  let history =
    list.flatten([
      [turn([current])],
      failed_turn("c3", no_query_reordered()),
      failed_turn("c2", no_query()),
      failed_turn("c1", no_query_reordered()),
    ])
  assert repeat_guard.streak(current, history) == 3
}

pub fn two_failures_still_clear_test() {
  let current = call("now", no_query())
  let history =
    list.flatten([failed_turn("c2", no_query()), failed_turn("c1", no_query())])
  assert repeat_guard.judge(current, history) == repeat_guard.Proceed
}

pub fn a_third_failure_refuses_and_a_fourth_ends_the_run_test() {
  let current = call("now", no_query())
  let three =
    list.flatten([
      failed_turn("c3", no_query()),
      failed_turn("c2", no_query()),
      failed_turn("c1", no_query()),
    ])
  let assert repeat_guard.Refuse(reason:, ending: planner.RefusalContinues) =
    repeat_guard.judge(current, three)
  assert string.contains(reason, "3 times in a row")
  assert string.contains(reason, "ends the run")

  let four = list.append(failed_turn("c4", no_query()), three)
  let assert repeat_guard.Refuse(ending: planner.RefusalEndsRun, ..) =
    repeat_guard.judge(current, four)
}

pub fn a_changed_argument_is_a_different_call_test() {
  let current =
    call(
      "now",
      json.Object([
        #("action", json.String("search")),
        #("query", json.String("SI issue")),
      ]),
    )
  let history =
    list.flatten([
      failed_turn("c3", no_query()),
      failed_turn("c2", no_query()),
      failed_turn("c1", no_query()),
    ])
  assert repeat_guard.streak(current, history) == 0
}

// Each of these ends the streak where it sits, so only the failures
// newer than it count.
pub fn a_user_message_a_success_or_another_turn_breaks_the_streak_test() {
  let current = call("now", no_query())
  let older =
    list.flatten([failed_turn("c2", no_query()), failed_turn("c1", no_query())])

  let steered =
    list.flatten([
      failed_turn("c4", no_query()),
      [fake.user("try a query")],
      older,
    ])
  assert repeat_guard.streak(current, steered) == 1

  let succeeded =
    list.flatten([
      failed_turn("c4", no_query()),
      [result("c3", False), turn([call("c3", no_query())])],
      older,
    ])
  assert repeat_guard.streak(current, succeeded) == 1

  let elsewhere =
    list.flatten([
      failed_turn("c4", no_query()),
      [
        result("c3", True),
        turn([ToolCall(..call("c3", no_query()), name: "bash")]),
      ],
      older,
    ])
  assert repeat_guard.streak(current, elsewhere) == 1
}

// Editing a file beside re-running the same failing command changes what
// the command runs against, so such a turn is progress, not a repeat: the
// edit-then-test loop every coding model runs must never be refused.
pub fn a_turn_that_also_did_other_work_breaks_the_streak_test() {
  let current = call("now", no_query())
  let edit = ToolCall(..call("e3", json.Object([])), name: "fs_edit")
  let history =
    list.flatten([
      failed_turn("c4", no_query()),
      [
        result("c3", True),
        result("e3", False),
        turn([edit, call("c3", no_query())]),
      ],
      failed_turn("c2", no_query()),
      failed_turn("c1", no_query()),
    ])
  assert repeat_guard.streak(current, history) == 1
}

// The incident's first turn sent the call twice in one batch. A turn
// counts once, and only when every copy in it failed.
pub fn a_turn_counts_once_and_only_if_every_copy_failed_test() {
  let current = call("now", no_query())
  let doubled = [
    result("b", True),
    result("a", True),
    turn([call("a", no_query()), call("b", no_query())]),
  ]
  assert repeat_guard.streak(current, doubled) == 1

  let half = [
    result("b", False),
    result("a", True),
    turn([call("a", no_query()), call("b", no_query())]),
  ]
  assert repeat_guard.streak(current, half) == 0
}

// --- the incident, driven --------------------------------------------------

// A provider that answers every turn with the same failing call, under a
// fresh call id each time, the way the GLM-5.3 session did. Past a dozen
// turns it gives up and answers, so a guard that failed to act shows up
// as a completed-by-assistant run with far too many executions rather
// than as a hung test.
pub fn a_model_repeating_a_failing_call_is_stopped_test() {
  let rec = recorder.start()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let eff =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [#("history_search", ReplaySafe)],
      fn(spec) {
        case fake.turn(spec) {
          n if n < 12 ->
            fake.Reply(fake.tool_use(
              "searching",
              [#("c" <> int.to_string(n), "history_search")],
              3,
            ))
          _ -> fake.Reply(fake.answer("giving up", 3))
        }
      },
      fn(_run) {
        fake.ToolReply(
          text: "`query` is required to search the repository",
          is_error: True,
          terminate: False,
        )
      },
    )
  let options =
    api.Options(
      ..api.default_options(harness.configuration()),
      poll_interval_ms: 50,
      idle_poll_interval_ms: 50,
      tolerance: supervisor.Tolerance(intensity: 10_000, period: 10),
    )
  let assert Ok(rt) = api.open(sess, eff, options)
    as "the session tree must boot"
  let assert Ok(op) = api.prompt(rt, [fake.user("find the SI session")])
    as "the prompt must be accepted"
  let assert Ok(last) = api.await_result(rt, op, within_ms: 15_000)
    as "the looping run must end"

  let assert operation.RunLastResult(
    outcome: operation.RunCompleted(
      completion: operation.CompletedByTerminatedTools,
    ),
    ..,
  ) = last

  // Three real executions, then two refusals the tool never saw: the
  // warning and the one that ended the run.
  let executed =
    list.count(["c0", "c1", "c2", "c3", "c4"], fn(id) {
      recorder.read(rec, "tool:history_search:" <> id) == 1
    })
  assert executed == 3
  assert recorder.read(rec, "tool:history_search:c3") == 0
  assert recorder.read(rec, "provider") == 5

  let results =
    harness.final_projection(sess)
    |> list.filter(string.starts_with(_, "tool:"))
  let assert [_, _, _, warned, ended] = results
  assert string.contains(warned, ":err:loom refused this call without running")
  assert string.contains(ended, ":err:loom refused this call and ended the run")
  process.kill(rt.tree.supervisor)
}
