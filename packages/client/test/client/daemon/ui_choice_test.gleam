//// Which page a relayed session's route gets from the way an attach ended
//// (protocol-change/108, "Choosing the page"). Every outcome of
//// `top_relay.attach` is one page, and each arm is here.
////
//// The rule: a feed is the live page. A box that cannot be reached or asked for
//// another try is the live page waiting, because the box offers it and the next
//// attach can succeed. A box holding the most feeds it allows is the live page
//// waiting with its own words. A box that lacks the revisions, serves the
//// transcript, or answered something this daemon cannot read is the transcript
//// with the sentence that fits, because retrying an unreadable answer would leave
//// a feed on the box for every try.

import client/daemon/ui_socket.{
  Attached, Crowded, LivePage, TranscriptPage, Waiting,
}
import client/remote/top_relay
import client/remote_feed
import client/remote_top
import gleam/list
import web_view/relayed

fn attached() -> remote_feed.Attached {
  remote_feed.Attached(
    feed: "0123456789abcdef0123456789abcdef",
    epoch: "epoch",
    incarnation: "incarnation",
    label: remote_feed.Label(
      name: "work",
      placement: remote_top.Folder("/srv/work"),
    ),
  )
}

fn refused(refusal: remote_top.Refusal) -> ui_socket.Choice {
  ui_socket.chosen(Error(top_relay.Refused(refusal)))
}

pub fn a_feed_is_the_live_page_test() {
  assert ui_socket.chosen(Ok(attached())) == LivePage(Attached(attached()))
}

pub fn a_box_without_the_revisions_is_the_transcript_that_says_so_test() {
  assert ui_socket.chosen(Error(top_relay.Unsupported))
    == TranscriptPage(relayed.Absent)
  assert ui_socket.chosen(Error(top_relay.OlderBuild))
    == TranscriptPage(relayed.Absent)
}

pub fn a_box_that_serves_the_transcript_is_the_transcript_that_says_so_test() {
  assert refused(remote_top.NotOffered(remote_top.OfferedPage, "live"))
    == TranscriptPage(relayed.Served)
}

pub fn a_box_that_cannot_be_reached_is_the_live_page_waiting_test() {
  assert ui_socket.chosen(Error(top_relay.Unreachable)) == LivePage(Waiting)
  assert ui_socket.chosen(Error(top_relay.Silent)) == LivePage(Waiting)
  assert ui_socket.chosen(Error(top_relay.PeerChanged)) == LivePage(Waiting)
}

// A saved session that did not open in time, a refused permit, a slow feed host
// and a failed store are all the box asking for another try, which
// `remote_top.retryable` says and the cursor already applies to polls.
pub fn a_box_that_asked_for_another_try_is_the_live_page_waiting_test() {
  assert refused(remote_top.NotYetOpen("the session is opening"))
    == LivePage(Waiting)
  assert refused(remote_top.StoreFailure("the store failed"))
    == LivePage(Waiting)
}

// An ended feed counts toward the box's cap until it is forgotten, so a laptop
// that wakes with several relayed tabs meets the cap on some re-attaches. It
// clears within seconds, so the page retries, and its words say what is true.
pub fn a_box_at_its_feed_cap_is_the_live_page_waiting_with_its_own_words_test() {
  assert refused(remote_top.CapReached(remote_top.MaxFeeds, 8))
    == LivePage(Crowded)
  assert !remote_top.retryable(remote_top.CapReached(remote_top.MaxFeeds, 8))
    as "the cap is not retryable for a create, which is why the choice names it"
}

// Everything else the box refuses has its own words on the transcript page's read.
pub fn a_refusal_that_will_not_change_is_the_transcript_test() {
  list.each(
    [
      remote_top.UnknownSpawner("laptop@host"),
      remote_top.TopLevelOff,
      remote_top.NotOffered(remote_top.OfferedProfile, "alt"),
      remote_top.CapReached(remote_top.MaxSessions, 3),
      remote_top.NotRelayed,
      remote_top.InvalidArgument("no"),
    ],
    fn(refusal) {
      assert refused(refusal) == TranscriptPage(relayed.Unsaid)
    },
  )
  assert ui_socket.chosen(Error(top_relay.NotConfigured("desk")))
    == TranscriptPage(relayed.Unsaid)
}

// An answer that does not read, or an exchange the box's size limits refuse, is
// not retried: each try would leave a feed on the box to lapse. It is the
// transcript, with the sentence for a box this daemon cannot talk to.
pub fn an_answer_that_does_not_read_is_the_transcript_not_a_retry_test() {
  list.each(
    [
      top_relay.InvalidPeer,
      top_relay.RequestTooLarge,
      top_relay.Unreadable("not an attach answer"),
    ],
    fn(failure) {
      assert ui_socket.chosen(Error(failure)) == TranscriptPage(relayed.Absent)
    },
  )
}
