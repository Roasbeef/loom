//// A durable selection receipt survives a cold live queue and later generations.
//// The actor's stage callback is an observation boundary: a replay must neither
//// allocate another generation nor disturb the currently committed selection.

import client/evolution/control
import client/evolution/live
import client/evolution/queue
import client/evolution/record
import client/evolution/record_test
import client/evolution/store
import client/internal/ffi_os
import core/clock
import core/json
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import storage/access

pub fn extension_retry_after_queue_restart_never_restages_test() {
  replay(record_test.candidate())
}

pub fn workspace_program_retry_returns_original_generation_test() {
  let candidate = record_test.candidate()
  replay(record.identified(
    record.Candidate(
      ..candidate,
      kind: record.Program,
      scope: record.Workspace("/workspace"),
      files: [#("program.gleam", "pub fn run() { 1 }")],
    ),
  ))
}

fn replay(candidate: record.Candidate) {
  let assert Ok(catalogue) =
    store.open(
      "build/test_db/evolution-retry-"
        <> int.to_string(ffi_os.unique_positive_integer()),
      store.Owner,
      candidate.identity,
      clock.fixed(0),
    )
    as "the native catalogue opens under an owner capability"
  store.propose(catalogue, candidate) |> should.equal(Ok(candidate))
  let assert Ok(evidence) =
    store.record_evidence(
      catalogue,
      candidate.id,
      record.AuthorTests,
      record.Passed,
      "{}",
    )
    as "independent native evidence is retained"
  store.approve(
    catalogue,
    candidate.id,
    evidence.id,
    candidate.scope,
    "operator",
  )
  |> should.equal(Ok(Nil))
  let assert Ok(original) =
    store.select_request(
      catalogue,
      candidate.id,
      evidence.id,
      candidate.scope,
      candidate.name,
      None,
      "operator",
      "activate",
      "original-request",
    )
    as "the original request receives its durable acknowledgement"
  let assert Ok(current) =
    store.select(
      catalogue,
      candidate.id,
      evidence.id,
      candidate.scope,
      candidate.name,
      Some(original),
      "operator",
      "supersede",
    )
    as "a later selection has advanced the native generation"
  let staged = process.new_subject()
  let assert Ok(owner) =
    live.start(
      live.Config(
        clock: clock.fixed(0),
        stage: fn(_) {
          process.send(staged, Nil)
          Error(store.Unavailable("a replay must never stage"))
        },
        adopt: fn(_) { Ok(Nil) },
        recover: fn() { Ok(None) },
      ),
    )
    as "the replacement live owner has no cached request"
  let assert Ok(front) = queue.start(owner, clock.fixed(0))
    as "the replacement queue is empty"
  let door =
    control.new(
      "session-a",
      "/workspace",
      fn(authority) {
        store.open(
          store.root(catalogue),
          authority,
          candidate.identity,
          clock.fixed(0),
        )
      },
      owner,
      front,
      clock.fixed(0),
    )
  let fields = [
    #("candidate_id", json.String(record.id_string(candidate.id))),
    #("evidence_id", json.String(record.evidence_string(evidence.id))),
    #("expected_generation", json.Int(0)),
    #("reason", json.String("activate")),
    #("request_id", json.String("original-request")),
  ]
  let assert Ok(value) =
    door.command(access.Owner, "operator", "select", json.Object(fields))
    as "the exact retry recovers its original acknowledgement"
  let committed = case candidate.kind {
    record.Extension -> field(value, "committed")
    record.Program | record.Prompt -> value
  }
  field(committed, "generation") |> should.equal(json.Int(1))
  case candidate.kind {
    record.Extension -> {
      field(value, "state") |> should.equal(json.String("committed"))
      field(value, "request_id")
      |> should.equal(json.String("original-request"))
    }
    record.Program | record.Prompt -> Nil
  }
  queue.poll(front, "original-request") |> should.equal(Ok(None))
  process.receive(staged, 0) |> should.equal(Error(Nil))

  // A changed payload cannot borrow the acknowledged request's authority.
  door.command(
    access.Owner,
    "operator",
    "select",
    json.Object(list.key_set(fields, "reason", json.String("different intent"))),
  )
  |> should.equal(Error("candidate or evaluator identity changed"))
  door.command(
    access.Owner,
    "operator",
    "select",
    json.Object(list.key_set(fields, "expected_generation", json.Int(2))),
  )
  |> should.equal(Error("candidate or evaluator identity changed"))
  door.command(
    access.Owner,
    "operator",
    "select",
    json.Object(list.key_set(
      fields,
      "request_id",
      json.String("new-stale-request"),
    )),
  )
  |> should.equal(Error("selection changed"))
  store.selected(catalogue, candidate.scope, candidate.name)
  |> should.equal(Ok(Some(current)))
  process.receive(staged, 0) |> should.equal(Error(Nil))
  queue.close(front) |> should.equal(Ok(Nil))
  live.close(owner, 1000) |> should.equal(Ok(Nil))
}

fn field(value: json.JsonValue, name: String) -> json.JsonValue {
  let assert json.Object(fields) = value as "the control result is an object"
  let assert Ok(found) = list.key_find(fields, name)
    as "the expected result field exists"
  found
}
