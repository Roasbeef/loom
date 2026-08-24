//// Cryptographic externals for the broker.
////
//// FFI confinement (spec §0.2): all `@external` declarations used for
//// entropy and constant-time comparison live here, backed by the shims
//// in `broker_ffi.erl`. The rest of the package injects these as plain
//// function values, so pure logic stays testable with deterministic
//// substitutes.

/// Returns `count` cryptographically strong random bytes.
///
/// Uses OTP `crypto:strong_rand_bytes/1`; entropy has no pure
/// alternative by definition. Production capability tokens are minted
/// from this; tests inject deterministic byte sources instead.
@external(erlang, "broker_ffi", "strong_rand_bytes")
pub fn strong_random_bytes(count: Int) -> BitArray

/// Compares two byte strings in constant time with respect to their
/// contents, so a token check leaks no timing signal about how many
/// leading bytes matched.
///
/// Uses OTP `crypto:hash_equals/2` (via a shim that answers `False` for
/// unequal lengths, which are public information — every token is 32
/// bytes). No pure alternative exists: Gleam `==` on bit arrays
/// short-circuits at the first differing byte.
@external(erlang, "broker_ffi", "constant_time_equal")
pub fn constant_time_equal(a: BitArray, b: BitArray) -> Bool
