//// Test-side FFI (spec §0.2 confinement, mirroring the conformance
//// package's test support): the minimal websocket probe the boot smoke
//// test uses to witness a real upgrade and a real frame round trip.

/// Dials `host:port`, upgrades `/v1/ws` with the bearer token, sends
/// one text frame, and returns the first text frame the server sends
/// back. Erlang `gen_tcp`/`crypto` in `client_test_ffi` — a socket
/// probe has no pure alternative, and using a client library would
/// hide the handshake the test exists to witness.
@external(erlang, "client_test_ffi", "ws_roundtrip")
pub fn ws_roundtrip(
  host: String,
  port: Int,
  token: String,
  text: String,
) -> Result(String, String)
