//// The fold of the membership ledger (protocol-change/086): the acceptance
//// steps after the line is read, the per-kind rules, the pin table, and the
//// outcomes that are not refusals. Each refusal reason has a test that
//// produces it from entries a signer could really have written, and the
//// property suite in `membership_ledger_property_test` covers the laws.

import client/distribution_plan.{Executor, Orchestrator}
import client/membership_entry.{
  type Kind, Genesis, Learner, Malformed, Member, NotInDirectory, Revoke, Upsert,
  Voter,
}
import client/membership_ledger.{
  Applied, Chain, Duplicate, Enrolled, Fork, Gap, Head, Invalid, LedgerFull,
  NodeInUse, NotActive, NotEnrolled, PinInUse, Revoked, TooManyActive,
  TooManyNames, UnknownLink, Unreadable,
}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import support/membership_fixture as fixture
import support/membership_log as history

fn accept(log: history.Log, line: BitArray) {
  membership_ledger.accept(log.ledger, line, fixture.verifier())
}

// The refusal the fold gives an entry built at the head's successor.
fn refusal(log: history.Log, kind: Kind) -> membership_ledger.Refusal {
  let assert Error(refusal) = history.push(log, kind)
    as "the fold was expected to refuse"
  refusal
}

fn names(count: Int) -> List(String) {
  list.index_map(list.repeat(Nil, count), fn(_, index) {
    "n" <> int.to_string(index)
  })
}

fn peer_names(table: membership_ledger.PinTable) -> List(String) {
  list.map(membership_ledger.peers(table), fn(peer) { peer.name })
}

fn table_of(log: history.Log, name: String) -> membership_ledger.PinTable {
  membership_ledger.pin_table(log.ledger, name)
}

// --- starting a ledger ---------------------------------------------------------

pub fn a_genesis_line_starts_a_ledger_test() {
  let log = history.genesis()
  let assert Ok(ledger) =
    membership_ledger.begin(
      membership_entry.line(
        fixture.seal(fixture.entry(
          0,
          membership_entry.genesis_prev(),
          fixture.genesis_kind(),
        )),
      ),
      fixture.verifier(),
    )
  assert ledger == log.ledger
  assert membership_ledger.deployment(ledger) == fixture.deployment
  assert membership_ledger.head(ledger).seq == 0
  assert membership_ledger.members(ledger) == []
}

pub fn the_genesis_names_the_authority_test() {
  let assert Genesis(authority:, ..) = fixture.genesis_kind()
  assert membership_ledger.authority(history.genesis().ledger) == authority
}

pub fn a_ledger_cannot_start_with_another_kind_test() {
  let first =
    fixture.entry(
      0,
      membership_entry.genesis_prev(),
      Upsert(fixture.member("a", [])),
    )
  assert membership_ledger.start(fixture.seal(first))
    == Error(Invalid(membership_ledger.FirstEntryNotGenesis))
}

pub fn a_genesis_must_be_at_sequence_zero_test() {
  let late =
    fixture.entry(1, membership_entry.genesis_prev(), fixture.genesis_kind())
  assert membership_ledger.start(fixture.seal(late))
    == Error(Invalid(membership_ledger.FirstEntryNotGenesis))
}

pub fn a_genesis_must_have_a_zero_prev_test() {
  let log = history.genesis()
  let head = membership_ledger.head(log.ledger)
  let chained = fixture.entry(0, head.id, fixture.genesis_kind())
  assert membership_ledger.start(fixture.seal(chained))
    == Error(Invalid(membership_ledger.FirstEntryNotGenesis))
}

pub fn begin_reports_an_unreadable_first_line_test() {
  assert membership_ledger.begin(<<"nonsense":utf8>>, fixture.verifier())
    == Error(Unreadable(Malformed(membership_entry.LineShape)))
}

// --- the acceptance steps -----------------------------------------------------

pub fn accept_applies_the_next_line_test() {
  let log = history.genesis()
  let line =
    fixture.line(history.next_entry(log, Upsert(fixture.member("hub", []))))
  let assert Ok(Applied(ledger:, entry:)) = accept(log, line)
  assert membership_ledger.head(ledger).seq == 1
  assert membership_ledger.head(ledger).id == entry.id
  assert list.map(membership_ledger.members(ledger), fn(member) { member.name })
    == ["hub"]
}

pub fn accept_reports_each_unreadable_line_with_its_step_test() {
  let log = history.genesis()
  let step = fn(line) {
    let assert Error(refusal) = accept(log, line)
    membership_ledger.step(refusal)
  }
  assert step(<<"nonsense":utf8>>) == "malformed"

  let next = history.next_entry(log, Upsert(fixture.member("hub", [])))
  let assert Ok(forged) = membership_entry.seal(next, fixture.stranger_signer())
  assert step(membership_entry.line(forged)) == "bad_signature"

  let other_format =
    bit_array.from_string("{\"format\":\"loom-membership-ledger/9\"}")
  let assert Ok(signature) =
    fixture.signer()(membership_entry.signing_input(other_format))
  assert step(membership_entry.frame_line(other_format, signature))
    == "unsupported_format"
}

pub fn a_line_already_applied_is_a_duplicate_test() {
  let log = history.enroll(history.genesis(), "hub", [])
  let assert [_, hub_entry] = list.reverse(log.entries)
  assert accept(log, membership_entry.line(hub_entry)) == Ok(Duplicate)

  let genesis_line =
    membership_entry.line(
      fixture.seal(fixture.entry(
        0,
        membership_entry.genesis_prev(),
        fixture.genesis_kind(),
      )),
    )
  assert accept(log, genesis_line) == Ok(Duplicate)
}

pub fn a_different_entry_at_an_applied_sequence_is_a_fork_test() {
  let log = history.enroll(history.genesis(), "hub", [])
  let assert [_, hub_entry] = list.reverse(log.entries)

  let rival =
    fixture.seal(
      membership_entry.Entry(..hub_entry.entry, time: fixture.other_stamp),
    )
  assert rival.id != hub_entry.id
  assert accept(log, membership_entry.line(rival))
    == Error(Fork(seq: 1, ours: hub_entry.id, theirs: rival.id))
}

pub fn a_fork_of_the_genesis_is_a_fork_test() {
  let log = history.genesis()
  let assert [genesis] = log.entries
  let rival =
    fixture.seal(fixture.entry(
      0,
      membership_entry.genesis_prev(),
      Genesis(deployment: "ffffffffffffffffffffffffffffffff", authority: <<
        1:size(256),
      >>),
    ))
  assert accept(log, membership_entry.line(rival))
    == Error(Fork(seq: 0, ours: genesis.id, theirs: rival.id))
}

pub fn a_refusal_leaves_the_ledger_able_to_continue_test() {
  let log = history.enroll(history.genesis(), "hub", [])
  let before = membership_ledger.head(log.ledger)
  let assert [_, hub_entry] = list.reverse(log.entries)

  // The refused branch changes nothing, and the real next entry still applies.
  let rival =
    fixture.seal(
      membership_entry.Entry(..hub_entry.entry, time: fixture.other_stamp),
    )
  let assert Error(Fork(..)) = accept(log, membership_entry.line(rival))
  assert membership_ledger.head(log.ledger) == before
  let next = history.next_entry(log, Upsert(fixture.member("laptop", ["hub"])))
  let assert Ok(Applied(..)) = accept(log, fixture.line(next))
}

pub fn an_entry_beyond_the_next_is_a_gap_test() {
  let log = history.genesis()
  let head = membership_ledger.head(log.ledger)
  let far = fixture.entry(5, head.id, Upsert(fixture.member("hub", [])))
  assert accept(log, fixture.line(far)) == Ok(Gap(head: head))
}

pub fn a_next_entry_with_the_wrong_prev_is_a_chain_failure_test() {
  let log = history.genesis()
  let wrong =
    fixture.entry(
      1,
      membership_entry.genesis_prev(),
      Upsert(fixture.member("hub", [])),
    )
  assert accept(log, fixture.line(wrong)) == Error(Chain)
}

pub fn the_steps_are_checked_in_order_test() {
  // An entry at the next sequence number that also breaks a rule is a chain
  // failure when its prev is wrong: the chain is checked before the fold.
  let log = history.genesis()
  let bad =
    fixture.entry(
      1,
      membership_entry.genesis_prev(),
      fixture.revoke_kind("nobody"),
    )
  assert accept(log, fixture.line(bad)) == Error(Chain)

  // The same entry with the right prev reaches the fold.
  let right = history.next_entry(log, fixture.revoke_kind("nobody"))
  assert accept(log, fixture.line(right)) == Error(Invalid(NotActive("nobody")))
}

pub fn the_step_words_match_the_control_protocol_test() {
  let id = membership_entry.genesis_prev()
  assert membership_ledger.step(Fork(seq: 1, ours: id, theirs: id)) == "fork"
  assert membership_ledger.step(Chain) == "chain"
  assert membership_ledger.step(Invalid(PinInUse)) == "invalid"
  assert membership_ledger.step(Unreadable(membership_entry.BadSignature))
    == "bad_signature"
}

// --- the member rules -----------------------------------------------------------

pub fn a_genesis_after_the_first_entry_is_invalid_test() {
  assert refusal(history.genesis(), fixture.genesis_kind())
    == Invalid(membership_ledger.GenesisNotFirst)
}

pub fn a_node_name_in_use_is_invalid_test() {
  let log = history.enroll(history.genesis(), "hub", [])
  let clash =
    Member(..fixture.member("other", []), node: "loom@hub.example.net")
  assert refusal(log, Upsert(clash))
    == Invalid(NodeInUse("loom@hub.example.net"))
}

pub fn a_pin_in_use_is_invalid_test() {
  let log = history.enroll(history.genesis(), "hub", [])
  let clash =
    Member(..fixture.member("other", []), pin: fixture.pin_for("hub", 0))
  assert refusal(log, Upsert(clash)) == Invalid(PinInUse)
}

pub fn a_link_to_an_unknown_member_is_invalid_test() {
  let log = history.enroll(history.genesis(), "hub", [])
  assert refusal(log, Upsert(fixture.member("laptop", ["ghost"])))
    == Invalid(UnknownLink("ghost"))
}

pub fn a_link_to_oneself_is_invalid_test() {
  let log = history.enroll(history.genesis(), "hub", [])
  assert refusal(log, Upsert(fixture.member("laptop", ["laptop"])))
    == Invalid(UnknownLink("laptop"))
  assert refusal(log, Upsert(fixture.member("hub", ["hub"])))
    == Invalid(UnknownLink("hub"))
}

pub fn a_link_to_a_revoked_member_is_invalid_test() {
  let log =
    history.genesis()
    |> history.enroll("hub", [])
    |> history.revoke("hub")
  assert refusal(log, Upsert(fixture.member("laptop", ["hub"])))
    == Invalid(UnknownLink("hub"))
}

pub fn a_revoke_of_a_member_that_is_not_active_is_invalid_test() {
  let log = history.enroll(history.genesis(), "hub", [])
  assert refusal(log, fixture.revoke_kind("ghost"))
    == Invalid(NotActive("ghost"))
  let revoked = history.revoke(log, "hub")
  assert refusal(revoked, fixture.revoke_kind("hub"))
    == Invalid(NotActive("hub"))
}

pub fn a_revoke_records_a_pin_it_does_not_compare_test() {
  let log = history.enroll(history.genesis(), "hub", [])
  let other_pin = fixture.pin_for("someone else", 7)
  let kind = Revoke(name: "hub", pin: other_pin, reason: "audit only")
  let revoked = history.must_push(log, kind)
  assert membership_ledger.enrollment(revoked.ledger, "hub") == Revoked
}

pub fn an_amendment_keeps_the_pin_and_changes_the_rest_test() {
  let log = history.enroll(history.genesis(), "hub", [])
  let amended =
    Member(
      ..fixture.member("hub", []),
      role: Orchestrator,
      host: "hub.moved.example.net",
      listen_port: Some(4369),
    )
  let log = history.must_push(log, Upsert(amended))
  assert membership_ledger.member(log.ledger, "hub") == Ok(amended)
}

pub fn an_entry_may_keep_its_own_node_and_pin_test() {
  // The uniqueness rules compare with the other active members, so an
  // amendment that repeats the member's own node and pin is not a clash.
  let log = history.enroll(history.genesis(), "hub", [])
  let assert Ok(_) = history.push(log, Upsert(fixture.member("hub", [])))
}

pub fn a_renewal_replaces_the_pin_test() {
  let log = history.enroll(history.genesis(), "hub", [])
  let renewed =
    Member(..fixture.member("hub", []), pin: fixture.pin_for("hub", 1))
  let log = history.must_push(log, Upsert(renewed))
  let assert Ok(held) = membership_ledger.member(log.ledger, "hub")
  assert held.pin == fixture.pin_for("hub", 1)
}

pub fn a_retired_pin_may_be_taken_by_another_member_test() {
  let log =
    history.genesis()
    |> history.enroll("hub", [])
    |> history.revoke("hub")
  let heir =
    Member(..fixture.member("heir", []), pin: fixture.pin_for("hub", 0))
  let assert Ok(_) = history.push(log, Upsert(heir))
}

pub fn a_revoked_name_can_be_enrolled_again_test() {
  let log =
    history.genesis()
    |> history.enroll("hub", [])
    |> history.revoke("hub")
  assert membership_ledger.enrollment(log.ledger, "hub") == Revoked
  let again = history.enroll(log, "hub", [])
  let assert Enrolled(_) = membership_ledger.enrollment(again.ledger, "hub")
}

pub fn a_revoke_drops_the_links_that_named_the_member_test() {
  let log =
    history.genesis()
    |> history.enroll("hub", [])
    |> history.enroll("laptop", ["hub"])
    |> history.revoke("hub")
  let assert Ok(laptop) = membership_ledger.member(log.ledger, "laptop")
  assert laptop.links == []

  // The name is enrolled again later. The edge made to its previous holder
  // does not come back with it.
  let log = history.enroll(log, "hub", [])
  assert peer_names(table_of(log, "laptop")) == []
  assert peer_names(table_of(log, "hub")) == []
}

pub fn enrollment_distinguishes_never_revoked_and_active_test() {
  let log =
    history.genesis()
    |> history.enroll("hub", [])
    |> history.enroll("old", [])
    |> history.revoke("old")
  let ledger = log.ledger
  let assert Enrolled(member) = membership_ledger.enrollment(ledger, "hub")
  assert member.name == "hub"
  assert membership_ledger.enrollment(ledger, "old") == Revoked
  assert membership_ledger.enrollment(ledger, "stranger") == NotEnrolled
}

// --- the bounds ----------------------------------------------------------------

pub fn at_most_64_members_are_active_test() {
  let log =
    list.fold(names(64), history.genesis(), fn(log, name) {
      history.enroll(log, name, [])
    })
  assert list.length(membership_ledger.members(log.ledger)) == 64
  assert refusal(log, Upsert(fixture.member("extra", [])))
    == Invalid(TooManyActive)

  // Amending a member that is already active does not add one.
  let assert Ok(_) = history.push(log, Upsert(fixture.member("n0", ["n1"])))

  // A revoke makes room.
  let log = history.revoke(log, "n0")
  let assert Ok(_) = history.push(log, Upsert(fixture.member("extra", [])))
}

pub fn at_most_256_names_are_ever_enrolled_test() {
  let log =
    list.fold(names(256), history.genesis(), fn(log, name) {
      history.enroll(log, name, []) |> history.revoke(name)
    })
  assert refusal(log, Upsert(fixture.member("one-more", [])))
    == Invalid(TooManyNames)

  // A name already counted can be enrolled again.
  let assert Ok(_) = history.push(log, Upsert(fixture.member("n17", [])))
}

pub fn the_ledger_holds_at_most_10000_entries_test() {
  let full = fill(history.genesis(), 9999)
  assert membership_ledger.head(full.ledger).seq == 9999
  assert refusal(full, Upsert(fixture.member("late", [])))
    == Invalid(LedgerFull)
  assert refusal(full, fixture.revoke_kind("late")) == Invalid(LedgerFull)
}

// Appends amendments of one member until the log holds `count` more entries.
fn fill(log: history.Log, count: Int) -> history.Log {
  let seeded = history.enroll(log, "hub", [])
  amend(seeded, count - 1)
}

fn amend(log: history.Log, remaining: Int) -> history.Log {
  case remaining {
    0 -> log
    _ -> amend(history.enroll(log, "hub", []), remaining - 1)
  }
}

// --- checking an entry before it is signed -------------------------------------

pub fn check_accepts_what_the_fold_accepts_test() {
  let log = history.genesis()
  let entry = history.next_entry(log, Upsert(fixture.member("hub", [])))
  let assert Ok(next) = membership_ledger.check(log.ledger, entry)
  let assert Ok(Applied(ledger:, ..)) = accept(log, fixture.line(entry))
  assert next == ledger
}

pub fn check_refuses_what_the_fold_refuses_test() {
  let log = history.genesis()
  let entry = history.next_entry(log, fixture.revoke_kind("ghost"))
  assert membership_ledger.check(log.ledger, entry)
    == Error(Invalid(NotActive("ghost")))
}

pub fn check_refuses_an_entry_a_reader_would_refuse_test() {
  // A name with a capital encodes fine and decodes to nothing, so every node
  // would refuse the line. The signer's tool learns that before it signs.
  let log = history.genesis()
  let bad = Member(..fixture.member("hub", []), name: "Hub")
  let entry = history.next_entry(log, Upsert(bad))
  assert membership_ledger.check(log.ledger, entry)
    == Error(Unreadable(Malformed(membership_entry.FieldInvalid("name"))))
}

pub fn check_refuses_an_entry_off_the_head_test() {
  let log = history.genesis()
  let head = membership_ledger.head(log.ledger)
  let skipped = fixture.entry(3, head.id, Upsert(fixture.member("hub", [])))
  assert membership_ledger.check(log.ledger, skipped) == Error(Chain)
  let detached =
    fixture.entry(
      1,
      membership_entry.genesis_prev(),
      Upsert(fixture.member("hub", [])),
    )
  assert membership_ledger.check(log.ledger, detached) == Error(Chain)
}

// --- replaying a file ----------------------------------------------------------

pub fn replay_applies_a_file_in_order_test() {
  let log =
    history.genesis()
    |> history.enroll("hub", [])
    |> history.enroll("laptop", ["hub"])
  assert membership_ledger.replay(history.lines(log), fixture.verifier())
    == Ok(log.ledger)
}

pub fn replay_of_nothing_is_refused_test() {
  assert membership_ledger.replay([], fixture.verifier())
    == Error(membership_ledger.ReplayError(
      index: 0,
      refusal: Invalid(membership_ledger.FirstEntryNotGenesis),
    ))
}

pub fn replay_names_the_line_that_failed_test() {
  let log =
    history.genesis()
    |> history.enroll("hub", [])
    |> history.enroll("laptop", ["hub"])
  let assert [genesis, hub, laptop] = history.lines(log)
  assert membership_ledger.replay(
      [genesis, <<"junk":utf8>>, laptop],
      fixture.verifier(),
    )
    == Error(membership_ledger.ReplayError(
      index: 1,
      refusal: Unreadable(Malformed(membership_entry.LineShape)),
    ))
  assert membership_ledger.replay([genesis, hub, hub], fixture.verifier())
    == Error(membership_ledger.ReplayError(index: 2, refusal: Chain))
  assert membership_ledger.replay([genesis, laptop], fixture.verifier())
    == Error(membership_ledger.ReplayError(index: 1, refusal: Chain))
}

// --- the pin table -------------------------------------------------------------

pub fn a_member_lists_the_peers_it_links_to_test() {
  let log =
    history.genesis()
    |> history.enroll("hub", [])
    |> history.enroll("devbox", [])
    |> history.enroll("laptop", ["hub"])
  assert peer_names(table_of(log, "laptop")) == ["hub"]
}

pub fn a_link_is_symmetric_test() {
  let log =
    history.genesis()
    |> history.enroll("hub", [])
    |> history.enroll("devbox", [])
    |> history.enroll("laptop", ["hub"])
  assert peer_names(table_of(log, "hub")) == ["laptop"]
  assert peer_names(table_of(log, "devbox")) == []
}

pub fn unlinked_members_do_not_trust_each_other_test() {
  let log =
    history.genesis()
    |> history.enroll("a", [])
    |> history.enroll("b", [])
  assert membership_ledger.is_empty(table_of(log, "a"))
  assert membership_ledger.is_empty(table_of(log, "b"))
}

pub fn directory_members_are_linked_to_each_other_test() {
  let in_directory = fn(name: String, standing) {
    Upsert(Member(..fixture.member(name, []), directory: standing))
  }
  let log =
    history.genesis()
    |> history.must_push(in_directory("v1", Voter))
    |> history.must_push(in_directory("v2", Voter))
    |> history.must_push(in_directory("l1", Learner))
    |> history.must_push(in_directory("outside", NotInDirectory))
  assert peer_names(table_of(log, "v1")) == ["l1", "v2"]
  assert peer_names(table_of(log, "l1")) == ["v1", "v2"]
  assert peer_names(table_of(log, "outside")) == []
}

pub fn a_table_never_holds_its_own_member_test() {
  let log =
    history.genesis()
    |> history.must_push(Upsert(
      Member(..fixture.member("v1", []), directory: Voter),
    ))
  assert membership_ledger.is_empty(table_of(log, "v1"))
}

pub fn a_node_that_is_not_active_has_an_empty_table_test() {
  let log =
    history.genesis()
    |> history.enroll("hub", [])
    |> history.enroll("laptop", ["hub"])
    |> history.revoke("laptop")
  assert membership_ledger.is_empty(table_of(log, "laptop"))
  assert membership_ledger.is_empty(table_of(log, "stranger"))
}

pub fn a_revoked_member_leaves_every_table_test() {
  let log =
    history.genesis()
    |> history.enroll("hub", [])
    |> history.enroll("laptop", ["hub"])
  assert peer_names(table_of(log, "hub")) == ["laptop"]
  let log = history.revoke(log, "laptop")
  assert peer_names(table_of(log, "hub")) == []
}

pub fn the_table_maps_pins_and_nodes_test() {
  let log =
    history.genesis()
    |> history.must_push(Upsert(
      Member(..fixture.member("hub", []), role: Orchestrator, directory: Voter),
    ))
    |> history.enroll("laptop", ["hub"])
  let table = table_of(log, "laptop")
  let hub_pin = fixture.pin_for("hub", 0)

  let assert Ok(peer) = membership_ledger.lookup_pin(table, hub_pin)
  assert peer.name == "hub"
  assert peer.node == "loom@hub.example.net"
  assert peer.role == Orchestrator
  assert peer.directory == Voter

  assert membership_ledger.lookup_node(table, "loom@hub.example.net")
    == Ok(hub_pin)
  assert membership_ledger.lookup_pin(table, fixture.pin_for("laptop", 0))
    == Error(Nil)
  assert membership_ledger.lookup_pin(table, <<1, 2, 3>>) == Error(Nil)
  assert membership_ledger.lookup_node(table, "loom@laptop.example.net")
    == Error(Nil)
}

pub fn a_renewal_replaces_the_pin_in_the_table_test() {
  let log =
    history.genesis()
    |> history.enroll("hub", [])
    |> history.enroll("laptop", ["hub"])
  let old_pin = fixture.pin_for("hub", 0)
  let renewed =
    Member(..fixture.member("hub", []), pin: fixture.pin_for("hub", 1))
  let log = history.must_push(log, Upsert(renewed))
  let table = table_of(log, "laptop")
  assert membership_ledger.lookup_pin(table, old_pin) == Error(Nil)
  let assert Ok(peer) =
    membership_ledger.lookup_pin(table, fixture.pin_for("hub", 1))
  assert peer.name == "hub"
}

pub fn head_and_member_accessors_agree_test() {
  let log = history.enroll(history.genesis(), "hub", [])
  assert membership_ledger.head(log.ledger)
    == Head(seq: 1, id: {
      let assert [newest, ..] = log.entries
      newest.id
    })
  assert membership_ledger.member(log.ledger, "ghost") == Error(Nil)
  let assert Ok(hub) = membership_ledger.member(log.ledger, "hub")
  assert hub.role == Executor
  assert hub.listen_port == None
}
