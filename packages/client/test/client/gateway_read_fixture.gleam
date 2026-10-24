//// A read-only gateway over a supplied fixture store, shared by regression
//// tests and the matched SQLite benchmark. Runtime effects remain parked;
//// only the gateway's real prime and hint pulls touch the supplied
//// store. The auxiliary runtime is retired explicitly after each trial.

import client/gateway
import client/gateway_test
import core/clock
import core/ids
import gleam/erlang/process
import gleam/int
import machine/strand
import runtime/api
import session/session
import support/addresses
import weft/registry as address

/// The exact options measured by both versions and their auxiliary cleanup.
pub type Fixture {
  Fixture(options: gateway.Options, retire: fn() -> Nil)
}

/// Seeds idle strands in a real store and prepares read-only gateway options.
///
/// ## Examples
///
/// ```gleam
/// // let fixture = gateway_read_fixture.open(store, 128)
/// ```
pub fn open(store: session.Session, count: Int) -> Fixture {
  int.range(from: 1, to: count + 1, with: Nil, run: fn(_, index) {
    let assert Ok(Nil) =
      session.ensure_strand(
        store,
        "strand-" <> int.to_string(index),
        configuration(),
      )
      as "the fixture strand is seeded"
    Nil
  })
  let id = ids.mint_session(ids.generator(clock.fixed(1000), 3091)).0
  let harness = gateway_test.reserved_fixture(id)
  let runtime = api.Runtime(..harness.runtime, session: store)
  Fixture(gateway.default_options("gateway-read-fixture", runtime), fn() {
    let assert Ok(Nil) = api.close(harness.runtime)
      as "the auxiliary runtime closes"
    let assert Ok(subject) = address.lookup(harness.hub.name)
      as "the auxiliary gateway still owns its name"
    let assert Ok(pid) = process.subject_owner(subject)
      as "the auxiliary subject has an owner"
    process.unlink(pid)
    process.kill(pid)
    process.unlink(harness.commits)
    process.kill(harness.commits)
  })
}

fn configuration() -> strand.StrandConfiguration {
  strand.StrandConfiguration(
    model: strand.ModelIdentity("acme", "loom-1"),
    thinking_level: strand.ThinkingOff,
    active_tool_names: [],
  )
}

/// Pulls through the configuration hint and waits behind it on the same mailbox.
/// No profile desk is installed, so this hint cannot reopen the fixture.
///
/// ## Examples
///
/// ```gleam
/// // gateway_read_fixture.pull(hub)
/// ```
pub fn pull(hub: gateway.Gateway) -> Nil {
  let attached = gateway.attached(hub)
  assert attached > 0 as "the fixture has a barrier witness attached"
  gateway.configuration_changed(hub.name)
  assert gateway.attached(hub) == attached
    as "the same-sender pull and following mailbox barrier complete"
  Nil
}

/// Starts a candidate gateway with the prepared read-only options.
///
/// ## Examples
///
/// ```gleam
/// // let #(hub, pid) = gateway_read_fixture.start(fixture.options)
/// ```
pub fn start(options: gateway.Options) -> #(gateway.Gateway, process.Pid) {
  let name = addresses.new()
  let assert Ok(started) = gateway.start_host_fixture(options, name)
    as "the read-only fixture gateway starts"
  let hub = gateway.Gateway(name)
  let assert Ok(_) = gateway.attach(hub, fn(_) { Nil })
    as "the fixture attaches a barrier witness"
  #(hub, started.pid)
}
