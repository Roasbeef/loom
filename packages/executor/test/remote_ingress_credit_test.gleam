//// Real TLS proves service custody survives the socket deadline.
////
//// Suspending the concrete service stops consumption without mocking dispatch.
//// Exact durable admissions, and the native service's monotone generation,
//// expose which requests were queued while the service could not reply. These
//// tests use existing OTP system controls and the existing PKIX fixture only.

import broker/broker
import broker/exec
import broker/executor as native
import broker/policy
import core/clock
import core/ids
import core/workspace as cw
import executor/remote/admission
import executor/remote/connection
import executor/remote/identity
import executor/remote/journal
import executor/remote/listener
import executor/remote/service
import executor/remote/tls
import executor/remote/wire
import executor/remote/workspace_connection as transport
import executor/remote/workspace_journal as book
import executor/remote/workspace_service
import executor/remote/workspace_transfer as transfer
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/otp/supervision
import gleam/otp/system
import gleam/result
import gleam/string
import gleam/time/timestamp
import remote_tls_test
import simplifile
import telemetry/log
import tools/directory_access
import tools/fs
import tools/tool
import tools/workspace
import tools/workspace_codec as codec
import tools/workspace_local
import weft
import weft/poll

type Network {
  Network(socket: tls.Listener, owner: connection.Config)
}

// Stock OTP observation exists only in tests; no production process or message
// representation escapes through a new runtime capability.
type QueueKey {
  MessageQueueLen
}

type LinksKey {
  Links
}

type MonitorsKey {
  MonitoredBy
}

type MessagesKey {
  Messages
}

@external(erlang, "erlang", "process_info")
fn queue_info(pid: process.Pid, key: QueueKey) -> #(QueueKey, Int)

@external(erlang, "erlang", "process_info")
fn links_info(pid: process.Pid, key: LinksKey) -> #(LinksKey, List(process.Pid))

@external(erlang, "erlang", "process_info")
fn watched_info(
  pid: process.Pid,
  key: MonitorsKey,
) -> #(MonitorsKey, List(process.Pid))

@external(erlang, "erlang", "process_info")
fn messages_info(
  pid: process.Pid,
  key: MessagesKey,
) -> #(MessagesKey, List(Dynamic))

@external(erlang, "supervisor", "which_children")
fn children_info(
  pid: process.Pid,
) -> List(#(Dynamic, process.Pid, Dynamic, Dynamic))

@external(erlang, "erlang", "element")
fn workspace_subject(index: Int, journal: book.Journal) -> process.Subject(Nil)

@external(erlang, "erlang", "element")
fn native_subject(index: Int, journal: journal.Journal) -> process.Subject(Nil)

pub fn workspace_deadlines_cannot_recycle_unconsumed_service_asks_test() {
  let root = directory("workspace-ingress")
  let assert Ok(limits) = book.limits(12, 268_435_456) as "Finite journal."
  let assert Ok(journal) =
    book.fresh(root <> "/book.sqlite", semantic_scope(), limits)
    as "Real durable journal."
  let host = workspace_host(root)
  let assert Ok(config) = workspace_service.configure(host, journal, 4, 3000)
    as "Concrete scoped service."
  let assert Ok(remote) = workspace_service.start(config) as "Start service."
  let network = network()
  let assert Ok(server) = transport.server("owner", scope(), remote)
    as "Bind exact scope."
  let assert Ok(config) =
    listener.configure_workspace(network.socket, server, 4, 700)
    as "Four stable credits."
  let #(tree, stop, reports) = start_listener(config)
  system.suspend(workspace_service.pid(remote))

  // All four authenticated peers send complete invocations before their socket
  // runs finish. Service suspension keeps the original asks unconsumed.
  let peers =
    list.map([1, 2, 3, 4], fn(number) {
      let socket = workspace_peer(network.owner)
      assert tls.send(socket, <<"LWQ", 1, 0>>) == Ok(Nil)
      assert transfer.send(socket, transfer.Invocation, invocation(number))
        == Ok(Nil)
      socket
    })
  queued(workspace_service.pid(remote), 4)
  assert queued_workspace_bytes(workspace_service.pid(remote))
    == list.fold([1, 2, 3, 4], 0, fn(total, number) {
      total + bit_array.byte_size(invocation(number))
    })
  list.each(peers, await_socket_end)
  assert process.is_alive(tree)
  let assert Ok(client) =
    transport.client(connection.Config(..network.owner, within_ms: 200))
    as "Short caller deadline."
  list.each([5, 6, 7, 8], fn(number) {
    assert transport.exchange(client, transport.Submit, invocation(number))
      == Error(transport.Uncertain)
  })

  assert queue_info(workspace_service.pid(remote), MessageQueueLen).1 == 4
  assert queued_workspace_bytes(workspace_service.pid(remote))
    == list.fold([1, 2, 3, 4], 0, fn(total, number) {
      total + bit_array.byte_size(invocation(number))
    })

  // No timer clears service custody. Resuming consumption reveals the exact
  // queued submissions; an early-credit mutation leaves eight durable IDs.
  system.resume(workspace_service.pid(remote))
  let assert Ok(_) = workspace_service.query(remote, invocation(1))
    as "Consumption barrier follows the retired socket workers."
  list.each([1, 2, 3, 4], fn(number) {
    assert book.inspect(journal, invocation(number)) |> result.is_ok
  })
  list.each([5, 6, 7, 8], fn(number) {
    assert book.inspect(journal, invocation(number)) == Error(book.Missing)
  })
  let assert Ok(client) =
    transport.client(connection.Config(..network.owner, within_ms: 2500))
    as "Fresh exchange after actual service replies."
  assert transport.exchange(client, transport.Submit, invocation(9))
    |> result.is_ok
  stop_listener(network.socket, stop, reports)
  assert workspace_service.close(remote) == Ok(Nil)
  assert book.release(journal) == Ok(Nil)
  assert simplifile.delete(root) == Ok(Nil)
}

pub fn native_operation_deadlines_cannot_recycle_pending_credit_into_another_hello_test() {
  let root = directory("native-ingress")
  let assert Ok(capacity) = admission.capacity(12)
    as "Finite native identities."
  let assert Ok(journal) =
    journal.fresh(root <> "/book.sqlite", scope(), capacity)
    as "Real durable journal."
  let pool = native_pool()
  let assert Ok(remote) =
    service.start(service.Config(
      "owner",
      "executor",
      scope(),
      1,
      journal,
      pool,
      fn(_, _) { Error(Nil) },
      poll.monotonic().now,
    ))
    as "Concrete native service."
  let network = network()
  let assert Ok(config) = listener.configure(network.socket, remote, 4, 700)
    as "Four stable credits."
  let #(tree, stop, reports) = start_listener(config)

  // Hello completes normally on each connection before the service is stopped.
  // Its second operation then owns the same credit, never a new connection slot.
  let peers = list.map([1, 2, 3, 4], fn(_) { native_peer(network.owner) })
  system.suspend(service.pid(remote))
  let assert Ok(command) = wire.encode(envelope(1, wire.Hello))
    as "Closed second native operation."
  list.each(peers, fn(peer) {
    assert tls.send(peer, command) == Ok(Nil)
  })
  queued(service.pid(remote), 4)
  list.each(peers, await_socket_end)
  assert process.is_alive(tree)
  list.each([5, 6, 7, 8], fn(generation) {
    assert connection.exchange(
        connection.Config(..network.owner, generation:, within_ms: 200),
        wire.Hello,
      )
      == Error(connection.Uncertain)
  })
  assert queue_info(service.pid(remote), MessageQueueLen).1 == 4
  system.resume(service.pid(remote))
  assert service.exchange(remote, envelope(1, wire.Hello)) == Ok(wire.Hello)
  let assert Ok(generation) =
    decode.run(
      system.get_state(service.pid(remote)),
      decode.at([2], decode.int),
    )
    as "Observe concrete service generation after consuming its queue."
  assert generation == 1
  assert connection.exchange(
      connection.Config(..network.owner, within_ms: 2500),
      wire.Hello,
    )
    == Ok(wire.Hello)
  stop_listener(network.socket, stop, reports)
  assert service.shutdown(remote) == Ok(Nil)
  assert journal.release(journal) == Ok(Nil)
  assert simplifile.delete(root) == Ok(Nil)
}

pub fn workspace_query_deadlines_keep_bounded_bytes_without_admission_rows_test() {
  workspace_fixture("query", 4, fn(network, remote, journal, config) {
    list.each([1, 2, 3, 4], fn(number) {
      assert book.admit(journal, invocation(number)) == Ok(book.Accepted)
      let assert Ok(book.Claimed(_)) = book.claim(journal, invocation(number))
        as "Query observes original Started evidence without an effect worker."
    })
    let #(tree, stop, reports) = start_listener(config)
    system.suspend(workspace_service.pid(remote))
    let peers =
      list.map([1, 2, 3, 4], fn(number) {
        let peer = workspace_peer(network.owner)
        assert tls.send(peer, <<"LWQ", 1, 1>>) == Ok(Nil)
        assert transfer.send(peer, transfer.Invocation, invocation(number))
          == Ok(Nil)
        peer
      })
    queued(workspace_service.pid(remote), 4)
    let original_bytes = queued_workspace_bytes(workspace_service.pid(remote))
    list.each(peers, await_socket_end)
    let assert Ok(client) =
      transport.client(connection.Config(..network.owner, within_ms: 150))
      as "Each excess peer has a finite short lifetime."
    list.each([5, 6, 7, 8, 9, 10], fn(number) {
      assert transport.exchange(client, transport.Query, invocation(number))
        == Error(transport.Uncertain)
      assert queue_info(workspace_service.pid(remote), MessageQueueLen).1 == 4
      assert queued_workspace_bytes(workspace_service.pid(remote))
        == original_bytes
    })
    assert list.length(credits(tree)) == 4
    system.resume(workspace_service.pid(remote))
    assert workspace_service.query(remote, invocation(1)) == Ok(book.Unknown)
    let assert Ok(client) = transport.client(network.owner)
      as "Normal bounded client."
    assert transport.exchange(client, transport.Query, invocation(1))
      == Ok(book.Unknown)
    assert list.length(credits(tree)) == 4
    stop_listener(network.socket, stop, reports)
  })
}

pub fn socket_worker_death_preserves_credit_until_service_replies_test() {
  workspace_fixture("socket-death", 1, fn(network, remote, journal, config) {
    assert book.admit(journal, invocation(1)) == Ok(book.Accepted)
    let assert Ok(book.Claimed(_)) = book.claim(journal, invocation(1))
      as "Original Started identity."
    let #(tree, stop, reports) = start_listener(config)
    system.suspend(workspace_service.pid(remote))
    let peer = workspace_peer(network.owner)
    assert tls.send(peer, <<"LWQ", 1, 1>>) == Ok(Nil)
    assert transfer.send(peer, transfer.Invocation, invocation(1)) == Ok(Nil)
    queued(workspace_service.pid(remote), 1)
    let assert [credit] = credits(tree) as "One stable ingress owner."
    killed(network_worker(credit))
    await_socket_end(peer)
    assert process.is_alive(credit)
    let assert Ok(client) =
      transport.client(connection.Config(..network.owner, within_ms: 150))
      as "Bounded excess peer."
    list.each([2, 3, 4], fn(number) {
      assert transport.exchange(client, transport.Query, invocation(number))
        == Error(transport.Uncertain)
      assert queue_info(workspace_service.pid(remote), MessageQueueLen).1 == 1
    })
    system.resume(workspace_service.pid(remote))
    assert workspace_service.query(remote, invocation(1)) == Ok(book.Unknown)
    let assert Ok(client) = transport.client(network.owner)
      as "Reconciled service can reply."
    assert transport.exchange(client, transport.Query, invocation(1))
      == Ok(book.Unknown)
    assert credits(tree) == [credit]
    stop_listener(network.socket, stop, reports)
  })
}

pub fn acceptor_death_never_remints_an_unconsumed_temporary_credit_test() {
  workspace_fixture("acceptor-death", 1, fn(network, remote, _journal, config) {
    assert listener.supervised(config).restart == supervision.Temporary
    let #(tree, stop, reports) = start_listener(config)
    system.suspend(workspace_service.pid(remote))
    let peer = workspace_peer(network.owner)
    assert tls.send(peer, <<"LWQ", 1, 1>>) == Ok(Nil)
    assert transfer.send(peer, transfer.Invocation, invocation(1)) == Ok(Nil)
    queued(workspace_service.pid(remote), 1)
    let assert [credit] = credits(tree) as "One fixed child."
    killed(credit)
    no_credits(tree, 1000)
    await_socket_end(peer)
    let assert Ok(client) =
      transport.client(connection.Config(..network.owner, within_ms: 150))
      as "Excess peer remains bounded."
    list.each([2, 3, 4], fn(number) {
      assert transport.exchange(client, transport.Query, invocation(number))
        == Error(transport.Uncertain)
      assert queue_info(workspace_service.pid(remote), MessageQueueLen).1 == 1
      assert credits(tree) == []
    })
    system.resume(workspace_service.pid(remote))
    assert workspace_service.query(remote, invocation(1))
      == Error(workspace_service.Custody(book.Missing))
    assert credits(tree) == []
    stop_listener(network.socket, stop, reports)
  })
}

pub fn downstream_workspace_journal_timeout_retires_credit_while_rpc_stays_queued_test() {
  workspace_fixture("journal-timeout", 1, fn(network, remote, journal, config) {
    let assert Ok(journal_pid) =
      process.subject_owner(workspace_subject(2, journal))
      as "Test observation projects the existing opaque journal's lifecycle pid."
    system.suspend(journal_pid)
    let #(tree, stop, reports) = start_listener(config)
    let peer = workspace_peer(network.owner)
    assert tls.send(peer, <<"LWQ", 1, 1>>) == Ok(Nil)
    assert transfer.send(peer, transfer.Invocation, invocation(1)) == Ok(Nil)
    queued(journal_pid, 1)
    await_socket_end(peer)

    // The real service times out its 30-second journal RPC. Those downstream
    // bytes survive that reply, so uncertain service completion retires credit.
    no_credits(tree, 32_000)
    assert queue_info(journal_pid, MessageQueueLen).1 == 1
    let assert Ok(client) =
      transport.client(connection.Config(..network.owner, within_ms: 150))
      as "Bounded follow-up peers."
    list.each([2, 3, 4], fn(number) {
      assert transport.exchange(client, transport.Query, invocation(number))
        == Error(transport.Uncertain)
      assert queue_info(journal_pid, MessageQueueLen).1 == 1
      assert credits(tree) == []
    })
    system.resume(journal_pid)
    assert workspace_service.query(remote, invocation(1))
      == Error(workspace_service.Custody(book.Missing))
    stop_listener(network.socket, stop, reports)
  })
}

pub fn service_death_closes_admission_without_replacing_credits_test() {
  let root = directory("service-death")
  let assert Ok(limits) = book.limits(12, 268_435_456)
    as "Finite journal capacity."
  let assert Ok(journal) =
    book.fresh(root <> "/book.sqlite", semantic_scope(), limits)
    as "Concrete journal."
  let assert Ok(config) =
    workspace_service.configure(workspace_host(root), journal, 4, 3000)
    as "Concrete service config."
  let assert Ok(remote) = workspace_service.start(config)
    as "Start actual service."
  let network = network()
  let assert Ok(server) = transport.server("owner", scope(), remote)
    as "Bind scope."
  let assert Ok(config) =
    listener.configure_workspace(network.socket, server, 1, 700)
    as "One Temporary credit."
  let #(tree, stop, reports) = start_listener(config)
  system.suspend(workspace_service.pid(remote))
  let peer = workspace_peer(network.owner)
  assert tls.send(peer, <<"LWQ", 1, 1>>) == Ok(Nil)
  assert transfer.send(peer, transfer.Invocation, invocation(1)) == Ok(Nil)
  queued(workspace_service.pid(remote), 1)
  process.unlink(workspace_service.pid(remote))
  killed(workspace_service.pid(remote))
  no_credits(tree, 1000)
  await_socket_end(peer)
  let assert Ok(client) =
    transport.client(connection.Config(..network.owner, within_ms: 150))
    as "Bounded following peer."
  assert transport.exchange(client, transport.Query, invocation(2))
    == Error(transport.Uncertain)
  assert credits(tree) == []
  stop_listener(network.socket, stop, reports)
  assert book.release(journal) == Ok(Nil)
  assert simplifile.delete(root) == Ok(Nil)
}

pub fn downstream_native_journal_timeout_retires_credit_while_rpc_stays_queued_test() {
  let root = directory("native-journal-timeout")
  let assert Ok(capacity) = admission.capacity(12)
    as "Finite native identities."
  let assert Ok(journal) =
    journal.fresh(root <> "/book.sqlite", scope(), capacity)
    as "Actual native journal."
  let assert Ok(remote) =
    service.start(service.Config(
      "owner",
      "executor",
      scope(),
      1,
      journal,
      native_pool(),
      fn(_, _) { Error(Nil) },
      poll.monotonic().now,
    ))
    as "Concrete native service."
  let network = network()
  let assert Ok(config) = listener.configure(network.socket, remote, 1, 700)
    as "One stable ingress credit."
  let #(tree, stop, reports) = start_listener(config)
  let peer = native_peer(network.owner)
  let assert Ok(journal_pid) = process.subject_owner(native_subject(2, journal))
    as "Test observes actual downstream journal pid."
  system.suspend(journal_pid)
  let assert Ok(id) =
    identity.request_id("00000000-0000-7000-8000-000000000001")
    as "Original request UUID."
  let key = identity.request_key(scope(), operation(), id)
  let assert Ok(digest) = identity.digest(<<1:size(256)>>)
    as "Fixed request digest."
  let assert Ok(command) = wire.encode(envelope(1, wire.Query(key, digest, 0)))
    as "Concrete retained-evidence query."
  assert tls.send(peer, command) == Ok(Nil)
  queued(journal_pid, 1)
  await_socket_end(peer)
  no_credits(tree, 32_000)
  assert queue_info(journal_pid, MessageQueueLen).1 == 1
  list.each([2, 3, 4], fn(_) {
    assert connection.exchange(
        connection.Config(..network.owner, within_ms: 150),
        wire.Query(key, digest, 0),
      )
      == Error(connection.Uncertain)
    assert queue_info(journal_pid, MessageQueueLen).1 == 1
    assert credits(tree) == []
  })
  system.resume(journal_pid)
  assert service.exchange(remote, envelope(1, wire.Hello)) == Ok(wire.Hello)
  stop_listener(network.socket, stop, reports)
  assert service.shutdown(remote) == Ok(Nil)
  assert journal.release(journal) == Ok(Nil)
  assert simplifile.delete(root) == Ok(Nil)
}

fn workspace_fixture(
  name: String,
  workers: Int,
  run: fn(Network, workspace_service.Service, book.Journal, listener.Config) ->
    Nil,
) {
  let root = directory(name)
  let assert Ok(limits) = book.limits(12, 268_435_456)
    as "Finite journal capacity."
  let assert Ok(journal) =
    book.fresh(root <> "/book.sqlite", semantic_scope(), limits)
    as "Real durable journal."
  let assert Ok(config) =
    workspace_service.configure(workspace_host(root), journal, 4, 3000)
    as "Concrete effect service."
  let assert Ok(remote) = workspace_service.start(config)
    as "Concrete service starts."
  let network = network()
  let assert Ok(server) = transport.server("owner", scope(), remote)
    as "Scope binds."
  let assert Ok(config) =
    listener.configure_workspace(network.socket, server, workers, 700)
    as "Finite ingress capacity."
  run(network, remote, journal, config)
  assert workspace_service.close(remote) == Ok(Nil)
  assert book.release(journal) == Ok(Nil)
  assert simplifile.delete(root) == Ok(Nil)
}

fn start_listener(
  config: listener.Config,
) -> #(process.Pid, weft.Cancel, process.Subject(weft.Pulled(Nil, Nil))) {
  let spec = listener.supervised(config)
  let ready = process.new_subject()
  let reports = process.new_subject()
  let stop = weft.cancel_signal()
  let _relay =
    weft.new([
      fn() {
        let assert Ok(started) = spec.start()
          as "Start actual acceptor subtree."
        process.send(ready, started.pid)
        process.sleep_forever()
        Ok(Nil)
      },
    ])
    |> weft.cancel_with(stop)
    |> weft.deadline(90_000)
    |> weft.start_relayed(to: reports)
  let assert Ok(tree) = process.receive(ready, 1000)
    as "Acceptor tree is ready."
  #(tree, stop, reports)
}

fn stop_listener(
  socket: tls.Listener,
  stop: weft.Cancel,
  reports: process.Subject(weft.Pulled(Nil, Nil)),
) -> Nil {
  tls.close_listener(socket)
  weft.cancel(stop)
  let assert Ok(weft.PulledOutcome(_)) = process.receive(reports, 2000)
    as "Network owner reports after bounded shutdown."
  assert process.receive(reports, 2000) == Ok(weft.AllDelivered)
}

fn network() -> Network {
  let f = remote_tls_test.fixture()
  let settings = fn(
    local: remote_tls_test.Credentials,
    peer: remote_tls_test.Credentials,
  ) {
    let assert Ok(settings) =
      tls.settings(
        local.ca,
        local.certificate,
        local.key,
        peer.pin,
        1000,
        1500,
        500,
      )
      as "Real pinned credentials."
    settings
  }
  let assert Ok(socket) =
    tls.listen(settings(f.server, f.client), tls.Loopback, 0)
    as "Real TLS loopback; sandbox denial is a test failure."
  let assert Ok(port) = tls.port(socket) as "Ephemeral listener port."
  Network(
    socket,
    connection.Config(
      settings(f.client, f.server),
      "localhost",
      port,
      2500,
      "owner",
      "executor",
      1,
      scope(),
    ),
  )
}

fn native_peer(owner: connection.Config) -> tls.Connection {
  let assert Ok(socket) = tls.connect(owner.tls, "localhost", owner.port)
    as "Real authenticated native peer."
  let assert Ok(hello) = wire.encode(envelope(owner.generation, wire.Hello))
    as "Hello frame."
  assert tls.send(socket, hello) == Ok(Nil)
  let assert Ok(bytes) = tls.receive(socket) as "Initial Hello must complete."
  let assert Ok(reply) =
    wire.decode(bytes, wire.Executor, "owner", "executor", scope())
    as "Authenticated Hello reply."
  assert reply.body == wire.Hello
  socket
}

fn workspace_peer(owner: connection.Config) -> tls.Connection {
  let assert Ok(socket) = tls.connect(owner.tls, "localhost", owner.port)
    as "Real authenticated workspace peer."
  let assert Ok(hello) = wire.encode(envelope(1, wire.Hello))
    as "Workspace hello."
  let frame = <<"LWS", 1, hello:bits>>
  assert tls.send(socket, frame) == Ok(Nil)
  let assert Ok(<<"LWS", 1, reply:bytes>>) = tls.receive(socket)
    as "Workspace Hello precedes its decoded service ask."
  assert wire.decode(reply, wire.Executor, "owner", "executor", scope())
    |> result.is_ok
  socket
}

fn await_socket_end(peer: tls.Connection) -> Nil {
  assert tls.receive(peer) |> result.is_error
  tls.close(peer)
}

fn native_pool() -> native.Executor {
  let assert Ok(pool) =
    exec.start_pool(size: 1, spawn: fn() { Error(exec.PortOpenFailed) })
    as "Native pool is lazy; this ingress test launches no process."
  let assert Ok(executor) =
    native.start(native.ExecutorConfig(
      checkout: fn() { exec.checkout(pool, waiting: 1000) },
      checkin: fn(helper) { exec.checkin(pool, helper) },
      custody: fn() { exec.pool_custody(pool, waiting: 1000) },
      close_helpers: fn(ms) { exec.close_pool(pool, waiting: ms) },
      incarnation: 1,
      log: log.discard(),
    ))
    as "Concrete native executor."
  executor
}

fn scope() -> identity.Scope {
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-000000000001")
    as "Session."
  let assert Ok(workspace) = identity.workspace_id("checkout") as "Workspace."
  let assert Ok(executor) = identity.executor_id("executor") as "Executor."
  let assert Ok(epoch) = identity.epoch(1) as "Epoch."
  identity.scope(session, workspace, executor, epoch, epoch)
}

fn semantic_scope() -> cw.Scope {
  let assert Ok(scope) =
    cw.scope_from_fields(
      "00000000-0000-7000-8000-000000000001",
      "checkout",
      "executor",
      1,
      1,
    )
    as "Semantic scope."
  scope
}

fn operation() -> ids.OpId {
  let assert Ok(op) = ids.parse_op_id("00000000-0000-7000-8000-000000000002")
    as "Operation."
  op
}

fn envelope(generation: Int, body: wire.Body) -> wire.Envelope {
  wire.Envelope(wire.Owner, "owner", "executor", generation, scope(), body)
}

fn invocation(number: Int) -> BitArray {
  let assert Ok(id) =
    ids.parse_entry_id(
      "00000000-0000-7000-8000-"
      <> string.pad_start(int.to_string(number), 12, "0"),
    )
    as "Original UUID."
  let assert Ok(step) = cw.step("ingress") as "Physical step."
  let assert Ok(path) = cw.relative_path("file" <> int.to_string(number))
    as "Local path."
  let assert Ok(bytes) =
    codec.encode_invocation(workspace.invocation(
      semantic_scope(),
      operation(),
      step,
      workspace.System(workspace.WorkspaceAdministration),
      id,
      workspace.Write(path, "once"),
    ))
    as "Complete canonical invocation."
  bytes
}

fn workspace_host(root: String) -> workspace_local.Host {
  local_host(
    semantic_scope(),
    tool.Ctx(
      workspace: tool.LocalWorkspace(root, fs.real_filesystem()),
      strand: "main",
      op_id: operation(),
      step_id: "ingress",
      source_index: 0,
      base_policy: policy.workspace_default(root),
      directory_access: directory_access.none(),
      grants: [],
      demand: exec.FullEnforcement,
      env: [],
      clock: clock.fixed(0),
      owner_blobs: tool.OwnerBlobs(root <> "/.blobs", fs.real_filesystem()),
      clear_call: fn(_, _) { Error(broker.BrokerUnavailable) },
      raise_refusal: tool.no_raise(),
      observe_output: tool.ignore_output(),
    ),
    fn(_) { None },
  )
}

fn directory(name: String) -> String {
  let assert Ok(here) = simplifile.current_directory() as "Fixture root."
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let root =
    here
    <> "/build/remote-ingress/"
    <> name
    <> int.to_string(seconds)
    <> int.to_string(nanos)
  assert simplifile.create_directory_all(root) == Ok(Nil)
  root
}

fn queued(pid: process.Pid, expected: Int) {
  let answer =
    poll.until(1000, 5, fn() {
      let count = queue_info(pid, MessageQueueLen).1
      case count {
        count if count == expected -> poll.Done(Nil)
        count if count > expected -> poll.Fail(count)
        _ -> poll.Retry
      }
    })
  assert answer == poll.Answered(Nil)
}

fn queued_workspace_bytes(pid: process.Pid) -> Int {
  messages_info(pid, Messages).1
  |> list.fold(0, fn(total, message) {
    let assert Ok(bytes) =
      decode.run(message, decode.at([1, 1, 1], decode.bit_array))
      as "Every suspended-service message is a validated workspace ask."
    total + bit_array.byte_size(bytes)
  })
}

fn credits(tree: process.Pid) -> List(process.Pid) {
  children_info(tree) |> list.map(fn(child) { child.1 })
}

fn network_worker(credit: process.Pid) -> process.Pid {
  let assert [scope] = watched_info(credit, MonitoredBy).1
    as "Exactly one managed network scope watches this credit."
  let workers =
    links_info(scope, Links).1
    |> list.filter(fn(pid) { links_info(pid, Links).1 == [scope] })
  let assert [worker] = workers
    as "One concrete socket worker is linked only to its managed scope."
  worker
}

fn killed(pid: process.Pid) {
  let monitor = process.monitor(pid)
  process.kill(pid)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
    as "The exact selected process died."
  Nil
}

fn no_credits(tree: process.Pid, within: Int) {
  assert poll.until(within, 5, fn() {
      case credits(tree) {
        [] -> poll.Done(Nil)
        [_, ..] -> poll.Retry
      }
    })
    == poll.Answered(Nil)
}

// A registered context cannot construct the executor-local host.
fn local_host(
  scope: cw.Scope,
  ctx: tool.Ctx,
  observer: fn(String) -> option.Option(String),
) -> workspace_local.Host {
  let assert Ok(host) = workspace_local.new(scope, ctx, observer)
    as "fixture must have local authority"
  host
}
