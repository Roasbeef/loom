//// Real owner receipt, authenticated chunks and executor-local filesystem proof.
////
//// The runner loses an actual queued Submit caller through its finite deadline.
//// A post-write observer holds the effect before result persistence so retries
//// must report Unknown without writing again. The owner then retains the exact
//// completion before ACK and reopens its SQLite custody to recover it.
////
//// Two independent TLS BEAM OS roles own distinct owner and workspace paths.
//// It is not the shipped two-host product gate, and it makes no provider call.
//// `finish` closes the local owner after its assertions, then awaits the fixed
//// executor's independent semantic seal and native retirement. The fixture
//// parent independently checks both actual OS exits before reporting success.

import broker/exec
import broker/executor as native
import broker/policy
import client/remote/custodian
import client/remote/workspace_binding as binding
import core/clock
import core/ids
import core/remote_tool
import core/workspace as cw
import distribution_fixture
import executor/remote/admission
import executor/remote/beam_endpoint as connection
import executor/remote/distribution
import executor/remote/identity
import executor/remote/internal/beam_protocol as transport
import executor/remote/journal as native_journal
import executor/remote/service as native_service
import executor/remote/wire
import executor/remote/workspace_journal as journal
import executor/remote/workspace_service as service
import gleam/bit_array
import gleam/erlang/process
import gleam/io
import gleam/option.{None, Some}
import gleam/otp/system
import gleam/string
import host/bootstrap
import internal/ffi_workspace_mailbox as mailbox
import simplifile
import storage/owner_custody as custody
import support/workspace_e2e_beam_fixture as nodes
import telemetry/log
import tools/directory_access
import tools/fs
import tools/tool
import tools/workspace
import tools/workspace_codec as codec
import tools/workspace_local as local
import weft
import weft/poll
import weft/registry

type Fixture {
  FixtureState(
    root: String,
    owner: custodian.Handle,
    owner_config: custodian.Config,
    owner_pid: process.Pid,
    connection: connection.Config,
  )
}

/// Runs a joined semantic effect and durable owner receipt under real TLS.
///
/// ## Examples
///
/// `bash scripts/e2e_remote_workspace.sh` runs this isolated component fixture.
pub fn main() {
  use peer <- nodes.run
  let f = fixture(peer)
  let request =
    workspace.Write(path("proof.txt"), string.repeat("seed\n", 100_000))
  let b = binding.new(scope(), f.owner, fn() { entry(11) })
  let assert Ok(reservation) = reserve(b, child(0), request)
    as "Owner custody must reserve exact bytes before possible submission."
  let bytes = binding.content(reservation)
  let assert True = bit_array.byte_size(bytes) > 262_144
    as "The joined request must actually exceed the original 256-KiB threshold and span BEAM chunks."

  // The actual Submit is queued before its caller expires. Resuming the service
  // still takes the original claim; recovery cannot grant another execution.
  drop_submit_reply(f, bytes)
  nodes.await(f.root, "written")
  let assert Ok(text) = simplifile.read(f.root <> "/executor/proof.txt")
    as "Only the executor directory contains the physical mutation."
  assert text == string.repeat("seed\n", 100_000)
  assert simplifile.is_file(f.root <> "/owner/proof.txt") == Ok(False)
  assert connection.workspace_exchange(f.connection, transport.Query, bytes)
    == Ok(journal.Unknown)

  // A second write would overwrite this independent editor change. A byte-for-
  // byte retry must keep the original claim and leave the newer file alone.
  assert simplifile.write(f.root <> "/executor/proof.txt", "external change\n")
    == Ok(Nil)
  assert connection.workspace_exchange(f.connection, transport.Submit, bytes)
    == Ok(journal.Unknown)
  nodes.mark(f.root, "release-write")
  let result = completed(f.connection, bytes)
  let assert Ok(Ok(local.Completed(workspace.WriteCompleted(Ok(_)), None))) =
    codec.decode_completion(request, result)
    as "The exact original successful write result must survive the lost reply."
  assert simplifile.read(f.root <> "/executor/proof.txt")
    == Ok("external change\n")

  let digest = persist_before_ack(f.owner, reservation, result)
  assert connection.workspace_exchange(
      f.connection,
      transport.Acknowledge(digest),
      bytes,
    )
    == Ok(journal.Acknowledged(identity.digest_bytes(digest)))
  assert connection.workspace_exchange(f.connection, transport.Submit, bytes)
    == Ok(journal.Acknowledged(identity.digest_bytes(digest)))
  assert simplifile.read(f.root <> "/executor/proof.txt")
    == Ok("external change\n")

  // Reopening owner custody cannot run the parent tool or invent a fresh child.
  stop_owner(f)
  let assert Ok(restarted) = custodian.start(f.owner, f.owner_config)
    as "Original owner metadata reopens without tool execution."
  let f = FixtureState(..f, owner_pid: restarted.pid)
  let recovered_binding = binding.new(scope(), f.owner, fn() { entry(999) })
  let assert Ok(#(recovered, Some(retained))) =
    binding.recover(recovered_binding, child(0))
    as "The durable owner receipt survives callback and custodian lifetime."
  assert retained == result
  assert binding.content(recovered) == bytes
  let assert Ok(retry) = reserve(recovered_binding, child(0), request)
    as "Exact retry uses the original reserved UUID after reopen."
  assert binding.content(retry) == bytes

  // A full text read crosses the same wire in the opposite large direction.
  let large = string.repeat("read\n", 100_000)
  assert simplifile.write(f.root <> "/executor/large.txt", large) == Ok(Nil)
  let read_request = workspace.Read(path("large.txt"), workspace.Text)
  let read_binding = binding.new(scope(), f.owner, fn() { entry(12) })
  let assert Ok(read) = reserve(read_binding, child(1), read_request)
    as "Read also keeps its own original child identity."
  let read_bytes = binding.content(read)
  let assert Ok(_) =
    connection.workspace_exchange(f.connection, transport.Submit, read_bytes)
    as "Authenticated read submission must be accepted."
  let read_result = completed(f.connection, read_bytes)
  let assert True = bit_array.byte_size(read_result) > 262_144
    as "The joined completion must actually exceed the original 256-KiB threshold and span BEAM chunks."
  assert codec.decode_completion(read_request, read_result)
    == Ok(
      Ok(local.Completed(
        workspace.ReadCompleted(Ok(workspace.TextRead(large))),
        None,
      )),
    )
  let read_digest = persist_before_ack(f.owner, read, read_result)
  assert connection.workspace_exchange(
      f.connection,
      transport.Acknowledge(read_digest),
      read_bytes,
    )
    == Ok(journal.Acknowledged(identity.digest_bytes(read_digest)))

  wrong_scope(f)
  finish(f)
  io.println(
    "remote-workspace: joined custody/TLS/filesystem/receipt proof passed",
  )
}

fn persist_before_ack(
  owner: custodian.Handle,
  reservation: binding.Reservation,
  result: BitArray,
) -> identity.Digest {
  let digest = case bootstrap.getenv("LOOM_REMOTE_WORKSPACE_MUTATION") {
    Ok("skip-owner-receipt") -> journal.digest(result)
    _ -> {
      let assert Ok(ack) = binding.receive(reservation, result)
        as "Only a durable owner commit can produce this acknowledgement."
      binding.acknowledgement(ack).1
    }
  }
  let call = binding.invocation(reservation)
  let id = workspace.invocation_identity(call).4
  let origin = case workspace.request(call) {
    workspace.Write(_, _) -> child(0)
    workspace.Read(_, _) -> child(1)
    _ -> panic as "Fixture only receives its two exact request kinds."
  }
  let assert Ok(stored) = custodian.child(owner, origin)
    as "Actual SQLite must contain the receipt before sending ACK."
  assert stored.0 == id
  assert stored.2 == Some(result)
  let assert Ok(digest) = identity.digest(digest)
    as "Receipt digest has fixed width."
  digest
}

fn completed(client: connection.Config, bytes: BitArray) -> BitArray {
  let answer =
    poll.until(5000, 10, fn() {
      case connection.workspace_exchange(client, transport.Query, bytes) {
        Ok(journal.Finished(result)) -> poll.Done(result)
        Ok(journal.Accepted) | Ok(journal.Unknown) -> poll.Retry
        other -> poll.Fail(other)
      }
    })
  let assert poll.Answered(bytes) = answer
    as "Supervised effect must publish exact durable completion within the fixture budget."
  bytes
}

fn drop_submit_reply(f: Fixture, bytes: BitArray) {
  assert simplifile.write_bits(f.root <> "/original-submit.bytes", bytes)
    == Ok(Nil)
  nodes.mark(f.root, "original-submit-ready")
  let endpoint = connection.Config(..f.connection, within_ms: 3000)
  let reports = process.new_subject()
  let _ =
    weft.new([
      fn() { connection.workspace_exchange(endpoint, transport.Submit, bytes) },
    ])
    |> weft.deadline(6000)
    |> weft.start_relayed(to: reports)
  nodes.await(f.root, "submit-queued")

  // The endpoint's own deadline cancels and joins its real exchange caller.
  // The service is still suspended, so this cannot be its Unknown response.
  assert process.receive(reports, 5000)
    == Ok(weft.PulledOutcome(weft.Failed(0, connection.Uncertain)))
  assert process.receive(reports, 2000) == Ok(weft.AllDelivered)
  nodes.mark(f.root, "caller-lost")
  nodes.await(f.root, "ask-retained")
}

fn wrong_scope(f: Fixture) {
  let changed = identity_scope(2)
  let client = connection.Config(..f.connection, scope: changed)
  let assert Ok(bound) =
    cw.scope_from_fields(
      ids.session_id_to_string(session()),
      "checkout",
      "executor",
      2,
      1,
    )
    as "Changed authority epoch remains a valid value."
  let call =
    workspace.invocation(
      bound,
      operation(),
      step(),
      tool_origin(),
      entry(99),
      workspace.Write(path("forbidden.txt"), "bad"),
    )
  let assert Ok(bytes) = codec.encode_invocation(call)
    as "Wrong authority has well-formed content."
  assert connection.workspace_exchange(client, transport.Submit, bytes)
    == Error(connection.Uncertain)
  assert simplifile.is_file(f.root <> "/executor/forbidden.txt") == Ok(False)
}

fn fixture(peer: distribution.Peer) -> Fixture {
  let root = nodes.root() <> "/data"
  assert simplifile.create_directory_all(root <> "/owner") == Ok(Nil)
  assert simplifile.create_directory_all(root <> "/executor") == Ok(Nil)

  let assert Ok(limits) =
    custody.limits(4, 16, 268_435_456, codec.max_completion_bytes)
    as "Owner reserves complete workspace results within finite aggregate capacity."
  let owner_path = root <> "/owner/custody.db"
  let assert Ok(store) = custody.open(owner_path, session(), limits)
    as "Owner SQLite opens."
  let assert Ok(parent) = custody.payload(limits, <<"parent">>)
    as "Parent material is bounded."
  assert custody.admit(store, key(), parent, parent) == Ok(Nil)
  assert custody.close(store) == Ok(Nil)

  // The parent commit precedes the owner-local custodian's child receipt door.
  let assert Ok(names) = registry.start() as "Fixture owns a registry."
  let assert Ok(owner_config) =
    custodian.config(owner_path, session(), limits, 1, 5000, fn(_, _, _) {
      panic as "Child recovery must never execute the parent tool."
    })
    as "Owner lifetime is finite."
  let owner = custodian.new(names, owner_config)
  let assert Ok(owner_started) = custodian.start(owner, owner_config)
    as "Owner custodian starts."
  let connection =
    connection.Config(peer, "owner", "executor", identity_scope(1), 1, 5000)
  nodes.await(root, "executor-ready")
  FixtureState(root, owner, owner_config, owner_started.pid, connection)
}

/// Starts the fixed independent executor with actual semantic and native actors.
///
/// ## Examples
/// Only the workspace component fixture invokes `executor_main()`.
pub fn executor_main() -> Nil {
  let runtime_root = nodes.root()
  let root = runtime_root <> "/data"
  assert simplifile.create_directory_all(root <> "/executor") == Ok(Nil)
  let assert Ok(provisioned) =
    distribution_fixture.read_provisioned(runtime_root <> "/fixture.term")
    as "The executor reads its original private bootstrap configuration."
  let assert Ok(membership) = distribution.start(provisioned.executor_config)
    as "The independent executor boots real authenticated TLS distribution."
  let assert Ok(owner) = distribution.peer(membership, provisioned.owner_name)
    as "Only the original authenticated owner can enter this endpoint."

  // Filesystem effect and SQLite custody stay in the executor VM. The fixed
  // observer holds the real write before its result can be persisted.
  let assert Ok(limits) = journal.limits(4, 268_435_456)
    as "Executor reservation is bounded."
  let assert Ok(book) =
    journal.fresh(root <> "/executor/custody.db", scope(), limits)
    as "Executor SQLite opens."
  let local =
    local_host(scope(), context(root <> "/executor"), fn(_) {
      nodes.mark(root, "written")
      nodes.await(root, "release-write")
      None
    })
  let assert Ok(config) = service.configure(local, book, 2, 10_000)
    as "Service binds exact host and journal scope."
  let assert Ok(semantic) = service.start(config)
    as "Effect custody is independent from connection custody."

  // Semantic enrollment shares the existing fixed native service boundary.
  // No native command is allocated by this filesystem-only component fixture.
  let #(native_executor, native_remote, native_book) = concrete_native(root)
  let assert Ok(row) =
    connection.registration(owner, native_remote, Some(semantic))
    as "Enrollment derives exact scope from concrete executor-local services."
  let assert Ok(config) = connection.configure_server([row], 10_000)
    as "The single scope shares four data and two control credits."
  let assert Ok(endpoint) = connection.start(config)
    as "The fixed production endpoint publishes after TLS admission."

  // Suspend only this concrete local semantic actor through its OTP interface.
  // The owner begins a real exchange after the endpoint is ready for admission.
  system.suspend(service.pid(semantic))
  nodes.mark(root, "executor-ready")
  nodes.await(root, "original-submit-ready")
  let assert Ok(original) =
    simplifile.read_bits(root <> "/original-submit.bytes")
    as "The test witness contains the original canonical invocation bytes."
  let assert Ok(invocation) = codec.decode_invocation(original)
    as "Original child identity comes from the production total invocation codec."
  let original_id = workspace.invocation_identity(invocation).4

  // Exact content and original UUID identify the queued operation. Capacity
  // alone cannot distinguish this Submit from any other occupying request.
  let assert poll.Answered(queued) =
    poll.until(2500, 5, fn() {
      case mailbox.queued(service.pid(semantic), original, original_id) {
        Ok(queued) -> poll.Done(queued)
        Error(Nil) -> poll.Retry
      }
    })
    as "Exactly one actual Submit carries the original bytes and child identity."
  assert connection.inspect(endpoint) == Ok(connection.Capacity(1, 3, 2))
  nodes.mark(root, "submit-queued")
  nodes.await(root, "caller-lost")

  // Neither the original ask nor its assigned credit can disappear on loss.
  // The full original message, including its stable reply subject, stays exact.
  assert mailbox.queued(service.pid(semantic), original, original_id)
    == Ok(queued)
  assert connection.inspect(endpoint) == Ok(connection.Capacity(1, 3, 2))
  nodes.mark(root, "ask-retained")
  system.resume(service.pid(semantic))
  nodes.await(root, "owner-done")

  // Native retirement and semantic closure remain separate from endpoint death.
  // This fixed fixture never exercises proposal-dependent production assembly.
  connection.quiesce(endpoint)
  assert service.close(semantic) == Ok(Nil)
  assert journal.mode(book) == Ok(journal.SealedScope)
  assert journal.release(book) == Ok(Nil)
  let down = process.monitor(connection.pid(endpoint))
  connection.stop(endpoint)
  let assert Ok(process.ProcessDown(_, _, process.Normal)) =
    process.new_selector()
    |> process.select_specific_monitor(down, fn(down) { down })
    |> process.selector_receive(2000)
    as "The exact endpoint actor exits normally; this is transport evidence."

  // ScopeRetirement owns native shutdown once. Its concrete actor must join
  // before native journal release; endpoint death alone grants neither fact.
  let native_down = process.monitor(native.pid(native_executor))
  assert native_service.exchange(
      native_remote,
      wire.Envelope(
        wire.Owner,
        "owner",
        "executor",
        1,
        identity_scope(1),
        wire.CloseScope,
      ),
    )
    == Ok(wire.ScopeRetirement)
  let assert Ok(process.ProcessDown(_, _, process.Normal)) =
    process.new_selector()
    |> process.select_specific_monitor(native_down, fn(down) { down })
    |> process.selector_receive(2000)
    as "The original native actor actually exits after its one retirement action."
  assert native_journal.release(native_book) == Ok(Nil)
  nodes.mark(runtime_root, "executor-success")
}

fn concrete_native(root: String) {
  let assert Ok(executor) =
    native.start(native.ExecutorConfig(
      fn() { Error(exec.PoolUnavailable) },
      fn(_) { Nil },
      fn() { Error(exec.PoolUnavailable) },
      fn(_) { Ok(Nil) },
      4,
      log.discard(),
    ))
    as "The actual native actor allocates no process pool in this semantic fixture."
  let assert Ok(capacity) = admission.capacity(4)
    as "Native enrollment retains its finite admission limit."
  let assert Ok(book) =
    native_journal.fresh(root <> "/native.sqlite", identity_scope(1), capacity)
    as "Native enrollment has its own actual scoped journal."
  let assert Ok(remote) =
    native_service.start(native_service.Config(
      "owner",
      "executor",
      identity_scope(1),
      1,
      book,
      executor,
      fn(_, _) { Ok(Nil) },
      poll.monotonic().now,
    ))
    as "The existing native service binds this concrete local scope."
  #(executor, remote, book)
}

fn context(root: String) -> tool.Ctx {
  tool.Ctx(
    workspace: tool.LocalWorkspace(root, fs.real_filesystem()),
    strand: "main",
    op_id: operation(),
    step_id: "workspace",
    source_index: 0,
    base_policy: policy.workspace_default(root),
    directory_access: directory_access.none(),
    grants: [],
    demand: exec.FullEnforcement,
    env: [],
    clock: clock.fixed(1000),
    owner_blobs: tool.OwnerBlobs(root <> "/.blobs", fs.real_filesystem()),
    clear_call: fn(_, _) {
      panic as "File-only fixture must not launch a process."
    },
    raise_refusal: tool.no_raise(),
    observe_output: tool.ignore_output(),
  )
}

fn reserve(
  b: binding.Binding,
  child: remote_tool.ChildOrigin,
  request: workspace.Request,
) {
  binding.reserve(b, child, operation(), step(), tool_origin(), request)
}

fn session() {
  ids.mint_session(ids.generator(clock.fixed(1000), 1)).0
}

fn operation() {
  ids.mint_op(ids.generator(clock.fixed(1000), 2)).0
}

fn entry(seed: Int) {
  ids.mint_entry(ids.generator(clock.fixed(1000), seed)).0
}

fn step() {
  let assert Ok(value) = cw.step("workspace") as "Fixture step validates."
  value
}

fn key() {
  let assert Ok(value) =
    remote_tool.key(
      session(),
      operation(),
      "workspace",
      0,
      string.repeat("a", 64),
      entry(3),
    )
    as "Complete parent key validates."
  value
}

fn child(ordinal: Int) {
  let assert Ok(value) =
    remote_tool.tool_child(key(), remote_tool.Workspace(ordinal))
    as "Workspace child cannot alias native launch or capability calls."
  value
}

fn tool_origin() {
  let assert Ok(digest) = bit_array.base16_decode(string.repeat("aa", 32))
    as "Source digest is exact."
  let assert Ok(origin) = workspace.tool_origin(0, digest)
    as "Original source index validates."
  workspace.Tool(origin)
}

fn path(text: String) {
  let assert Ok(value) = cw.relative_path(text) as "Fixture path is relative."
  value
}

fn scope() {
  let assert Ok(value) =
    cw.scope_from_fields(
      ids.session_id_to_string(session()),
      "checkout",
      "executor",
      1,
      1,
    )
    as "Complete scope validates."
  value
}

fn identity_scope(epoch: Int) {
  let assert Ok(w) = identity.workspace_id("checkout")
    as "Workspace label validates."
  let assert Ok(e) = identity.executor_id("executor")
    as "Executor label validates."
  let assert Ok(owner_epoch) = identity.epoch(epoch) as "Owner epoch validates."
  let assert Ok(workspace_epoch) = identity.epoch(1)
    as "Workspace epoch validates."
  identity.scope(session(), w, e, owner_epoch, workspace_epoch)
}

fn stop_owner(f: Fixture) {
  let monitor = process.monitor(f.owner_pid)
  assert custodian.stop(f.owner) == Ok(Nil)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(2000)
    as "SQLite owner exits before reopen."
  Nil
}

fn finish(f: Fixture) {
  stop_owner(f)
  nodes.mark(f.root, "owner-done")
  nodes.await(nodes.root(), "executor-success")
}

// A registered context cannot construct the executor-local host.
fn local_host(
  scope: cw.Scope,
  ctx: tool.Ctx,
  observer: fn(String) -> option.Option(String),
) -> local.Host {
  let assert Ok(host) = local.new(scope, ctx, observer)
    as "fixture must have local authority"
  host
}
