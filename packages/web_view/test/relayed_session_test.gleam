//// The rules of the relayed session page (protocol-change/094): which presses
//// reach the daemon, and what each answer leaves on the page.
////
//// A press is judged against the row the page last read. These tests pin that a
//// page that has read nothing, or whose list does not hold the session, asks
//// nothing; that a reply, a stop, an archive and a decision each ask once; and
//// that a decision names a request the row lists, at the revision the card
//// showed, which the box's ceiling lets the page decide.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import session_view/remote_transcript
import web_view/listing
import web_view/relayed
import web_view/relayed_session as session

const identity = "0198c0de-0000-7000-8000-000000000001"

fn need(
  escalation: String,
  seq: Int,
  ability: relayed.Ability,
  remember: relayed.Remember,
) -> relayed.Need {
  relayed.Need(
    escalation:,
    seq:,
    strand: "main",
    tool: "bash",
    question: "Allow this command?",
    action: "go test ./...",
    authority: ["Network access: any host"],
    outside: [],
    ability:,
    remember:,
  )
}

fn row(needs: List(relayed.Need)) -> relayed.Row {
  relayed.Row(
    name: "build the thing",
    code: listing.Registered("exec", "loom"),
    activity: relayed.Working,
    updated_ms: 1000,
    needs:,
    more_needs: 0,
  )
}

fn shown() -> relayed.History {
  relayed.Shown(remote_transcript.Page(
    child: "main",
    entries: [],
    omitted: 0,
    next: None,
  ))
}

// A page whose first read found the session with these requests pending.
fn listed(needs: List(relayed.Need)) -> session.State {
  session.heard(
    session.open("box", identity),
    relayed.Heard(row: Some(row(needs)), history: shown()),
    100,
  )
}

fn plain() -> session.State {
  listed([
    need("ask-1", 4, relayed.Decidable, relayed.Rememberable),
    need("ask-2", 9, relayed.ViewOnly, relayed.OnceOnly),
    need("ask-3", 2, relayed.Decidable, relayed.OnceOnly),
  ])
}

pub fn a_new_page_has_read_nothing_and_holds_no_row_test() {
  let state = session.open("box", identity)

  assert state.presence == session.Unread
  assert state.row == None
  assert state.history == None
  assert state.reach == session.Answering
  assert state.sending == session.Ready
  assert state.acting == session.Calm
  assert state.sent == 0
}

// A press before the first read, or after the list stopped holding the session,
// has no row to be judged against and asks nothing, whatever it names.
pub fn a_page_with_no_row_asks_nothing_test() {
  let fresh = session.open("box", identity)
  let presses = [
    session.Replied("hello"),
    session.Stopped,
    session.ArchiveAsked,
    session.ArchiveConfirmed,
    session.Decided("ask-1", 4, relayed.Allow),
  ]
  list.each(presses, fn(press) {
    assert session.update(fresh, press) == #(fresh, session.Stay)
  })

  let gone =
    session.heard(listed([]), relayed.Heard(row: None, history: shown()), 200)
  assert gone.presence == session.Unlisted
  assert gone.row == None
  assert gone.history == None
  list.each(presses, fn(press) {
    assert session.update(gone, press) == #(gone, session.Stay)
  })
}

pub fn a_read_that_lists_the_session_replaces_the_row_and_the_transcript_test() {
  let state = listed([])

  assert state.presence == session.Listed
  assert state.row == Some(row([]))
  assert state.history == Some(shown())
  assert state.seen_ms == Some(100)
  assert state.clock_ms == 100
  assert state.reach == session.Answering
}

pub fn a_failed_read_keeps_what_the_page_has_and_dates_the_failure_test() {
  let state = listed([])
  let down = session.heard(state, relayed.Unreached("no route"), 5000)

  assert down.row == state.row
  assert down.history == state.history
  assert down.seen_ms == Some(100)
  assert down.clock_ms == 5000
  assert down.reach == session.Silent(since_ms: 5000, why: "no route")

  // The age shown is the age of the data: the failure that follows keeps the
  // time the first one began and takes the latest reason.
  let still = session.heard(down, relayed.Unreached("timed out"), 10_000)
  assert still.reach == session.Silent(since_ms: 5000, why: "timed out")

  // A read that answers clears the mark and replaces what the page holds.
  let back =
    session.heard(
      still,
      relayed.Heard(row: Some(row([])), history: shown()),
      15_000,
    )
  assert back.reach == session.Answering
  assert back.seen_ms == Some(15_000)
}

pub fn a_reply_is_trimmed_and_asked_once_test() {
  let #(sending, intent) = session.update(plain(), session.Replied("  hi  \n"))

  assert intent == session.SendReply("hi")
  assert sending.sending == session.Out

  // While it is out, a second press asks nothing.
  assert session.update(sending, session.Replied("again"))
    == #(sending, session.Stay)
}

pub fn an_empty_reply_asks_nothing_test() {
  let state = plain()

  assert session.update(state, session.Replied("")) == #(state, session.Stay)
  assert session.update(state, session.Replied(" \n\t "))
    == #(state, session.Stay)
}

// A reply over the bound is refused on the form in words and nothing is sent,
// so the person keeps their text and learns why.
pub fn a_reply_over_the_bound_is_refused_in_words_test() {
  let long = string.repeat("a", session.reply_limit + 1)
  let #(state, intent) = session.update(plain(), session.Replied(long))

  assert intent == session.Stay
  assert state.sending == session.Ready
  let assert Some(session.Failed(words:)) = state.notice
  assert string.contains(words, "too long")

  let edge = string.repeat("a", session.reply_limit)
  let #(_, intent) = session.update(plain(), session.Replied(edge))
  assert intent == session.SendReply(edge)
}

pub fn a_reply_that_landed_rebuilds_the_form_and_a_lost_one_keeps_it_test() {
  let #(sending, _) = session.update(plain(), session.Replied("hi"))

  let landed = session.replied(sending, relayed.Done)
  assert landed.sending == session.Ready
  assert landed.sent == 1
  assert landed.notice == None

  let refused =
    session.replied(sending, relayed.Refusal("the session is archived"))
  assert refused.sending == session.Ready
  assert refused.sent == 0
  assert refused.notice == Some(session.Failed("the session is archived"))

  let lost = session.replied(sending, relayed.Unknown("did not answer"))
  assert lost.sent == 0
  assert lost.notice == Some(session.Failed("did not answer"))
}

pub fn a_stop_asks_once_and_the_answer_clears_it_test() {
  let #(stopping, intent) = session.update(plain(), session.Stopped)

  assert intent == session.StopRun
  assert stopping.acting == session.Busy
  assert session.update(stopping, session.Stopped) == #(stopping, session.Stay)

  let done = session.stopped(stopping, relayed.Done)
  assert done.acting == session.Calm
  assert done.notice == Some(session.Said("The run was stopped."))

  let refused = session.stopped(stopping, relayed.Refusal("not relayed"))
  assert refused.acting == session.Calm
  assert refused.notice == Some(session.Failed("not relayed"))
}

// Archive is two presses: the first opens the question and sends nothing, and a
// confirmation with no question open does nothing.
pub fn an_archive_asks_only_after_its_question_test() {
  let state = plain()
  assert session.update(state, session.ArchiveConfirmed)
    == #(state, session.Stay)

  let #(asking, intent) = session.update(state, session.ArchiveAsked)
  assert intent == session.Stay
  assert asking.acting == session.Confirming

  let #(cancelled, intent) = session.update(asking, session.ArchiveCancelled)
  assert intent == session.Stay
  assert cancelled.acting == session.Calm

  let #(archiving, intent) = session.update(asking, session.ArchiveConfirmed)
  assert intent == session.ArchiveSession
  assert archiving.acting == session.Busy

  // Nothing else starts while the archive is out.
  assert session.update(archiving, session.Stopped)
    == #(archiving, session.Stay)
  assert session.update(archiving, session.ArchiveAsked)
    == #(archiving, session.Stay)

  let done = session.archived(archiving, relayed.Done)
  assert done.acting == session.Calm
  let assert Some(session.Said(words:)) = done.notice
  assert string.contains(words, "archived")
}

pub fn a_stop_while_the_archive_question_is_open_asks_nothing_test() {
  let #(asking, _) = session.update(plain(), session.ArchiveAsked)

  assert session.update(asking, session.Stopped) == #(asking, session.Stay)
}

pub fn a_decision_names_a_request_the_row_lists_at_its_revision_test() {
  let #(deciding, intent) =
    session.update(plain(), session.Decided("ask-1", 4, relayed.Allow))

  assert intent == session.Decide("ask-1", 4, relayed.Allow)
  assert deciding.deciding == Some("ask-1")

  // One decision at a time: another request waits for the first's answer.
  assert session.update(deciding, session.Decided("ask-3", 2, relayed.Deny))
    == #(deciding, session.Stay)

  let done = session.decided(deciding, relayed.Done)
  assert done.deciding == None
  assert done.notice == Some(session.Said("Your decision was sent."))

  let refused =
    session.decided(deciding, relayed.Refusal("outside the ceiling"))
  assert refused.deciding == None
  assert refused.notice == Some(session.Failed("outside the ceiling"))
}

// "Your decision was sent." says so while the card may still be listed, and is gone
// once a later read no longer lists that request. Another notice is left alone.
pub fn the_decision_line_clears_once_the_request_is_gone_test() {
  let #(deciding, _) =
    session.update(plain(), session.Decided("ask-1", 4, relayed.Allow))
  let sent = session.decided(deciding, relayed.Done)
  assert sent.notice == Some(session.Said("Your decision was sent."))

  // A read that still lists the request keeps the line.
  let still =
    session.heard(
      sent,
      relayed.Heard(
        row: Some(row([need("ask-1", 4, relayed.Decidable, relayed.OnceOnly)])),
        history: shown(),
      ),
      2000,
    )
  assert still.notice == Some(session.Said("Your decision was sent."))

  // A read that does not list it clears the line, and only that line.
  let gone =
    session.heard(
      still,
      relayed.Heard(row: Some(row([])), history: shown()),
      3000,
    )
  assert gone.notice == None

  let failed =
    session.State(
      ..still,
      notice: Some(session.Failed("the box did not answer")),
    )
  let kept =
    session.heard(
      failed,
      relayed.Heard(row: Some(row([])), history: shown()),
      3000,
    )
  assert kept.notice == Some(session.Failed("the box did not answer"))
}

// A forged press, or a stale one, finds no request and asks nothing: an unknown
// identity, the right identity at a revision the card was not drawn with, and a
// request the ceiling does not let the page decide.
pub fn a_forged_or_stale_decision_asks_nothing_test() {
  let state = plain()

  assert session.update(state, session.Decided("other", 4, relayed.Allow))
    == #(state, session.Stay)
  assert session.update(state, session.Decided("ask-1", 5, relayed.Allow))
    == #(state, session.Stay)
  assert session.update(state, session.Decided("ask-2", 9, relayed.Deny))
    == #(state, session.Stay)
}

// Allowing for the session is offered only for a request whose grants the
// terminal would also remember. A press for one that cannot be remembered asks
// nothing, though Allow once and Deny on it do.
pub fn allowing_for_the_session_needs_a_rememberable_request_test() {
  let state = plain()

  let #(_, remembered) =
    session.update(state, session.Decided("ask-1", 4, relayed.AllowForSession))
  assert remembered == session.Decide("ask-1", 4, relayed.AllowForSession)

  assert session.update(
      state,
      session.Decided("ask-3", 2, relayed.AllowForSession),
    )
    == #(state, session.Stay)

  let #(_, once) =
    session.update(state, session.Decided("ask-3", 2, relayed.Allow))
  assert once == session.Decide("ask-3", 2, relayed.Allow)
  let #(_, denied) =
    session.update(state, session.Decided("ask-3", 2, relayed.Deny))
  assert denied == session.Decide("ask-3", 2, relayed.Deny)
}

// A list that no longer holds the session ends whatever decision was out for it:
// there is nothing left to answer.
pub fn a_session_that_leaves_the_list_ends_a_pending_decision_test() {
  let #(deciding, _) =
    session.update(plain(), session.Decided("ask-1", 4, relayed.Allow))
  let gone =
    session.heard(deciding, relayed.Heard(row: None, history: shown()), 300)

  assert gone.deciding == None
}
