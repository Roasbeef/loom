//// The full projection pipeline (pi §2.5): custom-entry projectors, the
//// `transform_context` hook seam, orphan-call healing, and the
//// append-only context invariant as a generated property — across a
//// strand's successive projections, the prior projection is a prefix of
//// the next except across a compaction.
////
//// The invariant is a `statem` test. A command is one settled turn appended
//// to a fresh in-memory session (a user message, a settled assistant turn, a
//// tool round trip, a custom entry, a compaction), and after each one the
//// session is projected and compared with the projection before it. Deleting
//// a turn from the middle of a failing list leaves a shorter valid list,
//// which is what `statem` shrinks by, where a list of kinds under `qcheck`
//// redraws its elements when its length shrinks. The model is empty, because
//// every turn is meaningful after any other.

import core/clock
import core/entry.{type Entry}
import core/json
import core/message.{type AgentMessage}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import qcheck
import session/session
import statem
import storage/storage
import support/drive
import support/messages

// The projection every test here uses: "note" customs project to user
// messages; other custom types stay out of context.
fn note_projection() -> session.Projection {
  session.projection()
  |> session.with_projector("note", fn(view) {
    case view.data {
      Some(json.String(text)) -> Some(messages.user_text("note:" <> text))
      Some(_) | None -> None
    }
  })
}

// --- projectors and the transform hook ------------------------------------

pub fn registered_projector_enters_context_test() {
  let assert Ok(sess) = session.open_memory(clock.fixed(at: 1000))
  let ctx = drive.new_ctx(sess, 11)
  let #(ctx, _) = drive.append_message(ctx, messages.user_msg(1))
  let #(ctx, _) = drive.append_custom(ctx, "note", Some(json.String("hello")))
  let assert Ok(projected) = session.project(sess, ctx.leaf, note_projection())
  assert projected == [messages.user_msg(1), messages.user_text("note:hello")]
}

pub fn unregistered_custom_is_skipped_test() {
  let assert Ok(sess) = session.open_memory(clock.fixed(at: 1000))
  let ctx = drive.new_ctx(sess, 12)
  let #(ctx, _) = drive.append_message(ctx, messages.user_msg(1))
  let #(ctx, _) =
    drive.append_custom(ctx, "unknown", Some(json.String("hidden")))
  let assert Ok(projected) = session.project(sess, ctx.leaf, note_projection())
  assert projected == [messages.user_msg(1)]
}

pub fn projector_returning_none_keeps_entry_out_test() {
  let assert Ok(sess) = session.open_memory(clock.fixed(at: 1000))
  let ctx = drive.new_ctx(sess, 13)
  // The registered "note" projector maps non-string payloads to None.
  let #(ctx, _) = drive.append_custom(ctx, "note", Some(json.Int(7)))
  let assert Ok(projected) = session.project(sess, ctx.leaf, note_projection())
  assert projected == []
}

pub fn transform_hook_runs_last_test() {
  let assert Ok(sess) = session.open_memory(clock.fixed(at: 1000))
  let ctx = drive.new_ctx(sess, 14)
  let #(ctx, _) = drive.append_message(ctx, messages.user_msg(1))
  let #(ctx, _) = drive.append_custom(ctx, "note", Some(json.String("x")))
  let marker = messages.user_text("appended-by-transform")
  let projection =
    note_projection()
    |> session.with_transform(fn(messages) { list.append(messages, [marker]) })
  let assert Ok(projected) = session.project(sess, ctx.leaf, projection)
  // The transform saw the projector's output — it ran after every other
  // rule.
  assert projected
    == [messages.user_msg(1), messages.user_text("note:x"), marker]
}

pub fn empty_leaf_skips_transform_test() {
  let assert Ok(sess) = session.open_memory(clock.fixed(at: 1000))
  let projection =
    session.projection()
    |> session.with_transform(fn(_) { [messages.user_text("injected")] })
  let assert Ok(projected) = session.project(sess, None, projection)
  assert projected == []
}

// --- orphan-call healing ---------------------------------------------------

pub fn orphaned_call_is_healed_test() {
  let call = messages.tool_call(1, json.Object([]))
  let assistant = messages.assistant_msg(2, message.ToolUse, [call])
  let assert Ok(sess) = session.open_memory(clock.fixed(at: 1000))
  let ctx = drive.new_ctx(sess, 15)
  let #(ctx, _) = drive.append_message(ctx, messages.user_msg(1))
  let #(ctx, _) = drive.append_message(ctx, assistant)
  let assert Ok(projected) = session.project_context(sess, ctx.leaf)
  let assert [_user, _assistant, healed] = projected
  let assert message.ToolResultMessage(
    tool_call_id: "call-1",
    tool_name: "tool-1",
    is_error: True,
    ..,
  ) = healed
}

pub fn healed_result_sits_directly_after_its_assistant_test() {
  let call = messages.tool_call(1, json.Object([]))
  let assistant = messages.assistant_msg(2, message.ToolUse, [call])
  let assert Ok(sess) = session.open_memory(clock.fixed(at: 1000))
  let ctx = drive.new_ctx(sess, 16)
  let #(ctx, _) = drive.append_message(ctx, messages.user_msg(1))
  let #(ctx, _) = drive.append_message(ctx, assistant)
  // A later user message follows the orphan; the synthetic result must be
  // inserted between the assistant message and it.
  let #(ctx, _) = drive.append_message(ctx, messages.user_msg(3))
  let assert Ok(projected) = session.project_context(sess, ctx.leaf)
  let assert [_, projected_assistant, healed, last] = projected
  assert projected_assistant == assistant
  let assert message.ToolResultMessage(tool_call_id: "call-1", ..) = healed
  assert last == messages.user_msg(3)
}

pub fn present_result_is_not_healed_test() {
  let call = messages.tool_call(1, json.Object([]))
  let assistant = messages.assistant_msg(2, message.ToolUse, [call])
  let result = messages.tool_result(call, 3)
  let assert Ok(sess) = session.open_memory(clock.fixed(at: 1000))
  let ctx = drive.new_ctx(sess, 17)
  let #(ctx, _) = drive.append_message(ctx, messages.user_msg(1))
  let #(ctx, _) = drive.append_message(ctx, assistant)
  let #(ctx, _) = drive.append_message(ctx, result)
  let assert Ok(projected) = session.project_context(sess, ctx.leaf)
  assert projected == [messages.user_msg(1), assistant, result]
}

pub fn partially_settled_batch_heals_only_the_missing_call_test() {
  let call_a = messages.tool_call(1, json.Object([]))
  let call_b = messages.tool_call(2, json.Object([]))
  let assistant = messages.assistant_msg(3, message.ToolUse, [call_a, call_b])
  let result_a = messages.tool_result(call_a, 4)
  let healed =
    session.project_entries(
      scan_of([assistant, result_a]),
      session.projection(),
    )
  let assert [projected_assistant, synthetic, projected_result] = healed
  assert projected_assistant == assistant
  let assert message.ToolResultMessage(
    tool_call_id: "call-2",
    is_error: True,
    ..,
  ) = synthetic
  assert projected_result == result_a
}

// Builds the newest-first entry list a branch scan returns for a linear
// chain of the given messages.
fn scan_of(messages: List(AgentMessage)) -> List(Entry) {
  let assert Ok(sess) = session.open_memory(clock.fixed(at: 1000))
  let ctx = drive.new_ctx(sess, 99)
  let ctx =
    list.fold(over: messages, from: ctx, with: fn(ctx, message) {
      let #(ctx, _) = drive.append_message(ctx, message)
      ctx
    })
  let assert Some(start) = ctx.leaf
  let assert Ok(entries) =
    storage.scan_branch(sess.store, storage.branch_scan(from: start))
  entries
}

// --- the append-only context invariant (generated property) ---------------

/// How many generated sessions the invariant is checked over (the
/// hand-seeded sweep it replaced drew 30), and the seed they are drawn from.
/// The seed is fixed so the gate is deterministic. A session is up to
/// fourteen settled turns.
const session_count = 100

const session_seed = 17

const longest_session = 14

/// One settled turn. The kinds are ordered from the plainest (a user message)
/// to the most disruptive (a compaction), so a failing session shrinks to
/// fewer turns, each a user message, with only the turns that matter left
/// disruptive.
type Turn {
  UserTurn
  AssistantStop
  AssistantErrored
  ToolRoundTrip
  Note
  Shadow
  Compaction
}

fn turn_generator() -> qcheck.Generator(Turn) {
  qcheck.from_generators(qcheck.constant(UserTurn), [
    qcheck.constant(AssistantStop),
    qcheck.constant(AssistantErrored),
    qcheck.constant(ToolRoundTrip),
    qcheck.constant(Note),
    qcheck.constant(Shadow),
    qcheck.constant(Compaction),
  ])
}

// The session under test and the projection taken after the last turn.
type Scenario {
  Scenario(ctx: drive.Ctx, previous: List(AgentMessage))
}

fn new_scenario() -> Scenario {
  let assert Ok(sess) = session.open_memory(clock.fixed(at: 1000))
    as "an in-memory session always opens"
  Scenario(ctx: drive.new_ctx(sess, 4242), previous: [])
}

fn spec() -> statem.Spec(Nil, Turn, Scenario) {
  statem.Spec(
    initial: Nil,
    command: fn(_) { turn_generator() },
    precondition: fn(_, _) { statem.Admit },
    next_model: fn(model, _) { model },
    new_sut: new_scenario,
    execute: step_turn,
    finish: fn(_, _) { Ok(Nil) },
    teardown: fn(_) { Nil },
  )
}

pub fn append_only_context_invariant_property_test() {
  let config =
    statem.default_config(seed: session_seed)
    |> statem.with_test_count(session_count)
    |> statem.with_max_commands(longest_session)
  case statem.check(spec(), config) {
    Ok(Nil) -> Nil
    Error(failure) -> panic as statem.report(failure, string.inspect)
  }
}

// One settled turn: append a complete unit (a user turn, a settled
// assistant turn with all its tool results, a custom entry, or a
// compaction), then project and hold the invariant. Projections happen at
// request-construction points — settled histories — which is exactly
// where pi defines the invariant: mid-batch states never construct a
// request, so they never produce a projection.
fn step_turn(
  scenario: Scenario,
  _model: Nil,
  turn: Turn,
) -> Result(Scenario, statem.Violation) {
  let Scenario(ctx:, previous:) = scenario
  let #(ctx, n) = drive.tick(ctx)
  let ctx = append_turn(ctx, n, turn, previous)
  case session.project(ctx.session, ctx.leaf, note_projection()) {
    Error(_) ->
      Error(statem.Violation(
        tag: "projection",
        detail: "the session could not be projected after "
          <> string.inspect(turn),
      ))
    Ok(projected) ->
      case turn, is_prefix(of: projected, prefix: previous) {
        // Compaction is the one deliberate cache invalidation.
        Compaction, _ | _, True -> Ok(Scenario(ctx:, previous: projected))
        _, False ->
          Error(statem.Violation(
            tag: "append_only",
            detail: "previous projection ("
              <> int.to_string(list.length(previous))
              <> " messages) is not a prefix of the next ("
              <> int.to_string(list.length(projected))
              <> ")",
          ))
      }
  }
}

fn append_turn(
  ctx: drive.Ctx,
  n: Int,
  turn: Turn,
  previous: List(AgentMessage),
) -> drive.Ctx {
  case turn {
    UserTurn -> drive.append_message(ctx, messages.user_msg(n)).0
    AssistantStop ->
      drive.append_message(ctx, messages.assistant_msg(n, message.Stop, [])).0

    // Dropped from context by the standard rule; the projection must still
    // only grow (here: stay identical).
    AssistantErrored ->
      drive.append_message(ctx, messages.assistant_msg(n, message.Errored, [])).0
    ToolRoundTrip -> {
      let call = messages.tool_call(n, json.Object([]))
      let #(ctx, _) =
        drive.append_message(
          ctx,
          messages.assistant_msg(n, message.ToolUse, [call]),
        )
      drive.append_message(ctx, messages.tool_result(call, n)).0
    }
    Note ->
      drive.append_custom(ctx, "note", Some(json.String(int.to_string(n)))).0
    Shadow -> drive.append_custom(ctx, "shadow", None).0
    Compaction -> {
      let tail = list.drop(previous, int.max(0, list.length(previous) - 2))
      drive.append_compaction(ctx, "summary-" <> int.to_string(n), tail).0
    }
  }
}

fn is_prefix(
  of longer: List(AgentMessage),
  prefix prefix: List(AgentMessage),
) -> Bool {
  case prefix, longer {
    [], _ -> True
    [_, ..], [] -> False
    [first, ..rest_prefix], [head, ..rest] ->
      first == head && is_prefix(of: rest, prefix: rest_prefix)
  }
}
