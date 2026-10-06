//// The executor service as a process of its own: the same pool, service and
//// dispatcher the harness's service lane builds, booted without the harness.
////
//// The service (`broker/executor`) was written to own a session's helpers,
//// and its seams are closures over a pool, so nothing in it needs a session.
//// This package is the proof, and the compile-time half of the proof is the
//// dependency list: it depends on `broker` and `core` and not on `client`,
//// so a daemon built from here cannot reach a session, a model provider or
//// the web view. Helper locality is preserved because the helper is spawned
//// exactly as the harness spawns it, over the same `exec.prepare_helper`,
//// on the machine that runs this process; a native `loom-exec` is never
//// reached across a network, only by the port that spawned it.
////
//// ## What this is not
////
//// There is no listener, no control socket, no frame and no registration
//// here. A standalone executor has no caller until the distributed-runtime
//// work supplies a transport and a trust model, and defining either now
//// would fix them before their only consumer exists.
////
//// ## The adapter
////
//// `broker/dispatch.Dispatcher` is the narrow adapter that work implements
//// and consumes. A record holding one function, it already crosses the
//// seam between the broker's decision to run a call and whatever owns the
//// helper: a remote transport is a `Dispatcher` whose `start` forwards a
//// `Dispatch` to a peer and whose `Execution` closures forward `cancel`,
//// `stdin`, `release` and `abandon` back. Its peer on this side is
//// `service_of`, which hands out the local service's dispatcher. No type is
//// added here, because a second name for the same record would only invite
//// the two to drift. Version agreement is `broker/census`: `census` reports
//// this process's, and `broker/census.skew` is the refusal.
////
//// ## Life of a boot
////
//// 1. `boot` spawns a pool of helpers over a base policy with a writable
////    scratch and the network off, starts the service over the pool's
////    seams, and starts a broker over the service's dispatcher.
//// 2. `smoke` runs `true` once, jailed, through that broker, which is the
////    smallest proof that the helper, the jail and the service agree. A
////    degraded result (a host missing a layer the helper would build) is
////    refused, naming the skipped layers.
//// 3. `census` reports the versions and the features the helper said in its
////    hello. It follows the smoke because the pool only hears a hello when
////    it spawns, and the census borrows nothing; before any spawn the
////    features are empty, which means unknown.
//// 4. `drain` closes the service: new work is refused, live executions are
////    cancelled and given half the budget to settle, the pool is closed
////    with the rest, and the answer is the pool's native-exit verdict.
////
//// "Restart" is a fresh incarnation. Nothing is resumed: a second `boot`
//// in the same VM spawns new helpers under a new incarnation, minted from
//// the wall clock to the microsecond, so within one VM an execution
//// identity from the first service never equals one from the second.
////
//// The scratch directory is the jail's writable root and holds the helper's
//// policy files, which a jailed command can read just as the harness's can.
//// It is removed only after a drain that confirmed custody, and after a
//// boot that failed before spawning anything.

import argv
import broker/broker
import broker/budget
import broker/census.{type Census}
import broker/exec
import broker/executor as service
import broker/policy
import broker/token
import core/clock
import core/ids
import envoy
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import gleam/time/timestamp
import simplifile
import telemetry/log

/// Where the helper is looked for when neither argv nor the environment
/// names one: the path `make binaries` installs it at, relative to the
/// working directory.
pub const default_helper = "bin/loom-exec"

/// The environment variable that names the helper, consulted when argv
/// names none.
pub const helper_variable = "LOOM_EXEC_HELPER"

/// What a boot is built from.
pub type Config {
  Config(
    /// Path to the `loom-exec` helper.
    helper: String,
    /// An absolute directory the jail may write and the helper's transient
    /// policy file lives under. Created if absent.
    scratch: String,
    /// How many helpers the pool may hold.
    pool_size: Int,
  )
}

/// A running standalone executor: the pool, the service over it and a
/// broker over the service. Hold it to keep the processes linked to the
/// caller alive; give it to `drain` to end them.
pub opaque type Standalone {
  Standalone(
    pool: exec.Pool,
    service: service.Executor,
    broker: broker.Broker,
    incarnation: Int,
  )
}

/// Picks the helper path: the first argument, else the environment
/// variable, else `default_helper`. Pure so that the choice is testable
/// without touching the process.
///
/// ## Examples
///
/// ```gleam
/// assert executor.choose_helper(["/opt/loom-exec"], Ok("/env")) == "/opt/loom-exec"
/// assert executor.choose_helper([], Ok("/env")) == "/env"
/// assert executor.choose_helper([], Error(Nil)) == "bin/loom-exec"
/// ```
///
pub fn choose_helper(
  arguments: List(String),
  environment: Result(String, Nil),
) -> String {
  case arguments, environment {
    [path, ..], _ -> path
    [], Ok(path) if path != "" -> path
    [], _ -> default_helper
  }
}

/// The base policy every execution of a standalone executor runs under: the
/// scratch directory writable, the whole filesystem readable, the network
/// off. A request may narrow it; nothing here widens it.
///
/// ## Examples
///
/// ```gleam
/// assert executor.base_policy("/s").writable_roots == ["/s"]
/// ```
///
pub fn base_policy(scratch: String) -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    ..policy.workspace_default(scratch),
    readable_roots: ["/"],
    network: policy.NetworkOff,
  )
}

/// Mints an incarnation: the wall clock in microseconds since the epoch.
/// Two boots in one VM are separated by at least a helper spawn, orders of
/// magnitude more than a microsecond, so they never share one.
///
/// ## Examples
///
/// ```gleam
/// assert executor.mint_incarnation() > 0
/// ```
///
pub fn mint_incarnation() -> Int {
  let #(seconds, nanoseconds) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  seconds * 1_000_000 + nanoseconds / 1000
}

/// Boots a pool, a service over it and a broker over the service.
///
/// Every process is linked to the caller, as the harness's plane is to the
/// session that builds it. The pool spawns helpers lazily, so a wrong
/// helper path surfaces at the first execution or census, not here.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(up) = executor.boot(executor.Config("bin/loom-exec", "/tmp/s", 1))
/// ```
///
pub fn boot(config: Config) -> Result(Standalone, String) {
  boot_with(config, start: start_plane)
}

/// `boot` with the start of the processes supplied, so that a test can make
/// the step after the scratch directory exists fail. The scratch is created
/// here and removed again if `start` fails: nothing was spawned, so no jail
/// can be using it, and `run` (which only cleans up after a boot that
/// succeeded) would otherwise never see it.
///
/// ## Examples
///
/// ```gleam
/// let failed = executor.boot_with(config, start: fn(_) { Error("no") })
/// assert failed == Error("no")
/// ```
///
pub fn boot_with(
  config: Config,
  start start: fn(Config) -> Result(Standalone, String),
) -> Result(Standalone, String) {
  // The helper refuses a relative path in its policy after it has been
  // spawned, which surfaces as a dead handshake. Say so before spawning.
  use Nil <- result.try(
    policy.validate(base_policy(config.scratch))
    |> result.map_error(fn(error) {
      "the scratch "
      <> config.scratch
      <> " is not a usable policy root: "
      <> string.inspect(error)
    }),
  )
  use Nil <- result.try(
    simplifile.create_directory_all(config.scratch <> "/tmp")
    |> result.map_error(fn(error) {
      "cannot create " <> config.scratch <> ": " <> string.inspect(error)
    }),
  )
  case start(config) {
    Ok(up) -> Ok(up)
    Error(reason) -> {
      let _ = simplifile.delete(config.scratch)
      Error(reason)
    }
  }
}

// Spawns the pool, the service over it and the broker over the service. The
// pool is lazy and linked to the caller, so a failure here leaves no helper.
fn start_plane(config: Config) -> Result(Standalone, String) {
  let spawn_config =
    exec.SpawnConfig(
      helper_path: config.helper,
      shell_path: "/bin/sh",
      base_policy: base_policy(config.scratch),
      helper_args: [],
      tmp_dir: config.scratch <> "/tmp",
      handshake_timeout_ms: 5000,
      cancel_grace_ms: 3000,
      heartbeat_interval_ms: 0,
    )
  use pool <- result.try(
    exec.start_pool(size: config.pool_size, spawn: fn() {
      exec.prepare_helper(spawn_config)
    })
    |> result.map_error(fn(error) {
      "the helper pool did not start: " <> string.inspect(error)
    }),
  )
  let incarnation = mint_incarnation()
  use started <- result.try(
    service.start_with_retirement(
      service.ExecutorConfig(
        checkout: fn() { exec.checkout(pool, waiting: 15_000) },
        checkin: fn(helper) { exec.checkin(pool, helper) },
        custody: fn() { exec.pool_custody(pool, waiting: 1000) },
        close_helpers: fn(waiting) { exec.close_pool(pool, waiting:) },
        incarnation:,
        // The entrypoint's stdout is the census line, and a global log
        // handler would interleave with it. A deployed executor (#697)
        // installs its own handler and passes its logger here.
        log: log.discard(),
      ),
      fn(helper, completed) {
        exec.prepare_borrowed_retirement(pool, helper, completed)
      },
    )
    |> result.map_error(fn(error) {
      "the executor service did not start: " <> string.inspect(error)
    }),
  )
  use fronted <- result.map(
    broker.start_dispatching(
      entropy: token.production_entropy(),
      clock: wall_clock(),
      dispatcher: service.dispatcher(started),
    )
    |> result.map_error(fn(error) {
      "the broker did not start: " <> string.inspect(error)
    }),
  )
  Standalone(pool:, service: started, broker: fronted, incarnation:)
}

/// The incarnation this boot minted.
pub fn incarnation(standalone: Standalone) -> Int {
  standalone.incarnation
}

/// The service, for a caller that needs its `Dispatcher`
/// (`broker/executor.dispatcher`), its inventory or its census. This is the
/// local half of the adapter the module doc describes.
pub fn service_of(standalone: Standalone) -> service.Executor {
  standalone.service
}

/// This executor's version census. The features are the hello of the newest
/// helper the pool has spawned, and are empty (unknown) until one has said
/// hello; the census borrows and spawns nothing (see
/// `broker/executor.census`).
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(here) = executor.census(up)
/// assert here.service == census.service_version
/// ```
///
pub fn census(standalone: Standalone) -> Result(Census, String) {
  service.census(standalone.service, waiting: 10_000)
  |> result.replace_error("the executor service did not answer a census")
}

/// A census as one line of JSON, the form the entrypoint prints.
///
/// ## Examples
///
/// ```gleam
/// assert executor.census_line(census.Census(1, 3, 2, ["a"]))
///   == "{\"service\":1,\"exec_proto\":3,\"policy_v\":2,\"features\":[\"a\"]}"
/// ```
///
pub fn census_line(here: Census) -> String {
  json.object([
    #("service", json.int(here.service)),
    #("exec_proto", json.int(here.exec_proto)),
    #("policy_v", json.int(here.policy_v)),
    #("features", json.array(here.features, json.string)),
  ])
  |> json.to_string
}

/// Runs `true` once, jailed, through the broker and the service, and
/// answers whether it exited 0 under full enforcement. A degraded result
/// (the host lacked a layer the helper would build) is refused and names
/// the skipped layers: a smoke that passed unjailed would prove nothing.
///
/// ## Examples
///
/// ```gleam
/// assert executor.smoke(up, scratch: "/tmp/s") == Ok(Nil)
/// ```
///
pub fn smoke(
  standalone: Standalone,
  scratch scratch: String,
) -> Result(Nil, String) {
  let #(op_id, _) =
    ids.mint_op(ids.generator(wall_clock(), seed: standalone.incarnation))
  let base = base_policy(scratch)
  let spec =
    broker.CallSpec(
      op_id:,
      step_id: "smoke",
      base_policy: base,
      requirements: base,
      grants: [],
      response: broker.RefuseNarrowed,
      demand: exec.BestEffort,
      argv: ["/usr/bin/true"],
      env: [#("PATH", "/usr/bin:/bin")],
      cwd: "/",
      budget: budget.Budget(max_outstanding: 1, deadline_ms: 0),
    )
  let events = process.new_subject()
  use _handle <- result.try(
    broker.clear_call(standalone.broker, spec, events:, waiting: 15_000)
    |> result.map_error(fn(refusal) {
      "the smoke call was refused: " <> string.inspect(refusal)
    }),
  )
  settled(events)
}

// Waits for the one settlement a cleared call always produces, skipping
// output chunks. Silence is a failure of the service, not of `true`.
fn settled(events: process.Subject(broker.CallEvent)) -> Result(Nil, String) {
  case process.receive(events, 20_000) {
    Error(Nil) -> Error("the smoke call never settled")
    Ok(broker.CallOutput(..)) -> settled(events)
    Ok(broker.CallSettled(broker.CallExited(result:))) ->
      case result.degraded, result.code {
        True, _ ->
          Error(
            "the smoke call ran without the required enforcement (degraded); "
            <> "skipped layers: "
            <> string.join(skipped_layers(result.enforcement), "; "),
          )
        False, 0 -> Ok(Nil)
        False, code -> Error("the smoke call exited " <> int.to_string(code))
      }
    Ok(broker.CallSettled(broker.CallFailed(failure:))) ->
      Error("the smoke call failed: " <> string.inspect(failure))
  }
}

// The helper reports every layer it did not build as `skip:` and the reason,
// so the refusal can name them.
fn skipped_layers(enforcement: List(String)) -> List(String) {
  list.filter_map(enforcement, fn(entry) {
    case string.starts_with(entry, exec.skip_prefix) {
      True -> Ok(string.drop_start(entry, string.length(exec.skip_prefix)))
      False -> Error(Nil)
    }
  })
}

/// Drains and shuts the executor down: stops the broker, then closes the
/// service, which refuses new work, cancels live executions, and closes the
/// pool. The answer is the pool's native-exit verdict, unchanged.
///
/// ## Examples
///
/// ```gleam
/// assert executor.drain(up) == Ok(Nil)
/// ```
///
pub fn drain(standalone: Standalone) -> Result(Nil, exec.RetirementFailure) {
  broker.stop(standalone.broker)
  service.close(
    standalone.service,
    draining: service.drain_ms,
    helpers: service.helpers_ms,
  )
}

/// The entrypoint. It boots, prints the census as one JSON line, runs the
/// smoke execution, drains, prints the verdict and exits 0 only when every
/// step succeeded.
pub fn main() -> Nil {
  let helper = choose_helper(argv.load().arguments, envoy.get(helper_variable))
  let scratch = scratch_root()
  let outcome = run(Config(helper:, scratch:, pool_size: 1))
  case outcome {
    Ok(Nil) -> Nil
    Error(reason) -> {
      io.println_error("executor: " <> reason)
      fail()
    }
  }
}

/// One whole life of the entrypoint against `config`, returning why it
/// failed, if it did. The scratch directory is removed after a drain that
/// returned `Ok`; when the drain could not confirm custody a jail may still
/// be using it, so it is left in place and its path is printed. `main` is
/// this plus an exit status.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(_) = executor.run(executor.Config("none", "/tmp/s", 1))
/// ```
///
pub fn run(config: Config) -> Result(Nil, String) {
  run_with(config, drain: drain)
}

/// `run` with the drain supplied, so a test can make it answer an
/// unconfirmed custody. The supplied drain must still close the executor it
/// is given.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(_) =
///   executor.run_with(config, drain: executor.drain)
/// ```
///
pub fn run_with(
  config: Config,
  drain drain: fn(Standalone) -> Result(Nil, exec.RetirementFailure),
) -> Result(Nil, String) {
  use up <- result.try(boot(config))
  let ran = smoke(up, scratch: config.scratch)

  // The census follows the smoke because features are what a helper said in
  // its hello: before the first spawn the answer is "unknown" (empty).
  let measured = census(up)
  case measured {
    Ok(here) -> io.println(census_line(here))
    Error(_) -> Nil
  }
  let verdict = drain(up)
  remove_scratch(config.scratch, verdict)
  io.println(
    "drain: "
    <> case verdict {
      Ok(Nil) -> "ok"
      Error(failure) -> "failed " <> string.inspect(failure)
    },
  )
  use _here <- result.try(measured)
  use Nil <- result.try(ran)
  verdict |> result.map_error(fn(failure) { string.inspect(failure) })
}

// Only a drain that answered `Ok` proves no jail is left, so only then is
// the scratch (the writable root and the helper's policy files) removed. On
// an unconfirmed custody it stays as evidence and the operator is told. A
// removal failure is reported and never changes the exit status.
fn remove_scratch(
  scratch: String,
  verdict: Result(Nil, exec.RetirementFailure),
) -> Nil {
  case verdict {
    Ok(Nil) ->
      case simplifile.delete(scratch) {
        Ok(Nil) -> Nil
        Error(error) ->
          io.println_error(
            "executor: could not remove "
            <> scratch
            <> ": "
            <> string.inspect(error),
          )
      }
    Error(_) ->
      io.println_error(
        "executor: custody of the helpers was not confirmed, so "
        <> scratch
        <> " was left in place; a jail may still be using it",
      )
  }
}

// A scratch under the OS temp area, distinct per incarnation so that two
// executors on one host do not share a policy-file directory.
fn scratch_root() -> String {
  let base = case envoy.get("TMPDIR") {
    Ok(dir) if dir != "" -> dir
    _ -> "/tmp"
  }
  base <> "/loom-executor-" <> int.to_string(mint_incarnation())
}

// A nonzero exit without a new `@external`: the entry process kills itself,
// which the runtime reports as a crash and exits 1. Reaching here means
// the reason has already been printed.
fn fail() -> Nil {
  process.kill(process.self())
}

fn wall_clock() -> clock.Clock {
  clock.from_function(fn() { mint_incarnation() / 1000 })
}
