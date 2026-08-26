//// Test-side FFI (spec §0.2 confinement, alongside `ffi_ws`): running a
//// program and waiting for it. The terminal end-to-end needs to build the
//// TUI binary and to drive `tmux`, and neither has a pure alternative.

/// The absolute path of a program on `PATH`, or `Error(Nil)` when the
/// host does not have it. Feature detection for the terminal harness:
/// a missing `tmux` or `go` is a skip, not a failure.
@external(erlang, "client_test_ffi", "which")
pub fn which(name: String) -> Result(String, Nil)

/// Runs `executable` with `args` in `directory` and waits for it,
/// returning `#(exit_status, output)` with stdout and stderr
/// interleaved.
///
/// The arguments reach `execve` as a vector — `open_port` with
/// `spawn_executable`, never `os:cmd` — so nothing built here is ever
/// parsed by a shell. That is load-bearing rather than tidy: the strings
/// passed through are terminal keystrokes.
@external(erlang, "client_test_ffi", "run")
pub fn run(
  executable: String,
  args: List(String),
  in directory: String,
) -> Result(#(Int, String), String)
