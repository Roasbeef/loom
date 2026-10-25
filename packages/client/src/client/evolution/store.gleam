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
import client/evolution/retirement
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
import weft/poll

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
  CleanupUnconfirmed(reason: String, retire: retirement.Task)

  /// A native dependency failed.
  Unavailable(reason: String)
}

/// The surface an operator acted through, recorded in each audit entry.
///
/// The gateway derives it from the authenticated connection, never from the
/// author's JSON, so a history row can say where a decision came from.
pub type Via {
  /// The `loom evolution` command, or any native caller with no better name.
  Cli

  /// A browser page.
  Web

  /// The terminal client.
  Terminal
}

/// An address and native authority, with no retained database connection.
pub opaque type Store {
  Store(
    root: String,
    authority: Authority,
    identity: record.Identity,
    clock: Clock,
    via: Via,
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
  Ok(Store(root:, authority:, identity:, clock:, via: Cli))
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

/// Names the surface the next mutations are recorded under.
///
/// The surface goes into the audit text only. It is not part of a selection's
/// request signature, so retrying a request from another surface still finds
/// its receipt.
///
/// ## Examples
///
/// `with_via(store, Web)` makes a later `approve` record `"via":"web"`.
pub fn with_via(store: Store, via: Via) -> Store {
  Store(..store, via:)
}

/// The audit word for a surface.
///
/// ## Examples
///
/// `via_text(Terminal) == "terminal"`.
pub fn via_text(via: Via) -> String {
  case via {
    Cli -> "cli"
    Web -> "web"
    Terminal -> "terminal"
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

  // The proposal and current selection determine whether a candidate may be staged.
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
  with_session(store, fn(opened) { catalogue_in(store, opened) })
}

/// One approval as the catalogue recorded it.
pub type Approval {
  Approval(
    /// The evidence the approval named.
    evidence_id: record.EvidenceId,
    /// The authenticated principal that approved.
    principal: String,
    /// The surface recorded with it, or `""` for an approval written before
    /// surfaces were recorded.
    via: String,
  )
}

/// One candidate with what the board draws beside it.
pub type Row {
  Row(
    /// The immutable proposal.
    candidate: record.Candidate,
    /// Its current approval, if any.
    approval: Option(Approval),
    /// Every retained observation of it, newest first, with `observation`
    /// emptied because a single one can be 64 KiB.
    evidence: List(record.Evidence),
    /// Its selection, when this candidate is the one currently selected for
    /// its scope and name.
    selected: Option(record.Selection),
  )
}

/// One audit entry of the catalogue, read back.
///
/// The decoder is total. An entry whose text does not parse keeps its sequence,
/// time and kind and loses the rest, and only the owner sees it, because its
/// scope is unknown.
pub type Event {
  Event(
    /// The audit entry's sequence number, which orders the journal.
    seq: Int,
    /// The commit time in Unix milliseconds.
    at_ms: Int,
    /// `approved`, `revoked` or `selected`.
    kind: String,
    /// The scope the event concerned, when the entry named one.
    scope: Option(record.Scope),
    /// The candidate's digest, or `""` when the entry named none.
    candidate_id: String,
    /// The candidate's name, from the entry or from the catalogue, or `""`.
    name: String,
    /// The generation a selection created; `None` for the other kinds.
    generation: Option(Int),
    /// The authenticated principal, or `""` when unknown.
    principal: String,
    /// The surface recorded, or `""` when the entry predates surfaces.
    via: String,
    /// The operator's reason, or `""`.
    reason: String,
    /// The selection's request identity, or `""`.
    request_id: String,
  )
}

/// A consistent read of what the operator board draws.
pub type Board {
  Board(
    /// Every candidate this capability may see, newest first.
    rows: List(Row),
    /// The current selection of each scope and name those candidates share.
    selections: List(record.Selection),
    /// The newest audit entries this capability may see, newest first.
    history: List(Event),
    /// How many visible audit entries are older than `history`.
    history_omitted: Int,
  )
}

/// How many audit entries `read_board` returns.
pub const board_history = 64

/// Reads the candidates, evidence, approvals, selections and audit journal this
/// capability may see, under one lease.
///
/// Every list is bounded by a catalogue count (128 candidates, 256 evidence
/// rows, 4096 audit entries), so the read never scans an unbounded source.
///
/// ## Examples
///
/// `read_board(store)` lets an operator page draw the whole catalogue from one
/// call.
pub fn read_board(store: Store) -> Result(Board, Refusal) {
  with_session(store, fn(opened) {
    use candidates <- result.try(catalogue_in(store, opened))
    use observed <- result.try(observed_evidence(opened))
    use selections <- result.try(current_selections(store, opened, candidates))
    use rows <- result.try(
      list.try_map(candidates, fn(candidate) {
        use approval <- result.try(approval_in(opened, candidate))
        let selected =
          list.key_find(selections, selection_key_of(candidate))
          |> result.try(fn(selection) {
            case selection.candidate_id == candidate.id {
              True -> Ok(selection)
              False -> Error(Nil)
            }
          })
        Ok(Row(
          candidate:,
          approval:,
          evidence: list.filter(observed, fn(evidence) {
            evidence.candidate_id == candidate.id
          }),
          selected: option.from_result(selected),
        ))
      }),
    )
    use #(history, omitted) <- result.try(history_in(store, opened, candidates))
    Ok(Board(
      rows:,
      selections: list.map(selections, fn(pair) { pair.1 }),
      history:,
      history_omitted: omitted,
    ))
  })
}

// The visible candidates, in index order. `catalogue` and `read_board` share it
// so the two reads can never disagree about who sees what.
/// Decodes the catalogue snapshot and its bounded persisted records.
fn catalogue_in(
  store: Store,
  opened: session.Session,
) -> Result(List(record.Candidate), Refusal) {
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
}

// Every retained observation, newest first, without its observation text. The
// caller keeps only the rows of candidates it may see.
/// Returns evidence that remains visible under the requested candidate scope.
fn observed_evidence(
  opened: session.Session,
) -> Result(List(record.Evidence), Refusal) {
  use keys <- result.try(index(opened, "evidence"))
  list.try_map(keys, fn(key) {
    use text <- result.try(required(opened, key))
    use evidence <- result.try(
      record.decode_evidence(text) |> result.map_error(Corrupt),
    )
    Ok(record.Evidence(..evidence, observation: ""))
  })
}

fn selection_key_of(candidate: record.Candidate) -> String {
  selection_key(candidate.scope, candidate.name)
}

// One selection register per scope and name the visible candidates share. A
// scope the capability may not select in is skipped rather than refused,
// because the board shows what is visible and the selection of a hidden scope
// is not.
/// Reads the current selection set from the catalogue state.
fn current_selections(
  store: Store,
  opened: session.Session,
  candidates: List(record.Candidate),
) -> Result(List(#(String, record.Selection)), Refusal) {
  list.try_fold(candidates, [], fn(found, candidate) {
    let key = selection_key_of(candidate)

    // The stored selection rows determine the current selected candidates.
    case
      list.key_find(found, key),
      result.is_ok(scope_visible(store, candidate.scope))
    {
      Ok(_), _ -> Ok(found)
      Error(Nil), False -> Ok(found)
      Error(Nil), True -> {
        use selected <- result.try(selection_in(
          opened,
          candidate.scope,
          candidate.name,
        ))
        Ok(case selected {
          None -> found
          Some(selection) -> list.append(found, [#(key, selection)])
        })
      }
    }
  })
}

/// Decodes the candidate approval record from persisted catalogue state.
fn approval_in(
  opened: session.Session,
  candidate: record.Candidate,
) -> Result(Option(Approval), Refusal) {
  use found <- result.try(cell(
    opened,
    approval_key(candidate.id, candidate.scope),
  ))

  // The approval record determines which candidate authority is active.
  case found {
    None -> Ok(None)
    Some(register) -> {
      use text <- result.try(text_of(register))
      let decoder = {
        use evidence <- decode.field("evidence", decode.string)
        use principal <- decode.field("principal", decode.string)
        use via <- decode.optional_field("via", "", decode.string)
        decode.success(#(evidence, principal, via))
      }
      use #(evidence, principal, via) <- result.try(
        json.parse(text, decoder)
        |> result.replace_error(Corrupt("invalid approval")),
      )
      use evidence_id <- result.try(
        record.evidence_id(evidence) |> result.map_error(Corrupt),
      )
      Ok(Some(Approval(evidence_id:, principal:, via:)))
    }
  }
}

// The newest audit entries the capability may see, and how many older ones it
// may see and is not shown. Filtering happens before counting, so the count
// never discloses an event of a scope the capability cannot read.
/// Reads the selection history associated with the candidate and scope.
fn history_in(
  store: Store,
  opened: session.Session,
  candidates: List(record.Candidate),
) -> Result(#(List(Event), Int), Refusal) {
  use entries <- result.try(
    storage.scan_entries(
      opened.store,
      storage.EntryScan(
        ..storage.entry_scan(),
        kind: Some(storage.Custom),
        order: storage.NewestFirst,
      ),
    )
    |> result.replace_error(Unavailable("catalogue audit read failed")),
  )
  let events =
    list.filter_map(entries, fn(audited) { audit_event(audited, candidates) })
    |> list.filter(fn(event) { event_visible(store, event) })
  Ok(#(
    list.take(events, board_history),
    list.length(list.drop(events, board_history)),
  ))
}

// An owner sees every entry. Anyone else sees the entries whose scope names
// something they may see, so an entry with no readable scope is the owner's.
/// Checks whether an audit event belongs in the caller-visible catalogue view.
fn event_visible(store: Store, event: Event) -> Bool {
  case store.authority, event.scope {
    Owner, _ -> True
    _, None -> False
    _, Some(scope) -> result.is_ok(scope_visible(store, scope))
  }
}

// One audit entry as an event, or `Error(Nil)` for an entry that is not an
// approval, revocation or selection (the catalogue also journals retentions).
/// Builds the audit record for a committed catalogue operation.
fn audit_event(
  audited: entry.Entry,
  candidates: List(record.Candidate),
) -> Result(Event, Nil) {
  case audited {
    entry.CustomEntry(
      seq:,
      ts:,
      custom_type:,
      data: Some(value.String(text)),
      ..,
    ) -> event_from(custom_type, seq, ts, text, candidates)
    _ -> Error(Nil)
  }
}

/// Reads one audit entry's text as an event, totally.
///
/// An entry whose text does not parse still yields an event, with only its
/// sequence, time and kind. The text of a selection entry may be in the shape
/// the catalogue wrote before it recorded who selected and from where.
///
/// ## Examples
///
/// `event_from("evolution/revoked", 7, 0, text, [])` is `Ok(event)` with kind
/// `revoked`, and `event_from("evolution/retained", 7, 0, text, [])` is
/// `Error(Nil)`.
@internal
pub fn event_from(
  custom_type: String,
  seq: Int,
  ts: Int,
  text: String,
  candidates: List(record.Candidate),
) -> Result(Event, Nil) {
  case custom_type {
    "evolution/approved" -> Ok(approved_event(seq, ts, text, candidates))
    "evolution/revoked" -> Ok(revoked_event(seq, ts, text, candidates))
    "evolution/selected" -> Ok(selected_event(seq, ts, text))
    _ -> Error(Nil)
  }
}

/// Builds the stable refusal for a catalogue record that cannot be decoded.
fn unreadable(kind: String, seq: Int, ts: Int) -> Event {
  Event(
    seq:,
    at_ms: ts,
    kind:,
    scope: None,
    candidate_id: "",
    name: "",
    generation: None,
    principal: "",
    via: "",
    reason: "",
    request_id: "",
  )
}

/// Resolves one candidate by its catalogue name.
fn named(candidates: List(record.Candidate), candidate_id: String) -> String {
  case
    list.find(candidates, fn(candidate) {
      record.id_string(candidate.id) == candidate_id
    })
  {
    Ok(candidate) -> candidate.name
    Error(Nil) -> ""
  }
}

/// Decodes the audit event that records candidate approval.
fn approved_event(
  seq: Int,
  ts: Int,
  text: String,
  candidates: List(record.Candidate),
) -> Event {
  let decoder = {
    use candidate <- decode.field("candidate", decode.string)
    use scope <- decode.field("scope", record.scope_decoder())
    use principal <- decode.field("principal", decode.string)
    use via <- decode.optional_field("via", "", decode.string)
    decode.success(Event(
      seq:,
      at_ms: ts,
      kind: "approved",
      scope: Some(scope),
      candidate_id: candidate,
      name: named(candidates, candidate),
      generation: None,
      principal:,
      via:,
      reason: "",
      request_id: "",
    ))
  }
  result.lazy_unwrap(json.parse(text, decoder), fn() {
    unreadable("approved", seq, ts)
  })
}

/// Decodes the audit event that records candidate revocation.
fn revoked_event(
  seq: Int,
  ts: Int,
  text: String,
  candidates: List(record.Candidate),
) -> Event {
  let decoder = {
    use candidate <- decode.field("candidate", decode.string)
    use scope <- decode.field("scope", record.scope_decoder())
    use principal <- decode.field("principal", decode.string)
    use via <- decode.optional_field("via", "", decode.string)
    use reason <- decode.field("reason", decode.string)
    decode.success(Event(
      seq:,
      at_ms: ts,
      kind: "revoked",
      scope: Some(scope),
      candidate_id: candidate,
      name: named(candidates, candidate),
      generation: None,
      principal:,
      via:,
      reason:,
      request_id: "",
    ))
  }
  result.lazy_unwrap(json.parse(text, decoder), fn() {
    unreadable("revoked", seq, ts)
  })
}

// A selection entry is an object in the current format and `reason: selection`
// in the one before it. The old text carries no principal, surface or request
// identity, and its reason is whatever precedes the last `: {"candidate":`.
/// Decodes the audit event that records a candidate selection.
fn selected_event(seq: Int, ts: Int, text: String) -> Event {
  let current = {
    use selection_text <- decode.field("selection", decode.string)
    use principal <- decode.field("principal", decode.string)
    use via <- decode.optional_field("via", "", decode.string)
    use reason <- decode.field("reason", decode.string)
    use request_id <- decode.optional_field("request_id", "", decode.string)
    decode.success(#(selection_text, principal, via, reason, request_id))
  }
  let parsed =
    json.parse(text, current)
    |> result.lazy_or(fn() { legacy_selected(text) })

  // The event payload determines whether it represents a valid selection.
  case parsed {
    Error(_) -> unreadable("selected", seq, ts)
    Ok(#(selection_text, principal, via, reason, request_id)) ->
      case json.parse(selection_text, selection_decoder()) {
        Error(_) -> unreadable("selected", seq, ts)
        Ok(selection) ->
          Event(
            seq:,
            at_ms: ts,
            kind: "selected",
            scope: Some(selection.scope),
            candidate_id: record.id_string(selection.candidate_id),
            name: selection.name,
            generation: Some(selection.generation),
            principal:,
            via:,
            reason:,
            request_id:,
          )
      }
  }
}

// Reads the text a selection audit entry had before it became an object. The
// reason may itself contain a colon, so the split is at the last occurrence of
// the marker that begins the selection object.
/// Reads a legacy selection event when its required identity is present.
fn legacy_selected(
  text: String,
) -> Result(#(String, String, String, String, String), json.DecodeError) {
  let marker = ": {\"candidate\":"

  // The legacy event is accepted only when its stored identity is complete.
  case list.reverse(string.split(text, marker)) {
    [last, next, ..earlier] ->
      Ok(#(
        "{\"candidate\":" <> last,
        "",
        "",
        string.join(list.reverse([next, ..earlier]), marker),
        "",
      ))
    _ -> Error(json.UnexpectedEndOfInput)
  }
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
      [set(key, approval_text(id, evidence_id, scope, principal, store.via))],
      [expect(key, prior)],
      "approved",
      approval_text(id, evidence_id, scope, principal, store.via),
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
          #("via", json.string(via_text(store.via))),
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

/// Lists the selections scoped to one session that are still approved, which
/// are the extensions and programs that session would serve if it were open.
///
/// A daemon asks this before handing the session to another orchestrator,
/// because the selection lives in this daemon's catalogue and does not travel
/// with the session. It is a read for the owner, so it takes no store from the
/// caller and compares no identity: identity gates proposals, evidence and
/// approvals, and none of the reads below consult it. A selection whose
/// approval was revoked stays on file but serves nothing, so it is not listed.
///
/// A directory with no catalogue database holds no selections. The database is
/// not created to find that out, so asking about a daemon that never used
/// evolution leaves its state directory as it was. An existing database is
/// opened under the store's usual lease, waiting at most one second for it
/// (`borrow`); a catalogue that stays busy answers `Busy`, and the caller must
/// not read that as an empty list.
///
/// ## Examples
///
/// `session_selections(state <> "/evolution", "session-a", clock)` is
/// `Ok([])` for a session that serves nothing.
pub fn session_selections(
  root: String,
  session_id: String,
  clock: Clock,
) -> Result(List(record.Selection), Refusal) {
  use present <- result.try(
    simplifile.is_file(root <> "/evolution.db")
    |> result.map_error(fn(error) {
      Unavailable(simplifile.describe_error(error))
    }),
  )

  // Without a database file there is nothing to open, and opening would make
  // the directory and the database.
  case present {
    False -> Ok([])
    True -> {
      let unchecked = record.Identity("", "", "")
      use reader <- result.try(open(root, Owner, unchecked, clock))
      with_session(reader, fn(opened) {
        use candidates <- result.try(catalogue_in(reader, opened))
        let names =
          list.filter_map(candidates, fn(candidate) {
            case candidate.scope == record.Session(session_id) {
              True -> Ok(candidate.name)
              False -> Error(Nil)
            }
          })
          |> list.unique

        list.try_fold(names, [], fn(found, name) {
          use selected <- result.try(approved_selection_in(
            opened,
            record.Session(session_id),
            name,
          ))
          Ok(list.append(found, option.values([selected])))
        })
      })
    }
  }
}

// The selection of a name if its current approval names the selected evidence.
// Revocation deletes the approval and leaves the selection register, so the
// approval is what says the selection still serves.
/// Reads one selection and keeps it only while its approval still holds.
fn approved_selection_in(
  opened: session.Session,
  scope: record.Scope,
  name: String,
) -> Result(Option(record.Selection), Refusal) {
  use found <- result.try(selection_in(opened, scope, name))

  // No selection register means nothing was ever selected under this name.
  case found {
    None -> Ok(None)
    Some(selection) -> {
      use approval <- result.try(cell(
        opened,
        approval_key(selection.candidate_id, scope),
      ))

      // A missing or different approval is the revoked state, not an error.
      case approved_evidence(approval, selection.evidence_id) {
        Ok(Nil) -> Ok(Some(selection))
        Error(NotApproved) -> Ok(None)
        Error(refusal) -> Error(refusal)
      }
    }
  }
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
  select_request_admitted(
    store,
    id,
    evidence_id,
    scope,
    name,
    expected,
    principal,
    reason,
    request_id,
    fn() { Ok(Nil) },
  )
}

/// Checks native transition admission immediately before a new selection CAS.
///
/// Lease acquisition may wait behind another catalogue borrower. The callback
/// rechecks an absolute deadline after that wait; an existing exact receipt is
/// recovered first, because expiry cannot undo an already committed selection.
///
/// ## Examples
///
/// `select_request_admitted(store,id,evidence,scope,name,expected,owner,reason,token,admit)`
/// commits once after native admission or recovers the original receipt.
@internal
pub fn select_request_admitted(
  store: Store,
  id: record.CandidateId,
  evidence_id: record.EvidenceId,
  scope: record.Scope,
  name: String,
  expected: Option(record.Selection),
  principal: String,
  reason: String,
  request_id: String,
  admit: fn() -> Result(Nil, Refusal),
) -> Result(record.Selection, Refusal) {
  use Nil <- result.try(owner(store, scope, principal))
  use Nil <- result.try(bound(request_id, 256, "operator request id"))
  use Nil <- result.try(bound(reason, 4096, "operator reason"))
  let signature =
    selection_signature(
      id,
      evidence_id,
      scope,
      name,
      expected,
      principal,
      reason,
    )
  with_session(store, fn(opened) {
    use prior <- result.try(receipt_in(opened, request_id))

    // The durable receipt determines whether this request was already admitted.
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
          principal,
          reason,
          request_id,
          signature,
          admit,
        )
    }
  })
}

/// Recovers the original submitted request before any new staging or CAS.
///
/// The receipt retains the original full expected selection. A retry supplies
/// its original generation, so current selection changes cannot alter its
/// request identity. Every other submitted field still belongs to the signature.
///
/// ## Examples
///
/// `request_receipt(store, id, evidence, scope, name, 0, owner, reason, token)`
/// returns the original acknowledgement after a later selection supersedes it.
pub fn request_receipt(
  store: Store,
  id: record.CandidateId,
  evidence_id: record.EvidenceId,
  scope: record.Scope,
  name: String,
  expected_generation: Int,
  principal: String,
  reason: String,
  request_id: String,
) -> Result(Option(record.Selection), Refusal) {
  use Nil <- result.try(owner(store, scope, principal))
  use Nil <- result.try(bound(request_id, 256, "operator request id"))
  use Nil <- result.try(bound(reason, 4096, "operator reason"))
  with_session(store, fn(opened) {
    use prior <- result.try(receipt_in(opened, request_id))

    // The request identity selects its durable admission receipt.
    case prior {
      None -> Ok(None)
      Some(#(written_signature, selected)) -> {
        use expected_text <- result.try(
          json.parse(written_signature, {
            use expected <- decode.field(
              "expected",
              decode.optional(decode.string),
            )
            decode.success(expected)
          })
          |> result.replace_error(Corrupt("invalid receipt expectation")),
        )

        // The request identity selects its durable admission receipt.
        use expected <- result.try(case expected_text {
          None -> Ok(None)
          Some(text) ->
            json.parse(text, selection_decoder())
            |> result.map(Some)
            |> result.replace_error(Corrupt("invalid receipt expectation"))
        })

        // The request identity selects its durable admission receipt.
        let generation = case expected {
          None -> 0
          Some(selection) -> selection.generation
        }

        let signature =
          selection_signature(
            id,
            evidence_id,
            scope,
            name,
            expected,
            principal,
            reason,
          )

        // Replaying an acknowledged action transfers no new executable custody.
        case
          signature == written_signature && generation == expected_generation
        {
          True -> Ok(Some(selected))
          False -> Error(Changed)
        }
      }
    }
  })
}

/// Builds the identity signature used to compare candidate selections.
fn selection_signature(
  id: record.CandidateId,
  evidence_id: record.EvidenceId,
  scope: record.Scope,
  name: String,
  expected: Option(record.Selection),
  principal: String,
  reason: String,
) -> String {
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

    // The receipt state determines whether the committed request can be returned.
    case prior {
      None -> Ok(None)
      Some(#(_, selection)) -> {
        use Nil <- result.try(scope_visible(store, selection.scope))
        Ok(Some(selection))
      }
    }
  })
}

/// Commits a new selection while preserving durable request idempotency.
fn select_new(
  store: Store,
  opened: session.Session,
  id: record.CandidateId,
  evidence_id: record.EvidenceId,
  scope: record.Scope,
  name: String,
  expected: Option(record.Selection),
  principal: String,
  reason: String,
  request_id: String,
  signature: String,
  admit: fn() -> Result(Nil, Refusal),
) -> Result(record.Selection, Refusal) {
  use candidate <- result.try(candidate_in(store, opened, id))
  use evidence <- result.try(evidence_in(opened, evidence_id))
  use Nil <- result.try(approvable(store, candidate, evidence, scope))

  // The current selection and request identity determine whether a new selection is committed.
  use Nil <- result.try(case candidate.name == name {
    True -> Ok(Nil)
    False -> Error(Changed)
  })

  let approved_key = approval_key(id, scope)
  use approved <- result.try(cell(opened, approved_key))
  use Nil <- result.try(approved_evidence(approved, evidence_id))

  // Verify expected generation before recording the new selection.
  let key = selection_key(scope, name)
  use prior <- result.try(cell(opened, key))
  use actual <- result.try(selection_in(opened, scope, name))

  // The current selection and request identity determine whether a new selection is committed.
  use Nil <- result.try(case actual == expected {
    True -> Ok(Nil)
    False -> Error(Stale)
  })

  // The current selection and request identity determine whether a new selection is committed.
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
  let writes = [set(key, encode_selection(selection)), ..receipt_writes]
  let expected = [
    expect(key, prior),
    expect(approved_key, approved),
    ..receipt_expected
  ]
  let text =
    selection_audit(selection, principal, store.via, reason, request_id)
  use Nil <- result.try(commit_admitted(
    opened,
    writes,
    expected,
    "selected",
    text,
    store.clock,
    admit,
  ))
  Ok(selection)
}

/// Decodes one durable request receipt from catalogue storage.
fn receipt_in(
  opened: session.Session,
  request_id: String,
) -> Result(Option(#(String, record.Selection)), Refusal) {
  // The stored receipt value determines whether the request can be decoded.
  case request_id {
    "" -> Ok(None)
    _ -> {
      use found <- result.try(cell(opened, "receipt/" <> request_id))

      // The stored receipt value determines whether the request can be decoded.
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

/// Persists request receipt state for the admitted operation.
fn receipt_writes(
  opened: session.Session,
  request_id: String,
  signature: String,
  selection: record.Selection,
) -> Result(#(List(tx.Write), List(tx.SeqExpectation)), Refusal) {
  // The request outcome determines which receipt facts are persisted.
  case request_id {
    "" -> Ok(#([], []))
    _ -> {
      use retained <- result.try(index(opened, "receipts"))

      // The request outcome determines which receipt facts are persisted.
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

    // The authority record determines whether this candidate can be used.
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

/// Decodes the approved candidate and its authority metadata.
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

  // The decoded approval record determines the approved candidate.
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

/// Runs a catalogue operation under the requested session scope.
fn with_session(
  store: Store,
  work: fn(session.Session) -> Result(a, Refusal),
) -> Result(a, Refusal) {
  use #(opened, retire) <- result.try(borrow(store))
  let outcome = work(opened)

  // Close alone releases no ownership proof; RETIRE must answer before return.
  case retire() {
    Ok(Nil) -> outcome
    Error(_) ->
      Error(CleanupUnconfirmed(
        "SQLite retirement did not confirm release",
        retirement.repeat(fn() {
          retire()
          |> result.replace_error("SQLite retirement remains unconfirmed")
        }),
      ))
  }
}

// Every catalogue capability for a canonical path contends on the same fenced
// SQLite lease. Only a refused open is repeated: work and retirement each run
// once after custody is acquired, including an acquisition at the wall deadline.
/// Loads and validates the candidate before granting it to the caller.
fn borrow(store: Store) {
  let path = store.root <> "/evolution.db"
  let clock = store.clock
  let #(at, _) = clock.read(clock)
  let owner = "evolution-" <> int.to_string(at)

  // The candidate record is exposed only after its authority and contents validate.
  case
    poll.until(within: 1000, every: 10, attempt: fn() {
      case
        session.open_sqlite_owned_waiting(
          path:,
          owner:,
          lease_ttl_ms: 30_000,
          clock:,
          busy_timeout_ms: 10,
        )
      {
        Ok(owned) -> poll.Done(owned)
        Error(session.SqliteOpenFailed(sqlite.AdmissionBusy))
        | Error(session.SqliteOpenFailed(sqlite.LeaseHeld(_, _))) -> poll.Retry
        Error(error) -> poll.Fail(open_error(error))
      }
    })
  {
    poll.Answered(owned) -> Ok(owned)
    poll.Failed(error) -> Error(error)
    poll.Expired -> Error(Busy)
  }
}

/// Decodes a persisted candidate and its content metadata.
fn candidate_in(
  store: Store,
  opened: session.Session,
  id: record.CandidateId,
) -> Result(record.Candidate, Refusal) {
  use text <- result.try(required(opened, "candidate/" <> record.id_string(id)))
  use candidate <- result.try(
    record.decode_candidate(text) |> result.map_error(Corrupt),
  )

  // The stored candidate payload determines whether the candidate record is complete.
  use Nil <- result.try(case candidate.id == id {
    True -> Ok(Nil)
    False -> Error(Changed)
  })

  use Nil <- result.try(admit_source(candidate))
  use Nil <- result.try(visible(store, candidate))
  Ok(candidate)
}

/// Decodes persisted candidate evidence and validates its fields.
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

  // The stored evidence payload determines whether the evidence record is valid.
  case evidence.id == id {
    True -> Ok(evidence)
    False -> Error(Changed)
  }
}

/// Checks the candidate and evidence required for an approval transition.
fn approvable(
  store: Store,
  candidate: record.Candidate,
  evidence: record.Evidence,
  scope: record.Scope,
) -> Result(Nil, Refusal) {
  use Nil <- result.try(current(store, candidate.identity))
  use Nil <- result.try(current(store, evidence.identity))

  // The candidate state and evidence determine whether approval can be granted.
  use Nil <- result.try(
    case candidate.id == evidence.candidate_id && candidate.scope == scope {
      True -> Ok(Nil)
      False -> Error(Changed)
    },
  )

  // The candidate state and evidence determine whether approval can be granted.
  use Nil <- result.try(case candidate.kind, evidence.purpose {
    record.Prompt, record.AuthorTests ->
      Error(TestFailed("prompt approval requires independent rollout evidence"))
    record.Prompt, record.IndependentRollout
    | record.Extension, _
    | record.Program, _
    -> Ok(Nil)
  })

  // The candidate state and evidence determine whether approval can be granted.
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

/// Validates source files, bounds, and provenance before storing a candidate.
fn admit_source(candidate: record.Candidate) -> Result(Nil, Refusal) {
  let paths = list.map(candidate.files, fn(file) { file.0 })

  // The source artifact is validated and bounded before it enters the catalogue.
  use Nil <- result.try(
    case
      list.length(paths) <= 256
      && list.length(paths) == list.length(list.unique(paths))
    {
      True -> Ok(Nil)
      False -> Error(Bounds("candidate file count or duplicate paths"))
    },
  )

  // The source artifact is validated and bounded before it enters the catalogue.
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

  // The source artifact is validated and bounded before it enters the catalogue.
  case candidate.kind {
    record.Extension -> admit_extension_descriptors(candidate)
    record.Prompt -> Ok(Nil)
    record.Program -> {
      use schema <- result.try(
        value.parse(candidate.input_schema)
        |> result.replace_error(Corrupt("skill input schema is invalid JSON")),
      )

      // The source artifact is validated and bounded before it enters the catalogue.
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
/// Validates extension tool descriptors against the catalogue bounds.
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

/// Checks that a descriptor field fits its declared size limit.
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

/// Validates that a candidate path is a safe relative path.
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

/// Validates the source origin before admitting its artifact.
fn admit_origin(
  store: Store,
  candidate: record.Candidate,
) -> Result(Nil, Refusal) {
  use Nil <- result.try(visible(store, candidate))

  // The origin metadata determines whether the candidate source is trusted.
  case store.authority {
    Owner -> Ok(Nil)
    Caller(session_id, workspace) | SessionOperator(session_id, workspace) -> {
      // The origin metadata determines whether the candidate source is trusted.
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
      // The origin metadata determines whether the candidate source is trusted.
      use Nil <- result.try(
        case
          candidate.origin.session_id == session_id
          && candidate.origin.workspace == workspace
        {
          True -> Ok(Nil)
          False -> Error(Authority("model proposal origin is not this caller"))
        },
      )

      // The origin metadata determines whether the candidate source is trusted.
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

/// Checks whether a catalogue record is visible under the caller’s scope.
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

/// Checks whether a candidate scope is visible to this session.
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

/// Resolves the candidate owner from its scope and persisted origin.
fn owner(
  store: Store,
  scope: record.Scope,
  principal: String,
) -> Result(Nil, Refusal) {
  use Nil <- result.try(bound(principal, 256, "operator identity"))

  // The scope and owner fields determine who controls the candidate.
  use Nil <- result.try(case principal != "" {
    True -> Ok(Nil)
    False -> Error(Authority("authenticated operator identity missing"))
  })

  // The scope and owner fields determine who controls the candidate.
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

/// Reads one named field from the persisted candidate representation.
fn cell(
  opened: session.Session,
  key: String,
) -> Result(Option(storage.Register), Refusal) {
  storage.get_register(opened.store, register.FactCustom, key)
  |> result.replace_error(Unavailable("catalogue register read failed"))
}

/// Extracts a required stored value or reports a malformed record.
fn required(opened: session.Session, key: String) -> Result(String, Refusal) {
  use found <- result.try(cell(opened, key))

  // The required state determines the valid catalogue transition.
  case found {
    None -> Error(Unknown)
    Some(register) -> text_of(register)
  }
}

/// Decodes a required text value from persisted catalogue data.
fn text_of(register: storage.Register) -> Result(String, Refusal) {
  // The text of state determines the valid catalogue transition.
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

/// Builds the bounded candidate index used by catalogue lookups.
fn index(
  opened: session.Session,
  key: String,
) -> Result(List(String), Refusal) {
  use found <- result.try(cell(opened, "index/" <> key))

  // The bounded index maps a stored candidate identity to its record.
  case found {
    None -> Ok([])
    Some(register) -> {
      use text <- result.try(text_of(register))
      use entries <- result.try(
        json.parse(text, decode.list(decode.string))
        |> result.replace_error(Corrupt("invalid bounded catalogue index")),
      )

      // The bounded index maps a stored candidate identity to its record.
      case list.length(entries) <= 512 {
        True -> Ok(entries)
        False -> Error(Corrupt("catalogue index exceeds bound"))
      }
    }
  }
}

/// Retains evidence under the candidate identity without losing prior custody.
fn retain(
  opened: session.Session,
  key: String,
  text: String,
  collection: String,
  limit: Int,
  clock: Clock,
) -> Result(Nil, Refusal) {
  use prior <- result.try(cell(opened, key))

  // The evidence record is retained only when its durable identity is valid.
  case prior {
    Some(register) -> {
      use existing <- result.try(text_of(register))

      // The evidence record is retained only when its durable identity is valid.
      case existing == text {
        True -> Ok(Nil)
        False -> Error(Changed)
      }
    }
    None -> retain_new(opened, key, text, collection, limit, clock)
  }
}

/// Stores new evidence after validating its identity and encoded size.
fn retain_new(
  opened: session.Session,
  key: String,
  text: String,
  collection: String,
  limit: Int,
  clock: Clock,
) -> Result(Nil, Refusal) {
  use retained <- result.try(index(opened, collection))

  // New evidence is validated and committed without replacing an existing record.
  use Nil <- result.try(case list.length(retained) < limit {
    True -> Ok(Nil)
    False -> Error(Bounds("retained " <> collection <> " count"))
  })

  use budget <- result.try(cell(opened, "retained_bytes"))

  // New evidence is validated and committed without replacing an existing record.
  use bytes <- result.try(case budget {
    None -> Ok(0)
    Some(register) -> {
      use text <- result.try(text_of(register))
      int.parse(text)
      |> result.replace_error(Corrupt("invalid storage byte census"))
    }
  })

  let size = bytes + string.byte_size(text)

  // New evidence is validated and committed without replacing an existing record.
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

/// Checks that the current selection matches the expected identity.
fn expect(key: String, cell: Option(storage.Register)) -> tx.SeqExpectation {
  tx.Expect(
    register.FactCustom,
    key,
    option.map(cell, fn(register) { register.seq }),
  )
}

/// Commits a catalogue update under the session’s durable store.
fn commit(
  opened: session.Session,
  writes: List(tx.Write),
  expected: List(tx.SeqExpectation),
  event: String,
  text: String,
  clock: Clock,
) -> Result(Nil, Refusal) {
  commit_admitted(opened, writes, expected, event, text, clock, fn() { Ok(Nil) })
}

/// Applies an admitted selection commit and records its durable receipt.
fn commit_admitted(
  opened: session.Session,
  writes: List(tx.Write),
  expected: List(tx.SeqExpectation),
  event: String,
  text: String,
  clock: Clock,
  admit: fn() -> Result(Nil, Refusal),
) -> Result(Nil, Refusal) {
  use event_cell <- result.try(cell(opened, "event_count"))

  // The admitted commit result determines which durable selection changes are applied.
  use count <- result.try(case event_cell {
    None -> Ok(0)
    Some(register) -> {
      use text <- result.try(text_of(register))
      int.parse(text) |> result.replace_error(Corrupt("invalid event census"))
    }
  })

  // The admitted commit result determines which durable selection changes are applied.
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

  // Lease admission and the audit census can wait. The native transition's
  // absolute deadline is checked after both, immediately before a new CAS.
  use Nil <- result.try(admit())
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

/// Builds the stable key used to identify a selection record.
fn selection_key(scope: record.Scope, name: String) -> String {
  // A model target owns one profile slot regardless of an author's alias.
  case scope {
    record.ExactModel(_) -> "selection/" <> record.scope_key(scope)
    record.Session(_) | record.Workspace(_) ->
      "selection/" <> record.scope_key(scope) <> "/" <> name
  }
}

/// Renders the approval state as stable caller-visible text.
fn approval_text(
  id: record.CandidateId,
  evidence: record.EvidenceId,
  scope: record.Scope,
  principal: String,
  via: Via,
) -> String {
  json.to_string(
    json.object([
      #("candidate", json.string(record.id_string(id))),
      #("evidence", json.string(record.evidence_string(evidence))),
      #("scope", record.encode_scope(scope)),
      #("principal", json.string(principal)),
      #("via", json.string(via_text(via))),
    ]),
  )
}

// The audit text of a selection. It was once `reason <> ": " <> selection`,
// which named no principal and could not be split back apart when the reason
// itself held a colon, so a history reader had to guess. It is an object now,
// and `legacy_selected` still reads the old shape.
/// Builds the audit event for a candidate selection change.
fn selection_audit(
  selection: record.Selection,
  principal: String,
  via: Via,
  reason: String,
  request_id: String,
) -> String {
  json.to_string(
    json.object([
      #("selection", json.string(encode_selection(selection))),
      #("principal", json.string(principal)),
      #("via", json.string(via_text(via))),
      #("reason", json.string(reason)),
      #("request_id", json.string(request_id)),
    ]),
  )
}

/// Loads evidence associated with the approved candidate.
fn approved_evidence(
  found: Option(storage.Register),
  id: record.EvidenceId,
) -> Result(Nil, Refusal) {
  // The approval record determines which evidence is associated with the candidate.
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

  // The approval record determines which evidence is associated with the candidate.
  case evidence == record.evidence_string(id) {
    True -> Ok(Nil)
    False -> Error(NotApproved)
  }
}

/// Encodes a selection using the persisted catalogue format.
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

/// Decodes a stored selection record and validates its fields.
fn selection_in(
  opened: session.Session,
  scope: record.Scope,
  name: String,
) -> Result(Option(record.Selection), Refusal) {
  use found <- result.try(cell(opened, selection_key(scope, name)))

  // The persisted selection fields determine whether a selection can be reconstructed.
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

/// Decodes a selection record from its stored JSON representation.
fn selection_decoder() -> decode.Decoder(record.Selection) {
  use candidate <- decode.field("candidate", decode.string)
  use evidence <- decode.field("evidence", decode.string)
  use scope <- decode.field("scope", record.scope_decoder())
  use name <- decode.field("name", decode.string)
  use generation <- decode.field("generation", decode.int)

  // The stored selection value is decoded only when every required field is valid.
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

/// Maps a catalogue open failure to the stable refusal vocabulary.
fn open_error(error: session.OpenError) -> Refusal {
  case error {
    session.SqliteOpenFailed(sqlite.AdmissionBusy)
    | session.SqliteOpenFailed(sqlite.LeaseHeld(_, _)) -> Busy
    session.SqliteOpenFailed(sqlite.CorruptSession(_)) ->
      Corrupt("catalogue database corrupt")
    session.SqliteOpenFailed(sqlite.UnsupportedVersion(_, _)) -> Changed
    session.SqliteOpenFailed(sqlite.OpenFailed(reason)) -> Unavailable(reason)
    session.MemoryOpenFailed(_) ->
      Unavailable("unexpected memory store failure")
  }
}
