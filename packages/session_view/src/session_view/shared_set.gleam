//// One-field updates of `Shared`.
////
//// `Shared` has about ninety fields. Gleam compiles `Shared(..shared, notice:
//// x)` to a tuple that reads every untouched field with its own `element/2`,
//// so each such expression costs erlc one copy of the whole record, measured
//// at roughly 10 ms. The session reducers, the terminal and their tests held
//// several hundred of them, and they were most of the compile time of
//// `session_view` and `tui` (`skills/beam-compile-review`). A reducer that
//// changes one field calls the setter here, so the record is expanded once
//// per field and the reducer pays for a call. A setter returns the record
//// unchanged in every other field, exactly as the record update it replaces;
//// several fields are set by piping the record through one setter after
//// another.
////
//// A setter exists for each field that three or more call sites set. A
//// field with fewer keeps its record update at the call site, where a setter
//// would cost as much as it saves.
////
//// ## Flow
////
//// `notice` → `strands` → `peer`
////
//// The module is a table, not a path. Those three are the setters the callers
//// use most, and every other setter has the same one-field shape, in the order
//// of how many call sites set it.

import session_view/model.{type Shared, Shared} as _

/// Replaces `Shared.notice`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.notice(model.shared, value)
/// ```
@internal
pub fn notice(shared: Shared(a, b, c, d), notice) -> Shared(a, b, c, d) {
  Shared(..shared, notice:)
}

/// Replaces `Shared.strands`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.strands(model.shared, value)
/// ```
@internal
pub fn strands(shared: Shared(a, b, c, d), strands) -> Shared(a, b, c, d) {
  Shared(..shared, strands:)
}

/// Replaces `Shared.peer`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.peer(model.shared, value)
/// ```
@internal
pub fn peer(shared: Shared(a, b, c, d), peer) -> Shared(a, b, c, d) {
  Shared(..shared, peer:)
}

/// Replaces `Shared.transcript`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.transcript(model.shared, value)
/// ```
@internal
pub fn transcript(
  shared: Shared(a, b, c, d),
  transcript,
) -> Shared(a, b, c, d) {
  Shared(..shared, transcript:)
}

/// Replaces `Shared.records`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.records(model.shared, value)
/// ```
@internal
pub fn records(shared: Shared(a, b, c, d), records) -> Shared(a, b, c, d) {
  Shared(..shared, records:)
}

/// Replaces `Shared.session`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.session(model.shared, value)
/// ```
@internal
pub fn session(shared: Shared(a, b, c, d), session) -> Shared(a, b, c, d) {
  Shared(..shared, session:)
}

/// Replaces `Shared.worktree`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.worktree(model.shared, value)
/// ```
@internal
pub fn worktree(shared: Shared(a, b, c, d), worktree) -> Shared(a, b, c, d) {
  Shared(..shared, worktree:)
}

/// Replaces `Shared.channel`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.channel(model.shared, value)
/// ```
@internal
pub fn channel(shared: Shared(a, b, c, d), channel) -> Shared(a, b, c, d) {
  Shared(..shared, channel:)
}

/// Replaces `Shared.record_cache_valid`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.record_cache_valid(model.shared, value)
/// ```
@internal
pub fn record_cache_valid(
  shared: Shared(a, b, c, d),
  record_cache_valid,
) -> Shared(a, b, c, d) {
  Shared(..shared, record_cache_valid:)
}

/// Replaces `Shared.submitting`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.submitting(model.shared, value)
/// ```
@internal
pub fn submitting(
  shared: Shared(a, b, c, d),
  submitting,
) -> Shared(a, b, c, d) {
  Shared(..shared, submitting:)
}

/// Replaces `Shared.scrollback`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.scrollback(model.shared, value)
/// ```
@internal
pub fn scrollback(
  shared: Shared(a, b, c, d),
  scrollback,
) -> Shared(a, b, c, d) {
  Shared(..shared, scrollback:)
}

/// Replaces `Shared.captured`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.captured(model.shared, value)
/// ```
@internal
pub fn captured(shared: Shared(a, b, c, d), captured) -> Shared(a, b, c, d) {
  Shared(..shared, captured:)
}

/// Replaces `Shared.attachments`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.attachments(model.shared, value)
/// ```
@internal
pub fn attachments(
  shared: Shared(a, b, c, d),
  attachments,
) -> Shared(a, b, c, d) {
  Shared(..shared, attachments:)
}

/// Replaces `Shared.active_strand`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.active_strand(model.shared, value)
/// ```
@internal
pub fn active_strand(
  shared: Shared(a, b, c, d),
  active_strand,
) -> Shared(a, b, c, d) {
  Shared(..shared, active_strand:)
}

/// Replaces `Shared.goal_report`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.goal_report(model.shared, value)
/// ```
@internal
pub fn goal_report(
  shared: Shared(a, b, c, d),
  goal_report,
) -> Shared(a, b, c, d) {
  Shared(..shared, goal_report:)
}

/// Replaces `Shared.nudges`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.nudges(model.shared, value)
/// ```
@internal
pub fn nudges(shared: Shared(a, b, c, d), nudges) -> Shared(a, b, c, d) {
  Shared(..shared, nudges:)
}

/// Replaces `Shared.streams`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.streams(model.shared, value)
/// ```
@internal
pub fn streams(shared: Shared(a, b, c, d), streams) -> Shared(a, b, c, d) {
  Shared(..shared, streams:)
}

/// Replaces `Shared.queue_request`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.queue_request(model.shared, value)
/// ```
@internal
pub fn queue_request(
  shared: Shared(a, b, c, d),
  queue_request,
) -> Shared(a, b, c, d) {
  Shared(..shared, queue_request:)
}

/// Replaces `Shared.interrupt`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.interrupt(model.shared, value)
/// ```
@internal
pub fn interrupt(shared: Shared(a, b, c, d), interrupt) -> Shared(a, b, c, d) {
  Shared(..shared, interrupt:)
}

/// Replaces `Shared.context`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.context(model.shared, value)
/// ```
@internal
pub fn context(shared: Shared(a, b, c, d), context) -> Shared(a, b, c, d) {
  Shared(..shared, context:)
}

/// Replaces `Shared.details_expanded`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.details_expanded(model.shared, value)
/// ```
@internal
pub fn details_expanded(
  shared: Shared(a, b, c, d),
  details_expanded,
) -> Shared(a, b, c, d) {
  Shared(..shared, details_expanded:)
}

/// Replaces `Shared.inbox`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.inbox(model.shared, value)
/// ```
@internal
pub fn inbox(shared: Shared(a, b, c, d), inbox) -> Shared(a, b, c, d) {
  Shared(..shared, inbox:)
}

/// Replaces `Shared.tool_tails`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.tool_tails(model.shared, value)
/// ```
@internal
pub fn tool_tails(
  shared: Shared(a, b, c, d),
  tool_tails,
) -> Shared(a, b, c, d) {
  Shared(..shared, tool_tails:)
}

/// Replaces `Shared.queued`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.queued(model.shared, value)
/// ```
@internal
pub fn queued(shared: Shared(a, b, c, d), queued) -> Shared(a, b, c, d) {
  Shared(..shared, queued:)
}

/// Replaces `Shared.cache`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.cache(model.shared, value)
/// ```
@internal
pub fn cache(shared: Shared(a, b, c, d), cache) -> Shared(a, b, c, d) {
  Shared(..shared, cache:)
}

/// Replaces `Shared.pending_submission`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.pending_submission(model.shared, value)
/// ```
@internal
pub fn pending_submission(
  shared: Shared(a, b, c, d),
  pending_submission,
) -> Shared(a, b, c, d) {
  Shared(..shared, pending_submission:)
}

/// Replaces `Shared.goal`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.goal(model.shared, value)
/// ```
@internal
pub fn goal(shared: Shared(a, b, c, d), goal) -> Shared(a, b, c, d) {
  Shared(..shared, goal:)
}

/// Replaces `Shared.awaiting_outcome`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.awaiting_outcome(model.shared, value)
/// ```
@internal
pub fn awaiting_outcome(
  shared: Shared(a, b, c, d),
  awaiting_outcome,
) -> Shared(a, b, c, d) {
  Shared(..shared, awaiting_outcome:)
}

/// Replaces `Shared.reviewer_rows`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.reviewer_rows(model.shared, value)
/// ```
@internal
pub fn reviewer_rows(
  shared: Shared(a, b, c, d),
  reviewer_rows,
) -> Shared(a, b, c, d) {
  Shared(..shared, reviewer_rows:)
}

/// Replaces `Shared.queue_notices`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.queue_notices(model.shared, value)
/// ```
@internal
pub fn queue_notices(
  shared: Shared(a, b, c, d),
  queue_notices,
) -> Shared(a, b, c, d) {
  Shared(..shared, queue_notices:)
}

/// Replaces `Shared.advisor_history`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.advisor_history(model.shared, value)
/// ```
@internal
pub fn advisor_history(
  shared: Shared(a, b, c, d),
  advisor_history,
) -> Shared(a, b, c, d) {
  Shared(..shared, advisor_history:)
}

/// Replaces `Shared.notes_requested`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.notes_requested(model.shared, value)
/// ```
@internal
pub fn notes_requested(
  shared: Shared(a, b, c, d),
  notes_requested,
) -> Shared(a, b, c, d) {
  Shared(..shared, notes_requested:)
}

/// Replaces `Shared.agent_rows`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.agent_rows(model.shared, value)
/// ```
@internal
pub fn agent_rows(
  shared: Shared(a, b, c, d),
  agent_rows,
) -> Shared(a, b, c, d) {
  Shared(..shared, agent_rows:)
}

/// Replaces `Shared.stamp`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.stamp(model.shared, value)
/// ```
@internal
pub fn stamp(shared: Shared(a, b, c, d), stamp) -> Shared(a, b, c, d) {
  Shared(..shared, stamp:)
}

/// Replaces `Shared.nudges_awaiting`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.nudges_awaiting(model.shared, value)
/// ```
@internal
pub fn nudges_awaiting(
  shared: Shared(a, b, c, d),
  nudges_awaiting,
) -> Shared(a, b, c, d) {
  Shared(..shared, nudges_awaiting:)
}

/// Replaces `Shared.current_model`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.current_model(model.shared, value)
/// ```
@internal
pub fn current_model(
  shared: Shared(a, b, c, d),
  current_model,
) -> Shared(a, b, c, d) {
  Shared(..shared, current_model:)
}

/// Replaces `Shared.roster`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.roster(model.shared, value)
/// ```
@internal
pub fn roster(shared: Shared(a, b, c, d), roster) -> Shared(a, b, c, d) {
  Shared(..shared, roster:)
}

/// Replaces `Shared.jobs_refresh`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.jobs_refresh(model.shared, value)
/// ```
@internal
pub fn jobs_refresh(
  shared: Shared(a, b, c, d),
  jobs_refresh,
) -> Shared(a, b, c, d) {
  Shared(..shared, jobs_refresh:)
}

/// Replaces `Shared.agent_messages`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.agent_messages(model.shared, value)
/// ```
@internal
pub fn agent_messages(
  shared: Shared(a, b, c, d),
  agent_messages,
) -> Shared(a, b, c, d) {
  Shared(..shared, agent_messages:)
}

/// Replaces `Shared.goal_awaiting`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.goal_awaiting(model.shared, value)
/// ```
@internal
pub fn goal_awaiting(
  shared: Shared(a, b, c, d),
  goal_awaiting,
) -> Shared(a, b, c, d) {
  Shared(..shared, goal_awaiting:)
}

/// Replaces `Shared.goal_request`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.goal_request(model.shared, value)
/// ```
@internal
pub fn goal_request(
  shared: Shared(a, b, c, d),
  goal_request,
) -> Shared(a, b, c, d) {
  Shared(..shared, goal_request:)
}

/// Replaces `Shared.nudges_request`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.nudges_request(model.shared, value)
/// ```
@internal
pub fn nudges_request(
  shared: Shared(a, b, c, d),
  nudges_request,
) -> Shared(a, b, c, d) {
  Shared(..shared, nudges_request:)
}

/// Replaces `Shared.summaries`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.summaries(model.shared, value)
/// ```
@internal
pub fn summaries(shared: Shared(a, b, c, d), summaries) -> Shared(a, b, c, d) {
  Shared(..shared, summaries:)
}

/// Replaces `Shared.jobs_notice`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.jobs_notice(model.shared, value)
/// ```
@internal
pub fn jobs_notice(
  shared: Shared(a, b, c, d),
  jobs_notice,
) -> Shared(a, b, c, d) {
  Shared(..shared, jobs_notice:)
}

/// Replaces `Shared.nudges_refresh`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.nudges_refresh(model.shared, value)
/// ```
@internal
pub fn nudges_refresh(
  shared: Shared(a, b, c, d),
  nudges_refresh,
) -> Shared(a, b, c, d) {
  Shared(..shared, nudges_refresh:)
}

/// Replaces `Shared.skills`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.skills(model.shared, value)
/// ```
@internal
pub fn skills(shared: Shared(a, b, c, d), skills) -> Shared(a, b, c, d) {
  Shared(..shared, skills:)
}

/// Replaces `Shared.note_board`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.note_board(model.shared, value)
/// ```
@internal
pub fn note_board(
  shared: Shared(a, b, c, d),
  note_board,
) -> Shared(a, b, c, d) {
  Shared(..shared, note_board:)
}

/// Replaces `Shared.approvals`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.approvals(model.shared, value)
/// ```
@internal
pub fn approvals(shared: Shared(a, b, c, d), approvals) -> Shared(a, b, c, d) {
  Shared(..shared, approvals:)
}

/// Replaces `Shared.goal_refresh`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.goal_refresh(model.shared, value)
/// ```
@internal
pub fn goal_refresh(
  shared: Shared(a, b, c, d),
  goal_refresh,
) -> Shared(a, b, c, d) {
  Shared(..shared, goal_refresh:)
}

/// Replaces `Shared.usage`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.usage(model.shared, value)
/// ```
@internal
pub fn usage(shared: Shared(a, b, c, d), usage) -> Shared(a, b, c, d) {
  Shared(..shared, usage:)
}

/// Replaces `Shared.todo_seed`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.todo_seed(model.shared, value)
/// ```
@internal
pub fn todo_seed(shared: Shared(a, b, c, d), todo_seed) -> Shared(a, b, c, d) {
  Shared(..shared, todo_seed:)
}

/// Replaces `Shared.generation_started_ms`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.generation_started_ms(model.shared, value)
/// ```
@internal
pub fn generation_started_ms(
  shared: Shared(a, b, c, d),
  generation_started_ms,
) -> Shared(a, b, c, d) {
  Shared(..shared, generation_started_ms:)
}

/// Replaces `Shared.jobs_awaiting`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.jobs_awaiting(model.shared, value)
/// ```
@internal
pub fn jobs_awaiting(
  shared: Shared(a, b, c, d),
  jobs_awaiting,
) -> Shared(a, b, c, d) {
  Shared(..shared, jobs_awaiting:)
}

/// Replaces `Shared.models`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.models(model.shared, value)
/// ```
@internal
pub fn models(shared: Shared(a, b, c, d), models) -> Shared(a, b, c, d) {
  Shared(..shared, models:)
}

/// Replaces `Shared.session_label`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.session_label(model.shared, value)
/// ```
@internal
pub fn session_label(
  shared: Shared(a, b, c, d),
  session_label,
) -> Shared(a, b, c, d) {
  Shared(..shared, session_label:)
}

/// Replaces `Shared.surface_facts`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.surface_facts(model.shared, value)
/// ```
@internal
pub fn surface_facts(
  shared: Shared(a, b, c, d),
  surface_facts,
) -> Shared(a, b, c, d) {
  Shared(..shared, surface_facts:)
}

/// Replaces `Shared.pending_records`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.pending_records(model.shared, value)
/// ```
@internal
pub fn pending_records(
  shared: Shared(a, b, c, d),
  pending_records,
) -> Shared(a, b, c, d) {
  Shared(..shared, pending_records:)
}

/// Replaces `Shared.outbox`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.outbox(model.shared, value)
/// ```
@internal
pub fn outbox(shared: Shared(a, b, c, d), outbox) -> Shared(a, b, c, d) {
  Shared(..shared, outbox:)
}

/// Replaces `Shared.goal_observations`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.goal_observations(model.shared, value)
/// ```
@internal
pub fn goal_observations(
  shared: Shared(a, b, c, d),
  goal_observations,
) -> Shared(a, b, c, d) {
  Shared(..shared, goal_observations:)
}

/// Replaces `Shared.render_revision`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.render_revision(model.shared, value)
/// ```
@internal
pub fn render_revision(
  shared: Shared(a, b, c, d),
  render_revision,
) -> Shared(a, b, c, d) {
  Shared(..shared, render_revision:)
}

/// Replaces `Shared.connection_backlog`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.connection_backlog(model.shared, value)
/// ```
@internal
pub fn connection_backlog(
  shared: Shared(a, b, c, d),
  connection_backlog,
) -> Shared(a, b, c, d) {
  Shared(..shared, connection_backlog:)
}

/// Replaces `Shared.compact_call_cache`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.compact_call_cache(model.shared, value)
/// ```
@internal
pub fn compact_call_cache(
  shared: Shared(a, b, c, d),
  compact_call_cache,
) -> Shared(a, b, c, d) {
  Shared(..shared, compact_call_cache:)
}

/// Replaces `Shared.compact_entry_cache`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.compact_entry_cache(model.shared, value)
/// ```
@internal
pub fn compact_entry_cache(
  shared: Shared(a, b, c, d),
  compact_entry_cache,
) -> Shared(a, b, c, d) {
  Shared(..shared, compact_entry_cache:)
}

/// Replaces `Shared.quit`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.quit(model.shared, value)
/// ```
@internal
pub fn quit(shared: Shared(a, b, c, d), quit) -> Shared(a, b, c, d) {
  Shared(..shared, quit:)
}

/// Replaces `Shared.jobs`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.jobs(model.shared, value)
/// ```
@internal
pub fn jobs(shared: Shared(a, b, c, d), jobs) -> Shared(a, b, c, d) {
  Shared(..shared, jobs:)
}

/// Replaces `Shared.todo_boards`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.todo_boards(model.shared, value)
/// ```
@internal
pub fn todo_boards(
  shared: Shared(a, b, c, d),
  todo_boards,
) -> Shared(a, b, c, d) {
  Shared(..shared, todo_boards:)
}

/// Replaces `Shared.clock_offset`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.clock_offset(model.shared, value)
/// ```
@internal
pub fn clock_offset(
  shared: Shared(a, b, c, d),
  clock_offset,
) -> Shared(a, b, c, d) {
  Shared(..shared, clock_offset:)
}

/// Replaces `Shared.recorder`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.recorder(model.shared, value)
/// ```
@internal
pub fn recorder(shared: Shared(a, b, c, d), recorder) -> Shared(a, b, c, d) {
  Shared(..shared, recorder:)
}

/// Replaces `Shared.next_id`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.next_id(model.shared, value)
/// ```
@internal
pub fn next_id(shared: Shared(a, b, c, d), next_id) -> Shared(a, b, c, d) {
  Shared(..shared, next_id:)
}

/// Replaces `Shared.output_rate_tps`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.output_rate_tps(model.shared, value)
/// ```
@internal
pub fn output_rate_tps(
  shared: Shared(a, b, c, d),
  output_rate_tps,
) -> Shared(a, b, c, d) {
  Shared(..shared, output_rate_tps:)
}

/// Replaces `Shared.replay_inbox`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.replay_inbox(model.shared, value)
/// ```
@internal
pub fn replay_inbox(
  shared: Shared(a, b, c, d),
  replay_inbox,
) -> Shared(a, b, c, d) {
  Shared(..shared, replay_inbox:)
}

/// Replaces `Shared.activity_started_ms`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.activity_started_ms(model.shared, value)
/// ```
@internal
pub fn activity_started_ms(
  shared: Shared(a, b, c, d),
  activity_started_ms,
) -> Shared(a, b, c, d) {
  Shared(..shared, activity_started_ms:)
}

/// Replaces `Shared.activity_elapsed_s`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.activity_elapsed_s(model.shared, value)
/// ```
@internal
pub fn activity_elapsed_s(
  shared: Shared(a, b, c, d),
  activity_elapsed_s,
) -> Shared(a, b, c, d) {
  Shared(..shared, activity_elapsed_s:)
}

/// Replaces `Shared.jobs_request`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.jobs_request(model.shared, value)
/// ```
@internal
pub fn jobs_request(
  shared: Shared(a, b, c, d),
  jobs_request,
) -> Shared(a, b, c, d) {
  Shared(..shared, jobs_request:)
}

/// Replaces `Shared.answer`; the record documents the field.
///
/// ## Examples
///
/// ```gleam
/// shared_set.answer(model.shared, value)
/// ```
@internal
pub fn answer(shared: Shared(a, b, c, d), answer) -> Shared(a, b, c, d) {
  Shared(..shared, answer:)
}
