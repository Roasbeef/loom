//// The last failing command is a pure reading of a `proc.run` call and its
//// reply. These tests pin what makes a record, what does not, and that both
//// cuts land on a UTF-8 boundary and never exceed their limit.

import core/msgpack
import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tools/proc_failure.{Exited, ProcFailure, TimedOut}

fn argv(words: List(String)) -> msgpack.MsgPackValue {
  msgpack.MapValue([
    #(
      msgpack.StringValue("argv"),
      msgpack.ArrayValue(list.map(words, msgpack.StringValue)),
    ),
  ])
}

fn reply(
  exit_code: Int,
  timed_out: Bool,
  stderr: String,
) -> msgpack.MsgPackValue {
  msgpack.MapValue([
    #(msgpack.StringValue("exit_code"), msgpack.IntValue(exit_code)),
    #(msgpack.StringValue("timed_out"), msgpack.BoolValue(timed_out)),
    #(msgpack.StringValue("stderr"), msgpack.StringValue(stderr)),
  ])
}

fn bytes(text: String) -> Int {
  bit_array.byte_size(bit_array.from_string(text))
}

pub fn the_command_is_the_argv_joined_with_spaces_test() {
  assert proc_failure.command_text(argv(["git", "log", "--format", "%h %s"]))
    == Some("git log --format %h %s")
}

pub fn arguments_without_a_string_argv_have_no_command_test() {
  assert proc_failure.command_text(msgpack.NilValue) == None
  assert proc_failure.command_text(argv([])) == None
}

pub fn a_long_command_is_cut_on_a_character_boundary_test() {
  // The 157 bytes left for text after the ellipsis end inside an "é", so the
  // cut backs off one byte: 156 bytes of text plus 3 for the ellipsis.
  let long = string.repeat("é", 200)
  let assert Some(text) = proc_failure.command_text(argv([long]))
  assert text == string.repeat("é", 78) <> "…"
  assert bytes(text) == 159

  // A leading byte moves the boundary onto the cut, so the limit is filled.
  let assert Some(text) = proc_failure.command_text(argv(["a" <> long]))
  assert text == "a" <> string.repeat("é", 78) <> "…"
  assert bytes(text) == proc_failure.max_command_bytes
}

pub fn a_short_command_is_not_cut_test() {
  assert proc_failure.cut_head("abc", 3) == "abc"
  assert proc_failure.cut_head("abcdef", 5) == "ab…"
}

pub fn a_nonzero_exit_makes_a_record_test() {
  assert proc_failure.from_reply("git log", reply(128, False, "fatal: x\n"))
    == Some(ProcFailure("git log", 128, Exited, "fatal: x"))
}

pub fn a_timeout_makes_a_record_even_with_exit_zero_test() {
  assert proc_failure.from_reply("sleep 9", reply(0, True, ""))
    == Some(ProcFailure("sleep 9", 0, TimedOut, ""))
}

pub fn a_clean_exit_makes_no_record_test() {
  assert proc_failure.from_reply("true", reply(0, False, "warning")) == None
}

pub fn a_reply_that_is_not_an_output_makes_no_record_test() {
  assert proc_failure.from_reply("x", msgpack.NilValue) == None
  assert proc_failure.from_reply("x", msgpack.MapValue([])) == None
}

pub fn a_long_stderr_keeps_its_end_within_the_limit_test() {
  let stderr = string.repeat("a", 1000) <> "THE END"
  let assert Some(failure) =
    proc_failure.from_reply("x", reply(1, False, stderr))
  assert bytes(failure.stderr_tail) == proc_failure.max_stderr_bytes
  assert string.starts_with(failure.stderr_tail, "…")
  assert string.ends_with(failure.stderr_tail, "THE END")
}

pub fn the_stderr_cut_lands_on_a_character_boundary_test() {
  // 1000 bytes; the 397-byte suffix starts inside an "é", so the cut moves
  // forward one byte: 396 bytes of text plus 3 for the ellipsis.
  let stderr = string.repeat("é", 500)
  let assert Some(failure) =
    proc_failure.from_reply("x", reply(1, False, stderr))
  assert failure.stderr_tail == "…" <> string.repeat("é", 198)
  assert bytes(failure.stderr_tail) == 399

  // With a trailing byte the suffix starts on a boundary and fills the limit.
  let assert Some(failure) =
    proc_failure.from_reply("x", reply(1, False, stderr <> "a"))
  assert failure.stderr_tail == "…" <> string.repeat("é", 198) <> "a"
  assert bytes(failure.stderr_tail) == proc_failure.max_stderr_bytes
}

pub fn stderr_is_trimmed_before_it_is_cut_test() {
  assert proc_failure.cut_tail("abcdef", 5) == "…ef"
  let assert Some(failure) =
    proc_failure.from_reply("x", reply(1, False, "  boom \n\n"))
  assert failure.stderr_tail == "boom"
}

pub fn the_line_names_the_command_status_and_stderr_test() {
  assert proc_failure.line(ProcFailure("git log", 128, Exited, "fatal: x"))
    == "last failing command: `git log` exited 128: fatal: x"
  assert proc_failure.line(ProcFailure("sleep 9", 0, TimedOut, ""))
    == "last failing command: `sleep 9` timed out"
}

pub fn multi_line_stderr_stays_on_one_line_test() {
  assert proc_failure.line(ProcFailure("c", 2, Exited, "one\n\n two \nthree"))
    == "last failing command: `c` exited 2: one | two | three"
}
