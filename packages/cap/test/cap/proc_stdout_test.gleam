//// `proc.stdout` and `proc.stdout_accepting` reduce a run to its output text
//// or one error string. The reduction is `proc.stdout_from`, which takes the
//// run result as an argument, so every rule is tested here without a channel.

import cap/proc
import gleam/bit_array
import gleam/list
import gleam/string

fn output(
  exit_code: Int,
  stdout: String,
  stderr: String,
  timed_out: Bool,
) -> proc.Output {
  proc.Output(
    exit_code:,
    stdout:,
    stderr:,
    stdout_truncated: False,
    stderr_truncated: False,
    timed_out:,
  )
}

pub fn a_zero_exit_returns_stdout_test() {
  assert proc.stdout_from(["ls"], Ok(output(0, "a\nb\n", "warn", False)), [0])
    == Ok("a\nb\n")
}

pub fn a_failed_exit_names_the_command_code_and_stderr_test() {
  let result =
    proc.stdout_from(
      ["git", "log", "--format", "%h %s"],
      Ok(output(128, "", "fatal: ambiguous argument '%h %s'\n", False)),
      [0],
    )
  assert result
    == Error(
      "`git log --format %h %s` exited 128: fatal: ambiguous argument '%h %s'",
    )
}

pub fn empty_stderr_is_said_to_be_empty_test() {
  assert proc.stdout_from(["false"], Ok(output(1, "", " \n", False)), [0])
    == Error("`false` exited 1: (no stderr)")
}

pub fn accepted_nonzero_exits_are_data_test() {
  let no_match = Ok(output(1, "", "", False))
  assert proc.stdout_from(["grep", "x"], no_match, [0, 1]) == Ok("")
  assert proc.stdout_from(["grep", "x"], no_match, [0])
    == Error("`grep x` exited 1: (no stderr)")
  assert proc.stdout_from(["grep", "x"], Ok(output(2, "", "bad", False)), [0, 1])
    == Error("`grep x` exited 2: bad")
}

pub fn a_timeout_is_an_error_even_with_an_accepted_exit_test() {
  assert proc.stdout_from(["sleep", "9"], Ok(output(0, "x", "", True)), [0])
    == Error("`sleep 9` timed out")
  assert proc.stdout_from(["sleep", "9"], Ok(output(0, "x", "slow", True)), [0])
    == Error("`sleep 9` timed out: slow")
}

pub fn a_proc_error_names_the_command_test() {
  assert proc.stdout_from(["nope"], Error(proc.SpawnFailed("no such file")), [0])
    == Error("`nope`: spawn failed: no such file")
}

pub fn a_long_command_line_is_cut_within_the_limit_test() {
  // The ellipsis counts toward the 160 bytes, so 157 bytes of text are
  // allowed. Each "é" is two bytes, so the cut falls inside the 79th one and
  // backs off to a boundary: 156 bytes of text plus 3 for the ellipsis.
  let argv = [string.repeat("é", 100)]
  let assert Error(text) =
    proc.stdout_from(argv, Ok(output(1, "", "e", False)), [0])
  assert text == "`" <> string.repeat("é", 78) <> "…` exited 1: e"
  assert command_bytes(text) == 159

  // A leading byte shifts the boundaries, so the cut lands exactly on one
  // and the text fills the limit.
  let argv = ["a" <> string.repeat("é", 100)]
  let assert Error(text) =
    proc.stdout_from(argv, Ok(output(1, "", "e", False)), [0])
  assert text == "`a" <> string.repeat("é", 78) <> "…` exited 1: e"
  assert command_bytes(text) == 160
}

// The bytes between the opening backtick and the closing one.
fn command_bytes(text: String) -> Int {
  let assert Ok(#(_, rest)) = string.split_once(text, "`")
  let assert Ok(#(command, _)) = string.split_once(rest, "`")
  bit_array.byte_size(<<command:utf8>>)
}

pub fn a_short_command_line_is_kept_whole_test() {
  let argv = list.repeat("x", 80)
  let line = string.join(argv, " ")
  let assert Error(text) =
    proc.stdout_from(argv, Ok(output(1, "", "e", False)), [0])
  assert string.contains(text, line)
  assert !string.contains(text, "…")
}

pub fn only_the_tail_of_long_stderr_is_kept_test() {
  // The ellipsis counts toward the 400 bytes, so 397 bytes of text remain.
  let stderr = string.repeat("a", 500) <> "FATAL"
  let assert Error(text) =
    proc.stdout_from(["x"], Ok(output(1, "", stderr, False)), [0])
  assert text == "`x` exited 1: …" <> string.repeat("a", 392) <> "FATAL"
  assert reason_bytes(text) == 400

  // A cut that lands inside a character moves forward to the next boundary:
  // the 397-byte suffix starts inside an "é", so 396 bytes of text remain.
  let wide = string.repeat("é", 300)
  let assert Error(text) =
    proc.stdout_from(["x"], Ok(output(1, "", wide, False)), [0])
  assert text == "`x` exited 1: …" <> string.repeat("é", 198)
  assert reason_bytes(text) == 399
}

// The bytes after the `: ` that precedes the stderr text.
fn reason_bytes(text: String) -> Int {
  let assert Ok(#(_, reason)) = string.split_once(text, "exited 1: ")
  bit_array.byte_size(<<reason:utf8>>)
}
