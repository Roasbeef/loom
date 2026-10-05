//// The words `transcript_lines` shares between the terminal's footer and the
//// web page's bar and Session tab.

import core/message
import gleam/option.{None, Some}
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
