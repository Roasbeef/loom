//// Display words for usage estimates, independent of transcript projection.
////
//// Goal boards and conversation bars share one interpretation of evidence.
//// Keeping it below either projection avoids a dependency from protocol
//// decoding back into the transcript that consumes that protocol.
////
//// A cost reads in two forms that differ only in the `est` marker. `estimate`
//// carries the marker for a surface that stands alone; `figure` omits it for a
//// row whose label already says estimate. Both qualify the amount with its
//// rate basis and coverage, so neither can show a subscription reference or a
//// partial total as a billed price.

import core/usage_evidence
import gleam/float
import gleam/int
import gleam/string

/// Words one estimate using its coverage and its configured rate basis.
///
/// ## Examples
///
/// ```gleam
/// // usage_display.estimate(0.0, usage_evidence.none()) == "est $0.00"
/// // usage_display.estimate(1.0, chatgpt_partial) == "API ref partial est $1.00"
/// ```
pub fn estimate(amount: Float, evidence: usage_evidence.Evidence) -> String {
  words(amount, evidence, marker: "est ")
}

/// Words the same estimate without its `est` marker, for a row whose label
/// supplies it. An unavailable cost still reads as a dash, never as zero.
///
/// ## Examples
///
/// ```gleam
/// // usage_display.figure(0.0, usage_evidence.none()) == "$0.00"
/// // usage_display.figure(1.0, chatgpt_partial) == "API ref partial $1.00"
/// ```
pub fn figure(amount: Float, evidence: usage_evidence.Evidence) -> String {
  words(amount, evidence, marker: "")
}

// The marker sits directly before the amount, after the rate basis and
// coverage qualifiers, so the two public forms cannot drift apart.
fn words(
  amount: Float,
  evidence: usage_evidence.Evidence,
  marker marker: String,
) -> String {
  case evidence {
    usage_evidence.NoProvider -> marker <> "$0.00"
    usage_evidence.Remote(_, usage_evidence.Unreported)
    | usage_evidence.Remote(
        _,
        usage_evidence.Reported(_, usage_evidence.Unpriced),
      ) -> marker <> "—"
    usage_evidence.Remote(
      _,
      usage_evidence.Reported(_, usage_evidence.Priced(coverage, basis)),
    ) -> {
      let prefix = case basis {
        usage_evidence.ApiRates -> ""
        usage_evidence.ChatGptReferenceRates -> "API ref "
        usage_evidence.MixedRates -> "mixed rates "
      }
      let coverage = case coverage {
        usage_evidence.Complete -> ""
        usage_evidence.Partial -> "partial "
      }
      prefix <> coverage <> marker <> "$" <> money(amount)
    }
  }
}

/// Currency is display data. Round once to cents before splitting the whole
/// and fractional parts, so binary floating point tails never reach a panel.
/// A negative amount reads as zero.
///
/// ## Examples
///
/// ```gleam
/// assert usage_display.money(0.456) == "0.46"
/// assert usage_display.money(-1.0) == "0.00"
/// ```
pub fn money(value: Float) -> String {
  let cents = int.max(0, float.round(value *. 100.0))
  int.to_string(cents / 100)
  <> "."
  <> string.pad_start(int.to_string(cents % 100), 2, "0")
}
