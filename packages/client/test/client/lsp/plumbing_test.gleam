//// The language-server door, plumbed: what a session with no configured
//// server sees (nothing, byte for byte), what a session with one sees
//// (observed writes and `cap/lsp` admitted, rendered,
//// advertised and routed together), and the applied rename code mode
//// reaches, landing through the write boundary a program is held to.
////
//// Every door here is a fake: the manager that fills a real one is its
//// own slice, and what is under test is only where the door goes.

import broker/broker
import broker/exec
import broker/framing
import broker/policy
import client/codemode
import client/contributions
import codemode/codemode as pipeline
import codemode/identity
import codemode/lsp as codemode_lsp
import codemode/lsp_host/codemode_rename
import codemode/satellite
import codemode/vet
import codemode/vet/policy as vet_policy
import core/clock
import core/ids
import core/json
import core/message
import core/msgpack
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lsp/observation
import lsp/query
import simplifile
import tools/codemode as codemode_tool
import tools/directory_access
import tools/fs
import tools/hashline
import tools/tool

// --- fixtures ------------------------------------------------------------

// A door where every closure answers `Unavailable`, so a test overrides
// exactly the closure it is about and any other call shows up as a
// refusal it did not expect.
fn door() -> query.Door {
  let unused = query.Unavailable("not part of this test")
  query.Door(
    definition: fn(_) { Error(unused) },
    references: fn(_) { Error(unused) },
    hover: fn(_) { Error(unused) },
    outline: fn(_) { Error(unused) },
    calls: fn(_, _) { Error(unused) },
    diagnostics: fn(_) { Error(unused) },
    prepare_rename: fn(_, _) { Error(unused) },
    after_write: fn(_) { None },
  )
}

// Every path the door is told was written, in order.
fn recording_door(written: process.Subject(String)) -> query.Door {
  query.Door(..door(), after_write: fn(path) {
    process.send(written, path)
    Some(query.Settled([diagnostic("unused variable `x`")]))
  })
}

fn diagnostic(text: String) -> query.Diagnostic {
  query.Diagnostic(
    site: query.Site(path: "a.txt", line: 1, column: 1, text: "old"),
    severity: query.SeverityWarning,
    message: text,
  )
}

fn drain(written: process.Subject(String)) -> List(String) {
  case process.receive(written, 0) {
    Ok(path) -> [path, ..drain(written)]
    Error(Nil) -> []
  }
}

// A fresh directory under this package's build tree, emptied first so a
// rerun starts from nothing. Not under `/tmp`, where a jailed caller
// would see the scratch tmpfs instead.
fn scratch(name: String) -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner has a working directory"
  let root = here <> "/build/lsp-plumbing-test/" <> name
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
    as "the scratch directory must be creatable"
  root
}

fn idle_broker() -> broker.Broker {
  let assert Ok(started) =
    broker.start(
      broker.BrokerConfig(
        entropy: fn(bytes) { <<0:size(bytes)-unit(8)>> },
        clock: clock.fixed(at: 0),
        checkout: fn() { Error(exec.AllBusy(size: 0)) },
        checkin: fn(_helper) { Nil },
      ),
    )
    as "the broker must start"
  started
}

fn config_for(broker_actor: broker.Broker) -> codemode.Config {
  codemode.default_config(
    broker: broker_actor,
    clock: clock.fixed(at: 1000),
    workspace: "/work",
    toolchain: codemode.toolchain(
      gleam_path: "/opt/gleam/bin/gleam",
      erl_path: "/usr/lib/erlang/bin/erl",
      seed_root: "/opt/loom/codemode-seed",
    ),
  )
}

fn a_request(workspace: String) -> codemode_tool.Request {
  let #(op_id, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 3))
  codemode_tool.Request(
    directory_access: directory_access.none(),
    source: "pub fn main() { todo }",
    seam: codemode_tool.WorkspaceSeam,
    strand: "main",
    op_id:,
    step_id: "lsp-plumbing",
    source_index: 0,
    workspace:,
    base_policy: policy.workspace_default(workspace),
    demand: exec.FullEnforcement,
    env: [],
    within_ms: 60_000,
    grants: [],
    observe_output: tool.ignore_output(),
  )
}

fn routed(
  config: codemode.Config,
  request: codemode_tool.Request,
  cap: String,
  args: List(#(String, msgpack.MsgPackValue)),
) -> framing.CapOutcome {
  let built =
    codemode.exec_config(config, request, "/work/x", 9_000_000, widened_by: [])
  let call =
    satellite.CapRequest(
      cap:,
      args: msgpack.MapValue(
        list.map(args, fn(pair) { #(msgpack.StringValue(pair.0), pair.1) }),
      ),
      identity: identity.run_phase(built.identity),
      base_policy: request.base_policy,
      demand: request.demand,
      env: [],
      cwd: request.workspace,
      ordinal: 0,
    )
  route(built, call)
}

fn route(
  built: pipeline.ExecConfig,
  call: satellite.CapRequest,
) -> framing.CapOutcome {
  case built.satellite.router(call) {
    Error(denial) -> framing.CapErr(code: denial.code, message: denial.message)
    Ok(satellite.ServedHere(serve)) | Ok(satellite.ScopedService(serve)) ->
      serve()
    Ok(satellite.ClearedCall(..)) ->
      panic as "an lsp call is answered in the harness"
  }
}

fn symbol_args(symbol: String) -> List(#(String, msgpack.MsgPackValue)) {
  [
    #("symbol", msgpack.StringValue(symbol)),
    #("path", msgpack.NilValue),
    #("line", msgpack.NilValue),
  ]
}

fn ctx_in(workspace: String) -> tool.Ctx {
  let #(op_id, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 3))
  tool.Ctx(
    directory_access: directory_access.none(),
    workspace: tool.LocalWorkspace(workspace, fs.real_filesystem()),
    strand: "main",
    op_id:,
    step_id: "step-1",
    source_index: 0,
    base_policy: policy.workspace_default(workspace),
    grants: [],
    demand: exec.BestEffort,
    env: [],
    clock: clock.fixed(at: 0),
    owner_blobs: tool.OwnerBlobs(workspace <> "/.blobs", fs.real_filesystem()),
    clear_call: fn(_spec, _events) { Error(broker.BrokerUnavailable) },
    raise_refusal: tool.no_raise(),
    observe_output: tool.ignore_output(),
  )
}

fn registry(lsp: Option(query.Door)) -> tool.Registry {
  let assert Ok(registry) =
    contributions.registry(
      contributions.built_in(None, None, None, None, None, None, None, lsp, []),
    )
    as "the built-in contributions never collide"
  registry
}

fn text_of(outcome: tool.ToolOutcome) -> String {
  outcome.content
  |> list.filter_map(fn(block) {
    case block {
      message.ToolResultText(text:, ..) -> Ok(text)
      message.ToolResultImage(..) -> Error(Nil)
    }
  })
  |> string.join("\n")
}

// --- the tool registry -----------------------------------------------------

// No door, no bytes: the tool array is the cached prefix, so a session
// with no configured server must register exactly what it always did.
pub fn no_door_registers_no_lsp_tool_test() {
  let names = tool.names(registry(None))
  assert names == ["bash", "fs_edit", "fs_read", "fs_write", "grep"]
  assert tool.declarations(registry(None))
    == tool.declarations(
      tool.registry([
        tool_named(registry(None), "bash"),
        tool_named(registry(None), "grep"),
        tool_named(registry(None), "fs_read"),
        fs.write_tool(),
        fs.edit_tool(),
      ]),
    )
}

fn tool_named(registry: tool.Registry, name: String) -> tool.Tool {
  let assert Ok(found) = tool.lookup(registry, name)
    as "the core tool is registered"
  found
}

pub fn a_door_keeps_language_calls_in_code_mode_test() {
  let names = tool.names(registry(Some(door())))
  assert list.filter(names, string.starts_with(_, "lsp_")) == []
}

// With a door, a landed write is reported to it and its diagnostics
// trail the result; without one, the same write's result is untouched.
pub fn a_door_observes_fs_write_test() {
  let workspace = scratch("observed-write")
  let written = process.new_subject()
  let args =
    json.Object([
      #("path", json.String("a.txt")),
      #("content", json.String("old\n")),
    ])

  let observed =
    tool.dispatch(
      registry(Some(recording_door(written))),
      ctx_in(workspace),
      "fs_write",
      args,
    )
  assert !observed.is_error
  assert string.contains(text_of(observed), "unused variable `x`")
  let assert [path] = drain(written)
  assert string.ends_with(path, "/a.txt")

  let plain = tool.dispatch(registry(None), ctx_in(workspace), "fs_write", args)
  assert !plain.is_error
  assert !string.contains(text_of(plain), "unused variable")
}

pub fn a_door_observes_fs_edit_test() {
  let workspace = scratch("observed-edit")
  let written = process.new_subject()
  let content = "old\n"
  let assert Ok(Nil) = simplifile.write(workspace <> "/a.txt", content)
  let anchor =
    json.Object([
      #("line", json.Int(1)),
      #("anchor", json.String(hashline.anchor("old"))),
    ])
  let outcome =
    tool.dispatch(
      registry(Some(recording_door(written))),
      ctx_in(workspace),
      "fs_edit",
      json.Object([
        #("path", json.String("a.txt")),
        #("digest", json.String(hashline.digest(content))),
        #(
          "hunks",
          json.Array([
            json.Object([
              #("op", json.String("replace")),
              #("from", anchor),
              #("to", anchor),
              #("lines", json.Array([json.String("new")])),
            ]),
          ]),
        ),
      ]),
    )
  assert !outcome.is_error
  assert string.contains(text_of(outcome), "unused variable `x`")
  assert simplifile.read(workspace <> "/a.txt") == Ok("new\n")
  let assert [path] = drain(written)
  assert string.ends_with(path, "/a.txt")
}

fn guidance_registry(
  lsp: Option(query.Door),
  seams: codemode_tool.Seams,
) -> tool.Registry {
  let mode =
    codemode_tool.CodeMode(
      execute: fn(_) { panic as "discovery never executes a program" },
      background: None,
      seams:,
      default_within_ms: 1000,
      max_within_ms: 1000,
    )
  let assert Ok(registry) =
    contributions.registry(
      contributions.built_in(
        None,
        Some(mode),
        None,
        None,
        None,
        None,
        None,
        lsp,
        [
          #("gleam", "Gleam installed profile. Second sentence stays visible."),
          #("go", "Go installed profile."),
        ],
      ),
    )
  registry
}

fn guidance_offer(
  imports: List(String),
  caps: List(String),
) -> codemode_tool.SeamOffer {
  codemode_tool.SeamOffer(
    seam: codemode_tool.WorkspaceSeam,
    allowed_imports: imports,
    serviced_caps: caps,
    extra_surfaces: [],
  )
}

pub fn language_guidance_requires_door_import_and_service_test() {
  let full =
    guidance_offer(["cap/lsp", "cap/lsp_sql"], [
      "lsp.definition",
      "lsp.snapshot",
    ])
  let cases = [
    #(None, full),
    #(Some(door()), guidance_offer([], ["lsp.definition", "lsp.snapshot"])),
    #(Some(door()), guidance_offer(["cap/lsp", "cap/lsp_sql"], [])),
  ]
  list.each(cases, fn(test_case) {
    let registry =
      guidance_registry(test_case.0, codemode_tool.one_seam(test_case.1))
    let described = tool_named(registry, "code_mode").description
    assert !string.contains(described, "installed profile")
    let read =
      tool.dispatch(
        registry,
        ctx_in("/nonexistent"),
        "fs_read",
        json.Object([#("path", json.String("cap://lsp"))]),
      )
    assert !string.contains(text_of(read), "installed profile")
  })
}

pub fn language_guidance_is_shared_once_and_discovered_after_api_test() {
  let full =
    guidance_offer(["cap/lsp", "cap/lsp_sql"], [
      "lsp.definition",
      "lsp.snapshot",
    ])
  let seams =
    codemode_tool.Seams(default: full, alternates: [
      codemode_tool.SeamOffer(..full, seam: codemode_tool.OrchestrationSeam),
    ])
  let registry = guidance_registry(Some(door()), seams)
  let described = tool_named(registry, "code_mode").description
  assert list.length(string.split(described, "Gleam installed profile")) == 2
  assert list.length(string.split(described, "### cap/lsp\n")) == 2
  assert string.contains(described, "Second sentence stays visible.")
  assert string.contains(described, "bounded observation once")
  let read =
    tool.dispatch(
      registry,
      ctx_in("/nonexistent"),
      "fs_read",
      json.Object([#("path", json.String("cap://lsp"))]),
    )
  assert !read.is_error
  let assert [_before, after_api] =
    string.split(text_of(read), "pub fn definition(Query)")
  let assert [_api, after_gleam] =
    string.split(after_api, "Gleam installed profile")
  assert string.contains(after_gleam, "Go installed profile")
  let index =
    tool.dispatch(
      registry,
      ctx_in("/nonexistent"),
      "fs_read",
      json.Object([#("path", json.String("cap://"))]),
    )
  assert !index.is_error
  assert list.length(string.split(text_of(index), "cap/lsp:")) == 2
}

pub fn sql_guidance_requires_its_own_import_and_snapshot_service_test() {
  let cases = [
    guidance_offer(["cap/lsp"], ["lsp.definition", "lsp.snapshot"]),
    guidance_offer(["cap/lsp", "cap/lsp_sql"], ["lsp.definition"]),
  ]
  list.each(cases, fn(offer) {
    let registry =
      guidance_registry(Some(door()), codemode_tool.one_seam(offer))
    let described = tool_named(registry, "code_mode").description
    assert string.contains(described, "Gleam installed profile")
    assert !string.contains(described, "bounded observation once")
  })
}

// --- code mode --------------------------------------------------------------

// The gate the whole slice is for: with no door, `cap/lsp` is not
// admitted, not rendered into the description, not advertised and not
// routed; a program that imports it is refused with a reason at vetting.
pub fn no_door_hides_cap_lsp_from_code_mode_test() {
  let broker_actor = idle_broker()
  let base = config_for(broker_actor)
  let seam = vet_policy.WorkspaceSeam
  let allowlist = codemode.seam_allowlist(base, seam)
  assert !vet_policy.contains(allowlist, "cap/lsp")
  assert !list.any(codemode.seam_caps_on(base, seam), string.starts_with(
    _,
    "lsp.",
  ))
  assert !string.contains(
    codemode_tool.description(codemode.seam(base)),
    "cap/lsp",
  )

  let source = "import cap/lsp\npub fn main() { lsp.symbol(\"f\") }\n"
  let assert vet.Rejected([rejection]) = vet.vet(source, allowlist)
  assert string.contains(string.inspect(rejection), "cap/lsp")

  let assert framing.CapErr(code: "unsupported_cap", ..) =
    routed(base, a_request("/work"), "lsp.definition", symbol_args("f"))
  broker.stop(broker_actor)
}

pub fn a_door_admits_renders_advertises_and_routes_cap_lsp_test() {
  let broker_actor = idle_broker()
  let found =
    query.Door(..door(), definition: fn(_) {
      Ok(query.Served(
        value: [query.Site(path: "a.gleam", line: 3, column: 1, text: "f")],
        warmth: query.Warm,
      ))
    })
  let config = codemode.over_lsp(config_for(broker_actor), Some(found))
  let seam = vet_policy.WorkspaceSeam
  let allowlist = codemode.seam_allowlist(config, seam)
  assert vet_policy.contains(allowlist, "cap/lsp")
  assert list.all(codemode_lsp.serviced_caps, list.contains(
    codemode.seam_caps_on(config, seam),
    _,
  ))
  assert string.contains(
    codemode_tool.description(codemode.seam(config)),
    "### cap/lsp",
  )

  let source = "import cap/lsp\npub fn main() { lsp.symbol(\"f\") }\n"
  let assert vet.Passed(_) = vet.vet(source, allowlist)

  let assert framing.CapOk(..) =
    routed(config, a_request("/work"), "lsp.definition", symbol_args("f"))

  // Extensions and resident hooks never inherit the door.
  assert !vet_policy.contains(
    codemode.seam_allowlist(config, vet_policy.ExtensionSeam),
    "cap/lsp",
  )
  assert !vet_policy.contains(
    codemode.seam_allowlist(config, vet_policy.ResidentSeam),
    "cap/lsp",
  )
  broker.stop(broker_actor)
}

// --- the applied rename ---------------------------------------------------

fn renaming(
  written: process.Subject(String),
  edits: List(query.FileEdit),
) -> query.Door {
  query.Door(..recording_door(written), prepare_rename: fn(_, _) {
    Ok(query.Served(value: edits, warmth: query.Warm))
  })
}

// A program's `lsp.rename` with `mode: apply` lands through the hashline
// path, and the door hears of the landed file.
pub fn an_applied_rename_lands_through_code_mode_test() {
  let broker_actor = idle_broker()
  let workspace = scratch("applied-rename")
  let assert Ok(Nil) = simplifile.write(workspace <> "/a.txt", "old\nkeep\n")
    as "the fixture file must be writable"
  let written = process.new_subject()
  let edit =
    query.FileEdit(
      path: "a.txt",
      base: "old\nkeep\n",
      edited: "new\nkeep\n",
      edits: 1,
    )
  let config =
    codemode.over_lsp(config_for(broker_actor), Some(renaming(written, [edit])))

  let assert framing.CapOk(..) =
    routed(
      config,
      a_request(workspace),
      "lsp.rename",
      list.append(symbol_args("old"), [
        #("new_name", msgpack.StringValue("new")),
        #("mode", msgpack.StringValue("apply")),
      ]),
    )
  assert simplifile.read(workspace <> "/a.txt") == Ok("new\nkeep\n")
  let assert [path] = drain(written)
  assert path == "a.txt"
  broker.stop(broker_actor)
}

// The protected list a program's `fs.write` is refused by refuses a
// rename's file too, and nothing is written anywhere.
pub fn an_applied_rename_respects_protected_paths_test() {
  let workspace = scratch("protected-rename")
  let assert Ok(Nil) = simplifile.create_directory_all(workspace <> "/.git")
    as "the protected directory must be creatable"
  let assert Ok(Nil) = simplifile.write(workspace <> "/.git/config", "old\n")
    as "the protected file must be writable in the fixture"
  let assert Ok(Nil) = simplifile.write(workspace <> "/a.txt", "old\n")
    as "the fixture file must be writable"
  let written = process.new_subject()
  let edits = [
    query.FileEdit(
      path: ".git/config",
      base: "old\n",
      edited: "new\n",
      edits: 1,
    ),
    query.FileEdit(path: "a.txt", base: "old\n", edited: "new\n", edits: 1),
  ]
  let apply =
    codemode_rename.rename(
      renaming(written, edits),
      filesystem: fs.real_filesystem(),
      workspace:,
      roots: [],
      protected: [workspace <> "/.git"],
    )

  let assert Ok(query.Served(value: report, ..)) =
    apply(query.SymbolQuery(symbol: "old", path: None, line: None), "new")
  let assert [
    query.Rejected(path: ".git/config", reason:),
    query.NotAttempted(path: "a.txt"),
  ] = report.files
  assert string.starts_with(reason, "permission denied:")
  assert simplifile.read(workspace <> "/.git/config") == Ok("old\n")
  assert simplifile.read(workspace <> "/a.txt") == Ok("old\n")
  assert drain(written) == []
}

// The finite SQL capability enters exactly the native LSP program scopes.
// A capture door by itself cannot grant imports, and installed extensions
// cannot inherit it from the session's code-mode host configuration.
pub fn finite_capture_inherits_native_lsp_scope_and_deadline_test() {
  let broker_actor = idle_broker()
  let seen = process.new_subject()
  let capture =
    observation.Door(collect: fn(_, control) {
      process.send(seen, control.deadline_ms)
      Error(observation.Changed("fixture changed"))
    })
  let base = config_for(broker_actor)
  let capture_only = codemode.over_lsp_observation(base, Some(capture))
  assert !vet_policy.contains(
    codemode.seam_allowlist(capture_only, vet_policy.WorkspaceSeam),
    "cap/lsp_sql",
  )
  let configured = capture_only |> codemode.over_lsp(Some(door()))
  list.each([vet_policy.WorkspaceSeam, vet_policy.OrchestrationSeam], fn(seam) {
    assert vet_policy.contains(
      codemode.seam_allowlist(configured, seam),
      "cap/lsp_sql",
    )
    assert list.contains(
      codemode.seam_caps_on(configured, seam),
      "lsp.snapshot",
    )
  })
  assert !vet_policy.contains(
    codemode.seam_allowlist(configured, vet_policy.ExtensionSeam),
    "cap/lsp_sql",
  )
  assert !list.contains(
    codemode.seam_caps_on(configured, vet_policy.ExtensionSeam),
    "lsp.snapshot",
  )
  let ask = a_request("/work")
  let built =
    codemode.exec_config(configured, ask, "/work/run", 123_456, widened_by: [])
  assert list.contains(
    built.satellite.ceilings,
    satellite.CapCeiling("lsp.snapshot", 4, "snapshot_ceiling"),
  )
  let answer =
    routed(configured, ask, "lsp.snapshot", [
      #("server", msgpack.StringValue("gleam")),
      #("root", msgpack.StringValue("/work")),
      #("outlines", msgpack.ArrayValue([])),
      #("targets", msgpack.ArrayValue([])),
    ])
  assert answer == framing.CapErr("observation_changed", "fixture changed")
  assert process.receive(seen, 100) == Ok(9_000_000)
  let call =
    satellite.CapRequest(
      cap: "lsp.snapshot",
      args: msgpack.MapValue([
        #(msgpack.StringValue("server"), msgpack.StringValue("gleam")),
        #(msgpack.StringValue("root"), msgpack.StringValue("/work")),
        #(msgpack.StringValue("outlines"), msgpack.ArrayValue([])),
        #(msgpack.StringValue("targets"), msgpack.ArrayValue([])),
      ]),
      identity: identity.run_phase(built.identity),
      base_policy: ask.base_policy,
      demand: ask.demand,
      env: [],
      cwd: "/work",
      ordinal: 0,
    )
  let _ = route(built, call)
  assert process.receive(seen, 100) == Ok(123_456)
  broker.stop(broker_actor)
}
