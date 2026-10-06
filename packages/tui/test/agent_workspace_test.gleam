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
import session_view/advisor_pending
import session_view/agent_messages
import session_view/agent_view
import session_view/composer
import session_view/protocol
import session_view/reviewer_status
import session_view/session_channel
import session_view/shared_set
import session_view/snapshot
import session_view/snapshot_view
import session_view/worktree_view
import tui
import tui/agent_message_panel
import tui/agents
import tui/connection
import tui/frame
import tui/inbound
import tui/model as tui_model
import tui/render
import tui/view_set
import tui/workspace

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
    model().shared.usage,
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
      model().shared.usage,
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
  let initial = {
    let base = model()
    tui_model.Model(
      shared: base.shared
        |> shared_set.strands(roster())
        |> shared_set.attachments([
          composer.Attachment("attached main context", 5),
        ]),
      view: base.view
        |> view_set.input(textarea.state_from_string("main draft"))
        |> view_set.submission_mode(tui_model.SteerNow),
    )
  }
  let inspected = initial |> press("f2") |> press("down")
  assert inspected.shared.active_strand == "main"
  assert inspected.view.input == initial.view.input
  assert inspected.shared.attachments == initial.shared.attachments
  let worker = inspected |> press("enter")
  assert worker.shared.active_strand == "worker"
  assert textarea.value(worker.view.input) == ""
  assert worker.shared.attachments == []
  assert worker.view.submission_mode == tui_model.PromptNext
  let worker = worker |> press("w")
  let returned = worker |> press("f2") |> press("up") |> press("enter")
  assert returned.shared.active_strand == "main"
  assert returned.view.input == initial.view.input
  assert returned.shared.attachments == initial.shared.attachments
  assert returned.view.submission_mode == tui_model.SteerNow
  let reopened = returned |> press("f2") |> press("down") |> press("enter")
  assert textarea.value(reopened.view.input) == "w"
}

pub fn selection_survives_insertion_and_removal_cannot_retarget_a_draft_test() {
  let initial = {
    let base = model()
    tui_model.Model(
      shared: shared_set.strands(base.shared, roster()),
      view: view_set.input(base.view, textarea.state_from_string("keep me")),
    )
  }
  let inspected = initial |> press("f2") |> press("down")
  let inserted =
    tui_model.Model(
      ..inspected,
      shared: shared_set.strands(inspected.shared, [
        protocol.Strand("earlier", None, None),
        ..roster()
      ]),
    )
  let assert tui_model.AgentInspector(selection) = inserted.view.overlay
    as "the workspace remains open"
  assert selection.selected == "worker"
  let removed =
    tui_model.Model(
      ..inserted,
      shared: shared_set.strands(inserted.shared, [
        protocol.Strand("main", None, None),
      ]),
    )
    |> press("enter")
  assert removed.shared.active_strand == "main"
  assert removed.view.input == initial.view.input
  let navigated = removed |> press("down")
  let assert tui_model.AgentInspector(selection) = navigated.view.overlay
    as "missing selection remains navigable"
  assert selection.selected == "main"
}

pub fn expanded_pending_nudges_keep_all_lines_in_the_scrollable_tail_test() {
  let body = "first line\nsecond line\nlast visible instruction"
  let initial = {
    let base = model()
    tui_model.Model(
      ..base,
      shared: base.shared
        |> shared_set.strands([])
        |> shared_set.nudges(Some(advisor_pending.Board("main", 1, [body], 1)))
        |> shared_set.details_expanded(True),
    )
  }
  let rendered = tui.update(backend.Resize(100, 30), initial)
  let text =
    render.view(rendered, geometry.rect_new(0, 0, 100, 30)).0
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
      assert string.contains(text, "↑↓")
      assert string.contains(text, "▸")

      // Beside the list, the footer names the unchanged recipient; a
      // stacked workspace leaves that to the composer's own frame below it.
      case size.0 >= 116 {
        True -> {
          assert string.contains(text, "To: main")
        }
        False -> Nil
      }
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
  let initial = {
    let base = model()
    tui_model.Model(
      ..base,
      view: view_set.input(
        base.view,
        textarea.state_from_string("private draft for main"),
      ),
    )
  }
  let cut =
    snapshot.Captured(
      snapshot.Attachment(
        snapshot.Expected(initial.shared.session, "epoch", "instance"),
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
    inbound.apply_channel_update(
      initial,
      session_channel.Captured(cut, removed, session_channel.Notified),
    )
  assert captured.shared.active_strand == "main"
  let refused = captured |> press("enter")
  assert refused.view.input == initial.view.input
  assert refused.shared.active_strand == "main"
  assert refused.shared.pending_submission == None
  assert refused.shared.queued == []
  let text =
    render.view(
      refused,
      geometry.rect_new(0, 0, refused.view.width, refused.view.height),
    ).0
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
  let initial = {
    let base = model()
    tui_model.Model(
      shared: shared_set.strands(base.shared, roster()),
      view: view_set.input(base.view, textarea.state_from_string("main draft")),
    )
  }
  let worker = initial |> press("f2") |> press("down") |> press("enter")
  let worker =
    tui_model.Model(
      ..worker,
      view: view_set.input(
        worker.view,
        textarea.state_from_string("worker draft"),
      ),
    )
  let returned =
    inbound.apply_channel_update(
      worker,
      session_channel.Auxiliary(protocol.HeldInputReturned(
        strand: "main",
        id: "held",
        kind: "queue",
        text: "returned main prompt",
        attachment_count: 0,
      )),
    )
  assert textarea.value(returned.view.input) == "worker draft"
  assert returned.shared.active_strand == "worker"

  // The return passed through the session state and the terminal took it
  // into the parked editor in the same call, so none is left waiting.
  assert returned.shared.returned_drafts == []
  let main = returned |> press("f2") |> press("up") |> press("enter")
  assert textarea.value(main.view.input) == "main draft\n\nreturned main prompt"
}

pub fn editing_inside_the_workspace_keeps_the_original_recipient_test() {
  let initial = {
    let base = model()
    tui_model.Model(
      shared: shared_set.strands(base.shared, roster()),
      view: view_set.input(base.view, textarea.state_from_string("main draft")),
    )
  }
  let inspected =
    initial |> press("f2") |> press("down") |> press("w") |> press("!")
  assert inspected.shared.active_strand == "main"
  assert textarea.value(inspected.view.input) == "main draft!"
  let assert tui_model.AgentInspector(inspector) = inspected.view.overlay
    as "the composer remains inside the agent workspace"
  assert inspector.selected == "worker"
  assert inspector.focus == agents.Composing
  let navigated = inspected |> press("esc") |> press("up")
  assert navigated.shared.active_strand == "main"
  assert textarea.value(navigated.view.input) == "main draft!"
  let assert tui_model.AgentInspector(inspector) = navigated.view.overlay
    as "Escape returned keyboard ownership to inspection"
  assert inspector.selected == "main"
}

/// Bracketed paste obeys the same workspace focus as ordinary key presses.
///
/// Browsing exposes a composer underneath the inspector. A paste there must
/// not silently change the draft that a later Enter could submit.
pub fn paste_edits_only_while_the_workspace_composer_has_focus_test() {
  let initial = {
    let base = model()
    tui_model.Model(
      shared: shared_set.strands(base.shared, roster()),
      view: view_set.input(base.view, textarea.state_from_string("main draft")),
    )
  }
  let browsing = press(initial, "f2")
  let ignored = tui.update(backend.Paste(" hidden"), browsing)
  assert textarea.value(ignored.view.input) == "main draft"
    as "browsing must not change the hidden composer"

  let composing = press(browsing, "w")
  let pasted = tui.update(backend.Paste(" visible"), composing)
  assert textarea.value(pasted.view.input) == "main draft visible"
    as "paste should edit after w gives the composer focus"

  let returned = press(pasted, "esc")
  let ignored_again = tui.update(backend.Paste(" hidden"), returned)
  assert textarea.value(ignored_again.view.input) == "main draft visible"
    as "Escape must restore the browsing paste fence"
}

/// A focused diff navigator also owns paste while the composer is hidden.
pub fn diff_navigation_does_not_paste_into_the_hidden_composer_test() {
  let base = {
    let base = model()
    tui_model.Model(
      ..base,
      view: base.view
        |> view_set.diff_view(tui_model.DiffVisible)
        |> view_set.input(textarea.state_from_string("main draft")),
    )
  }
  let browsing =
    tui_model.Model(
      ..base,
      shared: shared_set.worktree(
        base.shared,
        worktree_view.State(
          ..base.shared.worktree,
          focus: worktree_view.Navigator,
        ),
      ),
    )
  let ignored = tui.update(backend.Paste(" hidden"), browsing)
  assert textarea.value(ignored.view.input) == "main draft"

  let composing =
    tui_model.Model(
      ..browsing,
      shared: shared_set.worktree(
        browsing.shared,
        worktree_view.State(
          ..browsing.shared.worktree,
          focus: worktree_view.Composer,
        ),
      ),
    )
  let pasted = tui.update(backend.Paste(" visible"), composing)
  assert textarea.value(pasted.view.input) == "main draft visible"
}

pub fn opening_selected_message_sender_preserves_drafts_until_the_action_test() {
  let send =
    agent_messages.Item(
      entry_id: "entry",
      call_id: "call",
      source: "worker",
      target: "main",
      body: "Please review this result",
      body_extent: agent_messages.Complete,
      seq: 7,
      state: agent_messages.Accepted,
      ts: 0,
    )
  let initial = {
    let base = model()
    tui_model.Model(
      shared: base.shared
        |> shared_set.strands(roster())
        |> shared_set.agent_messages([send]),
      view: view_set.input(base.view, textarea.state_from_string("main draft")),
    )
  }
  let inspected = initial |> press("f2") |> press("2")
  assert inspected.shared.active_strand == "main"
  assert textarea.value(inspected.view.input) == "main draft"
  let opened = inspected |> press("o")
  assert opened.shared.active_strand == "worker"
  assert textarea.value(opened.view.input) == ""
  let restored = opened |> press("f2") |> press("up") |> press("enter")
  assert restored.shared.active_strand == "main"
  assert textarea.value(restored.view.input) == "main draft"
}

pub fn unknown_message_sender_is_refused_without_retargeting_test() {
  let send =
    agent_messages.Item(
      entry_id: "entry",
      call_id: "call",
      source: "evicted",
      target: "main",
      body: "Old send",
      body_extent: agent_messages.Complete,
      seq: 7,
      state: agent_messages.SendPending,
      ts: 0,
    )
  let initial = {
    let base = model()
    tui_model.Model(
      shared: base.shared
        |> shared_set.strands(roster())
        |> shared_set.agent_messages([send]),
      view: view_set.input(base.view, textarea.state_from_string("main draft")),
    )
  }
  let refused = initial |> press("f2") |> press("2") |> press("o")
  assert refused.shared.active_strand == "main"
  assert textarea.value(refused.view.input) == "main draft"
  assert string.contains(refused.shared.notice, "sender is unavailable")
}

pub fn short_detail_with_multiline_draft_keeps_selected_body_visible_test() {
  let send =
    agent_messages.Item(
      entry_id: "entry",
      call_id: "call",
      source: "main",
      target: "worker",
      body: "visible-message-body",
      body_extent: agent_messages.Complete,
      seq: 7,
      state: agent_messages.Accepted,
      ts: 0,
    )
  let inspector = agents.inspect("main")
  let inspected =
    {
      let base = model()
      tui_model.Model(
        shared: base.shared
          |> shared_set.strands(roster())
          |> shared_set.agent_messages([send]),
        view: base.view
          |> view_set.input(textarea.state_from_string("one\ntwo\nthree\nfour"))
          |> view_set.overlay(tui_model.AgentInspector(
            agents.Inspector(
              ..inspector,
              detail: agents.Messages,
              message: Some(agent_message_panel.identity(send)),
            ),
          )),
      )
    }
    |> tui.update(backend.Resize(80, 24), _)
  let rendered =
    render.view(inspected, geometry.rect_new(0, 0, 80, 24)).0
    |> frame.buffer_to_text
  assert string.contains(rendered, "visible-message-body")
}

pub fn capture_reconciliation_preserves_scrolled_durable_selection_test() {
  let retained =
    agent_messages.Item(
      entry_id: "old-entry",
      call_id: "old-call",
      source: "main",
      target: "worker",
      body: "retained body",
      body_extent: agent_messages.Complete,
      seq: 7,
      state: agent_messages.Accepted,
      ts: 0,
    )
  let fresh =
    agent_messages.Item(
      entry_id: "new-entry",
      call_id: "new-call",
      source: "main",
      target: "worker",
      body: "new body",
      body_extent: agent_messages.Complete,
      seq: 8,
      state: agent_messages.Started,
      ts: 0,
    )
  let inspector = agents.inspect("main")
  let model =
    {
      let base = model()
      tui_model.Model(
        shared: shared_set.agent_messages(base.shared, [
          fresh,
          retained,
        ]),
        view: view_set.overlay(
          base.view,
          tui_model.AgentInspector(
            agents.Inspector(
              ..inspector,
              detail: agents.Messages,
              message: Some(agent_message_panel.identity(retained)),
              scroll: 3,
            ),
          ),
        ),
      )
    }
    |> inbound.reconcile_agent_message_selection
  let assert tui_model.AgentInspector(preserved) = model.view.overlay
  assert preserved.message == Some(agent_message_panel.identity(retained))
  assert preserved.scroll == 3

  let evicted =
    tui_model.Model(
      ..model,
      shared: shared_set.agent_messages(model.shared, [fresh]),
    )
    |> inbound.reconcile_agent_message_selection
  let assert tui_model.AgentInspector(fallback) = evicted.view.overlay
  assert fallback.message == Some(agent_message_panel.identity(fresh))
  assert fallback.scroll == 0
}

pub fn workspace_preserves_recipient_controls_and_attention_at_small_sizes_test() {
  list.each(
    [#(40, 12), #(80, 24), #(100, 30), #(116, 38), #(160, 50)],
    fn(size) {
      let initial =
        {
          let base = model()
          tui_model.Model(
            shared: shared_set.strands(base.shared, roster()),
            view: view_set.input(
              base.view,
              textarea.state_from_string("retained draft"),
            ),
          )
        }
        |> tui.update(backend.Resize(size.0, size.1), _)
        |> press("f2")
      let rendered =
        render.view(initial, geometry.rect_new(0, 0, size.0, size.1)).0
        |> frame.buffer_to_text
      assert string.contains(rendered, "To main")
      assert string.contains(rendered, "retained draft")
      let editing = initial |> press("w")
      let rendered =
        render.view(editing, geometry.rect_new(0, 0, size.0, size.1)).0
        |> frame.buffer_to_text
      assert string.contains(rendered, "Enter")
      assert editing.shared.active_strand == "main"
    },
  )
}

pub fn collaboration_tab_preserves_inspection_and_composer_target_test() {
  let initial =
    {
      let base = model()
      tui_model.Model(..base, shared: shared_set.strands(base.shared, roster()))
    }
    |> press("f2")
  let opened = initial |> press("down") |> press("4")
  let assert tui_model.AgentInspector(inspector) = opened.view.overlay
  assert inspector.detail == agents.Collaboration
  assert inspector.selected == "worker"
  assert opened.shared.active_strand == "main"
  let rendered =
    render.view(opened, geometry.rect_new(0, 0, 100, 30)).0
    |> frame.buffer_to_text
  assert string.contains(rendered, "4 Collaborate")
  assert string.contains(rendered, "To: main")
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
  assert string.contains(rendered, "Needs approval: fs_write")

  // The captured preview wraps rather than being cut, so all of it shows.
  assert string.contains(rendered, "report")
  assert string.contains(rendered, "a reviews the exact request")
  assert string.contains(rendered, "Nothing is approved here")
}

// Writing from the workspace transfers keyboard ownership out of any
// previously visible surface.
pub fn workspace_typing_leaves_the_hidden_diff_navigator_test() {
  let initial =
    {
      let base = model()
      tui_model.Model(
        shared: shared_set.strands(base.shared, roster()),
        view: view_set.diff_view(base.view, tui_model.DiffVisible),
      )
    }
    |> press("ctrl+d")
  assert initial.shared.worktree.focus == worktree_view.Navigator
  let editing = initial |> press("f2") |> press("w") |> press("x")
  assert editing.shared.worktree.focus == worktree_view.Composer
  assert textarea.value(editing.view.input) == "x"
  let navigating = editing |> press("ctrl+d")
  assert navigating.view.overlay == tui_model.NoOverlay
  assert navigating.shared.worktree.focus == worktree_view.Navigator
}

pub fn workspace_commands_expose_the_surface_that_owns_the_next_key_test() {
  list.each(
    ["/help", "/notes", "/diff", "/context", "/queue", "/summary"],
    fn(command) {
      let editing = model() |> press("f2") |> press("w")
      let opened =
        tui_model.Model(
          ..editing,
          view: view_set.input(
            editing.view,
            textarea.state_from_string(command),
          ),
        )
        |> press("enter")
      assert opened.view.overlay == tui_model.NoOverlay as command
    },
  )
  let previous = {
    let base = model()
    tui_model.Model(..base, view: view_set.help_open(base.view, True))
  }
  let editing = previous |> press("f2") |> press("w") |> press("x")
  assert !editing.view.help_open
  assert textarea.value(editing.view.input) == "x"
}

// The identity row must remain useful in a deeply nested worktree.
pub fn long_checkout_paths_do_not_hide_the_session_identity_test() {
  let initial =
    {
      let base = model()
      tui_model.Model(
        shared: base.shared
          |> shared_set.session("review-session")
          |> shared_set.current_model("provider/model"),
        view: view_set.workspace(
          base.view,
          workspace.Context("/work/" <> string.repeat("nested/", 30), None),
        ),
      )
    }
    |> tui.update(backend.Resize(80, 24), _)
  let header =
    render.view(initial, geometry.rect_new(0, 0, 80, 24)).0
    |> frame.buffer_to_text
    |> string.split("\n")
    |> list.first
  let assert Ok(header) = header as "a terminal has a header"
  assert string.contains(header, "review-session")
  assert string.contains(header, "· strand main")
  assert string.contains(header, "model")
}

pub fn tiny_workspace_keeps_selected_identity_and_navigation_visible_test() {
  let initial =
    {
      let base = model()
      tui_model.Model(
        shared: shared_set.strands(base.shared, roster()),
        view: view_set.input(
          base.view,
          textarea.state_from_string("retained draft"),
        ),
      )
    }
    |> tui.update(backend.Resize(40, 12), _)
    |> press("f2")
    |> press("down")
  let rendered =
    render.view(
      tui_model.Model(
        ..initial,
        view: view_set.caches(
          initial.view,
          tui_model.Caches(..initial.view.caches, frame_cache: None),
        ),
      ),
      geometry.rect_new(0, 0, 40, 12),
    ).0
    |> frame.buffer_to_text
  assert string.contains(rendered, "Review scheduler")
  assert string.contains(rendered, "↑↓")
  assert string.contains(rendered, "To: main")

  // Browsing covers the composer; writing from the workspace brings it
  // back with the draft its recipient kept.
  let writing = initial |> press("w")
  let rendered =
    render.view(
      tui_model.Model(
        ..writing,
        view: view_set.caches(
          writing.view,
          tui_model.Caches(..writing.view.caches, frame_cache: None),
        ),
      ),
      geometry.rect_new(0, 0, 40, 12),
    ).0
    |> frame.buffer_to_text
  assert string.contains(rendered, "retained draft")
}

// A cut replaces the agent messages the Messages tab browses, so the tab's
// selection is checked against the captured list: a selection whose message
// is no longer listed moves, and its scroll starts over.
pub fn a_cut_revalidates_the_message_selection_test() {
  let gone =
    agent_messages.Item(
      entry_id: "gone-entry",
      call_id: "gone-call",
      source: "main",
      target: "worker",
      body: "gone body",
      body_extent: agent_messages.Complete,
      seq: 3,
      state: agent_messages.Accepted,
      ts: 0,
    )
  let inspector = agents.inspect("main")
  let base = model()
  let browsing =
    tui_model.Model(
      ..base,
      view: view_set.overlay(
        base.view,
        tui_model.AgentInspector(
          agents.Inspector(
            ..inspector,
            detail: agents.Messages,
            message: Some(agent_message_panel.identity(gone)),
            scroll: 3,
          ),
        ),
      ),
    )
  let cut =
    snapshot.Captured(
      snapshot.Attachment(
        snapshot.Expected(browsing.shared.session, "epoch", "instance"),
        "peer",
        message.Origin("operator", "Operator"),
        snapshot.Owner,
      ),
      1,
      json.Object([]),
      snapshot.empty(),
      None,
    )
  let captured =
    inbound.apply_channel_update(
      browsing,
      session_channel.Captured(cut, empty_view(), session_channel.Notified),
    )
  let assert tui_model.AgentInspector(after) = captured.view.overlay
    as "the inspector stays open"
  assert after.message != Some(agent_message_panel.identity(gone))
    as "a message the cut no longer lists is not selected"
  assert after.scroll == 0
}
