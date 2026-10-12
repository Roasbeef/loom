//// The learner role of the membership ledger (docs/design-notes/membership-ledger.md,
//// sections 11.3 and 16). Phase 0 measured that a Ra member added as a
//// `non_voter` works through Khepri's own reads and does not count toward the
//// quorum. Phase 3 made the production join take the membership, so the same
//// scenario now joins through `client_khepri_ffi` and proves it, and a second
//// scenario proves the removal that the Ra leader's reconciler issues. Both
//// boot real emulators that run the directory's Ra system and store; see
//// `client_ledger_spike_ra_fixture_ffi`.

@external(erlang, "client_ledger_spike_ra_fixture_ffi", "scenario")
fn scenario(name: String) -> Result(Nil, String)

pub fn a_non_voter_reads_and_writes_through_khepri_without_a_vote_test() {
  let assert Ok(Nil) = scenario("non_voter")
    as "A learner must serve local and consistent reads, write through the leader, stay a non-voter across traffic and a restart, and leave a lone voter without a quorum."
  Nil
}

// The leader removes members with the production `remove_member`, a learner
// first and then a voter, and a name Ra never held is not a member.
pub fn the_leader_removes_a_learner_and_then_a_voter_test() {
  let assert Ok(Nil) = scenario("remove_member")
    as "The leader must remove a learner and a voter, keep committing, and treat a name that is not a member as removed."
  Nil
}
