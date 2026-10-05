//// What `<loom-time>` decides (`web_client/time`): the clock time of an instant
//// in the viewer's zone, as `HH:MM`.
////
//// The daemon states an instant, such as when the next grant is free, as Unix
//// milliseconds, and the server cannot know the person's zone: the page is
//// served from the daemon's host and the browser may be anywhere. So the server
//// writes the instant and the browser says what time it is there. The browser
//// supplies one fact about its zone, the offset from UTC at that instant
//// (`ffi_dom.timezone_offset_minutes`, which is where daylight saving lives),
//// and everything else is integer arithmetic, here, so a test can run it under
//// Node with any offset.
////
//// A time is rounded up to the minute, so the page never shows a time before it
//// comes: an instant a millisecond after 13:02 is shown as 13:03. The module
//// imports neither Lustre nor the DOM binding.

import gleam/int
import gleam/string

/// Milliseconds in a minute.
const minute_ms = 60_000

/// The attribute's value as an instant: whole milliseconds, and nothing else. A
/// value that is not a whole number is no instant, so the element keeps what it
/// drew.
///
/// ## Examples
///
/// ```gleam
/// assert time_rule.instant(" 1790030460000 ") == Ok(1_790_030_460_000)
/// assert time_rule.instant("soon") == Error(Nil)
/// ```
pub fn instant(value: String) -> Result(Int, Nil) {
  int.parse(string.trim(value))
}

/// The time of day of an instant in a zone, as `HH:MM`, rounded up to the
/// minute. `offset_minutes` is the zone's offset as the browser reports it:
/// minutes to add to local time to reach UTC, so a zone east of Greenwich is
/// negative.
///
/// ## Examples
///
/// ```gleam
/// // 22:41 UTC, drawn in a zone two hours east of UTC (offset -120).
/// assert time_rule.clock(1_790_030_460_000, -120) == "00:41"
/// assert time_rule.clock(1_790_030_460_000, 0) == "22:41"
/// ```
pub fn clock(milliseconds: Int, offset_minutes: Int) -> String {
  let utc_minutes = { int.max(milliseconds, 0) + minute_ms - 1 } / minute_ms
  let local = { utc_minutes - offset_minutes } % 1440
  let local = case local < 0 {
    True -> local + 1440
    False -> local
  }
  pad(local / 60) <> ":" <> pad(local % 60)
}

fn pad(number: Int) -> String {
  string.pad_start(int.to_string(number), to: 2, with: "0")
}
