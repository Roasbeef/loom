//// The embedding contract, run end to end.
////
//// One in-process session through `runtime/api.open`, with everything an
//// embedder such as a review service supplies: a custom tool whose `run`
//// closes over a per-job grant, a terminating `submit` tool, a system prompt
//// of its own and an in-memory session. The model is a scripted Anthropic
//// transport, so the wire encoding, the routing, the admission and the tool
//// dispatch are all the real ones; only the network is replaced. The test
//// names no `client` module, and `harness` cannot import one.

import broker/policy
import core/clock
import core/json
import core/message
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import harness
import machine/operation
import runtime/api
import session/session
import support/fixtures
import support/scripted
import tools/tool

const system_prompt = "You are the harness embedding test's reviewer."

const job_grant = "grant-7f3a"

fn schema(field: String) -> json.JsonValue {
  json.Object([
    #("type", json.String("object")),
    #(
      "properties",
      json.Object([#(field, json.Object([#("type", json.String("string"))]))]),
    ),
    #("required", json.Array([json.String(field)])),
  ])
}

// A tool whose executor closes over the job's grant, as an embedder's does.
// It reads nothing from the context: a plain function of its arguments.
fn lookup(grant: String) -> tool.Tool {
  tool.Tool(
    name: "lookup",
    description: "Look a finding up under this job's grant.",
    prompt_snippet: None,
    schema: schema("finding"),
    replay: tool.Safe,
    execution_mode: tool.Concurrent,
    requirements: policy.workspace_default,
    run: fn(_ctx, _arguments) {
      tool.success("finding visible under " <> grant)
    },
  )
}

// The terminating tool. It hands its arguments to the embedder and ends the
// run: no further model request follows its result.
fn submit(report: process.Subject(String)) -> tool.Tool {
  tool.Tool(
    name: "submit",
    description: "Submit the verdict. Ends the job.",
    prompt_snippet: None,
    schema: schema("verdict"),
    replay: tool.Never,
    execution_mode: tool.Exclusive,
    requirements: policy.workspace_default,
    run: fn(_ctx, arguments) {
      process.send(report, json.to_string(arguments))
      tool.ToolOutcome(
        ..tool.success("verdict recorded"),
        terminate: tool.TerminateRun,
      )
    },
  )
}

// The model looks the finding up, reads the grant back, then submits.
fn script(body: String) -> scripted.Turn {
  case scripted.tool_results(body) {
    0 ->
      scripted.CallTool(
        "call_lookup",
        "lookup",
        json.Object([#("finding", json.String("F-1"))]),
      )
    1 ->
      scripted.CallTool(
        "call_submit",
        "submit",
        json.Object([#("verdict", json.String("no issue"))]),
      )
    _ -> scripted.Say("unreachable: submit ends the run")
  }
}

pub fn a_session_runs_with_custom_tools_a_terminating_submit_and_a_prompt_test() {
  let requests = process.new_subject()
  let report = process.new_subject()
  let registry = tool.registry([lookup(job_grant), submit(report)])

  let assert Ok(opened) =
    session.open_memory(clock.stepping(from: 1_756_000_000_000, by: 3))
    as "the in-memory session opens"
  let assert Ok(config) =
    harness.new(
      harness.Settings(
        ..harness.settings(
          gateway: fixtures.routed_gateway(scripted.transport(requests, script)),
          session: opened,
          registry:,
          clock: clock.stepping(from: 1_756_000_000_000, by: 3),
          fallback: fixtures.fallback(),
          tools: harness.Embedded(
            workspace: "/nonexistent/harness-embedding",
            blob_root: "/nonexistent/harness-embedding/blobs",
          ),
        ),
        system: Some(system_prompt),
      ),
    )
    as "the configuration is valid"

  let options =
    api.Options(
      ..api.default_options(fixtures.strand_on_route(["lookup", "submit"])),
      poll_interval_ms: 25,
      idle_poll_interval_ms: 25,
    )
  let assert Ok(runtime) = api.open(opened, harness.effects(config), options)
    as "the runtime opens over the harness effects"
  let assert Ok(operation) =
    api.prompt(runtime, [
      message.UserMessage(
        content: [message.UserText("Review finding F-1.", None)],
        timestamp: 1_756_000_000_000,
        origin: None,
      ),
    ])
  let assert Ok(result) =
    api.await_result(runtime, operation, within_ms: 10_000)
    as "the job reaches a terminal result"

  // The run ended because the tool said so, not because the model stopped.
  let assert operation.RunLastResult(
    outcome: operation.RunCompleted(
      completion: operation.CompletedByTerminatedTools,
    ),
    ..,
  ) = result

  // The terminating tool received exactly what the model sent.
  let assert Ok(submitted) = process.receive(report, 1000)
  assert string.contains(submitted, "no issue")

  // Two model requests and no third: `submit` ended the run. Both carried the
  // embedder's system prompt and the tools it registered, sorted by name.
  let assert Ok(first) = process.receive(requests, 1000)
  let assert Ok(second) = process.receive(requests, 1000)
  assert string.contains(first, system_prompt)
  assert string.contains(second, system_prompt)
  assert string.contains(first, "\"name\":\"lookup\"")
  assert string.contains(first, "\"name\":\"submit\"")
  assert process.receive(requests, 200) == Error(Nil)

  // The first tool's result, produced under the job's grant, reached the
  // model on the second request.
  assert string.contains(second, "finding visible under " <> job_grant)

  assert api.close(runtime) == Ok(Nil)
}
