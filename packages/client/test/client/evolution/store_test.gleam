import client/evolution/record
import client/evolution/record_test
import client/evolution/store
import client/internal/ffi_os
import core/clock
import core/json
import core/register
import core/tx
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import session/session
import storage/storage

fn opened() -> store.Store {
  let assert Ok(store) =
    store.open(
      "build/test_db/evolution-"
        <> int.to_string(ffi_os.system_time_ms())
        <> "-"
        <> int.to_string(ffi_os.unique_positive_integer()),
      store.Owner,
      record_test.candidate().identity,
      clock.fixed(at: 1_700_000_000_000),
    )
    as "native catalogue opens"
  store
}

fn approved(
  store: store.Store,
  candidate: record.Candidate,
) -> record.Evidence {
  store.propose(store, candidate) |> should.equal(Ok(candidate))
  let assert Ok(evidence) =
    store.record_evidence(
      store,
      candidate.id,
      record.AuthorTests,
      record.Passed,
      "{\"checks\":2}",
    )
    as "actual evaluator observation retained"
  store.approve(store, candidate.id, evidence.id, candidate.scope, "operator")
  |> should.equal(Ok(Nil))
  evidence
}

pub fn approval_evidence_selection_and_receipt_survive_reopen_test() {
  let catalogue = opened()
  let candidate = record_test.candidate()
  let evidence = approved(catalogue, candidate)
  let assert Ok(selected) =
    store.select_request(
      catalogue,
      candidate.id,
      evidence.id,
      candidate.scope,
      candidate.name,
      None,
      "operator",
      "activate",
      "request-a",
    )
    as "approval and selection commit together"
  let assert Ok(reopened) =
    store.open(
      store.root(catalogue),
      store.Owner,
      candidate.identity,
      clock.fixed(at: 1_700_000_000_001),
    )
    as "catalogue reopens after native retire witness"
  store.selected(reopened, candidate.scope, candidate.name)
  |> should.equal(Ok(Some(selected)))
  store.receipt(reopened, "request-a") |> should.equal(Ok(Some(selected)))
  store.read_evidence(reopened, evidence.id) |> should.equal(Ok(evidence))
}

pub fn superseded_request_receipt_and_aba_generation_test() {
  let catalogue = opened()
  let first = record_test.candidate()
  let second =
    record.identified(record.Candidate(..first, description: "version two"))
  let first_evidence = approved(catalogue, first)
  let second_evidence = approved(catalogue, second)
  let assert Ok(one) =
    store.select_request(
      catalogue,
      first.id,
      first_evidence.id,
      first.scope,
      first.name,
      None,
      "operator",
      "v1",
      "r1",
    )
    as "first selection commits"
  let assert Ok(two) =
    store.select(
      catalogue,
      second.id,
      second_evidence.id,
      first.scope,
      first.name,
      Some(one),
      "operator",
      "v2",
    )
    as "second selection commits"
  let assert Ok(three) =
    store.select(
      catalogue,
      first.id,
      first_evidence.id,
      first.scope,
      first.name,
      Some(two),
      "operator",
      "rollback",
    )
    as "rollback advances generation"
  three.generation |> should.equal(3)
  store.select(
    catalogue,
    second.id,
    second_evidence.id,
    first.scope,
    first.name,
    Some(one),
    "operator",
    "stale",
  )
  |> should.equal(Error(store.Stale))
  store.select_request(
    catalogue,
    first.id,
    first_evidence.id,
    first.scope,
    first.name,
    None,
    "operator",
    "v1",
    "r1",
  )
  |> should.equal(Ok(one))
  store.select_request(
    catalogue,
    second.id,
    second_evidence.id,
    first.scope,
    first.name,
    None,
    "operator",
    "v1",
    "r1",
  )
  |> should.equal(Error(store.Changed))
}

pub fn original_request_identity_survives_supersession_and_reopen_test() {
  let catalogue = opened()
  let candidate = record_test.candidate()
  let evidence = approved(catalogue, candidate)
  let assert Ok(one) =
    store.select_request(
      catalogue,
      candidate.id,
      evidence.id,
      candidate.scope,
      candidate.name,
      None,
      "operator",
      "original",
      "retry",
    )
    as "original acknowledged request commits"
  let assert Ok(two) =
    store.select_request(
      catalogue,
      candidate.id,
      evidence.id,
      candidate.scope,
      candidate.name,
      Some(one),
      "operator",
      "later generation",
      "retry-after-one",
    )
    as "the second request binds a full expected selection"
  let assert Ok(three) =
    store.select(
      catalogue,
      candidate.id,
      evidence.id,
      candidate.scope,
      candidate.name,
      Some(two),
      "operator",
      "supersede both requests",
    )
    as "a third generation supersedes both durable receipts"
  let assert Ok(reopened) =
    store.open(
      store.root(catalogue),
      store.Owner,
      candidate.identity,
      clock.fixed(2),
    )
    as "a new native capability has no in-memory request state"

  store.request_receipt(
    reopened,
    candidate.id,
    evidence.id,
    candidate.scope,
    candidate.name,
    0,
    "operator",
    "original",
    "retry",
  )
  |> should.equal(Ok(Some(one)))
  store.request_receipt(
    reopened,
    candidate.id,
    evidence.id,
    candidate.scope,
    candidate.name,
    1,
    "operator",
    "original",
    "retry",
  )
  |> should.equal(Error(store.Changed))
  store.request_receipt(
    reopened,
    candidate.id,
    evidence.id,
    candidate.scope,
    candidate.name,
    0,
    "operator",
    "changed reason",
    "retry",
  )
  |> should.equal(Error(store.Changed))
  store.request_receipt(
    reopened,
    candidate.id,
    record.evidence_placeholder(),
    candidate.scope,
    candidate.name,
    0,
    "operator",
    "original",
    "retry",
  )
  |> should.equal(Error(store.Changed))
  store.request_receipt(
    reopened,
    candidate.id,
    evidence.id,
    candidate.scope,
    candidate.name,
    0,
    "other operator",
    "original",
    "retry",
  )
  |> should.equal(Error(store.Changed))
  store.request_receipt(
    reopened,
    candidate.id,
    evidence.id,
    candidate.scope,
    candidate.name,
    1,
    "operator",
    "later generation",
    "retry-after-one",
  )
  |> should.equal(Ok(Some(two)))
  store.selected(reopened, candidate.scope, candidate.name)
  |> should.equal(Ok(Some(three)))
}

pub fn revocation_blocks_selection_and_current_invocation_test() {
  let catalogue = opened()
  let candidate = record_test.candidate()
  let evidence = approved(catalogue, candidate)
  let assert Ok(selected) =
    store.select(
      catalogue,
      candidate.id,
      evidence.id,
      candidate.scope,
      candidate.name,
      None,
      "operator",
      "v1",
    )
    as "selected version exists"
  store.revoke(catalogue, candidate.id, candidate.scope, "operator", "revoked")
  |> should.equal(Ok(Nil))
  store.authorized(catalogue, selected)
  |> should.equal(Error(store.NotApproved))
  store.select(
    catalogue,
    candidate.id,
    evidence.id,
    candidate.scope,
    candidate.name,
    Some(selected),
    "operator",
    "reselect",
  )
  |> should.equal(Error(store.NotApproved))
}

pub fn edited_candidate_and_changed_evaluator_cannot_reuse_approval_test() {
  let catalogue = opened()
  let candidate = record_test.candidate()
  let evidence = approved(catalogue, candidate)
  let changed =
    record.identified(record.Candidate(..candidate, description: "new bytes"))
  store.propose(catalogue, changed) |> should.equal(Ok(changed))
  store.approve(catalogue, changed.id, evidence.id, changed.scope, "operator")
  |> should.equal(Error(store.Changed))
  let assert Ok(new_host) =
    store.open(
      store.root(catalogue),
      store.Owner,
      record.Identity("build-v2", "extension-v1", "evaluator-v1"),
      clock.fixed(at: 1_700_000_000_001),
    )
    as "updated host opens catalogue"
  store.approve(
    new_host,
    candidate.id,
    evidence.id,
    candidate.scope,
    "operator",
  )
  |> should.equal(Error(store.Changed))
}

pub fn caller_cannot_forge_global_scope_or_operator_approval_test() {
  let catalogue = opened()
  let candidate = record_test.candidate()
  let evidence = approved(catalogue, candidate)
  let assert Ok(caller) =
    store.open(
      store.root(catalogue),
      store.Caller("session-a", "/workspace"),
      candidate.identity,
      clock.fixed(at: 1_700_000_000_001),
    )
    as "caller capability opens"
  store.approve(
    caller,
    candidate.id,
    evidence.id,
    candidate.scope,
    "forged operator",
  )
  |> should.be_error
  let foreign =
    record.identified(
      record.Candidate(
        ..candidate,
        scope: record.ExactModel(record.ModelScope("provider", "model", "api")),
      ),
    )
  store.propose(caller, foreign) |> should.be_error
  let assert Ok(other) =
    store.open(
      store.root(catalogue),
      store.Caller("session-b", "/other"),
      candidate.identity,
      clock.fixed(at: 1_700_000_000_001),
    )
    as "foreign capability opens"
  store.read_candidate(other, candidate.id) |> should.be_error
}

pub fn overlapping_catalogue_lease_returns_named_busy_test() {
  let catalogue = opened()
  let assert Ok(#(_, retire)) =
    session.open_sqlite_owned(
      path: store.root(catalogue) <> "/evolution.db",
      owner: "other",
      lease_ttl_ms: 30_000,
      clock: clock.fixed(at: 1_700_000_000_000),
    )
    as "independent writer lease acquired"
  store.catalogue(catalogue) |> should.equal(Error(store.Busy))
  retire() |> should.equal(Ok(Nil))
  store.catalogue(catalogue) |> should.equal(Ok([]))
}

pub fn corrupt_candidate_bytes_cannot_reuse_approval_test() {
  let catalogue = opened()
  let candidate = record_test.candidate()
  let evidence = approved(catalogue, candidate)
  let assert Ok(#(opened, retire)) =
    session.open_sqlite_owned(
      path: store.root(catalogue) <> "/evolution.db",
      owner: "corruption-fixture",
      lease_ttl_ms: 30_000,
      clock: clock.fixed(at: 1_700_000_000_000),
    )
    as "fixture edits persisted bytes through existing storage API"
  let tampered = record.Candidate(..candidate, description: "changed on disk")
  storage.commit(
    opened.store,
    tx.Tx(
      writes: [
        tx.SetRegister(
          register.FactCustom,
          "candidate/" <> record.id_string(candidate.id),
          register.value(json.String(record.encode_candidate(tampered))),
        ),
      ],
      expected: [],
    ),
  )
  |> should.be_ok
  retire() |> should.equal(Ok(Nil))
  store.approve(
    catalogue,
    candidate.id,
    evidence.id,
    candidate.scope,
    "operator",
  )
  |> should.be_error
}

pub fn staged_candidate_revoked_by_concurrent_operator_is_not_committed_test() {
  let catalogue = opened()
  let candidate = record_test.candidate()
  let evidence = approved(catalogue, candidate)
  let staged =
    record.Selection(
      candidate.id,
      evidence.id,
      candidate.scope,
      candidate.name,
      1,
    )
  let ready = process.new_subject()
  let completed = process.new_subject()
  let _worker =
    process.spawn(fn() {
      store.approved(catalogue, staged) |> should.equal(Ok(candidate))
      let resume = process.new_subject()
      process.send(ready, resume)
      let assert Ok(Nil) = process.receive(resume, 1000)
        as "activation waits until operator revocation commits"
      process.send(
        completed,
        store.select(
          catalogue,
          candidate.id,
          evidence.id,
          candidate.scope,
          candidate.name,
          None,
          "operator",
          "publish staged",
        ),
      )
    })
  let assert Ok(resume) = process.receive(ready, 1000)
    as "staging saw current approval"
  store.revoke(
    catalogue,
    candidate.id,
    candidate.scope,
    "operator",
    "revoke during staging",
  )
  |> should.equal(Ok(Nil))
  process.send(resume, Nil)
  process.receive(completed, 1000) |> should.equal(Ok(Error(store.NotApproved)))
}

pub fn own_prompt_author_reads_and_tests_without_global_selection_authority_test() {
  let catalogue = opened()
  let original = record_test.candidate()
  let target = record.ModelScope("test-provider", "test-model", "responses")
  let prompt =
    record.identified(
      record.Candidate(
        ..original,
        kind: record.Prompt,
        scope: record.ExactModel(target),
        files: [#("prompt.json", "{}")],
        test_entry: None,
      ),
    )
  let assert Ok(caller) =
    store.open(
      store.root(catalogue),
      store.Caller("session-a", "/workspace"),
      prompt.identity,
      clock.fixed(at: 1_700_000_000_002),
    )
    as "author obtains only its source-bound read capability"
  let assert Ok(author) = store.model_author(caller, target)
    as "native resolution admits the exact authoring target"
  store.propose(author, prompt) |> should.equal(Ok(prompt))
  store.read_candidate(caller, prompt.id) |> should.equal(Ok(prompt))
  let assert Ok(evidence) =
    store.record_evidence(
      caller,
      prompt.id,
      record.IndependentRollout,
      record.Passed,
      "{\"baseline\":\"host-observation\"}",
    )
    as "the native evaluator persists visible evidence for the originating caller"
  store.read_evidence(caller, evidence.id) |> should.equal(Ok(evidence))
  store.approve(caller, prompt.id, evidence.id, prompt.scope, "forged owner")
  |> should.be_error
  let assert Ok(foreign) =
    store.open(
      store.root(catalogue),
      store.Caller("session-b", "/workspace"),
      prompt.identity,
      clock.fixed(at: 1_700_000_000_003),
    )
    as "a different source session opens its own constrained capability"
  store.read_candidate(foreign, prompt.id) |> should.be_error
  store.read_evidence(foreign, evidence.id) |> should.be_error
}

pub fn exact_model_aliases_share_one_generation_slot_test() {
  let catalogue = opened()
  let original = record_test.candidate()
  let first_scope =
    record.ExactModel(record.ModelScope("provider", "model-a", "responses"))
  let other_scope =
    record.ExactModel(record.ModelScope("provider", "model-b", "responses"))
  let alpha =
    record.identified(
      record.Candidate(
        ..original,
        kind: record.Prompt,
        scope: first_scope,
        name: "alpha",
        files: [#("prompt.json", "{}")],
        test_entry: None,
      ),
    )
  let beta = record.identified(record.Candidate(..alpha, name: "beta"))
  let other = record.identified(record.Candidate(..alpha, scope: other_scope))
  let alpha_evidence = approved_prompt(catalogue, alpha)
  let beta_evidence = approved_prompt(catalogue, beta)
  let other_evidence = approved_prompt(catalogue, other)
  let assert Ok(first) =
    store.select(
      catalogue,
      alpha.id,
      alpha_evidence.id,
      first_scope,
      alpha.name,
      None,
      "operator",
      "first model profile",
    )
    as "the first alias occupies its exact model slot"
  let assert Ok(independent) =
    store.select(
      catalogue,
      other.id,
      other_evidence.id,
      other_scope,
      other.name,
      None,
      "operator",
      "other model profile",
    )
    as "a different exact target occupies an independent slot"
  store.select(
    catalogue,
    beta.id,
    beta_evidence.id,
    first_scope,
    beta.name,
    None,
    "operator",
    "forget predecessor",
  )
  |> should.equal(Error(store.Stale))
  let assert Ok(second) =
    store.select(
      catalogue,
      beta.id,
      beta_evidence.id,
      first_scope,
      beta.name,
      Some(first),
      "operator",
      "replace alias",
    )
    as "a new alias supersedes the exact target with predecessor CAS"
  second.generation |> should.equal(2)
  store.selected(catalogue, first_scope, alpha.name)
  |> should.equal(Ok(Some(second)))
  store.selected(catalogue, first_scope, beta.name)
  |> should.equal(Ok(Some(second)))
  store.selected(catalogue, other_scope, other.name)
  |> should.equal(Ok(Some(independent)))
  store.authorized(catalogue, first) |> should.equal(Error(store.Stale))
}

fn approved_prompt(
  catalogue: store.Store,
  candidate: record.Candidate,
) -> record.Evidence {
  store.propose(catalogue, candidate) |> should.equal(Ok(candidate))
  let assert Ok(evidence) =
    store.record_evidence(
      catalogue,
      candidate.id,
      record.IndependentRollout,
      record.Passed,
      "{\"baseline\":\"measured\"}",
    )
    as "independent rollout evidence binds the immutable profile"
  store.approve(
    catalogue,
    candidate.id,
    evidence.id,
    candidate.scope,
    "operator",
  )
  |> should.equal(Ok(Nil))
  evidence
}

pub fn oversized_description_and_skill_schema_refuse_before_retention_test() {
  let catalogue = opened()
  let original = record_test.candidate()
  store.propose(
    catalogue,
    record.identified(
      record.Candidate(..original, description: string.repeat("é", 2049)),
    ),
  )
  |> should.be_error
  store.propose(
    catalogue,
    record.identified(
      record.Candidate(
        ..original,
        kind: record.Program,
        input_schema: string.repeat("x", 16_385),
        files: [#("program.gleam", "pub fn run() { 1 }")],
      ),
    ),
  )
  |> should.be_error
  store.propose(
    catalogue,
    record.identified(
      record.Candidate(
        ..original,
        kind: record.Program,
        input_schema: "[]",
        files: [#("program.gleam", "pub fn run() { 1 }")],
      ),
    ),
  )
  |> should.be_error
  store.catalogue(catalogue) |> should.equal(Ok([]))
}

pub fn complete_extension_descriptor_is_bounded_before_retention_test() {
  let catalogue = opened()
  let original = record_test.candidate()
  let candidate =
    record.identified(
      record.Candidate(
        ..original,
        files: list.map(original.files, fn(file) {
          case file.0 {
            "schema/example.json" -> #(
              file.0,
              "{\"description\":\"" <> string.repeat("x", 24_000) <> "\"}",
            )
            _ -> file
          }
        }),
      ),
    )
  store.propose(catalogue, candidate) |> should.be_error
  let escaped =
    record.identified(
      record.Candidate(..original, description: string.repeat("\n", 3000)),
    )
  store.propose(catalogue, escaped) |> should.be_error
  store.catalogue(catalogue) |> should.equal(Ok([]))
}
