//// `ext/runtime` — the extension satellite's whole main loop, in one
//// call.
////
//// An installed extension is compiled once, at install, with a generated
//// entry module the harness writes (`client/extension/install`):
////
//// ```gleam
//// import ext/runtime
//// import weather/forecast
////
//// pub fn main() -> Nil {
////   runtime.serve([#("weather", forecast.run)])
//// }
//// ```
////
//// Everything else about a tool call happens here. The extension author
//// never sees the capability channel, the token, the outcome frame, or the
//// deadline; they write `ext.Tool`s and name them.
////
//// ## The shape of one execution (pin this)
////
//// A satellite is launched per call and lives for exactly one:
////
//// 1. `cap/runtime.run` boots the capability channel over `LOOM_CAP_SOCK`
////    with the token from `LOOM_CAP_TOKEN_FILE`. That is reused rather
////    than reimplemented: the token never becomes reachable from this
////    module, and the outcome framing stays in one place.
//// 2. `cap/ext.call` asks the harness which tool this execution is for.
////    The result is `{tool, args, strand, deadline_ms}` with `args` as
////    JSON text (`cap/ext`'s module doc pins the wire shape).
//// 3. The name is looked up in the served list. An unknown name is an
////    error outcome that *names the tools this artifact has*, because the
////    only way that happens is a manifest and an artifact that disagree,
////    and the operator needs to see both sides of the disagreement.
//// 4. The tool runs. Its `Outcome` becomes the `outcome` frame's value
////    and its `Refusal` becomes the frame's error message; a crash inside
////    the tool is turned into an errored outcome by `cap/runtime` itself,
////    which runs the program in a monitored child.
////
//// ## The outcome body (pin this)
////
//// `cap/report`'s existing envelope carries it, so nothing new appears on
//// the wire:
////
//// ```
//// {ok: true,  value: {content: [block…], terminate: Bool}}
//// {ok: false, message: String, details: {tool: String}}
//// ```
////
//// where a block is `{type: "text", text: String}` or
//// `{type: "json", json: String}` — the JSON block's payload is its
//// serialization, because the channel speaks msgpack and a round trip
//// through two structured encodings is a place for the two sides to
//// disagree about numbers. The harness-side router that answers
//// `ext.call` and reads this body arrives in phase 2.

import cap/ext as cap_ext
import cap/report
import cap/runtime
import ext.{
  type Content, type Ctx, type Outcome, type Refusal, type Terminate, type Tool,
  ContinueRun, Ctx, Json, Refusal, TerminateRun, Text,
}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string

/// Serves one tool call and exits. The generated entry module's one call.
///
/// The list is `#(manifest tool name, implementation)`; the names are the
/// manifest's, because the manifest is what the model was told about.
///
/// ## Examples
///
/// ```gleam
/// pub fn main() -> Nil {
///   runtime.serve([#("weather", forecast.run)])
/// }
/// ```
///
pub fn serve(tools: List(#(String, Tool))) -> Nil {
  runtime.run(fn() { answer(tools) })
}

/// Fetches this execution's call and serves it, returning the outcome the
/// satellite reports.
///
/// Separated from `serve` so the whole round trip is exercisable over an
/// injected `cap/runtime.Transport` — a fake channel, no socket — which is
/// how this package's own tests drive it.
///
/// ## Examples
///
/// ```gleam
/// let outcome = runtime.answer([#("echo", echo_tool)])
/// ```
///
pub fn answer(tools: List(#(String, Tool))) -> report.Outcome {
  case cap_ext.call() {
    Ok(call) -> dispatch(tools, call)

    // No call means no execution to serve. The harness already knows why
    // it refused, so the value here is naming which side failed.
    Error(refused) -> report.failure(describe_refusal(refused))
  }
}

/// Runs `call` against the served tools and marshals the result.
///
/// Pure but for the tool it invokes, so an author can test their own
/// dispatch table without a channel at all.
///
/// ## Examples
///
/// ```gleam
/// let call = cap_ext.Call("echo", "{}", "main", 1000)
/// let outcome = runtime.dispatch([#("echo", echo_tool)], call)
/// ```
///
pub fn dispatch(
  tools: List(#(String, Tool)),
  call: cap_ext.Call,
) -> report.Outcome {
  case resolve(tools, call) {
    Ok(#(tool, arguments)) -> settle(call.tool, tool(arguments, context(call)))
    Error(outcome) -> outcome
  }
}

// Finds the tool and decodes the arguments, or answers with the outcome
// that says which of the two went wrong. Both failures are the harness's
// rather than the model's — the name came from a manifest this artifact
// was built beside, and the arguments were schema-checked before they were
// sent — so both name the tool they were about.
fn resolve(
  tools: List(#(String, Tool)),
  call: cap_ext.Call,
) -> Result(#(Tool, Dynamic), report.Outcome) {
  use tool <- result.try(
    list.key_find(tools, call.tool)
    |> result.map_error(fn(_nil) { unknown_tool(tools, call.tool) }),
  )
  use arguments <- result.try(
    parse_args(call.args)
    |> result.map_error(fn(reason) {
      errored(call.tool, "bad arguments: " <> reason)
    }),
  )
  Ok(#(tool, arguments))
}

// The context handed to every tool: the call's own coordinates, plus a
// `report` sink that drops its own failures. A partial that could not be
// emitted must not fail the call it was narrating.
fn context(call: cap_ext.Call) -> Ctx {
  Ctx(strand: call.strand, deadline_ms: call.deadline_ms, report: fn(text) {
    let _ =
      report.emit(name: "partial", content_type: "text/plain", bytes: <<
        text:utf8,
      >>)
    Nil
  })
}

fn settle(name: String, run: Result(Outcome, Refusal)) -> report.Outcome {
  case run {
    Ok(outcome) -> report.value(body(outcome))
    Error(Refusal(message:)) -> errored(name, message)
  }
}

fn body(outcome: Outcome) -> report.Value {
  report.object([
    #("content", report.list(list.map(outcome.content, block))),
    #("terminate", report.bool(terminates(outcome.terminate))),
  ])
}

fn block(content: Content) -> report.Value {
  case content {
    Text(text:) ->
      report.object([
        #("type", report.string("text")),
        #("text", report.string(text)),
      ])
    Json(value:) ->
      report.object([
        #("type", report.string("json")),
        #("json", report.string(json.to_string(value))),
      ])
  }
}

fn terminates(terminate: Terminate) -> Bool {
  case terminate {
    ContinueRun -> False
    TerminateRun -> True
  }
}

// A name the artifact does not serve. The manifest and the artifact were
// written by the same install, so a mismatch is a broken install rather
// than a bad model call — and the fastest way for an operator to see that
// is both lists side by side.
fn unknown_tool(tools: List(#(String, Tool)), name: String) -> report.Outcome {
  let served = list.map(tools, fn(entry) { entry.0 })
  errored(
    name,
    "this extension serves no tool named "
      <> name
      <> "; it serves "
      <> string.join(list.sort(served, string.compare), ", "),
  )
}

fn errored(name: String, message: String) -> report.Outcome {
  report.Errored(
    message:,
    details: report.object([#("tool", report.string(name))]),
  )
}

// --- arguments ------------------------------------------------------------

// The call's arguments as a `Dynamic` the tool's own decoder can walk.
// `decode.dynamic` never fails, so the only failure here is text that is
// not JSON, which `dispatch` reports rather than guessing past.
fn parse_args(text: String) -> Result(Dynamic, String) {
  case json.parse(from: text, using: decode.dynamic) {
    Ok(value) -> Ok(value)
    Error(_) -> Error("the arguments were not JSON")
  }
}

fn describe_refusal(refused: cap_ext.CallRefused) -> String {
  case refused {
    cap_ext.CallDenied(code:, message:) ->
      "the harness refused to hand over a call (" <> code <> "): " <> message
    cap_ext.CallUnavailable(reason:) ->
      "the capability channel could not fetch the call: " <> reason
  }
}
