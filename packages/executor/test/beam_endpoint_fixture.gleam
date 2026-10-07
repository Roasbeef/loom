//// Fixed owner and executor entrypoints run on independent authenticated OS VMs.
//// Coordination files are test barriers; canonical workspace effects execute only
//// through the executor's local semantic service. No role runner performs RPC
//// closures or substitutes native history for a fresh whole-service Claim.

import broker/broker
import broker/enrollment
import broker/exec
import broker/executor as local
import broker/policy
import codemode/compile
import codemode/run_channel as channel
import codemode/service_input as input
import codemode/vet/policy as vet_policy
import core/clock
import core/command
import core/ids
import core/remote_tool
import core/workspace as cw
import distribution_fixture as fixture
import envoy
import executor/remote/admission
import executor/remote/beam_endpoint as endpoint
import executor/remote/compile_service as compile_whole
import executor/remote/distribution
import executor/remote/identity
import executor/remote/internal/beam_protocol as protocol
import executor/remote/journal
import executor/remote/launch_beam as bridge
import executor/remote/launch_service as launch
import executor/remote/launch_wire
import executor/remote/resource_journal as j
import executor/remote/service
import executor/remote/wire
import executor/remote/workspace_journal as wj
import executor/remote/workspace_service as ws
import executor/remote/workspace_transfer as transfer
import gleam/bit_array
import gleam/crypto
import gleam/dynamic
import gleam/erlang/process
import gleam/erlang/reference
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import launch_stream_preparation_fixture as preparation
import simplifile
import telemetry/log
import tools/directory_access
import tools/fs
import tools/tool
import tools/workspace as w
import tools/workspace_codec as codec
import tools/workspace_local
import weft
import weft/actor
import weft/poll

type BindPrepared {
  BindPrepared(command.ServiceKey)
}

type BindSocket

@external(erlang, "executor_launch_socket_fixture", "connect_unix")
fn bind_connect(path: String) -> Result(BindSocket, Nil)

@external(erlang, "executor_launch_socket_fixture", "peer_send")
fn bind_send(socket: BindSocket, bytes: BitArray) -> Result(Nil, Nil)

@external(erlang, "executor_launch_socket_fixture", "peer_recv")
fn bind_receive(socket: BindSocket, within_ms: Int) -> Result(BitArray, Nil)

@external(erlang, "executor_launch_socket_fixture", "peer_close")
fn bind_close(socket: BindSocket) -> Nil

// Existing OTP primitives park the concrete service, never a mocked exchange.
@external(erlang, "erlang", "suspend_process")
fn suspend(pid: process.Pid) -> Nil

@external(erlang, "erlang", "resume_process")
fn resume(pid: process.Pid) -> Nil

// These fixed test probes capture and inject one actual previous local handoff.
// Production exposes neither private subjects nor a state-replacement API.
@external(erlang, "executor_beam_endpoint_test_ffi", "launch_snapshot")
fn launch_snapshot(pid: process.Pid) -> String

type HandoffProbe

@external(erlang, "executor_beam_endpoint_test_ffi", "credits")
fn credits(server: process.Pid) -> List(process.Subject(Nil))

@external(erlang, "executor_beam_endpoint_test_ffi", "capture")
fn capture(credits: List(process.Subject(Nil))) -> Result(HandoffProbe, Nil)

@external(erlang, "executor_beam_endpoint_test_ffi", "head")
fn head(server: process.Pid) -> process.Subject(Nil)

@external(erlang, "executor_beam_endpoint_test_ffi", "inject_idle")
fn inject_idle(
  probe: HandoffProbe,
  subject: process.Subject(Nil),
) -> Result(Nil, Nil)

@external(erlang, "executor_beam_endpoint_test_ffi", "inject_active")
fn inject_active(
  probe: HandoffProbe,
  subject: process.Subject(Nil),
) -> Result(Nil, Nil)

pub fn executor_main() {
  let #(root, provisioned) = inputs()
  let assert Ok(membership) = distribution.start(provisioned.executor_config)
    as "real executor TLS bootstrap"
  let assert Ok(owner) = distribution.peer(membership, provisioned.owner_name)
    as "fixed authenticated owner"
  let native = native()
  let first = native_service(root, native, 1)
  let second = native_service(root, native, 2)
  let semantic = semantic_service(root)
  let assert Ok(base_row) =
    endpoint.registration(owner, first, Some(semantic), process.self())
    as "concrete scope registration"
  let assert Ok(capacity) = j.limits(8, 30_000_000)
    as "finite Launch history capacity"
  let assert Ok(book) =
    j.fresh(
      root <> "/launch.sqlite",
      control_enrolled(),
      capacity,
      service.configuration(first).journal,
    )
    as "same original native resource binding"
  let assert Ok(whole) =
    launch.configure(book, first, 2) |> result.try(launch.start)
    as "concrete whole Launch owner"
  let assert Ok(contract) =
    input.trusted_contract(
      control_enrolled(),
      input.WorkspaceProgram,
      vet_policy.workspace_effects(),
      [],
    )
    as "trusted source contract on original enrollment"
  let assert Ok(compiled_owner) =
    compile_whole.configure(book, first, contract, 1)
    |> result.try(compile_whole.start)
    as "original whole Compile owner"
  assert endpoint.attach_launch(base_row, whole) |> result.is_ok
  assert compile_whole.resource_owner(compiled_owner) == j.pid(book)
  assert launch.resource_owner(whole) == j.pid(book)
  let assert Ok(shared_row) =
    endpoint.compile_registration(
      owner,
      compiled_owner,
      Some(semantic),
      process.self(),
    )
    as "Compile retains the original resource writer"
  let assert Ok(other_book) =
    j.fresh(
      root <> "/other-launch.sqlite",
      control_enrolled(),
      capacity,
      service.configuration(first).journal,
    )
    as "equal enrollment with a different live resource writer"
  let assert Ok(other_whole) =
    launch.configure(other_book, first, 2) |> result.try(launch.start)
    as "different writer passes independent service configuration"
  assert endpoint.attach_launch(shared_row, other_whole)
    == Error(endpoint.InvalidConfiguration)
  let assert Ok(row) = endpoint.attach_launch(shared_row, whole)
    as "same-row Launch attachment"
  assert endpoint.attach_launch(row, whole)
    == Error(endpoint.InvalidConfiguration)
  assert launch.configure(book, second, 2) == Error(launch.InvalidConfiguration)
  let assert Ok(other) =
    endpoint.registration(owner, second, None, process.self())
    as "second exact scope"
  let assert Ok(config) = endpoint.configure_server([], 1500)
    as "bounded dynamic table"
  let assert Ok(server) = endpoint.start(config)
    as "single registered rendezvous"
  assert endpoint.register(server, row) == Ok(Nil)
  assert endpoint.register(server, row)
    == Error(endpoint.ConflictingRegistration)
  assert endpoint.register(server, other) == Ok(Nil)
  int.range(3, 17, Nil, fn(_, epoch) {
    let concrete = native_service(root, native, epoch)
    let assert Ok(row) =
      endpoint.registration(owner, concrete, None, process.self())
      as "bounded concrete scope"
    assert endpoint.register(server, row) == Ok(Nil)
  })
  let assert Ok(overflow) =
    endpoint.registration(
      owner,
      native_service(root, native, 17),
      None,
      process.self(),
    )
    as "seventeenth concrete scope"
  assert endpoint.register(server, overflow)
    == Error(endpoint.InvalidConfiguration)
  assert endpoint.inspect(server) == Ok(endpoint.Capacity(16, 4, 2))
  let original_credits = credits(endpoint.pid(server))
  mark(root, "ready")
  await(root, "launch-suspend")
  suspend(launch.pid(whole))
  mark(root, "launch-suspended")
  await(root, "launch-held")
  assert endpoint.inspect(server) == Ok(endpoint.Capacity(16, 0, 0))
  assert endpoint.inspect_drain(server, row) == Ok(endpoint.Busy)
  resume(launch.pid(whole))
  let assert poll.Answered(Nil) =
    poll.until(2000, 10, fn() {
      case endpoint.inspect(server) {
        Ok(endpoint.Capacity(16, 4, 2)) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "actual Launch replies and producer retirement return all six finite credits"
  assert endpoint.inspect_drain(server, row) == Ok(endpoint.Busy)
  mark(root, "launch-drained")
  await(root, "suspend")
  suspend(service.pid(first))
  mark(root, "suspended")
  await(root, "data-held")
  assert endpoint.inspect(server) == Ok(endpoint.Capacity(16, 0, 2))
  let assert Ok(probe) = capture(original_credits)
    as "actual original handoff references while queued"
  mark(root, "held-checked")
  await(root, "control-started")
  let assert poll.Answered(Nil) =
    poll.until(1500, 10, fn() {
      case endpoint.inspect(server) {
        Ok(endpoint.Capacity(16, 0, 1)) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "control still has independent capacity while data is unresolved"
  resume(service.pid(first))
  let assert poll.Answered(Nil) =
    poll.until(2000, 10, fn() {
      case endpoint.inspect(server) {
        Ok(endpoint.Capacity(16, 4, 2)) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "actual service replies plus joined runs restore credits"
  mark(root, "drained")
  await(root, "drain-observed")
  let same_credit = head(endpoint.pid(server))
  assert inject_idle(probe, same_credit) == Ok(Nil)
  assert endpoint.inspect(server) == Ok(endpoint.Capacity(16, 4, 2))
  suspend(service.pid(first))
  mark(root, "stale-ready")
  await(root, "reuse-started")
  let assert poll.Answered(Nil) =
    poll.until(1000, 10, fn() {
      case inject_active(probe, same_credit) {
        Ok(Nil) -> poll.Done(Nil)
        Error(Nil) -> poll.Retry
      }
    })
    as "same stable credit discards old handoff while current native ask is held"
  assert endpoint.inspect(server) == Ok(endpoint.Capacity(16, 3, 2))
  resume(service.pid(first))
  await(root, "reuse-complete")
  let assert poll.Answered(Nil) =
    poll.until(2000, 10, fn() {
      case endpoint.inspect(server) {
        Ok(endpoint.Capacity(16, 4, 2)) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "new run keeps its own service ask and transport drain"
  await(root, "launch-loss")
  suspend(launch.pid(whole))
  mark(root, "launch-loss-suspended")
  await(root, "launch-loss-held")
  assert endpoint.inspect(server) == Ok(endpoint.Capacity(16, 4, 1))
  process.kill(launch.pid(whole))
  assert endpoint.fence(server, row) == Ok(Nil)
  let assert poll.Answered(Nil) =
    poll.until(500, 10, fn() {
      case endpoint.inspect_drain(server, row) {
        Ok(endpoint.DrainUncertain) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "Launch owner loss preserves its original unresolved finite assignment"
  assert endpoint.inspect(server) == Ok(endpoint.Capacity(16, 4, 1))
  mark(root, "launch-loss-observed")
  await(root, "quiesce")
  endpoint.quiesce(server)
  assert endpoint.inspect(server) == Ok(endpoint.Capacity(16, 4, 1))
  assert endpoint.register(server, row) == Error(endpoint.InvalidConfiguration)
  mark(root, "quiesced")
  await(root, "done")
  assert simplifile.read(root <> "/workspace/file")
    == Ok(string.repeat("x", 70_000))
  assert ws.close(semantic) == Ok(Nil)
  endpoint.stop(server)
  simplifile.write(
    root <> "/executor-success",
    "exact_scope_shared_credits_actual_reply_drain_stale_reference_refused",
  )
}

pub fn owner_main() {
  let #(root, provisioned) = inputs()
  let assert Ok(membership) = distribution.start(provisioned.owner_config)
    as "real owner TLS bootstrap"
  let assert Ok(peer) = distribution.peer(membership, provisioned.executor_name)
    as "fixed authenticated executor"
  await(root, "ready")
  let config = endpoint.Config(peer, "owner", "executor", scope(1), 1, 3000)
  assert endpoint.validate(config) == Ok(Nil)
  assert endpoint.validate(endpoint.Config(..config, within_ms: 0))
    == Error(endpoint.InvalidConfiguration)
  let launch_original =
    control_launched(control_compiled("pub fn main() { Nil }", 3).key, 5)
  let assert Ok(launch_bytes) =
    launch_wire.encode_input(control_enrolled(), launch_original)
    as "canonical full Launch envelope"
  let assert Ok(#(challenge, None)) =
    endpoint.launch_exchange(config, launch_wire.ChallengeRequest, launch_bytes)
    as "actual finite Launch challenge route"
  let assert Ok(launch_wire.Challenge(returned, nonce, 1000)) =
    launch_wire.decode_reply(
      control_enrolled(),
      launch_original,
      challenge,
      None,
    )
    as "actual service answer preserves full original key"
  assert returned == launch_original.key
  let assert Ok(placement) =
    launch_wire.encode_placement(control_enrolled(), launch_original, <<
      7:size(256),
    >>)
    as "closed token transport body"
  let assert Ok(#(refusal, None)) =
    endpoint.launch_exchange(
      config,
      launch_wire.PlaceToken(nonce, 1000),
      placement,
    )
    as "actual token admission refusal still returns metadata"
  assert launch_wire.decode_reply(
      control_enrolled(),
      launch_original,
      refusal,
      None,
    )
    == Error(launch_wire.Refused)
  let assert Ok(#(query, None)) =
    endpoint.launch_exchange(config, launch_wire.Query, launch_bytes)
    as "actual historical query reaches Launch"
  assert launch_wire.decode_reply(
      control_enrolled(),
      launch_original,
      query,
      None,
    )
    == Error(launch_wire.Refused)
  assert endpoint.exchange(config, wire.Hello) == Ok(wire.Hello)
  assert endpoint.exchange(
      endpoint.Config(..config, scope: scope(2)),
      wire.Hello,
    )
    == Ok(wire.Hello)
  assert endpoint.exchange(
      endpoint.Config(..config, generation: 2, within_ms: 100),
      wire.Hello,
    )
    == Error(endpoint.Uncertain)
  assert endpoint.exchange(
      endpoint.Config(..config, scope: scope(18), within_ms: 100),
      wire.Hello,
    )
    == Error(endpoint.Uncertain)
  let assert Ok(satellite_ref) =
    command.command_ref(launch_original.key, command.SatelliteCommand)
    as "exact role-bound Satellite command"
  let assert Ok(rejected) =
    endpoint.exchange_command(
      config,
      satellite_ref,
      wire.ChallengeRequest(key(), control_digest()),
    )
    as "unclaimed command receives actual whole-owner refusal"
  let assert wire.Rejected(_) = rejected
    as "a missing retained Launch Claim never falls back to native Challenge"
  mark(root, "launch-suspend")
  await(root, "launch-suspended")
  let launch_operations = [
    launch_wire.ChallengeRequest,
    launch_wire.ChallengeRequest,
    launch_wire.ChallengeRequest,
    launch_wire.ChallengeRequest,
    launch_wire.Query,
    launch_wire.Query,
  ]
  let held =
    weft.new(
      list.map(launch_operations, fn(operation) {
        fn() {
          Ok(endpoint.launch_exchange(
            endpoint.Config(..config, within_ms: 250),
            operation,
            launch_bytes,
          ))
        }
      }),
    )
    |> weft.deadline(1000)
    |> weft.start
  assert list.length(weft.values(held)) == 6
  list.each(weft.values(held), fn(answer) {
    assert answer == Error(endpoint.Uncertain)
  })
  mark(root, "launch-held")
  await(root, "launch-drained")
  let bytes = invocation()
  let submitted = endpoint.workspace_exchange(config, protocol.Submit, bytes)
  assert submitted == Ok(wj.Accepted) || submitted == Ok(wj.Unknown)
  let assert poll.Answered(completion) =
    poll.until(2500, 10, fn() {
      case endpoint.workspace_exchange(config, protocol.Query, bytes) {
        Ok(wj.Finished(bytes)) -> poll.Done(bytes)
        Ok(wj.Unknown) | Ok(wj.Accepted) -> poll.Retry
        other -> poll.Fail(other)
      }
    })
    as "exact executor-side write completion"
  let assert Ok(digest) =
    identity.digest(crypto.hash(crypto.Sha256, completion))
    as "exact receipt digest"
  assert endpoint.workspace_exchange(
      config,
      protocol.Acknowledge(digest),
      bytes,
    )
    == Ok(wj.Acknowledged(identity.digest_bytes(digest)))
  mark(root, "suspend")
  await(root, "suspended")
  let callers =
    weft.new(list.repeat(
      fn() {
        Ok(endpoint.exchange(
          endpoint.Config(..config, within_ms: 250),
          wire.ChallengeRequest(key(), digest),
        ))
      },
      4,
    ))
    |> weft.deadline(2000)
    |> weft.start
  assert weft.values(callers) == list.repeat(Error(endpoint.Uncertain), 4)
  mark(root, "data-held")
  await(root, "held-checked")
  assert endpoint.exchange(
      endpoint.Config(..config, within_ms: 100),
      wire.ChallengeRequest(key(), digest),
    )
    == Error(endpoint.Uncertain)
  mark(root, "control-started")
  assert endpoint.exchange(config, wire.Hello) == Ok(wire.Hello)
  await(root, "drained")
  assert endpoint.exchange(config, wire.Hello) == Ok(wire.Hello)
  mark(root, "drain-observed")
  await(root, "stale-ready")
  mark(root, "reuse-started")
  let assert Ok(wire.Challenge(returned_key, returned_digest, _, _)) =
    endpoint.exchange(config, wire.ChallengeRequest(key(), digest))
    as "new run survives stale same-credit handoff injection"
  assert returned_key == key()
  assert returned_digest == digest
  mark(root, "reuse-complete")
  mark(root, "launch-loss")
  await(root, "launch-loss-suspended")
  assert endpoint.launch_exchange(
      endpoint.Config(..config, within_ms: 250),
      launch_wire.Query,
      launch_bytes,
    )
    == Error(endpoint.Uncertain)
  mark(root, "launch-loss-held")
  await(root, "launch-loss-observed")
  mark(root, "quiesce")
  await(root, "quiesced")
  assert endpoint.exchange(
      endpoint.Config(..config, within_ms: 100),
      wire.Hello,
    )
    == Error(endpoint.Uncertain)
  mark(root, "done")
  assert simplifile.write(
      root <> "/owner-success",
      "canonical_multichunk_workspace_exact_ack",
    )
    == Ok(Nil)
}

fn inputs() -> #(String, fixture.Provisioned) {
  let assert Ok(root) = envoy.get("LOOM_BEAM_ENDPOINT_FIXTURE")
    as "parent-chosen fixed fixture"
  let assert Ok(provisioned) = fixture.read_provisioned(root <> "/fixture.term")
    as "trusted administrative fixture"
  #(root, provisioned)
}

fn mark(root: String, name: String) {
  assert simplifile.write(root <> "/" <> name, "ready") == Ok(Nil)
}

fn await(root: String, name: String) {
  let assert poll.Answered(Nil) =
    poll.until(15_000, 10, fn() {
      case simplifile.is_file(root <> "/" <> name) {
        Ok(True) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "finite two-node barrier"
}

fn scope(epoch: Int) -> identity.Scope {
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-000000000001")
    as "fixture session"
  let assert Ok(workspace) = identity.workspace_id("checkout")
    as "fixture workspace"
  let assert Ok(executor) = identity.executor_id("executor")
    as "fixture executor"
  let assert Ok(session_epoch) = identity.epoch(1) as "fixture session epoch"
  let assert Ok(workspace_epoch) = identity.epoch(epoch)
    as "fixture workspace epoch"
  identity.scope(session, workspace, executor, session_epoch, workspace_epoch)
}

fn core_scope() -> cw.Scope {
  let assert Ok(scope) =
    cw.scope_from_fields(
      "00000000-0000-7000-8000-000000000001",
      "checkout",
      "executor",
      1,
      1,
    )
    as "semantic scope"
  scope
}

fn key() -> identity.RequestKey {
  let assert Ok(operation) =
    ids.parse_op_id("00000000-0000-7000-8000-000000000002")
    as "fixture operation"
  let assert Ok(request) =
    identity.request_id("00000000-0000-7000-8000-000000000003")
    as "fixture request"
  identity.request_key(scope(1), operation, request)
}

fn native() -> local.Executor {
  let assert Ok(native) =
    local.start(local.ExecutorConfig(
      fn() { Error(exec.PoolUnavailable) },
      fn(_) { Nil },
      fn() { Error(exec.PoolUnavailable) },
      fn(_) { Ok(Nil) },
      17,
      log.discard(),
    ))
    as "real native actor without effects"
  native
}

fn native_service(
  root: String,
  native: local.Executor,
  epoch: Int,
) -> service.Service {
  let assert Ok(capacity) = admission.capacity(8) as "native admission"
  let suffix = int.to_string(epoch)
  let assert Ok(book) =
    journal.fresh(root <> "/" <> suffix <> ".sqlite", scope(epoch), capacity)
    as "real native journal"
  let assert Ok(remote) =
    service.start(service.Config(
      "owner",
      "executor",
      scope(epoch),
      1,
      book,
      native,
      fn(_, _) { Ok(Nil) },
      poll.monotonic().now,
    ))
    as "real scoped native service"
  remote
}

fn semantic_service(root: String) -> ws.Service {
  let workspace_root = root <> "/workspace"
  assert simplifile.create_directory(workspace_root) == Ok(Nil)
  let assert Ok(operation) =
    ids.parse_op_id("00000000-0000-7000-8000-000000000002")
    as "context operation"
  let ctx =
    tool.Ctx(
      workspace: tool.LocalWorkspace(workspace_root, fs.real_filesystem()),
      strand: "main",
      op_id: operation,
      step_id: "physical-step",
      source_index: 0,
      base_policy: policy.workspace_default(workspace_root),
      directory_access: directory_access.none(),
      grants: [],
      demand: exec.FullEnforcement,
      env: [],
      clock: clock.fixed(0),
      owner_blobs: tool.OwnerBlobs(
        workspace_root <> "/.blobs",
        fs.real_filesystem(),
      ),
      clear_call: fn(_, _) { Error(broker.BrokerUnavailable) },
      raise_refusal: tool.no_raise(),
      observe_output: tool.ignore_output(),
    )
  let assert Ok(host) = workspace_local.new(core_scope(), ctx, fn(_) { None })
    as "actual executor filesystem host"
  let assert Ok(limits) = wj.limits(6, 256_000_000) as "semantic custody limits"
  let assert Ok(book) =
    wj.fresh(root <> "/workspace.sqlite", core_scope(), limits)
    as "actual semantic custody"
  let assert Ok(config) = ws.configure(host, book, 4, 3000)
    as "checked semantic service"
  let assert Ok(service) = ws.start(config) as "concrete semantic actor"
  service
}

fn invocation() -> BitArray {
  let assert Ok(operation) =
    ids.parse_op_id("00000000-0000-7000-8000-000000000002")
    as "input operation"
  let assert Ok(id) = ids.parse_entry_id("00000000-0000-7000-8000-000000000004")
    as "input request"
  let assert Ok(step) = cw.step("physical-step") as "input step"
  let assert Ok(path) = cw.relative_path("file") as "relative effect path"
  let assert Ok(bytes) =
    codec.encode_invocation(w.invocation(
      core_scope(),
      operation,
      step,
      w.System(w.WorkspaceAdministration),
      id,
      w.Write(path, string.repeat("x", 70_000)),
    ))
    as "canonical multichunk input"
  bytes
}

// Scoped tests observe the private controller only to distinguish actual answer
// and managed producer retirement. Every assignment still comes from real TLS.
type ReleaseProbe

@external(erlang, "executor_beam_endpoint_test_ffi", "capture_release")
fn capture_release(server: process.Pid) -> ReleaseProbe

@external(erlang, "executor_beam_endpoint_test_ffi", "inject_release")
fn inject_release(
  probe: ReleaseProbe,
  server: endpoint.Server,
) -> Result(Nil, Nil)

@external(erlang, "executor_beam_endpoint_test_ffi", "retire_idle")
fn retire_idle(server: process.Pid) -> Nil

@external(erlang, "executor_beam_endpoint_test_ffi", "retire_busy")
fn retire_busy(server: process.Pid) -> Nil

@external(erlang, "executor_beam_endpoint_test_ffi", "answer_waiting")
fn answer_waiting(server: process.Pid) -> Bool

@external(erlang, "executor_beam_endpoint_test_ffi", "joined_waiting")
fn joined_waiting(server: process.Pid) -> Bool

type ScopeOwnerMessage {
  FinishOwner
}

type RawReservation {
  Reservation(
    BitArray,
    reference.Reference,
    process.Pid,
    process.Subject(RawReply),
  )
}

type RawReply {
  Granted(reference.Reference, process.Subject(RawFrame))
  Consumed(reference.Reference, Int)
  Returned(reference.Reference, Int, BitArray)
  BindReturned(reference.Reference, BitArray, bridge.Door)
}

type RawFrame {
  Input(reference.Reference, Int, BitArray)
  ReplyConsumed(reference.Reference, Int)
  BindInput(reference.Reference, BitArray, bridge.Door)
}

/// Fixed scoped-lifecycle executor role with distinct pools, journals and owners.
///
/// ## Examples
/// `scoped_executor_main()` runs only under the parent TLS test fixture.
pub fn scoped_executor_main() {
  let #(root, provisioned) = inputs()
  let assert Ok(membership) = distribution.start(provisioned.executor_config)
    as "scoped executor TLS bootstrap"
  let assert Ok(owner) = distribution.peer(membership, provisioned.owner_name)
    as "original provisioned owner"
  let first = scoped_native(root, 1)
  let second = scoped_native(root, 2)
  let third = scoped_native(root, 3)
  let fourth = scoped_native(root, 4)
  let assert Ok(a) = endpoint.registration(owner, first.1, None, first.2)
    as "A original local lifetime"
  let assert Ok(b) = endpoint.registration(owner, second.1, None, second.2)
    as "B independent original local lifetime"
  let assert Ok(c) = endpoint.registration(owner, third.1, None, third.2)
    as "C independent local owner"
  let assert Ok(d) = endpoint.registration(owner, fourth.1, None, fourth.2)
    as "D independent local owner"
  let assert Ok(mismatch) =
    endpoint.registration(owner, first.1, None, second.2)
    as "same scope with different concrete lifetime owner"
  let assert Ok(missing) =
    endpoint.registration(
      owner,
      native_service(root, native(), 5),
      None,
      process.self(),
    )
    as "not enrolled scope"
  let assert Ok(config) = endpoint.configure_server([a, b, c, d], 1500)
    as "initial rows use the same monitored enrollment path"
  let assert Ok(server) = endpoint.start(config) as "shared node endpoint"
  assert endpoint.inspect_drain(server, a) == Ok(endpoint.Busy)
  assert endpoint.inspect_drain(server, mismatch)
    == Error(endpoint.InvalidConfiguration)
  assert endpoint.fence(server, missing) == Error(endpoint.InvalidConfiguration)
  assert endpoint.fence(server, mismatch)
    == Error(endpoint.InvalidConfiguration)
  mark(root, "scope-ready")
  await(root, "scope-hold-a")
  suspend(service.pid(first.1))
  mark(root, "scope-a-suspended")
  await(root, "scope-a-caller-joined")
  let assert poll.Answered(Nil) =
    poll.until(2000, 10, fn() {
      case joined_waiting(endpoint.pid(server)) {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
    as "actual transport AllDelivered precedes A service answer"
  let original = capture_release(endpoint.pid(server))
  assert endpoint.inspect(server) == Ok(endpoint.Capacity(4, 3, 2))
  assert endpoint.fence(server, a) == Ok(Nil)
  assert endpoint.fence(server, a) == Ok(Nil)
  assert endpoint.register(server, a) == Error(endpoint.ConflictingRegistration)
  assert endpoint.inspect_drain(server, a) == Ok(endpoint.Busy)
  mark(root, "scope-a-fenced")
  await(root, "scope-sibling-checked")
  assert endpoint.inspect(server) == Ok(endpoint.Capacity(4, 3, 2))
  assert endpoint.inspect_drain(server, a) == Ok(endpoint.Busy)
  resume(service.pid(first.1))
  scoped_drain(server, a, endpoint.Drained)
  mark(root, "scope-a-drained")
  await(root, "scope-b-old-answer-held")
  let old_b = capture_release(endpoint.pid(server))
  mark(root, "scope-b-old-release-checked")
  await(root, "scope-b-old-producer-joined")
  scoped_capacity(server, endpoint.Capacity(4, 4, 2))
  mark(root, "scope-b-old-credit-returned")
  await(root, "scope-b-current-answer-held")
  let assert poll.Answered(Nil) =
    poll.until(2000, 10, fn() {
      case answer_waiting(endpoint.pid(server)) {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
    as "actual B service answer precedes transport AllDelivered"
  assert endpoint.fence(server, b) == Ok(Nil)
  assert endpoint.inspect_drain(server, b) == Ok(endpoint.Busy)
  assert inject_release(original, server) == Ok(Nil)
  assert inject_release(old_b, server) == Ok(Nil)
  assert endpoint.inspect(server) == Ok(endpoint.Capacity(4, 3, 2))
  assert endpoint.inspect_drain(server, b) == Ok(endpoint.Busy)
  assert endpoint.inspect_drain(server, a) == Ok(endpoint.Drained)
  mark(root, "scope-b-current-release-checked")
  await(root, "scope-b-current-producer-joined")
  scoped_drain(server, b, endpoint.Drained)
  retire_idle(endpoint.pid(server))
  scoped_capacity(server, endpoint.Capacity(4, 3, 2))
  assert endpoint.inspect_drain(server, a) == Ok(endpoint.Drained)
  assert endpoint.inspect_drain(server, b) == Ok(endpoint.Drained)
  assert endpoint.inspect_drain(server, c) == Ok(endpoint.Busy)
  process.send(third.0, FinishOwner)
  scoped_drain(server, c, endpoint.Drained)
  mark(root, "scope-idle-loss-checked")
  await(root, "scope-owner-down-checked")
  assert endpoint.inspect(server) == Ok(endpoint.Capacity(4, 3, 2))
  suspend(service.pid(fourth.1))
  mark(root, "scope-d-suspended")
  await(root, "scope-d-caller-joined")
  scoped_capacity(server, endpoint.Capacity(4, 2, 2))
  let lost = capture_release(endpoint.pid(server))
  assert endpoint.fence(server, d) == Ok(Nil)
  assert endpoint.inspect_drain(server, d) == Ok(endpoint.Busy)
  retire_busy(endpoint.pid(server))
  scoped_drain(server, d, endpoint.DrainUncertain)
  assert inject_release(lost, server) == Ok(Nil)
  assert endpoint.inspect_drain(server, d) == Ok(endpoint.DrainUncertain)
  assert endpoint.inspect(server) == Ok(endpoint.Capacity(4, 2, 2))
  assert endpoint.inspect_drain(server, a) == Ok(endpoint.Drained)
  resume(service.pid(fourth.1))
  mark(root, "scope-busy-loss-checked")
  await(root, "scope-done")
  endpoint.stop(server)
  mark(root, "scoped-executor-success")
}

/// Fixed real-peer role tests stale reservations and both answer/join orders.
///
/// ## Examples
/// `scoped_owner_main()` has no production RPC callback or fabricated Peer.
pub fn scoped_owner_main() {
  let #(root, provisioned) = inputs()
  let assert Ok(membership) = distribution.start(provisioned.owner_config)
    as "scoped owner TLS bootstrap"
  let assert Ok(peer) = distribution.peer(membership, provisioned.executor_name)
    as "actual configured executor peer"
  let config = endpoint.Config(peer, "owner", "executor", scope(1), 1, 3000)
  let assert Ok(digest) = identity.digest(crypto.hash(crypto.Sha256, <<1>>))
    as "canonical challenge digest"
  await(root, "scope-ready")
  mark(root, "scope-hold-a")
  await(root, "scope-a-suspended")
  assert endpoint.exchange(
      endpoint.Config(..config, within_ms: 200),
      wire.ChallengeRequest(key(), digest),
    )
    == Error(endpoint.Uncertain)
  mark(root, "scope-a-caller-joined")
  await(root, "scope-a-fenced")
  assert endpoint.exchange(
      endpoint.Config(..config, within_ms: 100),
      wire.ChallengeRequest(key(), digest),
    )
    == Error(endpoint.Uncertain)
  assert endpoint.exchange(
      endpoint.Config(..config, within_ms: 100),
      wire.Hello,
    )
    == Error(endpoint.Uncertain)
  let other = endpoint.Config(..config, scope: scope(2))
  assert endpoint.exchange(other, wire.Hello) == Ok(wire.Hello)
  let assert Ok(wire.Challenge(_, _, _, _)) =
    endpoint.exchange(other, wire.ChallengeRequest(scoped_key(2), digest))
    as "B uses remaining data capacity while A is fenced and still busy"
  mark(root, "scope-sibling-checked")
  await(root, "scope-a-drained")
  raw_answer_before_join(root, peer, digest, "old")
  mark(root, "scope-b-old-producer-joined")
  await(root, "scope-b-old-credit-returned")
  raw_answer_before_join(root, peer, digest, "current")
  mark(root, "scope-b-current-producer-joined")
  await(root, "scope-idle-loss-checked")
  assert endpoint.exchange(
      endpoint.Config(..config, scope: scope(3), within_ms: 100),
      wire.Hello,
    )
    == Error(endpoint.Uncertain)
  assert endpoint.exchange(
      endpoint.Config(..config, scope: scope(4)),
      wire.Hello,
    )
    == Ok(wire.Hello)
  mark(root, "scope-owner-down-checked")
  await(root, "scope-d-suspended")
  assert endpoint.exchange(
      endpoint.Config(..config, scope: scope(4), within_ms: 200),
      wire.ChallengeRequest(scoped_key(4), digest),
    )
    == Error(endpoint.Uncertain)
  mark(root, "scope-d-caller-joined")
  await(root, "scope-busy-loss-checked")
  assert endpoint.exchange(
      endpoint.Config(..config, scope: scope(4), within_ms: 100),
      wire.Hello,
    )
    == Error(endpoint.Uncertain)
  mark(root, "scope-done")
  mark(root, "scoped-owner-success")
}

fn scoped_native(
  root: String,
  epoch: Int,
) -> #(process.Subject(ScopeOwnerMessage), service.Service, process.Pid) {
  let assert Ok(started) =
    actor.new_with_initialiser(1000, fn(subject) {
      // These metadata-only controls need distinct real pools, not launched effects.
      let assert Ok(pool) =
        exec.start_pool(1, fn() { Error(exec.PortOpenFailed) })
        as "independent original native pool"
      let assert Ok(native) =
        local.start(local.ExecutorConfig(
          fn() { exec.checkout(pool, 1000) },
          fn(helper) { exec.checkin(pool, helper) },
          fn() { exec.pool_custody(pool, 1000) },
          fn(ms) { exec.close_pool(pool, ms) },
          epoch,
          log.discard(),
        ))
        as "scope-local native custody actor"
      let service = native_service(root, native, epoch)
      Ok(actor.initialised(Nil) |> actor.returning(#(subject, service)))
    })
    |> actor.on_message(fn(_, message) {
      case message {
        FinishOwner -> actor.stop()
      }
    })
    |> actor.start
    as "concrete lifetime owner starts its linked original services"
  #(started.data.0, started.data.1, started.pid)
}

fn scoped_key(epoch: Int) -> identity.RequestKey {
  let #(operation_text, request_text) = identity.key_fields(key())
  let assert Ok(operation) = ids.parse_op_id(operation_text)
    as "same original operation"
  let assert Ok(request) = identity.request_id(request_text)
    as "same original request"
  identity.request_key(scope(epoch), operation, request)
}

fn scoped_drain(
  server: endpoint.Server,
  row: endpoint.Registration,
  expected: endpoint.DrainState,
) {
  let assert poll.Answered(Nil) =
    poll.until(2000, 10, fn() {
      case endpoint.inspect_drain(server, row) == Ok(expected) {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
    as "exact scoped transport disposition"
}

fn scoped_capacity(server: endpoint.Server, expected: endpoint.Capacity) {
  let assert poll.Answered(Nil) =
    poll.until(2000, 10, fn() {
      case endpoint.inspect(server) == Ok(expected) {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
    as "actual six-record capacity snapshot"
}

fn raw_answer_before_join(
  root: String,
  peer: distribution.Peer,
  digest: identity.Digest,
  round: String,
) {
  let assert Ok(Nil) = distribution.connect(peer, 3000)
    as "explicit TLS connection"
  let assert Ok(pid) = distribution.endpoint(peer, 3000)
    as "fixed literal endpoint lookup"
  let door =
    process.unsafely_create_subject(
      pid,
      dynamic.string("loom.executor.endpoint/1"),
    )
  let binding = protocol.Binding("owner", "executor", 1, scope(2))
  let assert Ok(header) =
    protocol.header(binding, protocol.Native(protocol.Data))
    as "canonical data reservation"
  let reply = process.new_subject()
  let correlation = reference.new()
  assert distribution.send(
      door,
      Reservation(header, correlation, process.self(), reply),
    )
    == distribution.Sent
  let assert Ok(Granted(ref, incoming)) = process.receive(reply, 3000)
    as "real TLS credit granted"
  assert ref == correlation
  let assert Ok(bytes) =
    wire.encode(protocol.envelope(
      binding,
      wire.Owner,
      wire.ChallengeRequest(scoped_key(2), digest),
    ))
    as "closed actual native request"
  let assert Ok(#(head, sender)) =
    transfer.begin_send(transfer.Invocation, bytes)
    as "bounded original transfer"
  assert distribution.send(incoming, Input(ref, 0, head)) == distribution.Sent
  let assert Ok(Consumed(ack, 0)) = process.receive(reply, 3000)
    as "header acknowledged"
  assert ack == ref
  raw_input(sender, incoming, reply, ref, 1)
  let assert Ok(Returned(answer_ref, 0, answer_header)) =
    process.receive(reply, 3000)
    as "actual service answer reached transport"
  assert answer_ref == ref
  let assert Ok(receiver) =
    transfer.begin_receive(transfer.Completion, answer_header)
    as "bounded canonical reply"
  mark(root, "scope-b-" <> round <> "-answer-held")
  await(root, "scope-b-" <> round <> "-release-checked")
  assert distribution.send(incoming, ReplyConsumed(ref, 0)) == distribution.Sent
  let returned = raw_output(receiver, incoming, reply, ref, 1)
  let assert Ok(envelope) = protocol.native(binding, wire.Executor, returned)
    as "actual original answer decoded"
  let assert wire.Challenge(_, _, _, _) = envelope.body
    as "real native service result"
}

fn raw_input(
  sender: transfer.Sender,
  incoming: process.Subject(RawFrame),
  reply: process.Subject(RawReply),
  ref: reference.Reference,
  ordinal: Int,
) {
  case transfer.next(sender) {
    None -> Nil
    Some(#(bytes, sender)) -> {
      assert distribution.send(incoming, Input(ref, ordinal, bytes))
        == distribution.Sent
      let assert Ok(Consumed(ack, index)) = process.receive(reply, 3000)
        as "actual input chunk acknowledged"
      assert ack == ref && index == ordinal
      raw_input(sender, incoming, reply, ref, ordinal + 1)
    }
  }
}

fn raw_output(
  receiver: transfer.Receiver,
  incoming: process.Subject(RawFrame),
  reply: process.Subject(RawReply),
  ref: reference.Reference,
  ordinal: Int,
) -> BitArray {
  let assert Ok(Returned(answer_ref, index, bytes)) =
    process.receive(reply, 3000)
    as "actual reply chunk"
  assert answer_ref == ref && index == ordinal
  let assert Ok(accepted) = transfer.accept(receiver, bytes)
    as "canonical reply transfer"
  assert distribution.send(incoming, ReplyConsumed(ref, ordinal))
    == distribution.Sent
  case accepted {
    transfer.Complete(bytes) -> bytes
    transfer.Receiving(receiver) ->
      raw_output(receiver, incoming, reply, ref, ordinal + 1)
  }
}

fn control_scope() -> cw.Scope {
  let assert Ok(scope) =
    cw.scope_from_fields(
      "00000000-0000-7000-8000-000000000001",
      "checkout",
      "executor",
      1,
      1,
    )
    as "Full original scope."
  scope
}

fn control_hash(c: String) -> String {
  string.repeat(c, 64)
}

fn control_base() -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    writable_roots: ["/work", "/alloc"],
    readable_roots: ["/tc", "/seed", "/work"],
    protected: ["/work/.git"],
    network: policy.NetworkOff,
    limits: policy.Limits(11, 12, 13, 14, 15, 16),
    env_allow: ["PATH", "HOME"],
    scratch: policy.ScratchTmpfs,
    mounts: [
      policy.Mount("/tc", policy.MountReadOnly, policy.MountRequired),
      policy.Mount("/seed", policy.MountReadOnly, policy.MountOptional),
    ],
  )
}

fn control_enrolled() -> enrollment.SessionEnrollment {
  let assert Ok(enrolled) =
    enrollment.new(
      enrollment.NativeFacts(
        control_scope(),
        ["/"],
        control_base(),
        exec.PlatformEnforcement,
      ),
      enrollment.CodeModeFacts(
        "/work",
        "/alloc/build",
        "/alloc/channel",
        "/tc/bin/gleam",
        "/tc/bin/erl",
        "/seed",
        ["/tc"],
        control_base().mounts,
        "/tc/bin",
      ),
      control_hash("b"),
      control_hash("c"),
    )
    as "Exact isolated trusted enrollment."
  enrolled
}

fn control_id(number: Int) -> ids.EntryId {
  let assert Ok(id) =
    ids.parse_entry_id(
      "00000000-0000-7000-8000-"
      <> string.pad_start(int.to_string(number), 12, "0"),
    )
    as "Original UUID."
  id
}

fn control_parent(
  step: String,
  index: Int,
  digest: String,
  result: Int,
) -> remote_tool.ToolKey {
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-000000000001")
    as "Session UUID."
  let assert Ok(operation) =
    ids.parse_op_id("00000000-0000-7000-8000-000000000002")
    as "Operation UUID."
  let assert Ok(parent) =
    remote_tool.key(session, operation, step, index, digest, control_id(result))
    as "Complete original managed parent."
  parent
}

fn control_key(
  role: command.ServiceRole,
  step: String,
  number: Int,
  parent: remote_tool.ToolKey,
  body: BitArray,
) -> command.ServiceKey {
  let assert Ok(step) = cw.step(step) as "Physical coordinate."
  let digest = string.lowercase(bit_array.base16_encode(j.digest(body)))
  let assert Ok(key) =
    command.service_key(
      parent,
      role,
      control_scope(),
      remote_tool.operation(parent),
      step,
      control_id(number),
      digest,
      control_hash("b"),
      control_hash("c"),
    )
    as "Digest-linked complete service key."
  key
}

fn control_compiled(source: String, number: Int) -> j.Input {
  let assert Ok(decoded) =
    input.compile_input(
      control_enrolled(),
      input.WorkspaceProgram,
      source,
      [],
      compile.default_dependencies(),
      control_base(),
      180_000,
    )
    as "Canonical compile input."
  let body = input.encode_compile(decoded)
  j.Input(
    control_key(
      command.CompileService,
      "physical:build",
      number,
      control_parent("parent", 3, control_hash("a"), 4),
      body,
    ),
    body,
  )
}

fn control_launched(producer: command.ServiceKey, number: Int) -> j.Input {
  let #(scope, operation, step) = command.coordinates(producer)
  let #(digest, _, contract) = command.digests(producer)
  let artifact =
    compile.ExecutorArtifact(
      scope,
      operation,
      step,
      ids.entry_id_to_string(command.request_id(producer)),
      digest,
      "issued-artifact",
      contract,
      compile.entry_module,
      "sha256-" <> control_hash("e"),
    )
  let assert Ok(decoded) =
    input.launch_input(
      control_enrolled(),
      producer,
      artifact,
      [],
      cw.root(),
      control_base(),
      control_hash("d"),
    )
    as "Canonical launch body, without successful artifact proof."
  let body = input.encode_launch(decoded)
  j.Input(
    control_key(
      command.LaunchService,
      "physical:run",
      number,
      command.parent(producer),
      body,
    ),
    body,
  )
}

fn control_digest() -> identity.Digest {
  let assert Ok(digest) = identity.digest(<<9:size(256)>>)
    as "bounded physical-command digest"
  digest
}

// These roles compose the actual finite endpoint with a separately owned stream.
// No prepared service or paused local connection crosses the distribution hop.
/// Drives finite endpoint installation against real original preparation.
///
/// ## Examples
/// `bind_executor_main()` runs in the trusted parent TLS fixture only.
pub fn bind_executor_main() {
  let #(root, provisioned) = inputs()
  let assert Ok(membership) = distribution.start(provisioned.executor_config)
    as "Real executor TLS bootstrap."
  let assert Ok(owner) = distribution.peer(membership, provisioned.owner_name)
    as "Authenticated owner peer."
  await(root, "bind-owner-started")
  assert distribution.connect(owner, 3000) == Ok(Nil)
  preparation.with_prepared(fn(whole, key, paths) {
    let assert Ok(row) =
      endpoint.registration(
        owner,
        launch.native_service(whole),
        None,
        process.self(),
      )
      |> result.try(fn(row) { endpoint.attach_launch(row, whole) })
      as "Same original Launch row."
    let assert Ok(server) =
      endpoint.configure_server([row], 3000)
      |> result.try(endpoint.start)
      as "Six actual finite credit actors."
    let assert Ok(owner_pid) = distribution.endpoint(owner, 3000)
      as "Test-only owner rendezvous."
    assert distribution.send(bind_prepared(owner_pid), BindPrepared(key))
      == distribution.Sent
    await(root, "bind-missing-refused")
    bind_all_credits(server)
    mark(root, "bind-missing-capacity")
    await(root, "bind-duplicate-refused")
    bind_all_credits(server)
    mark(root, "bind-duplicate-capacity")
    await(root, "bind-installed")
    assert endpoint.inspect(server) == Ok(endpoint.Capacity(1, 4, 2))
    assert endpoint.inspect_drain(server, row) == Ok(endpoint.Busy)
    let assert Ok(socket) = bind_connect(paths.1)
      as "Socket acceptance starts after finite credit restoration."
    assert bind_send(socket, <<3:32, 4, 5, 6, 3:32, 10, 11, 12>>) == Ok(Nil)
    let assert Ok(bytes) = bind_receive(socket, 5000)
      as "Original actual Unix writer."
    assert bytes == <<3:32, 7, 8, 9>>
    await(root, "bind-live")
    assert endpoint.inspect(server) == Ok(endpoint.Capacity(1, 4, 2))
    mark(root, "bind-credits-live")
    await(root, "bind-owner-closed")
    bind_close(socket)
    assert endpoint.inspect(server) == Ok(endpoint.Capacity(1, 4, 2))
    assert simplifile.write(
        root <> "/bind-original-before-close",
        launch_snapshot(launch.pid(whole)),
      )
      == Ok(Nil)
    endpoint.stop(server)
  })
  mark(root, "bind-first-closed")

  // A lost ACK after a known Installed answer retires only transport custody.
  preparation.with_prepared(fn(whole, key, _paths) {
    let assert Ok(row) =
      endpoint.registration(
        owner,
        launch.native_service(whole),
        None,
        process.self(),
      )
      |> result.try(fn(row) { endpoint.attach_launch(row, whole) })
      as "Original known-install row."
    let assert Ok(server) =
      endpoint.configure_server([row], 1000)
      |> result.try(endpoint.start)
      as "Finite lost-ACK endpoint."
    let assert Ok(owner_pid) = distribution.endpoint(owner, 3000)
      as "Original test rendezvous."
    assert distribution.send(bind_prepared(owner_pid), BindPrepared(key))
      == distribution.Sent
    await(root, "bind-ack-withheld")
    bind_all_credits(server)
    mark(root, "bind-ack-retired")
    await(root, "bind-ack-duplicate")
    bind_all_credits(server)
    mark(root, "bind-ack-duplicate-capacity")
    await(root, "bind-ack-closed")
    assert simplifile.write(
        root <> "/bind-lost-ack-before-close",
        launch_snapshot(launch.pid(whole)),
      )
      == Ok(Nil)
    endpoint.stop(server)
  })
  mark(root, "bind-ack-fixture-closed")

  // A second real original entry holds installation itself, rather than a socket.
  preparation.with_prepared(fn(whole, key, _paths) {
    let assert Ok(row) =
      endpoint.registration(
        owner,
        launch.native_service(whole),
        None,
        process.self(),
      )
      |> result.try(fn(row) { endpoint.attach_launch(row, whole) })
      as "Second original Launch row."
    let assert Ok(server) =
      endpoint.configure_server([row], 3000)
      |> result.try(endpoint.start)
      as "Fresh bounded finite endpoint."
    suspend(launch.pid(whole))
    let assert Ok(owner_pid) = distribution.endpoint(owner, 3000)
      as "Original owner test rendezvous."
    assert distribution.send(bind_prepared(owner_pid), BindPrepared(key))
      == distribution.Sent
    await(root, "bind-lost")
    let assert poll.Answered(Nil) =
      poll.until(3000, 10, fn() {
        case endpoint.inspect(server) {
          Ok(endpoint.Capacity(1, 4, 1)) -> poll.Done(Nil)
          _ -> poll.Retry
        }
      })
      as "Lost installation answer retains original control custody."
    assert endpoint.fence(server, row) == Ok(Nil)
    let assert poll.Answered(Nil) =
      poll.until(3000, 10, fn() {
        case endpoint.inspect_drain(server, row) {
          Ok(endpoint.DrainUncertain) -> poll.Done(Nil)
          _ -> poll.Retry
        }
      })
      as "Actual uncertain installation retires the original credit without refund."
    resume(launch.pid(whole))
    mark(root, "bind-lost-retained")
    await(root, "bind-second-closed")
    assert simplifile.write(
        root <> "/bind-held-install-before-close",
        launch_snapshot(launch.pid(whole)),
      )
      == Ok(Nil)
    endpoint.stop(server)
  })
  mark(root, "bind-executor-success")
}

/// Proves finite binding and original stream consumption on the owner node.
///
/// ## Examples
/// `bind_owner_main()` runs in the trusted parent TLS fixture only.
pub fn bind_owner_main() {
  let #(root, provisioned) = inputs()
  let assert Ok(membership) = distribution.start(provisioned.owner_config)
    as "Real owner TLS bootstrap."
  let assert Ok(executor) =
    distribution.peer(membership, provisioned.executor_name)
    as "Authenticated executor peer."
  assert distribution.register_endpoint(process.self()) == Ok(Nil)
  mark(root, "bind-owner-started")
  let assert Ok(BindPrepared(key)) =
    process.receive(bind_prepared(process.self()), 35_000)
    as "Real prepared original key."
  let pin = bind_pin(key)
  let config =
    endpoint.Config(
      executor,
      pin.owner,
      pin.executor,
      pin.scope,
      pin.generation,
      1000,
    )
  let events = process.new_subject()
  let assert Ok(owner) =
    bridge.start_owner(
      executor,
      pin,
      key,
      channel.host_endpoint(process.self(), events),
      poll.monotonic().now() + 20_000,
      poll.monotonic().now,
    )
    as "Original local host projection."

  // Registration checks reject altered peer labels and generation before admission.
  assert endpoint.bind_launch(
      endpoint.Config(..config, owner: "other"),
      bridge.offer(owner),
    )
    == Error(endpoint.Uncertain)
  assert endpoint.bind_launch(
      endpoint.Config(..config, generation: 2),
      bridge.offer(owner),
    )
    == Error(endpoint.Uncertain)
  let #(session, workspace, executor_id, _epoch, workspace_epoch) =
    identity.scope_fields(pin.scope)
  let assert Ok(session) = ids.parse_session_id(session) as "Original session. "
  let assert Ok(workspace) = identity.workspace_id(workspace)
    as "Original workspace. "
  let assert Ok(executor_id) = identity.executor_id(executor_id)
    as "Original executor. "
  let assert Ok(workspace_epoch) = identity.epoch(workspace_epoch)
    as "Original workspace epoch. "
  let assert Ok(epoch) = identity.epoch(3) as "Different valid scope epoch."
  let wrong_scope =
    identity.scope(session, workspace, executor_id, epoch, workspace_epoch)
  assert endpoint.bind_launch(
      endpoint.Config(..config, scope: wrong_scope),
      bridge.offer(owner),
    )
    == Error(endpoint.Uncertain)

  // A different original key is canonical but owns no prepared listener.
  let #(scope, operation, step) = command.coordinates(key)
  let #(input_digest, registration_digest, contract_digest) =
    command.digests(key)
  let assert Ok(request) =
    ids.parse_entry_id("00000000-0000-7000-8000-00000000000f")
    as "Distinct original request."
  let assert Ok(missing) =
    command.service_key(
      command.parent(key),
      command.LaunchService,
      scope,
      operation,
      step,
      request,
      input_digest,
      registration_digest,
      contract_digest,
    )
    as "Full different canonical original key."
  let assert Ok(unprepared) =
    bridge.start_owner(
      executor,
      pin,
      missing,
      channel.host_endpoint(process.self(), events),
      poll.monotonic().now() + 20_000,
      poll.monotonic().now,
    )
    as "Original unprepared host projection."
  assert endpoint.bind_launch(config, bridge.offer(unprepared))
    == Error(endpoint.Uncertain)
  mark(root, "bind-missing-refused")
  await(root, "bind-missing-capacity")
  let _closed = bridge.close(unprepared)

  let assert Ok(accepted) = endpoint.bind_launch(config, bridge.offer(owner))
    as "Finite binding returns before Unix accept."
  let #(bytes, executor_door) = bridge.acceptance_fields(accepted)
  let assert Ok(foreign) =
    bridge.offer_from_wire(executor, bytes, executor_door)
    as "Real executor-owned door used in an owner offer."
  assert endpoint.bind_launch(config, foreign) == Error(endpoint.Uncertain)
  assert bridge.install(owner, accepted) == Ok(Nil)
  assert endpoint.bind_launch(config, bridge.offer(owner))
    == Error(endpoint.Uncertain)
  mark(root, "bind-duplicate-refused")
  await(root, "bind-duplicate-capacity")
  assert bridge.await_connection(owner, 1) == Error(bridge.Uncertain)
  mark(root, "bind-installed")
  let assert Ok(connection) = bridge.await_connection(owner, 3000)
    as "Actual paused original handoff."
  assert process.receive(events, 0) == Error(Nil)
  assert connection.activate() == Ok(Nil)
  let assert Ok(channel.Frame(frame)) = process.receive(events, 3000)
    as "Actual original host frame."
  assert channel.payload(channel.delivered(frame).1) == <<4, 5, 6>>
  assert process.receive(events, 0) == Error(Nil)
  let assert Ok(payload) = channel.from_wire(<<3:32, 7, 8, 9>>)
    as "Closed actual write payload."
  let assert Ok(#(held, reservation)) =
    channel.reserve_write(connection.initial_write_grant, payload)
    as "Original actual writer grant."
  assert connection.offer(reservation, payload) == Ok(Nil)
  let assert Ok(channel.WriteConsumed(written)) = process.receive(events, 3000)
    as "Actual Unix writer consumption."
  assert channel.consume_write(held, written).1 == channel.Consumed
  mark(root, "bind-live")
  await(root, "bind-credits-live")
  channel.consume(frame, channel.Final)
  bridge.cancel(owner)
  let closed = connection.close()
  assert closed.transport == channel.TransportJoined
  assert closed.resources != channel.ResourcesReleased
  mark(root, "bind-owner-closed")
  await(root, "bind-first-closed")
  let assert Ok(BindPrepared(lost_ack)) =
    process.receive(bind_prepared(process.self()), 35_000)
    as "Known installation with deliberately withheld acceptance ACK."
  let lost_pin = bind_pin(lost_ack)
  let events = process.new_subject()
  let assert Ok(retained) =
    bridge.start_owner(
      executor,
      lost_pin,
      lost_ack,
      channel.host_endpoint(process.self(), events),
      poll.monotonic().now() + 20_000,
      poll.monotonic().now,
    )
    as "Original host retained without retry."
  bind_without_ack(executor, lost_pin, bridge.offer(retained))
  mark(root, "bind-ack-withheld")
  await(root, "bind-ack-retired")
  assert endpoint.bind_launch(config, bridge.offer(retained))
    == Error(endpoint.Uncertain)
  mark(root, "bind-ack-duplicate")
  await(root, "bind-ack-duplicate-capacity")
  let _closed = bridge.close(retained)
  mark(root, "bind-ack-closed")
  await(root, "bind-ack-fixture-closed")
  let assert Ok(BindPrepared(second)) =
    process.receive(bind_prepared(process.self()), 35_000)
    as "Second real original entry."
  let pin = bind_pin(second)
  let events = process.new_subject()
  let assert Ok(owner) =
    bridge.start_owner(
      executor,
      pin,
      second,
      channel.host_endpoint(process.self(), events),
      poll.monotonic().now() + 20_000,
      poll.monotonic().now,
    )
    as "Held-install original host."
  assert endpoint.bind_launch(
      endpoint.Config(..config, within_ms: 50),
      bridge.offer(owner),
    )
    == Error(endpoint.Uncertain)
  mark(root, "bind-lost")
  await(root, "bind-lost-retained")
  let _closed = bridge.close(owner)
  mark(root, "bind-second-closed")
  await(root, "bind-executor-success")
  mark(root, "bind-owner-success")
}

fn bind_prepared(pid: process.Pid) -> process.Subject(BindPrepared) {
  process.unsafely_create_subject(
    pid,
    dynamic.string("loom.executor.endpoint/1"),
  )
}

fn bind_pin(key: command.ServiceKey) -> protocol.Binding {
  let #(scope, _, _) = command.coordinates(key)
  let #(session, registered) = cw.scope_fields(scope)
  let #(selected, second, first) = cw.binding_fields(registered)
  let #(executor, workspace) = cw.selector_fields(selected)
  let assert Ok(workspace) = identity.workspace_id(workspace)
    as "Original workspace."
  let assert Ok(executor) = identity.executor_id(executor)
    as "Original executor."
  let assert Ok(first) = identity.epoch(first) as "Original session epoch."
  let assert Ok(second) = identity.epoch(second) as "Original workspace epoch."
  protocol.Binding(
    "owner",
    "linux",
    1,
    identity.scope(session, workspace, executor, first, second),
  )
}

fn bind_all_credits(server: endpoint.Server) {
  let assert poll.Answered(Nil) =
    poll.until(3000, 10, fn() {
      case endpoint.inspect(server) {
        Ok(endpoint.Capacity(1, 4, 2)) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "Definite invalid installation restores all original finite credits."
}

fn bind_without_ack(
  peer: distribution.Peer,
  pin: protocol.Binding,
  offered: bridge.Offer,
) {
  let assert Ok(endpoint) = distribution.endpoint(peer, 1000)
    as "Actual finite endpoint."
  let assert Ok(header) = protocol.header(pin, protocol.LaunchBind)
    as "Canonical route five."
  let reservation =
    process.unsafely_create_subject(
      endpoint,
      dynamic.string("loom.executor.endpoint/1"),
    )
  let reply = process.new_subject()
  let correlation = reference.new()
  assert distribution.send(
      reservation,
      Reservation(header, correlation, process.self(), reply),
    )
    == distribution.Sent
  let assert Ok(Granted(actual, incoming)) = process.receive(reply, 1000)
    as "Actual checked control grant."
  assert actual == correlation
  let #(bytes, door) = bridge.offer_fields(offered)
  assert distribution.send(incoming, BindInput(correlation, bytes, door))
    == distribution.Sent
  let assert Ok(BindReturned(actual, returned, door)) =
    process.receive(reply, 1000)
    as "Actual Installed answer before withholding ACK."
  assert actual == correlation
  assert returned == bytes
  assert bridge.acceptance_from_wire(peer, returned, door) |> result.is_ok
}
