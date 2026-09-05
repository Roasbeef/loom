//// Issue #149's exit criterion, end to end: **an ordinary session boot
//// distils, and a preference remembered in one session reaches the next
//// session's request bytes — with nobody running `client/distill` by
//// hand.**
////
//// `memory_persist_test` proves the same journey with the pipeline
//// called from the test. This file deletes that call. Every pass here
//// is started by `serve.boot` itself, through the supervised worker in
//// `client/distillpass`, and the only scripted things are the provider
//// transport (which answers the pipeline's consolidation turn over a
//// real SSE body, so the model turn is real as far as the gateway is
//// concerned) and the session's model catalogue.
////
//// The rest of the file is the retry surface, because the whole
//// argument for a once-per-boot pass is what happens when one does not
//// finish: a live source is skipped, a held memory lease is reported
//// and retried next boot, a provider failure leaves the digest where it
//// was, an interrupted pass leaves a store the next boot can finish
//// from, and a repository with nothing new says so rather than
//// rewriting the sidecar.

import broker/broker
import broker/exec
import broker/policy
import client/catalog
import client/codemode
import client/distillpass
import client/memory
import client/schedule
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
import support/tool_registry
import telemetry/level
import telemetry/log
import telemetry/record.{type Record}
import tools/remember
import tools/tool

// A home directory that does not exist, so a server booted here never
// picks up the developer's own `~/.agents/AGENTS.md`.
const empty_home = Some("build/no-operator-home")

// The preference the user states in the first session, which the second
// must know about without being told.
const preference = "the user prefers tabs over spaces in this repository"

// What the scripted consolidation turn writes memory back as.
const consolidated = "preference: " <> preference

// The marker `client/distill.consolidation_prompt` puts in the prompt,
// and the only thing the scripted transport dispatches on. Extraction
// prompts and ordinary generations do not carry it.
const consolidation_marker = "consolidating the durable memory"

// --- the exit criterion ------------------------------------------------------

/// Two separately booted sessions over one directory, and nothing calls
/// the pipeline: the first remembers a preference through the `remember`
/// door and closes, the second boots, distils on its own lifecycle, and
/// carries the digest in the bytes it sends.
pub fn a_remembered_preference_survives_two_boots_test() {
  let root = fresh_root("lifecycle")

  // --- session A, and the pass a boot runs with nothing to read -------
  let assert Ok(first) = serve.boot(settings(root, "a.db", quiet_gateway()))
    as "session A must boot"
  let assert Some(worker) = first.instance.memory_pass
    as "a default boot must run a distillation pass"

  // The live-lease rule, measured: the only session file in the
  // directory is this server's own, and the pass skipped it rather than
  // reading the session it runs inside.
  let assert Ok(distillpass.Completed(report)) =
    distillpass.settled(worker, timeout_ms: 30_000)
    as "session A's pass must settle"
  assert report.sources == 0
  assert report.skipped == 1
  assert report.digest == None

  // The note is written through the production `remember` seam, after
  // the pass has released the memory lease it held.
  let outcome =
    tool.dispatch(
      tool_registry.built_in(None, None, None, Some(a_seam(root)), None),
      a_ctx(root),
      remember.tool_name,
      note(preference),
    )
  assert outcome.is_error == False
  serve.shutdown(first)

  // --- session B: a fresh session file over the same directory --------
  let bodies = process.new_subject()
  let assert Ok(second) =
    serve.boot(settings(root, "b.db", recording_gateway(bodies)))
    as "session B must boot"
  let assert Some(worker) = second.instance.memory_pass
    as "session B must distil too"
  let assert Ok(distillpass.Completed(report)) =
    distillpass.settled(worker, timeout_ms: 30_000)
    as "session B's pass must settle"

  // One row consolidated out of the note, and a sidecar written.
  assert report.rows == 1
  let assert Some(bytes) = report.digest as "the pass must write a digest"
  assert bytes > 0

  let assert Ok(_op) =
    api.prompt(second.instance.runtime, [user("what do you know?")])
    as "the prompt must be accepted"
  let assert Ok(sent) = process.receive(bodies, within: 10_000)
    as "session B must dispatch one generation"
  serve.shutdown(second)

  // The criterion: the preference is in the bytes, fenced and
  // attributed, and no test line ever called `client/distill`.
  assert string.contains(sent, preference)
  assert string.contains(sent, memory.fence)
  assert string.contains(sent, "Distilled memory from this repository")

  // --- a third boot with nothing new: unchanged, and it says so -------
  let assert Some(before) = memory.read_digest(root <> "/loom-memory.digest")
    as "the sidecar must be on disk"
  let assert Ok(third) = serve.boot(settings(root, "c.db", quiet_gateway()))
    as "session C must boot"
  let assert Some(worker) = third.instance.memory_pass
    as "session C must distil too"
  let assert Ok(distillpass.Completed(report)) =
    distillpass.settled(worker, timeout_ms: 30_000)
    as "session C's pass must settle"
  serve.shutdown(third)

  // `None` is the vocabulary `memory.reconcile_digest` answers in for a
  // sidecar this pass never touched, and it is what the worker's line
  // reports as `digest=unchanged`.
  assert report.digest == None
  assert memory.read_digest(root <> "/loom-memory.digest") == Some(before)
}

// --- the retry surface --------------------------------------------------------

/// A memory lease somebody else holds is reported rather than waited
/// out, and the boot after it — with the lease gone — completes.
pub fn a_held_memory_lease_is_reported_and_retried_test() {
  let root = fresh_root("leased")
  remembered(root)

  // A foreign holder, opened exactly the way a concurrent `loom-distill`
  // would open it.
  //
  // The clock is far in the future on purpose: a lease's expiry is an
  // absolute instant, and the server's pass reads the real wall clock,
  // so a holder claiming under a fixture's own epoch would hand it an
  // already-expired lease to steal.
  let assert Ok(held) =
    memory.open(
      path: root <> "/loom-memory.db",
      owner: "somebody-else",
      lease_ttl_ms: 60_000,
      clock: distant(),
      generator: core_ids.generator(distant(), seed: 11),
    )
    as "the foreign holder must open the store"

  let assert Ok(booted) = serve.boot(settings(root, "a.db", scripted_gateway()))
    as "the server must boot while the memory lease is held"
  let assert Some(worker) = booted.instance.memory_pass
    as "the pass must be started"
  let assert Ok(distillpass.Refused(reason)) =
    distillpass.settled(worker, timeout_ms: 30_000)
    as "a held lease must refuse the pass"
  serve.shutdown(booted)

  // The refusal names the holder, which is the fact an operator acts on.
  assert string.contains(reason, "somebody-else")
  assert memory.read_digest(root <> "/loom-memory.digest") == None

  // The next boot, with the lease released: the same material, read
  // again, and consolidated.
  memory.close(held)
  let assert Ok(again) = serve.boot(settings(root, "b.db", scripted_gateway()))
    as "the second server must boot"
  let assert Some(worker) = again.instance.memory_pass
    as "the second pass must start"
  let assert Ok(distillpass.Completed(report)) =
    distillpass.settled(worker, timeout_ms: 30_000)
    as "the retry must settle"
  serve.shutdown(again)

  assert report.rows == 1
  let assert Some(body) = memory.read_digest(root <> "/loom-memory.digest")
    as "the retry must leave a digest"
  assert string.contains(body, preference)
}

/// A provider that refuses every request leaves the digest exactly where
/// it was and says why, in one `memory.distill.failed` line.
pub fn a_provider_failure_is_logged_and_changes_nothing_test() {
  let root = fresh_root("provider")
  remembered(root)

  let records = process.new_subject()
  let assert Ok(booted) =
    serve.boot_with(
      settings(root, "a.db", refusing_gateway()),
      logger: log.new(sink: log.to_subject(records), threshold: level.Debug),
    )
    as "the server must boot against a refusing provider"
  let assert Some(worker) = booted.instance.memory_pass
    as "the pass must be started"
  let assert Ok(distillpass.Refused(_reason)) =
    distillpass.settled(worker, timeout_ms: 30_000)
    as "a refused provider must refuse the pass"
  serve.shutdown(booted)

  // Nothing was written: no sidecar, and the note is still waiting for a
  // pass that can reach a model.
  assert memory.read_digest(root <> "/loom-memory.digest") == None
  assert logged(records, distillpass.failed_event)
}

/// A pass interrupted by shutdown leaves a store the next boot finishes
/// from: no half-written head, the note still pending, and the sidecar
/// untouched.
pub fn an_interrupted_pass_leaves_the_next_boot_a_consistent_store_test() {
  let root = fresh_root("interrupted")
  remembered(root)

  // A provider that never answers, so the consolidation turn is still in
  // flight when the shutdown reaps the worker.
  let assert Ok(booted) = serve.boot(settings(root, "a.db", hanging_gateway()))
    as "the server must boot"
  let assert Some(worker) = booted.instance.memory_pass
    as "the pass must be started"

  // The interruption, pinned. Every assertion below would hold just as
  // well if the pass had never started, so the test has to prove the
  // machine is still in `Running` when the shutdown arrives: a question
  // asked mid-pass is postponed, so this wait times out, and that
  // timeout *is* the proof that nothing had settled.
  let assert Error(_still_running) =
    distillpass.settled(worker, timeout_ms: 200)
    as "the pass must still be in flight when the shutdown reaps it"
  serve.shutdown(booted)

  // The store as the interruption left it. Opened on a clock far past
  // the run lease's TTL, which is exactly what a boot ten minutes later
  // does — and the reason the module doc calls the stale lease a
  // freshness cost rather than a lost row.
  let assert Ok(opened) =
    memory.open(
      path: root <> "/loom-memory.db",
      owner: "test-reader",
      lease_ttl_ms: 60_000,
      clock: distant(),
      generator: core_ids.generator(distant(), seed: 13),
    )
    as "the interrupted store must still open"
  let assert Ok(#(head, _seq)) = memory.head(opened)
    as "the head must be readable"
  let assert Ok(pending) = memory.notes_after(opened, 0, limit: 8)
    as "the notes must be readable"
  memory.close(opened)

  // Nothing committed, because the pipeline's write order puts the rows
  // and the head CAS after the turn that never came back.
  assert head == []
  assert list.length(pending) == 1
  assert memory.read_digest(root <> "/loom-memory.digest") == None

  // And the next boot finishes the job — with the lease the killed pass
  // could not release now gone, because closing the reader above is what
  // released it. A *real* next boot has no such helper: inside the
  // ten-minute run TTL it is refused with `loom-distill` named as the
  // holder (the case `a_held_memory_lease_is_reported_and_retried_test`
  // covers), and it is the TTL it waits out. What this leg proves is the
  // half that is about the store: the material survived the
  // interruption intact and consolidates when a pass can reach a model.
  let assert Ok(again) = serve.boot(settings(root, "b.db", scripted_gateway()))
    as "the next server must boot"
  let assert Some(worker) = again.instance.memory_pass
    as "the next pass must start"
  let assert Ok(distillpass.Completed(report)) =
    distillpass.settled(worker, timeout_ms: 30_000)
    as "the next pass must settle"
  serve.shutdown(again)

  assert report.rows == 1
  let assert Some(body) = memory.read_digest(root <> "/loom-memory.digest")
    as "the next pass must leave a digest"
  assert string.contains(body, preference)
}

/// `[memory] distill = "off"` starts no worker at all — the posture a
/// host with no rules takes, applied to a plane that is on by default.
pub fn an_opted_out_host_runs_no_pass_test() {
  let root = fresh_root("off")
  let configured =
    serve.Settings(
      ..settings(root, "a.db", quiet_gateway()),
      memory: distillpass.no_pass(),
    )
  let assert Ok(booted) = serve.boot(configured) as "the server must boot"
  assert booted.instance.memory_pass == None
  serve.shutdown(booted)

  // No pass means no memory session was ever opened, so the store the
  // first pass would have created is not there.
  assert simplifile.is_file(root <> "/loom-memory.db") == Ok(False)
}

// --- the table ----------------------------------------------------------------

/// The `[memory]` table's three answers, and the strictness around them.
pub fn the_memory_table_decodes_test() {
  assert distillpass.parse("") == Ok(distillpass.default_options())
  assert distillpass.parse("[memory]\ndistill = \"on-boot\"\n")
    == Ok(distillpass.default_options())
  assert distillpass.parse("[memory]\ndistill = \"off\"\n")
    == Ok(distillpass.no_pass())
  assert distillpass.parse("[memory]\ndistill = \"off\"\ndistill_wall_ms = 5\n")
    == Ok(distillpass.Options(cadence: distillpass.DistillsOff, wall_ms: 5))

  // A typoed key is a refusal, because an opt-out that distilled anyway
  // is the one failure an operator cannot see.
  let assert Error(unknown) = distillpass.parse("[memory]\ndistil = \"off\"\n")
    as "an unknown key must be refused"
  assert string.contains(unknown, "distil")
  let assert Error(bad_value) =
    distillpass.parse("[memory]\ndistill = \"no\"\n")
    as "an unknown cadence must be refused"
  assert string.contains(bad_value, "on-boot")
  let assert Error(bad_wall) =
    distillpass.parse("[memory]\ndistill_wall_ms = 0\n")
    as "a non-positive deadline must be refused"
  assert string.contains(bad_wall, "positive")

  // And a deadline above the memory session's own lease, which a pass
  // cannot outlive because nothing renews a lease but a commit.
  let assert Error(too_long) =
    distillpass.parse("[memory]\ndistill_wall_ms = 3600000\n")
    as "a deadline past the lease TTL must be refused"
  assert string.contains(too_long, "lease")

  // And the top-level check has to know the table exists, or a document
  // carrying it would be refused by the catalogue before this parser
  // ever saw it.
  assert catalog.parse(minimal_catalogue <> "[memory]\ndistill = \"off\"\n")
    |> result_is_ok
}

const minimal_catalogue = "[models.acme]
dialect = \"anthropic\"
base_url = \"https://acme.test\"
api_key_env = \"ACME_KEY\"
model_id = \"loom-1\"
context_window = 100000
max_output_tokens = 4096

[roles]
main = [\"acme\"]
"

fn result_is_ok(outcome: Result(a, b)) -> Bool {
  case outcome {
    Ok(_value) -> True
    Error(_reason) -> False
  }
}

// --- the rig ------------------------------------------------------------------

// A note written the way a model writes one, through the production
// seam, before any server exists to hold the memory lease.
fn remembered(root: String) -> Nil {
  let outcome =
    tool.dispatch(
      tool_registry.built_in(None, None, None, Some(a_seam(root)), None),
      a_ctx(root),
      remember.tool_name,
      note(preference),
    )
  assert outcome.is_error == False
  Nil
}

// Whether a named event reached the capturing sink. Drains what is
// there; the pass has already settled by the time this is asked, so
// everything it logged is in the mailbox.
fn logged(records: Subject(Record), event: String) -> Bool {
  case process.receive(records, within: 100) {
    Error(Nil) -> False
    Ok(found) ->
      case found.event == event {
        True -> True
        False -> logged(records, event)
      }
  }
}

fn a_seam(root: String) -> remember.Memory {
  memory.remember_seam(
    root <> "/loom-memory.db",
    clock: a_clock(),
    entropy: fn() { 7717 },
  )
}

fn note(text: String) -> core_json.JsonValue {
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
    deactivated_tools: [],
    memory: distillpass.default_options(),
    // Offline, three names: the jail every session had before the
    // `[tools]` table existed.
    tools: catalog.default_tools(),
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

fn gateway_over(transport: http.Transport) -> provider_gateway.Gateway {
  catalog.gateway(
    scripted_catalog(),
    transport:,
    secrets: secret.from_list([#("ACME_KEY", "test-key")]),
    clock: clock.fixed(at: 0),
  )
}

// The pass's own provider: a consolidation turn is answered with a real
// SSE body carrying the distillate, and anything else is refused
// terminally so nothing waits out a timeout.
fn scripted_gateway() -> provider_gateway.Gateway {
  gateway_over(
    provider_test.transport(fn(request: http.HttpRequest, out) {
      case string.contains(request.body, consolidation_marker) {
        True -> settled(out, consolidated)
        False -> refused(out)
      }
    }),
  )
}

// The same, plus a report of every ordinary generation's body — which is
// where the digest injection is asserted.
fn recording_gateway(bodies: Subject(String)) -> provider_gateway.Gateway {
  gateway_over(
    provider_test.transport(fn(request: http.HttpRequest, out) {
      case string.contains(request.body, consolidation_marker) {
        True -> settled(out, consolidated)
        False -> {
          process.send(bodies, request.body)
          refused(out)
        }
      }
    }),
  )
}

// A provider nothing asks: the passes in these lanes have nothing to
// consolidate, so a request arriving here would itself be the failure.
fn quiet_gateway() -> provider_gateway.Gateway {
  gateway_over(provider_test.transport(fn(_request, out) { refused(out) }))
}

// Every request refused terminally, which is what a pass meets when the
// provider is down.
fn refusing_gateway() -> provider_gateway.Gateway {
  gateway_over(provider_test.transport(fn(_request, out) { refused(out) }))
}

// A provider that never answers *and never fails*, so a pass really is
// still in flight when the shutdown reaps it.
//
// `provider_test.silent()` is not this: its owner replays nothing and
// then exits, which the stream reads as a terminal transport failure, so
// a pass over it settles in milliseconds. Sleeping on the owner process
// is what holds the request open — and what the interruption test needs,
// since a settled pass would prove nothing about an interrupted one.
fn hanging_gateway() -> provider_gateway.Gateway {
  gateway_over(
    provider_test.transport(fn(_request, _out) { process.sleep_forever() }),
  )
}

fn settled(out: Subject(http.HttpEvent), text: String) -> Nil {
  process.send(
    out,
    http.ResponseStatus(status: 200, headers: [
      #("content-type", "text/event-stream"),
    ]),
  )
  process.send(out, http.ResponseChunk(chunk: <<sse(text):utf8>>))
  process.send(out, http.ResponseEnd)
}

fn refused(out: Subject(http.HttpEvent)) -> Nil {
  process.send(out, http.ResponseStatus(status: 400, headers: []))
  process.send(
    out,
    http.ResponseChunk(chunk: <<
      "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"scripted\"}}":utf8,
    >>),
  )
  process.send(out, http.ResponseEnd)
}

// One settled anthropic message, as the adapter reads it off the wire.
fn sse(text: String) -> String {
  event(
    "message_start",
    "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_lifecycle\","
      <> "\"model\":\"loom-1\",\"usage\":{\"input_tokens\":10,"
      <> "\"output_tokens\":1}}}",
  )
  <> event(
    "content_block_start",
    "{\"type\":\"content_block_start\",\"index\":0,"
      <> "\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
  )
  <> event(
    "content_block_delta",
    "{\"type\":\"content_block_delta\",\"index\":0,"
      <> "\"delta\":{\"type\":\"text_delta\",\"text\":\""
      <> text
      <> "\"}}",
  )
  <> event(
    "message_delta",
    "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},"
      <> "\"usage\":{\"output_tokens\":6}}",
  )
  <> event("message_stop", "{\"type\":\"message_stop\"}")
}

fn event(name: String, data: String) -> String {
  "event: " <> name <> "\ndata: " <> data <> "\n\n"
}

fn user(text: String) -> message.AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: 0,
  )
}

// A clock past every lease this tree can take, which is what a reader
// arriving after an interruption's ten-minute TTL sees.
fn distant() -> clock.Clock {
  clock.fixed(at: 9_000_000_000_000)
}

fn a_clock() -> clock.Clock {
  clock.stepping(from: 1_756_000_000_000, by: 3)
}

// Absolute, because the workspace root becomes the base policy's
// writable root and `serve.base_policy_fault` refuses a boot on a policy
// whose paths the jail could not accept.
fn fresh_root(lane: String) -> String {
  let relative = "build/test_db/memory-lifecycle-" <> lane
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
