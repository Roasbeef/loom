//// The domain-retirement corpus varies the saved target and duplicate count.
//// Each seed compares a fully retired baseline with an open acknowledged while
//// original domain cleanup is held, using real registry and custody messages.

import conformance/simulation/daemon/domain_runner.{
  LastSession, SavedPeer, Script,
}
import gleam/int
import gleam/list

/// Four seeds cover both saved targets and both duplicate-open counts.
pub const corpus = [20_260_912, 20_260_913, 20_260_914, 20_260_915]

/// Pins the workload combinations so changing the corpus cannot lose a case.
///
/// ## Examples
///
/// `scripts/test.sh conformance --match domain_corpus_covers`.
pub fn domain_corpus_covers_every_script_test() {
  let scripts = list.map(corpus, domain_runner.plan) |> list.unique
  assert list.length(scripts) == 4
  assert list.contains(scripts, Script(LastSession, 1))
  assert list.contains(scripts, Script(LastSession, 2))
  assert list.contains(scripts, Script(SavedPeer, 1))
  assert list.contains(scripts, Script(SavedPeer, 2))
}

/// Every script preserves admission, custody ordering and durable convergence.
///
/// ## Examples
///
/// `scripts/test.sh conformance --match domain_corpus_converges`.
pub fn domain_corpus_converges_test() {
  list.each(corpus, fn(seed) {
    case domain_runner.run(seed:) {
      Ok(Nil) -> Nil
      Error(failure) -> {
        let report =
          failure.check
          <> ": "
          <> failure.detail
          <> "\nreproduce: domain_runner.run(seed: "
          <> int.to_string(seed)
          <> ")"
        panic as report
      }
    }
  })
}
