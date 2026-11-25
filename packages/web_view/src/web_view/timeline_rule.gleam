//// What the page holds of a session's timeline and which of it a person sees
//// (protocol-change/134).
////
//// The daemon answers a read with one page of cards. A person asks for the page
//// of a thread that is open, and for the older cards of it with a press, so the
//// page keeps the cards of every read it started for a session, oldest first,
//// and the cursor the next press asks from. The cards a person sees depend on a
//// density they choose: only the landmark cards, every card, or every card with
//// its detail open. That is a decision about records and a number, never about
//// the words in a card, so it is made here and the view only draws. The module
//// performs no I/O and draws nothing.
////
//// ## Flow
////
//// `merged` → `shown` → `landmark`
////
//// 1. `merged` folds one read into what the page held for the session.
//// 2. `shown` picks the cards a density shows.
//// 3. `landmark` is the test the lowest density applies to one card.

import gleam/list
import gleam/option.{type Option, None, Some}
import session_view/timeline
import web_view/timeline_feed.{type Card, type Feed}

/// How much of the timeline a person asked to see.
pub type Density {
  /// Prompts, answers, asks, compactions, sub-agent results and failed
  /// commands, which are the spans a reader looks for first.
  Landmarks

  /// Every card.
  Standard

  /// Every card, each with its detail open.
  Detailed
}

/// What the page holds of one session's timeline.
pub type Held {
  Held(
    /// The cards the page has read, oldest first.
    cards: List(Card),
    /// The `before` the next press of "Earlier cards" asks with, when the
    /// daemon said there are older cards.
    older: Option(Int),
    /// The span still open at the last read of the newest page.
    now: Option(Card),
    /// The daemon's fixed words when its last read was refused and the page had
    /// nothing to keep, and nothing otherwise.
    words: Option(String),
  )
}

/// The density a page starts at: the landmarks, because a session makes a card
/// for about every three steps and a reader wants the milestones first.
pub const starting_density = Landmarks

/// Folds one read into what the page held. A read of the newest page replaces the
/// held cards, since the session may have closed more of them, and a read of an
/// older page goes in front of them. A refused read keeps what the page has, and
/// says its words only when the page has nothing.
///
/// ## Examples
///
/// ```gleam
/// assert timeline_rule.merged(None, None, Error("busy")).words == Some("busy")
/// ```
pub fn merged(
  held: Option(Held),
  before: Option(Int),
  read: Result(Feed, String),
) -> Held {
  // The read's page decides how it joins what is held.
  case read, before, held {
    Ok(feed), Some(_), Some(kept) ->
      Held(
        cards: list.append(feed.cards, kept.cards),
        older: feed.older,
        now: kept.now,
        words: None,
      )
    Ok(feed), _, _ ->
      Held(cards: feed.cards, older: feed.older, now: feed.now, words: None)
    Error(_), _, Some(kept) -> kept
    Error(words), _, None ->
      Held(cards: [], older: None, now: None, words: Some(words))
  }
}

/// The cards a density shows, oldest first.
///
/// ## Examples
///
/// ```gleam
/// assert timeline_rule.shown([], Landmarks) == []
/// ```
pub fn shown(cards: List(Card), density: Density) -> List(Card) {
  // Only the lowest density leaves cards out.
  case density {
    Landmarks -> list.filter(cards, landmark)
    Standard | Detailed -> cards
  }
}

/// Whether a card is one a reader looks for first: a prompt, an answer, an ask, a
/// compaction, a sub-agent's result, or a command that failed.
///
/// ## Examples
///
/// ```gleam
/// // timeline_rule.landmark(card)
/// ```
pub fn landmark(card: Card) -> Bool {
  // A command is a landmark only when it failed, and plain work never is.
  case card.kind {
    timeline.Prompted
    | timeline.Answered
    | timeline.Asked
    | timeline.Compacted
    | timeline.Reported -> True
    timeline.Ran -> card.failed > 0
    timeline.Worked -> False
  }
}
