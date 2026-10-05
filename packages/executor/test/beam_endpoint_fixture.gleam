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
import executor/remote/workspace_transfer as transfer
import gleam/crypto
import gleam/dynamic
import gleam/erlang/process
import gleam/erlang/reference
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
import weft/actor
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
  let assert Ok(row) =
    endpoint.registration(owner, first, Some(semantic), process.self())
    as "concrete scope registration"
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
}

type RawFrame {
  Input(reference.Reference, Int, BitArray)
  ReplyConsumed(reference.Reference, Int)
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
