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

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import session_view/timeline
import web_view/timeline_feed.{type Card, type Feed}

/// How much of the timeline a person asked to see.
pub type Density {
  /// The landmark cards (prompts, answers, asks, compactions, sub-agent results
  /// and failed commands) of the turns where something happened, and of the
  /// newest turn. A turn where something happened wrote a file, had a failed
  /// call, asked a question, compacted or got a sub-agent's result. The census
  /// of recorded sessions found about one landmark card in five turns that did
  /// nothing worth a reader's time, and those turns are most of a long session.
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

/// Folds one read into what the page held. A read of the newest page joins the
/// cards the person already loaded when it overlaps them and replaces them when it
/// does not, and a read of an older page goes in front of the held cards only when
/// it answers the cursor the page holds, so a duplicate or a late reply changes
/// nothing. A refused read keeps what the page has, and says its words only when
/// the page has nothing.
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
    Ok(feed), Some(asked), Some(kept) if kept.older == Some(asked) ->
      Held(
        cards: list.append(feed.cards, kept.cards),
        older: feed.older,
        now: kept.now,
        words: None,
      )
    Ok(_), Some(_), Some(kept) -> kept
    Ok(feed), _, Some(kept) -> refreshed(kept, feed)
    Ok(feed), _, None ->
      Held(cards: feed.cards, older: feed.older, now: feed.now, words: None)
    Error(_), _, Some(kept) -> kept
    Error(words), _, None ->
      Held(cards: [], older: None, now: None, words: Some(words))
  }
}

/// The newest page again, joined to what the person already loaded. When the new
/// page's oldest card is one the page holds, the held cards older than it stay and
/// so does the cursor that reaches those older still; otherwise the sessions's
/// cards moved past what was held, and the new page replaces it.
fn refreshed(kept: Held, feed: Feed) -> Held {
  // The new page and the held cards overlap at the new page's oldest card.
  case feed.cards {
    [oldest, ..] ->
      case list.any(kept.cards, fn(card) { card.from_seq == oldest.from_seq }) {
        True ->
          Held(
            cards: list.append(
              list.take_while(kept.cards, fn(card) {
                card.from_seq < oldest.from_seq
              }),
              feed.cards,
            ),
            older: kept.older,
            now: feed.now,
            words: None,
          )
        False ->
          Held(cards: feed.cards, older: feed.older, now: feed.now, words: None)
      }
    [] -> Held(cards: [], older: feed.older, now: feed.now, words: None)
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
    Landmarks -> {
      let eventful = eventful_turns(cards)
      let newest =
        list.fold(cards, 0, fn(most, card) { int.max(most, card.turn_seq) })

      list.filter(cards, fn(card) {
        landmark(card)
        && { set.contains(eventful, card.turn_seq) || card.turn_seq == newest }
      })
    }
    Standard | Detailed -> cards
  }
}

/// The turns of the cards where something happened. A card of turn 0 is from a
/// window that began inside a turn, whose start is unknown, so its turn is kept.
fn eventful_turns(cards: List(Card)) -> Set(Int) {
  cards
  |> list.filter(fn(card) {
    card.turn_seq == 0
    || card.files_total > 0
    || card.failed > 0
    || card.kind == timeline.Asked
    || card.kind == timeline.Compacted
    || card.kind == timeline.Reported
  })
  |> list.map(fn(card) { card.turn_seq })
  |> set.from_list
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
  // A command is a landmark only when it exited with a failure, and plain work
  // never is.
  case card.kind {
    timeline.Prompted
    | timeline.Answered
    | timeline.Asked
    | timeline.Compacted
    | timeline.Reported -> True
    timeline.Ran ->
      case card.command {
        Some(command) -> command.exit != 0
        None -> card.failed > 0
      }
    timeline.Worked -> False
  }
}
