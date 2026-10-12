//// How a daemon whose trust is a ledger learns that it is a member of the
//// session directory (protocol-change/086, phase 3): the members come from the
//// ledger the process holds, and there is no `[directory]` table to read.
////
//// `main.ledger_directory` is the step between the ledger process and the
//// daemon's configuration. These tests run it over a ledger process in this VM
//// with node names of their own, and check what it derives, what it refuses and
//// what it writes down. The member actor that runs on the result is
//// `ledger_directory_test`.

import client/daemon/main
import client/directory/settings.{Settings}
import client/membership_entry.{Learner, Member, Upsert, Voter}
import client/orchestrators.{Orchestrator}
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import support/ledger_rig as rig
import support/membership_fixture as fixture
import support/membership_log as membership
import telemetry/level
import telemetry/log

fn seated(
  history: membership.Log,
  name: String,
  standing: membership_entry.DirectoryStanding,
) -> membership.Log {
  membership.must_push(
    history,
    Upsert(Member(..fixture.member(name, []), directory: standing)),
  )
}

fn capture() {
  let records = process.new_subject()
  #(log.new(sink: log.to_subject(records), threshold: level.Warning), records)
}

const a = "loom@a.example.net"

const b = "loom@b.example.net"

const c = "loom@c.example.net"

const l = "loom@l.example.net"

fn three_voters_and_a_learner(label: String) {
  rig.start(
    label,
    membership.lines(
      membership.genesis()
      |> seated("a", Voter)
      |> seated("b", Voter)
      |> seated("c", Voter)
      |> seated("l", Learner)
      |> membership.enroll("laptop", ["a"]),
    ),
    rig.patient,
    [],
  )
}

// A static deployment has no ledger, and the table it read stands.
pub fn without_a_ledger_the_configured_table_stands_test() {
  let #(logger, _) = capture()
  let configured = Some(Settings(members: [a, b, c]))
  assert main.ledger_directory(configured, None, a, [], logger)
    == Ok(configured)
  assert main.ledger_directory(None, None, a, [], logger) == Ok(None)
}

// Every seated node is a member, and so is each of them to itself.
pub fn a_seated_node_is_a_member_of_the_ledgers_directory_test() {
  let started = three_voters_and_a_learner("ledger-directory-seated")
  let #(logger, records) = capture()
  let members = [a, b, c, l]
  assert main.ledger_directory(None, Some(started.service), a, [], logger)
    == Ok(Some(Settings(members:)))
  assert main.ledger_directory(None, Some(started.service), l, [], logger)
    == Ok(Some(Settings(members:)))

  // Three voters is within the bounds and odd, so there is nothing to say.
  assert process.receive(records, 50) == Error(Nil)
}

pub fn a_node_the_ledger_does_not_seat_is_not_a_member_test() {
  let started = three_voters_and_a_learner("ledger-directory-unseated")
  let #(logger, _) = capture()
  assert main.ledger_directory(
      None,
      Some(started.service),
      "loom@laptop.example.net",
      [],
      logger,
    )
    == Ok(None)
}

// A member daemon moves sessions by the record, so every orchestrator it lists
// must be a member too (protocol-change/083). A parse cannot check that against
// a ledger, so the start does.
pub fn a_listed_orchestrator_must_be_a_member_test() {
  let started = three_voters_and_a_learner("ledger-directory-orchestrators")
  let #(logger, _) = capture()
  let assert Ok(Some(_)) =
    main.ledger_directory(
      None,
      Some(started.service),
      a,
      [Orchestrator(name: "b", node: b, address: None)],
      logger,
    )
    as "an orchestrator that is a member is accepted"
  let assert Error(reason) =
    main.ledger_directory(
      None,
      Some(started.service),
      a,
      [
        Orchestrator(
          name: "outsider",
          node: "loom@laptop.example.net",
          address: None,
        ),
      ],
      logger,
    )
    as "an orchestrator outside the directory is refused"
  assert string.contains(
    reason,
    "orchestrators.outsider.node loom@laptop.example.net must be one of",
  )
}

// The ledger records what the operator signed, so a count of voters outside
// three to seven, or an even one, is logged and not refused.
pub fn a_count_of_voters_outside_the_bounds_is_logged_not_refused_test() {
  let started =
    rig.start(
      "ledger-directory-two",
      membership.lines(
        membership.genesis()
        |> seated("a", Voter)
        |> seated("b", Voter),
      ),
      rig.patient,
      [],
    )
  let #(logger, records) = capture()
  let assert Ok(Some(_)) =
    main.ledger_directory(None, Some(started.service), a, [], logger)
  let assert Ok(warning) = process.receive(records, 1000)
  assert warning.event == "daemon.directory_voters"
}
