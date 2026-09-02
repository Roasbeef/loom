//// A real TLS origin on loopback, for the extension egress end-to-end.
////
//// `broker/egress` refuses anything but `https` and verifies every chain
//// against the policy's own roots, and no test is allowed to relax
//// either. So this is an actual `ssl` listener with a chain generated at
//// test time, whose root the test pins through `egress.PinnedRoots`: the
//// client's verification path runs for real, and the production policy's
//// `SystemRoots` is the only difference.
////
//// One route, `/get`, answering a fixed body that does **not** echo the
//// request. That is the point rather than a simplification. The
//// end-to-end asserts two things at once — that the injected credential
//// reached the origin, and that its value appears in no frame on the
//// capability channel — and an origin that echoed its headers back would
//// put the value in the response body and defeat the second. What the
//// origin saw comes back through `seen`, out of band, having crossed no
//// jail and no channel.
////
//// `packages/broker` has a listener of its own for the `egress` suite.
//// The duplication is deliberate: a test module inside a package is a
//// module *of* that package, so neither suite can import the other's.
////
//// Backed by `client_test_ffi.erl`; production code never uses any of
//// this.

/// The server's controlling process. Opaque on this side: the only
/// things a test does with it are read `seen` and `stop` it.
pub type Server

/// Starts a server on an ephemeral loopback port.
///
/// Answers with the server handle, the port it bound, and the DER of the
/// root a client must pin to reach it.
@external(erlang, "client_test_ffi", "origin_start")
pub fn start() -> #(Server, Int, BitArray)

/// Stops a server. Killing the owner closes the listen socket with it.
@external(erlang, "client_test_ffi", "origin_stop")
pub fn stop(server: Server) -> Nil

/// The headers of every request this origin has answered, newest first:
/// one inner list per request, each entry a lowercased `name: value`
/// line.
@external(erlang, "client_test_ffi", "origin_seen")
pub fn seen(server: Server) -> List(List(String))
