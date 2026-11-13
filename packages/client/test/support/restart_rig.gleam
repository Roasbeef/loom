//// A real executor host, its ledger and an owner port in one VM, with the host
//// restartable under the same name.
////
//// An executor that restarts keeps its ledger on the state disk, keeps its node
//// name, and loses every workspace plane, which is memory. This rig reproduces
//// that without a VM: `restart` ends the host and starts a new one over the same
//// ledger file, registered under the same name, so an address an orchestrator
//// already holds reaches it. The fake plane factory is the same one the first
//// host used, so a call run before the restart and a call run after it are
//// counted by the one probe.
////
//// The surface tests and the restart model share it, so the two read the same
//// executor.

import client/remote/address
import client/remote/host
import client/remote/owner_port
import client/remote/protocol
import client/remote/surface
import core/clock
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/option
import support/remote_fixtures as fixtures

/// The executor host that is running now, and what a test needs to reach it.
pub type Rig {
  Rig(
    /// The running host.
    host_pid: process.Pid,
    /// Where an orchestrator reaches the host. It names the host, not its pid,
    /// so it survives a restart.
    address: address.Address(protocol.HostMessage(String)),
    /// The probe every plane the rig builds reports to.
    probe: fixtures.Probe,
    /// The session's owner port, which the executor calls back.
    port: owner_port.Port,
    /// The ledger file the host opens.
    path: String,
    /// The host's configuration, so a restart can start the same host again.
    host_config: host.Config(String),
  )
}

/// Starts a host over a fresh ledger, and an owner port beside it.
///
/// `scratch` names the scratch directory, which must be unique to the test
/// module.
///
/// ## Examples
///
/// ```gleam
/// // let rig = restart_rig.rig("surface", fixtures.Open, fixtures.AsksNothing)
/// ```
pub fn rig(scratch: String, gate: fixtures.Gate, asks: fixtures.Asks) -> Rig {
  let probe = fixtures.probe(gate)
  let path = fixtures.scratch(scratch) <> "/ledger.db"
  let factory = fixtures.factory(probe, asks, protocol.AllRetired)
  let config = fixtures.host_config(path, factory)
  let assert Ok(started) = host.start(config) as "the host starts"
  let assert Ok(port) =
    owner_port.start(owner_port.Config(
      services: fixtures.quiet_services(),
      clock: clock.fixed(at: 1000),
      settled: fn(_key) { False },
      reconcile_every_ms: 60_000,
      executions: owner_port.no_executions(),
      mcp: protocol.empty_mcp_plan(),
      git_identity: option.None,
    ))
    as "the port starts"
  Rig(
    host_pid: started.pid,
    address: started.data,
    probe:,
    port:,
    path:,
    host_config: config,
  )
}

/// Ends the host and starts a new one over the same ledger, registered under
/// the same name. The new host holds no plane, as after a restart of the VM.
/// `factory` is what the new host builds its planes with.
///
/// ## Examples
///
/// ```gleam
/// // let restarted = restart_rig.restart(rig, restart_rig.healthy(rig))
/// ```
pub fn restart(rig: Rig, factory: host.PlaneFactory(String)) -> Rig {
  let ended = process.monitor(rig.host_pid)
  process.unlink(rig.host_pid)
  process.kill(rig.host_pid)

  // The name is free only once the old host is gone.
  let _down =
    process.new_selector()
    |> process.select_specific_monitor(ended, fn(_down) { Nil })
    |> process.selector_receive(5000)
  let config = host.Config(..rig.host_config, factory:)
  let assert Ok(started) = host.start(config) as "the restarted host starts"
  Rig(..rig, host_pid: started.pid, address: started.data, host_config: config)
}

/// The factory the first host was built with, for a restart after which the
/// executor can build a plane again.
pub fn healthy(rig: Rig) -> host.PlaneFactory(String) {
  fixtures.factory(rig.probe, fixtures.AsksNothing, protocol.AllRetired)
}

/// The text a broken factory fails with, so a test can find it in the refusal.
pub const broken_reason = "the toolchain is gone"

/// A factory that cannot build a plane, for a restart after which the executor
/// cannot serve the scope.
pub fn broken() -> host.PlaneFactory(String) {
  fn(_spec: host.AttachSpec) { Error(host.NoPlaneBuilt(broken_reason)) }
}

/// Ends the host.
pub fn stop(rig: Rig) -> Nil {
  process.unlink(rig.host_pid)
  process.kill(rig.host_pid)
}

/// The surface's configuration for session `s1`, minting the token
/// `token-<n>`.
///
/// ## Examples
///
/// ```gleam
/// // surface.attach(restart_rig.config(rig, 1))
/// ```
pub fn config(rig: Rig, token_n: Int) -> surface.Config(String) {
  surface.Config(
    address: rig.address,
    session: "s1",
    workspace: "/work",
    incarnation: 0,
    port: rig.port,
    read_authority: fn(_run) { Ok(fixtures.authority()) },
    reconnect: fn() { Ok(Nil) },
    remote_tools: ["bash"],
    attach_within_ms: 2000,
    mint_token: fn() {
      bit_array.from_string("token-" <> int.to_string(token_n))
    },
    attached: fn(_attached) { Nil },
  )
}

/// A surface attached with the token `token-<n>`.
///
/// ## Examples
///
/// ```gleam
/// // let remote = restart_rig.attached(rig, 1)
/// ```
pub fn attached(rig: Rig, token_n: Int) -> surface.Surface(String) {
  let assert Ok(surface.Attachment(surface:, ..)) =
    surface.attach(config(rig, token_n))
    as "the attach succeeds"
  surface
}
