//// Agent presentation must retain identity and distinguish captured evidence
//// from a missing observation. Interaction tests drive the real input reducer.

import core/clock
import core/entry
import core/ids
import core/json
import core/message
import core/register
import etui/backend
import etui/buffer
import etui/geometry
import etui/widgets/textarea
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/codec
import machine/operation
import machine/strand
import tui
import tui/advisor_pending
import tui/agent_view
import tui/agents
import tui/composer
import tui/connection
import tui/frame
import tui/protocol
import tui/reviewer_status
import tui/session_channel
import tui/snapshot
import tui/snapshot_view
import tui/workspace
import tui/worktree_view

fn model() {
  tui.new_model_with_clock(
    connection.new_inbox(),
    workspace.Context("/work", None),
    fn() { 0 },
  )
}

fn op_id(n) {
  ids.mint_op(ids.generator(clock.fixed(n), n)).0
}

fn entry_id(n) {
  ids.mint_entry(ids.generator(clock.fixed(n), n)).0
}

fn empty_view() {
  snapshot_view.View(
    [protocol.Strand("main", Some("main"), None)],
    dict.new(),
    dict.new(),
    dict.new(),
    model().usage,
    snapshot_view.RunSettings("one_at_a_time", "parallel", None),
    [],
    [],
    None,
    Some([]),
    None,
  )
}

fn state(control, phase, latest) {
  operation.RunState(
    control,
    operation.RunSettings(
      operation.CompactionSettings(False, 0, 0),
      operation.ConsumeAll,
      operation.ConsumeAll,
      operation.Parallel,
    ),
    phase,
    operation.Inbox([], [], []),
    latest,
  )
}

fn live_view(control, latest) {
  let current = ids.op_id_to_string(op_id(1))
  snapshot_view.View(
    ..empty_view(),
    strands: [protocol.Strand("main", Some("main"), Some("starting"))],
    operations: dict.from_list([#("main", current)]),
    cells: [
      snapshot_view.Cell(
        register.OpState,
        current,
        1,
        codec.encode_state(state(control, operation.Starting, latest)),
      ),
    ],
  )
}

fn terminal_view(outcome, final) {
  snapshot_view.View(..empty_view(), cells: [
    snapshot_view.Cell(
      register.StrandLastResult,
      "main",
      3,
      codec.encode_last_result(operation.RunLastResult(
        op_id(1),
        final,
        outcome,
        final,
      )),
    ),
  ])
}

fn observe(previous, view, items) {
  let window = snapshot.Window(items, 0, None)
  agent_view.observe(
    previous,
    window,
    view,
    reviewer_status.observe([], window, view),
  )
}

fn only(rows) {
  let assert [row] = rows as "the fixture has exactly one agent"
  row
}

pub fn terminal_evidence_is_required_for_success_and_failure_test() {
  let unknown = agent_view.legacy(empty_view().strands) |> only
  assert unknown.status == agent_view.Unavailable
  assert observe([], empty_view(), []) |> only |> fn(row) { row.status }
    == agent_view.Idle
  let cases = [
    #(
      operation.RunCompleted(operation.CompletedByAssistant),
      agent_view.Finished,
    ),
    #(
      operation.RunFailed(operation.OperationError(
        "provider",
        "unavailable",
        None,
      )),
      agent_view.Failed,
    ),
    #(operation.RunAborted, agent_view.Halted),
  ]
  list.each(cases, fn(pair) {
    assert only(observe([], terminal_view(pair.0, None), [])).status == pair.1
  })
  let malformed =
    snapshot_view.View(..empty_view(), cells: [
      snapshot_view.Cell(register.StrandLastResult, "main", 1, json.Null),
    ])
  assert only(observe([], malformed, [])).status == agent_view.Unavailable
}

pub fn missing_state_and_pending_input_are_not_invented_work_or_questions_test() {
  let live = live_view(operation.Running, None)
  let unknown = snapshot_view.View(..live, cells: [], pending_inputs: None)
  let row = only(observe([], unknown, []))
  assert row.status == agent_view.Unavailable
  assert row.pending == "Pending input unknown"
  let pending =
    Some([
      snapshot_view.PendingInput(
        "i",
        "main",
        snapshot_view.Queue,
        "please inspect this",
        2,
        snapshot_view.ReadOnly,
      ),
    ])
  let running =
    only(observe([], snapshot_view.View(..live, pending_inputs: pending), []))
  assert running.status == agent_view.Working
  assert running.pending == "1 received, awaiting delivery"
  let halted =
    only(
      observe(
        [],
        snapshot_view.View(..empty_view(), pending_inputs: pending),
        [],
      ),
    )
  assert halted.status == agent_view.Halted
  assert string.contains(halted.activity, "held")
  let stopping =
    only(observe([], live_view(operation.CancelRequested(2, [], []), None), []))
  assert stopping.activity == "Stopping"
}

fn assistant() {
  entry.MessageEntry(
    entry_id(2),
    None,
    2,
    2,
    message.AssistantMessage(
      [message.AssistantText("The recovered test now passes.", None)],
      "test",
      "test",
      "test",
      None,
      None,
      None,
      model().usage,
      message.Stop,
      None,
      None,
      None,
      None,
      2,
    ),
    False,
  )
}

pub fn latest_update_belongs_to_the_operation_and_survives_only_eviction_test() {
  let current = live_view(operation.Running, Some(entry_id(2)))
  let first = observe([], current, [snapshot.Loaded(assistant(), 20)])
  assert only(first).update == "The recovered test now passes."
  assert only(observe(first, current, [])).update == only(first).update
  assert only(
      observe(first, live_view(operation.Running, Some(entry_id(3))), []),
    ).update
    == "Latest update unavailable"
  let successor =
    snapshot_view.View(
      ..current,
      operations: dict.from_list([#("main", "successor")]),
      cells: [],
    )
  assert only(observe(first, successor, [])).update
    == "Latest update unavailable"
  assert only(observe(first, terminal_view(operation.RunAborted, None), [])).update
    == "Latest update unavailable"
}

fn permission(owner, current) {
  snapshot_view.Cell(
    register.FactCustom,
    "escalation/permission",
    7,
    json.Object([
      #("id", json.String("permission")),
      #("status", json.String("pending")),
      #("tool", json.String("fs_write")),
      #("preview", json.String("write report")),
      #("action", json.String("captured-action")),
      #("origin", json.Null),
      #("denial", json.Object([#("wanted", json.Array([]))])),
      #(
        "scope",
        json.Object([
          #("strand", json.String(owner)),
          #("operation", json.String(current)),
        ]),
      ),
    ]),
  )
}

pub fn attention_requires_an_exact_pending_approval_for_this_operation_test() {
  let view = live_view(operation.Running, None)
  let current = ids.op_id_to_string(op_id(1))
  let own =
    snapshot_view.View(..view, cells: [
      permission("main", current),
      ..view.cells
    ])
  let row = only(observe([], own, []))
  assert row.status == agent_view.NeedsInput
  assert row.approvals == ["permission"]
  list.each([#("other", current), #("main", "previous")], fn(pair) {
    let unrelated =
      snapshot_view.View(..view, cells: [
        permission(pair.0, pair.1),
        ..view.cells
      ])
    assert only(observe([], unrelated, [])).status == agent_view.Working
  })
}

fn roster() {
  [
    protocol.Strand("main", Some("main"), None),
    protocol.Strand(
      "worker",
      Some("Review scheduler ownership"),
      Some("assistant"),
    ),
  ]
}

fn press(model, key) {
  tui.update(backend.KeyPress(key), model)
}

pub fn inspection_keeps_the_recipient_and_opening_restores_each_draft_test() {
  let initial =
    tui.Model(
      ..model(),
      strands: roster(),
      input: textarea.state_from_string("main draft"),
      attachments: [composer.Attachment("attached main context", 5)],
      submission_mode: tui.SteerNow,
    )
  let inspected = initial |> press("f2") |> press("down")
  assert inspected.active_strand == "main"
  assert inspected.input == initial.input
  assert inspected.attachments == initial.attachments
  let worker = inspected |> press("enter")
  assert worker.active_strand == "worker"
  assert textarea.value(worker.input) == ""
  assert worker.attachments == []
  assert worker.submission_mode == tui.PromptNext
  let worker = worker |> press("w")
  let returned = worker |> press("f2") |> press("up") |> press("enter")
  assert returned.active_strand == "main"
  assert returned.input == initial.input
  assert returned.attachments == initial.attachments
  assert returned.submission_mode == tui.SteerNow
  let reopened = returned |> press("f2") |> press("down") |> press("enter")
  assert textarea.value(reopened.input) == "w"
}

pub fn selection_survives_insertion_and_removal_cannot_retarget_a_draft_test() {
  let initial =
    tui.Model(
      ..model(),
      strands: roster(),
      input: textarea.state_from_string("keep me"),
    )
  let inspected = initial |> press("f2") |> press("down")
  let inserted =
    tui.Model(..inspected, strands: [
      protocol.Strand("earlier", None, None),
      ..roster()
    ])
  let assert tui.AgentInspector(selection) = inserted.overlay
    as "the workspace remains open"
  assert selection.selected == "worker"
  let removed =
    tui.Model(..inserted, strands: [protocol.Strand("main", None, None)])
    |> press("enter")
  assert removed.active_strand == "main"
  assert removed.input == initial.input
  let navigated = removed |> press("down")
  let assert tui.AgentInspector(selection) = navigated.overlay
    as "missing selection remains navigable"
  assert selection.selected == "main"
}

pub fn compact_pending_nudges_keep_all_lines_in_the_scrollable_tail_test() {
  let body = "first line\nsecond line\nlast visible instruction"
  let initial =
    tui.Model(
      ..model(),
      strands: [],
      nudges: Some(advisor_pending.Board("main", 1, [body], 1)),
      details_expanded: False,
    )
  let rendered = tui.update(backend.Resize(100, 30), initial)
  let text =
    tui.view(rendered, geometry.rect_new(0, 0, 100, 30)).0
    |> frame.buffer_to_text
  assert string.contains(text, "pending, not delivered")
  assert string.contains(text, "first line")
  assert string.contains(text, "second line")
  assert string.contains(text, "last visible instruction")
}

pub fn workspace_is_opaque_and_navigable_at_narrow_and_short_sizes_test() {
  let rows = agent_view.legacy(roster())
  list.each(
    [#(40, 12), #(80, 24), #(100, 30), #(116, 38), #(160, 50)],
    fn(size) {
      let screen = geometry.rect_new(0, 0, size.0, size.1)
      let underlying = buffer.buffer_new(screen)
      let painted =
        agents.render_overlay(
          underlying,
          screen,
          rows,
          "main",
          agents.inspect("worker"),
        )
      let text = frame.buffer_to_text(painted)
      assert string.contains(text, "↑/↓ inspect")
      assert string.contains(text, "To: main")
      assert string.contains(text, "▸")
    },
  )
}

pub fn only_captured_retry_or_deferred_state_claims_a_wait_test() {
  let config =
    strand.StrandConfiguration(
      strand.ModelIdentity("test", "test"),
      strand.ThinkingOff,
      [],
    )
  let context =
    operation.GenerationContext(
      "step",
      entry_id(2),
      config,
      json.Object([]),
      operation.NormalizedRetryPolicy(operation.Bounded(3), 100, 1000),
      False,
    )
  let phases = [
    operation.Assistant(operation.GenerationRetryWait(context, 2, 1000, "retry")),
    operation.AwaitingDeferred(operation.DeferredSuspended(
      "step",
      entry_id(2),
      1,
      config,
      json.Object([]),
    )),
  ]
  let view = live_view(operation.Running, None)
  list.each(phases, fn(phase) {
    let waiting =
      snapshot_view.View(..view, cells: [
        snapshot_view.Cell(
          register.OpState,
          ids.op_id_to_string(op_id(1)),
          1,
          codec.encode_state(state(operation.Running, phase, None)),
        ),
      ])
    assert only(observe([], waiting, [])).status == agent_view.Waiting
  })
  assert only(observe([], view, [])).status == agent_view.Working
}

pub fn a_disappeared_recipient_is_retained_and_cannot_accept_a_prompt_test() {
  let initial =
    tui.Model(
      ..model(),
      input: textarea.state_from_string("private draft for main"),
    )
  let cut =
    snapshot.Captured(
      snapshot.Attachment(
        snapshot.Expected(initial.session, "epoch", "instance"),
        "peer",
        message.Origin("operator", "Operator"),
        snapshot.Owner,
      ),
      1,
      json.Object([]),
      snapshot.empty(),
      None,
    )
  let removed =
    snapshot_view.View(..empty_view(), strands: [
      protocol.Strand("worker", None, None),
    ])
  let captured =
    tui.apply_channel_update(
      initial,
      session_channel.Captured(cut, removed, session_channel.Notified),
    )
  assert captured.active_strand == "main"
  let refused = captured |> press("enter")
  assert refused.input == initial.input
  assert refused.active_strand == "main"
  assert refused.pending_submission == None
  assert refused.queued == []
  let text =
    tui.view(refused, geometry.rect_new(0, 0, refused.width, refused.height)).0
    |> frame.buffer_to_text
  assert string.contains(text, "recipient unavailable")
}

pub fn task_on_initial_terminal_capture_uses_its_acceptance_metadata_test() {
  let id = entry_id(3)
  let prompt =
    entry.MessageEntry(
      id,
      None,
      3,
      3,
      message.UserMessage(
        [message.UserText("Verify viewport ownership", None)],
        3,
        None,
      ),
      False,
    )
  let view =
    terminal_view(operation.RunCompleted(operation.CompletedByAssistant), None)
  let view =
    snapshot_view.View(..view, cells: [
      snapshot_view.Cell(
        register.OpMeta,
        ids.op_id_to_string(op_id(1)),
        1,
        codec.encode_operation(operation.Operation(
          op_id(1),
          "main",
          None,
          1,
          operation.RunIntent([id]),
        )),
      ),
      ..view.cells
    ])
  assert only(observe([], view, [snapshot.Loaded(prompt, 20)])).task
    == "Verify viewport ownership"
}

// Terminal evidence wins over a journal record whose waiter has already gone.
pub fn terminal_operations_do_not_inherit_stale_approval_attention_test() {
  list.each(
    [
      #(
        operation.RunCompleted(operation.CompletedByAssistant),
        agent_view.Finished,
      ),
      #(
        operation.RunFailed(operation.OperationError("tool", "timed out", None)),
        agent_view.Failed,
      ),
      #(operation.RunAborted, agent_view.Halted),
    ],
    fn(pair) {
      let view = terminal_view(pair.0, None)
      let view =
        snapshot_view.View(..view, cells: [
          permission("main", ids.op_id_to_string(op_id(1))),
          ..view.cells
        ])
      let row = only(observe([], view, []))
      assert row.status == pair.1
      assert row.approvals == []
    },
  )
}

pub fn returned_input_keeps_its_owner_while_another_draft_is_open_test() {
  let initial =
    tui.Model(
      ..model(),
      strands: roster(),
      input: textarea.state_from_string("main draft"),
    )
  let worker = initial |> press("f2") |> press("down") |> press("enter")
  let worker =
    tui.Model(..worker, input: textarea.state_from_string("worker draft"))
  let returned =
    tui.apply_channel_update(
      worker,
      session_channel.Auxiliary(protocol.HeldInputReturned(
        strand: "main",
        id: "held",
        kind: "queue",
        text: "returned main prompt",
        attachment_count: 0,
      )),
    )
  assert textarea.value(returned.input) == "worker draft"
  assert returned.active_strand == "worker"
  let main = returned |> press("f2") |> press("up") |> press("enter")
  assert textarea.value(main.input) == "main draft\n\nreturned main prompt"
}

pub fn editing_inside_the_workspace_keeps_the_original_recipient_test() {
  let initial =
    tui.Model(
      ..model(),
      strands: roster(),
      input: textarea.state_from_string("main draft"),
    )
  let inspected =
    initial |> press("f2") |> press("down") |> press("tab") |> press("!")
  assert inspected.active_strand == "main"
  assert textarea.value(inspected.input) == "main draft!"
  let assert tui.AgentInspector(inspector) = inspected.overlay
    as "the composer remains inside the agent workspace"
  assert inspector.selected == "worker"
  assert inspector.focus == agents.Composing
  let navigated = inspected |> press("esc") |> press("up")
  assert navigated.active_strand == "main"
  assert textarea.value(navigated.input) == "main draft!"
  let assert tui.AgentInspector(inspector) = navigated.overlay
    as "Escape returned keyboard ownership to inspection"
  assert inspector.selected == "main"
}

pub fn workspace_preserves_recipient_controls_and_attention_at_small_sizes_test() {
  list.each(
    [#(40, 12), #(80, 24), #(100, 30), #(116, 38), #(160, 50)],
    fn(size) {
      let initial =
        tui.Model(
          ..model(),
          strands: roster(),
          input: textarea.state_from_string("retained draft"),
        )
        |> tui.update(backend.Resize(size.0, size.1), _)
        |> press("f2")
      let rendered =
        tui.view(initial, geometry.rect_new(0, 0, size.0, size.1)).0
        |> frame.buffer_to_text
      assert string.contains(rendered, "To main")
      assert string.contains(rendered, "attention")
      assert string.contains(rendered, "retained draft")
      let editing = initial |> press("tab")
      let rendered =
        tui.view(editing, geometry.rect_new(0, 0, size.0, size.1)).0
        |> frame.buffer_to_text
      assert string.contains(rendered, "enter")
      assert editing.active_strand == "main"
    },
  )
}

pub fn approval_detail_keeps_its_captured_preview_and_no_default_decision_test() {
  let view = live_view(operation.Running, None)
  let current = ids.op_id_to_string(op_id(1))
  let own =
    snapshot_view.View(..view, cells: [
      permission("main", current),
      ..view.cells
    ])
  let row = only(observe([], own, []))
  assert row.decision == "fs_write · write report"
  let screen = geometry.rect_new(0, 0, 116, 38)
  let rendered =
    agents.render_overlay(
      buffer.buffer_new(screen),
      screen,
      [row],
      "main",
      agents.inspect("main"),
    )
    |> frame.buffer_to_text
  assert string.contains(rendered, "PERMISSION NEEDED")
  assert string.contains(rendered, "write report")
  assert string.contains(rendered, "Nothing is approved here")
}

// Tab transfers keyboard ownership out of any previously visible surface.
pub fn workspace_typing_leaves_the_hidden_diff_navigator_test() {
  let initial =
    tui.Model(..model(), strands: roster(), diff_view: tui.DiffVisible)
    |> press("ctrl+d")
  assert initial.worktree.focus == worktree_view.Navigator
  let editing = initial |> press("f2") |> press("tab") |> press("x")
  assert editing.worktree.focus == worktree_view.Composer
  assert textarea.value(editing.input) == "x"
  let navigating = editing |> press("ctrl+d")
  assert navigating.overlay == tui.NoOverlay
  assert navigating.worktree.focus == worktree_view.Navigator
}

pub fn workspace_commands_expose_the_surface_that_owns_the_next_key_test() {
  list.each(
    ["/help", "/notes", "/diff", "/context", "/queue", "/summary"],
    fn(command) {
      let editing = model() |> press("f2") |> press("tab")
      let opened =
        tui.Model(..editing, input: textarea.state_from_string(command))
        |> press("enter")
      assert opened.overlay == tui.NoOverlay as command
    },
  )
  let previous = tui.Model(..model(), help_open: True)
  let editing = previous |> press("f2") |> press("tab") |> press("x")
  assert !editing.help_open
  assert textarea.value(editing.input) == "x"
}

// The identity row must remain useful in a deeply nested worktree.
pub fn long_checkout_paths_do_not_hide_the_session_identity_test() {
  let initial =
    tui.Model(
      ..model(),
      workspace: workspace.Context(
        "/work/" <> string.repeat("nested/", 30),
        None,
      ),
      session: "review-session",
      current_model: "provider/model",
    )
    |> tui.update(backend.Resize(80, 24), _)
  let header =
    tui.view(initial, geometry.rect_new(0, 0, 80, 24)).0
    |> frame.buffer_to_text
    |> string.split("\n")
    |> list.first
  let assert Ok(header) = header as "a terminal has a header"
  assert string.contains(header, "review-session")
  assert string.contains(header, "provider/model")
}

pub fn tiny_workspace_keeps_selected_identity_and_navigation_visible_test() {
  let initial =
    tui.Model(
      ..model(),
      strands: roster(),
      input: textarea.state_from_string("retained draft"),
    )
    |> tui.update(backend.Resize(40, 12), _)
    |> press("f2")
    |> press("down")
  let rendered =
    tui.view(
      tui.Model(..initial, frame_cache: None),
      geometry.rect_new(0, 0, 40, 12),
    ).0
    |> frame.buffer_to_text
  assert string.contains(rendered, "Review scheduler")
  assert string.contains(rendered, "inspect")
  assert string.contains(rendered, "To main")
  assert string.contains(rendered, "retained draft")
}
