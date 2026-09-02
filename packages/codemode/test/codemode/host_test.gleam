//// The persistent satellite host's own tests: one node held open across
//// invocations, driven by an in-process peer that speaks the reverse
//// direction of the cap channel.
////
//// What is proved here is the half of `protocol-change/012` the harness
//// owns, and every case is one of its rules made falsifiable:
////
//// - an invocation is asked for and answered, and a second one reaches
////   the *same* node — the whole point of the persistent shape;
//// - a second `invoke` while one is open is `Busy` rather than queued;
//// - a `cap_call` presenting the invocation's token is served, and one
////   presenting a token whose invocation has closed is `unauthorized`,
////   which is the property that stops an extension acting between
////   invocations;
//// - a deadline that passes with no answer destroys the node, and every
////   later `invoke` says so;
//// - a `hook_result` correlating to nothing destroys the node.
////
//// No live jail and no live socket: the broker runs over a
//// `ChannelTransport` fake helper and the peer is a process, exactly as
//// `satellite_test`'s cases are.

import broker/broker
import broker/budget
import broker/exec
import broker/framing
import broker/policy
import broker/token
import codemode/compile
import codemode/identity
import codemode/satellite
import core/clock
import core/ids
import core/msgpack.{type MsgPackValue}
import gleam/erlang/process.{type Subject}
import gleam/string
import simplifile
import support/fake_helper
import support/satellite_peer.{type PeerCtx}

const t = 1_700_000_000_000

// How long a peer script waits for a frame it expects to arrive at once.
const soon = 5000

fn op_id(seed: Int) -> ids.OpId {
  let generator = ids.generator(clock.fixed(at: t), seed:)
  let #(op, _) = ids.mint_op(generator)
  op
}

fn phase(seed: Int, deadline_ms: Int) -> identity.PhaseIdentity {
  identity.for_execution(
    op_id: op_id(seed),
    step_id: "step-1",
    budget: budget.Budget(max_outstanding: 8, deadline_ms:),
  )
  |> identity.run_phase
}

fn artifact() -> compile.Artifact {
  compile.Artifact(
    build_root: "/tmp/loom-ext",
    beam_dir: "/tmp/loom-ext/ebin",
    entry_module: compile.entry_module,
    manifest_hash: "h",
  )
}

fn fresh_dir(name: String) -> String {
  let assert Ok(here) = simplifile.current_directory()
  let dir = here <> "/build/cmtest/host-" <> name
  let _ = simplifile.delete(dir)
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  dir
}

fn start_broker() -> broker.Broker {
  let assert Ok(started) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.fixed(at: t),
        checkout: fn() { Ok(fake_helper.start_helper(fake_helper.EchoNow)) },
        checkin: fn(_helper) { Nil },
      ),
    )
    as "the test broker must start"
  started
}

fn config(dir: String, broker: broker.Broker) -> satellite.HostConfig {
  satellite.HostConfig(
    broker:,
    identity: phase(7, t + 600_000),
    base_policy: policy.workspace_default("/work"),
    demand: exec.BestEffort,
    env: [#("PATH", "/usr/bin")],
    cwd: "/work",
    cap_socket_path: dir <> "/sock",
    entropy: token.production_entropy(),
    clock: clock.fixed(at: t),
    write_token_file: satellite.private_token_writer(dir),
    unlink_token_file: satellite.unlink_token_file,
    call_timeout_ms: 3000,
  )
}

fn invoking(seed: Int) -> satellite.Invoking {
  satellite.Invoking(
    identity: phase(seed, t + 600_000),
    base_policy: policy.workspace_default("/work"),
    demand: exec.BestEffort,
    router: satellite.default_router,
    ceilings: [],
  )
}

fn args(text: String) -> MsgPackValue {
  msgpack.MapValue([
    #(msgpack.StringValue("args"), msgpack.StringValue(text)),
    #(msgpack.StringValue("strand"), msgpack.StringValue("main")),
  ])
}

// --- one node, two invocations -------------------------------------------

/// The property the per-call node never had: two tool calls, one launch.
/// The launch count is asserted rather than inferred, because "it felt
/// fast" is not the claim.
pub fn two_invocations_reach_one_node_test() {
  let dir = fresh_dir("two")
  let broker = start_broker()
  let launches = process.new_subject()
  let assert Ok(host) =
    satellite.start(
      artifact(),
      config(dir, broker),
      counting(launches, echo_peer),
    )
    as "the host must start"

  let first =
    satellite.invoke(
      host,
      satellite.Tool("search"),
      args("{\"q\":1}"),
      invoking(11),
      soon,
    )
  let second =
    satellite.invoke(
      host,
      satellite.Tool("search"),
      args("{\"q\":2}"),
      invoking(12),
      soon,
    )

  assert first == Ok(framing.CapOk(msgpack.StringValue("search")))
  assert second == Ok(framing.CapOk(msgpack.StringValue("search")))
  assert launched(launches) == 1
  let _report = satellite.stop(host)
}

/// An event invocation travels the same frame under a different kind, so
/// the satellite can tell a model-made call from a moment on the harness's
/// timeline without a second frame type.
pub fn an_event_invocation_carries_its_kind_test() {
  let dir = fresh_dir("event")
  let broker = start_broker()
  let seen = process.new_subject()
  let assert Ok(host) =
    satellite.start(artifact(), config(dir, broker), reporting_kind(seen))
    as "the host must start"

  let answer =
    satellite.invoke(
      host,
      satellite.Event("session_start"),
      msgpack.MapValue([]),
      invoking(13),
      soon,
    )
  assert answer == Ok(framing.CapOk(msgpack.StringValue("session_start")))
  assert process.receive(seen, soon) == Ok(#("event", "session_start"))
  let _report = satellite.stop(host)
}

// --- one at a time -------------------------------------------------------

/// The protocol allows one outstanding `hook_call`, so the host refuses a
/// second rather than queueing it: a queue would hold a second token under
/// the first invocation's answer.
pub fn a_second_invocation_is_busy_test() {
  let dir = fresh_dir("busy")
  let broker = start_broker()
  let assert Ok(host) =
    satellite.start(artifact(), config(dir, broker), silent_peer())
    as "the host must start"

  // The peer never answers, so the first invocation is still open when
  // the second arrives. The first is left to its deadline.
  let asking = process.new_subject()
  process.spawn_unlinked(fn() {
    process.send(
      asking,
      satellite.invoke(
        host,
        satellite.Tool("slow"),
        args("{}"),
        invoking(21),
        3000,
      ),
    )
  })
  process.sleep(300)
  let second =
    satellite.invoke(
      host,
      satellite.Tool("other"),
      args("{}"),
      invoking(22),
      soon,
    )
  assert second == Error(satellite.Busy)

  let assert Ok(Error(satellite.InvocationDeadline)) =
    process.receive(asking, 10_000)
    as "the unanswered invocation must end at its deadline"
  Nil
}

// --- the token is the invocation's ---------------------------------------

/// A `cap_call` under the token the `hook_call` handed over is served; the
/// same token after the invocation closes is `unauthorized`. That pair is
/// the whole confinement story of a satellite that outlives an execution.
pub fn a_token_is_dead_once_its_invocation_closes_test() {
  let dir = fresh_dir("token")
  let broker = start_broker()
  let verdicts = process.new_subject()
  let assert Ok(host) =
    satellite.start(artifact(), config(dir, broker), stale_token_peer(verdicts))
    as "the host must start"

  let answer =
    satellite.invoke(
      host,
      satellite.Tool("probe"),
      args("{}"),
      invoking(31),
      soon,
    )
  assert answer == Ok(framing.CapOk(msgpack.StringValue("probe")))

  // The peer keeps the token and uses it again once the invocation is
  // over. It must not work.
  let assert Ok(#(during, after)) = process.receive(verdicts, soon)
    as "the peer must report both attempts"
  assert during == "served"
  assert after == "unauthorized"
  let _report = satellite.stop(host)
}

// --- the two ways a satellite loses its node -----------------------------

/// A satellite that ignores its deadline is not one the host can keep
/// trusting with a session's worth of state, so the node dies with the
/// invocation and stays dead.
pub fn a_deadline_destroys_the_node_test() {
  let dir = fresh_dir("deadline")
  let broker = start_broker()
  let assert Ok(host) =
    satellite.start(artifact(), config(dir, broker), silent_peer())
    as "the host must start"

  let expired =
    satellite.invoke(
      host,
      satellite.Tool("slow"),
      args("{}"),
      invoking(41),
      500,
    )
  assert expired == Error(satellite.InvocationDeadline)

  let assert Error(satellite.HostGone(reason:)) =
    satellite.invoke(
      host,
      satellite.Tool("slow"),
      args("{}"),
      invoking(42),
      soon,
    )
    as "a destroyed host must stay destroyed"
  assert string.contains(reason, "deadline")
}

/// A `hook_result` correlating to nothing is a satellite not speaking this
/// protocol. The node dies for it: a peer whose frames cannot be matched
/// is one whose next frame cannot be trusted either.
pub fn a_stray_hook_result_destroys_the_node_test() {
  let dir = fresh_dir("stray")
  let broker = start_broker()
  let assert Ok(host) =
    satellite.start(artifact(), config(dir, broker), stray_peer())
    as "the host must start"

  // The peer sends its stray answer as soon as it starts, before any
  // invocation exists.
  process.sleep(300)
  let assert Error(satellite.HostGone(reason:)) =
    satellite.invoke(
      host,
      satellite.Tool("anything"),
      args("{}"),
      invoking(51),
      soon,
    )
    as "a host that saw a stray hook_result must be gone"
  assert string.contains(reason, "hook_result")
}

// --- peers ----------------------------------------------------------------

// Wraps a launcher so a test can count launches: the persistent shape's
// whole claim is that a second invocation launches nothing.
fn counting(
  launches: Subject(Nil),
  script: fn(PeerCtx) -> Nil,
) -> satellite.Launcher {
  let inner = satellite_peer.launcher(script)
  fn(spec) {
    process.send(launches, Nil)
    inner(spec)
  }
}

fn launched(launches: Subject(Nil)) -> Int {
  count_loop(launches, 0)
}

fn count_loop(launches: Subject(Nil), seen: Int) -> Int {
  case process.receive(launches, 50) {
    Ok(Nil) -> count_loop(launches, seen + 1)
    Error(Nil) -> seen
  }
}

// Answers every invocation with the name it was asked for.
fn echo_peer(ctx: PeerCtx) -> Nil {
  echo_loop(ctx, satellite_peer.reading())
}

fn echo_loop(ctx: PeerCtx, cursor: satellite_peer.Reading) -> Nil {
  case satellite_peer.next_hook_call(ctx, cursor, 60_000) {
    Error(Nil) -> Nil
    Ok(#(cursor, frame)) -> {
      let #(_token, _kind, name) = satellite_peer.hook_call_parts(frame)
      satellite_peer.send_hook_result(
        ctx,
        frame.id,
        framing.CapOk(msgpack.StringValue(name)),
      )
      echo_loop(ctx, cursor)
    }
  }
}

// Reports the kind and name of the one invocation it is asked for.
fn reporting_kind(seen: Subject(#(String, String))) -> satellite.Launcher {
  satellite_peer.launcher(fn(ctx) {
    case satellite_peer.next_hook_call(ctx, satellite_peer.reading(), 60_000) {
      Error(Nil) -> Nil
      Ok(#(_cursor, frame)) -> {
        let #(_token, kind, name) = satellite_peer.hook_call_parts(frame)
        process.send(seen, #(kind, name))
        satellite_peer.send_hook_result(
          ctx,
          frame.id,
          framing.CapOk(msgpack.StringValue(name)),
        )
      }
    }
  })
}

// Reads its invocations and never answers one.
fn silent_peer() -> satellite.Launcher {
  satellite_peer.launcher(fn(ctx) { satellite_peer.wait_for_close(ctx) })
}

// Answers, then re-uses the invocation's token after it has closed.
fn stale_token_peer(
  verdicts: Subject(#(String, String)),
) -> satellite.Launcher {
  satellite_peer.launcher(fn(ctx) {
    case satellite_peer.next_hook_call(ctx, satellite_peer.reading(), 60_000) {
      Error(Nil) -> Nil
      Ok(#(cursor, frame)) -> {
        let #(token, _kind, name) = satellite_peer.hook_call_parts(frame)

        // Inside the invocation: the token works.
        satellite_peer.send_proc_run(ctx, token, 900, ["/bin/echo", "hi"])
        let during = verdict(ctx, cursor, 900)

        satellite_peer.send_hook_result(
          ctx,
          frame.id,
          framing.CapOk(msgpack.StringValue(name)),
        )

        // Outside it: the same bytes buy nothing.
        satellite_peer.send_proc_run(ctx, token, 901, ["/bin/echo", "hi"])
        let after = verdict(ctx, during.0, 901)
        process.send(verdicts, #(during.1, after.1))
      }
    }
  })
}

// The `cap_result` for `id`, as one word: what was served, or the code it
// was refused under.
fn verdict(
  ctx: PeerCtx,
  cursor: satellite_peer.Reading,
  id: Int,
) -> #(satellite_peer.Reading, String) {
  case satellite_peer.next_frame(ctx, cursor, soon) {
    Error(Nil) -> #(cursor, "nothing")
    Ok(#(cursor, frame)) ->
      case frame.body, frame.id == id {
        framing.CapResult(outcome: framing.CapOk(..), usage: _), True -> #(
          cursor,
          "served",
        )
        framing.CapResult(outcome: framing.CapErr(code:, ..), usage: _), True -> #(
          cursor,
          code,
        )
        _other, _ -> verdict(ctx, cursor, id)
      }
  }
}

// Answers an invocation nobody made.
fn stray_peer() -> satellite.Launcher {
  satellite_peer.launcher(fn(ctx) {
    satellite_peer.send_hook_result(
      ctx,
      99,
      framing.CapOk(msgpack.StringValue("unasked")),
    )
    satellite_peer.wait_for_close(ctx)
  })
}
