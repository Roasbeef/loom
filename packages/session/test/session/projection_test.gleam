//// The full projection pipeline (pi §2.5): custom-entry projectors, the
//// `transform_context` hook seam, orphan-call healing, and the
//// append-only context invariant as a seeded property — across a
//// strand's successive projections, the prior projection is a prefix of
//// the next except across a compaction.

import core/clock
import core/entry.{type Entry}
import core/json
import core/message.{type AgentMessage}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import session/session
import storage/storage
import support/drive
import support/generate

// The projection every test here uses: "note" customs project to user
// messages; other custom types stay out of context.
fn note_projection() -> session.Projection {
  session.projection()
  |> session.with_projector("note", fn(view) {
    case view.data {
      Some(json.String(text)) -> Some(generate.user_text("note:" <> text))
      Some(_) | None -> None
    }
  })
}

// --- projectors and the transform hook ------------------------------------

pub fn registered_projector_enters_context_test() {
  let assert Ok(sess) = session.open_memory(clock.fixed(at: 1000))
  let ctx = drive.new_ctx(sess, 11)
  let #(ctx, _) = drive.append_message(ctx, generate.user_msg(1))
  let #(ctx, _) = drive.append_custom(ctx, "note", Some(json.String("hello")))
  let assert Ok(projected) = session.project(sess, ctx.leaf, note_projection())
  assert projected == [generate.user_msg(1), generate.user_text("note:hello")]
}

pub fn unregistered_custom_is_skipped_test() {
  let assert Ok(sess) = session.open_memory(clock.fixed(at: 1000))
  let ctx = drive.new_ctx(sess, 12)
  let #(ctx, _) = drive.append_message(ctx, generate.user_msg(1))
  let #(ctx, _) =
    drive.append_custom(ctx, "unknown", Some(json.String("hidden")))
  let assert Ok(projected) = session.project(sess, ctx.leaf, note_projection())
  assert projected == [generate.user_msg(1)]
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
  let #(ctx, _) = drive.append_message(ctx, generate.user_msg(1))
  let #(ctx, _) = drive.append_custom(ctx, "note", Some(json.String("x")))
  let marker = generate.user_text("appended-by-transform")
  let projection =
    note_projection()
    |> session.with_transform(fn(messages) { list.append(messages, [marker]) })
  let assert Ok(projected) = session.project(sess, ctx.leaf, projection)
  // The transform saw the projector's output — it ran after every other
  // rule.
  assert projected
    == [generate.user_msg(1), generate.user_text("note:x"), marker]
}

pub fn empty_leaf_skips_transform_test() {
  let assert Ok(sess) = session.open_memory(clock.fixed(at: 1000))
  let projection =
    session.projection()
    |> session.with_transform(fn(_) { [generate.user_text("injected")] })
  let assert Ok(projected) = session.project(sess, None, projection)
  assert projected == []
}

// --- orphan-call healing ---------------------------------------------------

pub fn orphaned_call_is_healed_test() {
  let call = generate.tool_call(1, json.Object([]))
  let assistant = generate.assistant_msg(2, message.ToolUse, [call])
  let assert Ok(sess) = session.open_memory(clock.fixed(at: 1000))
  let ctx = drive.new_ctx(sess, 15)
  let #(ctx, _) = drive.append_message(ctx, generate.user_msg(1))
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
  let call = generate.tool_call(1, json.Object([]))
  let assistant = generate.assistant_msg(2, message.ToolUse, [call])
  let assert Ok(sess) = session.open_memory(clock.fixed(at: 1000))
  let ctx = drive.new_ctx(sess, 16)
  let #(ctx, _) = drive.append_message(ctx, generate.user_msg(1))
  let #(ctx, _) = drive.append_message(ctx, assistant)
  // A later user message follows the orphan; the synthetic result must be
  // inserted between the assistant message and it.
  let #(ctx, _) = drive.append_message(ctx, generate.user_msg(3))
  let assert Ok(projected) = session.project_context(sess, ctx.leaf)
  let assert [_, projected_assistant, healed, last] = projected
  assert projected_assistant == assistant
  let assert message.ToolResultMessage(tool_call_id: "call-1", ..) = healed
  assert last == generate.user_msg(3)
}

pub fn present_result_is_not_healed_test() {
  let call = generate.tool_call(1, json.Object([]))
  let assistant = generate.assistant_msg(2, message.ToolUse, [call])
  let result = generate.tool_result(call, 3)
  let assert Ok(sess) = session.open_memory(clock.fixed(at: 1000))
  let ctx = drive.new_ctx(sess, 17)
  let #(ctx, _) = drive.append_message(ctx, generate.user_msg(1))
  let #(ctx, _) = drive.append_message(ctx, assistant)
  let #(ctx, _) = drive.append_message(ctx, result)
  let assert Ok(projected) = session.project_context(sess, ctx.leaf)
  assert projected == [generate.user_msg(1), assistant, result]
}

pub fn partially_settled_batch_heals_only_the_missing_call_test() {
  let call_a = generate.tool_call(1, json.Object([]))
  let call_b = generate.tool_call(2, json.Object([]))
  let assistant = generate.assistant_msg(3, message.ToolUse, [call_a, call_b])
  let result_a = generate.tool_result(call_a, 4)
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

// --- the append-only context invariant (seeded property) -------------------

pub fn append_only_context_invariant_property_test() {
  list.each(generate.range(from: 1, to: 30), fn(seed_n) {
    run_append_only_scenario(generate.seed(seed_n))
  })
}

type Scenario {
  Scenario(ctx: drive.Ctx, seed: generate.Seed, previous: List(AgentMessage))
}

fn run_append_only_scenario(seed: generate.Seed) -> Nil {
  let assert Ok(sess) = session.open_memory(clock.fixed(at: 1000))
  let #(turns, seed) = generate.int_between(seed, 8, 14)
  let scenario = Scenario(ctx: drive.new_ctx(sess, 4242), seed:, previous: [])
  let _ =
    list.fold(
      over: generate.range(from: 1, to: turns),
      from: scenario,
      with: fn(scenario, _turn) { step_turn(scenario) },
    )
  Nil
}

// One settled turn: append a complete unit (a user turn, a settled
// assistant turn with all its tool results, a custom entry, or a
// compaction), then project and hold the invariant. Projections happen at
// request-construction points — settled histories — which is exactly
// where pi defines the invariant: mid-batch states never construct a
// request, so they never produce a projection.
fn step_turn(scenario: Scenario) -> Scenario {
  let Scenario(ctx:, seed:, previous:) = scenario
  let #(kind, seed) = generate.int_between(seed, 0, 6)
  let #(ctx, n) = drive.tick(ctx)
  let #(ctx, compacted) = case kind {
    0 -> {
      let #(ctx, _) = drive.append_message(ctx, generate.user_msg(n))
      #(ctx, False)
    }
    1 -> {
      let #(ctx, _) =
        drive.append_message(ctx, generate.assistant_msg(n, message.Stop, []))
      #(ctx, False)
    }
    2 -> {
      // Dropped from context by the standard rule; the projection must
      // still only grow (here: stay identical).
      let #(ctx, _) =
        drive.append_message(
          ctx,
          generate.assistant_msg(n, message.Errored, []),
        )
      #(ctx, False)
    }
    3 -> {
      let call = generate.tool_call(n, json.Object([]))
      let #(ctx, _) =
        drive.append_message(
          ctx,
          generate.assistant_msg(n, message.ToolUse, [call]),
        )
      let #(ctx, _) = drive.append_message(ctx, generate.tool_result(call, n))
      #(ctx, False)
    }
    4 -> {
      let #(ctx, _) =
        drive.append_custom(ctx, "note", Some(json.String(int.to_string(n))))
      #(ctx, False)
    }
    5 -> {
      let #(ctx, _) = drive.append_custom(ctx, "shadow", None)
      #(ctx, False)
    }
    _ -> {
      let tail = list.drop(previous, int.max(0, list.length(previous) - 2))
      let #(ctx, _) =
        drive.append_compaction(ctx, "summary-" <> int.to_string(n), tail)
      #(ctx, True)
    }
  }
  let assert Ok(projected) =
    session.project(ctx.session, ctx.leaf, note_projection())
  case compacted {
    // Compaction is the one deliberate cache invalidation.
    True -> Nil
    False ->
      case is_prefix(of: projected, prefix: previous) {
        True -> Nil
        False ->
          panic as {
            "append-only invariant violated: previous projection ("
            <> int.to_string(list.length(previous))
            <> " messages) is not a prefix of the next ("
            <> int.to_string(list.length(projected))
            <> ")"
          }
      }
  }
  Scenario(ctx:, seed:, previous: projected)
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
