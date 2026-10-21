//// What a page knows of one session that runs on another orchestrator
//// (protocol-change/094, the placement revamp's slice S2b).
////
//// A page is bound to the daemon that serves it, yet the owner may start a
//// session whose agent runs on the box and drive it from the laptop's page. The
//// daemon relays: it asks the box for what the page draws and tells the box what
//// the person decided. This module is the page's half of that vocabulary. The
//// daemon (`client/daemon/ui_top`) turns what the box said into these types
//// after its own total decoders have judged the answer, so everything here is
//// already bounded and closed, and nothing in it is a credential, a node name or
//// an address.
////
//// ## Untrusted text
////
//// A session's name, a folder, a request's tool and preview are written on the
//// box, and a request's words are written by a model. They are drawn as text
//// nodes and nowhere else: never an attribute, a class, a link or a style. The
//// one exception is a request's identity, which keys its card in the list
//// (`view/relayed_session`): a key is only compared with the other keys of that
//// list, never becomes a path, a class or an attribute, and the port's decoder
//// bounds its length. The two values a route is built from, the orchestrator's key and the
//// session's identity, are checked by the router before a page exists and are
//// never taken from this module's types.
////
//// ## What a request carries
////
//// A `Need` is one pending request of the session, already worded by the same
//// rules a local approval card follows (`session_view/approval.presentation`),
//// so the page draws the exact action and the exact authority that approving
//// would add, one literal line for each. `ability` says whether the box's
//// approval ceiling admits any of it, and `remember` whether the grants may be
//// kept for the session, as the terminal's "Allow for this session" is offered
//// (`approval.rememberable`). A press names a request by the box's identity and
//// the revision the person was shown, and the box refuses a decision for a
//// question that has since changed.
////
//// ## Flow
////
//// `activity_words` → `age_words` → `find_need`
////
//// 1. `activity_words` is the one word a session's state is drawn as.
//// 2. `age_words` words how long ago a read was made, for a box that stopped
////    answering.
//// 3. `find_need` is how a press on a request is checked against the row the
////    page last read.

import gleam/int
import gleam/list
import gleam/option.{type Option}
import session_view/remote_transcript
import web_view/listing

/// What a relayed session is doing, as the box's list says it. A session the
/// owner archived is not listed, so there is no word for it.
pub type Activity {
  /// A request is pending, or the last run failed and nothing has run since.
  NeedsYou

  /// A strand is running.
  Working

  /// Nothing runs and nothing is asked.
  Idle
}

/// Whether the page may decide a pending request.
pub type Ability {
  /// The box's approval ceiling admits some of what the request wants, so the
  /// buttons are drawn. The box judges the decision again.
  Decidable

  /// The ceiling admits nothing of it, or the spawner has no ceiling: the page
  /// shows the request and says it is decided on the box's own page.
  ViewOnly
}

/// Whether the grants of a request may be kept for the rest of the session.
pub type Remember {
  /// The request is one the terminal would offer to remember too.
  Rememberable

  /// The request can be allowed once and no longer.
  OnceOnly
}

/// One pending request of a relayed session.
pub type Need {
  Need(
    /// The box's identity for the request, which a decision names.
    escalation: String,
    /// The revision of the question the person was shown. A decision carries it,
    /// and the box refuses one for a question that has since changed.
    seq: Int,
    /// The strand that asked.
    strand: String,
    /// The tool the call was for.
    tool: String,
    /// What is being decided, in a sentence such as "Allow this command?".
    question: String,
    /// The exact action, which the box wrote.
    action: String,
    /// The access that approving would add, one literal line for each grant.
    authority: List(String),
    /// The grants the box's ceiling does not admit, in words, one line each.
    /// They are drawn and are not part of what Allow carries.
    outside: List(String),
    /// Whether the page may decide it.
    ability: Ability,
    /// Whether the grants may be kept for the session.
    remember: Remember,
  )
}

/// One relayed session as the box's list says it.
pub type Row {
  Row(
    /// The session's display name.
    name: String,
    /// Where its tools run.
    code: listing.Code,
    /// What it is doing.
    activity: Activity,
    /// When it last changed, in Unix milliseconds on the box's clock.
    updated_ms: Int,
    /// The oldest pending requests, at most eight.
    needs: List(Need),
    /// How many pending requests the box holds beyond `needs`.
    more_needs: Int,
  )
}

/// Whether the transcript could be read.
pub type History {
  /// The newest page of the transcript. Images, reasoning and results are words
  /// in it (`session_view/remote_transcript.said`), never markup.
  Shown(
    /// The page, oldest entry first.
    page: remote_transcript.Page,
  )

  /// The page could not be read, and why.
  Unreadable(
    /// The reason, in words for the person.
    why: String,
  )
}

/// What one read of the box gave the page.
pub type Read {
  /// The box answered its list. `row` is `None` when the list does not hold the
  /// session, which is what an archived or deleted session, or an identity the
  /// box never made for this page, looks like.
  Heard(
    /// The session's row in the list.
    row: Option(Row),
    /// The transcript, read when the row was found.
    history: History,
  )

  /// The box could not be reached, or did not answer, or answered what could not
  /// be read.
  Unreached(
    /// The reason, in words for the person.
    why: String,
  )
}

/// What the box said to a request that changed something: a message, a stop, an
/// archive or a decision.
pub type Outcome {
  /// The box did it.
  Done

  /// The box, or this daemon, refused. Nothing changed.
  Refusal(
    /// The refusal, in words for the person.
    why: String,
  )

  /// The box did not answer, so it is not known whether it happened. A message
  /// stays in the form so the person can look before sending it again.
  Unknown(
    /// What to tell the person.
    why: String,
  )
}

/// How a person decides a request.
pub type Choice {
  /// Approve what the box's ceiling admits, once.
  Allow

  /// Approve it, and remember the grants for the session.
  AllowForSession

  /// Reject it.
  Deny
}

/// The word a session's activity is drawn as.
///
/// ## Examples
///
/// ```gleam
/// assert relayed.activity_words(relayed.NeedsYou) == "needs you"
/// assert relayed.activity_words(relayed.Working) == "working"
/// assert relayed.activity_words(relayed.Idle) == "idle"
/// ```
pub fn activity_words(activity: Activity) -> String {
  case activity {
    NeedsYou -> "needs you"
    Working -> "working"
    Idle -> "idle"
  }
}

/// How long ago something was read, in words: whole seconds under a minute, then
/// minutes, hours and days, each figure rounded down. A time in the future is
/// "just now".
///
/// ## Examples
///
/// ```gleam
/// assert relayed.age_words(125_000) == "2m ago"
/// assert relayed.age_words(-5) == "just now"
/// ```
pub fn age_words(age_ms: Int) -> String {
  let seconds = age_ms / 1000
  case seconds {
    seconds if seconds < 1 -> "just now"
    seconds if seconds < 60 -> int.to_string(seconds) <> "s ago"
    seconds if seconds < 3600 -> int.to_string(seconds / 60) <> "m ago"
    seconds if seconds < 86_400 -> int.to_string(seconds / 3600) <> "h ago"
    seconds -> int.to_string(seconds / 86_400) <> "d ago"
  }
}

/// The request of a row that a press names, found by the box's identity and the
/// revision the card was drawn with. A press for a request the row does not list,
/// or for a question that has since moved, finds nothing.
///
/// ## Examples
///
/// ```gleam
/// assert relayed.find_need([], "id", 1) == Error(Nil)
/// ```
pub fn find_need(
  needs: List(Need),
  escalation: String,
  seq: Int,
) -> Result(Need, Nil) {
  list.find(needs, fn(need) { need.escalation == escalation && need.seq == seq })
}
