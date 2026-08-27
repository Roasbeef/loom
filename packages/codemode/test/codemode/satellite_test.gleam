//// Satellite-host tests, all deterministic and in-process: a real broker
//// over `ChannelTransport` fake helpers, and a fake satellite peer that
//// speaks the cap channel. No live jail, no live socket.
////
//// They prove the host's half of the WP-J behaviour: the happy path, the
//// escaped-satellite tabletop (an unauthenticated `cap_call` denied, the
//// genuine token buying no policy, and the deadline kill), the node being
//// destroyed on the two races that used to drop it, envelope validation of
//// the terminal frame, input-order preservation under out-of-order
//// completion, real per-clearance cancellation, and the pooled budget under
//// fan-out. Each peer computes its verdict and returns it through the
//// program `Outcome`, which the blocking `satellite.run` hands straight
//// back.

import broker/broker
import broker/budget
import broker/exec
import broker/framing.{type CapOutcome}
import broker/policy
import broker/token
import codemode/compile
import codemode/enforcement
import codemode/identity
import codemode/satellite
import core/clock
import core/ids
import core/msgpack.{type MsgPackValue}
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

// The run phase of one execution, derived from the one identity the
// execution is minted with. There is no way to hand the host a second one:
// `SatelliteConfig` carries no coordinates and no budget.
fn run_phase(budget: budget.Budget) -> identity.PhaseIdentity {
  identity.for_execution(op_id: op_id(), step_id: "step-1", budget:)
  |> identity.run_phase
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

fn config(dir: String) -> satellite.SatelliteConfig {
  satellite.SatelliteConfig(
    base_policy: policy.workspace_default("/work"),
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
  let cfg = config(dir)
  let outcome =
    satellite.run(
      artifact(),
      run_phase(budget.Budget(max_outstanding: 8, deadline_ms: t + 20_000)),
      broker,
      cfg,
      satellite_peer.launcher(finish_peer),
    ).outcome
  let assert Ok(satellite.Completed(value)) = outcome
  assert value == msgpack.StringValue("done")
  broker.stop(broker)
}

fn finish_peer(ctx: PeerCtx) -> Nil {
  satellite_peer.send_outcome(ctx, msgpack.StringValue("done"))
}

// --- the node's enforcement report rides out with the outcome (issue #5) --

pub fn a_completed_run_carries_the_nodes_enforcement_report_test() {
  let dir = fresh_dir("node-report")
  let broker = start_broker(echoing())
  let cfg = config(dir)
  let report =
    enforcement.Reported(entries: ["bwrap", "seccomp-net"], degraded: False)
  let ran =
    satellite.run(
      artifact(),
      run_phase(budget.Budget(max_outstanding: 8, deadline_ms: t + 20_000)),
      broker,
      cfg,
      satellite_peer.reporting_launcher(connected_then_finish, report),
    )
  assert ran.outcome == Ok(satellite.Completed(msgpack.StringValue("done")))
  // What the launcher learned on teardown reaches the caller *with* the
  // outcome. It used to be published on a side channel the host's own
  // teardown raced, so a run exactly like this one — healthy, prompt —
  // reported nothing for the node.
  assert ran.node == report
  broker.stop(broker)
}

// A peer that makes one capability call and waits for its settlement
// before reporting its outcome. The settlement can only reach it through
// `CapConnection.send`, which exists only once the host has taken the
// connection — so by the time the terminal frame is written, the host owns
// `destroy` and must carry the report out itself. (The peers that finish
// instantly settle before the hand-over, which is a different path:
// `hand_over` destroys the node and carries the report back.)
fn connected_then_finish(ctx: PeerCtx) -> Nil {
  satellite_peer.send_proc_run(ctx, ctx.token, 1, ["/bin/echo", "hi"])
  let _settled = satellite_peer.collect_results(ctx, 1, 3000)
  satellite_peer.send_outcome(ctx, msgpack.StringValue("done"))
}

// --- escaped-satellite tabletop (WP-J exit criterion, in-process half) ---
//
// The kernel-enforced half of the tabletop — a hostile `.beam` loaded
// straight into the node, bypassing vetting and the cap channel entirely —
// needs the real Go sandbox and a kernel to enforce with, so it lives
// there: the `unvetted beam denied host write, secret, and network` probe
// in `packages/sandbox/internal/selftest`, which `make selftest` runs and
// `.github/enforcement-expectations` declares required of the jail CI job.
// The two halves proved here are the ones the host owns: an unauthorized
// `cap_call` is denied, and a satellite that never returns is killed at
// the deadline.

pub fn cap_calls_without_the_token_are_all_denied_test() {
  let dir = fresh_dir("denied")
  let broker = start_broker(echoing())
  let cfg = config(dir)
  let outcome =
    satellite.run(
      artifact(),
      run_phase(budget.Budget(max_outstanding: 8, deadline_ms: t + 20_000)),
      broker,
      cfg,
      satellite_peer.launcher(denied_peer(3)),
    ).outcome
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
  let cfg = config(dir)
  let outcome =
    satellite.run(
      artifact(),
      run_phase(budget.Budget(max_outstanding: 8, deadline_ms: t + 200)),
      broker,
      cfg,
      satellite_peer.launcher(satellite_peer.wait_for_close),
    ).outcome
  assert outcome == Error(satellite.DeadlineExceeded)
  broker.stop(broker)
}

// --- the launched node is destroyed on every exit path (CH-F3) ----------
//
// `CapConnection.destroy` is the host's only handle on the launched node
// and its socket. Two races used to drop it: a launch that outlasts the
// wall deadline, and a channel that closes while the connection is still
// in flight. Either one leaks a live jailed node past its deadline.

pub fn a_launch_outlasting_the_deadline_still_destroys_the_node_test() {
  let dir = fresh_dir("late-launch")
  let broker = start_broker(echoing())
  // The wall deadline is 100ms; the jail spawn takes four times that.
  let cfg = config(dir)
  let destroyed = process.new_subject()
  let outcome =
    satellite.run(
      artifact(),
      run_phase(budget.Budget(max_outstanding: 8, deadline_ms: t + 100)),
      broker,
      cfg,
      fn(_spec) {
        process.sleep(400)
        Ok(recording_connection(destroyed))
      },
    ).outcome
  assert outcome == Error(satellite.DeadlineExceeded)
  assert process.receive(destroyed, 2000) == Ok(Nil)
  broker.stop(broker)
}

pub fn a_connection_arriving_after_the_host_stops_is_destroyed_test() {
  let dir = fresh_dir("late-connect")
  let broker = start_broker(echoing())
  let cfg = config(dir)
  let destroyed = process.new_subject()
  // The cap channel closes before the launcher hands its connection back,
  // so the host settles and stops with the connection still in flight.
  let outcome =
    satellite.run(
      artifact(),
      run_phase(budget.Budget(max_outstanding: 8, deadline_ms: t + 20_000)),
      broker,
      cfg,
      fn(spec) {
        process.send(spec.wire, satellite.WireClosed(reason: "socket closed"))
        process.sleep(100)
        Ok(recording_connection(destroyed))
      },
    ).outcome
  assert outcome == Error(satellite.SatelliteGone("socket closed"))
  assert process.receive(destroyed, 2000) == Ok(Nil)
  broker.stop(broker)
}

fn recording_connection(destroyed: Subject(Nil)) -> satellite.CapConnection {
  satellite.CapConnection(send: fn(_bytes) { Nil }, destroy: fn() {
    process.send(destroyed, Nil)
    enforcement.Unreported("this test launcher runs no node")
  })
}

// --- the real token buys no policy (CH-F4) -------------------------------
//
// The token file is bind-mounted readable into the jail, so a hostile
// `.beam` can read it and present the genuine token. This case takes that
// adversary at its word: it presents the *real* token, and the call is
// still refused — by policy, at the broker, on this one call. The token
// authenticates the channel; it is not a bearer capability that widens what
// the channel may ask for.

pub fn the_real_token_does_not_widen_policy_test() {
  let dir = fresh_dir("policy")
  let broker = start_broker(echoing())
  let cfg = satellite.SatelliteConfig(..config(dir), router: network_router)
  let outcome =
    satellite.run(
      artifact(),
      run_phase(budget.Budget(max_outstanding: 8, deadline_ms: t + 20_000)),
      broker,
      cfg,
      satellite_peer.launcher(real_token_peer),
    ).outcome
  let assert Ok(satellite.Completed(value)) = outcome
  // The token was accepted (no `unauthorized`) and the call was refused
  // anyway, by the broker's per-call policy check.
  assert bool_field(value, "authenticated") == True
  assert bool_field(value, "policy_refused") == True
  broker.stop(broker)
}

// A router whose `net.fetch` asks for full network — more than the session
// base grants — and refuses rather than proceeding narrowed.
fn network_router(
  request: satellite.CapRequest,
) -> Result(satellite.CapPlan, satellite.CapDenial) {
  case request.cap {
    "net.fetch" ->
      Ok(satellite.CapPlan(
        spec: broker.CallSpec(
          op_id: identity.op_id(request.identity),
          step_id: identity.step_id(request.identity),
          base_policy: request.base_policy,
          requirements: policy.SandboxPolicy(
            ..request.base_policy,
            network: policy.NetworkFull,
          ),
          grants: [],
          response: broker.RefuseNarrowed,
          demand: request.demand,
          argv: ["fetch"],
          env: request.env,
          cwd: request.cwd,
          budget: identity.pooled_budget(request.identity),
        ),
        render: satellite.proc_render,
      ))
    _other -> satellite.default_router(request)
  }
}

fn real_token_peer(ctx: PeerCtx) -> Nil {
  satellite_peer.send_cap_call(
    ctx,
    ctx.token,
    0,
    "net.fetch",
    msgpack.MapValue([]),
  )
  let results = satellite_peer.collect_results(ctx, 1, 3000)
  let authenticated =
    !list.any(results, fn(r) { is_unauthorized(r.1) }) && results != []
  let policy_refused = list.any(results, fn(r) { is_code(r.1, "policy") })
  satellite_peer.send_outcome(
    ctx,
    msgpack.MapValue([
      #(msgpack.StringValue("authenticated"), msgpack.BoolValue(authenticated)),
      #(
        msgpack.StringValue("policy_refused"),
        msgpack.BoolValue(policy_refused),
      ),
    ]),
  )
}

// --- the outcome frame gets the same envelope checks (CH-F5) -------------

pub fn an_outcome_frame_of_another_version_is_rejected_test() {
  let dir = fresh_dir("outcome-version")
  let broker = start_broker(echoing())
  let cfg = config(dir)
  let outcome =
    satellite.run(
      artifact(),
      run_phase(budget.Budget(max_outstanding: 8, deadline_ms: t + 20_000)),
      broker,
      cfg,
      satellite_peer.launcher(fn(ctx) {
        satellite_peer.send_envelope(ctx, [
          #("v", msgpack.IntValue(2)),
          #("id", msgpack.IntValue(0)),
          #("kind", msgpack.StringValue(satellite.outcome_kind)),
          #("body", satellite_peer.completed_body(msgpack.StringValue("x"))),
        ])
        satellite_peer.wait_for_close(ctx)
      }),
    ).outcome
  assert is_channel_faulted(outcome)
  broker.stop(broker)
}

pub fn an_outcome_frame_missing_its_id_is_rejected_test() {
  let dir = fresh_dir("outcome-id")
  let broker = start_broker(echoing())
  let cfg = config(dir)
  let outcome =
    satellite.run(
      artifact(),
      run_phase(budget.Budget(max_outstanding: 8, deadline_ms: t + 20_000)),
      broker,
      cfg,
      satellite_peer.launcher(fn(ctx) {
        satellite_peer.send_envelope(ctx, [
          #("v", msgpack.IntValue(1)),
          #("kind", msgpack.StringValue(satellite.outcome_kind)),
          #("body", satellite_peer.completed_body(msgpack.StringValue("x"))),
        ])
        satellite_peer.wait_for_close(ctx)
      }),
    ).outcome
  assert is_channel_faulted(outcome)
  broker.stop(broker)
}

fn is_channel_faulted(
  outcome: Result(satellite.Outcome, satellite.RunError),
) -> Bool {
  case outcome {
    Error(satellite.ChannelFaulted(_)) -> True
    _ -> False
  }
}

// --- the outstanding gate precedes the collector (CH-F6) -----------------

pub fn cap_calls_past_the_outstanding_cap_never_reach_the_broker_test() {
  let dir = fresh_dir("gate")
  let broker = start_broker(echoing())
  // A zero pooled outstanding cap admits no effect at all, and the broker
  // is stopped before the run. A refusal can therefore only come from the
  // host's own gate: a collector spawned to ask this broker would never
  // answer at all.
  broker.stop(broker)
  process.sleep(50)
  let cfg = config(dir)
  let outcome =
    satellite.run(
      artifact(),
      run_phase(budget.Budget(max_outstanding: 0, deadline_ms: t + 5000)),
      broker,
      cfg,
      satellite_peer.launcher(budget_peer(3)),
    ).outcome
  let assert Ok(satellite.Completed(msgpack.IntValue(refused))) = outcome
  assert refused == 3
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
  let cfg = config(dir)
  let outcome =
    satellite.run(
      artifact(),
      run_phase(budget.Budget(max_outstanding: 16, deadline_ms: t + 20_000)),
      broker,
      cfg,
      satellite_peer.launcher(echo_peer(count)),
    ).outcome
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
  let cfg = config(dir)
  let outcome =
    satellite.run(
      artifact(),
      run_phase(budget.Budget(max_outstanding: 2, deadline_ms: t + 20_000)),
      broker,
      cfg,
      satellite_peer.launcher(budget_peer(count)),
    ).outcome
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
  let cfg = config(dir)
  let outcome =
    satellite.run(
      artifact(),
      run_phase(budget.Budget(max_outstanding: 8, deadline_ms: t + 20_000)),
      broker,
      cfg,
      satellite_peer.launcher(cancel_peer),
    ).outcome
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

// `stdout` is msgpack text, not binary: `cap/proc` decodes it into a
// `String` (see `satellite.proc_render`).
fn stdout_has(outcome: CapOutcome, prefix: String) -> Bool {
  case outcome {
    framing.CapOk(value:) ->
      case map_field(value, "stdout") {
        Ok(msgpack.StringValue(text)) -> string.starts_with(text, prefix)
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
