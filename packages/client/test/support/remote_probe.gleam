//// The probe: a third distribution member, run as a throwaway emulator, that
//// asks the shipped daemons what they are connected to.
////
//// A shipped orchestrator and executor start TLS distribution and then wait.
//// Nothing in either VM dials a peer yet, and the test VM cannot join their
//// cluster, because it was not booted for distribution and other suites in
//// it must stay non-distributed. So the fixture lists one more node in each
//// daemon's `[[distribution.peers]]`, and this module is that node. It is
//// started by `support/remote_daemons.run_probe` with the same boot flags a
//// daemon gets, reads its own `[distribution]` table, and then runs the steps
//// a file lists, one per line:
////
////   connect NODE    connect to a configured peer, as a daemon would
////   dial A B        have the already-connected node A connect to node B
////   hidden NODE     list the hidden nodes the connected node NODE sees
////
//// Each step prints one `RESULT` line that the parent reads back, and the
//// emulator ends with `PROBE_COMPLETE` and status zero only after every step
//// ran. `dial` is the observable that matters for the distributed runtime:
//// it makes the orchestrator open the connection to the executor with the
//// orchestrator's own certificate and pins, which is what a later slice has
//// the orchestrator do by itself. The probe carries full privileges over any
//// node that lists it, which is why it exists only in tests and why a
//// daemon's configuration lists it only in a fixture's temporary directory.

import client/distribution
import gleam/erlang/atom
import gleam/erlang/node.{type Node}
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/option.{Some}
import gleam/string
import simplifile
import support/internal/ffi_probe

// How long a single connection attempt or remote call may take. The daemons
// are already listening when the probe starts, so this is a bound on a
// refused handshake rather than on a slow boot.
const step_ms = 15_000

// The whole emulator is finite. A probe that is wedged by a bug in a step
// ends itself instead of holding its node name in epmd.
const lifetime_ms = 60_000

/// The probe's entry point, called from the emulator's `-eval`.
///
/// `config_path` names the probe's own `loom.toml`, whose `[distribution]`
/// table the probe starts from, and `steps_path` the file of steps.
///
/// ## Examples
///
/// ```gleam
/// // erl ... -eval 'support@remote_probe:main(<<"probe.toml">>, <<"steps">>).'
/// ```
pub fn main(config_path: String, steps_path: String) -> Nil {
  let _watchdog =
    process.spawn_unlinked(fn() {
      process.sleep(lifetime_ms)
      ffi_probe.halt(3)
    })
  let assert Ok(text) = simplifile.read(config_path)
    as "the probe reads its own configuration"
  let assert Ok(Some(config)) = distribution.parse(text)
    as "the probe configuration has a [distribution] table"
  let assert Ok(membership) = distribution.start(config)
    as "the probe emulator was booted for distribution"
  let assert Ok(steps) = simplifile.read(steps_path)
    as "the probe reads its steps"
  steps
  |> string.split("\n")
  |> list.filter(fn(line) { line != "" })
  |> list.each(fn(line) { step(membership, line) })
  io.println("PROBE_COMPLETE")
  ffi_probe.halt(0)
}

fn step(membership: distribution.Membership, line: String) -> Nil {
  case string.split(line, " ") {
    ["connect", name] -> {
      let peer = configured(membership, name)
      case distribution.connect(peer, step_ms) {
        Ok(Nil) -> io.println("RESULT connect " <> name <> " connected")
        Error(_) -> io.println("RESULT connect " <> name <> " refused")
      }
    }

    ["dial", origin, target] -> {
      let reached =
        ffi_probe.dial(
          node_of(membership, origin),
          node_of(membership, target),
          step_ms,
        )
      io.println(
        "RESULT dial "
        <> origin
        <> " "
        <> target
        <> case reached {
          True -> " connected"
          False -> " refused"
        },
      )
    }

    ["hidden", name] -> {
      let seen =
        ffi_probe.hidden_nodes(node_of(membership, name), step_ms)
        |> list.map(fn(peer) { atom.to_string(node.name(peer)) })
        |> list.sort(string.compare)
      io.println("RESULT hidden " <> name <> " " <> string.join(seen, ","))
    }

    _ -> panic as { "the probe was given an unknown step: " <> line }
  }
}

fn configured(
  membership: distribution.Membership,
  name: String,
) -> distribution.Peer {
  let assert Ok(peer) = distribution.peer(membership, name)
    as "a step names only a configured peer"
  peer
}

fn node_of(membership: distribution.Membership, name: String) -> Node {
  distribution.node(configured(membership, name))
}
