//// `ext/hook` — the typed behaviours an extension's `[[hook]]` entry
//// implements, and the one place the hook wire shapes are read and
//// written on the extension's side.
////
//// A tool is something the model asked for. A hook fires on the
//// *harness's* timeline: a run was accepted, a call was planned, a reply
//// settled. The harness sends a `hook_call` frame and waits
//// (`protocol-change/012`); the satellite runtime answers it by handing
//// the event to whichever `Hook` the manifest named for that event.
////
//// ## Why the shapes here are text and `Dynamic`
////
//// The extension seam admits `gleam/json`, `gleam/dynamic` and no
//// msgpack decoder, so every payload crosses as a msgpack string holding
//// JSON. This module decodes that text into the arguments a `Hook` is
//// written against and encodes the answer back, so an author never
//// touches either encoding.
////
//// A conversation message is the exception worth naming. The harness
//// carries messages in `core/codec`'s durable JSON, which is a document
//// `core` decodes totally and this package cannot import — `core` is not
//// on the extension seam, and putting it there would widen the seam for
//// a convenience. So a `context` hook sees each message as a `Dynamic`
//// and returns each as a `Json`: an author reads the fields they care
//// about with an ordinary decoder and passes the rest through unchanged,
//// and the harness re-decodes the result totally, discarding a transform
//// that no longer decodes rather than committing a half-understood one.
////
//// ## The events, and which of them are chained
////
//// Five events are notifications or one-shot questions the harness fans
//// out to every extension. Two — `context` and `tool_result` — are
//// *chained transforms*: the harness folds them over the installed
//// extensions in load order, and each one is handed its predecessor's
//// output rather than the original. An author writing one should assume
//// somebody else has already been here.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import gleam/result

/// What a `tool_call` hook decided about one planned call.
///
/// A block is not a crash: the reason is text the model reads and can
/// act on, so it should say what to do differently. Arguments are
/// read-only by ruling — a hook that rewrote a call's arguments after
/// vetting is the one thing vetting cannot see — so there is no third
/// variant carrying replacements.
pub type Verdict {
  /// Nothing to say; the call proceeds.
  Allow

  /// Refuse the call, with a reason the model reads.
  Block(reason: String)
}

/// What a `tool_call` hook is told about the call.
pub type Call {
  Call(
    /// The operation the call belongs to.
    op_id: String,
    /// The tool the model asked for.
    tool: String,
    /// Its arguments, exactly as the model sent them. Read-only.
    arguments: Dynamic,
    /// Which call of the assistant turn this is, from zero.
    source_index: Int,
  )
}

/// What a `before_agent_start` hook is told about the run.
pub type RunStart {
  RunStart(op_id: String, strand: String)
}

/// What a `context` hook is handed: the request's operation, and the
/// message list as the previous extension in the chain left it.
///
/// The operation is here because every other event carries it and a
/// context hook that could not tell two runs apart would be the odd one
/// out — an extension keeping per-run state between
/// `before_agent_start` and the requests that follow it needs the two to
/// name the same thing.
pub type Context {
  Context(op_id: String, messages: List(Dynamic))
}

/// The typed behaviour behind one `[[hook]]` entry.
///
/// One variant per event, so an entry that answers the wrong event is a
/// compile error in the extension rather than a shape mismatch on the
/// wire. The generated entry module pairs each of these with the event
/// name its manifest declared.
pub type Hook {
  /// `session_start`: the session server booted this extension. Nothing
  /// to answer; the moment is the point.
  OnSessionStart(run: fn() -> Nil)

  /// `before_agent_start`: a run was accepted, before planning. Return
  /// text to have it injected at run start, fenced and attributed to
  /// this extension by the harness, or `None` to add nothing.
  OnBeforeAgentStart(run: fn(RunStart) -> Option(String))

  /// `context`: before each provider request, over a copy of the
  /// message list. Chained: the list handed in is the previous
  /// extension's output. The harness discards a transform that grows the
  /// context past its token allowance.
  OnContext(run: fn(Context) -> List(Json))

  /// `tool_call`: a call was planned, before dispatch.
  OnToolCall(run: fn(Call) -> Verdict)

  /// `tool_result`: a tool settled, before the reply is committed.
  /// Chained. The message handed in is the whole reply; an answer that
  /// changes which call it settles, or whether that call failed, is
  /// discarded whole by the harness.
  OnToolResult(run: fn(Dynamic) -> Json)

  /// `agent_end`: a run reached a terminal state.
  OnAgentEnd(run: fn(String) -> Nil)

  /// `agent_settled`: the run and every follow-up it queued are done.
  OnAgentSettled(run: fn(String) -> Nil)
}

/// The manifest event name a hook answers. The pairing the generated
/// entry module is built from, so a `[[hook]]` and its implementation
/// cannot drift apart silently.
///
/// ## Examples
///
/// ```gleam
/// assert hook.event(hook.OnToolCall(fn(_call) { hook.Allow }))
///   == "tool_call"
/// ```
///
pub fn event(hook: Hook) -> String {
  case hook {
    OnSessionStart(..) -> "session_start"
    OnBeforeAgentStart(..) -> "before_agent_start"
    OnContext(..) -> "context"
    OnToolCall(..) -> "tool_call"
    OnToolResult(..) -> "tool_result"
    OnAgentEnd(..) -> "agent_end"
    OnAgentSettled(..) -> "agent_settled"
  }
}

/// Runs a hook against the harness's `args` document and renders its
/// answer as the `hook_result` value.
///
/// Both sides are JSON text, which is what a `hook_call` carries. An
/// `args` document that does not hold what the event needs is an
/// `Error`: the harness and this module are two halves of one wire
/// shape, so a disagreement is a bug in one of them rather than
/// something to guess past.
///
/// ## Examples
///
/// ```gleam
/// let gate = hook.OnToolCall(fn(_call) { hook.Block("no") })
/// let assert Ok(answer) = hook.answer(gate, "{\"op_id\":\"a\",\"tool\":\"bash\",\"arguments\":{},\"source_index\":0}")
/// assert answer == "{\"verdict\":\"block\",\"reason\":\"no\"}"
/// ```
///
pub fn answer(hook: Hook, args: String) -> Result(String, String) {
  use document <- result.try(parse(args))
  case hook {
    OnSessionStart(run:) -> {
      run()
      Ok(nothing())
    }

    OnBeforeAgentStart(run:) -> {
      use start <- result.try(run_start(document))
      Ok(json.to_string(injection(run(start))))
    }

    OnContext(run:) -> {
      use context <- result.try(context_of(document))
      Ok(
        json.to_string(
          json.object([#("messages", json.preprocessed_array(run(context)))]),
        ),
      )
    }

    OnToolCall(run:) -> {
      use call <- result.try(call_of(document))
      Ok(json.to_string(verdict(run(call))))
    }

    OnToolResult(run:) -> {
      use message <- result.try(field(document, "message"))
      Ok(json.to_string(json.object([#("message", run(message))])))
    }

    OnAgentEnd(run:) -> {
      use op_id <- result.try(field_string(document, "op_id"))
      run(op_id)
      Ok(nothing())
    }

    OnAgentSettled(run:) -> {
      use op_id <- result.try(field_string(document, "op_id"))
      run(op_id)
      Ok(nothing())
    }
  }
}

// The answer to an event that returns nothing. Still a document rather
// than an empty string, because the harness reads every `hook_result`
// the same way and a body it cannot parse is a broken extension.
fn nothing() -> String {
  json.to_string(json.object([]))
}

fn injection(text: Option(String)) -> Json {
  case text {
    Some(text) -> json.object([#("inject", json.string(text))])
    None -> json.object([#("inject", json.null())])
  }
}

fn verdict(verdict: Verdict) -> Json {
  case verdict {
    Allow -> json.object([#("verdict", json.string("allow"))])
    Block(reason:) ->
      json.object([
        #("verdict", json.string("block")),
        #("reason", json.string(reason)),
      ])
  }
}

fn run_start(document: Dynamic) -> Result(RunStart, String) {
  use op_id <- result.try(field_string(document, "op_id"))
  use strand <- result.try(field_string(document, "strand"))
  Ok(RunStart(op_id:, strand:))
}

fn context_of(document: Dynamic) -> Result(Context, String) {
  use op_id <- result.try(field_string(document, "op_id"))
  use messages <- result.try(field_list(document, "messages"))
  Ok(Context(op_id:, messages:))
}

fn call_of(document: Dynamic) -> Result(Call, String) {
  use op_id <- result.try(field_string(document, "op_id"))
  use tool <- result.try(field_string(document, "tool"))
  use arguments <- result.try(field(document, "arguments"))
  use source_index <- result.try(field_int(document, "source_index"))
  Ok(Call(op_id:, tool:, arguments:, source_index:))
}

// --- reading the args document --------------------------------------------

fn parse(text: String) -> Result(Dynamic, String) {
  json.parse(from: text, using: decode.dynamic)
  |> result.replace_error("the hook arguments were not JSON")
}

fn field(document: Dynamic, name: String) -> Result(Dynamic, String) {
  decode.run(document, decode.at([name], decode.dynamic))
  |> result.replace_error("the hook arguments have no " <> name)
}

fn field_string(document: Dynamic, name: String) -> Result(String, String) {
  decode.run(document, decode.at([name], decode.string))
  |> result.replace_error("the hook arguments have no string " <> name)
}

fn field_int(document: Dynamic, name: String) -> Result(Int, String) {
  decode.run(document, decode.at([name], decode.int))
  |> result.replace_error("the hook arguments have no integer " <> name)
}

fn field_list(
  document: Dynamic,
  name: String,
) -> Result(List(Dynamic), String) {
  decode.run(document, decode.at([name], decode.list(decode.dynamic)))
  |> result.replace_error("the hook arguments have no array " <> name)
}
