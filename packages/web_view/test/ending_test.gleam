//// The words a page says when it has no session, and how its socket ends,
//// are decided by a closed type (protocol-change/051, the addendum on an
//// ended page). These tests hold the three tables to each other: every
//// ending survives the trip through the reason string the relay sends, has
//// words of its own, and has a close code, and a reason no ending names is
//// handed back to the caller's fallback instead of being drawn.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import web_view/ending

pub fn every_ending_survives_its_reason_string_test() {
  list.each(ending.all(), fn(reason) {
    assert ending.from_reason(ending.reason(reason), otherwise: reason)
      == reason

    // The round trip is not the fallback in disguise: a different
    // fallback gives the same answer.
    let other = case reason {
      ending.ConnectionFailed -> ending.NotOpen
      ending.PageEnded
      | ending.AccessRevoked
      | ending.SessionStopped
      | ending.NotOpen
      | ending.DaemonNotReady
      | ending.LinkExpired -> ending.ConnectionFailed
    }
    assert ending.from_reason(ending.reason(reason), otherwise: other) == reason
  })
}

pub fn no_two_endings_share_a_reason_or_a_headline_test() {
  let reasons = list.map(ending.all(), ending.reason)
  assert list.unique(reasons) == reasons
  let headlines = list.map(ending.all(), ending.headline)
  assert list.unique(headlines) == headlines
}

// A reason the daemon composed for its log, or one a lane failed with, names
// no ending. The caller's fallback stands for it and its words are not kept.
pub fn a_reason_that_names_no_ending_takes_the_fallback_test() {
  assert ending.from_reason("gateway unavailable", otherwise: ending.NotOpen)
    == ending.NotOpen
  assert ending.from_reason("unauthorized", otherwise: ending.AccessRevoked)
    == ending.AccessRevoked
  assert ending.from_reason("", otherwise: ending.ConnectionFailed)
    == ending.ConnectionFailed
}

// The relay's reasons before this type existed. A lane's recorded reason and
// the daemon's tests read the same strings, so they are fixed.
pub fn the_relays_reason_strings_are_unchanged_test() {
  assert ending.reason(ending.PageEnded) == "the page session ended"
  assert ending.reason(ending.AccessRevoked) == "access was revoked"
  assert ending.reason(ending.SessionStopped) == "the session ended"
}

// Lustre's client runtime reconnects after any close code but 1000. An
// ending the daemon may clear by itself is retried; one the person has to
// resolve is final, so a notice that will not change is not refreshed every
// ten seconds.
pub fn only_an_ending_that_may_clear_by_itself_is_retried_test() {
  let retried =
    list.filter(ending.all(), fn(e) { ending.close(e) == ending.Retry })
  assert retried == [ending.NotOpen, ending.DaemonNotReady]
  assert ending.close(ending.PageEnded) == ending.Final
  assert ending.close(ending.AccessRevoked) == ending.Final
  assert ending.close(ending.SessionStopped) == ending.Final
}

// A stopped session is the one ending whose page is still good: its UI
// session lasts eight hours and a reload does not need the session to be
// open, so a fresh link would end the page for nothing.
pub fn the_advice_names_the_command_for_the_session_test() {
  list.each(ending.all(), fn(reason) {
    let advice = ending.advice(reason, "0192ab34cd")
    case reason {
      ending.SessionStopped -> {
        assert string.contains(advice, "reload this page")
        assert !string.contains(advice, "loom ui")
      }
      ending.PageEnded
      | ending.AccessRevoked
      | ending.NotOpen
      | ending.DaemonNotReady
      | ending.LinkExpired
      | ending.ConnectionFailed -> {
        assert string.contains(advice, "`loom ui --session 0192ab34cd`")
      }
    }
  })
}

// An ended page is not helped by a reload: its key is gone, so the reload
// finds no page session. Only the endings that clear by themselves, or that
// a reload can resolve, tell the person to reload.
pub fn an_ended_page_is_told_to_ask_for_a_fresh_link_not_to_reload_test() {
  assert !string.contains(ending.advice(ending.PageEnded, "S"), "Reload")
  assert !string.contains(ending.advice(ending.LinkExpired, "S"), "Reload")
  assert string.contains(ending.advice(ending.DaemonNotReady, "S"), "Reload")
}

// Opening a newer link ends an earlier page only at the bound
// (protocol-change/051, the addendum on several pages), so the words for an
// ended page name the three causes and the bound, and never say that any
// new link ends the page.
pub fn an_ended_page_names_what_ends_a_page_test() {
  let advice = ending.advice(ending.PageEnded, "S")
  assert !string.contains(advice, "new link")
  assert string.contains(advice, "eight hours")
  assert string.contains(advice, "restarts")
  assert string.contains(advice, "4 pages")
  assert string.contains(advice, "oldest")
  assert ending.max_pages == 4
}

// The live notice's sentence is the advice's lead and then the command in
// backticks, and an ending with no command says its lead and nothing more, for
// a session's page and for a home's.
pub fn the_sentence_is_the_lead_then_the_command_test() {
  list.each(ending.all(), fn(reason) {
    let session = ending.advised(reason, "S")
    let said = ending.advice(reason, "S")
    assert string.starts_with(said, session.lead)
    case session.command {
      Some(command) -> {
        assert command == "loom ui --session S"
        assert string.ends_with(
          said,
          "Run `" <> command <> "` for a fresh link.",
        )
      }
      None -> {
        assert said == session.lead
      }
    }
    let home = ending.home_advised(reason)
    assert home.command == Some("loom ui")
    assert string.starts_with(ending.home_advice(reason), home.lead)
  })
}
