//// The imported-hook layer serving a real session, end to end.
////
//// Every other test of this layer holds a piece of it still: the
//// loader against files on disk, the gates against a stub `Effects`,
//// the runner against a jailed helper. None of them can answer the
//// question issue #350 actually asks, which is whether an operator's
//// `~/.claude/settings.json` — untouched, its commands written as
//// `~/hooks/...` — makes those hooks fire inside a session that boots
//// the way a real one boots. That question needs the whole assembly:
//// `serve.open_instance`, the session's own broker and jail, the
//// provider wiring, and the durable machine that owns the run-start
//// and run-end boundaries.
////
//// So this fixture boots one. The operator's home is a temporary
//// directory the test writes and `Settings.home` names, which is what
//// makes the `~` in every command resolve there: the server points a
//// hook process's `HOME` at that directory (`serve.hook_environment`)
//// and the shell expands the `~` against it. The machine's real home
//// is never read.
////
//// ## The shape of the run
////
//// Three scripted provider replies drive one operation across both
//// boundaries the gates sit on:
////
//// 1. plain text, so the run reaches its first finishable boundary
////    with no tool call behind it. The `Stop` hook is asked there, the
////    marker file does not exist yet, and it exits 2 — the contract's
////    blocking code — so the gate places a born-placed follow-up and
////    the run continues instead of finishing;
//// 2. a `bash` call that creates the marker. `PreToolUse` fires at the
////    clearance and `PostToolUse` at the settled result, both matched
////    on `Bash` through the Claude-side name;
//// 3. plain text again. The `Stop` hook is asked at the second
////    boundary, the marker is there, it exits 0, and the run finishes
////    `RunCompleted`.
////
//// The block is therefore observed rather than assumed: the follow-up
//// the gate placed is in the *second* provider request's body, which
//// is the only place a message that was never sent could not appear.
////
//// ## Where a hook may write
////
//// An imported hook runs in the session's own jail, whose single
//// writable root is the workspace. The stubs therefore append their
//// firing log to `$CLAUDE_PROJECT_DIR/fired.log` rather than to
//// anything under the operator's home: the home is where a hook's
//// *script* lives and the workspace is where its side effects land,
//// and that split is the layer's accepted difference from Claude
//// rather than an accident of this fixture. Using the variable also
//// makes the fixture fail if `CLAUDE_PROJECT_DIR` ever stops being
//// granted on the session base — the refusal is of the whole call,
//// before any process exists.

import broker/exec
import client/catalog
import client/codemode
import client/distillpass
import client/internal/ffi_os
import client/jobs
import client/schedule
import client/serve
import client/tui_e2e_test.{type EunitTest, Timeout}
import core/clock
import core/json
import core/message
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/int
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
import telemetry/level
import telemetry/log
import telemetry/record.{type Record}
import weft/actor

/// The whole budget: one real instance assembly, three scripted
/// provider turns, one jailed `bash` call and six jailed hook
/// processes. eunit's unchosen default is 5 s, which gleeunit scales to
/// 50 — close enough to the observed run that a slow host would report
/// `Timeout` at a line number rather than a failed assertion.
const test_timeout_seconds = 240

/// gleeunit runs eunit with `ScaleTimeouts(10)`, and that scale
/// multiplies a generator's own timeout too, so the number handed to
/// eunit is the number wanted divided by ten. Stated rather than folded
/// into the constant because the arithmetic is the trap: `Timeout(240,
/// _)` read at face value would be forty minutes.
const gleeunit_timeout_scale = 10

/// The line the `SessionStart` stub prints. It has to be findable in a
/// provider request body and impossible to confuse with anything the
/// harness writes on its own.
const session_start_line = "the operator keeps a checklist in NOTES.md"

/// The sentence the `Stop` stub writes to stderr while the marker is
/// absent. Exit 2 is the contract's blocking code and stderr is the
/// reason the model is shown, so this is the text that must reach the
/// second provider request.
const stop_block_reason = "the run may not finish until the marker exists"

/// The file the `bash` call creates, relative to the workspace, which
/// is the tool's own cwd and the jail's one writable root.
const marker_name = "marker"

/// A user-level collection of the ordinary shape, with four handlers
/// and nothing else: no owner fixture is loaded here, because what is
/// under test is the path a collection travels rather than any
/// particular collection's size. Every command is a `~` path, which is
/// the form ten of the sixteen entries in the reference collection use
/// and the one that only resolves because the hook process's `HOME` is
/// the operator's.
const settings_json = "{
  \"model\": \"opus\",
  \"hooks\": {
    \"SessionStart\": [
      { \"hooks\": [{ \"type\": \"command\",
                    \"command\": \"~/hooks/session-start.sh\",
                    \"timeout\": 30 }] }
    ],
    \"PreToolUse\": [
      { \"matcher\": \"Bash\",
        \"hooks\": [{ \"type\": \"command\",
                    \"command\": \"~/hooks/pre-tool.sh\",
                    \"timeout\": 30 }] }
    ],
    \"PostToolUse\": [
      { \"matcher\": \"Bash\",
        \"hooks\": [{ \"type\": \"command\",
                    \"command\": \"~/hooks/post-tool.sh\",
                    \"timeout\": 30 }] }
    ],
    \"Stop\": [
      { \"hooks\": [{ \"type\": \"command\",
                    \"command\": \"~/hooks/stop.sh\",
                    \"timeout\": 30 }] }
    ]
  }
}"

/// The acceptance case of issue #350, as a test rather than a claim: an
/// unedited user-level collection loads on a real boot, and its
/// `SessionStart`, `PreToolUse`, `PostToolUse` and `Stop` handlers all
/// fire at the harness moments the parity matrix assigns them.
pub fn an_unedited_user_collection_serves_a_real_session_test_() -> EunitTest {
  Timeout(test_timeout_seconds / gleeunit_timeout_scale, fn() {
    let rig = rig()
    let script = script()
    let records = process.new_subject()
    let logger =
      log.new(sink: log.to_subject(records), threshold: level.Warning)
    let assert Ok(instance) = serve.open_instance(settings(rig, script), logger)
      as "the imported-hook fixture must open a real instance"

    // The turn itself, through the instance's own writer and the real
    // provider wiring. `await_result` is what proves the second `Stop`
    // ask let the run finish: a gate that kept blocking would spend the
    // eight-follow-up cap and only then complete, and a gate that never
    // answered would time out here.
    let outcome = complete(instance)
    serve.close_instance(instance)

    let assert Ok(operation.RunLastResult(outcome: completion, ..)) = outcome
      as "the operation must settle through the real machine"
    assert completion == operation.RunCompleted(operation.CompletedByAssistant)

    // The four events fired, at their own moments and no others. The
    // log is the hooks' own account of themselves, written from inside
    // the jail.
    let fired = fired(rig)
    assert occurrences(fired, "SessionStart greet") == 1
    assert occurrences(fired, "PreToolUse guard") == 1
    assert occurrences(fired, "PostToolUse record") == 1
    assert occurrences(fired, "Stop gate") >= 2
      as "the Stop hook is asked at both finishable boundaries"

    // The `bash` call ran and had its effect, which is what turned the
    // second `Stop` ask from a block into a pass.
    assert simplifile.is_file(rig.workspace <> "/" <> marker_name) == Ok(True)

    // What the model was actually shown. The `SessionStart` context
    // rides the first request because `run_start` precedes the first
    // dispatch; the `Stop` block's follow-up rides the second because a
    // born-placed continuation is a committed entry before the
    // successor turn is planned. Asserting on the request bodies rather
    // than on the durable tree is deliberate: the transcript would show
    // a message that was written, and this shows one that was sent.
    let assert [first, second, ..] = bodies(script)
      as "the scripted provider must have been asked at least twice"
    assert string.contains(first, session_start_line)
    assert string.contains(first, "[SessionStart hook]")
    assert string.contains(second, "[Stop hook] " <> stop_block_reason)

    // Nothing was skipped. A user-level source with no trust record is
    // trusted on sight, so a skip line here would mean the collection
    // never loaded and every assertion above was about some other
    // session's hooks.
    let skips =
      drained(records, [])
      |> list.filter(fn(one) { one.event == "hooks.source_skipped" })
    assert skips == []
  })
}

// --- the operator's home ------------------------------------------------------

// Where one run's two directory trees live. The home is a sibling of
// the workspace rather than the machine's own: a fixture that read the
// developer's `HOME` would pass on their machine for a reason it could
// not state, and would write stub scripts into a directory they did not
// ask for.
type Rig {
  Rig(root: String, home: String, workspace: String)
}

fn rig() -> Rig {
  let assert Ok(here) = simplifile.current_directory()
    as "the test process must know where it is"
  let root =
    here
    <> "/build/hookserve-e2e-"
    <> int.to_string(ffi_os.system_time_ms())
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let rig = Rig(root:, home: root <> "/home", workspace: root <> "/work")

  // A previous run's tree under this name, removed before this one's is
  // made. The name carries a clock reading as well as the node-local
  // counter, because the counter restarts with the Erlang node and a
  // second run would otherwise inherit the first run's `fired.log` and
  // marker — which is exactly the state every assertion here reads.
  let assert Ok(Nil) = simplifile.delete_all([root])
    as "a previous run's fixture tree must be removable"
  let assert Ok(Nil) = simplifile.create_directory_all(rig.workspace)
    as "the fixture workspace must be creatable"
  write(rig.home <> "/.claude/settings.json", settings_json)
  stubs(rig)
  rig
}

// The four stub scripts the collection names. Each one drains stdin
// first, the way a real hook does: the event payload is the whole of
// stdin and the runner closes it after one write, so a stub that never
// read it would leave that half of the contract unexercised. Then it
// appends its own line to the workspace log.
fn stubs(rig: Rig) -> Nil {
  stub(rig, "session-start", "echo '" <> session_start_line <> "'\n")
  stub(rig, "pre-tool", "")
  stub(rig, "post-tool", "")

  // The gate that makes the run's shape observable: it blocks until the
  // `bash` call has created the marker, so the first boundary continues
  // the run and the second finishes it.
  stub(
    rig,
    "stop",
    "if [ -e \"$CLAUDE_PROJECT_DIR/"
      <> marker_name
      <> "\" ]; then exit 0; fi\n"
      <> "echo '"
      <> stop_block_reason
      <> "' >&2\n"
      <> "exit 2\n",
  )
}

// One stub script, written executable. The event's own name is the
// first word of the line it logs, which is what lets one `fired.log`
// answer for all four.
fn stub(rig: Rig, name: String, tail: String) -> Nil {
  let path = rig.home <> "/hooks/" <> name <> ".sh"
  write(
    path,
    "#!/bin/sh\n"
      <> "cat > /dev/null\n"
      <> "echo '"
      <> logged(name)
      <> "' >> \"$CLAUDE_PROJECT_DIR/fired.log\"\n"
      <> tail,
  )
  let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o755)
    as "a stub hook script must be executable"
  Nil
}

// The line each stub appends: the contract's event name, then the
// handler's own name so two handlers on one event stay distinguishable.
fn logged(name: String) -> String {
  case name {
    "session-start" -> "SessionStart greet"
    "pre-tool" -> "PreToolUse guard"
    "post-tool" -> "PostToolUse record"
    _stop -> "Stop gate"
  }
}

fn write(path: String, body: String) -> Nil {
  let assert Ok(directory) = string.split(path, "/") |> parent
    as "a fixture path must have a parent directory"
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
    as "the fixture directory must be creatable"
  let assert Ok(Nil) = simplifile.write(path, body)
    as "the fixture file must be writable"
  Nil
}

fn parent(segments: List(String)) -> Result(String, Nil) {
  case list.reverse(segments) {
    [_leaf, ..rest] -> Ok(string.join(list.reverse(rest), "/"))
    [] -> Error(Nil)
  }
}

// --- reading back what the hooks did -------------------------------------------

// The hooks' own log, which is absent rather than empty when nothing
// fired at all — a distinction worth keeping, since an empty string
// would satisfy every `contains` written against it.
fn fired(rig: Rig) -> String {
  let assert Ok(text) = simplifile.read(rig.workspace <> "/fired.log")
    as "the hooks must have written their log at all"
  text
}

fn occurrences(text: String, line: String) -> Int {
  string.split(text, "\n") |> list.count(fn(one) { one == line })
}

// Every log record the boot and the run delivered, drained without
// waiting: the sink sends from whichever process logged, and by the
// time the instance is closed every one of them has been sent.
fn drained(records: Subject(Record), seen: List(Record)) -> List(Record) {
  case process.receive(records, within: 0) {
    Ok(one) -> drained(records, [one, ..seen])
    Error(Nil) -> list.reverse(seen)
  }
}

// --- the scripted provider -----------------------------------------------------

// The three replies, and the request bodies they were answers to. The
// bodies are kept because the two injections this fixture asserts on
// are only observable in what went out on the wire.
type ScriptMessage {
  Dispatched(body: String, reply: Subject(Int))
  Bodies(reply: Subject(List(String)))
}

fn script() -> Subject(ScriptMessage) {
  let assert Ok(started) =
    actor.new([])
    |> actor.on_message(fn(seen: List(String), message) {
      case message {
        Dispatched(body:, reply:) -> {
          process.send(reply, list.length(seen) + 1)
          actor.continue([body, ..seen])
        }

        Bodies(reply:) -> {
          process.send(reply, list.reverse(seen))
          actor.continue(seen)
        }
      }
    })
    |> actor.start
    as "the provider script must start"
  started.data
}

fn bodies(script: Subject(ScriptMessage)) -> List(String) {
  actor.call(script, waiting: 1000, sending: fn(reply) { Bodies(reply) })
}

fn scripted_transport(script: Subject(ScriptMessage)) -> http.Transport {
  provider_test.transport(fn(request: http.HttpRequest, events) {
    let index =
      actor.call(script, waiting: 5000, sending: fn(reply) {
        Dispatched(request.body, reply)
      })

    // Turn two is the only one that calls a tool. Turn one has to end
    // the assistant's say without one, or the first finishable boundary
    // — the only place the `Stop` gate is asked before the marker
    // exists — would never be reached.
    let response = case index {
      1 -> text_turn("first", "nothing to do yet")
      2 ->
        tool_turn(
          "touch-marker",
          json.Object([
            #("command", json.String("touch " <> marker_name)),
          ]),
        )
      _ -> text_turn("last", "the marker is in place")
    }
    process.send(
      events,
      http.ResponseStatus(200, [#("content-type", "text/event-stream")]),
    )
    process.send(events, http.ResponseChunk(bit_array.from_string(response)))
    process.send(events, http.ResponseEnd)
  })
}

fn text_turn(id: String, text: String) -> String {
  started(id)
  <> sse(
    "content_block_start",
    "{\"type\":\"content_block_start\",\"index\":0,"
      <> "\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
  )
  <> sse(
    "content_block_delta",
    "{\"type\":\"content_block_delta\",\"index\":0,"
      <> "\"delta\":{\"type\":\"text_delta\",\"text\":\""
      <> text
      <> "\"}}",
  )
  <> sse("content_block_stop", "{\"type\":\"content_block_stop\",\"index\":0}")
  <> stopped("end_turn")
}

fn tool_turn(id: String, arguments: json.JsonValue) -> String {
  started(id)
  <> sse(
    "content_block_start",
    "{\"type\":\"content_block_start\",\"index\":0,"
      <> "\"content_block\":{\"type\":\"tool_use\",\"id\":\""
      <> id
      <> "\","
      <> "\"name\":\"bash\",\"input\":{}}}",
  )
  <> sse(
    "content_block_delta",
    "{\"type\":\"content_block_delta\",\"index\":0,"
      <> "\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":"
      <> json.to_string(json.String(json.to_string(arguments)))
      <> "}}",
  )
  <> sse("content_block_stop", "{\"type\":\"content_block_stop\",\"index\":0}")
  <> stopped("tool_use")
}

fn started(id: String) -> String {
  sse(
    "message_start",
    "{\"type\":\"message_start\",\"message\":{\"id\":\""
      <> id
      <> "\","
      <> "\"model\":\"loom-1\","
      <> "\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}",
  )
}

fn stopped(reason: String) -> String {
  sse(
    "message_delta",
    "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\""
      <> reason
      <> "\"},\"usage\":{\"output_tokens\":1}}",
  )
  <> sse("message_stop", "{\"type\":\"message_stop\"}")
}

fn sse(event: String, data: String) -> String {
  "event: " <> event <> "\ndata: " <> data <> "\n\n"
}

// --- the session ----------------------------------------------------------------

// One turn, admitted through the instance's own writer and awaited to
// settlement. The helper is checked out and back first for the reason
// `serve_test`'s own instance turn does it: an instance whose pool never
// handshook would otherwise fail later, inside the tool call, as a
// clearance refusal that reads like a policy decision.
fn complete(instance: serve.Instance) -> Result(operation.LastResult, Nil) {
  let assert Ok(helper) = exec.checkout(instance.pool, waiting: 5000)
    as "the instance must have a real, handshaken helper"
  exec.checkin(instance.pool, helper)
  let assert Ok(op) =
    api.prompt(instance.runtime, [
      message.UserMessage(
        content: [
          message.UserText(text: "run the fixture turn", text_signature: None),
        ],
        timestamp: 0,
        origin: None,
      ),
    ])
    as "the instance must admit through its own writer"
  api.await_result(instance.runtime, op, within_ms: 120_000)
}

fn settings(rig: Rig, script: Subject(ScriptMessage)) -> serve.Settings {
  let assert Ok(here) = simplifile.current_directory()
    as "the test process must know where it is"
  serve.Settings(
    secrets: secret.env(),
    secret_failures: [],
    session_path: rig.root <> "/session.db",
    domain_paths: None,
    // No listener: `open_instance` binds none, and the invalid address
    // is what proves it did not.
    bind_host: "not an interface",
    bind_port: -1,
    token_path: rig.root <> "/transport-only/daemon.token",
    workspace: rig.workspace,
    base_policy: serve.base_policy(rig.workspace),
    helper_path: here <> "/../sandbox/loom-exec",
    helper_pool_size: 2,
    session_id: "hookserve-e2e",
    demand: exec.BestEffort,
    gateway: gateway(script),
    catalog: scripted_catalog(),
    system: None,
    // The whole point of the fixture: the operator's home is this
    // temporary tree, so `~/hooks/...` resolves inside it and the
    // machine's own `HOME` is never read.
    home: Some(rig.home),
    model: machine_strand.ModelIdentity(provider: "acme", model_id: "loom-1"),
    context_window: 100_000,
    max_output_tokens: 4096,
    api: anthropic.api_name,
    compaction: operation.CompactionSettings(
      enabled: True,
      reserve_tokens: 16_384,
      keep_recent_tokens: 20_000,
    ),
    codemode_seed: rig.root <> "/no-such-seed",
    codemode_seams: codemode.WorkspaceOnly,
    rules: [],
    schedules: [],
    schedule_policy: schedule.ModelSchedulesOff,
    jobs_policy: jobs.default_policy,
    deactivated_tools: [],
    memory: distillpass.no_pass(),
    tools: catalog.default_tools(),
  )
}

fn gateway(script: Subject(ScriptMessage)) -> provider_gateway.Gateway {
  catalog.gateway(
    scripted_catalog(),
    transport: scripted_transport(script),
    secrets: secret.from_list([#("ACME_KEY", "hookserve-e2e-key")]),
    clock: clock.fixed(at: 0),
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
      ),
    ],
    roles: [#(model.Main, ["acme"])],
    mcp_servers: [],
  )
}
