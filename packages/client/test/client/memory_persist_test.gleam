//// The memory plane's end to end journey: **a note remembered in one session
//// reaches the next session's request bytes, fenced and attributed.**
////
//// Real servers over real SQLite session files in one directory, with the
//// real memory plane wired by the real boot path: the memory store created
//// by the first `remember` call, the notes index rebuilt by the boot's own
//// session open and read by the boot's own hook, the base policy assembled
//// by the boot's own protection. The `remember` call goes through the
//// production registry. Only the provider transport is scripted: it records
//// the request body and then fails the attempt so the run drains at once.
////
//// The assertion is on **the bytes on the wire**, not on the projection and
//// not on the hook's return value: what matters is that the index is in the
//// request the second session actually sends.

import broker/broker
import broker/exec
import broker/policy
import client/catalog
import client/codemode
import client/internal/ffi_os
import client/jobs
import client/memory
import client/memory_config
import client/retryconf
import client/schedule
import client/serve
import client/workspace_policy
import core/clock
import core/ids as core_ids
import core/json as core_json
import core/message
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/operation
import machine/strand as machine_strand
import provider/adapter/anthropic
import provider/gateway as provider_gateway
import provider/http
import provider/model
import provider/secret
import runtime/api
import simplifile
import support/provider as provider_test
import support/tool_registry
import telemetry/log
import tools/directory_access
import tools/remember
import tools/tool

// A home directory that does not exist, so a server booted here never
// picks up the developer's own `~/.agents/AGENTS.md`. A home with no
// global default is silent, which is what keeps these assertions about
// the prompt pack and the workspace alone.
const empty_home = Some("build/no-operator-home")

// The preference the user states in session A and the second session
// must know about without being told.
const preference = "the user prefers tabs over spaces in this repository"

// --- the exit criterion -----------------------------------------------------

pub fn a_remembered_note_reaches_the_next_sessions_bytes_test() {
  let root = fresh_root("persist")

  // --- session A: a real server, and the memory door it registers ------
  let assert Ok(first) = serve.boot(settings(root, "a.db", dead_gateway()))
    as "session A must boot"
  // The door is really registered on this host: the pinned system prompt
  // lists the session's tools, and `remember` is among them.
  assert string.contains(first.instance.prompt.text, remember.tool_name)
  // The boot's probe is lease-free and creates nothing: a boot that
  // opened the store would take its writer lease. The door is registered
  // anyway, because an absent store is the ordinary state of a repository
  // that has never remembered anything.
  let assert Ok(False) = simplifile.is_file(root <> "/loom-memory.db")
    as "the boot must not create the memory store"
  assert memory.read_notes_index(root <> "/loom-memory.notes") == None

  let outcome =
    tool.dispatch(
      tool_registry.built_in(None, None, None, Some(a_seam(root)), None),
      a_ctx(root),
      remember.tool_name,
      core_json_note(preference),
    )
  assert outcome.is_error == False
  // The first note is what creates the store.
  let assert Ok(True) = simplifile.is_file(root <> "/loom-memory.db")
    as "the first remembered note must create the memory store"
  serve.shutdown(first)

  // --- session B: a fresh session file over the same memory ------------
  let bodies = process.new_subject()
  let assert Ok(second) =
    serve.boot(settings(root, "b.db", recording_gateway(bodies)))
    as "session B must boot"
  let assert Ok(_op) =
    api.prompt(second.instance.runtime, [user("what do you know?")])
    as "the prompt must be accepted"
  let assert Ok(sent) = process.receive(bodies, within: 10_000)
    as "session B must dispatch one generation"
  serve.shutdown(second)

  // The exit criterion: the note is in the bytes, inside the fence, under
  // the attribution, and it got there without anyone telling session B
  // about session A.
  assert string.contains(sent, "a note: for the tests")
  assert string.contains(sent, "loom-notes")
  assert string.contains(sent, "Notes saved in this repository")
  assert string.contains(sent, "heuristic")
}

// --- the notes index --------------------------------------------------------

// One run's request bytes from a fresh server over `root` with `memory`
// settings: boot, send one prompt, record the body, shut down.
fn request_bytes(
  root: String,
  file: String,
  memory: memory_config.Options,
) -> String {
  let bodies = process.new_subject()
  let configured =
    serve.Settings(..settings(root, file, recording_gateway(bodies)), memory:)
  let assert Ok(booted) = serve.boot(configured) as "the server must boot"
  let assert Ok(_op) =
    api.prompt(booted.instance.runtime, [user("what do you know?")])
    as "the prompt must be accepted"
  let assert Ok(sent) = process.receive(bodies, within: 10_000)
    as "the run must dispatch one generation"
  serve.shutdown(booted)
  sent
}

fn remember_preference(root: String) -> Nil {
  let outcome =
    tool.dispatch(
      tool_registry.built_in(None, None, None, Some(a_seam(root)), None),
      a_ctx(root),
      remember.tool_name,
      core_json_note(preference),
    )
  assert outcome.is_error == False
  Nil
}

fn occurrences(text: String, needle: String) -> Int {
  list.length(string.split(text, needle)) - 1
}

/// With the default settings a repository that has notes starts each run
/// with exactly one message carrying their index: titles and descriptions
/// under the notes' own fence and attribution, not the notes' bodies.
pub fn the_default_host_injects_the_notes_index_test() {
  let root = fresh_root("notes-default")
  remember_preference(root)
  let sent = request_bytes(root, "b.db", memory_config.default_options())

  assert occurrences(sent, "Notes saved in this repository by earlier") == 1
  assert occurrences(sent, "```loom-notes") == 1
  assert string.contains(sent, "a note: for the tests")
  assert string.contains(sent, "(fact, 2025-08-24)")
  // The index names the note; the body is fetched on demand.
  assert !string.contains(sent, preference)
  // And it is not the removed digest's fence.
  assert !string.contains(sent, "```loom-memory")
}

/// A repository with no notes sees no extra message at all.
pub fn a_repository_without_notes_sees_no_memory_message_test() {
  let root = fresh_root("notes-none")
  let sent = request_bytes(root, "a.db", memory_config.default_options())
  assert !string.contains(sent, "Notes saved in this repository")
  assert !string.contains(sent, "loom-notes")
}

/// `inject = "off"` injects nothing, notes or no notes.
pub fn inject_off_hides_the_notes_index_test() {
  let root = fresh_root("notes-off")
  remember_preference(root)
  assert simplifile.is_file(root <> "/loom-memory.notes") == Ok(True)
  let sent =
    request_bytes(
      root,
      "b.db",
      memory_config.Options(inject: memory_config.InjectsNothing, retired: []),
    )
  assert !string.contains(sent, "Notes saved in this repository")
  assert !string.contains(sent, "a note: for the tests")
}

/// Notes written before the index existed, or by a release that did not
/// maintain it, are indexed when a session opens, so the first run already
/// carries them. The sidecar is rebuilt from the store without a note being
/// written.
pub fn a_session_open_indexes_notes_written_before_the_index_test() {
  let root = fresh_root("notes-upgrade")
  remember_preference(root)
  let index = root <> "/loom-memory.notes"
  let assert Ok(Nil) = simplifile.delete(index)
  assert simplifile.is_file(index) == Ok(False)

  let sent = request_bytes(root, "b.db", memory_config.default_options())

  assert simplifile.is_file(index) == Ok(True)
  assert occurrences(sent, "Notes saved in this repository by earlier") == 1
  assert string.contains(sent, "a note: for the tests")
}

/// A busy memory writer does not prevent startup or replace its published
/// index. The first run still receives the last complete sidecar.
pub fn a_session_open_keeps_the_index_while_memory_is_busy_test() {
  let root = fresh_root("notes-busy")
  remember_preference(root)
  let store = root <> "/loom-memory.db"
  let index = root <> "/loom-memory.notes"
  let assert Ok(current) = simplifile.read(index)
    as "the note has a published index"
  let clock = clock.from_function(ffi_os.system_time_ms)
  let assert Ok(holder) =
    memory.open(
      path: store,
      owner: "busy-memory-writer",
      lease_ttl_ms: memory.lease_ttl_ms,
      clock:,
      generator: core_ids.generator(clock, seed: 31),
    )
    as "the concurrent writer holds the memory lease"

  let sent = request_bytes(root, "b.db", memory_config.default_options())
  assert simplifile.read(index) == Ok(current)
  assert string.contains(sent, "a note: for the tests")
  let assert Error(memory.MemoryHeld(owner: "busy-memory-writer")) =
    memory.open(
      path: store,
      owner: "competing-writer",
      lease_ttl_ms: memory.lease_ttl_ms,
      clock:,
      generator: core_ids.generator(clock, seed: 37),
    )
    as "startup leaves the concurrent writer's lease intact"
  memory.close(holder)
}

/// With `inject = "off"` the open leaves the sidecar alone: nothing reads it,
/// so rebuilding it would be work for no run.
pub fn a_session_open_does_not_rebuild_the_index_when_injection_is_off_test() {
  let root = fresh_root("notes-upgrade-off")
  remember_preference(root)
  let index = root <> "/loom-memory.notes"
  let assert Ok(Nil) = simplifile.delete(index)

  let sent =
    request_bytes(
      root,
      "b.db",
      memory_config.Options(inject: memory_config.InjectsNothing, retired: []),
    )

  assert simplifile.is_file(index) == Ok(False)
  assert !string.contains(sent, "Notes saved in this repository")
}

// --- the conditional protection ---------------------------------------------

/// The memory files join `protected` exactly where a writable root
/// reaches them, and nowhere else.
///
/// Both halves are the point. Protecting them unconditionally would put
/// a *missing* path under a read-only parent into the jail's mask list,
/// which the jail refuses — the failure that once made every jailed call
/// in the ordinary session-outside-the-workspace layout fail. Protecting
/// them never would leave a model-writable channel into every later
/// session's context.
pub fn memory_is_protected_where_a_write_could_reach_it_test() {
  let store = "/repo/loom-memory.db"
  let notes = "/repo/loom-memory.notes"

  // The ordinary layout: the session directory is outside the
  // workspace, so nothing writable reaches these files and nothing is
  // added to the mask list.
  let outside = policy.workspace_default("/repo/work")
  let unreached = workspace_policy.protecting_memory(outside, store, notes)
  assert unreached.protected == outside.protected

  // The layout where it matters: a writable root covers the session
  // directory, so both files, and the store's WAL family, are barred.
  let inside = policy.workspace_default("/repo")
  let reached = workspace_policy.protecting_memory(inside, store, notes)
  assert list.contains(reached.protected, store)
  assert list.contains(reached.protected, notes)
  assert list.contains(reached.protected, store <> "-wal")
  assert list.contains(reached.protected, store <> "-shm")
  // Whatever was already protected stays protected.
  assert list.all(inside.protected, list.contains(reached.protected, _))
}

// --- the rig ----------------------------------------------------------------

fn a_seam(root: String) -> remember.Memory {
  memory.remember_seam(
    root <> "/loom-memory.db",
    clock: a_clock(),
    entropy: fn() { 7717 },
    logger: log.discard(),
  )
}

fn core_json_note(text: String) -> core_json.JsonValue {
  core_json.Object([
    #("title", core_json.String("a note")),
    #("description", core_json.String("for the tests")),
    #("kind", core_json.String("fact")),
    #("note", core_json.String(text)),
  ])
}

fn settings(
  root: String,
  file: String,
  gateway: provider_gateway.Gateway,
) -> serve.Settings {
  let assert Ok(here) = simplifile.current_directory()
    as "the fixture locates its protocol-speaking helper"
  serve.Settings(
    peer_directory: None,
    peer_defaults: None,
    remote_reach: None,
    deadline_tick_ms: None,
    depth_cap: None,
    metering: None,
    spawner: None,
    laptop: None,
    first_prompt: None,
    profile_desk: None,
    codemode_sockets: None,
    secrets: secret.env(),
    secret_failures: [],
    session_path: root <> "/" <> file,
    domain_paths: option.None,
    bind_host: "127.0.0.1",
    bind_port: 0,
    token_path: root <> "/" <> file <> ".token",
    workspace: root <> "/work",
    base_policy: workspace_policy.base_policy(root <> "/work"),
    helper_path: here <> "/../sandbox/loom-exec",
    helper_pool_size: 2,
    session_id: file,
    demand: exec.BestEffort,
    gateway:,
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
    codemode_seed: root <> "/no-such-seed",
    codemode_seams: codemode.WorkspaceOnly,
    rules: [],
    schedules: [],
    schedule_policy: schedule.ModelSchedulesOff,
    jobs_policy: jobs.default_policy,
    retry_policy: retryconf.default_policy,
    deactivated_tools: [],
    memory: memory_config.default_options(),
    // Offline, three names: the jail every session had before the
    // `[tools]` table existed.
    tools: catalog.default_tools(),
    advisor: None,
    go_caches: None,
  )
}

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
        vision: catalog.TextOnly,
        max_images: 8,
        cyber_access: None,
        service_tier: None,
      ),
    ],
    roles: [#(model.Main, ["acme"])],
    profiles: [],
    mcp_servers: [],
    lsp_servers: [],
  )
}

fn dead_gateway() -> provider_gateway.Gateway {
  catalog.gateway(
    scripted_catalog(),
    transport: provider_test.silent(),
    secrets: secret.from_list([#("ACME_KEY", "test-key")]),
    clock: clock.fixed(at: 0),
  )
}

// A gateway whose transport reports the request body it was handed and
// then fails the attempt terminally, so the run drains at once instead
// of waiting out a provider timeout. `serve_test`'s own arrangement.
fn recording_gateway(bodies: Subject(String)) -> provider_gateway.Gateway {
  catalog.gateway(
    scripted_catalog(),
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
    secrets: secret.from_list([#("ACME_KEY", "test-key")]),
    clock: clock.fixed(at: 0),
  )
}

fn user(text: String) -> message.AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: 0,
    origin: None,
  )
}

fn a_clock() -> clock.Clock {
  clock.stepping(from: 1_756_000_000_000, by: 3)
}

// Absolute, because the workspace root becomes the base policy's
// writable root and `workspace_policy.base_policy_fault` refuses a boot on a policy
// whose paths the jail could not accept.
fn fresh_root(lane: String) -> String {
  let relative = "build/test_db/memory-persist-" <> lane
  let _stale = simplifile.delete(relative)
  let assert Ok(Nil) = simplifile.create_directory_all(relative <> "/work")
    as "the test root must be creatable"
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner must have a working directory"
  here <> "/" <> relative
}

fn a_ctx(root: String) -> tool.Ctx {
  let workspace = root <> "/work"
  let #(op_id, _generator) =
    core_ids.mint_op(core_ids.generator(clock.fixed(at: 0), seed: 3))
  tool.Ctx(
    directory_access: directory_access.none(),
    workspace:,
    strand: "main",
    op_id:,
    step_id: "step-1",
    source_index: 0,
    base_policy: policy.workspace_default(workspace),
    grants: [],
    demand: exec.BestEffort,
    env: [],
    clock: clock.fixed(at: 0),
    filesystem: dead_filesystem(),
    blob_root: workspace <> "/.blobs",
    clear_call: fn(_spec, _events) { Error(broker.BrokerUnavailable) },
    raise_refusal: tool.no_raise(),
    observe_output: tool.ignore_output(),
  )
}

fn dead_filesystem() -> tool.FileSystem {
  tool.FileSystem(
    read: fn(path) { Error(tool.FsNotFound(path:)) },
    write: fn(path, _bytes) { Error(tool.FsNotFound(path:)) },
    create_directory_all: fn(path) { Error(tool.FsNotFound(path:)) },
    is_file: fn(_path) { Ok(False) },
    read_link: fn(_path) { Ok(tool.LinkMissing) },
    rename: fn(from, _to) { Error(tool.FsNotFound(path: from)) },
  )
}
