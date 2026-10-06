//// The completion panel separates captured run evidence from current work.
//// Opening or closing it cannot consume the ordinary composer's draft.

import core/clock
import core/entry
import core/ids
import core/message
import etui/backend
import etui/geometry
import etui/widgets/textarea
import gleam/option.{None, Some}
import gleam/string
import session_view/composer
import session_view/live_jobs
import session_view/protocol
import session_view/session_channel
import session_view/shared_set
import tui
import tui/connection
import tui/frame
import tui/inbound
import tui/model as tui_model
import tui/queue_editor
import tui/render
import tui/side_surfaces
import tui/summary_panel
import tui/view_set
import tui/workspace

fn model() {
  {
    let base =
      tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
    tui_model.Model(
      shared: shared_set.attachments(base.shared, [
        composer.Attachment("retained context", 4),
      ]),
      view: view_set.input(
        base.view,
        textarea.state_from_string("continue my unfinished draft"),
      ),
    )
  }
}

fn painted(model) {
  let model = tui.update(backend.Resize(120, 30), model)
  let #(buffer, _) = render.view(model, geometry.rect_new(0, 0, 120, 30))
  frame.buffer_to_text(buffer)
}

fn key(model, value) {
  tui.update(backend.KeyPress(value), model)
}

pub fn summary_without_captured_evidence_keeps_composer_and_reports_absence_test() {
  let initial = model()
  let opened = side_surfaces.open_summary(initial)
  assert opened.view.summary_surface == queue_editor.Inspector
  assert opened.view.input == initial.view.input
  assert opened.shared.attachments == initial.shared.attachments
  let text = painted(opened)
  assert string.contains(
    text,
    "No completed operation captured for this strand",
  )
  assert string.contains(text, "1 Completion")
  let usage = opened |> key("2") |> painted
  assert string.contains(usage, "Queued input count unavailable")
  let jobs = opened |> key("3") |> painted
  assert string.contains(jobs, "Live jobs unavailable")
  assert !string.contains(jobs, "Observed roster: 0")
  let closed = tui.update(backend.KeyPress("esc"), opened)
  assert closed.view.summary_surface == queue_editor.Closed
  assert closed.view.input == initial.view.input
  assert closed.shared.attachments == initial.shared.attachments
  assert closed.shared.interrupt == initial.shared.interrupt
}

pub fn live_jobs_remain_a_separately_timestamped_observation_test() {
  let board =
    live_jobs.Board(
      "main",
      42_000,
      [
        live_jobs.Job(
          "job-7",
          "running",
          "earlier-operation",
          "sleep 30",
          2000,
          70_000,
        ),
      ],
      1,
      0,
    )
  let initial = {
    let base = model()
    tui_model.Model(..base, shared: shared_set.jobs(base.shared, Some(board)))
  }
  let opened = side_surfaces.open_summary(initial) |> key("3")
  let text = painted(opened)
  assert string.contains(text, "3 Jobs")
  assert string.contains(text, "Observed roster: 1 total · 0 omitted")
  assert string.contains(text, "▸ [RUNNING] job-7")
  assert string.contains(text, "Started by earlier-operation")
  assert string.contains(text, "Command excerpt: sleep 30")
  assert string.contains(text, "Age 2s · deadline in 28s")
  assert !string.contains(text, "Completed by assistant")
  assert opened.shared.jobs == Some(board)
  assert opened.view.input == initial.view.input
  assert opened.shared.attachments == initial.shared.attachments

  // A strand switch cannot present the last strand's job roster as current
  // work for the newly selected strand.
  let other =
    tui_model.Model(
      ..opened,
      shared: shared_set.active_strand(opened.shared, "other"),
    )
  assert !string.contains(painted(other), "job-7")
  assert string.contains(
    painted(
      tui_model.Model(
        ..other,
        shared: shared_set.jobs_notice(
          other.shared,
          "Live jobs observed separately from completion",
        ),
      ),
    ),
    "Live jobs unavailable for the current strand",
  )
}

// Current request input includes cached input once. Reasoning is already a
// subset of output, and cumulative usage can be much larger than the request.
pub fn summary_separates_current_context_from_cumulative_usage_test() {
  let initial = model()
  let last_usage =
    message.Usage(
      110,
      70,
      400,
      100,
      None,
      Some(20),
      680,
      initial.shared.usage.cost,
    )
  let cumulative =
    message.Usage(
      ..last_usage,
      input: 9000,
      cache_read: 20_000,
      cache_write: 3000,
      output: 1000,
      total_tokens: 33_000,
    )
  let measured =
    entry.MessageEntry(
      ids.mint_entry(ids.generator(clock.fixed(1), 1)).0,
      None,
      1,
      1,
      message.AssistantMessage(
        content: [message.AssistantText("Measured answer", None)],
        api: "test",
        provider: "test",
        model: "test",
        response_model: None,
        response_id: None,
        diagnostics: None,
        usage: last_usage,
        stop_reason: message.Stop,
        deferred: None,
        error_message: None,
        raw_stop_reason: None,
        end_turn: None,
        timestamp: 1,
      ),
      False,
    )
  let updated =
    tui_model.Model(
      ..initial,
      shared: initial.shared
        |> shared_set.records([protocol.EntryRecord("main", measured)])
        |> shared_set.usage(cumulative),
    )
  let text = painted(side_surfaces.open_summary(updated) |> key("2"))
  assert string.contains(text, "Input 9000")
  assert string.contains(text, "cache read 20000")
  assert string.contains(text, "610 input tokens (including cache)")
  assert string.contains(text, "output 70 (includes 20 reasoning)")
  assert !string.contains(text, "output 90")
}

pub fn jobs_tab_retains_selected_identity_and_keeps_refresh_notice_test() {
  let first = live_jobs.Job("a", "running", "op-a", "first", 1, 100)
  let second = live_jobs.Job("b", "draining", "op-b", "second", 2, 90)
  let board = live_jobs.Board("main", 50, [first, second], 3, 1)
  let opened =
    {
      let base = model()
      tui_model.Model(..base, shared: shared_set.jobs(base.shared, Some(board)))
    }
    |> side_surfaces.open_summary
    |> fn(model) {
      tui_model.Model(
        ..model,
        shared: shared_set.jobs_notice(
          model.shared,
          "Refreshing live jobs; previous observation may be stale",
        ),
      )
    }
    |> key("3")
    |> key("]")
  assert opened.view.summary_tab == summary_panel.Jobs
  assert opened.view.summary_job_selected == 1
  let stale = painted(opened)
  assert string.contains(stale, "previous observation may be stale")
  assert string.contains(stale, "1 omitted")

  let reordered = live_jobs.Board("main", 60, [second, first], 2, 0)
  let refreshed =
    inbound.apply_channel_update(
      tui_model.Model(
        ..opened,
        shared: shared_set.jobs_awaiting(opened.shared, Some(#("", "main"))),
      ),
      session_channel.Auxiliary(protocol.LiveJobsSnapshot(reordered)),
    )
  assert refreshed.view.summary_job_selected == 0
  assert string.contains(painted(refreshed), "▸ [DRAINING] b")
}
