//// The transport seam: the pure UTF-8 chunk splitter, and the
//// port-backed production transport against real child processes.
////
//// The real-port tests are feature-detected: on a host without the
//// spawned binary they print a loud SKIP line instead of failing, the
//// same pattern as codemode's jailed e2e suite. `/bin/echo`, `/bin/cat`
//// and `/bin/sh` are the children — tiny, universal, and enough to
//// prove the port FFI writes, reads, delivers the exit, and threads
//// argv, env and the working directory. A real MCP fixture server is
//// another slice's work.

import gleam/bit_array
import gleam/erlang/process
import gleam/io
import gleam/string
import mcp/client
import mcp/transport

// --- utf8_prefix ------------------------------------------------------------

pub fn utf8_prefix_passes_a_whole_valid_chunk_test() {
  assert transport.utf8_prefix(<<"hello":utf8>>) == Ok(#("hello", <<>>))
}

pub fn utf8_prefix_passes_an_empty_chunk_test() {
  assert transport.utf8_prefix(<<>>) == Ok(#("", <<>>))
}

pub fn utf8_prefix_holds_a_split_two_byte_character_test() {
  // "é" is <<0xc3, 0xa9>>; a chunk ending after the lead byte holds it.
  assert transport.utf8_prefix(<<"a":utf8, 0xc3>>) == Ok(#("a", <<0xc3>>))
}

pub fn utf8_prefix_holds_a_split_four_byte_character_test() {
  // A four-byte character missing its last byte leaves three behind —
  // the most `max_held_tail_bytes` promises to hold.
  assert transport.utf8_prefix(<<0xf0, 0x9f, 0x98>>)
    == Ok(#("", <<0xf0, 0x9f, 0x98>>))
}

pub fn utf8_prefix_reassembles_across_a_join_test() {
  let assert Ok(#("a", tail)) = transport.utf8_prefix(<<"a":utf8, 0xc3>>)
  assert transport.utf8_prefix(bit_array.append(tail, <<0xa9, "b":utf8>>))
    == Ok(#("éb", <<>>))
}

pub fn utf8_prefix_refuses_bytes_that_are_not_utf8_test() {
  // 0xff can begin no UTF-8 sequence: not a truncated tail, a fault.
  assert transport.utf8_prefix(<<0xff, 0xfe, "abc":utf8>>) == Error(Nil)
}

// --- the real port ----------------------------------------------------------

fn open_for_test(
  spawn: transport.Spawn,
) -> Result(
  #(transport.Connection, process.Selector(transport.TransportEvent)),
  String,
) {
  let inbound = process.new_subject()
  let base =
    process.new_selector()
    |> process.select(inbound)
  transport.open(transport.PortTransport(spawn:), inbound, base, fn(event) {
    event
  })
}

// Gathers output until the child closes (or the wait lapses), returning
// the bytes and whether the close arrived.
fn drain(
  selector: process.Selector(transport.TransportEvent),
  acc: BitArray,
) -> #(BitArray, Bool) {
  case process.selector_receive(selector, 5000) {
    Ok(transport.TransportData(bytes:)) ->
      drain(selector, bit_array.append(acc, bytes))
    Ok(transport.TransportClosed(..)) -> #(acc, True)
    Error(Nil) -> #(acc, False)
  }
}

// Gathers output until it contains a newline — enough for one echoed
// line from a child that stays alive.
fn receive_line(
  selector: process.Selector(transport.TransportEvent),
  acc: String,
) -> String {
  case string.contains(acc, "\n") {
    True -> acc
    False ->
      case process.selector_receive(selector, 5000) {
        Ok(transport.TransportData(bytes:)) ->
          case bit_array.to_string(bytes) {
            Ok(text) -> receive_line(selector, acc <> text)
            Error(Nil) -> panic as "the child wrote bytes that are not utf-8"
          }
        Ok(transport.TransportClosed(reason:)) ->
          panic as { "the child closed early: " <> reason }
        Error(Nil) -> panic as "the child wrote nothing within the wait"
      }
  }
}

pub fn a_real_childs_output_and_exit_arrive_as_events_test() {
  case open_for_test(transport.spawn("/bin/echo", ["hi"])) {
    Error(reason) ->
      io.println("SKIP a_real_childs_output_and_exit: " <> reason)
    Ok(#(connection, selector)) -> {
      let #(bytes, closed) = drain(selector, <<>>)
      assert bytes == <<"hi\n":utf8>>
      assert closed
      connection.close()
    }
  }
}

pub fn a_line_written_to_a_real_child_comes_back_test() {
  // cat is the echo transport: a line written to its stdin is a line
  // read from its stdout, proving the port writes and reads for real.
  case open_for_test(transport.spawn("/bin/cat", [])) {
    Error(reason) ->
      io.println("SKIP a_line_written_to_a_real_child: " <> reason)
    Ok(#(connection, selector)) -> {
      let assert Ok(Nil) = connection.send("{\"ping\":1}\n")
      assert receive_line(selector, "") == "{\"ping\":1}\n"
      connection.close()
    }
  }
}

pub fn env_and_directory_reach_a_real_child_test() {
  let spawn =
    transport.spawn("/bin/sh", [
      "-c",
      "printf '%s %s\\n' \"$PWD\" \"$LOOM_MCP_PROBE\"",
    ])
    |> transport.with_env([#("LOOM_MCP_PROBE", "probe-value")])
    |> transport.in_directory("/")
  case open_for_test(spawn) {
    Error(reason) -> io.println("SKIP env_and_directory: " <> reason)
    Ok(#(connection, selector)) -> {
      let #(bytes, closed) = drain(selector, <<>>)
      assert bytes == <<"/ probe-value\n":utf8>>
      assert closed
      connection.close()
    }
  }
}

pub fn the_client_over_a_real_port_answers_method_not_found_test() {
  // cat echoes the client's own initialize request straight back, which
  // decodes as a server-initiated request; the client answers it -32601;
  // cat echoes that answer back too, and — carrying the same id as the
  // in-flight initialize — it settles the handshake as a ServerError.
  // One refusal proving write → child → read → decode → -32601 answer →
  // correlate, end to end over a real pipe.
  let outcome =
    client.start(
      transport.PortTransport(spawn: transport.spawn("/bin/cat", [])),
      client.options("0.1.0") |> client.with_handshake_timeout(5000),
    )
  case outcome {
    Error(client.TransportFailed(reason:)) ->
      io.println("SKIP the_client_over_a_real_port: " <> reason)
    Error(client.HandshakeFailed(error: client.ServerError(code:, ..))) -> {
      assert code == client.method_not_found_code
    }
    Error(_) -> panic as "expected the echoed method-not-found refusal"
    Ok(connected) -> {
      client.stop(connected)
      panic as "an echo child should never complete the handshake"
    }
  }
}
