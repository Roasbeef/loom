//// What the daemon does with a passkey form once the router has checked the
//// request (protocol-change/127): spend the challenge, find the credential,
//// verify the ceremony with `client/daemon/passkey`, and write what it earned,
//// which is a login for a sign-in and a catalogue row for a registration.
////
//// The router owns everything about the request: the host, the sender, the
//// declared size, the permit and the page's standing. This module takes the
//// fields that survived `ui_http.posted_fields` and the facts the router
//// resolved, and answers `Result(_, Nil)` so that every refusal is one answer.
//// It never logs a field the browser sent. A refusal is logged by its reason,
//// which is a constructor of `passkey.Refusal` and so carries no value the
//// request chose.
////
//// ## Flow
////
//// `may_register` → `register` → `sign_in`
////
//// 1. `may_register` is the router's question of a page: whether it is the
////    owner's fresh operating home, which is the only page a registration is
////    accepted from.
//// 2. `register` reads the five registration fields, spends the challenge (which
////    must be this principal's registration), verifies the registration and
////    writes the passkey.
//// 3. `sign_in` reads the four assertion fields, spends the challenge the client
////    data names (which must be a sign-in's), finds the passkey and its
////    principal, verifies the assertion, records the counter and sets a login.
////
//// In both the challenge is spent first and before anything else is looked up,
//// so a replayed, expired or other-purpose challenge touches neither the
//// catalogue nor the crypto.

import client/daemon/manager
import client/daemon/passkey
import client/daemon/ui_http
import client/daemon/ui_login
import client/daemon/ui_sessions
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/result
import gleam/string
import host/bootstrap
import host/login
import storage/access
import telemetry/field
import telemetry/level
import telemetry/log

/// The label a passkey gets when the person left the name blank.
pub const default_label = "Passkey"

/// What a passkey sign-in earned: the login that was set and whose it is.
pub type Opened {
  Opened(minted: ui_login.Minted, principal: access.Principal)
}

/// Whether a page may register a passkey (protocol-change/127): it is the
/// owner's, a home, at `Operator` ceiling, and a `loom ui` exchange opened it, so
/// the owner held a control credential within the page's lifetime. A page a
/// passkey or a bookmark opened is `Resumed` and is refused.
///
/// ## Examples
///
/// ```gleam
/// // ui_passkey.may_register(principal, ui_sessions.grant(page))
/// ```
pub fn may_register(
  principal: access.Principal,
  grant: ui_sessions.Grant,
) -> Bool {
  principal.kind == access.OwnerPrincipal
  && grant.ceiling == access.Operator
  && grant.origin == ui_sessions.Fresh
  && grant.scope == ui_sessions.Home
}

/// The opaque handle a principal's passkeys carry as the user id: the SHA-256 of
/// a fixed prefix and the principal's identifier, as 43 base64url characters. It
/// is stable, so a new passkey on an authenticator replaces the old one of the
/// same principal there, and it names no one to a person who reads it.
///
/// ## Examples
///
/// ```gleam
/// assert string.length(ui_passkey.user_handle("owner")) == 43
/// ```
pub fn user_handle(principal_id: String) -> String {
  { "loom-passkey-user:" <> principal_id }
  |> bit_array.from_string
  |> bootstrap.sha256
  |> bit_array.base64_url_encode(False)
}

/// What the daemon requires of a ceremony on a page admitted under `origin`: the
/// origin's own address, its relying party id and the challenge named.
fn expected(origin: ui_http.PageOrigin, challenge: String) -> passkey.Expected {
  passkey.Expected(
    origin: ui_http.address(origin),
    rp_id: ui_http.rp_id(origin),
    challenge:,
  )
}

/// One field's bytes, decoded from the base64url the browser sent.
fn bytes(fields: Dict(String, String), name: String) -> Result(BitArray, Nil) {
  use text <- result.try(dict.get(fields, name))
  bit_array.base64_url_decode(text)
}

/// Signs a browser in with a passkey: the four fields of `POST /ui/signin`
/// (`id`, `cdj`, `ad` and `sig`) as the router parsed them. The answer is the
/// login that was set and the principal it is for, or `Error(Nil)` for every way
/// the sign-in can fail, which the router answers with one fixed document.
///
/// ## Examples
///
/// ```gleam
/// // ui_passkey.sign_in(root, sessions, registry, origin, fields, now_ms)
/// ```
pub fn sign_in(
  root: login.RootKey,
  sessions: ui_sessions.Sessions,
  registry: manager.Manager(instance),
  origin: ui_http.PageOrigin,
  fields: Dict(String, String),
  now_ms: Int,
) -> Result(Opened, Nil) {
  use client_data <- result.try(bytes(fields, "cdj"))
  use authenticator_data <- result.try(bytes(fields, "ad"))
  use signature <- result.try(bytes(fields, "sig"))
  use credential_id <- result.try(dict.get(fields, "id"))
  use challenge <- result.try(passkey.challenge_of(client_data))

  // The challenge is spent before anything is looked up, and it must be one the
  // sign-in page issued.
  use Nil <- result.try(spend_sign_in_challenge(sessions, challenge))
  use #(found, principal) <- result.try(
    manager.find_passkey(registry, credential_id) |> result.replace_error(Nil),
  )
  use Nil <- result.try(owner_only(principal))
  use count <- result.try(
    passkey.verify_assertion(
      expected(origin, challenge),
      passkey.Stored(public_key: found.public_key, sign_count: found.sign_count),
      passkey.Assertion(client_data:, authenticator_data:, signature:),
    )
    |> result.map_error(refused(_, "sign_in")),
  )
  use Nil <- result.try(
    manager.use_passkey(registry, credential_id, count, now_ms)
    |> result.replace_error(Nil),
  )
  use minted <- result.map(
    ui_login.passkey(root, registry, principal.id, now_ms)
    |> result.replace_error(Nil),
  )
  log.info(logger(), "daemon.passkey_signin", [
    field.ident("principal_id", principal.id),
    field.ident("passkey", access.passkey_fingerprint(credential_id)),
  ])
  Opened(minted:, principal:)
}

/// Registers a passkey for the owner whose fresh home asked: the five fields of
/// `POST /ui/p/<key>/passkey` as the router parsed them, `caller` the page's
/// credential and `epoch` the daemon's. The router has already checked that the
/// page may register (`may_register`) and that its nonce was presented. The
/// answer is `Error(Nil)` for every way the registration can fail.
///
/// ## Examples
///
/// ```gleam
/// // ui_passkey.register(sessions, registry, origin, epoch, caller, owner, fields, now_ms)
/// ```
pub fn register(
  sessions: ui_sessions.Sessions,
  registry: manager.Manager(instance),
  origin: ui_http.PageOrigin,
  epoch: String,
  caller: access.Digest,
  principal: access.Principal,
  fields: Dict(String, String),
  now_ms: Int,
) -> Result(Nil, Nil) {
  use client_data <- result.try(bytes(fields, "cdj"))
  use authenticator_data <- result.try(bytes(fields, "ad"))
  use public_key <- result.try(bytes(fields, "pk"))
  use raw_id <- result.try(bytes(fields, "id"))
  use credential_id <- result.try(canonical(fields, "id", raw_id))
  use challenge <- result.try(passkey.challenge_of(client_data))

  // The label is judged before the challenge is spent, so a label the person can
  // correct does not cost them the challenge.
  use label <- result.try(label(fields))

  // The challenge must be this principal's registration.
  use Nil <- result.try(spend_registration_challenge(
    sessions,
    challenge,
    principal,
  ))
  use registered <- result.try(
    passkey.verify_registration(
      expected(origin, challenge),
      passkey.Registration(
        credential_id: raw_id,
        client_data:,
        authenticator_data:,
        public_key:,
      ),
    )
    |> result.map_error(refused(_, "register")),
  )
  use Nil <- result.map(
    manager.add_passkey(
      registry,
      caller,
      epoch,
      credential_id,
      registered.public_key,
      registered.sign_count,
      label,
      now_ms,
    )
    |> result.replace_error(Nil),
  )
  log.info(logger(), "daemon.passkey_added", [
    field.ident("principal_id", principal.id),
    field.ident("passkey", access.passkey_fingerprint(credential_id)),
  ])
}

/// Spends the challenge a sign-in named, which must have been issued to the
/// sign-in page. The table removes it whether or not it was live, so it answers
/// once.
fn spend_sign_in_challenge(
  sessions: ui_sessions.Sessions,
  challenge: String,
) -> Result(Nil, Nil) {
  // A registration's challenge, and one that was never issued, are not a sign-in's.
  case ui_sessions.answer(sessions, challenge) {
    Ok(ui_sessions.SigningIn) -> Ok(Nil)
    Ok(ui_sessions.Registering(_)) | Error(Nil) -> Error(Nil)
  }
}

/// Spends the challenge a registration named, which must have been issued to
/// this principal's registration page.
fn spend_registration_challenge(
  sessions: ui_sessions.Sessions,
  challenge: String,
  principal: access.Principal,
) -> Result(Nil, Nil) {
  // Another principal's registration, a sign-in's and an unknown challenge are
  // each refused.
  case ui_sessions.answer(sessions, challenge) {
    Ok(ui_sessions.Registering(asked)) if asked == principal.id -> Ok(Nil)
    Ok(ui_sessions.Registering(_)) | Ok(ui_sessions.SigningIn) | Error(Nil) ->
      Error(Nil)
  }
}

/// The credential id as the daemon keeps it is the canonical base64url of its
/// bytes, so two spellings of one id cannot be two rows.
fn canonical(
  fields: Dict(String, String),
  name: String,
  raw: BitArray,
) -> Result(String, Nil) {
  use text <- result.try(dict.get(fields, name))

  // Another spelling of the same bytes is not the id the authenticator will
  // present at sign-in.
  case bit_array.base64_url_encode(raw, False) == text {
    True -> Ok(text)
    False -> Error(Nil)
  }
}

/// The label the person typed, or the default for a blank one, judged by the
/// catalogue's rule.
fn label(fields: Dict(String, String)) -> Result(String, Nil) {
  use typed <- result.try(dict.get(fields, "label"))

  // A blank label is the person's choice not to name the passkey.
  case string.trim(typed) {
    "" -> Ok(default_label)
    trimmed -> access.passkey_label(trimmed) |> result.replace_error(Nil)
  }
}

/// Passkeys belong to the owner (protocol-change/127), so a row of another
/// principal signs nobody in.
fn owner_only(principal: access.Principal) -> Result(Nil, Nil) {
  // A member's row is refused.
  case principal.kind {
    access.OwnerPrincipal -> Ok(Nil)
    access.MemberPrincipal -> Error(Nil)
  }
}

// A refusal is written down by its reason and ceremony, which hold nothing the
// request chose, and answered as one fixed refusal.
fn refused(reason: passkey.Refusal, ceremony: String) -> Nil {
  log.info(logger(), "daemon.passkey_refused", [
    field.ident("ceremony", ceremony),
    field.ident("reason", string.inspect(reason)),
  ])
}

// The daemon installs the JSON handler at boot, so a logger writing through
// Erlang `logger` reaches `daemon.log` without a handle being threaded here.
fn logger() -> log.Logger {
  log.erlang(threshold: level.Info)
}
