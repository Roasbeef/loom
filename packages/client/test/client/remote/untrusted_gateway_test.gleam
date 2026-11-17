//// The executor's gateway against an orchestrator driven by hand
//// (protocol-change/109).
////
//// The gateway feeds a real host. These tests check the two things the host
//// reads from the gateway's waiters: a dropped connection is a partition that
//// never cancels a call, and a cancel sent after the orchestrator re-sent the
//// call on a new connection is still an abort. They also check that the
//// gateway admits only the orchestrator pins it lists.
////
//// The same two hold for a background program (slice 2): a drop leaves it
//// running, and the start the orchestrator re-sends reads the value it stored
//// while nobody was connected, or is stopped by a cancel. The executor's proxy
//// carries a launch to the orchestrator and refuses an answer of another kind
//// as it would a lost one.
////
//// Wire 5 (protocol-change/117): a response past the value bound goes out as
//// its description, as one past the byte bound does.
////
//// The tunnel (protocol-change/117) runs against the production broker and a
//// real helper: a dropped connection cancels its tunnelled children, including
//// one whose waiter was still waiting out a full pool; a `cancel` kills only
//// the waiter, and the connection serves on; output past its cap settles as
//// truncated without an empty chunk; a read policy keeps the plane's
//// writable-only roots; a spec cannot widen the plane's base; and a binding
//// the orchestrator does not hold is refused.

import broker/broker
import broker/budget
import broker/exec
import broker/executor
import broker/framing
import broker/policy
import client/catalog
import client/internal/ffi_tls_stream.{type Stream}
import client/remote/blob_transfer
import client/remote/host
import client/remote/protocol
import client/remote/remote_census.{type RemoteCensus}
import client/remote/untrusted_codec
import client/remote/untrusted_gateway
import client/remote/untrusted_wire
import client/serve
import client/workspace_plane
import client/workspace_policy
import client/worktree_diff
import core/clock
import core/json
import core/message
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import runtime/effects.{type ToolRun}
import simplifile
import support/enforcement
import support/remote_fixtures as fixtures
import support/remote_orchestrator
import support/untrusted_rig as rig
import support/worktree_rig
import telemetry/log

const token = <<"token":utf8>>

type Rig {
  Rig(
    pair: rig.Pair,
    executor: remote_orchestrator.Executor,
    gateway: untrusted_gateway.Gateway,
    workers: Subject(process.Pid),
  )
}

fn start(label: String) -> Rig {
  let pair = rig.pair(label)
  let workers = process.new_subject()
  let executor =
    remote_orchestrator.start(holding(
      workers,
      remote_orchestrator.census(remote_orchestrator.standard_tools()),
    ))
  let assert Ok(gateway) =
    untrusted_gateway.start(untrusted_gateway.Config(
      address: "127.0.0.1",
      port: 0,
      credentials: pair.executor,
      orchestrators: [pair.orchestrator_pin],
      host: executor.address,
      blobs: None,
      demand: exec.PlatformEnforcement,
      logger: log.discard(),
    ))
    as "the gateway starts"
  Rig(pair:, executor:, gateway:, workers:)
}

fn stop(rig: Rig) -> Nil {
  process.unlink(rig.gateway.acceptor)
  process.kill(rig.gateway.acceptor)
  remote_orchestrator.stop(rig.executor)
}

// A plane for the background tests: every call asks the owner to launch the fixtures' execution and reports what it was told; a
// program reports its worker and a subject that releases it, and ends with the
// value it was released with.
fn programs(
  launches: Subject(Result(json.JsonValue, String)),
  started: Subject(#(process.Pid, Subject(json.JsonValue))),
  census: RemoteCensus,
) -> host.PlaneFactory(RemoteCensus) {
  fn(spec: host.AttachSpec) {
    let owner = spec.owner
    Ok(host.Plane(
      run: fn(run, _authority) {
        process.send(
          launches,
          owner.launch_execution(fixtures.execution_terms()),
        )
        fixtures.expected_outcome(run)
      },
      census:,
      children: fn(builder) { builder },
      close: fn(retire_children) {
        let _retired = retire_children()
        protocol.AllRetired
      },
      execute: fn(_start) {
        let release = process.new_subject()
        process.send(started, #(process.self(), release))
        process.receive_forever(release)
      },
      abort_step: fn(_op, _step) { Nil },
      evolution: None,
      state: None,
    ))
  }
}

// A plane whose every call reports its worker and then waits to be killed.
fn holding(
  workers: Subject(process.Pid),
  census: RemoteCensus,
) -> host.PlaneFactory(RemoteCensus) {
  fn(_spec: host.AttachSpec) {
    Ok(host.Plane(
      run: fn(run, _authority) {
        process.send(workers, process.self())
        process.sleep_forever()
        fixtures.expected_outcome(run)
      },
      census:,
      children: fn(builder) { builder },
      close: fn(retire_children) {
        let _retired = retire_children()
        protocol.AllRetired
      },
      execute: fn(_start) { json.Null },
      abort_step: fn(_op, _step) { Nil },
      evolution: None,
      state: None,
    ))
  }
}

// Reads frames until the response to `id`, answering the two questions a
// plane's build asks its owner on the way.
fn response_to(stream: Stream, id: Int) -> Nil {
  case rig.next(stream) {
    Ok(untrusted_codec.ResponseEnvelope(id: answered, ..)) if answered == id ->
      Nil
    Ok(untrusted_codec.CallbackEnvelope(binding:, id: asked, body:)) -> {
      let answer = case untrusted_codec.decode_callback(body) {
        Ok(untrusted_wire.McpPlanCall) ->
          untrusted_wire.McpPlanAnswered(protocol.empty_mcp_plan())
        _other -> untrusted_wire.GitIdentityAnswered(None)
      }
      rig.send(stream, untrusted_wire.Answer(binding:, id: asked, answer:))
      response_to(stream, id)
    }
    Ok(_other) -> response_to(stream, id)
    Error(reason) -> panic as reason
  }
}

fn attach(stream: Stream) -> Nil {
  rig.send(
    stream,
    untrusted_wire.Request(
      id: 1,
      request: untrusted_wire.AttachRequest(
        version: protocol.version,
        session: "s1",
        workspace: "/work",
        incarnation: 0,
        token:,
        binding: <<1:size(128)>>,
      ),
    ),
  )
  response_to(stream, 1)
}

fn run_request(id: Int, run: ToolRun) -> untrusted_wire.Frame {
  untrusted_wire.Request(
    id:,
    request: untrusted_wire.RunRequest(
      key: protocol.key_of("s1", run),
      incarnation: 0,
      token:,
      run:,
      authority: fixtures.authority(),
    ),
  )
}

pub fn a_cancel_after_a_reconnect_still_aborts_the_call_test() {
  let rig = start("reconnect-cancel")
  let first = rig.hello(rig.gateway.port, rig.pair)
  attach(first)
  let run = fixtures.tool_run("hold", 0)
  rig.send(first, run_request(2, run))
  let assert Ok(worker) = process.receive(rig.workers, 5000)
    as "the call starts"
  let watch = process.monitor(worker)
  let down =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(_down) { Nil })

  // The connection drops: a partition, which must not cancel the call.
  ffi_tls_stream.close(first)
  assert process.selector_receive(down, 500) == Error(Nil)

  // The orchestrator re-sends the call on a new connection, then the asker
  // dies and it cancels. Only the new waiter is left, so the host aborts.
  let second = rig.hello(rig.gateway.port, rig.pair)
  rig.send(second, run_request(2, run))
  process.sleep(200)
  rig.send(second, untrusted_wire.Cancel(2))
  assert process.selector_receive(down, 10_000) == Ok(Nil)
  stop(rig)
}

pub fn an_orchestrator_the_gateway_does_not_list_is_refused_test() {
  let rig = start("unlisted")

  // The stray leaf chains to the same authority, and is still not admitted,
  // because its pin is not one the gateway lists.
  let refused = case
    rig.dial(rig.gateway.port, rig.pair.stray, rig.pair.executor_pin)
  {
    Error(_failure) -> True
    Ok(stream) -> rig.closed(stream, 5000)
  }
  assert refused
  stop(rig)
}

// --- background executions (slice 2) ---------------------------------------------

type Programs {
  Programs(
    pair: rig.Pair,
    executor: remote_orchestrator.Executor,
    gateway: untrusted_gateway.Gateway,
    launches: Subject(Result(json.JsonValue, String)),
    started: Subject(#(process.Pid, Subject(json.JsonValue))),
  )
}

fn start_programs(label: String) -> Programs {
  let pair = rig.pair(label)
  let launches = process.new_subject()
  let started = process.new_subject()
  let executor =
    remote_orchestrator.start(programs(
      launches,
      started,
      remote_orchestrator.census(remote_orchestrator.standard_tools()),
    ))
  let assert Ok(gateway) =
    untrusted_gateway.start(untrusted_gateway.Config(
      address: "127.0.0.1",
      port: 0,
      credentials: pair.executor,
      orchestrators: [pair.orchestrator_pin],
      host: executor.address,
      blobs: None,
      demand: exec.PlatformEnforcement,
      logger: log.discard(),
    ))
    as "the gateway starts"
  Programs(pair:, executor:, gateway:, launches:, started:)
}

fn stop_programs(rig: Programs) -> Nil {
  process.unlink(rig.gateway.acceptor)
  process.kill(rig.gateway.acceptor)
  remote_orchestrator.stop(rig.executor)
}

fn start_request(id: Int) -> untrusted_wire.Frame {
  untrusted_wire.Request(
    id:,
    request: untrusted_wire.StartExecutionRequest(
      key: fixtures.execution_key("s1", "e1"),
      incarnation: 0,
      token:,
      terms: fixtures.execution_terms(),
      remaining_ms: 60_000,
    ),
  )
}

// Reads frames until the response to `id` and decodes it as an execution's.
fn execution_answer(stream: Stream, id: Int) -> protocol.ExecutionAnswer {
  let assert Ok(untrusted_codec.ResponseEnvelope(id: answered, body:)) =
    rig.next(stream)
    as "the start is answered"
  assert answered == id
  let assert Ok(untrusted_wire.ExecutionAnswered(answer)) =
    untrusted_codec.decode_response(untrusted_wire.ExecutionKind, body)
    as "the answer is an execution's"
  answer
}

pub fn a_dropped_connection_leaves_a_program_running_and_the_resent_start_reads_its_value_test() {
  let rig = start_programs("program-partition")
  let first = rig.hello(rig.gateway.port, rig.pair)
  attach(first)
  rig.send(first, start_request(2))
  let assert Ok(#(worker, release)) = process.receive(rig.started, 5000)
    as "the program starts"
  let watch = process.monitor(worker)
  let down =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(_down) { Nil })

  // The connection drops: a partition, which must not stop the program.
  ffi_tls_stream.close(first)
  assert process.selector_receive(down, 500) == Error(Nil)

  // The program ends while nobody is connected, and its value waits in the
  // ledger for the orchestrator's re-send.
  let value = json.Object([#("status", json.String("ok"))])
  process.send(release, value)
  assert process.selector_receive(down, 5000) == Ok(Nil)
  let second = rig.hello(rig.gateway.port, rig.pair)
  rig.send(second, start_request(2))
  assert execution_answer(second, 2) == protocol.ExecutionFinished(value)
  assert process.receive(rig.started, 300) == Error(Nil)
  stop_programs(rig)
}

pub fn a_cancel_after_a_reconnect_still_stops_the_program_test() {
  let rig = start_programs("program-cancel")
  let first = rig.hello(rig.gateway.port, rig.pair)
  attach(first)
  rig.send(first, start_request(2))
  let assert Ok(#(worker, _release)) = process.receive(rig.started, 5000)
    as "the program starts"
  let watch = process.monitor(worker)
  let down =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(_down) { Nil })

  ffi_tls_stream.close(first)
  assert process.selector_receive(down, 500) == Error(Nil)

  // The re-sent start joins the program that is running instead of starting
  // a second one, and the cancel after it stops that program.
  let second = rig.hello(rig.gateway.port, rig.pair)
  rig.send(second, start_request(2))
  assert process.receive(rig.started, 200) == Error(Nil)
  rig.send(second, untrusted_wire.Cancel(2))
  assert process.selector_receive(down, 10_000) == Ok(Nil)
  stop_programs(rig)
}

// Sends a `launch` call, answers the launch callback the plane makes with
// `answer`, and reports what the plane was told.
fn launched_with(
  label: String,
  answer: fn(BitArray, Int) -> untrusted_wire.Answer,
) -> Result(json.JsonValue, String) {
  let rig = start_programs(label)
  let stream = rig.hello(rig.gateway.port, rig.pair)
  attach(stream)
  rig.send(stream, run_request(2, fixtures.tool_run("launch", 0)))
  let assert Ok(untrusted_codec.CallbackEnvelope(binding:, id:, body:)) =
    rig.next(stream)
    as "the plane's launch is called back"
  assert untrusted_codec.decode_callback(body)
    == Ok(untrusted_wire.LaunchExecutionCall(fixtures.execution_terms()))
  rig.send(
    stream,
    untrusted_wire.Answer(binding:, id:, answer: answer(binding, id)),
  )
  let assert Ok(told) = process.receive(rig.launches, 5000)
    as "the plane hears the launch's answer"
  stop_programs(rig)
  told
}

pub fn a_launch_is_called_back_and_answered_with_the_owners_handle_test() {
  let told =
    launched_with("launch-answered", fn(_binding, _id) {
      untrusted_wire.LaunchAnswered(Ok(json.String("exec-1")))
    })
  assert told == Ok(json.String("exec-1"))
}

pub fn a_launch_answered_with_the_wrong_kind_is_refused_as_unanswered_test() {
  let told =
    launched_with("launch-wrong-kind", fn(_binding, _id) {
      untrusted_wire.InteractAnswered(Ok(json.String("exec-1")))
    })
  let assert Error(reason) = told
    as "an interaction's answer never answers a launch"
  assert string.contains(reason, "did not answer the launch")
  assert string.contains(reason, fixtures.handle_of(fixtures.execution_terms()))
}

// --- wire 5 (protocol-change/117) ------------------------------------------------

/// A gateway over a plane whose every call completes with `outcome`.
fn start_answering(label: String, outcome: effects.ToolOutcome) -> Rig {
  let pair = rig.pair(label)
  let workers = process.new_subject()
  let census = remote_orchestrator.census(remote_orchestrator.standard_tools())
  // The outcome is a few megabytes, so the host reserves what a real one does.
  let executor =
    remote_orchestrator.start_holding(
      fn(_spec: host.AttachSpec) {
        Ok(host.Plane(
          run: fn(_run, _authority) { outcome },
          census:,
          children: fn(builder) { builder },
          close: fn(retire_children) {
            let _retired = retire_children()
            protocol.AllRetired
          },
          execute: fn(_start) { json.Null },
          abort_step: fn(_op, _step) { Nil },
          evolution: None,
          state: None,
        ))
      },
      host.default_max_result_bytes,
    )
  let assert Ok(gateway) =
    untrusted_gateway.start(untrusted_gateway.Config(
      address: "127.0.0.1",
      port: 0,
      credentials: pair.executor,
      orchestrators: [pair.orchestrator_pin],
      host: executor.address,
      blobs: None,
      demand: exec.PlatformEnforcement,
      logger: log.discard(),
    ))
    as "the gateway starts"
  Rig(pair:, executor:, gateway:, workers:)
}

// A clearance under a binding this orchestrator does not hold has no plane to
// clear on: it is answered as a broker that cannot be reached, and the
// connection serves the next request.
pub fn a_clear_call_for_a_binding_not_held_is_refused_test() {
  let rig = start("clear-call")
  let stream = rig.hello(rig.gateway.port, rig.pair)
  attach(stream)

  let spec =
    untrusted_wire.TunnelSpec(
      op_id: fixtures.tool_run("check", 0).operation,
      step_id: "goal-check:1",
      base_policy: workspace_policy.base_policy("/work"),
      requirements: workspace_policy.base_policy("/work"),
      response: broker.RefuseNarrowed,
      argv: ["git", "status"],
      env: [],
      cwd: "/work",
      budget: budget.Budget(max_outstanding: 1, deadline_ms: 0),
    )
  rig.send(
    stream,
    untrusted_wire.Request(
      id: 2,
      request: untrusted_wire.ClearCallRequest(
        binding: <<2:size(128)>>,
        spec:,
        waiting_ms: 1000,
      ),
    ),
  )
  let assert Ok(untrusted_codec.ResponseEnvelope(id: 2, body:)) =
    rig.next(stream)
    as "the clearance is answered"
  assert untrusted_codec.decode_response(untrusted_wire.ClearedKind, body)
    == Ok(untrusted_wire.ClearedAnswered(Error(broker.BrokerUnavailable)))
  assert !rig.closed(stream, 300)
  stop(rig)
}

// A response far inside the byte bound but past the value bound goes out as
// its description, as one past the byte bound does, so the orchestrator never
// receives a frame it must refuse by closing the connection, and never re-sends
// a request whose answer would close it again.
pub fn a_response_past_the_value_bound_goes_out_as_oversized_test() {
  let outcome =
    effects.ToolCompleted(
      result: message.ToolResultMessage(
        tool_call_id: "wide",
        tool_name: "bash",
        content: [],
        details: Some(
          json.Array(list.repeat(json.Int(0), untrusted_wire.max_frame_values)),
        ),
        usage: None,
        added_tool_names: None,
        is_error: False,
        timestamp: 0,
      ),
      terminate: False,
    )
  let rig = start_answering("wide-response", outcome)
  let stream = rig.hello(rig.gateway.port, rig.pair)
  attach(stream)

  rig.send(stream, run_request(2, fixtures.tool_run("wide", 0)))
  let bytes = untrusted_codec.encode_outcome_bytes(outcome)
  assert bit_array.byte_size(bytes) < untrusted_wire.max_frame_bytes
  assert rig.next(stream)
    == Ok(untrusted_codec.OversizedEnvelope(
      id: 2,
      size: bit_array.byte_size(bytes),
      digest: blob_transfer.digest_of(bytes),
    ))
  stop(rig)
}

// --- the broker tunnel (protocol-change/117) -------------------------------------

/// A gateway over a host whose plane's broker is the production broker and
/// pool, with one helper, over a private workspace.
type Real {
  Real(
    pair: rig.Pair,
    executor: remote_orchestrator.Executor,
    gateway: untrusted_gateway.Gateway,
    broker: broker.Broker,
    service: executor.Executor,
    workspace: String,
    base: policy.SandboxPolicy,
    path: String,
  )
}

/// Runs `run` against a real plane whose base `shape` makes from the
/// workspace and the system's read roots, when the helper enforces here.
fn with_real_plane(
  label: String,
  shape: fn(String, List(String)) -> policy.SandboxPolicy,
  run: fn(Real, Stream) -> Nil,
) -> Nil {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner has a package working directory"
  let assert Ok(repository) = bootstrap.canonical_directory(here <> "/../..")
    as "the source repository locates the built helper"
  case enforcement.probe(repository <> "/bin/loom", "tunnel " <> label) {
    enforcement.EnforcementAbsent -> Nil
    enforcement.EnforcementLive -> {
      // The jail replaces /tmp with scratch, so /var/tmp keeps the
      // workspace's path the same inside it.
      let directory =
        "/var/tmp/loom-tunnel-"
        <> int.to_string(bootstrap.current_process_id())
        <> "-"
        <> label
        <> "-"
        <> int.to_string(bootstrap.system_time_ms())
      let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
        as "the test owns a workspace"
      let assert Ok(workspace) = bootstrap.canonical_directory(directory)
        as "the policy uses absolute paths"
      let #(reads, path) = system_reads()
      let base = shape(workspace, reads)
      let assert Ok(#(_pool, plane_broker, service)) =
        serve.start_effect_plane(
          helper: repository <> "/bin/loom-exec",
          base_policy: base,
          tmp_dir: workspace <> "/.helper",
          size: 1,
          clock: clock.from_function(bootstrap.system_time_ms),
        )
        as "the production broker and pool start"
      let real =
        real_gateway(label, workspace, base, plane_broker, service, path)
      let stream = rig.hello(real.gateway.port, real.pair)
      attach(stream)
      run(real, stream)
      stop_real(real)
    }
  }
}

/// The read roots and `PATH` a jailed Git needs here. Apple ships the real Git
/// with Xcode, and `/usr/bin/git` is a launcher whose discovery needs host
/// preferences, so only the developer tree is admitted and its binary comes
/// first.
fn system_reads() -> #(List(String), String) {
  let developer_usr = "/Applications/Xcode.app/Contents/Developer/usr"
  case simplifile.is_directory(developer_usr) {
    Ok(True) -> #(
      [developer_usr],
      developer_usr <> "/bin:/usr/bin:/bin:/usr/local/bin",
    )
    Ok(False) | Error(_) -> #([], "/usr/local/bin:/usr/bin:/bin")
  }
}

/// A plane base whose workspace is readable and writable.
fn readable_workspace(
  workspace: String,
  reads: List(String),
) -> policy.SandboxPolicy {
  let base = workspace_policy.base_policy_for(workspace, catalog.WorkspaceReads)
  policy.SandboxPolicy(..base, readable_roots: [workspace, ..reads])
}

/// A plane base whose workspace is writable only, as a linked worktree's Git
/// directory or a short tool tmpdir is.
fn writable_only_workspace(
  workspace: String,
  reads: List(String),
) -> policy.SandboxPolicy {
  let base = workspace_policy.base_policy_for(workspace, catalog.WorkspaceReads)
  policy.SandboxPolicy(..base, readable_roots: reads)
}

fn real_gateway(
  label: String,
  workspace: String,
  base: policy.SandboxPolicy,
  plane_broker: broker.Broker,
  service: executor.Executor,
  path: String,
) -> Real {
  let pair = rig.pair("tunnel-" <> label)
  let workers = process.new_subject()
  let census =
    remote_orchestrator.census_over(
      remote_orchestrator.standard_tools(),
      broker.subject(plane_broker),
    )
  let census =
    remote_census.RemoteCensus(
      ..census,
      census: workspace_plane.Census(
        ..census.census,
        workspace:,
        base_policy: base,
      ),
    )
  let executor = remote_orchestrator.start(holding(workers, census))
  let assert Ok(gateway) =
    untrusted_gateway.start(untrusted_gateway.Config(
      address: "127.0.0.1",
      port: 0,
      credentials: pair.executor,
      orchestrators: [pair.orchestrator_pin],
      host: executor.address,
      blobs: None,
      demand: exec.PlatformEnforcement,
      logger: log.discard(),
    ))
    as "the gateway starts"
  Real(
    pair:,
    executor:,
    gateway:,
    broker: plane_broker,
    service:,
    workspace:,
    base:,
    path:,
  )
}

fn stop_real(real: Real) -> Nil {
  process.unlink(real.gateway.acceptor)
  process.kill(real.gateway.acceptor)
  remote_orchestrator.stop(real.executor)
  broker.stop(real.broker)
  let _closed =
    executor.close(
      real.service,
      draining: executor.drain_ms,
      helpers: executor.helpers_ms,
    )
  Nil
}

/// A spec for `argv` in the workspace, under step `step` so each call has a
/// budget of its own, with a per-stream output limit.
fn real_spec(
  real: Real,
  step: String,
  argv: List(String),
  output_bytes: Int,
) -> untrusted_wire.TunnelSpec {
  let requirements =
    policy.SandboxPolicy(
      ..real.base,
      limits: policy.Limits(..real.base.limits, output_bytes:, wall_s: 60),
    )
  untrusted_wire.TunnelSpec(
    op_id: fixtures.tool_run("check", 0).operation,
    step_id: step,
    base_policy: real.base,
    requirements:,
    response: broker.RefuseNarrowed,
    argv:,
    env: [#("PATH", real.path), #("HOME", "/nonexistent")],
    cwd: real.workspace,
    budget: budget.Budget(1, bootstrap.system_time_ms() + 60_000),
  )
}

fn send_clear(
  stream: Stream,
  id: Int,
  spec: untrusted_wire.TunnelSpec,
  waiting_ms: Int,
) -> Nil {
  rig.send(
    stream,
    untrusted_wire.Request(
      id:,
      request: untrusted_wire.ClearCallRequest(
        binding: <<1:size(128)>>,
        spec:,
        waiting_ms:,
      ),
    ),
  )
}

/// Reads the next frame as the `cleared` of request `id`.
fn cleared_within(
  stream: Stream,
  id: Int,
  within_ms: Int,
) -> Result(Nil, broker.Refusal) {
  let assert Ok(frame) = rig.next_raw(stream, within_ms)
    as "the clearance is answered"
  let assert Ok(untrusted_codec.ResponseEnvelope(id: answered, body:)) =
    untrusted_codec.decode_envelope(frame)
    as "the answer is a response"
  assert answered == id
  let assert Ok(untrusted_wire.ClearedAnswered(answer)) =
    untrusted_codec.decode_response(untrusted_wire.ClearedKind, body)
    as "the response is a clearance"
  answer
}

/// Reads call `id`'s events until its settlement.
fn settlement(
  stream: Stream,
  id: Int,
  chunks: List(#(framing.OutputStream, BitArray)),
) -> #(List(#(framing.OutputStream, BitArray)), broker.CallOutcome) {
  let assert Ok(frame) = rig.next_raw(stream, 30_000) as "the call reports"
  let assert Ok(untrusted_codec.CallEventEnvelope(call:, body:)) =
    untrusted_codec.decode_envelope(frame)
    as "the report is a call event"
  assert call == id
  let assert Ok(event) = untrusted_codec.decode_call_event(body)
    as "the event decodes"
  case event {
    untrusted_wire.TunnelOutput(stream: output, data:) ->
      settlement(stream, id, [#(output, data), ..chunks])
    untrusted_wire.TunnelSettled(outcome:) -> #(list.reverse(chunks), outcome)
  }
}

fn stdout_of(chunks: List(#(framing.OutputStream, BitArray))) -> BitArray {
  list.fold(chunks, <<>>, fn(all, chunk) {
    case chunk.0 {
      framing.Stdout -> <<all:bits, { chunk.1 }:bits>>
      framing.Stderr -> all
    }
  })
}

/// Runs `echo ready` as call `id` and checks it clears and prints, which a
/// pool of one helper does only once every earlier call has let it go.
fn echoes(real: Real, stream: Stream, id: Int) -> Nil {
  send_clear(
    stream,
    id,
    real_spec(real, "echo-" <> int.to_string(id), ["/bin/echo", "ready"], 4096),
    15_000,
  )
  assert cleared_within(stream, id, 20_000) == Ok(Nil)
  let #(chunks, outcome) = settlement(stream, id, [])
  assert stdout_of(chunks) == <<"ready\n">>
  let assert broker.CallExited(result:) = outcome as "the echo exits"
  assert result.code == 0
}

// A dropped connection kills its tunnel waiters, and with them the children:
// the running one, and one whose waiter was still waiting out the full pool.
// The pool has one helper, so the next connection's call clears only if both
// let it go.
pub fn a_dropped_connection_cancels_the_tunnelled_children_test() {
  use real, first <- with_real_plane("dropped", readable_workspace)
  send_clear(
    first,
    2,
    real_spec(real, "sleep-a", ["/bin/sleep", "60"], 4096),
    15_000,
  )
  assert cleared_within(first, 2, 20_000) == Ok(Nil)
  send_clear(
    first,
    3,
    real_spec(real, "sleep-b", ["/bin/sleep", "60"], 4096),
    15_000,
  )
  assert rig.next_raw(first, 500) == Error("silent")

  ffi_tls_stream.close(first)
  let second = rig.hello(real.gateway.port, real.pair)
  echoes(real, second, 4)
}

// `cancel` kills the waiter, which is unlinked first: a linked waiter killed
// by its own connection would take the connection with it, and the next
// request would find no one to serve it.
pub fn a_cancel_kills_the_tunnel_waiter_and_the_connection_serves_on_test() {
  use real, stream <- with_real_plane("cancel", readable_workspace)
  send_clear(
    stream,
    2,
    real_spec(real, "sleep", ["/bin/sleep", "60"], 4096),
    15_000,
  )
  assert cleared_within(stream, 2, 20_000) == Ok(Nil)
  rig.send(stream, untrusted_wire.Cancel(2))
  echoes(real, stream, 3)
}

// A command that prints past its cap settles with `stdout_truncated`, and the
// chunk with no bytes the helper sends at the cap is not forwarded, so the
// bytes the orchestrator sees never pass the limit it set.
pub fn a_command_printing_past_its_cap_settles_truncated_test() {
  use real, stream <- with_real_plane("truncated", readable_workspace)
  send_clear(
    stream,
    2,
    real_spec(
      real,
      "loud",
      ["/bin/sh", "-c", "head -c 5000 /dev/zero | tr '\\000' x"],
      64,
    ),
    15_000,
  )
  assert cleared_within(stream, 2, 20_000) == Ok(Nil)
  let #(chunks, outcome) = settlement(stream, 2, [])
  assert list.all(chunks, fn(chunk) { bit_array.byte_size(chunk.1) > 0 })
  assert bit_array.byte_size(stdout_of(chunks)) <= 64
  let assert broker.CallExited(result:) = outcome as "the command exits"
  assert result.stdout_truncated
  assert !rig.closed(stream, 300)
}

// A Git call clears under the read policy the diff uses, which lists the
// plane's writable-only workspace as readable. The meet counts the plane's
// writable roots as readable, so the root is kept and the call runs.
pub fn a_writable_only_root_runs_a_read_policy_git_call_test() {
  use real, stream <- with_real_plane("read-policy", writable_only_workspace)
  let _initialized = worktree_rig.git(real.workspace, ["init", "--quiet"])
  let read = worktree_diff.read_policy(real.base)
  let spec =
    untrusted_wire.TunnelSpec(
      ..real_spec(
        real,
        "git",
        ["git", "rev-parse", "--is-inside-work-tree"],
        4096,
      ),
      base_policy: read,
      requirements: policy.SandboxPolicy(
        ..read,
        limits: policy.Limits(..read.limits, output_bytes: 4096, wall_s: 60),
      ),
    )
  send_clear(stream, 2, spec, 15_000)
  assert cleared_within(stream, 2, 20_000) == Ok(Nil)
  let #(chunks, outcome) = settlement(stream, 2, [])
  assert stdout_of(chunks) == <<"true\n">>
  let assert broker.CallExited(result:) = outcome as "git exits"
  assert result.code == 0
}

// A spec that asks for a wider base than the plane's runs under the plane's:
// a file outside the plane's roots cannot be read, though the spec names its
// directory and proceeds when narrowed.
pub fn a_wider_spec_base_runs_under_the_planes_base_test() {
  use real, stream <- with_real_plane("wider", readable_workspace)
  let outside =
    "/var/tmp/loom-tunnel-outside-"
    <> int.to_string(bootstrap.current_process_id())
    <> "-"
    <> int.to_string(bootstrap.system_time_ms())
  let assert Ok(Nil) = bootstrap.ensure_private_directory(outside)
    as "the outside directory exists"
  let assert Ok(outside) = bootstrap.canonical_directory(outside)
    as "the outside directory is absolute"
  let assert Ok(Nil) = simplifile.write(outside <> "/secret", "SECRET")
    as "the secret is written"
  let wide =
    policy.SandboxPolicy(..real.base, readable_roots: [
      outside,
      ..real.base.readable_roots
    ])
  let spec =
    untrusted_wire.TunnelSpec(
      ..real_spec(real, "wide", ["/bin/cat", outside <> "/secret"], 4096),
      base_policy: wide,
      requirements: policy.SandboxPolicy(
        ..wide,
        limits: policy.Limits(..wide.limits, output_bytes: 4096, wall_s: 60),
      ),
      response: broker.ProceedNarrowed,
    )
  send_clear(stream, 2, spec, 15_000)
  assert cleared_within(stream, 2, 20_000) == Ok(Nil)
  let #(chunks, outcome) = settlement(stream, 2, [])
  assert !string.contains(
    bit_array.to_string(stdout_of(chunks)) |> result.unwrap(""),
    "SECRET",
  )
  let assert broker.CallExited(result:) = outcome as "cat exits"
  assert result.code != 0
}
