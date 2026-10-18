//// Test-only entropy external for the e2e suites (seeding id generators).
//// Backed by `conformance_test_ffi.erl`; production code never uses it.
//// Environment reads go through `envoy`; this module keeps only what no
//// library covers: `erlang:unique_integer/1` with `monotonic` ordering,
//// which nothing in the stdlib or OTP wrappers in the tree exposes.

/// A positive, strictly monotonic integer that never repeats within the
/// VM's lifetime. Uses `erlang:unique_integer/1`; the e2e wiring
/// injects it as the entropy source because id-generator seeds must
/// never repeat in-session (spec-gaps WP-E item 6) and a deterministic
/// fixture cannot provide that across tree restarts.
@external(erlang, "conformance_test_ffi", "unique_integer")
pub fn unique_integer() -> Int
