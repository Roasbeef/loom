//// A real TLS origin server for the `broker/egress` suite.
////
//// The egress client refuses to verify anything but a chain it was
//// given roots for, and no test is allowed to relax that. So the suite
//// runs an actual `ssl` listener on loopback with a chain generated at
//// test time by `public_key:pkix_test_data/1`, and pins that chain's
//// root: the client's verification path runs for real, and the
//// untrusted-certificate case is a second, unrelated root rather than a
//// disabled check.
////
//// Backed by `broker_test_ffi.erl`; production code never uses these.

/// The server's controlling process. Opaque on this side: the only
/// things a test does with it are pass it back to `stop`.
pub type Server

/// Starts a server on an ephemeral loopback port.
///
/// Answers with the server handle, the port it bound, and the DER of the
/// root a client must pin to reach it. Two servers started in the same
/// node share a chain and differ only in port, which is what makes a
/// policy with two origins and one credential testable without a second
/// resolvable hostname.
@external(erlang, "broker_test_ffi", "egress_start")
pub fn start() -> #(Server, Int, BitArray)

/// The same server, pinned to TLS 1.2.
///
/// Session resumption is only reachable on 1.2: TLS 1.3 resumes through
/// tickets and OTP's client has those off by default, so a 1.3 origin
/// cannot exercise the abbreviated handshake at all and a test that used
/// one would pass whatever the client did. The client's own version list
/// still offers both, so 1.2 is negotiated rather than imposed.
@external(erlang, "broker_test_ffi", "egress_start_tls12")
pub fn start_tls12() -> #(Server, Int, BitArray)

/// Stops a server. Killing the owner closes the listen socket with it.
@external(erlang, "broker_test_ffi", "egress_stop")
pub fn stop(server: Server) -> Nil

/// The root of an unrelated chain, for the refusal case.
@external(erlang, "broker_test_ffi", "egress_foreign_root")
pub fn foreign_root() -> BitArray
