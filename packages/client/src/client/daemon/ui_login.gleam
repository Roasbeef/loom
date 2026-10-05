//// The daemon's half of the browser login (protocol-change/065, PR 8): what it
//// does with a login token and a login's catalogue row, around the pure token
//// module `host/login`.
////
//// A login is set by an exchange. `issue` draws an identifier, a key and a
//// nonce, signs the token and writes the login's row, and answers what the
//// response must hand the browser: the cookie's token, the key its path is
//// scoped to, and the nonce, which the browser keeps and the daemon forgets.
//// The row is keyed by the digest of the identifier and has the kind
//// `Browser`, so everything that takes a credential digest (the page's
//// authentication, its per-frame re-check, revocation) runs on it unchanged,
//// and a bearer lookup never finds it.
////
//// A login is used by a resume. `resume` opens each cookie value the request
//// carried, in order, and takes the first whose chain verifies and whose
//// caveats hold for this request: the path's key, the posted nonce and the
//// clock. That is the whole of what runs before the catalogue is asked, so a
//// forged, narrowed-past, expired or misdirected token costs one HMAC chain and
//// no read. Only then is the row found, active, of kind `Browser` and the
//// principal the token names.
////
//// A login is also set by a browser claim (`claim`, PR 9): the login's row is
//// the credential the claim binds, so the invitee has no bearer and nothing to
//// keep but the login. The row is written in the transaction that spends the
//// claim, with the same thirty-day expiry `issue` records, and the token is
//// signed only after that transaction names the principal.
////
//// The root key is read when the daemon starts (`root_key`). A missing file is
//// the owner's whole-daemon revocation: every login row is revoked first and a
//// new key written after, so a start that stops between the two finds no file
//// again and revokes nothing more, and the listings never show a login that can
//// no longer verify as live.
////
//// Nothing here logs a token, a nonce, a key or the root key. The log lines
//// name a principal and a login's fingerprint, which identifies a login and
//// authenticates nothing.

import broker/token
import client/daemon/manager
import client/daemon/ui_sessions
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import host/login
import storage/access
import telemetry/field
import telemetry/level
import telemetry/log

/// A login that was just set: what the exchange's response hands the browser.
pub type Minted {
  Minted(
    /// The token, which is the cookie's value.
    token: String,
    /// The login key, the cookie's path and the bookmark's.
    key: String,
    /// The login nonce, delivered once in the response's body. The daemon keeps
    /// its digest, inside the token, and nothing else.
    nonce: String,
    /// The cookie's lifetime in seconds: until the token's expiry, which a
    /// device link's login inherits and which is never extended.
    max_age_s: Int,
    /// The login as the page table knows it, which the page the exchange opened
    /// is the browser of.
    issuer: ui_sessions.Issuer,
  )
}

/// Why an exchange set no login. The page still opens: a login is a
/// convenience the exchange adds, and the browser is no worse off than one that
/// was told `--no-remember`.
pub type Unset {
  /// The login this one would inherit its expiry from has already ended.
  ParentEnded

  /// The login's row could not be written.
  RowRefused
}

/// A login that verified for a request and whose row is live.
pub type Resumed {
  Resumed(
    /// The principal the login is for, as the catalogue holds it now.
    principal: access.Principal,
    /// What the token allows after its caveats intersected.
    allowance: login.Allowance,
    /// The login as the page table knows it.
    issuer: ui_sessions.Issuer,
    /// The login row's digest, which a page the login mints authenticates as.
    digest: access.Digest,
  )
}

/// A browser claim that bound: the principal the claim names, as the catalogue
/// holds it now with the name the invitee chose, the digest of the login row the
/// claim bound, and the login the response must hand the browser.
pub type Claimed {
  Claimed(
    principal: access.Principal,
    /// The login row's digest, which the home page the claim opens
    /// authenticates as.
    digest: access.Digest,
    minted: Minted,
  )
}

/// Reads the root key at start, or draws one. A key that is present and wrong
/// refuses start. A missing file revokes every login row, logs the count, and
/// only then writes the new key.
///
/// ## Examples
///
/// ```gleam
/// // ui_login.root_key(state_root, registry)
/// ```
pub fn root_key(
  state_root: String,
  registry: manager.Manager(instance),
) -> Result(login.RootKey, String) {
  use found <- result.try(login.probe_root(state_root))
  case found {
    login.Present(key) -> Ok(key)
    login.Absent -> {
      use revoked <- result.try(
        manager.revoke_all_logins(registry)
        |> result.replace_error(
          "the browser logins could not be revoked for a new login key",
        ),
      )
      log.info(logger(), "daemon.logins_revoked", [
        field.count("count", revoked),
      ])
      login.write_root(state_root, token.production_entropy())
    }
  }
}

/// Sets a login for the principal of `grant`, ending `login.lifetime_ms` from
/// `now_ms`, or at `parent`'s expiry when this login comes from a device link
/// of that login, so no family of logins outlives the one it began from. The
/// ceiling of the token is the grant's, so every page the login mints is held to
/// what the exchange's page was.
///
/// ## Examples
///
/// ```gleam
/// // ui_login.issue(root, registry, grant, None, now_ms)
/// ```
pub fn issue(
  root: login.RootKey,
  registry: manager.Manager(instance),
  grant: ui_sessions.Grant,
  parent: Option(ui_sessions.Issuer),
  now_ms: Int,
) -> Result(Minted, Unset) {
  let expires_at_ms = case parent {
    Some(parent) -> parent.expires_at_ms
    None -> now_ms + login.lifetime_ms
  }
  case expires_at_ms > now_ms {
    False -> Error(ParentEnded)
    True -> write(root, registry, grant, parent, now_ms, expires_at_ms)
  }
}

// Draws the login's three values, signs the token and writes the row. The row
// is written last of the effects, so a refused row leaves nothing but a token
// that no row stands behind, which no request can open.
fn write(
  root: login.RootKey,
  registry: manager.Manager(instance),
  grant: ui_sessions.Grant,
  parent: Option(ui_sessions.Issuer),
  now_ms: Int,
  expires_at_ms: Int,
) -> Result(Minted, Unset) {
  let entropy = token.production_entropy()
  let id = login.fresh_id(entropy)
  let key = login.fresh_key(entropy)
  let nonce = login.fresh_nonce(entropy)

  // The token's ceiling is the grant's, so every page the login mints is held to
  // what the page this exchange opened was.
  let ceiling = case grant.ceiling {
    access.Operator -> login.Operator
    access.Observer -> login.Observer
  }
  let signed =
    seal(root, id, grant.principal, ceiling, expires_at_ms, key, nonce)

  // The row is keyed by the digest of the identifier, as the kind only a login's
  // lookup asks for.
  use digest <- result.try(row_digest(id))
  let from = option.map(parent, fn(issuer) { issuer.fingerprint })
  use Nil <- result.map(
    manager.issue_login(
      registry,
      grant.principal,
      digest,
      now_ms,
      expires_at_ms,
      from,
    )
    |> result.replace_error(RowRefused),
  )
  let fingerprint = access.fingerprint(digest)
  log.info(logger(), "daemon.login_issued", [
    field.ident("principal_id", grant.principal),
    field.ident("login", fingerprint),
    ..parent_field(from)
  ])
  minted(signed, key, nonce, now_ms, expires_at_ms, fingerprint)
}

// Signs the token for a login: the principal, the ceiling, the end, the key and
// the digest of the nonce, under the root key, for the identifier. It is pure,
// so the browser claim can run it after the catalogue has said who the claim
// names.
fn seal(
  root: login.RootKey,
  id: String,
  principal: String,
  ceiling: login.Ceiling,
  expires_at_ms: Int,
  key: String,
  nonce: String,
) -> String {
  login.issue(
    root,
    id,
    login.Minting(
      principal:,
      ceiling:,
      expires_at_ms:,
      key:,
      nonce_digest: login.nonce_digest(nonce),
    ),
  )
}

// What the response hands the browser for a login that was signed and written.
fn minted(
  signed: String,
  key: String,
  nonce: String,
  now_ms: Int,
  expires_at_ms: Int,
  fingerprint: String,
) -> Minted {
  Minted(
    token: signed,
    key:,
    nonce:,
    max_age_s: int.max({ expires_at_ms - now_ms } / 1000, 1),
    issuer: ui_sessions.Issuer(fingerprint:, expires_at_ms:, key:),
  )
}

/// Redeems `claim` in the browser: draws a login, binds its row to the claim
/// with `name` (or the inviter's name when `None`) in the one transaction that
/// spends the claim, and, once the catalogue has said whom the claim names,
/// signs the token (protocol-change/065, PR 9). The login is an `Operator` one
/// ending `login.lifetime_ms` from `now_ms`, and the row records that end as
/// `issue` does. The claim is spent only when the row is written, so a refused
/// name or a claim that is void, expired or bound to another credential binds
/// nothing and draws nothing the caller must forget. The token and its nonce
/// exist only after the bind, so no refusal has one to leak.
///
/// ## Examples
///
/// ```gleam
/// // ui_login.claim(root, registry, claim_digest, Some("Alex"), now_ms)
/// ```
pub fn claim(
  root: login.RootKey,
  registry: manager.Manager(instance),
  claim: access.ClaimDigest,
  name: Option(String),
  now_ms: Int,
) -> Result(Claimed, manager.ClaimError) {
  let entropy = token.production_entropy()
  let id = login.fresh_id(entropy)
  let key = login.fresh_key(entropy)
  let nonce = login.fresh_nonce(entropy)
  let expires_at_ms = now_ms + login.lifetime_ms

  // The row is keyed by the digest of the identifier, as a login's always is,
  // and the claim spends in the same transaction that writes it.
  use digest <- result.try(
    access.browser_digest(login.row_digest(id))
    |> result.replace_error(manager.ClaimUnavailable),
  )
  use bound <- result.map(manager.claim_login(
    registry,
    claim,
    digest,
    name,
    now_ms:,
    expires_at_ms:,
  ))

  // Only now does the catalogue say whom the claim names, so the token is
  // signed for the principal it returned and not for one the request named.
  let signed =
    seal(
      root,
      id,
      bound.principal.id,
      login.Operator,
      expires_at_ms,
      key,
      nonce,
    )
  let fingerprint = access.fingerprint(digest)
  log.info(logger(), "daemon.login_issued", [
    field.ident("principal_id", bound.principal.id),
    field.ident("login", fingerprint),
    field.ident("claimed", "browser"),
  ])
  Claimed(
    principal: bound.principal,
    digest:,
    minted: minted(signed, key, nonce, now_ms, expires_at_ms, fingerprint),
  )
}

fn parent_field(from: Option(String)) -> List(field.Field) {
  case from {
    Some(fingerprint) -> [field.ident("issued_by", fingerprint)]
    None -> []
  }
}

// The login row's digest, of the kind only a login's lookup asks for.
fn row_digest(id: String) -> Result(access.Digest, Unset) {
  access.browser_digest(login.row_digest(id))
  |> result.replace_error(RowRefused)
}

/// Resumes a login for a request: opens each of `cookies` in turn and takes the
/// first that verifies and holds for `key` (from the path), `nonce` (from the
/// body) and the clock, and then has the registry find its row active, of kind
/// `Browser` and the principal the token names. A token that fails any step is
/// passed over, so a value another port planted under a longer path, which the
/// browser sends first, cannot deny the person their own. The registry is asked
/// only for a token that passed every other step.
///
/// ## Examples
///
/// ```gleam
/// // ui_login.resume(root, registry, cookies, key, nonce, now_ms)
/// ```
pub fn resume(
  root: login.RootKey,
  registry: manager.Manager(instance),
  cookies: List(String),
  key: String,
  nonce: String,
  now_ms: Int,
) -> Result(Resumed, Nil) {
  use opened <- result.try(
    list.find_map(cookies, fn(cookie) {
      login.open(root, cookie, now_ms:, key:, nonce:)
    }),
  )
  use digest <- result.try(
    access.browser_digest(login.row_digest(opened.id))
    |> result.replace_error(Nil),
  )
  use principal <- result.map(
    manager.resume_login(registry, digest, opened.allowance.principal, now_ms)
    |> result.replace_error(Nil),
  )
  let fingerprint = access.fingerprint(digest)
  log.info(logger(), "daemon.login_resumed", [
    field.ident("principal_id", principal.id),
    field.ident("login", fingerprint),
  ])
  Resumed(
    principal:,
    allowance: opened.allowance,
    issuer: ui_sessions.Issuer(
      fingerprint:,
      expires_at_ms: opened.allowance.expires_at_ms,
      key:,
    ),
    digest:,
  )
}

/// Writes down that a login was revoked, naming its principal and fingerprint.
///
/// ## Examples
///
/// ```gleam
/// // ui_login.revoked("alice", digest)
/// ```
pub fn revoked(principal_id: String, digest: access.Digest) -> Nil {
  log.info(logger(), "daemon.login_revoked", [
    field.ident("principal_id", principal_id),
    field.ident("login", access.fingerprint(digest)),
  ])
}

/// Writes down that a principal signed out of every login at once, with how
/// many were active.
///
/// ## Examples
///
/// ```gleam
/// // ui_login.revoked_all("alice", 3)
/// ```
pub fn revoked_all(principal_id: String, count: Int) -> Nil {
  log.info(logger(), "daemon.login_revoked", [
    field.ident("principal_id", principal_id),
    field.count("count", count),
  ])
}

// The daemon installs the JSON handler at boot, so a logger writing through
// Erlang `logger` reaches `daemon.log` without a handle being threaded here.
fn logger() -> log.Logger {
  log.erlang(threshold: level.Info)
}
