//// The session's language-server manager and its door.
////
//// Four layers, cheapest first. The pure rules of `client/lsp/resolve`
//// (splitting a qualified symbol, the qualifier's reach, containers, the
//// search bounds). The enforcement probe, driven with a scripted broker
//// runner, so a degraded jail is provable on a host that has none. The
//// manager's process story over an in-process fake server
//// (`support/fake_lsp`): one start however many callers, eviction, a lazy
//// restart that re-opens what the dead server held, the pull-resync, the
//// containment refusal, the ambiguous answer and the wait for a server
//// still loading. And the real thing: a `gleam lsp` jailed through the
//// broker on a two-module project, a `gopls` on a two-package module and
//// a `rust-analyzer` on a two-file crate when they are installed, all under
//// `BestEffort` so they run on a host with no delegated cgroup. Their
//// projects live under this package's `build/`, never `/tmp`, which the
//// jail replaces with a tmpfs of its own.

import broker/broker
import broker/exec
import broker/policy
import broker/token
import client/internal/ffi_os
import client/lsp/jail
import client/lsp/leases
import client/lsp/manager
import client/lsp/profile
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
import gleam/otp/static_supervisor as sup
import gleam/result
import gleam/string
import lsp/protocol
import lsp/query
import lsp/range
import mcp/transport
import provider/secret
import simplifile
import support/fake_lsp
import tools/tool
import weft/poll
import weft/registry as address

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

fn fake_server() -> profile.LspServer {
  profile.LspServer(
    name: "fake",
    command: ["/bin/false"],
    extensions: [".gleam"],
    root_markers: ["gleam.toml"],
    project: profile.ProjectReadOnly,
    readable: [],
    writable: [],
    env: [],
    cache_env: [],
    language_id: "gleam",
    qualifier_separators: ["."],
    module_case: profile.AsWritten,
    hint: None,
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
  rig_with(workspace, search, script, fn(_method, _params) { [] })
}

// A rig whose fakes also publish what `notifier` names. The session's
// protected list holds the `app` project's `.git`, as a session base
// policy's does for the workspace's own.
fn rig_with(
  workspace: String,
  search: fn(manager.Search) -> Result(List(manager.Hit), String),
  script: fn(String, option.Option(json.JsonValue)) -> fake_lsp.Answer,
  notifier: fake_lsp.Notifier,
) -> Rig {
  rig_timed(workspace, search, script, notifier, quick_timing())
}

// `rig_with` under bounds of the test's choosing.
fn rig_timed(
  workspace: String,
  search: fn(manager.Search) -> Result(List(manager.Hit), String),
  script: fn(String, option.Option(json.JsonValue)) -> fake_lsp.Answer,
  notifier: fake_lsp.Notifier,
  timing: manager.Timing,
) -> Rig {
  let starts = process.new_subject()
  let connect = fn(identity: resolve.Identity) {
    let fake = fake_lsp.start_with(fake_lsp.everything(), script, notifier)
    process.send(starts, #(identity.root, fake))
    Ok(fake_lsp.seam(fake))
  }
  let assert Ok(started) =
    manager.start(manager.Config(
      workspace:,
      servers: [fake_server()],
      backend: manager.Backend(connect:, search:, protected: [
        workspace <> "/app/.git",
      ]),
      timing:,
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
  assert resolve.split_symbol("greet", ["."]) == resolve.Symbol("greet", None)
  assert resolve.split_symbol("probe.greet", ["."])
    == resolve.Symbol("greet", Some("probe"))
  assert resolve.split_symbol("pkg/mod.name", ["."])
    == resolve.Symbol("name", Some("pkg/mod"))
  assert resolve.split_symbol("a.b.c", ["."])
    == resolve.Symbol("c", Some("a/b"))
  assert resolve.split_symbol("..", ["."]) == resolve.Symbol("..", None)
}

pub fn a_qualifier_matches_a_module_path_or_a_directory_test() {
  assert resolve.satisfies(
    "/w",
    "/w/src/probe.gleam",
    "probe",
    profile.AsWritten,
  )
  assert resolve.satisfies("/w", "/w/util/util.go", "util", profile.AsWritten)
  assert resolve.satisfies(
    "/w",
    "/w/src/pkg/mod.gleam",
    "pkg/mod",
    profile.AsWritten,
  )
  assert !resolve.satisfies(
    "/w",
    "/w/src/probe.gleam",
    "robe",
    profile.AsWritten,
  )
  assert !resolve.satisfies(
    "/w",
    "/w/src/other.gleam",
    "probe",
    profile.AsWritten,
  )
}

// A server that qualifies with `::` splits there, and `.` is then an
// ordinary character; with both listed, the longer wins at each position.
pub fn a_symbol_splits_on_the_servers_separators_test() {
  assert resolve.split_symbol("util::greet", ["::"])
    == resolve.Symbol("greet", Some("util"))
  assert resolve.split_symbol("a::b::c", ["::"])
    == resolve.Symbol("c", Some("a/b"))
  assert resolve.split_symbol("util.greet", ["::"])
    == resolve.Symbol("util.greet", None)
  assert resolve.split_symbol("util::greet", [":", "::"])
    == resolve.Symbol("greet", Some("util"))
  assert resolve.split_symbol("pkg/mod::name", ["::", "."])
    == resolve.Symbol("name", Some("pkg/mod"))
  assert resolve.split_symbol("a.b::c", [".", "::"])
    == resolve.Symbol("c", Some("a/b"))
  assert resolve.split_symbol("::", ["::"]) == resolve.Symbol("::", None)
}

pub fn a_segment_maps_to_snake_case_test() {
  assert resolve.cased("MyApp", profile.Snake) == "my_app"
  assert resolve.cased("HTTPServer", profile.Snake) == "http_server"
  assert resolve.cased("already_snake", profile.Snake) == "already_snake"
  assert resolve.cased("MyApp/Accounts", profile.Snake) == "my_app/accounts"
  assert resolve.cased("V2Api", profile.Snake) == "v2_api"
  assert resolve.cased("IO", profile.Snake) == "io"
  assert resolve.cased("MyApp/HTTPServer", profile.AsWritten)
    == "MyApp/HTTPServer"
}

// Elixir's `MyApp.Accounts.list` lives in `lib/my_app/accounts.ex`, which
// only a snake-cased qualifier meets.
pub fn a_snake_qualifier_matches_the_snake_path_test() {
  let symbol = resolve.split_symbol("MyApp.Accounts.list", ["."])
  assert symbol == resolve.Symbol("list", Some("MyApp/Accounts"))
  let assert Some(qualifier) = symbol.qualifier
  assert resolve.satisfies(
    "/w",
    "/w/lib/my_app/accounts.ex",
    qualifier,
    profile.Snake,
  )
  assert !resolve.satisfies(
    "/w",
    "/w/lib/my_app/accounts.ex",
    qualifier,
    profile.AsWritten,
  )
  assert !resolve.satisfies(
    "/w",
    "/w/lib/my_app/users.ex",
    qualifier,
    profile.Snake,
  )
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
      profile.AsWritten,
      root: "/w",
      path: "/w/x.gleam",
    )
    == [#("Server.handle", range.Position(2, 6))]
  assert resolve.named(
      symbols,
      "handle",
      Some("Other"),
      profile.AsWritten,
      root: "/w",
      path: "/w/x.gleam",
    )
    == []
}

// Under `Snake` the parent-type match still compares the qualifier as
// written: `Server.handle` names the type `Server`, which the outline
// spells `Server`, and a snake-cased `server` would miss it.
pub fn a_parent_type_matches_as_written_under_snake_test() {
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
  assert resolve.named(
      symbols,
      "handle",
      Some("Server"),
      profile.Snake,
      root: "/w",
      path: "/w/lib/web/endpoint.ex",
    )
    == [#("Server.handle", range.Position(2, 6))]

  // The module match is the one that is cased: `Web/Endpoint` meets
  // `web/endpoint.ex` only once snake-cased.
  assert resolve.named(
      symbols,
      "handle",
      Some("Web/Endpoint"),
      profile.Snake,
      root: "/w",
      path: "/w/lib/web/endpoint.ex",
    )
    == [#("Server.handle", range.Position(2, 6))]
  assert resolve.named(
      symbols,
      "handle",
      Some("Web/Endpoint"),
      profile.AsWritten,
      root: "/w",
      path: "/w/lib/web/endpoint.ex",
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
    places: profile.Places(home: None, cache: None),
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

// Not `/bin/sh`: on most hosts that is a link, whose install prefix climbs
// out of `/bin` to `/`, and `jail.policy_for` refuses a region covering
// the server's writes before any probe could be cleared.
fn shell_server() -> profile.LspServer {
  profile.LspServer(..fake_server(), name: "shell", command: ["/bin/false"])
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

/// A private cache must exist before any policy that binds it is cleared,
/// because bwrap refuses a writable root whose source is missing. The
/// runner looks for the directory at the moment the probe is cleared, so
/// a manager that made it later, or never, fails here.
pub fn a_private_cache_is_made_before_the_probe_is_cleared_test() {
  let workspace = scratch("private-cache")
  let root = project(workspace, "app")
  let cache = workspace <> "/host-cache"
  let private = cache <> "/loom/lsp/shell/xdg"
  let seen = process.new_subject()
  let run = fn(spec: broker.CallSpec, events) {
    process.send(seen, #(
      simplifile.is_directory(private) == Ok(True),
      list.key_find(spec.env, "XDG_CACHE_HOME"),
    ))
    process.send(events, broker.CallSettled(outcome: clean()))
    Ok(tool.RunningCall(stdin: fn(_data, _eof) { Nil }, cancel: fn() { Nil }))
  }
  let jailed =
    manager.Jailed(
      ..probe_jailed(workspace, run, exec.BestEffort),
      places: profile.Places(home: None, cache: Some(cache)),
    )
  let server =
    profile.LspServer(..shell_server(), cache_env: [#("XDG_CACHE_HOME", "xdg")])
  assert simplifile.is_directory(private) != Ok(True)

  let assert Ok(_transport) =
    manager.connect_jailed(jailed, resolve.Identity(server:, root:))
    as "a server with a private cache must start"
  let assert [#(made, value)] = drain(seen, [])
    as "only the probe is cleared before the transport connects"
  assert made
  assert value == Ok(private)
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

// --- (c') the gate on what a server names ---------------------------------------
//
// The jail bounds what a server reads, never which paths it names, and the
// door reads in the harness. Each test below plants a file whose text is a
// unique marker where the gate must keep the harness out of it, has the
// fake server name it, and asserts the marker appears nowhere: not in any
// door answer, and not in anything the client sent back into the jail.

const marker = "SECRET-MARKER-7f3a9c"

// A file the server's jail cannot see: outside the `app` root, inside the
// workspace, so its path is shown relative and still never read.
fn plant_secret(workspace: String) -> String {
  let secret = workspace <> "/secret/owner.token"
  write(secret, marker <> "\n")
  secret
}

// Whether the marker reached anything the fake was sent.
fn leaked_into(fake: fake_lsp.Fake) -> Bool {
  list.any(fake_lsp.seen(fake), fn(entry) {
    case entry {
      fake_lsp.Sent(_method, Some(params)) ->
        string.contains(json.to_string(params), marker)
      fake_lsp.Sent(_method, None) | fake_lsp.Closed -> False
    }
  })
}

// Whether the fake was sent any notification or request naming `path`.
fn named_to(fake: fake_lsp.Fake, method: String, path: String) -> Bool {
  list.any(fake_lsp.seen(fake), fn(entry) {
    case entry {
      fake_lsp.Sent(sent, Some(params)) if sent == method ->
        string.contains(json.to_string(params), uri(path))
      fake_lsp.Sent(..) | fake_lsp.Closed -> False
    }
  })
}

// A script answering `method` with `answer` and everything else as
// `outline_script` does.
fn answering(
  method: String,
  answer: json.JsonValue,
) -> fn(String, option.Option(json.JsonValue)) -> fake_lsp.Answer {
  fn(asked, params) {
    case asked == method {
      True -> fake_lsp.Answer(answer)
      False -> outline_script(asked, params)
    }
  }
}

pub fn a_definition_outside_the_root_is_shown_but_never_read_test() {
  let workspace = scratch("gate-definition")
  let root = project(workspace, "app")
  let secret = plant_secret(workspace)

  // Two ways out: the path itself, and a link inside the root whose real
  // location is the same file.
  let assert Ok(Nil) =
    simplifile.create_symlink(to: secret, from: root <> "/src/link.gleam")
    as "the fixture link must be made"
  let rig =
    rig(
      workspace,
      no_search,
      answering(
        "textDocument/definition",
        json.Array([
          fake_lsp.location(uri(secret), 0, 3),
          fake_lsp.location(uri(root <> "/src/link.gleam"), 0, 3),
        ]),
      ),
    )
  let answer =
    rig.door.definition(query.SymbolQuery(
      "greet",
      Some("app/src/a.gleam"),
      Some(1),
    ))
  let assert Ok(served) = answer as "the definition must still answer"
  assert served.value
    == [
      query.Site("secret/owner.token", 1, 4, ""),
      query.Site("app/src/link.gleam", 1, 4, ""),
    ]
  assert !string.contains(string.inspect(answer), marker)

  // Nothing of the file travelled into the jail either.
  let assert [#(_, fake)] = started(rig) as "one start"
  assert !leaked_into(fake)
  manager.stop(rig.manager)
  let _ = simplifile.delete_all([workspace])
  Nil
}

pub fn diagnostics_for_a_protected_path_echo_no_text_test() {
  let workspace = scratch("gate-diagnostics")
  let root = project(workspace, "app")
  let config = root <> "/.git/config"
  write(config, marker <> "\n")

  // Every open or change is answered with a publication about the
  // protected file, which lies inside the server's root.
  let notifier = fn(method, _params) {
    case method {
      "textDocument/didOpen" | "textDocument/didChange" -> [
        #(
          "textDocument/publishDiagnostics",
          json.Object([
            #("uri", json.String(uri(config))),
            #(
              "diagnostics",
              json.Array([
                json.Object([
                  #(
                    "range",
                    json.Object([
                      #(
                        "start",
                        json.Object([
                          #("line", json.Int(0)),
                          #("character", json.Int(2)),
                        ]),
                      ),
                      #(
                        "end",
                        json.Object([
                          #("line", json.Int(0)),
                          #("character", json.Int(4)),
                        ]),
                      ),
                    ]),
                  ),
                  #("severity", json.Int(1)),
                  #("message", json.String("broken")),
                ]),
              ]),
            ),
          ]),
        ),
      ]
      _ -> []
    }
  }
  let rig = rig_with(workspace, no_search, outline_script, notifier)
  let answer = rig.door.diagnostics(Some("app/src/a.gleam"))
  let assert Ok(served) = answer as "diagnostics must answer"
  let found = case served.value {
    query.Settled(diagnostics:) -> diagnostics
    query.Unsettled(seen:) -> seen
  }
  let assert [diagnostic] = found as "the protected file's diagnostic is kept"
  assert diagnostic.site == query.Site("app/.git/config", 1, 3, "")
  assert diagnostic.message == "broken"
  assert !string.contains(string.inspect(answer), marker)
  manager.stop(rig.manager)
  let _ = simplifile.delete_all([workspace])
  Nil
}

pub fn references_into_an_outside_file_never_open_it_test() {
  let workspace = scratch("gate-references")
  let root = project(workspace, "app")
  let secret = plant_secret(workspace)
  let rig =
    rig(
      workspace,
      no_search,
      answering(
        "textDocument/references",
        json.Array([
          fake_lsp.location(uri(root <> "/src/a.gleam"), 0, 7),
          fake_lsp.location(uri(secret), 0, 0),
        ]),
      ),
    )
  let answer =
    rig.door.references(query.SymbolQuery(
      "greet",
      Some("app/src/a.gleam"),
      Some(1),
    ))
  let assert Ok(served) = answer as "references must answer"
  assert list.map(served.value, fn(reference) { reference.site })
    == [
      query.Site("app/src/a.gleam", 1, 8, "pub fn greet() -> String {"),
      query.Site("secret/owner.token", 1, 1, ""),
    ]
  assert !string.contains(string.inspect(answer), marker)

  // The admitted file was opened and outlined; the withheld one was
  // neither opened nor asked about.
  let assert [#(_, fake)] = started(rig) as "one start"
  assert named_to(fake, "textDocument/didOpen", root <> "/src/a.gleam")
  assert !named_to(fake, "textDocument/didOpen", secret)
  assert !named_to(fake, "textDocument/documentSymbol", secret)
  assert !leaked_into(fake)
  manager.stop(rig.manager)
  let _ = simplifile.delete_all([workspace])
  Nil
}

pub fn a_rename_naming_an_outside_file_is_refused_whole_test() {
  let workspace = scratch("gate-rename")
  let root = project(workspace, "app")
  let secret = plant_secret(workspace)
  let edit = fn(line, from, to) {
    let at = fn(character) {
      json.Object([
        #("line", json.Int(line)),
        #("character", json.Int(character)),
      ])
    }
    json.Object([
      #("range", json.Object([#("start", at(from)), #("end", at(to))])),
      #("newText", json.String("salute")),
    ])
  }
  let rig =
    rig(
      workspace,
      no_search,
      answering(
        "textDocument/rename",
        json.Object([
          #(
            "changes",
            json.Object([
              #(uri(root <> "/src/a.gleam"), json.Array([edit(0, 7, 12)])),
              #(uri(secret), json.Array([edit(0, 0, 5)])),
            ]),
          ),
        ]),
      ),
    )
  let answer =
    rig.door.prepare_rename(
      query.SymbolQuery("greet", Some("app/src/a.gleam"), Some(1)),
      "salute",
    )
  let assert Error(query.ServerRefused(message)) = answer
    as "a rename reaching outside the root must be refused"
  assert string.contains(message, "secret/owner.token")
  assert string.contains(message, "nothing was read or changed")
  assert !string.contains(string.inspect(answer), marker)
  let assert Ok(on_disk) = simplifile.read(secret) as "the secret still reads"
  assert on_disk == marker <> "\n"
  let assert [#(_, fake)] = started(rig) as "one start"
  assert !leaked_into(fake)
  manager.stop(rig.manager)
  let _ = simplifile.delete_all([workspace])
  Nil
}

// The fs tools hand the write observer the real path they wrote. Under a
// workspace reached through a symlink that path never starts with the
// workspace as written, and the observer must still find its owner.
pub fn after_write_finds_its_owner_under_a_symlinked_workspace_test() {
  let real = scratch("symlinked-real")
  let link = real <> "-link"
  let assert Ok(Nil) = simplifile.create_symlink(to: real, from: link)
    as "the workspace link must be made"
  let _root = project(link, "app")
  let rig = rig(link, no_search, outline_script)
  let assert Ok(_) = rig.door.outline("app/src/a.gleam") as "start"
  let assert Some(query.Settled([])) =
    rig.door.after_write(real <> "/app/src/a.gleam")
    as "the real path of a write must reach the running owner"
  manager.stop(rig.manager)
  let _ = simplifile.delete(link)
  let _ = simplifile.delete_all([real])
  Nil
}

// A server gone silent on `definition` must cost a bare-name question one
// request deadline, not one per hit.
pub fn a_silent_server_cuts_a_bare_name_search_short_test() {
  let workspace = scratch("silent")
  let root = project(workspace, "app")
  let calls = "pub fn twice() {\n" <> string.repeat("  greet()\n", 8) <> "}\n"
  write(root <> "/src/calls.gleam", calls)
  let hits =
    list.map([2, 3, 4, 5, 6, 7, 8, 9], fn(line) {
      manager.Hit(root <> "/src/calls.gleam", line)
    })
  let script = fn(method, params) {
    case method {
      "textDocument/definition" -> fake_lsp.Silent
      _ -> outline_script(method, params)
    }
  }
  let rig = rig(workspace, fn(_search) { Ok(hits) }, script)
  let assert Ok(_) = rig.door.outline("app/src/a.gleam") as "start"
  let began = ffi_os.system_time_ms()
  let answer = rig.door.definition(query.SymbolQuery("greet", None, None))
  let took = ffi_os.system_time_ms() - began
  let assert Error(query.Unavailable(reason)) = answer
    as "a server that stops answering must be reported, not taken for none"
  assert string.contains(reason, "stopped there")

  // One request deadline (2 s here) and some margin; eight would be 16 s.
  assert took < quick_timing().request_ms * 2
  manager.stop(rig.manager)
  let _ = simplifile.delete_all([workspace])
  Nil
}

// `$/progress` params for one work-done token.
fn progress(token: String, kind: String) -> json.JsonValue {
  json.Object([
    #("token", json.String(token)),
    #(
      "value",
      json.Object([
        #("kind", json.String(kind)),
        #("title", json.String("Loading workspace")),
      ]),
    ),
  ])
}

// A server that begins loading as soon as it is initialized, and reports
// the end only when the test says so.
fn loads_after_initialized(
  method: String,
  _params: option.Option(json.JsonValue),
) -> List(#(String, json.JsonValue)) {
  case method {
    "initialized" -> [#("$/progress", progress("load", "begin"))]
    _ -> []
  }
}

// The one fake the rig has started, once it has been.
fn first_start(rig: Rig) -> fake_lsp.Fake {
  let assert Ok(#(_root, fake)) = process.receive(rig.starts, 5000)
    as "the server must be started"
  fake
}

// A server still loading at the readiness deadline is reported as loading,
// in words that tell the model to ask again, and is never asked the
// question it would answer wrongly. It is left running, and the next
// question, warm, is asked without waiting: a token the server never ends
// costs one refusal, not one per query.
pub fn a_server_still_loading_at_the_deadline_is_unavailable_test() {
  let workspace = scratch("still-loading")
  let _root = project(workspace, "app")
  let timing = manager.Timing(..quick_timing(), ready_ms: 200)
  let rig =
    rig_timed(
      workspace,
      no_search,
      outline_script,
      loads_after_initialized,
      timing,
    )

  let assert Error(query.Unavailable(reason)) =
    rig.door.outline("app/src/a.gleam")
    as "a loading server must not be asked"
  assert reason
    == "the language server is still loading (Loading workspace); ask again in a moment"
  let fake = first_start(rig)
  assert !list.contains(fake_lsp.methods(fake), "textDocument/documentSymbol")

  let assert Ok(served) = rig.door.outline("app/src/a.gleam")
    as "the warm server must be asked, its token still open"
  assert served.warmth == query.Warm
  assert started(rig) == []
  manager.stop(rig.manager)
  let _ = simplifile.delete_all([workspace])
  Nil
}

// A warm query never waits, even while the server reports work: a
// re-index answers from the server's previous state, as it does for any
// editor, and a leaked token must not stall every question.
pub fn a_warm_query_does_not_wait_on_active_progress_test() {
  let workspace = scratch("warm-busy")
  let _root = project(workspace, "app")
  let timing = manager.Timing(..quick_timing(), ready_ms: 10_000)
  let rig =
    rig_timed(
      workspace,
      no_search,
      outline_script,
      fn(_method, _params) { [] },
      timing,
    )
  let assert Ok(served) = rig.door.outline("app/src/a.gleam") as "start"
  assert served.warmth == query.Started("fake")
  let fake = first_start(rig)

  // The server begins work it never ends. Diagnostics, which do not wait,
  // settle on a barrier the server answers behind the `begin`, so once
  // they return the client holds the token.
  fake_lsp.notify(fake, "$/progress", progress("reindex", "begin"))
  let assert Ok(_) = rig.door.diagnostics(Some("app/src/a.gleam"))
    as "diagnostics must settle"

  let began = ffi_os.system_time_ms()
  let assert Ok(served) = rig.door.outline("app/src/a.gleam")
    as "a warm query must be asked while progress is open"
  assert ffi_os.system_time_ms() - began < 1000
  assert served.warmth == query.Warm
  let assert [entry] = served.value as "the outline has one entry"
  assert entry.name == "greet"
  manager.stop(rig.manager)
  let _ = simplifile.delete_all([workspace])
  Nil
}

// The first query after a start waits for the load it started: nothing is
// asked until the progress ends, and then only after the quiet window.
// Diagnostics do not wait.
pub fn a_fresh_start_waits_for_the_server_to_be_ready_test() {
  let workspace = scratch("fresh-start")
  let _root = project(workspace, "app")
  let timing = manager.Timing(..quick_timing(), ready_ms: 10_000, quiet_ms: 200)
  let rig =
    rig_timed(
      workspace,
      no_search,
      outline_script,
      loads_after_initialized,
      timing,
    )
  let answers = process.new_subject()
  process.spawn(fn() {
    process.send(answers, rig.door.outline("app/src/a.gleam"))
  })
  let fake = first_start(rig)

  // The document is opened, and then the question waits.
  let assert poll.Answered(Nil) =
    poll.until(within: 5000, every: 10, attempt: fn() {
      case list.contains(fake_lsp.methods(fake), "textDocument/didOpen") {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
    as "the query's document must be opened"
  assert process.receive(answers, 300) == Error(Nil)
  assert !list.contains(fake_lsp.methods(fake), "textDocument/documentSymbol")

  // Diagnostics are settled by their own rules, loading or not.
  let assert Ok(_) = rig.door.diagnostics(Some("app/src/a.gleam"))
    as "diagnostics must not wait for readiness"

  let ended = ffi_os.system_time_ms()
  fake_lsp.notify(fake, "$/progress", progress("load", "end"))
  let assert Ok(Ok(served)) = process.receive(answers, 5000)
    as "the query must be answered once the server is ready"
  assert ffi_os.system_time_ms() - ended >= timing.quiet_ms
  assert served.warmth == query.Started("fake")
  assert list.contains(fake_lsp.methods(fake), "textDocument/documentSymbol")
  manager.stop(rig.manager)
  let _ = simplifile.delete_all([workspace])
  Nil
}

// The session's arrangement: the manager is a transient child of a
// supervisor, bound to an address, and every door is built over the
// address. A crashed manager is replaced and the same door reaches the
// replacement, whose first query starts the server again; the crashed
// one's keeper, seeing its manager go, stopped its server politely. A
// manager `stop` ended is not replaced, and `stop` returns only once the
// server's keeper has finished stopping it.
pub fn a_supervised_manager_is_replaced_under_its_address_test() {
  let workspace = scratch("supervised")
  let _root = project(workspace, "app")
  let starts = process.new_subject()
  let closes = process.new_subject()

  // Each fake's transport closes slowly, and says when it has: a server
  // that takes a moment to exit is what makes "stop waits for the keeper"
  // observable, since a fake that closed at once would look stopped
  // whether or not anybody waited.
  let connect = fn(identity: resolve.Identity) {
    let fake = fake_lsp.start(fake_lsp.everything(), outline_script)
    process.send(starts, #(identity.root, fake))
    Ok(slow_close(fake_lsp.seam(fake), closes))
  }
  let config =
    manager.Config(
      workspace:,
      servers: [fake_server()],
      backend: manager.Backend(connect:, search: no_search, protected: []),
      timing: quick_timing(),
    )
  let assert Ok(names) = address.start() as "the registry must start"
  let name = address.new_address(names)
  let assert Ok(tree) =
    sup.new(sup.OneForOne)
    |> sup.add(manager.supervised(name, config))
    |> sup.start
    as "the supervisor must start the manager"
  let handle = manager.addressed(name, config)
  let door = manager.door(handle)

  let assert Ok(served) = door.outline("app/src/a.gleam") as "first start"
  assert served.warmth == query.Started("fake")
  let assert [#(_, first)] = drain(starts, []) as "one start"

  // The crash. The replacement answers through the same address.
  let assert Ok(incarnation) = address.lookup(name) as "the manager is bound"
  let assert Ok(crashed) = process.subject_owner(incarnation)
    as "the manager has a pid"
  process.kill(crashed)
  let outcome =
    poll.until(within: 5000, every: 20, attempt: fn() {
      case door.outline("app/src/a.gleam") {
        Ok(served) -> poll.Done(served)
        Error(query.Unavailable(_)) -> poll.Retry
        Error(other) -> poll.Fail(other)
      }
    })
  let assert poll.Answered(again) = outcome
    as "the replacement must serve the same door"
  assert again.warmth == query.Started("fake")
  let assert [#(_, second)] = drain(starts, []) as "exactly one restart"
  assert list.contains(fake_lsp.methods(first), "shutdown")

  // `stop` waits out the keeper's graceful stop, and a stopped manager
  // is not replaced: the address stays unbound.
  let _first_close = drain(closes, [])
  manager.stop(handle)
  assert process.receive(closes, within: 0) == Ok(Nil)
    as "stop must return only after the server's transport closed"
  assert list.contains(fake_lsp.methods(second), "shutdown")
  process.sleep(200)
  assert address.lookup(name) == Error(Nil)
  assert door.after_write("app/src/a.gleam") == None

  process.unlink(tree.pid)
  process.kill(tree.pid)
  let _ = simplifile.delete_all([workspace])
  Nil
}

// A channel transport whose close takes 300 ms and then reports on
// `closed`, for the stop-waits test above.
fn slow_close(
  inner: transport.Transport,
  closed: Subject(Nil),
) -> transport.Transport {
  case inner {
    transport.ChannelTransport(connect:) ->
      transport.ChannelTransport(connect: fn(inbound) {
        let connection = connect(inbound)
        transport.Connection(..connection, close: fn() {
          process.spawn_unlinked(fn() {
            process.sleep(300)
            connection.close()
            process.send(closed, Nil)
          })
          Nil
        })
      })
    transport.PortTransport(..) -> inner
  }
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
  servers: List(profile.LspServer),
  reading: fn(String) -> Result(String, Nil),
) -> manager.Manager {
  let lsp_op = op()
  let jailed =
    manager.Jailed(
      workspace: live.workspace,
      session_base: live_base(live.workspace),
      demand: exec.BestEffort,
      toolchain: None,
      places: profile.Places(home: Some(live.workspace <> "/home"), cache: None),
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

// The live tests resolve a bare symbol, which the manager does with
// ripgrep inside the jail before asking the server, so ripgrep is as much
// a prerequisite as the server itself: without it the answer is a worded
// refusal, not a result to assert on.
pub fn gleam_lsp_answers_the_door_from_inside_the_jail_test() {
  case
    live_prerequisites("lsp manager gleam lsp"),
    ffi_os.find_executable("gleam"),
    ffi_os.find_executable("rg")
  {
    Error(Nil), _, _ -> Nil
    Ok(_), Error(_), _ ->
      io.println_error("SKIP lsp manager gleam lsp: gleam is not on PATH")
    Ok(_), Ok(_), Error(_) ->
      io.println_error(
        "SKIP lsp manager gleam lsp: ripgrep (rg) is not on PATH",
      )
    Ok(helper), Ok(_), Ok(_) -> run_gleam(live_rig(helper, "gleam"))
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
    profile.LspServer(
      name: "gleam",
      command: ["gleam", "lsp"],
      extensions: [".gleam"],
      root_markers: ["gleam.toml"],
      project: profile.ProjectWritable,
      readable: [],
      writable: [],
      env: [],
      cache_env: [],
      language_id: "gleam",
      qualifier_separators: ["."],
      module_case: profile.AsWritten,
      hint: None,
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
    ffi_os.find_executable("go"),
    ffi_os.find_executable("rg")
  {
    Error(Nil), _, _, _ -> Nil
    Ok(_), Ok(True), Ok(go), Ok(_) -> run_gopls(live_rig_for_go(), gopls, go)
    Ok(_), Ok(True), Ok(_), Error(_) ->
      io.println_error("SKIP lsp manager gopls: ripgrep (rg) is not on PATH")
    Ok(_), _, _, _ ->
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
    profile.LspServer(
      name: "gopls",
      command: [gopls],
      extensions: [".go"],
      root_markers: ["go.mod"],
      project: profile.ProjectReadOnly,
      readable: [],
      writable: [profile.AbsolutePath(cache), profile.AbsolutePath(gopath)],
      env: ["GOCACHE", "GOPATH", "GOFLAGS", "GOTOOLCHAIN", "GOPROXY"],
      cache_env: [],
      language_id: "go",
      qualifier_separators: ["."],
      module_case: profile.AsWritten,
      hint: None,
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

// `rust-analyzer` answers while it loads the Cargo workspace, and answers
// with empty results rather than errors, so this is the server the
// readiness wait exists for. It is rustup's link in `~/.cargo/bin`, which
// makes `~/.cargo` its read-only region; the toolchain it dispatches to
// lives under `~/.rustup`. Cargo's target directory and home are writable
// roots outside the workspace, since the project root is read-only.
pub fn rust_analyzer_answers_the_door_once_ready_test() {
  let home =
    secret.lookup(secret.env(), "HOME") |> result.unwrap("/nonexistent")
  case
    live_prerequisites("lsp manager rust-analyzer"),
    rust_prerequisites(home),
    ffi_os.find_executable("rg")
  {
    Error(Nil), _, _ -> Nil
    Ok(helper), Ok(Nil), Ok(_) ->
      run_rust_analyzer(live_rig(helper, "rust-analyzer"), home)
    Ok(_), Error(reason), _ ->
      io.println_error("SKIP lsp manager rust-analyzer: " <> reason)
    Ok(_), Ok(Nil), Error(_) ->
      io.println_error(
        "SKIP lsp manager rust-analyzer: ripgrep (rg) is not on PATH",
      )
  }
}

// Whether rustup's `rust-analyzer` can actually serve. The file existing
// proves nothing: rustup installs its `rust-analyzer` link whether or not
// the component is installed, and the link then fails at its first use.
// So the server must answer `--version`, and `rust-src` must be in the
// sysroot, since the server loads the standard library from it and the
// call inside `println!` is never found without it.
fn rust_prerequisites(home: String) -> Result(Nil, String) {
  let bin = home <> "/.cargo/bin/"
  let missing =
    "rust-analyzer does not run (rustup component add rust-analyzer rust-src)"
  use #(status, _version) <- result.try(
    ffi_os.run_capture(bin <> "rust-analyzer", ["--version"], 10_000)
    |> result.replace_error(missing),
  )
  use Nil <- result.try(case status {
    0 -> Ok(Nil)
    _failed -> Error(missing)
  })
  use #(_status, sysroot) <- result.try(
    ffi_os.run_capture(bin <> "rustc", ["--print", "sysroot"], 10_000)
    |> result.replace_error("rustc does not run in ~/.cargo/bin"),
  )
  case
    simplifile.is_directory(
      string.trim(sysroot) <> "/lib/rustlib/src/rust/library",
    )
  {
    Ok(True) -> Ok(Nil)
    Ok(False) | Error(_) ->
      Error("rust-src is not installed (rustup component add rust-src)")
  }
}

const util_rs = "pub fn greet() -> &'static str {\n    \"hi\"\n}\n"

const main_rs = "mod util;\n\nfn main() {\n    println!(\"{}\", util::greet());\n    let again = util::greet();\n    println!(\"{}\", again);\n}\n"

fn run_rust_analyzer(live: Live, home: String) -> Nil {
  let crate = live.workspace <> "/probe"
  write(
    crate <> "/Cargo.toml",
    "[package]\nname = \"probe\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[dependencies]\n",
  )

  // The project root is read-only in the jail, and `cargo metadata`
  // writes a missing lockfile before it answers: without one the crate
  // never loads, and every answer is empty however long the wait.
  write(
    crate <> "/Cargo.lock",
    "# This file is automatically @generated by Cargo.\n# It is not intended for manual editing.\nversion = 4\n\n[[package]]\nname = \"probe\"\nversion = \"0.1.0\"\n",
  )
  write(crate <> "/src/util.rs", util_rs)
  write(crate <> "/src/main.rs", main_rs)

  let target = live.root <> "/cargo-target"
  let cargo_home = live.root <> "/cargo-home"
  let assert Ok(Nil) = simplifile.create_directory_all(target) as "target dir"
  let assert Ok(Nil) = simplifile.create_directory_all(cargo_home)
    as "cargo home"

  // `rust-analyzer` loads the standard library as a Cargo workspace of its
  // own, and resolving it needs std's dependencies from the registry. An
  // empty Cargo home, offline, cannot resolve them (measured: "no matching
  // package named `hashbrown`"), std loads without them, and the call
  // inside `println!` — a std macro — is then never found. The home's
  // registry is the host's own, read through `~/.cargo`'s read-only
  // region; only the home itself is writable.
  let assert Ok(Nil) =
    simplifile.create_symlink(
      to: home <> "/.cargo/registry",
      from: cargo_home <> "/registry",
    )
    as "the cargo home's registry must be linked"
  let server =
    profile.LspServer(
      name: "rust-analyzer",
      command: [home <> "/.cargo/bin/rust-analyzer"],
      extensions: [".rs"],
      root_markers: ["Cargo.toml"],
      project: profile.ProjectReadOnly,
      readable: [profile.AbsolutePath(home <> "/.rustup")],
      writable: [profile.AbsolutePath(target), profile.AbsolutePath(cargo_home)],
      env: [
        "RUSTUP_HOME",
        "CARGO_HOME",
        "CARGO_TARGET_DIR",
        "CARGO_NET_OFFLINE",
      ],
      cache_env: [],
      language_id: "rust",
      qualifier_separators: ["::"],
      module_case: profile.AsWritten,
      hint: None,
    )
  let running =
    live_manager(live, [server], fn(name) {
      case name {
        "PATH" -> Ok(home <> "/.cargo/bin:/usr/local/bin:/usr/bin:/bin")
        "RUSTUP_HOME" -> Ok(home <> "/.rustup")
        "CARGO_HOME" -> Ok(cargo_home)
        "CARGO_TARGET_DIR" -> Ok(target)
        "CARGO_NET_OFFLINE" -> Ok("true")
        _ -> Error(Nil)
      }
    })
  let door = manager.door(running)
  let main_path = "probe/src/main.rs"
  let util_path = "probe/src/util.rs"

  // The first question starts the server and waits for its load. Asked
  // before readiness existed, this answered `[]`.
  let began = ffi_os.system_time_ms()
  let assert Ok(served) =
    door.definition(query.SymbolQuery("util::greet", Some(main_path), Some(4)))
    as "the definition must answer"
  io.println_error(
    "lsp manager rust-analyzer: definition after "
    <> int.to_string(ffi_os.system_time_ms() - began)
    <> " ms "
    <> string.inspect(served),
  )
  assert served.warmth == query.Started("rust-analyzer")
  assert sites(served) == [#(util_path, 1)]

  // Every site, the one inside `println!` included, and the declaration:
  // while the workspace loads, the answer held the declaration alone.
  let assert Ok(served) =
    door.references(query.SymbolQuery("greet", Some(util_path), Some(1)))
    as "references must answer"
  io.println_error(
    "lsp manager rust-analyzer: references " <> string.inspect(served),
  )
  let found =
    list.map(served.value, fn(reference) {
      #(reference.site.path, reference.site.line)
    })
    |> list.sort(fn(a, b) {
      case string.compare(a.0, b.0) {
        order.Eq -> int.compare(a.1, b.1)
        other -> other
      }
    })
  assert found == [#(main_path, 4), #(main_path, 5), #(util_path, 1)]

  // Both files change, and `main.rs` at both of its calls: loading, the
  // rename edited `util.rs` alone.
  let assert Ok(served) =
    door.prepare_rename(
      query.SymbolQuery("greet", Some(util_path), Some(1)),
      "salute",
    )
    as "a rename must be prepared"
  let edited =
    list.map(served.value, fn(edit) { #(edit.path, edit.edited) })
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  io.println_error(
    "lsp manager rust-analyzer: rename " <> string.inspect(edited),
  )
  assert edited
    == [
      #(main_path, string.replace(main_rs, "greet", "salute")),
      #(util_path, string.replace(util_rs, "greet", "salute")),
    ]
  stop_live(live, running)
}

fn dirname(path: String) -> String {
  let parts = string.split(path, "/")
  string.join(list.take(parts, list.length(parts) - 1), "/")
}
