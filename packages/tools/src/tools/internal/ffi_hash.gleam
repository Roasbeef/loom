//// FFI confinement module for the tools package's one external:
//// cryptographic hashing for blob content addressing. See
//// `tools_ffi.erl` for the Erlang side.

/// SHA-256 of the given bytes, as 32 raw bytes.
///
/// Uses OTP `crypto:hash/2` (via `tools_ffi:sha256/1`, which fixes the
/// algorithm atom on the Erlang side). No pure alternative exists at
/// acceptable cost: blob refs are content addresses shared across
/// sessions, so the hash must be collision resistant, and implementing
/// SHA-256 in Gleam would be slow and a fresh audit surface.
@external(erlang, "tools_ffi", "sha256")
pub fn sha256(bytes: BitArray) -> BitArray
