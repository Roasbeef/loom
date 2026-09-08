//// Assembly and lifecycle tests use real SQLite with scripted providers.
//// Wire tests admit that assembly through the real daemon's authenticated v2
//// listener and credited snapshots; the legacy health route must be absent.
//// Internal host fixtures retain focused lease, supervision and policy checks.

import broker/broker
import broker/exec
import broker/policy
import client/catalog
import client/codemode
import client/daemon/domain as domain_service
import client/daemon/main as daemon_main
import client/daemon/manager
import client/daemon/root as daemon_root
import client/daemon/session_socket
import client/daemon_server_test as wire
import client/distillpass
import client/host
import client/internal/ffi_os
import client/jobs
import client/rules
import client/schedule
import client/serve
import client/server
import client/session_socket_test as transfer
import client/system_prompt
import core/clock
import core/ids
import core/json
import core/message
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import machine/operation
import machine/strand as machine_strand
import provider/adapter/anthropic
import provider/gateway as provider_gateway
import provider/http
import provider/model
import provider/secret
import runtime/api
import session/session
import simplifile
import storage/sqlite
import support/addresses
import support/internal/ffi_ws
import support/provider as provider_test
import telemetry/log
import tui/connection
import weft
import weft/poll
import weft/registry as address

// A home directory that does not exist, so a server booted here never
// picks up the developer's own `~/.agents/AGENTS.md`. A home with no
// global default is silent, which is what keeps these assertions about
// the prompt pack and the workspace alone.
const empty_home = Some("build/no-operator-home")

const root = "build/serve-test"

// A one-entry catalogue whose gateway rides a transport that never
// answers: subscribe and healthz touch no provider, so the smoke boot
// needs reachability of the seam, not a live wire — and building the
// gateway *from* the catalogue is exactly what `resolve` does.
fn scripted_catalog() -> catalog.Catalog {
  catalog.Catalog(
    models: [
      catalog.CatalogModel(
        name: "acme",
        dialect: catalog.Anthropic,
        base_url: "https://acme.test",
        api_key_env: "ACME_KEY",
        model_id: "loom-1",
        context_window: 100_000,
        max_output_tokens: 4096,
        thinking: model.ThinkingOff,
        pricing: None,
      ),
    ],
    roles: [#(model.Main, ["acme"])],
    mcp_servers: [],
  )
}

fn scripted_gateway() -> provider_gateway.Gateway {
  catalog.gateway(
    scripted_catalog(),
    transport: provider_test.silent(),
    secrets: secret.from_list([#("ACME_KEY", "smoke-test-key")]),
    clock: clock.fixed(at: 0),
  )
}

fn settings() -> serve.Settings {
  settings_under(root)
}

// A repository-relative test path as the absolute one every policy path
// must be.
fn absolute(path: String) -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner must have a working directory"
  here <> "/" <> path
}

fn settings_under(root: String) -> serve.Settings {
  // Absolute, because the workspace root really is: it becomes the base
  // policy's writable root, and `serve.base_policy_fault` refuses a boot
  // on a policy whose paths the jail could not accept. A test that
  // booted on a relative one was proving a server can start in a posture
  // no tool call could ever run under.
  let root = absolute(root)
  serve.Settings(
    secrets: secret.env(),
    secret_failures: [],
    session_path: root <> "/session.db",
    domain_paths: option.None,
    bind_host: "127.0.0.1",
    bind_port: 0,
    token_path: root <> "/session.db.token",
    workspace: root <> "/work",
    base_policy: serve.base_policy(root <> "/work"),
    // Never spawned: nothing in this test runs a tool, and the pool
    // spawns helpers lazily at first checkout.
    helper_path: "/bin/sh",
    helper_pool_size: 2,
    session_id: "session",
    demand: exec.BestEffort,
    gateway: scripted_gateway(),
    catalog: scripted_catalog(),
    system: None,
    home: empty_home,
    model: machine_strand.ModelIdentity(provider: "acme", model_id: "loom-1"),
    context_window: 100_000,
    max_output_tokens: 4096,
    api: anthropic.api_name,
    compaction: operation.CompactionSettings(
      enabled: True,
      reserve_tokens: 16_384,
      keep_recent_tokens: 20_000,
    ),
    // No seed here: the boot smoke must not go looking for a toolchain,
    // and a host without one registers no `code_mode` tool.
    codemode_seed: root <> "/no-such-seed",
    codemode_seams: codemode.WorkspaceOnly,
    rules: [],
    schedules: [],
    schedule_policy: schedule.ModelSchedulesOff,
    jobs_policy: jobs.default_policy,
    deactivated_tools: [],
    // No lifecycle distillation in this rig: the pass would open the
    // memory store this test asserts about and spend the scripted
    // provider's turns. `memory_lifecycle_test` is where the shipped
    // producer is exercised.
    memory: distillpass.no_pass(),
    // Offline, three names: the jail every session had before the
    // `[tools]` table existed.
    tools: catalog.default_tools(),
  )
}

pub fn the_session_environment_carries_the_toolchain_home_and_tmpdir_test() {
  // Without a toolchain the shell gets the system PATH; with one it gets
  // the compiler's, so `gleam` resolves in the shell as it does for the
  // build. HOME and TMPDIR are directories under the workspace, because
  // the workspace is the one root the jail lets a tool write — and under
  // its dot-directory, so what a toolchain writes to either stays out of
  // the operator's tree.
  assert serve.session_environment("/work", None)
    == [
      #("PATH", "/usr/local/bin:/usr/bin:/bin"),
      #("HOME", "/work/.codemode/home"),
      #("TMPDIR", "/work/.codemode/tmp"),
    ]
  let toolchain = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
  let assert Ok(path) =
    list.key_find(serve.session_environment("/work", Some(toolchain)), "PATH")
  assert path == toolchain
  assert serve.tool_tmp_directory("/work") == "/work/.codemode/tmp"
  assert serve.tool_home_directory("/work") == "/work/.codemode/home"
}

pub fn a_linked_worktree_widens_the_base_to_its_git_directories_test() {
  // A worktree keeps its metadata under the main repository's .git, so
  // a jailed git commit needs both that directory and the main .git it
  // shares objects with; a primary checkout, whose .git is inside the
  // workspace, gets nothing extra.
  let root = "build/test-linked-worktree"
  let _stale = simplifile.delete(root)
  let assert Ok(cwd) = simplifile.current_directory()
  let repo = cwd <> "/" <> root <> "/repo"
  let work = cwd <> "/" <> root <> "/work"
  let gitdir = repo <> "/.git/worktrees/work"
  let assert Ok(Nil) = simplifile.create_directory_all(gitdir)
  let assert Ok(Nil) = simplifile.create_directory_all(work)
  let assert Ok(Nil) =
    simplifile.write(work <> "/.git", "gitdir: " <> gitdir <> "\n")
  let assert Ok(Nil) = simplifile.write(gitdir <> "/commondir", "../..\n")

  assert serve.linked_git_directories(work) == [gitdir, repo <> "/.git"]
  let widened = serve.widening_linked_worktree(serve.base_policy(work), work)
  assert widened.writable_roots == [work, gitdir, repo <> "/.git"]

  // A primary checkout: .git is a directory, so reading it fails and
  // nothing is widened.
  let assert Ok(Nil) = simplifile.create_directory_all(repo <> "/src")
  assert serve.linked_git_directories(repo) == []
  assert serve.widening_linked_worktree(serve.base_policy(repo), repo)
    == serve.base_policy(repo)
  let _cleanup = simplifile.delete(root)
}

pub fn boot_serves_healthz_and_ws_subscribe_test() {
  use serving, instance, incarnation, token <- with_daemon_instance
  let token_path = serving.ready.state_root <> "/owner.token"
  assert simplifile.read(token_path) == Ok(token)
  let assert Ok(info) = simplifile.file_info(token_path)
    as "the stable daemon credential is a real private file"
  assert info.mode % 0o1000 == 0o600
  let base = "http://127.0.0.1:" <> int.to_string(serving.listener.port)
  let assert Ok(health) = request.to(base <> "/healthz")
    as "the legacy route probe is a valid URL"
  let assert Ok(health_response) = httpc.send(health)
    as "the daemon listener answers HTTP"
  assert health_response.status == 404
  let assert Ok(control) = request.to(base <> "/v2/control")
    as "the protected route probe is a valid URL"
  let assert Ok(control_response) = httpc.send(control)
    as "the daemon rejects an unauthenticated request"
  assert control_response.status == 401
  subscribed_cut(serving, instance, incarnation, token)
}

// The root remains outside the bounded assertion task, so a failed wire or
// lifecycle assertion cannot bypass its original transitive shutdown witness.
fn with_daemon_instance(run) {
  // Default prompt rendering checks the helper's advertised jail capabilities.
  // Its peer must speak the helper protocol and confirm retirement at shutdown.
  let settings =
    serve.Settings(
      ..settings_under(fresh_instance_root()),
      helper_path: absolute("../sandbox/loom-exec"),
    )
  let assert Ok(config) =
    daemon_main.parse(["--state-dir", settings.workspace <> "/daemon"])
    as "the fixture selects one fresh daemon directory"
  let assert Ok(daemon) =
    daemon_root.start(
      daemon_root.Config(config.state_root, "Fixture owner", 2),
      manager.Assembly(
        domain_build: fn(_, _, _) { Ok(domain_service.inert()) },
        build: fn(record, _domain, _services, owner) {
          let assert Ok(id) = ids.parse_session_id(record.id)
            as "the catalogue reserved a canonical identity"
          serve.assemble_owned(
            serve.Settings(
              ..settings,
              session_path: record.path,
              session_id: record.id,
            ),
            id,
            log.discard(),
            owner,
          )
        },
        fatal: serve.instance_children,
      ),
    )
    as "the root owns every admitted SQLite instance"
  let outcomes =
    weft.new([
      fn() -> Result(Nil, Nil) {
        let assert Ok(serving) =
          daemon_main.listen(config, daemon, fn(request, attachment) {
            session_socket.upgrade(
              daemon,
              request,
              attachment,
              attachment.instance.gateway,
            )
          })
          as "the original root owns the real v2 listener"
        let assert Ok(token) = daemon_root.listener_credential(daemon)
          as "the owner credential is available only to the fixture"
        let assert Ok(view) =
          manager.create(
            serving.ready.registry,
            manager.Creation("serve-wire", settings.workspace, "Fixture", ""),
            directory: serving.ready.sessions_directory,
            generator: ids.generator(clock.fixed(1000), 887),
          )
          as "an explicit command admits one real session"
        let assert poll.Answered(instance) =
          poll.until(within: 10_000, every: 5, attempt: fn() {
            case manager.resolve(serving.ready.registry, view.registration.id) {
              Ok(instance) -> poll.Done(instance)
              Error(_) -> poll.Retry
            }
          })
          as "the explicitly admitted SQLite instance becomes resident"
        let assert Ok(manager.View(status: manager.Resident(incarnation), ..)) =
          manager.get(serving.ready.registry, view.registration.id)
          as "the fixture captures the original incarnation"
        run(serving, instance, incarnation, token)
        Ok(Nil)
      },
    ])
    |> weft.deadline(30_000)
    |> weft.start

  // Report only the fixed task classification: assertion payloads can contain
  // the fixture credential, and a cleanup failure must not hide task failure.
  list.each(outcomes, fn(outcome) {
    let status = case outcome {
      weft.Completed(..) -> "completed"
      weft.Failed(..) -> "failed"
      weft.Crashed(..) -> "crashed"
      weft.Abandoned(..) -> "abandoned"
      weft.NeverStarted(..) -> "never_started"
      weft.DrainProofLost(..) -> "drain_proof_lost"
      weft.CancellationUnconfirmed(..) -> "cancellation_unconfirmed"
    }
    io.println("serve daemon fixture task: " <> status)
  })
  assert daemon_root.shutdown(daemon, within: 15_000) == Ok(Nil)
    as "original listener and instance retirement completes even after assertion failure"
  assert outcomes == [weft.Completed(0, Nil)]
    as "the bounded daemon fixture completed every assertion"
}

fn subscribed_cut(
  serving: daemon_main.Serving(serve.Instance),
  instance: serve.Instance,
  incarnation,
  token,
) {
  let id = ids.session_id_to_string(api.session_id(instance.runtime))
  let #(socket, headers) =
    wire.connect(serving.listener.port, token, "/v2/sessions/" <> id <> "/ws")
  assert string.contains(headers, "101 Switching Protocols")
  let #(begin, snapshot_id) = transfer.begin(socket, id, within_ms: 1000)
  assert wire_field(begin, "session_id") == json.String(id)
  assert wire_field(begin, "epoch") == json.String(serving.ready.epoch)
  assert wire_field(begin, "incarnation") == json.String(incarnation)
  assert wire_field(begin, "role") == json.String("owner")
  assert transfer.drain(socket, snapshot_id, 0, [], 32, within_ms: 1000) != []
  let _closed = ffi_ws.tcp_close(socket)
  Nil
}

fn wire_field(value, key) {
  let assert json.Object(fields) = value as "the frame body is an object"
  let assert Ok(value) = list.key_find(fields, key)
    as "the authoritative attachment field is present"
  value
}

pub fn a_socket_crash_does_not_kill_its_terminal_test() {
  use served <- with_instance_listener
  let inbox = connection.new_inbox()
  let socket = open_test_socket(served, inbox)
  let assert Ok(owner) = connection.owner(socket)
    as "the connected socket must have an owner"
  process.kill(owner)
  let assert Ok(connection.Closed(_)) = process.receive(inbox, 1000)
    as "a socket crash must become a close notice in the surviving terminal"
  assert connection.adopt(socket) != Ok(Nil)
}

pub fn normal_terminal_exit_closes_its_socket_test() {
  use served <- with_instance_listener
  let sockets = process.new_subject()
  process.spawn_unlinked(fn() {
    let socket = open_test_socket(served, connection.new_inbox())
    process.send(sockets, socket)

    // Returning normally must release the socket without an explicit close.
    Nil
  })
  let assert Ok(socket) = process.receive(sockets, 1000)
    as "the terminal must publish its socket before exiting"
  await_socket_exit(socket)
}

pub fn cancelled_connection_attempt_closes_its_socket_test() {
  use served <- with_instance_listener
  let sockets = process.new_subject()
  let inbox = connection.new_inbox()
  let attempt =
    process.spawn_unlinked(fn() {
      let assert Ok(socket) =
        connection.connect(socket_address(served), served.token, inbox)
        as "the background connection attempt must succeed"
      process.send(sockets, socket)
      process.sleep_forever()
    })
  let assert Ok(socket) = process.receive(sockets, 1000)
    as "the attempt must publish its socket before cancellation"
  process.kill(attempt)
  await_socket_exit(socket)
}

pub fn a_returned_socket_remains_owned_by_its_inbox_test() {
  use served <- with_instance_listener
  let sockets = process.new_subject()
  let inbox = connection.new_inbox()
  let attempt =
    process.spawn_unlinked(fn() {
      let assert Ok(socket) =
        connection.connect(socket_address(served), served.token, inbox)
        as "the background connection attempt must succeed"
      process.send(sockets, socket)
    })
  let monitor = process.monitor(attempt)
  let assert Ok(socket) = process.receive(sockets, 1000)
    as "the successful attempt must return its socket"
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
    as "the attempt must exit before the terminal adopts its socket"
  assert connection.adopt(socket) == Ok(Nil)
  connection.close(socket)
  await_socket_exit(socket)
}

fn with_instance_listener(run: fn(server.Server) -> Nil) -> Nil {
  let assert Ok(instance) =
    serve.open_instance(instance_settings(fresh_instance_root()), log.discard())
    as "the lifecycle fixture must open a real instance"
  let assert Ok(served) =
    server.serve(server.Config(
      gateway: instance.gateway,
      bind: "127.0.0.1",
      port: 0,
      auth: server.BearerAuth("socket-lifetime-test"),
      entropy: ffi_os.unique_positive_integer,
    ))
    as "the lifecycle fixture must expose a real listener"
  run(served)
  server.stop(served)
  serve.close_instance(instance)
}

fn socket_address(served: server.Server) -> String {
  "ws://127.0.0.1:" <> int.to_string(served.port) <> "/v1/ws"
}

fn open_test_socket(
  served: server.Server,
  inbox: Subject(connection.Message),
) -> connection.Connection {
  let assert Ok(socket) =
    connection.connect(socket_address(served), served.token, inbox)
    as "the fixture socket must authenticate"
  let assert Ok(connection.Connected) = process.receive(inbox, 1000)
    as "the fixture socket must complete its handshake"
  socket
}

fn await_socket_exit(socket: connection.Connection) -> Nil {
  case connection.owner(socket) {
    Error(Nil) -> Nil
    Ok(pid) -> {
      let monitor = process.monitor(pid)
      let assert Ok(_) =
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(down) { down })
        |> process.selector_receive(1000)
        as "the abandoned socket must actually exit"
      Nil
    }
  }
}

pub fn two_instances_have_independent_lifetimes_test() {
  let root = fresh_instance_root()
  let first_settings = instance_settings(root <> "/a")
  let second_settings = instance_settings(root <> "/b")
  let assert Ok(first) = serve.open_instance(first_settings, log.discard())
    as "session A must open without a listener"
  let assert Ok(second) = serve.open_instance(second_settings, log.discard())
    as "session B must open beside session A in the same VM"
  assert api.session_id(first.runtime) != api.session_id(second.runtime)
  assert address.owner(first.namespace) != address.owner(second.namespace)
  complete_instance_turn(first)

  // Session assembly must ignore transport settings. Both fixtures carry an
  // invalid bind address and port, and neither may publish a token file.
  assert simplifile.is_file(first_settings.token_path) == Ok(False)
  assert simplifile.is_file(second_settings.token_path) == Ok(False)
  assert simplifile.is_directory(absolute(root <> "/a/transport-only"))
    == Ok(False)
  serve.close_instance(first)
  assert !process.is_alive(address.owner(first.namespace))
  assert address.lookup(first.gateway.name) == Error(Nil)
  assert process.is_alive(second.runtime.tree.supervisor)
  complete_instance_turn(second)
  serve.close_instance(second)
  assert !process.is_alive(address.owner(second.namespace))
}

pub fn listener_failure_closes_the_opened_instance_test() {
  let root = fresh_instance_root()
  let settings = instance_settings(root)

  // Session assembly creates the workspace directory. A token cannot replace
  // that directory, so listener setup fails after the whole instance opens.
  let refused =
    serve.boot(serve.Settings(..settings, token_path: settings.workspace))
  let assert Error(reason) = refused as "the token path must refuse a directory"
  assert string.contains(reason, "the websocket server did not start")
  let assert Ok(reopened) =
    session.open_sqlite(
      path: settings.session_path,
      owner: "listener-failure-probe",
      lease_ttl_ms: 60_000,
      clock: clock.from_function(ffi_os.system_time_ms),
    )
    as "a failed listener must close the instance and release its writer lease"
  assert session.close(reopened) == Ok(Nil)
}

pub fn reopened_instance_does_not_revive_an_expired_writer_test() {
  let root = fresh_instance_root()
  let settings = instance_settings(root)
  let assert Ok(Nil) = simplifile.create_directory_all(absolute(root))
    as "the stale writer's database directory must exist"

  // Retain an expired fence-one connection without a runtime renewing it.
  // This is the old daemon's constant identity, not the new incarnation's.
  let assert Ok(stale) =
    session.open_sqlite(
      path: settings.session_path,
      owner: "loomd",
      lease_ttl_ms: 1000,
      clock: clock.fixed(at: 0),
    )
    as "the stale writer must acquire the original fence"
  let assert Ok(first) = serve.open_instance(settings, log.discard())
    as "the first instance must take over the expired writer lease"
  let first_owner = held_writer_owner(settings.session_path)
  let session_id = api.session_id(first.runtime)
  serve.close_instance(first)

  // Closing removes the row. The next incarnation returns to fence one,
  // which would make the stale connection authoritative under a fixed owner.
  let assert Ok(second) = serve.open_instance(settings, log.discard())
    as "a cleanly closed session must reopen"
  let second_owner = held_writer_owner(settings.session_path)
  assert result.is_error(stale.renew_lease())
    as "reopening must not revive the expired fence-one writer"
  assert first_owner != second_owner
  assert api.session_id(second.runtime) == session_id

  // A delayed close from the stale connection must not delete the current
  // lease. A complete provider turn proves the current writer can still commit.
  assert session.close(stale) == Ok(Nil)
  assert held_writer_owner(settings.session_path) == second_owner
  complete_instance_turn(second)
  serve.close_instance(second)
}

fn held_writer_owner(path: String) -> String {
  let assert Error(session.SqliteOpenFailed(sqlite.LeaseHeld(owner:, ..))) =
    session.open_sqlite(
      path:,
      owner: "lease-identity-probe",
      lease_ttl_ms: 60_000,
      clock: clock.from_function(ffi_os.system_time_ms),
    )
    as "a second connection must be refused with the live writer identity"
  owner
}

type Counter {
  AtomCount
}

@external(erlang, "erlang", "system_info")
fn system_count(counter: Counter) -> Int

pub fn repeated_instance_assembly_does_not_allocate_atoms_test() {
  let root = fresh_instance_root()

  // Warm module loading and every measured loop path in this VM. Each cycle
  // still creates a new SQLite database and executes through the real wiring.
  int.range(from: 0, to: 2, with: Nil, run: fn(_, index) {
    instance_cycle(root <> "/warm-" <> int.to_string(index))
  })
  let before = system_count(AtomCount)
  int.range(from: 0, to: 10, with: Nil, run: fn(_, index) {
    instance_cycle(root <> "/measured-" <> int.to_string(index))
  })
  assert system_count(AtomCount) == before
    as "session services must not leave permanent process-name atoms"
}

fn fresh_instance_root() -> String {
  root
  <> "/instances-"
  <> int.to_string(ffi_os.system_time_ms())
  <> "-"
  <> int.to_string(ffi_os.unique_positive_integer())
}

fn instance_settings(root: String) -> serve.Settings {
  serve.Settings(
    ..settings_under(root),
    bind_host: "not an interface",
    bind_port: -1,
    token_path: absolute(root) <> "/transport-only/daemon.token",
    // Startup probes a helper's jail capabilities. Use the built protocol peer,
    // not /bin/sh, whose missing hello waits out every handshake deadline.
    helper_path: absolute("../sandbox/loom-exec"),
    gateway: completed_gateway(),
  )
}

fn instance_cycle(root: String) -> Nil {
  let assert Ok(instance) =
    serve.open_instance(instance_settings(root), log.discard())
    as "the complete session assembly must open"
  complete_instance_turn(instance)
  serve.close_instance(instance)
  assert !process.is_alive(instance.runtime.tree.supervisor)
  assert !process.is_alive(instance.services)
  assert !process.is_alive(address.owner(instance.namespace))
}

fn complete_instance_turn(instance: serve.Instance) -> Nil {
  let assert Ok(helper) = exec.checkout(instance.pool, waiting: 1000)
    as "the instance must have a real, handshaken helper"
  exec.checkin(instance.pool, helper)
  let assert Ok(op) = api.prompt(instance.runtime, [user("finish this turn")])
    as "the instance must admit through its own writer"
  let assert Ok(operation.RunLastResult(outcome: operation.RunCompleted(_), ..)) =
    api.await_result(instance.runtime, op, within_ms: 5000)
    as "the instance must complete through the real provider wiring"
  Nil
}

fn completed_gateway() -> provider_gateway.Gateway {
  catalog.gateway(
    scripted_catalog(),
    transport: provider_test.transport(fn(_request, events) {
      process.send(
        events,
        http.ResponseStatus(200, [
          #("content-type", "text/event-stream"),
        ]),
      )
      process.send(
        events,
        http.ResponseChunk(bit_array.from_string(
          "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"instance\",\"model\":\"loom-1\",\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}\n\n"
          <> "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"
          <> "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"finished\"}}\n\n"
          <> "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n"
          <> "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
        )),
      )
      process.send(events, http.ResponseEnd)
    }),
    secrets: secret.from_list([#("ACME_KEY", "instance-test-key")]),
    clock: clock.fixed(at: 0),
  )
}

// --- the catalogue's thinking level, seeded (issue #14, ruling 3) ----------

const thinking_root = "build/serve-test-thinking"

// A catalogue entry's `thinking` is not decoration and it is not a
// dispatch override: it *seeds* the strand the boot creates. What the
// server then puts on the wire is the strand's own per-turn level, which
// is why the boot has to get the seed right — nothing downstream will
// re-derive it, and `set_config thinking_level` is the only thing that
// moves it afterwards.
pub fn a_boot_seeds_the_main_strand_from_the_entrys_thinking_test() {
  let _stale = simplifile.delete(thinking_root)
  let bodies = process.new_subject()
  let catalogue = thinking_catalog(model.ThinkingHigh)
  let assert Ok(booted) =
    serve.boot(
      serve.Settings(
        ..settings_under(thinking_root),
        catalog: catalogue,
        gateway: recording_gateway(catalogue, bodies),
      ),
    )
    as "the server must boot"

  // The seed landed durably…
  let assert Ok(Some(session.Cell(value: seeded, ..))) =
    session.strand_configuration(booted.instance.runtime.session, "main")
    as "the main strand's configuration must read cleanly"
  assert seeded.thinking_level == machine_strand.ThinkingHigh

  // …and it is what the *first dispatch* actually asks the provider for.
  // Driven through the whole real stack — the boot's own wiring, gateway
  // and Anthropic adapter — so this is the bytes on the wire and not a
  // restatement of the seed. High is `budget_tokens: 16384`.
  let assert Ok(_op) = api.prompt(booted.instance.runtime, [user("think hard")])
    as "the prompt must be accepted"
  let assert Ok(body) = process.receive(bodies, within: 10_000)
    as "the boot must dispatch one generation"
  assert string.contains(body, "\"budget_tokens\":16384")

  serve.shutdown(booted)
}

fn user(text: String) -> message.AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: 0,
    origin: None,
  )
}

fn thinking_catalog(level: model.ThinkingLevel) -> catalog.Catalog {
  let assert [entry] = scripted_catalog().models
    as "the scripted catalogue must have exactly one entry"
  catalog.Catalog(..scripted_catalog(), models: [
    catalog.CatalogModel(..entry, thinking: level),
  ])
}

// A gateway whose transport reports the request body it was handed and
// then fails the attempt terminally, so the run drains at once instead of
// waiting out a provider timeout. The subject belongs to the test
// process, which is what lets the body be read after the fact.
fn recording_gateway(
  catalogue: catalog.Catalog,
  bodies: Subject(String),
) -> provider_gateway.Gateway {
  catalog.gateway(
    catalogue,
    transport: provider_test.transport(fn(request: http.HttpRequest, out) {
      process.send(bodies, request.body)
      process.send(out, http.ResponseStatus(status: 400, headers: []))
      process.send(
        out,
        http.ResponseChunk(chunk: <<
          "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"scripted\"}}":utf8,
        >>),
      )
      process.send(out, http.ResponseEnd)
    }),
    secrets: secret.from_list([#("ACME_KEY", "smoke-test-key")]),
    clock: clock.fixed(at: 0),
  )
}

// --- which seams can reach an MCP server ------------------------------------

/// A host serving the orchestration seam alone starts no MCP server,
/// however many are configured. A server's tools are a module only a
/// *workspace* program can import — the orchestration seam is widened by
/// none of it, ever — so `[mcp.*]` beside `--codemode-seams
/// orchestration` would spawn third-party processes, each holding a
/// configured secret in its environment, that no program could ever
/// call. The boot says so on one `mcp.unavailable` line instead.
pub fn orchestration_only_seams_cannot_reach_an_mcp_server_test() {
  let orchestrating =
    serve.Settings(
      ..settings(),
      codemode_seams: codemode.OrchestrationOnly,
      catalog: catalog.Catalog(..scripted_catalog(), mcp_servers: [
        catalog.McpServer(
          name: "github",
          command: ["mcp-server-github"],
          api_key_env: Some("GITHUB_TOKEN"),
        ),
      ]),
    )
  assert !serve.mcp_reachable(orchestrating.codemode_seams)
  // And both seams that do serve a workspace program reach one, so this
  // is a gate on reachability rather than on MCP.
  assert serve.mcp_reachable(codemode.WorkspaceOnly)
  assert serve.mcp_reachable(codemode.BothSeams)
}

// --- the pinned system prompt ----------------------------------------------

const prompt_root = "build/serve-test-prompt"

/// The prompt is assembled at the first open and pinned; every later boot
/// of the same session sends the pinned bytes rather than deriving them
/// again. The proof is a `CLAUDE.md` that changes between the two boots:
/// a re-derived prompt would carry the new text and cost a fresh
/// one-hour cache write on the first turn after every restart.
pub fn boot_pins_the_system_prompt_and_reuses_it_test() {
  let _stale = simplifile.delete(prompt_root)
  let workspace = prompt_root <> "/work"
  let assert Ok(Nil) = simplifile.create_directory_all(workspace)
    as "the workspace must exist"
  let assert Ok(Nil) =
    simplifile.write(workspace <> "/CLAUDE.md", "# demo\n\nBuild with make.\n")
    as "the guidance file must be written"

  let assert Ok(first) = serve.boot(settings_under(prompt_root))
    as "the first boot must succeed"
  let assert Ok(Some(pinned)) = system_prompt.pinned(first.instance.runtime)
    as "the first boot must pin a system prompt"
  // A first boot renders the shipped pack and owes the pin it just paid.
  assert first.instance.prompt.origin == system_prompt.Shipped
  assert first.instance.prompt.text == pinned
  assert first.instance.prompt.warnings == []
  // It is the rendered pack against this host, not an empty string and
  // not a placeholder: the workspace, the shell, and the repository's own
  // guidance are all in it, framed as project-authored data.
  assert string.contains(pinned, "Workspace root: " <> absolute(workspace))
  assert string.contains(pinned, "Shell: " <> serve.shell_path)
  assert string.contains(pinned, "<project-guidance>")
  assert string.contains(pinned, "Build with make.")
  serve.shutdown(first)

  // The guidance changes under the session. A prompt derived from live
  // inputs would move; a pinned one cannot.
  let assert Ok(Nil) =
    simplifile.write(
      workspace <> "/CLAUDE.md",
      "# demo\n\nEverything about this project is different now.\n",
    )
    as "the guidance file must be rewritten"
  let assert Ok(second) = serve.boot(settings_under(prompt_root))
    as "the second boot must succeed"
  let assert Ok(Some(resumed)) = system_prompt.pinned(second.instance.runtime)
    as "the second boot must read the pinned prompt"
  // The second boot took the pin rather than the pack: nothing was
  // rendered, so nothing could have moved.
  assert second.instance.prompt.origin == system_prompt.Pinned
  assert !second.instance.prompt.fresh
  assert resumed == pinned
  assert !string.contains(resumed, "different now")
  serve.shutdown(second)
}

/// The enforcement demand is part of the prompt's durable identity. A
/// changed demand re-renders once so the prompt cannot claim a stronger
/// sandbox than the broker requires; the next boot at that demand reuses
/// the new bytes.
pub fn a_changed_enforcement_demand_repins_the_system_prompt_test() {
  let demand_root = "build/serve-test-prompt-demand"
  let _stale = simplifile.delete(demand_root)
  let workspace = demand_root <> "/work"
  let assert Ok(Nil) = simplifile.create_directory_all(workspace)
    as "the workspace must exist"

  let best_effort = settings_under(demand_root)
  let assert Ok(first) = serve.boot(best_effort)
    as "the first boot must succeed"
  assert first.instance.prompt.origin == system_prompt.Shipped
  assert string.contains(first.instance.prompt.text, "best-effort mode")
  let best_effort_text = first.instance.prompt.text
  serve.shutdown(first)

  let platform = serve.Settings(..best_effort, demand: exec.PlatformEnforcement)
  let assert Ok(second) = serve.boot(platform)
    as "the changed demand must render a truthful replacement"
  assert second.instance.prompt.origin == system_prompt.Shipped
  assert second.instance.prompt.fresh
  assert second.instance.prompt.text != best_effort_text
  assert !string.contains(second.instance.prompt.text, "best-effort mode")
  let platform_text = second.instance.prompt.text
  serve.shutdown(second)

  let assert Ok(third) = serve.boot(platform)
    as "the unchanged demand must reuse the replacement"
  assert third.instance.prompt.origin == system_prompt.Pinned
  assert !third.instance.prompt.fresh
  assert third.instance.prompt.text == platform_text
  serve.shutdown(third)
}

/// `LOOM_SYSTEM_PROMPT` still bypasses the pack entirely, and beats an
/// existing pin, because setting it is a deliberate act.
pub fn an_explicit_override_bypasses_the_pack_test() {
  let override_root = "build/serve-test-override"
  let _stale = simplifile.delete(override_root)
  let assert Ok(booted) =
    serve.boot(
      serve.Settings(
        ..settings_under(override_root),
        system: Some("operator words only"),
      ),
    )
    as "the boot must succeed with an override"
  let assert Ok(Some(pinned)) = system_prompt.pinned(booted.instance.runtime)
    as "the override must be pinned"
  assert pinned == "operator words only"
  serve.shutdown(booted)
}

/// The assembled prompt reaches the wire, not just the durable cell. A
/// capturing transport takes the request the gateway would have sent and
/// the rendered `system` block is in its body — which is the only place
/// the pin is worth anything, and the one thing a pinned-cell assertion
/// alone would not notice going missing.
pub fn the_pinned_prompt_reaches_the_provider_request_test() {
  let wire_root = "build/serve-test-wire"
  let _stale = simplifile.delete(wire_root)
  let workspace = wire_root <> "/work"
  let assert Ok(Nil) = simplifile.create_directory_all(workspace)
    as "the workspace must exist"
  let sent = process.new_subject()
  let assert Ok(booted) =
    serve.boot(
      serve.Settings(
        ..settings_under(wire_root),
        gateway: capturing_gateway(sent),
      ),
    )
    as "the boot must succeed"
  let assert Ok(Some(pinned)) = system_prompt.pinned(booted.instance.runtime)
    as "the boot must pin a system prompt"

  let assert Ok(_operation) =
    api.prompt(booted.instance.runtime, [
      message.UserMessage(
        content: [message.UserText(text: "hello", text_signature: None)],
        timestamp: 1,
        origin: None,
      ),
    ])
    as "the prompt must be accepted"
  let assert Ok(body) = process.receive(sent, within: 10_000)
    as "the gateway must have built a request"

  // The pinned bytes are what went out. Line by line, because the body is
  // JSON and the newlines inside the block are escaped there.
  list.each(string.split(pinned, on: "\n"), fn(line) {
    assert string.contains(body, line)
      as { "the system prompt line is missing from the wire: " <> line }
  })
  serve.shutdown(booted)
}

// A gateway whose transport hands the request it would have sent to a
// subject and then says nothing, so the operation stays in flight and the
// test owns the timing.
fn capturing_gateway(sent: Subject(String)) -> provider_gateway.Gateway {
  catalog.gateway(
    scripted_catalog(),
    transport: provider_test.transport(fn(request, _events) {
      process.send(sent, request.body)
    }),
    secrets: secret.from_list([#("ACME_KEY", "smoke-test-key")]),
    clock: clock.fixed(at: 0),
  )
}

// --- the host: what a death costs -------------------------------------------

/// A fatal tree death without its ledger cannot prove a clean provider drain.
///
/// The host still closes the listener and the rest of the stack, but it leaves
/// the lease to its TTL rather than letting a replacement overlap work whose
/// ownership record disappeared. Availability yields to the stream invariant.
///
/// The children this reaches are the ones a boot links to whichever
/// process ran it. Before the host existed that process was the one
/// waiting for `SIGTERM`, it did not trap exits, and the generated
/// runner above it turned the link into `init:stop(1)` with no cleanup at all.
pub fn a_fatal_drain_ledger_death_keeps_the_lease_test() {
  let fault_root = "build/serve-test-fault"
  let _stale = simplifile.delete(fault_root)
  let assert Ok(booted) = serve.boot(settings_under(fault_root))
    as "the server must boot"

  // The significant ledger is fatal by policy. Killing it directly makes the
  // absent-witness condition deterministic instead of racing the ledger's
  // orderly exit after a separately killed root.
  let assert Ok(ledger) =
    process.subject_owner(booted.instance.runtime.tree.drains)
  process.kill(ledger)

  let assert Ok(host.Faulted(child:, ..)) =
    process.receive(booted.instance.stops, within: 10_000)
    as "the host must report the fault rather than take the node with it"
  assert child == "the session tree"

  // Once both the root and its drain ledger are gone, no later caller can
  // prove whether detached provider work survived them. Failing closed keeps
  // the lease rather than overlapping an unverified predecessor.
  let assert Error(_) =
    session.open_sqlite(
      path: fault_root <> "/session.db",
      owner: "probe",
      lease_ttl_ms: 60_000,
      clock: clock.fixed(at: 0),
    )
    as "a missing drain witness must leave the lease held"
  let _sealed = session.close(booted.instance.runtime.session)

  // And the front door is shut: the teardown ran in full, not just far
  // enough to reach the lease.
  let base = "http://127.0.0.1:" <> int.to_string(booted.served.port)
  let assert Ok(health) = request.to(base <> "/healthz")
  assert httpc.send(health) |> result.is_error
    as "the listener must be closed once the host has torn the stack down"
}

/// The broker is captured by value, so its original process is a named fatal
/// child rather than a restartable service. Its death must report that exact
/// identity and release the writer lease through orderly host teardown.
pub fn a_linked_childs_death_releases_the_lease_test() {
  let fault_root = "build/serve-test-linked-fault"
  let _stale = simplifile.delete(fault_root)
  let assert Ok(booted) = serve.boot(settings_under(fault_root))
    as "the server must boot"

  let assert Ok(broker_pid) = broker.pid(booted.instance.broker)
    as "the broker must be alive"
  process.kill(broker_pid)

  let assert Ok(host.Faulted(child:, ..)) =
    process.receive(booted.instance.stops, within: 10_000)
    as "a linked child's death must be reported, not fatal by side effect"
  assert child == "the capability broker"

  let assert Ok(reopened) =
    session.open_sqlite(
      path: fault_root <> "/session.db",
      owner: "probe",
      lease_ttl_ms: 60_000,
      clock: clock.fixed(at: 0),
    )
    as "the writer lease must have been released, not left to its TTL"
  let _sealed = session.close(reopened)
}

/// The other half of the policy: the composition layer is supervised, so
/// a hub crash is a restart under the same name, not the end of the
/// server. The listener, the commit forwarder, and the provider tap all
/// address the hub by name, which is the whole reason this one can be
/// replaced in place — and the session is untouched, so the websocket
/// surface answers again.
pub fn a_hub_crash_restarts_rather_than_ending_the_server_test() {
  use serving, instance, incarnation, token <- with_daemon_instance
  let original_runtime = instance.runtime.tree.supervisor
  let runtime_monitor = process.monitor(original_runtime)
  let assert Ok(before) = addresses.owner(instance.gateway.name)
    as "the hub must be registered before the crash"
  process.kill(before)
  let assert poll.Answered(after) =
    poll.until(within: 2000, every: 5, attempt: fn() {
      case addresses.owner(instance.gateway.name) {
        Ok(pid) if pid != before -> poll.Done(pid)
        _ -> poll.Retry
      }
    })
    as "the hub must come back under the same name"
  assert after != before
  // The assembly owns its stop subject. This caller instead observes the
  // original runtime directly, without receiving another process's mailbox.
  assert process.new_selector()
    |> process.select_specific_monitor(runtime_monitor, fn(down) { down })
    |> process.selector_receive(250)
    == Error(Nil)
    as "a restartable child's crash must not stop the original runtime"
  process.demonitor_process(runtime_monitor)
  let id = ids.session_id_to_string(api.session_id(instance.runtime))
  let assert Ok(current) = manager.resolve(serving.ready.registry, id)
    as "hub recovery does not reopen or replace the admitted instance"
  assert current.runtime.tree.supervisor == original_runtime
  assert process.is_alive(original_runtime)
  let assert Ok(manager.View(status: manager.Resident(current_incarnation), ..)) =
    manager.get(serving.ready.registry, id)
    as "the same registry slot remains resident"
  assert current_incarnation == incarnation
  subscribed_cut(serving, current, incarnation, token)
}

/// A crash loop spends the service supervisor's restart budget, and then
/// the composition layer *is* fatal — but still orderly. "Restartable"
/// is a bounded promise, not an unbounded one.
pub fn an_unrecoverable_service_still_releases_the_lease_test() {
  let loop_root = "build/serve-test-service-loop"
  let _stale = simplifile.delete(loop_root)
  let assert Ok(booted) = serve.boot(settings_under(loop_root))
    as "the server must boot"

  // One kill more than the budget, each waiting for the replacement so
  // the intensity counter sees distinct restarts.
  kill_hub_repeatedly(
    booted,
    Ok(before_the_loop(booted)),
    serve.service_restart_intensity + 1,
  )

  let assert Ok(host.Faulted(child:, ..)) =
    process.receive(booted.instance.stops, within: 10_000)
    as "a spent restart budget must end the server, in order"
  assert child == "the service supervisor"

  let assert Ok(reopened) =
    session.open_sqlite(
      path: loop_root <> "/session.db",
      owner: "probe",
      lease_ttl_ms: 60_000,
      clock: clock.fixed(at: 0),
    )
    as "the writer lease must have been released, not left to its TTL"
  let _sealed = session.close(reopened)
}

fn before_the_loop(booted: serve.Booted) -> process.Pid {
  let assert Ok(pid) = settled_hub_pid(booted, 400)
    as "the hub must be registered before the crash loop"
  pid
}

// Kills the hub `times` over, each time waiting for the supervisor to
// put a *different* pid under the name, so every kill costs a restart
// rather than landing on a corpse.
fn kill_hub_repeatedly(
  booted: serve.Booted,
  current: Result(process.Pid, Nil),
  times: Int,
) -> Nil {
  case current, times <= 0 {
    _, True -> Nil
    Error(Nil), _ -> Nil
    Ok(pid), False -> {
      process.kill(pid)
      kill_hub_repeatedly(
        booted,
        replacement_hub_pid(booted, pid, 400),
        times - 1,
      )
    }
  }
}

// The pid under the hub's name once it is neither missing nor the one
// that was just killed.
fn replacement_hub_pid(
  booted: serve.Booted,
  before: process.Pid,
  attempts: Int,
) -> Result(process.Pid, Nil) {
  case hub_pid(booted) {
    Ok(pid) if pid != before -> Ok(pid)
    _ ->
      case attempts <= 0 {
        True -> Error(Nil)
        False -> {
          process.sleep(5)
          replacement_hub_pid(booted, before, attempts - 1)
        }
      }
  }
}

// The hub registers under a name the boot minted, so the only handle a
// test has on it is the gateway record the server holds.
fn hub_pid(booted: serve.Booted) -> Result(process.Pid, Nil) {
  addresses.owner(booted.instance.gateway.name)
}

// The pid once the supervisor has finished replacing it, or `Error(Nil)`
// if it never comes back.
fn settled_hub_pid(
  booted: serve.Booted,
  attempts: Int,
) -> Result(process.Pid, Nil) {
  case hub_pid(booted) {
    Ok(pid) -> Ok(pid)
    Error(Nil) ->
      case attempts <= 0 {
        True -> Error(Nil)
        False -> {
          process.sleep(5)
          settled_hub_pid(booted, attempts - 1)
        }
      }
  }
}

// --- the base policy the server refuses to boot on -------------------------

pub fn a_base_policy_the_sandbox_can_enforce_boots_test() {
  assert serve.base_policy_fault(serve.base_policy("/work")) == Ok(Nil)
}

// --- what the daemon masks under its state root ----------------------------

pub fn the_state_root_masks_name_the_secrets_and_not_the_root_test() {
  // The grain the shipped daemon got wrong. Masking `~/.loom` whole
  // denied reads over the working directory of a session opened on it,
  // and every jailed call came back `getcwd: cannot access parent
  // directories`. The list must therefore name what a jail must not
  // reach and stop there.
  let masks = serve.state_root_mask_candidates("/home/o/.loom")

  let secrets = [
    "/home/o/.loom/owner.token",
    "/home/o/.loom/tokens",
    "/home/o/.loom/sessions",
    "/home/o/.loom/catalogue.db",
    "/home/o/.loom/workspaces",
    "/home/o/.loom/domains",
    "/home/o/.loom/locks",
    "/home/o/.loom/daemon.lock",
    "/home/o/.loom/launch.lock",
    "/home/o/.loom/endpoints",
    "/home/o/.loom/daemon.endpoint",
  ]
  list.each(secrets, fn(entry) {
    assert list.contains(masks, entry) as { "masked: " <> entry }
  })

  // The root itself is not a mask, which is the whole of the fix, and
  // neither is anything an operator has a legitimate reason to edit.
  // The catalogues name environment variables; they hold no secret.
  let allowed = [
    "/home/o/.loom",
    "/home/o/.loom/loom.toml",
    "/home/o/.loom/loom-glm.toml",
    "/home/o/.loom/extensions",
    "/home/o/.loom/logs",
    "/home/o/.loom/daemon.log",
  ]
  list.each(allowed, fn(entry) {
    assert !list.contains(masks, entry) as { "not masked: " <> entry }
  })
}

pub fn the_state_root_masks_carry_the_sqlite_side_files_test() {
  // A write to `catalogue.db-wal` is the same forgery one filename to
  // the right: WAL frame checksums are not cryptographic, so a crafted
  // frame is served as content on the next read.
  let masks = serve.state_root_mask_candidates("/home/o/.loom")
  list.each(["-wal", "-shm", "-journal"], fn(suffix) {
    assert list.contains(masks, "/home/o/.loom/catalogue.db" <> suffix)
      as { "catalogue side file " <> suffix }
  })

  // The session databases have the same family, and their directory
  // mask covers all of it at once — a per-file enumeration there would
  // be a mask per session and could not be written as a function of the
  // root anyway.
  assert list.contains(masks, "/home/o/.loom/sessions")
}

pub fn a_workspace_on_the_state_root_is_a_policy_the_server_boots_on_test() {
  // The operator's case: a session opened on `~/.loom` to edit
  // `loom.toml`. The masks are composed exactly as `resolve_managed`
  // composes them, and the workspace survives.
  let base =
    serve.protecting_state_root(
      serve.base_policy("/home/o/.loom"),
      "/home/o/.loom",
    )
  assert serve.base_policy_fault(base) == Ok(Nil)

  // And the secrets are still masked from that session's jail, which is
  // the half the fix must not have traded away.
  assert list.contains(base.protected, "/home/o/.loom/owner.token")
  assert list.contains(base.protected, "/home/o/.loom/sessions")
}

pub fn a_workspace_equal_to_a_masked_entry_refuses_the_boot_test() {
  let base =
    serve.protecting_state_root(
      serve.base_policy("/home/o/.loom/sessions"),
      "/home/o/.loom",
    )
  let assert Error(reason) = serve.base_policy_fault(base)
    as "a workspace on the sessions directory refuses the boot"
  assert string.contains(reason, "/home/o/.loom/sessions")
  assert string.contains(reason, "Choose another directory")
}

pub fn a_workspace_under_a_masked_entry_refuses_the_boot_test() {
  // Under rather than equal, and the refusal must name the *entry* so
  // the operator knows which directory is the one they cannot have.
  let base =
    serve.protecting_state_root(
      serve.base_policy("/home/o/.loom/tokens/scratch"),
      "/home/o/.loom",
    )
  let assert Error(reason) = serve.base_policy_fault(base)
    as "a workspace under the tokens directory refuses the boot"
  assert string.contains(reason, "`/home/o/.loom/tokens`")
  assert string.contains(reason, "/home/o/.loom/tokens/scratch")
}

pub fn a_relative_protected_entry_refuses_the_boot_test() {
  // The finding this check exists for. A relative `protected` entry
  // normalizes to `/.git` in the harness's own path work, where it is
  // under no workspace and covers nothing — so the operator who wrote it
  // gets a session that protects nothing while reading as though it
  // does. The jail refuses the very same value (`policy.validate`), and
  // two enforcement points disagreeing is exactly what must not ship.
  // Refused at boot, before a directory is made or a helper is spawned,
  // because the alternative is learning about it from the first tool
  // call of a live session.
  let base =
    policy.SandboxPolicy(..serve.base_policy("/work"), protected: [".git"])
  let assert Error(reason) = serve.base_policy_fault(base)
    as "a relative protected entry refuses the boot"
  assert string.contains(reason, "base policy")
  assert string.contains(reason, ".git")
  assert string.contains(reason, "not absolute")
}

pub fn a_relative_writable_root_refuses_the_boot_test() {
  // Same check, the other kind of path: `validate` is one rule over
  // every path a policy names, and this server refuses on all of them
  // rather than on the one that prompted the check.
  let base =
    policy.SandboxPolicy(..serve.base_policy("/work"), writable_roots: [
      "work",
    ])
  let assert Error(reason) = serve.base_policy_fault(base)
    as "a relative writable root refuses the boot"
  assert string.contains(reason, "`work` is not absolute")
}

pub fn a_negative_limit_refuses_the_boot_naming_the_field_test() {
  let base = serve.base_policy("/work")
  let limits = policy.Limits(..base.limits, wall_s: -1)
  let assert Error(reason) =
    serve.base_policy_fault(policy.SandboxPolicy(..base, limits:))
    as "a negative limit refuses the boot"
  assert string.contains(reason, "wall_s")
  assert string.contains(reason, "cannot be negative")
}

pub fn a_scratch_of_the_host_root_refuses_the_boot_test() {
  let base =
    policy.SandboxPolicy(
      ..serve.base_policy("/work"),
      scratch: policy.ScratchPath(path: "/"),
    )
  let assert Error(reason) = serve.base_policy_fault(base)
    as "a scratch of the host root refuses the boot"
  assert string.contains(reason, "Landlock")
}

pub fn the_boot_itself_refuses_before_anything_is_spawned_test() {
  // Not just the pure check: `assemble` asks it first, so no session
  // file, no lease, no helper pool. The session path is one this test
  // has never created, and the refusal must be about the policy rather
  // than about the missing directory.
  let boot_root = "build/serve-test-policy-fault"
  let _stale = simplifile.delete(boot_root)
  let settings = settings_under(boot_root)
  let base =
    policy.SandboxPolicy(..settings.base_policy, protected: ["relative/entry"])
  let assert Error(reason) =
    serve.boot(serve.Settings(..settings, base_policy: base))
    as "the boot refuses a base policy the sandbox cannot enforce"
  assert string.contains(reason, "relative/entry")
  // Nothing was prepared: the check runs before `prepare_directories`.
  assert simplifile.is_directory(boot_root) == Ok(False)
}

// --- the triggered-rule scanner's presence (issue #27) ---------------------

const rules_root = "build/serve-test-rules"

// A server nobody configured rules for runs exactly the processes it ran
// before rules existed. Not a scanner holding an empty list: no scanner,
// and one log line saying so — the `codemode.unavailable` posture, for
// the same reason.
pub fn a_boot_with_no_rules_starts_no_scanner_test() {
  let _stale = simplifile.delete(rules_root)
  let assert Ok(booted) = serve.boot(settings_under(rules_root))
    as "the server must boot with no rules configured"
  assert booted.instance.rulescan == None
  serve.shutdown(booted)
}

// And a server that *was* configured runs one, under the restartable
// service supervisor, addressable by the name the writer subscribes to.
pub fn a_boot_with_rules_runs_a_supervised_scanner_test() {
  let _stale = simplifile.delete(rules_root <> "-on")
  let base = settings_under(rules_root <> "-on")
  let assert Ok(booted) =
    serve.boot(
      serve.Settings(..base, rules: [
        rules.Rule(
          name: "schema-gate",
          triggers: ["ALTER TABLE"],
          body: "Run the schema gate first.",
        ),
      ]),
    )
    as "the server must boot with a rule configured"
  let assert Some(name) = booted.instance.rulescan
    as "a configured rule must name a scanner"
  let assert Ok(_pid) = addresses.owner(name)
    as "the scanner must be registered under that name"
  serve.shutdown(booted)
}

const schedules_root = "build/serve-test-schedules"

// The same posture as rules: a server nobody configured schedules for
// starts no scanner at all.
pub fn a_boot_with_no_schedules_starts_no_scanner_test() {
  let _stale = simplifile.delete(schedules_root)
  let assert Ok(booted) = serve.boot(settings_under(schedules_root))
    as "the server must boot with no schedules configured"
  assert booted.instance.schedulescan == None
  serve.shutdown(booted)
}

// And a server that *was* configured runs one, under the restartable
// service supervisor, addressable by the name it registered under — not
// a writer subscriber, unlike the rule scanner, but still reached by
// name for the same restart-transparency reason.
pub fn a_boot_with_schedules_runs_a_supervised_scanner_test() {
  let _stale = simplifile.delete(schedules_root <> "-on")
  let base = settings_under(schedules_root <> "-on")
  let assert Ok(booted) =
    serve.boot(
      serve.Settings(..base, schedules: [
        schedule.Schedule(
          name: "heartbeat",
          target: "main",
          owner: schedule.OperatorOwned,
          timing: schedule.Interval(
            seconds: 300,
            expiry: schedule.Expiry(max_fires: 1000, expires_after_s: 604_800),
          ),
          wake: schedule.SteersOnly,
          body: "Check on things.",
        ),
      ]),
    )
    as "the server must boot with a schedule configured"
  let assert Some(name) = booted.instance.schedulescan
    as "a configured schedule must name a scanner"
  let assert Ok(_pid) = addresses.owner(name)
    as "the scanner must be registered under that name"
  serve.shutdown(booted)
}

// --- the operator's [tools] table (network egress, environment) -----------

// A `[tools]` table an operator opted in with: egress on, one name read
// from the host, one literal.
fn networked_tools() -> catalog.ToolsConfig {
  catalog.ToolsConfig(
    network: catalog.ToolNetworkFull,
    env: ["GH_TOKEN"],
    path: ["/opt/homebrew/bin"],
    set: [
      #("GH_CONFIG_DIR", "/home/me/.config/gh"),
    ],
  )
}

// A host environment with `GH_TOKEN` set and nothing else, so the skip
// path is exercised by a name that is genuinely absent rather than by
// one this machine happens not to have.
fn host_reading(name: String) -> Result(String, Nil) {
  case name {
    "GH_TOKEN" -> Ok("gho_secret")
    _other -> Error(Nil)
  }
}

pub fn the_tool_environment_appends_after_the_server_owned_names_test() {
  let #(environment, unset) =
    serve.tool_environment(
      "/work",
      None,
      networked_tools(),
      reading: host_reading,
    )
  assert environment
    == [
      #("PATH", "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"),
      #("HOME", "/work/.codemode/home"),
      #("TMPDIR", "/work/.codemode/tmp"),
      #("GH_TOKEN", "gho_secret"),
      #("GH_CONFIG_DIR", "/home/me/.config/gh"),
    ]
  assert unset == []
}

pub fn configured_path_entries_follow_the_servers_own_test() {
  // The toolchain and system directories stay in front, so the shell
  // resolves the same gleam the compiler does; the operator's directories
  // are where the rest of the host's tools live.
  let #(environment, _unset) =
    serve.tool_environment(
      "/work",
      Some("/tool/bin:/usr/bin:/bin"),
      networked_tools(),
      reading: fn(_name) { Error(Nil) },
    )
  let assert Ok(path) = list.key_find(environment, "PATH")
  assert path == "/tool/bin:/usr/bin:/bin:/opt/homebrew/bin"
}

pub fn an_unset_configured_name_is_skipped_and_reported_test() {
  // Skipped, not defaulted to the empty string: a `gh` handed
  // `GH_TOKEN=""` reads as logged out in a way no operator asked for.
  let tools =
    catalog.ToolsConfig(..networked_tools(), env: ["GH_TOKEN", "NO_SUCH_VAR"])
  let #(environment, unset) =
    serve.tool_environment("/work", None, tools, reading: host_reading)
  assert list.key_find(environment, "NO_SUCH_VAR") == Error(Nil)
  assert list.key_find(environment, "GH_TOKEN") == Ok("gho_secret")
  assert unset == ["NO_SUCH_VAR"]
}

pub fn the_default_tools_table_leaves_the_environment_alone_test() {
  let #(environment, unset) =
    serve.tool_environment(
      "/work",
      None,
      catalog.default_tools(),
      reading: host_reading,
    )
  assert environment == serve.session_environment("/work", None)
  assert unset == []
}

pub fn a_full_network_table_opens_the_base_policy_test() {
  // Both halves matter and neither implies the other: the network is
  // what the meet takes from the base, and the allowlist is what stops
  // the same meet dropping the names out of the shell's environment.
  let base = serve.base_policy("/work")
  assert base.network == policy.NetworkOff
  let opened = serve.under_tools_config(base, networked_tools())
  assert opened.network == policy.NetworkFull
  assert list.contains(opened.env_allow, "GH_TOKEN")
  assert list.contains(opened.env_allow, "GH_CONFIG_DIR")
  // Nothing else about the base moved.
  assert opened.writable_roots == base.writable_roots
  assert opened.protected == base.protected
}

pub fn the_default_tools_table_leaves_the_base_policy_offline_test() {
  let base = serve.base_policy("/work")
  let unchanged = serve.under_tools_config(base, catalog.default_tools())
  assert unchanged == base
}

const networked_root = "build/serve-test-network"

// The whole boot on an egress-on catalogue: the composed base policy is
// still one the sandbox can enforce, so the server comes up rather than
// refusing at `base_policy_fault`.
pub fn a_boot_with_full_network_configured_comes_up_test() {
  let _stale = simplifile.delete(networked_root)
  let base = settings_under(networked_root)
  let assert Ok(booted) =
    serve.boot(serve.Settings(..base, tools: networked_tools()))
    as "the server must boot with network egress configured"
  serve.shutdown(booted)
}

// --- the code-mode mount plan (#242) ---------------------------------------

// The two halves of one statement: the session base says what code mode
// may reach, `codemode/launch.node_requirements` says what a satellite
// needs, and composition takes the meet by path. These tests hold the two
// against each other, because a drift between them is not a compile
// error — it is a session in which every code-mode execution is refused.

fn a_toolchain() -> codemode.Toolchain {
  codemode.toolchain(
    gleam_path: "/opt/homebrew/bin/gleam",
    erl_path: "/usr/lib/erlang/bin/erl",
    seed_root: "/opt/loom/share/codemode-seed",
  )
}

pub fn the_base_admits_the_toolchain_as_mounts_test() {
  let admitted =
    serve.admitting_codemode(serve.base_policy("/work"), Ok(a_toolchain()))
  assert list.map(admitted.mounts, fn(mount) { mount.path })
    == ["/usr/lib/erlang", "/opt/loom/share/codemode-seed", "/opt/homebrew/bin"]
}

pub fn a_host_without_a_toolchain_admits_nothing_test() {
  // A host that registers no `code_mode` tool launches no satellite, so a
  // mount for it would be a region granted for nothing.
  let base = serve.base_policy("/work")
  assert serve.admitting_codemode(base, Error("no gleam on PATH")) == base
}

pub fn the_admitted_base_is_one_the_sandbox_can_enforce_test() {
  // `validate` refuses a mount that overlaps a `protected` entry, and the
  // session base protects the workspace's blob store. The toolchain lives
  // outside every workspace, so the two never meet; a policy that put
  // them in one region would fail the boot rather than this test, which is
  // why the check is worth stating here where the shape is visible.
  let admitted =
    serve.admitting_codemode(serve.base_policy("/work"), Ok(a_toolchain()))
  assert serve.base_policy_fault(admitted) == Ok(Nil)
}

pub fn the_base_and_the_node_compose_without_narrowing_test() {
  // The property the whole item rests on: the base carries exactly what
  // the launcher requires, so the meet is the requirements and no mount is
  // lost on the way into the jail.
  let mounts = codemode.toolchain_mounts(a_toolchain())
  let base =
    serve.admitting_codemode(serve.base_policy("/work"), Ok(a_toolchain()))
  let requirements = policy.SandboxPolicy(..base, mounts:)
  let #(effective, narrowings) =
    policy.compose(base:, requirements:, grants: [])
  assert narrowings == []
  assert effective.mounts == mounts
}

pub fn a_base_missing_a_toolchain_mount_refuses_the_node_test() {
  // The refusal an operator has to be able to act on. Without it a
  // narrowed base would produce a satellite that boots into a jail with no
  // ERTS tree and dies with nothing to read.
  let mounts = codemode.toolchain_mounts(a_toolchain())
  let base = serve.base_policy("/work")
  let requirements = policy.SandboxPolicy(..base, mounts:)
  let #(_effective, narrowings) =
    policy.compose(base:, requirements:, grants: [])
  assert list.length(narrowings) == 3
}

pub fn the_state_root_masks_do_not_meet_the_toolchain_mounts_test() {
  // The one shape that could refuse a boot: `validate` rejects a mount
  // overlapping a `protected` entry, and `resolve_managed` adds the
  // daemon's state-root masks to every session's base. They cannot
  // overlap, because every mask is a named path *under* the state root
  // and the toolchain lives in an install prefix, but the check is cheap
  // and the failure would be a daemon that refuses every session.
  let admitted =
    serve.base_policy("/work")
    |> serve.protecting_state_root("/home/o/.loom")
    |> serve.admitting_codemode(Ok(a_toolchain()))
  assert serve.base_policy_fault(admitted) == Ok(Nil)
}

pub fn a_hook_runs_under_the_assembled_session_base_test() {
  // The drift this holds shut: hooks fire on the harness's own timeline,
  // so their coordinates are built once at assembly rather than borrowed
  // from a run. Built from the settings' own policy they would carry
  // neither the toolchain mounts an extension node requires nor the
  // index, memory and worktree masks the session runs under, and every
  // hook-fired launch would meet three required mounts against an empty
  // base list and be refused.
  let settings = settings_under("hook-base")
  let assembled =
    settings.base_policy
    |> serve.protecting_index(settings.workspace <> "/.loom/index.sqlite")
    |> serve.admitting_codemode(Ok(a_toolchain()))
  assert assembled != settings.base_policy
  let at =
    serve.hook_coordinates(settings, assembled, 7, clock.fixed(at: 0), [])
  assert at.base_policy == assembled
}

pub fn a_toolchain_inside_the_state_root_refuses_the_boot_test() {
  // And the pathological arrangement is refused by name rather than
  // enforced differently on the two platforms: a seed unpacked inside the
  // daemon's own sessions directory is a mount over a mask.
  let inside =
    codemode.toolchain(
      gleam_path: "/opt/homebrew/bin/gleam",
      erl_path: "/usr/bin/erl",
      seed_root: "/home/o/.loom/sessions/seed",
    )
  let admitted =
    serve.base_policy("/work")
    |> serve.protecting_state_root("/home/o/.loom")
    |> serve.admitting_codemode(Ok(inside))
  assert serve.base_policy_fault(admitted) != Ok(Nil)
}

// --- the minimal jail root (protocol-change/020) ---------------------------

// The base view is no longer the whole host, so every region a session
// may reach is stated. These tests hold the three derivations against
// what they claim: the per-user toolchain set, the sibling checkouts a
// manifest names, and the operator's own `[workspace] mounts` line.

fn scratch_root(name: String) -> String {
  let assert Ok(cwd) = simplifile.current_directory()
    as "the test needs an absolute working directory"
  let root = cwd <> "/build/dev/minimal-root/" <> name
  let _stale = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
    as "the scratch root must be creatable"
  root
}

fn make(path: String) -> Nil {
  let assert Ok(Nil) = simplifile.create_directory_all(path)
    as "the fixture directory must be creatable"
  Nil
}

fn mount_paths(base: policy.SandboxPolicy) -> List(String) {
  list.map(base.mounts, fn(mount) { mount.path })
}

fn access_of(base: policy.SandboxPolicy, path: String) -> Result(_, Nil) {
  list.find(base.mounts, fn(mount) { mount.path == path })
  |> result.map(fn(mount) { mount.access })
}

pub fn the_user_toolchain_set_carries_only_what_exists_test() {
  let home = scratch_root("home")
  make(home <> "/.cargo/bin")
  make(home <> "/.cargo/registry")
  make(home <> "/.cache")
  make(home <> "/.local/bin")
  let base =
    serve.admitting_user_toolchains(
      policy.workspace_default("/work"),
      Some(home),
    )
  let paths = mount_paths(base)

  // Present directories are carried, and every one of them read-only.
  // The jail's `HOME` is under the workspace, so no build writes to the
  // operator's account and a read-write bind here would only have
  // exposed `~/.cache` to a session.
  assert list.contains(paths, home <> "/.cargo/bin")
  assert list.all(base.mounts, fn(mount) {
    mount.access == policy.MountReadOnly
  })
  assert access_of(base, home <> "/.cargo/registry") == Ok(policy.MountReadOnly)
  assert access_of(base, home <> "/.cache") == Ok(policy.MountReadOnly)

  // An absent directory is not a refusal and not an empty mount; it is
  // simply not there.
  assert !list.contains(paths, home <> "/.rustup")
  assert !list.contains(paths, home <> "/.pyenv")

  // Every user entry is optional, because an account that lacks one must
  // not fail a dispatch over it.
  assert list.all(base.mounts, fn(mount) {
    mount.requirement == policy.MountOptional
  })
}

pub fn the_cargo_split_is_two_siblings_and_never_a_nesting_test() {
  // `.cargo` holds the two directories a build has reason to reach and
  // others it has none. Naming the parent would bind whatever else an
  // operator keeps there, so the set names the children.
  assert !list.contains(serve.user_toolchain_readable, ".cargo")
  assert list.contains(serve.user_toolchain_readable, ".cargo/bin")
  assert list.contains(serve.user_toolchain_readable, ".cargo/registry")

  // `.local/share` holds keyrings and shell history and no toolchain, so
  // it is not in the set at any access.
  assert !list.contains(serve.user_toolchain_readable, ".local/share")

  // The shared set names only what the helper's own system roots leave
  // out. `/opt/homebrew` is in `DarwinSystemRoots` and `/nix/store` in
  // `SystemRoots`, so naming either here would only make a duplicate.
  assert serve.shared_toolchain_readable == ["/home/linuxbrew/.linuxbrew"]

  // No entry may cover another, in either set.
  let all = serve.user_toolchain_readable
  assert list.all(all, fn(entry) {
    list.all(all, fn(other) {
      entry == other
      || !policy.covers(root: "/h/" <> other, path: "/h/" <> entry)
    })
  })
}

pub fn a_home_the_host_does_not_have_yields_no_user_set_test() {
  // An account with no `HOME` is one this knows nothing about, which is
  // the empty answer rather than a refusal. The account-wide roots are
  // not derived from `HOME`, so whichever of them this host has is
  // admitted either way; nothing under a home directory is.
  let base = policy.workspace_default("/work")
  let admitted = serve.admitting_user_toolchains(base, None)
  assert list.all(mount_paths(admitted), fn(path) {
    list.contains(serve.shared_toolchain_readable, path)
  })
}

pub fn a_user_directory_under_a_mask_is_dropped_test() {
  // The mask is the half worth keeping: a cache an operator put under
  // the daemon's state root is a build that fails saying so, while a
  // mask that lost is a credential a session can read. `validate`
  // refuses the pair, so one of the two has to go before it sees them.
  let home = scratch_root("masked-home")
  make(home <> "/.cache")
  let base =
    policy.SandboxPolicy(..policy.workspace_default("/work"), protected: [
      home <> "/.cache",
    ])
  let admitted = serve.admitting_user_toolchains(base, Some(home))
  assert !list.contains(mount_paths(admitted), home <> "/.cache")
  assert policy.validate(admitted) == Ok(Nil)
}

pub fn a_sibling_path_dependency_is_mounted_read_only_test() {
  let root = scratch_root("siblings")
  let workspace = root <> "/checkout"
  make(workspace)
  make(root <> "/weft")
  let assert Ok(Nil) =
    simplifile.write(
      to: workspace <> "/gleam.toml",
      contents: "name = \"loom\"\n\n[dependencies]\nweft = { path = \"../weft\" }\ngleam_stdlib = \">= 0.60.0\"\n",
    )
    as "the manifest must be writable"
  let base =
    serve.widening_path_dependencies(
      policy.workspace_default(workspace),
      workspace,
    )
  assert mount_paths(base) == [root <> "/weft"]
  assert access_of(base, root <> "/weft") == Ok(policy.MountReadOnly)
  assert list.all(base.mounts, fn(mount) {
    mount.requirement == policy.MountOptional
  })
}

pub fn a_path_dependency_inside_the_workspace_is_not_mounted_test() {
  // The workspace is already the one region every session reaches, so a
  // manifest naming a sibling package of its own says nothing new.
  let root = scratch_root("intra")
  let workspace = root <> "/checkout"
  make(workspace <> "/packages/core")
  let assert Ok(Nil) =
    simplifile.write(
      to: workspace <> "/packages/core/gleam.toml",
      contents: "name = \"core\"\n\n[dev-dependencies]\nsibling = { path = \"../machine\" }\n",
    )
    as "the manifest must be writable"
  let base =
    serve.widening_path_dependencies(
      policy.workspace_default(workspace),
      workspace,
    )
  assert base.mounts == []
}

pub fn a_workspace_with_no_manifest_widens_nothing_test() {
  let root = scratch_root("bare")
  assert serve.path_dependencies(root) == []
}

pub fn configured_mounts_are_required_at_the_access_stated_test() {
  let base =
    serve.admitting_config_mounts(policy.workspace_default("/work"), [
      catalog.WorkspaceMount(path: "/srv/data", access: policy.MountReadOnly),
      catalog.WorkspaceMount(path: "/var/shared", access: policy.MountReadWrite),
    ])
  assert mount_paths(base) == ["/srv/data", "/var/shared"]
  assert access_of(base, "/var/shared") == Ok(policy.MountReadWrite)

  // Required, because nothing derives this list: a path an operator
  // wrote down is one the session was told it needs.
  assert list.all(base.mounts, fn(mount) {
    mount.requirement == policy.MountRequired
  })
  assert serve.base_policy_fault(base) == Ok(Nil)
}

pub fn a_configured_mount_over_a_mask_refuses_the_boot_test() {
  // Unlike a derived entry, a written one is not dropped: the operator
  // has to be told the server will not honour the line, and the refusal
  // names both halves.
  let base =
    policy.SandboxPolicy(..policy.workspace_default("/work"), protected: [
      "/state/secrets",
    ])
    |> serve.admitting_config_mounts([
      catalog.WorkspaceMount(
        path: "/state/secrets",
        access: policy.MountReadOnly,
      ),
    ])
  let assert Error(reason) = serve.base_policy_fault(base)
    as "a mount over a mask must refuse the boot"
  assert string.contains(reason, "/state/secrets")
}

// --- merging the assembled mounts ------------------------------------------

// Two derivations can land on the same directory without either being
// wrong, and `broker/policy.validate` refuses a repeated path. These
// tests hold the merge against the two host layouts that actually
// collided: a Linux box where `gleam` sits in `~/.local/bin`, and a
// Homebrew Mac where it is a link under `/opt/homebrew`.

pub fn a_toolchain_directory_the_user_set_also_names_merges_test() {
  // The Linux shape. `admitting_codemode` names `~/.local/bin` because
  // that is where `gleam` is; the per-user set names it because it is
  // one of the directories a version manager puts on `PATH`.
  let home = scratch_root("linux-home")
  make(home <> "/.local/bin")
  let base =
    serve.base_policy("/work")
    |> serve.admitting_user_toolchains(Some(home))
    |> serve.admitting_codemode(
      Ok(codemode.toolchain(
        gleam_path: home <> "/.local/bin/gleam",
        erl_path: "/usr/lib/erlang/bin/erl",
        seed_root: "/opt/loom/share/codemode-seed",
      )),
    )
  let assert Error(reason) = serve.base_policy_fault(base)
    as "the two derivations must collide before the merge"
  assert string.contains(reason, home <> "/.local/bin")

  let merged = serve.merging_mounts(base)
  assert policy.validate(merged) == Ok(Nil)
  assert list.count(mount_paths(merged), fn(path) {
      path == home <> "/.local/bin"
    })
    == 1

  // The toolchain's entry is `MountRequired`, so the surviving one is
  // too: a step that asks to fail closed on a missing source must not
  // lose that by sharing a path with the user set.
  let assert Ok(mount) =
    list.find(merged.mounts, fn(mount) { mount.path == home <> "/.local/bin" })
    as "the merged entry must be there"
  assert mount.requirement == policy.MountRequired
  assert mount.access == policy.MountReadOnly
}

pub fn the_homebrew_prefix_collides_with_the_shared_set_and_merges_test() {
  // The Homebrew shape. `gleam` is a link, so `toolchain_mounts` emits
  // the prefix beside the binary's directory, and the prefix is exactly
  // what `shared_toolchain_readable` names.
  let toolchain =
    codemode.Toolchain(
      gleam_path: "/opt/homebrew/bin/gleam",
      erl_path: "/opt/homebrew/bin/erl",
      seed_root: "/opt/loom/share/codemode-seed",
      gleam_prefix: "/opt/homebrew",
      erl_prefix: "/opt/homebrew",
      gleam_binary: codemode.GleamSymlink,
    )
  let shared =
    policy.Mount(
      path: "/opt/homebrew",
      access: policy.MountReadOnly,
      requirement: policy.MountOptional,
    )
  let base =
    policy.SandboxPolicy(..serve.base_policy("/work"), mounts: [shared])
    |> serve.admitting_codemode(Ok(toolchain))
  let assert Error(_reason) = serve.base_policy_fault(base)
    as "the prefix must collide before the merge"

  let merged = serve.merging_mounts(base)
  assert policy.validate(merged) == Ok(Nil)
  assert mount_paths(merged)
    == ["/opt/homebrew", "/opt/loom/share/codemode-seed"]
}

pub fn a_read_write_twin_at_a_toolchain_path_stays_read_only_test() {
  // Every toolchain region is read-only, so a read-write entry at
  // exactly a toolchain path would widen the toolchain. A directory a
  // build genuinely writes is named under the region instead.
  let base =
    policy.SandboxPolicy(..policy.workspace_default("/work"), mounts: [
      policy.Mount(
        path: "/opt/tools",
        access: policy.MountReadWrite,
        requirement: policy.MountOptional,
      ),
      policy.Mount(
        path: "/opt/tools",
        access: policy.MountReadOnly,
        requirement: policy.MountRequired,
      ),
    ])
  let merged = serve.merging_mounts(base)
  assert merged.mounts
    == [
      policy.Mount(
        path: "/opt/tools",
        access: policy.MountReadOnly,
        requirement: policy.MountRequired,
      ),
    ]
}

pub fn a_mount_inside_another_mount_is_not_a_duplicate_test() {
  // Nesting is two binds with different access on purpose. Collapsing
  // the child into its parent would give the wider access to the
  // narrower region.
  let base =
    policy.SandboxPolicy(..policy.workspace_default("/work"), mounts: [
      policy.Mount(
        path: "/h/.cargo/bin",
        access: policy.MountReadOnly,
        requirement: policy.MountOptional,
      ),
      policy.Mount(
        path: "/h/.cargo",
        access: policy.MountReadWrite,
        requirement: policy.MountOptional,
      ),
    ])
  assert serve.merging_mounts(base).mounts == base.mounts
}

pub fn a_full_user_set_beside_a_toolchain_validates_test() {
  // The whole assembly on a host that has every directory the user set
  // names and a `gleam` in one of them, which is the boot that failed.
  let home = scratch_root("full-home")
  list.each(serve.user_toolchain_readable, fn(entry) {
    make(home <> "/" <> entry)
  })
  let assert Ok(Nil) =
    simplifile.write(to: home <> "/.local/bin/gleam", contents: "")
    as "the fixture binary must be writable"
  let base =
    serve.base_policy("/work")
    |> serve.admitting_user_toolchains(Some(home))
    |> serve.admitting_codemode(
      Ok(codemode.toolchain(
        gleam_path: home <> "/.local/bin/gleam",
        erl_path: "/usr/lib/erlang/bin/erl",
        seed_root: "/opt/loom/share/codemode-seed",
      )),
    )
    |> serve.merging_mounts
  assert serve.base_policy_fault(base) == Ok(Nil)
}

pub fn the_workspace_table_parses_both_array_forms_test() {
  let assert Ok(inline) =
    catalog.parse_workspace(
      "[workspace]\nmounts = [{ path = \"/srv/a\", access = \"ro\" }]\n",
    )
    as "an inline mounts array must parse"
  assert inline.mounts
    == [catalog.WorkspaceMount(path: "/srv/a", access: policy.MountReadOnly)]

  let assert Ok(tables) =
    catalog.parse_workspace(
      "[[workspace.mounts]]\npath = \"/srv/b\"\naccess = \"rw\"\n",
    )
    as "an array of tables must parse the same way"
  assert tables.mounts
    == [catalog.WorkspaceMount(path: "/srv/b", access: policy.MountReadWrite)]
}

pub fn a_workspace_mount_line_that_says_nothing_usable_is_refused_test() {
  let relative =
    catalog.parse_workspace(
      "[workspace]\nmounts = [{ path = \"srv/a\", access = \"ro\" }]\n",
    )
  assert result.is_error(relative)

  let word =
    catalog.parse_workspace(
      "[workspace]\nmounts = [{ path = \"/srv/a\", access = \"read\" }]\n",
    )
  assert result.is_error(word)

  let repeated =
    catalog.parse_workspace(
      "[workspace]\nmounts = [{ path = \"/srv/a\", access = \"ro\" }, { path = \"/srv/a\", access = \"rw\" }]\n",
    )
  assert result.is_error(repeated)

  let unknown =
    catalog.parse_workspace(
      "[workspace]\nmounts = [{ path = \"/srv/a\", access = \"ro\", mode = \"x\" }]\n",
    )
  assert result.is_error(unknown)
}
