//// The three operating-system actions that belong to the terminal itself.
////
//// Everything else the launcher needs from the operating system — private
//// files, locks, process identity and launch, clocks, digests — is shared
//// with the daemon and lives in `host/bootstrap`. What is left here is what
//// only a program that owns a terminal wants: silencing the logger that would
//// otherwise write over the alternate screen, running a child whose output
//// *is* this program's output, and exiting the VM with that child's status.
//// None of the three has an expression in `gleam_stdlib`, `gleam_erlang`,
//// `gleam_otp` or weft, which is why they are `@external` at all.

/// Stops every OTP logger handler from writing to the terminal.
///
/// Uses OTP `logger:set_primary_config/2` with level `none`. Once etui owns
/// the alternate screen, a dependency's error report or a crash report has
/// nowhere to go except over the rendered frame, where it stays until those
/// cells repaint; a stale endpoint probe during a session switch is one
/// producer. Failures the operator must see already reach the transcript as
/// typed errors.
@external(erlang, "tui_ffi", "silence_logger")
pub fn silence_logger() -> Nil

/// Runs one executable to completion, forwarding its output to this
/// process's stdout as it arrives, and answers with its exit status.
///
/// Uses OTP `open_port/2` with `exit_status` and `stderr_to_stdout`. The
/// passthrough `loom ext` needs: nothing draws a frame, so the child's
/// output is the output, and the child's status is the launcher's.
@external(erlang, "tui_ffi", "run_forwarding")
pub fn run_forwarding(
  executable: String,
  arguments: List(String),
) -> Result(Int, String)

/// Exits the VM with a status.
///
/// Uses OTP `erlang:halt/1`. Only the passthrough path calls it: the
/// interactive launcher returns from `main` so the terminal is restored.
@external(erlang, "tui_ffi", "halt")
pub fn halt(code: Int) -> anything
