//// Before-numbers for the exec helper pool, measured against the real
//// `loom-exec` under the real jail.
////
//// Issue #696 moves the pool behind an executor service in three
//// commits. Each of them claims to leave the cost of running a command
//// unchanged or better, and a claim like that needs a number taken before
//// the first commit and a command that retakes it after the last. This
//// module is that command. It is a measurement, not an assertion: the only
//// things it fails on are the things that make a number meaningless, such as
//// a call that never settles or a helper that cannot be spawned.
////
//// ## Flow
////
//// `bench_exec_test_` is the gate. Unless `LOOM_BENCH_EXEC=1` it does
//// nothing, because it takes a minute or two and spawns real jails.
//// Otherwise `run_all` opens the bench with `open_bench`, then runs the
//// probes in a fixed order, each through `emit`, which writes one JSON line
//// to stdout and to the output file. The probes are `meta`,
//// `spawn_to_ready`, `round_trip_warm`, `first_wide_batch`,
//// `cancel_to_settle`, `flood`, `leak_census`, `memory` and
//// `enforcement_fixture`. They share `start_plane`, which builds the same
//// pool-and-broker pair production builds, and `stop_plane`, which closes it
//// and returns the verdict `close_pool` gave.
////
//// ## Output
////
//// `make bench-exec` writes `build/bench-exec.jsonl` beside the package, or
//// the path in `LOOM_BENCH_OUT`, truncated at the start of a run so a file
//// is always one run. Every line carries `probe`, `n`, and, for probes that
//// time something, `p50_ms`, `p95_ms`, `max_ms` and `min_ms`, then the probe's
//// own fields, then `demand`: the enforcement demand every call was made
//// under. It is `BestEffort`, as the other real-helper suites use, because
//// a container without the cgroup-v2 pids ceiling would refuse anything
//// stricter before measuring it. The `enforcement_fixture` line records
//// what a stricter demand does instead.
////
//// ## Limits of the numbers
////
//// Wall-clock latencies on a shared machine move with whatever else it is
//// doing, so compare runs from the same machine and read the spread
//// (`p95_ms` against `p50_ms`) before the middle. Memory fields are `/proc`
//// resident-set readings and `erlang:memory(total)` after a full collection;
//// they are observations, not bounds.
////
//// ## Payload marker
////
//// Every long-running payload sleeps for `300.25` seconds rather than `300`.
//// No other program on a developer's machine does, so a process whose command
//// line carries it is one this benchmark started, and the leak census can
//// count it, and later kill it, without touching anyone else's `sleep`.

import broker/broker
import broker/budget
import broker/exec
import broker/internal/ffi_os
import broker/policy
import broker/support/bench_host as host
import broker/token
import core/clock
import core/ids
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import weft

// --- the gate ---------------------------------------------------------------

/// eunit's test representation, built in Gleam: a constructor with fields
/// compiles to a tagged tuple, so `Timeout(seconds, body)` is literally
/// `{timeout, Seconds, Body}`. A zero-arity `*_test_` generator returning it
/// is the only way a gleeunit-style suite gets a deadline longer than eunit's
/// default five seconds.
pub type EunitTest {
  /// Run `body`, failing it if it outlives `seconds`.
  Timeout(
    /// The deadline eunit enforces on the body.
    seconds: Int,
    /// The test itself.
    body: fn() -> Nil,
  )
}

/// Measures the exec pool when `LOOM_BENCH_EXEC=1`, and otherwise says it
/// did not.
///
/// The unset path prints a plain sentence to stderr and passes. It does not
/// print `SKIP`: the skip census fails a CI job on any `SKIP` line it cannot
/// match to a declaration, and a declaration for a test that is skipped on
/// every lane that runs the broker suite is stale on every lane that does
/// not. This is an opt-in measurement, like the soak suites, and an opt-in
/// that was not requested is not a dropped test.
///
/// ## Examples
///
/// `make bench-exec` sets the variable and runs only this module.
pub fn bench_exec_test_() -> EunitTest {
  case host.getenv("LOOM_BENCH_EXEC") {
    Ok("1") -> Timeout(240, run_all)
    Ok(_) | Error(Nil) -> Timeout(5, not_requested)
  }
}

fn not_requested() -> Nil {
  io.println_error(
    "bench_exec: not run; `make bench-exec` (LOOM_BENCH_EXEC=1) measures the exec pool against the real helper",
  )
}

// --- the bench and the plane ------------------------------------------------

// Everything a probe needs to build a pool: where output goes, the scratch
// directory the jail's workspace lives in, how helpers are spawned, and the
// enforcement demand calls are made under.
type Bench {
  Bench(
    out_path: String,
    work_dir: String,
    config: exec.SpawnConfig,
    demand: exec.EnforcementDemand,
  )
}

// One effect plane as the daemon builds it: a pool of helpers and a broker
// whose checkout seam borrows from it. `op_id` is shared by every call a
// probe makes, and each call takes a fresh `step_id`, which is the key the
// broker's budget ledger and token vault are indexed by.
type Plane {
  Plane(bench: Bench, pool: exec.Pool, owner: broker.Broker, op_id: ids.OpId)
}

// A call that ran to its terminal event: what it ended as, how many output
// bytes streamed first, how long the caller waited, and the monotonic
// instant it settled.
type Settled {
  Settled(
    outcome: broker.CallOutcome,
    bytes: Int,
    elapsed_us: Int,
    settled_at_us: Int,
  )
}

const default_output_bytes = 1_048_576

// The jail's workspace and scratch live under the package's build directory
// so a run leaves nothing outside it. The helper path matches the one the
// real-helper integration suite uses, so the same `make sandbox` serves both.
fn open_bench() -> Bench {
  let assert Ok(here) = simplifile.current_directory()
    as "the package directory is readable"
  let work_dir = here <> "/build/bench-exec"
  let helper_path = here <> "/../sandbox/loom-exec"
  let out_path =
    host.getenv("LOOM_BENCH_OUT")
    |> result.unwrap("build/bench-exec.jsonl")

  case exec.unjailed_skip_reason(exec.host_platform()) {
    Some(reason) -> panic as { "bench_exec needs a jail to measure: " <> reason }
    None -> Nil
  }
  let assert Ok(True) = simplifile.is_file(helper_path)
    as { "no loom-exec at " <> helper_path <> "; run `make sandbox`" }

  let assert Ok(Nil) = simplifile.create_directory_all(work_dir <> "/work")
    as "the jail workspace can be created"
  let assert Ok(Nil) = simplifile.create_directory_all(parent_of(out_path))
    as "the output directory can be created"

  // A run's file holds exactly that run, so the start truncates it.
  let assert Ok(Nil) = simplifile.write(out_path, "")
    as "the output file is writable"
  Bench(
    out_path:,
    work_dir:,
    config: exec.SpawnConfig(
      helper_path:,
      shell_path: "/bin/sh",
      base_policy: policy_with(work_dir, default_output_bytes),
      helper_args: [],
      tmp_dir: work_dir <> "/tmp",
      handshake_timeout_ms: 5000,
      cancel_grace_ms: 3000,
      heartbeat_interval_ms: 0,
    ),
    demand: exec.BestEffort,
  )
}

fn parent_of(path: String) -> String {
  let parts =
    string.split(path, "/")
    |> list.reverse
    |> list.drop(1)
    |> list.reverse

  case string.join(parts, "/") {
    "" -> "."
    directory -> directory
  }
}

// The policy every probe runs under, differing only in the per-stream output
// cap, which the flood probe varies. Base and requirement are the same value,
// so composition narrows nothing and the cap the helper enforces is exactly
// the one named here.
fn policy_with(work_dir: String, output_bytes: Int) -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    writable_roots: [work_dir <> "/work"],
    readable_roots: ["/"],
    protected: [],
    network: policy.NetworkOff,
    limits: policy.Limits(
      cpu_s: 30,
      wall_s: 60,
      mem_bytes: 536_870_912,
      pids: 64,
      fsize_bytes: 8_388_608,
      output_bytes:,
    ),
    env_allow: ["PATH"],
    scratch: policy.ScratchTmpfs,
    mounts: [],
  )
}

// The broker's clock is the monotonic one in milliseconds. A budget deadline
// is only ever compared with the same clock, so its origin does not matter.
fn now_ms() -> Int {
  host.now_us() / 1000
}

// Builds the pool and broker the way `client/serve` does: the pool's spawn
// factory is `prepare_helper`, and the broker's seams borrow and return
// through the pool. The pool starts empty and fills lazily, so a probe that
// wants warm helpers asks for them with `warm`.
fn start_plane(bench: Bench, size: Int) -> Plane {
  let assert Ok(pool) =
    exec.start_pool(size:, spawn: fn() { exec.prepare_helper(bench.config) })
    as "the benchmark pool starts"
  let assert Ok(owner) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.from_function(now_ms),
        checkout: fn() { exec.checkout(pool, waiting: 15_000) },
        checkin: fn(helper) { exec.checkin(pool, helper) },
      ),
    )
    as "the benchmark broker starts"

  let #(op_id, _) =
    ids.mint_op(ids.generator(clock.fixed(at: 1_700_000_000_000), seed: 696))
  Plane(bench:, pool:, owner:, op_id:)
}

// Stops admissions at the broker, then asks the pool for its retirement
// proof. The verdict is returned rather than asserted: the leak census
// exists to record what it says when a helper cannot be retired.
fn stop_plane(plane: Plane) -> Result(Nil, exec.RetirementFailure) {
  broker.stop(plane.owner)
  exec.close_pool(plane.pool, waiting: 10_000)
}

// Fills `count` slots and returns them, so the next calls find idle ready
// helpers. Every checkout is held before any is returned: returning one
// early would hand the same helper out again and warm a single slot.
fn warm(plane: Plane, count: Int) -> Nil {
  let helpers =
    list.repeat(Nil, count)
    |> list.map(fn(_) {
      exec.checkout(plane.pool, waiting: 15_000)
      |> result.map_error(string.inspect)
      |> must("warming checkout")
    })

  list.each(helpers, fn(helper) { exec.checkin(plane.pool, helper) })
}

fn must(result: Result(a, String), context: String) -> a {
  case result {
    Ok(value) -> value
    Error(reason) -> panic as { context <> ": " <> reason }
  }
}

// --- one call ---------------------------------------------------------------

fn spec(
  plane: Plane,
  argv: List(String),
  output_bytes: Int,
) -> broker.CallSpec {
  let policy = policy_with(plane.bench.work_dir, output_bytes)

  broker.CallSpec(
    op_id: plane.op_id,
    step_id: "bench-" <> int.to_string(host.unique()),
    base_policy: policy,
    requirements: policy,
    grants: [],
    response: broker.RefuseNarrowed,
    demand: plane.bench.demand,
    argv:,
    env: [#("PATH", "/usr/bin:/bin")],
    cwd: plane.bench.work_dir <> "/work",
    budget: budget.Budget(max_outstanding: 1, deadline_ms: now_ms() + 600_000),
  )
}

fn true_spec(plane: Plane) -> broker.CallSpec {
  spec(plane, ["/usr/bin/true"], default_output_bytes)
}

// A shell payload that prints `ready` once it is running, which is what lets
// a probe cancel a process that has started rather than one that is racing
// to. The first announces itself and then becomes `sleep`, so TERM reaches
// the sleeper and ends it on the first rung of the ladder.
const honours_term = "echo ready; exec sleep 300.25"

// The second ignores TERM and keeps ignoring it in the `sleep` it forks,
// because an ignored disposition survives exec. Only the KILL rung ends it.
const ignores_term = "trap '' TERM; echo ready; sleep 300.25"

fn shell(plane: Plane, script: String) -> broker.CallSpec {
  spec(plane, ["/bin/sh", "-c", script], default_output_bytes)
}

fn refusal_text(refusal: broker.Refusal) -> String {
  "refused: " <> string.inspect(refusal)
}

// Clears one call and drains its events to the terminal one. The clock starts
// before `clear_call`, so the sample is what a caller waits: checkout, token,
// dispatch, run and settlement together.
fn run_to_settle(
  plane: Plane,
  spec: broker.CallSpec,
) -> Result(Settled, String) {
  let events = process.new_subject()
  let started = host.now_us()
  use _handle <- result.try(
    broker.clear_call(plane.owner, spec, events:, waiting: 20_000)
    |> result.map_error(refusal_text),
  )
  await_settled(events, started, 0)
}

fn await_settled(
  events: Subject(broker.CallEvent),
  started_us: Int,
  bytes: Int,
) -> Result(Settled, String) {
  case process.receive(events, 60_000) {
    Ok(broker.CallOutput(data:, ..)) ->
      await_settled(events, started_us, bytes + bit_array.byte_size(data))

    Ok(broker.CallSettled(outcome:)) -> {
      let now = host.now_us()
      Ok(Settled(
        outcome:,
        bytes:,
        elapsed_us: now - started_us,
        settled_at_us: now,
      ))
    }

    Error(Nil) -> Error("no terminal event within 60 s")
  }
}

// Starts a call and returns once it has printed something, which for the
// shell payloads above means the jailed process is running.
fn start_until_output(
  plane: Plane,
  spec: broker.CallSpec,
) -> Result(#(broker.CallHandle, Subject(broker.CallEvent)), String) {
  let events = process.new_subject()
  use handle <- result.try(
    broker.clear_call(plane.owner, spec, events:, waiting: 20_000)
    |> result.map_error(refusal_text),
  )
  use Nil <- result.try(await_first_output(events))
  Ok(#(handle, events))
}

fn await_first_output(
  events: Subject(broker.CallEvent),
) -> Result(Nil, String) {
  case process.receive(events, 10_000) {
    Ok(broker.CallOutput(..)) -> Ok(Nil)
    Ok(broker.CallSettled(outcome:)) ->
      Error("settled before any output: " <> describe(outcome))
    Error(Nil) -> Error("no output within 10 s")
  }
}

// The cancel clock starts immediately before the cancel is sent, so the
// sample is the time from deciding to stop a call to being told it stopped.
fn cancel_and_settle(
  plane: Plane,
  handle: broker.CallHandle,
  events: Subject(broker.CallEvent),
) -> Result(Settled, String) {
  let started = host.now_us()
  broker.cancel(plane.owner, handle)
  await_settled(events, started, 0)
}

fn cancel_run(plane: Plane, script: String) -> Result(Settled, String) {
  use #(handle, events) <- result.try(start_until_output(
    plane,
    shell(plane, script),
  ))
  cancel_and_settle(plane, handle, events)
}

// What a call ended as, with no field that varies from run to run, so equal
// outcomes count as equal. A failure is named by its constructor alone.
fn describe(outcome: broker.CallOutcome) -> String {
  case outcome {
    broker.CallExited(result:) ->
      "exited code="
      <> int.to_string(result.code)
      <> " cancelled="
      <> string.inspect(result.cancelled)
    broker.CallFailed(failure:) -> "failed " <> failure_kind(failure)
  }
}

fn failure_kind(failure: exec.ExecFailure) -> String {
  case string.split(string.inspect(failure), "(") {
    [kind, ..] -> kind
    [] -> ""
  }
}

fn expect_exit(settled: Settled) -> exec.ExecResult {
  case settled.outcome {
    broker.CallExited(result:) -> result
    broker.CallFailed(failure:) ->
      panic as { "a call that must succeed failed: " <> failure_kind(failure) }
  }
}

// --- the numbers ------------------------------------------------------------

// Output values: just enough JSON for flat probe lines. `JLiteral` carries a
// token already in JSON form, which is how a bool is written without the
// bench growing a bool-typed field.
type Json {
  JStr(String)
  JInt(Int)
  JFloat(Float)
  JLiteral(String)
  JList(List(Json))
  JObject(List(#(String, Json)))
}

fn render(value: Json) -> String {
  case value {
    JStr(text) -> "\"" <> escape(text) <> "\""
    JInt(number) -> int.to_string(number)
    JFloat(number) -> float.to_string(number)
    JLiteral(token) -> token
    JList(items) -> "[" <> string.join(list.map(items, render), ",") <> "]"
    JObject(fields) ->
      "{"
      <> string.join(
        list.map(fields, fn(field) {
          "\"" <> escape(field.0) <> "\":" <> render(field.1)
        }),
        ",",
      )
      <> "}"
  }
}

fn escape(text: String) -> String {
  text
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  |> string.replace("\t", "\\t")
}

fn strings(items: List(String)) -> Json {
  JList(list.map(items, JStr))
}

fn ms(us: Int) -> Json {
  JFloat(float.to_precision(int.to_float(us) /. 1000.0, 3))
}

fn mib(bytes: Int) -> Json {
  JFloat(float.to_precision(int.to_float(bytes) /. 1_048_576.0, 2))
}

fn ms_list(samples: List(Int)) -> Json {
  JList(list.map(samples, ms))
}

// Nearest-rank percentile of an ascending list: the smallest sample that at
// least `pct` percent of the samples do not exceed.
fn percentile(sorted: List(Int), pct: Int) -> Int {
  let count = list.length(sorted)
  let rank = int.max({ pct * count + 99 } / 100, 1)

  sorted
  |> list.drop(rank - 1)
  |> list.first
  |> result.unwrap(0)
}

fn latency_fields(samples: List(Int)) -> List(#(String, Json)) {
  case list.sort(samples, int.compare) {
    [] -> []
    [lowest, ..] as sorted -> [
      #("p50_ms", ms(percentile(sorted, 50))),
      #("p95_ms", ms(percentile(sorted, 95))),
      #("max_ms", ms(percentile(sorted, 100))),
      #("min_ms", ms(lowest)),
    ]
  }
}

// Counts equal strings, for a tally of outcomes.
fn counts(items: List(String)) -> Json {
  items
  |> list.sort(string.compare)
  |> list.chunk(fn(item) { item })
  |> list.map(fn(group) {
    #(list.first(group) |> result.unwrap(""), JInt(list.length(group)))
  })
  |> JObject
}

// One line per probe, to stdout and to the output file. The file is the
// record: a passing eunit test's stdout is captured, so it is the progress
// line on stderr and the file that a person watching a run can follow.
fn emit(
  bench: Bench,
  name: String,
  n: Int,
  samples: List(Int),
  extras: List(#(String, Json)),
) -> Nil {
  let fields =
    list.flatten([
      [#("probe", JStr(name)), #("n", JInt(n))],
      latency_fields(samples),
      extras,
      [#("demand", JStr(string.inspect(bench.demand)))],
    ])
  let line = render(JObject(fields))
  io.println(line)
  io.println_error("bench_exec: " <> name)

  let assert Ok(Nil) = simplifile.append(bench.out_path, line <> "\n")
    as "the output file accepts a line"
  Nil
}

fn repeat(times: Int, body: fn() -> a) -> List(a) {
  list.repeat(Nil, times) |> list.map(fn(_) { body() })
}

fn elapsed(settled: List(Settled)) -> List(Int) {
  list.map(settled, fn(one) { one.elapsed_us })
}

fn closed_json(closed: Result(Nil, exec.RetirementFailure)) -> Json {
  JStr(string.inspect(closed))
}

// --- the run ----------------------------------------------------------------

fn run_all() -> Nil {
  let bench = open_bench()
  meta(bench)
  spawn_to_ready(bench)
  round_trip_warm(bench)
  first_wide_batch(bench)
  cancel_to_settle(bench)
  flood(bench, 1_048_576)
  flood(bench, 0)
  leak_census(bench)
  memory(bench)
  enforcement_fixture(bench)

  // The leak census kills what it finds; this is the last sweep, so that a
  // run which failed in the middle of a later probe still leaves nothing of
  // its own running.
  let _ = reap_leftovers(bench)
  Nil
}

// What the numbers below were taken on: the host, the helper, and what the
// helper says it can enforce. Features come from one standalone spawn so the
// line does not depend on a pool.
fn meta(bench: Bench) -> Nil {
  let assert Ok(helper) = exec.spawn_helper(bench.config)
    as "meta: a helper spawns"
  let assert exec.StatusReady(features) = exec.status(helper, waiting: 2000)
    as "meta: the helper is ready"
  let assert Ok(Nil) = exec.close(helper, waiting: 10_000)
    as "meta: the helper retires"

  emit(bench, "meta", 1, [], [
    #("os", JStr(ffi_os.os_name())),
    #("schedulers_online", JInt(ffi_os.schedulers_online())),
    #("default_pool_size", JInt(exec.default_pool_size())),
    #("helper_path", JStr(bench.config.helper_path)),
    #("hello_features", strings(features)),
    #("handshake_timeout_ms", JInt(bench.config.handshake_timeout_ms)),
    #("cancel_grace_ms", JInt(bench.config.cancel_grace_ms)),
    #("heartbeat_interval_ms", JInt(bench.config.heartbeat_interval_ms)),
  ])
}

// --- probe 1: spawn to ready --------------------------------------------------

// The cost of one helper from nothing: preparing the owner, opening the port,
// the shell's fd-3 redirection, the helper's own start, and its hello. This
// is the path the pool takes when it fills a slot, taken one helper at a time
// so no two spawns compete. Each helper is then closed, and that is timed too
// because a pool pays it on every retirement.
fn spawn_to_ready(bench: Bench) -> Nil {
  let runs = repeat(30, fn() { spawn_once(bench) })
  let ready = list.map(runs, fn(run) { run.0 })
  let closing = list.map(runs, fn(run) { run.1 })
  let refused = list.count(runs, fn(run) { result.is_error(run.2) })
  let closing_sorted = list.sort(closing, int.compare)

  emit(bench, "spawn_to_ready", list.length(runs), ready, [
    #("close_p50_ms", ms(percentile(closing_sorted, 50))),
    #("close_p95_ms", ms(percentile(closing_sorted, 95))),
    #("close_max_ms", ms(percentile(closing_sorted, 100))),
    #("close_unconfirmed", JInt(refused)),
  ])
}

fn spawn_once(
  bench: Bench,
) -> #(Int, Int, Result(Nil, exec.RetirementFailure)) {
  let started = host.now_us()
  let assert Ok(helper) = exec.prepare_helper(bench.config)
    as "spawn_to_ready: a helper is prepared"
  exec.begin(helper)
  let assert Ok(_features) =
    exec.await_ready(helper, waiting: bench.config.handshake_timeout_ms + 1000)
    as "spawn_to_ready: the handshake completes"

  let ready_us = host.now_us() - started
  let closing = host.now_us()
  let retired = exec.close(helper, waiting: 10_000)
  #(ready_us, host.now_us() - closing, retired)
}

// --- probe 2: warm round trip ---------------------------------------------------

// The steady-state cost of one command: a pool of four whose helpers are
// already up, a command that does nothing, and a caller that waits for the
// terminal event. What is left is checkout, token, dispatch, the jail's own
// setup and teardown, and settlement.
fn round_trip_warm(bench: Bench) -> Nil {
  let plane = start_plane(bench, 4)
  warm(plane, 4)

  let settled =
    repeat(100, fn() {
      run_to_settle(plane, true_spec(plane)) |> must("round_trip_warm")
    })
  let failures = list.count(settled, fn(one) { expect_exit(one).code != 0 })
  let closed = stop_plane(plane)

  emit(bench, "round_trip_warm", list.length(settled), elapsed(settled), [
    #("pool_size", JInt(4)),
    #("nonzero_exits", JInt(failures)),
    #("close_pool", closed_json(closed)),
  ])
}

// --- probe 3: first wide batch ---------------------------------------------------

// What the first fan-out of a session pays. Eight callers arrive at once at a
// pool of four that has not spawned anything, so the batch dispatches behind a
// series of handshakes and then queues for slots. The same batch is then
// repeated on the pool the first one warmed. Three fresh pools give three
// batches of each, because one cold batch is an anecdote.
fn first_wide_batch(bench: Bench) -> Nil {
  let batches =
    repeat(3, fn() {
      let plane = start_plane(bench, 4)
      let cold = wide_batch(plane, 8)
      let warm_batch = wide_batch(plane, 8)
      let closed = stop_plane(plane)
      #(cold, warm_batch, closed)
    })
  let cold = list.map(batches, fn(batch) { batch.0 })
  let warmed = list.map(batches, fn(batch) { batch.1 })

  emit(
    bench,
    "first_wide_batch",
    list.length(cold) * 8,
    list.flat_map(cold, fn(batch) { batch.1 }),
    [
      #("width", JInt(8)),
      #("pool_size", JInt(4)),
      #("batches", JInt(list.length(batches))),
      #("cold_batch_ms", ms_list(list.map(cold, fn(batch) { batch.0 }))),
      #("warm_batch_ms", ms_list(list.map(warmed, fn(batch) { batch.0 }))),
      #(
        "warm_call_p50_ms",
        ms(percentile(
          list.sort(list.flat_map(warmed, fn(batch) { batch.1 }), int.compare),
          50,
        )),
      ),
      #(
        "close_pool",
        JList(list.map(batches, fn(batch) { closed_json(batch.2) })),
      ),
    ],
  )
}

// Runs `width` calls from `width` processes at once and returns the time from
// the start to the last settlement, with each call's own latency. weft runs
// the tasks under a deadline and with a limit equal to the width, so none
// waits for another to finish before it starts.
fn wide_batch(plane: Plane, width: Int) -> #(Int, List(Int)) {
  let started = host.now_us()
  let outcomes =
    list.repeat(Nil, width)
    |> list.map(fn(_) { fn() { timed_true(plane) } })
    |> weft.new
    |> weft.limit(width)
    |> weft.deadline(120_000)
    |> weft.start
  let finished = weft.values(outcomes)
  assert list.length(finished) == width as "every wide-batch call completed"

  let last_settled =
    finished
    |> list.map(fn(call) { call.1 })
    |> list.reduce(int.max)
    |> result.unwrap(started)
  #(last_settled - started, list.map(finished, fn(call) { call.0 }))
}

fn timed_true(plane: Plane) -> Result(#(Int, Int), String) {
  use settled <- result.try(run_to_settle(plane, true_spec(plane)))
  let _result = expect_exit(settled)
  Ok(#(settled.elapsed_us, settled.settled_at_us))
}

// --- probe 4: cancel to settle ------------------------------------------------------

// From sending a cancel to being told the call is over. A payload that takes
// TERM ends on the ladder's first rung; one that ignores it holds out for the
// helper's two-second grace and is then killed, so its number is the ladder
// rather than the pool.
fn cancel_to_settle(bench: Bench) -> Nil {
  let plane = start_plane(bench, 2)
  warm(plane, 2)

  let honoured =
    repeat(10, fn() {
      cancel_run(plane, honours_term) |> must("cancel (TERM honoured)")
    })
  let ignored =
    repeat(5, fn() {
      cancel_run(plane, ignores_term) |> must("cancel (TERM ignored)")
    })
  let closed = stop_plane(plane)

  emit(bench, "cancel_to_settle", list.length(honoured), elapsed(honoured), [
    #("payload", JStr(honours_term)),
    #("outcomes", counts(list.map(honoured, fn(one) { describe(one.outcome) }))),
  ])
  emit(
    bench,
    "cancel_to_settle_term_ignored",
    list.length(ignored),
    elapsed(ignored),
    [
      #("payload", JStr(ignores_term)),
      #(
        "outcomes",
        counts(list.map(ignored, fn(one) { describe(one.outcome) })),
      ),
      #("close_pool", closed_json(closed)),
    ],
  )
}

// --- probe 5: flood -------------------------------------------------------------------

// Where the relay stands when the cancel lands: the mark is taken at the
// instant of the cancel, so everything after it is what the flood cost beyond
// the decision to stop.
type CancelMark {
  CancelMark(at_us: Int, call_us: Int, bytes: Int, memory_bytes: Int)
}

// What a flooding call has delivered so far. `mark` is `None` until the
// deadline passes and the cancel is sent; `settled` is `None` until the
// terminal event arrives.
type Flood {
  Flood(
    bytes: Int,
    chunks: Int,
    truncated_chunks: Int,
    last_output_us: Int,
    mark: Option(CancelMark),
    settled: Option(#(Int, broker.CallOutcome)),
  )
}

// `yes` writes as fast as it is read. Under the one-mebibyte cap the helper
// truncates the stream and the harness sees about a mebibyte; under no cap
// the harness sees everything the relay can carry. The probe lets it run for
// three seconds, cancels, and records how much arrived, how long the cancel
// took to settle, and how much the BEAM grew by while it was happening.
fn flood(bench: Bench, limit: Int) -> Nil {
  let plane = start_plane(bench, 1)
  warm(plane, 1)

  let before = host.vm_settled_memory()
  let events = process.new_subject()
  let assert Ok(handle) =
    broker.clear_call(
      plane.owner,
      spec(plane, ["/usr/bin/yes"], limit),
      events:,
      waiting: 20_000,
    )
    as "flood: the call clears"
  let deadline = host.now_us() + 3_000_000
  let finished =
    flood_loop(plane, handle, events, deadline, Flood(0, 0, 0, 0, None, None))
  let after = host.vm_settled_memory()
  let closed = stop_plane(plane)

  emit_flood(bench, limit, finished, after - before, closed)
}

fn flood_loop(
  plane: Plane,
  handle: broker.CallHandle,
  events: Subject(broker.CallEvent),
  deadline_us: Int,
  flood: Flood,
) -> Flood {
  let flood = cancel_when_due(plane, handle, deadline_us, flood)

  case process.receive(events, 20) {
    Ok(broker.CallOutput(data:, truncated:, ..)) ->
      flood_loop(
        plane,
        handle,
        events,
        deadline_us,
        count_chunk(flood, data, case truncated {
          True -> 1
          False -> 0
        }),
      )

    Ok(broker.CallSettled(outcome:)) ->
      Flood(..flood, settled: Some(#(host.now_us(), outcome)))

    // A quiet interval is how a capped flood looks after the cap, and it is
    // also how a cancel that never settles looks. The loop head re-checks the
    // deadline either way; this arm only gives up on the second case.
    Error(Nil) ->
      case flood_overdue(flood) {
        True -> flood
        False -> flood_loop(plane, handle, events, deadline_us, flood)
      }
  }
}

fn count_chunk(flood: Flood, data: BitArray, truncated_chunks: Int) -> Flood {
  Flood(
    ..flood,
    bytes: flood.bytes + bit_array.byte_size(data),
    chunks: flood.chunks + 1,
    truncated_chunks: flood.truncated_chunks + truncated_chunks,
    last_output_us: host.now_us(),
  )
}

// The cancel is sent once, at the first pass through the loop head after the
// deadline. Memory is read before the cancel so the mark's reading is what the
// flood had cost by then, not what the cancel's own traffic added.
fn cancel_when_due(
  plane: Plane,
  handle: broker.CallHandle,
  deadline_us: Int,
  flood: Flood,
) -> Flood {
  case flood.mark, host.now_us() >= deadline_us {
    None, True -> {
      let #(_ports, _processes, memory_bytes) = host.vm_counts()
      let at_us = host.now_us()
      broker.cancel(plane.owner, handle)
      let call_us = host.now_us() - at_us
      Flood(
        ..flood,
        mark: Some(CancelMark(
          at_us:,
          call_us:,
          bytes: flood.bytes,
          memory_bytes:,
        )),
      )
    }
    Some(_), _ | None, False -> flood
  }
}

// A cancel that has gone a full minute without a terminal event is a finding,
// and the loop returns it as one rather than waiting out the test deadline.
fn flood_overdue(flood: Flood) -> Bool {
  case flood.mark {
    Some(mark) -> host.now_us() - mark.at_us > 60_000_000
    None -> False
  }
}

fn emit_flood(
  bench: Bench,
  limit: Int,
  flood: Flood,
  retained_bytes: Int,
  closed: Result(Nil, exec.RetirementFailure),
) -> Nil {
  let mark = option.unwrap(flood.mark, CancelMark(0, 0, 0, 0))
  let settle_us = case flood.settled {
    Some(#(at, _)) -> at - mark.at_us
    None -> -1
  }
  let tail_us = int.max(flood.last_output_us - mark.at_us, 0)
  let #(outcome, helper_bytes, helper_truncated) = case flood.settled {
    Some(#(_, broker.CallExited(result:))) -> #(
      describe(broker.CallExited(result:)),
      result.stdout_bytes,
      string.inspect(result.stdout_truncated),
    )
    Some(#(_, broker.CallFailed(failure:))) -> #(
      describe(broker.CallFailed(failure:)),
      0,
      "",
    )
    None -> #("no terminal event", 0, "")
  }

  emit(bench, "flood", 1, [settle_us], [
    #("limit_bytes", JInt(limit)),
    #("run_ms", JInt(3000)),
    #("bytes_received", JInt(flood.bytes)),
    #("bytes_at_cancel", JInt(mark.bytes)),
    #("chunks", JInt(flood.chunks)),
    #("truncated_chunks", JInt(flood.truncated_chunks)),
    #("cancel_call_ms", ms(mark.call_us)),
    #("output_after_cancel_ms", ms(tail_us)),
    #("beam_memory_at_cancel_mib", mib(mark.memory_bytes)),
    #("beam_retained_mib", mib(retained_bytes)),
    #("outcome", JStr(outcome)),
    #("helper_stdout_bytes", JInt(helper_bytes)),
    #("helper_stdout_truncated", JStr(helper_truncated)),
    #("close_pool", closed_json(closed)),
  ])
}

// --- probe 6: leak census --------------------------------------------------------------

// What a hundred calls leave behind. Most succeed, some are cancelled, and
// three are cancelled after their helper has been stopped with SIGSTOP, so it
// cannot act on the cancel: the pool's own deadline has to escalate. The
// census then compares ports, processes and OS processes before and after,
// and records what `close_pool` says, whatever it says.
type StepKind {
  Succeed
  CancelStep
  Escalate
}

type Step {
  Step(kind: String, result: String, elapsed_us: Int)
}

fn step_kind(index: Int) -> StepKind {
  case list.contains([25, 55, 85], index), index % 5 {
    True, _ -> Escalate
    False, 0 -> CancelStep
    False, _ -> Succeed
  }
}

fn leak_census(bench: Bench) -> Nil {
  let baseline = host.helper_os_pids()
  let #(ports_before, processes_before, _) = host.vm_counts()
  let memory_before = host.vm_settled_memory()
  let global_before = list.length(host.census(["loom-exec", "bwrap"]))

  let plane = start_plane(bench, 4)
  warm(plane, 4)
  let steps = census_loop(plane, baseline, 1, [])

  let #(ports_busy, processes_busy, _) = host.vm_counts()
  let closing = host.now_us()
  let closed = stop_plane(plane)
  let close_us = host.now_us() - closing

  // Let ports and exit signals drain before the after-reading.
  process.sleep(1000)
  let #(ports_after, processes_after, _) = host.vm_counts()
  let memory_after = host.vm_settled_memory()
  let global_after = list.length(host.census(["loom-exec", "bwrap"]))
  let leftovers = host.census(ours_markers(bench))
  let killed = reap_leftovers(bench)

  emit(bench, "leak_census", list.length(steps), [], [
    #("steps", counts(list.map(steps, step_label))),
    #(
      "escalation_settle_ms",
      ms_list(
        steps
        |> list.filter(fn(step) { string.starts_with(step.kind, "escalation") })
        |> list.map(fn(step) { step.elapsed_us }),
      ),
    ),
    #("close_pool", closed_json(closed)),
    #("close_pool_ms", ms(close_us)),
    #("ports_delta_before_close", JInt(ports_busy - ports_before)),
    #("processes_delta_before_close", JInt(processes_busy - processes_before)),
    #("ports_delta_after_close", JInt(ports_after - ports_before)),
    #("processes_delta_after_close", JInt(processes_after - processes_before)),
    #("beam_retained_kib", JInt({ memory_after - memory_before } / 1024)),
    #("os_loom_exec_or_bwrap_before", JInt(global_before)),
    #("os_loom_exec_or_bwrap_after", JInt(global_after)),
    #("os_ours_left_after_close", JInt(list.length(leftovers))),
    #("os_ours_left", strings(describe_processes(leftovers))),
    #("os_ours_killed_by_cleanup", JInt(killed)),
  ])
}

fn census_loop(
  plane: Plane,
  baseline: List(Int),
  index: Int,
  steps: List(Step),
) -> List(Step) {
  let refusals =
    list.count(steps, fn(step) { string.starts_with(step.result, "refused") })

  case index > 100 || refusals >= 5 {
    True -> list.reverse(steps)
    False ->
      census_loop(plane, baseline, index + 1, [
        census_step(plane, baseline, index),
        ..steps
      ])
  }
}

fn census_step(plane: Plane, baseline: List(Int), index: Int) -> Step {
  case step_kind(index) {
    Succeed -> run_to_settle(plane, true_spec(plane)) |> step_of("success")
    CancelStep -> cancel_run(plane, honours_term) |> step_of("cancel")
    Escalate -> escalate(plane, baseline)
  }
}

// Stops the busy helper dead, then cancels. A stopped process receives
// nothing, so the cancel frame goes unanswered until the pool's grace expires.
// A pid that cannot be isolated is recorded in the label and the call is
// cancelled anyway, so a failed arrangement never leaves a payload running.
fn escalate(plane: Plane, baseline: List(Int)) -> Step {
  let started = start_until_output(plane, shell(plane, honours_term))
  let label = case started {
    Error(_) -> "escalation:not-started"
    Ok(_) ->
      case host.busy_helper_os_pid(exclude: baseline) {
        Ok(victim) -> {
          host.signal(victim, "STOP")
          "escalation:stopped"
        }
        Error(Nil) -> "escalation:unstopped"
      }
  }

  started
  |> result.try(fn(running) { cancel_and_settle(plane, running.0, running.1) })
  |> step_of(label)
}

fn step_of(result: Result(Settled, String), kind: String) -> Step {
  case result {
    Ok(settled) ->
      Step(
        kind:,
        result: describe(settled.outcome),
        elapsed_us: settled.elapsed_us,
      )
    Error(reason) -> Step(kind:, result: reason, elapsed_us: 0)
  }
}

fn step_label(step: Step) -> String {
  step.kind <> ": " <> step.result
}

// Processes this benchmark can be identified as having started: anything
// carrying its workspace path, the helper's path, or the payload marker.
fn ours_markers(bench: Bench) -> List(String) {
  [bench.work_dir, bench.config.helper_path, "300.25"]
}

fn describe_processes(found: List(#(Int, String, String))) -> List(String) {
  found
  |> list.take(8)
  |> list.map(fn(entry) {
    int.to_string(entry.0)
    <> " "
    <> entry.1
    <> ": "
    <> string.slice(entry.2, 0, 100)
  })
}

// Kills this benchmark's own leftovers and says how many. Only processes of
// the four kinds a jail leaves are touched, so the shell, the test runner
// and the editor that started the run are never in the set.
fn reap_leftovers(bench: Bench) -> Int {
  host.census(ours_markers(bench))
  |> list.filter(fn(entry) {
    list.contains(["loom-exec", "bwrap", "sleep", "sh"], entry.1)
  })
  |> list.map(fn(entry) { host.signal(entry.0, "KILL") })
  |> list.length
}

// --- probe 7: memory ---------------------------------------------------------------------

// The resident cost of the machinery: one idle helper, a helper holding a
// running `sleep` with its jail, and the BEAM's own growth for a warm pool of
// four. The helpers' pids are those that appeared since the probe began, so
// anything an earlier probe left cannot be mistaken for them.
fn memory(bench: Bench) -> Nil {
  let baseline = host.helper_os_pids()
  let before = host.vm_settled_memory()
  let plane = start_plane(bench, 4)
  warm(plane, 4)

  let after = host.vm_settled_memory()
  let idle =
    host.helper_os_pids()
    |> list.filter(fn(pid) { !list.contains(baseline, pid) })
    |> list.map(root_rss_kb)
  let running = running_tree(plane, baseline)
  let closed = stop_plane(plane)

  emit(bench, "memory", 1, [], [
    #("idle_helper_rss_kb", JList(list.map(idle, JInt))),
    #(
      "running_tree",
      strings(list.map(running, fn(m) { m.1 <> ":" <> int.to_string(m.2) })),
    ),
    #("running_tree_total_kb", JInt(sum(list.map(running, fn(m) { m.2 })))),
    #(
      "running_sleep_rss_kb",
      JInt(
        running
        |> list.filter(fn(m) { m.1 == "sleep" })
        |> list.map(fn(m) { m.2 })
        |> sum,
      ),
    ),
    #("beam_pool_of_4_delta_kib", JInt({ after - before } / 1024)),
    #("beam_bytes_per_helper", JInt({ after - before } / 4)),
    #("close_pool", closed_json(closed)),
  ])
}

fn root_rss_kb(pid: Int) -> Int {
  host.proc_tree(pid)
  |> list.find(fn(member) { member.0 == pid })
  |> result.map(fn(member) { member.2 })
  |> result.unwrap(0)
}

fn sum(values: List(Int)) -> Int {
  list.fold(values, 0, int.add)
}

// Runs a sleeper, reads the busy helper's process tree while it runs, and then
// cancels it. An unlocatable helper reads as an empty tree.
fn running_tree(
  plane: Plane,
  baseline: List(Int),
) -> List(#(Int, String, Int)) {
  let #(handle, events) =
    start_until_output(plane, shell(plane, honours_term))
    |> must("memory: the sleeper starts")
  let tree =
    host.busy_helper_os_pid(exclude: baseline)
    |> result.map(host.proc_tree)
    |> result.unwrap([])
  let _settled =
    cancel_and_settle(plane, handle, events)
    |> must("memory: the sleeper stops")
  tree
}

// --- probe 8: the enforcement fixture -------------------------------------------------------

// The exact list of layers a trivial command reports as applied, and whether
// the helper called the run degraded. A later lane-equivalence test compares
// this line byte for byte, so it carries no timing and no field that varies.
// The same command under a strict demand is recorded as well, since which
// demand a development container can meet is itself part of the baseline.
fn enforcement_fixture(bench: Bench) -> Nil {
  let plane = start_plane(bench, 1)
  let result =
    run_to_settle(plane, true_spec(plane))
    |> must("enforcement fixture")
    |> expect_exit
  let strict =
    run_to_settle(
      plane,
      broker.CallSpec(..true_spec(plane), demand: exec.PlatformEnforcement),
    )
    |> must("enforcement fixture (strict)")
  let closed = stop_plane(plane)

  emit(bench, "enforcement_fixture", 1, [], [
    #("enforcement", strings(result.enforcement)),
    #("degraded", JLiteral(string.lowercase(string.inspect(result.degraded)))),
    #("code", JInt(result.code)),
    #("platform_enforcement_outcome", JStr(describe(strict.outcome))),
    #("close_pool", closed_json(closed)),
  ])
}
