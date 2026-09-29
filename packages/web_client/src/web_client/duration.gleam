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
