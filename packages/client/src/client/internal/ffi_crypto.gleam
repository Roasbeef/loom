//// Cryptographic externals for the websocket transport's bearer-token
//// check.
////
//// FFI confinement (spec §0.2): the one `@external` this file declares
//// lives here, backed by the shim in `client_ffi.erl`. This is a
//// deliberate copy of the same primitive `broker/internal/ffi_crypto`
//// ships (`crypto:hash_equals` via an Erlang shim) rather than a new
//// dependency on `broker` from this module: the broker package is a
//// capability-token vault with its own actor and wire protocol, and
//// pulling it in for one comparison function would wire this transport
//// module into machinery it has no other reason to depend on. The
//// primitive is a few lines; copying it keeps the dependency graph
//// honest.

/// Compares two byte strings for equality without leaking timing
/// information about their contents *or* their lengths.
///
/// Unlike `broker/internal/ffi_crypto.constant_time_equal` (whose two
/// operands are always exactly 32 bytes, so a length check first is
/// harmless), the presented side here is attacker-controlled: a
/// wrong-length header must take exactly as long to refuse as a
/// right-length one, or the response time itself becomes an oracle for
/// the token's length. The shim hashes both operands to a fixed-size
/// digest with `crypto:hash/2` before comparing with
/// `crypto:hash_equals/2`, so the comparison never branches on the
/// presented length at all. No pure alternative exists: Gleam `==` on
/// bit arrays short-circuits at the first differing byte.
@external(erlang, "client_ffi", "constant_time_equal")
pub fn constant_time_equal(a: BitArray, b: BitArray) -> Bool
