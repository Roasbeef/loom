//// The page's proposals review: what the page holds between reads, and the
//// question an approval asks before it sends (protocol-change/086).
////
//// A model that notices a correction worth keeping queues a proposal for a
//// standing rule, and the daemon writes nothing until a person approves it.
//// The owner's page lists the proposals, shows each as the exact edit it would
//// make, and approves or rejects it. The list itself is
//// `session_view/proposals` (the daemon's board, decoded totally, and the
//// words both hosts share); this module is the page's own part.
////
//// Approving is two presses. The first arms a question for one proposal and
//// sends nothing. What it arms is the identity of the row as the page drew it,
//// and the second press sends exactly that, so a press can never decide a
//// proposal that was not on screen. The confirm also looks the row up in the
//// board it holds now, so a row that has since been decided, or has gone,
//// sends nothing. Rejecting writes nothing and is one press.
////
//// The board stays fresh by the daemon's `proposals_changed` push, which the
//// shared lane turns into a read. The page also wants the board when it opens
//// and, as a backstop for a push it never heard, no less often than
//// `refresh_ms`.

import gleam/option.{type Option, None, Some}

/// How long a board stands before the page reads it again, in milliseconds of
/// the transport's clock. The push is what keeps the list current; this is the
/// backstop for one the page missed, such as the lane reconnecting.
pub const refresh_ms = 60_000

/// What the page holds about the list besides the board, which is part of the
/// session's shared record.
pub type State {
  State(
    /// When the page last wanted the board, on the transport's clock.
    asked_at: Option(Int),
    /// The proposal whose approval is being asked about, by its identity.
    approving: Option(String),
  )
}

/// A page that has read nothing and asked nothing.
///
/// ## Examples
///
/// ```gleam
/// assert proposals.new().approving == None
/// ```
pub fn new() -> State {
  State(asked_at: None, approving: None)
}

/// Whether the page should want the board at `at`: when it never has, or last
/// did `refresh_ms` or more ago.
///
/// ## Examples
///
/// ```gleam
/// assert proposals.due(proposals.new(), 0)
/// ```
pub fn due(state: State, at: Int) -> Bool {
  case state.asked_at {
    Some(before) -> at - before >= refresh_ms
    None -> True
  }
}

/// Records that the page wanted the board at `at`.
///
/// ## Examples
///
/// ```gleam
/// assert proposals.wanted(proposals.new(), 5).asked_at == Some(5)
/// ```
pub fn wanted(state: State, at: Int) -> State {
  State(..state, asked_at: Some(at))
}

/// Opens the question for one proposal's approval, replacing any other: only
/// one row asks at a time.
///
/// ## Examples
///
/// ```gleam
/// assert proposals.arm(proposals.new(), "prop-0123456789").approving
///   == Some("prop-0123456789")
/// ```
pub fn arm(state: State, id: String) -> State {
  State(..state, approving: Some(id))
}

/// Closes the question without sending anything.
///
/// ## Examples
///
/// ```gleam
/// assert proposals.disarm(proposals.new()).approving == None
/// ```
pub fn disarm(state: State) -> State {
  State(..state, approving: None)
}

/// Whether the question is open for this proposal.
///
/// ## Examples
///
/// ```gleam
/// assert !proposals.asking(proposals.new(), "prop-0123456789")
/// ```
pub fn asking(state: State, id: String) -> Bool {
  state.approving == Some(id)
}

/// The words of the question an approval asks.
pub const approval_question =
  "Approve this rule? It is written to loom-rules.md, which sessions opened afterwards read. A session that is running keeps the rules it started with, and the workspace's AGENTS.md is never edited."

/// The label of the confirm button.
pub const approve_label = "Approve rule"

/// The label of the button that opens the question.
pub const ask_label = "Approve"

/// The label of the rejecting button.
pub const reject_label = "Reject"

/// The label of the question's way out.
pub const keep_label = "Keep waiting"
