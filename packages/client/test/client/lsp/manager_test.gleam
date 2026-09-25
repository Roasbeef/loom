//// The session's language-server manager and its door.
////
//// Four layers, cheapest first. The pure rules of `client/lsp/resolve`
//// (splitting a qualified symbol, the qualifier's reach, containers, the
//// search bounds). The enforcement probe, driven with a scripted broker
//// runner, so a degraded jail is provable on a host that has none. The
//// manager's process story over an in-process fake server
//// (`support/fake_lsp`): one start however many callers, eviction, a lazy
//// restart that re-opens what the dead server held, the pull-resync, the
//// containment refusal and the ambiguous answer. And the real thing: a
//// `gleam lsp` jailed through the broker on a two-module project, and a
//// `gopls` on a two-package module when one is installed, both under
//// `BestEffort` so they run on a host with no delegated cgroup. Their
//// projects live under this package's `build/`, never `/tmp`, which the
//// jail replaces with a tmpfs of its own.

import broker/broker
import broker/exec
import broker/policy
import broker/token
import client/catalog
import client/internal/ffi_os
import client/lsp/jail
import client/lsp/leases
import client/lsp/manager
import client/lsp/resolve
import core/clock
import core/ids
import core/json
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/result
import gleam/string
import lsp/protocol
import lsp/query
import lsp/range
import provider/secret
import simplifile
import support/fake_lsp
import tools/tool
import weft/poll

// --- fixtures ------------------------------------------------------------------

fn here() -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner must have a working directory"
  here
}

// A fresh workspace under this package's `build/`, removed by the caller.
fn scratch(tag: String) -> String {
  let root =
    here()
    <> "/build/lsp-manager-"
    <> tag
    <> "-"
    <> int.to_string(ffi_os.system_time_ms())
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let assert Ok(Nil) = simplifile.create_directory_all(root)
    as "the scratch workspace must be made"
  root
}

fn write(path: String, text: String) -> Nil {
  let assert Ok(Nil) = simplifile.create_directory_all(dirname(path))
    as "a fixture directory must be made"
  let assert Ok(Nil) = simplifile.write(path, text)
    as "a fixture file must be written"
  Nil
}

fn fake_server() -> catalog.LspServer {
  catalog.LspServer(
    name: "fake",
    command: ["/bin/false"],
    extensions: [".gleam"],
    root_markers: ["gleam.toml"],
    project: catalog.ProjectReadOnly,
    readable: [],
    writable: [],
    env: [],
  )
}

fn quick_timing() -> manager.Timing {
  manager.Timing(
    ..manager.default_timing(),
    start_ms: 5000,
    request_ms: 2000,
    settle_ms: 500,
    stop_grace_ms: 500,
    previous_ms: 3000,
  )
}

// A rig over fake servers: `connect` makes a new fake per start and tells
// the test which root it started and the fake it made.
type Rig {
  Rig(
    manager: manager.Manager,
    door: query.Door,
    starts: Subject(#(String, fake_lsp.Fake)),
  )
}

fn rig(
  workspace: String,
  search: fn(manager.Search) -> Result(List(manager.Hit), String),
  script: fn(String, option.Option(json.JsonValue)) -> fake_lsp.Answer,
) -> Rig {
  let starts = process.new_subject()
  let connect = fn(identity: resolve.Identity) {
    let fake = fake_lsp.start(fake_lsp.everything(), script)
    process.send(starts, #(identity.root, fake))
    Ok(fake_lsp.seam(fake))
  }
  let assert Ok(started) =
    manager.start(manager.Config(
      workspace:,
      servers: [fake_server()],
      backend: manager.Backend(connect:, search:),
      timing: quick_timing(),
    ))
    as "the manager must start"
  Rig(manager: started, door: manager.door(started), starts:)
}

fn no_search(_search: manager.Search) -> Result(List(manager.Hit), String) {
  Ok([])
}

// Every start the rig has made so far, oldest first.
fn started(rig: Rig) -> List(#(String, fake_lsp.Fake)) {
  drain(rig.starts, [])
}

fn drain(subject: Subject(a), into: List(a)) -> List(a) {
  case process.receive(subject, 0) {
    Ok(item) -> drain(subject, [item, ..into])
    Error(Nil) -> list.reverse(into)
  }
}

// One outline entry named `greet` on the first line, which is what every
// fake script below answers a `documentSymbol` with.
fn greet_outline() -> json.JsonValue {
  let at = fn(line, character) {
    json.Object([
      #("line", json.Int(line)),
      #("character", json.Int(character)),
    ])
  }
  json.Array([
    json.Object([
      #("name", json.String("greet")),
      #("kind", json.Int(12)),
      #("range", json.Object([#("start", at(0, 0)), #("end", at(2, 1))])),
      #(
        "selectionRange",
        json.Object([#("start", at(0, 7)), #("end", at(0, 12))]),
      ),
    ]),
  ])
}

fn outline_script(
  method: String,
  _params: option.Option(json.JsonValue),
) -> fake_lsp.Answer {
  case method {
    "textDocument/documentSymbol" -> fake_lsp.Answer(greet_outline())
    _ -> fake_lsp.Answer(json.Null)
  }
}

fn project(workspace: String, name: String) -> String {
  let root = workspace <> "/" <> name
  write(root <> "/gleam.toml", "name = \"" <> name <> "\"\n")
  write(root <> "/src/a.gleam", "pub fn greet() -> String {\n  \"hi\"\n}\n")
  root
}

fn uri(path: String) -> String {
  let assert Ok(uri) = protocol.path_to_uri(path)
    as "a fixture path is absolute"
  uri
}

// --- (a) the pure rules --------------------------------------------------------

pub fn a_qualified_symbol_splits_into_qualifier_and_identifier_test() {
  assert resolve.split_symbol("greet") == resolve.Symbol("greet", None)
  assert resolve.split_symbol("probe.greet")
    == resolve.Symbol("greet", Some("probe"))
  assert resolve.split_symbol("pkg/mod.name")
    == resolve.Symbol("name", Some("pkg/mod"))
  assert resolve.split_symbol("a.b.c") == resolve.Symbol("c", Some("a/b"))
  assert resolve.split_symbol("..") == resolve.Symbol("..", None)
}

pub fn a_qualifier_matches_a_module_path_or_a_directory_test() {
  assert resolve.satisfies("/w", "/w/src/probe.gleam", "probe")
  assert resolve.satisfies("/w", "/w/util/util.go", "util")
  assert resolve.satisfies("/w", "/w/src/pkg/mod.gleam", "pkg/mod")
  assert !resolve.satisfies("/w", "/w/src/probe.gleam", "robe")
  assert !resolve.satisfies("/w", "/w/src/other.gleam", "probe")
}

pub fn the_container_is_the_innermost_entry_qualified_by_its_parents_test() {
  let span = fn(a, b, c, d) {
    range.Range(range.Position(a, b), range.Position(c, d))
  }
  let symbols =
    protocol.Hierarchical([
      protocol.DocumentSymbol(
        name: "Server",
        kind: 5,
        detail: None,
        range: span(0, 0, 10, 0),
        selection_range: span(0, 5, 0, 11),
        children: [
          protocol.DocumentSymbol(
            name: "handle",
            kind: 6,
            detail: None,
            range: span(2, 2, 5, 3),
            selection_range: span(2, 6, 2, 12),
            children: [],
          ),
        ],
      ),
    ])
  assert resolve.container(symbols, range.Position(3, 4))
    == Some("Server.handle")
  assert resolve.container(symbols, range.Position(7, 0)) == Some("Server")
  assert resolve.container(symbols, range.Position(12, 0)) == None
  assert resolve.named(
      symbols,
      "handle",
      Some("Server"),
      root: "/w",
      path: "/w/x.gleam",
    )
    == [#("Server.handle", range.Position(2, 6))]
  assert resolve.named(
      symbols,
      "handle",
      Some("Other"),
      root: "/w",
      path: "/w/x.gleam",
    )
    == []
}

pub fn paths_display_relative_to_the_workspace_test() {
  assert resolve.display(["/work"], "/work/src/a.gleam") == "src/a.gleam"
  assert resolve.display(["/work"], "/workspace/a.gleam")
    == "/workspace/a.gleam"
  assert resolve.extension_of("src/App.Gleam") == ".gleam"
  assert resolve.extension_of("Makefile") == ""
  assert resolve.compare(range.Position(1, 0), range.Position(0, 9)) == order.Gt
}

pub fn a_search_keeps_its_hit_and_file_bounds_test() {
  let many =
    list.flat_map(
      int.range(from: 1, to: 81, with: [], run: fn(acc, i) { [i, ..acc] })
        |> list.reverse,
      fn(file) {
        list.map(
          int.range(from: 1, to: 11, with: [], run: fn(acc, i) { [i, ..acc] })
            |> list.reverse,
          fn(line) { manager.Hit(path: "/w/f" <> int.to_string(file), line:) },
        )
      },
    )
  let kept = manager.bounded_hits(many)
  assert list.length(kept) <= manager.max_search_hits
  assert list.length(list.unique(list.map(kept, fn(hit) { hit.path })))
    <= manager.max_search_files
  assert list.take(kept, 1) == [manager.Hit("/w/f1", 1)]
}

// --- (b) the enforcement probe --------------------------------------------------

fn probe_session_base(workspace: String) -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    ..policy.workspace_default(workspace),
    readable_roots: ["/"],
    network: policy.NetworkFull,
    env_allow: ["PATH", "HOME", "TMPDIR"],
  )
}

fn degraded() -> broker.CallOutcome {
  broker.CallFailed(
    exec.DegradedExecution(exec.ExecResult(
      code: 0,
      signal: 0,
      stdout_bytes: 0,
      stderr_bytes: 0,
      stdout_truncated: False,
      stderr_truncated: False,
      enforcement: ["bwrap", "skip:cgroup"],
      degraded: True,
      wall_ms: 3,
      timed_out: False,
      cancelled: False,
    )),
  )
}

fn clean() -> broker.CallOutcome {
  broker.CallExited(exec.ExecResult(
    code: 0,
    signal: 0,
    stdout_bytes: 0,
    stderr_bytes: 0,
    stdout_truncated: False,
    stderr_truncated: False,
    enforcement: ["bwrap", "cgroup"],
    degraded: False,
    wall_ms: 3,
    timed_out: False,
    cancelled: False,
  ))
}

// A broker runner that records every clearance and settles each with
// `outcome` at once.
fn scripted_run(
  cleared: Subject(broker.CallSpec),
  outcome: broker.CallOutcome,
) -> fn(broker.CallSpec, Subject(broker.CallEvent)) ->
  Result(tool.RunningCall, broker.Refusal) {
  fn(spec, events) {
    process.send(cleared, spec)
    process.send(events, broker.CallSettled(outcome:))
    Ok(tool.RunningCall(stdin: fn(_data, _eof) { Nil }, cancel: fn() { Nil }))
  }
}

fn probe_jailed(
  workspace: String,
  run: fn(broker.CallSpec, Subject(broker.CallEvent)) ->
    Result(tool.RunningCall, broker.Refusal),
  demand: exec.EnforcementDemand,
) -> manager.Jailed {
  let assert Ok(counter) = leases.start(exec.min_pool_size)
    as "the lease counter must start"
  manager.Jailed(
    workspace:,
    session_base: probe_session_base(workspace),
    demand:,
    toolchain: None,
    home: None,
    reading: fn(name) {
      case name {
        "PATH" -> Ok("/usr/bin:/bin")
        _ -> Error(Nil)
      }
    },
    run:,
    abort_step: fn(_step) { Nil },
    leases: counter,
    op_id: op(),
    clock: clock.fixed(0),
    exec_ms: 2000,
  )
}

fn shell_server() -> catalog.LspServer {
  catalog.LspServer(..fake_server(), name: "shell", command: ["/bin/sh"])
}

pub fn a_degraded_probe_refuses_the_server_naming_the_layer_test() {
  let workspace = scratch("probe")
  let root = project(workspace, "app")
  let cleared = process.new_subject()
  let jailed =
    probe_jailed(
      workspace,
      scripted_run(cleared, degraded()),
      exec.PlatformEnforcement,
    )
  let identity = resolve.Identity(server: shell_server(), root:)

  // The probe is the only clearance: a server whose jail could not be
  // proven is never dispatched, so no lease is held for it either.
  let assert Error(reason) = manager.connect_jailed(jailed, identity)
    as "a degraded probe must refuse the server"
  assert string.contains(reason, "skip:cgroup")
  let assert [spec] = drain(cleared, []) as "only the probe may be cleared"
  assert spec.argv == manager.probe_argv
  assert spec.demand == exec.PlatformEnforcement
  assert string.ends_with(spec.step_id, "/probe")
  let _ = simplifile.delete_all([workspace])
  Nil
}

pub fn a_clean_probe_clears_the_server_under_the_session_demand_test() {
  let workspace = scratch("probe-clean")
  let root = project(workspace, "app")
  let cleared = process.new_subject()
  let jailed =
    probe_jailed(workspace, scripted_run(cleared, clean()), exec.BestEffort)
  let identity = resolve.Identity(server: shell_server(), root:)
  let assert Ok(_transport) = manager.connect_jailed(jailed, identity)
    as "a clean probe must let the server start"
  let assert [spec] = drain(cleared, [])
    as "only the probe is cleared before the transport connects"
  assert spec.demand == exec.BestEffort
  let _ = simplifile.delete_all([workspace])
  Nil
}

// --- (c) the manager over a fake server ------------------------------------------

pub fn one_start_serves_every_caller_who_asked_during_it_test() {
  let workspace = scratch("one-start")
  let _root = project(workspace, "app")
  let rig = rig(workspace, no_search, outline_script)
  let answers = process.new_subject()
  list.each([1, 2, 3], fn(_) {
    process.spawn(fn() {
      process.send(answers, rig.door.outline("app/src/a.gleam"))
    })
  })
  let replies =
    list.map([1, 2, 3], fn(_) {
      let assert Ok(reply) = process.receive(answers, 10_000)
        as "every caller must be answered"
      reply
    })
  list.each(replies, fn(reply) {
    let assert Ok(served) = reply as "every caller must be served"
    assert served.warmth == query.Started("fake")
    let assert [entry] = served.value as "the outline has one entry"
    assert entry.site
      == query.Site("app/src/a.gleam", 1, 8, "pub fn greet() -> String {")
  })
  assert list.length(started(rig)) == 1

  // The fourth caller finds it running.
  let assert Ok(served) = rig.door.outline("app/src/a.gleam")
    as "a warm server must answer"
  assert served.warmth == query.Warm
  manager.stop(rig.manager)
  let _ = simplifile.delete_all([workspace])
  Nil
}

pub fn a_path_whose_real_location_leaves_the_root_is_refused_test() {
  let workspace = scratch("containment")
  let root = project(workspace, "app")
  write(workspace <> "/elsewhere/x.gleam", "pub fn x() { 1 }\n")
  let assert Ok(Nil) =
    simplifile.create_symlink(
      to: workspace <> "/elsewhere/x.gleam",
      from: root <> "/src/link.gleam",
    )
    as "the fixture link must be made"
  let rig = rig(workspace, no_search, outline_script)
  let assert Error(query.NoServer(reason)) =
    rig.door.outline("app/src/link.gleam")
    as "a file outside the server's root must be refused"
  assert string.contains(reason, "outside the server's root")
  assert started(rig) == []

  // The write observer is told nothing about it either.
  assert rig.door.after_write("app/src/link.gleam") == None
  assert rig.door.after_write("notes.md") == None
  manager.stop(rig.manager)
  let _ = simplifile.delete_all([workspace])
  Nil
}

pub fn two_distinct_definitions_are_ambiguous_and_a_qualifier_narrows_test() {
  let workspace = scratch("ambiguous")
  let root = project(workspace, "app")
  write(root <> "/src/b.gleam", "pub fn greet() -> String {\n  \"yo\"\n}\n")

  // Each hit is its own definition: two modules each define `greet`.
  let search = fn(_search: manager.Search) {
    Ok([
      manager.Hit(root <> "/src/a.gleam", 1),
      manager.Hit(root <> "/src/b.gleam", 1),
    ])
  }
  let script = fn(method, params) {
    case method, params {
      "textDocument/definition", Some(json.Object(fields)) ->
        case list.key_find(fields, "textDocument") {
          Ok(json.Object(document)) ->
            case list.key_find(document, "uri") {
              Ok(json.String(asked)) ->
                fake_lsp.Answer(fake_lsp.location(asked, 0, 7))
              _ -> fake_lsp.Answer(json.Null)
            }
          _ -> fake_lsp.Answer(json.Null)
        }
      _, _ -> outline_script(method, params)
    }
  }
  let rig = rig(workspace, search, script)

  // A path-scoped question starts the server, so the bare ones below
  // search its root.
  let assert Ok(_) = rig.door.outline("app/src/a.gleam")
    as "the server must start"
  let assert Error(query.Ambiguous(candidates)) =
    rig.door.definition(query.SymbolQuery("greet", None, None))
    as "two definitions must be ambiguous, never a guess"
  assert list.map(candidates, fn(site) { site.path })
    == ["app/src/a.gleam", "app/src/b.gleam"]
  let assert Ok(served) =
    rig.door.definition(query.SymbolQuery("b.greet", None, None))
    as "a qualifier must pick the module"
  assert list.map(served.value, fn(site) { #(site.path, site.line) })
    == [#("app/src/b.gleam", 1)]
  let assert Error(query.NotFound(_)) =
    rig.door.definition(query.SymbolQuery("c.greet", None, None))
    as "a qualifier nothing satisfies finds nothing"
  manager.stop(rig.manager)
  let _ = simplifile.delete_all([workspace])
  Nil
}

pub fn a_document_edited_behind_the_servers_back_is_resent_test() {
  let workspace = scratch("resync")
  let root = project(workspace, "app")
  write(root <> "/src/c.gleam", "pub fn c() { 1 }\n")
  let rig = rig(workspace, no_search, outline_script)
  let assert Ok(_) = rig.door.outline("app/src/a.gleam") as "outline a"
  let assert Ok(_) = rig.door.outline("app/src/c.gleam") as "outline c"
  let assert [#(_, fake)] = started(rig) as "one start"

  // `bash` rewrites one open document and deletes the other.
  write(
    root <> "/src/a.gleam",
    "// moved\npub fn greet() -> String {\n  \"hi\"\n}\n",
  )
  let assert Ok(Nil) = simplifile.delete(root <> "/src/c.gleam")
    as "the fixture file must be deleted"
  let assert Ok(_) = rig.door.outline("app/src/a.gleam") as "outline again"
  let seen = fake_lsp.seen(fake)
  assert list.any(seen, fn(entry) {
    case entry {
      fake_lsp.Sent("textDocument/didChange", Some(params)) ->
        string.contains(json.to_string(params), "// moved")
      _ -> False
    }
  })
  assert list.any(seen, fn(entry) {
    case entry {
      fake_lsp.Sent("textDocument/didClose", Some(params)) ->
        string.contains(json.to_string(params), uri(root <> "/src/c.gleam"))
      _ -> False
    }
  })
  manager.stop(rig.manager)
  let _ = simplifile.delete_all([workspace])
  Nil
}

pub fn a_dead_server_restarts_on_next_use_and_reopens_its_documents_test() {
  let workspace = scratch("restart")
  let root = project(workspace, "app")
  write(root <> "/src/b.gleam", "pub fn b() { 1 }\n")
  let rig = rig(workspace, no_search, outline_script)
  let assert Ok(_) = rig.door.outline("app/src/a.gleam") as "first start"
  let assert [#(_, first)] = started(rig) as "one start"
  fake_lsp.die(first, "the fake server crashed")

  // Nothing restarts it until somebody asks; the ask that does says so.
  let outcome =
    poll.until(within: 5000, every: 20, attempt: fn() {
      case rig.door.outline("app/src/b.gleam") {
        Ok(served) -> poll.Done(served)
        Error(query.Unavailable(_)) -> poll.Retry
        Error(other) -> poll.Fail(other)
      }
    })
  let assert poll.Answered(served) = outcome as "the next use must restart it"
  assert served.warmth == query.Started("fake")
  let assert [#(_, second)] = started(rig) as "exactly one restart"

  // The document the dead server held is re-opened before the question.
  let methods = fake_lsp.methods(second)
  let assert Ok(first_symbol) =
    list.index_map(methods, fn(method, at) { #(method, at) })
    |> list.key_find("textDocument/documentSymbol")
    as "the restarted server was asked"
  assert list.any(list.take(fake_lsp.seen(second), first_symbol), fn(entry) {
    case entry {
      fake_lsp.Sent("textDocument/didOpen", Some(params)) ->
        string.contains(json.to_string(params), uri(root <> "/src/a.gleam"))
      _ -> False
    }
  })
  manager.stop(rig.manager)
  let _ = simplifile.delete_all([workspace])
  Nil
}

pub fn a_file_in_another_project_evicts_the_running_server_test() {
  let workspace = scratch("evict")
  let one = project(workspace, "one")
  let two = project(workspace, "two")
  let rig = rig(workspace, no_search, outline_script)
  let assert Ok(_) = rig.door.outline("one/src/a.gleam") as "start one"
  let assert Ok(served) = rig.door.outline("two/src/a.gleam") as "start two"
  assert served.warmth == query.Started("fake")
  let assert [#(first_root, first), #(second_root, _)] = started(rig)
    as "two starts, in order"
  assert first_root == one
  assert second_root == two

  // The evicted server was stopped politely, and before the second started
  // nothing overlapped: the new keeper waited for the old one to exit.
  let methods = fake_lsp.methods(first)
  assert list.contains(methods, "shutdown")
  assert list.contains(methods, "exit")
  assert list.contains(methods, "<close>")
  manager.stop(rig.manager)
  let _ = simplifile.delete_all([workspace])
  Nil
}

pub fn after_write_pushes_only_to_a_running_owner_test() {
  let workspace = scratch("after-write")
  let _root = project(workspace, "app")
  let rig = rig(workspace, no_search, outline_script)

  // No server is running: the edit costs nothing and starts nothing.
  assert rig.door.after_write("app/src/a.gleam") == None
  assert started(rig) == []

  let assert Ok(_) = rig.door.outline("app/src/a.gleam") as "start"
  let assert [#(_, fake)] = started(rig) as "one start"
  let assert Some(query.Settled([])) = rig.door.after_write("app/src/a.gleam")
    as "a running owner settles"
  assert list.contains(fake_lsp.methods(fake), "textDocument/didChange")
  manager.stop(rig.manager)
  let _ = simplifile.delete_all([workspace])
  Nil
}

// --- (d) the real servers, jailed ------------------------------------------------

type Live {
  Live(
    root: String,
    workspace: String,
    pool: exec.Pool,
    broker: broker.Broker,
    counter: leases.Leases,
  )
}

fn live_prerequisites(label: String) -> Result(String, Nil) {
  let skip = fn(reason) {
    io.println_error("SKIP " <> label <> ": " <> reason)
    Error(Nil)
  }
  case exec.unjailed_skip_reason(exec.host_platform()) {
    Some(reason) -> skip(reason)
    None -> {
      let helper = here() <> "/../../bin/loom-exec"
      case simplifile.is_file(helper) {
        Ok(True) -> Ok(helper)
        _absent -> skip("no loom-exec at " <> helper <> "; run `make binaries`")
      }
    }
  }
}

fn live_base(workspace: String) -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    ..policy.workspace_default(workspace),
    writable_roots: [workspace],
    readable_roots: [workspace],
    network: policy.NetworkFull,
    env_allow: ["PATH"],
  )
}

fn wall_clock() -> clock.Clock {
  clock.from_function(ffi_os.system_time_ms)
}

fn op() -> ids.OpId {
  jail.operation(clock.fixed(1000), seed: 7)
}

fn live_rig(helper: String, tag: String) -> Live {
  let root = scratch(tag)
  let workspace = root <> "/ws"
  let assert Ok(Nil) = simplifile.create_directory_all(workspace <> "/home")
    as "the live home must be made"
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/helper-tmp")
    as "the helper's temporary directory must be made"
  let base = live_base(workspace)
  let assert Ok(pool) =
    exec.start_pool(size: exec.min_pool_size, spawn: fn() {
      exec.spawn_helper(exec.SpawnConfig(
        helper_path: helper,
        shell_path: "/bin/sh",
        base_policy: base,
        helper_args: [],
        tmp_dir: root <> "/helper-tmp",
        handshake_timeout_ms: 5000,
        cancel_grace_ms: 3000,
        heartbeat_interval_ms: 0,
      ))
    })
    as "the helper pool must start"
  let assert Ok(broker_actor) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: wall_clock(),
        checkout: fn() { exec.checkout(pool, waiting: 20_000) },
        checkin: fn(helper) { exec.checkin(pool, helper) },
      ),
    )
    as "the broker must start"
  let assert Ok(counter) = leases.start(exec.min_pool_size)
    as "the lease counter must start"
  Live(root:, workspace:, pool:, broker: broker_actor, counter:)
}

fn live_manager(
  live: Live,
  servers: List(catalog.LspServer),
  reading: fn(String) -> Result(String, Nil),
) -> manager.Manager {
  let lsp_op = op()
  let jailed =
    manager.Jailed(
      workspace: live.workspace,
      session_base: live_base(live.workspace),
      demand: exec.BestEffort,
      toolchain: None,
      home: Some(live.workspace <> "/home"),
      reading:,
      run: tool.broker_runner(
        broker: live.broker,
        waiting: jail.clearance_wait_ms,
      ),
      abort_step: fn(step) {
        broker.abort_step(live.broker, lsp_op, step_id: step)
      },
      leases: live.counter,
      op_id: lsp_op,
      clock: wall_clock(),
      exec_ms: 20_000,
    )
  let assert Ok(started) =
    manager.start(manager.Config(
      workspace: live.workspace,
      servers:,
      backend: manager.jailed(jailed),
      timing: manager.default_timing(),
    ))
    as "the live manager must start"
  started
}

fn stop_live(live: Live, running: manager.Manager) -> Nil {
  manager.stop(running)

  // The keeper stops the server after `stop` returns; the lease coming
  // back is the witness that it has.
  let _ =
    poll.until(within: 15_000, every: 50, attempt: fn() {
      case leases.held(live.counter, waiting: 1000) {
        Ok(0) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
  broker.stop(live.broker)
  exec.stop_pool(live.pool)
  leases.stop(live.counter)
  let _ = simplifile.delete_all([live.root])
  Nil
}

fn sites(served: query.Served(List(query.Site))) -> List(#(String, Int)) {
  list.map(served.value, fn(site) { #(site.path, site.line) })
}

const probe_source = "pub fn greet() -> String {\n  \"hi\"\n}\n"

const other_source = "import probe\n\npub fn twice() -> String {\n  probe.greet() <> probe.greet()\n}\n"

pub fn gleam_lsp_answers_the_door_from_inside_the_jail_test() {
  case
    live_prerequisites("lsp manager gleam lsp"),
    ffi_os.find_executable("gleam")
  {
    Error(Nil), _ -> Nil
    Ok(_), Error(_) ->
      io.println_error("SKIP lsp manager gleam lsp: gleam is not on PATH")
    Ok(helper), Ok(_) -> run_gleam(live_rig(helper, "gleam"))
  }
}

fn run_gleam(live: Live) -> Nil {
  let project = live.workspace <> "/probe"
  write(
    project <> "/gleam.toml",
    "name = \"probe\"\nversion = \"1.0.0\"\ntarget = \"erlang\"\n\n[dependencies]\n",
  )
  write(project <> "/src/probe.gleam", probe_source)
  write(project <> "/src/other.gleam", other_source)
  let server =
    catalog.LspServer(
      name: "gleam",
      command: ["gleam", "lsp"],
      extensions: [".gleam"],
      root_markers: ["gleam.toml"],
      project: catalog.ProjectWritable,
      readable: [],
      writable: [],
      env: [],
    )
  let running =
    live_manager(live, [server], fn(name) {
      case name {
        "PATH" -> Ok("/usr/local/bin:/usr/bin:/bin")
        _ -> Error(Nil)
      }
    })
  let door = manager.door(running)
  let probe_path = "probe/src/probe.gleam"
  let other_path = "probe/src/other.gleam"

  // A bare name, asked before any server runs: the workspace is searched,
  // the one project found, its server started, and both call sites in
  // `other` resolve to the one definition.
  let assert Ok(served) =
    door.definition(query.SymbolQuery("greet", None, None))
    as "a bare symbol must resolve"
  io.println_error(
    "lsp manager gleam lsp: definition " <> string.inspect(served),
  )
  assert sites(served) == [#(probe_path, 1)]
  assert served.warmth == query.Started("gleam")

  let assert Ok(served) =
    door.definition(query.SymbolQuery("probe.greet", None, None))
    as "a qualified symbol must resolve"
  assert sites(served) == [#(probe_path, 1)]
  assert served.warmth == query.Warm
  let assert Error(query.NotFound(_)) =
    door.definition(query.SymbolQuery("nowhere.greet", None, None))
    as "a qualifier no file satisfies finds nothing"

  // References across files, each with the symbol that contains it.
  let assert Ok(served) =
    door.references(query.SymbolQuery("greet", Some(probe_path), Some(1)))
    as "references must answer"
  io.println_error(
    "lsp manager gleam lsp: references " <> string.inspect(served),
  )
  let in_other =
    list.filter(served.value, fn(reference) {
      reference.site.path == other_path
    })
  assert list.length(in_other) == 2
  assert list.all(in_other, fn(reference) {
    reference.container == Some("twice") && reference.site.line == 4
  })

  let assert Ok(served) =
    door.hover(query.SymbolQuery("greet", Some(probe_path), Some(1)))
    as "hover must answer"
  assert string.contains(served.value.contents, "String")

  let assert Ok(served) = door.outline(probe_path) as "outline must answer"
  assert list.map(served.value, fn(entry) { entry.name }) == ["greet"]
  let assert [entry] = served.value as "one entry"
  assert entry.site.line == 1

  // A rename is prepared, never written, and its edited texts are exactly
  // the renamed sources.
  let assert Ok(served) =
    door.prepare_rename(
      query.SymbolQuery("greet", Some(probe_path), Some(1)),
      "salute",
    )
    as "a rename must be prepared"
  let files =
    list.sort(served.value, fn(a, b) { string.compare(a.path, b.path) })
  let assert [other_edit, probe_edit] = files as "two files change"
  assert other_edit.path == other_path
  assert other_edit.base == other_source
  assert other_edit.edited == string.replace(other_source, "greet", "salute")
  assert other_edit.edits == 2
  assert probe_edit.edited == string.replace(probe_source, "greet", "salute")
  let assert Ok(on_disk) = simplifile.read(project <> "/src/probe.gleam")
    as "the source must still read"
  assert on_disk == probe_source

  // The outline above opened `probe.gleam`. Two lines pushed in front of
  // the definition behind the server's back must move the answer: the
  // pull re-sends the text before the question is asked.
  write(project <> "/src/probe.gleam", "// one\n// two\n" <> probe_source)
  let assert Ok(served) =
    door.definition(query.SymbolQuery("greet", Some(other_path), Some(4)))
    as "the definition must answer after the edit"
  assert sites(served) == [#(probe_path, 3)]

  // Post-edit diagnostics: a breaking edit settles with the error, and the
  // fix settles without it.
  write(
    project <> "/src/other.gleam",
    string.replace(other_source, "probe.greet() <>", "probe.nothing() <>"),
  )
  let assert Some(query.Settled(broken)) =
    door.after_write(project <> "/src/other.gleam")
    as "a breaking edit must settle"
  io.println_error("lsp manager gleam lsp: broken " <> string.inspect(broken))
  assert list.any(broken, fn(diagnostic) {
    diagnostic.site.path == other_path
    && diagnostic.severity == query.SeverityError
  })
  write(project <> "/src/other.gleam", other_source)
  let assert Some(query.Settled(fixed)) = door.after_write(other_path)
    as "the fix must settle"
  io.println_error("lsp manager gleam lsp: fixed " <> string.inspect(fixed))
  assert !list.any(fixed, fn(diagnostic) {
    diagnostic.severity == query.SeverityError
  })
  stop_live(live, running)
}

pub fn gopls_answers_the_door_from_inside_the_jail_test() {
  // `go install` puts gopls in `~/go/bin`, which is on few PATHs.
  let installed =
    secret.lookup(secret.env(), "HOME")
    |> result.map(fn(home) { home <> "/go/bin/gopls" })
    |> result.unwrap("/nonexistent/gopls")
  let gopls = result.unwrap(ffi_os.find_executable("gopls"), installed)
  case
    live_prerequisites("lsp manager gopls"),
    simplifile.is_file(gopls),
    ffi_os.find_executable("go")
  {
    Error(Nil), _, _ -> Nil
    Ok(_), Ok(True), Ok(go) -> run_gopls(live_rig_for_go(), gopls, go)
    Ok(_), _, _ ->
      io.println_error("SKIP lsp manager gopls: gopls or go is not installed")
  }
}

fn live_rig_for_go() -> Live {
  let assert Ok(helper) = live_prerequisites("lsp manager gopls")
    as "checked by the caller"
  live_rig(helper, "gopls")
}

fn run_gopls(live: Live, gopls: String, go: String) -> Nil {
  let module = live.workspace <> "/gomod"
  write(module <> "/go.mod", "module example.com/m\n\ngo 1.21\n")
  write(
    module <> "/util/util.go",
    "package util\n\n// Greet says hi.\nfunc Greet() string {\n\treturn \"hi\"\n}\n",
  )
  write(
    module <> "/main.go",
    "package main\n\nimport \"example.com/m/util\"\n\nfunc main() {\n\tprintln(util.Greet())\n}\n",
  )
  let cache = live.workspace <> "/gocache"
  let gopath = live.workspace <> "/gopath"
  let assert Ok(Nil) = simplifile.create_directory_all(cache) as "cache dir"
  let assert Ok(Nil) = simplifile.create_directory_all(gopath) as "gopath dir"
  let go_bin = dirname(go)
  let server =
    catalog.LspServer(
      name: "gopls",
      command: [gopls],
      extensions: [".go"],
      root_markers: ["go.mod"],
      project: catalog.ProjectReadOnly,
      readable: [],
      writable: [catalog.AbsolutePath(cache), catalog.AbsolutePath(gopath)],
      env: ["GOCACHE", "GOPATH", "GOFLAGS", "GOTOOLCHAIN", "GOPROXY"],
    )
  let running =
    live_manager(live, [server], fn(name) {
      case name {
        "PATH" -> Ok(go_bin <> ":/usr/local/bin:/usr/bin:/bin")
        "GOCACHE" -> Ok(cache)
        "GOPATH" -> Ok(gopath)
        "GOFLAGS" -> Ok("-mod=mod")
        "GOTOOLCHAIN" -> Ok("local")
        "GOPROXY" -> Ok("off")
        _ -> Error(Nil)
      }
    })
  let door = manager.door(running)
  let util_path = "gomod/util/util.go"

  let assert Ok(served) =
    door.definition(query.SymbolQuery("util.Greet", None, None))
    as "a qualified Go symbol must resolve"
  io.println_error("lsp manager gopls: definition " <> string.inspect(served))
  assert sites(served) == [#(util_path, 4)]
  assert served.warmth == query.Started("gopls")

  let assert Ok(served) =
    door.references(query.SymbolQuery("Greet", Some(util_path), Some(4)))
    as "references must answer"
  assert list.any(served.value, fn(reference) {
    reference.site.path == "gomod/main.go"
    && reference.container == Some("main")
  })

  let assert Ok(served) =
    door.hover(query.SymbolQuery("Greet", Some(util_path), Some(4)))
    as "hover must answer"
  assert string.contains(served.value.contents, "string")

  let assert Ok(served) =
    door.prepare_rename(
      query.SymbolQuery("Greet", Some(util_path), Some(4)),
      "Hello",
    )
    as "a rename must be prepared"
  let edited =
    list.map(served.value, fn(edit) { #(edit.path, edit.edited) })
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  let assert [#("gomod/main.go", main_text), #(util_edited, util_text)] = edited
    as "two files change"
  assert util_edited == util_path
  assert string.contains(main_text, "util.Hello()")
  assert string.contains(util_text, "func Hello() string")
  stop_live(live, running)
}

fn dirname(path: String) -> String {
  let parts = string.split(path, "/")
  string.join(list.take(parts, list.length(parts) - 1), "/")
}
