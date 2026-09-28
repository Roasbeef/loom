//// Test-only shell externals for the feature-detected integration
//// suite: finding `git` and preparing the repository its worktree
//// fixture approves writes into. Backed by `tools_test_ffi.erl`;
//// production code never uses these.

/// Looks an executable up on PATH. Uses `os:find_executable/1`; PATH
/// lookup has no pure alternative.
@external(erlang, "tools_test_ffi", "find_executable")
pub fn find_executable(name: String) -> Result(String, Nil)

/// Runs a shell command and returns its stdout. Uses `os:cmd/1`;
/// test-only, for preparing a git repository outside the jail.
@external(erlang, "tools_test_ffi", "os_cmd")
pub fn os_cmd(command: String) -> String
