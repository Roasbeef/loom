//// Phase 0 of the membership ledger (docs/design-notes/membership-ledger.md,
//// section 16): the TLS verify callback reads a table that changes while the
//// emulators run, and the options file that selects it names no pin.
////
//// Both tests boot real emulators with the production boot flags and the
//// production `start`, and connect them over real TLS distribution, because a
//// stand-in for the handshake would not exercise the callback that is the
//// trust boundary. The scenarios live in `client_ledger_spike_fixture_ffi`.

@external(erlang, "client_ledger_spike_fixture_ffi", "scenario")
fn scenario(name: String) -> Result(Nil, String)

fn proves(name: String, why: String) {
  let assert Ok(Nil) = scenario(name) as why
  Nil
}

pub fn a_pin_changed_at_runtime_takes_effect_on_the_next_handshake_test() {
  proves(
    "live_pins",
    "A pin published while both emulators run must be accepted, a pin "
      <> "removed must leave the connection up until it is disconnected and "
      <> "then be refused, and a dead table owner must close the node.",
  )
}

pub fn a_pin_less_options_file_passes_the_boot_check_test() {
  proves(
    "options_boot_check",
    "The live options file must name no pin, pass the boot check in live "
      <> "mode, and be refused by the other mode and when others can write it.",
  )
}
