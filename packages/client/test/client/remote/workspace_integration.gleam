//// Real owner receipt, authenticated chunks and executor-local filesystem proof.
////
//// The runner deliberately drops a submit connection after sending its bytes.
//// A post-write observer holds the effect before result persistence so retries
//// must report Unknown without writing again. The owner then retains the exact
//// completion before ACK and reopens its SQLite custody to recover it.
////
//// This fixture runs in one emulator with distinct owner and workspace paths.
//// It is not the shipped two-host product gate, and it makes no provider call.

import broker/exec
import broker/policy
import client/remote/custodian
import client/remote/workspace_binding as binding
import core/clock
import core/ids
import core/remote_tool
import core/workspace as cw
import executor/remote/connection
import executor/remote/identity
import executor/remote/listener
import executor/remote/tls
import executor/remote/wire
import executor/remote/workspace_connection as transport
import executor/remote/workspace_journal as journal
import executor/remote/workspace_service as service
import executor/remote/workspace_transfer as transfer
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/option.{None, Some}
import gleam/otp/static_supervisor as supervisor
import gleam/string
import gleam/time/timestamp
import host/bootstrap
import simplifile
import storage/owner_custody as custody
import tools/directory_access
import tools/fs
import tools/tool
import tools/workspace
import tools/workspace_codec as codec
import tools/workspace_local as local
import weft/poll
import weft/registry

type Credentials {
  Credentials(ca: BitArray, certificate: BitArray, key: BitArray, pin: BitArray)
}

type Certificates {
  Fixture(
    server: Credentials,
    client: Credentials,
    wrong_server: Credentials,
    wrong_client: Credentials,
    foreign: Credentials,
    expired: Credentials,
  )
}

// Credential generation is test-only and reuses the existing OTP PKIX fixture.
@external(erlang, "executor_remote_tls_test_ffi", "fixture")
fn certificates() -> Certificates

type Fixture {
  FixtureState(
    root: String,
    owner: custodian.Handle,
    owner_config: custodian.Config,
    owner_pid: process.Pid,
    book: journal.Journal,
    service: service.Service,
    connection: connection.Config,
    client: transport.Client,
    listener: tls.Listener,
    acceptors: process.Pid,
    observed: process.Subject(process.Subject(Nil)),
  )
}

type Shutdown {
  Shutdown
}

/// Runs a joined semantic effect and durable owner receipt under real TLS.
///
/// ## Examples
///
/// `bash scripts/e2e_remote_workspace.sh` runs this isolated component fixture.
pub fn main() {
  let f = fixture()
  let request =
    workspace.Write(path("proof.txt"), string.repeat("seed\n", 100_000))
  let b = binding.new(scope(), f.owner, fn() { entry(11) })
  let assert Ok(reservation) = reserve(b, child(0), request)
    as "Owner custody must reserve exact bytes before possible submission."
  let bytes = binding.content(reservation)
  let assert True = bit_array.byte_size(bytes) > tls.max_frame_bytes
    as "The joined request must actually exercise multiple TLS frames."
  drop_submit_reply(f.connection, bytes)
  let assert Ok(release) = process.receive(f.observed, 5000)
    as "The real write happened despite the caller losing its submit connection."
  let assert Ok(text) = simplifile.read(f.root <> "/executor/proof.txt")
    as "Only the executor directory contains the physical mutation."
  assert text == string.repeat("seed\n", 100_000)
  assert simplifile.is_file(f.root <> "/owner/proof.txt") == Ok(False)
  assert transport.exchange(f.client, transport.Query, bytes)
    == Ok(journal.Unknown)

  // A second write would overwrite this independent editor change. A byte-for-
  // byte retry must keep the original claim and leave the newer file alone.
  assert simplifile.write(f.root <> "/executor/proof.txt", "external change\n")
    == Ok(Nil)
  assert transport.exchange(f.client, transport.Submit, bytes)
    == Ok(journal.Unknown)
  process.send(release, Nil)
  let result = completed(f.client, bytes)
  let assert Ok(Ok(local.Completed(workspace.WriteCompleted(Ok(_)), None))) =
    codec.decode_completion(request, result)
    as "The exact original successful write result must survive the lost reply."
  assert simplifile.read(f.root <> "/executor/proof.txt")
    == Ok("external change\n")

  let digest = persist_before_ack(f.owner, reservation, result)
  assert transport.exchange(f.client, transport.Acknowledge(digest), bytes)
    == Ok(journal.Acknowledged(identity.digest_bytes(digest)))
  assert transport.exchange(f.client, transport.Submit, bytes)
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
  let assert Ok(_) = transport.exchange(f.client, transport.Submit, read_bytes)
    as "Authenticated read submission must be accepted."
  let read_result = completed(f.client, read_bytes)
  let assert True = bit_array.byte_size(read_result) > tls.max_frame_bytes
    as "The joined completion must actually exercise multiple TLS frames."
  assert codec.decode_completion(read_request, read_result)
    == Ok(
      Ok(local.Completed(
        workspace.ReadCompleted(Ok(workspace.TextRead(large))),
        None,
      )),
    )
  let read_digest = persist_before_ack(f.owner, read, read_result)
  assert transport.exchange(
      f.client,
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

fn completed(client: transport.Client, bytes: BitArray) -> BitArray {
  let answer =
    poll.until(5000, 10, fn() {
      case transport.exchange(client, transport.Query, bytes) {
        Ok(journal.Finished(result)) -> poll.Done(result)
        Ok(journal.Accepted) | Ok(journal.Unknown) -> poll.Retry
        other -> poll.Fail(other)
      }
    })
  let assert poll.Answered(bytes) = answer
    as "Supervised effect must publish exact durable completion within the fixture budget."
  bytes
}

fn drop_submit_reply(config: connection.Config, bytes: BitArray) {
  let assert Ok(socket) = tls.connect(config.tls, config.hostname, config.port)
    as "Dropped-reply control still authenticates normally."
  let hello =
    wire.Envelope(
      wire.Owner,
      config.owner,
      config.executor,
      config.generation,
      config.scope,
      wire.Hello,
    )
  let assert Ok(hello) = wire.encode(hello)
    as "Fixture uses production identity encoding."
  assert tls.send(socket, <<"LWS", 1, hello:bits>>) == Ok(Nil)
  let assert Ok(_) = tls.receive(socket) as "Peer completes the scoped hello."
  assert tls.send(socket, <<"LWQ", 1, 0>>) == Ok(Nil)
  assert transfer.send(socket, transfer.Invocation, bytes) == Ok(Nil)
  tls.close(socket)
}

fn wrong_scope(f: Fixture) {
  let changed = identity_scope(2)
  let assert Ok(client) =
    transport.client(connection.Config(..f.connection, scope: changed))
    as "The competing epoch is syntactically valid."
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
  assert transport.exchange(client, transport.Submit, bytes)
    == Error(transport.Uncertain)
  assert simplifile.is_file(f.root <> "/executor/forbidden.txt") == Ok(False)
}

fn fixture() -> Fixture {
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let assert Ok(here) = simplifile.current_directory()
    as "Fixture has a project directory."
  let root =
    here
    <> "/build/remote-workspace-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
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
  let assert Ok(names) = registry.start() as "Fixture owns a registry."
  let assert Ok(owner_config) =
    custodian.config(owner_path, session(), limits, 1, 5000, fn(_, _) {
      panic as "Child recovery must never execute the parent tool."
    })
    as "Owner lifetime is finite."
  let owner = custodian.new(names, owner_config)
  let assert Ok(owner_started) = custodian.start(owner, owner_config)
    as "Owner custodian starts."
  let assert Ok(limits) = journal.limits(4, 268_435_456)
    as "Executor reservation is bounded."
  let assert Ok(book) =
    journal.fresh(root <> "/executor/custody.db", scope(), limits)
    as "Executor SQLite opens."
  let observed = process.new_subject()
  let local =
    local.new(scope(), context(root <> "/executor"), fn(_) {
      let continue = process.new_subject()
      process.send(observed, continue)
      let assert Ok(Nil) = process.receive(continue, 5000)
        as "Fixture releases the actual post-write barrier."
      None
    })
  let assert Ok(config) = service.configure(local, book, 2, 10_000)
    as "Service binds exact host and journal scope."
  let assert Ok(service) = service.start(config)
    as "Effect custody is independent from connection custody."
  let assert Ok(Nil) = tls.start() as "SSL starts."
  let Fixture(server_cert, client_cert, _, _, _, _) = certificates()
  let assert Ok(socket) =
    tls.listen(settings(server_cert, client_cert), tls.Loopback, 0)
    as "Real listener binds."
  let assert Ok(port) = tls.port(socket) as "Ephemeral endpoint is known."
  let assert Ok(server) = transport.server("owner", identity_scope(1), service)
    as "Peer scope matches actual service."
  let assert Ok(config) = listener.configure_workspace(socket, server, 2, 5000)
    as "Acceptor capacity is finite."
  let assert Ok(acceptors) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(listener.supervised(config))
    |> supervisor.start
    as "Production acceptor subtree starts."
  let connection =
    connection.Config(
      settings(client_cert, server_cert),
      "localhost",
      port,
      5000,
      "owner",
      "executor",
      1,
      identity_scope(1),
    )
  let assert Ok(client) = transport.client(connection)
    as "Owner endpoint validates."
  FixtureState(
    root,
    owner,
    owner_config,
    owner_started.pid,
    book,
    service,
    connection,
    client,
    socket,
    acceptors.pid,
    observed,
  )
}

fn context(root: String) -> tool.Ctx {
  tool.Ctx(
    workspace: root,
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
    filesystem: fs.real_filesystem(),
    blob_root: root <> "/.blobs",
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

fn settings(local: Credentials, peer: Credentials) {
  let Credentials(ca, certificate, key, _) = local
  let assert Ok(value) =
    tls.settings(ca, certificate, key, peer.pin, 2000, 2000, 1000)
    as "Existing PKIX fixtures parse."
  value
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
  tls.close_listener(f.listener)
  let monitor = process.monitor(f.acceptors)
  process.unlink(f.acceptors)
  process.send_abnormal_exit(f.acceptors, Shutdown)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(6000)
    as "All bounded network workers stop."
  assert service.close(f.service) == Ok(Nil)
  assert journal.mode(f.book) == Ok(journal.SealedScope)
  assert journal.release(f.book) == Ok(Nil)
  stop_owner(f)
}
