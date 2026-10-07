//// An elapsed duration the way the terminal's strip shows one. It is here,
//// away from `web_client/elapsed`, so its tests run without Lustre or a page.

import gleam/int
import gleam/string

/// An elapsed duration the way the terminal's strip shows one
/// (`session_view/agent_roster.duration`): seconds under a minute, minutes
/// and padded seconds under an hour, then hours and padded minutes.
///
/// ## Examples
///
/// ```gleam
/// assert duration.format(475) == "7m 55s"
/// ```
pub fn format(seconds: Int) -> String {
  case seconds >= 3600, seconds >= 60 {
    True, _ ->
      int.to_string(seconds / 3600)
      <> "h "
      <> pad2({ seconds % 3600 } / 60)
      <> "m"
    False, True ->
      int.to_string(seconds / 60) <> "m " <> pad2(seconds % 60) <> "s"
    False, False -> int.to_string(int.max(0, seconds)) <> "s"
  }
}

fn pad2(value: Int) -> String {
  string.pad_start(int.to_string(value), to: 2, with: "0")
}

/// The time left before something ends, the way the admin page's pill says it:
/// whole minutes, rounded up, from a minute on, and seconds under a minute. A
/// page that has run out says `0s`.
///
/// ## Examples
///
/// ```gleam
/// assert duration.remaining(14 * 60 + 10) == "15m"
/// assert duration.remaining(45) == "45s"
/// ```
pub fn remaining(seconds: Int) -> String {
  case seconds >= 60 {
    True -> int.to_string({ seconds + 59 } / 60) <> "m"
    False -> int.to_string(int.max(0, seconds)) <> "s"
  }
}

/// How long ago, in milliseconds, something that started at `since` began, by
/// a clock that reads `now`. A start after `now`, which a browser clock set
/// behind the daemon's produces, is no time at all.
///
/// ## Examples
///
/// ```gleam
/// assert duration.since_offset(now: 72_500, since: 500) == 72_000
/// assert duration.since_offset(now: 100, since: 900) == 0
/// ```
pub fn since_offset(now now: Int, since since: Int) -> Int {
  int.max(0, now - since)
}
