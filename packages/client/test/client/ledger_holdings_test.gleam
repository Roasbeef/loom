//// What the orchestrators of a deployment hold, as the operator's `revoke`
//// asks it (protocol-change/086, phase 2). The fan-out is exercised with a
//// scripted asker over fixture ledgers, and the daemon's side of the question is
//// exercised over a real registry holding real registrations, so the counts the
//// operator reads are the counts the catalogue has.

import client/daemon/manager
import client/distribution_plan.{Executor, Orchestrator}
import client/executors
import client/ledger_holdings.{Answer}
import client/membership_entry.{Upsert}
import client/membership_ledger
import client/node_report
import client/remote/orchestrator_port.{type Held, Held, Placed}
import client/roster
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import storage/catalogue
import support/held_catalogue
import support/membership_fixture as fixture
import support/membership_log as log

// --- who is asked --------------------------------------------------------------

fn orchestrator(name: String, links: List(String)) {
  membership_entry.Member(..fixture.member(name, links), role: Orchestrator)
}

// A hub linked to a laptop and a box, a stray orchestrator the hub is not
// linked to, and a desk that was revoked.
fn estate() -> membership_ledger.Ledger {
  let estate =
    log.genesis()
    |> log.must_push(Upsert(orchestrator("hub", [])))
    |> log.must_push(Upsert(orchestrator("laptop", ["hub"])))
    |> log.must_push(Upsert(orchestrator("stray", [])))
    |> log.must_push(Upsert(orchestrator("desk", ["hub"])))
    |> log.must_push(Upsert(
      membership_entry.Member(..fixture.member("box", ["hub"]), role: Executor),
    ))
    |> log.revoke("desk")
  estate.ledger
}

const hub = "loom@hub.example.net"

pub fn an_orchestrator_asks_itself_and_the_orchestrators_it_is_linked_to_test() {
  assert ledger_holdings.targets(estate(), hub)
    == [
      #("hub", hub),
      #("laptop", "loom@laptop.example.net"),
    ]
}

pub fn an_executor_asks_the_orchestrators_that_use_it_and_not_itself_test() {
  assert ledger_holdings.targets(estate(), "loom@box.example.net")
    == [#("hub", hub)]
}

pub fn a_node_the_ledger_does_not_list_asks_nobody_test() {
  assert ledger_holdings.targets(estate(), "loom@ghost.example.net") == []
  assert ledger_holdings.targets(estate(), "loom@desk.example.net") == []
}

// --- the fan-out -----------------------------------------------------------------

pub fn each_target_is_asked_once_and_silence_is_not_nothing_test() {
  let ask = fn(node) {
    case node {
      "loom@laptop.example.net" -> Error(Nil)
      _ -> Ok(Held(sessions: 2, placed: []))
    }
  }
  assert ledger_holdings.collect(estate(), hub, ask)
    == [
      Answer("hub", hub, Some(Held(sessions: 2, placed: []))),
      Answer("laptop", "loom@laptop.example.net", None),
    ]
}

pub fn an_ask_that_crashes_reads_as_silence_test() {
  let ask = fn(node) {
    case node {
      "loom@laptop.example.net" -> panic as "the asker failed"
      _ -> Ok(Held(sessions: 0, placed: []))
    }
  }
  let answers = ledger_holdings.collect(estate(), hub, ask)
  assert list.map(answers, fn(answer) { answer.held })
    == [Some(Held(sessions: 0, placed: [])), None]
}

pub fn the_silent_asker_leaves_every_orchestrator_unanswered_test() {
  let answers = ledger_holdings.collect(estate(), hub, ledger_holdings.silent)
  assert list.all(answers, fn(answer) { answer.held == None })
  assert list.length(answers) == 2
}

// --- the catalogue's side ---------------------------------------------------------

pub fn the_catalogue_counts_its_sessions_and_where_they_are_placed_test() {
  let #(registry, store, directory) = held_catalogue.start()
  let _ = held_catalogue.registered_n(store, directory, "box", 2)
  let _ = held_catalogue.registered_n(store, directory, "", 1)
  let listed =
    roster.fixed([
      executors.plain("box", "loom@box.example.net"),
      executors.plain("desk", "loom@desk.example.net"),
    ])
  assert ledger_holdings.from_catalogue(registry, listed)()
    == Ok(
      Held(sessions: 3, placed: [
        Placed(executor_node: "loom@box.example.net", sessions: 2),
      ]),
    )
}

pub fn two_names_for_one_node_are_added_and_an_unlisted_name_is_not_a_placement_test() {
  let #(registry, store, directory) = held_catalogue.start()
  let _ = held_catalogue.registered_n(store, directory, "box", 1)
  let _ = held_catalogue.registered_n(store, directory, "build", 2)
  let _ = held_catalogue.registered_n(store, directory, "gone", 4)
  let listed =
    roster.fixed([
      executors.plain("box", "loom@box.example.net"),
      executors.plain("build", "loom@box.example.net"),
    ])

  // Seven sessions, three of them on the box under either name, and four on an
  // executor no row lists now, which names no node.
  assert ledger_holdings.from_catalogue(registry, listed)()
    == Ok(
      Held(sessions: 7, placed: [
        Placed(executor_node: "loom@box.example.net", sessions: 3),
      ]),
    )
}

pub fn a_session_handed_to_another_orchestrator_is_not_counted_test() {
  let #(registry, store, directory) = held_catalogue.start()
  let sessions = held_catalogue.registered_n(store, directory, "box", 3)
  let assert [first, ..] = sessions
  let assert Ok(_) = catalogue.begin_move(store, first, op: "op-1", to: "bravo")
  let assert Ok(_) = catalogue.finish_move(store, first, op: "op-1")
  let listed = roster.fixed([executors.plain("box", "loom@box.example.net")])
  assert ledger_holdings.from_catalogue(registry, listed)()
    == Ok(
      Held(sessions: 2, placed: [
        Placed(executor_node: "loom@box.example.net", sessions: 2),
      ]),
    )
}

pub fn a_session_still_moving_is_still_owned_test() {
  let #(registry, store, directory) = held_catalogue.start()
  let sessions = held_catalogue.registered_n(store, directory, "", 2)
  let assert [first, ..] = sessions
  let assert Ok(_) = catalogue.begin_move(store, first, op: "op-2", to: "bravo")
  assert ledger_holdings.from_catalogue(registry, roster.fixed([]))()
    == Ok(Held(sessions: 2, placed: []))
}

pub fn the_walk_crosses_a_page_boundary_test() {
  let #(registry, store, directory) = held_catalogue.start()
  let count = catalogue.page_limit + 5
  let _ = held_catalogue.registered_n(store, directory, "box", count)
  let listed = roster.fixed([executors.plain("box", "loom@box.example.net")])
  assert ledger_holdings.from_catalogue(registry, listed)()
    == Ok(
      Held(sessions: count, placed: [
        Placed(executor_node: "loom@box.example.net", sessions: count),
      ]),
    )
}

pub fn an_empty_catalogue_holds_nothing_test() {
  let #(registry, _, _) = held_catalogue.start()
  assert ledger_holdings.from_catalogue(registry, roster.fixed([]))()
    == Ok(Held(sessions: 0, placed: []))
}

pub fn a_registry_that_cannot_be_read_is_unknown_and_not_empty_test() {
  let #(registry, _, _) = held_catalogue.start()
  manager.shutdown(registry)
  assert ledger_holdings.from_catalogue(registry, roster.fixed([]))()
    == Error(Nil)
}

// --- the bounds -------------------------------------------------------------------

pub fn a_catalogue_past_the_page_bound_is_unknown_and_not_partial_test() {
  let #(registry, store, directory) = held_catalogue.start()
  let _ =
    held_catalogue.registered_n(store, directory, "", catalogue.page_limit + 1)
  let listed = roster.fixed([])

  // One page holds a hundred and the catalogue has a hundred and one. A tally
  // of the first page would read as "a hundred and no more".
  assert ledger_holdings.from_pages(registry, listed, 1)() == Error(Nil)
  assert ledger_holdings.from_pages(registry, listed, 2)()
    == Ok(Held(sessions: catalogue.page_limit + 1, placed: []))
}

pub fn a_catalogue_that_fills_the_bound_exactly_is_known_test() {
  let #(registry, store, directory) = held_catalogue.start()
  let _ =
    held_catalogue.registered_n(store, directory, "", catalogue.page_limit)

  // The bound is reached with the next page empty, so nothing was left out.
  assert ledger_holdings.from_pages(registry, roster.fixed([]), 1)()
    == Ok(Held(sessions: catalogue.page_limit, placed: []))
}

// Registers one session on each of `count` executors, named `e0`, `e1` and so
// on, lists them all on nodes of their own, and answers what the catalogue
// holds.
fn spread(count: Int) -> Result(Held, Nil) {
  let #(registry, store, directory) = held_catalogue.start()
  let names =
    list.repeat(Nil, count)
    |> list.index_map(fn(_, number) { "e" <> int.to_string(number) })
  list.each(names, fn(name) {
    let _ = held_catalogue.registered_n(store, directory, name, 1)
    Nil
  })
  let listed =
    roster.fixed(
      list.map(names, fn(name) {
        executors.plain(name, "loom@" <> name <> ".example.net")
      }),
    )
  ledger_holdings.from_catalogue(registry, listed)()
}

pub fn placements_on_more_executors_than_the_port_carries_are_unknown_test() {
  assert spread(orchestrator_port.max_placed + 1) == Error(Nil)
}

pub fn placements_on_exactly_the_most_the_port_carries_are_known_test() {
  let assert Ok(Held(sessions:, placed:)) = spread(orchestrator_port.max_placed)
  assert sessions == orchestrator_port.max_placed
  assert list.length(placed) == orchestrator_port.max_placed
}

// --- the placements a report lists ---------------------------------------------

pub fn placements_split_the_sessions_on_an_executor_by_residency_test() {
  let #(registry, store, directory) = held_catalogue.start()
  let _ = held_catalogue.registered_n(store, directory, "box", 2)
  let _ = held_catalogue.registered_n(store, directory, "", 1)
  let listed = roster.fixed([executors.plain("box", "loom@box.example.net")])

  // The fixture's sessions are saved and none has a runtime, and the session
  // with no executor is a session and not a placement.
  assert ledger_holdings.placements(registry, listed)
    == Ok([
      node_report.Placement(
        executor_node: "loom@box.example.net",
        resident: 0,
        saved: 2,
      ),
    ])
}

pub fn a_session_handed_away_is_not_a_placement_test() {
  let #(registry, store, directory) = held_catalogue.start()
  let sessions = held_catalogue.registered_n(store, directory, "box", 3)
  let assert [first, ..] = sessions
  let assert Ok(_) = catalogue.begin_move(store, first, op: "op-1", to: "bravo")
  let assert Ok(_) = catalogue.finish_move(store, first, op: "op-1")
  let listed = roster.fixed([executors.plain("box", "loom@box.example.net")])
  assert ledger_holdings.placements(registry, listed)
    == Ok([
      node_report.Placement(
        executor_node: "loom@box.example.net",
        resident: 0,
        saved: 2,
      ),
    ])
}

pub fn more_executors_than_a_report_lists_are_unknown_not_truncated_test() {
  let #(registry, store, directory) = held_catalogue.start()
  let names =
    list.repeat(Nil, node_report.max_placements + 1)
    |> list.index_map(fn(_, n) { "box" <> int.to_string(n) })
  list.each(names, fn(name) {
    let _ = held_catalogue.registered_n(store, directory, name, 1)
    Nil
  })
  let listed =
    roster.fixed(
      list.map(names, fn(name) {
        executors.plain(name, "loom@" <> name <> ".example.net")
      }),
    )

  // The full tally fits the port's `Holds` and does not fit a report, so the
  // report is left without placements and nobody reads a short list as whole.
  assert ledger_holdings.placements(registry, listed) == Error(Nil)
}

pub fn an_empty_catalogue_has_no_placements_test() {
  let #(registry, _, _) = held_catalogue.start()
  assert ledger_holdings.placements(registry, roster.fixed([])) == Ok([])
}
