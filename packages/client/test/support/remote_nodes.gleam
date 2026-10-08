//// The two halves of a remote tool call across real emulators.
////
//// `client_distribution_fixture_ffi` boots one emulator per node with the
//// production TLS distribution flags, and its roles call into this module.
//// The executor role starts the real host over a fake workspace plane and
//// registers a probe so the orchestrator can count how many times the fake
//// tool ran. The orchestrator role attaches a real surface, runs a call, and
//// loses the connection while the call is in flight, because a connection that
//// is dropped on a real network is the only way to show that a re-sent `Run`
//// reaches a host that already holds the call.
////
//// The scenarios differ in how long the connection stays down. A short outage
//// is repaired while the tool is still running, so the re-sent `Run` joins the
//// live call. A long one outlasts the tool, so the outcome waits in the ledger
//// and the re-sent `Run` is answered from the stored row. Both must produce the
//// outcome exactly once and run the tool exactly once.

import client/distribution
import client/escalate
import client/internal/ffi_remote
import client/owner_services
import client/remote/address
import client/remote/host
import client/remote/owner_port
import client/remote/protocol
import client/remote/surface
import core/clock
import gleam/erlang/node.{type Node}
import gleam/erlang/process.{type Name}
import gleam/list
import gleam/result
import gleam/string
import runtime/effects
import storage/exec_ledger
import support/remote_fixtures as fixtures

/// What the executor role keeps until it is asked to verify.
pub type HostHandle {
  HostHandle(probe: fixtures.Probe)
}

@external(erlang, "erlang", "disconnect_node")
fn disconnect_node(node: Node) -> Bool

fn probe_name() -> Name(fixtures.ProbeMessage) {
  ffi_remote.fixed_name("loom_remote_probe")
}

/// The executor role: a host over a ledger in `directory`, whose fake tool
/// finishes `hold_ms` milliseconds after it starts. `asks` is `"owner"` for a
/// tool that asks its owner to decide a refusal first and `"nothing"` otherwise.
pub fn host(
  directory: String,
  asks: String,
  hold_ms: Int,
) -> Result(HostHandle, String) {
  let probe = fixtures.named_probe(fixtures.Held, probe_name())
  let mode = case asks {
    "owner" -> fixtures.AsksOwner
    _ -> fixtures.AsksNothing
  }
  let config =
    host.Config(
      name: address.default(),
      ledger_path: directory <> "/ledger.db",
      limits: exec_ledger.default_limits(),
      max_result_bytes: 65_536,
      clock: clock.fixed(at: 1000),
      factory: fixtures.factory(probe, mode, protocol.AllRetired),
    )
  use _started <- result.try(
    host.start(config) |> result.map_error(string.inspect),
  )

  // The tool is released a fixed time after it starts, by the executor itself,
  // so it finishes whether or not the orchestrator is connected.
  let _releaser =
    process.spawn_unlinked(fn() {
      let _started = fixtures.eventually(fn() { fixtures.runs(probe) != [] })
      process.sleep(hold_ms)
      fixtures.release(probe)
    })
  Ok(HostHandle(probe:))
}

/// The executor role's last word: the fake tool ran exactly once.
pub fn verify_host(handle: HostHandle) -> Result(Nil, String) {
  case list.length(fixtures.runs(handle.probe)) {
    1 -> Ok(Nil)
    other ->
      Error(
        "the executor ran the tool "
        <> string.inspect(other)
        <> " times, not once",
      )
  }
}

/// The orchestrator role. `scenario` is `"run"` for an undisturbed call that
/// round-trips an owner callback, `"short_outage"` for a connection that drops
/// and is repaired while the tool runs, and `"long_outage"` for one that stays
/// down until the tool has finished.
pub fn orchestrate(
  peer: distribution.Peer,
  scenario: String,
) -> Result(Nil, String) {
  let target = distribution.node(peer)
  let reconnect = case scenario {
    "long_outage" -> fn() {
      process.sleep(2500)
      reconnect_to(peer)
    }
    _ -> fn() { reconnect_to(peer) }
  }
  use port <- result.try(
    owner_port.start(owner_port.Config(
      services: owner_services.OwnerServices(
        ..fixtures.quiet_services(),
        escalate: fn(_refused: escalate.Refused) { escalate.Settle },
      ),
      clock: clock.fixed(at: 1000),
      settled: fn(_key) { False },
      reconcile_every_ms: 60_000,
    )),
  )
  use attachment <- result.try(
    surface.attach(surface.Config(
      address: address.Address(node: target, name: address.default()),
      session: "s1",
      workspace: "/work",
      incarnation: 0,
      port:,
      read_authority: fn(_run) { Ok(fixtures.authority()) },
      reconnect:,
      remote_tools: ["bash"],
      attach_within_ms: 10_000,
      mint_token: surface.strong_token,
    ))
    |> result.map_error(protocol.describe),
  )
  let remote = attachment.surface
  let run = fixtures.tool_run("call_1", 0)
  let outcome = process.new_subject()
  let _caller =
    process.spawn_unlinked(fn() {
      process.send(outcome, surface.run(remote, run))
    })
  use Nil <- result.try(case scenario {
    "run" -> Ok(Nil)
    _ -> partition(target)
  })
  use finished <- result.try(
    process.receive(outcome, 30_000)
    |> result.replace_error("the call never produced an outcome"),
  )
  let expected = case scenario {
    "run" ->
      effects.ToolCompleted(
        result: fixtures.text_result(run, "settled"),
        terminate: False,
      )
    _ -> fixtures.expected_outcome(run)
  }
  use Nil <- result.try(case finished == expected {
    True -> Ok(Nil)
    False -> Error("unexpected outcome: " <> string.inspect(finished))
  })
  exactly_once(peer, target)
}

fn reconnect_to(peer: distribution.Peer) -> Result(Nil, String) {
  distribution.connect(peer, 5000)
  |> result.map_error(distribution.describe)
}

// Waits for the executor's tool to start, then drops the connection under it.
fn partition(target: Node) -> Result(Nil, String) {
  let started =
    fixtures.eventually(fn() {
      executor_runs(target) |> result.unwrap([]) != []
    })
  case started {
    False -> Error("the tool never started on the executor")
    True -> {
      let _dropped = disconnect_node(target)
      Ok(Nil)
    }
  }
}

// Asks the executor's probe what the fake tool did, over whatever connection
// exists now.
fn executor_runs(target: Node) -> Result(List(#(process.Pid, String)), String) {
  let reply = process.new_subject()
  ffi_remote.send(to: target, name: probe_name(), message: fixtures.Runs(reply))
  process.receive(reply, 1000)
  |> result.replace_error("the executor's probe did not answer")
}

// After the outcome is in hand, the connection is repaired if it is still down,
// and the executor's probe is asked how many times the tool ran.
fn exactly_once(peer: distribution.Peer, target: Node) -> Result(Nil, String) {
  use Nil <- result.try(reconnect_to(peer))
  use runs <- result.try(executor_runs(target))
  case list.map(runs, fn(entry) { entry.1 }) {
    ["call_1"] -> Ok(Nil)
    other ->
      Error("the executor ran " <> string.inspect(other) <> ", not call_1 once")
  }
}
