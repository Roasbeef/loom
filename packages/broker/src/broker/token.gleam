//// Capability tokens: the unforgeable refs that clear every effect.
////
//// Per design §5.3 and spec Part 1.4: a token is a 32-byte random value
//// minted by the broker, valid for one `{op_id, step_id}`, bound to the
//// policy and deadline of the execution it clears, transmitted only over
//// the channel it authorizes, and checked on every capability call. The
//// revocation list is broker-local; abort revokes every token of an
//// operation.
////
//// Entropy is injected (`fn(Int) -> BitArray`), so minting is
//// deterministic under test; production injects
//// `broker/internal/ffi_crypto.strong_random_bytes`. Presented bytes are
//// compared in constant time (OTP `crypto:hash_equals` via the FFI), and
//// the check scans every entry without early exit so a match's position
//// leaks nothing either.

import broker/internal/ffi_crypto
import broker/policy.{type SandboxPolicy}
import core/ids.{type OpId}
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}

/// Every token is exactly this many random bytes.
pub const byte_count = 32

/// A live capability token. Opaque: the only way to get one is
/// `mint`, and the raw bytes leave the broker only via `to_bytes` when
/// they are placed on the channel they authorize.
pub opaque type Token {
  /// Invariant: `bytes` is exactly `byte_count` bytes of injected
  /// entropy.
  Token(bytes: BitArray)
}

/// What a token authorizes: one step of one operation, under one
/// policy, until one deadline.
pub type Binding {
  Binding(
    /// The operation this token belongs to; `revoke_all` keys on it.
    op_id: OpId,
    /// The step within the operation. One token per `{op_id, step_id}`.
    step_id: String,
    /// The composed policy the effect was cleared under.
    policy: SandboxPolicy,
    /// Unix-ms instant after which the token is dead.
    deadline_ms: Int,
  )
}

/// The broker-local token table: live and revoked tokens plus the
/// entropy source used for minting.
pub opaque type Vault {
  /// Invariants: `entries` bytes are pairwise distinct; revoked entries
  /// are retained (never resurrected) so a revoked token refuses as
  /// `Revoked`, not `UnknownToken`.
  Vault(entropy: fn(Int) -> BitArray, entries: List(Entry))
}

type Entry {
  Entry(bytes: BitArray, binding: Binding, revoked: Bool)
}

/// Why a presented token was refused. Precedence when several apply:
/// `UnknownToken` > `Revoked` > `Expired` > `WrongBinding`.
pub type Refusal {
  /// The bytes match no token ever minted by this vault.
  UnknownToken

  /// The token was revoked (directly or via `revoke_all`).
  Revoked

  /// The binding's deadline has passed.
  Expired(deadline_ms: Int)

  /// The token is live but bound to a different `{op_id, step_id}`.
  WrongBinding
}

/// Why minting failed.
pub type MintError {
  /// The entropy source returned the wrong number of bytes.
  EntropyFailure(got_bytes: Int)

  /// The entropy source repeated an existing token's bytes — with real
  /// entropy this is unreachable; with injected test entropy it is a
  /// fixture bug worth naming.
  DuplicateToken
}

/// A vault minting from the given entropy source. Production passes
/// `production_entropy`; tests inject deterministic bytes.
///
/// ## Examples
///
/// ```gleam
/// let vault = token.new(entropy: fn(count) { <<0:size(count)-unit(8)>> })
/// // -> a vault whose first minted token is 32 zero bytes
/// ```
///
pub fn new(entropy entropy: fn(Int) -> BitArray) -> Vault {
  Vault(entropy:, entries: [])
}

/// The production entropy source: OTP `crypto:strong_rand_bytes` via
/// the package FFI.
pub fn production_entropy() -> fn(Int) -> BitArray {
  ffi_crypto.strong_random_bytes
}

/// Mints a token bound to `binding`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(#(_vault, _token)) = token.mint(vault, binding)
/// ```
///
pub fn mint(
  vault: Vault,
  binding: Binding,
) -> Result(#(Vault, Token), MintError) {
  let bytes = vault.entropy(byte_count)
  let got_bytes = bit_array.byte_size(bytes)
  case got_bytes == byte_count {
    False -> Error(EntropyFailure(got_bytes:))
    True ->
      case scan(vault.entries, bytes) {
        Some(_) -> Error(DuplicateToken)
        None -> {
          let entry = Entry(bytes:, binding:, revoked: False)
          let vault = Vault(..vault, entries: [entry, ..vault.entries])
          Ok(#(vault, Token(bytes:)))
        }
      }
  }
}

/// The token's raw bytes, for placing on the channel it authorizes.
/// Never log or persist these.
pub fn to_bytes(token: Token) -> BitArray {
  token.bytes
}

/// Checks presented bytes against the vault: known, unrevoked, and
/// within deadline. Returns the binding so the caller learns the policy
/// the effect was cleared under.
///
/// ## Examples
///
/// ```gleam
/// assert token.check(vault, <<1, 2, 3>>, now: 0) == Error(token.UnknownToken)
/// ```
///
pub fn check(
  vault: Vault,
  presented: BitArray,
  now now: Int,
) -> Result(Binding, Refusal) {
  case scan(vault.entries, presented) {
    None -> Error(UnknownToken)
    Some(Entry(bytes: _, binding: _, revoked: True)) -> Error(Revoked)
    Some(Entry(bytes: _, binding:, revoked: False)) ->
      case now > binding.deadline_ms {
        True -> Error(Expired(deadline_ms: binding.deadline_ms))
        False -> Ok(binding)
      }
  }
}

/// Like `check`, additionally requiring the token to be bound to
/// exactly this `{op_id, step_id}` — the form every `cap_call` and exec
/// dispatch uses.
pub fn check_for(
  vault: Vault,
  presented: BitArray,
  op_id op_id: OpId,
  step_id step_id: String,
  now now: Int,
) -> Result(Binding, Refusal) {
  // `check` settles Unknown/Revoked/Expired before this function's own
  // binding comparison ever runs, so a token that is both dead and
  // wrong-bound reports the deader fact — the caller learns the token is
  // unusable at all, not merely misdirected, which is the more actionable
  // diagnosis regardless of which came "first".
  case check(vault, presented, now:) {
    Error(refusal) -> Error(refusal)
    Ok(binding) ->
      case binding.op_id == op_id && binding.step_id == step_id {
        True -> Ok(binding)
        False -> Error(WrongBinding)
      }
  }
}

/// Revokes the token with these bytes. Idempotent: revoking an already
/// revoked or unknown token changes nothing.
pub fn revoke(vault: Vault, presented: BitArray) -> Vault {
  let entries =
    list.map(vault.entries, fn(entry) {
      case ffi_crypto.constant_time_equal(entry.bytes, presented) {
        True -> Entry(..entry, revoked: True)
        False -> entry
      }
    })
  Vault(..vault, entries:)
}

/// Revokes every token of an operation — the abort path. Idempotent.
pub fn revoke_all(vault: Vault, op_id: OpId) -> Vault {
  let entries =
    list.map(vault.entries, fn(entry) {
      case entry.binding.op_id == op_id {
        True -> Entry(..entry, revoked: True)
        False -> entry
      }
    })
  Vault(..vault, entries:)
}

/// Drops entries whose deadline is more than `grace_ms` in the past —
/// housekeeping so a long session's vault stays small. Expired-but-kept
/// entries still refuse as `Expired`; dropped ones refuse as
/// `UnknownToken`, which is equally a refusal.
pub fn drop_expired(
  vault: Vault,
  now now: Int,
  grace_ms grace_ms: Int,
) -> Vault {
  let entries =
    list.filter(vault.entries, fn(entry) {
      entry.binding.deadline_ms + grace_ms >= now
    })
  Vault(..vault, entries:)
}

/// How many entries (live and revoked) the vault holds. For tests and
/// telemetry.
pub fn size(vault: Vault) -> Int {
  list.length(vault.entries)
}

// Constant-time-per-entry scan without early exit: every entry is
// compared even after a match, so timing reveals neither the matching
// entry's position nor how close a guess came.
fn scan(entries: List(Entry), presented: BitArray) -> Option(Entry) {
  list.fold(entries, None, fn(found, entry) {
    case ffi_crypto.constant_time_equal(entry.bytes, presented), found {
      True, None -> Some(entry)
      True, Some(_) -> found
      False, _ -> found
    }
  })
}
