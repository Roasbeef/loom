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
import tui
import tui/composer
import tui/connection
import tui/frame
import tui/live_jobs
import tui/protocol
import tui/queue_editor
import tui/workspace

fn model() {
  tui.Model(
    ..tui.new_model(connection.new_inbox(), workspace.Context("/work", None)),
    input: textarea.state_from_string("continue my unfinished draft"),
    attachments: [composer.Attachment("retained context", 4)],
  )
}

fn painted(model) {
  let model = tui.update(backend.Resize(120, 30), model)
  let #(buffer, _) = tui.view(model, geometry.rect_new(0, 0, 120, 30))
  frame.buffer_to_text(buffer)
}

pub fn summary_without_captured_evidence_keeps_composer_and_reports_absence_test() {
  let initial = model()
  let opened = tui.open_summary(initial)
  assert opened.summary_surface == queue_editor.Inspector
  assert opened.input == initial.input
  assert opened.attachments == initial.attachments
  let text = painted(opened)
  assert string.contains(
    text,
    "No completed operation captured for this strand",
  )
  assert string.contains(text, "Queued input count unavailable")
  assert string.contains(text, "Live jobs unavailable")
  assert !string.contains(text, "Live jobs: 0")
  let closed = tui.update(backend.KeyPress("esc"), opened)
  assert closed.summary_surface == queue_editor.Closed
  assert closed.input == initial.input
  assert closed.attachments == initial.attachments
  assert closed.interrupt == initial.interrupt
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
  let initial = tui.Model(..model(), jobs: Some(board))
  let opened = tui.open_summary(initial)
  let text = painted(opened)
  assert string.contains(
    text,
    "No completed operation captured for this strand",
  )
  assert string.contains(text, "Live jobs: 1 · at last refresh")
  assert string.contains(text, "job-7 · running · started by earlier-operation")
  assert string.contains(text, "sleep 30")
  assert string.contains(text, "age 2s · deadline in 28s")
  assert !string.contains(text, "Completed by assistant")
  assert opened.jobs == Some(board)
  assert opened.input == initial.input
  assert opened.attachments == initial.attachments

  // A strand switch cannot present the last strand's job roster as current
  // work for the newly selected strand.
  let other = tui.Model(..opened, active_strand: "other")
  assert !string.contains(painted(other), "job-7")
  assert string.contains(painted(other), "Live jobs unavailable")
}

// Current request input includes cached input once. Reasoning is already a
// subset of output, and cumulative usage can be much larger than the request.
pub fn summary_separates_current_context_from_cumulative_usage_test() {
  let initial = model()
  let last_usage =
    message.Usage(110, 70, 400, 100, None, Some(20), 680, initial.usage.cost)
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
    tui.Model(
      ..initial,
      records: [protocol.EntryRecord("main", measured)],
      usage: cumulative,
    )
  let text = painted(tui.open_summary(updated))
  assert string.contains(text, "uncached input 9k")
  assert string.contains(text, "cache read 20k")
  assert string.contains(text, "610 input tokens (including cache)")
  assert string.contains(text, "output 70 (includes 20 reasoning)")
  assert !string.contains(text, "output 90")
}
