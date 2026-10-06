//// The words `transcript_lines` shares between the terminal's footer and the
//// web page's bar and Session tab.

import core/message
import gleam/option.{None, Some}
import session_view/transcript_line
import session_view/transcript_lines

fn usage(total_tokens: Int, total: Float) -> message.Usage {
  message.Usage(
    input: 12_345,
    output: 678,
    cache_read: 90_000,
    cache_write: 123,
    cache_write_1h: None,
    reasoning: Some(40),
    total_tokens:,
    cost: message.UsageCost(0.0, 0.0, 0.0, 0.0, total),
  )
}

// A figure is shown only when something was priced. A zero total is
// unpriced whether or not tokens were spent: a session that has spent nothing
// has priced nothing, and `$0.00` would claim a known figure.
pub fn a_zero_total_is_unpriced_whatever_the_token_count_test() {
  assert transcript_lines.cost_words(usage(103_146, 0.037)) == "est $0.04"
  assert transcript_lines.cost_words(usage(103_146, 0.0)) == "est —"
  assert transcript_lines.cost_words(usage(0, 0.0)) == "est —"
}

// A Stop or a steer ends a response that is being written, and the records do
// not say which. The provider's confirmed cancellation is the one word
// `Stopped` and nothing beneath it, whatever part of the harness the diagnostic
// names, so a reader is not shown `runtime: explicit stop`.
pub fn a_confirmed_stop_says_stopped_and_nothing_more_test() {
  let stopped = [transcript_line.Line(transcript_line.System, "Stopped")]
  assert transcript_lines.assistant_terminal_lines(
      message.Aborted,
      Some("provider request was cancelled (runtime: explicit stop)"),
    )
    == stopped
  assert transcript_lines.assistant_terminal_lines(
      message.Aborted,
      Some("provider request was cancelled"),
    )
    == stopped
  assert transcript_lines.assistant_terminal_lines(message.Aborted, None)
    == stopped
}

// A stop the harness could not establish keeps its words, and a failed turn is
// still a failure.
pub fn an_unconfirmed_stop_keeps_its_diagnostic_test() {
  let unconfirmed =
    "provider cancellation could not be confirmed (runtime: explicit stop)"
  assert transcript_lines.assistant_terminal_lines(
      message.Aborted,
      Some(unconfirmed),
    )
    == [
      transcript_line.Line(transcript_line.System, "Stopped"),
      transcript_line.Line(transcript_line.ToolDetail, unconfirmed),
    ]
  assert transcript_lines.assistant_terminal_lines(
      message.Errored,
      Some("provider request was cancelled (runtime: explicit stop)"),
    )
    == [
      transcript_line.Line(
        transcript_line.Failure,
        "provider request was cancelled (runtime: explicit stop)",
      ),
    ]
}
