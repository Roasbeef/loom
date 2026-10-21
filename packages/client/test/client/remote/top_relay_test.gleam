//// The laptop's end of a page that drives sessions on another orchestrator
//// (protocol-change/094): dialling on demand, the answers it decodes, what a
//// lost link does to each call, and the last page a view keeps for a box that
//// cannot be reached.
////
//// The ports are real orchestrator ports on this node, served by a `TopHost`
//// that counts and sometimes misbehaves, and the relay reaches them through an
//// injected dial, so a test can drop the link, make the box slow, or have it
//// answer garbage. The timing is shortened so that a resend window ends inside a
//// test. The production dial over the TLS distribution is covered where the
//// distribution is, in `distribution_test`.

import client/remote/address.{type Address}
import client/remote/orchestrator_port.{type Message}
import client/remote/top_relay.{
  type Failure, NotConfigured, OlderBuild, Refused, Silent, Unreachable,
  Unreadable,
}
import client/remote/top_view
import client/remote_escalation
import client/remote_mail
import client/remote_top
import core/json
import gleam/erlang/node
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import session_view/remote_transcript
import weft/actor

// A window and pauses short enough to end inside a test, and a wait for one
// answer shorter than the slowest thing a test makes the box do.
fn quick() -> top_relay.Timing {
  top_relay.Timing(
    retry_window_ms: 1200,
    create_ms: 150,
    call_ms: 150,
    first_pause_ms: 10,
    longest_pause_ms: 40,
  )
}

fn request() -> String {
  "0198c0de-0000-7000-8000-000000000001"
}

fn on_box() -> remote_top.Placement {
  remote_top.Workspace(executor: "exec", name: "repo")
}

// A counter a test reads and a function bumps from any process.
fn counter() -> Subject(Subject(Int)) {
  let assert Ok(started) =
    actor.new(0)
    |> actor.on_message(fn(count, reply: Subject(Int)) {
      process.send(reply, count)
      actor.continue(count + 1)
    })
    |> actor.start
    as "the counter starts"
  started.data
}

// The number of times the counter was asked, and the ask itself.
fn tick(counted: Subject(Subject(Int))) -> Int {
  process.call(counted, waiting: 1000, sending: fn(reply) { reply })
}

// Everything the box saw, in order.
fn log() -> Subject(String) {
  process.new_subject()
}

fn seen(entries: Subject(String)) -> List(String) {
  drain(entries, [])
}

fn drain(entries: Subject(String), found: List(String)) -> List(String) {
  case process.receive(entries, 0) {
    Ok(entry) -> drain(entries, [entry, ..found])
    Error(Nil) -> list.reverse(found)
  }
}

fn serving(top: orchestrator_port.TopHost) -> Address(Message) {
  let name = process.new_name("orchestrator_port")
  let assert Ok(_) =
    orchestrator_port.start_with_top(
      name,
      fn(_session) { Ok(orchestrator_port.NotOwned) },
      fn(_session, _command) { Error(orchestrator_port.peer_unserved) },
      fn(_session) { Error("not_found") },
      orchestrator_port.declining(),
      orchestrator_port.refusing_spawns(),
      orchestrator_port.refusing_children(),
      orchestrator_port.unheld,
      orchestrator_port.unreported(),
      top,
    )
    as "the port starts"
  address.Address(node: node.self(), name:)
}

// A dial that reaches `port` under the name "box" and says "gone" is
// unreachable. Any other name is not configured.
fn dial_to(port: Address(Message)) -> top_relay.Dial {
  fn(name) {
    case name {
      "box" -> Ok(port)
      "gone" -> Error(Unreachable)
      other -> Error(NotConfigured(other))
    }
  }
}

fn relay_to(top: orchestrator_port.TopHost) -> top_relay.Relay {
  top_relay.through(dial_to(serving(top)), quick())
}

// --- naming and dialling ------------------------------------------------------------------

pub fn a_name_the_daemon_does_not_list_is_a_definitive_failure_test() {
  let relay = relay_to(orchestrator_port.refusing_top())
  assert top_relay.stop(relay, "elsewhere", "s")
    == Error(NotConfigured("elsewhere"))
  assert top_relay.placements(relay, "elsewhere")
    == Error(NotConfigured("elsewhere"))
}

pub fn a_box_that_cannot_be_connected_to_fails_every_call_at_once_test() {
  let relay = relay_to(orchestrator_port.refusing_top())
  assert top_relay.placements(relay, "gone") == Error(Unreachable)
  assert top_relay.sessions(relay, "gone", "", 10) == Error(Unreachable)
  assert top_relay.stop(relay, "gone", "s") == Error(Unreachable)
  assert top_relay.create(relay, "gone", request(), on_box(), "alt", None)
    == Error(Unreachable)
  assert top_relay.send(relay, "gone", "s", "m", "hi") == Error(Unreachable)
}

// --- the answers --------------------------------------------------------------------------

pub fn placements_are_asked_on_every_call_and_decoded_test() {
  let asked = counter()
  let relay =
    relay_to(
      orchestrator_port.TopHost(
        ..orchestrator_port.refusing_top(),
        placements: fn(_node) {
          let count = tick(asked)
          Ok(remote_top.encode_offers(
            remote_top.Offers(..remote_top.no_offers(), profiles: [
              "alt-" <> int.to_string(count),
            ]),
          ))
        },
      ),
    )
  let assert Ok(first) = top_relay.placements(relay, "box")
  let assert Ok(second) = top_relay.placements(relay, "box")
  assert first.profiles == ["alt-0"]
  assert second.profiles == ["alt-1"]
}

pub fn an_answer_that_does_not_decode_is_unreadable_and_used_in_no_part_test() {
  let relay =
    relay_to(
      orchestrator_port.TopHost(
        ..orchestrator_port.refusing_top(),
        placements: fn(_node) { Ok(json.String("not offers")) },
        sessions: fn(_node, _after, _limit) { Ok(json.Object([])) },
        history: fn(_node, _session, _cursor, _limit) { Ok(json.Null) },
        send: fn(_node, _session, _id, _text) { Ok(json.String("landed?")) },
      ),
    )
  let assert Error(Unreadable(..)) = top_relay.placements(relay, "box")
  let assert Error(Unreadable(..)) = top_relay.sessions(relay, "box", "", 10)
  let assert Error(Unreadable(..)) = top_relay.history(relay, "box", "s", 0, 10)
  let assert Error(Unreadable(..)) =
    top_relay.send(relay, "box", "s", "m", "hi")
}

pub fn a_page_a_transcript_and_a_landing_decode_to_their_types_test() {
  let page =
    remote_top.SessionsPage(
      rows: [
        remote_top.Row(
          session_id: "0198c0de-0000-7000-8000-000000000009",
          request_id: request(),
          name: "work",
          placement: on_box(),
          activity: remote_top.Working,
          updated_at: 5,
          requests: [],
          more: 0,
          children: [],
        ),
      ],
      more: remote_top.Last,
    )
  let transcript =
    remote_transcript.Page(child: "main", entries: [], omitted: 0, next: None)
  let relay =
    relay_to(
      orchestrator_port.TopHost(
        ..orchestrator_port.refusing_top(),
        sessions: fn(_node, _after, _limit) { Ok(remote_top.encode_page(page)) },
        history: fn(_node, _session, _cursor, _limit) {
          Ok(remote_transcript.encode(transcript))
        },
        send: fn(_node, _session, _id, _text) {
          Ok(remote_mail.encode_landing(remote_mail.Admitted))
        },
      ),
    )
  assert top_relay.sessions(relay, "box", "", 10) == Ok(page)
  assert top_relay.history(relay, "box", "s", 0, 10) == Ok(transcript)
  assert top_relay.send(relay, "box", "s", "m", "hi")
    == Ok(remote_mail.Admitted)
  assert top_relay.session_for_request(page, request())
    == Some("0198c0de-0000-7000-8000-000000000009")
  assert top_relay.session_for_request(page, "another") == None
}

// --- a create, and what a lost link does to it ---------------------------------------------

pub fn a_create_the_box_answers_is_one_try_with_the_pages_request_id_test() {
  let entries = log()
  let relay =
    relay_to(
      orchestrator_port.TopHost(
        ..orchestrator_port.refusing_top(),
        create: fn(_node, request_id, _placement, profile, model) {
          process.send(
            entries,
            request_id <> " " <> profile <> " " <> string.inspect(model),
          )
          Ok("0198c0de-0000-7000-8000-00000000000a")
        },
      ),
    )
  assert top_relay.create(
      relay,
      "box",
      request(),
      on_box(),
      "alt",
      Some("fast"),
    )
    == Ok("0198c0de-0000-7000-8000-00000000000a")
  assert seen(entries) == [request() <> " alt Some(\"fast\")"]
}

pub fn a_definitive_refusal_is_not_sent_again_test() {
  let tries = counter()
  let relay =
    relay_to(
      orchestrator_port.TopHost(
        ..orchestrator_port.refusing_top(),
        create: fn(_node, _id, _placement, _profile, _model) {
          let _ = tick(tries)
          Error(remote_top.CapReached(cap: remote_top.MaxSessions, limit: 3))
        },
      ),
    )
  assert top_relay.create(relay, "box", request(), on_box(), "alt", None)
    == Error(
      Refused(remote_top.CapReached(cap: remote_top.MaxSessions, limit: 3)),
    )
  assert tick(tries) == 1
}

pub fn a_store_failure_is_sent_again_with_the_same_request_id_until_it_succeeds_test() {
  let entries = log()
  let tries = counter()
  let relay =
    relay_to(
      orchestrator_port.TopHost(
        ..orchestrator_port.refusing_top(),
        create: fn(_node, request_id, _placement, _profile, _model) {
          process.send(entries, request_id)
          case tick(tries) {
            0 | 1 -> Error(remote_top.StoreFailure("busy"))
            _ -> Ok("0198c0de-0000-7000-8000-00000000000a")
          }
        },
      ),
    )
  assert top_relay.create(relay, "box", request(), on_box(), "alt", None)
    == Ok("0198c0de-0000-7000-8000-00000000000a")
  assert seen(entries) == [request(), request(), request()]
}

pub fn a_lost_answer_is_sent_again_and_the_box_answers_the_same_session_test() {
  // The first two answers come after the page stopped waiting, as they do when
  // a link drops after the box did the work. The third is prompt.
  let tries = counter()
  let entries = log()
  let relay =
    relay_to(
      orchestrator_port.TopHost(
        ..orchestrator_port.refusing_top(),
        create: fn(_node, request_id, _placement, _profile, _model) {
          process.send(entries, request_id)
          case tick(tries) {
            0 | 1 -> {
              process.sleep(400)
              Ok("0198c0de-0000-7000-8000-00000000000a")
            }
            _ -> Ok("0198c0de-0000-7000-8000-00000000000a")
          }
        },
      ),
    )
  assert top_relay.create(relay, "box", request(), on_box(), "alt", None)
    == Ok("0198c0de-0000-7000-8000-00000000000a")
  let sent = seen(entries)
  assert list.length(sent) >= 3
  assert list.all(sent, fn(id) { id == request() })
}

pub fn a_box_that_never_answers_ends_the_window_with_the_outcome_unknown_test() {
  let relay =
    relay_to(
      orchestrator_port.TopHost(
        ..orchestrator_port.refusing_top(),
        create: fn(_node, _id, _placement, _profile, _model) {
          process.sleep(800)
          Ok("0198c0de-0000-7000-8000-00000000000a")
        },
      ),
    )
  let assert Error(Silent) =
    top_relay.create(relay, "box", request(), on_box(), "alt", None)
  assert top_relay.outcome_unknown(Silent)
}

pub fn a_link_that_drops_after_the_first_send_is_waited_for_not_given_up_on_test() {
  // The first dial connects, the box does not answer in time, then the link is
  // down for two dials, then it is back. A create is never queued when the link
  // is already down, but one that was sent is not abandoned when it drops.
  let dials = counter()
  let tries = counter()
  let port =
    serving(
      orchestrator_port.TopHost(
        ..orchestrator_port.refusing_top(),
        create: fn(_node, _id, _placement, _profile, _model) {
          case tick(tries) {
            0 -> {
              process.sleep(600)
              Ok("0198c0de-0000-7000-8000-00000000000a")
            }
            _ -> Ok("0198c0de-0000-7000-8000-00000000000a")
          }
        },
      ),
    )
  let flaky = fn(name) {
    case tick(dials) {
      0 -> Ok(port)
      1 | 2 -> Error(Unreachable)
      _ -> dial_to(port)(name)
    }
  }
  let relay = top_relay.through(flaky, quick())
  assert top_relay.create(relay, "box", request(), on_box(), "alt", None)
    == Ok("0198c0de-0000-7000-8000-00000000000a")
}

pub fn a_window_that_ends_on_a_downed_link_is_silence_not_unreachable_test() {
  let dials = counter()
  let port =
    serving(
      orchestrator_port.TopHost(
        ..orchestrator_port.refusing_top(),
        create: fn(_node, _id, _placement, _profile, _model) {
          process.sleep(600)
          Ok("0198c0de-0000-7000-8000-00000000000a")
        },
      ),
    )
  let drops = fn(_name) {
    case tick(dials) {
      0 -> Ok(port)
      _ -> Error(Unreachable)
    }
  }
  let relay = top_relay.through(drops, quick())

  // The create may have happened, so the page is told the outcome is unknown.
  assert top_relay.create(relay, "box", request(), on_box(), "alt", None)
    == Error(Silent)
}

pub fn a_port_that_is_gone_once_connected_is_an_older_build_test() {
  let gone =
    address.Address(
      node: node.self(),
      name: process.new_name("orchestrator_port_absent"),
    )
  let relay = top_relay.through(fn(_name) { Ok(gone) }, quick())
  assert top_relay.placements(relay, "box") == Error(OlderBuild)
  assert top_relay.stop(relay, "box", "s") == Error(OlderBuild)
  assert top_relay.create(relay, "box", request(), on_box(), "alt", None)
    == Error(OlderBuild)
}

// --- a message ---------------------------------------------------------------------------------

pub fn a_message_is_sent_again_with_the_same_id_and_lands_once_test() {
  let entries = log()
  let tries = counter()
  let relay =
    relay_to(
      orchestrator_port.TopHost(
        ..orchestrator_port.refusing_top(),
        send: fn(_node, session, message_id, text) {
          process.send(entries, session <> " " <> message_id <> " " <> text)
          case tick(tries) {
            0 -> {
              process.sleep(400)
              Ok(remote_mail.encode_landing(remote_mail.Admitted))
            }
            _ -> Ok(remote_mail.encode_landing(remote_mail.Admitted))
          }
        },
      ),
    )
  assert top_relay.send(relay, "box", "s1", "m1", "build it")
    == Ok(remote_mail.Admitted)
  let sent = seen(entries)
  assert list.length(sent) >= 2
  assert list.all(sent, fn(line) { line == "s1 m1 build it" })
}

// --- the single-try calls --------------------------------------------------------------------------

pub fn a_decision_a_stop_and_an_archive_are_asked_once_test() {
  let tries = counter()
  let slow = fn() {
    let _ = tick(tries)
    process.sleep(600)
  }
  let relay =
    relay_to(
      orchestrator_port.TopHost(
        ..orchestrator_port.refusing_top(),
        stop: fn(_node, _session) {
          slow()
          Ok(Nil)
        },
        archive: fn(_node, _session) {
          slow()
          Ok(Nil)
        },
        resolve: fn(_node, _session, _id, _decision, _seq, _decider) {
          slow()
          Ok(remote_escalation.Forgotten)
        },
      ),
    )
  assert top_relay.stop(relay, "box", "s") == Error(Silent)
  assert top_relay.archive(relay, "box", "s") == Error(Silent)
  assert top_relay.resolve(
      relay,
      "box",
      "s",
      "policy-1",
      remote_escalation.Deny,
      1,
      remote_escalation.Decider(principal: "ab", name: "Ola"),
    )
    == Error(Silent)

  // One try each, and the window of a create was not applied to them.
  assert tick(tries) == 3
}

pub fn the_boxs_answers_to_a_decision_reach_the_page_unchanged_test() {
  let relay =
    relay_to(
      orchestrator_port.TopHost(
        ..orchestrator_port.refusing_top(),
        resolve: fn(_node, _session, _id, _decision, _seq, _decider) {
          Ok(remote_escalation.Refused(
            reason: remote_escalation.outside_the_ceiling,
          ))
        },
      ),
    )
  assert top_relay.resolve(
      relay,
      "box",
      "s",
      "policy-1",
      remote_escalation.Deny,
      1,
      remote_escalation.Decider(principal: "ab", name: "Ola"),
    )
    == Ok(remote_escalation.Refused(
      reason: remote_escalation.outside_the_ceiling,
    ))
}

pub fn every_failure_has_words_for_the_page_test() {
  let words = fn(failure: Failure) { top_relay.describe(failure) }
  assert words(NotConfigured("x"))
    == "x is not one of this daemon's orchestrators"
  assert words(Unreachable) == "the orchestrator is not reachable"
  assert string.contains(words(Silent), "not known whether it happened")
  assert words(OlderBuild) == "the orchestrator runs an older Loom"
  assert words(Refused(remote_top.NotRelayed))
    == "that session was not started by your orchestrator"
  assert string.contains(words(Unreadable("bad")), "bad")
  assert !top_relay.outcome_unknown(Unreachable)
  assert !top_relay.outcome_unknown(OlderBuild)
}

// --- every page ----------------------------------------------------------------------------------------

fn row(n: Int) -> remote_top.Row {
  remote_top.Row(
    session_id: "0198c0de-0000-7000-8000-" <> int.to_string(100_000_000_000 - n),
    request_id: "r" <> int.to_string(n),
    name: "s",
    placement: on_box(),
    activity: remote_top.Idle,
    updated_at: n,
    requests: [],
    more: 0,
    children: [],
  )
}

pub fn every_page_is_read_after_the_last_row_of_the_one_before_test() {
  let afters = log()
  let all = list.map([1, 2, 3, 4, 5], row)
  let relay =
    relay_to(
      orchestrator_port.TopHost(
        ..orchestrator_port.refusing_top(),
        sessions: fn(_node, after, _limit) {
          process.send(afters, after)
          let page = case after {
            "" -> remote_top.SessionsPage(list.take(all, 2), remote_top.Further)
            _ ->
              case list.drop_while(all, fn(r) { r.session_id != after }) {
                [_, ..rest] ->
                  case list.length(rest) > 2 {
                    True ->
                      remote_top.SessionsPage(
                        list.take(rest, 2),
                        remote_top.Further,
                      )
                    False -> remote_top.SessionsPage(rest, remote_top.Last)
                  }
                [] -> remote_top.empty_page()
              }
          }
          Ok(remote_top.encode_page(page))
        },
      ),
    )
  assert top_relay.all_sessions(relay, "box") == Ok(all)
  assert seen(afters)
    == [
      "",
      { row(2) }.session_id,
      { row(4) }.session_id,
    ]
}

pub fn a_failed_page_ends_the_read_and_returns_none_of_the_pages_before_it_test() {
  let tries = counter()
  let relay =
    relay_to(
      orchestrator_port.TopHost(
        ..orchestrator_port.refusing_top(),
        sessions: fn(_node, _after, _limit) {
          case tick(tries) {
            0 ->
              Ok(
                remote_top.encode_page(remote_top.SessionsPage(
                  [row(1)],
                  remote_top.Further,
                )),
              )
            _ -> Error(remote_top.StoreFailure("busy"))
          }
        },
      ),
    )
  assert top_relay.all_sessions(relay, "box")
    == Error(Refused(remote_top.StoreFailure("busy")))
}

pub fn a_box_that_always_says_more_is_read_for_at_most_the_page_bound_test() {
  let tries = counter()
  let relay =
    relay_to(
      orchestrator_port.TopHost(
        ..orchestrator_port.refusing_top(),
        sessions: fn(_node, _after, _limit) {
          let n = tick(tries)
          Ok(
            remote_top.encode_page(remote_top.SessionsPage(
              [row(n)],
              remote_top.Further,
            )),
          )
        },
      ),
    )
  let assert Ok(read) = top_relay.all_sessions(relay, "box")
  assert list.length(read) == top_relay.max_pages
}

// --- the view a page keeps between asks ---------------------------------------------------------------------------

fn clock_at(times: List(Int)) -> fn() -> Int {
  let reads = counter()
  fn() {
    let index = tick(reads)
    case list.drop(times, index) {
      [now, ..] -> now
      [] -> 0
    }
  }
}

pub fn a_view_keeps_the_last_good_rows_and_ages_them_through_a_failure_test() {
  let tries = counter()
  let relay =
    relay_to(
      orchestrator_port.TopHost(
        ..orchestrator_port.refusing_top(),
        sessions: fn(_node, _after, _limit) {
          case tick(tries) {
            0 ->
              Ok(
                remote_top.encode_page(remote_top.SessionsPage(
                  [row(1)],
                  remote_top.Last,
                )),
              )
            1 | 2 -> Error(remote_top.StoreFailure("busy"))
            _ ->
              Ok(
                remote_top.encode_page(remote_top.SessionsPage(
                  [row(2)],
                  remote_top.Last,
                )),
              )
          }
        },
      ),
    )
  let assert Ok(view) = top_view.start()

  // Before any ask the view has nothing and nothing is known to be wrong.
  assert top_view.latest(view)
    == top_view.Snapshot(rows: [], seen_ms: None, standing: top_view.Current)

  // A good ask: the rows and when they were read.
  let now = clock_at([1000, 2000, 3000, 4000])
  assert top_view.refresh(view, relay, "box", now)
    == top_view.Snapshot(
      rows: [row(1)],
      seen_ms: Some(1000),
      standing: top_view.Current,
    )

  // A failed ask keeps the rows, marks them stale, and remembers when the
  // failures began.
  let after_one = top_view.refresh(view, relay, "box", now)
  assert after_one.rows == [row(1)]
  assert after_one.seen_ms == Some(1000)
  assert after_one.standing
    == top_view.Stale(
      why: Refused(remote_top.StoreFailure("busy")),
      since_ms: 2000,
    )

  // A second failure keeps the first one's time, so the age is the box's
  // time out of reach and not the last failure's.
  let after_two = top_view.refresh(view, relay, "box", now)
  assert after_two.standing
    == top_view.Stale(
      why: Refused(remote_top.StoreFailure("busy")),
      since_ms: 2000,
    )

  // The box answers again: the rows are replaced and the mark is cleared.
  assert top_view.refresh(view, relay, "box", now)
    == top_view.Snapshot(
      rows: [row(2)],
      seen_ms: Some(4000),
      standing: top_view.Current,
    )
}

pub fn a_view_with_an_unreachable_box_has_no_rows_and_says_why_test() {
  let relay = relay_to(orchestrator_port.refusing_top())
  let assert Ok(view) = top_view.start()
  let snapshot = top_view.refresh(view, relay, "gone", fn() { 7 })
  assert snapshot.rows == []
  assert snapshot.seen_ms == None
  assert snapshot.standing == top_view.Stale(why: Unreachable, since_ms: 7)
}
