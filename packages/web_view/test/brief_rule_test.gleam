//// When the page reads a brief and what of it a thread may show
//// (`web_view/brief_rule`).

import gleam/option.{None, Some}
import web_view/brief_rule.{Read}
import web_view/session_brief.{Brief, Peer}

fn peer() -> session_brief.Peer {
  Peer(
    session: "s",
    strand: "main",
    at: 5,
    text: session_brief.untrusted("hello"),
  )
}

fn brief() -> session_brief.Brief {
  Brief(
    assistant: None,
    steps: [],
    strands: [],
    goal: None,
    peers: [peer()],
    command: None,
  )
}

pub fn a_session_never_read_is_always_due_test() {
  assert brief_rule.due(None, 0, 0, brief_rule.Refreshed)
  assert brief_rule.due(None, 0, 0, brief_rule.Opened)
}

pub fn a_refresh_reads_again_only_after_fifteen_seconds_test() {
  assert !brief_rule.due(Some(Read(0, 0)), 14_999, 0, brief_rule.Refreshed)
  assert brief_rule.due(Some(Read(0, 0)), 15_000, 0, brief_rule.Refreshed)
}

pub fn an_opening_reads_again_unless_it_repeats_at_once_test() {
  assert !brief_rule.due(Some(Read(0, 0)), 999, 0, brief_rule.Opened)
  assert brief_rule.due(Some(Read(0, 0)), 1000, 0, brief_rule.Opened)
}

pub fn a_read_that_asked_after_another_time_is_due_again_test() {
  assert brief_rule.due(Some(Read(0, 0)), 1, 7, brief_rule.Refreshed)
  assert !brief_rule.due(Some(Read(0, 7)), 1, 7, brief_rule.Refreshed)
}

pub fn peers_are_shown_only_for_a_read_that_named_the_raise_time_test() {
  let held = Some(session_brief.Seen(brief()))

  assert brief_rule.shown(held, Some(100), Some(100)) == Some(brief())
  assert brief_rule.shown(held, Some(0), Some(100))
    == Some(Brief(..brief(), peers: []))
  assert brief_rule.shown(held, Some(100), None)
    == Some(Brief(..brief(), peers: []))
  assert brief_rule.shown(held, None, Some(100))
    == Some(Brief(..brief(), peers: []))
}

pub fn a_refused_or_missing_read_shows_nothing_test() {
  assert brief_rule.shown(None, None, None) == None
  assert brief_rule.shown(Some(session_brief.Unseen("no")), Some(1), Some(1))
    == None
}
