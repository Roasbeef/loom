//// Ledger mode across real emulators (protocol-change/086): a deployment whose
//// only source of trust is a signed ledger, with the production TLS flags, the
//// production PKI and the daemon's own boot.
////
//// Each test boots separate OS processes that connect over real TLS
//// distribution, because a stand-in for the handshake would not exercise the
//// verify callback that reads the published table. The scenarios are in
//// `client_ledger_live_fixture_ffi` and the nodes' side of them is
//// `support/ledger_live`. A child registers its names in its own emulator, so
//// these tests register nothing in this VM and need no entry in
//// `scripts/serial-tests`.

@external(erlang, "client_ledger_live_fixture_ffi", "scenario")
fn scenario(name: String) -> Result(Nil, String)

fn proves(name: String, why: String) {
  let assert Ok(Nil) = scenario(name) as why
  Nil
}

pub fn nodes_boot_from_ledgers_and_connect_along_links_only_test() {
  proves(
    "links_only",
    "Three nodes with no peer in any configuration must boot from their "
      <> "ledgers, the orchestrator must reach both linked executors without "
      <> "being told to, and the two unlinked executors must be refused by "
      <> "the handshake even when the allow list permits the name.",
  )
}

pub fn a_member_enrolled_while_nodes_run_connects_without_a_restart_test() {
  proves(
    "enroll_without_restart",
    "A node whose ledger holds its own entry must be refused until the "
      <> "others hold the entry, then connect to both linked peers with no "
      <> "restart, the entry having reached the second peer through the first.",
  )
}

pub fn a_revoke_drops_the_connections_of_every_linked_node_test() {
  proves(
    "revoke_drops_connections",
    "A revoke applied at one node must drop that node's connection to the "
      <> "revoked member, reach the other linked node through the remaining "
      <> "connection so it drops its own, and leave the revoked member "
      <> "refused when it reconnects.",
  )
}

pub fn a_handshake_that_read_the_old_table_ends_at_its_node_up_test() {
  proves(
    "node_up_after_publish",
    "A handshake accepted on the old row while the ledger process was held "
      <> "applying a revoke must be disconnected by the node-up check alone "
      <> "once the process is let go, with the sweep of the entry left out.",
  )
}
