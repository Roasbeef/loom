//// One-field updates of `View`.
////
//// `View` has about eighty fields. Gleam compiles `View(..view, overlay: x)`
//// to a tuple that reads every untouched field with its own `element/2`, so
//// each such expression costs erlc one copy of the whole record, measured at
//// roughly 10 ms. The terminal's handlers and tests held several hundred of
//// them, and they were most of the package's compile time
//// (`skills/beam-compile-review`). A handler that changes one field calls
//// the setter here, so the record is expanded once per field and the handler
//// pays for a call. A setter returns the view unchanged in every other field,
//// exactly as the record update it replaces; several fields are set by
//// piping the view through one setter after another. A chain of N setters
//// builds N intermediate records where the replaced update built one. The
//// result is identical, and the extra short-lived allocation is accepted for
//// the compile-time win.
////
//// A setter exists for each field that three or more call sites set. A
//// field with fewer keeps its record update at the call site, where a setter
//// would cost as much as it saves.

import tui/model.{type View, View} as _

/// Replaces `View.overlay`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.overlay(model.view, value)
/// ```
@internal
pub fn overlay(view: View, overlay) -> View {
  View(..view, overlay:)
}

/// Replaces `View.input`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.input(model.view, value)
/// ```
@internal
pub fn input(view: View, input) -> View {
  View(..view, input:)
}

/// Replaces `View.caches`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.caches(model.view, value)
/// ```
@internal
pub fn caches(view: View, caches) -> View {
  View(..view, caches:)
}

/// Replaces `View.queue_editor`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.queue_editor(model.view, value)
/// ```
@internal
pub fn queue_editor(view: View, queue_editor) -> View {
  View(..view, queue_editor:)
}

/// Replaces `View.candidate`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.candidate(model.view, value)
/// ```
@internal
pub fn candidate(view: View, candidate) -> View {
  View(..view, candidate:)
}

/// Replaces `View.notes_open`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.notes_open(model.view, value)
/// ```
@internal
pub fn notes_open(view: View, notes_open) -> View {
  View(..view, notes_open:)
}

/// Replaces `View.control_request`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.control_request(model.view, value)
/// ```
@internal
pub fn control_request(view: View, control_request) -> View {
  View(..view, control_request:)
}

/// Replaces `View.scroll_offset`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.scroll_offset(model.view, value)
/// ```
@internal
pub fn scroll_offset(view: View, scroll_offset) -> View {
  View(..view, scroll_offset:)
}

/// Replaces `View.submission_mode`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.submission_mode(model.view, value)
/// ```
@internal
pub fn submission_mode(view: View, submission_mode) -> View {
  View(..view, submission_mode:)
}

/// Replaces `View.reconnect`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.reconnect(model.view, value)
/// ```
@internal
pub fn reconnect(view: View, reconnect) -> View {
  View(..view, reconnect:)
}

/// Replaces `View.diff_view`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.diff_view(model.view, value)
/// ```
@internal
pub fn diff_view(view: View, diff_view) -> View {
  View(..view, diff_view:)
}

/// Replaces `View.note_scroll`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.note_scroll(model.view, value)
/// ```
@internal
pub fn note_scroll(view: View, note_scroll) -> View {
  View(..view, note_scroll:)
}

/// Replaces `View.activity_poll`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.activity_poll(model.view, value)
/// ```
@internal
pub fn activity_poll(view: View, activity_poll) -> View {
  View(..view, activity_poll:)
}

/// Replaces `View.note_selected`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.note_selected(model.view, value)
/// ```
@internal
pub fn note_selected(view: View, note_selected) -> View {
  View(..view, note_selected:)
}

/// Replaces `View.rail_focus`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.rail_focus(model.view, value)
/// ```
@internal
pub fn rail_focus(view: View, rail_focus) -> View {
  View(..view, rail_focus:)
}

/// Replaces `View.summary_scroll`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.summary_scroll(model.view, value)
/// ```
@internal
pub fn summary_scroll(view: View, summary_scroll) -> View {
  View(..view, summary_scroll:)
}

/// Replaces `View.running`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.running(model.view, value)
/// ```
@internal
pub fn running(view: View, running) -> View {
  View(..view, running:)
}

/// Replaces `View.transport_time_ms`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.transport_time_ms(model.view, value)
/// ```
@internal
pub fn transport_time_ms(view: View, transport_time_ms) -> View {
  View(..view, transport_time_ms:)
}

/// Replaces `View.rail`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.rail(model.view, value)
/// ```
@internal
pub fn rail(view: View, rail) -> View {
  View(..view, rail:)
}

/// Replaces `View.revealed_rows`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.revealed_rows(model.view, value)
/// ```
@internal
pub fn revealed_rows(view: View, revealed_rows) -> View {
  View(..view, revealed_rows:)
}

/// Replaces `View.command_selected`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.command_selected(model.view, value)
/// ```
@internal
pub fn command_selected(view: View, command_selected) -> View {
  View(..view, command_selected:)
}

/// Replaces `View.diff_scroll_offset`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.diff_scroll_offset(model.view, value)
/// ```
@internal
pub fn diff_scroll_offset(view: View, diff_scroll_offset) -> View {
  View(..view, diff_scroll_offset:)
}

/// Replaces `View.inspecting_approval`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.inspecting_approval(model.view, value)
/// ```
@internal
pub fn inspecting_approval(view: View, inspecting_approval) -> View {
  View(..view, inspecting_approval:)
}

/// Replaces `View.local_options`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.local_options(model.view, value)
/// ```
@internal
pub fn local_options(view: View, local_options) -> View {
  View(..view, local_options:)
}

/// Replaces `View.launch_note`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.launch_note(model.view, Some("a line"))
/// ```
@internal
pub fn launch_note(view: View, launch_note) -> View {
  View(..view, launch_note:)
}

/// Replaces `View.selection`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.selection(model.view, value)
/// ```
@internal
pub fn selection(view: View, selection) -> View {
  View(..view, selection:)
}

/// Replaces `View.history_draft`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.history_draft(model.view, value)
/// ```
@internal
pub fn history_draft(view: View, history_draft) -> View {
  View(..view, history_draft:)
}

/// Replaces `View.rendered_revision`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.rendered_revision(model.view, value)
/// ```
@internal
pub fn rendered_revision(view: View, rendered_revision) -> View {
  View(..view, rendered_revision:)
}

/// Replaces `View.history_index`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.history_index(model.view, value)
/// ```
@internal
pub fn history_index(view: View, history_index) -> View {
  View(..view, history_index:)
}

/// Replaces `View.cache_outlook`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.cache_outlook(model.view, value)
/// ```
@internal
pub fn cache_outlook(view: View, cache_outlook) -> View {
  View(..view, cache_outlook:)
}

/// Replaces `View.help_open`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.help_open(model.view, value)
/// ```
@internal
pub fn help_open(view: View, help_open) -> View {
  View(..view, help_open:)
}

/// Replaces `View.record_gutters`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.record_gutters(model.view, value)
/// ```
@internal
pub fn record_gutters(view: View, record_gutters) -> View {
  View(..view, record_gutters:)
}

/// Replaces `View.monotonic_time_ms`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.monotonic_time_ms(model.view, value)
/// ```
@internal
pub fn monotonic_time_ms(view: View, monotonic_time_ms) -> View {
  View(..view, monotonic_time_ms:)
}

/// Replaces `View.width`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.width(model.view, value)
/// ```
@internal
pub fn width(view: View, width) -> View {
  View(..view, width:)
}

/// Replaces `View.height`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.height(model.view, value)
/// ```
@internal
pub fn height(view: View, height) -> View {
  View(..view, height:)
}

/// Replaces `View.selection_gutters`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.selection_gutters(model.view, value)
/// ```
@internal
pub fn selection_gutters(view: View, selection_gutters) -> View {
  View(..view, selection_gutters:)
}

/// Replaces `View.prompted_approvals`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.prompted_approvals(model.view, value)
/// ```
@internal
pub fn prompted_approvals(view: View, prompted_approvals) -> View {
  View(..view, prompted_approvals:)
}

/// Replaces `View.configuring`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.configuring(model.view, value)
/// ```
@internal
pub fn configuring(view: View, configuring) -> View {
  View(..view, configuring:)
}

/// Replaces `View.workspace`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.workspace(model.view, value)
/// ```
@internal
pub fn workspace(view: View, workspace) -> View {
  View(..view, workspace:)
}

/// Replaces `View.note_mode`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.note_mode(model.view, value)
/// ```
@internal
pub fn note_mode(view: View, note_mode) -> View {
  View(..view, note_mode:)
}

/// Replaces `View.summary_tab`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.summary_tab(model.view, value)
/// ```
@internal
pub fn summary_tab(view: View, summary_tab) -> View {
  View(..view, summary_tab:)
}

/// Replaces `View.opening_image`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.opening_image(model.view, value)
/// ```
@internal
pub fn opening_image(view: View, opening_image) -> View {
  View(..view, opening_image:)
}

/// Replaces `View.next_attempt`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.next_attempt(model.view, value)
/// ```
@internal
pub fn next_attempt(view: View, next_attempt) -> View {
  View(..view, next_attempt:)
}

/// Replaces `View.rendered_row_count`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.rendered_row_count(model.view, value)
/// ```
@internal
pub fn rendered_row_count(view: View, rendered_row_count) -> View {
  View(..view, rendered_row_count:)
}

/// Replaces `View.strip_focus`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.strip_focus(model.view, value)
/// ```
@internal
pub fn strip_focus(view: View, strip_focus) -> View {
  View(..view, strip_focus:)
}

/// Replaces `View.summary_surface`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.summary_surface(model.view, value)
/// ```
@internal
pub fn summary_surface(view: View, summary_surface) -> View {
  View(..view, summary_surface:)
}

/// Replaces `View.summary_job_selected`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.summary_job_selected(model.view, value)
/// ```
@internal
pub fn summary_job_selected(view: View, summary_job_selected) -> View {
  View(..view, summary_job_selected:)
}

/// Replaces `View.herdr_reporter`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.herdr_reporter(model.view, value)
/// ```
@internal
pub fn herdr_reporter(view: View, herdr_reporter) -> View {
  View(..view, herdr_reporter:)
}

/// Replaces `View.frame_debt`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.frame_debt(model.view, value)
/// ```
@internal
pub fn frame_debt(view: View, frame_debt) -> View {
  View(..view, frame_debt:)
}

/// Replaces `View.strand_workspaces`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.strand_workspaces(model.view, value)
/// ```
@internal
pub fn strand_workspaces(view: View, strand_workspaces) -> View {
  View(..view, strand_workspaces:)
}

/// Replaces `View.history`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.history(model.view, value)
/// ```
@internal
pub fn history(view: View, history) -> View {
  View(..view, history:)
}

/// Replaces `View.sheet`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.sheet(model.view, value)
/// ```
@internal
pub fn sheet(view: View, sheet) -> View {
  View(..view, sheet:)
}

/// Replaces `View.outbox`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// view_set.outbox(model.view, value)
/// ```
@internal
pub fn outbox(view: View, outbox) -> View {
  View(..view, outbox:)
}

/// Flips `View.repaint_phase`, which tells the painter that the next frame
/// must be drawn in full.
///
/// ## Examples
///
/// ```gleam
/// view_set.toggle_repaint(model.view)
/// ```
@internal
pub fn toggle_repaint(view: View) -> View {
  View(..view, repaint_phase: !view.repaint_phase)
}
