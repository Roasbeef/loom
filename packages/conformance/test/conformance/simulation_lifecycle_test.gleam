//// The daemon simulation's faulted lifecycle and revocation scripts.
////
//// Three claims. The first is convergence: a daemon killed with a lifecycle
//// request in flight, restarted over the same state root, leaves the
//// catalogue where an orderly run left it. The second is that the restart
//// resumes nothing on the owner's behalf. The third is that a revoked
//// principal is refused at the admission boundary, including for a command
//// admitted while its grant was still live.
////
//// The seed corpus is small and fixed. Each seed draws which lifecycle
//// request is interrupted and where the revocation lands, so four seeds
//// covering the four combinations discriminate more than forty drawn at
//// random would, and the gate budget is real: every one of these runs a real
//// root over a real catalogue on a real temporary directory.

import conformance/simulation/daemon/lifecycle_faults.{
  BeforeAdmission, BetweenAdmissionAndDelivery, PendingOpen, PendingStop,
}
import conformance/simulation/daemon/lifecycle_runner
import gleam/list

/// The pinned corpus. Between them these seeds cover an interrupted open and
/// an interrupted stop, and a revocation landing before admission and between
/// admission and delivery.
pub const corpus = [20_260_908, 20_260_909, 20_260_910, 20_260_911]

/// The corpus covers all four schedules the two draws can produce.
///
/// This is a property of the corpus rather than of the daemon, and it is
/// asserted so that a later edit of the seed list cannot quietly drop a
/// schedule while the suite stays green.
///
/// ## Examples
///
/// `scripts/test.sh conformance --match lifecycle_corpus_covers`.
pub fn lifecycle_corpus_covers_every_schedule_test() {
  let drawn =
    list.unique(
      list.map(corpus, fn(seed) {
        #(
          lifecycle_faults.pending_for(seed),
          lifecycle_faults.coordinate_for(seed),
        )
      }),
    )
  assert list.length(drawn) == 4
  assert list.contains(drawn, #(PendingOpen, BeforeAdmission))
  assert list.contains(drawn, #(PendingOpen, BetweenAdmissionAndDelivery))
  assert list.contains(drawn, #(PendingStop, BeforeAdmission))
  assert list.contains(drawn, #(PendingStop, BetweenAdmissionAndDelivery))
}

/// Every pinned seed converges and every named check holds.
///
/// ## Examples
///
/// `scripts/test.sh conformance --match lifecycle_corpus_converges`.
pub fn lifecycle_corpus_converges_test() {
  list.each(corpus, fn(seed) {
    assert lifecycle_runner.run(seed:) == lifecycle_runner.Passed
  })
}
