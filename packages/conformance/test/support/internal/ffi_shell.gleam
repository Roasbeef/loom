//// Test-only entropy and environment externals for the e2e and soak
//// suites (seeding id generators and reading the soak's opt-in
//// variables). Backed by `conformance_test_ffi.erl`; production code
//// never uses these.

/// A positive, strictly monotonic integer that never repeats within the
/// VM's lifetime. Uses `erlang:unique_integer/1`; the e2e wiring
/// injects it as the entropy source because id-generator seeds must
/// never repeat in-session (spec-gaps WP-E item 6) and a deterministic
/// fixture cannot provide that across tree restarts.
@external(erlang, "conformance_test_ffi", "unique_integer")
pub fn unique_integer() -> Int

/// Reads an environment variable. Uses `os:getenv/1`; the soak suite is
/// opt-in and an environment variable is how it is opted into.
@external(erlang, "conformance_test_ffi", "get_env")
pub fn get_env(name: String) -> Result(String, Nil)
