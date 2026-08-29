//// Memory stage M2's exit criterion, end to end: **a preference
//// remembered in one session reaches the next session's request bytes,
//// fenced and attributed.**
////
//// Three real servers' worth of machinery and one scripted thing. Two
//// `serve.boot`s over two real SQLite session files in one directory,
//// with the real memory plane wired by the real boot path — the memory
//// store created by the boot's own probe, the digest read by the boot's
//// own hook, the base policy assembled by the boot's own protection.
//// The `remember` call goes through the production registry. The
//// distillation run is `client/distill.run`. Only two things are
//// scripted: the pipeline's model turns, through the `Distiller` seam,
//// and the provider transport, which records the request body and then
//// fails the attempt so the run drains at once.
////
//// The assertion is on **the bytes on the wire**, not on the projection
//// and not on the hook's return value: what matters is that the digest
//// is in the request the second session actually sends.

import broker/broker
import broker/exec
import broker/policy
import client/catalog
import client/codemode
import client/distill
import client/memory
import client/serve
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
import tools/remember
import tools/tool

// The preference the user states in session A and the second session
// must know about without being told.
const preference = "the user prefers tabs over spaces in this repository"

// What the scripted consolidation turn writes memory back as.
const consolidated = "preference: " <> preference

// --- the exit criterion -----------------------------------------------------

pub fn a_remembered_preference_reaches_the_next_sessions_bytes_test() {
  let root = fresh_root("persist")

  // --- session A: a real server, and the memory door it registers ------
  let assert Ok(first) = serve.boot(settings(root, "a.db", dead_gateway()))
    as "session A must boot"
  // The door is really registered on this host: the pinned system prompt
  // lists the session's tools, and `remember` is among them.
  assert string.contains(first.prompt.text, remember.tool_name)
  // The boot's probe is lease-free and creates nothing: a boot that
  // opened the store would take its writer lease, and one arriving
  // during a distillation run would steal that run's. The door is
  // registered anyway — an absent store is the ordinary state of a
  // repository that has never remembered anything.
  let assert Ok(False) = simplifile.is_file(root <> "/loom-memory.db")
    as "the boot must not create the memory store"
  // Nothing is injected yet: no distillation has run, so there is no
  // sidecar and the hook has nothing to say.
  assert memory.read_digest(root <> "/loom-memory.digest") == None

  let outcome =
    tool.dispatch(
      serve.registry(None, None, None, Some(a_seam(root))),
      a_ctx(root),
      remember.tool_name,
      core_json_note(preference),
    )
  assert outcome.is_error == False
  // The first note is what creates the store.
  let assert Ok(True) = simplifile.is_file(root <> "/loom-memory.db")
    as "the first remembered note must create the memory store"
  serve.shutdown(first)

  // --- the pipeline, for real ------------------------------------------
  let assert Ok(report) =
    distill.run(
      distill.config_for(
        root,
        scripted_distiller(),
        clock: a_clock(),
        entropy: fn() { 8191 },
      ),
    )
    as "the distillation run must succeed"
  assert report.rows == 1
  let assert Some(body) = memory.read_digest(root <> "/loom-memory.digest")
    as "the run must leave a digest"
  assert string.contains(body, preference)

  // --- session B: a fresh session file over the same memory ------------
  let bodies = process.new_subject()
  let assert Ok(second) =
    serve.boot(settings(root, "b.db", recording_gateway(bodies)))
    as "session B must boot"
  let assert Ok(_op) = api.prompt(second.runtime, [user("what do you know?")])
    as "the prompt must be accepted"
  let assert Ok(sent) = process.receive(bodies, within: 10_000)
    as "session B must dispatch one generation"
  serve.shutdown(second)

  // The exit criterion: the preference is in the bytes, inside the
  // fence, under the attribution — and it got there without anyone
  // telling session B about session A.
  assert string.contains(sent, preference)
  assert string.contains(sent, "loom-memory")
  assert string.contains(sent, "Distilled memory from this repository")
  assert string.contains(sent, "heuristic context")
}

/// The other half of the same mechanism: a directory with no digest
/// injects nothing at all. Memory is scoped to its own session
/// directory, so a server booted anywhere else spends no tokens on it.
pub fn a_session_with_no_digest_beside_it_injects_nothing_test() {
  let root = fresh_root("empty")
  let bodies = process.new_subject()
  let assert Ok(booted) =
    serve.boot(settings(root, "a.db", recording_gateway(bodies)))
    as "the server must boot"
  let assert Ok(_op) = api.prompt(booted.runtime, [user("hello")])
    as "the prompt must be accepted"
  let assert Ok(sent) = process.receive(bodies, within: 10_000)
    as "the boot must dispatch one generation"
  serve.shutdown(booted)

  assert string.contains(sent, "Distilled memory from this repository") == False
  assert string.contains(sent, memory.fence) == False
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
  let digest = "/repo/loom-memory.digest"

  // The ordinary layout: the session directory is outside the
  // workspace, so nothing writable reaches these files and nothing is
  // added to the mask list.
  let outside = policy.workspace_default("/repo/work")
  let unreached = serve.protecting_memory(outside, store, digest)
  assert unreached.protected == outside.protected

  // The layout where it matters: a writable root covers the session
  // directory, so both files — and the store's WAL family — are barred.
  let inside = policy.workspace_default("/repo")
  let reached = serve.protecting_memory(inside, store, digest)
  assert list.contains(reached.protected, store)
  assert list.contains(reached.protected, digest)
  assert list.contains(reached.protected, store <> "-wal")
  assert list.contains(reached.protected, store <> "-shm")
  // Whatever was already protected stays protected.
  assert list.all(inside.protected, list.contains(reached.protected, _))
}

// --- the rig ----------------------------------------------------------------

fn scripted_distiller() -> distill.Distiller {
  distill.Distiller(ask: fn(prompt) {
    case string.contains(prompt, "consolidating the durable memory") {
      True -> Ok(distill.Answer(text: consolidated, usage: usage(9)))
      False -> Ok(distill.Answer(text: "nothing", usage: usage(3)))
    }
  })
}

fn a_seam(root: String) -> remember.Memory {
  memory.remember_seam(
    root <> "/loom-memory.db",
    clock: a_clock(),
    entropy: fn() { 7717 },
  )
}

fn core_json_note(text: String) -> core_json.JsonValue {
  core_json.Object([#("note", core_json.String(text))])
}

fn settings(
  root: String,
  file: String,
  gateway: provider_gateway.Gateway,
) -> serve.Settings {
  serve.Settings(
    session_path: root <> "/" <> file,
    bind_host: "127.0.0.1",
    bind_port: 0,
    token_path: root <> "/" <> file <> ".token",
    workspace: root <> "/work",
    base_policy: serve.base_policy(root <> "/work"),
    helper_path: "/bin/sh",
    helper_pool_size: 2,
    session_id: file,
    demand: exec.BestEffort,
    gateway:,
    catalog: scripted_catalog(),
    system: None,
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
      ),
    ],
    roles: [#(model.Main, ["acme"])],
    mcp_servers: [],
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
  )
}

fn usage(tokens: Int) -> message.Usage {
  message.Usage(
    input: tokens,
    output: 0,
    cache_read: 0,
    cache_write: 0,
    cache_write_1h: None,
    reasoning: None,
    total_tokens: tokens,
    cost: message.UsageCost(
      input: 0.0,
      output: 0.0,
      cache_read: 0.0,
      cache_write: 0.0,
      total: 0.0,
    ),
  )
}

fn a_clock() -> clock.Clock {
  clock.stepping(from: 1_756_000_000_000, by: 3)
}

// Absolute, because the workspace root becomes the base policy's
// writable root and `serve.base_policy_fault` refuses a boot on a policy
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
