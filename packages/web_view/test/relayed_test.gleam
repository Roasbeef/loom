//// The relayed session's vocabulary (protocol-change/094): the words a session's
//// activity and a read's age are drawn as, and how a press on a request is
//// found among the requests the page holds.
////
//// The age is the one place a figure is computed, so it is checked over
//// generated ages with a fixed seed: whatever the age, the words end in a unit
//// and never carry a sign or a fraction.

import gleam/string
import qcheck
import web_view/relayed

const seed = 20_261_021

fn need(escalation: String, seq: Int) -> relayed.Need {
  relayed.Need(
    escalation:,
    seq:,
    strand: "main",
    tool: "bash",
    question: "Allow this command?",
    action: "go test ./...",
    authority: ["Network access: any host"],
    outside: [],
    ability: relayed.Decidable,
    remember: relayed.OnceOnly,
  )
}

pub fn every_activity_has_its_own_word_test() {
  assert relayed.activity_words(relayed.NeedsYou) == "needs you"
  assert relayed.activity_words(relayed.Working) == "working"
  assert relayed.activity_words(relayed.Idle) == "idle"
}

pub fn an_age_is_the_largest_whole_unit_test() {
  assert relayed.age_words(999) == "just now"
  assert relayed.age_words(1000) == "1s ago"
  assert relayed.age_words(59_999) == "59s ago"
  assert relayed.age_words(60_000) == "1m ago"
  assert relayed.age_words(3_599_999) == "59m ago"
  assert relayed.age_words(3_600_000) == "1h ago"
  assert relayed.age_words(86_399_999) == "23h ago"
  assert relayed.age_words(86_400_000) == "1d ago"
}

// A clock that moved backwards, or a read stamped in the future, is not an
// age the page can count from, so it says the read is current.
pub fn a_time_in_the_future_is_just_now_test() {
  assert relayed.age_words(-1) == "just now"
  assert relayed.age_words(-86_400_000) == "just now"
}

pub fn an_age_always_ends_in_a_unit_or_is_current_test() {
  let config =
    qcheck.default_config()
    |> qcheck.with_test_count(500)
    |> qcheck.with_seed(qcheck.seed(seed))

  qcheck.run(
    config,
    qcheck.bounded_int(from: -1_000_000, to: 9_000_000_000),
    fn(age) {
      let words = relayed.age_words(age)
      assert words == "just now" || string.ends_with(words, " ago")
      assert !string.contains(words, "-")
      assert !string.contains(words, ".")
    },
  )
}

pub fn a_press_finds_the_request_it_was_drawn_with_test() {
  let needs = [need("a", 3), need("b", 7)]

  assert relayed.find_need(needs, "b", 7) == Ok(need("b", 7))
  assert relayed.find_need(needs, "a", 3) == Ok(need("a", 3))
}

// A question that was revised since the card was drawn has a new revision,
// and a press for the old one finds nothing: the person decides again from what
// the page now shows.
pub fn a_press_for_a_revised_or_unknown_request_finds_nothing_test() {
  let needs = [need("a", 3)]

  assert relayed.find_need(needs, "a", 4) == Error(Nil)
  assert relayed.find_need(needs, "z", 3) == Error(Nil)
  assert relayed.find_need([], "a", 3) == Error(Nil)
}
