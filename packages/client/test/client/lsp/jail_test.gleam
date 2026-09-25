//// The jailed language-server lease: its policy, its helper-lease cap, its
//// relay, and one real `gleam lsp` run through the jail end to end.
////
//// The policy tests are pure and state ADR-013 §1 as assertions: what the
//// project root may and may not be written, which extra roots and names the
//// operator's table adds, that the per-command limits are zero on both sides
//// so composition narrows nothing, and that the network is off whatever the
//// session's base allows. The lease tests run the counter at
//// `exec.min_pool_size`, where the cap is one. The relay tests drive the
//// transport against a scripted runner, so truncation, stderr and the
//// close ladder are provable without a helper.
////
//// The last test is the real thing, feature-detected like the code-mode
//// live suite: it needs `gleam` on `PATH`, `bin/loom-exec` (`make
//// binaries`) and a kernel that can jail. Without one it prints a `SKIP`
//// line on stderr and passes. Its project lives under this package's
//// `build/` directory, never `/tmp`, which the jail replaces with a tmpfs of
//// its own.

import broker/broker
import broker/exec
import broker/framing
import broker/policy
import broker/token
import client/catalog
import client/internal/ffi_os
import client/lsp/jail
import client/lsp/leases
import core/clock
import core/ids
import core/json
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import mcp/jsonrpc
import mcp/transport
import simplifile
import tools/tool

// --- fixtures ----------------------------------------------------------------

const workspace = "/work"

const root = "/work/probe"

fn server(project: catalog.ProjectAccess) -> catalog.LspServer {
  catalog.LspServer(
    name: "gleam",
    command: ["gleam", "lsp"],
    extensions: [".gleam"],
    root_markers: ["gleam.toml"],
    project:,
    readable: [],
    writable: [],
    env: [],
  )
}

fn placement(server: catalog.LspServer) -> jail.Placement {
  jail.Placement(
    server:,
    root:,
    workspace:,
    executable: jail.Executable(
      path: "/usr/local/bin/gleam",
      file: jail.PlainExecutable,
    ),
    home: Some("/home/o"),
  )
}

// A session base shaped like production's: the workspace writable, a
// read view, the network on, and the per-command limits that must not
// reach a lease.
fn session_base() -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    ..policy.workspace_default(workspace),
    readable_roots: ["/"],
    network: policy.NetworkFull,
    env_allow: ["PATH", "HOME", "TMPDIR"],
  )
}

fn host_env(name: String) -> Result(String, Nil) {
  case name {
    "PATH" -> Ok("/usr/bin:/bin")
    "GOFLAGS" -> Ok("-mod=mod")
    _ -> Error(Nil)
  }
}

fn built(server: catalog.LspServer) -> jail.Jail {
  let assert Ok(built) =
    jail.policy_for(placement(server), session_base(), reading: host_env)
    as "the fixture's jail must be buildable"
  built
}

fn composed(built: jail.Jail) -> policy.SandboxPolicy {
  let #(final, narrowings) =
    policy.compose(
      base: built.base,
      requirements: built.requirements,
      grants: [],
    )
  assert narrowings == []
  final
}

// --- (a) the policy ----------------------------------------------------------

pub fn a_writable_project_is_writable_in_the_jail_test() {
  let final = composed(built(server(catalog.ProjectWritable)))
  assert list.contains(final.writable_roots, root)
  assert list.contains(final.readable_roots, root)
}

pub fn a_read_only_project_is_read_but_never_written_test() {
  let built = built(server(catalog.ProjectReadOnly))
  let final = composed(built)
  assert !list.contains(built.requirements.writable_roots, root)
  assert list.contains(final.readable_roots, root)

  // The session base could write the workspace; the jail writes only its
  // scratch directory, which is not the project.
  assert final.writable_roots == [built.scratch]
}

pub fn the_extra_roots_are_the_operators_expanded_against_home_test() {
  let gopls =
    catalog.LspServer(
      ..server(catalog.ProjectReadOnly),
      name: "gopls",
      readable: [catalog.HomePath("go/pkg/mod")],
      writable: [catalog.HomePath(".cache/go-build")],
    )
  let built = built(gopls)
  let final = composed(built)

  // The base is widened by exactly the table's roots, which the session
  // base (writable only under /work) could not have granted.
  assert list.contains(built.base.readable_roots, "/home/o/go/pkg/mod")
  assert list.contains(built.base.writable_roots, "/home/o/.cache/go-build")
  assert list.contains(final.readable_roots, "/home/o/go/pkg/mod")
  assert list.contains(final.writable_roots, "/home/o/.cache/go-build")
  assert !list.contains(final.writable_roots, "/home/o/go/pkg/mod")
}

pub fn a_home_root_without_a_home_is_refused_test() {
  let gopls =
    catalog.LspServer(..server(catalog.ProjectReadOnly), readable: [
      catalog.HomePath("go/pkg/mod"),
    ])
  let refused =
    jail.policy_for(
      jail.Placement(..placement(gopls), home: None),
      session_base(),
      reading: host_env,
    )
  assert result.is_error(refused)
}

pub fn the_environment_is_constructed_and_the_names_pass_through_test() {
  let gopls =
    catalog.LspServer(..server(catalog.ProjectReadOnly), env: [
      "GOFLAGS",
      "GOPROXY",
    ])
  let built = built(gopls)
  assert list.key_find(built.env, "HOME") == Ok("/home/o")
  assert list.key_find(built.env, "TMPDIR") == Ok(built.scratch <> "/tmp")
  assert list.key_find(built.env, "GOFLAGS") == Ok("-mod=mod")
  assert list.key_find(built.env, "PATH") == Ok("/usr/local/bin:/usr/bin:/bin")

  // An unset name is skipped and reported, never passed empty.
  assert built.unset == ["GOPROXY"]
  assert list.key_find(built.env, "GOPROXY") == Error(Nil)
  assert built.requirements.env_allow == ["PATH", "HOME", "TMPDIR", "GOFLAGS"]
  assert list.contains(composed(built).env_allow, "GOFLAGS")
}

pub fn the_tmpdir_is_pinned_under_a_writable_root_test() {
  let built = built(server(catalog.ProjectReadOnly))
  let assert Ok(tmp) = list.key_find(built.env, "TMPDIR")
  let final = composed(built)
  assert list.any(final.writable_roots, fn(writable) {
    policy.covers(root: writable, path: tmp)
  })
  assert !string.starts_with(tmp, "/tmp")
}

pub fn the_lease_limits_are_zero_and_survive_composition_test() {
  let built = built(server(catalog.ProjectWritable))

  // The session base carries a command's limits; the lease base does not.
  assert session_base().limits.output_bytes > 0
  assert built.base.limits.wall_s == 0
  assert built.base.limits.cpu_s == 0
  assert built.base.limits.output_bytes == 0

  // Composed with the requirements, nothing narrows and the zeros stand,
  // while the memory and process ceilings are the session's.
  let final = composed(built)
  assert final.limits.wall_s == 0
  assert final.limits.cpu_s == 0
  assert final.limits.output_bytes == 0
  assert final.limits.mem_bytes == session_base().limits.mem_bytes
  assert final.limits.pids == session_base().limits.pids
}

pub fn the_network_is_off_whatever_the_base_allows_test() {
  let built = built(server(catalog.ProjectWritable))
  assert built.base.network == policy.NetworkFull
  assert built.requirements.network == policy.NetworkOff
  assert composed(built).network == policy.NetworkOff
  assert jail.call_spec(built, op(), now_ms: 0, demand: exec.BestEffort).response
    == broker.RefuseNarrowed
}

pub fn a_root_the_session_cannot_reach_is_refused_not_granted_test() {
  let refused =
    jail.policy_for(
      jail.Placement(
        ..placement(server(catalog.ProjectWritable)),
        root: "/elsewhere",
      ),
      session_base(),
      reading: host_env,
    )
  let assert Error(reason) = refused as "a root outside the workspace refuses"
  assert string.contains(reason, "write /elsewhere")
}

pub fn the_executable_region_is_mounted_read_only_test() {
  let built = built(server(catalog.ProjectWritable))
  let wanted =
    policy.Mount(
      path: "/usr/local/bin",
      access: policy.MountReadOnly,
      requirement: policy.MountRequired,
    )
  assert built.requirements.mounts == [wanted]
  assert list.contains(built.base.mounts, wanted)
  assert composed(built).mounts == [wanted]
}

pub fn a_region_the_base_already_binds_is_asked_for_by_its_path_test() {
  let prefix =
    policy.Mount(
      path: "/usr/local",
      access: policy.MountReadOnly,
      requirement: policy.MountRequired,
    )
  let base = policy.SandboxPolicy(..session_base(), mounts: [prefix])
  let assert Ok(built) =
    jail.policy_for(
      placement(server(catalog.ProjectWritable)),
      base,
      reading: host_env,
    )
  assert built.base.mounts == [prefix]
  assert built.requirements.mounts == [prefix]
}

pub fn a_linked_executable_mounts_its_prefix_test() {
  assert jail.regions(jail.Executable(
      path: "/opt/homebrew/bin/gleam",
      file: jail.LinkedExecutable,
    ))
    == ["/opt/homebrew"]
  assert jail.regions(jail.Executable(
      path: "/home/o/go/bin/gopls",
      file: jail.PlainExecutable,
    ))
    == ["/home/o/go/bin"]
}

pub fn the_step_names_the_server_and_its_root_test() {
  let step = jail.step_id("gleam", "/work/a")
  assert string.starts_with(step, "lsp/gleam/")
  assert string.length(step) == string.length("lsp/gleam/") + 16
  assert step != jail.step_id("gleam", "/work/b")

  let spec =
    jail.call_spec(
      built(server(catalog.ProjectWritable)),
      op(),
      now_ms: 5,
      demand: exec.PlatformEnforcement,
    )
  assert spec.budget.max_outstanding == 1
  assert spec.budget.deadline_ms == 5 + jail.lease_lifetime_ms
  assert spec.demand == exec.PlatformEnforcement

  // The demand is the caller's, carried unchanged: the session's demand is
  // what the probe proves, so the spec must not substitute its own.
  let relaxed =
    jail.call_spec(
      built(server(catalog.ProjectWritable)),
      op(),
      now_ms: 5,
      demand: exec.BestEffort,
    )
  assert relaxed.demand == exec.BestEffort
  assert spec.step_id == jail.step_id("gleam", root)
}

fn op() -> ids.OpId {
  jail.operation(clock.fixed(1000), seed: 7)
}

// --- (b) the lease cap -------------------------------------------------------

pub fn the_cap_at_the_minimum_pool_is_one_test() {
  assert leases.cap_for(exec.min_pool_size) == 1
  assert leases.cap_for(exec.max_pool_size) == exec.max_pool_size - 3
}

pub fn a_lease_past_the_cap_is_refused_naming_the_cap_test() {
  let assert Ok(counter) = leases.start(exec.min_pool_size)
  let assert Ok(first) =
    leases.acquire(counter, holder: process.self(), waiting: 1000)
  let assert Error(refusal) =
    leases.acquire(counter, holder: process.self(), waiting: 1000)
    as "the second lease at the minimum pool exceeds the cap"
  assert refusal == leases.AtCap(cap: 1, pool_size: exec.min_pool_size)
  assert string.contains(leases.refusal_text(refusal), "pool of 4")

  // Released, the slot is free again, and a second release changes nothing.
  leases.release(first)
  leases.release(first)
  let assert Ok(_second) =
    leases.acquire(counter, holder: process.self(), waiting: 1000)
  assert leases.held(counter, waiting: 1000) == Ok(1)
  leases.stop(counter)
}

pub fn a_dead_holder_gives_its_lease_back_test() {
  let assert Ok(counter) = leases.start(exec.min_pool_size)
  let granted = process.new_subject()
  let holder =
    process.spawn_unlinked(fn() {
      process.send(
        granted,
        leases.acquire(counter, holder: process.self(), waiting: 1000),
      )
      process.sleep(50)
    })
  let assert Ok(Ok(_lease)) = process.receive(granted, 1000)
  let watch = process.monitor(holder)
  let assert Ok(_down) =
    process.selector_receive(
      process.new_selector()
        |> process.select_specific_monitor(watch, fn(d) { d }),
      1000,
    )
  assert held_eventually(counter, 0)
  let assert Ok(_) =
    leases.acquire(counter, holder: process.self(), waiting: 1000)
  leases.stop(counter)
}

// The counter's monitor fires asynchronously, so its effect is observed
// by asking again for a bounded while rather than once.
fn held_eventually(counter: leases.Leases, wanted: Int) -> Bool {
  list.repeat(Nil, 100)
  |> list.any(fn(_attempt) {
    case leases.held(counter, waiting: 1000) {
      Ok(count) if count == wanted -> True
      _other -> {
        process.sleep(10)
        False
      }
    }
  })
}

// --- (c) the relay against a scripted runner -------------------------------

// What the scripted runner reports to the test.
type Seen {
  Cleared(events: Subject(broker.CallEvent))
  Stdin(data: BitArray, eof: Bool)
  Aborted
}

fn scripted(
  counter: leases.Leases,
  seen: Subject(Seen),
  scratch: String,
) -> jail.Launch {
  jail.Launch(
    run: fn(_spec, events) {
      process.send(seen, Cleared(events:))
      Ok(
        tool.RunningCall(
          stdin: fn(data, eof) { process.send(seen, Stdin(data:, eof:)) },
          cancel: fn() { Nil },
        ),
      )
    },
    abort: fn() { process.send(seen, Aborted) },
    leases: counter,
    spec: jail.call_spec(
      built(server(catalog.ProjectWritable)),
      op(),
      now_ms: 0,
      demand: exec.PlatformEnforcement,
    ),
    scratch:,
    timing: jail.Timing(
      lease_wait_ms: 1000,
      close_grace_ms: 50,
      settle_grace_ms: 200,
    ),
  )
}

fn scratch_dir(label: String) -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner must have a working directory"
  here
  <> "/build/lsp-jail-"
  <> label
  <> "-"
  <> int.to_string(ffi_os.unique_positive_integer())
}

fn connected(
  launch: jail.Launch,
) -> #(transport.Connection, Subject(transport.TransportEvent)) {
  let inbound = process.new_subject()
  let assert Ok(#(connection, _selector)) =
    transport.open(
      jail.transport(launch),
      inbound,
      process.new_selector(),
      fn(e) { e },
    )
    as "a channel transport always opens"
  #(connection, inbound)
}

fn cleared(seen: Subject(Seen)) -> Subject(broker.CallEvent) {
  let assert Ok(Cleared(events:)) = process.receive(seen, 2000)
    as "the relay must clear the call"
  events
}

fn exited(code: Int) -> broker.CallEvent {
  broker.CallSettled(
    outcome: broker.CallExited(result: exec.ExecResult(
      code:,
      signal: 0,
      stdout_bytes: 0,
      stderr_bytes: 0,
      stdout_truncated: False,
      stderr_truncated: False,
      enforcement: [],
      degraded: False,
      wall_ms: 1,
      timed_out: False,
      cancelled: False,
    )),
  )
}

pub fn stdout_is_the_wire_and_the_settlement_names_the_exit_and_stderr_test() {
  let assert Ok(counter) = leases.start(exec.min_pool_size)
  let seen = process.new_subject()
  let scratch = scratch_dir("relay")
  let #(connection, inbound) = connected(scripted(counter, seen, scratch))
  let events = cleared(seen)

  // A write before or after the clearance reaches stdin in order.
  let assert Ok(Nil) = connection.send("hello")
  let assert Ok(Stdin(data: <<"hello":utf8>>, eof: False)) =
    process.receive(seen, 1000)

  process.send(
    events,
    broker.CallOutput(framing.Stdout, <<"abc":utf8>>, 3, False),
  )
  process.send(
    events,
    broker.CallOutput(framing.Stderr, <<"panic: boom":utf8>>, 11, False),
  )
  process.send(events, exited(2))
  let assert Ok(transport.TransportData(bytes: <<"abc":utf8>>)) =
    process.receive(inbound, 1000)
  let assert Ok(transport.TransportClosed(reason:)) =
    process.receive(inbound, 1000)
  assert string.contains(reason, "exited with code 2")
  assert string.contains(reason, "panic: boom")

  // Nothing follows the close, the lease is back, and a send now fails.
  assert process.receive(inbound, 100) == Error(Nil)
  assert held_eventually(counter, 0)
  assert held_eventually_dead(connection)
  leases.stop(counter)
  let _ = simplifile.delete_all([scratch])
  Nil
}

// A send after the relay stopped answers Error(Nil) once the relay's pid is
// gone, which it is shortly after the settlement.
fn held_eventually_dead(connection: transport.Connection) -> Bool {
  list.repeat(Nil, 100)
  |> list.any(fn(_attempt) {
    case connection.send("late") {
      Error(Nil) -> True
      Ok(Nil) -> {
        process.sleep(10)
        False
      }
    }
  })
}

pub fn a_truncated_stdout_chunk_is_fatal_and_aborts_the_step_test() {
  let assert Ok(counter) = leases.start(exec.min_pool_size)
  let seen = process.new_subject()
  let scratch = scratch_dir("truncated")
  let #(_connection, inbound) = connected(scripted(counter, seen, scratch))
  let events = cleared(seen)
  process.send(
    events,
    broker.CallOutput(framing.Stdout, <<"Content-Le":utf8>>, 10, True),
  )
  let assert Ok(transport.TransportClosed(reason:)) =
    process.receive(inbound, 1000)
  assert string.starts_with(reason, "stdout truncated")
  assert process.receive(seen, 1000) == Ok(Aborted)

  // The lease is held until the helper actually settles.
  assert leases.held(counter, waiting: 1000) == Ok(1)
  process.send(events, exited(137))
  assert held_eventually(counter, 0)
  assert process.receive(inbound, 100) == Error(Nil)
  leases.stop(counter)
  let _ = simplifile.delete_all([scratch])
  Nil
}

pub fn stderr_is_never_fatal_and_keeps_only_its_tail_test() {
  let assert Ok(counter) = leases.start(exec.min_pool_size)
  let seen = process.new_subject()
  let scratch = scratch_dir("stderr")
  let #(_connection, inbound) = connected(scripted(counter, seen, scratch))
  let events = cleared(seen)
  let noise = bit_array.from_string(string.repeat("x", jail.stderr_ring_bytes))
  process.send(events, broker.CallOutput(framing.Stderr, noise, 0, True))
  process.send(
    events,
    broker.CallOutput(framing.Stderr, <<"last words":utf8>>, 0, False),
  )
  process.send(
    events,
    broker.CallOutput(framing.Stdout, <<"{}":utf8>>, 2, False),
  )
  let assert Ok(transport.TransportData(bytes: <<"{}":utf8>>)) =
    process.receive(inbound, 1000)
  process.send(events, exited(1))
  let assert Ok(transport.TransportClosed(reason:)) =
    process.receive(inbound, 1000)
  assert string.ends_with(reason, "last words")
  assert string.length(reason) < jail.stderr_ring_bytes + 200
  leases.stop(counter)
  let _ = simplifile.delete_all([scratch])
  Nil
}

pub fn close_sends_eof_and_aborts_a_server_that_ignores_it_test() {
  let assert Ok(counter) = leases.start(exec.min_pool_size)
  let seen = process.new_subject()
  let scratch = scratch_dir("close")
  let #(connection, inbound) = connected(scripted(counter, seen, scratch))
  let events = cleared(seen)
  connection.close()
  assert process.receive(seen, 1000) == Ok(Stdin(data: <<>>, eof: True))

  // The server does not exit; the grace runs out and the step is aborted.
  assert process.receive(seen, 1000) == Ok(Aborted)
  process.send(events, exited(143))
  let assert Ok(transport.TransportClosed(reason:)) =
    process.receive(inbound, 1000)
  assert string.contains(reason, "code 143")
  assert held_eventually(counter, 0)
  leases.stop(counter)
  let _ = simplifile.delete_all([scratch])
  Nil
}

pub fn a_second_server_past_the_cap_is_refused_as_no_server_test() {
  let assert Ok(counter) = leases.start(exec.min_pool_size)
  let seen = process.new_subject()
  let scratch = scratch_dir("cap")
  let #(_first, first_inbound) = connected(scripted(counter, seen, scratch))
  let events = cleared(seen)

  // At the minimum pool the cap is one, so the second server never clears.
  let #(second, second_inbound) = connected(scripted(counter, seen, scratch))
  let assert Ok(transport.TransportClosed(reason:)) =
    process.receive(second_inbound, 1000)
  assert string.starts_with(reason, "no_server: ")
  assert string.contains(reason, "pool of 4")
  assert process.receive(seen, 100) == Error(Nil)
  assert held_eventually_dead(second)

  // The first is unaffected and settles normally.
  process.send(events, exited(0))
  let assert Ok(transport.TransportClosed(_)) =
    process.receive(first_inbound, 1000)
  leases.stop(counter)
  let _ = simplifile.delete_all([scratch])
  Nil
}

// --- (d) a real `gleam lsp` in the jail -------------------------------------

pub fn gleam_lsp_answers_initialize_from_inside_the_jail_test() {
  case live_prerequisites() {
    Error(reason) -> io.println_error("SKIP lsp jailed gleam lsp: " <> reason)
    Ok(#(helper, here)) -> run_live(helper, here)
  }
}

fn live_prerequisites() -> Result(#(String, String), String) {
  use Nil <- result.try(case exec.unjailed_skip_reason(exec.host_platform()) {
    Some(reason) -> Error(reason)
    None -> Ok(Nil)
  })
  use _gleam <- result.try(
    ffi_os.find_executable("gleam")
    |> result.replace_error("gleam is not on PATH"),
  )
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner must have a working directory"
  let helper = here <> "/../../bin/loom-exec"
  case simplifile.is_file(helper) {
    Ok(True) -> Ok(#(helper, here))
    _absent -> Error("no loom-exec at " <> helper <> "; run `make binaries`")
  }
}

type Live {
  Live(
    root: String,
    workspace: String,
    project: String,
    pool: exec.Pool,
    broker: broker.Broker,
    counter: leases.Leases,
  )
}

fn live_rig(helper: String, here: String) -> Live {
  let root =
    here
    <> "/build/lsp-jail-live-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let workspace = root <> "/ws"
  let project = workspace <> "/probe"
  let assert Ok(Nil) = simplifile.create_directory_all(project <> "/src")
    as "the live project directory must be made"
  let assert Ok(Nil) = simplifile.create_directory_all(workspace <> "/home")
    as "the live home directory must be made"
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/helper-tmp")
    as "the helper's own temporary directory must be made"
  let assert Ok(Nil) =
    simplifile.write(
      project <> "/gleam.toml",
      "name = \"probe\"\nversion = \"1.0.0\"\ntarget = \"erlang\"\n\n[dependencies]\n",
    )
    as "the live project manifest must be written"
  let assert Ok(Nil) =
    simplifile.write(
      project <> "/src/probe.gleam",
      "pub fn greet() -> String {\n  \"hi\"\n}\n",
    )
    as "the live project source must be written"

  // The base reads the workspace alone, so the only regions the lease can
  // add are the ones its own policy names. The helper's minimal view binds
  // the system directories itself, so on a host whose `gleam` lives in one
  // of them the executable mount is not what makes it reachable; the policy
  // tests above are what pin that mount.
  let base = live_base(workspace)
  let assert Ok(pool) =
    exec.start_pool(size: exec.min_pool_size, spawn: fn() {
      exec.spawn_helper(exec.SpawnConfig(
        helper_path: helper,
        shell_path: "/bin/sh",
        base_policy: base,
        helper_args: [],
        tmp_dir: root <> "/helper-tmp",
        handshake_timeout_ms: 5000,
        cancel_grace_ms: 3000,
        heartbeat_interval_ms: 0,
      ))
    })
    as "the helper pool must start"
  let assert Ok(broker_actor) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: wall_clock(),
        checkout: fn() { exec.checkout(pool, waiting: 20_000) },
        checkin: fn(helper) { exec.checkin(pool, helper) },
      ),
    )
    as "the broker must start"
  let assert Ok(counter) = leases.start(exec.min_pool_size)
    as "the lease counter must start"
  Live(root:, workspace:, project:, pool:, broker: broker_actor, counter:)
}

fn live_base(workspace: String) -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    ..policy.workspace_default(workspace),
    writable_roots: [workspace],
    readable_roots: [workspace],
    network: policy.NetworkFull,
    env_allow: ["PATH"],
  )
}

fn wall_clock() -> clock.Clock {
  clock.from_function(ffi_os.system_time_ms)
}

fn run_live(helper: String, here: String) -> Nil {
  let live = live_rig(helper, here)
  let server = server(catalog.ProjectWritable)
  let assert Ok(executable) = jail.locate(server, None)
    as "gleam must be located on PATH"
  let placement =
    jail.Placement(
      server:,
      root: live.project,
      workspace: live.workspace,
      executable:,
      home: Some(live.workspace <> "/home"),
    )
  let assert Ok(built) =
    jail.policy_for(placement, live_base(live.workspace), reading: fn(name) {
      case name {
        "PATH" -> Ok("/usr/local/bin:/usr/bin:/bin")
        _ -> Error(Nil)
      }
    })
    as "the live jail must compose"
  let launch =
    jail.launch(
      live.broker,
      live.counter,
      built,
      op(),
      wall_clock(),
      demand: exec.PlatformEnforcement,
    )
  let #(connection, inbound) = connected(launch)
  let uri = "file://" <> live.project
  send(connection, initialize(uri))
  case await_reply(inbound, <<>>, 1) {
    Declined(reason) -> {
      decline(reason)
      stop_live(live)
    }
    Replied(result:, buffer:) ->
      converse(live, connection, inbound, uri, result, buffer)
  }
}

fn converse(
  live: Live,
  connection: transport.Connection,
  inbound: Subject(transport.TransportEvent),
  uri: String,
  initialized: json.JsonValue,
  buffer: BitArray,
) -> Nil {
  assert advertises(initialized, "definitionProvider")

  // Opening a document makes the server compile the project, which is what
  // writes `manifest.toml` and `build/`; a document-symbol request after
  // it is the barrier that says the compile has happened.
  let file = uri <> "/src/probe.gleam"
  send(connection, jsonrpc.notification("initialized", Some(json.Object([]))))
  send(connection, did_open(file))
  send(
    connection,
    jsonrpc.request(
      jsonrpc.IdInt(2),
      "textDocument/documentSymbol",
      Some(
        json.Object([
          #("textDocument", json.Object([#("uri", json.String(file))])),
        ]),
      ),
    ),
  )
  let buffer = case await_reply(inbound, buffer, 2) {
    Replied(result: _, buffer:) -> buffer
    Declined(reason) -> panic as reason
  }

  // The polite stop ADR-013 §1 names: shutdown, exit, then stdin EOF.
  send(connection, jsonrpc.request(jsonrpc.IdInt(3), "shutdown", None))
  let _ = case await_reply(inbound, buffer, 3) {
    Replied(result: _, buffer:) -> buffer
    Declined(reason) -> panic as reason
  }
  send(connection, jsonrpc.notification("exit", None))
  connection.close()
  let reason = await_closed(inbound)
  io.println_error("lsp jailed gleam lsp: " <> reason)
  assert held_eventually(live.counter, 0)

  // The helper reports what it enforced only in the exit report, so a host
  // that cannot give platform enforcement is learned here, after the whole
  // conversation ran. Everything above still ran through the jail's mounts;
  // what cannot be claimed is the demanded enforcement, and that is the
  // declared skip rather than a pass.
  case string.contains(reason, "demanded enforcement") {
    True -> decline(reason)
    False -> {
      assert string.contains(reason, "exited with code 0")
    }
  }

  // The server wrote inside the project and nowhere else in the workspace
  // but its own scratch and home.
  let assert Ok(project) = simplifile.read_directory(live.project)
    as "the project must be listable"
  assert list.sort(project, string.compare)
    == ["build", "gleam.toml", "manifest.toml", "src"]
  let assert Ok(entries) = simplifile.read_directory(live.workspace)
    as "the workspace must be listable"
  assert list.sort(entries, string.compare) == [".codemode", "home", "probe"]
  stop_live(live)
}

// The skip line and its detail are two lines, the convention
// `test/support/enforcement` keeps: the census matches the first literally,
// and the second can say whatever the helper said.
fn decline(reason: String) -> Nil {
  io.println_error(
    "SKIP lsp jailed gleam lsp: platform enforcement unavailable",
  )
  io.println_error("  lsp jailed gleam lsp degraded: " <> reason)
}

fn stop_live(live: Live) -> Nil {
  broker.stop(live.broker)
  exec.stop_pool(live.pool)
  leases.stop(live.counter)
  let _ = simplifile.delete_all([live.root])
  Nil
}

fn send(connection: transport.Connection, message: json.JsonValue) -> Nil {
  let assert Ok(Nil) = connection.send(frame(message))
    as "the relay must accept a frame while the server runs"
  Nil
}

type Awaited {
  Replied(result: json.JsonValue, buffer: BitArray)
  Declined(reason: String)
}

// Reads frames until the response carrying `id`. A close before it is the
// helper declining the demanded enforcement when the reason says so, and a
// failure otherwise.
fn await_reply(
  inbound: Subject(transport.TransportEvent),
  buffer: BitArray,
  id: Int,
) -> Awaited {
  let assert Ok(event) = process.receive(inbound, 60_000)
    as "gleam lsp must answer within a minute"
  case event {
    transport.TransportClosed(reason:) ->
      case string.contains(reason, "demanded enforcement") {
        True -> Declined(reason)
        False -> panic as { "the jailed server closed: " <> reason }
      }
    transport.TransportData(bytes:) -> {
      let #(buffer, bodies) = frames(bit_array.append(buffer, bytes), [])
      case list.find_map(bodies, response_to(_, id)) {
        Ok(result) -> Replied(result:, buffer:)
        Error(Nil) -> await_reply(inbound, buffer, id)
      }
    }
  }
}

fn response_to(body: String, id: Int) -> Result(json.JsonValue, Nil) {
  use value <- result.try(json.parse(body) |> result.replace_error(Nil))
  case value {
    json.Object(fields) ->
      case list.key_find(fields, "id"), list.key_find(fields, "result") {
        Ok(json.Int(found)), Ok(result) if found == id -> Ok(result)
        _, _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn await_closed(inbound: Subject(transport.TransportEvent)) -> String {
  let assert Ok(event) = process.receive(inbound, 30_000)
    as "the jailed server must settle after exit"
  case event {
    transport.TransportClosed(reason:) -> reason
    transport.TransportData(_) -> await_closed(inbound)
  }
}

// --- the wire, written out -----------------------------------------------------
//
// `client` does not depend on the `lsp` package yet (the manager slice adds
// it), so this suite frames and reads the few messages it needs by hand:
// `Content-Length`, a blank line, compact JSON. It is the whole of the
// protocol a transport test needs, and it keeps the test from importing a
// transitive dependency.

fn frame(message: json.JsonValue) -> String {
  let body = json.to_string(message)
  "Content-Length: "
  <> int.to_string(string.byte_size(body))
  <> "\r\n\r\n"
  <> body
}

fn initialize(uri: String) -> json.JsonValue {
  jsonrpc.request(
    jsonrpc.IdInt(1),
    "initialize",
    Some(
      json.Object([
        #("processId", json.Null),
        #("rootUri", json.String(uri)),
        #(
          "workspaceFolders",
          json.Array([
            json.Object([
              #("uri", json.String(uri)),
              #("name", json.String("probe")),
            ]),
          ]),
        ),
        #("capabilities", json.Object([])),
      ]),
    ),
  )
}

fn did_open(file: String) -> json.JsonValue {
  jsonrpc.notification(
    "textDocument/didOpen",
    Some(
      json.Object([
        #(
          "textDocument",
          json.Object([
            #("uri", json.String(file)),
            #("languageId", json.String("gleam")),
            #("version", json.Int(1)),
            #("text", json.String("pub fn greet() -> String {\n  \"hi\"\n}\n")),
          ]),
        ),
      ]),
    ),
  )
}

// Whether an initialize result advertises `provider`: `true` or an options
// object, as the protocol allows either.
fn advertises(result: json.JsonValue, provider: String) -> Bool {
  case result {
    json.Object(fields) ->
      case list.key_find(fields, "capabilities") {
        Ok(json.Object(capabilities)) ->
          case list.key_find(capabilities, provider) {
            Ok(json.Bool(True)) | Ok(json.Object(_)) -> True
            _other -> False
          }
        _other -> False
      }
    _other -> False
  }
}

// Splits every complete frame off the front of `buffer`, returning what is
// left and the bodies in arrival order.
fn frames(buffer: BitArray, bodies: List(String)) -> #(BitArray, List(String)) {
  case header_end(buffer, 0) {
    Error(Nil) -> #(buffer, list.reverse(bodies))
    Ok(end) -> {
      let assert Ok(head) = bit_array.slice(buffer, 0, end)
        as "a header slice is in range"
      let assert Ok(head) = bit_array.to_string(head)
        as "an LSP header is ASCII"
      let assert Ok(length) =
        string.split(head, "\r\n")
        |> list.find_map(fn(line) {
          case string.split_once(line, ":") {
            Ok(#(name, value)) ->
              case string.lowercase(name) == "content-length" {
                True -> int.parse(string.trim(value))
                False -> Error(Nil)
              }
            Error(Nil) -> Error(Nil)
          }
        })
        as "every frame carries a Content-Length"
      let start = end + 4
      case bit_array.byte_size(buffer) >= start + length {
        False -> #(buffer, list.reverse(bodies))
        True -> {
          let assert Ok(body) = bit_array.slice(buffer, start, length)
            as "a body slice is in range"
          let assert Ok(body) = bit_array.to_string(body)
            as "an LSP body is UTF-8"
          let size = bit_array.byte_size(buffer)
          let assert Ok(rest) =
            bit_array.slice(buffer, start + length, size - start - length)
            as "the remainder slice is in range"
          frames(rest, [body, ..bodies])
        }
      }
    }
  }
}

fn header_end(buffer: BitArray, at: Int) -> Result(Int, Nil) {
  case bit_array.slice(buffer, at, 4) {
    Ok(<<"\r\n\r\n":utf8>>) -> Ok(at)
    Ok(_) -> header_end(buffer, at + 1)
    Error(Nil) -> Error(Nil)
  }
}
