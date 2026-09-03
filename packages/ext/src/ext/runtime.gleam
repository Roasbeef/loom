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
//// never sees the capability channel, the token, the frame ids, or the
//// deadline; they write `ext.Tool`s and name them.
////
//// ## The shape of a satellite's life (pin this)
////
//// A satellite is launched once per session per extension and answers
//// many invocations (`protocol-change/012`, ADR-007 Decision 3). Phase 1
//// launched one node per call and had it *pull* its work with a single
//// `ext.call`; that is gone, and nothing here can pull, because a node
//// that lives past its first answer has nothing left to pull against and
//// no token for its second call.
////
//// 1. `cap/runtime.serve` boots the capability channel over
////    `LOOM_CAP_SOCK` and then waits. That is reused rather than
////    reimplemented: the token never becomes reachable from this module,
////    the one-at-a-time rule and the crash handling stay in one place,
////    and so does the loop's teardown.
//// 2. Each `hook_call` the harness sends arrives here as a
////    `runtime.Asked`: a `Tool(name)` or an `Event(name)`, that row's
////    arguments, and what is left of the invocation's deadline.
//// 3. The name is looked up in the served list. An unknown tool is a
////    refusal that *names the tools this artifact has*, because the only
////    way that happens is a manifest and an artifact that disagree, and
////    the operator needs to see both sides of the disagreement. An event
////    with no handler is `unhandled`, which is an ordinary answer rather
////    than a fault: an extension is not obliged to care about every
////    moment the harness offers it.
//// 4. The tool runs, in a process `cap/runtime` monitors, so a `panic`
////    inside it becomes a `crashed` answer and the satellite serves the
////    next invocation.
////
//// ## The answer's shape (pin this)
////
//// A tool's answer is the value on the `hook_result` frame:
////
//// ```
//// {content: [block…], terminate: Bool}
//// ```
////
//// where a block is `{type: "text", text: String}` or
//// `{type: "json", json: String}` — the JSON block's payload is its
//// serialization, because the channel speaks msgpack and a round trip
//// through two structured encodings is a place for the two sides to
//// disagree about numbers. A refusal is `{ok: false, error: {code,
//// msg}}` instead, under the codes below.
////
//// ## The arguments (pin this)
////
//// A tool invocation's arguments are `{args: String, strand: String}`,
//// where `args` is **JSON text**, not a structured value. An extension
//// tool is typed `fn(dynamic.Dynamic, Ctx)`, and `gleam_json`'s parser is
//// the only route from bytes to a `Dynamic` that the extension seam's
//// allowlist admits; carrying the arguments as text also means the
//// harness hands over exactly the bytes the model's tool call carried,
//// with no re-encoding step in between to disagree about.
////
//// An event invocation's arguments are **JSON text too**, in the row
//// `client/extension/hooks` pins for that event, and its answer is JSON
//// text in the same table's return column. `ext/hook` owns both
//// marshallings — `hook.answer` takes the document and renders the
//// reply — so this module carries the text between the channel and that
//// one place and reads neither end.

import cap/report.{type Value}
import cap/runtime
import ext.{
  type Content, type Ctx, type Outcome, type Refusal, type Terminate, type Tool,
  ContinueRun, Ctx, Json, Refusal, TerminateRun, Text,
}
import ext/hook.{type Hook}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string

/// The in-band code a tool's own `Refusal` travels under.
///
/// Distinct from `unknown_tool` and from `cap/runtime`'s `crashed`,
/// because the three are different facts about an install: a refusal is
/// the extension working as written, an unknown tool is a manifest and an
/// artifact that disagree, and a crash is a bug in somebody's code.
pub const refused_code = "refused"

/// The code a tool name this artifact does not serve travels under.
pub const unknown_tool_code = "unknown_tool"

/// The code an event with no handler travels under.
pub const unhandled_code = "unhandled"

/// The code a `[[hook]]` whose entry answers a different event travels
/// under.
///
/// Its own code because it is neither a refusal nor a crash but an
/// install that does not hold together: the manifest declared one event
/// and the module implements another, and only the pair can see it.
pub const mismatched_hook_code = "mismatched_hook"

/// The code arguments that did not parse travel under.
pub const bad_arguments_code = "bad_arguments"

/// One `[[hook]]` entry as the generated entry module passes it: the
/// event name the manifest declared, paired with the typed behaviour the
/// extension's module returns.
///
/// The name travels beside the hook rather than being read off it,
/// because the two come from different places — the manifest an operator
/// approved, and the module the build compiled — and a pair that
/// disagrees is an install that does not hold together. `answer` checks
/// them against each other and refuses `mismatched_hook` rather than
/// serving whichever one it happened to read.
pub type Declared =
  #(String, Hook)

/// Serves this artifact's tools for the life of the satellite. The
/// generated entry module's one call.
///
/// The list is `#(manifest tool name, implementation)`; the names are the
/// manifest's, because the manifest is what the model was told about.
/// Returns when the harness cancels the satellite or the capability
/// channel closes.
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
  serving(tools:, hooks: [])
}

/// Serves tools and hooks both.
///
/// The shape a generated entry takes once an extension declares a
/// `[[hook]]`; `serve` is this with an empty hook table, which is what an
/// extension that declares none gets. Two functions rather than one with
/// an optional argument because the generated entry writes whichever call
/// the manifest asked for, and the common one should read as the common
/// one.
///
/// ## Examples
///
/// ```gleam
/// pub fn main() -> Nil {
///   runtime.serving(
///     tools: [#("weather", forecast.run)],
///     hooks: [#("tool_call", forecast.on_event())],
///   )
/// }
/// ```
///
pub fn serving(
  tools tools: List(#(String, Tool)),
  hooks hooks: List(Declared),
) -> Nil {
  runtime.serve(fn(asked) { answer(tools, hooks, asked) })
}

/// Answers one invocation against the served tables.
///
/// Separated from `serving` so the whole dispatch is exercisable with no
/// channel and no socket at all — which is how this package's own tests
/// drive it — and so an author can test their own table the same way.
///
/// ## Examples
///
/// ```gleam
/// let asked =
///   runtime.Asked(runtime.Tool("echo"), args, deadline_ms: 1000)
/// let _answer = runtime.answer([#("echo", echo_tool)], [], asked)
/// ```
///
pub fn answer(
  tools: List(#(String, Tool)),
  hooks: List(Declared),
  asked: runtime.Asked,
) -> runtime.Answer {
  case asked.invocation {
    runtime.Tool(name:) -> tool_answer(tools, name, asked)
    runtime.Event(name:) -> event_answer(hooks, name, asked.args)
  }
}

// --- tools ----------------------------------------------------------------

// Finds the tool, decodes the invocation's envelope, runs it. Both
// failures before the run are the harness's rather than the model's — the
// name came from a manifest this artifact was built beside, and the
// arguments were schema-checked before they were sent — so both name the
// tool they were about.
fn tool_answer(
  tools: List(#(String, Tool)),
  name: String,
  asked: runtime.Asked,
) -> runtime.Answer {
  case resolve(tools, name, asked) {
    Ok(#(tool, arguments, ctx)) -> settle(tool(arguments, ctx))
    Error(refusal) -> refusal
  }
}

fn resolve(
  tools: List(#(String, Tool)),
  name: String,
  asked: runtime.Asked,
) -> Result(#(Tool, Dynamic, Ctx), runtime.Answer) {
  use tool <- result.try(
    list.key_find(tools, name)
    |> result.map_error(fn(_nil) { unknown_tool(tools, name) }),
  )
  use text <- result.try(
    string_field(asked.args, "args")
    |> result.map_error(fn(reason) {
      runtime.Refused(code: bad_arguments_code, message: reason)
    }),
  )
  use arguments <- result.try(
    parse_args(text)
    |> result.map_error(fn(reason) {
      runtime.Refused(
        code: bad_arguments_code,
        message: "the arguments to `" <> name <> "` " <> reason,
      )
    }),
  )
  Ok(#(tool, arguments, context(asked)))
}

// The context handed to every tool: the invocation's own coordinates,
// plus a `report` sink that drops its own failures. A partial that could
// not be emitted must not fail the call it was narrating.
//
// A strand the harness did not name is the empty string rather than a
// refusal: attribution is what it is for, and an invocation with no
// strand is still one a tool can serve.
fn context(asked: runtime.Asked) -> Ctx {
  Ctx(
    strand: result.unwrap(string_field(asked.args, "strand"), ""),
    deadline_ms: asked.deadline_ms,
    report: fn(text) {
      let _ =
        report.emit(name: "partial", content_type: "text/plain", bytes: <<
          text:utf8,
        >>)
      Nil
    },
  )
}

fn settle(run: Result(Outcome, Refusal)) -> runtime.Answer {
  case run {
    Ok(outcome) -> runtime.Answered(value: body(outcome))
    Error(Refusal(message:)) -> runtime.Refused(code: refused_code, message:)
  }
}

fn body(outcome: Outcome) -> Value {
  report.object([
    #("content", report.list(list.map(outcome.content, block))),
    #("terminate", report.bool(terminates(outcome.terminate))),
  ])
}

fn block(content: Content) -> Value {
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
fn unknown_tool(tools: List(#(String, Tool)), name: String) -> runtime.Answer {
  let served = list.map(tools, fn(entry) { entry.0 })
  runtime.Refused(
    code: unknown_tool_code,
    message: "this extension serves no tool named "
      <> name
      <> "; it serves "
      <> string.join(list.sort(served, string.compare), ", "),
  )
}

// --- events ---------------------------------------------------------------

// An event nobody registered for. `unhandled` rather than a fault,
// because the harness offers every installed extension every moment and
// most extensions care about none of them; the bus reads the code and
// moves on.
//
// The payload crosses as JSON text and the answer goes back as JSON
// text, which is `client/extension/hooks`'s wire and `ext/hook`'s
// marshalling: the extension seam admits `gleam/json` and no msgpack
// decoder, so text is the only shape both ends can read.
fn event_answer(
  hooks: List(Declared),
  name: String,
  args: Value,
) -> runtime.Answer {
  case list.key_find(hooks, name) {
    Error(Nil) ->
      runtime.Refused(
        code: unhandled_code,
        message: "this extension registers no handler for the event " <> name,
      )
    Ok(declared) -> fire(declared, name, args)
  }
}

fn fire(declared: Hook, name: String, args: Value) -> runtime.Answer {
  case hook.event(declared) == name {
    False ->
      runtime.Refused(
        code: mismatched_hook_code,
        message: "this extension's manifest declares a `"
          <> name
          <> "` hook, but the module it named answers `"
          <> hook.event(declared)
          <> "`",
      )
    True -> fired(declared, name, args)
  }
}

fn fired(declared: Hook, name: String, args: Value) -> runtime.Answer {
  case as_text(args) {
    Error(reason) -> runtime.Refused(code: bad_arguments_code, message: reason)
    Ok(document) ->
      case hook.answer(declared, document) {
        Ok(rendered) -> runtime.Answered(value: report.string(rendered))
        Error(reason) ->
          runtime.Refused(
            code: refused_code,
            message: "the `" <> name <> "` hook could not answer: " <> reason,
          )
      }
  }
}

// --- arguments ------------------------------------------------------------

// The call's arguments as a `Dynamic` the tool's own decoder can walk.
// `decode.dynamic` never fails, so the only failure here is text that is
// not JSON, which the caller reports rather than guessing past.
fn parse_args(text: String) -> Result(Dynamic, String) {
  case json.parse(from: text, using: decode.dynamic) {
    Ok(value) -> Ok(value)
    Error(_) -> Error("were not JSON")
  }
}

// The invocation's arguments as the JSON text both ends agreed on. A
// value that is not text is the harness disagreeing with this module
// about the wire, which is a message rather than a crash.
fn as_text(args: Value) -> Result(String, String) {
  report.as_string(args)
  |> result.replace_error("the hook's arguments were not JSON text")
}

// One string out of the invocation's envelope, totally. A field that is
// missing or is not text is a message rather than a crash: the envelope
// comes off a wire, and this module decodes it like every other boundary
// in the tree.
fn string_field(value: Value, key: String) -> Result(String, String) {
  case report.field(value, key) {
    Error(Nil) -> Error("the invocation carried no `" <> key <> "` field")
    Ok(found) ->
      report.as_string(found)
      |> result.replace_error("the invocation's `" <> key <> "` was not text")
  }
}
