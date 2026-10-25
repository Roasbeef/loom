//// Test support: a scripted in-process provider and the small builders the
//// runner's tests share.
////
//// The provider is a `provider/http.Transport` that answers from memory, so
//// no socket is opened and no model is involved. It follows the request
//// body: a prompt carrying `WRITE[<path>=<content>]` is answered with one
//// `fs_write` tool call, the request that carries the tool result is answered
//// with a closing text, and a prompt carrying `STALL` is never answered. That
//// is enough to drive a real jailed session through a real tool call and
//// leave a file for the grader, which is everything the runner's lifecycle
//// needs and nothing about a model.
////
//// The transport honours the same contract as the replay lane's: a parked
//// weft task per request, released by the begin permit, its scope the drain
//// witness.

import client/catalog.{type Catalog}
import client/serve.{type Settings}
import core/json
import eval/arm.{type Arm, Any, Arm, Knobs, SystemSuffix, Target}
import eval/plan.{type Plan, Budgets, Clean, Harness, Plan, Quick}
import eval/run_cli
import eval/task.{type Task, ExpectedFiles, HandWritten, Inline, Task}
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import provider/http.{type Transport}
import provider/model
import provider/pricing
import provider/secret
import simplifile
import weft
import weft/actor

/// The EUnit timeout wrapper: a generator named `*_test_` returning this is
/// run with the given number of seconds instead of the five a bare test gets.
pub type EunitTest {
  Timeout(seconds: Int, body: fn() -> Nil)
}

/// Whether this checkout has what a real session needs: the jail helper and
/// the offline code-mode seed. A test that needs them prints a skip line to
/// standard error and passes when they are absent.
pub fn available() -> Bool {
  result.is_ok(bootstrap.find_executable("../sandbox/loom-exec"))
  && result.is_ok(bootstrap.canonical_directory("../../build/codemode-seed"))
}

/// Runs `body` only when a real session can be opened here.
pub fn when_available(name: String, body: fn() -> Nil) -> Nil {
  case available() {
    True -> body()
    False -> echo_skip(name)
  }
}

fn echo_skip(name: String) -> Nil {
  io.println_error("SKIP " <> name <> ": the jail helper or seed is absent")
}

/// A fresh canonical directory under this package's `build/`, never `/tmp`.
pub fn scratch(name: String) -> String {
  let assert Ok(here) = simplifile.current_directory() as "the test has a cwd"
  let path =
    here
    <> "/build/eval-test/"
    <> name
    <> "-"
    <> int.to_string(bootstrap.system_time_ms())
    <> "-"
    <> int.to_string(bootstrap.current_process_id())
  let assert Ok(Nil) = simplifile.create_directory_all(path)
    as "the scratch directory is creatable"
  let assert Ok(canonical) = bootstrap.canonical_directory(path)
    as "the scratch directory is canonical"

  canonical
}

/// The catalogue: one priced Anthropic-dialect model named `fixture`, and a
/// second named `fixture-b`, both routed to nothing real.
pub fn catalogue() -> Catalog {
  catalog.Catalog(
    models: [model_named("fixture"), model_named("fixture-b")],
    roles: [#(model.Main, ["fixture"])],
    profiles: [],
    mcp_servers: [],
    lsp_servers: [],
  )
}

fn model_named(name: String) -> catalog.CatalogModel {
  catalog.CatalogModel(
    name:,
    dialect: catalog.Anthropic,
    base_url: "http://fixture.invalid",
    api_key_env: "FIXTURE_KEY",
    model_id: name,
    context_window: 100_000,
    max_output_tokens: 4096,
    thinking: model.ThinkingOff,
    pricing: Some(pricing.Pricing(1.0, 1.0, 1.0, 1.0)),
    vision: catalog.TextOnly,
    max_images: 8,
    cyber_access: None,
    service_tier: None,
  )
}

/// The base session settings over a scripted transport, rooted at `root`.
pub fn base(root: String, transport: Transport) -> Settings {
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/work")
    as "the base workspace exists"
  let assert Ok(helper) = bootstrap.find_executable("../sandbox/loom-exec")
    as "the jail helper exists"
  let assert Ok(seed) =
    bootstrap.canonical_directory("../../build/codemode-seed")
    as "the seed exists"
  let assert Ok(settings) =
    run_cli.base_settings(
      catalogue(),
      transport,
      secret.from_list([#("FIXTURE_KEY", "fixture-key")]),
      root,
      helper,
      seed,
    )
    as "the base settings build"

  settings
}

/// A hand-written task that asks the scripted provider to write
/// `out.txt` with `written` and expects `expected`.
pub fn task_named(name: String, written: String, expected: String) -> Task {
  task.mint(Task(
    id: "",
    name:,
    prompt: "Make the file. " <> name <> " WRITE[out.txt=" <> written <> "]",
    workspace: Inline([#("seed.txt", "seed\n")]),
    verifier: ExpectedFiles([#("out.txt", expected)]),
    tags: ["kind:write"],
    provenance: HandWritten("test"),
  ))
}

/// A task whose agent never gets an answer.
pub fn stalled_task() -> Task {
  task.mint(Task(
    id: "",
    name: "stalled",
    prompt: "Make the file. STALL",
    workspace: Inline([#("seed.txt", "seed\n")]),
    verifier: ExpectedFiles([#("out.txt", "never")]),
    tags: [],
    provenance: HandWritten("test"),
  ))
}

/// The baseline arm: no components, no knobs.
pub fn baseline() -> Arm {
  let assert Ok(minted) =
    arm.mint(Arm(
      id: "",
      name: "baseline",
      components: [],
      knobs: Knobs(roles: [], thinking: [], disabled_tools: []),
    ))
    as "the baseline arm mints"

  minted
}

/// A candidate arm: the baseline plus a system suffix on the fixture model.
pub fn suffixed() -> Arm {
  let assert Ok(minted) =
    arm.mint(Arm(
      id: "",
      name: "suffixed",
      components: [
        #(
          SystemSuffix(Target("fixture", "fixture", "anthropic-messages", Any)),
          "Check your work.",
        ),
      ],
      knobs: Knobs(roles: [], thinking: [], disabled_tools: []),
    ))
    as "the suffixed arm mints"

  minted
}

/// A minted live-lane plan over the given tasks and arms.
pub fn plan_of(
  tasks: List(Task),
  arms: List(Arm),
  trials: Int,
  concurrency: Int,
  max_dollars: Float,
  wall_ms: Int,
) -> Plan {
  plan.mint(Plan(
    id: "",
    task_ids: list.map(tasks, fn(each) { each.id }),
    arm_ids: list.map(arms, fn(each) { each.id }),
    trials_per_cell: trials,
    lane: plan.Live,
    profile: Quick,
    split_salt: "salt",
    budgets: Budgets(
      max_requests_per_trial: 4,
      max_dollars:,
      wall_ms_per_trial: wall_ms,
      concurrency:,
    ),
    harness: Harness("0123456789abcdef0123456789abcdef01234567", Clean),
  ))
}

/// The scripted transport. `input_tokens` is the usage each response reports.
pub fn transport(input_tokens: Int) -> Transport {
  http.Transport(prepare_streaming: fn(request, events) {
    parked(events, fn() { respond(request.body, events, input_tokens) })
  })
}

fn respond(
  body: String,
  events: process.Subject(http.HttpEvent),
  input_tokens: Int,
) -> Nil {
  case string.contains(body, "STALL") {
    True -> process.sleep_forever()
    False -> {
      process.send(
        events,
        http.ResponseStatus(200, [#("content-type", "text/event-stream")]),
      )
      list.each(script(body, input_tokens), fn(piece) {
        process.send(events, http.ResponseChunk(bit_array.from_string(piece)))
      })
      process.send(events, http.ResponseEnd)
    }
  }
}

fn script(body: String, input_tokens: Int) -> List(String) {
  case string.contains(body, "\"tool_result\"") {
    True ->
      transcript(
        text_block(),
        "text_delta",
        "text",
        json.String("done"),
        "end_turn",
        input_tokens,
      )
    False -> {
      let #(path, content) = written_in(body)

      transcript(
        tool_block(),
        "input_json_delta",
        "partial_json",
        json.String(
          json.to_string(
            json.Object([
              #("path", json.String(path)),
              #("content", json.String(content)),
            ]),
          ),
        ),
        "tool_use",
        input_tokens,
      )
    }
  }
}

fn written_in(body: String) -> #(String, String) {
  case string.split(body, "WRITE[") {
    [_, rest, ..] ->
      case string.split(rest, "]") {
        [spec, ..] ->
          case string.split(spec, "=") {
            [path, content] -> #(path, content)
            _ -> #("out.txt", "")
          }
        [] -> #("out.txt", "")
      }
    _ -> #("out.txt", "")
  }
}

fn text_block() -> json.JsonValue {
  json.Object([#("type", json.String("text")), #("text", json.String(""))])
}

fn tool_block() -> json.JsonValue {
  json.Object([
    #("type", json.String("tool_use")),
    #("id", json.String("call-1")),
    #("name", json.String("fs_write")),
    #("input", json.Object([])),
  ])
}

fn event(name: String, fields: List(#(String, json.JsonValue))) -> String {
  "event: "
  <> name
  <> "\ndata: "
  <> json.to_string(json.Object(fields))
  <> "\n\n"
}

fn transcript(
  block: json.JsonValue,
  delta_type: String,
  delta_key: String,
  delta_value: json.JsonValue,
  reason: String,
  input_tokens: Int,
) -> List(String) {
  [
    event("message_start", [
      #("type", json.String("message_start")),
      #(
        "message",
        json.Object([
          #("id", json.String("scripted")),
          #("model", json.String("fixture")),
          #(
            "usage",
            json.Object([
              #("input_tokens", json.Int(input_tokens)),
              #("output_tokens", json.Int(0)),
            ]),
          ),
        ]),
      ),
    ]),
    event("content_block_start", [
      #("type", json.String("content_block_start")),
      #("index", json.Int(0)),
      #("content_block", block),
    ]),
    event("content_block_delta", [
      #("type", json.String("content_block_delta")),
      #("index", json.Int(0)),
      #(
        "delta",
        json.Object([
          #("type", json.String(delta_type)),
          #(delta_key, delta_value),
        ]),
      ),
    ]),
    event("content_block_stop", [
      #("type", json.String("content_block_stop")),
      #("index", json.Int(0)),
    ]),
    event("message_delta", [
      #("type", json.String("message_delta")),
      #("delta", json.Object([#("stop_reason", json.String(reason))])),
      #("usage", json.Object([#("output_tokens", json.Int(1))])),
    ]),
    event("message_stop", [#("type", json.String("message_stop"))]),
  ]
}

fn parked(
  events: process.Subject(http.HttpEvent),
  operation: fn() -> Nil,
) -> Result(http.PreparedRequest, String) {
  use consumer <- result.try(
    process.subject_owner(events)
    |> result.replace_error("the response consumer is not a live process"),
  )
  let ready = process.new_subject()
  let witnessed =
    weft.new_prepared([
      weft.managed(fn(_ledger) {
        let begin = process.new_subject()
        process.send(ready, begin)
        process.receive_forever(begin)
        operation()
        Ok(Nil)
      }),
    ])
    |> weft.on_failure(weft.CancelSiblings)
    |> weft.cancel_when_exits(consumer)
    |> weft.start_witnessed
  let watch = process.monitor(weft.witness_pid(witnessed))
  let readiness =
    process.new_selector()
    |> process.select_map(ready, Ok)
    |> process.select_specific_monitor(watch, fn(_down) { Error(Nil) })
  let publication = process.selector_receive(readiness, 5000)
  process.demonitor_process(watch)

  case publication {
    Ok(Ok(begin)) ->
      Ok(
        http.PreparedRequest(
          running: http.RunningRequest(
            owner: weft.witness_pid(witnessed),
            cancel: fn() { weft.cancel_witnessed(witnessed) },
          ),
          begin: fn() { process.send(begin, Nil) },
        ),
      )
    Ok(Error(Nil)) | Error(Nil) -> {
      weft.cancel_witnessed(witnessed)
      Error("the scripted provider could not park the request")
    }
  }
}

/// A shared counter, for seams that must remember across trial processes.
pub opaque type Counter {
  Counter(subject: process.Subject(CounterMessage))
}

pub type CounterMessage {
  Bump(reply: process.Subject(Int))
  Peek(reply: process.Subject(Int))
}

/// Starts a counter at zero.
pub fn counter() -> Counter {
  let assert Ok(started) =
    actor.new(0)
    |> actor.on_message(fn(total, message) {
      case message {
        Bump(reply:) -> {
          process.send(reply, total + 1)
          actor.continue(total + 1)
        }
        Peek(reply:) -> {
          process.send(reply, total)
          actor.continue(total)
        }
      }
    })
    |> actor.start
    as "the counter starts"

  Counter(started.data)
}

/// Adds one and answers the new total.
pub fn bump(counter: Counter) -> Int {
  actor.call(counter.subject, waiting: 5000, sending: Bump)
}

/// The present total.
pub fn count(counter: Counter) -> Int {
  actor.call(counter.subject, waiting: 5000, sending: Peek)
}
