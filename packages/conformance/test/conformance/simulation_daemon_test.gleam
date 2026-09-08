//// The daemon simulation's fault-free baseline.
////
//// Two claims, and they are separate on purpose. The first is that the
//// script converges: two runs from two temporary state roots leave the same
//// durable rows at the same catalogue fence, so the identities a daemon
//// mints are decided by the script, the logical clock and the seed. The
//// second is that a creation key reserves one identity inside a single run,
//// however the retry seeds its generator. PR 2 faults the manager between
//// the reservation and the confirmation and asks the same question again;
//// what these two record is the answer with nothing going wrong.

import conformance/simulation/daemon/daemon_runner
import gleam/list
import gleam/string

/// The script's two runs converge on the same rows and the same fence.
///
/// ## Examples
///
/// `scripts/test.sh conformance --match daemon_script_converges`.
pub fn daemon_script_converges_across_two_runs_test() {
  assert daemon_runner.run(seed: 20_260_908) == daemon_runner.Passed
}

/// A creation key reused inside one run answers with one identity.
///
/// The script retries `alpha` with a generator seeded differently from the
/// one that minted it, so a registry that consulted the generator on a retry
/// would leave three rows here rather than two.
///
/// ## Examples
///
/// `scripts/test.sh conformance --match daemon_creation_key`.
pub fn daemon_creation_key_reserves_one_identity_test() {
  let assert Ok(report) = daemon_runner.observe(4471)
    as "the fault-free daemon script completes"
  let keys = list.map(report.rows, fn(row) { row.request_key })
  assert list.sort(keys, string.compare) == ["alpha", "beta"]
  assert list.length(list.unique(list.map(report.rows, fn(row) { row.id })))
    == 2
}
