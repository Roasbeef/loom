//// Satellite-host tests, all deterministic and in-process: a real broker
//// over `ChannelTransport` fake helpers, and a fake satellite peer that
//// speaks the cap channel. No live jail, no live socket.
////
//// They prove the host's half of the WP-J behaviour: the happy path, the
//// escaped-satellite tabletop (token denial + deadline kill), input-order
//// preservation under out-of-order completion, real per-clearance
//// cancellation, and the pooled budget under fan-out. Each peer computes
//// its verdict and returns it through the program `Outcome`, which the
//// blocking `satellite.run` hands straight back.

import broker/broker
import broker/budget
import broker/exec
import broker/framing.{type CapOutcome}
import broker/policy
import broker/token
import codemode/compile
import codemode/satellite
import core/clock
import core/ids
import core/msgpack.{type MsgPackValue}
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/string
import simplifile
import support/fake_helper
import support/satellite_peer.{type PeerCtx}

const t = 1_700_000_000_000

fn op_id() -> ids.OpId {
  let generator = ids.generator(clock.fixed(at: t), seed: 7)
  let #(op, _) = ids.mint_op(generator)
  op
}

fn exec_id() -> satellite.ExecId {
  satellite.ExecId(op_id: op_id(), step_id: "step-1")
}

fn artifact() -> compile.Artifact {
  compile.Artifact(
    build_root: "/tmp/loom-cm",
    beam_dir: "/tmp/loom-cm/ebin",
    entry_module: compile.entry_module,
    manifest_hash: "h",
  )
}

fn fresh_dir(name: String) -> String {
  let assert Ok(here) = simplifile.current_directory()
  let dir = here <> "/build/cmtest/sat-" <> name
  let _ = simplifile.delete(dir)
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  dir
}

fn config(dir: String, budget: budget.Budget) -> satellite.SatelliteConfig {
  satellite.SatelliteConfig(
    base_policy: policy.workspace_default("/work"),
    budget:,
    demand: exec.BestEffort,
    env: [#("PATH", "/usr/bin")],
    cwd: "/work",
    cap_socket_path: dir <> "/sock",
    entropy: token.production_entropy(),
    clock: clock.fixed(at: t),
    write_token_file: satellite.private_token_writer(dir),
    unlink_token_file: satellite.unlink_token_file,
    router: satellite.default_router,
    call_timeout_ms: 3000,
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
  started
}

fn echoing() -> fn() -> Result(exec.Helper, exec.CheckoutError) {
  fn() { Ok(fake_helper.start_helper(fake_helper.EchoNow)) }
}

fn holding() -> fn() -> Result(exec.Helper, exec.CheckoutError) {
  fn() { Ok(fake_helper.start_helper(fake_helper.HoldForCancel)) }
}

// --- happy path ----------------------------------------------------------

pub fn happy_path_returns_the_program_outcome_test() {
  let dir = fresh_dir("happy")
  let broker = start_broker(echoing())
  let cfg =
    config(dir, budget.Budget(max_outstanding: 8, deadline_ms: t + 20_000))
  let outcome =
    satellite.run(
      artifact(),
      exec_id(),
      broker,
      cfg,
      satellite_peer.launcher(finish_peer),
    )
  let assert Ok(satellite.Completed(value)) = outcome
  assert value == msgpack.StringValue("done")
  broker.stop(broker)
}

fn finish_peer(ctx: PeerCtx) -> Nil {
  satellite_peer.send_outcome(ctx, msgpack.StringValue("done"))
}

// --- escaped-satellite tabletop (WP-J exit criterion, in-process half) ---
//
// The kernel-enforced half of the tabletop — that a hostile `.beam` inside
// the jail reaches *nothing* on the filesystem or network — depends on the
// real Go sandbox and a target-tier kernel, and is deferred to `make e2e`
// (consistent with the existing sandbox degraded-mode practice). The two
// halves proved here are the ones the host owns: an unauthorized `cap_call`
// is denied, and a satellite that never returns is killed at the deadline.

pub fn cap_calls_without_the_token_are_all_denied_test() {
  let dir = fresh_dir("denied")
  let broker = start_broker(echoing())
  let cfg =
    config(dir, budget.Budget(max_outstanding: 8, deadline_ms: t + 20_000))
  let outcome =
    satellite.run(
      artifact(),
      exec_id(),
      broker,
      cfg,
      satellite_peer.launcher(denied_peer(3)),
    )
  let assert Ok(satellite.Completed(msgpack.IntValue(denied))) = outcome
  assert denied == 3
  broker.stop(broker)
}

fn denied_peer(count: Int) -> fn(PeerCtx) -> Nil {
  fn(ctx) {
    // 32 bytes that are not the minted cap token.
    let bogus = <<0xAA:size(256)>>
    each_id(count, fn(i) { satellite_peer.send_proc_run(ctx, bogus, i, ["x"]) })
    let results = satellite_peer.collect_results(ctx, count, 2000)
    let denied = count_matching(results, is_unauthorized)
    satellite_peer.send_outcome(ctx, msgpack.IntValue(denied))
  }
}

pub fn satellite_that_never_returns_is_killed_at_the_deadline_test() {
  let dir = fresh_dir("deadline")
  let broker = start_broker(echoing())
  let cfg = config(dir, budget.Budget(max_outstanding: 8, deadline_ms: t + 200))
  let outcome =
    satellite.run(
      artifact(),
      exec_id(),
      broker,
      cfg,
      satellite_peer.launcher(satellite_peer.wait_for_close),
    )
  assert outcome == Error(satellite.DeadlineExceeded)
  broker.stop(broker)
}

// --- order preservation --------------------------------------------------

pub fn parallel_results_preserve_input_order_test() {
  let dir = fresh_dir("order")
  let count = 3
  // A driver releases the gated executions in reverse of input order,
  // forcing out-of-order completion; the host must still tag each
  // cap_result with its own id so the peer reassembles input order.
  let handoff = process.new_subject()
  process.spawn(fn() {
    let control = process.new_subject()
    process.send(handoff, control)
    release_reverse(control, count)
  })
  let assert Ok(control) = process.receive(handoff, 1000)
  let broker =
    start_broker(fn() {
      Ok(fake_helper.start_helper(fake_helper.Gated(control:)))
    })
  let cfg =
    config(dir, budget.Budget(max_outstanding: 16, deadline_ms: t + 20_000))
  let outcome =
    satellite.run(
      artifact(),
      exec_id(),
      broker,
      cfg,
      satellite_peer.launcher(echo_peer(count)),
    )
  let assert Ok(satellite.Completed(value)) = outcome
  // Each result's stdout matched its own id (correlation held), and the
  // arrival order really was scrambled (the property is not vacuous).
  assert bool_field(value, "correct") == True
  assert bool_field(value, "out_of_order") == True
  broker.stop(broker)
}

fn echo_peer(count: Int) -> fn(PeerCtx) -> Nil {
  fn(ctx) {
    each_id(count, fn(i) {
      satellite_peer.send_proc_run(ctx, ctx.token, i, [
        "idx-" <> int.to_string(i),
      ])
    })
    let results = satellite_peer.collect_results(ctx, count, 5000)
    let arrival = list.map(results, fn(r) { r.0 })
    let out_of_order = arrival != id_list(count)
    let correct =
      list.all(results, fn(r) { stdout_has(r.1, "idx-" <> int.to_string(r.0)) })
    satellite_peer.send_outcome(
      ctx,
      msgpack.MapValue([
        #(msgpack.StringValue("correct"), msgpack.BoolValue(correct)),
        #(msgpack.StringValue("out_of_order"), msgpack.BoolValue(out_of_order)),
      ]),
    )
  }
}

fn release_reverse(control: Subject(fake_helper.Started), count: Int) -> Nil {
  // Release highest-index first, spacing each so its result lands before
  // the next is released — a deterministic reverse completion order, so
  // the input-order property under test is not vacuous.
  collect_started(control, count, [])
  |> list.sort(fn(a, b) { string.compare(argv_head(b), argv_head(a)) })
  |> list.each(fn(started) {
    process.send(started.release, fake_helper.Release(id: started.id))
    process.sleep(60)
  })
}

fn collect_started(
  control: Subject(fake_helper.Started),
  remaining: Int,
  acc: List(fake_helper.Started),
) -> List(fake_helper.Started) {
  case remaining <= 0 {
    True -> acc
    False ->
      case process.receive(control, 3000) {
        Ok(started) -> collect_started(control, remaining - 1, [started, ..acc])
        Error(Nil) -> acc
      }
  }
}

fn argv_head(started: fake_helper.Started) -> String {
  case started.argv {
    [head, ..] -> head
    [] -> ""
  }
}

// --- pooled budget -------------------------------------------------------

pub fn pooled_budget_refuses_fanout_past_the_cap_test() {
  let dir = fresh_dir("budget")
  let count = 4
  let broker = start_broker(holding())
  // One shared ledger of cap 2 for the whole execution: of four concurrent
  // cap_calls, exactly two are refused. Per-call budgets would refuse none.
  let cfg =
    config(dir, budget.Budget(max_outstanding: 2, deadline_ms: t + 20_000))
  let outcome =
    satellite.run(
      artifact(),
      exec_id(),
      broker,
      cfg,
      satellite_peer.launcher(budget_peer(count)),
    )
  let assert Ok(satellite.Completed(msgpack.IntValue(refused))) = outcome
  assert refused == 2
  broker.stop(broker)
}

fn budget_peer(count: Int) -> fn(PeerCtx) -> Nil {
  fn(ctx) {
    each_id(count, fn(i) {
      satellite_peer.send_proc_run(ctx, ctx.token, i, ["b-" <> int.to_string(i)])
    })
    // The two admitted calls hold open; only the refusals answer promptly.
    let results = satellite_peer.drain_results(ctx, 1500)
    let refused =
      count_matching(results, fn(outcome) { is_code(outcome, "budget") })
    satellite_peer.send_outcome(ctx, msgpack.IntValue(refused))
  }
}

// --- real cancellation ---------------------------------------------------

pub fn cancel_kills_the_losers_clearance_only_test() {
  let dir = fresh_dir("cancel")
  let broker = start_broker(holding())
  let cfg =
    config(dir, budget.Budget(max_outstanding: 8, deadline_ms: t + 20_000))
  let outcome =
    satellite.run(
      artifact(),
      exec_id(),
      broker,
      cfg,
      satellite_peer.launcher(cancel_peer),
    )
  let assert Ok(satellite.Completed(value)) = outcome
  // The cancelled clearance settled (cancel really fired at the broker),
  // with the cancel-driven exit code, while the other stayed outstanding.
  assert bool_field(value, "landed") == True
  assert bool_field(value, "cancel_code") == True
  assert bool_field(value, "other_pending") == True
  broker.stop(broker)
}

fn cancel_peer(ctx: PeerCtx) -> Nil {
  satellite_peer.send_proc_run(ctx, ctx.token, 0, ["a"])
  satellite_peer.send_proc_run(ctx, ctx.token, 1, ["b"])
  satellite_peer.send_cancel(ctx, 0)
  let results = satellite_peer.drain_results(ctx, 1500)
  let ids = list.map(results, fn(r) { r.0 })
  let landed = list.contains(ids, 0)
  let other_pending = !list.contains(ids, 1)
  let cancel_code =
    list.any(results, fn(r) { r.0 == 0 && exit_code_is(r.1, 137) })
  satellite_peer.send_outcome(
    ctx,
    msgpack.MapValue([
      #(msgpack.StringValue("landed"), msgpack.BoolValue(landed)),
      #(msgpack.StringValue("other_pending"), msgpack.BoolValue(other_pending)),
      #(msgpack.StringValue("cancel_code"), msgpack.BoolValue(cancel_code)),
    ]),
  )
}

// --- shared helpers ------------------------------------------------------

fn id_list(count: Int) -> List(Int) {
  build_ids(count - 1, [])
}

fn build_ids(index: Int, acc: List(Int)) -> List(Int) {
  case index < 0 {
    True -> acc
    False -> build_ids(index - 1, [index, ..acc])
  }
}

fn each_id(count: Int, run: fn(Int) -> Nil) -> Nil {
  list.each(id_list(count), run)
}

fn count_matching(
  results: List(#(Int, CapOutcome)),
  predicate: fn(CapOutcome) -> Bool,
) -> Int {
  results
  |> list.filter(fn(r) { predicate(r.1) })
  |> list.length
}

fn is_unauthorized(outcome: CapOutcome) -> Bool {
  is_code(outcome, "unauthorized")
}

fn is_code(outcome: CapOutcome, code: String) -> Bool {
  case outcome {
    framing.CapErr(code: found, message: _) -> found == code
    framing.CapOk(value: _) -> False
  }
}

fn stdout_has(outcome: CapOutcome, prefix: String) -> Bool {
  case outcome {
    framing.CapOk(value:) ->
      case map_field(value, "stdout") {
        Ok(msgpack.BinaryValue(bytes:)) ->
          case bit_array.to_string(bytes) {
            Ok(text) -> string.starts_with(text, prefix)
            Error(Nil) -> False
          }
        _ -> False
      }
    framing.CapErr(..) -> False
  }
}

fn exit_code_is(outcome: CapOutcome, code: Int) -> Bool {
  case outcome {
    framing.CapOk(value:) ->
      case map_field(value, "exit_code") {
        Ok(msgpack.IntValue(found)) -> found == code
        _ -> False
      }
    framing.CapErr(..) -> False
  }
}

fn bool_field(value: MsgPackValue, key: String) -> Bool {
  case map_field(value, key) {
    Ok(msgpack.BoolValue(flag)) -> flag
    _ -> False
  }
}

fn map_field(value: MsgPackValue, key: String) -> Result(MsgPackValue, Nil) {
  case value {
    msgpack.MapValue(entries:) ->
      list.find_map(entries, fn(entry) {
        case entry.0 == msgpack.StringValue(key) {
          True -> Ok(entry.1)
          False -> Error(Nil)
        }
      })
    _ -> Error(Nil)
  }
}
