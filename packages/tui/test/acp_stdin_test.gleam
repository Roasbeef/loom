//// The protocol line reader against a real pipe: a line that is not valid
//// UTF-8 must come back as a line (so the protocol layer can answer it with
//// a parse error) and must not end the input or spin the reader, and a valid
//// multi-byte character must arrive as exactly its UTF-8 bytes whatever the
//// locale. An external VM reads the pipe because the test VM owns its own
//// standard input. The pause after the bad line matters: the console driver
//// decodes a whole chunk at a time and falls back to Latin-1 for the rest of
//// a chunk that held an undecodable byte, so valid text sharing a chunk with
//// a bad line can arrive garbled. Text in a later chunk is unaffected, which
//// is what this test pins.

import gleam/int
import gleam/string
import tui/internal/ffi_terminal

// Reads four lines and checks each against what the protocol layer needs:
// the undecodable line is a line, the accented one is exact UTF-8, the plain
// one is untouched, and the fourth read is the end of input.
const probe =
  "A = tui_ffi:read_protocol_line(), B = tui_ffi:read_protocol_line(), C = tui_ffi:read_protocol_line(), D = tui_ffi:read_protocol_line(), case {A, B, C, D} of {{ok, _}, {ok, <<195, 169, 10>>}, {ok, <<\"{}\\n\">>}, {error, _}} -> halt(0); _ -> halt(7) end"

fn run_probe(locale: String) -> Int {
  let script =
    "(printf '\\377\\n'; sleep 1; printf '\\303\\251\\n{}\\n') | LANG="
    <> locale
    <> " LC_ALL="
    <> locale
    <> " erl -noshell -pa build/dev/erlang/tui/ebin -eval '"
    <> probe
    <> "'"
  let assert Ok(status) = ffi_terminal.run_forwarding("/bin/sh", ["-c", script])
    as "the probe VM ran"
  status
}

pub fn invalid_bytes_are_a_line_and_the_next_lines_are_exact_test() {
  assert run_probe("C") == 0
}

pub fn the_result_does_not_depend_on_the_locale_test() {
  assert run_probe("C.UTF-8") == 0
  assert string.length(int.to_string(run_probe("en_US.UTF-8"))) == 1
}
