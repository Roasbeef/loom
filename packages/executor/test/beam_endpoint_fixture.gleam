//// Fixed owner and executor entrypoints run on independent authenticated OS VMs.
//// Coordination files are test barriers; canonical workspace effects execute only
//// through the executor's local semantic service. No role runner performs RPC
//// closures or substitutes native history for a fresh whole-service Claim.

import broker/broker
import broker/exec
import broker/executor as local
import broker/policy
import core/clock
import core/ids
import core/workspace as cw
import distribution_fixture as fixture
import envoy
import executor/remote/admission
import executor/remote/beam_endpoint as endpoint
import executor/remote/distribution
import executor/remote/identity
import executor/remote/internal/beam_protocol as protocol
import executor/remote/journal
import executor/remote/service
import executor/remote/wire
import executor/remote/workspace_journal as wj
import executor/remote/workspace_service as ws
import gleam/crypto
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile
import telemetry/log
import tools/directory_access
import tools/fs
import tools/tool
import tools/workspace as w
import tools/workspace_codec as codec
import tools/workspace_local
import weft
import weft/poll

// Existing OTP primitives park the concrete service, never a mocked exchange.
@external(erlang, "erlang", "suspend_process")
fn suspend(pid: process.Pid) -> Nil

@external(erlang, "erlang", "resume_process")
fn resume(pid: process.Pid) -> Nil

// These fixed test probes capture and inject one actual previous local handoff.
// Production exposes neither private subjects nor a state-replacement API.
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
  let assert Ok(row) = endpoint.registration(owner, first, Some(semantic))
    as "concrete scope registration"
  let assert Ok(other) = endpoint.registration(owner, second, None)
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
    let assert Ok(row) = endpoint.registration(owner, concrete, None)
      as "bounded concrete scope"
    assert endpoint.register(server, row) == Ok(Nil)
  })
  let assert Ok(overflow) =
    endpoint.registration(owner, native_service(root, native, 17), None)
    as "seventeenth concrete scope"
  assert endpoint.register(server, overflow)
    == Error(endpoint.InvalidConfiguration)
  assert endpoint.inspect(server) == Ok(endpoint.Capacity(16, 4, 2))
  let original_credits = credits(endpoint.pid(server))
  mark(root, "ready")
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
  await(root, "quiesce")
  endpoint.quiesce(server)
  assert endpoint.inspect(server) == Ok(endpoint.Capacity(16, 4, 2))
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
