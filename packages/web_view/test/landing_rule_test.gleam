//// The first round that decides the home page's centre
//// (`web_view/landing_rule`). The module is pure, so each test states the rule
//// over a record: which reads are due, the order they answer in, and what the
//// round gathered. The page's own behaviour under the same rule is pinned in
//// `attention_threads_test` and `ticket_threads_test`.

import gleam/list
import gleam/option.{None, Some}
import web_view/inbox_rule
import web_view/landing_rule.{
  type Close, type Round, type Source, ActivitySource, BoardsSource, Closes,
  Continues, Due, FeedSource, ListSource, NotDue, SummarySource,
}
import web_view/sessions.{Report}

// A round whose list has answered and in which every other read is due.
fn everything_due() -> Round {
  let #(round, close) =
    landing_rule.listed(
      landing_rule.open(Due),
      activity: Due,
      summary: Due,
      feed: Due,
    )
  assert close == Continues

  round
}

// The closes an answering order gives, in the order the answers came.
fn closes(round: Round, order: List(Source)) -> List(Close) {
  let #(_, seen) =
    list.fold(order, #(round, []), fn(held, source) {
      let #(round, seen) = held
      let #(next, close) = landing_rule.answer(round, source)

      #(next, [close, ..seen])
    })

  list.reverse(seen)
}

fn picture(
  reports: List(sessions.Report),
  needing: Int,
  finds: Int,
  tickets: Int,
) -> landing_rule.Picture {
  landing_rule.Picture(reports:, needing:, finds:, tickets:)
}

// Whichever order the four reads after the list answer in, the round closes
// once, on the last of them.
pub fn every_arrival_order_closes_once_on_the_last_test() {
  let orders =
    list.permutations([ActivitySource, SummarySource, BoardsSource, FeedSource])

  assert list.length(orders) == 24

  list.each(orders, fn(order) {
    assert closes(everything_due(), order)
      == [Continues, Continues, Continues, Closes]
  })
}

// The list answering last closes the round too: nothing is special about the
// read that names the others.
pub fn the_list_is_one_read_among_the_others_test() {
  let round = landing_rule.open(Due)

  // Before the list is read the others are not known to be due, so a board that
  // answers first leaves the round open.
  let #(round, close) = landing_rule.answer(round, BoardsSource)
  assert close == Continues

  let #(_, close) =
    landing_rule.listed(round, activity: NotDue, summary: NotDue, feed: NotDue)
  assert close == Closes
}

// A read that is not due is ignored: it neither delays the round nor closes it.
pub fn reads_that_are_not_due_are_ignored_test() {
  let #(round, close) =
    landing_rule.listed(
      landing_rule.open(NotDue),
      activity: Due,
      summary: NotDue,
      feed: Due,
    )
  assert close == Continues

  // The summary and the boards were never due, so their answers change nothing.
  assert landing_rule.answer(round, SummarySource) == #(round, Continues)
  assert landing_rule.answer(round, BoardsSource) == #(round, Continues)

  assert closes(round, [SummarySource, ActivitySource, BoardsSource, FeedSource])
    == [Continues, Continues, Continues, Closes]
  assert closes(round, [FeedSource, BoardsSource, ActivitySource])
    == [Continues, Continues, Closes]
}

// A page whose list holds nothing that starts another read, and that lists no
// projects, has only the list to wait for.
pub fn a_list_that_starts_no_read_closes_at_once_test() {
  let #(round, close) =
    landing_rule.listed(
      landing_rule.open(NotDue),
      activity: NotDue,
      summary: NotDue,
      feed: NotDue,
    )

  assert close == Closes
  assert round.list == landing_rule.Answered
}

// Only the first list says which reads are due. A later list neither adds a read
// to a round that is waiting nor reopens a round that closed.
pub fn only_the_first_list_sets_the_reads_test() {
  let round = everything_due()

  // A later list that starts the same reads changes nothing.
  assert landing_rule.listed(round, activity: Due, summary: Due, feed: Due)
    == #(round, Continues)

  let #(closed, _) =
    list.fold(
      [ActivitySource, SummarySource, BoardsSource, FeedSource],
      #(round, Continues),
      fn(held, source) { landing_rule.answer(held.0, source) },
    )

  assert landing_rule.listed(closed, activity: Due, summary: Due, feed: Due)
    == #(closed, Continues)
}

// Once the round has closed, no answer closes it again, whichever read it is
// and however many times it comes.
pub fn a_later_read_never_closes_the_round_again_test() {
  let sources = [ActivitySource, SummarySource, BoardsSource, FeedSource]
  let #(closed, _) =
    list.fold(sources, #(everything_due(), Continues), fn(held, source) {
      landing_rule.answer(held.0, source)
    })

  list.each([ListSource, ..sources], fn(source) {
    assert landing_rule.answer(closed, source) == #(closed, Continues)
  })
}

// A read that answers twice before the round closes counts once.
pub fn a_second_answer_of_the_same_read_does_not_close_the_round_test() {
  assert closes(everything_due(), [
      ActivitySource,
      ActivitySource,
      FeedSource,
      FeedSource,
      SummarySource,
      SummarySource,
      BoardsSource,
    ])
    == [
      Continues,
      Continues,
      Continues,
      Continues,
      Continues,
      Continues,
      Closes,
    ]
}

// A running session that works lands the inbox, and so does one that said
// something when it stopped.
pub fn a_running_session_lands_the_inbox_test() {
  let working = Report(sessions.Working, None, [], None, None, 0)
  let said = Report(sessions.Idle, Some("Done."), [], None, None, 0)

  assert landing_rule.landing(picture([working], 0, 0, 0)) == inbox_rule.Inbox
  assert landing_rule.landing(picture([said], 0, 0, 0)) == inbox_rule.Inbox
}

// Each kind of item that waits on a person lands the inbox with nothing running:
// an approval, ask or stuck strand, which the page counts together, an open find,
// and a project ticket.
pub fn each_kind_of_waiting_item_lands_the_inbox_test() {
  assert landing_rule.landing(picture([], 1, 0, 0)) == inbox_rule.Inbox
  assert landing_rule.landing(picture([], 0, 1, 0)) == inbox_rule.Inbox
  assert landing_rule.landing(picture([], 0, 0, 1)) == inbox_rule.Inbox
}

// A quiet running session lands the inbox only when something else waits, which
// is the case the first round exists for: the activity read alone says form.
pub fn a_quiet_session_lands_the_form_unless_something_waits_test() {
  let quiet = Report(sessions.Idle, None, [], None, None, 0)

  assert landing_rule.landing(picture([quiet], 0, 0, 0)) == inbox_rule.Form
  assert landing_rule.landing(picture([quiet], 1, 0, 0)) == inbox_rule.Inbox
  assert landing_rule.landing(picture([quiet], 0, 0, 1)) == inbox_rule.Inbox
}

// Nothing at all gives the form.
pub fn nothing_gives_the_form_test() {
  assert landing_rule.landing(picture([], 0, 0, 0)) == inbox_rule.Form
}

// A later list that no longer starts a read still due releases it, since its
// task may have crashed and delivered nothing, and closes the round if that
// was the last read owed.
pub fn a_list_that_no_longer_starts_a_due_read_releases_it_test() {
  let #(round, _) =
    landing_rule.listed(
      landing_rule.open(NotDue),
      activity: Due,
      summary: Due,
      feed: NotDue,
    )
  let #(round, close) = landing_rule.answer(round, SummarySource)
  assert close == Continues

  let #(released, close) =
    landing_rule.relisted(
      round,
      activity: NotDue,
      summary: NotDue,
      feed: NotDue,
    )
  assert close == Closes
  assert released.activity == landing_rule.Answered
}

// A read the later list still starts stays due, so the round stays open, and a
// read that was not due is not made due by it.
pub fn a_list_that_still_starts_the_read_keeps_it_due_test() {
  let #(round, _) =
    landing_rule.listed(
      landing_rule.open(NotDue),
      activity: Due,
      summary: NotDue,
      feed: NotDue,
    )

  assert landing_rule.relisted(round, activity: Due, summary: Due, feed: Due)
    == #(round, Continues)
}

// A round that has closed is not closed again by a later list.
pub fn a_later_list_never_closes_a_closed_round_test() {
  let #(round, _) =
    landing_rule.listed(
      landing_rule.open(NotDue),
      activity: NotDue,
      summary: NotDue,
      feed: NotDue,
    )

  assert landing_rule.relisted(
      round,
      activity: NotDue,
      summary: NotDue,
      feed: NotDue,
    )
    == #(round, Continues)
}
