//// What the operator's commands decide about the session directory's voters
//// (protocol-change/086, phase 3), apart from files and sockets: the standing an
//// enrollment carries, and the bounds of three to seven voters that `enroll` and
//// `revoke` keep.

import client/distribution_plan.{Orchestrator}
import client/ledger_operator.{Enrollment}
import client/membership_entry.{Learner, NotInDirectory, Upsert, Voter}
import client/membership_ledger
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import support/membership_fixture as fixture
import support/membership_log as log

const time = "2026-10-12T09:00:00Z"

fn request(name: String, directory: membership_entry.DirectoryStanding) {
  Enrollment(
    name:,
    node: "loom@" <> name <> ".example.net",
    role: Orchestrator,
    host: None,
    listen_port: None,
    links: [],
    directory:,
    workspaces: [],
    bundle_dir: None,
  )
}

fn seated(
  history: log.Log,
  name: String,
  directory: membership_entry.DirectoryStanding,
) -> log.Log {
  log.must_push(
    history,
    Upsert(membership_entry.Member(..fixture.member(name, []), directory:)),
  )
}

fn voters_named(names: List(String)) -> log.Log {
  list.fold(names, log.genesis(), fn(history, name) {
    seated(history, name, Voter)
  })
}

pub fn an_enrollment_carries_the_directory_standing_it_asks_for_test() {
  let ledger = { log.genesis() }.ledger
  let enrolled = fn(standing) {
    let assert Ok(entry) =
      ledger_operator.enroll(
        ledger,
        request("laptop", standing),
        fixture.pin_for("laptop", 0),
        time,
      )
    let assert Upsert(member) = entry.kind
    member.directory
  }
  assert enrolled(Learner) == Learner
  assert enrolled(Voter) == Voter
  assert enrolled(NotInDirectory) == NotInDirectory
}

pub fn the_directory_takes_at_most_seven_voters_test() {
  let seven = voters_named(["a", "b", "c", "d", "e", "f", "g"])
  let enrolling = fn(history: log.Log, standing) {
    ledger_operator.enroll(
      history.ledger,
      request("h", standing),
      fixture.pin_for("h", 0),
      time,
    )
  }

  // A learner holds no vote, so the eighth member is welcome as one.
  assert result.is_ok(enrolling(seven, Learner))
  let assert Error(reason) = enrolling(seven, Voter)
  assert string.contains(reason, "at most 7 voters")
  assert string.contains(reason, "--directory learner")

  // Six voters can take a seventh.
  let six = voters_named(["a", "b", "c", "d", "e", "f"])
  assert result.is_ok(enrolling(six, Voter))
}

pub fn a_revoke_may_not_leave_fewer_than_three_voters_test() {
  let three = voters_named(["a", "b", "c"]) |> seated("l", Learner)
  let revoking = fn(history: log.Log, name) {
    let assert Ok(entry) =
      ledger_operator.revoke(history.ledger, name, "lost", time)
    let assert Ok(after) = membership_ledger.check(history.ledger, entry)
    ledger_operator.check_voters(history.ledger, after)
  }
  let assert Error(reason) = revoking(three, "a")
  assert string.contains(reason, "left with 2 voters")
  assert string.contains(reason, "at least 3")

  // A learner holds no vote, so it goes whatever the voters are.
  assert revoking(three, "l") == Ok(Nil)

  // A fourth voter makes room for the removal of one.
  assert revoking(seated(three, "d", Voter), "a") == Ok(Nil)
  let assert Error(_) = revoking(voters_named(["a", "b"]), "a")
}

pub fn a_member_outside_the_directory_changes_no_count_test() {
  let history = voters_named(["a", "b", "c"]) |> log.enroll("laptop", [])
  let assert Ok(entry) =
    ledger_operator.revoke(history.ledger, "laptop", "lost", time)
  let assert Ok(after) = membership_ledger.check(history.ledger, entry)
  assert ledger_operator.check_voters(history.ledger, after) == Ok(Nil)
}
