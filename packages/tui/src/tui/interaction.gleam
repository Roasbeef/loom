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
////
//// ## Flow
////
//// `update_ready_key` → `update_key` → `update_normal_key` → `update_main_key` → `update_palette_key` → `update_conversation_key`
////
//// 1. `update_ready_key` lets Escape or Ctrl+C cancel a queued final reply first;
////    any other key drains bounded socket traffic so it acts on the newest state.
//// 2. `update_key_over_selection` clears a mouse selection unless the key keeps it,
////    then `update_key` takes the strip out of the keyboard's path when something
////    covers it.
//// 3. The context view, queue editor and summary surfaces each own the key in turn
////    (`update_context_key`, `update_queue_key`, `update_summary_key`); if none is
////    open, `update_key_without_context` falls to `update_normal_key`.
//// 4. `update_normal_key` quits on Ctrl+C and otherwise hands the key to the open
////    overlay's handler (`update_model_selector`, `update_agent_inspector`,
////    `update_goal_inspector`, `update_daemon_selector`), or to `update_main_key`.
//// 5. `update_main_key` sends the key to `update_strip_key` while the agent strip
////    has the cursor and to `update_main_key_composing` otherwise, which routes
////    the diff navigator (`update_diff_key`) or on to `update_palette_key`.
//// 6. Keys the command palette does not take pass `update_main_key_without_palette`
////    (it closes the diff on Escape) to `update_conversation_key`, which
////    scrolls, toggles the notes and help surfaces and edits the composer.
//// 7. Pastes enter at `handle_paste`; the mouse enters at `begin_selection`,
////    `extend_selection`, `finish_selection` and `scroll_at`.

import etui/buffer
import etui/geometry.{type Rect}
import etui/keys
import etui/widgets/textarea as text_area
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/agent_messages
import session_view/agent_roster
import session_view/approval
import session_view/cache_watch
import session_view/command
import session_view/commands
import session_view/composer
import session_view/connection_event
import session_view/context_view
import session_view/history_view
import session_view/model.{Attached, OverlaySubmission, Shared} as session_model
import session_view/msg
import session_view/outbound
import session_view/pasted_image
import session_view/protocol.{ModelInfo, Strand}
import session_view/queue_request
import session_view/session_channel
import session_view/shared_set
import session_view/snapshot_view
import session_view/surfaces
import session_view/worktree_view
import tui/agent_message_panel
import tui/agent_strip
import tui/agents
import tui/approval_panel
import tui/attachment
import tui/buffered
import tui/context_panel
import tui/daemon/protocol as control_protocol
import tui/effect
import tui/focused_goal_panel
import tui/frame
import tui/image_drain
import tui/inbound
import tui/job
import tui/layout
import tui/model.{
  type Model, type ScrollDirection, AccessManager, AgentInspector,
  ApprovalInspector, Caches, DaemonSelector, DiffHidden, DiffVisible, FrameCache,
  GoalInspector, Model, ModelSelector, Newer, NoClipboard, NoOverlay, Older,
  PeerLinkManager, ReconnectAttempting, ReconnectIdle, ReconnectSpent,
  TerminalClipboard, View,
} as tui_model
import tui/model_selector
import tui/note_panel
import tui/peer_links
import tui/projection
import tui/queue_editor
import tui/queue_panel
import tui/rail
import tui/rail_tabs
import tui/render
import tui/selection
import tui/session_control
import tui/session_selector
import tui/side_surfaces
import tui/submit
import tui/summary_panel
import tui/view_set

/// The rename overlay owns pasted text just as it owns character keys. It
/// must never leave a pasted title in the hidden conversation composer.
/// `image` is what the host found when it read the path the paste names,
/// before the step; the composer attaches it rather than reading the file.
@internal
pub fn handle_paste(
  model: Model,
  text: String,
  image: Result(Option(pasted_image.Image), String),
) -> Model {
  case model.view.overlay {
    DaemonSelector(
      session_selector.State(prompt: session_selector.Renaming(..), ..) as selector,
    ) -> update_daemon_selector(keys.Char(text), model, selector)
    NoOverlay ->
      case layout.diff_shown(model), model.shared.worktree.focus {
        True, worktree_view.Navigator -> model
        _, _ -> handle_underlay_paste(model, text, image)
      }
    AgentInspector(agents.Inspector(focus: agents.Composing, ..)) ->
      handle_underlay_paste(model, text, image)
    PeerLinkManager(
      peer_links.State(prompt: peer_links.EditingTargetStrand, ..) as state,
    ) -> session_control.update_peer_link_manager(keys.Char(text), model, state)
    AgentInspector(_)
    | ModelSelector(_)
    | GoalInspector(_)
    | DaemonSelector(_)
    | ApprovalInspector(_)
    | PeerLinkManager(_)
    | AccessManager(_) -> model
  }
}

fn handle_underlay_paste(
  model: Model,
  text: String,
  image: Result(Option(pasted_image.Image), String),
) -> Model {
  use <- bool.guard(model.shared.context.surface != context_view.Hidden, model)
  case model.view.queue_editor.surface {
    queue_editor.Editor ->
      edit_queue_text(model, fn(input) { insert_queue_paste(input, text) })
    queue_editor.Inspector -> model
    queue_editor.Closed ->
      case model.view.summary_surface {
        queue_editor.Closed -> handle_composer_paste(model, text, image)
        queue_editor.Editor | queue_editor.Inspector -> model
      }
  }
}

fn handle_composer_paste(
  model: Model,
  text: String,
  image: Result(Option(pasted_image.Image), String),
) -> Model {
  case model.shared.pending_submission {
    Some(_) -> tui_model.run_shared(model, outbound.waiting_notice)
    None -> paste_unlocked(model, text, image)
  }
}

// The host read the file this paste names before the step
// (`runtime.message`), and the message carried what it found here.
fn paste_unlocked(
  model: Model,
  text: String,
  image: Result(Option(pasted_image.Image), String),
) -> Model {
  case image {
    Error(reason) -> tui_model.append_error(model, reason)
    Ok(Some(image)) -> add_attachment(model, composer.ImageAttachment(image))
    Ok(None) ->
      case composer.classify(text) {
        composer.Inline(text) -> {
          // Paste follows the editor's insertion path so an existing draft
          // and the cursor's suffix remain part of the next prompt.
          let editor = text_area.textarea_new() |> text_area.with_max_lines(0)
          let input =
            list.fold(
              string.to_graphemes(text),
              model.view.input,
              fn(state, char) {
                case char {
                  "\n" -> text_area.newline(editor, state)
                  _ -> text_area.insert_char(editor, state, char)
                }
              },
            )
          Model(
            ..model,
            view: model.view
              |> view_set.input(input)
              |> view_set.history_index(0)
              |> view_set.history_draft(text_area.value(input)),
          )
        }
        composer.Compact(attachment) -> add_attachment(model, attachment)
      }
  }
}

fn add_attachment(model: Model, attachment: composer.Attachment) -> Model {
  case composer.admit_attachment(model.shared.attachments, attachment) {
    Error(reason) -> tui_model.append_error(model, reason)
    Ok(attachments) -> {
      let notice =
        composer.summary(attachments) |> option.unwrap("pasted content")
      Model(
        ..model,
        shared: model.shared
          |> shared_set.attachments(attachments)
          |> shared_set.notice(notice),
      )
    }
  }
}

/// Applies one frame a test driver selected from the candidate's frames
/// inbox, behind the frames already held.
///
/// ## Examples
///
/// ```gleam
/// // interaction.accept_candidate_frame(model, message)
/// ```
@internal
pub fn accept_candidate_frame(
  model: Model,
  message: connection_event.Message,
) -> Model {
  advance_candidate(
    model,
    attachment.accept(
      model.view.candidate,
      message,
      now: model.shared.stamp.transport_ms,
    ),
  )
}

/// Applies one advance of the provisional attachment: a poll's or an
/// accepted event's next status, its outcome, and the outputs it decided on.
///
/// The outputs are queued before the outcome is applied. They belong to the
/// attempt, which an adoption or a failure is about to take off the model,
/// so this is the last point at which the step still holds them. They
/// include everything the candidate's channel queued, its recording notes
/// among them, so an adopted channel arrives with nothing left to move.
///
/// ## Examples
///
/// ```gleam
/// // interaction.advance_candidate(model, attachment.poll(model.candidate))
/// ```
@internal
pub fn advance_candidate(
  model: Model,
  advanced: #(
    attachment.Status,
    Option(attachment.Outcome),
    List(attachment.Out),
  ),
) -> Model {
  let #(candidate, outcome, outputs) = advanced
  let model = list.fold(outputs, model, tui_model.emit_attachment)
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
  let model = Model(..model, view: view_set.candidate(model.view, candidate))
  case outcome {
    None -> model
    Some(attachment.Failed(reason)) -> {
      let failed =
        tui_model.append_error(
          inbound.cancel_pending(
            model,
            "target change from " <> model.shared.session,
          ),
          "open session: " <> reason,
        )

      // A failed open owes nothing: the line would otherwise surface on the
      // next adoption, which may be a different session's.
      Model(..failed, view: view_set.launch_note(failed.view, None))
    }
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
      let cancelled = case model.shared.pending_submission {
        Some(_) ->
          Some(
            "Not sent: target changed from "
            <> model.shared.session
            <> "; draft retained",
          )
        None -> None
      }
      let model =
        inbound.cancel_pending(
          model,
          "target change from " <> model.shared.session,
        )

      // Retirement runs while the old channel's session is still the visible
      // one: its outcome is reported against the identity that produced it,
      // and a sent request keeps that identity rather than acquiring the new
      // session's.
      let model = retire_previous(model)
      let target_strand = case
        model.shared.session == cut.attachment.expected.session
      {
        True -> model.shared.active_strand
        False -> "main"
      }
      let model =
        inbound.select_workspace(
          model,
          cut.attachment.expected.session,
          target_strand,
        )

      let model =
        Model(
          ..model,
          shared: shared_set.scrollback(
            model.shared,
            history_view.cancel(model.shared.scrollback),
          ),
        )

      // The old inbox's flush is decided only after the retirement, so it
      // is queued behind the retired lane's close, which `retire_previous`
      // moved into the outbox. Deciding it before the retirement would
      // discard frames the retirement is entitled to reduce. The flush
      // itself runs after the step, which is safe because the model stops
      // reading that inbox at the swap below and nothing selects on it
      // again.
      //
      // The swap replaces the whole `buffered.Inbox`, so the messages the
      // runtime had already received from the old socket leave the model
      // with it, and no later drain in this step or any other can reduce
      // one into the adopted lane. The adopted inbox arrives with the
      // frames the candidate received and left for it.
      let model =
        tui_model.emit(
          model,
          effect.Discard(buffered.sender(model.shared.inbox)),
        )
      let adopted =
        Model(
          shared: Shared(
            ..model.shared,
            inbox: inbox,
            peer: Attached,
            ended: None,
            channel: Some(channel),
            captured: None,
            note_board: None,
            notes_requested: None,
            approvals: [],
            active_strand: target_strand,
            agent_rows: case
              model.shared.session == cut.attachment.expected.session
            {
              True -> model.shared.agent_rows
              False -> []
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
            cache: cache_watch.new(),
            cache_notices: [],
            roster: case
              model.shared.session == cut.attachment.expected.session
            {
              True -> model.shared.roster
              False -> agent_roster.new()
            },
          ),
          view: View(
            ..{
              model.view
              |> view_set.workspace(workspace)
              |> view_set.note_selected(None)
              |> view_set.prompted_approvals([])
              |> view_set.overlay(NoOverlay)
              |> view_set.cache_outlook("")
              |> view_set.scroll_offset(case model.shared.scrollback.mode {
                history_view.Reading -> model.view.scroll_offset
                history_view.Live -> 0
              })
              |> view_set.strip_focus(
                case model.shared.session == cut.attachment.expected.session {
                  True -> model.view.strip_focus
                  False -> agent_strip.Composing
                },
              )
            },
            creation_key: case creation_key {
              Some(key) if model.view.creation_key == Some(key) -> None
              Some(_) | None -> model.view.creation_key
            },
          ),
        )
        |> inbound.apply_cut(cut, view)

      // The adoption marker is queued after the cut, not before it. ADR-009
      // makes that ordering a correctness rule: a recording is replayed by
      // the same reducer, and a marker ahead of its cut would move the
      // visible session before the frames that justify it. It is noted on
      // the lane as the cut left it, so nothing the cut decided is undone.
      let adopted = case adopted.shared.channel {
        Some(held) ->
          tui_model.hold_channel(adopted, session_channel.adopted(held))
        None -> adopted
      }
      let adopted =
        adopted
        |> tui_model.send_frame(protocol.models(1))
        |> inbound.request_visible_worktree

      // An adoption proves the daemon answers, so a relaunch still in flight
      // is no longer needed. Cancelling it stops a second daemon start that
      // the cleared slot would otherwise leave running until it gave up.
      let adopted = case adopted.view.reconnect {
        ReconnectIdle | ReconnectSpent -> adopted
        ReconnectAttempting(job: awaiting) ->
          tui_model.release_reconnect(adopted, awaiting)
          |> tui_model.emit(effect.CancelJob(job.key(awaiting)))
      }
      let adopted =
        Model(..adopted, view: view_set.reconnect(adopted.view, ReconnectIdle))
      let adopted = case cancelled {
        Some(notice) -> tui_model.append_system(adopted, notice)
        None -> adopted
      }

      // The launch's own line is written after the cut for the reason the
      // cancelled draft's is: the cut replaced the transcript, so anything
      // written before it is gone. It is spent by this adoption, which keeps
      // a later reconnect from saying it again.
      case adopted.view.launch_note {
        Some(line) ->
          Model(..adopted, view: view_set.launch_note(adopted.view, None))
          |> tui_model.append_notice(line)
        None -> adopted
      }
    }
  }
}

// Consume the old channel's outcome while its session identity is still the
// visible one. Closing an already-sent request cannot imply it was rejected.
// With no channel there is no socket to close: an attached peer always has
// its lane, and the other peers never had a socket.
fn retire_previous(model: Model) -> Model {
  case model.shared.channel {
    Some(previous) -> {
      let #(closed, updates) =
        session_channel.retire(previous, "attachment replaced")
      list.fold(
        updates,
        tui_model.hold_channel(model, closed),
        inbound.apply_channel_update,
      )
    }
    None -> model
  }
}

fn update_key(key: keys.Key, model: Model) -> Model {
  // The strip owns the keyboard only while nothing else is in front of it.
  // An overlay, including an approval the daemon opened on its own, takes
  // the cursor out of the strip, so closing it leaves the composer, not a
  // cursor waiting to turn the next Enter into a strand switch.
  let model = case strip_covered(model) {
    True ->
      tui_model.store_strip(model, agent_strip.leave(tui_model.strip(model)))
    False -> model
  }
  case model.shared.context.surface {
    context_view.Overview | context_view.All -> update_context_key(key, model)
    context_view.Hidden -> update_key_without_context(key, model)
  }
}

fn update_key_without_context(key: keys.Key, model: Model) -> Model {
  case model.view.queue_editor.surface {
    queue_editor.Inspector | queue_editor.Editor -> update_queue_key(key, model)
    queue_editor.Closed ->
      case model.view.summary_surface {
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
      case model.view.overlay {
        ModelSelector(selector) -> update_model_selector(key, model, selector)
        AgentInspector(selected) -> update_agent_inspector(key, model, selected)
        GoalInspector(state) -> update_goal_inspector(key, model, state)
        DaemonSelector(selector) -> update_daemon_selector(key, model, selector)
        PeerLinkManager(state) ->
          session_control.update_peer_link_manager(key, model, state)
        AccessManager(state) ->
          session_control.update_access_overlay(key, model, state)
        ApprovalInspector(panel) ->
          case approval_panel.update(key, panel) {
            approval_panel.Close ->
              Model(..model, view: view_set.overlay(model.view, NoOverlay))
            approval_panel.Continue(next) ->
              Model(
                ..model,
                view: view_set.overlay(model.view, ApprovalInspector(next)),
              )
            approval_panel.Decide(record, choice) ->
              inbound.decide_captured_approval(model, record, choice)
          }
        NoOverlay -> update_main_key(key, model)
      }
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
        shared: shared_set.notice(model.shared, "goal inspector closed"),
        view: model.view
          |> view_set.overlay(NoOverlay)
          |> view_set.toggle_repaint,
      )
    focused_goal_panel.Continue(next) ->
      Model(..model, view: view_set.overlay(model.view, GoalInspector(next)))
    focused_goal_panel.Refresh -> side_surfaces.request_goal_status(model)
    focused_goal_panel.Pause ->
      tui_model.run_shared(model, surfaces.submit_goal_action(
        _,
        command.GoalPause,
      ))
    focused_goal_panel.Resume ->
      tui_model.run_shared(model, surfaces.submit_goal_action(
        _,
        command.GoalResume,
      ))
  }
}

fn update_daemon_selector(
  key: keys.Key,
  model: Model,
  selector: session_selector.State,
) -> Model {
  case session_selector.update(key, selector) {
    session_selector.Continue(next) ->
      Model(..model, view: view_set.overlay(model.view, DaemonSelector(next)))
    session_selector.Close ->
      Model(
        shared: shared_set.notice(model.shared, "session selection cancelled"),
        view: view_set.overlay(model.view, NoOverlay),
      )
    session_selector.Choose(row) ->
      session_control.open_chosen(model, row.session_id)
    session_selector.Link(row) ->
      case row.status {
        control_protocol.Resident(_) ->
          session_control.begin_peer_workspace_for_session(model, selector, row)
        _ ->
          Model(
            ..model,
            shared: shared_set.notice(
              model.shared,
              "open the saved session before linking it",
            ),
          )
      }
    session_selector.NewSession -> session_control.create_session(model)
    session_selector.Delete(session_id) ->
      session_control.begin_delete(model, session_id)
    session_selector.Archive(session_id) ->
      session_control.begin_removal(model, session_id, job.Archive)
    session_selector.Restore(session_id) ->
      session_control.begin_removal(model, session_id, job.Restore)
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
      Model(..model, view: view_set.overlay(model.view, ModelSelector(next)))
    model_selector.Close ->
      Model(
        shared: shared_set.notice(model.shared, "model selection cancelled"),
        view: model.view
          |> view_set.overlay(NoOverlay)
          |> view_set.toggle_repaint,
      )

    // The selector closes before the session's half runs. The notice it
    // sets is replaced by the line `commands.select_model` appends, as it
    // always was; the switch reads neither the notice nor the overlay.
    model_selector.Choose(name) -> {
      let closed =
        Model(
          shared: shared_set.notice(model.shared, "model: " <> name),
          view: model.view
            |> view_set.overlay(NoOverlay)
            |> view_set.toggle_repaint,
        )
      inbound.run_settled(closed, commands.act(_, msg.SelectModel(name)))
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
    // Tab narrows the list, as it does in the session picker; Escape is the
    // way back to the composer. `w` writes to the unchanged recipient from
    // inside the workspace.
    keys.Tab ->
      Model(
        ..model,
        view: view_set.overlay(
          model.view,
          AgentInspector(agents.cycle_filter(inspector, rows, agents.Next)),
        ),
      )
    keys.BackTab ->
      Model(
        ..model,
        view: view_set.overlay(
          model.view,
          AgentInspector(agents.cycle_filter(inspector, rows, agents.Previous)),
        ),
      )
    keys.Char("w") ->
      Model(
        shared: shared_set.worktree(
          model.shared,
          worktree_view.State(
            ..model.shared.worktree,
            focus: worktree_view.Composer,
          ),
        ),
        view: model.view
          |> view_set.help_open(False)
          |> view_set.notes_open(False)
          |> view_set.overlay(AgentInspector(
            agents.Inspector(..inspector, focus: agents.Composing),
          )),
      )
    keys.Escape | keys.F(2) | keys.Ctrl("o") ->
      Model(
        shared: shared_set.notice(model.shared, "agents closed"),
        view: model.view
          |> view_set.overlay(NoOverlay)
          |> view_set.toggle_repaint,
      )
    keys.Up ->
      Model(
        ..model,
        view: view_set.overlay(
          model.view,
          AgentInspector(
            agents.navigate(inspector, rows, agents.Previous)
            |> inbound.select_inspector_message(model.shared.agent_messages),
          ),
        ),
      )
    keys.Down ->
      Model(
        ..model,
        view: view_set.overlay(
          model.view,
          AgentInspector(
            agents.navigate(inspector, rows, agents.Next)
            |> inbound.select_inspector_message(model.shared.agent_messages),
          ),
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
      side_surfaces.select_note(model, -1)
    keys.Char("]") if inspector.detail == agents.Notes ->
      side_surfaces.select_note(model, 1)
    keys.Char("r") if inspector.detail == agents.Notes ->
      side_surfaces.refresh_notes(model)
    keys.Ctrl("g") if inspector.detail == agents.Notes -> toggle_note_mode(model)
    keys.Ctrl("g") -> submit.toggle_details(model)
    keys.Char("n") ->
      Model(
        ..model,
        view: view_set.overlay(
          model.view,
          AgentInspector(
            agents.next_attention(inspector, rows)
            |> inbound.select_inspector_message(model.shared.agent_messages),
          ),
        ),
      )
    keys.Char("p") -> session_control.begin_peer_workspace_for(model, inspector)
    keys.PageUp if inspector.detail == agents.Messages -> {
      let maximum = message_max_scroll(model, inspector)
      Model(
        ..model,
        view: view_set.overlay(
          model.view,
          AgentInspector(
            agents.Inspector(
              ..inspector,
              scroll: int.max(
                0,
                int.min(inspector.scroll, maximum) - message_page_step(model),
              ),
            ),
          ),
        ),
      )
    }
    keys.PageDown if inspector.detail == agents.Messages -> {
      let maximum = message_max_scroll(model, inspector)
      Model(
        ..model,
        view: view_set.overlay(
          model.view,
          AgentInspector(
            agents.Inspector(
              ..inspector,
              scroll: int.min(
                maximum,
                int.min(inspector.scroll, maximum) + message_page_step(model),
              ),
            ),
          ),
        ),
      )
    }
    keys.PageUp if inspector.detail == agents.Notes -> {
      let maximum = inbound.note_max_scroll(model)
      Model(
        ..model,
        view: view_set.note_scroll(
          model.view,
          int.max(
            0,
            int.min(model.view.note_scroll, maximum) - note_page_step(model),
          ),
        ),
      )
    }
    keys.PageDown if inspector.detail == agents.Notes ->
      Model(
        ..model,
        view: view_set.note_scroll(
          model.view,
          int.min(
            inbound.note_max_scroll(model),
            int.min(model.view.note_scroll, inbound.note_max_scroll(model))
              + note_page_step(model),
          ),
        ),
      )
    keys.PageUp ->
      Model(
        ..model,
        view: view_set.overlay(
          model.view,
          AgentInspector(
            agents.Inspector(
              ..inspector,
              scroll: int.max(0, inspector.scroll - 5),
            ),
          ),
        ),
      )
    keys.PageDown ->
      Model(
        ..model,
        view: view_set.overlay(
          model.view,
          AgentInspector(
            agents.Inspector(..inspector, scroll: inspector.scroll + 5),
          ),
        ),
      )
    keys.Char("a") -> inspect_agent_approval(model, inspector.selected)
    keys.Char("o") if inspector.detail == agents.Messages ->
      open_agent_message_sender(model, inspector)
    keys.Enter ->
      case
        session_model.is_known_strand(model.shared.strands, inspector.selected)
      {
        True -> submit.switch_active_strand(model, inspector.selected)
        False ->
          Model(
            ..model,
            shared: shared_set.notice(
              model.shared,
              "Selected agent is unavailable; recipient unchanged",
            ),
          )
      }
    _ -> model
  }
  case changed.view.overlay {
    AgentInspector(next)
      if next.detail == agents.Notes && next.selected != inspector.selected
    ->
      side_surfaces.refresh_notes(
        Model(
          ..changed,
          view: changed.view
            |> view_set.note_selected(None)
            |> view_set.note_scroll(0)
            |> view_set.note_mode(note_panel.Readable),
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
  model.shared.agent_messages
  |> agent_messages.for_strand(inspector.selected)
  |> agent_message_panel.max_scroll(inspector.message, area)
}

fn note_page_step(model: Model) -> Int {
  case model.view.overlay {
    AgentInspector(_) -> note_panel.page_step(layout.message_detail_area(model))
    _ -> note_panel.page_step(layout.note_detail_area(model))
  }
}

fn toggle_note_mode(model: Model) -> Model {
  let mode = case model.view.note_mode {
    note_panel.Readable -> note_panel.Raw
    note_panel.Raw -> note_panel.Readable
  }
  Model(
    ..model,
    view: model.view
      |> view_set.note_mode(mode)
      |> view_set.note_scroll(0),
  )
  |> tui_model.invalidate_transcript
}

fn select_agent_detail(
  model: Model,
  inspector: agents.Inspector,
  detail: agents.Detail,
) -> Model {
  let message = case detail {
    agents.Messages ->
      agent_messages.for_strand(model.shared.agent_messages, inspector.selected)
      |> agent_message_panel.selected(inspector.message)
      |> option.map(agent_message_panel.identity)
    agents.Overview | agents.Notes | agents.Collaboration -> inspector.message
  }
  let owner_changed = case model.shared.note_board {
    Some(board) -> board.strand != inspector.selected
    None -> True
  }
  let selected =
    Model(
      ..model,
      view: View(
        ..model.view,
        note_selected: case detail, owner_changed {
          agents.Notes, True -> None
          _, _ -> model.view.note_selected
        },
        note_scroll: case detail, owner_changed {
          agents.Notes, True -> 0
          _, _ -> model.view.note_scroll
        },
        overlay: AgentInspector(
          agents.Inspector(..inspector, detail:, scroll: 0, message:),
        ),
      ),
    )
  case detail {
    agents.Notes -> side_surfaces.refresh_notes(selected)
    agents.Overview | agents.Messages | agents.Collaboration -> selected
  }
}

fn select_agent_message(
  model: Model,
  inspector: agents.Inspector,
  amount: Int,
) -> Model {
  let messages =
    agent_messages.for_strand(model.shared.agent_messages, inspector.selected)
  Model(
    ..model,
    view: view_set.overlay(
      model.view,
      AgentInspector(
        agents.Inspector(
          ..inspector,
          message: agent_message_panel.move(messages, inspector.message, amount),
          scroll: 0,
        ),
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
    agent_messages.for_strand(model.shared.agent_messages, inspector.selected)
  case agent_message_panel.selected(messages, inspector.message) {
    None ->
      Model(
        ..model,
        shared: shared_set.notice(
          model.shared,
          "No observed message is selected",
        ),
      )
    Some(item) ->
      case session_model.is_known_strand(model.shared.strands, item.source) {
        True -> submit.switch_active_strand(model, item.source)
        False ->
          Model(
            ..model,
            shared: shared_set.notice(
              model.shared,
              "Message sender is unavailable; recipient unchanged",
            ),
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
        view: view_set.overlay(
          model.view,
          AgentInspector(agents.Inspector(..inspector, focus: agents.Browsing)),
        ),
      )
    _ -> {
      let next =
        update_main_key(
          key,
          Model(..model, view: view_set.overlay(model.view, NoOverlay)),
        )

      // Commands transfer keyboard ownership to their visible destination.
      // Retaining inspection would conceal help or a diff navigator while
      // that surface was already consuming the next key.
      let editing =
        !next.view.help_open
        && !next.view.notes_open
        && next.shared.worktree.focus == worktree_view.Composer
        && next.view.diff_view == model.view.diff_view
        && next.shared.context.surface == context_view.Hidden
        && next.view.queue_editor.surface == queue_editor.Closed
        && next.view.summary_surface == queue_editor.Closed
      case next.view.overlay, editing {
        NoOverlay, True ->
          Model(
            ..next,
            view: view_set.overlay(next.view, AgentInspector(inspector)),
          )
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
      list.find(model.shared.approvals, fn(review) {
        review.id == id && review.status == approval.Pending
      })
    })
  case found {
    Ok(review) ->
      Model(
        ..model,
        view: view_set.overlay(
          model.view,
          ApprovalInspector(inbound.captured_approval_panel(model, review)),
        ),
      )
    Error(Nil) ->
      Model(
        ..model,
        shared: shared_set.notice(
          model.shared,
          "No current approval for this agent",
        ),
      )
  }
}

fn update_main_key(key: keys.Key, model: Model) -> Model {
  case focused_tab(model), tab_of_key(key) {
    // A digit while the keyboard is on the rail chooses a tab, on Changes as
    // well: its panel has a focus of its own, but the keyboard is still the
    // rail's until a key that is not a digit takes it back.
    Some(_), Ok(tab) ->
      submit.select_rail_tab(model, tab)
      |> keep_tab_keyboard(tab)

    // The tabs with keys of their own. Strands has them only in the sheet
    // when it has no list to hold a cursor, which is the one case that sets
    // the keyboard on it.
    Some(rail.Trace), Error(Nil)
    | Some(rail.Session), Error(Nil)
    | Some(rail.Strands), Error(Nil)
    -> update_tab_key(key, model)

    // Changes has a focus of its own, so a key that is not a digit is the
    // composer's and the changes' to act on as it was before the rail held
    // the keyboard. Escape in particular reaches the surface on top, which
    // closes the changes, in one press.
    Some(rail.Changes), Error(Nil) ->
      update_main_key_strip(
        key,
        Model(
          ..model,
          view: view_set.rail_focus(model.view, tui_model.FocusComposer),
        ),
      )

    None, _ -> composer_takes(key, model)
  }
}

// The keyboard is the composer's again. When the rail had it and the tab left
// the screen (the rail was hidden or the terminal narrowed), the focus is
// reset with this key. Escape is consumed by that reset: forwarded, it would
// interrupt the strand, which a key pressed at a tab that had gone away
// cannot have meant.
fn composer_takes(key: keys.Key, model: Model) -> Model {
  case model.view.rail_focus {
    tui_model.FocusComposer -> update_main_key_strip(key, model)
    tui_model.FocusTab -> {
      let returned =
        Model(
          ..model,
          view: view_set.rail_focus(model.view, tui_model.FocusComposer),
        )
      case key {
        keys.Escape -> returned
        _ -> update_main_key_strip(key, returned)
      }
    }
  }
}

// The tab the rail is showing, in either form, or none when it is not on
// screen.
fn shown_tab(model: Model) -> Option(rail.Tab) {
  case layout.rail_present(model) {
    True -> Some(layout.rail_tab(model))
    False -> None
  }
}

// The tab that holds the keyboard: the shown one while the keyboard is on the
// rail, and none when it is the composer's or the tab has left the screen.
fn focused_tab(model: Model) -> Option(rail.Tab) {
  case model.view.rail_focus {
    tui_model.FocusTab -> shown_tab(model)
    tui_model.FocusComposer -> None
  }
}

// The Trace and Session tabs have no cursor, so while one has the keyboard
// the digits choose a tab, the arrows and pages scroll it, and Escape hands
// the keyboard back. Any other key is the composer's, and takes the keyboard
// with it, as a key the strip does not want does.
fn update_tab_key(key: keys.Key, model: Model) -> Model {
  case tab_of_key(key), key {
    Ok(tab), _ ->
      submit.select_rail_tab(model, tab)
      |> keep_tab_keyboard(tab)
    Error(Nil), keys.Up -> scrolled_tab(model, -1)
    Error(Nil), keys.Down -> scrolled_tab(model, 1)
    Error(Nil), keys.PageUp -> scrolled_tab(model, -10)
    Error(Nil), keys.PageDown -> scrolled_tab(model, 10)
    Error(Nil), keys.Escape ->
      case layout.sheet_shown(model) {
        True -> submit.close_sheet(model)
        False ->
          Model(
            ..model,
            view: view_set.rail_focus(model.view, tui_model.FocusComposer),
          )
      }
    Error(Nil), _ ->
      update_main_key_strip(
        key,
        Model(
          ..model,
          view: view_set.rail_focus(model.view, tui_model.FocusComposer),
        ),
      )
  }
}

// The tab a digit key names.
fn tab_of_key(key: keys.Key) -> Result(rail.Tab, Nil) {
  case key {
    keys.Char(digit) ->
      case int.parse(digit) {
        Ok(number) -> rail.of_number(number)
        Error(Nil) -> Error(Nil)
      }
    keys.Up
    | keys.Down
    | keys.Left
    | keys.Right
    | keys.Enter
    | keys.Backspace
    | keys.Delete
    | keys.Tab
    | keys.BackTab
    | keys.Home
    | keys.End
    | keys.PageUp
    | keys.PageDown
    | keys.Escape
    | keys.Insert
    | keys.F(_)
    | keys.Ctrl(_)
    | keys.Alt(_)
    | keys.Unknown(_) -> Error(Nil)
  }
}

// After a digit chose a tab with the keyboard on the tab, the keyboard stays
// on the tab when the new one is another with no cursor of its own, so the
// digits keep working; Strands has the list's cursor to be entered with
// Down, and Changes has its own focus.
fn keep_tab_keyboard(model: Model, tab: rail.Tab) -> Model {
  case tab {
    rail.Trace | rail.Session | rail.Changes ->
      Model(..model, view: view_set.rail_focus(model.view, tui_model.FocusTab))
      |> fn(held) {
        tui_model.store_strip(held, agent_strip.leave(tui_model.strip(held)))
      }
    rail.Strands -> model
  }
}

fn scrolled_tab(model: Model, by: Int) -> Model {
  Model(
    ..model,
    view: View(
      ..model.view,
      rail_scroll: int.clamp(
        model.view.rail_scroll + by,
        min: 0,
        max: rail_tabs.scroll_limit(model),
      ),
    ),
  )
  |> tui_model.invalidate_frame
}

fn update_main_key_strip(key: keys.Key, model: Model) -> Model {
  case model.view.strip_focus, layout.strands_listed(model) {
    agent_strip.Browsing(_), True -> update_strip_key(key, model)

    // Every agent settled while the cursor was in the strip, so the strip
    // is gone. The keyboard returns to the composer with this key, rather
    // than an invisible cursor taking an Enter the operator meant to send.
    //
    // Escape is consumed by that reset and not forwarded: forwarded, it would
    // interrupt the strand, which is not what pressing it at a cursor that
    // had gone away could have meant.
    agent_strip.Browsing(_), False -> {
      let left =
        tui_model.store_strip(model, agent_strip.leave(tui_model.strip(model)))
      case key {
        keys.Escape -> left
        _ -> update_main_key_composing(key, left)
      }
    }
    agent_strip.Composing, _ -> update_main_key_composing(key, model)
  }
}

// The strip owns the keyboard only between a Down from the idle composer and
// the key that hands it back. Opening goes through the same switch the
// workspace's Enter uses, so the draft is parked with its strand and the
// transcript, the composer's recipient and its badge change together.
fn update_strip_key(key: keys.Key, model: Model) -> Model {
  case layout.rail_present(model), tab_of_key(key) {
    True, Ok(tab) ->
      submit.select_rail_tab(model, tab)
      |> keep_tab_keyboard(tab)
    True, Error(Nil) | False, _ -> update_strip_key_in_list(key, model)
  }
}

fn update_strip_key_in_list(key: keys.Key, model: Model) -> Model {
  let pressed = case key {
    keys.Up -> agent_strip.Up
    keys.Down -> agent_strip.Down
    keys.Enter -> agent_strip.Select
    keys.Char("x") -> agent_strip.Halt
    keys.Escape -> agent_strip.Back
    _ -> agent_strip.Other
  }
  let strip = tui_model.strip(model)
  case agent_strip.key(strip, pressed, layout.strip_lines(model)) {
    agent_strip.Moved(strip) -> tui_model.store_strip(model, strip)

    // Leaving the list in the sheet leaves the sheet: it has nothing else
    // for a key to be about.
    agent_strip.Left(strip) ->
      case layout.sheet_shown(model) {
        True -> submit.close_sheet(tui_model.store_strip(model, strip))
        False -> tui_model.store_strip(model, strip)
      }

    // Choosing an agent in the sheet closes it, so the transcript that was
    // chosen is the one on screen.
    agent_strip.Open(strip, strand) ->
      case strand == model.shared.active_strand {
        True -> tui_model.store_strip(model, strip)
        False ->
          submit.switch_active_strand(
            tui_model.store_strip(model, strip),
            strand,
          )
      }
      |> close_sheet_after_open
    agent_strip.Stop(strip, strand) ->
      submit.stop_strand(tui_model.store_strip(model, strip), strand)
    agent_strip.Pass(strip) ->
      update_main_key_composing(key, tui_model.store_strip(model, strip))
  }
}

// Choosing an agent from the sheet closes the sheet.
fn close_sheet_after_open(model: Model) -> Model {
  case layout.sheet_shown(model) && model.view.sheet == tui_model.SheetOpen {
    True -> submit.close_sheet(model)
    False -> model
  }
}

fn update_main_key_composing(key: keys.Key, model: Model) -> Model {
  case layout.diff_shown(model), model.shared.worktree.focus, key {
    _, _, keys.Alt("q") -> submit.open_queue(model)

    // Ctrl+O ("open agents") is the chord a hand already on the keyboard
    // reaches; F2 stays for anyone who learned it. Ctrl+A was the other
    // candidate and is the composer's start-of-line.
    _, _, keys.F(2) | _, _, keys.Ctrl("o") -> submit.open_agents(model)
    True, _, keys.Ctrl("d") ->
      Model(
        ..model,
        shared: shared_set.worktree(
          model.shared,
          worktree_view.State(
            ..model.shared.worktree,
            focus: case model.shared.worktree.focus {
              worktree_view.Composer -> worktree_view.Navigator
              worktree_view.Navigator -> worktree_view.Composer
            },
          ),
        ),
      )
    True, worktree_view.Navigator, _ -> update_diff_key(key, model)
    _, _, _ -> update_palette_key(key, model)
  }
}

fn update_palette_key(key: keys.Key, model: Model) -> Model {
  let suggestions =
    command.suggestions_with_skills(
      text_area.value(model.view.input),
      model.shared.skills,
    )
  case suggestions, command_palette_escape(key), key {
    [_, ..], True, _ ->
      Model(
        shared: shared_set.notice(model.shared, "commands closed"),
        view: model.view
          |> view_set.input(text_area.state_new())
          |> view_set.command_selected(0),
      )
    [_, ..], False, keys.Up ->
      Model(
        ..model,
        view: view_set.command_selected(
          model.view,
          command.move_selection(
            model.view.command_selected,
            list.length(suggestions),
            False,
          ),
        ),
      )
    [_, ..], False, keys.Down ->
      Model(
        ..model,
        view: view_set.command_selected(
          model.view,
          command.move_selection(
            model.view.command_selected,
            list.length(suggestions),
            True,
          ),
        ),
      )
    [_, ..], False, keys.Tab ->
      case command.selected(suggestions, model.view.command_selected) {
        Some(value) ->
          Model(
            ..model,
            view: model.view
              |> view_set.input(text_area.state_from_string(value))
              |> view_set.command_selected(0),
          )
        None -> model
      }

    // Enter takes the highlighted row. A row that still wants an argument
    // is completed into the editor, as Tab would; a complete one is
    // submitted at once, so `/effort` plus a highlighted level is one
    // keystroke, not Tab then Enter.
    [_, ..], False, keys.Enter ->
      case command.selected(suggestions, model.view.command_selected) {
        Some(value) -> {
          let completed =
            Model(
              ..model,
              view: model.view
                |> view_set.input(text_area.state_from_string(value))
                |> view_set.command_selected(0),
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
  model.view.overlay != NoOverlay
  || model.shared.context.surface != context_view.Hidden
  || model.view.queue_editor.surface != queue_editor.Closed
  || model.view.summary_surface != queue_editor.Closed
}

// Down walks forward through prompt history while the operator is browsing
// it. At the newest entry there is nothing further forward, so the same key
// steps down into the agent strip, the next thing below the composer.
fn down_from_composer(model: Model) -> Model {
  let lines = layout.strip_lines(model)
  case
    model.view.history_index,
    layout.strands_listed(model),
    shown_tab(model)
  {
    0, True, _ ->
      tui_model.store_strip(
        model,
        agent_strip.enter(
          tui_model.strip(model),
          lines,
          model.shared.active_strand,
        ),
      )

    // The rail shows Trace or Session, which have no list to enter, so Down
    // gives the keyboard to the tab, where the digits choose a tab.
    0, False, Some(rail.Trace) | 0, False, Some(rail.Session) ->
      Model(..model, view: view_set.rail_focus(model.view, tui_model.FocusTab))
    _, _, _ -> submit.navigate_history(model, False)
  }
}

/// Reports whether Escape belongs to an open slash-command palette.
@internal
pub fn command_palette_escape(key: keys.Key) -> Bool {
  key == keys.Escape
}

fn update_main_key_without_palette(key: keys.Key, model: Model) -> Model {
  case key, layout.sheet_shown(model), model.view.diff_view {
    // The sheet is the surface on top, so Escape closes it, and the changes
    // with it, and never interrupts the strand behind it.
    keys.Escape, True, _ ->
      Model(
        shared: shared_set.notice(model.shared, "sheet closed"),
        view: view_set.diff_view(model.view, DiffHidden),
      )
      |> submit.close_sheet

    keys.Escape, False, DiffVisible ->
      Model(
        shared: shared_set.notice(model.shared, "changes closed"),
        view: model.view
          |> view_set.diff_view(DiffHidden)
          |> view_set.toggle_repaint,
      )
    _, _, _ -> update_conversation_key(key, model)
  }
}

fn update_conversation_key(key: keys.Key, model: Model) -> Model {
  // While the reader is above the tail with nothing typed, `o` opens the
  // strand's newest image outside the terminal; with text in the prompt it
  // is a letter like any other.
  let opens_image =
    tui_model.reading_history(model)
    && model.view.overlay == tui_model.NoOverlay
    && text_area.value(model.view.input) == ""

  case key, model.view.help_open, model.view.notes_open {
    keys.Char("o"), False, False if opens_image -> image_drain.open_newest(model)
    keys.Char("r"), False, True -> side_surfaces.refresh_notes(model)
    keys.Up, False, True -> side_surfaces.select_note(model, -1)
    keys.Down, False, True -> side_surfaces.select_note(model, 1)
    keys.Char("["), False, True -> side_surfaces.select_note(model, -1)
    keys.Char("]"), False, True -> side_surfaces.select_note(model, 1)
    keys.Ctrl("g"), False, True -> toggle_note_mode(model)
    keys.Ctrl("g"), _, _ -> submit.toggle_details(model)
    keys.PageUp, False, True -> {
      let maximum = inbound.note_max_scroll(model)
      Model(
        ..model,
        view: view_set.note_scroll(
          model.view,
          int.max(
            0,
            int.min(model.view.note_scroll, maximum) - note_page_step(model),
          ),
        ),
      )
    }
    keys.PageDown, False, True ->
      Model(
        ..model,
        view: view_set.note_scroll(
          model.view,
          int.min(
            inbound.note_max_scroll(model),
            int.min(model.view.note_scroll, inbound.note_max_scroll(model))
              + note_page_step(model),
          ),
        ),
      )
    keys.PageUp, _, _ -> scroll_reading_panel(model, Older, 10)
    keys.PageDown, _, _ -> scroll_reading_panel(model, Newer, 10)
    keys.Escape, True, _ ->
      Model(
        shared: shared_set.notice(model.shared, "help closed"),
        view: model.view
          |> view_set.help_open(False)
          |> view_set.scroll_offset(0)
          |> view_set.toggle_repaint,
      )
    keys.Escape, False, True ->
      Model(
        shared: model.shared
          |> shared_set.note_board(None)
          |> shared_set.notes_requested(None)
          |> shared_set.notice("agent notes closed"),
        view: model.view
          |> view_set.notes_open(False)
          |> view_set.note_selected(None)
          |> view_set.note_mode(note_panel.Readable)
          |> view_set.note_scroll(0)
          |> view_set.scroll_offset(0)
          |> view_set.toggle_repaint,
      )
    keys.Escape, False, False -> submit.interrupt_active(model)
    keys.Tab, False, False -> submit.toggle_submission_mode(model)
    keys.BackTab, False, False -> submit.toggle_agent_rail(model)
    keys.Up, False, False -> submit.navigate_history(model, True)
    keys.Down, False, False -> down_from_composer(model)
    keys.Enter, False, False -> submit.submit(model)
    keys.Backspace, False, False ->
      case text_area.value(model.view.input), model.shared.attachments {
        "", [_, ..] -> {
          let attachments = composer.drop_last(model.shared.attachments)
          Model(
            ..model,
            shared: model.shared
              |> shared_set.attachments(attachments)
              |> shared_set.notice(
                composer.summary(attachments)
                |> option.unwrap("paste removed"),
              ),
          )
        }
        _, _ -> {
          let input = text_area.backspace(model.view.input)
          Model(
            ..model,
            view: model.view
              |> view_set.input(input)
              |> view_set.history_index(0)
              |> view_set.history_draft(text_area.value(input))
              |> view_set.command_selected(0),
          )
        }
      }

    // Left with nothing to move through has no editing meaning, so it opens
    // the session picker, the way Down from an idle composer enters the
    // strip. A draft or a pending paste keeps Left as a cursor key: the
    // picker must never be one stray arrow away from text being edited.
    keys.Left, False, False ->
      case text_area.value(model.view.input), model.shared.attachments {
        "", [] -> submit.open_session_selector(model)
        _, _ ->
          Model(
            ..model,
            view: view_set.input(
              model.view,
              text_area.move_cursor_left(model.view.input),
            ),
          )
      }
    keys.Right, False, False ->
      Model(
        ..model,
        view: view_set.input(
          model.view,
          text_area.move_cursor_right(model.view.input),
        ),
      )
    keys.Home, False, False ->
      Model(
        ..model,
        view: view_set.input(
          model.view,
          text_area.move_to_line_start(model.view.input),
        ),
      )
    keys.End, False, False ->
      case
        text_area.value(model.view.input) == ""
        && tui_model.reading_history(model)
      {
        True -> scroll_transcript(model, False, model.view.rendered_row_count)
        False ->
          Model(
            ..model,
            view: view_set.input(
              model.view,
              text_area.move_to_line_end(model.view.input),
            ),
          )
      }
    keys.Alt(character), False, False ->
      submit.interrupt_and_insert(model, character)
    keys.Char(character), False, False -> {
      let editor = text_area.textarea_new() |> text_area.with_max_lines(1)
      Model(
        ..model,
        view: model.view
          |> view_set.input(text_area.insert_char(
            editor,
            model.view.input,
            character,
          ))
          |> view_set.history_index(0)
          |> view_set.history_draft(
            text_area.value(model.view.input) <> character,
          )
          |> view_set.command_selected(0),
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
  case model.view.selection, key {
    Some(_), keys.Escape -> {
      let cleared = clear_selection(model)
      Model(
        ..cleared,
        shared: shared_set.notice(cleared.shared, "selection cleared"),
      )
    }
    Some(_), keys.Ctrl("g") -> update_key(key, model)
    Some(_), _ | None, _ -> update_key(key, clear_selection(model))
  }
}

/// Escape owns cancellation before a queued final reply can send the intent.
/// Other input first observes bounded ready traffic, then the current lock.
@internal
pub fn update_ready_key(key: keys.Key, model: Model) -> Model {
  case model.shared.pending_submission, key {
    Some(_), keys.Escape -> inbound.cancel_pending(model, "cancelled by Escape")
    Some(_), keys.Ctrl("c") ->
      submit.quit(inbound.cancel_pending(model, "terminal closed"))
    _, _ -> {
      let model = inbound.drain_connection(model, tui_model.connection_batch)
      case model.shared.pending_submission, key {
        None, _ -> update_key_over_selection(key, model)
        Some(_), keys.PageUp -> scroll_transcript(model, True, 10)
        Some(_), keys.PageDown -> scroll_transcript(model, False, 10)
        Some(_), _ -> tui_model.run_shared(model, outbound.waiting_notice)
      }
    }
  }
}

/// Drops the mouse selection and the frame it was made on.
@internal
pub fn clear_selection(model: Model) -> Model {
  Model(
    ..model,
    view: model.view
      |> view_set.selection(None)
      |> view_set.selection_gutters([])
      |> view_set.caches(Caches(..model.view.caches, selection_frame: None)),
  )
}

/// A press starts over: whatever was highlighted is replaced by a fresh
/// selection in the area the press landed in.
@internal
pub fn begin_selection(model: Model, at: geometry.Position) -> Model {
  let screen = geometry.rect_new(0, 0, model.view.width, model.view.height)
  let #(_, body, _, _) = layout.layout(screen, model)
  let #(conversation, queue) = layout.queue_body_layout(body, model)
  let transcript = conversation
  use <- bool.lazy_guard(
    tui_model.reading_history(model)
      && !layout.sheet_shown(model)
      && at.y == geometry.bottom(transcript) - 1
      && at.x < geometry.right(transcript),
    fn() {
      scroll_transcript(
        clear_selection(model),
        False,
        model.view.rendered_row_count,
      )
    },
  )
  case queue_row_hit(model, queue, at) {
    Some(selected) -> {
      let cleared = clear_selection(model)
      Model(
        shared: shared_set.notice(cleared.shared, "queued input selected"),
        view: view_set.queue_editor(
          cleared.view,
          queue_editor.State(
            ..model.view.queue_editor,
            surface: queue_editor.Inspector,
            selected:,
            preview_scroll: 0,
          ),
        ),
      )
    }
    None ->
      case layout.diff_navigation_hit(model, at) {
        Some(selected) ->
          Model(
            shared: shared_set.worktree(
              model.shared,
              worktree_view.State(
                ..model.shared.worktree,
                selected:,
                focus: worktree_view.Navigator,
              ),
            ),
            view: model.view
              |> view_set.selection(None)
              |> view_set.selection_gutters([])
              |> view_set.caches(
                Caches(..model.view.caches, selection_frame: None),
              )
              |> view_set.diff_scroll_offset(0),
          )
          |> tui_model.invalidate_transcript
        None -> {
          let #(shown, selection_gutters) = selection_display(model)
          Model(
            ..model,
            view: model.view
              |> view_set.selection(
                Some(selection.start(layout.hit_area(model, at), at)),
              )
              |> view_set.selection_gutters(selection_gutters)
              |> view_set.caches(
                Caches(..model.view.caches, selection_frame: Some(shown)),
              ),
          )
        }
      }
  }
}

/// A drag without a press this client saw, which a terminal that started
/// reporting mid-gesture can produce, selects nothing.
@internal
pub fn extend_selection(model: Model, at: geometry.Position) -> Model {
  case model.view.selection {
    Some(selected) ->
      Model(
        ..model,
        view: view_set.selection(
          model.view,
          Some(selection.extend(selected, at)),
        ),
      )
    None -> model
  }
}

/// The release is where the copy happens. A click, which selects nothing,
/// dismisses a settled highlight; a drag copies the cells as the frame on
/// display shows them and leaves the highlight up as confirmation until the
/// next key or wheel notch.
@internal
pub fn finish_selection(model: Model, at: geometry.Position) -> Model {
  case model.view.selection {
    None -> model
    Some(selected) -> {
      let selected = selection.extend(selected, at)
      case selection.is_click(selected) {
        True ->
          Model(
            ..model,
            view: model.view
              |> view_set.selection(None)
              |> view_set.selection_gutters([])
              |> view_set.caches(
                Caches(..model.view.caches, selection_frame: None),
              ),
          )
        False -> {
          let shown =
            option.lazy_unwrap(model.view.caches.selection_frame, fn() {
              selection_display(model).0
            })
          let text = case selection_covers_transcript(model, selected) {
            True ->
              transcript_selection_text(
                shown,
                selected,
                model.view.selection_gutters,
              )
            False -> selection.text(shown, selected)
          }
          {
            let copied = write_clipboard(model, text)
            Model(
              shared: shared_set.notice(
                copied.shared,
                selection.copied_notice(list.length(selection.rows(selected))),
              ),
              view: view_set.selection(copied.view, Some(selected)),
            )
          }
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
  let screen = geometry.rect_new(0, 0, model.view.width, model.view.height)
  let #(_, body_area, _, _) = layout.layout(screen, model)
  let #(conversation, _) = layout.queue_body_layout(body_area, model)
  let transcript_panel = conversation
  selected.area == layout.transcript_inner(transcript_panel)
  && !layout.diff_covers_transcript(model)
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
  let screen = geometry.rect_new(0, 0, model.view.width, model.view.height)
  let #(_, body_area, _, _) = layout.layout(screen, model)
  let #(conversation, _) = layout.queue_body_layout(body_area, model)
  let transcript_panel = conversation
  let area = layout.transcript_inner(transcript_panel)
  model.view.rendered_gutters
  |> list.drop(model.view.scroll_offset + tui_model.viewport_backlog(model))
  |> list.take(area.size.height)
  |> list.reverse
  |> list.index_map(fn(gutter, index) { #(area.position.y + index, gutter) })
}

// The frame and its copy layout come from one completed cache entry. A paced
// scroll may leave that entry deliberately stale; taking either half from the
// current model would pair old cells with new row metadata.
fn selection_display(model: Model) -> #(buffer.Buffer, List(#(Int, Int))) {
  let screen = geometry.rect_new(0, 0, model.view.width, model.view.height)
  case model.view.caches.frame_cache {
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

// The copy is queued as an OSC 52 sequence rather than printed here, so a
// step that copies decides the write without making it; the runtime prints
// it in line with etui's own frames. A terminal with no clipboard gets
// nothing, not an escape sequence it would draw as text.
fn write_clipboard(model: Model, text: String) -> Model {
  case model.view.clipboard {
    TerminalClipboard ->
      tui_model.emit(
        model,
        effect.WriteClipboard(selection.clipboard_sequence(text)),
      )
    NoClipboard -> model
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
      model.view.scroll_offset + tui_model.viewport_backlog(model),
      older,
      rows,
    )
    |> projection.bounded_scroll_offset(
      model.view.rendered_row_count,
      layout.transcript_viewport_height(model),
    )
  let model =
    Model(
      // The reading row at the transcript's foot says how far below the
      // tail the reader is, so leaving the tail writes no notice of its own.
      // The notice standing is left as it was rather than cleared, so the
      // status band keeps its height and the viewport does not move under
      // the reader as they enter scrollback.
      shared: shared_set.notice(model.shared, case offset == 0 && !older {
        True -> "following output"
        False -> model.shared.notice
      }),
      view: view_set.scroll_offset(model.view, offset),
    )
  case model.view.help_open || model.view.notes_open, model.shared.captured {
    True, _ | _, None -> model
    False, Some(#(cut, view)) -> {
      case offset == 0 && !older {
        True -> {
          let history = history_view.resume(model.shared.scrollback)
          inbound.apply_cut(
            Model(..model, shared: shared_set.scrollback(model.shared, history)),
            cut,
            view,
          )
        }
        False -> {
          let history = history_view.freeze(model.shared.scrollback)
          let history = case
            older
            && offset + layout.transcript_viewport_height(model)
            >= model.view.rendered_row_count - history_prefetch_rows(model)
          {
            True ->
              history_view.older(
                history,
                history_view.branch(history, view).unloaded,
              )
            False -> history
          }
          inbound.service_history(
            Model(..model, shared: shared_set.scrollback(model.shared, history)),
          )
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
    model.shared.scrollback.mode != history_view.Reading
      || model.shared.scrollback.request != history_view.Quiet
      || model.shared.scrollback.before_seq <= 1
      || model.view.help_open
      || model.view.notes_open
      || model.view.scroll_offset + layout.transcript_viewport_height(model)
      < model.view.rendered_row_count - history_prefetch_rows(model),
    model,
  )
  case model.shared.captured {
    None -> model
    Some(#(_, view)) ->
      Model(
        ..model,
        shared: shared_set.scrollback(
          model.shared,
          history_view.older(
            model.shared.scrollback,
            history_view.branch(model.shared.scrollback, view).unloaded,
          ),
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
    layout.diff_covers_transcript(model)
    || model.shared.worktree.focus == worktree_view.Navigator,
    sheet_text_tab(model)
  {
    True, _ -> scroll_diff(model, direction, layout.diff_patch_height(model))
    False, True ->
      scrolled_tab(model, case direction {
        Older -> -rows
        Newer -> rows
      })
    False, False -> scroll_transcript(model, direction == Older, rows)
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
  use <- bool.lazy_guard(
    model.shared.context.surface != context_view.Hidden,
    fn() {
      scroll_context(model, case direction {
        Older -> -3
        Newer -> 3
      })
    },
  )
  case
    layout.diff_covers_transcript(model)
    || {
      layout.diff_shown(model)
      && geometry.contains(layout.active_diff_panel(model), position)
    },
    sheet_text_tab(model)
  {
    True, _ -> scroll_diff(model, direction, 3)
    False, True ->
      scrolled_tab(model, case direction {
        Older -> -3
        Newer -> 3
      })
    False, False -> scroll_transcript(model, direction == Older, 3)
  }
}

// Whether the sheet is showing Trace or Session, which are text with a scroll
// of their own, over a transcript the wheel must not move.
fn sheet_text_tab(model: Model) -> Bool {
  layout.sheet_shown(model)
  && case layout.rail_tab(model) {
    rail.Trace | rail.Session -> True
    rail.Strands | rail.Changes -> False
  }
}

fn scroll_diff(model: Model, direction: ScrollDirection, rows: Int) -> Model {
  let current =
    projection.bounded_scroll_offset(
      model.view.diff_scroll_offset,
      model.view.diff_row_count,
      layout.diff_patch_height(model),
    )
  let offset =
    scroll_offset(current, direction == Older, rows)
    |> projection.bounded_scroll_offset(
      model.view.diff_row_count,
      layout.diff_patch_height(model),
    )
  Model(
    shared: shared_set.notice(model.shared, "scrolling captured changes"),
    view: view_set.diff_scroll_offset(model.view, offset),
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
  let index = case model.view.queue_editor.surface {
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
              model.view.queue_editor.selected,
              int.max(0, list.length(rows) - visible),
            )
          offset + at.y - list_area.position.y
        }
        False -> -1
      }
    }
    queue_editor.Editor -> -1
  }
  let visible = case model.view.queue_editor.surface {
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
  let state = model.view.queue_editor
  case key, state.surface {
    keys.Ctrl("c"), _ -> submit.quit(model)
    keys.Escape, queue_editor.Editor ->
      Model(
        shared: shared_set.queue_request(
          model.shared,
          queue_request.State(
            ..model.shared.queue_request,
            fetch: None,
            awaiting: None,
          ),
        ),
        view: view_set.queue_editor(
          model.view,
          queue_editor.State(..state, surface: queue_editor.Inspector),
        ),
      )
    keys.Escape, queue_editor.Inspector ->
      Model(
        shared: shared_set.queue_request(
          model.shared,
          queue_request.State(
            ..model.shared.queue_request,
            fetch: None,
            awaiting: None,
          ),
        ),
        view: view_set.queue_editor(
          model.view,
          queue_editor.State(..state, surface: queue_editor.Closed),
        ),
      )
    keys.Up, queue_editor.Inspector ->
      Model(
        ..model,
        view: view_set.queue_editor(
          model.view,
          queue_editor.State(
            ..state,
            selected: int.max(0, state.selected - 1),
            preview_scroll: 0,
          ),
        ),
      )
    keys.Down, queue_editor.Inspector ->
      Model(
        ..model,
        view: view_set.queue_editor(
          model.view,
          queue_editor.State(
            ..state,
            selected: int.min(
              int.max(0, list.length(layout.queue_rows(model)) - 1),
              state.selected + 1,
            ),
            preview_scroll: 0,
          ),
        ),
      )
    keys.PageUp, queue_editor.Inspector -> {
      let area = layout.queue_preview_area(model)
      let maximum =
        queue_panel.max_scroll(layout.queue_rows(model), state.selected, area)
      Model(
        ..model,
        view: view_set.queue_editor(
          model.view,
          queue_editor.State(
            ..state,
            preview_scroll: int.max(
              0,
              int.min(state.preview_scroll, maximum)
                - queue_panel.page_rows(area),
            ),
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
        view: view_set.queue_editor(
          model.view,
          queue_editor.State(
            ..state,
            preview_scroll: int.min(
              maximum,
              int.min(state.preview_scroll, maximum)
                + queue_panel.page_rows(area),
            ),
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
  case model.view.queue_editor.draft {
    Some(_) ->
      Model(
        shared: shared_set.queue_request(model.shared, queue_request.new()),
        view: view_set.queue_editor(
          model.view,
          queue_editor.State(
            ..model.view.queue_editor,
            surface: queue_editor.Editor,
            message: "Retained draft resumed · Ctrl+s saves · Esc returns to inspection",
          ),
        ),
      )
    None ->
      Model(
        ..model,
        view: view_set.queue_editor(
          model.view,
          queue_editor.State(
            ..model.view.queue_editor,
            message: "No retained queue draft to resume",
          ),
        ),
      )
  }
}

fn select_queue_input(model: Model) -> Model {
  let state = model.view.queue_editor
  case list.first(list.drop(layout.queue_rows(model), state.selected)) {
    Ok(row) ->
      case
        retained_other_draft(
          state.draft,
          row,
          session_model.queue_namespace(model.shared),
        ),
        row.editing
      {
        True, _ ->
          Model(
            ..model,
            view: view_set.queue_editor(
              model.view,
              queue_editor.State(
                ..state,
                message: "Retained draft belongs to another input · e resumes it; browsing remains available",
              ),
            ),
          )
        False, snapshot_view.Editable -> {
          let fetch =
            queue_request.Fetch(
              session_model.queue_owner(model.shared),
              session_model.queue_namespace(model.shared),
              row.strand,
              row.id,
            )
          tui_model.run_shared(
            Model(
              shared: shared_set.queue_request(
                model.shared,
                queue_request.State(
                  fetch: Some(fetch),
                  awaiting: None,
                  request_id: None,
                ),
              ),
              view: view_set.queue_editor(
                model.view,
                queue_editor.State(
                  ..state,
                  message: "Waiting for the full queued input…",
                ),
              ),
            ),
            surfaces.service_queue_read,
          )
        }
        False, snapshot_view.ReadOnly ->
          Model(
            ..model,
            view: view_set.queue_editor(
              model.view,
              queue_editor.State(
                ..state,
                message: "This queued input is read-only for this attachment",
              ),
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
  let state = model.view.queue_editor
  case state.draft {
    Some(draft) if draft.delivery != queue_editor.Saving -> {
      use <- bool.guard(
        draft.namespace != session_model.queue_namespace(model.shared),
        Model(
          ..model,
          view: view_set.queue_editor(
            model.view,
            queue_editor.State(
              ..state,
              message: "Queue namespace changed; this retained draft cannot be rebound",
            ),
          ),
        ),
      )
      let fetch =
        queue_request.Fetch(
          session_model.queue_owner(model.shared),
          session_model.queue_namespace(model.shared),
          draft.document.strand,
          draft.document.id,
        )
      tui_model.run_shared(
        Model(
          shared: shared_set.queue_request(
            model.shared,
            queue_request.State(
              ..model.shared.queue_request,
              fetch: Some(fetch),
            ),
          ),
          view: view_set.queue_editor(
            model.view,
            queue_editor.State(
              ..state,
              message: "Explicitly reconciling with the current queue…",
            ),
          ),
        ),
        surfaces.service_queue_read,
      )
    }
    Some(_) | None -> model
  }
}

fn save_queue_draft(model: Model) -> Model {
  case model.view.queue_editor.draft, model.shared.channel {
    Some(draft), Some(channel) if draft.delivery == queue_editor.Editable -> {
      let available =
        session_channel.mutation_available(channel)
        && session_model.queue_owner(model.shared) == draft.owner
        && session_model.queue_namespace(model.shared) == draft.namespace
      case available {
        True ->
          tui_model.send_frame(
            Model(
              shared: shared_set.pending_submission(
                model.shared,
                Some(OverlaySubmission),
              ),
              view: view_set.queue_editor(
                model.view,
                queue_editor.State(
                  ..model.view.queue_editor,
                  draft: Some(
                    queue_editor.Draft(..draft, delivery: queue_editor.Saving),
                  ),
                  message: "Saving this revision…",
                ),
              ),
            ),
            protocol.edit_queued_input(
              model.shared.next_id,
              draft.document,
              text_area.value(draft.input),
            ),
          )
        False ->
          Model(
            ..model,
            view: view_set.queue_editor(
              model.view,
              queue_editor.State(
                ..model.view.queue_editor,
                message: "Attachment changed or command lane is busy; draft retained",
              ),
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
  case model.view.queue_editor.draft {
    Some(draft) if draft.delivery == queue_editor.Editable ->
      Model(
        ..model,
        view: view_set.queue_editor(
          model.view,
          queue_editor.State(
            ..model.view.queue_editor,
            draft: Some(queue_editor.Draft(..draft, input: edit(draft.input))),
          ),
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
        shared: shared_set.worktree(
          model.shared,
          worktree_view.State(
            ..model.shared.worktree,
            focus: worktree_view.Composer,
          ),
        ),
      )
    keys.Char("r") -> inbound.refresh_worktree(model)
    keys.Escape ->
      Model(
        shared: shared_set.worktree(
          model.shared,
          worktree_view.State(
            ..model.shared.worktree,
            focus: worktree_view.Composer,
          ),
        ),
        view: view_set.diff_view(model.view, DiffHidden),
      )
    keys.PageUp -> scroll_diff(model, Older, layout.diff_patch_height(model))
    keys.PageDown -> scroll_diff(model, Newer, layout.diff_patch_height(model))
    _ -> model
  }
}

fn select_diff_file(model: Model, delta: Int) -> Model {
  let selected =
    int.clamp(
      model.shared.worktree.selected + delta,
      0,
      list.length(worktree_view.labels(model.shared.worktree)) - 1,
    )
  Model(
    shared: shared_set.worktree(
      model.shared,
      worktree_view.State(..model.shared.worktree, selected:),
    ),
    view: view_set.diff_scroll_offset(model.view, 0),
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
  let current = int.min(model.view.summary_scroll, maximum)
  case key {
    keys.Ctrl("c") -> submit.quit(model)
    keys.Escape ->
      Model(
        ..model,
        view: view_set.summary_surface(model.view, queue_editor.Closed),
      )
    keys.Char("r") ->
      tui_model.run_shared(
        Model(
          shared: shared_set.jobs_refresh(model.shared, worktree_view.Requested),
          view: view_set.summary_scroll(model.view, 0),
        ),
        surfaces.service_jobs_read,
      )
    keys.Char("1") ->
      Model(
        ..model,
        view: model.view
          |> view_set.summary_tab(summary_panel.Completion)
          |> view_set.summary_scroll(0),
      )
    keys.Char("2") ->
      Model(
        ..model,
        view: model.view
          |> view_set.summary_tab(summary_panel.Usage)
          |> view_set.summary_scroll(0),
      )
    keys.Char("3") ->
      Model(
        ..model,
        view: model.view
          |> view_set.summary_tab(summary_panel.Jobs)
          |> view_set.summary_scroll(0),
      )
    keys.Char("[") -> select_summary_job(model, -1)
    keys.Char("]") -> select_summary_job(model, 1)
    keys.Up ->
      Model(
        ..model,
        view: view_set.summary_scroll(model.view, int.max(0, current - 1)),
      )
    keys.Down ->
      Model(
        ..model,
        view: view_set.summary_scroll(model.view, int.min(maximum, current + 1)),
      )
    keys.PageUp ->
      Model(
        ..model,
        view: view_set.summary_scroll(
          model.view,
          int.max(0, current - viewport),
        ),
      )
    keys.PageDown ->
      Model(
        ..model,
        view: view_set.summary_scroll(
          model.view,
          int.min(maximum, current + viewport),
        ),
      )
    _ -> model
  }
}

fn select_summary_job(model: Model, delta: Int) -> Model {
  case model.view.summary_tab, model.shared.jobs {
    summary_panel.Jobs, Some(board)
      if board.strand == model.shared.active_strand
    ->
      Model(
        ..model,
        view: model.view
          |> view_set.summary_job_selected(int.clamp(
            model.view.summary_job_selected + delta,
            0,
            int.max(0, list.length(board.jobs) - 1),
          ))
          |> view_set.summary_scroll(0),
      )
    summary_panel.Completion, _
    | summary_panel.Usage, _
    | summary_panel.Jobs, None
    | summary_panel.Jobs, Some(_)
    -> model
  }
}

fn update_context_key(key: keys.Key, model: Model) -> Model {
  let state = model.shared.context
  let viewport = layout.panel_inner(layout.model_screen(model)).size.height
  case key {
    keys.Ctrl("c") -> submit.quit(model)
    keys.Escape ->
      Model(
        ..model,
        shared: shared_set.context(
          model.shared,
          context_view.State(..state, surface: context_view.Hidden),
        ),
      )
    keys.Char("r") ->
      tui_model.run_shared(
        Model(
          ..model,
          shared: shared_set.context(
            model.shared,
            context_view.State(..context_view.invalidate(state), scroll: 0),
          ),
        ),
        surfaces.service_context_read,
      )
    keys.Char("a") ->
      Model(
        ..model,
        shared: shared_set.context(
          model.shared,
          context_view.State(..state, scroll: 0, surface: case state.surface {
            context_view.All -> context_view.Overview
            context_view.Overview | context_view.Hidden -> context_view.All
          }),
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
      list.length(context_panel.lines(model.shared.context, inner.size.width))
        - inner.size.height,
    )
  let current = int.min(model.shared.context.scroll, maximum)
  Model(
    ..model,
    shared: shared_set.context(
      model.shared,
      context_view.State(
        ..model.shared.context,
        scroll: int.clamp(current + delta, 0, maximum),
      ),
    ),
  )
}
