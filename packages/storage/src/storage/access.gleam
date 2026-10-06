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
//// Every credential row has a kind, `Bearer` or `Browser` (protocol-change/065).
//// A lookup names the kind it wants, so a digest that belongs to one kind is
//// absent to the other. The queries behind 053's rule 3, "a member holds at
//// most one active credential", count `Bearer` rows only: that rule is what
//// lets a listing show one credential per principal, and a login is counted
//// beside it, never in its place.
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
////
//// ## Flow
////
//// `bootstrap_owner` → `invite_member` → `claim` → `redeem` → `bind` → `authenticate` → `authorization`
////
//// 1. `bootstrap_owner` creates the first owner or verifies its credential
////    with `verify_owner_credential`; `create_member` adds a member with a
////    credential directly.
//// 2. `invite_member` (and `rotate_member`) enrolls a member with an open
////    claim and no credential, through `enroll`.
//// 3. `claim` runs `redeem` in one transaction: a refusal writes nothing.
//// 4. `redeem` reads the claim row; an open claim goes to `bind`, a spent
////    one answers an exact replay of the bound credential, a void one is
////    unknown.
//// 5. `bind` checks expiry and digest hygiene, inserts the credential, and
////    marks the claim claimed.
//// 6. `authenticate` maps an active credential digest to its principal, and
////    `authorization` resolves that principal's `Authority` over a session.
//// 7. `revoke_member` and `revoke_credential` close the loop, leaving
////    tombstones so an old digest cannot be reactivated.

import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import storage/catalogue.{type Catalogue, type Error, Conflict, Invalid, Missing}
import storage/sql

/// A validated lowercase hexadecimal SHA-256 credential digest, and the kind of
/// credential it names.
///
/// The kind travels with the digest so that every check that takes a digest
/// looks it up as the kind its constructor named. `credential_digest`, which
/// every wire path uses, makes a `Bearer` digest, and only `browser_digest`
/// makes a `Browser` one, so a string a connection presents as a bearer can
/// never be looked up as a login's row, whatever it hashes to.
pub opaque type Digest {
  Digest(value: String, kind: CredentialKind)
}

/// A validated lowercase hexadecimal SHA-256 digest of a claim token.
///
/// It is a separate type from `Digest` so that no caller can hand a claim to
/// `authenticate`: the two digests name different tables, and only a
/// credential digest ever authorizes a connection.
pub opaque type ClaimDigest {
  ClaimDigest(value: String)
}

/// Which presenter a credential row belongs to.
///
/// A credential's digest is the key of its row, and the digest of a `Browser`
/// row is derived from a value that is not secret (protocol-change/065). So
/// the kind is part of every lookup: a digest authenticates only as the kind
/// it was made as (`credential_digest` or `browser_digest`), and a string a
/// connection presents as a bearer can never reach a `Browser` row, whatever
/// its digest.
pub type CredentialKind {
  /// A token the holder presents as `Authorization: Bearer`, and the only kind
  /// 053's one-credential-per-principal rules count.
  Bearer

  /// A browser login's row, which only a page grant minted from that login
  /// may name.
  Browser
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

  /// The invitee's chosen display name is blank after trimming, longer than
  /// 256 bytes, or holds a control character. The claim binds nothing and
  /// stays open, so the invitee can try again with another name.
  InvalidClaimName

  /// The catalogue could not answer or refused the write.
  ClaimStore(error: Error)
}

/// The most memberships a claim reply lists; the member's own session listing
/// returns the rest. The claim-memberships query carries the same bound.
pub const claim_membership_limit = 16

/// How many rows one listing page holds. A page query fetches one more row
/// than this, and the extra row only says that another page exists.
pub const listing_limit = 100

/// What a principal can authenticate with, or come to, as the owner's listing
/// reports it. A claim token or a bearer is never part of it: a claim appears
/// only as its remaining lifetime, and a credential only as its fingerprint.
pub type CredentialSummary {
  /// One active credential. `claimed_at_ms` is the wall-clock instant a claim
  /// bound it, and is absent for the owner's credential and for one enrolled
  /// by digest.
  CredentialActive(fingerprint: String, claimed_at_ms: Option(Int))

  /// An open claim that has not expired, with the time it has left.
  CredentialClaimOpen(expires_in_ms: Int)

  /// A member whose only claim expired unredeemed and who holds no active
  /// credential. Rotation issues a new claim.
  CredentialClaimExpired

  /// No active credential and no open claim: revoked, or never enrolled.
  CredentialNone
}

/// One principal and the credential state the owner's listing shows for it.
pub type Listing {
  Listing(
    principal: Principal,
    /// The bearer's state, or the claim's: what 053's listing always showed.
    /// A login is never reported here.
    credential: CredentialSummary,
    /// How many browser logins the principal holds that are active and have
    /// not reached their expiry (protocol-change/065).
    logins: Int,
  )
}

/// One browser login as its principal's sign-in list shows it. The fingerprint
/// identifies a login and authenticates nothing.
pub type Signin {
  Signin(
    /// The first sixteen hexadecimal digits of the login row's digest.
    fingerprint: String,
    /// When the login was minted, in Unix milliseconds; zero for a row whose
    /// minting time was not recorded.
    issued_at_ms: Int,
    /// When the login last minted a home page, if it has. Written at most once
    /// an hour (`resumed`), so it says when a login was last used and not how
    /// often.
    last_resumed_ms: Option(Int),
    /// When the login ends, as its token's expiry says, if it was recorded. A
    /// login that inherited an earlier login's expiry ends then, and not thirty
    /// days after it was minted.
    expires_at_ms: Option(Int),
    /// The fingerprint of the login whose device link made this one, so a
    /// family of logins is traceable from any member.
    issued_by: Option(String),
  )
}

/// One page of `Signin` rows in fingerprint order, at most `listing_limit`.
pub type SigninPage {
  SigninPage(entries: List(Signin), remainder: Remainder)
}

/// What `resumed` did.
pub type Stamp {
  /// The row's `last_resumed_ms` was older than `resume_stamp_window_ms`, or
  /// absent, and is now the instant given.
  Stamped

  /// The row's `last_resumed_ms` is recent enough that nothing was written.
  Unchanged
}

/// How recent a login's `last_resumed_ms` may be before a resume leaves it
/// alone: one hour, so a visit costs one registry read and rarely a write.
pub const resume_stamp_window_ms = 3_600_000

/// Whether a listing page is the last one.
pub type Remainder {
  /// No row follows the page.
  Exhausted

  /// At least one more row follows, so the caller asks again after the last.
  Remaining
}

/// One page of `Listing` rows in principal-ID order, at most `listing_limit`.
pub type ListingPage {
  ListingPage(entries: List(Listing), remainder: Remainder)
}

/// One session membership with the session's current display name.
pub type MembershipEntry {
  MembershipEntry(session_id: String, name: String, role: Role)
}

/// One page of `MembershipEntry` rows in session-ID order, at most
/// `listing_limit`.
pub type MembershipPage {
  MembershipPage(entries: List(MembershipEntry), remainder: Remainder)
}

/// One member of a session: the principal's recovery ID, its display name and
/// the role it holds in that session.
pub type SessionMember {
  SessionMember(principal_id: String, name: String, role: Role)
}

/// One page of `SessionMember` rows in principal-ID order, at most
/// `listing_limit`.
pub type SessionMemberPage {
  SessionMemberPage(entries: List(SessionMember), remainder: Remainder)
}

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
    True -> Ok(Digest(value, Bearer))
    False -> Error(Invalid("credential digest must be 64 lowercase hex bytes"))
  }
}

/// Validates the digest of a browser login's identifier. It is
/// `credential_digest` for the other kind: the same 64 lowercase hex bytes, and
/// a digest that every lookup then asks of `Browser` rows only. Only the
/// daemon's login code makes one, from the identifier of a token whose chain
/// has verified; no wire path does.
///
/// ## Examples
///
/// ```gleam
/// // access.browser_digest(login.row_digest(identifier))
/// ```
@internal
pub fn browser_digest(value: String) -> Result(Digest, Error) {
  case string.byte_size(value) == 64 && ascii_in(value, "0123456789abcdef") {
    True -> Ok(Digest(value, Browser))
    False -> Error(Invalid("credential digest must be 64 lowercase hex bytes"))
  }
}

/// The first 16 hexadecimal characters of a credential digest, which the owner
/// and the invitee compare out of band to confirm who bound a claim. It is not
/// secret: it is part of a digest of the credential, not the credential.
///
/// ## Examples
///
/// ```gleam
/// // access.fingerprint(digest) -> "9c1e0f2ab3d4e5f6"
/// ```
@internal
pub fn fingerprint(digest: Digest) -> String {
  string.slice(digest.value, 0, 16)
}

/// Which presenter a digest names: a bearer token, or a browser login.
///
/// A durable record that says which credential made a decision keeps this
/// beside the fingerprint, so a reader can tell a login the owner can end from
/// the terminal's own credential without looking either up.
///
/// ## Examples
///
/// ```gleam
/// // access.credential_kind(digest) == access.Browser
/// ```
@internal
pub fn credential_kind(digest: Digest) -> CredentialKind {
  digest.kind
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
  use proposed <- result.try(new_principal(proposed_id, display_name, "owner"))
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
  use proposed <- result.try(new_principal(id, display_name, "member"))
  catalogue.atomic(store, fn() { insert_principal(store, proposed, digest) })
}

fn insert_principal(store: Catalogue, proposed: Principal, digest: Digest) {
  use Nil <- result.try(bearer_only(digest))
  use Nil <- result.try(absent(get(store, proposed.id)))
  use Nil <- result.try(unused(store, digest))
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
    sql.insert_access_credential(digest.value, proposed.id, kind_name(Bearer)),
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
  use proposed <- result.try(new_principal(id, name, "member"))
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
      use Nil <- result.try(bearer_only(digest))
      use Nil <- result.try(unused(store, digest))
      catalogue.statement(
        store,
        sql.insert_access_credential(digest.value, id, kind_name(Bearer)),
      )
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
/// `name` is the display name the invitee chose, or `None` to keep the one
/// the inviter gave. A chosen name is trimmed, checked by the rule every
/// display name meets, and written in the same transaction as the credential,
/// so a refused name (`InvalidClaimName`) binds nothing and leaves the claim
/// open. Only the redemption that binds applies it: the replay of a lost reply
/// answers the principal as it stands and never renames, whatever name it
/// carries. Events already admitted keep the name they were admitted under.
///
/// The row is written as the kind `presented` was made as, and an exact replay is
/// recognised only for that kind: a claim bound as one kind answers a replay of
/// the other as a conflict. The `/v2/claim` route is a bearer path and presents a
/// `Bearer` digest. A claim binds only a principal that holds no active
/// credential of either kind (`no_active_credential`), so a login is counted
/// beside a bearer and never ignored in its place.
///
/// `equal` compares two digests. The daemon passes a constant-time
/// comparison; this package has no cryptographic dependency of its own.
///
/// ## Examples
///
/// ```gleam
/// // access.claim(store, claim, credential, Some("Alex"), now_ms, constant_time_equal)
/// ```
@internal
pub fn claim(
  store: Catalogue,
  claim: ClaimDigest,
  presented: Digest,
  name: Option(String),
  now_ms: Int,
  equal: fn(String, String) -> Bool,
) -> Result(Claimed, ClaimRefusal) {
  case presented.kind {
    Bearer -> claim_as(store, claim, AsBearer(presented), name, now_ms, equal)
    Browser ->
      Error(ClaimStore(Invalid("a bearer claim presents a bearer digest")))
  }
}

/// `claim` for the browser claim (protocol-change/065, PR 9): the credential
/// the claim binds is a login, written as `issue_login` writes one, ending at
/// `expires_at_ms`. A login row with no expiry would be listed as live forever,
/// so a claim bound as a login has no way to omit it. Every other rule is
/// `claim`'s: a refused name binds nothing and leaves the claim open, and an
/// exact replay of the bound login answers the principal as it stands.
///
/// ## Examples
///
/// ```gleam
/// // access.claim_login(store, claim, login, None, now_ms, now_ms + thirty_days, equal)
/// ```
@internal
pub fn claim_login(
  store: Catalogue,
  claim: ClaimDigest,
  presented: Digest,
  name: Option(String),
  now_ms: Int,
  expires_at_ms: Int,
  equal: fn(String, String) -> Bool,
) -> Result(Claimed, ClaimRefusal) {
  case presented.kind {
    Browser ->
      claim_as(
        store,
        claim,
        AsLogin(presented, expires_at_ms),
        name,
        now_ms,
        equal,
      )
    Bearer ->
      Error(ClaimStore(Invalid("a browser claim presents a browser digest")))
  }
}

// The credential a claim binds and, for a login, when it ends. Making the
// expiry part of the login's variant is what keeps a claim from writing a login
// row that never expires.
type Presented {
  AsBearer(Digest)
  AsLogin(Digest, expires_at_ms: Int)
}

fn presented_digest(presented: Presented) -> Digest {
  case presented {
    AsBearer(digest) | AsLogin(digest, _) -> digest
  }
}

fn claim_as(
  store: Catalogue,
  claim: ClaimDigest,
  presented: Presented,
  name: Option(String),
  now_ms: Int,
  equal: fn(String, String) -> Bool,
) -> Result(Claimed, ClaimRefusal) {
  let outcome =
    catalogue.atomic(store, fn() {
      // A refusal commits an empty transaction, since every refusal precedes
      // every write. A store failure rolls back whatever had been written.
      case redeem(store, claim, presented, name, now_ms, equal) {
        Ok(claimed) -> Ok(Ok(claimed))
        Error(ClaimStore(error)) -> Error(error)
        Error(InvalidClaimName) -> Ok(Error(InvalidClaimName))
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
  presented: Presented,
  name: Option(String),
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
      let wanted = presented_digest(presented)
      use found <- result.try(case credential(store, bound, wanted.kind) {
        // The row exists, since the claim references it, so only a bound
        // credential of the other kind is absent from this lookup.
        Error(Missing) -> Error(ConflictingClaim)
        other -> stored(other)
      })
      case found.state, equal(bound.value, wanted.value) {
        Revoked, _ -> Error(UnknownClaim)
        Active, True -> claimed(store, row.principal_id)
        Active, False -> Error(ConflictingClaim)
      }
    }

    OpenClaim -> bind(store, row, presented, name, now_ms, equal)
  }
}

fn bind(
  store: Catalogue,
  row: ClaimRow,
  credential: Presented,
  name: Option(String),
  now_ms: Int,
  equal: fn(String, String) -> Bool,
) -> Result(Claimed, ClaimRefusal) {
  let presented = presented_digest(credential)
  use <- bool.guard(
    when: now_ms >= row.expires_at_ms,
    return: Error(ExpiredClaim),
  )
  use <- bool.guard(
    when: equal(presented.value, row.claim.value),
    return: Error(ConflictingClaim),
  )
  use Nil <- result.try(unused(store, presented) |> result.map_error(refusal))
  use Nil <- result.try(
    no_active_credential(store, row.principal_id) |> result.map_error(refusal),
  )

  // The name is judged before the first write, so a refused one leaves the
  // claim open and the principal as the inviter named it.
  use chosen <- result.try(case name {
    None -> Ok(None)
    Some(given) -> {
      let trimmed = string.trim(given)
      new_name(trimmed)
      |> result.replace_error(InvalidClaimName)
      |> result.replace(Some(trimmed))
    }
  })

  // The credential row first: the claim's `credential_digest` references it.
  // A login's row records when it began, as `issue_login` writes it.
  use Nil <- result.try(
    stored(
      catalogue.statement(store, case credential {
        AsBearer(_) ->
          sql.insert_access_credential(
            presented.value,
            row.principal_id,
            kind_name(Bearer),
          )
        AsLogin(_, expires_at_ms) ->
          sql.insert_access_login(
            presented.value,
            row.principal_id,
            Some(now_ms),
            Some(expires_at_ms),
          )
      }),
    ),
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
  use Nil <- result.try(case chosen {
    None -> Ok(Nil)
    Some(display_name) ->
      stored(catalogue.statement(
        store,
        sql.rename_access_principal(display_name, row.principal_id),
      ))
  })
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

// A claim binds only a member who holds no active credential, whatever kind:
// 053's rule 3 is that a member has an open claim and no credential, or no open
// claim, and a login is a credential. Counting bearers alone would let a member
// whose only credential is a login bind a second one.
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

/// Lists principals after `after`, in principal-ID order, with the credential
/// state of each, in one coherent read.
///
/// `after` is empty for the first page, else a principal ID. `now_ms` is the
/// wall-clock instant an open claim's expiry is judged against, the clock the
/// claim was stamped with. Rule 3 of protocol-change/053 (a member has one
/// open claim and no active credential, or no open claim) is what lets each
/// principal show one credential state; if a row ever held both, the active
/// credential is the one shown.
///
/// ## Examples
///
/// ```gleam
/// // access.principals_page(store, "", now_ms)
/// ```
@internal
pub fn principals_page(
  store: Catalogue,
  after: String,
  now_ms: Int,
) -> Result(ListingPage, Error) {
  use Nil <- result.try(case after {
    "" -> Ok(Nil)
    id -> valid_id(id)
  })
  catalogue.coherent(store, fn() {
    use rows <- result.try(catalogue.query(store, sql.principal_listing(after)))
    use listed <- result.map(
      list.try_map(rows, fn(row) {
        use found <- result.try(principal(
          row.principal_id,
          row.display_name,
          row.kind,
        ))
        use summary <- result.try(credential_summary(store, found.id, now_ms))
        use logins <- result.map(login_count(store, found.id, now_ms))
        Listing(found, summary, logins)
      }),
    )
    let #(entries, remainder) = split_page(listed)
    ListingPage(entries, remainder)
  })
}

// A principal's credential is its active bearer. A login that a claim bound is
// the credential that claim made (the browser claim has no bearer), so it is
// listed here too, with the instant the claim was redeemed, and counted beside
// as one of the principal's logins. Any other login is only counted.
fn credential_summary(
  store: Catalogue,
  id: String,
  now_ms: Int,
) -> Result(CredentialSummary, Error) {
  use active <- result.try(catalogue.query(
    store,
    sql.principal_active_credential(id, Some(now_ms)),
  ))
  case active {
    [row, ..] -> {
      use digest <- result.map(credential_digest(row.digest))
      CredentialActive(fingerprint(digest), row.claimed_at_ms)
    }
    [] -> {
      use open <- result.map(catalogue.query(
        store,
        sql.principal_open_claim(id),
      ))
      case open {
        [] -> CredentialNone
        [row, ..] if row.expires_at_ms > now_ms ->
          CredentialClaimOpen(row.expires_at_ms - now_ms)
        [_, ..] -> CredentialClaimExpired
      }
    }
  }
}

/// Lists one principal's memberships after the session `after`, in
/// session-ID order, with each session's current display name.
///
/// An unknown principal is `Missing`. The owner holds no membership rows, so
/// its page is empty.
///
/// ## Examples
///
/// ```gleam
/// // access.memberships_page(store, "alice", "")
/// ```
@internal
pub fn memberships_page(
  store: Catalogue,
  id: String,
  after: String,
) -> Result(MembershipPage, Error) {
  use Nil <- result.try(valid_id(id))
  catalogue.coherent(store, fn() {
    use _found <- result.try(get(store, id))
    use rows <- result.try(catalogue.query(
      store,
      sql.principal_memberships(id, after),
    ))
    use listed <- result.map(
      list.try_map(rows, fn(row) {
        use role <- result.map(role_from(row.role))
        MembershipEntry(row.session_id, row.name, role)
      }),
    )
    let #(entries, remainder) = split_page(listed)
    MembershipPage(entries, remainder)
  })
}

/// Lists one session's members after the principal `after`, in principal-ID
/// order, with each member's display name and role in that session.
///
/// An unknown session is `Missing`. The owner holds no membership rows, so it
/// never appears. The query reads `access_memberships` by session, which its
/// primary key (principal, session) does not index: the table holds one row per
/// invitee and session, the call is the owner's alone and a page is bounded, so
/// the scan is accepted rather than adding an index and a catalogue version.
///
/// ## Examples
///
/// ```gleam
/// // access.session_members_page(store, session_id, "")
/// ```
@internal
pub fn session_members_page(
  store: Catalogue,
  session_id: String,
  after: String,
) -> Result(SessionMemberPage, Error) {
  use Nil <- result.try(case after {
    "" -> Ok(Nil)
    id -> valid_id(id)
  })
  catalogue.coherent(store, fn() {
    use _found <- result.try(catalogue.get(store, session_id))
    use rows <- result.try(catalogue.query(
      store,
      sql.session_members(session_id, after),
    ))
    use listed <- result.map(
      list.try_map(rows, fn(row) {
        use role <- result.try(role_from(row.role))
        use _ <- result.try(valid_id(row.principal_id))
        use _ <- result.map(stored_name(row.display_name))
        SessionMember(row.principal_id, row.display_name, role)
      }),
    )
    let #(entries, remainder) = split_page(listed)
    SessionMemberPage(entries, remainder)
  })
}

// A page query fetches `listing_limit + 1` rows; the extra one is dropped and
// reported only as "another page exists".
fn split_page(rows: List(a)) -> #(List(a), Remainder) {
  case list.drop(rows, listing_limit) {
    [] -> #(rows, Exhausted)
    [_, ..] -> #(list.take(rows, listing_limit), Remaining)
  }
}

/// Resolves an active credential to the principal's current durable identity.
/// Invalid persisted values fail closed instead of receiving a default role.
///
/// The lookup is of the kind the digest was made as, so no caller can omit it
/// and none can ask for the other: a digest that names a row of the other kind
/// is `Missing`, exactly as an unknown digest is.
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
  use found <- result.try(credential(store, digest, digest.kind))
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
  let display_name = string.trim(display_name)
  use Nil <- result.try(new_name(display_name))
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
    use _found <- result.try(held(store, digest))
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
    use Nil <- result.try(bearer_only(old))
    use Nil <- result.try(bearer_only(replacement))
    use found <- result.try(authenticate(store, old))
    use Nil <- result.try(unused(store, replacement))
    use Nil <- result.try(catalogue.statement(
      store,
      sql.revoke_access_credential(old.value),
    ))
    use Nil <- result.try(catalogue.statement(
      store,
      sql.insert_access_credential(
        replacement.value,
        found.id,
        kind_name(Bearer),
      ),
    ))
    Ok(found)
  })
}

/// Records a browser login: one `Browser` credential row for `principal_id`,
/// keyed by the digest of the login token's identifier, with the instant it was
/// minted and the instant its token expires. `issued_by`, when there is one, is
/// the fingerprint of the login whose device link made this one.
///
/// The digest must be a `browser_digest` and unused in either kind, and the
/// principal must exist; any of them wrong writes nothing. Whether the principal
/// may hold a login is the daemon's decision and not made here.
///
/// ## Examples
///
/// ```gleam
/// // access.issue_login(store, "alice", digest, now_ms, now_ms + thirty_days, None)
/// ```
@internal
pub fn issue_login(
  store: Catalogue,
  principal_id: String,
  digest: Digest,
  issued_at_ms: Int,
  expires_at_ms: Int,
  issued_by: Option(String),
) -> Result(Nil, Error) {
  use Nil <- result.try(case digest.kind {
    Browser -> Ok(Nil)
    Bearer -> Error(Invalid("a login row is a browser credential"))
  })
  use Nil <- result.try(case issued_by {
    None -> Ok(Nil)
    Some(parent) -> fingerprint_shape(parent)
  })
  catalogue.atomic(store, fn() {
    use _found <- result.try(get(store, principal_id))
    use Nil <- result.try(unused(store, digest))
    catalogue.statement(store, case issued_by {
      None ->
        sql.insert_access_login(
          digest.value,
          principal_id,
          Some(issued_at_ms),
          Some(expires_at_ms),
        )
      Some(parent) ->
        sql.insert_access_login_from(
          digest.value,
          principal_id,
          Some(issued_at_ms),
          Some(expires_at_ms),
          Some(parent),
        )
    })
  })
}

/// Lists a principal's active, unexpired browser logins after the fingerprint
/// `after`, in fingerprint order, at most `listing_limit`. `after` is empty for
/// the first page. `now_ms` is the wall-clock instant expiry is judged against.
/// An unknown principal is `Missing`.
///
/// ## Examples
///
/// ```gleam
/// // access.signins_page(store, "alice", "", now_ms)
/// ```
@internal
pub fn signins_page(
  store: Catalogue,
  principal_id: String,
  after: String,
  now_ms: Int,
) -> Result(SigninPage, Error) {
  use Nil <- result.try(valid_id(principal_id))
  use Nil <- result.try(case after {
    "" -> Ok(Nil)
    fingerprint -> fingerprint_shape(fingerprint)
  })
  catalogue.coherent(store, fn() {
    use _found <- result.try(get(store, principal_id))
    use rows <- result.try(catalogue.query(
      store,
      sql.principal_logins(principal_id, Some(now_ms), after),
    ))
    use listed <- result.map(
      list.try_map(rows, fn(row) {
        use digest <- result.map(browser_digest(row.digest))
        Signin(
          fingerprint: fingerprint(digest),
          issued_at_ms: option.unwrap(row.issued_at_ms, 0),
          last_resumed_ms: row.last_resumed_ms,
          expires_at_ms: row.expires_at_ms,
          issued_by: row.issued_by,
        )
      }),
    )
    let #(entries, remainder) = split_page(listed)
    SigninPage(entries, remainder)
  })
}

// Counts the principal's active browser logins whose expiry has not come.
fn login_count(
  store: Catalogue,
  principal_id: String,
  now_ms: Int,
) -> Result(Int, Error) {
  use rows <- result.try(catalogue.query(
    store,
    sql.principal_login_count(principal_id, Some(now_ms)),
  ))
  use row <- result.map(one(rows))
  row.count
}

/// Revokes one of a principal's own browser logins, named by its fingerprint,
/// and answers its digest so the caller can log its fingerprint and drop what
/// it remembers of it. Only a row of this principal and of kind `Browser` can
/// match, so a fingerprint of a bearer, or of another principal's login, is
/// `Missing`. Revoking a login that is already revoked is idempotent.
///
/// ## Examples
///
/// ```gleam
/// // access.revoke_login(store, "alice", "9c1e0f2ab3d4e5f6")
/// ```
@internal
pub fn revoke_login(
  store: Catalogue,
  principal_id: String,
  fingerprint: String,
) -> Result(Digest, Error) {
  use Nil <- result.try(valid_id(principal_id))
  use Nil <- result.try(fingerprint_shape(fingerprint))
  catalogue.atomic(store, fn() {
    use rows <- result.try(catalogue.query(
      store,
      sql.principal_login_by_fingerprint(principal_id, fingerprint),
    ))
    use row <- result.try(one(rows))
    use digest <- result.try(browser_digest(row.digest))
    use Nil <- result.map(catalogue.statement(
      store,
      sql.revoke_access_credential(digest.value),
    ))
    digest
  })
}

/// Revokes every active browser login of one principal ("sign out everywhere")
/// and answers how many were active. Bearers and claims are untouched.
///
/// ## Examples
///
/// ```gleam
/// // access.revoke_logins(store, "alice")
/// ```
@internal
pub fn revoke_logins(
  store: Catalogue,
  principal_id: String,
) -> Result(Int, Error) {
  use Nil <- result.try(valid_id(principal_id))
  catalogue.atomic(store, fn() {
    use _found <- result.try(get(store, principal_id))

    // Zero as the instant counts every active row, since no login's expiry is
    // before it.
    use held <- result.try(login_count(store, principal_id, 0))
    use Nil <- result.map(catalogue.statement(
      store,
      sql.revoke_principal_logins(principal_id),
    ))
    held
  })
}

/// Revokes every active browser login of every principal and answers how many
/// there were. It is what a daemon start does after it drew a new root key: the
/// rows' tokens can no longer verify, and without this the sign-in listings
/// would show them as live.
///
/// ## Examples
///
/// ```gleam
/// // access.revoke_all_logins(store)
/// ```
@internal
pub fn revoke_all_logins(store: Catalogue) -> Result(Int, Error) {
  catalogue.atomic(store, fn() {
    use rows <- result.try(catalogue.query(store, sql.active_login_count()))
    use row <- result.try(one(rows))
    use Nil <- result.map(catalogue.statement(store, sql.revoke_all_logins()))
    row.count
  })
}

/// Records that a login minted a home page at `now_ms`, when its last record is
/// absent or at least `resume_stamp_window_ms` old, and otherwise writes
/// nothing. A login row that does not exist is `Missing`.
///
/// ## Examples
///
/// ```gleam
/// // access.resumed(store, digest, now_ms)
/// ```
@internal
pub fn resumed(
  store: Catalogue,
  digest: Digest,
  now_ms: Int,
) -> Result(Stamp, Error) {
  use Nil <- result.try(case digest.kind {
    Browser -> Ok(Nil)
    Bearer -> Error(Invalid("a login row is a browser credential"))
  })
  catalogue.atomic(store, fn() {
    use rows <- result.try(catalogue.query(
      store,
      sql.login_resumed_at(digest.value),
    ))
    use row <- result.try(one(rows))
    case row.last_resumed_ms {
      Some(last) if now_ms - last < resume_stamp_window_ms -> Ok(Unchanged)
      Some(_) | None -> {
        use Nil <- result.map(catalogue.statement(
          store,
          sql.stamp_login_resumed(Some(now_ms), digest.value),
        ))
        Stamped
      }
    }
  })
}

// A fingerprint is the first sixteen hexadecimal digits of a digest.
fn fingerprint_shape(value: String) -> Result(Nil, Error) {
  case string.byte_size(value) == 16 && ascii_in(value, "0123456789abcdef") {
    True -> Ok(Nil)
    False -> Error(Invalid("fingerprint must be 16 lowercase hex bytes"))
  }
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

fn credential(store: Catalogue, digest: Digest, kind: CredentialKind) {
  use rows <- result.try(catalogue.query(
    store,
    sql.access_credential(digest.value, kind_name(kind)),
  ))
  use row <- result.try(one(rows))
  decoded_credential(row.digest, row.principal_id, row.state)
}

fn decoded_credential(digest: String, principal_id: String, state: String) {
  use _digest <- result.try(credential_digest(digest))
  use Nil <- result.try(valid_id(principal_id))
  case state {
    "active" -> Ok(Credential(principal_id, Active))
    "revoked" -> Ok(Credential(principal_id, Revoked))
    _ -> Error(Invalid("unknown persisted credential state"))
  }
}

fn kind_name(kind: CredentialKind) -> String {
  case kind {
    Bearer -> "bearer"
    Browser -> "browser"
  }
}

// The paths that enroll a member's own credential, and the one that replaces it,
// are bearer paths. A login's row is written only by `issue_login`, which
// records its expiry, and by a claim bound as a login.
fn bearer_only(digest: Digest) -> Result(Nil, Error) {
  case digest.kind {
    Bearer -> Ok(Nil)
    Browser -> Error(Invalid("a browser login is not a bearer credential"))
  }
}

// A digest is one primary key across both kinds, so "is this digest free" and
// "does this digest exist" ask both kinds. Only an authentication names one.
fn held(store: Catalogue, digest: Digest) {
  use rows <- result.try(catalogue.query(
    store,
    sql.access_credential_any_kind(digest.value),
  ))
  use row <- result.try(one(rows))
  decoded_credential(row.digest, row.principal_id, row.state)
}

fn unused(store: Catalogue, digest: Digest) -> Result(Nil, Error) {
  absent(held(store, digest))
}

// A principal about to be written: the name must meet the stricter rule for
// new names, then the row is built as one read back would be.
fn new_principal(id: String, display_name: String, kind: String) {
  use Nil <- result.try(new_name(display_name))
  principal(id, display_name, kind)
}

// A principal read back from the catalogue, or built from a validated write.
fn principal(id: String, display_name: String, kind: String) {
  use Nil <- result.try(valid_id(id))
  use Nil <- result.try(stored_name(display_name))
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

// The rule for a name already in the catalogue, applied when a row is read.
//
// It is deliberately the older, looser rule: nonblank, at most 256 bytes, no
// control characters. A row written before `new_name` refused invisible and
// direction-changing characters must still decode, or authentication and every
// listing would fail for that principal after an upgrade. Decoding never
// rewrites a name; it only declines to be the place a stored name is judged
// against a rule it did not have when it was written.
fn stored_name(name: String) {
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

// The rule for a name about to be written (claim, rename, invitation): the
// stored rule plus no zero-width or direction-changing character, since a
// name is drawn beside other text and such a character reorders it or leaves
// the name drawing as nothing. It is stricter than `stored_name` only on
// writes so that tightening it cannot strand an existing row.
fn new_name(name: String) {
  case
    stored_name(name),
    list.any(string.to_utf_codepoints(name), fn(point) {
      catalogue.invisible(string.utf_codepoint_to_int(point))
    })
  {
    Ok(Nil), False -> Ok(Nil)
    Ok(Nil), True ->
      Error(Invalid(
        "display name must be nonblank, at most 256 bytes, and contain no controls or invisible characters",
      ))
    Error(error), _ -> Error(error)
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
