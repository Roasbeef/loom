//// The daemon simulation's creation-key suite.
////
//// One claim, asked of a pinned corpus rather than of a range: a creation key
//// reserves one identity, and killing the daemon partway through that
//// creation does not change which identity it reserved. Each seed draws a
//// script and a schedule, runs the script fault-free, runs it again under the
//// schedule, and requires the two to end on the same catalogue rows at the
//// same revision.
////
//// The corpus is pinned rather than generated over a range because these
//// seeds are the ones that discriminate. Each covers a different step of the
//// creation the daemon is killed at, and each was checked against the
//// mutations recorded in this branch's commit messages: removing the
//// `by_request_key` lookup from `manager.reserve_creation` fails
//// `creation/one-identity-per-key` here, and letting `manager.open` admit an
//// unconfirmed reservation fails `publication/before-execute`.
////
//// A run costs two daemons and, under a kill, three, so the corpus is kept
//// small on purpose. The soak that walks a seed range is PR 5's target, not
//// this suite's.

import conformance/simulation/daemon/daemon_fault
import conformance/simulation/daemon/daemon_runner
import gleam/list
import gleam/string

/// The pinned seeds, one per creation step a schedule can kill at, plus one
/// that draws no kill at all so the fault-free path stays covered.
const corpus = [2, 4, 6, 18, 41]

/// Every pinned seed converges: the faulted run ends on the fault-free run's
/// rows, at the same catalogue revision.
///
/// ## Examples
///
/// `scripts/test.sh conformance --match daemon_creation_corpus`.
pub fn daemon_creation_corpus_converges_test() {
  let verdicts =
    list.map(corpus, fn(seed) { #(seed, daemon_runner.run(seed:)) })
  let failures =
    list.filter(verdicts, fn(verdict) { verdict.1 != daemon_runner.Passed })
  assert failures == [] as string.inspect(failures)
}

/// The corpus covers every step of a creation the taxonomy can kill at, so a
/// later edit that narrows the generator cannot silently drop a step.
///
/// ## Examples
///
/// `scripts/test.sh conformance --match daemon_creation_corpus_covers`.
pub fn daemon_creation_corpus_covers_every_step_test() {
  let steps =
    list.flat_map(corpus, fn(seed) {
      let #(_script, schedule) = daemon_runner.plan(seed)
      list.map(schedule.faults, fn(fault) {
        let daemon_fault.KillDaemonAt(step:, ..) = fault
        step
      })
    })
    |> list.unique
  assert list.length(steps) == 4 as string.inspect(steps)
}

/// A creation key reused inside one run answers with one identity, with
/// nothing going wrong.
///
/// The retry seeds its generator differently from the call that minted the
/// identity, so a registry that consulted the generator on a retry would
/// leave a second row here.
///
/// ## Examples
///
/// `scripts/test.sh conformance --match daemon_creation_key`.
pub fn daemon_creation_key_reserves_one_identity_test() {
  let assert Ok(report) = daemon_runner.observe(2, daemon_fault.none())
    as "the fault-free daemon script completes"
  let #(script, _schedule) = daemon_runner.plan(2)
  let keys = list.map(report.rows, fn(row) { row.request_key })
  assert list.sort(keys, string.compare)
    == list.sort(
      list.map(script.creations, fn(one) { one.key }),
      string.compare,
    )
  assert list.length(list.unique(list.map(report.rows, fn(row) { row.id })))
    == list.length(script.creations)
}
