//// Shared pieces of the untrusted link's tests (protocol-change/109): minted
//// certificates on disk, and a hand-driven executor end that reads and writes
//// frames over a real TLS socket, so a test can play a hostile executor
//// without the gateway's good manners.

import client/internal/ffi_pki
import client/internal/ffi_tls_stream.{type Listener, type Stream}
import client/remote/protocol
import client/remote/untrusted_codec
import client/remote/untrusted_wire
import gleam/erlang/process
import simplifile
import support/remote_fixtures as fixtures

/// One orchestrator's and one executor's credentials under one authority,
/// with each leaf's pin.
pub type Pair {
  Pair(
    orchestrator: ffi_tls_stream.Credentials,
    orchestrator_pin: BitArray,
    executor: ffi_tls_stream.Credentials,
    executor_pin: BitArray,
    /// A third leaf under the same authority, which neither side pins.
    stray: ffi_tls_stream.Credentials,
  )
}

/// Mints an authority and two leaves into a fresh scratch directory.
pub fn pair(name: String) -> Pair {
  let directory = fixtures.scratch("untrusted-" <> name)
  let #(ca, ca_key) = ffi_pki.authority("untrusted test authority")
  let #(orchestrator, orchestrator_pin) =
    leaf(directory, "orchestrator", ca, ca_key)
  let #(executor, executor_pin) = leaf(directory, "executor", ca, ca_key)
  let #(stray, _stray_pin) = leaf(directory, "stray", ca, ca_key)
  Pair(orchestrator:, orchestrator_pin:, executor:, executor_pin:, stray:)
}

/// A second authority's leaf, which chains to nothing the pair trusts.
pub fn stranger(name: String) -> #(ffi_tls_stream.Credentials, BitArray) {
  let directory = fixtures.scratch("untrusted-stranger-" <> name)
  let #(ca, ca_key) = ffi_pki.authority("a stranger's authority")
  leaf(directory, "stranger", ca, ca_key)
}

fn leaf(
  directory: String,
  name: String,
  ca: String,
  ca_key: String,
) -> #(ffi_tls_stream.Credentials, BitArray) {
  let assert Ok(#(certificate, key)) =
    ffi_pki.issue(ca, ca_key, name, ["localhost", "127.0.0.1"])
    as "the leaf is issued"
  let assert Ok(pin) = ffi_pki.pin(certificate) as "the leaf has a pin"
  let ca_path = directory <> "/" <> name <> "-ca.pem"
  let certificate_path = directory <> "/" <> name <> ".pem"
  let key_path = directory <> "/" <> name <> ".key"
  let assert Ok(Nil) = simplifile.write(ca_path, ca) as "the CA is written"
  let assert Ok(Nil) = simplifile.write(certificate_path, certificate)
    as "the leaf is written"
  let assert Ok(Nil) = simplifile.write(key_path, key) as "the key is written"
  #(
    ffi_tls_stream.Credentials(
      ca: ca_path,
      certificate: certificate_path,
      key: key_path,
    ),
    pin,
  )
}

/// A listener for a hand-driven executor, admitting `pins`.
pub fn listen(
  credentials: ffi_tls_stream.Credentials,
  pins: List(BitArray),
) -> #(Listener, Int) {
  let assert Ok(listener) =
    ffi_tls_stream.listen(
      "127.0.0.1",
      0,
      credentials,
      pins,
      untrusted_wire.max_frame_bytes,
    )
    as "the test listener starts"
  let assert Ok(port) = ffi_tls_stream.port_of(listener)
    as "the test listener has a port"
  #(listener, port)
}

/// Accepts one connection and runs its handshake in the calling process.
pub fn accept(listener: Listener) -> Stream {
  let assert Ok(raw) = ffi_tls_stream.accept(listener, 10_000)
    as "an orchestrator connects"
  let assert Ok(stream) = ffi_tls_stream.handshake(raw, 10_000)
    as "the handshake completes"
  stream
}

/// Accepts a connection, reads `hello` and answers `welcome`, as an honest
/// executor's first exchange.
pub fn greeted(listener: Listener) -> Stream {
  let stream = accept(listener)
  let assert Ok(untrusted_codec.HelloEnvelope(..)) = next(stream)
    as "the orchestrator says hello"
  send(
    stream,
    untrusted_wire.Welcome(
      wire: untrusted_wire.version,
      protocol: protocol.version,
    ),
  )
  stream
}

/// The next frame, decoded as far as its envelope.
pub fn next(stream: Stream) -> Result(untrusted_codec.Envelope, String) {
  case next_raw(stream, 5000) {
    Ok(frame) ->
      case untrusted_codec.decode_envelope(frame) {
        Ok(envelope) -> Ok(envelope)
        Error(_report) -> Error("undecodable")
      }
    Error(reason) -> Error(reason)
  }
}

/// The next frame's bytes, or why none came within `within_ms`.
pub fn next_raw(stream: Stream, within_ms: Int) -> Result(BitArray, String) {
  let assert Ok(Nil) = ffi_tls_stream.arm(stream) as "the stream is armed"
  let selector =
    process.new_selector() |> ffi_tls_stream.select(fn(inbound) { inbound })
  case process.selector_receive(selector, within_ms) {
    Ok(ffi_tls_stream.Received(frame:)) -> Ok(frame)
    Ok(ffi_tls_stream.Ended) -> Error("ended")
    Ok(ffi_tls_stream.Broken) -> Error("broken")
    Error(Nil) -> Error("silent")
  }
}

/// Drops every socket event waiting in this process's mailbox. The selector a
/// hand-driven end reads with takes any stream's events, so a stream a test
/// left armed would otherwise hand its close to the next test's first read.
pub fn flush() -> Nil {
  let selector =
    process.new_selector() |> ffi_tls_stream.select(fn(inbound) { inbound })
  case process.selector_receive(selector, 200) {
    Ok(_stale) -> flush()
    Error(Nil) -> Nil
  }
}

/// Whether the peer has closed the connection within `within_ms`.
pub fn closed(stream: Stream, within_ms: Int) -> Bool {
  case next_raw(stream, within_ms) {
    Error("ended") | Error("broken") -> True
    Ok(_frame) | Error(_other) -> False
  }
}

/// Dials a listener as an orchestrator holding `credentials`, expecting the
/// executor's leaf to hash to `pin`.
pub fn dial(
  port: Int,
  credentials: ffi_tls_stream.Credentials,
  pin: BitArray,
) -> Result(Stream, ffi_tls_stream.Failure) {
  ffi_tls_stream.connect(
    "127.0.0.1",
    port,
    credentials,
    pin,
    untrusted_wire.max_frame_bytes,
    10_000,
  )
}

/// Dials and greets as an honest orchestrator would.
pub fn hello(port: Int, pair: Pair) -> Stream {
  let assert Ok(stream) = dial(port, pair.orchestrator, pair.executor_pin)
    as "the gateway admits the orchestrator"
  send(
    stream,
    untrusted_wire.Hello(
      wire: untrusted_wire.version,
      protocol: protocol.version,
    ),
  )
  let assert Ok(untrusted_codec.WelcomeEnvelope(..)) = next(stream)
    as "the gateway welcomes the orchestrator"
  stream
}

/// Sends a frame.
pub fn send(stream: Stream, frame: untrusted_wire.Frame) -> Nil {
  send_raw(stream, untrusted_codec.encode_frame(frame))
}

/// Sends raw bytes as a frame.
pub fn send_raw(stream: Stream, bytes: BitArray) -> Nil {
  let assert Ok(Nil) = ffi_tls_stream.send(stream, bytes) as "the frame is sent"
  Nil
}
