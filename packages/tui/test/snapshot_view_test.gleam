//// Projection follows captured leaves and pairs configuration with its author.

import core/clock
import core/codec
import core/entry
import core/ids
import core/json
import core/message
import core/register
import etui/keys
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import machine/codec as machine_codec
import machine/strand
import session_view/approval
import session_view/model as session_model
import session_view/protocol
import session_view/session_channel
import session_view/shared_set
import session_view/snapshot
import session_view/snapshot_view
import session_view/transcript_line
import tui/approval_panel
import tui/inbound
import tui/model as tui_model
import tui/view_set
import tui_test/pushed

fn author(name) {
  json.Object([
    #("principal", json.String("principal-" <> name)),
    #("name", json.String(name)),
  ])
}

fn cell(namespace, key, value) {
  json.Object([
    #("namespace", json.String(register.ns_to_string(namespace))),
    #("key", json.String(key)),
    #("seq", json.Int(1)),
    #("value", value),
  ])
}

fn settings(name, queue) {
  json.Object([
    #("queue_mode", json.String(queue)),
    #("tool_execution", json.String("parallel")),
    #("origin", author(name)),
  ])
}

fn metadata(cells) {
  json.Object([
    #("cells", json.Array(cells)),
    #("message_count", json.Int(0)),
    #(
      "usage",
      codec.encode_usage(message.Usage(
        0,
        0,
        0,
        0,
        None,
        None,
        0,
        message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0),
      )),
    ),
    #("host_run_settings", settings("Host", "one_at_a_time")),
    #(
      "peers",
      json.Array([
        json.Object([
          #("connection_id", json.String("alice-tab")),
          #("origin", author("Alice")),
          #("role", json.String("operator")),
        ]),
      ]),
    ),
  ])
}

fn cut(metadata, window) {
  snapshot.Captured(
    snapshot.Attachment(
      snapshot.Expected("session", "epoch", "incarnation"),
      "alice-tab",
      message.Origin("principal-Alice", "Alice"),
      snapshot.Operator,
    ),
    10,
    metadata,
    window,
    None,
  )
}

pub fn snapshot_view_lookup_requires_exact_complete_requested_keys_test() {
  let present = cell(register.FactCustom, "escalation/esc", json.Object([]))
  let lookup = fn(cells, missing) {
    cut(
      json.Object([
        #("cells", json.Array(cells)),
        #("missing", json.Array(list.map(missing, json.String))),
      ]),
      snapshot.empty(),
    )
  }
  let assert Ok(#(found, missing)) =
    snapshot_view.lookup(lookup([present], ["absent"]), ["esc", "absent"])
    as "requested present and absent identities are distinct explicit answers"
  assert list.length(found) == 1
  assert missing == ["absent"]
  list.each(
    [
      lookup([present], ["esc"]),
      lookup([present], []),
      lookup(
        [cell(register.FactCustom, "escalation/esc-neighbor", json.Object([]))],
        ["absent"],
      ),
      lookup([cell(register.StrandConfig, "escalation/esc", json.Object([]))], [
        "absent",
      ]),
    ],
    fn(captured) {
      let assert Error(_) = snapshot_view.lookup(captured, ["esc", "absent"])
        as "duplicate, omitted, prefix-neighbor and wrong-namespace answers fail closed"
    },
  )
}

pub fn snapshot_view_decided_accepts_only_escalation_cells_test() {
  let decided = fn(cells, missing) {
    cut(
      json.Object([
        #("cells", json.Array(cells)),
        #("missing", json.Array(list.map(missing, json.String))),
      ]),
      snapshot.empty(),
    )
  }
  let present = cell(register.FactCustom, "escalation/esc", json.Object([]))
  let assert Ok(found) = snapshot_view.decided(decided([present], []))
    as "decided escalation cells are the whole answer"
  assert list.length(found) == 1
  let assert Ok([]) = snapshot_view.decided(decided([], []))
    as "a session with no decisions answers with no cells"
  list.each(
    [
      decided(
        [cell(register.StrandConfig, "escalation/esc", json.Object([]))],
        [],
      ),
      decided([cell(register.FactCustom, "client/other", json.Object([]))], []),
      decided([present], ["named"]),
    ],
    fn(captured) {
      let assert Error(_) = snapshot_view.decided(captured)
        as "another namespace, another prefix or a missing list fails closed"
    },
  )
}

fn config_cells(leaf, name, model) {
  [
    cell(
      register.StrandConfig,
      "main",
      machine_codec.encode_configuration(
        strand.StrandConfiguration(
          strand.ModelIdentity("provider", model),
          strand.ThinkingOff,
          [],
        ),
      ),
    ),
    cell(register.StrandLeaf, "main", leaf),
    cell(
      register.StrandState,
      "main",
      machine_codec.encode_strand_state(strand.StrandState(None, [])),
    ),
    cell(
      register.FactCustom,
      "client/config_origin/main",
      json.Object([#("origin", author(name))]),
    ),
    cell(
      register.FactCustom,
      "client/run_settings",
      settings(name, "consume_all"),
    ),
  ]
}

pub fn snapshot_view_metadata_only_cut_replaces_configuration_and_author_together_test() {
  let first =
    cut(metadata(config_cells(json.Null, "Alice", "first")), snapshot.empty())
  let second =
    cut(metadata(config_cells(json.Null, "Bob", "second")), snapshot.empty())
  let assert Ok(a) = snapshot_view.decode(first)
    as "first coherent metadata decodes"
  let assert Ok(b) = snapshot_view.decode(second)
    as "metadata can change without a new entry cursor"
  let assert Ok(config) = dict.get(b.configurations, "main")
    as "captured configuration is present"
  assert config.configuration.model.model_id == "second"
  assert config.origin == Some(message.Origin("principal-Bob", "Bob"))
  assert a.settings.origin != b.settings.origin
  assert b.settings.queue_mode == "consume_all"
    as "durable run settings override host defaults"
  assert first.next_seq == second.next_seq
  assert b.peers
    == [
      snapshot_view.Peer(
        "alice-tab",
        message.Origin("principal-Alice", "Alice"),
        snapshot.Operator,
      ),
    ]
}

pub fn snapshot_view_projects_only_real_ancestry_and_marks_missing_parent_test() {
  let #(missing, generator) =
    ids.mint_entry(ids.generator(clock.fixed(1000), 1))
  let #(leaf, generator) = ids.mint_entry(generator)
  let #(unrelated, _) = ids.mint_entry(generator)
  let row =
    entry.MessageEntry(
      leaf,
      Some(missing),
      2,
      1000,
      message.UserMessage([message.UserText("selected", None)], 1000, None),
      False,
    )
  let other =
    entry.MessageEntry(
      unrelated,
      None,
      3,
      1000,
      message.UserMessage([message.UserText("unrelated", None)], 1000, None),
      False,
    )
  let window =
    snapshot.Window(
      [snapshot.Loaded(other, 100), snapshot.Loaded(row, 100)],
      200,
      None,
    )
  let captured =
    cut(
      metadata(config_cells(
        json.String(ids.entry_id_to_string(leaf)),
        "Alice",
        "first",
      )),
      window,
    )
  let assert Ok(view) = snapshot_view.decode(captured)
    as "captured leaf and strand state agree"
  let branch = snapshot_view.branch(view, window, "main")
  assert list.map(branch.records, fn(record) { record.entry.id }) == [leaf]
  assert branch.unloaded == Some(ids.entry_id_to_string(missing))
}

pub fn snapshot_view_rejects_duplicate_cells_and_registers_outside_cut_test() {
  let value =
    cell(register.FactCustom, "client/run_settings", settings("Alice", "all"))
  let assert Error(_) =
    snapshot_view.decode(cut(metadata([value, value]), snapshot.empty()))
    as "duplicate mutable identities cannot silently overwrite one another"
  let captured = cut(metadata([value]), snapshot.empty())
  let assert Error(_) =
    snapshot_view.decode(snapshot.Captured(..captured, next_seq: 1))
    as "a register sequence cannot be at or after the capture cursor"
  Nil
}

pub fn tool_result_lookup_and_tail_retirement_match_strand_and_call_test() {
  let #(main_result, generator) =
    ids.mint_entry(ids.generator(clock.fixed(1000), 1))
  let #(peer_result, _) = ids.mint_entry(generator)
  let result = fn(id, call_id) {
    entry.MessageEntry(
      id,
      None,
      1,
      1000,
      message.ToolResultMessage(
        call_id,
        "bash",
        [message.ToolResultText("done", None)],
        None,
        None,
        None,
        False,
        1000,
      ),
      False,
    )
  }
  let window =
    snapshot.Window(
      [
        snapshot.Loaded(result(main_result, "call-main"), 100),
        snapshot.Loaded(result(peer_result, "call-peer"), 100),
      ],
      200,
      None,
    )
  let cells =
    list.append(
      config_cells(
        json.String(ids.entry_id_to_string(main_result)),
        "Alice",
        "first",
      ),
      [
        cell(
          register.StrandConfig,
          "sub:1",
          machine_codec.encode_configuration(
            strand.StrandConfiguration(
              strand.ModelIdentity("provider", "first"),
              strand.ThinkingOff,
              [],
            ),
          ),
        ),
        cell(
          register.StrandLeaf,
          "sub:1",
          json.String(ids.entry_id_to_string(peer_result)),
        ),
        cell(
          register.StrandState,
          "sub:1",
          machine_codec.encode_strand_state(strand.StrandState(None, [])),
        ),
      ],
    )
  let assert Ok(view) = snapshot_view.decode(cut(metadata(cells), window))
    as "both strand branches decode"
  assert snapshot_view.has_tool_result(view, window, "main", "call-main")
  assert !snapshot_view.has_tool_result(view, window, "main", "call-peer")
    as "another strand's result cannot retire this tail"
  assert snapshot_view.has_tool_result(view, window, "sub:1", "call-peer")
  assert !snapshot_view.has_tool_result(view, window, "sub:1", "call-main")

  // A network client may learn about these results only through a capture.
  // Reconciliation must retire the inactive strand and only the completed
  // call on main, leaving a live peer in the same operation untouched.
  let tail = fn(strand, call_id, source_index) {
    transcript_line.ToolTail(
      strand:,
      operation: "shared-operation",
      step: "step-1",
      source_index:,
      call_id:,
      stream: "stdout",
      text: call_id,
      total_bytes: 1,
    )
  }
  let model =
    {
      let base = pushed.attached()
      tui_model.Model(
        ..base,
        shared: shared_set.tool_tails(base.shared, [
          tail("main", "call-main", 0),
          tail("main", "call-running", 1),
          tail("sub:1", "call-peer", 0),
        ]),
      )
    }
    |> inbound.apply_channel_update(session_channel.Captured(
      cut(metadata(cells), window),
      view,
      session_channel.Refreshed,
    ))
  assert list.map(model.shared.tool_tails, fn(tail) {
      #(tail.strand, tail.call_id)
    })
    == [#("main", "call-running")]
    as "capture retirement is exact and applies beyond the active strand"
}

fn pending_permission_cut(seq: Int) -> snapshot.Captured {
  permission_cut(seq, "pending", json.Null)
}

// The same escalation register at a given status, with the decider the
// winning decision stored, or `json.Null` while nobody has decided.
fn permission_cut(
  seq: Int,
  status: String,
  decider: json.JsonValue,
) -> snapshot.Captured {
  let value =
    json.Object([
      #("id", json.String("permission")),
      #("status", json.String(status)),
      #("tool", json.String("fs_write")),
      #("preview", json.String("write the requested file")),
      #("action", json.String("captured-action")),
      #("origin", decider),
      #(
        "denial",
        json.Object([
          #(
            "wanted",
            json.Array([
              json.Object([
                #("grant", json.String("writable_root")),
                #("path", json.String("/shared/output")),
              ]),
            ]),
          ),
        ]),
      ),
    ])
  let row =
    json.Object([
      #("namespace", json.String("fact.custom")),
      #("key", json.String("escalation/permission")),
      #("seq", json.Int(seq)),
      #("value", value),
    ])
  snapshot.Captured(..cut(metadata([row]), snapshot.empty()), next_seq: seq + 1)
}

fn capture_permission(
  model: tui_model.Model,
  captured: snapshot.Captured,
) -> tui_model.Model {
  let assert Ok(view) = snapshot_view.decode(captured)
    as "the approval metadata must decode"
  inbound.apply_channel_update(
    model,
    session_channel.Captured(captured, view, session_channel.Refreshed),
  )
}

pub fn pending_permission_automatically_opens_a_dialog_with_captured_consent_test() {
  let first = pending_permission_cut(11)
  let opened = capture_permission(pushed.attached(), first)
  let assert tui_model.ApprovalInspector(panel) = opened.view.overlay
    as "a new pending request must present decision options automatically"
  let assert approval_panel.Continue(_) =
    approval_panel.update(keys.Enter, panel)
    as "an Enter queued before the dialog appeared cannot approve anything"
  let refreshed = capture_permission(opened, pending_permission_cut(12))
  let assert tui_model.ApprovalInspector(still_captured) =
    refreshed.view.overlay
    as "a metadata refresh must not replace the visible question"
  let assert approval_panel.Continue(selected) =
    approval_panel.update(keys.Right, still_captured)
    as "the operator explicitly selects allow once"
  let assert approval_panel.Decide(review, approval_panel.AllowOnce) =
    approval_panel.update(keys.Enter, selected)
    as "the dialog returns its captured decision"
  assert review.seq == 11
  assert review.permission
    == approval.Exact("captured-action", [
      json.Object([
        #("type", json.String("writable_root")),
        #("path", json.String("/shared/output")),
      ]),
    ])
}

// The dialog closes once its decision is handed to the lane, and a refused
// decision leaves the question on screen with the reason beside it, so the
// operator can answer it again once the conversation is back.
pub fn a_decision_closes_the_dialog_unless_it_is_refused_test() {
  let captured =
    capture_permission(pushed.attached(), pending_permission_cut(41))
  let assert tui_model.ApprovalInspector(panel) = captured.view.overlay
    as "the pending request opens its dialog"
  let review = approval_panel.review(panel)

  // The cut lists no strands; the decision goes to a strand the session
  // knows, or it is refused before it is encoded.
  let opened =
    tui_model.Model(
      ..captured,
      shared: shared_set.strands(captured.shared, [
        protocol.Strand("main", Some("main"), None),
      ]),
    )

  let decided =
    inbound.decide_captured_approval(opened, review, approval_panel.Deny)
  assert decided.view.overlay == tui_model.NoOverlay
    as "a decision on its way takes the question off the screen"

  let offline =
    tui_model.Model(
      ..opened,
      shared: shared_set.peer(opened.shared, session_model.Disconnected),
    )
  let refused =
    inbound.decide_captured_approval(offline, review, approval_panel.Deny)
  let assert tui_model.ApprovalInspector(_) = refused.view.overlay
    as "a refused decision leaves the question open"
  assert refused.shared.notice == "no conversation is attached; draft retained"
}

pub fn deferred_question_is_not_reopened_until_its_sequence_changes_test() {
  let first = pending_permission_cut(21)
  let opened = capture_permission(pushed.attached(), first)
  let deferred =
    tui_model.Model(
      ..opened,
      view: view_set.overlay(opened.view, tui_model.NoOverlay),
    )
  let same = capture_permission(deferred, first)
  assert same.view.overlay == tui_model.NoOverlay
  let reopened = capture_permission(same, pending_permission_cut(22))
  let assert tui_model.ApprovalInspector(_) = reopened.view.overlay
    as "the same request ID at a new sequence is a new question"
  let observer_cut =
    snapshot.Captured(
      ..first,
      attachment: snapshot.Attachment(
        ..first.attachment,
        role: snapshot.Observer,
      ),
    )
  assert capture_permission(pushed.attached(), observer_cut).view.overlay
    == tui_model.NoOverlay
    as "read-only observers do not receive decision controls automatically"
}

pub fn late_lookup_preserves_the_open_question_and_selection_test() {
  let opened = capture_permission(pushed.attached(), pending_permission_cut(31))
  let assert tui_model.ApprovalInspector(panel) = opened.view.overlay
    as "the captured question must be visible"
  let assert approval_panel.Continue(selected) =
    approval_panel.update(keys.Right, panel)
    as "the operator selects allow once before the lookup finishes"
  let looking_up =
    tui_model.Model(
      ..opened,
      view: opened.view
        |> view_set.overlay(tui_model.ApprovalInspector(selected))
        |> view_set.inspecting_approval(Some("permission")),
    )
  let newer = capture_permission(pushed.attached(), pending_permission_cut(32))
  let updated =
    inbound.apply_channel_update(
      looking_up,
      session_channel.LookedUp(newer.shared.approvals, []),
    )
  assert updated.view.overlay == looking_up.view.overlay
  assert updated.view.inspecting_approval == None
  let assert tui_model.ApprovalInspector(preserved) = updated.view.overlay
    as "the lookup cannot replace the question under review"
  let assert approval_panel.Decide(review, approval_panel.AllowOnce) =
    approval_panel.update(keys.Enter, preserved)
    as "the existing selection remains attached to the captured question"
  assert review.seq == 31
}

pub fn question_settled_by_another_client_closes_its_dialog_test() {
  let opened = capture_permission(pushed.attached(), pending_permission_cut(51))
  let assert tui_model.ApprovalInspector(_) = opened.view.overlay
    as "the pending question must be on screen first"

  // The web view answered the question, so the next cut carries the
  // register resolved and signed by the operator who decided it.
  let settled =
    capture_permission(opened, permission_cut(52, "approved", author("Alice")))
  assert settled.view.overlay == tui_model.NoOverlay
    as "a question answered elsewhere must not keep offering decisions"
  assert settled.shared.notice
    == "Approval permission (fs_write) was settled elsewhere by Alice; its dialog is closed."
}

pub fn question_whose_register_disappears_closes_its_dialog_test() {
  let opened = capture_permission(pushed.attached(), pending_permission_cut(61))
  let assert tui_model.ApprovalInspector(_) = opened.view.overlay
    as "the pending question must be on screen first"
  let gone = capture_permission(opened, cut(metadata([]), snapshot.empty()))
  assert gone.view.overlay == tui_model.NoOverlay
    as "a request that is no longer pending anywhere cannot stay on screen"
}

pub fn lookup_reporting_the_question_resolved_closes_its_dialog_test() {
  let opened = capture_permission(pushed.attached(), pending_permission_cut(81))
  let assert tui_model.ApprovalInspector(_) = opened.view.overlay
    as "the pending question must be on screen first"

  // The lookup reply is the first thing to report the decision; no cut
  // arrives in between to close the panel.
  let resolved =
    capture_permission(
      pushed.attached(),
      permission_cut(82, "approved", author("Bob")),
    )
  let settled =
    inbound.apply_channel_update(
      opened,
      session_channel.LookedUp(resolved.shared.approvals, []),
    )
  assert settled.view.overlay == tui_model.NoOverlay
    as "a lookup that shows the question resolved must close its dialog"
  assert settled.shared.notice
    == "Approval permission (fs_write) was settled elsewhere by Bob; its dialog is closed."
}

// The line that closes the dialog is written where the lookup's reply is
// applied, before the reply's own line about the records it could not load,
// so that line is the notice the update leaves.
pub fn a_settled_dialog_line_precedes_the_lookups_missing_line_test() {
  let opened = capture_permission(pushed.attached(), pending_permission_cut(91))
  let assert tui_model.ApprovalInspector(_) = opened.view.overlay
    as "the pending question must be on screen first"
  let resolved =
    capture_permission(
      pushed.attached(),
      permission_cut(92, "approved", author("Bob")),
    )
  let settled =
    inbound.apply_channel_update(
      opened,
      session_channel.LookedUp(resolved.shared.approvals, ["elsewhere"]),
    )
  assert settled.view.overlay == tui_model.NoOverlay
  let assert [missing, closed, ..] = list.reverse(settled.shared.transcript)
    as "the update writes both lines"
  assert closed.text
    == "Approval permission (fs_write) was settled elsewhere by Bob; its dialog is closed."
  assert missing.text == "Decisions not available: elsewhere"
  assert settled.shared.notice == "Decisions not available: elsewhere"
}

pub fn deliberate_inspection_of_a_resolved_decision_stays_open_test() {
  let resolved = permission_cut(71, "approved", author("Alice"))
  let captured = capture_permission(pushed.attached(), resolved)
  assert captured.view.overlay == tui_model.NoOverlay
    as "a resolved decision is never presented automatically"

  // This is the `/approvals permission` path: the lookup answers with the
  // resolved record and the panel opens on it.
  let inspecting =
    inbound.apply_channel_update(
      tui_model.Model(
        ..captured,
        view: view_set.inspecting_approval(captured.view, Some("permission")),
      ),
      session_channel.LookedUp(captured.shared.approvals, []),
    )
  let assert tui_model.ApprovalInspector(panel) = inspecting.view.overlay
    as "the lookup opens the requested decision"
  assert approval_panel.review(panel).status == approval.Approved

  // Neither a repeated cut nor one that no longer carries the register may
  // close a decision the operator asked to read.
  let repeated = capture_permission(inspecting, resolved)
  assert repeated.view.overlay == inspecting.view.overlay
  let moved = capture_permission(repeated, cut(metadata([]), snapshot.empty()))
  assert moved.view.overlay == inspecting.view.overlay
    as "a deliberate inspection closes only when the operator closes it"
}

/// Metadata refreshes preserve footer feedback while adopting fresh presence.
pub fn metadata_refresh_preserves_the_footer_notice_test() {
  let captured = cut(metadata([]), snapshot.empty())
  let assert Ok(view) = snapshot_view.decode(captured)
    as "the empty observation must decode"
  let initial =
    inbound.apply_channel_update(
      pushed.attached(),
      session_channel.Captured(captured, view, session_channel.Refreshed),
    )
  let prior =
    tui_model.Model(
      ..initial,
      shared: shared_set.notice(initial.shared, "streaming thinking"),
    )
  let refreshed =
    inbound.apply_channel_update(
      prior,
      session_channel.Captured(captured, view, session_channel.Refreshed),
    )
  assert refreshed.shared.notice == prior.shared.notice
    as "a metadata refresh replaced current feedback with presence"
  assert refreshed.shared.captured == Some(#(captured, view))
}
