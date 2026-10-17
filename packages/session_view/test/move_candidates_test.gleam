import gleam/list
import gleam/option.{None, Some}
import session_view/move_candidates.{
  Candidate, Eligible, Ineligible, NoReport, NotAccepting, NotReceiving,
  NotServing, Offer, Receiving, Reported, Silent, Unreachable, Unreported,
}

fn reported(serves) {
  Reported(receives: Receiving, serves:)
}

pub fn an_orchestrator_that_serves_the_executor_is_eligible_test() {
  assert move_candidates.choose(
      [Offer("bravo", reported(["box", "other"]))],
      Some("box"),
    )
    == [Candidate("bravo", Eligible)]
}

pub fn the_first_reason_that_applies_is_the_one_given_test() {
  let offers = [
    Offer("down", Silent),
    Offer("old", Unreported),
    Offer("closed", Reported(NotReceiving, ["box"])),
    Offer("elsewhere", reported(["other"])),
  ]
  assert move_candidates.choose(offers, Some("box"))
    == [
      Candidate("down", Ineligible(Unreachable)),
      Candidate("old", Ineligible(NoReport)),
      Candidate("closed", Ineligible(NotAccepting)),
      Candidate("elsewhere", Ineligible(NotServing)),
    ]
}

pub fn a_session_with_no_executor_has_no_destination_test() {
  assert move_candidates.choose([Offer("bravo", reported(["box"]))], None)
    == [Candidate("bravo", Ineligible(NotServing))]
}

pub fn only_eligible_destinations_are_listed_test() {
  let offers = [
    Offer("a", reported(["box"])),
    Offer("b", Silent),
    Offer("c", reported(["box"])),
  ]
  assert move_candidates.eligible(move_candidates.choose(offers, Some("box")))
    == ["a", "c"]
}

pub fn every_reason_has_its_own_words_test() {
  assert list.map(
      [Unreachable, NoReport, NotAccepting, NotServing],
      move_candidates.reason_words,
    )
    == [
      "is not reachable",
      "gave no report",
      "does not accept moved sessions",
      "does not serve this session's executor",
    ]
}
