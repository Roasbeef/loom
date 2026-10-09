//// The words `transcript_lines` shares between the terminal's footer and the
//// web page's bar and Session tab.

import core/message
import core/usage_evidence
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
    evidence: case total >. 0.0 {
      True -> usage_evidence.priced_api()
      False -> usage_evidence.reported(usage_evidence.Other)
    },
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

// A stop the harness could not establish says so in plain words, with no part
// of the harness named, and any other diagnostic keeps its own words. A failed
// turn is still a failure.
pub fn an_unconfirmed_stop_says_so_in_plain_words_test() {
  let stopped = transcript_line.Line(transcript_line.System, "Stopped")
  let detail = fn(words) {
    transcript_line.Line(transcript_line.ToolDetail, words)
  }
  assert transcript_lines.assistant_terminal_lines(
      message.Aborted,
      Some(
        "provider cancellation could not be confirmed (runtime: explicit stop)",
      ),
    )
    == [stopped, detail("The provider may not have confirmed the stop.")]
  assert transcript_lines.assistant_terminal_lines(
      message.Aborted,
      Some("provider cancellation could not be confirmed"),
    )
    == [stopped, detail("The provider may not have confirmed the stop.")]
  assert transcript_lines.assistant_terminal_lines(
      message.Aborted,
      Some(
        "provider ownership ended without proof of drain (gateway: transport exit)",
      ),
    )
    == [stopped, detail("The provider may still be working on the request.")]
  assert transcript_lines.assistant_terminal_lines(
      message.Aborted,
      Some("the response was settled after a restart"),
    )
    == [stopped, detail("the response was settled after a restart")]
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

pub fn compact_cost_keeps_subscription_basis_and_coverage_test() {
  let measured =
    usage_evidence.with_price(
      usage_evidence.reported(usage_evidence.ChatGptPlan),
      usage_evidence.ChatGptReferenceRates,
    )
  let partial =
    usage_evidence.add(
      measured,
      usage_evidence.unknown(usage_evidence.ChatGptPlan),
    )
  let subscription = message.Usage(..usage(1000, 0.42), evidence: partial)
  assert transcript_lines.cost_words(subscription)
    == "API ref partial est $0.42"
  assert transcript_lines.cost_figure(subscription) == "API ref partial $0.42"

  let complete = message.Usage(..usage(1000, 0.42), evidence: measured)
  assert transcript_lines.cost_words(complete) == "API ref est $0.42"
  assert transcript_lines.cost_figure(complete) == "API ref $0.42"
}
