//// The Session tab's words for the owner's pending proposals.
////
//// The Session tab holds the review of the standing rules a model has proposed
//// (protocol-change/086), and the server writes how many wait as the
//// `proposals` attribute of `<loom-shell>`, on the daemon owner's page alone.
//// The tab's badge is that number, drawn by `web_client/shell` through
//// `shell_rule.badge`, and the number alone says nothing to a screen reader, so
//// the tab's own label says it. Decoding the attribute is `shell_rule.needing`,
//// which is total: anything but a small plain number is none.

import gleam/int

/// The words a screen reader gets for the Session tab: the label alone, or
/// with how many proposed standing rules wait for the owner.
///
/// ## Examples
///
/// ```gleam
/// assert proposals_rule.session_words(0) == "Session"
/// assert proposals_rule.session_words(1) == "Session, 1 proposal to review"
/// assert proposals_rule.session_words(3) == "Session, 3 proposals to review"
/// ```
pub fn session_words(count: Int) -> String {
  case count {
    1 -> "Session, 1 proposal to review"
    count if count > 1 ->
      "Session, " <> int.to_string(count) <> " proposals to review"
    _ -> "Session"
  }
}
