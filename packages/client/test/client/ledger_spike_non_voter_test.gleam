//// Phase 0 of the membership ledger (docs/design-notes/membership-ledger.md,
//// sections 11.3 and 16): a Ra member added as a `non_voter` works through
//// Khepri's own reads and does not count toward the quorum. The scenario boots
//// real emulators that run the directory's Ra system and store; see
//// `client_ledger_spike_ra_fixture_ffi`.

@external(erlang, "client_ledger_spike_ra_fixture_ffi", "scenario")
fn scenario(name: String) -> Result(Nil, String)

pub fn a_non_voter_reads_and_writes_through_khepri_without_a_vote_test() {
  let assert Ok(Nil) = scenario("non_voter")
    as "A learner must serve local and consistent reads, write through the leader, stay a non-voter across traffic and a restart, and leave a lone voter without a quorum."
  Nil
}
