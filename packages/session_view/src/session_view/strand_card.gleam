//// The words on a strand's card in a host's strand panel, and the count of
//// strands that are waiting for a person.
////
//// A card answers "what is this strand doing" in words a host draws beside
//// the strand's name, so a host that draws cards (the web view's Strands tab,
//// and the terminal when its strip is revised) says the same words. They are
//// derived from `agent_view.Status`, which the roster already joins with the
//// operation's activity, so nothing here reads the session again. A strand
//// that needs a decision says only so, in the same fixed words whatever the
//// request was: the request is the approval card's to show, in the place the
//// person can answer it.
////
//// The module is portable: it holds no `@external`, performs no I/O and
//// reads no clock.

import gleam/list
import session_view/agent_roster
import session_view/agent_view

/// The word for a strand's state on its card.
///
/// It is `agent_view.label`'s, except for a strand that needs a decision: that
/// is the pending approval, so the card says `Needs approval`, which is what
/// the person should do, where the label `Needs input` names only the state.
///
/// ## Examples
///
/// ```gleam
/// assert strand_card.word(agent_view.NeedsInput) == "Needs approval"
/// assert strand_card.word(agent_view.Working) == "Working"
/// ```
pub fn word(status: agent_view.Status) -> String {
  case status {
    agent_view.NeedsInput -> "Needs approval"
    agent_view.Working
    | agent_view.Waiting
    | agent_view.Finished
    | agent_view.Failed
    | agent_view.Halted
    | agent_view.Idle
    | agent_view.Unavailable -> agent_view.label(status)
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
