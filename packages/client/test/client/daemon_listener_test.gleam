//// The default host owns one real Mist listener through its daemon root.
//// These tests separate metadata restoration, explicit session admission, and
//// transitive listener retirement. Every socket and process wait is bounded.

import broker/token
import client/daemon/domain as domain_service
import client/daemon/main as entrypoint
import client/daemon/manager
import client/daemon/root
import client/internal/instance_owner as custody
import client/serve
import core/clock
import core/ids
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/response
import gleam/int
import gleam/list
import gleam/string
import host/bootstrap
import mist
import simplifile
import support/internal/ffi_daemon_socket as tcp
import support/internal/ffi_ws
import telemetry/log
import tui/daemon as control
import tui/daemon/protocol
import weft/poll

fn config() {
  let directory =
    "build/test_db/daemon-listener-"
    <> bit_array.base16_encode(token.production_entropy()(8))
  let assert Ok(config) = entrypoint.parse(["--state-dir", directory])
    as "fixture configuration resolves before resource acquisition"
  config
}

fn inert() {
  manager.Assembly(
    domain_build: fn(_, _, _) { Ok(domain_service.inert()) },
    build: fn(record, _domain, _services, _) { Ok(record.id) },
    fatal: fn(_) { [] },
  )
}

fn start(config: entrypoint.Config, assembly) {
  let assert Ok(daemon) =
    root.start(
      root.Config(config.state_root, config.owner_display_name, config.capacity),
      assembly,
    )
    as "root is prepared before filesystem or listener work"
  let assert Ok(serving) =
    entrypoint.listen(config, daemon, fn(_, _) {
      response.new(501)
      |> response.set_body(mist.Bytes(bytes_tree.from_string("inert fixture")))
    })
    as "root publishes and starts its sole real listener"
  serving
}

fn connect(serving: entrypoint.Serving(String)) {
  let assert Ok(token) = root.listener_credential(serving.daemon)
    as "host retains stable private credential"
  let address =
    "ws://127.0.0.1:" <> int.to_string(serving.listener.port) <> "/v2/control"
  let assert Ok(connection) =
    control.connect(address, token, process.self(), 2000)
    as "real authenticated control connection receives hello"
  connection
}

fn down(watch) {
  let assert Ok(down) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(15_000)
    as "original owner retires within the fixture deadline"
  down
}

fn port_closed(port) {
  let assert poll.Answered(Nil) =
    poll.until(within: 2000, every: 5, attempt: fn() {
      case
        tcp.connect(
          #(127, 0, 0, 1),
          port,
          [ffi_ws.Binary, ffi_ws.Active(False)],
          100,
        )
      {
        Error(_) -> poll.Done(Nil)
        Ok(socket) -> {
          ffi_ws.tcp_close(socket)
          poll.Retry
        }
      }
    })
    as "the original listening socket is closed, not merely its owner"
}

fn created(serving: entrypoint.Serving(String), key: String, seed: Int) {
  let assert Ok(view) =
    manager.create(
      serving.ready.registry,
      manager.Creation(key, serving.ready.state_root, key, ""),
      directory: serving.ready.sessions_directory,
      generator: ids.generator(clock.fixed(1000), seed),
    )
    as "only explicit creation starts session assembly"
  let assert poll.Answered(Nil) =
    poll.until(within: 2000, every: 2, attempt: fn() {
      case manager.get(serving.ready.registry, view.registration.id) {
        Ok(manager.View(status: manager.Resident(_), ..)) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "explicit creation becomes resident"
  view.registration.id
}

pub fn daemon_listener_restores_metadata_only_and_reuses_owner_token_test() {
  let config = config()
  let builds = process.new_subject()
  let assembly =
    manager.Assembly(
      domain_build: fn(_, _, _) { Ok(domain_service.inert()) },
      build: fn(record, _domain, _services, _) {
        process.send(builds, record.id)
        Ok(record.id)
      },
      fatal: fn(_) { [] },
    )
  let first = start(config, assembly)
  let socket = connect(first)
  let assert Ok(protocol.StatusReply(summary)) =
    control.request(socket, protocol.Status, 1000)
    as "default real listener answers authenticated status"
  assert summary.occupied == 0
  assert process.receive(builds, 0) == Error(Nil)
  let first_id = created(first, "first", 1)
  let second_id = created(first, "second", 2)
  assert first_id != second_id
  let assert Ok(manager.Summary(occupied: 2, resident: 2, ..)) =
    manager.summary(first.ready.registry)
    as "one daemon manages two independently admitted sessions"
  let token = root.listener_credential(first.daemon)
  let listener_watch = process.monitor(first.listener.supervisor)
  assert root.shutdown(first.daemon, within: 15_000) == Ok(Nil)
  let _ = down(listener_watch)
  port_closed(first.listener.port)
  control.close(socket)
  let _ = process.receive(builds, 1000)
  let _ = process.receive(builds, 1000)

  let restored = start(config, assembly)
  assert root.listener_credential(restored.daemon) == token
  assert restored.ready.epoch != first.ready.epoch
  let assert Ok(manager.View(status: manager.Saved, ..)) =
    manager.get(restored.ready.registry, first_id)
    as "restoration leaves the first session saved"
  let assert Ok(manager.View(status: manager.Saved, ..)) =
    manager.get(restored.ready.registry, second_id)
    as "restoration leaves the second session saved"
  assert process.receive(builds, 0) == Error(Nil)
  assert root.shutdown(restored.daemon, within: 15_000) == Ok(Nil)
}

pub fn daemon_listener_root_death_closes_original_socket_test() {
  let serving = start(config(), inert())
  let watch = process.monitor(serving.listener.supervisor)
  process.kill(root.pid(serving.daemon))
  let _ = down(watch)
  port_closed(serving.listener.port)
}

pub fn daemon_listener_abnormal_death_blocks_retirement_test() {
  let serving = start(config(), inert())
  let registry_watch = process.monitor(manager.pid(serving.ready.registry))
  process.kill(serving.listener.supervisor)
  let _ = down(registry_watch)
  let assert Error(_) = root.shutdown(serving.daemon, within: 1000)
    as "a killed listener cannot supply transitive retirement proof"
  assert bootstrap.try_launch_lock(serving.ready.state_root <> "/daemon.lock")
    == Error("busy")
  port_closed(serving.listener.port)
  process.kill(root.pid(serving.daemon))
}

pub fn daemon_listener_control_remains_available_during_session_drain_test() {
  let cleanup = process.new_subject()
  let serving =
    start(
      config(),
      manager.Assembly(
        domain_build: fn(_, _, _) { Ok(domain_service.inert()) },
        build: fn(record, _domain, _services, owner) {
          let assert Ok(Nil) =
            custody.publish(owner, custody.Storage, fn() {
              let permit = process.new_subject()
              process.send(cleanup, permit)
              let assert Ok(Nil) = process.receive(permit, 5000)
                as "fixture eventually permits retained cleanup"
              Ok(Nil)
            })
            as "cleanup is published before residency"
          Ok(record.id)
        },
        fatal: fn(_) { [] },
      ),
    )
  let id = created(serving, "drain", 1)
  let connection = connect(serving)
  let root_watch = process.monitor(root.pid(serving.daemon))
  root.request_shutdown(serving.daemon)
  let assert Ok(permit) = process.receive(cleanup, 2000)
    as "aggregate drain reaches the held session resource"
  let assert Ok(protocol.StatusReply(summary)) =
    control.request(connection, protocol.Status, 1000)
    as "an existing control socket reports drain progress"
  assert summary.occupied == 1
  let assert Error(control.Refused("unavailable", _)) =
    control.request(
      connection,
      protocol.SetDefault(serving.ready.state_root, id),
      1000,
    )
    as "drain status availability does not permit durable metadata mutation"
  let assert Error(_) = root.ready(serving.daemon, within: 1000)
    as "control progress does not reopen session ingress"
  process.send(permit, Nil)
  assert down(root_watch).reason == process.Normal
  port_closed(serving.listener.port)
  control.close(connection)
}

pub fn daemon_listener_normal_caller_exit_drains_listener_test() {
  let published = process.new_subject()
  let caller =
    process.spawn_unlinked(fn() {
      let release = process.new_subject()
      let serving = start(config(), inert())
      process.send(published, #(serving, release))
      let assert Ok(Nil) = process.receive(release, 5000)
        as "the test explicitly releases the daemon's initial caller"
      Nil
    })
  let assert Ok(#(serving, release)) = process.receive(published, 5000)
    as "listener readiness is published before caller retirement"
  let root_watch = process.monitor(root.pid(serving.daemon))
  let listener_watch = process.monitor(serving.listener.supervisor)
  let caller_watch = process.monitor(caller)
  process.send(release, Nil)
  assert down(caller_watch).reason == process.Normal
  assert down(root_watch).reason == process.Normal
  let _ = down(listener_watch)
  port_closed(serving.listener.port)
}

pub fn daemon_listener_rejects_legacy_route_and_competing_root_test() {
  let config = config()
  let serving = start(config, inert())
  let assert Ok(socket) =
    tcp.connect(
      #(127, 0, 0, 1),
      serving.listener.port,
      [ffi_ws.Binary, ffi_ws.Active(False)],
      1000,
    )
    as "raw client connects"
  assert tcp.send(
      socket,
      bit_array.from_string("GET /v1/ws HTTP/1.1\r\nHost: localhost\r\n\r\n"),
    )
    == Ok(Nil)
  let assert Ok(bytes) = ffi_ws.tcp_receive(socket, 12, 1000)
    as "legacy route responds within deadline"
  assert bytes == <<"HTTP/1.1 404":utf8>>
  ffi_ws.tcp_close(socket)
  let assert Ok(second) =
    root.start(root.Config(config.state_root, "Another", 8), inert())
    as "competing root remains prepared until lock attempt"
  assert root.ready(second, within: 5000) == Error("busy")
  assert root.shutdown(second, within: 5000) == Ok(Nil)
  assert root.shutdown(serving.daemon, within: 15_000) == Ok(Nil)
}

pub fn daemon_listener_cli_and_workspace_domains_test() {
  let assert Error(_) = entrypoint.parse(["--read-scope", "workspce"])
    as "a misspelled restriction must not enable host reads"
  let assert Error(_) = entrypoint.parse(["--network", "of"])
    as "a misspelled restriction must not enable network access"
  let assert Error(_) = entrypoint.parse(["--read-scope"])
    as "a missing restriction argument must be refused"
  let assert Error(_) = entrypoint.parse(["--network"])
    as "a missing network argument must be refused"
  let assert Error(_) = entrypoint.parse(["--session", "old.db"])
    as "per-session CLI is not a compatibility mode"
  let assert Error(_) = entrypoint.parse(["--bind", "0.0.0.0:9000"])
    as "cleartext public binding is refused"
  let assert Error(_) = entrypoint.parse(["--capacity", "0"])
    as "invalid admission capacity is refused before startup"
  let assert Ok(config) =
    entrypoint.parse(["--bind", "[::1]:0", "--state-dir", "/private/loom"])
    as "explicit IPv6 loopback is accepted"
  assert config.bind_host == "::1"
  let a = serve.workspace_data_root(config.state_root, "/project/a")
  let b = serve.workspace_data_root(config.state_root, "/project/b")
  assert a != b
  assert a == serve.workspace_data_root(config.state_root, "/project/a")
  assert string.starts_with(a, "/private/loom/workspaces/")
  assert string.byte_size(a)
    == string.byte_size("/private/loom/workspaces/") + 64
}

pub fn daemon_listener_production_prepare_is_lazy_test() {
  let config =
    entrypoint.Config(..config(), session_defaults: [
      "--helper", "/missing/loom-exec", "--config", "/missing/loom.toml",
    ])
  let assert Ok(daemon) = entrypoint.prepare(config, log.discard())
    as "default assembly is prepared without resolving missing session inputs"
  let assert Ok(serving) =
    entrypoint.listen(config, daemon, fn(_, _) {
      response.new(501) |> response.set_body(mist.Bytes(bytes_tree.new()))
    })
    as "missing session helper/config do not prevent empty daemon readiness"
  let assert Ok(manager.Summary(occupied: 0, ..)) =
    manager.summary(serving.ready.registry)
    as "production startup opens no runtime"
  assert simplifile.is_directory(serving.ready.state_root <> "/workspaces")
    == Ok(False)
  assert root.shutdown(daemon, within: 15_000) == Ok(Nil)
}

pub fn daemon_listener_production_opens_two_owned_sessions_test() {
  let config = config()
  let assert Ok(here) = simplifile.current_directory()
    as "fixture has a working directory"
  let helper = here <> "/../../bin/loom-exec"
  let workspace = config.state_root <> "-workspace"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(workspace)
    as "workspace is separate from the daemon's protected state"
  let file = workspace <> "/loom.toml"
  assert simplifile.write(
      file,
      "[models.fixture]\ndialect = \"anthropic\"\nbase_url = \"https://unused.invalid\"\napi_key_env = \"LOOM_UNUSED_DAEMON_FIXTURE_KEY\"\nmodel_id = \"fixture\"\ncontext_window = 100000\nmax_output_tokens = 4096\n[roles]\nmain = [\"fixture\"]\n[memory]\ndistill = \"off\"\n",
    )
    == Ok(Nil)
  let config =
    entrypoint.Config(..config, session_defaults: [
      "--helper",
      helper,
      "--best-effort",
    ])
  let assert Ok(daemon) = entrypoint.prepare(config, log.discard())
    as "real production assembly is retained before startup"
  let assert Ok(serving) =
    entrypoint.listen(config, daemon, fn(_, _) {
      response.new(501) |> response.set_body(mist.Bytes(bytes_tree.new()))
    })
    as "real production daemon serves before either explicit open"
  let records = [#("first", 1), #("second", 2)]
  let ids =
    list.map(records, fn(pair) {
      let assert Ok(view) =
        manager.create(
          serving.ready.registry,
          manager.Creation(pair.0, workspace, pair.0, file),
          directory: serving.ready.sessions_directory,
          generator: ids.generator(clock.fixed(1000), pair.1),
        )
        as "the real entrypoint admits explicit creation"
      view.registration.id
    })
  let assert poll.Answered(Nil) =
    poll.until(within: 20_000, every: 10, attempt: fn() {
      case manager.summary(serving.ready.registry) {
        Ok(manager.Summary(resident: 2, ..)) -> poll.Done(Nil)
        Ok(manager.Summary(blocked: blocked, ..)) if blocked > 0 ->
          poll.Fail("assembly blocked")
        _ -> poll.Retry
      }
    })
    as "one production daemon hosts two real owned runtimes"
  assert list.all(ids, fn(id) {
    bootstrap.path_exists(
      serving.ready.sessions_directory <> "/" <> id <> ".db",
    )
  })
  assert root.shutdown(daemon, within: 30_000) == Ok(Nil)
  port_closed(serving.listener.port)
}
