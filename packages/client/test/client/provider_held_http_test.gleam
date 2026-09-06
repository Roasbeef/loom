//// Narrow negative controls for the held provider's actual framing and close
//// boundaries. Pure cases pin the rejection cause; real socket cases terminate
//// immediately on malformed input, never by waiting out the provider hold.

import gleam/bit_array
import gleam/erlang/atom
import gleam/erlang/process
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleam/uri
import support/internal/ffi_daemon_socket as tcp
import support/internal/ffi_ws as socket
import support/provider_held_http as held
import support/provider_http
import weft

fn headers(length: String) -> String {
  "POST /v1/messages HTTP/1.1\r\nx-api-key: "
  <> provider_http.dummy_key
  <> "\r\nContent-Length: "
  <> length
  <> "\r\n\r\n"
}

pub fn held_provider_classifies_only_actual_socket_closure_test() {
  assert held.classify_closure(Error(atom.to_dynamic(atom.create("closed"))))
    == Ok(held.ClientClosed)
  assert held.classify_closure(Error(atom.to_dynamic(atom.create("timeout"))))
    == Ok(held.HoldExpired)
  assert held.classify_closure(
      Error(atom.to_dynamic(atom.create("econnreset"))),
    )
    == Error("unexpected held socket failure")
  assert held.classify_closure(Ok(<<>>))
    == Error("unexpected bytes on held connection")
  assert held.classify_closure(Ok(<<1>>))
    == Error("unexpected bytes on held connection")
}

pub fn held_provider_declared_length_pins_bounds_and_framing_test() {
  assert held.declared_length(headers("1")) == Ok(1)
  assert held.declared_length(headers("262144")) == Ok(262_144)
  list.each(["0", "-1", "262145"], fn(length) {
    assert held.declared_length(headers(length))
      == Error("body exceeds fixture bounds")
  })
  assert held.declared_length(headers("no")) == Error("invalid Content-Length")
  assert held.declared_length("POST /v1/messages HTTP/1.1\r\n")
    == Error("incomplete headers")
  assert held.declared_length(string.repeat("x", 8193))
    == Error("headers exceed fixture limit")
  assert held.declared_length(string.replace(headers("1"), "POST", "GET"))
    == Error("unexpected provider route")
  assert held.declared_length(string.replace(
      headers("1"),
      "Content-Length: 1",
      "broken",
    ))
    == Error("malformed header")
  assert held.declared_length(string.replace(
      headers("1"),
      provider_http.dummy_key,
      "wrong",
    ))
    == Error("invalid dummy key")
  assert held.declared_length(string.replace(
      headers("1"),
      "Content-Length: 1",
      "Transfer-Encoding: chunked",
    ))
    == Error("request transfer encoding is unsupported")
  assert held.declared_length(string.replace(
      headers("1"),
      "Content-Length: 1\r\n",
      "",
    ))
    == Error("expected one Content-Length")
  assert held.declared_length(string.replace(
      headers("1"),
      "Content-Length: 1",
      "Content-Length: 1\r\nContent-Length: 2",
    ))
    == Error("expected one Content-Length")
}

// Closing the test sender exposes actual EOF to the bounded reader. The outer
// scope must report a crash from that rejection, never deadline cancellation;
// its callback completion also proves that connection and send succeeded.
fn rejects_on_socket(bytes: String) -> Nil {
  let sent = process.new_subject()
  let outcomes =
    weft.new([
      fn() {
        held.with_server(fn(url, _witness) {
          let assert Ok(parsed) = uri.parse(url)
            as "the real listener publishes a URL"
          let assert Some(port) = parsed.port
            as "the ephemeral port is explicit"
          let assert Ok(peer) =
            tcp.connect(
              #(127, 0, 0, 1),
              port,
              [socket.Binary, socket.Active(False)],
              1000,
            )
            as "the negative request reaches the actual listening socket"
          assert tcp.send(peer, bit_array.from_string(bytes)) == Ok(Nil)
          let _ = socket.tcp_close(peer)
          process.send(sent, Nil)
        })
        Ok(Nil)
      },
    ])
    |> weft.deadline(5000)
    |> weft.start
  assert process.receive(sent, 1000) == Ok(Nil)
  let assert [weft.Crashed(0, _)] = outcomes
    as "malformed framing fails promptly instead of passing or exhausting the outer deadline"
  Nil
}

pub fn held_provider_rejects_actual_truncated_header_test() {
  rejects_on_socket("POST /v1/messages HTTP/1.1\r\nx-api-key:")
}

pub fn held_provider_rejects_actual_truncated_body_test() {
  rejects_on_socket(headers("20") <> "{")
}

pub fn held_provider_rejects_actual_overcap_body_declaration_test() {
  rejects_on_socket(headers("262145"))
}
