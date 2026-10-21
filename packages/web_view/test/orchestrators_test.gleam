//// What a page holds of the orchestrators it relays for
//// (`web_view/orchestrators`, protocol-change/094).
////
//// The state is kept for each orchestrator on its own, so these tests pin that
//// an answer changes only its machine; that an offers answer a newer read
//// overtook is dropped and offers already held stay while they are refreshed;
//// that a listing read that is out is never started twice; that silence keeps the
//// last rows and the time of the last good read; and the order the sidebar draws
//// rows in, which is checked over generated rows with a fixed seed.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import qcheck
import web_view/listing
import web_view/orchestrators.{type Listed, type Machine, Listed}
import web_view/placements
import web_view/relayed

const seed = 20_261_022

fn row(id: String, activity: relayed.Activity, updated_ms: Int) -> Listed {
  Listed(
    session: id,
    name: id,
    code: listing.Folder("/w"),
    activity:,
    updated_ms:,
  )
}

fn offers() -> orchestrators.Offers {
  orchestrators.Offers(
    folders: ["/w"],
    cards: placements.listed([], []),
    profiles: ["p"],
    models: [],
  )
}

fn only(machines: List(Machine), name: String) -> Machine {
  let assert Ok(found) = orchestrators.find(machines, name)
    as "the machine exists"
  found
}

// One machine for each configured name, in order, with nothing known.
pub fn a_machine_is_made_for_each_configured_orchestrator_test() {
  let machines = orchestrators.new(["box", "gpu"])

  assert list.map(machines, fn(each) { each.orchestrator }) == ["box", "gpu"]
  assert list.all(machines, fn(each) {
    each.rows == [] && each.reach == orchestrators.Unasked
  })
  assert orchestrators.new([]) == []
}

// An offers read is numbered. Its answer lands only if it is the newest, so a
// slow older answer cannot replace a newer one, and a name the page does not hold
// is not asked.
pub fn an_offers_answer_lands_only_for_the_newest_read_test() {
  let machines = orchestrators.new(["box"])
  let #(machines, first) = orchestrators.ask_offers(machines, "box")
  assert first == Ok(1)
  let #(machines, second) = orchestrators.ask_offers(machines, "box")
  assert second == Ok(2)

  let late =
    orchestrators.offers_heard(
      machines,
      "box",
      1,
      orchestrators.Offered(offers()),
    )
  assert orchestrators.standing(late, "box") == orchestrators.Asking

  let current =
    orchestrators.offers_heard(
      machines,
      "box",
      2,
      orchestrators.Offered(offers()),
    )
  assert orchestrators.standing(current, "box")
    == orchestrators.Offering(offers())

  let #(unchanged, none) = orchestrators.ask_offers(machines, "nowhere")
  assert unchanged == machines
  assert none == Error(Nil)
  assert orchestrators.standing(machines, "nowhere")
    == orchestrators.Refusing("not configured")
}

// Offers already held stay while a newer read is out, so the list does not empty
// while it is refreshed, and a failed read replaces them with its reason.
pub fn held_offers_stay_while_they_are_refreshed_test() {
  let #(machines, _) =
    orchestrators.ask_offers(orchestrators.new(["box"]), "box")
  let machines =
    orchestrators.offers_heard(
      machines,
      "box",
      1,
      orchestrators.Offered(offers()),
    )
  let #(machines, serial) = orchestrators.ask_offers(machines, "box")

  assert orchestrators.standing(machines, "box")
    == orchestrators.Offering(offers())

  let assert Ok(serial) = serial as "the read was numbered"
  let machines =
    orchestrators.offers_heard(
      machines,
      "box",
      serial,
      orchestrators.Withheld("down"),
    )
  assert orchestrators.standing(machines, "box")
    == orchestrators.Refusing("down")
}

// An answer changes its own machine and no other.
pub fn an_answer_changes_only_its_machine_test() {
  let machines = orchestrators.new(["box", "gpu"])
  let #(machines, serial) = orchestrators.ask_offers(machines, "box")
  let assert Ok(serial) = serial as "the read was numbered"
  let heard =
    orchestrators.offers_heard(
      machines,
      "box",
      serial,
      orchestrators.Withheld("down"),
    )

  assert only(heard, "gpu") == only(machines, "gpu")

  let listed =
    orchestrators.listing_heard(
      heard,
      "gpu",
      orchestrators.Heard([row("a", relayed.Idle, 1)]),
      10,
    )
  assert only(listed, "box") == only(heard, "box")
}

// A listing read that is out is not started again, and a machine that answered, in
// either way, can be asked again.
pub fn a_listing_read_that_is_out_is_not_started_twice_test() {
  let #(machines, owed) =
    orchestrators.begin_listing(orchestrators.new(["box", "gpu"]))
  assert owed == ["box", "gpu"]

  let #(machines, again) = orchestrators.begin_listing(machines)
  assert again == []

  let machines =
    orchestrators.listing_heard(
      machines,
      "gpu",
      orchestrators.Missed("down"),
      5,
    )
  let #(_, after) = orchestrators.begin_listing(machines)
  assert after == ["gpu"]

  assert orchestrators.listing_heard(
      machines,
      "nowhere",
      orchestrators.Missed("x"),
      5,
    )
    == machines
}

// A list replaces the rows and stamps the time. Silence keeps the rows and the time
// of the last list that answered, and a box never heard from has no time.
pub fn silence_keeps_the_last_rows_and_the_last_good_time_test() {
  let rows = [row("a", relayed.Working, 1)]
  let machines = orchestrators.new(["box"])

  let never =
    orchestrators.listing_heard(
      machines,
      "box",
      orchestrators.Missed("down"),
      3,
    )
  assert only(never, "box").reach == orchestrators.Silent("down", None)
  assert only(never, "box").rows == []

  let heard =
    orchestrators.listing_heard(machines, "box", orchestrators.Heard(rows), 10)
  assert only(heard, "box").reach == orchestrators.Fresh(10)
  assert only(heard, "box").rows == rows

  let silent =
    orchestrators.listing_heard(heard, "box", orchestrators.Missed("down"), 20)
  assert only(silent, "box").reach == orchestrators.Silent("down", Some(10))
  assert only(silent, "box").rows == rows

  // A second silence keeps the same last good time.
  let again =
    orchestrators.listing_heard(silent, "box", orchestrators.Missed("down"), 30)
  assert only(again, "box").reach == orchestrators.Silent("down", Some(10))
}

// The line under a stale heading: nothing while current or before a first read, the
// name alone for a box never heard from, and how long ago otherwise.
pub fn the_reach_words_say_how_long_ago_test() {
  assert orchestrators.reach_words("box", orchestrators.Unasked, 9) == ""
  assert orchestrators.reach_words("box", orchestrators.Fresh(1), 9) == ""
  assert orchestrators.reach_words("box", orchestrators.Silent("down", None), 9)
    == "box not reachable"
  assert orchestrators.reach_words(
      "box",
      orchestrators.Silent("down", Some(0)),
      125_000,
    )
    == "box not reachable, seen 2m ago"
}

// A press is honoured for a row the page holds on the machine it names and no
// other.
pub fn only_a_held_row_can_be_named_test() {
  let machines =
    orchestrators.listing_heard(
      orchestrators.new(["box", "gpu"]),
      "box",
      orchestrators.Heard([row("a", relayed.Idle, 1)]),
      1,
    )

  assert orchestrators.held_row(machines, "box", "a")
    == Ok(row("a", relayed.Idle, 1))
  assert orchestrators.held_row(machines, "gpu", "a") == Error(Nil)
  assert orchestrators.held_row(machines, "box", "b") == Error(Nil)
  assert orchestrators.held_row(machines, "nowhere", "a") == Error(Nil)
}

// What the Agent chip says a box is doing.
pub fn the_busy_words_count_what_needs_the_owner_first_test() {
  assert orchestrators.busy_words([]) == "no sessions yet"
  assert orchestrators.busy_words([
      row("a", relayed.Idle, 1),
      row("b", relayed.Idle, 1),
    ])
    == "2 idle"
  assert orchestrators.busy_words([row("a", relayed.Working, 1)]) == "1 working"
  assert orchestrators.busy_words([row("a", relayed.NeedsYou, 1)])
    == "1 needs you"
  assert orchestrators.busy_words([
      row("a", relayed.NeedsYou, 1),
      row("b", relayed.Working, 1),
      row("c", relayed.Working, 1),
    ])
    == "2 working, 1 needs you"
}

// A session with no name is drawn by the first eight characters of its identity,
// and one with markup in its name keeps it, to be drawn as text.
pub fn a_nameless_session_is_drawn_by_its_identity_test() {
  assert orchestrators.label(
      Listed(..row("0198c0de-0000", relayed.Idle, 1), name: " "),
    )
    == "0198c0de"
  assert orchestrators.label(
      Listed(..row("a", relayed.Idle, 1), name: "<b>x</b> & \"q\""),
    )
    == "<b>x</b> & \"q\""
}

fn rank(activity: relayed.Activity) -> Int {
  case activity {
    relayed.NeedsYou -> 0
    relayed.Working -> 1
    relayed.Idle -> 2
  }
}

fn activity() -> qcheck.Generator(relayed.Activity) {
  qcheck.from_generators(qcheck.return(relayed.NeedsYou), [
    qcheck.return(relayed.Working),
    qcheck.return(relayed.Idle),
  ])
}

// Whatever rows a box lists, the sidebar draws every one of them once, with the
// sessions that need the person first, then those working, then the quiet ones,
// and the newest first within each.
pub fn the_order_never_loses_a_row_and_puts_needs_first_test() {
  let config =
    qcheck.default_config()
    |> qcheck.with_test_count(300)
    |> qcheck.with_seed(qcheck.seed(seed))
  let generated =
    qcheck.generic_list(
      qcheck.map2(
        activity(),
        qcheck.bounded_int(from: 0, to: 50),
        fn(activity, updated) { row(int.to_string(updated), activity, updated) },
      ),
      qcheck.bounded_int(from: 0, to: 12),
    )

  qcheck.run(config, generated, fn(rows) {
    let ordered = orchestrators.ordered(rows)
    let ranks = list.map(ordered, fn(each) { rank(each.activity) })

    assert list.length(ordered) == list.length(rows)
    assert list.sort(ranks, int.compare) == ranks
    assert list.all(list.window_by_2(ordered), fn(pair) {
      let #(a, b) = pair
      rank(a.activity) != rank(b.activity) || a.updated_ms >= b.updated_ms
    })
  })
}
