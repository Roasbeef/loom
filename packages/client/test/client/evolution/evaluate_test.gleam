import client/evolution/evaluate
import client/evolution/record
import client/evolution/record_test
import client/evolution/retirement
import client/evolution/store
import client/internal/ffi_os
import codemode/compile
import codemode/enforcement
import core/clock
import gleam/int
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import support/evolution as fixture

fn proposed() -> #(store.Store, record.Candidate, String) {
  let directory =
    "build/test_db/evolution-evaluator-"
    <> int.to_string(ffi_os.system_time_ms())
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let original = record_test.candidate()
  let candidate =
    record.identified(
      record.Candidate(
        ..original,
        files: fixture.extension(1),
        test_entry: Some("evolution_check"),
      ),
    )
  let assert Ok(catalogue) =
    store.open(
      directory <> "/catalogue",
      store.Owner,
      candidate.identity,
      clock.fixed(at: 1_700_000_000_000),
    )
    as "catalogue opens before isolated evaluation"
  store.propose(catalogue, candidate) |> should.equal(Ok(candidate))
  #(catalogue, candidate, directory <> "/scratch")
}

pub fn compiler_failure_is_durable_author_evidence_after_retirement_test() {
  let #(catalogue, candidate, scratch) = proposed()
  let build = fn(_root) {
    compile.Built(
      result: Error(compile.BuildRejected("author check has a type error")),
      enforcement: enforcement.Unreported("compiler refused"),
    )
  }
  let run = fn(_) { Error(store.Unavailable("runner must not run")) }
  let assert Ok(evidence) =
    evaluate.extension_owned(
      catalogue,
      candidate.id,
      scratch,
      build,
      run,
      retirement.repeat(fn() { Ok(Nil) }),
    )
    as "failed compilation creates durable evidence"
  evidence.verdict |> should.equal(record.Failed)
  string.contains(evidence.observation, "author check has a type error")
  |> should.be_true
  evidence.purpose |> should.equal(record.AuthorTests)
  store.read_evidence(catalogue, evidence.id) |> should.equal(Ok(evidence))
  store.approve(
    catalogue,
    candidate.id,
    evidence.id,
    candidate.scope,
    "operator",
  )
  |> should.be_error
}

pub fn unconfirmed_executor_cleanup_retains_retry_and_writes_no_evidence_test() {
  let #(catalogue, candidate, scratch) = proposed()
  let build = fn(_root) {
    compile.Built(
      result: Error(compile.BuildRejected("check failed")),
      enforcement: enforcement.Unreported("compiler refused"),
    )
  }
  let refused =
    evaluate.extension_owned(
      catalogue,
      candidate.id,
      scratch,
      build,
      fn(_) { Error(store.Unknown) },
      retirement.repeat(fn() { Error("native executor still owns workers") }),
    )
  let assert Error(store.CleanupUnconfirmed(reason, retry)) = refused
    as "cleanup witness survives failed evaluation"
  reason |> should.equal("native executor still owns workers")
  let assert Error(failure) = retirement.perform(retry)
    as "the retained continuation can ask the native owner again"
  failure.reason |> should.equal(reason)
  store.read_evidence(catalogue, record.evidence_placeholder())
  |> should.equal(Error(store.Unknown))
}

pub fn partial_trial_is_inconclusive_and_cannot_be_approved_test() {
  let #(catalogue, candidate, scratch) = proposed()
  let build = fn(root) {
    compile.Built(
      result: Ok(compile.BuildProducts(
        beam_dir: root,
        manifest_hash: "fake-built-test",
      )),
      enforcement: enforcement.Unreported("fake compiler"),
    )
  }
  let assert Ok(evidence) =
    evaluate.extension_owned(
      catalogue,
      candidate.id,
      scratch,
      build,
      fn(_) { Error(store.Unavailable("evaluation cancelled")) },
      retirement.repeat(fn() { Ok(Nil) }),
    )
    as "partial result is recorded after retirement"
  let assert record.Inconclusive(reason) = evidence.verdict
    as evidence.observation
  reason |> should.equal("evaluation cancelled")
  store.approve(
    catalogue,
    candidate.id,
    evidence.id,
    candidate.scope,
    "operator",
  )
  |> should.be_error
}
