//// The rows a node derives from its ledger, and how they combine with the rows
//// its operator wrote (protocol-change/086, phase 2). The derivation is pure, so
//// most tests build a ledger and read rows from it. The last two run a ledger
//// process and read a roster while entries arrive, which is the property that
//// matters: a member enrolled or revoked changes the rows with no restart.

import client/distribution_plan.{type Role, Executor, Orchestrator}
import client/executors
import client/ledger_rows
import client/ledger_service
import client/membership_entry.{
  type DirectoryStanding, Member, NotInDirectory, Upsert, Voter,
}
import client/orchestrators
import client/roster
import gleam/erlang/process
import gleam/list
import gleam/option.{Some}
import support/ledger_rig as rig
import support/membership_fixture as fixture
import support/membership_log as history

const hub = "loom@hub.example.net"

fn member(
  name: String,
  role: Role,
  directory: DirectoryStanding,
  links: List(String),
) -> membership_entry.Kind {
  Upsert(Member(..fixture.member(name, links), role:, directory:))
}

fn enrolled(
  log: history.Log,
  name: String,
  role: Role,
  links: List(String),
) -> history.Log {
  history.must_push(log, member(name, role, NotInDirectory, links))
}

// A hub (orchestrator) linked to a box and a desk (executors) and to a laptop
// (orchestrator). A stray executor is linked to nobody the hub knows.
fn deployment() -> history.Log {
  history.genesis()
  |> enrolled("box", Executor, [])
  |> enrolled("desk", Executor, [])
  |> enrolled("laptop", Orchestrator, [])
  |> enrolled("stray", Executor, [])
  |> enrolled("hub", Orchestrator, ["box", "desk", "laptop"])
}

fn names(rows: List(row), name: fn(row) -> String) -> List(String) {
  list.map(rows, name)
}

// --- what is derived -------------------------------------------------------------

pub fn an_orchestrator_derives_a_row_for_each_linked_member_of_each_kind_test() {
  let ledger = deployment().ledger

  let derived = ledger_rows.executors_of(ledger, hub, [])
  assert names(derived, fn(row) { row.name }) == ["box", "desk"]
  assert names(derived, fn(row) { row.node })
    == ["loom@box.example.net", "loom@desk.example.net"]

  // A derived row declares nothing, which is why a pool that requires a
  // platform skips it.
  let assert [box, ..] = derived
  assert box == executors.plain("box", "loom@box.example.net")

  let peers = ledger_rows.orchestrators_of(ledger, hub, [])
  assert peers == [orchestrators.plain("laptop", "loom@laptop.example.net")]
}

pub fn a_member_the_node_is_not_linked_to_gets_no_row_test() {
  let ledger = deployment().ledger
  let derived = ledger_rows.executors_of(ledger, hub, [])
  assert !list.any(derived, fn(row) { row.name == "stray" })
}

pub fn a_link_listed_by_the_other_end_derives_the_row_too_test() {
  // The link is symmetric: an executor that lists the orchestrator is linked to
  // it, though the orchestrator lists nobody.
  let ledger =
    history.genesis()
    |> enrolled("hub", Orchestrator, [])
    |> enrolled("box", Executor, ["hub"])
    |> fn(log) { log.ledger }
  assert names(ledger_rows.executors_of(ledger, hub, []), fn(row) { row.name })
    == ["box"]
}

pub fn an_executor_derives_nothing_test() {
  let ledger = deployment().ledger
  assert ledger_rows.executors_of(ledger, "loom@box.example.net", []) == []
  assert ledger_rows.orchestrators_of(ledger, "loom@box.example.net", []) == []
}

pub fn a_node_the_ledger_does_not_list_derives_nothing_test() {
  let ledger = deployment().ledger
  assert ledger_rows.executors_of(ledger, "loom@ghost.example.net", []) == []
  assert ledger_rows.orchestrators_of(ledger, "loom@ghost.example.net", [])
    == []
}

pub fn a_revoked_member_has_no_row_test() {
  let log = deployment()
  assert list.length(ledger_rows.executors_of(log.ledger, hub, [])) == 2

  let after = history.revoke(log, "desk").ledger
  assert names(ledger_rows.executors_of(after, hub, []), fn(row) { row.name })
    == ["box"]
}

pub fn a_node_in_the_directory_lists_only_orchestrators_that_are_in_it_test() {
  // Protocol-change/083 requires every orchestrator a member daemon lists to be
  // a member itself, so the laptop outside the directory is not derived, and one
  // inside it is.
  let log =
    history.genesis()
    |> history.must_push(member("hub", Orchestrator, Voter, []))
    |> history.must_push(member("peer", Orchestrator, Voter, ["hub"]))
    |> history.must_push(
      member("laptop", Orchestrator, NotInDirectory, ["hub", "peer"]),
    )
  assert names(ledger_rows.orchestrators_of(log.ledger, hub, []), fn(row) {
      row.name
    })
    == ["peer"]

  // A node outside the directory lists both.
  let outside =
    ledger_rows.orchestrators_of(log.ledger, "loom@laptop.example.net", [])
  assert names(outside, fn(row) { row.name }) == ["hub", "peer"]
}

// --- combining with written rows -----------------------------------------------

pub fn a_written_row_with_the_same_name_replaces_the_derived_one_test() {
  let ledger = deployment().ledger
  let written =
    executors.Executor(
      name: "box",
      node: "loom@box.example.net",
      platform: Some("linux/x86_64"),
      enforcement: Some(executors.Enforced),
      toolchains: ["codemode"],
    )
  let rows = ledger_rows.executors_of(ledger, hub, [written])

  // The declarations survive, and the machine is listed once.
  assert rows == [written, executors.plain("desk", "loom@desk.example.net")]
}

pub fn a_written_row_claims_its_node_under_any_name_test() {
  // The operator named the ledger's `box` machine `build`. Listing it again as
  // `box` would put one machine in every listing twice.
  let ledger = deployment().ledger
  let written = executors.plain("build", "loom@box.example.net")
  let rows = ledger_rows.executors_of(ledger, hub, [written])
  assert names(rows, fn(row) { row.name }) == ["build", "desk"]
}

pub fn a_written_orchestrator_with_an_address_keeps_it_test() {
  let ledger = deployment().ledger
  let written =
    orchestrators.Orchestrator(
      name: "laptop",
      node: "loom@laptop.example.net",
      address: Some("wss://laptop.example.net/v2/control"),
    )
  assert ledger_rows.orchestrators_of(ledger, hub, [written]) == [written]
}

pub fn a_written_row_for_a_member_that_is_gone_stays_test() {
  // The operator's row outlives the member. It is inert (the pin table no longer
  // resolves the node), and it is the daemon's start that warns about it.
  let log = deployment()
  let written = executors.plain("desk", "loom@desk.example.net")
  let after = history.revoke(log, "desk").ledger
  assert ledger_rows.executors_of(after, hub, [written])
    == [executors.plain("box", "loom@box.example.net"), written]
}

pub fn the_rows_come_back_sorted_by_name_test() {
  let log =
    history.genesis()
    |> enrolled("zulu", Executor, [])
    |> enrolled("alpha", Executor, [])
    |> enrolled("hub", Orchestrator, ["zulu", "alpha"])
  let written = executors.plain("mike", "loom@mike.example.net")
  assert names(ledger_rows.executors_of(log.ledger, hub, [written]), fn(row) {
      row.name
    })
    == ["alpha", "mike", "zulu"]
}

// --- a roster that follows a running ledger -------------------------------------

fn running(log: history.Log, held: Int) -> #(rig.Rig, List(BitArray)) {
  let lines = history.lines(log)
  #(rig.start("rows-roster", list.take(lines, held), rig.patient, []), lines)
}

fn offer(r: rig.Rig, line: BitArray) -> Nil {
  let assert Ok(ledger_service.Accepted(_)) =
    ledger_service.offer(r.service, line, 5000)
    as "the entry is accepted"
  Nil
}

pub fn a_roster_follows_the_ledger_it_reads_test() {
  // The ledger starts with the hub and one executor. Entries arrive while the
  // roster exists: an executor is enrolled, then revoked.
  let log =
    history.genesis()
    |> enrolled("box", Executor, [])
    |> enrolled("hub", Orchestrator, ["box"])
    |> enrolled("desk", Executor, ["hub"])
    |> history.revoke("desk")
  let #(r, lines) = running(log, 3)
  let rows = ledger_rows.executor_roster(r.service, hub, [])
  let others = ledger_rows.orchestrator_roster(r.service, hub, [])

  assert names(roster.rows(rows), fn(row) { row.name }) == ["box"]
  assert roster.rows(others) == []

  // Enrolling the desk adds its row to the roster that already exists.
  let assert [_, _, _, enroll_desk, revoke_desk] = lines
  offer(r, enroll_desk)
  assert names(roster.rows(rows), fn(row) { row.name }) == ["box", "desk"]

  // Revoking it takes the row away again.
  offer(r, revoke_desk)
  assert names(roster.rows(rows), fn(row) { row.name }) == ["box"]
}

pub fn a_roster_with_no_ledger_process_offers_only_the_written_rows_test() {
  let log =
    history.genesis()
    |> enrolled("box", Executor, [])
    |> enrolled("hub", Orchestrator, ["box"])
  let #(r, _) = running(log, 3)
  let written = executors.plain("mine", "loom@mine.example.net")
  let rows = ledger_rows.executor_roster(r.service, hub, [written])
  assert names(roster.rows(rows), fn(row) { row.name }) == ["box", "mine"]

  // The process is gone, so nothing can confirm the derived rows. They fail
  // closed and the written one stays.
  process.unlink(ledger_service.pid(r.service))
  process.kill(ledger_service.pid(r.service))
  assert roster.rows(rows) == [written]
}
