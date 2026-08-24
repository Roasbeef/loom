//// Test entry point for the client package. The suites live under
//// `test/client/`: golden-fixture protocol conformance, the grant
//// bridge, the gateway's protocol conduct, the websocket transport,
//// and the protocol-driven M3 acceptance demo.

import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}
