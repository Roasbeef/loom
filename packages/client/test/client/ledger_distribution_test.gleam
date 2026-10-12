//// The membership ledger across real emulators (protocol-change/086): the
//// anti-entropy that `ledger_service_test` runs in one VM, here over the
//// production TLS distribution with the `loom_ledger` process registered by
//// name on each node.
////
//// The scenario is in `client_distribution_fixture_ffi`, and the nodes' side
//// of it is `support/ledger_nodes`. Each child emulator is a separate OS
//// process with its own name, so the test registers nothing in this VM and
//// needs no entry in `scripts/serial-tests`.

@external(erlang, "client_distribution_fixture_ffi", "scenario")
fn scenario(name: String) -> Result(Nil, String)

pub fn a_revoke_reaches_a_node_the_origin_is_not_connected_to_test() {
  let why =
    "Three nodes pinned in a chain must converge on the origin's head, "
    <> "the far end learning of entries and of a revoke only through the "
    <> "middle node, with the far ends never connected."
  let assert Ok(Nil) = scenario("ledger_relay") as why
  Nil
}
