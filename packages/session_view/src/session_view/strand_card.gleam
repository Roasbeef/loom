//// The words on a strand's card in a host's strand panel: one status line
//// under the name, and the count of strands that are waiting for a person.
////
//// A card answers "what is this strand doing" in one line, so a host that
//// draws cards (the web view's Strands tab, and the terminal when its strip
//// is revised) says the same words. The line is derived from the roster's
//// `Line`, which already joins the captured status with the operation's
//// activity or the strand's own summary, so nothing here reads the session
//// again. A strand that needs a decision says only so: its line is the same
//// fixed words whatever the request was, because the request is the approval
//// card's to show, in the place the person can answer it.
////
//// The activity text of a working strand is session text (a model wrote the
//// summary, or the captured tool name is shown), and hosts draw it as text.
//// The fixed words carry the state; the text after the separator only adds
//// to it.
////
//// The module is portable: it holds no `@external`, performs no I/O and
//// reads no clock.

import gleam/list
import gleam/option.{type Option, None, Some}
import session_view/agent_roster
import session_view/agent_view

/// The card's one status line for `line`.
///
/// A strand that needs a decision reads `Needs approval`. A working or
/// waiting strand reads its state word, and its activity after ` · ` when it
/// has one. A finished strand adds how long its last operation ran, when the
/// roster knows. The other states are their state words.
///
/// ## Examples
///
/// ```gleam
/// // strand_card.status_line(line) == "Working · code_mode"
/// ```
pub fn status_line(line: agent_roster.Line) -> String {
  case line.status {
    agent_view.NeedsInput -> "Needs approval"
    agent_view.Working | agent_view.Waiting ->
      case line.text {
        "" -> agent_view.label(line.status)
        text -> agent_view.label(line.status) <> " · " <> text
      }
    agent_view.Finished ->
      case line.elapsed_s {
        Some(seconds) ->
          agent_view.label(line.status) <> " " <> agent_roster.duration(seconds)
        None -> agent_view.label(line.status)
      }
    agent_view.Failed
    | agent_view.Halted
    | agent_view.Idle
    | agent_view.Unavailable -> agent_view.label(line.status)
  }
}

/// How many of `lines` are waiting for a decision: the number the Strands
/// tab's badge shows. A strand with a pending approval is exactly one whose
/// status is `NeedsInput`, which `agent_view` derives from the record of the
/// escalation and no other evidence.
///
/// ## Examples
///
/// ```gleam
/// assert strand_card.needing([]) == 0
/// ```
pub fn needing(lines: List(agent_roster.Line)) -> Int {
  list.count(lines, fn(line) { line.status == agent_view.NeedsInput })
}

/// The words for a strand's context size on its own view, or `None` when the
/// roster knows no size: the count in the strip's own short form followed by
/// `tokens`.
///
/// ## Examples
///
/// ```gleam
/// assert strand_card.context_words(Some(1500)) == Some("1.5k tokens")
/// assert strand_card.context_words(None) == None
/// ```
pub fn context_words(tokens: Option(Int)) -> Option(String) {
  case tokens {
    Some(count) -> Some(agent_roster.count_label(count) <> " tokens")
    None -> None
  }
}
