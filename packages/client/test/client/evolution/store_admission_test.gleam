//// Catalogue admission tests borrow the real fenced SQLite writer.
//// Independent native capabilities wait only before acquiring custody; once
//// admitted, selection and deadline checks execute exactly once.

import client/evolution/record
import client/evolution/record_test
import client/evolution/store
import client/internal/ffi_os
import core/clock
import gleam/erlang/process
import gleam/int
import gleam/option.{None, Some}
import gleeunit/should
import session/session
import weft

pub fn independent_capabilities_wait_then_commit_once_and_recover_receipt_test() {
  let #(catalogue, candidate, evidence) = approved()
  let assert Ok(independent) =
    store.open(
      store.root(catalogue),
      store.Owner,
      candidate.identity,
      clock.fixed(1_700_000_000_000),
    )
    as "another native capability targets the same canonical catalogue"
  let retire = held(catalogue)
  let started = process.new_subject()
  let calls = process.new_subject()
  let outcomes = process.new_subject()
  let run =
    weft.new_prepared([
      weft.managed(fn(_ledger) {
        process.send(started, Nil)
        store.select_request_admitted(
          independent,
          candidate.id,
          evidence.id,
          candidate.scope,
          candidate.name,
          None,
          "operator",
          "activate",
          "contended",
          fn() {
            process.send(calls, Nil)
            Ok(Nil)
          },
        )
      }),
    ])
  let _relay = weft.start_relayed(run, to: outcomes)
  process.receive(started, 1000) |> should.equal(Ok(Nil))
  process.receive(outcomes, 20) |> should.equal(Error(Nil))
  process.receive(calls, 0) |> should.equal(Error(Nil))

  // Releasing the predecessor's actual writer lease admits one CAS. The work
  // callback was never invoked by refused opens and cannot be replayed by poll.
  retire() |> should.equal(Ok(Nil))
  let assert Ok(weft.PulledOutcome(weft.Completed(_, selected))) =
    process.receive(outcomes, 2000)
    as "the independent caller acquires and retires its own writer"
  process.receive(outcomes, 1000) |> should.equal(Ok(weft.AllDelivered))
  process.receive(calls, 0) |> should.equal(Ok(Nil))
  process.receive(calls, 0) |> should.equal(Error(Nil))
  store.selected(catalogue, candidate.scope, candidate.name)
  |> should.equal(Ok(Some(selected)))

  // An expired retry recovers the exact committed receipt before consulting
  // admission. Expiry is a condition for a new commit, not for an old receipt.
  store.select_request_admitted(
    independent,
    candidate.id,
    evidence.id,
    candidate.scope,
    candidate.name,
    None,
    "operator",
    "activate",
    "contended",
    fn() {
      process.send(calls, Nil)
      Error(store.Busy)
    },
  )
  |> should.equal(Ok(selected))
  process.receive(calls, 0) |> should.equal(Error(Nil))
}

pub fn deadline_refusal_after_contended_admission_writes_no_selection_test() {
  let #(catalogue, candidate, evidence) = approved()
  let retire = held(catalogue)
  let admission_clock = clock.from_function(ffi_os.system_time_ms)
  let expires_at = clock.read(admission_clock).0 + 10
  let started = process.new_subject()
  let calls = process.new_subject()
  let outcomes = process.new_subject()
  let run =
    weft.new_prepared([
      weft.managed(fn(_ledger) {
        process.send(started, Nil)
        store.select_request_admitted(
          catalogue,
          candidate.id,
          evidence.id,
          candidate.scope,
          candidate.name,
          None,
          "operator",
          "expired",
          "deadline",
          fn() {
            process.send(calls, Nil)
            case clock.read(admission_clock).0 < expires_at {
              True -> Ok(Nil)
              False -> Error(store.Busy)
            }
          },
        )
      }),
    ])
  let _relay = weft.start_relayed(run, to: outcomes)
  process.receive(started, 1000) |> should.equal(Ok(Nil))
  process.receive(outcomes, 20) |> should.equal(Error(Nil))
  process.receive(calls, 0) |> should.equal(Error(Nil))

  // This is the queued transition's last admission boundary, after its lease
  // wait but before any new selection or receipt is committed.
  retire() |> should.equal(Ok(Nil))
  let assert Ok(weft.PulledOutcome(weft.Failed(_, reason))) =
    process.receive(outcomes, 2000)
    as "expired admission remains a named refusal"
  reason |> should.equal(store.Busy)
  process.receive(outcomes, 1000) |> should.equal(Ok(weft.AllDelivered))
  process.receive(calls, 0) |> should.equal(Ok(Nil))
  process.receive(calls, 0) |> should.equal(Error(Nil))
  store.selected(catalogue, candidate.scope, candidate.name)
  |> should.equal(Ok(None))
  store.receipt(catalogue, "deadline") |> should.equal(Ok(None))
}

fn approved() -> #(store.Store, record.Candidate, record.Evidence) {
  let candidate = record_test.candidate()
  let assert Ok(catalogue) =
    store.open(
      "build/test_db/evolution-admission-"
        <> int.to_string(ffi_os.system_time_ms())
        <> "-"
        <> int.to_string(ffi_os.unique_positive_integer()),
      store.Owner,
      candidate.identity,
      clock.fixed(1_700_000_000_000),
    )
    as "a fresh native catalogue opens"
  store.propose(catalogue, candidate) |> should.equal(Ok(candidate))
  let assert Ok(evidence) =
    store.record_evidence(
      catalogue,
      candidate.id,
      record.AuthorTests,
      record.Passed,
      "{}",
    )
    as "independent author evidence is retained"
  store.approve(
    catalogue,
    candidate.id,
    evidence.id,
    candidate.scope,
    "operator",
  )
  |> should.equal(Ok(Nil))
  #(catalogue, candidate, evidence)
}

fn held(catalogue: store.Store) {
  let assert Ok(#(_, retire)) =
    session.open_sqlite_owned(
      path: store.root(catalogue) <> "/evolution.db",
      owner: "independent-writer",
      lease_ttl_ms: 30_000,
      clock: clock.fixed(1_700_000_000_000),
    )
    as "a separate native writer owns the actual fenced lease"
  retire
}
