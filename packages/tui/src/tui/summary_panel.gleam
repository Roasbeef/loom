//// Completion, cumulative usage, and current jobs are three different kinds
//// of evidence. Tabs keep them adjacent without implying that one proves the
//// other, and job selection remains keyed by the observed stable identity.

import core/message
import etui/span
import etui/style
import etui/text
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import machine/operation
import tui/completion_summary
import tui/live_jobs
import tui/text_hygiene
import tui/theme

/// The independently scrollable summary section.
pub type Tab {
  /// Captured terminal outcome and attributable operation evidence.
  Completion

  /// Cumulative session accounting and latest active-request measurement.
  Usage

  /// Separately refreshed current-job observation.
  Jobs
}

/// Renders the selected section and its visible tab focus.
///
/// ## Examples
///
/// ```gleam
/// // summary_panel.lines(Completion, completion, usage, context, queue, jobs, notice, age, 0, 80)
/// ```
@internal
pub fn lines(
  tab: Tab,
  completion: Option(completion_summary.Summary),
  usage: message.Usage,
  latest_context: String,
  queue: String,
  jobs: Option(live_jobs.Board),
  jobs_notice: String,
  jobs_observation: String,
  selected_job: Int,
  width: Int,
) -> List(span.Line) {
  case tab {
    Completion -> completion_lines(completion, width)
    Usage -> usage_lines(usage, latest_context, queue, width)
    Jobs -> jobs_lines(jobs, jobs_notice, jobs_observation, selected_job, width)
  }
}

/// Renders the pinned tab selector outside the section viewport.
///
/// ## Examples
///
/// ```gleam
/// summary_panel.tab_line(Completion, 40)
/// ```
@internal
pub fn tab_line(tab: Tab, width: Int) -> span.Line {
  let labels = [
    #(Completion, "1 Completion"),
    #(Usage, "2 Usage"),
    #(Jobs, "3 Jobs"),
  ]
  let parts =
    list.flat_map(labels, fn(pair) {
      let appearance = case pair.0 == tab {
        True -> style.new(theme.paper, theme.raised, style.bold())
        False -> theme.overlay_quiet()
      }
      [span.span_styled(" " <> pair.1 <> " ", appearance)]
    })
  let line = span.line_new(parts)
  let padding = int.max(0, width - span.line_width(line))
  span.Line(
    ..line,
    spans: list.append(line.spans, [
      span.span_styled(string.repeat(" ", padding), theme.overlay_plain()),
    ]),
  )
}

fn completion_lines(
  summary: Option(completion_summary.Summary),
  width: Int,
) -> List(span.Line) {
  case summary {
    None ->
      styled(
        "No completed operation captured for this strand",
        theme.overlay_signal(),
        width,
      )
    Some(summary) -> {
      let coverage = case summary.coverage {
        completion_summary.Complete -> "complete captured ancestry"
        completion_summary.Partial -> "partial captured ancestry"
        completion_summary.Unavailable -> "ancestry unavailable"
      }
      let final = case summary.final_assistant {
        None ->
          styled(
            "Final assistant entry unavailable in captured evidence",
            theme.overlay_quiet(),
            width,
          )
        Some(value) -> [
          heading("FINAL ASSISTANT", width),
          ..styled(value, theme.overlay_plain(), width)
        ]
      }
      let edits =
        list.flatten([
          [heading("FILE-TOOL EVIDENCE", width)],
          styled(
            completion_summary.edit_totals(summary),
            theme.overlay_plain(),
            width,
          ),
          list.flat_map(summary.edits, fn(path) {
            styled(text_hygiene.single_line(path), theme.overlay_plain(), width)
          }),
        ])
      let tools = [
        heading("TOOL RESULTS", width),
        ..list.flat_map(summary.tools, fn(tool) {
          let status = case tool.status {
            completion_summary.Succeeded -> "succeeded"
            completion_summary.Failed -> "failed"
          }
          let evidence = case tool.command, tool.exit_code {
            Some(command), Some(code) ->
              " · exit "
              <> int.to_string(code)
              <> " · "
              <> text_hygiene.single_line(command)
            Some(command), None -> " · " <> text_hygiene.single_line(command)
            None, Some(code) -> " · exit " <> int.to_string(code)
            None, None -> ""
          }
          styled(
            tool.name <> " · " <> status <> evidence,
            theme.overlay_plain(),
            width,
          )
        })
      ]
      list.flatten([
        [heading("CAPTURED TERMINAL RESULT", width)],
        styled(
          completion_summary.brief(summary),
          outcome_style(summary.outcome),
          width,
        ),
        styled(
          "Operation " <> summary.operation <> " · " <> coverage,
          theme.overlay_quiet(),
          width,
        ),
        styled(
          "A command exit status is tool evidence; it does not establish test coverage.",
          theme.overlay_signal(),
          width,
        ),
        styled(
          "Captured history lists up to 32 file edits and tool outcomes.",
          theme.overlay_quiet(),
          width,
        ),
        final,
        edits,
        tools,
      ])
    }
  }
}

fn usage_lines(
  usage: message.Usage,
  latest: String,
  queue: String,
  width: Int,
) -> List(span.Line) {
  list.flatten([
    [heading("CUMULATIVE SESSION USAGE · ALL STRANDS", width)],
    styled(
      "Estimated cost $"
        <> float.to_string(usage.cost.total)
        <> " · total tokens "
        <> int.to_string(usage.total_tokens),
      theme.overlay_current(),
      width,
    ),
    styled(
      "Input "
        <> int.to_string(usage.input)
        <> " · cache read "
        <> int.to_string(usage.cache_read)
        <> " · cache write "
        <> int.to_string(usage.cache_write)
        <> " · output "
        <> int.to_string(usage.output),
      theme.overlay_plain(),
      width,
    ),
    styled(
      case usage.reasoning {
        Some(value) ->
          "Reasoning included in output accounting: " <> int.to_string(value)
        None -> "Reasoning token detail unavailable"
      },
      theme.overlay_quiet(),
      width,
    ),
    [heading("LATEST MEASURED ACTIVE REQUEST", width)],
    styled(latest, theme.overlay_plain(), width),
    styled(queue, theme.overlay_quiet(), width),
  ])
}

fn jobs_lines(
  board: Option(live_jobs.Board),
  notice: String,
  observation: String,
  selected: Int,
  width: Int,
) -> List(span.Line) {
  let notice = styled(notice, theme.overlay_signal(), width)
  case board {
    None -> notice
    Some(board) -> {
      let offset = int.max(0, selected - 1)
      let rows =
        list.index_map(
          board.jobs |> list.drop(offset) |> list.take(3),
          fn(job, index) {
            let index = offset + index
            let chosen = index == selected
            let marker = case chosen {
              True -> "▸ "
              False -> "  "
            }
            let background = case chosen {
              True -> theme.raised
              False -> theme.graphite
            }
            padded(
              marker
                <> "["
                <> string.uppercase(job.state)
                <> "] "
                <> text_hygiene.single_line(job.id),
              width,
              style.new(theme.current, background, style.none()),
            )
          },
        )
      let detail = case list.first(list.drop(board.jobs, selected)) {
        Error(Nil) -> []
        Ok(job) ->
          list.flatten([
            [
              heading(
                "SELECTED JOB · ["
                  <> string.uppercase(job.state)
                  <> "] "
                  <> text_hygiene.single_line(job.id),
                width,
              ),
            ],
            styled(
              "Started by " <> text_hygiene.single_line(job.started_by),
              theme.overlay_plain(),
              width,
            ),
            styled(
              "Command excerpt: " <> text_hygiene.multiline(job.command),
              theme.overlay_plain(),
              width,
            ),
            styled(
              "Age "
                <> live_jobs.duration(job.age_ms)
                <> case job.deadline_ms >= board.observed_at_ms {
                True ->
                  " · deadline in "
                  <> live_jobs.duration(job.deadline_ms - board.observed_at_ms)
                False ->
                  " · deadline passed "
                  <> live_jobs.duration(board.observed_at_ms - job.deadline_ms)
                  <> " ago"
              },
              theme.overlay_quiet(),
              width,
            ),
          ])
      }
      list.flatten([
        notice,
        styled(
          "Observed roster: "
            <> int.to_string(board.total)
            <> " total · "
            <> int.to_string(board.omitted)
            <> " omitted",
          theme.overlay_quiet(),
          width,
        ),
        detail,
        styled(observation, theme.overlay_quiet(), width),
        [heading("JOB ROSTER · selected with [ and ]", width)],
        rows,
      ])
    }
  }
}

fn outcome_style(outcome: operation.RunOutcome) -> style.Style {
  case outcome {
    operation.RunCompleted(_) ->
      style.new(theme.added, theme.graphite, style.bold())
    operation.RunFailed(_) | operation.RunAborted -> theme.overlay_signal()
  }
}

fn heading(value: String, width: Int) -> span.Line {
  span.line_new([
    span.span_styled(
      value |> text.truncate(width, "…") |> text.pad_right(width),
      style.new(theme.current, theme.raised, style.bold()),
    ),
  ])
}

fn styled(
  value: String,
  appearance: style.Style,
  width: Int,
) -> List(span.Line) {
  value
  |> text_hygiene.multiline
  |> string.split("\n")
  |> list.map(fn(line) { span.line_new([span.span_styled(line, appearance)]) })
  |> span.text_new
  |> span.wrap(int.max(1, width))
  |> fn(wrapped) { wrapped.lines }
}

fn padded(value: String, width: Int, appearance: style.Style) -> span.Line {
  span.line_new([
    span.span_styled(
      value |> text.truncate(width, "…") |> text.pad_right(width),
      appearance,
    ),
  ])
}
