//// Keyboard, paste and mouse handling.
////
//// `update_ready_key` is the entry point for a key press: it drains the
//// ready socket traffic first, so a key acts on the newest state, and then
//// routes the key to whichever overlay or surface owns focus, falling back
//// to the conversation and the composer. Pastes, mouse selection and the
//// wheel land here too, as do the attachment candidate's events, because
//// each changes what the operator is looking at rather than what the
//// daemon has said.
////
//// Geometry comes from `tui/layout`, so a click is interpreted against the
//// same rectangles the last frame was painted with.

import etui/buffer
import etui/geometry.{type Rect}
import etui/keys
import etui/widgets/textarea as text_area
import gleam/bool
import gleam/dict
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tui/agent_message_panel
import tui/agent_messages
import tui/agent_strip
import tui/agents
import tui/approval
import tui/approval_panel
import tui/attachment
import tui/command
import tui/composer
import tui/connection
import tui/context_panel
import tui/context_view
import tui/daemon/protocol as control_protocol
import tui/focused_goal_panel
import tui/frame
import tui/history_view
import tui/image_drop
import tui/inbound
import tui/layout
import tui/model.{
  type Clipboard, type Model, type ScrollDirection, AgentInspector,
  ApprovalInspector, Attached, DaemonSelector, DiffHidden, DiffVisible,
  Disconnected, FrameCache, GoalInspector, Model, ModelSelector, Newer,
  NoClipboard, NoOverlay, Older, OverlaySubmission, PeerLinkManager, Preview,
  ReconnectIdle, Replaying, SessionSelector, TerminalClipboard,
} as tui_model
import tui/model_selector
import tui/note_panel
import tui/outbound
import tui/peer_links
import tui/projection
import tui/protocol.{ModelInfo, Strand}
import tui/queue_editor
import tui/queue_panel
import tui/render
import tui/selection
import tui/session_channel
import tui/session_control.{Archive, Restore}
import tui/session_selector
import tui/sessions
import tui/snapshot_view
import tui/submit
import tui/summary_panel
import tui/surfaces
import tui/worktree_view

/// The rename overlay owns pasted text just as it owns character keys. It
/// must never leave a pasted title in the hidden conversation composer.
@internal
pub fn handle_paste(model: Model, text: String) -> Model {
  case model.overlay {
    DaemonSelector(
      session_selector.State(prompt: session_selector.Renaming(..), ..) as selector,
    ) -> update_daemon_selector(keys.Char(text), model, selector)
    NoOverlay ->
      case layout.diff_shown(model), model.worktree.focus {
        True, worktree_view.Navigator -> model
        _, _ -> handle_underlay_paste(model, text)
      }
    AgentInspector(agents.Inspector(focus: agents.Composing, ..)) ->
      handle_underlay_paste(model, text)
    PeerLinkManager(
      peer_links.State(prompt: peer_links.EditingTargetStrand, ..) as state,
    ) -> session_control.update_peer_link_manager(keys.Char(text), model, state)
    AgentInspector(_)
    | ModelSelector(_)
    | GoalInspector(_)
    | SessionSelector(_)
    | DaemonSelector(_)
    | ApprovalInspector(_)
    | PeerLinkManager(_) -> model
  }
}

fn handle_underlay_paste(model: Model, text: String) -> Model {
  use <- bool.guard(model.context.surface != context_view.Hidden, model)
  case model.queue_editor.surface {
    queue_editor.Editor ->
      edit_queue_text(model, fn(input) { insert_queue_paste(input, text) })
    queue_editor.Inspector -> model
    queue_editor.Closed ->
      case model.summary_surface {
        queue_editor.Closed -> handle_composer_paste(model, text)
        queue_editor.Editor | queue_editor.Inspector -> model
      }
  }
}

fn handle_composer_paste(model: Model, text: String) -> Model {
  case model.pending_submission {
    Some(_) -> outbound.waiting_notice(model)
    None -> paste_unlocked(model, text)
  }
}

fn paste_unlocked(model: Model, text: String) -> Model {
  case image_drop.load_paste(text) {
    Error(reason) -> tui_model.append_error(model, reason)
    Ok(Some(image)) -> add_attachment(model, composer.ImageAttachment(image))
    Ok(None) ->
      case composer.classify(text) {
        composer.Inline(text) -> {
          // Paste follows the editor's insertion path so an existing draft
          // and the cursor's suffix remain part of the next prompt.
          let editor = text_area.textarea_new() |> text_area.with_max_lines(0)
          let input =
            list.fold(string.to_graphemes(text), model.input, fn(state, char) {
              case char {
                "\n" -> text_area.newline(editor, state)
                _ -> text_area.insert_char(editor, state, char)
              }
            })
          Model(
            ..model,
            input:,
            history_index: 0,
            history_draft: text_area.value(input),
          )
        }
        composer.Compact(attachment) -> add_attachment(model, attachment)
      }
  }
}

fn add_attachment(model: Model, attachment: composer.Attachment) -> Model {
  case composer.admit_attachment(model.attachments, attachment) {
    Error(reason) -> tui_model.append_error(model, reason)
    Ok(attachments) -> {
      let notice =
        composer.summary(attachments) |> option.unwrap("pasted content")
      Model(..model, attachments:, notice:)
    }
  }
}

/// Applies one driver-selected candidate event before later queued traffic.
///
/// ## Examples
///
/// ```gleam
/// // tui.accept_candidate_event(model, event)
/// ```
@internal
pub fn accept_candidate_event(model: Model, event: attachment.Event) -> Model {
  let #(candidate, outcome) = attachment.accept(model.candidate, event)
  candidate_outcome(model, candidate, outcome)
}

/// Applies the terminal's selected candidate result without changing its owner.
///
/// ## Examples
///
/// ```gleam
/// // tui.candidate_outcome(model, candidate, outcome)
/// ```
@internal
pub fn candidate_outcome(model: Model, candidate, outcome) -> Model {
  let model = Model(..model, candidate: candidate)
  case outcome {
    None -> model
    Some(attachment.Failed(reason)) ->
      tui_model.append_error(
        inbound.cancel_pending(model, "target change from " <> model.session),
        "open session: " <> reason,
      )
    Some(attachment.Adopted(
      channel,
      cut,
      view,
      inbox,
      workspace,
      name,
      creation_key,
    )) -> {
      // `cancel_pending` below appends its own "Not sent: … ; draft retained"
      // notice, but `render_cut` replaces the whole transcript with the new
      // session's, so that line does not survive this arm. The fact still has
      // to reach the operator, so it is re-issued after the cut. Reading the
      // draft here rather than afterwards is what makes that possible: by
      // then the pending slot is already cleared.
      let cancelled = case model.pending_submission {
        Some(_) ->
          Some(
            "Not sent: target changed from "
            <> model.session
            <> "; draft retained",
          )
        None -> None
      }
      let model =
        inbound.cancel_pending(model, "target change from " <> model.session)

      // Retirement runs while the old channel's session is still the visible
      // one: its outcome is reported against the identity that produced it,
      // and a sent request keeps that identity rather than acquiring the new
      // session's.
      let model = retire_previous(model)
      let target_strand = case
        model.session == cut.attachment.expected.session
      {
        True -> model.active_strand
        False -> "main"
      }
      let model =
        inbound.select_workspace(
          model,
          cut.attachment.expected.session,
          target_strand,
        )

      let model =
        Model(..model, scrollback: history_view.cancel(model.scrollback))

      // Only then is the old inbox drained. Draining first would discard
      // frames the retirement is entitled to reduce.
      sessions.discard(model.inbox)
      let adopted =
        Model(
          ..model,
          inbox: inbox,
          peer: case session_channel.socket(channel) {
            Some(socket) -> Attached(socket)
            None -> Replaying
          },
          channel: Some(channel),
          captured: None,
          note_board: None,
          note_selected: None,
          notes_requested: None,
          approvals: [],
          prompted_approvals: [],
          overlay: NoOverlay,
          creation_key: case creation_key {
            Some(key) if model.creation_key == Some(key) -> None
            Some(_) | None -> model.creation_key
          },
          workspace: workspace,
          active_strand: target_strand,
          agent_rows: case model.session == cut.attachment.expected.session {
            True -> model.agent_rows
            False -> []
          },
          strip: case model.session == cut.attachment.expected.session {
            True -> model.strip
            False -> agent_strip.new()
          },
          session: cut.attachment.expected.session,
          session_label: Some(#(cut.attachment.expected.session, name)),
          records: [],
          streams: [],
          tool_tails: [],
          interrupt: None,
          submitting: None,
          // The new attachment's cut replaces the transcript wholesale, and
          // the submissions waiting here were made against the old one.
          queued: [],
          awaiting_outcome: None,
          models: [],
          skills: [],
          next_id: 1,
          record_cache_valid: False,
          // Every session's primary strand is named `main`, so a watch or a
          // notice carried over from the old session would be judged
          // against the wrong baseline: the new session's first usage row
          // would be compared to the old session's last one and drawn as a
          // miss that never happened.
          cache_watch: dict.new(),
          cache_seen_seq: dict.new(),
          cache_pending: dict.new(),
          cache_fence: dict.new(),
          cache_notices: [],
          cache_outlook: "",
          scroll_offset: case model.scrollback.mode {
            history_view.Reading -> model.scroll_offset
            history_view.Live -> 0
          },
        )
        |> inbound.apply_cut(cut, view)

      // The adoption marker is written after the cut, not before it. ADR-009
      // makes that ordering a correctness rule: a recording is replayed by
      // the same reducer, and a marker ahead of its cut would move the
      // visible session before the frames that justify it.
      session_channel.adopted(channel)
      let adopted =
        adopted
        |> outbound.send_frame(protocol.models(1))
        |> inbound.request_visible_worktree
      let adopted = Model(..adopted, reconnect: ReconnectIdle)
      case cancelled {
        Some(notice) -> tui_model.append_system(adopted, notice)
        None -> adopted
      }
    }
  }
}

// Consume the old channel's outcome while its session identity is still the
// visible one. Closing an already-sent request cannot imply it was rejected.
fn retire_previous(model: Model) -> Model {
  case model.channel {
    Some(previous) -> {
      let #(closed, updates) =
        session_channel.retire(previous, "attachment replaced")
      list.fold(
        updates,
        Model(..model, channel: Some(closed)),
        inbound.apply_channel_update,
      )
    }
    None -> {
      case model.peer {
        Attached(previous) -> connection.close(previous)
        Disconnected | Preview | Replaying -> Nil
      }
      model
    }
  }
}

fn update_key(key: keys.Key, model: Model) -> Model {
  // The strip owns the keyboard only while nothing else is in front of it.
  // An overlay, including an approval the daemon opened on its own, takes
  // the cursor out of the strip, so closing it leaves the composer, not a
  // cursor waiting to turn the next Enter into a strand switch.
  let model = case strip_covered(model) {
    True -> Model(..model, strip: agent_strip.leave(model.strip))
    False -> model
  }
  case model.context.surface {
    context_view.Overview | context_view.All -> update_context_key(key, model)
    context_view.Hidden -> update_key_without_context(key, model)
  }
}

fn update_key_without_context(key: keys.Key, model: Model) -> Model {
  case model.queue_editor.surface {
    queue_editor.Inspector | queue_editor.Editor -> update_queue_key(key, model)
    queue_editor.Closed ->
      case model.summary_surface {
        queue_editor.Closed -> update_normal_key(key, model)
        queue_editor.Inspector | queue_editor.Editor ->
          update_summary_key(key, model)
      }
  }
}

fn update_normal_key(key: keys.Key, model: Model) -> Model {
  case key == keys.Ctrl("c") {
    True -> submit.quit(model)
    False ->
      case model.overlay {
        ModelSelector(selector) -> update_model_selector(key, model, selector)
        AgentInspector(selected) -> update_agent_inspector(key, model, selected)
        GoalInspector(state) -> update_goal_inspector(key, model, state)
        SessionSelector(selector) ->
          update_session_selector(key, model, selector)
        DaemonSelector(selector) -> update_daemon_selector(key, model, selector)
        PeerLinkManager(state) ->
          session_control.update_peer_link_manager(key, model, state)
        ApprovalInspector(panel) ->
          case approval_panel.update(key, panel) {
            approval_panel.Close -> Model(..model, overlay: NoOverlay)
            approval_panel.Continue(next) ->
              Model(..model, overlay: ApprovalInspector(next))
            approval_panel.Decide(record, choice) ->
              inbound.decide_captured_approval(model, record, choice)
          }
        NoOverlay -> update_main_key(key, model)
      }
  }
}

fn update_session_selector(
  key: keys.Key,
  model: Model,
  selector: sessions.State,
) -> Model {
  case sessions.update(key, selector) {
    sessions.Continue(next) -> Model(..model, overlay: SessionSelector(next))
    sessions.Close ->
      Model(
        ..model,
        overlay: NoOverlay,
        repaint_phase: !model.repaint_phase,
        notice: "session selection cancelled",
      )
    sessions.Choose(choice) -> submit.begin_session_switch(model, choice)
  }
}

fn update_goal_inspector(
  key: keys.Key,
  model: Model,
  state: focused_goal_panel.State,
) -> Model {
  case
    focused_goal_panel.update(
      key,
      state,
      layout.model_goal_inspector_area(model),
      render.goal_availability(model),
    )
  {
    focused_goal_panel.Close ->
      Model(
        ..model,
        overlay: NoOverlay,
        repaint_phase: !model.repaint_phase,
        notice: "goal inspector closed",
      )
    focused_goal_panel.Continue(next) ->
      Model(..model, overlay: GoalInspector(next))
    focused_goal_panel.Refresh -> surfaces.request_goal_status(model)
    focused_goal_panel.Pause ->
      surfaces.submit_goal_action(model, command.GoalPause)
    focused_goal_panel.Resume ->
      surfaces.submit_goal_action(model, command.GoalResume)
  }
}

fn update_daemon_selector(
  key: keys.Key,
  model: Model,
  selector: session_selector.State,
) -> Model {
  case session_selector.update(key, selector) {
    session_selector.Continue(next) ->
      Model(..model, overlay: DaemonSelector(next))
    session_selector.Close ->
      Model(..model, overlay: NoOverlay, notice: "session selection cancelled")
    session_selector.Choose(row) ->
      session_control.begin_open(model, row.session_id)
    session_selector.Link(row) ->
      case row.status {
        control_protocol.Resident(_) ->
          session_control.begin_peer_workspace_for_session(model, selector, row)
        _ -> Model(..model, notice: "open the saved session before linking it")
      }
    session_selector.NewSession -> session_control.create_session(model)
    session_selector.Delete(session_id) ->
      session_control.begin_delete(model, session_id)
    session_selector.Archive(session_id) ->
      session_control.begin_removal(model, session_id, Archive)
    session_selector.Restore(session_id) ->
      session_control.begin_removal(model, session_id, Restore)
    session_selector.ShowCollection(collection) ->
      session_control.load_catalogue_collection(model, "", None, collection)
    session_selector.Rename(session_id, name) ->
      session_control.begin_rename(model, session_id, name)
    session_selector.NextPage(after, revision) ->
      session_control.load_catalogue_collection(
        model,
        after,
        Some(revision),
        selector.collection,
      )
    session_selector.FirstPage ->
      session_control.load_catalogue_collection(
        model,
        "",
        None,
        selector.collection,
      )
  }
}

fn update_model_selector(
  key: keys.Key,
  model: Model,
  selector: model_selector.State,
) -> Model {
  case model_selector.update(key, selector) {
    model_selector.Continue(next) ->
      Model(..model, overlay: ModelSelector(next))
    model_selector.Close ->
      Model(
        ..model,
        overlay: NoOverlay,
        repaint_phase: !model.repaint_phase,
        notice: "model selection cancelled",
      )
    model_selector.Choose(name) -> {
      let switched = inbound.select_model(model, name)
      let selected =
        Model(
          ..switched,
          overlay: NoOverlay,
          repaint_phase: !model.repaint_phase,
          notice: "model: " <> name,
        )
        |> outbound.send_frame(protocol.set_model(
          model.next_id,
          model.active_strand,
          name,
        ))
      tui_model.append_system(selected, "active model changed to " <> name)
    }
  }
}

fn update_agent_inspector(
  key: keys.Key,
  model: Model,
  inspector: agents.Inspector,
) -> Model {
  use <- bool.lazy_guard(inspector.focus == agents.Composing, fn() {
    update_workspace_composer(key, model, inspector)
  })
  let rows = layout.displayed_agents(model)
  let changed = case key {
    keys.Tab ->
      Model(
        ..model,
        help_open: False,
        notes_open: False,
        worktree: worktree_view.State(
          ..model.worktree,
          focus: worktree_view.Composer,
        ),
        overlay: AgentInspector(
          agents.Inspector(..inspector, focus: agents.Composing),
        ),
      )
    keys.Escape | keys.F(2) | keys.Ctrl("o") ->
      Model(
        ..model,
        overlay: NoOverlay,
        repaint_phase: !model.repaint_phase,
        notice: "agents closed",
      )
    keys.Up ->
      Model(
        ..model,
        overlay: AgentInspector(
          agents.navigate(inspector, rows, agents.Previous)
          |> inbound.select_inspector_message(model.agent_messages),
        ),
      )
    keys.Down ->
      Model(
        ..model,
        overlay: AgentInspector(
          agents.navigate(inspector, rows, agents.Next)
          |> inbound.select_inspector_message(model.agent_messages),
        ),
      )
    keys.Char("1") -> select_agent_detail(model, inspector, agents.Overview)
    keys.Char("2") -> select_agent_detail(model, inspector, agents.Messages)
    keys.Char("3") -> select_agent_detail(model, inspector, agents.Notes)
    keys.Char("4") ->
      select_agent_detail(model, inspector, agents.Collaboration)
    keys.Char("[") if inspector.detail == agents.Messages ->
      select_agent_message(model, inspector, -1)
    keys.Char("]") if inspector.detail == agents.Messages ->
      select_agent_message(model, inspector, 1)
    keys.Char("[") if inspector.detail == agents.Notes ->
      surfaces.select_note(model, -1)
    keys.Char("]") if inspector.detail == agents.Notes ->
      surfaces.select_note(model, 1)
    keys.Char("r") if inspector.detail == agents.Notes ->
      surfaces.refresh_notes(model)
    keys.Ctrl("g") if inspector.detail == agents.Notes -> toggle_note_mode(model)
    keys.Ctrl("g") -> submit.toggle_details(model)
    keys.Char("n") ->
      Model(
        ..model,
        overlay: AgentInspector(
          agents.next_attention(inspector, rows)
          |> inbound.select_inspector_message(model.agent_messages),
        ),
      )
    keys.Char("p") -> session_control.begin_peer_workspace_for(model, inspector)
    keys.PageUp if inspector.detail == agents.Messages -> {
      let maximum = message_max_scroll(model, inspector)
      Model(
        ..model,
        overlay: AgentInspector(
          agents.Inspector(
            ..inspector,
            scroll: int.max(
              0,
              int.min(inspector.scroll, maximum) - message_page_step(model),
            ),
          ),
        ),
      )
    }
    keys.PageDown if inspector.detail == agents.Messages -> {
      let maximum = message_max_scroll(model, inspector)
      Model(
        ..model,
        overlay: AgentInspector(
          agents.Inspector(
            ..inspector,
            scroll: int.min(
              maximum,
              int.min(inspector.scroll, maximum) + message_page_step(model),
            ),
          ),
        ),
      )
    }
    keys.PageUp if inspector.detail == agents.Notes -> {
      let maximum = inbound.note_max_scroll(model)
      Model(
        ..model,
        note_scroll: int.max(
          0,
          int.min(model.note_scroll, maximum) - note_page_step(model),
        ),
      )
    }
    keys.PageDown if inspector.detail == agents.Notes ->
      Model(
        ..model,
        note_scroll: int.min(
          inbound.note_max_scroll(model),
          int.min(model.note_scroll, inbound.note_max_scroll(model))
            + note_page_step(model),
        ),
      )
    keys.PageUp ->
      Model(
        ..model,
        overlay: AgentInspector(
          agents.Inspector(
            ..inspector,
            scroll: int.max(0, inspector.scroll - 5),
          ),
        ),
      )
    keys.PageDown ->
      Model(
        ..model,
        overlay: AgentInspector(
          agents.Inspector(..inspector, scroll: inspector.scroll + 5),
        ),
      )
    keys.Char("a") -> inspect_agent_approval(model, inspector.selected)
    keys.Char("o") if inspector.detail == agents.Messages ->
      open_agent_message_sender(model, inspector)
    keys.Enter ->
      case tui_model.is_known_strand(model.strands, inspector.selected) {
        True -> submit.switch_active_strand(model, inspector.selected)
        False ->
          Model(
            ..model,
            notice: "Selected agent is unavailable; recipient unchanged",
          )
      }
    _ -> model
  }
  case changed.overlay {
    AgentInspector(next)
      if next.detail == agents.Notes && next.selected != inspector.selected
    ->
      surfaces.refresh_notes(
        Model(
          ..changed,
          note_selected: None,
          note_scroll: 0,
          note_mode: note_panel.Readable,
        ),
      )
    _ -> changed
  }
}

fn message_page_step(model: Model) -> Int {
  agent_message_panel.page_step(layout.message_detail_area(model))
}

fn message_max_scroll(model: Model, inspector: agents.Inspector) -> Int {
  let area = layout.message_detail_area(model)
  model.agent_messages
  |> agent_messages.for_strand(inspector.selected)
  |> agent_message_panel.max_scroll(inspector.message, area)
}

fn note_page_step(model: Model) -> Int {
  case model.overlay {
    AgentInspector(_) -> note_panel.page_step(layout.message_detail_area(model))
    _ -> note_panel.page_step(layout.note_detail_area(model))
  }
}

fn toggle_note_mode(model: Model) -> Model {
  let mode = case model.note_mode {
    note_panel.Readable -> note_panel.Raw
    note_panel.Raw -> note_panel.Readable
  }
  Model(..model, note_mode: mode, note_scroll: 0)
  |> tui_model.invalidate_transcript
}

fn select_agent_detail(
  model: Model,
  inspector: agents.Inspector,
  detail: agents.Detail,
) -> Model {
  let message = case detail {
    agents.Messages ->
      agent_messages.for_strand(model.agent_messages, inspector.selected)
      |> agent_message_panel.selected(inspector.message)
      |> option.map(agent_message_panel.identity)
    agents.Overview | agents.Notes | agents.Collaboration -> inspector.message
  }
  let owner_changed = case model.note_board {
    Some(board) -> board.strand != inspector.selected
    None -> True
  }
  let selected =
    Model(
      ..model,
      note_selected: case detail, owner_changed {
        agents.Notes, True -> None
        _, _ -> model.note_selected
      },
      note_scroll: case detail, owner_changed {
        agents.Notes, True -> 0
        _, _ -> model.note_scroll
      },
      overlay: AgentInspector(
        agents.Inspector(..inspector, detail:, scroll: 0, message:),
      ),
    )
  case detail {
    agents.Notes -> surfaces.refresh_notes(selected)
    agents.Overview | agents.Messages | agents.Collaboration -> selected
  }
}

fn select_agent_message(
  model: Model,
  inspector: agents.Inspector,
  amount: Int,
) -> Model {
  let messages =
    agent_messages.for_strand(model.agent_messages, inspector.selected)
  Model(
    ..model,
    overlay: AgentInspector(
      agents.Inspector(
        ..inspector,
        message: agent_message_panel.move(messages, inspector.message, amount),
        scroll: 0,
      ),
    ),
  )
}

// Opening a sender is an explicit workspace switch. Merely inspecting a send
// never moves the composer recipient or the transcript reading position.
fn open_agent_message_sender(
  model: Model,
  inspector: agents.Inspector,
) -> Model {
  let messages =
    agent_messages.for_strand(model.agent_messages, inspector.selected)
  case agent_message_panel.selected(messages, inspector.message) {
    None -> Model(..model, notice: "No observed message is selected")
    Some(item) ->
      case tui_model.is_known_strand(model.strands, item.source) {
        True -> submit.switch_active_strand(model, item.source)
        False ->
          Model(
            ..model,
            notice: "Message sender is unavailable; recipient unchanged",
          )
      }
  }
}

// The editor uses the ordinary submission path and its existing owner. A
// command may open another surface; only an ordinary edit returns to inspection.
fn update_workspace_composer(
  key: keys.Key,
  model: Model,
  inspector: agents.Inspector,
) -> Model {
  case key {
    keys.Escape | keys.F(2) | keys.Ctrl("o") ->
      Model(
        ..model,
        overlay: AgentInspector(
          agents.Inspector(..inspector, focus: agents.Browsing),
        ),
      )
    _ -> {
      let next = update_main_key(key, Model(..model, overlay: NoOverlay))

      // Commands transfer keyboard ownership to their visible destination.
      // Retaining inspection would conceal help or a diff navigator while
      // that surface was already consuming the next key.
      let editing =
        !next.help_open
        && !next.notes_open
        && next.worktree.focus == worktree_view.Composer
        && next.diff_view == model.diff_view
        && next.context.surface == context_view.Hidden
        && next.queue_editor.surface == queue_editor.Closed
        && next.summary_surface == queue_editor.Closed
      case next.overlay, editing {
        NoOverlay, True -> Model(..next, overlay: AgentInspector(inspector))
        _, _ -> next
      }
    }
  }
}

// Inspection opens the existing exact-request panel. It never chooses or sends
// a decision, and a disappeared request cannot be replaced by a different one.
fn inspect_agent_approval(model: Model, strand: String) -> Model {
  let found =
    layout.displayed_agents(model)
    |> list.find(fn(row) { row.id == strand })
    |> result.try(fn(row) { list.first(row.approvals) })
    |> result.try(fn(id) {
      list.find(model.approvals, fn(review) {
        review.id == id && review.status == approval.Pending
      })
    })
  case found {
    Ok(review) ->
      Model(
        ..model,
        overlay: ApprovalInspector(inbound.captured_approval_panel(
          model,
          review,
        )),
      )
    Error(Nil) -> Model(..model, notice: "No current approval for this agent")
  }
}

fn update_main_key(key: keys.Key, model: Model) -> Model {
  case model.strip.focus, layout.strip_height(model) > 0 {
    agent_strip.Browsing(_), True -> update_strip_key(key, model)

    // Every agent settled while the cursor was in the strip, so the strip
    // is gone. The keyboard returns to the composer with this key, rather
    // than an invisible cursor taking an Enter the operator meant to send.
    agent_strip.Browsing(_), False ->
      update_main_key_composing(
        key,
        Model(..model, strip: agent_strip.leave(model.strip)),
      )
    agent_strip.Composing, _ -> update_main_key_composing(key, model)
  }
}

// The strip owns the keyboard only between a Down from the idle composer and
// the key that hands it back. Opening goes through the same switch the
// workspace's Enter uses, so the draft is parked with its strand and the
// transcript, the composer's recipient and its badge change together.
fn update_strip_key(key: keys.Key, model: Model) -> Model {
  let pressed = case key {
    keys.Up -> agent_strip.Up
    keys.Down -> agent_strip.Down
    keys.Enter -> agent_strip.Select
    keys.Char("x") -> agent_strip.Halt
    keys.Escape -> agent_strip.Back
    _ -> agent_strip.Other
  }
  case agent_strip.key(model.strip, pressed, layout.strip_lines(model)) {
    agent_strip.Moved(strip) | agent_strip.Left(strip) -> Model(..model, strip:)
    agent_strip.Open(strip, strand) ->
      case strand == model.active_strand {
        True -> Model(..model, strip:)
        False -> submit.switch_active_strand(Model(..model, strip:), strand)
      }
    agent_strip.Stop(strip, strand) ->
      submit.stop_strand(Model(..model, strip:), strand)
    agent_strip.Pass(strip) ->
      update_main_key_composing(key, Model(..model, strip:))
  }
}

fn update_main_key_composing(key: keys.Key, model: Model) -> Model {
  case layout.diff_shown(model), model.worktree.focus, key {
    _, _, keys.Alt("q") -> submit.open_queue(model)

    // Ctrl+O ("open agents") is the chord a hand already on the keyboard
    // reaches; F2 stays for anyone who learned it. Ctrl+A was the other
    // candidate and is the composer's start-of-line.
    _, _, keys.F(2) | _, _, keys.Ctrl("o") -> submit.open_agents(model)
    True, _, keys.Ctrl("d") ->
      Model(
        ..model,
        worktree: worktree_view.State(
          ..model.worktree,
          focus: case model.worktree.focus {
            worktree_view.Composer -> worktree_view.Navigator
            worktree_view.Navigator -> worktree_view.Composer
          },
        ),
      )
    True, worktree_view.Navigator, _ -> update_diff_key(key, model)
    _, _, _ -> update_palette_key(key, model)
  }
}

fn update_palette_key(key: keys.Key, model: Model) -> Model {
  let suggestions =
    command.suggestions_with_skills(text_area.value(model.input), model.skills)
  case suggestions, command_palette_escape(key), key {
    [_, ..], True, _ ->
      Model(
        ..model,
        input: text_area.state_new(),
        command_selected: 0,
        notice: "commands closed",
      )
    [_, ..], False, keys.Up ->
      Model(
        ..model,
        command_selected: command.move_selection(
          model.command_selected,
          list.length(suggestions),
          False,
        ),
      )
    [_, ..], False, keys.Down ->
      Model(
        ..model,
        command_selected: command.move_selection(
          model.command_selected,
          list.length(suggestions),
          True,
        ),
      )
    [_, ..], False, keys.Tab ->
      case command.selected(suggestions, model.command_selected) {
        Some(value) ->
          Model(
            ..model,
            input: text_area.state_from_string(value),
            command_selected: 0,
          )
        None -> model
      }

    // Enter takes the highlighted row. A row that still wants an argument
    // is completed into the editor, as Tab would; a complete one is
    // submitted at once, so `/effort` plus a highlighted level is one
    // keystroke, not Tab then Enter.
    [_, ..], False, keys.Enter ->
      case command.selected(suggestions, model.command_selected) {
        Some(value) -> {
          let completed =
            Model(
              ..model,
              input: text_area.state_from_string(value),
              command_selected: 0,
            )
          case string.ends_with(value, " ") {
            True -> completed
            False -> submit.submit(completed)
          }
        }
        None -> submit.submit(model)
      }
    _, _, _ -> update_main_key_without_palette(key, model)
  }
}

fn strip_covered(model: Model) -> Bool {
  model.overlay != NoOverlay
  || model.context.surface != context_view.Hidden
  || model.queue_editor.surface != queue_editor.Closed
  || model.summary_surface != queue_editor.Closed
}

// Down walks forward through prompt history while the operator is browsing
// it. At the newest entry there is nothing further forward, so the same key
// steps down into the agent strip, the next thing below the composer.
fn down_from_composer(model: Model) -> Model {
  let lines = layout.strip_lines(model)
  case model.history_index, layout.strip_height(model) {
    0, rows if rows > 0 ->
      Model(
        ..model,
        strip: agent_strip.enter(model.strip, lines, model.active_strand),
      )
    _, _ -> submit.navigate_history(model, False)
  }
}

/// Reports whether Escape belongs to an open slash-command palette.
@internal
pub fn command_palette_escape(key: keys.Key) -> Bool {
  key == keys.Escape
}

fn update_main_key_without_palette(key: keys.Key, model: Model) -> Model {
  case key, model.diff_view {
    keys.Escape, DiffVisible ->
      Model(
        ..model,
        diff_view: DiffHidden,
        repaint_phase: !model.repaint_phase,
        notice: "changes closed",
      )
    _, _ -> update_conversation_key(key, model)
  }
}

fn update_conversation_key(key: keys.Key, model: Model) -> Model {
  case key, model.help_open, model.notes_open {
    keys.Char("r"), False, True -> surfaces.refresh_notes(model)
    keys.Up, False, True -> surfaces.select_note(model, -1)
    keys.Down, False, True -> surfaces.select_note(model, 1)
    keys.Char("["), False, True -> surfaces.select_note(model, -1)
    keys.Char("]"), False, True -> surfaces.select_note(model, 1)
    keys.Ctrl("g"), False, True -> toggle_note_mode(model)
    keys.Ctrl("g"), _, _ -> submit.toggle_details(model)
    keys.PageUp, False, True -> {
      let maximum = inbound.note_max_scroll(model)
      Model(
        ..model,
        note_scroll: int.max(
          0,
          int.min(model.note_scroll, maximum) - note_page_step(model),
        ),
      )
    }
    keys.PageDown, False, True ->
      Model(
        ..model,
        note_scroll: int.min(
          inbound.note_max_scroll(model),
          int.min(model.note_scroll, inbound.note_max_scroll(model))
            + note_page_step(model),
        ),
      )
    keys.PageUp, _, _ -> scroll_reading_panel(model, Older, 10)
    keys.PageDown, _, _ -> scroll_reading_panel(model, Newer, 10)
    keys.Escape, True, _ ->
      Model(
        ..model,
        help_open: False,
        scroll_offset: 0,
        repaint_phase: !model.repaint_phase,
        notice: "help closed",
      )
    keys.Escape, False, True ->
      Model(
        ..model,
        notes_open: False,
        note_board: None,
        note_selected: None,
        note_mode: note_panel.Readable,
        note_scroll: 0,
        notes_requested: None,
        scroll_offset: 0,
        repaint_phase: !model.repaint_phase,
        notice: "agent notes closed",
      )
    keys.Escape, False, False -> submit.interrupt_active(model)
    keys.Tab, False, False -> submit.toggle_submission_mode(model)
    keys.BackTab, False, False -> submit.toggle_agent_rail(model)
    keys.Up, False, False -> submit.navigate_history(model, True)
    keys.Down, False, False -> down_from_composer(model)
    keys.Enter, False, False -> submit.submit(model)
    keys.Backspace, False, False ->
      case text_area.value(model.input), model.attachments {
        "", [_, ..] -> {
          let attachments = composer.drop_last(model.attachments)
          Model(
            ..model,
            attachments:,
            notice: composer.summary(attachments)
              |> option.unwrap("paste removed"),
          )
        }
        _, _ -> {
          let input = text_area.backspace(model.input)
          Model(
            ..model,
            input:,
            history_index: 0,
            history_draft: text_area.value(input),
            command_selected: 0,
          )
        }
      }
    keys.Left, False, False ->
      Model(..model, input: text_area.move_cursor_left(model.input))
    keys.Right, False, False ->
      Model(..model, input: text_area.move_cursor_right(model.input))
    keys.Home, False, False ->
      Model(..model, input: text_area.move_to_line_start(model.input))
    keys.End, False, False ->
      case
        text_area.value(model.input) == "" && tui_model.reading_history(model)
      {
        True -> scroll_transcript(model, False, model.rendered_row_count)
        False -> Model(..model, input: text_area.move_to_line_end(model.input))
      }
    keys.Alt(character), False, False ->
      submit.interrupt_and_insert(model, character)
    keys.Char(character), False, False -> {
      let editor = text_area.textarea_new() |> text_area.with_max_lines(1)
      Model(
        ..model,
        input: text_area.insert_char(editor, model.input, character),
        history_index: 0,
        history_draft: text_area.value(model.input) <> character,
        command_selected: 0,
      )
    }
    _, _, _ -> model
  }
}

// Transcript movement has one definition for keyboard and wheel input. The
// offset is measured backward from the newest wrapped row, so moving toward
// the present clamps at zero and resumes tail following.
// A key while a selection is on screen: Escape only dismisses it, the way it
// closes any other surface before it reaches the interrupt. Detail expansion
// retains the chosen cells; editing and navigation dismiss the selection.
fn update_key_over_selection(key: keys.Key, model: Model) -> Model {
  case model.selection, key {
    Some(_), keys.Escape ->
      Model(..clear_selection(model), notice: "selection cleared")
    Some(_), keys.Ctrl("g") -> update_key(key, model)
    Some(_), _ | None, _ -> update_key(key, clear_selection(model))
  }
}

/// Escape owns cancellation before a queued final reply can send the intent.
/// Other input first observes bounded ready traffic, then the current lock.
@internal
pub fn update_ready_key(key: keys.Key, model: Model) -> Model {
  case model.pending_submission, key {
    Some(_), keys.Escape -> inbound.cancel_pending(model, "cancelled by Escape")
    Some(_), keys.Ctrl("c") ->
      submit.quit(inbound.cancel_pending(model, "terminal closed"))
    _, _ -> {
      let model = inbound.drain_connection(model, 64)
      case model.pending_submission, key {
        None, _ -> update_key_over_selection(key, model)
        Some(_), keys.PageUp -> scroll_transcript(model, True, 10)
        Some(_), keys.PageDown -> scroll_transcript(model, False, 10)
        Some(_), _ -> outbound.waiting_notice(model)
      }
    }
  }
}

/// Drops the mouse selection and the frame it was made on.
@internal
pub fn clear_selection(model: Model) -> Model {
  Model(..model, selection: None, selection_frame: None, selection_gutters: [])
}

/// A press starts over: whatever was highlighted is replaced by a fresh
/// selection in the area the press landed in.
@internal
pub fn begin_selection(model: Model, at: geometry.Position) -> Model {
  let screen = geometry.rect_new(0, 0, model.width, model.height)
  let #(_, body, _, _) = layout.layout(screen, model)
  let #(conversation, queue) = layout.queue_body_layout(body, model)
  let #(transcript, _, _) = layout.body_layout(conversation, model)
  use <- bool.lazy_guard(
    tui_model.reading_history(model)
      && at.y == transcript.position.y
      && at.x < geometry.right(transcript),
    fn() {
      scroll_transcript(clear_selection(model), False, model.rendered_row_count)
    },
  )
  case queue_row_hit(model, queue, at) {
    Some(selected) ->
      Model(
        ..clear_selection(model),
        queue_editor: queue_editor.State(
          ..model.queue_editor,
          surface: queue_editor.Inspector,
          selected:,
          preview_scroll: 0,
        ),
        notice: "queued input selected",
      )
    None ->
      case layout.diff_navigation_hit(model, at) {
        Some(selected) ->
          Model(
            ..model,
            selection: None,
            selection_frame: None,
            selection_gutters: [],
            diff_scroll_offset: 0,
            worktree: worktree_view.State(
              ..model.worktree,
              selected:,
              focus: worktree_view.Navigator,
            ),
          )
          |> tui_model.invalidate_transcript
        None -> {
          let #(shown, selection_gutters) = selection_display(model)
          Model(
            ..model,
            selection: Some(selection.start(layout.hit_area(model, at), at)),
            selection_frame: Some(shown),
            selection_gutters:,
          )
        }
      }
  }
}

/// A drag without a press this client saw, which a terminal that started
/// reporting mid-gesture can produce, selects nothing.
@internal
pub fn extend_selection(model: Model, at: geometry.Position) -> Model {
  case model.selection {
    Some(selected) ->
      Model(..model, selection: Some(selection.extend(selected, at)))
    None -> model
  }
}

/// The release is where the copy happens. A click, which selects nothing,
/// dismisses a settled highlight; a drag copies the cells as the frame on
/// display shows them and leaves the highlight up as confirmation until the
/// next key or wheel notch.
@internal
pub fn finish_selection(model: Model, at: geometry.Position) -> Model {
  case model.selection {
    None -> model
    Some(selected) -> {
      let selected = selection.extend(selected, at)
      case selection.is_click(selected) {
        True ->
          Model(
            ..model,
            selection: None,
            selection_frame: None,
            selection_gutters: [],
          )
        False -> {
          let shown =
            option.lazy_unwrap(model.selection_frame, fn() {
              selection_display(model).0
            })
          let text = case selection_covers_transcript(model, selected) {
            True ->
              transcript_selection_text(
                shown,
                selected,
                model.selection_gutters,
              )
            False -> selection.text(shown, selected)
          }
          write_clipboard(model.clipboard, text)
          Model(
            ..model,
            selection: Some(selected),
            notice: selection.copied_notice(
              list.length(selection.rows(selected)),
            ),
          )
        }
      }
    }
  }
}

// Only the transcript has speaker gutters. Other selectable panels carry
// ordinary whitespace whose meaning this projection cannot reinterpret.
fn selection_covers_transcript(
  model: Model,
  selected: selection.Selection,
) -> Bool {
  let screen = geometry.rect_new(0, 0, model.width, model.height)
  let #(_, body_area, _, _) = layout.layout(screen, model)
  let #(conversation, _) = layout.queue_body_layout(body_area, model)
  let #(transcript_panel, _, _) = layout.body_layout(conversation, model)
  selected.area == layout.panel_inner(transcript_panel)
  && !layout.main_shows_diff(model)
}

/// Reads selected transcript cells without copying their visual left gutter.
///
/// Fixed gutter widths are captured from the private transcript layout which
/// painted the frame. Indentation after that prefix is authored text and
/// remains byte-for-byte intact. Rows remain separate because the frame does
/// not encode whether Markdown ended a block or wrapped one; guessing from row
/// width would join real newlines or split real paragraphs.
///
/// ## Examples
///
/// ```gleam
/// // tui.transcript_selection_text(frame, selected, gutters)
/// ```
@internal
pub fn transcript_selection_text(
  shown: buffer.Buffer,
  selected: selection.Selection,
  gutters: List(#(Int, Int)),
) -> String {
  selection.rows(selected)
  |> list.map(fn(row) {
    let prefix = list.key_find(gutters, row.position.y) |> result.unwrap(0)
    let gutter =
      int.clamp(
        selected.area.position.x + prefix - row.position.x,
        0,
        row.size.width,
      )
    frame.row_text(
      shown,
      row.position.x + gutter,
      row.position.y,
      row.size.width - gutter,
    )
  })
  |> string.join("\n")
}

/// The transcript is bottom-addressed in `rendered_gutters`, while screen rows
/// run top to bottom. This is the metadata twin of `render_rows`'s viewport
/// slice and reverse; the completed frame caches this map beside its cells.
@internal
pub fn selection_gutters_on_display(model: Model) -> List(#(Int, Int)) {
  let screen = geometry.rect_new(0, 0, model.width, model.height)
  let #(_, body_area, _, _) = layout.layout(screen, model)
  let #(conversation, _) = layout.queue_body_layout(body_area, model)
  let #(transcript_panel, _, _) = layout.body_layout(conversation, model)
  let area = layout.panel_inner(transcript_panel)
  model.rendered_gutters
  |> list.drop(model.scroll_offset + tui_model.viewport_backlog(model))
  |> list.take(area.size.height)
  |> list.reverse
  |> list.index_map(fn(gutter, index) { #(area.position.y + index, gutter) })
}

// The frame and its copy layout come from one completed cache entry. A paced
// scroll may leave that entry deliberately stale; taking either half from the
// current model would pair old cells with new row metadata.
fn selection_display(model: Model) -> #(buffer.Buffer, List(#(Int, Int))) {
  let screen = geometry.rect_new(0, 0, model.width, model.height)
  case model.frame_cache {
    Some(FrameCache(rendered: #(shown, _), selection_gutters:, ..)) -> #(
      shown,
      selection_gutters,
    )
    None -> #(
      render.render_frame(model, screen).0,
      selection_gutters_on_display(model),
    )
  }
}

// Etui draws its frames with `io:put_chars`, so a sequence printed the same
// way lands on the same terminal in order with them.
fn write_clipboard(clipboard: Clipboard, text: String) -> Nil {
  case clipboard {
    TerminalClipboard -> io.print(selection.clipboard_sequence(text))
    NoClipboard -> Nil
  }
}

// The gesture starts from the row the reader is looking at, which is the
// stored offset plus whatever the paced walk is still holding back: the
// viewport is drawn from that sum, and measuring a scroll against the
// stored offset alone would answer a request for older text by jumping the
// backlog forward to the tail. Folding it in also leaves the paths that
// ask for the latest row landing at zero, since they scroll by the whole
// row count and the bound clamps there.
fn scroll_transcript(model: Model, older: Bool, rows: Int) -> Model {
  let offset =
    scroll_offset(
      model.scroll_offset + tui_model.viewport_backlog(model),
      older,
      rows,
    )
    |> projection.bounded_scroll_offset(
      model.rendered_row_count,
      layout.transcript_viewport_height(model),
    )
  let model =
    Model(..model, scroll_offset: offset, notice: case offset == 0 && !older {
      True -> "following output"
      False -> "scrollback · End returns to latest (empty prompt)"
    })
  case model.help_open || model.notes_open, model.captured {
    True, _ | _, None -> model
    False, Some(#(cut, view)) -> {
      case offset == 0 && !older {
        True -> {
          let history = history_view.resume(model.scrollback)
          inbound.apply_cut(Model(..model, scrollback: history), cut, view)
        }
        False -> {
          let history = history_view.freeze(model.scrollback)
          let history = case
            older
            && offset + layout.transcript_viewport_height(model)
            >= model.rendered_row_count - history_prefetch_rows(model)
          {
            True ->
              history_view.older(
                history,
                history_view.branch(history, view).unloaded,
              )
            False -> history
          }
          inbound.service_history(Model(..model, scrollback: history))
        }
      }
    }
  }
}

// Start the existing bounded read two screens before the loaded boundary,
// leaving time for the reply while the reader continues scrolling.
fn history_prefetch_rows(model: Model) -> Int {
  int.max(10, 2 * layout.transcript_viewport_height(model))
}

/// A page can contain only other strands, and collapsing details can leave
/// fewer rows than one screen. Continue the bounded demand until older rows
/// exist above this viewport. A busy lane keeps Wanted for the next event;
/// the user does not need another wheel gesture to retry the same read.
///
/// The guard repeats the two scalars `history_view.older` itself tests. This
/// runs on every terminal event, including idle ticks, and the ancestry
/// projection below walks the whole retained window to produce an argument a
/// pending or exhausted request would discard.
@internal
pub fn request_history_for_view(model: Model) -> Model {
  use <- bool.guard(
    model.scrollback.mode != history_view.Reading
      || model.scrollback.request != history_view.Quiet
      || model.scrollback.before_seq <= 1
      || model.help_open
      || model.notes_open
      || model.scroll_offset + layout.transcript_viewport_height(model)
      < model.rendered_row_count - history_prefetch_rows(model),
    model,
  )
  case model.captured {
    None -> model
    Some(#(_, view)) ->
      Model(
        ..model,
        scrollback: history_view.older(
          model.scrollback,
          history_view.branch(model.scrollback, view).unloaded,
        ),
      )
  }
}

// Page keys follow the reading surface's focus. The default side pane never
// takes scrollback keys from a person typing in the conversation composer.
fn scroll_reading_panel(
  model: Model,
  direction: ScrollDirection,
  rows: Int,
) -> Model {
  case
    layout.main_shows_diff(model)
    || model.worktree.focus == worktree_view.Navigator
  {
    True -> scroll_diff(model, direction, layout.diff_patch_height(model))
    False -> scroll_transcript(model, direction == Older, rows)
  }
}

/// Scrolls the surface under `position` by one wheel notch in
/// `direction`.
@internal
pub fn scroll_at(
  model: Model,
  position: geometry.Position,
  direction: ScrollDirection,
) -> Model {
  use <- bool.lazy_guard(model.context.surface != context_view.Hidden, fn() {
    scroll_context(model, case direction {
      Older -> -3
      Newer -> 3
    })
  })
  case
    layout.main_shows_diff(model)
    || {
      layout.diff_shown(model)
      && geometry.contains(layout.active_diff_panel(model), position)
    }
  {
    True -> scroll_diff(model, direction, 3)
    False -> scroll_transcript(model, direction == Older, 3)
  }
}

fn scroll_diff(model: Model, direction: ScrollDirection, rows: Int) -> Model {
  let current =
    projection.bounded_scroll_offset(
      model.diff_scroll_offset,
      model.diff_row_count,
      layout.diff_patch_height(model),
    )
  let offset =
    scroll_offset(current, direction == Older, rows)
    |> projection.bounded_scroll_offset(
      model.diff_row_count,
      layout.diff_patch_height(model),
    )
  Model(
    ..model,
    diff_scroll_offset: offset,
    notice: "scrolling captured changes",
  )
}

/// Moves a transcript offset without allowing it to cross the live tail.
///
/// This is internal because transcript offsets belong to the terminal model;
/// it is public only so the input law can be pinned without running a PTY.
///
/// ## Examples
///
/// ```gleam
/// assert tui.scroll_offset(3, False, 10) == 0
/// assert tui.scroll_offset(3, True, 10) == 13
/// ```
@internal
pub fn scroll_offset(offset: Int, older: Bool, rows: Int) -> Int {
  case older {
    True -> offset + rows
    False -> int.max(0, offset - rows)
  }
}

/// The model catalogue the preview mode shows.
@internal
pub fn demo_models() -> List(protocol.ModelInfo) {
  [
    ModelInfo(
      name: "baseten-kimi-k3",
      dialect: "openai",
      model_id: "moonshotai/Kimi-K3",
      roles: ["default"],
      active: ["default"],
    ),
    ModelInfo(
      name: "baseten-deepseek-v4-flash",
      dialect: "openai",
      model_id: "deepseek-ai/DeepSeek-V4-Flash-0731",
      roles: ["fast"],
      active: [],
    ),
    ModelInfo(
      name: "baseten-glm-5-3",
      dialect: "openai",
      model_id: "zai-org/GLM-5.3",
      roles: ["deep"],
      active: [],
    ),
    ModelInfo(
      name: "baseten-glm-5-3-flash",
      dialect: "openai",
      model_id: "zai-org/GLM-5.3-Flash",
      roles: ["fast"],
      active: [],
    ),
  ]
}

/// The strand roster the preview mode shows.
@internal
pub fn demo_strands() -> List(protocol.Strand) {
  [
    Strand(id: "main", name: Some("main"), live_phase: Some("streaming")),
    Strand(
      id: "sub:main/catalog-audit-27af",
      name: Some("catalog audit"),
      live_phase: Some("running tools"),
    ),
    Strand(
      id: "sub:main/terminal-qa-8c1e",
      name: Some("terminal qa"),
      live_phase: None,
    ),
  ]
}

// Mouse selection reuses the rectangle already reserved for rendering. The
// passive card maps one visible message per row; the wide inspector maps its
// left-hand list after the heading. Compact inspection shows only the selected
// preview, so a click there leaves identity unchanged.
fn queue_row_hit(
  model: Model,
  area: Rect,
  at: geometry.Position,
) -> Option(Int) {
  use <- bool.guard(!geometry.contains(layout.panel_inner(area), at), None)
  let rows = layout.queue_rows(model)
  let inner = layout.panel_inner(area)
  let index = case model.queue_editor.surface {
    queue_editor.Closed -> at.y - inner.position.y
    queue_editor.Inspector -> {
      let content = layout.queue_content_area(area)
      let list_width = int.min(36, { content.size.width * 2 } / 5)
      let visible = int.max(1, content.size.height - 1)
      let list_area =
        geometry.rect_new(
          content.position.x,
          content.position.y + 1,
          list_width,
          int.min(visible, list.length(rows)),
        )
      case
        content.size.width >= 70
        && content.size.height >= 6
        && geometry.contains(list_area, at)
      {
        True -> {
          let offset =
            int.min(
              model.queue_editor.selected,
              int.max(0, list.length(rows) - visible),
            )
          offset + at.y - list_area.position.y
        }
        False -> -1
      }
    }
    queue_editor.Editor -> -1
  }
  let visible = case model.queue_editor.surface {
    queue_editor.Closed -> int.min(3, list.length(rows))
    queue_editor.Inspector -> list.length(rows)
    queue_editor.Editor -> 0
  }
  case index >= 0 && index < visible {
    True -> Some(index)
    False -> None
  }
}

fn update_queue_key(key: keys.Key, model: Model) -> Model {
  let state = model.queue_editor
  case key, state.surface {
    keys.Ctrl("c"), _ -> submit.quit(model)
    keys.Escape, queue_editor.Editor ->
      Model(
        ..model,
        queue_editor: queue_editor.State(
          ..state,
          surface: queue_editor.Inspector,
          fetch: None,
          awaiting: None,
        ),
      )
    keys.Escape, queue_editor.Inspector ->
      Model(
        ..model,
        queue_editor: queue_editor.State(
          ..state,
          surface: queue_editor.Closed,
          fetch: None,
          awaiting: None,
        ),
      )
    keys.Up, queue_editor.Inspector ->
      Model(
        ..model,
        queue_editor: queue_editor.State(
          ..state,
          selected: int.max(0, state.selected - 1),
          preview_scroll: 0,
        ),
      )
    keys.Down, queue_editor.Inspector ->
      Model(
        ..model,
        queue_editor: queue_editor.State(
          ..state,
          selected: int.min(
            int.max(0, list.length(layout.queue_rows(model)) - 1),
            state.selected + 1,
          ),
          preview_scroll: 0,
        ),
      )
    keys.PageUp, queue_editor.Inspector -> {
      let area = layout.queue_preview_area(model)
      let maximum =
        queue_panel.max_scroll(layout.queue_rows(model), state.selected, area)
      Model(
        ..model,
        queue_editor: queue_editor.State(
          ..state,
          preview_scroll: int.max(
            0,
            int.min(state.preview_scroll, maximum) - queue_panel.page_rows(area),
          ),
        ),
      )
    }
    keys.PageDown, queue_editor.Inspector -> {
      let area = layout.queue_preview_area(model)
      let maximum =
        queue_panel.max_scroll(layout.queue_rows(model), state.selected, area)
      Model(
        ..model,
        queue_editor: queue_editor.State(
          ..state,
          preview_scroll: int.min(
            maximum,
            int.min(state.preview_scroll, maximum) + queue_panel.page_rows(area),
          ),
        ),
      )
    }
    keys.Char("e"), queue_editor.Inspector -> resume_queue_draft(model)
    keys.Enter, queue_editor.Inspector -> select_queue_input(model)
    keys.Ctrl("r"), queue_editor.Editor -> reconcile_queue_draft(model)
    keys.Ctrl("s"), queue_editor.Editor -> save_queue_draft(model)
    _, queue_editor.Editor ->
      edit_queue_text(model, fn(input) { queue_text_key(key, input) })
    _, queue_editor.Closed | _, queue_editor.Inspector -> model
  }
}

fn resume_queue_draft(model: Model) -> Model {
  case model.queue_editor.draft {
    Some(_) ->
      Model(
        ..model,
        queue_editor: queue_editor.State(
          ..model.queue_editor,
          surface: queue_editor.Editor,
          fetch: None,
          awaiting: None,
          request_id: None,
          message: "Retained draft resumed · Ctrl+s saves · Esc returns to inspection",
        ),
      )
    None ->
      Model(
        ..model,
        queue_editor: queue_editor.State(
          ..model.queue_editor,
          message: "No retained queue draft to resume",
        ),
      )
  }
}

fn select_queue_input(model: Model) -> Model {
  let state = model.queue_editor
  case list.first(list.drop(layout.queue_rows(model), state.selected)) {
    Ok(row) ->
      case
        retained_other_draft(state.draft, row, tui_model.queue_namespace(model)),
        row.editing
      {
        True, _ ->
          Model(
            ..model,
            queue_editor: queue_editor.State(
              ..state,
              message: "Retained draft belongs to another input · e resumes it; browsing remains available",
            ),
          )
        False, snapshot_view.Editable -> {
          let fetch =
            queue_editor.Fetch(
              tui_model.queue_owner(model),
              tui_model.queue_namespace(model),
              row.strand,
              row.id,
            )
          surfaces.service_queue_read(
            Model(
              ..model,
              queue_editor: queue_editor.State(
                ..state,
                fetch: Some(fetch),
                awaiting: None,
                request_id: None,
                message: "Waiting for the full queued input…",
              ),
            ),
          )
        }
        False, snapshot_view.ReadOnly ->
          Model(
            ..model,
            queue_editor: queue_editor.State(
              ..state,
              message: "This queued input is read-only for this attachment",
            ),
          )
      }
    Error(Nil) -> model
  }
}

fn retained_other_draft(
  draft: Option(queue_editor.Draft),
  row: snapshot_view.PendingInput,
  namespace: String,
) -> Bool {
  case draft {
    Some(draft) -> {
      let dirty =
        text_area.value(draft.input) != draft.document.text
        || draft.delivery != queue_editor.Editable
      dirty
      && {
        draft.namespace != namespace
        || draft.document.id != row.id
        || draft.document.strand != row.strand
      }
    }
    None -> False
  }
}

fn reconcile_queue_draft(model: Model) -> Model {
  let state = model.queue_editor
  case state.draft {
    Some(draft) if draft.delivery != queue_editor.Saving -> {
      use <- bool.guard(
        draft.namespace != tui_model.queue_namespace(model),
        Model(
          ..model,
          queue_editor: queue_editor.State(
            ..state,
            message: "Queue namespace changed; this retained draft cannot be rebound",
          ),
        ),
      )
      let fetch =
        queue_editor.Fetch(
          tui_model.queue_owner(model),
          tui_model.queue_namespace(model),
          draft.document.strand,
          draft.document.id,
        )
      surfaces.service_queue_read(
        Model(
          ..model,
          queue_editor: queue_editor.State(
            ..state,
            fetch: Some(fetch),
            message: "Explicitly reconciling with the current queue…",
          ),
        ),
      )
    }
    Some(_) | None -> model
  }
}

fn save_queue_draft(model: Model) -> Model {
  case model.queue_editor.draft, model.channel {
    Some(draft), Some(channel) if draft.delivery == queue_editor.Editable -> {
      let available =
        session_channel.mutation_available(channel)
        && tui_model.queue_owner(model) == draft.owner
        && tui_model.queue_namespace(model) == draft.namespace
      case available {
        True ->
          outbound.send_frame(
            Model(
              ..model,
              pending_submission: Some(OverlaySubmission),
              queue_editor: queue_editor.State(
                ..model.queue_editor,
                draft: Some(
                  queue_editor.Draft(..draft, delivery: queue_editor.Saving),
                ),
                message: "Saving this revision…",
              ),
            ),
            protocol.edit_queued_input(
              model.next_id,
              draft.document,
              text_area.value(draft.input),
            ),
          )
        False ->
          Model(
            ..model,
            queue_editor: queue_editor.State(
              ..model.queue_editor,
              message: "Attachment changed or command lane is busy; draft retained",
            ),
          )
      }
    }
    _, _ -> model
  }
}

fn edit_queue_text(
  model: Model,
  edit: fn(text_area.TextAreaState) -> text_area.TextAreaState,
) -> Model {
  case model.queue_editor.draft {
    Some(draft) if draft.delivery == queue_editor.Editable ->
      Model(
        ..model,
        queue_editor: queue_editor.State(
          ..model.queue_editor,
          draft: Some(queue_editor.Draft(..draft, input: edit(draft.input))),
        ),
      )
    Some(_) | None -> model
  }
}

fn queue_text_key(
  key: keys.Key,
  input: text_area.TextAreaState,
) -> text_area.TextAreaState {
  case key {
    keys.Enter ->
      text_area.newline(
        text_area.textarea_new() |> text_area.with_max_lines(0),
        input,
      )
    keys.Backspace -> text_area.backspace(input)
    keys.Left -> text_area.move_cursor_left(input)
    keys.Right -> text_area.move_cursor_right(input)
    keys.Up -> text_area.move_cursor_up(input)
    keys.Down -> text_area.move_cursor_down(input)
    keys.Home | keys.Ctrl("a") -> text_area.move_to_line_start(input)
    keys.End | keys.Ctrl("e") -> text_area.move_to_line_end(input)
    keys.Char(value) ->
      text_area.insert_char(text_area.textarea_new(), input, value)
    _ -> input
  }
}

fn insert_queue_paste(
  input: text_area.TextAreaState,
  text: String,
) -> text_area.TextAreaState {
  list.fold(string.to_graphemes(text), input, fn(state, char) {
    case char {
      "\n" -> queue_text_key(keys.Enter, state)
      _ -> queue_text_key(keys.Char(char), state)
    }
  })
}

fn update_diff_key(key: keys.Key, model: Model) -> Model {
  case key {
    keys.Ctrl("c") -> submit.quit(model)
    keys.Up -> select_diff_file(model, -1)
    keys.Down -> select_diff_file(model, 1)
    keys.Enter ->
      Model(
        ..model,
        worktree: worktree_view.State(
          ..model.worktree,
          focus: worktree_view.Composer,
        ),
      )
    keys.Char("r") -> inbound.refresh_worktree(model)
    keys.Escape ->
      Model(
        ..model,
        diff_view: DiffHidden,
        worktree: worktree_view.State(
          ..model.worktree,
          focus: worktree_view.Composer,
        ),
      )
    keys.PageUp -> scroll_diff(model, Older, layout.diff_patch_height(model))
    keys.PageDown -> scroll_diff(model, Newer, layout.diff_patch_height(model))
    _ -> model
  }
}

fn select_diff_file(model: Model, delta: Int) -> Model {
  let selected =
    int.clamp(
      model.worktree.selected + delta,
      0,
      list.length(worktree_view.labels(model.worktree)) - 1,
    )
  Model(
    ..model,
    worktree: worktree_view.State(..model.worktree, selected:),
    diff_scroll_offset: 0,
  )
  |> tui_model.invalidate_transcript
}

fn update_summary_key(key: keys.Key, model: Model) -> Model {
  let screen = layout.model_screen(model)
  let body = layout.summary_body_area(screen)
  let viewport = body.size.height
  let maximum =
    int.max(
      0,
      list.length(render.summary_lines(model, body.size.width)) - viewport,
    )
  let current = int.min(model.summary_scroll, maximum)
  case key {
    keys.Ctrl("c") -> submit.quit(model)
    keys.Escape -> Model(..model, summary_surface: queue_editor.Closed)
    keys.Char("r") ->
      surfaces.service_jobs_read(
        Model(..model, jobs_refresh: worktree_view.Requested, summary_scroll: 0),
      )
    keys.Char("1") ->
      Model(..model, summary_tab: summary_panel.Completion, summary_scroll: 0)
    keys.Char("2") ->
      Model(..model, summary_tab: summary_panel.Usage, summary_scroll: 0)
    keys.Char("3") ->
      Model(..model, summary_tab: summary_panel.Jobs, summary_scroll: 0)
    keys.Char("[") -> select_summary_job(model, -1)
    keys.Char("]") -> select_summary_job(model, 1)
    keys.Up -> Model(..model, summary_scroll: int.max(0, current - 1))
    keys.Down -> Model(..model, summary_scroll: int.min(maximum, current + 1))
    keys.PageUp ->
      Model(..model, summary_scroll: int.max(0, current - viewport))
    keys.PageDown ->
      Model(..model, summary_scroll: int.min(maximum, current + viewport))
    _ -> model
  }
}

fn select_summary_job(model: Model, delta: Int) -> Model {
  case model.summary_tab, model.jobs {
    summary_panel.Jobs, Some(board) if board.strand == model.active_strand ->
      Model(
        ..model,
        summary_job_selected: int.clamp(
          model.summary_job_selected + delta,
          0,
          int.max(0, list.length(board.jobs) - 1),
        ),
        summary_scroll: 0,
      )
    summary_panel.Completion, _
    | summary_panel.Usage, _
    | summary_panel.Jobs, None
    | summary_panel.Jobs, Some(_)
    -> model
  }
}

fn update_context_key(key: keys.Key, model: Model) -> Model {
  let state = model.context
  let viewport = layout.panel_inner(layout.model_screen(model)).size.height
  case key {
    keys.Ctrl("c") -> submit.quit(model)
    keys.Escape ->
      Model(
        ..model,
        context: context_view.State(..state, surface: context_view.Hidden),
      )
    keys.Char("r") ->
      surfaces.service_context_read(
        Model(
          ..model,
          context: context_view.State(
            ..context_view.invalidate(state),
            scroll: 0,
          ),
        ),
      )
    keys.Char("a") ->
      Model(
        ..model,
        context: context_view.State(
          ..state,
          scroll: 0,
          surface: case state.surface {
            context_view.All -> context_view.Overview
            context_view.Overview | context_view.Hidden -> context_view.All
          },
        ),
      )
    keys.Up -> scroll_context(model, -1)
    keys.Down -> scroll_context(model, 1)
    keys.PageUp -> scroll_context(model, 0 - viewport)
    keys.PageDown -> scroll_context(model, viewport)
    _ -> model
  }
}

fn scroll_context(model: Model, delta: Int) -> Model {
  let inner = layout.panel_inner(layout.model_screen(model))
  let maximum =
    int.max(
      0,
      list.length(context_panel.lines(model.context, inner.size.width))
        - inner.size.height,
    )
  let current = int.min(model.context.scroll, maximum)
  Model(
    ..model,
    context: context_view.State(
      ..model.context,
      scroll: int.clamp(current + delta, 0, maximum),
    ),
  )
}
