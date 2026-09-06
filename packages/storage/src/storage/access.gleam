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

import gleam/list
import gleam/result
import gleam/string
import storage/catalogue.{type Catalogue, type Error, Conflict, Invalid, Missing}
import storage/sql

/// A validated lowercase hexadecimal SHA-256 credential digest.
pub opaque type Digest {
  Digest(value: String)
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

/// Creates one member, credential and membership in one transaction.
///
/// A duplicate principal is a conflict, never a retry that issues another
/// credential. The caller's stable principal ID permits explicit recovery by
/// member rotation if the successful invitation reply was lost.
///
/// ## Examples
///
/// ```gleam
/// // access.invite_member(store, "alice", "Alice", digest, session_id, Operator)
/// ```
@internal
pub fn invite_member(
  store: Catalogue,
  id: String,
  name: String,
  digest: Digest,
  session_id: String,
  role: Role,
) -> Result(Principal, Error) {
  use proposed <- result.try(principal(id, name, "member"))
  catalogue.atomic(store, fn() {
    use _ <- result.try(catalogue.get(store, session_id))
    use created <- result.try(insert_principal(store, proposed, digest))
    use Nil <- result.try(grant_changed(store, id, session_id, role))
    Ok(created)
  })
}

/// Replaces every active credential of one member, preserving all tombstones.
///
/// Owner credentials are excluded because the daemon's owner file has a
/// separate lifetime. A failed insertion rolls back all revocations.
///
/// ## Examples
///
/// ```gleam
/// // access.rotate_member(store, "alice", replacement_digest)
/// ```
@internal
pub fn rotate_member(
  store: Catalogue,
  id: String,
  replacement: Digest,
) -> Result(Principal, Error) {
  catalogue.atomic(store, fn() {
    use found <- result.try(member(store, id))
    use Nil <- result.try(absent(credential(store, replacement)))
    use Nil <- result.try(catalogue.statement(
      store,
      sql.revoke_member_credentials(id),
    ))
    use Nil <- result.try(catalogue.statement(
      store,
      sql.insert_access_credential(replacement.value, id),
    ))
    Ok(found)
  })
}

/// Revokes a member's active credentials without deleting its identity or grants.
///
/// Repeating this operation is idempotent. Explicit rotation can recover the
/// stable member later; no revoked bearer is ever reactivated.
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
    use Nil <- result.try(catalogue.statement(
      store,
      sql.revoke_member_credentials(id),
    ))
    Ok(found)
  })
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
  use found <- result.try(get(store, principal_id))
  use _session <- result.try(catalogue.get(store, session_id))
  case found.kind {
    OwnerPrincipal -> Ok(Owner)
    MemberPrincipal ->
      membership(store, principal_id, session_id) |> result.map(Participant)
  }
}

fn membership(store: Catalogue, principal_id: String, session_id: String) {
  use rows <- result.try(catalogue.query(
    store,
    sql.access_membership(principal_id, session_id),
  ))
  use row <- result.try(one(rows))
  case row.role {
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
