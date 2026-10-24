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
  let assert Ok(report) =
    evaluate.extension_owned(
      candidate,
      scratch,
      build,
      run,
      retirement.repeat(fn() { Ok(Nil) }),
    )
    as "failed compilation is answered as a report"
  report.verdict |> should.equal(record.Failed)

  // The check writes nothing; evidence exists only once the report is recorded.
  // Evidence is stored under its content digest, so the expected id is the one
  // the recorded observation will receive.
  let expected =
    record.observed(record.Evidence(
      id: record.evidence_placeholder(),
      candidate_id: candidate.id,
      identity: candidate.identity,
      at_ms: 1_700_000_000_000,
      purpose: record.AuthorTests,
      verdict: report.verdict,
      observation: report.observation,
    ))
  store.read_evidence(catalogue, expected.id)
  |> should.equal(Error(store.Unknown))
  let assert Ok(evidence) = evaluate.record(catalogue, candidate.id, report)
    as "the report is recorded as durable evidence"
  evidence.id |> should.equal(expected.id)
  store.read_evidence(catalogue, expected.id) |> should.be_ok
  evidence.observation |> should.equal(report.observation)
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
      candidate,
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
  let assert Ok(report) =
    evaluate.extension_owned(
      candidate,
      scratch,
      build,
      fn(_) { Error(store.Unavailable("evaluation cancelled")) },
      retirement.repeat(fn() { Ok(Nil) }),
    )
    as "partial result is answered after retirement"
  let assert Ok(evidence) = evaluate.record(catalogue, candidate.id, report)
    as "the partial report is recorded"
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

pub fn report_of_maps_each_outcome_shape_test() {
  evaluate.report_of(Ok(#(record.Passed, "{}")))
  |> should.equal(Ok(evaluate.Report(record.Passed, "{}")))

  evaluate.report_of(Error(store.TestFailed("no entry")))
  |> should.equal(
    Ok(evaluate.Report(record.Failed, "{\"refusal\":\"no entry\"}")),
  )

  evaluate.report_of(Error(store.Unavailable("cancelled")))
  |> should.equal(
    Ok(evaluate.Report(
      record.Inconclusive("cancelled"),
      "{\"refusal\":\"cancelled\"}",
    )),
  )

  // Any other refusal is no evidence at all.
  evaluate.report_of(Error(store.Unknown))
  |> should.equal(Error(store.Unknown))
}

pub fn record_writes_exactly_the_report_as_author_evidence_test() {
  let #(catalogue, candidate, _) = proposed()
  let report = evaluate.Report(record.Passed, "{\"ran\":true}")
  let assert Ok(evidence) = evaluate.record(catalogue, candidate.id, report)
    as "recording a report stores one evidence row"
  evidence.verdict |> should.equal(record.Passed)
  evidence.observation |> should.equal("{\"ran\":true}")
  evidence.purpose |> should.equal(record.AuthorTests)
  store.read_evidence(catalogue, evidence.id) |> should.equal(Ok(evidence))
}
