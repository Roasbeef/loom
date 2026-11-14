//// `executors.reload` with real links (protocol-change/115).
////
//// A registry that starts real `untrusted_link` processes holds a row for one
//// executor, and a session attaches through it. The file then gains a second
//// row, and `executors.reload` over a real control socket answers `started`
//// for the second and `unchanged` for the first. The first link's process is
//// the same one afterwards, so the session attached through it is undisturbed,
//// and a session attaches through the second link and runs a call.
////
//// Both gateways admit the same orchestrator certificate, because one
//// `[executor_link]` table is all a daemon presents; they differ in port.

import client/daemon/limits
import client/daemon/main
import client/daemon/untrusted_links
import client/daemon_server_test as wire
import client/deployment
import client/executors
import client/internal/ffi_os
import client/remote/host
import client/remote/owner_port
import client/remote/protocol
import client/remote/remote_census.{type RemoteCensus}
import client/remote/surface
import client/remote/untrusted_gateway
import client/remote/untrusted_link
import client/session_directory
import client/session_movers
import core/clock
import core/json
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import simplifile
import support/remote_fixtures as fixtures
import support/remote_orchestrator
import support/untrusted_rig as rig
import telemetry/log
import tools/codemode as codemode_tool

// A plane that answers every call as the fixtures expect, with no callbacks.
fn plane_factory() -> host.PlaneFactory(RemoteCensus) {
  let census = remote_orchestrator.census(remote_orchestrator.standard_tools())
  fn(_spec: host.AttachSpec) {
    Ok(host.Plane(
      run: fn(run, _authority) { fixtures.expected_outcome(run) },
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

// An executor host behind a gateway that admits `pair`'s orchestrator.
fn gateway_for(
  pair: rig.Pair,
) -> #(remote_orchestrator.Executor, untrusted_gateway.Gateway) {
  let executor = remote_orchestrator.start_holding(plane_factory(), 67_108_864)
  let assert Ok(gateway) =
    untrusted_gateway.start(untrusted_gateway.Config(
      address: "127.0.0.1",
      port: 0,
      credentials: pair.executor,
      orchestrators: [pair.orchestrator_pin],
      host: executor.address,
      blobs: None,
      logger: log.discard(),
    ))
    as "the gateway starts"
  #(executor, gateway)
}

// A state directory holding the orchestrator's credentials where `loom vm up`
// keeps them, so a daemon that started with no table accepts the file's.
fn state_with(pair: rig.Pair) -> #(String, String) {
  let state = "build/test_db/" <> unique("reload-e2e")
  let assert Ok(Nil) = bootstrap.ensure_private_directory(state)
    as "the state directory exists"
  let assert Ok(absolute) = bootstrap.absolute_path(state)
    as "the state directory resolves"
  let vm = absolute <> "/vm"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(vm)
    as "the vm directory exists"
  let copy = fn(from: String, name: String) {
    let assert Ok(text) = simplifile.read(from) as "the credential is read"
    let assert Ok(Nil) = simplifile.write(vm <> "/" <> name, text)
      as "the credential is copied"
    Nil
  }
  copy(pair.orchestrator.ca, "ca.pem")
  copy(pair.orchestrator.certificate, "c.pem")
  copy(pair.orchestrator.key, "k.pem")
  #(absolute, vm)
}

fn unique(label: String) -> String {
  label <> "-" <> int.to_string(ffi_os.unique_positive_integer())
}

fn file_text(vm: String, pin: BitArray, rows: List(#(String, Int))) -> String {
  let table =
    "[executor_link]\nca = \""
    <> vm
    <> "/ca.pem\"\ncertificate = \""
    <> vm
    <> "/c.pem\"\nkey = \""
    <> vm
    <> "/k.pem\"\n"
  let hex = bit_array.base16_encode(pin) |> string.lowercase
  table
  <> string.join(
    list.map(rows, fn(row) {
      "[executors."
      <> row.0
      <> "]\ntrust = \"untrusted\"\naddress = \"127.0.0.1:"
      <> int.to_string(row.1)
      <> "\"\npin = \""
      <> hex
      <> "\"\n"
    }),
    "",
  )
}

fn attached(
  name: String,
  port: owner_port.Port,
) -> surface.Attachment(RemoteCensus) {
  let link = untrusted_link.name_for(name)
  let assert Ok(attachment) =
    surface.attach(
      surface.Config(
        address: untrusted_link.address(link),
        session: "s-" <> name,
        workspace: "/work",
        incarnation: 0,
        port:,
        read_authority: fn(_run) { Ok(fixtures.authority()) },
        reconnect: fn() { untrusted_link.running(link, name) },
        remote_tools: ["bash", codemode_tool.tool_name],
        attach_within_ms: 10_000,
        mint_token: surface.strong_token,
        attached: fn(_attached) { Nil },
      ),
    )
    as "the attach succeeds over the link"
  attachment
}

pub fn a_row_added_by_a_reload_serves_while_the_first_link_stays_test() {
  let pair = rig.pair("reload")
  let #(executor_a, gateway_a) = gateway_for(pair)
  let #(executor_b, gateway_b) = gateway_for(pair)
  let a = unique("reload-a")
  let b = unique("reload-b")
  let #(state, vm) = state_with(pair)
  let path = state <> "/loom.toml"
  let first = file_text(vm, pair.executor_pin, [#(a, gateway_a.port)])
  let assert Ok(Nil) = simplifile.write(path, first) as "the file is written"

  let assert Ok(owner) =
    owner_port.start(owner_port.Config(
      services: fixtures.quiet_services(),
      clock: clock.fixed(at: 1000),
      settled: fn(_key) { False },
      reconcile_every_ms: 60_000,
      executions: owner_port.Executions(
        launch: fn(_terms, _link) { Error("no launch here") },
        interact: fn(_strand, _handle, _interaction, _within) {
          Error("no interaction here")
        },
        standing: fn(_key) { owner_port.RecordLive },
      ),
      mcp: protocol.empty_mcp_plan(),
      git_identity: None,
    ))
    as "the owner port starts"

  // The registry starts real links, and its first reconcile is the daemon's
  // start over the file as it is.
  let assert Ok(registry) =
    untrusted_links.start(
      untrusted_links.production(log.discard()),
      log.discard(),
    )
    as "the registry starts"
  let assert Ok(rows) = executors.parse(first) as "the file's rows decode"
  let assert Ok(_) =
    untrusted_links.reconcile(registry, fn() {
      Ok(untrusted_links.Wanted(rows:, credentials: Some(pair.orchestrator)))
    })
    as "the first reconcile applies"

  let surface.Attachment(surface: first_surface, ..) = attached(a, owner)
  let run = fixtures.tool_run("first", 0)
  assert surface.run(first_surface, run) == fixtures.expected_outcome(run)
  let assert Ok(before) = process_named(a) as "the first link holds its name"

  let assert Ok(parsed) = main.parse(["--state-dir", state])
    as "the flags parse"
  let config = main.Config(..parsed, links: Some(registry))
  wire.fixture_with_reload(
    limits.defaults,
    fn(_) { None },
    fn(record, _domain, _services, _owner, _directory) { Ok(record.id) },
    session_directory.none(),
    session_movers.idle(),
    deployment.alone("nonode@nohost"),
    None,
    main.executors_reload_for(config, path),
    fn(_daemon, _ready, port, credential) {
      let assert Ok(Nil) =
        simplifile.write(
          path,
          file_text(vm, pair.executor_pin, [
            #(a, gateway_a.port),
            #(b, gateway_b.port),
          ]),
        )
        as "the file gains a row"
      let #(socket, _) = wire.connect(port, credential, "/v2/control")
      let _hello = wire.frame(socket, within_ms: 1000)
      let reply =
        wire.send(
          socket,
          1,
          "executors.reload",
          json.Object([]),
          within_ms: 6000,
        )
      let assert json.Object(fields) = reply as "the reply is an object"
      let assert Ok(body) = list.key_find(fields, "body") as "a body"
      assert fields |> list.key_find("event")
        == Ok(json.String("executors.reload"))
      assert json.to_string(body)
        == "{\"executors\":[{\"name\":\""
        <> a
        <> "\",\"change\":\"unchanged\"},{\"name\":\""
        <> b
        <> "\",\"change\":\"started\"}]}"

      // The first link is the process it was, and the second serves a call.
      assert process_named(a) == Ok(before)
      let surface.Attachment(surface: second_surface, ..) = attached(b, owner)
      let second = fixtures.tool_run("second", 0)
      assert surface.run(second_surface, second)
        == fixtures.expected_outcome(second)
    },
  )

  // The first session's surface still answers through the link it began on.
  let again = fixtures.tool_run("again", 1)
  assert surface.run(first_surface, again) == fixtures.expected_outcome(again)
  remote_orchestrator.stop(executor_a)
  remote_orchestrator.stop(executor_b)
}

fn process_named(name: String) {
  process.named(untrusted_link.name_for(name))
}
