//// Durable principals, credentials, and session membership in the catalogue.
////
//// The daemon serializes these operations on its existing catalogue connection.
//// This module never opens a database or creates a process. Stable principal
//// identity is separate from a revocable credential: rotation cannot create a
//// new owner or change the identity recorded with an accepted user action.
////
//// Only validated SHA-256 digests enter this API. The caller must mint the
//// original credentials with cryptographic randomness and keep their plaintext
//// outside SQLite. Revoked digests remain tombstones, so replaying an old
//// bootstrap or creation request cannot reactivate a revoked credential.
//// Authorization here is internal data access, not a gateway policy or an
//// invitation endpoint. Callers must authenticate before using these mutations.
////
//// A member invited or rotated with a claim (protocol-change/053) has no
//// credential at all until the claim is redeemed. The claim's digest lives in
//// `access_claims` and never in `access_credentials`, so `authenticate` cannot
//// find it: a claim token authenticates nothing. `claim` binds the invitee's
//// own credential digest to the claim exactly once, in one transaction, and a
//// claim row is never deleted, so a spent or voided claim cannot be bound
//// again. A member has either one open claim and no active credential, or no
//// open claim; rotation and revocation void the open claim before they touch
//// credentials, which keeps that true.

import gleam/bool
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import storage/catalogue.{type Catalogue, type Error, Conflict, Invalid, Missing}
import storage/sql

/// A validated lowercase hexadecimal SHA-256 credential digest.
pub opaque type Digest {
  Digest(value: String)
}

/// A validated lowercase hexadecimal SHA-256 digest of a claim token.
///
/// It is a separate type from `Digest` so that no caller can hand a claim to
/// `authenticate`: the two digests name different tables, and only a
/// credential digest ever authorizes a connection.
pub opaque type ClaimDigest {
  ClaimDigest(value: String)
}

/// How an invited or rotated member comes to hold a credential.
pub type Enrollment {
  /// An open claim that expires at `expires_at_ms`, a wall-clock instant in
  /// Unix milliseconds. The member has no credential until the claim is
  /// redeemed with `claim`.
  ClaimEnrollment(claim: ClaimDigest, expires_at_ms: Int)

  /// The digest of a credential the invitee drew for itself, bound at once
  /// with no claim (enrollment by digest in protocol-change/053).
  DigestEnrollment(credential: Digest)
}

/// One session membership, as the claim reply reports it.
pub type Membership {
  Membership(
    /// Canonical session identity.
    session_id: String,
    /// The role this membership grants.
    role: Role,
  )
}

/// The outcome of a successful claim, identical on every repetition with the
/// same credential digest.
pub type Claimed {
  Claimed(
    /// The member the claim names, with its current display name.
    principal: Principal,
    /// At most `claim_membership_limit` memberships, in session-ID order.
    memberships: List(Membership),
  )
}

/// Why a claim was refused. None of them carries a digest or a token.
pub type ClaimRefusal {
  /// No such claim, a voided one, or a claimed one whose credential is no
  /// longer active.
  UnknownClaim

  /// The claim was still open when its expiry instant passed.
  ExpiredClaim

  /// The claim is bound to another credential, the presented digest is
  /// already a credential, the member already holds an active credential, or
  /// the presented digest is the claim's own.
  ConflictingClaim

  /// The catalogue could not answer or refused the write.
  ClaimStore(error: Error)
}

/// The most memberships a claim reply lists; the member's own session listing
/// returns the rest. The claim-memberships query carries the same bound.
pub const claim_membership_limit = 16

// The three persisted claim states, decoded totally from the row.
type ClaimState {
  OpenClaim
  ClaimedBy(credential: Digest)
  VoidClaim
}

type ClaimRow {
  ClaimRow(
    claim: ClaimDigest,
    principal_id: String,
    expires_at_ms: Int,
    state: ClaimState,
  )
}

/// Principal identity does not change when its credentials rotate.
pub type PrincipalKind {
  /// The single daemon-wide owner.
  OwnerPrincipal

  /// A participant whose authority comes from per-session membership.
  MemberPrincipal
}

/// Current durable identity, suitable for an accepted action's origin snapshot.
pub type Principal {
  Principal(
    /// Stable identifier, never a bearer token or display name.
    id: String,
    /// Current human-readable name; old origin snapshots remain unchanged.
    display_name: String,
    /// Whether authority is daemon-wide or membership-scoped.
    kind: PrincipalKind,
  )
}

/// The only roles a session membership may grant.
pub type Role {
  /// May issue commands allowed by the session's gateway policy.
  Operator

  /// May observe without issuing mutating commands.
  Observer
}

/// Authority for an existing catalogue session.
pub type Authority {
  /// The unique owner has daemon-wide authority.
  Owner

  /// A non-owner has exactly the stored role for this session.
  Participant(role: Role)
}

type CredentialState {
  Active
  Revoked
}

type Credential {
  Credential(principal_id: String, state: CredentialState)
}

/// Validates a digest without accepting a plaintext credential.
/// This checks representation, not the entropy of the original credential.
///
/// ## Examples
///
/// ```gleam
/// // access.credential_digest(sha256_hex(cryptographically_random_token))
/// ```
@internal
pub fn credential_digest(value: String) -> Result(Digest, Error) {
  case string.byte_size(value) == 64 && ascii_in(value, "0123456789abcdef") {
    True -> Ok(Digest(value))
    False -> Error(Invalid("credential digest must be 64 lowercase hex bytes"))
  }
}

/// Validates a claim-token digest. Like `credential_digest`, this checks the
/// representation only; the caller hashes the whole `loomclaim_` string.
///
/// ## Examples
///
/// ```gleam
/// // access.claim_digest(sha256_hex("loomclaim_" <> random_hex))
/// ```
@internal
pub fn claim_digest(value: String) -> Result(ClaimDigest, Error) {
  case string.byte_size(value) == 64 && ascii_in(value, "0123456789abcdef") {
    True -> Ok(ClaimDigest(value))
    False -> Error(Invalid("claim digest must be 64 lowercase hex bytes"))
  }
}

/// Reads the unique owner's current identity without changing credentials.
///
/// ## Examples
///
/// ```gleam
/// // access.owner(catalogue)
/// ```
@internal
pub fn owner(store: Catalogue) -> Result(Principal, Error) {
  use rows <- result.try(catalogue.query(store, sql.access_owner()))
  use row <- result.try(one(rows))
  principal(row.principal_id, row.display_name, row.kind)
}

/// Creates the first owner, or verifies the supplied credential of that owner.
/// Existing identity and display name remain unchanged on retry. A missing,
/// revoked, or unrelated credential is a conflict, never an implicit reset.
///
/// ## Examples
///
/// ```gleam
/// // access.bootstrap_owner(store, "owner-id", "Local owner", digest)
/// ```
@internal
pub fn bootstrap_owner(
  store: Catalogue,
  proposed_id: String,
  display_name: String,
  digest: Digest,
) -> Result(Principal, Error) {
  use proposed <- result.try(principal(proposed_id, display_name, "owner"))
  catalogue.atomic(store, fn() {
    case owner(store) {
      Error(Missing) -> insert_principal(store, proposed, digest)
      Error(error) -> Error(error)
      Ok(existing) -> verify_owner_credential(store, existing, digest)
    }
  })
}

fn verify_owner_credential(
  store: Catalogue,
  existing: Principal,
  digest: Digest,
) {
  case authenticate(store, digest) {
    Ok(found) if found.id == existing.id -> Ok(existing)
    Ok(_) | Error(Missing) -> Error(Conflict)
    Error(error) -> Error(error)
  }
}

/// Creates one non-owner and its initial credential atomically.
/// Reusing a principal ID or any historical digest is a conflict.
///
/// ## Examples
///
/// ```gleam
/// // access.create_member(store, "participant-id", "Reviewer", digest)
/// ```
@internal
pub fn create_member(
  store: Catalogue,
  id: String,
  display_name: String,
  digest: Digest,
) -> Result(Principal, Error) {
  use proposed <- result.try(principal(id, display_name, "member"))
  catalogue.atomic(store, fn() { insert_principal(store, proposed, digest) })
}

fn insert_principal(store: Catalogue, proposed: Principal, digest: Digest) {
  use Nil <- result.try(absent(get(store, proposed.id)))
  use Nil <- result.try(absent(credential(store, digest)))
  use Nil <- result.try(catalogue.statement(
    store,
    sql.insert_access_principal(
      proposed.id,
      proposed.display_name,
      kind(proposed.kind),
    ),
  ))
  use Nil <- result.try(catalogue.statement(
    store,
    sql.insert_access_credential(digest.value, proposed.id),
  ))
  Ok(proposed)
}

/// Creates one member, its enrollment and one membership in one transaction.
///
/// Under `ClaimEnrollment` the member gets an open claim and no credential;
/// under `DigestEnrollment` it gets that credential and no claim. A duplicate
/// principal is a conflict, never a retry that issues another claim. The
/// caller's stable principal ID permits explicit recovery by member rotation
/// if the successful invitation reply was lost.
///
/// ## Examples
///
/// ```gleam
/// // access.invite_member(store, "alice", "Alice", enrollment, session_id, Operator)
/// ```
@internal
pub fn invite_member(
  store: Catalogue,
  id: String,
  name: String,
  enrollment: Enrollment,
  session_id: String,
  role: Role,
) -> Result(Principal, Error) {
  use proposed <- result.try(principal(id, name, "member"))
  catalogue.atomic(store, fn() {
    use _ <- result.try(catalogue.get(store, session_id))
    use Nil <- result.try(absent(get(store, proposed.id)))
    use Nil <- result.try(catalogue.statement(
      store,
      sql.insert_access_principal(
        proposed.id,
        proposed.display_name,
        kind(proposed.kind),
      ),
    ))
    use Nil <- result.try(enroll(store, id, enrollment))
    use Nil <- result.try(grant_changed(store, id, session_id, role))
    Ok(proposed)
  })
}

/// Replaces a member's enrollment, preserving every tombstone.
///
/// The open claim, if any, is voided and every active credential revoked
/// before the new claim or credential is inserted, so a claim delivered
/// earlier stops redeeming and a credential bound earlier stops
/// authenticating in the same commit. Owner credentials are excluded because
/// the daemon's owner file has a separate lifetime. A failed insertion rolls
/// back the voiding and the revocations.
///
/// ## Examples
///
/// ```gleam
/// // access.rotate_member(store, "alice", enrollment)
/// ```
@internal
pub fn rotate_member(
  store: Catalogue,
  id: String,
  enrollment: Enrollment,
) -> Result(Principal, Error) {
  catalogue.atomic(store, fn() {
    use found <- result.try(member(store, id))
    use Nil <- result.try(withdraw(store, id))
    use Nil <- result.try(enroll(store, id, enrollment))
    Ok(found)
  })
}

/// Revokes a member's active credentials and voids its open claim, without
/// deleting its identity or grants.
///
/// Repeating this operation is idempotent. Explicit rotation can recover the
/// stable member later; no revoked bearer is ever reactivated and no voided
/// claim is ever redeemed.
///
/// ## Examples
///
/// ```gleam
/// // access.revoke_member(store, "alice")
/// ```
@internal
pub fn revoke_member(store: Catalogue, id: String) -> Result(Principal, Error) {
  catalogue.atomic(store, fn() {
    use found <- result.try(member(store, id))
    use Nil <- result.try(withdraw(store, id))
    Ok(found)
  })
}

// Removes everything a member could authenticate with, or come to, in the
// caller's transaction: the open claim is voided and every active credential
// revoked. Both rows stay as tombstones.
fn withdraw(store: Catalogue, id: String) -> Result(Nil, Error) {
  use Nil <- result.try(catalogue.statement(store, sql.void_member_claims(id)))
  catalogue.statement(store, sql.revoke_member_credentials(id))
}

// Inserts the one thing an enrollment grants. A claim digest already present,
// or a credential digest already present in any state, is a conflict: rows are
// never deleted, so presence means an earlier claim or a tombstone.
fn enroll(
  store: Catalogue,
  id: String,
  enrollment: Enrollment,
) -> Result(Nil, Error) {
  case enrollment {
    ClaimEnrollment(claim:, expires_at_ms:) -> {
      use Nil <- result.try(absent(claim_row(store, claim.value)))
      catalogue.statement(
        store,
        sql.insert_access_claim(claim.value, id, expires_at_ms),
      )
    }
    DigestEnrollment(credential: digest) -> {
      use Nil <- result.try(absent(credential(store, digest)))
      catalogue.statement(store, sql.insert_access_credential(digest.value, id))
    }
  }
}

/// Answers whether a claim row with this digest exists and is not void.
///
/// This is the `/v2/claim` upgrade's filter, not its decision: an expired or
/// already claimed row passes, and `claim` then refuses it with the specific
/// reason. `Missing` covers both an unknown and a voided claim.
///
/// ## Examples
///
/// ```gleam
/// // access.claim_known(store, claim)
/// ```
@internal
pub fn claim_known(store: Catalogue, claim: ClaimDigest) -> Result(Nil, Error) {
  use row <- result.try(claim_row(store, claim.value))
  case row.state {
    OpenClaim | ClaimedBy(_) -> Ok(Nil)
    VoidClaim -> Error(Missing)
  }
}

/// Binds a credential digest to an open claim, once, in one transaction.
///
/// The checks run in this order, and every refusal precedes every write: the
/// claim must exist and not be void; an already claimed row answers the same
/// success again only for the credential it bound, and only while that
/// credential is active; an open claim must not have expired at `now_ms`; the
/// presented digest must not be the claim's own digest, which would turn the
/// claim string, already sitting in a chat log, into a durable bearer; it must
/// be absent from `access_credentials` in every state; and the member must
/// hold no active credential. Then the credential is inserted and the claim
/// marked claimed at `now_ms`, a wall-clock instant in Unix milliseconds.
///
/// `equal` compares two digests. The daemon passes a constant-time
/// comparison; this package has no cryptographic dependency of its own.
///
/// ## Examples
///
/// ```gleam
/// // access.claim(store, claim, credential, now_ms, constant_time_equal)
/// ```
@internal
pub fn claim(
  store: Catalogue,
  claim: ClaimDigest,
  presented: Digest,
  now_ms: Int,
  equal: fn(String, String) -> Bool,
) -> Result(Claimed, ClaimRefusal) {
  let outcome =
    catalogue.atomic(store, fn() {
      // A refusal commits an empty transaction, since every refusal precedes
      // every write. A store failure rolls back whatever had been written.
      case redeem(store, claim, presented, now_ms, equal) {
        Ok(claimed) -> Ok(Ok(claimed))
        Error(ClaimStore(error)) -> Error(error)
        Error(UnknownClaim) -> Ok(Error(UnknownClaim))
        Error(ExpiredClaim) -> Ok(Error(ExpiredClaim))
        Error(ConflictingClaim) -> Ok(Error(ConflictingClaim))
      }
    })
  case outcome {
    Ok(answer) -> answer
    Error(error) -> Error(ClaimStore(error))
  }
}

fn redeem(
  store: Catalogue,
  claim: ClaimDigest,
  presented: Digest,
  now_ms: Int,
  equal: fn(String, String) -> Bool,
) -> Result(Claimed, ClaimRefusal) {
  use row <- result.try(case claim_row(store, claim.value) {
    Ok(row) -> Ok(row)
    Error(Missing) -> Error(UnknownClaim)
    Error(error) -> Error(ClaimStore(error))
  })
  case row.state {
    VoidClaim -> Error(UnknownClaim)

    // A lost reply is recovered by presenting the same claim and digest
    // again. The credential bound before is the only one that repeats the
    // success, and only while it still authenticates.
    ClaimedBy(bound) -> {
      use found <- result.try(stored(credential(store, bound)))
      case found.state, equal(bound.value, presented.value) {
        Revoked, _ -> Error(UnknownClaim)
        Active, True -> claimed(store, row.principal_id)
        Active, False -> Error(ConflictingClaim)
      }
    }

    OpenClaim -> bind(store, row, presented, now_ms, equal)
  }
}

fn bind(
  store: Catalogue,
  row: ClaimRow,
  presented: Digest,
  now_ms: Int,
  equal: fn(String, String) -> Bool,
) -> Result(Claimed, ClaimRefusal) {
  use <- bool.guard(
    when: now_ms >= row.expires_at_ms,
    return: Error(ExpiredClaim),
  )
  use <- bool.guard(
    when: equal(presented.value, row.claim.value),
    return: Error(ConflictingClaim),
  )
  use Nil <- result.try(
    absent(credential(store, presented)) |> result.map_error(refusal),
  )
  use Nil <- result.try(
    no_active_credential(store, row.principal_id) |> result.map_error(refusal),
  )

  // The credential row first: the claim's `credential_digest` references it.
  use Nil <- result.try(
    stored(catalogue.statement(
      store,
      sql.insert_access_credential(presented.value, row.principal_id),
    )),
  )
  use Nil <- result.try(
    stored(catalogue.statement(
      store,
      sql.bind_access_claim(
        Some(presented.value),
        Some(now_ms),
        row.claim.value,
      ),
    )),
  )
  claimed(store, row.principal_id)
}

fn claimed(store: Catalogue, id: String) -> Result(Claimed, ClaimRefusal) {
  use found <- result.try(stored(member(store, id)))
  use rows <- result.try(
    stored(catalogue.query(store, sql.claim_memberships(id))),
  )
  use memberships <- result.try(
    list.try_map(rows, fn(row) {
      use role <- result.map(role_from(row.role))
      Membership(row.session_id, role)
    })
    |> stored,
  )
  Ok(Claimed(found, memberships))
}

// A conflict from a presence check is the claim's conflict; anything else is
// the store's.
fn refusal(error: Error) -> ClaimRefusal {
  case error {
    Conflict -> ConflictingClaim
    Missing | catalogue.Unsupported | Invalid(_) | catalogue.Database(_) ->
      ClaimStore(error)
  }
}

fn stored(result: Result(a, Error)) -> Result(a, ClaimRefusal) {
  result.map_error(result, ClaimStore)
}

fn no_active_credential(store: Catalogue, id: String) -> Result(Nil, Error) {
  use rows <- result.try(catalogue.query(
    store,
    sql.active_member_credentials(id),
  ))
  case rows {
    [] -> Ok(Nil)
    [_, ..] -> Error(Conflict)
  }
}

// Decodes a claim row totally. The schema's CHECKs make a claimed row carry
// both its credential and its instant; a row that does not is corrupt, never
// an open claim.
fn claim_row(store: Catalogue, value: String) -> Result(ClaimRow, Error) {
  use rows <- result.try(catalogue.query(store, sql.access_claim(value)))
  use row <- result.try(one(rows))
  use claim <- result.try(claim_digest(row.digest))
  use Nil <- result.try(valid_id(row.principal_id))
  use state <- result.try(
    case row.state, row.credential_digest, row.claimed_at_ms {
      "open", None, None -> Ok(OpenClaim)
      "void", None, None -> Ok(VoidClaim)
      "claimed", Some(bound), Some(_) ->
        credential_digest(bound) |> result.map(ClaimedBy)
      _, _, _ -> Error(Invalid("invalid persisted claim state"))
    },
  )
  Ok(ClaimRow(claim, row.principal_id, row.expires_at_ms, state))
}

fn member(store: Catalogue, id: String) {
  use found <- result.try(get(store, id))
  case found.kind {
    MemberPrincipal -> Ok(found)
    OwnerPrincipal -> Error(Conflict)
  }
}

/// Resolves an active credential to the principal's current durable identity.
/// Invalid persisted values fail closed instead of receiving a default role.
///
/// ## Examples
///
/// ```gleam
/// // access.authenticate(store, digest)
/// ```
@internal
pub fn authenticate(
  store: Catalogue,
  digest: Digest,
) -> Result(Principal, Error) {
  use found <- result.try(credential(store, digest))
  case found.state {
    Active -> get(store, found.principal_id)
    Revoked -> Error(Missing)
  }
}

/// Reads a principal by its bounded stable ID.
///
/// ## Examples
///
/// ```gleam
/// // access.get(store, "participant-id")
/// ```
@internal
pub fn get(store: Catalogue, id: String) -> Result(Principal, Error) {
  use Nil <- result.try(valid_id(id))
  use rows <- result.try(catalogue.query(store, sql.access_principal(id)))
  use row <- result.try(one(rows))
  principal(row.principal_id, row.display_name, row.kind)
}

/// Changes only the current display name, preserving stable identity.
///
/// ## Examples
///
/// ```gleam
/// // access.rename(store, "participant-id", "New name")
/// ```
@internal
pub fn rename(
  store: Catalogue,
  id: String,
  display_name: String,
) -> Result(Principal, Error) {
  use Nil <- result.try(valid_name(display_name))
  catalogue.atomic(store, fn() {
    use found <- result.try(get(store, id))
    use Nil <- result.try(catalogue.statement(
      store,
      sql.rename_access_principal(display_name, id),
    ))
    Ok(Principal(..found, display_name:))
  })
}

/// Revokes a credential without deleting its anti-reuse tombstone.
/// Repeating revocation is idempotent; an unknown digest remains missing.
///
/// ## Examples
///
/// ```gleam
/// // access.revoke_credential(store, digest)
/// ```
@internal
pub fn revoke_credential(
  store: Catalogue,
  digest: Digest,
) -> Result(Nil, Error) {
  catalogue.atomic(store, fn() {
    use _found <- result.try(credential(store, digest))
    catalogue.statement(store, sql.revoke_access_credential(digest.value))
  })
}

/// Replaces an active credential in one transaction, preserving its principal.
/// A failed replacement leaves the old credential active.
///
/// ## Examples
///
/// ```gleam
/// // access.rotate_credential(store, old_digest, new_digest)
/// ```
@internal
pub fn rotate_credential(
  store: Catalogue,
  old: Digest,
  replacement: Digest,
) -> Result(Principal, Error) {
  catalogue.atomic(store, fn() {
    use found <- result.try(authenticate(store, old))
    use Nil <- result.try(absent(credential(store, replacement)))
    use Nil <- result.try(catalogue.statement(
      store,
      sql.revoke_access_credential(old.value),
    ))
    use Nil <- result.try(catalogue.statement(
      store,
      sql.insert_access_credential(replacement.value, found.id),
    ))
    Ok(found)
  })
}

/// Grants or replaces one member's role for an existing session.
/// An owner has no membership row: its global authority is not a grantable role.
///
/// ## Examples
///
/// ```gleam
/// // access.grant(store, participant_id, session_id, access.Observer)
/// ```
@internal
pub fn grant(
  store: Catalogue,
  principal_id: String,
  session_id: String,
  role: Role,
) -> Result(Nil, Error) {
  catalogue.atomic(store, fn() {
    use found <- result.try(get(store, principal_id))
    use _session <- result.try(catalogue.get(store, session_id))
    case found.kind {
      OwnerPrincipal -> Error(Conflict)
      MemberPrincipal -> grant_changed(store, principal_id, session_id, role)
    }
  })
}

// Membership changes invalidate continuation pages in the same transaction.
// Identical retries preserve the revision and do not force listing to restart.
fn grant_changed(
  store: Catalogue,
  principal_id: String,
  session_id: String,
  role: Role,
) {
  case membership(store, principal_id, session_id) {
    Ok(current) if current == role -> Ok(Nil)
    Ok(_) | Error(Missing) -> {
      use Nil <- result.try(catalogue.statement(
        store,
        sql.grant_access_membership(principal_id, session_id, role_name(role)),
      ))
      catalogue.statement(store, sql.increment_catalogue_revision())
    }
    Error(error) -> Error(error)
  }
}

/// Revokes one session membership without touching any other session.
///
/// ## Examples
///
/// ```gleam
/// // access.revoke_membership(store, participant_id, session_id)
/// ```
@internal
pub fn revoke_membership(
  store: Catalogue,
  principal_id: String,
  session_id: String,
) -> Result(Nil, Error) {
  catalogue.atomic(store, fn() {
    use _principal <- result.try(get(store, principal_id))
    use _session <- result.try(catalogue.get(store, session_id))
    case membership(store, principal_id, session_id) {
      Error(Missing) -> Ok(Nil)
      Error(error) -> Error(error)
      Ok(_) -> {
        use Nil <- result.try(catalogue.statement(
          store,
          sql.revoke_access_membership(principal_id, session_id),
        ))
        catalogue.statement(store, sql.increment_catalogue_revision())
      }
    }
  })
}

/// Resolves current authority for one existing session by indexed lookups.
/// A role in another session grants nothing here, and missing is not observer.
///
/// The three lookups read one deferred snapshot, like every other compound read
/// in the catalogue. Serializing the daemon's metadata calls under the lifetime
/// lock already keeps a membership change from landing between them, but the
/// read that answers "may this principal act on this session" should not depend
/// on a lock held in another module to see one state of the world.
///
/// ## Examples
///
/// ```gleam
/// // access.authorization(store, principal_id, session_id)
/// ```
@internal
pub fn authorization(
  store: Catalogue,
  principal_id: String,
  session_id: String,
) -> Result(Authority, Error) {
  catalogue.coherent(store, fn() {
    use found <- result.try(get(store, principal_id))
    use _session <- result.try(catalogue.get(store, session_id))
    case found.kind {
      OwnerPrincipal -> Ok(Owner)
      MemberPrincipal ->
        membership(store, principal_id, session_id) |> result.map(Participant)
    }
  })
}

fn membership(store: Catalogue, principal_id: String, session_id: String) {
  use rows <- result.try(catalogue.query(
    store,
    sql.access_membership(principal_id, session_id),
  ))
  use row <- result.try(one(rows))
  role_from(row.role)
}

fn role_from(text: String) -> Result(Role, Error) {
  case text {
    "operator" -> Ok(Operator)
    "observer" -> Ok(Observer)
    _ -> Error(Invalid("unknown persisted membership role"))
  }
}

fn credential(store: Catalogue, digest: Digest) {
  use rows <- result.try(catalogue.query(
    store,
    sql.access_credential(digest.value),
  ))
  use row <- result.try(one(rows))
  use _digest <- result.try(credential_digest(row.digest))
  use Nil <- result.try(valid_id(row.principal_id))
  case row.state {
    "active" -> Ok(Credential(row.principal_id, Active))
    "revoked" -> Ok(Credential(row.principal_id, Revoked))
    _ -> Error(Invalid("unknown persisted credential state"))
  }
}

fn principal(id: String, display_name: String, kind: String) {
  use Nil <- result.try(valid_id(id))
  use Nil <- result.try(valid_name(display_name))
  case kind {
    "owner" -> Ok(Principal(id, display_name, OwnerPrincipal))
    "member" -> Ok(Principal(id, display_name, MemberPrincipal))
    _ -> Error(Invalid("unknown persisted principal kind"))
  }
}

fn valid_id(id: String) {
  case
    string.byte_size(id) > 0
    && string.byte_size(id) <= 128
    && ascii_in(
      id,
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.",
    )
  {
    True -> Ok(Nil)
    False -> Error(Invalid("principal ID must be 1-128 ASCII identifier bytes"))
  }
}

fn valid_name(name: String) {
  case
    string.trim(name) != ""
    && string.byte_size(name) <= 256
    && list.all(string.to_utf_codepoints(name), fn(point) {
      let value = string.utf_codepoint_to_int(point)
      value >= 32 && value != 127 && !{ value >= 128 && value <= 159 }
    })
  {
    True -> Ok(Nil)
    False ->
      Error(Invalid(
        "display name must be nonblank, at most 256 bytes, and contain no controls",
      ))
  }
}

fn ascii_in(value: String, allowed: String) {
  list.all(string.to_graphemes(value), fn(char) {
    string.contains(allowed, char)
  })
}

fn kind(kind: PrincipalKind) {
  case kind {
    OwnerPrincipal -> "owner"
    MemberPrincipal -> "member"
  }
}

fn role_name(role: Role) {
  case role {
    Operator -> "operator"
    Observer -> "observer"
  }
}

// Unique-key lookups have a bounded result. Multiple rows indicate corrupt
// persisted identity, never permission to choose the first apparent owner.
fn one(rows: List(a)) -> Result(a, Error) {
  case rows {
    [row] -> Ok(row)
    [] -> Error(Missing)
    [_, _, ..] -> Error(Invalid("expected one access record"))
  }
}

fn absent(found: Result(a, Error)) -> Result(Nil, Error) {
  case found {
    Error(Missing) -> Ok(Nil)
    Error(error) -> Error(error)
    Ok(_) -> Error(Conflict)
  }
}
