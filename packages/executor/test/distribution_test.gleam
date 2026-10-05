//// Boot configuration is pure until explicit start. The separate-emulator
//// probe below drives the public Gleam bootstrap on real OTP TLS distribution;
//// its rejected peers do not use a fake handshake or transport.

import executor/remote/distribution
import gleam/erlang/process
import gleam/list

fn files() -> distribution.CredentialFiles {
  distribution.CredentialFiles("/ca", "/cert", "/key", "/cookie")
}

fn pin() -> BitArray {
  <<0:size(256)>>
}

pub fn rejects_unbounded_or_foreign_names_test() {
  let assert Error(distribution.InvalidConfiguration) =
    distribution.configure("owner@127.0.0.1", [], files())
    as "Empty allowlists must refuse rather than allow every cookie holder."
  let assert Error(distribution.InvalidConfiguration) =
    distribution.configure(
      "owner@127.0.0.1",
      [#("owner@127.0.0.1", pin())],
      files(),
    )
    as "Local names cannot be configured as a remote peer."
  let assert Error(distribution.InvalidConfiguration) =
    distribution.configure(
      "owner@127.0.0.1",
      [#("peer@@127.0.0.1", pin())],
      files(),
    )
    as "Full node names must have exactly one separator."
  let assert Error(distribution.InvalidConfiguration) =
    distribution.configure(
      "owner@127.0.0.1",
      [#("peer@127.0.0.1", <<>>)],
      files(),
    )
    as "Missing pins must refuse before bootstrap."

  let peers = list.repeat(#("peer@127.0.0.1", pin()), 33)
  let assert Error(distribution.InvalidConfiguration) =
    distribution.configure("owner@127.0.0.1", peers, files())
    as "Duplicate and oversized administrative sets must refuse."
}

pub fn validates_fixed_options_and_private_paths_test() {
  let assert Ok(config) =
    distribution.configure(
      "owner@127.0.0.1",
      [#("peer@127.0.0.1", pin())],
      files(),
    )
    as "Finite administrative configuration must validate without a VM boot."
  assert distribution.protected_paths(config)
    == ["/ca", "/cert", "/key", "/cookie"]

  // A default test VM has no TLS distribution flags. It must refuse without
  // opening distribution, creating peer atoms, or exposing an endpoint.
  assert distribution.start(config) == Error(distribution.UnsafeBoot)
  let subject = process.new_subject()
  assert distribution.send(subject, "exact bytes") == distribution.Sent
  assert process.receive(subject, 100) == Ok("exact bytes")
}

@external(erlang, "executor_distribution_test_ffi", "probe")
fn probe() -> Result(Nil, Nil)

pub fn real_tls_distribution_and_rejection_controls_test() {
  let assert Ok(Nil) = probe()
    as "Real TLS BEAM peers must connect; wrong pins, identity, missing client credentials and plaintext must refuse."
}
