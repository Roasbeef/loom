//// Capability admission is exercised through both real satellite host modes.
//// The peer speaks actual framed calls; the real broker records native dispatch.
//// Router refusals, host ceilings and invalid derivations must precede custody.

import broker/broker
import broker/budget
import broker/dispatch
import broker/exec
import broker/framing
import broker/policy
import broker/token
import codemode/compile
import codemode/identity
import codemode/satellite
import core/clock
import core/ids
import core/msgpack
import core/remote_tool
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import simplifile
import support/satellite_peer.{type PeerCtx}
import tools/call_record

const now = 1_700_000_000_000

fn parent(index: Int) -> remote_tool.ToolKey {
  let generator = ids.generator(clock.fixed(now), 91)
  let #(session, generator) = ids.mint_session(generator)
  let #(operation, generator) = ids.mint_op(generator)
  let #(entry, _) = ids.mint_entry(generator)
  let assert Ok(key) =
    remote_tool.key(
      session,
      operation,
      "original-tools",
      index,
      string.repeat("b", 64),
      entry,
    )
    as "The original managed invocation is bounded and complete."
  key
}

fn phase(index: Int, outstanding: Int) -> identity.PhaseIdentity {
  identity.for_managed_execution(
    parent(index),
    budget: budget.Budget(
      max_outstanding: outstanding,
      deadline_ms: now + 60_000,
    ),
  )
  |> identity.run_phase
}

fn artifact() -> compile.Artifact {
  compile.Artifact(
    build_root: "/controlled-peer",
    beam_dir: "/controlled-peer/ebin",
    entry_module: compile.entry_module,
    manifest_hash: "peer-fixture",
  )
}

fn root(name: String) -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "The fixtures belong to the integration checkout."
  let root = here <> "/build/cmtest/admitted-" <> name
  let _previous = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
    as "The real token writer has a private test directory."
  root
}

fn owner(
  seen: Subject(dispatch.Dispatch),
  cancelled: Subject(Nil),
) -> broker.Broker {
  let assert Ok(owner) =
    broker.start_dispatching(
      entropy: token.production_entropy(),
      clock: clock.fixed(now),
      dispatcher: dispatch.Dispatcher(start: fn(call) {
        process.send(seen, call)
        case call.request.argv {
          ["hold"] -> {
            let guarantor = process.spawn_unlinked(process.sleep_forever)
            Ok(
              dispatch.Execution(
                id: dispatch.execution_id(incarnation: 91, seq: call.seq),
                guarantor:,
                cancel: fn() {
                  process.send(cancelled, Nil)
                  call.settle(dispatch.Failed(exec.ChannelClosed(137)))
                },
                stdin: fn(_, _) { Nil },
                release: fn() { process.kill(guarantor) },
                abandon: fn() { process.kill(guarantor) },
              ),
            )
          }
          _other -> Error(dispatch.NotStarted)
        }
      }),
    )
    as "A real owner broker dispatches the actual admitted native commands."
  owner
}

fn router(routed: Subject(#(String, Int))) -> satellite.CapRouter {
  fn(request: satellite.CapRequest) {
    process.send(routed, #(request.cap, request.ordinal))
    case request.cap {
      "owner.callback" ->
        Ok(
          satellite.ServedHere(fn() {
            framing.CapOk(msgpack.StringValue("owner"))
          }),
        )
      "owner.scoped" ->
        Ok(
          satellite.ScopedService(fn() {
            framing.CapOk(msgpack.StringValue("scoped"))
          }),
        )
      "test.exec" ->
        satellite.default_router(
          satellite.CapRequest(..request, cap: "proc.run"),
        )
      _other -> satellite.default_router(request)
    }
  }
}

fn single_config(
  _dir: String,
  routed: Subject(#(String, Int)),
) -> satellite.RunConfig {
  satellite.RunConfig(
    base_policy: policy.workspace_default("/work"),
    demand: exec.BestEffort,
    env: [#("PATH", "/usr/bin")],
    cwd: "/work",
    entropy: token.production_entropy(),
    clock: clock.fixed(now),
    router: router(routed),
    ceilings: [
      satellite.CapCeiling(cap: "proc.run", admissions: 2, code: "lifetime"),
    ],
    call_timeout_ms: 3000,
  )
}

fn host_config(dir: String, owner: broker.Broker) -> satellite.HostConfig {
  satellite.HostConfig(
    broker: owner,
    identity: phase(99, 4),
    base_policy: policy.workspace_default("/work"),
    demand: exec.BestEffort,
    env: [#("PATH", "/usr/bin")],
    cwd: "/work",
    cap_socket_path: dir <> "/sock",
    entropy: token.production_entropy(),
    clock: clock.fixed(now),
    write_token_file: satellite.private_token_writer(dir),
    unlink_token_file: satellite.unlink_token_file,
    call_timeout_ms: 3000,
  )
}

fn invoking(
  phase: identity.PhaseIdentity,
  routed: Subject(#(String, Int)),
) -> satellite.Invoking {
  satellite.Invoking(
    identity: phase,
    base_policy: policy.workspace_default("/work"),
    demand: exec.BestEffort,
    router: router(routed),
    ceilings: [
      satellite.CapCeiling(cap: "proc.run", admissions: 2, code: "lifetime"),
    ],
  )
}

fn args(argv: List(String)) -> msgpack.MsgPackValue {
  msgpack.MapValue([
    #(
      msgpack.StringValue("argv"),
      msgpack.ArrayValue(list.map(argv, msgpack.StringValue)),
    ),
  ])
}

fn result_for(ctx: PeerCtx, id: Int) -> framing.CapOutcome {
  let assert [#(received_id, outcome)] =
    satellite_peer.collect_results(ctx, 1, 3000)
    as "Every attempted admission receives an actual framed result."
  assert received_id == id
  outcome
}

fn call(
  ctx: PeerCtx,
  token: BitArray,
  id: Int,
  cap: String,
  args: msgpack.MsgPackValue,
) -> framing.CapOutcome {
  satellite_peer.send_cap_call(ctx, token, id, cap, args)
  result_for(ctx, id)
}

// One rejected attempt leaves proc.run ordinal zero. Two admitted commands
// spend zero and one; the lifetime refusal costs no dispatcher execution.
fn admitted_script(ctx: PeerCtx, token: BitArray) -> Nil {
  let assert framing.CapErr(code: "invalid_argument", ..) =
    call(ctx, token, 1, "proc.run", msgpack.MapValue([]))
    as "The router refuses malformed arguments before admission."
  let assert framing.CapErr(..) =
    call(ctx, token, 2, "proc.run", args(["first"]))
    as "The dispatcher records and then refuses physical execution."
  let assert framing.CapErr(..) =
    call(ctx, token, 3, "proc.run", args(["second"]))
    as "The second admitted physical request has its own ordinal."
  let assert framing.CapErr(..) =
    call(ctx, token, 4, "test.exec", args(["alias"]))
    as "A distinct admitted name starts at ordinal zero."
  let assert framing.CapErr(code: "lifetime", ..) =
    call(ctx, token, 5, "proc.run", args(["past-ceiling"]))
    as "The host lifetime ceiling runs before a third native dispatch."
  assert call(ctx, token, 6, "owner.callback", msgpack.NilValue)
    == framing.CapOk(msgpack.StringValue("owner"))
  assert call(ctx, token, 7, "owner.scoped", msgpack.NilValue)
    == framing.CapOk(msgpack.StringValue("scoped"))
  let assert framing.CapErr(code: "lifetime", ..) =
    call(ctx, token, 8, "proc.run", args(["still-past-ceiling"]))
    as "A refused lifetime attempt cannot consume the next admitted ordinal."
  Nil
}

fn assert_native(
  seen: Subject(dispatch.Dispatch),
  key: remote_tool.ToolKey,
  name: String,
  ordinal: Int,
  argv: List(String),
) {
  let assert Ok(call) = process.receive(seen, 2000)
    as "The actual collector must reach the production broker Dispatcher."
  let assert Some(origin) = call.context.origin
    as "Managed admission must not fall into unmanaged native clearance."
  assert remote_tool.child_tool(origin) == Ok(key)
  assert remote_tool.child_role(origin)
    == Ok(remote_tool.AdmittedCapability(
      name,
      ordinal,
      remote_tool.NativeCommand,
    ))
  assert call.context.operation == remote_tool.operation(key)
  assert call.context.step == remote_tool.step(key)
  assert call.deadline_ms == now + 60_000
  assert call.request.argv == argv
  assert call.request.env == [#("PATH", "/usr/bin")]
  assert call.request.cwd == "/work"
  assert call.request.demand == exec.BestEffort
  assert call.request.policy == Some(policy.workspace_default("/work"))
}

fn assert_admitted(
  seen: Subject(dispatch.Dispatch),
  routed: Subject(#(String, Int)),
  key: remote_tool.ToolKey,
) {
  assert_native(seen, key, "proc.run", 0, ["first"])
  assert_native(seen, key, "proc.run", 1, ["second"])
  assert_native(seen, key, "test.exec", 0, ["alias"])
  list.each(
    [
      #("proc.run", 0),
      #("proc.run", 0),
      #("proc.run", 1),
      #("test.exec", 0),
      #("proc.run", 2),
      #("owner.callback", 0),
      #("owner.scoped", 0),
      #("proc.run", 2),
    ],
    fn(expected) {
      assert process.receive(routed, 2000) == Ok(expected)
    },
  )
}

pub fn real_single_shot_admission_preserves_names_ordinals_and_parent_test() {
  let seen = process.new_subject()
  let routed = process.new_subject()
  let owner = owner(seen, process.new_subject())
  let run =
    satellite.run(
      artifact(),
      phase(3, 4),
      owner,
      single_config(root("single"), routed),
      satellite_peer.foreground_launcher(fn(ctx) {
        admitted_script(ctx, ctx.token)
        satellite_peer.send_outcome(ctx, msgpack.StringValue("verified"))
      }),
    )
  assert run.outcome == Ok(satellite.Completed(msgpack.StringValue("verified")))
  assert_admitted(seen, routed, parent(3))
  assert process.receive(seen, 50) == Error(Nil)
  broker.stop(owner)
}

fn persistent_peer(
  script: fn(PeerCtx, BitArray) -> Nil,
  times: Int,
) -> satellite.Launcher {
  satellite_peer.launcher(fn(ctx) {
    invoke_peer(ctx, satellite_peer.reading(), script, times)
  })
}

fn invoke_peer(
  ctx: PeerCtx,
  cursor: satellite_peer.Reading,
  script: fn(PeerCtx, BitArray) -> Nil,
  remaining: Int,
) -> Nil {
  case remaining {
    0 -> satellite_peer.wait_for_close(ctx)
    _more -> {
      let assert Ok(#(cursor, frame)) =
        satellite_peer.next_hook_call(ctx, cursor, 5000)
        as "The persistent peer receives an actual invocation frame."
      let #(token, _, _) = satellite_peer.hook_call_parts(frame)
      script(ctx, token)
      satellite_peer.send_hook_result(
        ctx,
        frame.id,
        framing.CapOk(msgpack.StringValue("verified")),
      )
      invoke_peer(ctx, cursor, script, remaining - 1)
    }
  }
}

pub fn persistent_admissions_use_each_original_invocation_and_reset_its_tally_test() {
  let seen = process.new_subject()
  let routed = process.new_subject()
  let owner = owner(seen, process.new_subject())
  let assert Ok(host) =
    satellite.start(
      artifact(),
      host_config(root("persistent"), owner),
      persistent_peer(admitted_script, 2),
    )
    as "The real persistent host opens one node for two invocations."
  list.each([3, 4], fn(index) {
    assert satellite.invoke(
        host,
        satellite.Tool("tool"),
        msgpack.NilValue,
        invoking(phase(index, 4), routed),
        5000,
      )
      == Ok(framing.CapOk(msgpack.StringValue("verified")))
    assert_admitted(seen, routed, parent(index))
  })
  assert process.receive(seen, 50) == Error(Nil)
  let _report = satellite.stop(host)
  broker.stop(owner)
}

// Ordered peer frames hold one admitted call, then hit the outstanding cap.
// Cancellation settles that original call; the next native admission is one,
// not two, because the rejected concurrent attempt never moved the tally.
fn outstanding_script(ctx: PeerCtx, token: BitArray) -> Nil {
  satellite_peer.send_cap_call(ctx, token, 1, "proc.run", args(["hold"]))
  satellite_peer.send_cap_call(ctx, token, 2, "proc.run", args(["rejected"]))
  let assert framing.CapErr(code: "budget", ..) = result_for(ctx, 2)
    as "The host refuses excess concurrency before spawning or dispatching."
  satellite_peer.send_cancel(ctx, 1)
  let assert framing.CapErr(..) = result_for(ctx, 1)
    as "Cancellation settles the actual original native execution."
  let assert framing.CapErr(..) =
    call(ctx, token, 3, "proc.run", args(["after-cancel"]))
    as "Released admission uses the next unconsumed ordinal."
  Nil
}

fn assert_outstanding(
  seen: Subject(dispatch.Dispatch),
  routed: Subject(#(String, Int)),
  cancelled: Subject(Nil),
) {
  assert_native(seen, parent(3), "proc.run", 0, ["hold"])
  assert_native(seen, parent(3), "proc.run", 1, ["after-cancel"])
  list.each(
    [#("proc.run", 0), #("proc.run", 1), #("proc.run", 1)],
    fn(expected) {
      assert process.receive(routed, 2000) == Ok(expected)
    },
  )
  assert process.receive(cancelled, 2000) == Ok(Nil)
  assert process.receive(seen, 50) == Error(Nil)
}

pub fn single_shot_outstanding_refusal_retains_ordinal_and_cancellation_test() {
  let seen = process.new_subject()
  let routed = process.new_subject()
  let cancelled = process.new_subject()
  let owner = owner(seen, cancelled)
  let run =
    satellite.run(
      artifact(),
      phase(3, 1),
      owner,
      single_config(root("single-outstanding"), routed),
      satellite_peer.foreground_launcher(fn(ctx) {
        outstanding_script(ctx, ctx.token)
        satellite_peer.send_outcome(ctx, msgpack.StringValue("verified"))
      }),
    )
  assert run.outcome == Ok(satellite.Completed(msgpack.StringValue("verified")))
  assert_outstanding(seen, routed, cancelled)
  broker.stop(owner)
}

pub fn persistent_outstanding_refusal_retains_ordinal_and_cancellation_test() {
  let seen = process.new_subject()
  let routed = process.new_subject()
  let cancelled = process.new_subject()
  let owner = owner(seen, cancelled)
  let assert Ok(host) =
    satellite.start(
      artifact(),
      host_config(root("persistent-outstanding"), owner),
      persistent_peer(outstanding_script, 1),
    )
    as "The actual persistent host admits bounded capability work."
  assert satellite.invoke(
      host,
      satellite.Tool("tool"),
      msgpack.NilValue,
      invoking(phase(3, 1), routed),
      5000,
    )
    == Ok(framing.CapOk(msgpack.StringValue("verified")))
  assert_outstanding(seen, routed, cancelled)
  let _report = satellite.stop(host)
  broker.stop(owner)
}

fn invalid_phase_script(ctx: PeerCtx, token: BitArray) -> Nil {
  list.each([1, 2], fn(id) {
    let assert framing.CapErr(
      code: "invalid_origin",
      message: "managed capabilities require a run phase",
    ) = call(ctx, token, id, "proc.run", args(["must-not-dispatch"]))
      as "Invalid managed phase refuses before admitted tally or worker spawn."
  })
  assert call(ctx, token, 3, "owner.callback", msgpack.NilValue)
    == framing.CapOk(msgpack.StringValue("owner"))
}

pub fn both_hosts_refuse_invalid_derivation_without_spending_an_ordinal_test() {
  let invalid =
    identity.for_managed_execution(
      parent(3),
      budget: budget.Budget(max_outstanding: 4, deadline_ms: now + 60_000),
    )
    |> identity.build_phase
  let seen = process.new_subject()
  let routed = process.new_subject()
  let owner = owner(seen, process.new_subject())
  let run =
    satellite.run(
      artifact(),
      invalid,
      owner,
      single_config(root("invalid-single"), routed),
      satellite_peer.foreground_launcher(fn(ctx) {
        invalid_phase_script(ctx, ctx.token)
        satellite_peer.send_outcome(ctx, msgpack.StringValue("verified"))
      }),
    )
  assert run.outcome == Ok(satellite.Completed(msgpack.StringValue("verified")))

  // Provenance refusals remain visible in the call log without consuming a
  // native ordinal. The owner callback is recorded after both refused calls.
  assert run.calls.total == 3
  assert run.calls.failed == 2
  assert list.map(run.calls.items, fn(item) { #(item.status, item.error) })
    == [
      #(call_record.CallFailed, Some("invalid_origin")),
      #(call_record.CallFailed, Some("invalid_origin")),
      #(call_record.CallOk, None),
    ]
  let assert Ok(host) =
    satellite.start(
      artifact(),
      host_config(root("invalid-persistent"), owner),
      persistent_peer(invalid_phase_script, 1),
    )
    as "Persistent managed phase restriction runs at admission."
  assert satellite.invoke(
      host,
      satellite.Tool("tool"),
      msgpack.NilValue,
      invoking(invalid, routed),
      5000,
    )
    == Ok(framing.CapOk(msgpack.StringValue("verified")))
  list.each(
    [
      #("proc.run", 0),
      #("proc.run", 0),
      #("owner.callback", 0),
      #("proc.run", 0),
      #("proc.run", 0),
      #("owner.callback", 0),
    ],
    fn(expected) {
      assert process.receive(routed, 2000) == Ok(expected)
    },
  )
  assert process.receive(seen, 50) == Error(Nil)
  let _report = satellite.stop(host)
  broker.stop(owner)
}

pub fn capability_derivation_is_bounded_and_separates_closed_purposes_test() {
  let run = phase(3, 4)
  let assert Ok(Some(native)) =
    identity.capability_origin(run, "proc.run", 0, remote_tool.NativeCommand)
    as "Admitted native provenance derives from the original parent."
  let assert Ok(Some(semantic)) =
    identity.capability_origin(
      run,
      "proc.run",
      0,
      remote_tool.SemanticWorkspace,
    )
    as "Closed effect purposes have disjoint canonical origins."
  assert remote_tool.child_tool(native) == Ok(parent(3))
  assert remote_tool.child_address(native)
    != remote_tool.child_address(semantic)
  assert identity.capability_origin(run, "", 0, remote_tool.NativeCommand)
    |> result.is_error
  assert identity.capability_origin(
      run,
      string.repeat("x", 129),
      0,
      remote_tool.NativeCommand,
    )
    |> result.is_error
  assert identity.capability_origin(
      run,
      "proc.run",
      -1,
      remote_tool.NativeCommand,
    )
    |> result.is_error
  assert identity.capability_origin(
      run,
      "proc.run",
      4096,
      remote_tool.NativeCommand,
    )
    |> result.is_error
  let local =
    identity.for_execution(
      op_id: remote_tool.operation(parent(3)),
      step_id: "local",
      budget: budget.Budget(max_outstanding: 4, deadline_ms: now + 60_000),
    )
    |> identity.build_phase
  assert identity.capability_origin(
      local,
      "local",
      0,
      remote_tool.NativeCommand,
    )
    == Ok(None)
}
