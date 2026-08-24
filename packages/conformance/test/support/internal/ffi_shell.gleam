//// Test-only shell and entropy externals for the feature-detected e2e
//// suite (finding the Go toolchain, building the real helper, and
//// seeding id generators). Backed by `conformance_test_ffi.erl`;
//// production code never uses these.

/// Looks an executable up on PATH. Uses `os:find_executable/1`; PATH
/// lookup has no pure alternative.
@external(erlang, "conformance_test_ffi", "find_executable")
pub fn find_executable(name: String) -> Result(String, Nil)

/// Runs a shell command and returns its stdout. Uses `os:cmd/1`;
/// test-only, for driving `go build`.
@external(erlang, "conformance_test_ffi", "os_cmd")
pub fn os_cmd(command: String) -> String

/// A positive, strictly monotonic integer that never repeats within the
/// VM's lifetime. Uses `erlang:unique_integer/1`; the e2e wiring
/// injects it as the entropy source because id-generator seeds must
/// never repeat in-session (spec-gaps WP-E item 6) and a deterministic
/// fixture cannot provide that across tree restarts.
@external(erlang, "conformance_test_ffi", "unique_integer")
pub fn unique_integer() -> Int
