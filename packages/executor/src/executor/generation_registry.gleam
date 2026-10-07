//// Permanent registered-generation custody, separate from endpoint publication.
////
//// One serialized node administrator owns each Store. A private weft actor
//// retains its original connection; this DAL imports neither host nor endpoint.
//// Independent connections serialize
//// through BEGIN IMMEDIATE; WAL and FULL are checked before admission. A first
//// insertion COMMIT alone issues StartupClaim. Historical rows, lost replies
//// and recovery never reconstruct startup or publication authority.
////
//// Publication intent commits before the original administrator forwards
//// register. Close commits its fence before that same administrator forwards
//// fence. Gleam capabilities are copyable: the sole original administrator
//// must consume each returned claim or permit at most once. Durable phases
//// independently refuse repeated claim/publication issuance.
////
//// Retirement validates full original physical witnesses through a trusted
//// local verifier while those original handles still exist. No wire closure,
//// DOWN, absence, timeout or report can stand in for that verifier. Returned
//// RetirementRecord follows record COMMIT and exact readback. Published slot
//// release additionally requires the original endpoint's exact removal ACK;
//// the Removed COMMIT retains all association, fence and retirement history.
////
//// Logical quotas reserve future retirement/owner-close metadata on first
//// insertion. They bound encoded history, not SQLite pages, WAL or VM RSS.
//// Recovery refuses corrupt scalar inventories before reading bounded bodies
//// and permanently marks unavailable original startup custody Unknown.
//// ## Flow
////
//// `fresh` and `recover` enter `open`; `validate_path` refuses unsafe opens.
//// `admit` and `admit_planned` enter `admit_original`; `scope_plan` observes
//// immutable charged provenance. Admission checks exact originals and `check_lineage` before insertion; `original`
//// projects only its original claim. `prepare_publication` and `published`
//// serialize against `close_generation`. `validate_publication` checks original
//// Store and intent; `validate_removal` checks exact committed endpoint evidence.
//// `observe` reads historical phase.
//// `retire_started` validates original joins before `retirement` reads committed
//// evidence; `retirement_fields` projects it. `remove` retains Removed before
//// slot reuse, and `attest_predecessor` validates original owner-close bytes.
//// `transaction` enters `exchange`, `handle` and `handle_work`; `transact`
//// enters `inventory`, and `complete_transaction` owns COMMIT. `shutdown`
//// closes the original connection exactly once on linked owner retirement.
//// `read_row` checks canonical history and `validate_owner_envelope` checks its
//// predecessor association. `claim_row`, `exact_original`, `find_header` and
//// `required_header` and `inserted_row` compare original custody. `available`
//// accounts capacity. `validate_plan_inventory`, `read_plan_header`,
//// `plan_header_charge`, `read_plan`, `insert_plan`, `exact_plan` and
//// `plan_reservation` bind immutable child bytes to their original parent;
//// `endpoint_matches` checks immutable endpoint provenance. `record`,
//// `kind_value`, `decode_record` and `decode_kind` share the retirement codec.
//// `decode_phase`, `validate_doors`, `validate_owner_bytes`, `key_bytes`,
//// `scope_bytes`, `reservation`, `uuid`, `parse_uuid` and `hash` keep checked
//// projections bounded. `changed`, `statement`, `query`, `sql_error` and
//// `decoded_scalar` adapt named SQL without assembling statement text.

import core/bounded_msgpack
import core/generation as g
import core/ids
import core/msgpack as mp
import core/workspace
import executor/generation_registry_schema
import executor/generation_scope_plan as scope_plan
import executor/generation_scope_plan_migration
import executor/sql
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import parrot/dev
import simplifile
import sqlight
import weft/actor

/// Selected node-wide ceiling for simultaneously live or unretired claims.
pub const max_live = 16

/// Permanent identity ceiling; removal never returns this capacity.
pub const max_rows = 4096

/// Permanent logical-metadata ceiling, including future record reservations.
pub const max_bytes = 268_435_456

/// Maximum canonical witness or owner-close envelope.
pub const max_record_bytes = 8192

/// Immutable finite limits, persisted and compared on every open.
pub opaque type Limits {
  /// Lower profiles permit bounded component tests without changing hard maxima.
  Limits(
    /// Simultaneously live/unretired original startup claims.
    live: Int,
    /// Permanent generation identities, including no-claim fences.
    rows: Int,
    /// Permanent logical metadata reservations.
    bytes: Int,
  )
}

/// Original serialized connection owner, independent of host or endpoint handles.
pub opaque type Store {
  /// The original connection cannot be substituted by another open.
  Store(
    /// Original connection-owning actor; no closed native handle escapes.
    subject: process.Subject(Message),
    /// Once-minted original registry-use UUID, not a transport generation.
    incarnation: ids.EntryId,
    /// Immutable selected finite profile.
    limits: Limits,
  )
}

/// Sole original startup authority, returned only after first insertion COMMIT.
pub opaque type StartupClaim {
  /// This copyable value belongs to one original trusted continuation.
  StartupClaim(
    /// Actual issuing connection, unavailable after release or recovery.
    store: Store,
    /// Complete immutable association admitted by that insertion.
    association: g.GenerationAssociation,
    /// Exact canonical original owner door addresses.
    doors: BitArray,
  )
}

/// Sole original publication authority, following Publishing COMMIT.
pub opaque type PublishingPermit {
  /// Only the sole node administrator may forward this original registration.
  PublishingPermit(
    /// Original claim and physical startup continuation.
    claim: StartupClaim,
    /// Exact original endpoint incarnation selected before register.
    endpoint: g.Digest,
  )
}

/// Historical monotone disposition; none of these values grants startup.
pub type Phase {
  /// Original first startup claim has committed.
  Claimed

  /// Register may have been forwarded; absence is never inferred.
  Publishing

  /// Original concrete registration acknowledgement was retained.
  Published

  /// Durable closing fence blocks every future publication.
  Closing

  /// Exact original retirement record has committed.
  Retired

  /// Exact removal has committed; only this phase frees a claimed live slot.
  Removed

  /// Unavailable original custody remains permanently charged.
  Unknown
}

/// First admission distinguishes live permission from historical metadata.
pub type Admission {
  /// This absent-row transaction inserted and committed the original claim.
  Fresh(claim: StartupClaim)

  /// Exact original association/door history grants no second claim.
  Retained(phase: Phase)
}

/// Separate closed endpoint retirement witnesses.
pub type EndpointWitness {
  /// Original published row was fenced and had no assigned or unusable credit.
  PublishedFencedDrained(
    /// Exact endpoint incarnation, independently rechecked on removal.
    endpoint: g.Digest,
  )

  /// Durable Claimed-to-Closing proves publication was never authorized.
  UnpublishedFenced
}

/// Complete original physical evidence, validated by trusted local assembly.
/// Digests name canonical original witnesses; they do not authenticate themselves.
pub type StartedEvidence {
  /// Every obligation is required; no generic close result fills this record.
  StartedEvidence(
    /// Exact published drain or durable never-published fence.
    endpoint: EndpointWitness,
    /// Workspace, Compile, Launch and LSP continuation joins.
    continuations: g.Digest,
    /// Exact original physical-resource cleanup.
    resources: g.Digest,
    /// Original native scope retirement.
    native_scope: g.Digest,
    /// Every covered native-key confirmation.
    covered_keys: g.Digest,
    /// Original service exits.
    services: g.Digest,
    /// Original journal-handle closure.
    journals: g.Digest,
    /// Original host normal exit after its successful retirement result.
    host: g.Digest,
  )
}

/// Exact committed executor retirement, recoverable as history without authority.
pub opaque type RetirementRecord {
  /// Only durable fence or validated original witness admission constructs this.
  RetirementRecord(
    /// Exact original generation identity.
    key: g.GenerationKey,
    /// Closed never-started or started retirement representation.
    kind: RetirementKind,
    /// Exact canonical record, retained permanently.
    bytes: BitArray,
    /// SHA-256 of these bytes, independent of enrollment and owner-close hashes.
    digest: g.Digest,
  )
}

/// Closed historical retirement provenance.
pub type RetirementKind {
  /// No startup claim ever existed under the permanent closing fence.
  NeverStarted

  /// All original physical witnesses passed before this record committed.
  StartedRetired(evidence: StartedEvidence)
}

/// Owner attestation checked against the node's own original committed record.
pub opaque type PredecessorProof {
  /// Historical proof never grants a new claim itself.
  PredecessorProof(
    /// Original full predecessor association, including its immutable owner-use.
    association: g.GenerationAssociation,
    /// Node record read back from this permanent ledger.
    node: RetirementRecord,
    /// Digest of the authenticated original owner's canonical close attestation.
    owner: g.Digest,
  )
}

/// Fixed errors never echo SQL or untrusted payloads.
pub type Error {
  /// Limits exceed the selected hard ceilings or have a nonpositive member.
  InvalidLimits

  /// Host-supplied path was invalid, absent or unable to open safely.
  InvalidPath

  /// Fresh open would replace an existing history fence.
  AlreadyExists

  /// Exact original identity or predecessor proof is absent.
  Missing

  /// Immutable identity, original door bundle or exact witness differs.
  Conflict

  /// Permanent or live capacity is exhausted; no evidence is evicted.
  Capacity

  /// Original generation is permanently fenced against new authority.
  Fenced

  /// Stored bounds, types, canonical identity or monotone state are corrupt.
  Corrupt

  /// An unsuccessful operation may have committed; original evidence must be read.
  Uncertain
}

type Context {
  Context(
    connection: sqlight.Connection,
    incarnation: ids.EntryId,
    limits: Limits,
    format: Int,
  )
}

type OpenMode {
  Create
  Recover
}

type Row {
  Row(
    header: sql.GenerationHeaders,
    association: Option(g.GenerationAssociation),
    doors: BitArray,
    retired: Option(RetirementRecord),
    owner_close: BitArray,
    plan: Option(scope_plan.Plan),
  )
}

type Inventory {
  Inventory(
    headers: List(sql.GenerationHeaders),
    rows: Int,
    live: Int,
    bytes: Int,
  )
}

type PlanHeader {
  PlanHeader(header_size: Int, enrollment_size: Int, digest: g.Digest)
}

type State {
  Open(Context)
  Closed
}

type Message {
  AdmissionWork(
    fn(Context, Inventory) -> Result(Admission, Error),
    process.Subject(Result(Admission, Error)),
  )
  PublicationWork(
    fn(Context, Inventory) -> Result(PublishingPermit, Error),
    process.Subject(Result(PublishingPermit, Error)),
  )
  PhaseWork(
    fn(Context, Inventory) -> Result(Phase, Error),
    process.Subject(Result(Phase, Error)),
  )
  RetirementWork(
    fn(Context, Inventory) -> Result(RetirementRecord, Error),
    process.Subject(Result(RetirementRecord, Error)),
  )
  PredecessorWork(
    fn(Context, Inventory) -> Result(PredecessorProof, Error),
    process.Subject(Result(PredecessorProof, Error)),
  )
  NilWork(
    fn(Context, Inventory) -> Result(Nil, Error),
    process.Subject(Result(Nil, Error)),
  )
  PlanWork(
    fn(Context, Inventory) -> Result(Option(scope_plan.Plan), Error),
    process.Subject(Result(Option(scope_plan.Plan), Error)),
  )
  Release(process.Subject(Result(Nil, Error)))
  Stop
}

/// Validates immutable finite profiles under the approved node-wide maxima.
///
/// ## Examples
///
/// `limits(16, 4096, 268_435_456)` is the selected production profile.
pub fn limits(live: Int, rows: Int, bytes: Int) -> Result(Limits, Error) {
  case
    live >= 1
    && live <= max_live
    && rows >= 1
    && rows <= max_rows
    && bytes >= 1
    && bytes <= max_bytes
  {
    True -> Ok(Limits(live, rows, bytes))
    False -> Error(InvalidLimits)
  }
}

/// Returns the selected production profile with no deployment quota knob.
///
/// ## Examples
///
/// `selected_limits()` retains sixteen live and 4096 permanent slots.
pub fn selected_limits() -> Limits {
  Limits(max_live, max_rows, max_bytes)
}

/// Creates an unused node ledger and retains one original serialized connection.
///
/// ## Examples
///
/// `fresh(path, original_incarnation, selected_limits())` refuses an existing path.
pub fn fresh(
  path: String,
  incarnation: ids.EntryId,
  limits: Limits,
) -> Result(Store, Error) {
  open(path, incarnation, limits, Create)
}

/// Reads existing history and fences unavailable original startup custody Unknown.
/// Recovery creates no startup or publication claim, even with the same UUID.
///
/// ## Examples
///
/// `recover(path, new_incarnation, selected_limits())` preserves retired records.
pub fn recover(
  path: String,
  incarnation: ids.EntryId,
  limits: Limits,
) -> Result(Store, Error) {
  open(path, incarnation, limits, Recover)
}

/// Closes and joins this original DAL owner; it proves no physical service retirement.
///
/// ## Examples
///
/// `release(store)` leaves every permanent ledger row intact.
pub fn release(store: Store) -> Result(Nil, Error) {
  use owner <- result.try(
    process.subject_owner(store.subject) |> result.replace_error(Uncertain),
  )
  let watch = process.monitor(owner)
  let outcome = {
    use Nil <- result.try(exchange(store, Release))
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) {
      case down {
        process.ProcessDown(reason: process.Normal, ..) -> Ok(Nil)
        process.ProcessDown(..) | process.PortDown(..) -> Error(Uncertain)
      }
    })
    |> process.selector_receive(5000)
    |> result.unwrap(Error(Uncertain))
  }

  // Success joins the original actor after its acknowledged native-handle close.
  process.demonitor_process(watch)
  outcome
}

/// Admits complete original identity and doors before any startup effect.
/// Exact retained identity is consulted before quotas; duplicates issue no claim.
/// The caller already checked the immutable deployment table and original owner.
///
/// ## Examples
///
/// `admit(store, associated, doors, 1, None)` returns Fresh only once.
pub fn admit(
  store: Store,
  associated: g.GenerationAssociation,
  doors: BitArray,
  configured_first: Int,
  predecessor: Option(PredecessorProof),
) -> Result(Admission, Error) {
  admit_original(store, associated, doors, configured_first, predecessor, None)
}

/// Admits exact original journal provenance in the first claim transaction.
/// Both bodies and their digest stay permanently charged through removal.
/// Missing legacy provenance cannot be backfilled by a duplicate admission.
///
/// ## Examples
///
/// `admit_planned(store, original, doors, 1, None, plan)` issues Fresh only once.
@internal
pub fn admit_planned(
  store: Store,
  associated: g.GenerationAssociation,
  doors: BitArray,
  configured_first: Int,
  predecessor: Option(PredecessorProof),
  plan: scope_plan.Plan,
) -> Result(Admission, Error) {
  use Nil <- result.try(case scope_plan.original(plan) == associated {
    True -> Ok(Nil)
    False -> Error(Conflict)
  })
  admit_original(
    store,
    associated,
    doors,
    configured_first,
    predecessor,
    Some(plan),
  )
}

/// Observes immutable original provenance without returning startup authority.
/// No plan on a legacy or no-claim row remains unavailable, never reconstructed.
///
/// ## Examples
///
/// `scope_plan(store, key)` still returns exact original metadata after Removed.
@internal
pub fn scope_plan(
  store: Store,
  key: g.GenerationKey,
) -> Result(Option(scope_plan.Plan), Error) {
  use bytes <- result.try(key_bytes(key))
  transaction(store, PlanWork, fn(store, inventory) {
    case find_header(inventory, bytes) {
      None -> Ok(None)
      Some(header) ->
        read_row(store, header) |> result.map(fn(row) { row.plan })
    }
  })
}

fn admit_original(
  store: Store,
  associated: g.GenerationAssociation,
  doors: BitArray,
  configured_first: Int,
  predecessor: Option(PredecessorProof),
  plan: Option(scope_plan.Plan),
) -> Result(Admission, Error) {
  let issuer = store
  use Nil <- result.try(validate_doors(doors))
  use key <- result.try(key_bytes(g.association_key(associated)))
  transaction(store, AdmissionWork, fn(store, inventory) {
    case find_header(inventory, key) {
      Some(header) -> {
        use row <- result.try(read_row(store, header))
        use Nil <- result.try(exact_original(row, associated, doors))
        use Nil <- result.try(exact_plan(row.plan, plan))
        use phase <- result.try(decode_phase(header.phase))
        case row.association {
          None -> Error(Fenced)
          Some(_) -> Ok(Retained(phase))
        }
      }
      None -> {
        use Nil <- result.try(check_lineage(
          store,
          associated,
          configured_first,
          predecessor,
        ))
        use association <- result.try(
          g.encode_association(associated) |> result.replace_error(Corrupt),
        )
        let charge = reservation(key) + plan_reservation(plan)
        use Nil <- result.try(available(store, inventory, charge, 1))
        let #(scope, _, number) = g.key_fields(g.association_key(associated))
        use scope <- result.try(scope_bytes(scope))
        let #(_, _, owner, _) = g.association_fields(associated)
        use Nil <- result.try(
          case
            list.any(inventory.headers, fn(header) {
              header.live == 1 && header.scope == scope
            })
          {
            True -> Error(Fenced)
            False -> Ok(Nil)
          },
        )
        use Nil <- result.try(
          case
            list.any(inventory.headers, fn(header) {
              header.claimed == 1 && header.owner_use == uuid(owner)
            })
          {
            True -> Error(Conflict)
            False -> Ok(Nil)
          },
        )
        use Nil <- result.try(statement(
          store,
          sql.insert_generation_claim(
            key,
            scope,
            number,
            association,
            hash(association),
            uuid(owner),
            doors,
            uuid(store.incarnation),
            charge,
          ),
        ))

        // Parent and child share this transaction. A suppressed child insert or
        // altered readback rolls back the parent before live authority can escape.
        use Nil <- result.try(insert_plan(store, key, plan))
        use row <- result.try(
          inserted_row(store, key) |> result.replace_error(Uncertain),
        )
        use Nil <- result.try(exact_original(row, associated, doors))
        use Nil <- result.try(
          exact_plan(row.plan, plan) |> result.replace_error(Uncertain),
        )
        use Nil <- result.try(
          case
            row.header.phase == 0
            && row.header.claim_incarnation == uuid(store.incarnation)
          {
            True -> Ok(Nil)
            False -> Error(Uncertain)
          },
        )
        Ok(Fresh(StartupClaim(issuer, associated, doors)))
      }
    }
  })
}

/// Projects the immutable association retained by the original live claim.
///
/// ## Examples
///
/// `original(claim)` never resolves a latest generation or replacement door.
pub fn original(claim: StartupClaim) -> g.GenerationAssociation {
  claim.association
}

/// COMMITs Publishing before the sole administrator can forward register.
/// Repeated calls and Closing never return another publication permit.
///
/// ## Examples
///
/// `prepare_publication(claim, endpoint)` retains the exact original endpoint.
pub fn prepare_publication(
  claim: StartupClaim,
  endpoint: g.Digest,
) -> Result(PublishingPermit, Error) {
  let store = claim.store
  transaction(store, PublicationWork, fn(store, inventory) {
    use row <- result.try(claim_row(store, claim, inventory))
    use Nil <- result.try(case row.header.phase {
      0 -> Ok(Nil)
      _ -> Error(Fenced)
    })
    use Nil <- result.try(changed(
      store,
      sql.publish_generation_intent(
        g.digest_bytes(endpoint),
        row.header.key,
        uuid(store.incarnation),
      ),
      fn(row) { row.phase },
      1,
    ))
    Ok(PublishingPermit(claim, endpoint))
  })
}

/// Checks the original configured writer and its committed publication intent.
/// This local construction seam grants no permit or replacement startup claim.
///
/// ## Examples
///
/// `validate_publication(store, claim, endpoint)` refuses another Store actor.
@internal
pub fn validate_publication(
  store: Store,
  claim: StartupClaim,
  endpoint: g.Digest,
) -> Result(Nil, Error) {
  use Nil <- result.try(case store == claim.store {
    True -> Ok(Nil)
    False -> Error(Conflict)
  })
  transaction(store, NilWork, fn(context, inventory) {
    use row <- result.try(claim_row(context, claim, inventory))
    use Nil <- result.try(case row.header.phase {
      1 -> Ok(Nil)
      _ -> Error(Fenced)
    })
    case
      row.header.claim_incarnation == uuid(context.incarnation)
      && row.header.endpoint_incarnation == g.digest_bytes(endpoint)
    {
      True -> Ok(Nil)
      False -> Error(Conflict)
    }
  })
}

/// Retains the original concrete registration acknowledgement after publication.
/// The sole administrator supplied this acknowledgement from its original endpoint.
///
/// ## Examples
///
/// `published(permit)` refuses an intervening durable Close fence.
pub fn published(permit: PublishingPermit) -> Result(Nil, Error) {
  transaction(permit.claim.store, NilWork, fn(store, inventory) {
    use row <- result.try(claim_row(store, permit.claim, inventory))
    use Nil <- result.try(
      case row.header.endpoint_incarnation == g.digest_bytes(permit.endpoint) {
        True -> Ok(Nil)
        False -> Error(Conflict)
      },
    )
    case row.header.phase {
      2 -> Ok(Nil)
      1 ->
        changed(
          store,
          sql.complete_generation_publication(
            row.header.key,
            uuid(permit.claim.store.incarnation),
          ),
          fn(row) { row.phase },
          2,
        )
      _ -> Error(Fenced)
    }
  })
}

/// Reads an exact historical disposition without granting activation authority.
///
/// ## Examples
///
/// `observe(store, key)` never issues StartupClaim or PublishingPermit.
pub fn observe(store: Store, key: g.GenerationKey) -> Result(Phase, Error) {
  use bytes <- result.try(key_bytes(key))
  transaction(store, PhaseWork, fn(store, inventory) {
    use header <- result.try(required_header(inventory, bytes))
    use _ <- result.try(read_row(store, header))
    decode_phase(header.phase)
  })
}

/// Commits a permanent close fence, including before any first Activate.
/// No-claim close atomically commits NeverStarted and never releases a live slot.
///
/// ## Examples
///
/// `close_generation(store, key)` prevents every delayed publication for that key.
pub fn close_generation(
  store: Store,
  key: g.GenerationKey,
) -> Result(Phase, Error) {
  use bytes <- result.try(key_bytes(key))
  transaction(store, PhaseWork, fn(store, inventory) {
    case find_header(inventory, bytes) {
      None -> {
        let charge = reservation(bytes)
        use Nil <- result.try(available(store, inventory, charge, 0))
        use retired <- result.try(record(key, NeverStarted))
        let #(scope, _, number) = g.key_fields(key)
        use scope <- result.try(scope_bytes(scope))
        use Nil <- result.try(statement(
          store,
          sql.insert_generation_never_started(
            bytes,
            scope,
            number,
            charge,
            retired.bytes,
            g.digest_bytes(retired.digest),
          ),
        ))

        // A close acknowledgement requires the actual permanent no-claim row.
        use row <- result.try(inserted_row(store, bytes))
        use Nil <- result.try(
          case row.retired == Some(retired) && row.header.claimed == 0 {
            True -> Ok(Nil)
            False -> Error(Uncertain)
          },
        )
        Ok(Retired)
      }
      Some(header) -> {
        use _ <- result.try(read_row(store, header))
        case header.phase {
          0 | 1 | 2 -> {
            use Nil <- result.try(changed(
              store,
              sql.close_generation_fence(bytes),
              fn(row) { row.phase },
              3,
            ))
            Ok(Closing)
          }
          _ -> decode_phase(header.phase)
        }
      }
    }
  })
}

/// Validates full original physical witnesses, then commits exact retirement.
/// The trusted local verifier must check actual original handles and join order;
/// it runs before acquiring the writer lock, which then rechecks original custody.
///
/// ## Examples
///
/// `retire_started(claim, evidence, verify_original)` cannot use a recovered claim.
pub fn retire_started(
  claim: StartupClaim,
  evidence: StartedEvidence,
  verify: fn(StartupClaim, StartedEvidence) -> Result(Nil, Error),
) -> Result(RetirementRecord, Error) {
  use Nil <- result.try(verify(claim, evidence))
  use retired <- result.try(record(
    g.association_key(claim.association),
    StartedRetired(evidence),
  ))
  use saved <- result.try(
    transaction(claim.store, RetirementWork, fn(store, inventory) {
      use row <- result.try(claim_row(store, claim, inventory))
      case row.retired {
        Some(old) ->
          case old == retired {
            True -> Ok(old)
            False -> Error(Conflict)
          }
        None -> {
          use Nil <- result.try(case row.header.phase {
            3 -> Ok(Nil)
            _ -> Error(Fenced)
          })
          use Nil <- result.try(endpoint_matches(row.header, evidence.endpoint))
          use Nil <- result.try(changed(
            store,
            sql.retire_generation(
              retired.bytes,
              g.digest_bytes(retired.digest),
              row.header.key,
              uuid(claim.store.incarnation),
            ),
            fn(row) { row.phase },
            4,
          ))
          Ok(retired)
        }
      }
    }),
  )

  // A returned record additionally follows exact post-COMMIT readback.
  retirement(claim.store, saved.key)
}

/// Reads only the exact permanently committed retirement record.
///
/// ## Examples
///
/// `retirement(store, key)` returns Missing while original physical custody remains.
pub fn retirement(
  store: Store,
  key: g.GenerationKey,
) -> Result(RetirementRecord, Error) {
  use bytes <- result.try(key_bytes(key))
  transaction(store, RetirementWork, fn(store, inventory) {
    use header <- result.try(required_header(inventory, bytes))
    use row <- result.try(read_row(store, header))
    row.retired |> option.to_result(Missing)
  })
}

/// Projects canonical committed bytes and their independent node record digest.
///
/// ## Examples
///
/// `retirement_fields(record)` carries history without replacement authority.
pub fn retirement_fields(
  value: RetirementRecord,
) -> #(g.GenerationKey, RetirementKind, BitArray, g.Digest) {
  #(value.key, value.kind, value.bytes, value.digest)
}

/// Checks exact committed published retirement against its original endpoint.
/// Endpoint hot-row removal must additionally prove its own fence and drain.
///
/// ## Examples
///
/// `validate_removal(store, retired, endpoint)` refuses historical key equality.
@internal
pub fn validate_removal(
  store: Store,
  retired: RetirementRecord,
  endpoint: g.Digest,
) -> Result(Nil, Error) {
  use Nil <- result.try(case retired.kind {
    StartedRetired(StartedEvidence(
      endpoint: PublishedFencedDrained(original),
      ..,
    ))
      if original == endpoint
    -> Ok(Nil)
    NeverStarted | StartedRetired(_) -> Error(Conflict)
  })
  use key <- result.try(key_bytes(retired.key))
  transaction(store, NilWork, fn(context, inventory) {
    use header <- result.try(required_header(inventory, key))
    use row <- result.try(read_row(context, header))
    use Nil <- result.try(case row.retired == Some(retired) {
      True -> Ok(Nil)
      False -> Error(Conflict)
    })
    use Nil <- result.try(case header.phase {
      4 | 5 -> Ok(Nil)
      _ -> Error(Fenced)
    })
    case
      header.claim_incarnation == uuid(context.incarnation)
      && header.endpoint_incarnation == g.digest_bytes(endpoint)
    {
      True -> Ok(Nil)
      False -> Error(Conflict)
    }
  })
}

/// Records removal only after exact original endpoint ACK or never-published proof.
/// The trusted local verifier checks Fenced+Drained again and exact hot-row removal;
/// for UnpublishedFenced it confirms that no endpoint publication was authorized.
///
/// ## Examples
///
/// `remove(store, retired, verify_original_removal)` frees a slot after its COMMIT.
pub fn remove(
  store: Store,
  retired: RetirementRecord,
  verify: fn(RetirementRecord) -> Result(Nil, Error),
) -> Result(Nil, Error) {
  use Nil <- result.try(verify(retired))
  use bytes <- result.try(key_bytes(retired.key))
  use Nil <- result.try(
    transaction(store, NilWork, fn(store, inventory) {
      use header <- result.try(required_header(inventory, bytes))
      use row <- result.try(read_row(store, header))
      use saved <- result.try(row.retired |> option.to_result(Missing))
      use Nil <- result.try(case saved == retired {
        True -> Ok(Nil)
        False -> Error(Conflict)
      })
      case retired.kind, header.phase {
        NeverStarted, _ -> Ok(Nil)
        StartedRetired(_), 5 -> Ok(Nil)
        StartedRetired(_), 4 ->
          changed(
            store,
            sql.remove_generation(bytes, g.digest_bytes(retired.digest)),
            fn(row) { row.phase },
            5,
          )
        StartedRetired(_), _ -> Error(Fenced)
      }
    }),
  )

  // Exact post-COMMIT observation proves slot release was retained.
  use phase <- result.try(observe(store, retired.key))
  case retired.kind, phase {
    NeverStarted, Retired -> Ok(Nil)
    StartedRetired(_), Removed -> Ok(Nil)
    _, _ -> Error(Uncertain)
  }
}

/// Authenticates the original owner's canonical close bytes and retains their digest.
/// The local verifier must decode the closed owner attestation and compare every
/// original owner join, association and executor record against its configured Peer.
/// It is never a provider-supplied closure or unchecked wire constructor.
///
/// ## Examples
///
/// `attest_predecessor(store, previous, bytes, verify_owner)` compares node history first.
pub fn attest_predecessor(
  store: Store,
  previous: g.GenerationAssociation,
  owner_bytes: BitArray,
  verify: fn(g.GenerationAssociation, RetirementRecord, BitArray) ->
    Result(Nil, Error),
) -> Result(PredecessorProof, Error) {
  use node <- result.try(retirement(store, g.association_key(previous)))
  use Nil <- result.try(validate_owner_bytes(owner_bytes))
  use Nil <- result.try(verify(previous, node, owner_bytes))
  use envelope <- result.try(
    mp.encode(
      mp.ArrayValue([g.association_value(previous), mp.BinaryValue(owner_bytes)]),
    )
    |> result.replace_error(Corrupt),
  )
  use Nil <- result.try(case bit_array.byte_size(envelope) <= max_record_bytes {
    True -> Ok(Nil)
    False -> Error(Capacity)
  })
  let owner_hash = hash(owner_bytes)
  use bytes <- result.try(key_bytes(g.association_key(previous)))
  use Nil <- result.try(
    transaction(store, NilWork, fn(store, inventory) {
      use header <- result.try(required_header(inventory, bytes))
      use row <- result.try(read_row(store, header))
      use saved <- result.try(row.retired |> option.to_result(Missing))
      use Nil <- result.try(case saved == node {
        True -> Ok(Nil)
        False -> Error(Conflict)
      })
      use Nil <- result.try(case row.association {
        Some(original) if original != previous -> Error(Conflict)
        _ -> Ok(Nil)
      })
      case row.owner_close {
        <<>> ->
          changed(
            store,
            sql.retain_generation_owner_close(
              envelope,
              owner_hash,
              bytes,
              g.digest_bytes(node.digest),
            ),
            fn(row) { row.phase },
            header.phase,
          )
        existing
          if existing == envelope && header.owner_close_digest == owner_hash
        -> Ok(Nil)
        _ -> Error(Conflict)
      }
    }),
  )

  // Proof assembly follows exact durable envelope readback, including the no-claim case.
  transaction(store, PredecessorWork, fn(store, inventory) {
    use header <- result.try(required_header(inventory, bytes))
    use row <- result.try(read_row(store, header))
    use Nil <- result.try(
      case
        row.owner_close == envelope && header.owner_close_digest == owner_hash
      {
        True -> Ok(Nil)
        False -> Error(Uncertain)
      },
    )
    use owner <- result.try(
      g.digest(owner_hash) |> result.replace_error(Corrupt),
    )
    Ok(PredecessorProof(previous, node, owner))
  })
}

fn open(
  path: String,
  incarnation: ids.EntryId,
  limits: Limits,
  mode: OpenMode,
) -> Result(Store, Error) {
  use Nil <- result.try(validate_path(path))
  use exists <- result.try(
    simplifile.exists(path, False) |> result.replace_error(InvalidPath),
  )
  use Nil <- result.try(case mode, exists {
    Create, True -> Error(AlreadyExists)
    Recover, False -> Error(Missing)
    _, _ -> Ok(Nil)
  })
  use connection <- result.try(sqlight.open(path) |> sql_error)
  let provisional = Context(connection, incarnation, limits, 2)
  let opened = {
    // Unknown versions refuse before even journal-profile mutation. Version one
    // is validated under its original scalar/body rules before any DDL upgrade.
    use format <- result.try(case mode {
      Create -> Ok(2)
      Recover -> {
        use formats <- result.try(
          query(provisional, sql.generation_format())
          |> result.replace_error(Corrupt),
        )
        case formats {
          [value] if value.format == 1 || value.format == 2 -> Ok(value.format)
          _ -> Error(Corrupt)
        }
      }
    })
    let store = Context(..provisional, format: format)
    use modes <- result.try(
      sqlight.query(
        "PRAGMA journal_mode=WAL",
        connection,
        [],
        decode.field(0, decode.string, decode.success),
      )
      |> sql_error,
    )
    use Nil <- result.try(case modes {
      ["wal"] -> Ok(Nil)
      _ -> Error(Uncertain)
    })
    use Nil <- result.try(
      sqlight.exec(
        "PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000",
        connection,
      )
      |> sql_error,
    )
    use levels <- result.try(
      sqlight.query(
        "PRAGMA synchronous",
        connection,
        [],
        decode.field(0, decode.int, decode.success),
      )
      |> sql_error,
    )
    use Nil <- result.try(case levels {
      [2] -> Ok(Nil)
      _ -> Error(Uncertain)
    })
    use Nil <- result.try(
      sqlight.exec("BEGIN IMMEDIATE", connection) |> sql_error,
    )
    let initialized = {
      use Nil <- result.try(case mode {
        Create -> {
          use Nil <- result.try(
            sqlight.exec(generation_registry_schema.schema, connection)
            |> sql_error,
          )
          statement(
            store,
            sql.initialize_generations(limits.live, limits.rows, limits.bytes),
          )
        }
        Recover -> Ok(Nil)
      })
      use original_inventory <- result.try(inventory(store))
      use Nil <- result.try(
        list.try_each(original_inventory.headers, fn(header) {
          read_row(store, header) |> result.replace(Nil)
        }),
      )
      use Nil <- result.try(case mode, format {
        Recover, 1 ->
          sqlight.exec(generation_scope_plan_migration.schema, connection)
          |> sql_error
        Create, _ | Recover, _ -> Ok(Nil)
      })

      // The upgrade retains every old reservation and intentionally inserts no
      // provenance. Validate its new scalar shape before uncertainty changes.
      let upgraded = Context(..store, format: 2)
      use _ <- result.try(inventory(upgraded))
      case mode {
        Create -> Ok(Nil)
        Recover -> statement(upgraded, sql.recover_generation_uncertainty(<<>>))
      }
    }
    complete_transaction(store, initialized)
  }
  case opened {
    Ok(Nil) -> {
      case
        actor.new(Open(provisional))
        |> actor.on_message(handle)
        |> actor.on_shutdown(shutdown)
        |> actor.start
      {
        Ok(started) -> Ok(Store(started.data, incarnation, limits))
        Error(_) -> {
          let _ = sqlight.close(connection)
          Error(Uncertain)
        }
      }
    }
    Error(error) -> {
      let _ = sqlight.close(connection)
      Error(error)
    }
  }
}

fn validate_path(path: String) -> Result(Nil, Error) {
  use Nil <- result.try(
    case
      string.starts_with(path, "/")
      && string.byte_size(path) <= 4096
      && !string.contains(path, "\u{0}")
    {
      True -> Ok(Nil)
      False -> Error(InvalidPath)
    },
  )
  use kind <- result.try(
    simplifile.is_directory(path)
    |> result.or(Ok(False))
    |> result.replace_error(InvalidPath),
  )
  use Nil <- result.try(case kind {
    True -> Error(InvalidPath)
    False -> Ok(Nil)
  })
  let parent = case string.split(path, "/") |> list.reverse {
    [_file, ..parents] -> parents |> list.reverse |> string.join("/")
    [] -> ""
  }
  use exists <- result.try(
    simplifile.is_directory(parent) |> result.replace_error(InvalidPath),
  )
  case exists {
    True -> Ok(Nil)
    False -> Error(InvalidPath)
  }
}

fn transact(
  store: Context,
  work: fn(Context, Inventory) -> Result(a, Error),
) -> Result(a, Error) {
  use Nil <- result.try(
    sqlight.exec("BEGIN IMMEDIATE", store.connection) |> sql_error,
  )
  let outcome = {
    use inventory <- result.try(inventory(store))
    work(store, inventory)
  }
  complete_transaction(store, outcome)
}

fn complete_transaction(
  store: Context,
  outcome: Result(a, Error),
) -> Result(a, Error) {
  let answer = case outcome {
    Ok(value) ->
      sqlight.exec("COMMIT", store.connection)
      |> sql_error
      |> result.replace(value)
    Error(error) ->
      case sqlight.exec("ROLLBACK", store.connection) {
        Ok(Nil) -> Error(error)
        Error(_) -> Error(Uncertain)
      }
  }
  answer
}

fn inventory(store: Context) -> Result(Inventory, Error) {
  use formats <- result.try(
    query(store, sql.generation_format()) |> result.replace_error(Corrupt),
  )
  use Nil <- result.try(case formats {
    [value] if value.format == store.format -> Ok(Nil)
    _ -> Error(Corrupt)
  })
  use metadata <- result.try(query(store, sql.generation_metadata()))
  use Nil <- result.try(case metadata {
    [meta]
      if meta.live_limit == store.limits.live
      && meta.row_limit == store.limits.rows
      && meta.byte_limit == store.limits.bytes
    -> Ok(Nil)
    _ -> Error(Conflict)
  })

  // Scalar SQL guards reject excessive inventories before any bounded body read.
  use totals <- result.try(query(store, sql.generation_inventory()))
  use total <- result.try(case totals {
    [total] -> Ok(total)
    _ -> Error(Corrupt)
  })
  use live <- result.try(decoded_scalar(total.live))
  use bytes <- result.try(decoded_scalar(total.bytes))
  use invalid <- result.try(decoded_scalar(total.invalid))
  use Nil <- result.try(
    case
      total.rows >= 0
      && total.rows <= store.limits.rows
      && live >= 0
      && live <= store.limits.live
      && bytes >= 0
      && bytes <= store.limits.bytes
      && invalid == 0
    {
      True -> Ok(Nil)
      False -> Error(Corrupt)
    },
  )

  // Child scalars, orphans and exact parent charges are checked without loading
  // either body. Legacy version-one custody has no child table to inspect yet.
  use Nil <- result.try(validate_plan_inventory(store, total.rows))

  // The permanent row bound limits the complete immutable header inventory.
  use headers <- result.try(query(
    store,
    sql.generation_headers(store.limits.rows + 1),
  ))
  use Nil <- result.try(case list.length(headers) == total.rows {
    True -> Ok(Nil)
    False -> Error(Corrupt)
  })
  Ok(Inventory(headers, total.rows, live, bytes))
}

fn read_row(
  store: Context,
  header: sql.GenerationHeaders,
) -> Result(Row, Error) {
  use key <- result.try(
    g.decode_key(header.key) |> result.replace_error(Corrupt),
  )
  let #(scope, _, number) = g.key_fields(key)
  use scope <- result.try(scope_bytes(scope))
  use plan_header <- result.try(read_plan_header(store, header.key))
  use Nil <- result.try(
    case
      scope == header.scope
      && number == header.generation
      && header.reservation
      == reservation(header.key) + plan_header_charge(plan_header)
    {
      True -> Ok(Nil)
      False -> Error(Corrupt)
    },
  )
  use _ <- result.try(decode_phase(header.phase))

  // Header guards precede materialization; this query independently caps bodies.
  use bodies <- result.try(query(store, sql.generation_body(header.key)))
  use body <- result.try(case bodies {
    [body] -> Ok(body)
    _ -> Error(Corrupt)
  })
  use Nil <- result.try(
    case
      Some(bit_array.byte_size(body.association)) == header.association_size
      && Some(bit_array.byte_size(body.doors)) == header.doors_size
      && Some(bit_array.byte_size(body.retirement)) == header.retirement_size
      && Some(bit_array.byte_size(body.owner_close)) == header.owner_close_size
    {
      True -> Ok(Nil)
      False -> Error(Corrupt)
    },
  )

  // A no-claim close retains no startup fields; a started row keeps every original.
  use associated <- result.try(case header.claimed {
    0
      if body.association == <<>>
      && body.doors == <<>>
      && header.owner_use == <<>>
      && header.claim_incarnation == <<>>
      && header.association_digest == <<>>
      && header.live == 0
      && header.ever_published == 0
      && { header.phase == 4 || header.phase == 5 }
    -> Ok(None)
    1 -> {
      use associated <- result.try(
        g.decode_association(body.association) |> result.replace_error(Corrupt),
      )
      let #(_, _, owner, _) = g.association_fields(associated)
      use _ <- result.try(parse_uuid(header.claim_incarnation))
      use Nil <- result.try(
        validate_doors(body.doors) |> result.replace_error(Corrupt),
      )
      use Nil <- result.try(
        case
          g.association_key(associated) == key
          && uuid(owner) == header.owner_use
          && hash(body.association) == header.association_digest
          && {
            { header.phase == 5 && header.live == 0 }
            || { header.phase != 5 && header.live == 1 }
          }
        {
          True -> Ok(Nil)
          False -> Error(Corrupt)
        },
      )
      Ok(Some(associated))
    }
    _ -> Error(Corrupt)
  })
  use Nil <- result.try(
    case header.ever_published, header.endpoint_incarnation {
      0, <<>> if header.phase != 1 && header.phase != 2 -> Ok(Nil)
      1, <<_:size(256)>> -> Ok(Nil)
      _, _ -> Error(Corrupt)
    },
  )

  // Closed retirement provenance must match both durable phase and endpoint intent.
  use retired <- result.try(case body.retirement {
    <<>>
      if header.retirement_digest == <<>>
      && header.phase != 4
      && header.phase != 5
    -> Ok(None)
    bytes -> {
      use retired <- result.try(decode_record(key, bytes))
      use Nil <- result.try(
        case
          g.digest_bytes(retired.digest) == header.retirement_digest
          && { header.phase == 4 || header.phase == 5 }
        {
          True -> Ok(Nil)
          False -> Error(Corrupt)
        },
      )
      use Nil <- result.try(case retired.kind, associated {
        NeverStarted, None -> Ok(Nil)
        StartedRetired(evidence), Some(_) ->
          endpoint_matches(header, evidence.endpoint)
          |> result.replace_error(Corrupt)
        _, _ -> Error(Corrupt)
      })
      Ok(Some(retired))
    }
  })

  // Authenticated predecessor history remains tied to its full original association.
  use Nil <- result.try(validate_owner_envelope(
    header,
    body.owner_close,
    key,
    associated,
    retired,
  ))
  use plan <- result.try(read_plan(store, header.key, associated, plan_header))
  Ok(Row(header, associated, body.doors, retired, body.owner_close, plan))
}

fn validate_plan_inventory(
  store: Context,
  parent_rows: Int,
) -> Result(Nil, Error) {
  case store.format {
    1 -> Ok(Nil)
    2 -> {
      use totals <- result.try(query(store, sql.generation_plan_inventory()))
      use total <- result.try(case totals {
        [total] -> Ok(total)
        _ -> Error(Corrupt)
      })
      use invalid <- result.try(decoded_scalar(total.invalid))
      use Nil <- result.try(
        case total.rows >= 0 && total.rows <= parent_rows && invalid == 0 {
          True -> Ok(Nil)
          False -> Error(Corrupt)
        },
      )
      use charges <- result.try(query(store, sql.generation_plan_charges()))
      use charge <- result.try(case charges {
        [charge] -> Ok(charge)
        _ -> Error(Corrupt)
      })
      use invalid <- result.try(decoded_scalar(charge.invalid))
      case invalid == 0 {
        True -> Ok(Nil)
        False -> Error(Corrupt)
      }
    }
    _ -> Error(Corrupt)
  }
}

fn read_plan_header(
  store: Context,
  key: BitArray,
) -> Result(Option(PlanHeader), Error) {
  case store.format {
    1 -> Ok(None)
    2 -> {
      use headers <- result.try(query(store, sql.generation_plan_header(key)))
      case headers {
        [] -> Ok(None)
        [header] -> {
          use size <- result.try(option.to_result(header.header_size, Corrupt))
          use enrollment_size <- result.try(option.to_result(
            header.enrollment_size,
            Corrupt,
          ))
          use digest <- result.try(
            g.digest(header.digest) |> result.replace_error(Corrupt),
          )
          case
            size > 0
            && size <= scope_plan.max_body_bytes
            && enrollment_size > 0
            && enrollment_size <= scope_plan.max_body_bytes
          {
            True -> Ok(Some(PlanHeader(size, enrollment_size, digest)))
            False -> Error(Corrupt)
          }
        }
        _ -> Error(Corrupt)
      }
    }
    _ -> Error(Corrupt)
  }
}

fn plan_header_charge(header: Option(PlanHeader)) -> Int {
  case header {
    None -> 0
    Some(header) -> header.header_size + header.enrollment_size + 32
  }
}

fn read_plan(
  store: Context,
  key: BitArray,
  associated: Option(g.GenerationAssociation),
  header: Option(PlanHeader),
) -> Result(Option(scope_plan.Plan), Error) {
  case header {
    None -> Ok(None)
    Some(header) -> {
      use associated <- result.try(option.to_result(associated, Corrupt))
      use bodies <- result.try(query(store, sql.generation_plan_body(key)))
      use body <- result.try(case bodies {
        [body] -> Ok(body)
        _ -> Error(Corrupt)
      })
      use Nil <- result.try(
        case
          bit_array.byte_size(body.header) == header.header_size
          && bit_array.byte_size(body.enrollment) == header.enrollment_size
        {
          True -> Ok(Nil)
          False -> Error(Corrupt)
        },
      )
      use plan <- result.try(
        scope_plan.decode(body.header, body.enrollment, header.digest)
        |> result.replace_error(Corrupt),
      )
      case scope_plan.original(plan) == associated {
        True -> Ok(Some(plan))
        False -> Error(Corrupt)
      }
    }
  }
}

fn insert_plan(
  store: Context,
  key: BitArray,
  plan: Option(scope_plan.Plan),
) -> Result(Nil, Error) {
  case plan {
    None -> Ok(Nil)
    Some(plan) -> {
      let #(header, enrollment, digest) = scope_plan.encoded(plan)
      statement(
        store,
        sql.insert_generation_scope_plan(
          key,
          header,
          enrollment,
          g.digest_bytes(digest),
        ),
      )
    }
  }
}

fn exact_plan(
  retained: Option(scope_plan.Plan),
  proposed: Option(scope_plan.Plan),
) -> Result(Nil, Error) {
  case proposed {
    None -> Ok(Nil)
    Some(proposed) -> {
      case retained {
        Some(retained) if retained == proposed -> Ok(Nil)
        None | Some(_) -> Error(Conflict)
      }
    }
  }
}

fn plan_reservation(plan: Option(scope_plan.Plan)) -> Int {
  case plan {
    None -> 0
    Some(plan) -> scope_plan.reservation(plan)
  }
}

fn validate_owner_envelope(
  header: sql.GenerationHeaders,
  bytes: BitArray,
  key: g.GenerationKey,
  associated: Option(g.GenerationAssociation),
  retired: Option(RetirementRecord),
) -> Result(Nil, Error) {
  case bytes {
    <<>> if header.owner_close_digest == <<>> -> Ok(Nil)
    _ -> {
      use value <- result.try(
        bounded_msgpack.decode(bytes) |> result.replace_error(Corrupt),
      )
      case value, retired {
        mp.ArrayValue([original, mp.BinaryValue(attestation)]), Some(_) -> {
          use original <- result.try(
            g.decode_association_value(original)
            |> result.replace_error(Corrupt),
          )
          use canonical <- result.try(
            mp.encode(
              mp.ArrayValue([
                g.association_value(original),
                mp.BinaryValue(attestation),
              ]),
            )
            |> result.replace_error(Corrupt),
          )
          case
            canonical == bytes
            && g.association_key(original) == key
            && hash(attestation) == header.owner_close_digest
            && { associated == None || associated == Some(original) }
          {
            True -> Ok(Nil)
            False -> Error(Corrupt)
          }
        }
        _, _ -> Error(Corrupt)
      }
    }
  }
}

fn claim_row(
  store: Context,
  claim: StartupClaim,
  inventory: Inventory,
) -> Result(Row, Error) {
  use bytes <- result.try(key_bytes(g.association_key(claim.association)))
  use header <- result.try(required_header(inventory, bytes))
  use row <- result.try(read_row(store, header))
  use Nil <- result.try(exact_original(row, claim.association, claim.doors))
  case header.claim_incarnation == uuid(claim.store.incarnation) {
    True -> Ok(row)
    False -> Error(Conflict)
  }
}

fn exact_original(
  row: Row,
  associated: g.GenerationAssociation,
  doors: BitArray,
) -> Result(Nil, Error) {
  case row.association {
    None -> Error(Fenced)
    Some(original) if original == associated && row.doors == doors -> Ok(Nil)
    Some(_) -> Error(Conflict)
  }
}

fn check_lineage(
  store: Context,
  associated: g.GenerationAssociation,
  configured_first: Int,
  predecessor: Option(PredecessorProof),
) -> Result(Nil, Error) {
  case predecessor {
    None -> {
      use Nil <- result.try(
        g.checked_first(associated, configured_first)
        |> result.replace_error(Conflict),
      )
      use scope <- result.try(
        scope_bytes(g.key_scope(g.association_key(associated))),
      )
      use history <- result.try(inventory(store))
      case list.any(history.headers, fn(header) { header.scope == scope }) {
        True -> Error(Conflict)
        False -> Ok(Nil)
      }
    }
    Some(proof) -> {
      use Nil <- result.try(
        g.checked_successor(
          associated,
          proof.association,
          proof.node.digest,
          proof.owner,
        )
        |> result.replace_error(Conflict),
      )
      use key <- result.try(key_bytes(proof.node.key))
      use current <- result.try(inventory(store))
      use header <- result.try(required_header(current, key))
      use row <- result.try(read_row(store, header))
      use saved <- result.try(row.retired |> option.to_result(Missing))
      case
        saved == proof.node
        && header.owner_close_digest == g.digest_bytes(proof.owner)
        && bit_array.byte_size(row.owner_close) > 0
        && { header.claimed == 0 || header.phase == 5 }
      {
        True -> Ok(Nil)
        False -> Error(Fenced)
      }
    }
  }
}

fn available(
  store: Context,
  inventory: Inventory,
  charge: Int,
  live: Int,
) -> Result(Nil, Error) {
  case
    inventory.rows < store.limits.rows
    && inventory.live + live <= store.limits.live
    && inventory.bytes + charge <= store.limits.bytes
  {
    True -> Ok(Nil)
    False -> Error(Capacity)
  }
}

fn find_header(
  inventory: Inventory,
  key: BitArray,
) -> Option(sql.GenerationHeaders) {
  list.find(inventory.headers, fn(header) { header.key == key })
  |> option.from_result
}

fn required_header(
  inventory: Inventory,
  key: BitArray,
) -> Result(sql.GenerationHeaders, Error) {
  find_header(inventory, key) |> option.to_result(Missing)
}

fn endpoint_matches(
  header: sql.GenerationHeaders,
  witness: EndpointWitness,
) -> Result(Nil, Error) {
  case witness {
    UnpublishedFenced
      if header.ever_published == 0 && header.endpoint_incarnation == <<>>
    -> Ok(Nil)
    PublishedFencedDrained(endpoint) -> {
      case
        header.ever_published == 1
        && header.endpoint_incarnation == g.digest_bytes(endpoint)
      {
        True -> Ok(Nil)
        False -> Error(Conflict)
      }
    }
    _ -> Error(Conflict)
  }
}

fn record(
  key: g.GenerationKey,
  kind: RetirementKind,
) -> Result(RetirementRecord, Error) {
  let value =
    mp.ArrayValue([
      mp.IntValue(1),
      mp.StringValue("loom.generation.retirement/1"),
      g.key_value(key),
      kind_value(kind),
    ])
  use bytes <- result.try(mp.encode(value) |> result.replace_error(Corrupt))
  use digest <- result.try(
    g.digest(hash(bytes)) |> result.replace_error(Corrupt),
  )
  Ok(RetirementRecord(key, kind, bytes, digest))
}

fn kind_value(kind: RetirementKind) -> mp.MsgPackValue {
  case kind {
    NeverStarted -> mp.ArrayValue([mp.IntValue(0)])
    StartedRetired(e) ->
      mp.ArrayValue([
        mp.IntValue(1),
        case e.endpoint {
          UnpublishedFenced -> mp.ArrayValue([mp.IntValue(0)])
          PublishedFencedDrained(endpoint) ->
            mp.ArrayValue([
              mp.IntValue(1),
              mp.BinaryValue(g.digest_bytes(endpoint)),
            ])
        },
        mp.ArrayValue(
          list.map(
            [
              e.continuations,
              e.resources,
              e.native_scope,
              e.covered_keys,
              e.services,
              e.journals,
              e.host,
            ],
            fn(digest) { mp.BinaryValue(g.digest_bytes(digest)) },
          ),
        ),
      ])
  }
}

fn decode_record(
  expected: g.GenerationKey,
  bytes: BitArray,
) -> Result(RetirementRecord, Error) {
  use value <- result.try(
    bounded_msgpack.decode(bytes) |> result.replace_error(Corrupt),
  )
  case value {
    mp.ArrayValue([
      mp.IntValue(1),
      mp.StringValue("loom.generation.retirement/1"),
      key,
      kind,
    ]) -> {
      use key <- result.try(
        g.decode_key_value(key) |> result.replace_error(Corrupt),
      )
      use Nil <- result.try(case key == expected {
        True -> Ok(Nil)
        False -> Error(Corrupt)
      })
      use kind <- result.try(decode_kind(kind))
      use record <- result.try(record(key, kind))
      case record.bytes == bytes {
        True -> Ok(record)
        False -> Error(Corrupt)
      }
    }
    _ -> Error(Corrupt)
  }
}

fn decode_kind(value: mp.MsgPackValue) -> Result(RetirementKind, Error) {
  case value {
    mp.ArrayValue([mp.IntValue(0)]) -> Ok(NeverStarted)
    mp.ArrayValue([mp.IntValue(1), endpoint, mp.ArrayValue(witnesses)]) -> {
      use endpoint <- result.try(case endpoint {
        mp.ArrayValue([mp.IntValue(0)]) -> Ok(UnpublishedFenced)
        mp.ArrayValue([mp.IntValue(1), mp.BinaryValue(bytes)]) ->
          g.digest(bytes)
          |> result.map(PublishedFencedDrained)
          |> result.replace_error(Corrupt)
        _ -> Error(Corrupt)
      })
      use digests <- result.try(
        list.try_map(witnesses, fn(value) {
          case value {
            mp.BinaryValue(bytes) ->
              g.digest(bytes) |> result.replace_error(Corrupt)
            _ -> Error(Corrupt)
          }
        }),
      )
      case digests {
        [a, b, c, d, e, f, h] ->
          Ok(StartedRetired(StartedEvidence(endpoint, a, b, c, d, e, f, h)))
        _ -> Error(Corrupt)
      }
    }
    _ -> Error(Corrupt)
  }
}

fn decode_phase(value: Int) -> Result(Phase, Error) {
  case value {
    0 -> Ok(Claimed)
    1 -> Ok(Publishing)
    2 -> Ok(Published)
    3 -> Ok(Closing)
    4 -> Ok(Retired)
    5 -> Ok(Removed)
    6 -> Ok(Unknown)
    _ -> Error(Corrupt)
  }
}

fn validate_doors(bytes: BitArray) -> Result(Nil, Error) {
  use Nil <- result.try(
    case bit_array.byte_size(bytes) > 0 && bit_array.byte_size(bytes) <= 4096 {
      True -> Ok(Nil)
      False -> Error(Conflict)
    },
  )
  use value <- result.try(
    bounded_msgpack.decode(bytes) |> result.replace_error(Conflict),
  )
  use canonical <- result.try(
    mp.encode(value) |> result.replace_error(Conflict),
  )
  case canonical == bytes {
    True -> Ok(Nil)
    False -> Error(Conflict)
  }
}

fn validate_owner_bytes(bytes: BitArray) -> Result(Nil, Error) {
  case bit_array.byte_size(bytes) > 0 && bit_array.byte_size(bytes) <= 7168 {
    True -> Ok(Nil)
    False -> Error(Capacity)
  }
}

fn key_bytes(key: g.GenerationKey) -> Result(BitArray, Error) {
  g.encode_key(key) |> result.replace_error(Corrupt)
}

fn scope_bytes(scope: workspace.Scope) -> Result(BitArray, Error) {
  // The shared key codec supplies this index, with a fixed zero descriptor and
  // generation one. It preserves full scope without another identity encoding.
  use digest <- result.try(
    g.digest(<<0:size(256)>>) |> result.replace_error(Corrupt),
  )
  use key <- result.try(
    g.key(scope, digest, 1) |> result.replace_error(Corrupt),
  )
  g.encode_key(key) |> result.replace_error(Corrupt)
}

fn reservation(key: BitArray) -> Int {
  bit_array.byte_size(key)
  * 2
  + 1024
  + 4096
  + 36
  * 2
  + 32
  * 4
  + max_record_bytes
  * 2
}

fn uuid(value: ids.EntryId) -> BitArray {
  bit_array.from_string(ids.entry_id_to_string(value))
}

fn parse_uuid(bytes: BitArray) -> Result(ids.EntryId, Error) {
  use text <- result.try(
    bit_array.to_string(bytes) |> result.replace_error(Corrupt),
  )
  use id <- result.try(
    ids.parse_entry_id(text) |> result.replace_error(Corrupt),
  )
  case uuid(id) == bytes {
    True -> Ok(id)
    False -> Error(Corrupt)
  }
}

fn hash(bytes: BitArray) -> BitArray {
  crypto.hash(crypto.Sha256, bytes)
}

fn changed(
  store: Context,
  generated: #(String, List(dev.Param), decode.Decoder(a)),
  phase: fn(a) -> Int,
  expected: Int,
) -> Result(Nil, Error) {
  use rows <- result.try(query(store, generated))

  // Generated UPDATE RETURNING rows use the one closed phase field.
  case rows {
    [row] ->
      case phase(row) == expected {
        True -> Ok(Nil)
        False -> Error(Uncertain)
      }
    _ -> Error(Uncertain)
  }
}

fn statement(
  store: Context,
  generated: #(String, List(dev.Param)),
) -> Result(Nil, Error) {
  let #(text, parameters) = generated
  query(store, #(text, parameters, decode.success(Nil))) |> result.replace(Nil)
}

fn query(
  store: Context,
  generated: #(String, List(dev.Param), decode.Decoder(a)),
) -> Result(List(a), Error) {
  let #(text, parameters, decoder) = generated
  use arguments <- result.try(
    list.try_map(parameters, fn(value) {
      case value {
        dev.ParamInt(value) -> Ok(sqlight.int(value))
        dev.ParamBitArray(value) -> Ok(sqlight.blob(value))
        _ -> Error(Corrupt)
      }
    }),
  )
  sqlight.query(text, store.connection, arguments, decoder) |> sql_error
}

fn sql_error(value: Result(a, sqlight.Error)) -> Result(a, Error) {
  result.replace_error(value, Uncertain)
}

fn decoded_scalar(value: Option(decode.Dynamic)) -> Result(Int, Error) {
  use value <- result.try(option.to_result(value, Corrupt))
  decode.run(value, decode.int) |> result.replace_error(Corrupt)
}

fn inserted_row(store: Context, key: BitArray) -> Result(Row, Error) {
  use history <- result.try(inventory(store))
  use header <- result.try(
    required_header(history, key) |> result.replace_error(Uncertain),
  )
  read_row(store, header)
}

fn transaction(
  store: Store,
  make: fn(
    fn(Context, Inventory) -> Result(a, Error),
    process.Subject(Result(a, Error)),
  ) -> Message,
  work: fn(Context, Inventory) -> Result(a, Error),
) -> Result(a, Error) {
  exchange(store, fn(reply) { make(work, reply) })
}

fn exchange(
  store: Store,
  make: fn(process.Subject(Result(a, Error))) -> Message,
) -> Result(a, Error) {
  use owner <- result.try(
    process.subject_owner(store.subject) |> result.replace_error(Uncertain),
  )
  use Nil <- result.try(case process.is_alive(owner) {
    True -> Ok(Nil)
    False -> Error(Uncertain)
  })
  let reply = process.new_subject()
  let monitor = process.monitor(owner)
  process.send(store.subject, make(reply))
  let outcome =
    process.new_selector()
    |> process.select_map(reply, fn(answer) { answer })
    |> process.select_specific_monitor(monitor, fn(_) { Error(Uncertain) })
    |> process.selector_receive(30_000)

  // Timeout ends only observation; COMMIT may have preceded the lost reply.
  process.demonitor_process(monitor)
  result.unwrap(outcome, Error(Uncertain))
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    AdmissionWork(work, reply) -> handle_work(state, work, reply)
    PublicationWork(work, reply) -> handle_work(state, work, reply)
    PhaseWork(work, reply) -> handle_work(state, work, reply)
    RetirementWork(work, reply) -> handle_work(state, work, reply)
    PredecessorWork(work, reply) -> handle_work(state, work, reply)
    NilWork(work, reply) -> handle_work(state, work, reply)
    PlanWork(work, reply) -> handle_work(state, work, reply)
    Release(reply) -> {
      case state {
        Open(context) -> {
          let result = sqlight.close(context.connection) |> sql_error
          process.send(reply, result)
          actor.continue(Closed) |> actor.then_handle(Stop)
        }
        Closed -> {
          process.send(reply, Error(Uncertain))
          actor.continue(Closed) |> actor.then_handle(Stop)
        }
      }
    }
    Stop -> actor.stop()
  }
}

fn handle_work(
  state: State,
  work: fn(Context, Inventory) -> Result(a, Error),
  reply: process.Subject(Result(a, Error)),
) -> actor.Next(State, Message) {
  case state {
    Closed -> {
      process.send(reply, Error(Uncertain))
      actor.continue(Closed)
    }
    Open(context) -> {
      let outcome = transact(context, work)
      process.send(reply, outcome)
      case outcome {
        Error(Uncertain) | Error(Corrupt) -> {
          // Poisoned ownership closes its native handle once and cannot admit again.
          let _ = sqlight.close(context.connection)
          actor.continue(Closed) |> actor.then_handle(Stop)
        }
        _ -> actor.continue(state)
      }
    }
  }
}

fn shutdown(state: State, _reason: process.ExitReason) -> Nil {
  case state {
    Open(context) -> {
      let _ = sqlight.close(context.connection)
      Nil
    }
    Closed -> Nil
  }
}
