//// The ledger codec: every event reads back as written, and no text that is
//// not an event decodes.

import gleam/list
import gleam/option.{None}
import gleam/string
import project/codec
import project/event
import project/model.{CommitId, TicketId, TriggerId}
import qcheck
import support/gen

fn config() -> qcheck.Config {
  qcheck.default_config()
  |> qcheck.with_seed(qcheck.seed(20_261_102))
  |> qcheck.with_test_count(400)
}

pub fn every_event_reads_back_as_written_test() {
  use incoming <- qcheck.run(config(), gen.event())
  assert codec.decode(codec.encode(incoming)) == Ok(incoming)
}

pub fn arbitrary_text_is_malformed_not_a_crash_test() {
  use text <- qcheck.run(config(), gen.text())
  assert codec.decode(text) == Error(codec.Malformed)
}

pub fn a_truncated_event_is_malformed_test() {
  use incoming <- qcheck.run(config(), gen.event())
  let text = codec.encode(incoming)
  let length = string.length(text)
  assert codec.decode(string.slice(text, 0, length / 2))
    == Error(codec.Malformed)
  assert codec.decode(string.slice(text, 0, length - 1))
    == Error(codec.Malformed)
}

pub fn json_of_the_wrong_shape_is_malformed_test() {
  let cases = [
    "{}",
    "[]",
    "null",
    "0",
    "\"trigger_arrived\"",
    "{\"t\":\"nope\"}",
    "{\"t\":5}",
    "{\"t\":\"assignment_live\"}",
    "{\"t\":\"assignment_live\",\"ticket\":\"x\",\"seq\":\"one\"}",
    "{\"t\":\"mode_set\",\"source\":\"s\",\"rule\":\"r\",\"mode\":\"bogus\"}",
    "{\"t\":\"reported\",\"ticket\":\"x\",\"seq\":1,\"report\":{\"kind\":\"ready\"},\"head\":null}",
    "{\"t\":\"concluded\",\"ticket\":\"x\",\"outcome\":\"ready\"}",
    "{\"t\":\"check_finished\",\"ticket\":\"x\",\"check\":{\"result\":\"ok\",\"commit\":\"a\",\"digest\":\"d\"}}",
    "{\"t\":\"check_finished\",\"ticket\":\"x\",\"check\":{\"result\":\"passed\",\"commit\":\"a\",\"digest\":\"d\"}}",
  ]
  list.each(cases, fn(text) {
    assert codec.decode(text) == Error(codec.Malformed)
  })
}

pub fn a_missing_field_is_malformed_test() {
  use incoming <- qcheck.run(config(), gen.event())
  let text = codec.encode(incoming)
  case string.contains(text, "\"t\":") {
    False -> Nil
    True -> {
      let broken = string.replace(text, "\"t\":", "\"u\":")
      assert codec.decode(broken) == Error(codec.Malformed)
    }
  }
}

pub fn the_wire_form_of_one_event_is_pinned_test() {
  let text =
    codec.encode(event.Reported(
      TicketId("t-c1"),
      2,
      model.Waiting(model.Asking(3)),
      model.Head(CommitId("abc"), model.ProtectedPathsTouched),
    ))
  assert text
    == "{\"t\":\"reported\",\"ticket\":\"t-c1\",\"seq\":2,\"report\":{\"kind\":\"waiting\",\"question\":3},\"head\":{\"commit\":\"abc\",\"paths\":\"touched\"}}"
  assert codec.encode(event.RoutedIgnore(TriggerId("x")))
    == "{\"t\":\"routed_ignore\",\"trigger\":\"x\"}"
  assert codec.encode(event.WorkerFailed(TicketId("t-c1"), 1, "no clone"))
    == "{\"t\":\"worker_failed\",\"ticket\":\"t-c1\",\"seq\":1,\"why\":\"no clone\"}"
  assert codec.encode(event.PersonClosed(
      TicketId("t-c1"),
      model.PrincipalId("owner"),
    ))
    == "{\"t\":\"person_closed\",\"ticket\":\"t-c1\",\"by\":\"owner\"}"
}

pub fn the_wire_form_of_the_host_facts_is_pinned_test() {
  assert codec.encode(event.HeadObserved(
      TicketId("t-c1"),
      1,
      model.Head(CommitId("abc"), model.ProtectedPathsUntouched),
    ))
    == "{\"t\":\"head_observed\",\"ticket\":\"t-c1\",\"seq\":1,\"head\":{\"commit\":\"abc\",\"paths\":\"untouched\"}}"
  assert codec.encode(event.ReviewRequested(
      TicketId("t-c1"),
      CommitId("abc"),
      model.PublishingOff,
    ))
    == "{\"t\":\"review_requested\",\"ticket\":\"t-c1\",\"commit\":\"abc\",\"reason\":{\"k\":\"publishing_off\"}}"
  assert codec.encode(event.ReviewRequested(
      TicketId("t-c1"),
      CommitId("abc"),
      model.intake_refused("fsck"),
    ))
    == "{\"t\":\"review_requested\",\"ticket\":\"t-c1\",\"commit\":\"abc\",\"reason\":{\"k\":\"intake_refused\",\"why\":\"fsck\"}}"
}

pub fn a_review_reason_longer_than_the_cap_is_cut_on_the_way_in_test() {
  let long = string.repeat("w", 500)
  let text =
    "{\"t\":\"review_requested\",\"ticket\":\"x\",\"commit\":\"a\",\"reason\":{\"k\":\"unavailable\",\"why\":\""
    <> long
    <> "\"}}"
  assert codec.decode(text)
    == Ok(event.ReviewRequested(
      TicketId("x"),
      CommitId("a"),
      model.PublishUnavailable(string.repeat("w", model.max_reason_chars)),
    ))
  assert codec.decode(
      "{\"t\":\"review_requested\",\"ticket\":\"x\",\"commit\":\"a\",\"reason\":{\"k\":\"other\"}}",
    )
    == Error(codec.Malformed)
}

pub fn a_title_longer_than_the_cap_is_cut_on_the_way_in_test() {
  let long = string.repeat("a", 500)
  let text =
    "{\"t\":\"routed\",\"routing\":{\"trigger\":\"x\",\"kind\":{\"k\":\"accept\",\"title\":\""
    <> long
    <> "\"},\"holds\":[],\"related\":[],\"prior_hand_back\":null}}"
  assert codec.decode(text)
    == Ok(
      event.Routed(model.Routing(
        trigger: TriggerId("x"),
        kind: model.Accept(model.title(string.repeat("a", 80))),
        holds: [],
        related: [],
        prior_hand_back: None,
      )),
    )
}
