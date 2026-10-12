//// Phase 0 of the membership ledger (docs/design-notes/membership-ledger.md,
//// section 16): what `net_kernel:allow/1` does when a node calls it again and
//// again as members are enrolled. The scenario boots three real emulators
//// with the production TLS flags; see `client_ledger_spike_fixture_ffi`.

@external(erlang, "client_ledger_spike_fixture_ffi", "scenario")
fn scenario(name: String) -> Result(Nil, String)

pub fn the_allow_list_only_grows_and_refuses_after_tls_test() {
  let assert Ok(Nil) = scenario("allow_list")
    as "allow/1 must add names, ignore repeats and refuse a bad list whole, and must refuse an unlisted name after TLS accepted its pin."
  Nil
}
