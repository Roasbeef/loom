//// Production-launcher tests. The pure half — argv, environment, the
//// requirements the node puts to the session base, and the reachability
//// checks the policy vocabulary cannot express — needs nothing but values.
//// The live half runs the *real* launcher over a real AF_UNIX socket,
//// with the node dispatch absorbed by an in-process fake helper, and
//// drives it from a client that connects exactly as `cap/runtime` does.
//// No jail, no `erl`; `codemode/e2e_test` covers those.

import broker/broker
import broker/budget
import broker/exec
import broker/policy
import broker/token
import codemode/compile
import codemode/enforcement
import codemode/identity
import codemode/launch
import codemode/satellite
import core/clock
import core/ids
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/string
import simplifile
import support/fake_helper
import support/internal/ffi_peer
import support/rig

const t = 1_700_000_000_000

const deadline = 1_700_000_030_000

fn run_phase(budget: budget.Budget) -> identity.PhaseIdentity {
  identity.for_execution(op_id: op_id(), step_id: "step-1", budget:)
  |> identity.run_phase
}

fn op_id() -> ids.OpId {
  let generator = ids.generator(clock.fixed(at: t), seed: 11)
  let #(op, _generator) = ids.mint_op(generator)
  op
}

fn fresh_dir(name: String) -> String {
  let assert Ok(here) = simplifile.current_directory()
  let dir = here <> "/build/cmtest/launch-" <> name
  let _cleared = simplifile.delete(dir)
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  dir
}

fn artifact(dir: String) -> compile.Artifact {
  compile.Artifact(
    build_root: dir,
    beam_dir: dir <> "/ebin",
    entry_module: compile.entry_module,
    manifest_hash: "sha256-none",
  )
}

// A session base wide enough to host a satellite: the filesystem readable,
// and the two cap handles plus PATH on the environment allowlist.
fn base_policy(dir: String) -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    ..policy.workspace_default(dir),
    readable_roots: ["/"],
    env_allow: ["PATH", launch.sock_env, launch.token_env],
  )
}

fn spec(dir: String, wire: Subject(satellite.WireIn)) -> satellite.LaunchSpec {
  satellite.LaunchSpec(
    artifact: artifact(dir),
    token_path: dir <> "/token/cap-token",
    cap_socket_path: dir <> "/sock/cap.sock",
    identity: run_phase(budget.Budget(max_outstanding: 4, deadline_ms: deadline)),
    base_policy: base_policy(dir),
    env: [#("PATH", "/usr/bin")],
    cwd: dir,
    wire:,
  )
}

fn config(broker_actor: broker.Broker) -> launch.LaunchConfig {
  launch.LaunchConfig(
    broker: broker_actor,
    clock: clock.fixed(at: t),
    erl_path: "/usr/bin/erl",
    demand: exec.BestEffort,
    accept_timeout_ms: 3000,
  )
}

fn start_broker(
  checkout: fn() -> Result(exec.Helper, exec.CheckoutError),
) -> broker.Broker {
  let assert Ok(started) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.fixed(at: t),
        checkout:,
        checkin: fn(_helper) { Nil },
      ),
    )
    as "the broker must start"
  started
}

// --- the names shared with the prelude ------------------------------------

pub fn the_cap_handles_match_the_boot_runtimes_names_test() {
  // `codemode` must not depend on `cap` — linking model-facing code into
  // the harness VM is the one thing Rule Zero forbids — so the two
  // environment-variable names and the terminal frame kind are restated
  // on this side. Pin them against the prelude's own source, so a rename
  // there fails here instead of producing a satellite that boots and
  // cannot find its channel.
  let assert Ok(runtime) = simplifile.read("../cap/src/cap/runtime.gleam")
    as "the cap package must sit beside this one"
  assert string.contains(
    runtime,
    "pub const sock_env = \"" <> launch.sock_env <> "\"",
  )
  assert string.contains(
    runtime,
    "pub const token_env = \"" <> launch.token_env <> "\"",
  )
  assert string.contains(
    runtime,
    "pub const outcome_kind = \"" <> satellite.outcome_kind <> "\"",
  )
}

// --- argv and environment -------------------------------------------------

pub fn node_argv_disables_distribution_test() {
  let argv = launch.node_argv("/usr/bin/erl", artifact("/w"))
  // Distribution off, no epmd, and no -name/-sname anywhere: the framed
  // cap socket is the node's only link to anything.
  assert list.contains(argv, "-proto_dist")
  assert list.contains(argv, "none")
  assert list.contains(argv, "-start_epmd")
  assert list.contains(argv, "false")
  assert !list.contains(argv, "-name")
  assert !list.contains(argv, "-sname")
  // It boots the generated entry off the artifact's beam directory, and
  // stops the node when the entry returns.
  assert string.contains(string.join(argv, " "), "-pa /w/ebin")
  assert string.contains(
    string.join(argv, " "),
    "-run " <> compile.entry_module <> " main",
  )
  assert string.contains(string.join(argv, " "), "-s init stop")
}

pub fn node_env_pins_the_cap_handles_test() {
  let dir = "/work/x"
  let wire = process.new_subject()
  // A caller that tries to point the satellite at somebody else's socket
  // and token must not win: the launcher sets both itself.
  let smuggled =
    satellite.LaunchSpec(..spec(dir, wire), env: [
      #("PATH", "/usr/bin"),
      #(launch.sock_env, "/tmp/attacker.sock"),
      #(launch.token_env, "/tmp/attacker.token"),
    ])
  let env = launch.node_env(smuggled)
  assert list.key_find(env, launch.sock_env) == Ok(dir <> "/sock/cap.sock")
  assert list.key_find(env, launch.token_env) == Ok(dir <> "/token/cap-token")
  assert list.key_find(env, "PATH") == Ok("/usr/bin")
  // Exactly one entry per name — a duplicate would leave which one wins to
  // the helper's map construction.
  assert list.length(env) == 3
}

// --- the requirements put to the session base -----------------------------

pub fn node_requirements_turn_the_network_off_test() {
  let dir = "/work/x"
  let wire = process.new_subject()
  let open =
    satellite.LaunchSpec(
      ..spec(dir, wire),
      base_policy: policy.SandboxPolicy(
        ..base_policy(dir),
        network: policy.NetworkFull,
      ),
    )
  let requirements = launch.node_requirements(open, t)
  assert requirements.network == policy.NetworkOff
  // Composition takes the meet, so a network-off requirement against a
  // network-full base really is off.
  let #(effective, narrowings) =
    policy.compose(base: open.base_policy, requirements:, grants: [])
  assert effective.network == policy.NetworkOff
  assert narrowings == []
}

pub fn node_requirements_bound_the_wall_by_the_deadline_test() {
  let dir = "/work/x"
  let wire = process.new_subject()
  // 30 seconds left of the pooled deadline, against a base that would
  // allow 600: the node's own wall limit is the tighter one, so the jail
  // kills it even if the host's timer never fires.
  let requirements = launch.node_requirements(spec(dir, wire), t)
  assert requirements.limits.wall_s == 30
}

pub fn node_requirements_name_the_socket_and_token_directories_test() {
  let dir = "/work/x"
  let wire = process.new_subject()
  let requirements = launch.node_requirements(spec(dir, wire), t)
  assert list.contains(requirements.readable_roots, dir <> "/sock")
  assert list.contains(requirements.readable_roots, dir <> "/token")
  assert list.contains(requirements.readable_roots, dir <> "/ebin")
  assert list.contains(requirements.env_allow, launch.sock_env)
  assert list.contains(requirements.env_allow, launch.token_env)
}

// --- reachability the policy vocabulary cannot state ----------------------

pub fn a_protected_cap_socket_is_unreachable_test() {
  let guarded =
    policy.SandboxPolicy(..policy.workspace_default("/work"), protected: [
      "/work/secrets",
    ])
  let assert Error(reason) =
    launch.path_reachable(guarded, "/work/secrets/cap.sock", "the cap socket")
  assert string.contains(reason, "protected")
}

pub fn a_cap_socket_under_the_scratch_tmpfs_is_unreachable_test() {
  // The helper mounts the scratch tmpfs over /tmp, so a socket the host
  // can see there is simply not in the jail's filesystem at all.
  let assert Error(reason) =
    launch.path_reachable(
      policy.workspace_default("/work"),
      launch.scratch_mount <> "/loom/cap.sock",
      "the cap socket",
    )
  assert string.contains(reason, launch.scratch_mount)
}

pub fn a_cap_socket_no_root_admits_is_unreachable_test() {
  let assert Error(reason) =
    launch.path_reachable(
      policy.workspace_default("/work"),
      "/elsewhere/cap.sock",
      "the cap socket",
    )
  assert string.contains(reason, "no root")
}

pub fn a_relative_cap_socket_is_refused_test() {
  let assert Error(reason) =
    launch.path_reachable(
      policy.workspace_default("/work"),
      "cap.sock",
      "the cap socket",
    )
  assert string.contains(reason, "absolute")
}

pub fn a_covered_cap_socket_is_reachable_test() {
  assert launch.path_reachable(
      policy.workspace_default("/work"),
      "/work/caps/cap.sock",
      "the cap socket",
    )
    == Ok(Nil)
}

// --- in-band refusals -----------------------------------------------------

pub fn a_starved_budget_refuses_the_launch_test() {
  let dir = fresh_dir("starved")
  let wire = process.new_subject()
  let broker_actor =
    start_broker(fn() {
      Ok(fake_helper.start_helper(fake_helper.HoldForCancel))
    })
  // The node itself holds one outstanding effect for the whole execution,
  // so a pooled cap of one would leave nothing for a single cap call.
  let starved =
    satellite.LaunchSpec(
      ..spec(dir, wire),
      identity: run_phase(budget.Budget(
        max_outstanding: 1,
        deadline_ms: deadline,
      )),
    )
  let assert Error(reason) = launch.launcher(config(broker_actor))(starved)
  assert string.contains(reason, "at least 2")
  // Refused before anything exists: no socket was created.
  assert !rig.exists(starved.cap_socket_path)
  broker.stop(broker_actor)
}

pub fn a_base_without_the_cap_handles_refuses_the_launch_test() {
  let dir = fresh_dir("no-handles")
  let wire = process.new_subject()
  let broker_actor =
    start_broker(fn() {
      Ok(fake_helper.start_helper(fake_helper.HoldForCancel))
    })
  // A session base whose environment allowlist omits LOOM_CAP_SOCK cannot
  // host a satellite: the helper constructs the child's environment from
  // the allowlist, so the node would boot unable to find its channel.
  let narrow =
    satellite.LaunchSpec(
      ..spec(dir, wire),
      base_policy: policy.SandboxPolicy(..base_policy(dir), env_allow: ["PATH"]),
    )
  let assert Error(reason) = launch.launcher(config(broker_actor))(narrow)
  assert string.contains(reason, launch.sock_env)
  assert !rig.exists(narrow.cap_socket_path)
  broker.stop(broker_actor)
}

pub fn a_node_that_never_starts_closes_the_wire_test() {
  let dir = fresh_dir("no-helper")
  let wire = process.new_subject()
  // No helper can be borrowed, so the node is refused before it exists.
  // The host must learn that as a closed channel, not as a silent wait
  // until the deadline.
  let broker_actor = start_broker(fn() { Error(exec.AllBusy(size: 0)) })
  let assert Ok(connection) =
    launch.launcher(config(broker_actor))(spec(dir, wire))
  let assert Ok(satellite.WireClosed(reason:)) = process.receive(wire, 5000)
  assert string.contains(reason, "refused")
  // A node that never ran has nothing to report, and says so rather than
  // handing back an empty layer list a reader could mistake for one.
  let assert enforcement.Unreported(why) = connection.destroy()
  assert string.contains(why, "refused before it ran")
  broker.stop(broker_actor)
}

pub fn a_host_killed_from_outside_does_not_leak_the_node_test() {
  let dir = fresh_dir("janitor")
  let broker_actor =
    start_broker(fn() {
      Ok(fake_helper.start_helper(fake_helper.HoldForCancel))
    })
  // A stand-in for the host actor: it owns the wire subject and then just
  // sits there. Killing it is precisely the case the host's own teardown
  // cannot cover, because that teardown runs *inside* the actor — so
  // without a janitor the node, the bound socket, and the private token
  // file all outlive the execution (M4 triage CH-F3(b)).
  let handoff = process.new_subject()
  let host =
    process.spawn_unlinked(fn() {
      let wire = process.new_subject()
      process.send(handoff, wire)
      process.sleep(60_000)
    })
  let assert Ok(wire) = process.receive(handoff, 2000)
  let launched = spec(dir, wire)
  // The token file the host would have written and unlinked itself.
  let assert Ok(Nil) = simplifile.create_directory_all(dir <> "/token")
  let assert Ok(Nil) =
    simplifile.write(to: launched.token_path, contents: "0123456789abcdef")
  let assert Ok(_connection) = launch.launcher(config(broker_actor))(launched)
  // Both really exist first, so what follows is not measuring absence.
  assert rig.exists(launched.cap_socket_path)
  assert rig.exists(launched.token_path)

  process.kill(host)
  assert gone_eventually(launched.cap_socket_path)
  assert gone_eventually(launched.token_path)
  broker.stop(broker_actor)
}

fn gone_eventually(path: String) -> Bool {
  gone_loop(path, 40)
}

fn gone_loop(path: String, attempts: Int) -> Bool {
  case !rig.exists(path) {
    True -> True
    False ->
      case attempts <= 0 {
        True -> False
        False -> {
          process.sleep(50)
          gone_loop(path, attempts - 1)
        }
      }
  }
}

// --- the live cap socket --------------------------------------------------

pub fn the_cap_socket_carries_frames_both_ways_test() {
  let dir = fresh_dir("socket")
  let wire = process.new_subject()
  // The fake helper holds the "node" execution open, so the launcher's
  // socket is the only thing under test; the client connects exactly as
  // `cap/runtime` does.
  let broker_actor =
    start_broker(fn() {
      Ok(fake_helper.start_helper(fake_helper.HoldForCancel))
    })
  let launched = spec(dir, wire)
  let assert Ok(connection) = launch.launcher(config(broker_actor))(launched)

  let assert Ok(peer) = connect_eventually(launched.cap_socket_path, 40)
  // Satellite to host: raw bytes reach the host's wire subject verbatim.
  let assert Ok(Nil) = ffi_peer.send(peer, <<"from-the-satellite":utf8>>)
  let assert Ok(satellite.WireBytes(data:)) = process.receive(wire, 3000)
  assert data == <<"from-the-satellite":utf8>>

  // Host to satellite: what `CapConnection.send` writes arrives on the
  // socket, in order.
  connection.send(<<"one":utf8>>)
  connection.send(<<"two":utf8>>)
  let assert Ok(received) = read_until(peer, <<>>, 5)
  assert received == <<"onetwo":utf8>>

  // The satellite going away is an ordered close, after its bytes.
  ffi_peer.close(peer)
  let assert Ok(satellite.WireClosed(reason:)) = process.receive(wire, 5000)
  assert reason != ""

  // The socket really is on disk before teardown, so the assertion after it
  // is not measuring a file that never existed.
  assert rig.exists(launched.cap_socket_path)
  let _report = connection.destroy()
  // Teardown unlinks the socket file, so a later execution can reuse the
  // path without tripping over a stale inode.
  assert !rig.exists(launched.cap_socket_path)
  broker.stop(broker_actor)
}

// The launcher listens before it returns, but the client may still race
// the listen on a loaded machine; retry briefly rather than flake.
fn connect_eventually(
  path: String,
  attempts: Int,
) -> Result(ffi_peer.PeerSocket, Nil) {
  case ffi_peer.connect(path) {
    Ok(socket) -> Ok(socket)
    Error(Nil) ->
      case attempts <= 0 {
        True -> Error(Nil)
        False -> {
          process.sleep(25)
          connect_eventually(path, attempts - 1)
        }
      }
  }
}

// Two writes may arrive as one chunk or two; accumulate until quiet.
fn read_until(
  peer: ffi_peer.PeerSocket,
  seen: BitArray,
  attempts: Int,
) -> Result(BitArray, Nil) {
  case attempts <= 0 {
    True -> Ok(seen)
    False ->
      case ffi_peer.recv(peer, 500) {
        Error(Nil) -> Ok(seen)
        Ok(chunk) -> {
          let grown = <<seen:bits, chunk:bits>>
          case grown == <<"onetwo":utf8>> {
            True -> Ok(grown)
            False -> read_until(peer, grown, attempts - 1)
          }
        }
      }
  }
}

// --- the node's enforcement report (issue #5) -----------------------------

pub fn destroying_the_node_yields_its_enforcement_report_test() {
  let dir = fresh_dir("enforcement")
  let wire = process.new_subject()
  // The "node" runs until it is cancelled, which is what the host's own
  // teardown does; the helper answers the cancel with an `exec_exit` that
  // carries its enforcement report.
  let broker_actor =
    start_broker(fn() {
      Ok(fake_helper.start_helper(fake_helper.HoldForCancel))
    })
  let assert Ok(connection) =
    launch.launcher(config(broker_actor))(spec(dir, wire))
  // The report is in hand by the time `destroy` returns, because it *is*
  // what destroy returns: the host tears the node down and reports its
  // outcome in the same breath, so a report merely on its way is a report
  // the outcome cannot carry. The abort destroy performs is what provokes
  // the settlement it then collects — a cancelled execution still answers
  // with `exec_exit`, carrying the same enforcement list.
  let assert enforcement.Reported(entries:, degraded:) = connection.destroy()
    as "destroy must not return before the node's enforcement report exists"
  assert list.contains(entries, "bwrap")
  assert degraded == False
  broker.stop(broker_actor)
}

pub fn a_node_reporting_a_skipped_layer_is_never_read_as_enforced_test() {
  let dir = fresh_dir("skipped")
  let wire = process.new_subject()
  // A helper on a kernel that could not provide every demanded layer: the
  // report names the layer it skipped, and the run counts as degraded even
  // though the helper's own `degraded` bool (which tracks only bwrap)
  // stayed false. That is the broker's ground-truth rule, applied here so
  // a skipped layer can never be rendered as an enforced one.
  let broker_actor =
    start_broker(fn() { Ok(fake_helper.start_helper(fake_helper.PartialJail)) })
  let assert Ok(connection) =
    launch.launcher(config(broker_actor))(spec(dir, wire))
  let report = connection.destroy()
  let assert enforcement.Reported(degraded:, ..) = report
  assert degraded
  let #(applied, skipped) = enforcement.layers(report)
  assert applied == ["bwrap"]
  assert skipped == ["landlock: unavailable on this kernel"]
  broker.stop(broker_actor)
}

pub fn a_second_destroy_is_answered_from_the_held_report_test() {
  let dir = fresh_dir("twice")
  let wire = process.new_subject()
  // The host destroys on its exit path and the janitor may destroy again;
  // the second ask must be answered from what the first collected rather
  // than waiting out the timeout for a settlement that already happened.
  let broker_actor =
    start_broker(fn() {
      Ok(fake_helper.start_helper(fake_helper.HoldForCancel))
    })
  let assert Ok(connection) =
    launch.launcher(config(broker_actor))(spec(dir, wire))
  let first = connection.destroy()
  let second = connection.destroy()
  assert second == first
  let assert enforcement.Reported(..) = second
  broker.stop(broker_actor)
}
