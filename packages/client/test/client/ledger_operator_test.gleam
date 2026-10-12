//// What the operator commands decide before they sign (protocol-change/086):
//// the entry each one builds from the fold, the refusals of the pre-flight, the
//// concerns of a revoke and the confirmations of a status. The ledgers are the
//// fixture scheme's, so a rule is exercised without a key.

import client/distribution_plan.{Executor, Orchestrator}
import client/ledger_control.{HeadView, MemberView, StatusView}
import client/ledger_operator.{Enrollment}
import client/membership_entry.{NotInDirectory, Revoke, Upsert}
import client/membership_ledger
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import support/membership_fixture as fixture
import support/membership_log as log

const time = "2026-10-12T09:00:00Z"

fn request(name: String, links: List(String)) -> ledger_operator.Enrollment {
  Enrollment(
    name:,
    node: "loom@" <> name <> ".example.net",
    role: Orchestrator,
    host: None,
    listen_port: None,
    links:,
    directory: NotInDirectory,
    workspaces: [],
    bundle_dir: None,
  )
}

pub fn an_enrollment_is_a_member_entry_that_follows_the_head_test() {
  let history = log.genesis() |> log.enroll("hub", [])
  let ledger = history.ledger
  let assert Ok(entry) =
    ledger_operator.enroll(
      ledger,
      request("laptop", ["hub"]),
      fixture.pin_for("laptop", 0),
      time,
    )
  let head = membership_ledger.head(ledger)
  assert entry.seq == head.seq + 1
  assert entry.prev == head.id
  assert entry.time == time
  let assert Upsert(member) = entry.kind
  assert member.host == "laptop.example.net"
  assert member.links == ["hub"]
  assert member.directory == membership_entry.NotInDirectory
  assert is_ok(membership_ledger.check(ledger, entry))
}

pub fn an_enrollment_is_refused_by_name_for_each_rule_it_breaks_test() {
  let ledger = { log.genesis() |> log.enroll("hub", []) }.ledger
  let refused = fn(enrollment, fragment) {
    let assert Error(reason) =
      ledger_operator.enroll(ledger, enrollment, fixture.pin_for("x", 7), time)
    assert string.contains(reason, fragment)
  }
  refused(request("hub", []), "hub is already a member")
  refused(request("ghost-link", ["ghost"]), "ghost cannot be linked")
  refused(
    Enrollment(..request("twin", []), node: "loom@hub.example.net"),
    "loom@hub.example.net already belongs to another member",
  )
  let assert Error(reason) =
    ledger_operator.enroll(
      ledger,
      request("pinned", []),
      fixture.member("hub", []).pin,
      time,
    )
  assert string.contains(
    reason,
    "another member already holds this certificate",
  )
}

pub fn an_enrollments_own_fields_are_checked_before_anything_is_minted_test() {
  let refused = fn(enrollment, fragment) {
    let assert Error(reason) = ledger_operator.check_enrollment(enrollment)
    assert string.contains(reason, fragment)
  }
  assert is_ok(ledger_operator.check_enrollment(request("laptop", [])))
  refused(request("Not A Name", []), "is not a node name")
  refused(Enrollment(..request("a", []), node: "no-at-sign"), "--node")
  refused(
    Enrollment(..request("a", []), listen_port: Some(0)),
    "--port must be",
  )

  // An executor no orchestrator is linked to could never be reached, and links
  // cannot be added to a member later.
  refused(
    Enrollment(..request("box", []), role: Executor),
    "box is an executor with no --links",
  )
  assert is_ok(ledger_operator.check_enrollment(
    Enrollment(..request("box", ["hub"]), role: Executor),
  ))
  refused(
    Enrollment(..request("a", []), workspaces: [
      distribution_plan.Workspace("repo", "/srv/repo"),
    ]),
    "--workspace belongs to an executor",
  )
  refused(
    Enrollment(..request("a", ["hub"]), role: Executor, workspaces: [
      distribution_plan.Workspace("repo", "relative"),
    ]),
    "must be an absolute path",
  )
}

pub fn a_renewal_comes_from_the_fold_and_not_from_the_last_entry_test() {
  // `a` was enrolled with a link to `b`, and `b` has been revoked since. The
  // fold removed the link from `a`, so a renewal that copied the last entry
  // would name a member that is no longer active and be refused as invalid.
  let history =
    log.genesis()
    |> log.enroll("b", [])
    |> log.enroll("a", ["b"])
    |> log.revoke("b")
  let ledger = history.ledger
  let assert Ok(#(entry, member)) =
    ledger_operator.renew(ledger, "a", fixture.pin_for("a", 1), time)
  assert member.links == []
  assert member.pin == fixture.pin_for("a", 1)
  assert entry.kind == Upsert(member)

  // The copied entry is what the fold would refuse.
  let stale = Upsert(membership_entry.Member(..member, links: ["b"]))
  assert is_error(membership_ledger.check(
    ledger,
    log.next_entry(history, stale),
  ))
}

pub fn a_revoke_records_the_pin_the_member_held_test() {
  let ledger = { log.genesis() |> log.enroll("a", []) }.ledger
  let assert Ok(entry) = ledger_operator.revoke(ledger, "a", "lost", time)
  assert entry.kind
    == Revoke(name: "a", pin: fixture.pin_for("a", 0), reason: "lost")
  let assert Error(reason) = ledger_operator.revoke(ledger, "ghost", "", time)
  assert string.contains(reason, "ghost is not a member")
  let assert Error(reason) =
    ledger_operator.revoke(ledger, "a", string.repeat("x", 201), time)
  assert string.contains(reason, "--reason")
  let assert Error(reason) = ledger_operator.revoke(ledger, "a", "a\nb", time)
  assert string.contains(reason, "--reason")
}

pub fn a_revoked_name_is_not_renewed_but_may_be_enrolled_again_test() {
  let history = log.genesis() |> log.enroll("a", []) |> log.revoke("a")
  let ledger = history.ledger
  let assert Error(reason) =
    ledger_operator.renew(ledger, "a", fixture.pin_for("a", 1), time)
  assert string.contains(reason, "a was revoked")
  assert is_ok(ledger_operator.enroll(
    ledger,
    request("a", []),
    fixture.pin_for("a", 1),
    time,
  ))
}

fn orchestrator(name: String, links: List(String)) {
  membership_entry.Member(..fixture.member(name, links), role: Orchestrator)
}

pub fn a_revoke_that_cuts_the_graph_or_orphans_an_executor_is_a_concern_test() {
  // hub - a - b - c is a chain, so revoking `a` cuts `hub` off from the larger
  // group that stays.
  let chain =
    log.genesis()
    |> log.must_push(Upsert(orchestrator("hub", [])))
    |> log.must_push(Upsert(orchestrator("a", ["hub"])))
    |> log.must_push(Upsert(orchestrator("b", ["a"])))
    |> log.must_push(Upsert(orchestrator("c", ["b"])))
  let assert Ok(entry) = ledger_operator.revoke(chain.ledger, "a", "", time)
  let assert Ok(after) = membership_ledger.check(chain.ledger, entry)
  assert ledger_operator.concerns(chain.ledger, after)
    == [ledger_operator.Cut(["hub"])]
  assert ledger_operator.describe_concern(ledger_operator.Cut(["b", "c"]))
    == "the members b, c would no longer be linked to the rest"

  // An executor used by one orchestrator is orphaned when it goes.
  let pair =
    log.genesis()
    |> log.must_push(Upsert(orchestrator("hub", [])))
    |> log.must_push(Upsert(
      membership_entry.Member(..fixture.member("box", ["hub"]), role: Executor),
    ))
  let assert Ok(entry) = ledger_operator.revoke(pair.ledger, "hub", "", time)
  let assert Ok(after) = membership_ledger.check(pair.ledger, entry)
  assert ledger_operator.concerns(pair.ledger, after)
    == [ledger_operator.Orphaned("box")]

  // A concern that was there already is not the revoke's doing.
  let assert Ok(entry) = ledger_operator.revoke(pair.ledger, "box", "", time)
  let assert Ok(after) = membership_ledger.check(pair.ledger, entry)
  assert ledger_operator.concerns(pair.ledger, after) == []
}

// --- what a revoke would strand ----------------------------------------------

fn answer(
  name: String,
  held: option.Option(ledger_control.HeldView),
) -> ledger_control.AnswerView {
  ledger_control.AnswerView(
    name:,
    node: "loom@" <> name <> ".example.net",
    held:,
  )
}

fn held(sessions: Int, placed: List(#(String, Int))) {
  Some(ledger_control.HeldView(
    sessions:,
    placed: list.map(placed, fn(pair) {
      ledger_control.PlacedView(node: pair.0, sessions: pair.1)
    }),
  ))
}

// A hub and a laptop, both orchestrators, and a box they both use.
fn estate() -> membership_ledger.Ledger {
  let estate =
    log.genesis()
    |> log.must_push(Upsert(orchestrator("hub", [])))
    |> log.must_push(Upsert(orchestrator("laptop", ["hub"])))
    |> log.must_push(Upsert(
      membership_entry.Member(
        ..fixture.member("box", ["hub", "laptop"]),
        role: Executor,
      ),
    ))
  estate.ledger
}

const box = "loom@box.example.net"

pub fn an_orchestrator_that_reports_sessions_strands_them_test() {
  let answers = [answer("hub", held(0, [])), answer("laptop", held(3, []))]
  assert ledger_operator.strandings(estate(), "laptop", answers)
    == [ledger_operator.Owns(3)]
  assert ledger_operator.strandings(estate(), "hub", answers) == []
  assert ledger_operator.describe_stranding("laptop", ledger_operator.Owns(3))
    == "laptop owns 3 sessions, which nobody can open until it is enrolled again"
  assert ledger_operator.describe_stranding("laptop", ledger_operator.Owns(1))
    == "laptop owns 1 session, which nobody can open until it is enrolled again"
}

pub fn an_orchestrator_that_is_silent_or_unlisted_is_unknown_and_not_empty_test() {
  // It was asked and did not answer.
  assert ledger_operator.strandings(estate(), "laptop", [
      answer("hub", held(0, [])),
      answer("laptop", None),
    ])
    == [ledger_operator.Silent(["laptop"])]

  // The daemon that answered could not ask it at all.
  assert ledger_operator.strandings(estate(), "laptop", [
      answer("hub", held(0, [])),
    ])
    == [ledger_operator.Silent(["laptop"])]
  assert ledger_operator.describe_stranding(
      "laptop",
      ledger_operator.Silent(["laptop"]),
    )
    == "whether laptop holds sessions could not be told: laptop did not answer"
}

pub fn an_executor_is_stranded_by_the_sessions_orchestrators_placed_on_it_test() {
  let answers = [
    answer("hub", held(5, [#(box, 2), #("loom@other.example.net", 3)])),
    answer("laptop", held(4, [#(box, 1)])),
  ]
  assert ledger_operator.strandings(estate(), "box", answers)
    == [ledger_operator.Placed(3, ["hub", "laptop"])]
  assert ledger_operator.describe_stranding(
      "box",
      ledger_operator.Placed(3, ["hub", "laptop"]),
    )
    == "3 sessions placed on box by hub, laptop would fail as they do when an executor is down"

  // Sessions placed on another node do not count.
  assert ledger_operator.strandings(estate(), "box", [
      answer("hub", held(5, [#("loom@other.example.net", 5)])),
      answer("laptop", held(0, [])),
    ])
    == []
}

pub fn an_executor_with_a_silent_orchestrator_is_unknown_even_when_others_found_none_test() {
  assert ledger_operator.strandings(estate(), "box", [
      answer("hub", held(0, [])),
      answer("laptop", None),
    ])
    == [ledger_operator.Silent(["laptop"])]

  // Both facts are reported together: some are placed, and one did not answer.
  assert ledger_operator.strandings(estate(), "box", [
      answer("hub", held(1, [#(box, 1)])),
    ])
    == [
      ledger_operator.Placed(1, ["hub"]),
      ledger_operator.Silent(["laptop"]),
    ]
}

pub fn the_clear_sentence_names_what_was_checked_test() {
  let assert Ok(laptop) = membership_ledger.member(estate(), "laptop")
  let assert Ok(executor) = membership_ledger.member(estate(), "box")
  assert ledger_operator.describe_clear(laptop) == "laptop owns no sessions."
  assert ledger_operator.describe_clear(executor)
    == "no orchestrator linked to box has a session placed on it."
}

fn status_of(members: List(ledger_control.MemberView)) {
  StatusView(
    deployment: fixture.deployment,
    standing: ledger_control.Enrolled,
    head: HeadView(seq: 4, id: string.repeat("a", 64)),
    self_name: "hub",
    members:,
    last_refusal: None,
  )
}

fn view(name: String, reported: option.Option(Int)) {
  MemberView(
    name:,
    node: "loom@" <> name,
    role: "executor",
    directory: "none",
    reported_seq: reported,
    ms_since_report: None,
  )
}

pub fn a_member_has_confirmed_when_it_reported_the_entry_or_a_later_one_test() {
  let rows =
    ledger_operator.confirmations(
      status_of([
        view("a", Some(4)),
        view("b", Some(5)),
        view("c", Some(3)),
        view("d", None),
      ]),
      4,
    )
  assert rows
    == [
      #("a", ledger_operator.Confirmed),
      #("b", ledger_operator.Confirmed),
      #("c", ledger_operator.Pending(Some(3))),
      #("d", ledger_operator.Pending(None)),
    ]
  assert !ledger_operator.all_confirmed(rows)
  assert ledger_operator.all_confirmed([#("a", ledger_operator.Confirmed)])
  assert ledger_operator.all_confirmed([])
}

fn is_ok(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn is_error(result: Result(a, b)) -> Bool {
  !is_ok(result)
}
