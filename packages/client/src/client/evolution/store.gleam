//// The central evolution catalogue owns approval and selection authority.
//// Each operation holds a fenced SQLite lease only while reading and committing.
//// The separate retirement capability proves release before any jailed work.
////
//// ## Flow
////
//// `open` → `propose` → `record_evidence` → `approve` → `select_request` → `authorized` → `revoke`.
//// `with_session` owns fenced borrowing and RETIRE; `commit` atomically writes
//// audit and CAS guards. `receipt` recovers an acknowledgement without replay.
////
//// Candidate and evidence envelopes are retained in bounded registers; events
//// remain write-once audit entries and selections use generation-aware CAS.

import client/evolution/record
import client/extension/manifest
import client/internal/ffi_os
import codemode/vet/package
import core/clock.{type Clock}
import core/entry
import core/ids
import core/json as value
import core/register
import core/tx
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session/session
import simplifile
import storage/sqlite
import storage/storage
import tools/fs

/// A native host's catalogue capability.
pub type Authority {
  /// Origin-bound model tools, which cannot approve or select.
  Caller(session_id: String, workspace: String)

  /// The authenticated daemon owner.
  Owner

  /// An authenticated session operator, confined to this live session.
  SessionOperator(session_id: String, workspace: String)

  /// A model author admitted for the host's current exact resolved target.
  ModelAuthor(session_id: String, workspace: String, target: record.ModelScope)
}

/// Named lifecycle refusals preserve the failing boundary.
pub type Refusal {
  /// Another fenced transaction owns the catalogue.
  Busy

  /// Persisted bytes failed verification.
  Corrupt(reason: String)

  /// The requested immutable identity is absent.
  Unknown

  /// The expected generation changed.
  Stale

  /// There is no current approval for these exact inputs.
  NotApproved

  /// Build, seam or evaluator identity changed.
  Changed

  /// A bounded resource admission failed.
  Bounds(reason: String)

  /// Native caller authority does not admit the operation.
  Authority(reason: String)

  /// Required evidence did not pass.
  TestFailed(reason: String)

  /// Retirement is unproven; the owner must retain this retry witness.
  CleanupUnconfirmed(reason: String, retire: fn() -> Result(Nil, String))

  /// A native dependency failed.
  Unavailable(reason: String)
}

/// An address and native authority, with no retained database connection.
pub opaque type Store {
  Store(
    root: String,
    authority: Authority,
    identity: record.Identity,
    clock: Clock,
  )
}

/// The total retained source and observation budget.
pub const max_retained_bytes = 33_554_432

/// The bounded candidate catalogue.
pub const max_candidates = 128

/// One candidate's complete source budget.
pub const max_candidate_bytes = 1_048_576

/// One evaluator observation budget.
pub const max_evidence_bytes = 65_536

/// The bounded evidence catalogue.
pub const max_evidence = 256

/// Builds an origin-bound catalogue capability.
///
/// ## Examples
///
/// `open(root, Caller(session, workspace), identity, clock)` admits proposals.
pub fn open(
  root: String,
  authority: Authority,
  identity: record.Identity,
  clock: Clock,
) -> Result(Store, Refusal) {
  use Nil <- result.try(
    simplifile.create_directory_all(root)
    |> result.map_error(fn(error) {
      Unavailable(simplifile.describe_error(error))
    }),
  )
  use absolute <- result.try(
    simplifile.resolve(root)
    |> result.map_error(fn(error) {
      Unavailable(simplifile.describe_error(error))
    }),
  )
  use root <- result.try(
    fs.resolve_real(fs.real_filesystem(), "/", absolute)
    |> result.map_error(fn(error) { Authority(string.inspect(error)) }),
  )
  Ok(Store(root:, authority:, identity:, clock:))
}

/// Narrows model proposal authority to a native resolved target.
///
/// The target callback belongs to the provider host. Authored JSON never calls
/// this constructor with a provider or model of its own choosing.
///
/// ## Examples
///
/// `model_author(caller_store,current_target)` admits only that target's proposals.
pub fn model_author(
  store: Store,
  target: record.ModelScope,
) -> Result(Store, Refusal) {
  case store.authority {
    Caller(session_id, workspace)
    | SessionOperator(session_id, workspace)
    | ModelAuthor(session_id, workspace, _) ->
      Ok(Store(..store, authority: ModelAuthor(session_id, workspace, target)))
    Owner ->
      Error(Authority("model tools require origin-bound author capability"))
  }
}

/// Returns the protected catalogue directory.
///
/// ## Examples
///
/// `root(store)` must be excluded from all agent jails.
pub fn root(store: Store) -> String {
  store.root
}

/// Returns the host's current evaluator identity.
///
/// ## Examples
///
/// `identity(store)` is bound into every new observation.
pub fn identity(store: Store) -> record.Identity {
  store.identity
}

/// Admits immutable candidate bytes under native provenance and storage bounds.
///
/// ## Examples
///
/// `propose(store, candidate)` refuses a forged content address.
pub fn propose(
  store: Store,
  candidate: record.Candidate,
) -> Result(record.Candidate, Refusal) {
  use Nil <- result.try(admit_source(candidate))
  use Nil <- result.try(admit_origin(store, candidate))
  use Nil <- result.try(current(store, candidate.identity))
  use Nil <- result.try(case record.identified(candidate).id == candidate.id {
    True -> Ok(Nil)
    False -> Error(Changed)
  })
  let text = record.encode_candidate(candidate)
  use Nil <- result.try(bound(text, max_candidate_bytes, "candidate source"))
  use _ <- result.try(
    with_session(store, fn(opened) {
      retain(
        opened,
        "candidate/" <> record.id_string(candidate.id),
        text,
        "candidates",
        max_candidates,
        store.clock,
      )
    }),
  )
  Ok(candidate)
}

/// Reads verified bytes through the host's origin-bound capability.
///
/// ## Examples
///
/// `read_candidate(store, id)` refuses foreign session proposals.
pub fn read_candidate(
  store: Store,
  id: record.CandidateId,
) -> Result(record.Candidate, Refusal) {
  with_session(store, fn(opened) { candidate_in(store, opened, id) })
}

/// Returns the bounded candidate inventory visible to this capability.
///
/// ## Examples
///
/// `catalogue(store)` never performs an unbounded source scan.
pub fn catalogue(store: Store) -> Result(List(record.Candidate), Refusal) {
  with_session(store, fn(opened) {
    use ids <- result.try(index(opened, "candidates"))
    use records <- result.try(
      list.try_map(ids, fn(key) {
        use text <- result.try(required(opened, key))
        record.decode_candidate(text) |> result.map_error(Corrupt)
      }),
    )
    Ok(
      list.filter(records, fn(candidate) {
        result.is_ok(visible(store, candidate))
      }),
    )
  })
}

/// Retains a host observation after the actual evaluator has finished.
///
/// ## Examples
///
/// `record_evidence(store, id, AuthorTests, Passed, observation)` stamps identity.
pub fn record_evidence(
  store: Store,
  id: record.CandidateId,
  purpose: record.Purpose,
  verdict: record.Verdict,
  observation: String,
) -> Result(record.Evidence, Refusal) {
  use Nil <- result.try(bound(
    observation,
    max_evidence_bytes,
    "evaluator observation",
  ))
  use parsed <- result.try(
    value.parse(observation)
    |> result.replace_error(Corrupt("observation must be JSON")),
  )
  let #(at_ms, _) = clock.read(store.clock)
  let evidence =
    record.observed(record.Evidence(
      id: record.evidence_placeholder(),
      candidate_id: id,
      identity: store.identity,
      at_ms:,
      purpose:,
      verdict:,
      observation: value.to_string(value.canonical(parsed)),
    ))
  use _ <- result.try(
    with_session(store, fn(opened) {
      use candidate <- result.try(candidate_in(store, opened, id))
      use Nil <- result.try(current(store, candidate.identity))
      retain(
        opened,
        "evidence/" <> record.evidence_string(evidence.id),
        record.encode_evidence(evidence),
        "evidence",
        max_evidence,
        store.clock,
      )
    }),
  )
  Ok(evidence)
}

/// Reads an observation only after admitting its originating candidate.
///
/// ## Examples
///
/// `read_evidence(store, id)` verifies both envelope identities.
pub fn read_evidence(
  store: Store,
  id: record.EvidenceId,
) -> Result(record.Evidence, Refusal) {
  with_session(store, fn(opened) {
    use evidence <- result.try(evidence_in(opened, id))
    use _ <- result.try(candidate_in(store, opened, evidence.candidate_id))
    Ok(evidence)
  })
}

/// Approves exact current bytes and evidence through an owner capability.
///
/// ## Examples
///
/// `approve(store, id, evidence, scope, operator)` never accepts author metadata.
pub fn approve(
  store: Store,
  id: record.CandidateId,
  evidence_id: record.EvidenceId,
  scope: record.Scope,
  principal: String,
) -> Result(Nil, Refusal) {
  use Nil <- result.try(owner(store, scope, principal))
  with_session(store, fn(opened) {
    use candidate <- result.try(candidate_in(store, opened, id))
    use evidence <- result.try(evidence_in(opened, evidence_id))
    use Nil <- result.try(approvable(store, candidate, evidence, scope))
    let key = approval_key(id, scope)
    use prior <- result.try(cell(opened, key))
    commit(
      opened,
      [set(key, approval_text(id, evidence_id, scope, principal))],
      [expect(key, prior)],
      "approved",
      approval_text(id, evidence_id, scope, principal),
      store.clock,
    )
  })
}

/// Revokes approval durably; concurrent selections CAS this same register.
///
/// ## Examples
///
/// `revoke(store, id, scope, operator, reason)` prevents future selection.
pub fn revoke(
  store: Store,
  id: record.CandidateId,
  scope: record.Scope,
  principal: String,
  reason: String,
) -> Result(Nil, Refusal) {
  use Nil <- result.try(owner(store, scope, principal))
  with_session(store, fn(opened) {
    let key = approval_key(id, scope)
    use prior <- result.try(cell(opened, key))
    commit(
      opened,
      [tx.DeleteRegister(register.FactCustom, key)],
      [expect(key, prior)],
      "revoked",
      json.to_string(
        json.object([
          #("candidate", json.string(record.id_string(id))),
          #("scope", record.encode_scope(scope)),
          #("principal", json.string(principal)),
          #("reason", json.string(reason)),
        ]),
      ),
      store.clock,
    )
  })
}

/// Reads the authoritative committed selection.
///
/// ## Examples
///
/// `selected(store, scope, name)` retains its publication generation.
pub fn selected(
  store: Store,
  scope: record.Scope,
  name: String,
) -> Result(Option(record.Selection), Refusal) {
  use Nil <- result.try(scope_visible(store, scope))
  with_session(store, fn(opened) { selection_in(opened, scope, name) })
}

/// Publishes after current approval and expected generation both hold.
///
/// The caller stages and proves predecessor retirement before committing here.
/// A rollback uses this same operation, advancing rather than resetting generation.
///
/// ## Examples
///
/// `select(store, id, evidence, scope, name, expected, owner, reason)` is ABA-safe.
pub fn select(
  store: Store,
  id: record.CandidateId,
  evidence_id: record.EvidenceId,
  scope: record.Scope,
  name: String,
  expected: Option(record.Selection),
  principal: String,
  reason: String,
) -> Result(record.Selection, Refusal) {
  select_request(
    store,
    id,
    evidence_id,
    scope,
    name,
    expected,
    principal,
    reason,
    "",
  )
}

/// Publishes an idempotent operator request with its durable exact receipt.
///
/// Replaying a completed request returns its original generation even after a
/// later activation superseded it. Reusing a token with changed inputs refuses.
///
/// ## Examples
///
/// `select_request(store,id,evidence,scope,name,expected,owner,reason,token)` recovers lost acknowledgements.
pub fn select_request(
  store: Store,
  id: record.CandidateId,
  evidence_id: record.EvidenceId,
  scope: record.Scope,
  name: String,
  expected: Option(record.Selection),
  principal: String,
  reason: String,
  request_id: String,
) -> Result(record.Selection, Refusal) {
  use Nil <- result.try(owner(store, scope, principal))
  use Nil <- result.try(bound(request_id, 256, "operator request id"))
  use Nil <- result.try(bound(reason, 4096, "operator reason"))
  let signature =
    json.to_string(
      json.object([
        #("candidate", json.string(record.id_string(id))),
        #("evidence", json.string(record.evidence_string(evidence_id))),
        #("scope", record.encode_scope(scope)),
        #("name", json.string(name)),
        #("expected", case expected {
          None -> json.null()
          Some(selection) -> json.string(encode_selection(selection))
        }),
        #("principal", json.string(principal)),
        #("reason", json.string(reason)),
      ]),
    )
  with_session(store, fn(opened) {
    use prior <- result.try(receipt_in(opened, request_id))
    case prior {
      Some(#(written_signature, selection)) ->
        case written_signature == signature {
          True -> Ok(selection)
          False -> Error(Changed)
        }
      None ->
        select_new(
          store,
          opened,
          id,
          evidence_id,
          scope,
          name,
          expected,
          reason,
          request_id,
          signature,
        )
    }
  })
}

/// Reads a completed activation receipt through the caller's scope capability.
///
/// ## Examples
///
/// `receipt(store, token)` returns the committed generation for that request.
pub fn receipt(
  store: Store,
  request_id: String,
) -> Result(Option(record.Selection), Refusal) {
  with_session(store, fn(opened) {
    use prior <- result.try(receipt_in(opened, request_id))
    case prior {
      None -> Ok(None)
      Some(#(_, selection)) -> {
        use Nil <- result.try(scope_visible(store, selection.scope))
        Ok(Some(selection))
      }
    }
  })
}

fn select_new(
  store: Store,
  opened: session.Session,
  id: record.CandidateId,
  evidence_id: record.EvidenceId,
  scope: record.Scope,
  name: String,
  expected: Option(record.Selection),
  reason: String,
  request_id: String,
  signature: String,
) -> Result(record.Selection, Refusal) {
  use candidate <- result.try(candidate_in(store, opened, id))
  use evidence <- result.try(evidence_in(opened, evidence_id))
  use Nil <- result.try(approvable(store, candidate, evidence, scope))
  use Nil <- result.try(case candidate.name == name {
    True -> Ok(Nil)
    False -> Error(Changed)
  })
  let approved_key = approval_key(id, scope)
  use approved <- result.try(cell(opened, approved_key))
  use Nil <- result.try(approved_evidence(approved, evidence_id))
  let key = selection_key(scope, name)
  use prior <- result.try(cell(opened, key))
  use actual <- result.try(selection_in(opened, scope, name))
  use Nil <- result.try(case actual == expected {
    True -> Ok(Nil)
    False -> Error(Stale)
  })
  let generation = case actual {
    None -> 1
    Some(selection) -> selection.generation + 1
  }
  let selection =
    record.Selection(candidate_id: id, evidence_id:, scope:, name:, generation:)

  use #(receipt_writes, receipt_expected) <- result.try(receipt_writes(
    opened,
    request_id,
    signature,
    selection,
  ))

  // Approval and selection seqs are checked together before any event is written.
  use Nil <- result.try(commit(
    opened,
    [set(key, encode_selection(selection)), ..receipt_writes],
    [expect(key, prior), expect(approved_key, approved), ..receipt_expected],
    "selected",
    reason <> ": " <> encode_selection(selection),
    store.clock,
  ))
  Ok(selection)
}

fn receipt_in(
  opened: session.Session,
  request_id: String,
) -> Result(Option(#(String, record.Selection)), Refusal) {
  case request_id {
    "" -> Ok(None)
    _ -> {
      use found <- result.try(cell(opened, "receipt/" <> request_id))
      case found {
        None -> Ok(None)
        Some(register) -> {
          use text <- result.try(text_of(register))
          let decoder = {
            use signature <- decode.field("signature", decode.string)
            use selection_text <- decode.field("selection", decode.string)
            decode.success(#(signature, selection_text))
          }
          use decoded <- result.try(
            json.parse(text, decoder)
            |> result.replace_error(Corrupt("invalid request receipt")),
          )
          use selection <- result.try(
            json.parse(decoded.1, selection_decoder())
            |> result.replace_error(Corrupt("invalid receipt selection")),
          )
          Ok(Some(#(decoded.0, selection)))
        }
      }
    }
  }
}

fn receipt_writes(
  opened: session.Session,
  request_id: String,
  signature: String,
  selection: record.Selection,
) -> Result(#(List(tx.Write), List(tx.SeqExpectation)), Refusal) {
  case request_id {
    "" -> Ok(#([], []))
    _ -> {
      use retained <- result.try(index(opened, "receipts"))
      use Nil <- result.try(case list.length(retained) < 512 {
        True -> Ok(Nil)
        False -> Error(Bounds("operator request receipts"))
      })
      let key = "receipt/" <> request_id
      let text =
        json.to_string(
          json.object([
            #("signature", json.string(signature)),
            #("selection", json.string(encode_selection(selection))),
          ]),
        )
      use Nil <- result.try(bound(text, max_evidence_bytes, "selection receipt"))
      use prior_index <- result.try(cell(opened, "index/receipts"))
      Ok(
        #(
          [
            set(key, text),
            set(
              "index/receipts",
              json.to_string(json.array([key, ..retained], json.string)),
            ),
          ],
          [
            tx.Expect(register.FactCustom, key, None),
            expect("index/receipts", prior_index),
          ],
        ),
      )
    }
  }
}

/// Rechecks current approval before a generation accepts an invocation.
///
/// ## Examples
///
/// `authorized(store, selection)` refuses revocation without selecting replacement.
pub fn authorized(
  store: Store,
  selection: record.Selection,
) -> Result(record.Candidate, Refusal) {
  with_session(store, fn(opened) {
    use candidate <- result.try(approved_in(store, opened, selection))
    use current_selection <- result.try(selection_in(
      opened,
      selection.scope,
      selection.name,
    ))
    case current_selection == Some(selection) {
      True -> Ok(candidate)
      False -> Error(Stale)
    }
  })
}

/// Checks staging approval without claiming this generation is selected.
///
/// Publication separately CASes the same approval register. This check permits
/// staging a future generation without confusing it with current invocation.
///
/// ## Examples
///
/// `approved(store,next_selection)` admits staging before the selection commit.
pub fn approved(
  store: Store,
  selection: record.Selection,
) -> Result(record.Candidate, Refusal) {
  with_session(store, fn(opened) { approved_in(store, opened, selection) })
}

fn approved_in(
  store: Store,
  opened: session.Session,
  selection: record.Selection,
) -> Result(record.Candidate, Refusal) {
  use candidate <- result.try(candidate_in(
    store,
    opened,
    selection.candidate_id,
  ))
  use Nil <- result.try(
    case selection.name == candidate.name && selection.generation > 0 {
      True -> Ok(Nil)
      False -> Error(Corrupt("selection identity disagrees with its candidate"))
    },
  )
  use evidence <- result.try(evidence_in(opened, selection.evidence_id))
  use Nil <- result.try(approvable(store, candidate, evidence, selection.scope))
  use approved <- result.try(cell(
    opened,
    approval_key(selection.candidate_id, selection.scope),
  ))
  use Nil <- result.try(approved_evidence(approved, selection.evidence_id))
  Ok(candidate)
}

/// Renders a refusal while retaining any cleanup witness in the typed caller.
///
/// ## Examples
///
/// `describe(Busy)` explains the contention without fabricating a retry result.
pub fn describe(refusal: Refusal) -> String {
  case refusal {
    Busy -> "catalogue busy"
    Corrupt(reason) -> "corrupt: " <> reason
    Unknown -> "unknown candidate or evidence"
    Stale -> "selection changed"
    NotApproved -> "candidate evidence is not currently approved"
    Changed -> "candidate or evaluator identity changed"
    Bounds(reason) -> "bounds: " <> reason
    Authority(reason) -> "authority: " <> reason
    TestFailed(reason) -> "tests failed: " <> reason
    CleanupUnconfirmed(reason, _) -> "cleanup unconfirmed: " <> reason
    Unavailable(reason) -> "unavailable: " <> reason
  }
}

fn with_session(
  store: Store,
  work: fn(session.Session) -> Result(a, Refusal),
) -> Result(a, Refusal) {
  let #(at, _) = clock.read(store.clock)
  use #(opened, retire) <- result.try(
    session.open_sqlite_owned(
      path: store.root <> "/evolution.db",
      owner: "evolution-" <> int.to_string(at),
      lease_ttl_ms: 30_000,
      clock: store.clock,
    )
    |> result.map_error(open_error),
  )
  let outcome = work(opened)

  // Close alone releases no ownership proof; RETIRE must answer before return.
  case retire() {
    Ok(Nil) -> outcome
    Error(_) ->
      Error(
        CleanupUnconfirmed("SQLite retirement did not confirm release", fn() {
          retire()
          |> result.replace_error("SQLite retirement remains unconfirmed")
        }),
      )
  }
}

fn candidate_in(
  store: Store,
  opened: session.Session,
  id: record.CandidateId,
) -> Result(record.Candidate, Refusal) {
  use text <- result.try(required(opened, "candidate/" <> record.id_string(id)))
  use candidate <- result.try(
    record.decode_candidate(text) |> result.map_error(Corrupt),
  )
  use Nil <- result.try(case candidate.id == id {
    True -> Ok(Nil)
    False -> Error(Changed)
  })
  use Nil <- result.try(admit_source(candidate))
  use Nil <- result.try(visible(store, candidate))
  Ok(candidate)
}

fn evidence_in(
  opened: session.Session,
  id: record.EvidenceId,
) -> Result(record.Evidence, Refusal) {
  use text <- result.try(required(
    opened,
    "evidence/" <> record.evidence_string(id),
  ))
  use evidence <- result.try(
    record.decode_evidence(text) |> result.map_error(Corrupt),
  )
  case evidence.id == id {
    True -> Ok(evidence)
    False -> Error(Changed)
  }
}

fn approvable(
  store: Store,
  candidate: record.Candidate,
  evidence: record.Evidence,
  scope: record.Scope,
) -> Result(Nil, Refusal) {
  use Nil <- result.try(current(store, candidate.identity))
  use Nil <- result.try(current(store, evidence.identity))
  use Nil <- result.try(
    case candidate.id == evidence.candidate_id && candidate.scope == scope {
      True -> Ok(Nil)
      False -> Error(Changed)
    },
  )
  use Nil <- result.try(case candidate.kind, evidence.purpose {
    record.Prompt, record.AuthorTests ->
      Error(TestFailed("prompt approval requires independent rollout evidence"))
    record.Prompt, record.IndependentRollout
    | record.Extension, _
    | record.Program, _
    -> Ok(Nil)
  })
  case evidence.verdict {
    record.Passed -> Ok(Nil)
    record.Failed -> Error(TestFailed("required checks failed"))
    record.Inconclusive(reason) -> Error(TestFailed(reason))
  }
}

fn current(store: Store, identity: record.Identity) -> Result(Nil, Refusal) {
  case store.identity == identity {
    True -> Ok(Nil)
    False -> Error(Changed)
  }
}

fn admit_source(candidate: record.Candidate) -> Result(Nil, Refusal) {
  let paths = list.map(candidate.files, fn(file) { file.0 })
  use Nil <- result.try(
    case
      list.length(paths) <= 256
      && list.length(paths) == list.length(list.unique(paths))
    {
      True -> Ok(Nil)
      False -> Error(Bounds("candidate file count or duplicate paths"))
    },
  )
  use Nil <- result.try(case list.all(paths, legal_path) {
    True -> Ok(Nil)
    False ->
      Error(Authority("candidate path is outside the immutable source envelope"))
  })
  use Nil <- result.try(bound(candidate.name, 128, "candidate name"))
  use Nil <- result.try(bound(
    candidate.origin.session_id,
    256,
    "session provenance",
  ))
  use Nil <- result.try(bound(candidate.origin.strand, 256, "strand provenance"))
  use Nil <- result.try(bound(
    candidate.origin.workspace,
    4096,
    "workspace provenance",
  ))
  use Nil <- result.try(bound(
    record.scope_key(candidate.scope),
    4096,
    "candidate scope",
  ))
  use Nil <- result.try(bound(
    value.to_string(value.String(record.scope_key(candidate.scope))),
    4098,
    "encoded candidate scope",
  ))
  use Nil <- result.try(bound(
    candidate.description,
    4096,
    "candidate description",
  ))
  use Nil <- result.try(bound(
    value.to_string(value.String(candidate.description)),
    4098,
    "encoded candidate description",
  ))
  use Nil <- result.try(bound(candidate.input_schema, 16_384, "input schema"))
  case candidate.kind {
    record.Extension -> admit_extension_descriptors(candidate)
    record.Prompt -> Ok(Nil)
    record.Program -> {
      use schema <- result.try(
        value.parse(candidate.input_schema)
        |> result.replace_error(Corrupt("skill input schema is invalid JSON")),
      )
      case schema {
        value.Object(_) -> {
          use Nil <- result.try(bound(
            value.to_string(schema),
            16_384,
            "canonical input schema",
          ))
          descriptor_bound(
            candidate,
            candidate.name,
            candidate.description,
            schema,
          )
        }
        _ -> Error(Corrupt("skill input schema must be an object"))
      }
    }
  }
}

// Admission owns discovery bounds before tests can approve an executable version.
// A complete identity and schema must fit one page; byte truncation cannot
// silently change the contract a caller will later invoke.
fn admit_extension_descriptors(
  candidate: record.Candidate,
) -> Result(Nil, Refusal) {
  use text <- result.try(
    list.key_find(candidate.files, "extension.toml")
    |> result.replace_error(TestFailed("extension manifest is absent")),
  )
  use decoded <- result.try(
    manifest.decode(
      text,
      manifest.Surroundings(
        candidate.files,
        package.module_names_of(candidate.files),
      ),
    )
    |> result.map_error(TestFailed),
  )
  list.try_each(decoded.tools, fn(declared) {
    use text <- result.try(
      list.key_find(candidate.files, declared.parameters)
      |> result.replace_error(TestFailed("extension schema is absent")),
    )
    use schema <- result.try(
      value.parse(text)
      |> result.replace_error(TestFailed("extension schema is invalid JSON")),
    )
    descriptor_bound(candidate, declared.name, declared.description, schema)
  })
}

fn descriptor_bound(
  candidate: record.Candidate,
  name: String,
  description: String,
  schema: value.JsonValue,
) -> Result(Nil, Refusal) {
  bound(
    value.to_string(
      value.Object([
        #("candidate_id", value.String(record.id_string(candidate.id))),
        #("generation", value.Int(9_223_372_036_854_775_807)),
        #("name", value.String(name)),
        #("description", value.String(description)),
        #("schema", schema),
      ]),
    ),
    23_549,
    "complete callable descriptor",
  )
}

fn legal_path(path: String) -> Bool {
  string.byte_size(path) <= 256
  && list.all(string.split(path, "/"), fn(segment) {
    segment != ""
    && segment != "."
    && segment != ".."
    && !string.contains(segment, "\\")
    && list.all(string.to_graphemes(segment), fn(char) {
      string.contains(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-",
        char,
      )
    })
  })
}

fn admit_origin(
  store: Store,
  candidate: record.Candidate,
) -> Result(Nil, Refusal) {
  use Nil <- result.try(visible(store, candidate))
  case store.authority {
    Owner -> Ok(Nil)
    Caller(session_id, workspace) | SessionOperator(session_id, workspace) -> {
      use Nil <- result.try(
        case
          candidate.origin.session_id == session_id
          && candidate.origin.workspace == workspace
        {
          True -> Ok(Nil)
          False -> Error(Authority("proposal origin is not this caller"))
        },
      )
      scope_visible(store, candidate.scope)
    }
    ModelAuthor(session_id, workspace, target) -> {
      use Nil <- result.try(
        case
          candidate.origin.session_id == session_id
          && candidate.origin.workspace == workspace
        {
          True -> Ok(Nil)
          False -> Error(Authority("model proposal origin is not this caller"))
        },
      )
      case
        candidate.scope == record.ExactModel(target)
        && candidate.kind == record.Prompt
      {
        True -> Ok(Nil)
        False ->
          Error(Authority("proposal is not for the admitted exact model"))
      }
    }
  }
}

fn visible(store: Store, candidate: record.Candidate) -> Result(Nil, Refusal) {
  case store.authority {
    Owner -> Ok(Nil)
    Caller(session_id, workspace)
    | SessionOperator(session_id, workspace)
    | ModelAuthor(session_id, workspace, _) ->
      case candidate.scope {
        record.ExactModel(_) ->
          case
            candidate.origin.session_id == session_id
            && candidate.origin.workspace == workspace
          {
            True -> Ok(Nil)
            False -> Error(Authority("foreign model proposal"))
          }
        record.Session(id) ->
          case session_id == id {
            True -> Ok(Nil)
            False -> Error(Authority("foreign session proposal"))
          }
        record.Workspace(path) ->
          case workspace == path && candidate.origin.workspace == workspace {
            True -> Ok(Nil)
            False -> Error(Authority("foreign workspace proposal"))
          }
      }
  }
}

fn scope_visible(store: Store, scope: record.Scope) -> Result(Nil, Refusal) {
  case store.authority, scope {
    Owner, _ -> Ok(Nil)
    Caller(session_id, _), record.Session(id)
    | SessionOperator(session_id, _), record.Session(id)
    | ModelAuthor(session_id, _, _), record.Session(id)
    ->
      case session_id == id {
        True -> Ok(Nil)
        False -> Error(Authority("foreign session"))
      }
    Caller(_, workspace), record.Workspace(path)
    | SessionOperator(_, workspace), record.Workspace(path)
    | ModelAuthor(_, workspace, _), record.Workspace(path)
    ->
      case workspace == path {
        True -> Ok(Nil)
        False -> Error(Authority("foreign workspace"))
      }
    Caller(_, _), record.ExactModel(_)
    | SessionOperator(_, _), record.ExactModel(_)
    | ModelAuthor(_, _, _), record.ExactModel(_)
    -> Error(Authority("exact-model selections require daemon owner"))
  }
}

fn owner(
  store: Store,
  scope: record.Scope,
  principal: String,
) -> Result(Nil, Refusal) {
  use Nil <- result.try(bound(principal, 256, "operator identity"))
  use Nil <- result.try(case principal != "" {
    True -> Ok(Nil)
    False -> Error(Authority("authenticated operator identity missing"))
  })
  case store.authority, scope {
    Owner, _ -> Ok(Nil)
    SessionOperator(session_id, _), record.Session(id) ->
      case session_id == id {
        True -> Ok(Nil)
        False -> Error(Authority("foreign session operator"))
      }
    SessionOperator(_, _), record.Workspace(_)
    | SessionOperator(_, _), record.ExactModel(_)
    -> Error(Authority("global approval requires daemon owner"))
    Caller(_, _), _ | ModelAuthor(_, _, _), _ ->
      Error(Authority(
        "approval and selection require native operator authority",
      ))
  }
}

fn cell(
  opened: session.Session,
  key: String,
) -> Result(Option(storage.Register), Refusal) {
  storage.get_register(opened.store, register.FactCustom, key)
  |> result.replace_error(Unavailable("catalogue register read failed"))
}

fn required(opened: session.Session, key: String) -> Result(String, Refusal) {
  use found <- result.try(cell(opened, key))
  case found {
    None -> Error(Unknown)
    Some(register) -> text_of(register)
  }
}

fn text_of(register: storage.Register) -> Result(String, Refusal) {
  case register.value.payload {
    value.String(text) -> {
      use Nil <- result.try(bound(
        text,
        max_candidate_bytes,
        "persisted catalogue cell",
      ))
      Ok(text)
    }
    _ -> Error(Corrupt("catalogue cell is not text"))
  }
}

fn index(
  opened: session.Session,
  key: String,
) -> Result(List(String), Refusal) {
  use found <- result.try(cell(opened, "index/" <> key))
  case found {
    None -> Ok([])
    Some(register) -> {
      use text <- result.try(text_of(register))
      use entries <- result.try(
        json.parse(text, decode.list(decode.string))
        |> result.replace_error(Corrupt("invalid bounded catalogue index")),
      )
      case list.length(entries) <= 512 {
        True -> Ok(entries)
        False -> Error(Corrupt("catalogue index exceeds bound"))
      }
    }
  }
}

fn retain(
  opened: session.Session,
  key: String,
  text: String,
  collection: String,
  limit: Int,
  clock: Clock,
) -> Result(Nil, Refusal) {
  use prior <- result.try(cell(opened, key))
  case prior {
    Some(register) -> {
      use existing <- result.try(text_of(register))
      case existing == text {
        True -> Ok(Nil)
        False -> Error(Changed)
      }
    }
    None -> retain_new(opened, key, text, collection, limit, clock)
  }
}

fn retain_new(
  opened: session.Session,
  key: String,
  text: String,
  collection: String,
  limit: Int,
  clock: Clock,
) -> Result(Nil, Refusal) {
  use retained <- result.try(index(opened, collection))
  use Nil <- result.try(case list.length(retained) < limit {
    True -> Ok(Nil)
    False -> Error(Bounds("retained " <> collection <> " count"))
  })
  use budget <- result.try(cell(opened, "retained_bytes"))
  use bytes <- result.try(case budget {
    None -> Ok(0)
    Some(register) -> {
      use text <- result.try(text_of(register))
      int.parse(text)
      |> result.replace_error(Corrupt("invalid storage byte census"))
    }
  })
  let size = bytes + string.byte_size(text)
  use Nil <- result.try(case size <= max_retained_bytes {
    True -> Ok(Nil)
    False -> Error(Bounds("aggregate catalogue bytes"))
  })
  use prior_index <- result.try(cell(opened, "index/" <> collection))
  commit(
    opened,
    [
      set(key, text),
      set(
        "index/" <> collection,
        json.to_string(json.array([key, ..retained], json.string)),
      ),
      set("retained_bytes", int.to_string(size)),
    ],
    [
      tx.Expect(register.FactCustom, key, None),
      expect("index/" <> collection, prior_index),
      expect("retained_bytes", budget),
    ],
    "retained",
    key,
    clock,
  )
}

fn set(key: String, text: String) -> tx.Write {
  tx.SetRegister(register.FactCustom, key, register.value(value.String(text)))
}

fn expect(key: String, cell: Option(storage.Register)) -> tx.SeqExpectation {
  tx.Expect(
    register.FactCustom,
    key,
    option.map(cell, fn(register) { register.seq }),
  )
}

fn commit(
  opened: session.Session,
  writes: List(tx.Write),
  expected: List(tx.SeqExpectation),
  event: String,
  text: String,
  clock: Clock,
) -> Result(Nil, Refusal) {
  use event_cell <- result.try(cell(opened, "event_count"))
  use count <- result.try(case event_cell {
    None -> Ok(0)
    Some(register) -> {
      use text <- result.try(text_of(register))
      int.parse(text) |> result.replace_error(Corrupt("invalid event census"))
    }
  })
  use Nil <- result.try(case count < 4096 {
    True -> Ok(Nil)
    False -> Error(Bounds("evolution audit event count"))
  })
  use Nil <- result.try(bound(text, 16_384, "evolution audit event"))
  let #(event_id, _) =
    ids.mint_entry(ids.generator(clock, seed: ffi_os.unique_positive_integer()))
  let audit =
    entry.CustomEntry(
      id: event_id,
      parent: None,
      seq: 0,
      ts: 0,
      custom_type: "evolution/" <> event,
      data: Some(value.String(text)),
    )
  storage.commit(
    opened.store,
    tx.Tx(
      writes: [
        tx.InsertEntry(audit),
        set("event_count", int.to_string(count + 1)),
        ..writes
      ],
      expected: [expect("event_count", event_cell), ..expected],
    ),
  )
  |> result.replace(Nil)
  |> result.map_error(fn(error) {
    case error {
      tx.StaleExpectation(_) -> Stale
      tx.LeaseLost(_) -> Busy
      tx.Corruption(_) -> Corrupt("catalogue commit corruption")
      tx.Faulted(reason) -> Unavailable(reason)
    }
  })
}

fn approval_key(id: record.CandidateId, scope: record.Scope) -> String {
  "approval/" <> record.scope_key(scope) <> "/" <> record.id_string(id)
}

fn selection_key(scope: record.Scope, name: String) -> String {
  // A model target owns one profile slot regardless of an author's alias.
  case scope {
    record.ExactModel(_) -> "selection/" <> record.scope_key(scope)
    record.Session(_) | record.Workspace(_) ->
      "selection/" <> record.scope_key(scope) <> "/" <> name
  }
}

fn approval_text(
  id: record.CandidateId,
  evidence: record.EvidenceId,
  scope: record.Scope,
  principal: String,
) -> String {
  json.to_string(
    json.object([
      #("candidate", json.string(record.id_string(id))),
      #("evidence", json.string(record.evidence_string(evidence))),
      #("scope", record.encode_scope(scope)),
      #("principal", json.string(principal)),
    ]),
  )
}

fn approved_evidence(
  found: Option(storage.Register),
  id: record.EvidenceId,
) -> Result(Nil, Refusal) {
  use text <- result.try(case found {
    None -> Error(NotApproved)
    Some(register) -> text_of(register)
  })
  let decoder = {
    use evidence <- decode.field("evidence", decode.string)
    decode.success(evidence)
  }
  use evidence <- result.try(
    json.parse(text, decoder)
    |> result.replace_error(Corrupt("invalid approval")),
  )
  case evidence == record.evidence_string(id) {
    True -> Ok(Nil)
    False -> Error(NotApproved)
  }
}

fn encode_selection(selection: record.Selection) -> String {
  json.to_string(
    json.object([
      #("candidate", json.string(record.id_string(selection.candidate_id))),
      #("evidence", json.string(record.evidence_string(selection.evidence_id))),
      #("scope", record.encode_scope(selection.scope)),
      #("name", json.string(selection.name)),
      #("generation", json.int(selection.generation)),
    ]),
  )
}

fn selection_in(
  opened: session.Session,
  scope: record.Scope,
  name: String,
) -> Result(Option(record.Selection), Refusal) {
  use found <- result.try(cell(opened, selection_key(scope, name)))
  case found {
    None -> Ok(None)
    Some(register) -> {
      use text <- result.try(text_of(register))
      json.parse(text, selection_decoder())
      |> result.map(Some)
      |> result.replace_error(Corrupt("invalid selection"))
    }
  }
}

fn selection_decoder() -> decode.Decoder(record.Selection) {
  use candidate <- decode.field("candidate", decode.string)
  use evidence <- decode.field("evidence", decode.string)
  use scope <- decode.field("scope", record.scope_decoder())
  use name <- decode.field("name", decode.string)
  use generation <- decode.field("generation", decode.int)
  case record.candidate_id(candidate), record.evidence_id(evidence) {
    Ok(candidate_id), Ok(evidence_id) ->
      decode.success(record.Selection(
        candidate_id:,
        evidence_id:,
        scope:,
        name:,
        generation:,
      ))
    _, _ ->
      decode.failure(
        record.Selection(
          candidate_id: record.placeholder(),
          evidence_id: record.evidence_placeholder(),
          scope:,
          name:,
          generation:,
        ),
        "valid selection identities",
      )
  }
}

fn bound(text: String, limit: Int, what: String) -> Result(Nil, Refusal) {
  case string.byte_size(text) <= limit {
    True -> Ok(Nil)
    False -> Error(Bounds(what))
  }
}

fn open_error(error: session.OpenError) -> Refusal {
  case error {
    session.SqliteOpenFailed(sqlite.LeaseHeld(_, _)) -> Busy
    session.SqliteOpenFailed(sqlite.CorruptSession(_)) ->
      Corrupt("catalogue database corrupt")
    session.SqliteOpenFailed(sqlite.UnsupportedVersion(_, _)) -> Changed
    session.SqliteOpenFailed(sqlite.OpenFailed(reason)) -> Unavailable(reason)
    session.MemoryOpenFailed(_) ->
      Unavailable("unexpected memory store failure")
  }
}
