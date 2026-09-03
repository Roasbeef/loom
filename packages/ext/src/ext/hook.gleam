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
//// and answers with a `Json`, and the harness re-decodes the result
//// totally, discarding a transform that no longer decodes rather than
//// committing a half-understood one.
////
//// There is no `Dynamic -> Json` in the standard library, and a
//// transform that keeps most of what it was handed needs one, so
//// `rendered` is here: a total re-render of any JSON document, so an
//// author decodes the fields they came for and re-renders the rest
//// unchanged rather than rebuilding a message they did not want to
//// touch. It is `Result`-returning because it is total — a `Dynamic`
//// that is not a JSON document has no rendering, and saying so is
//// better than inventing one.
////
//// ## The events, and which of them are chained
////
//// Five events are notifications or one-shot questions the harness fans
//// out to every extension. Two — `context` and `tool_result` — are
//// *chained transforms*: the harness folds them over the installed
//// extensions in load order, and each one is handed its predecessor's
//// output rather than the original. An author writing one should assume
//// somebody else has already been here.

import gleam/dict
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
  RunStart(
    /// The operation the run was accepted as.
    op_id: String,
    /// The strand it belongs to.
    strand: String,
  )
}

/// What a `before_compact` hook is told about a compaction that has
/// already been decided.
///
/// A notification with an optional answer, never a veto: the compaction
/// runs whatever this hook returns, and returning text only adds a
/// block to the summarizer's input. The harness's own reason is one of
/// `"threshold"`, `"overflow"` and `"requested"`, and it arrives as a
/// `String` rather than a variant on purpose — a word this package
/// turned into a decode failure would be an extension that stops
/// working the day the harness learns a fourth door.
pub type Compaction {
  Compaction(
    /// The operation the compaction belongs to.
    op_id: String,
    /// Why the compaction started: `"threshold"`, `"overflow"` or
    /// `"requested"` today.
    reason: String,
    /// What the context cost before the compaction, in tokens.
    tokens_before: Int,
    /// How many projected messages the summary replaces.
    summarized_messages: Int,
    /// How many trailing messages survive verbatim.
    retained_messages: Int,
  )
}

/// Whether a ledger row is a provider's report or a caller's correction.
///
/// The harness sends a boolean and this is what it means, named, so a
/// tracing hook does not have to carry the polarity of an `adjustment`
/// flag in its head.
pub type UsageOrigin {
  /// The provider reported these numbers for a request.
  ProviderReported

  /// A caller wrote a reconciliation row against the ledger.
  ///
  /// Nothing in the harness produces one today: every row a run commits
  /// is a provider's report, and no adjustment path exists to write the
  /// other kind. The variant is here so the wire field stays total — the
  /// harness sends a boolean and a decoder that could only read `false`
  /// would be one an author had to revisit the day an adjustment lands.
  Reconciliation
}

/// One committed cost-ledger row, as a `usage` hook reads it.
///
/// Numbers and coordinates only. No request and no response content
/// crosses this event, by ruling: an extension that wanted the
/// conversation has `context` and `tool_result`, and both are gated on
/// an install the operator read.
pub type Usage {
  Usage(
    /// The operation the row belongs to.
    op_id: String,
    /// The row's own id.
    usage_id: String,
    /// The storage-assigned seq the row committed at.
    seq: Int,
    /// The entry this cost belongs to, when the row names one.
    entry_id: Option(String),
    /// Where the numbers came from.
    origin: UsageOrigin,
    /// Uncached input tokens.
    input_tokens: Int,
    /// Output tokens.
    output_tokens: Int,
    /// Input tokens served from the provider's cache.
    cache_read_tokens: Int,
    /// Input tokens written to the provider's cache.
    cache_write_tokens: Int,
    /// Input tokens written to a one-hour cache, when the provider
    /// reports that separately.
    cache_write_1h_tokens: Option(Int),
    /// Thinking tokens, when the provider reports them.
    thinking_tokens: Option(Int),
    /// The provider's own total.
    total_tokens: Int,
    /// What the row cost, in dollars.
    cost: Float,
  )
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
  Context(
    /// The operation the request belongs to.
    op_id: String,
    /// The projected message list, as the previous extension in the
    /// chain left it. Each message is `core/codec`'s durable JSON;
    /// `rendered` turns one back into `Json` unchanged, which is how a
    /// hook keeps the messages it did not come for.
    messages: List(Dynamic),
  )
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
  ///
  /// The answer is a `List(Json)`, so a hook that keeps a message it did
  /// not come for has to re-render it: `rendered` does that, totally,
  /// and is the intended first line of an implementation.
  OnContext(run: fn(Context) -> List(Json))

  /// `tool_call`: a call was planned, before dispatch.
  OnToolCall(run: fn(Call) -> Verdict)

  /// `tool_result`: a tool settled, before the reply is committed.
  /// Chained. The message handed in is the whole reply, and the harness
  /// takes its `content` and nothing else — `is_error`, the usage and
  /// the call's coordinates stay the harness's whatever this answers
  /// with. `rendered` re-renders the parts a hook leaves alone.
  OnToolResult(run: fn(Dynamic) -> Json)

  /// `agent_end`: a run reached a terminal state.
  OnAgentEnd(run: fn(String) -> Nil)

  /// `agent_settled`: the run and every follow-up it queued are done.
  OnAgentSettled(run: fn(String) -> Nil)

  /// `before_compact`: the runtime decided to compact, before the
  /// summary generation starts. Return text to have it appended to the
  /// summarizer's input, fenced and attributed to this extension by the
  /// harness, or `None` to add nothing. The harness discards a note
  /// past its token allowance, and no answer stops the compaction.
  OnBeforeCompact(run: fn(Compaction) -> Option(String))

  /// `usage`: one cost-ledger row was committed. Notify-only; there is
  /// nothing to answer, and the row is already durable when this runs.
  OnUsage(run: fn(Usage) -> Nil)
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
    OnBeforeCompact(..) -> "before_compact"
    OnUsage(..) -> "usage"
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

    OnBeforeCompact(run:) -> {
      use compaction <- result.try(compaction_of(document))
      Ok(json.to_string(note(run(compaction))))
    }

    OnUsage(run:) -> {
      use usage <- result.try(usage_of(document))
      run(usage)
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

fn note(text: Option(String)) -> Json {
  case text {
    Some(text) -> json.object([#("note", json.string(text))])
    None -> json.object([#("note", json.null())])
  }
}

fn compaction_of(document: Dynamic) -> Result(Compaction, String) {
  use op_id <- result.try(field_string(document, "op_id"))
  use reason <- result.try(field_string(document, "reason"))
  use tokens_before <- result.try(field_int(document, "tokens_before"))
  use summarized <- result.try(field_int(document, "summarized_messages"))
  use retained <- result.try(field_int(document, "retained_messages"))
  Ok(Compaction(
    op_id:,
    reason:,
    tokens_before:,
    summarized_messages: summarized,
    retained_messages: retained,
  ))
}

// The ledger row, read field by field. The two optional counts and the
// optional entry are optional on the wire because the harness's own
// `Usage` and `UsageRow` have them optional; everything else is
// required, so a document missing a count is a disagreement about the
// wire rather than a provider that reported nothing.
fn usage_of(document: Dynamic) -> Result(Usage, String) {
  use op_id <- result.try(field_string(document, "op_id"))
  use usage_id <- result.try(field_string(document, "usage_id"))
  use seq <- result.try(field_int(document, "seq"))
  use origin <- result.try(field_bool(document, "adjustment"))
  use input <- result.try(field_int(document, "input_tokens"))
  use output <- result.try(field_int(document, "output_tokens"))
  use cache_read <- result.try(field_int(document, "cache_read_tokens"))
  use cache_write <- result.try(field_int(document, "cache_write_tokens"))
  use total <- result.try(field_int(document, "total_tokens"))
  use cost <- result.try(field_float(document, "cost"))
  Ok(Usage(
    op_id:,
    usage_id:,
    seq:,
    entry_id: optional_string(document, "entry_id"),
    origin: case origin {
      True -> Reconciliation
      False -> ProviderReported
    },
    input_tokens: input,
    output_tokens: output,
    cache_read_tokens: cache_read,
    cache_write_tokens: cache_write,
    cache_write_1h_tokens: optional_int(document, "cache_write_1h_tokens"),
    thinking_tokens: optional_int(document, "thinking_tokens"),
    total_tokens: total,
    cost:,
  ))
}

fn call_of(document: Dynamic) -> Result(Call, String) {
  use op_id <- result.try(field_string(document, "op_id"))
  use tool <- result.try(field_string(document, "tool"))
  use arguments <- result.try(field(document, "arguments"))
  use source_index <- result.try(field_int(document, "source_index"))
  Ok(Call(op_id:, tool:, arguments:, source_index:))
}

/// Re-renders a JSON document read as `Dynamic` back into `Json`,
/// unchanged.
///
/// The one thing an author cannot write themselves and needs on every
/// `context` and `tool_result` hook: the messages a transform leaves
/// alone have to come back out, and they arrive as `Dynamic` because
/// `core`'s message type is not on the extension seam.
///
/// Total, and the failure is real rather than defensive: the values that
/// reach a hook came from a JSON document, so this returns `Error` only
/// for a `Dynamic` an author built themselves out of something else.
///
/// ## Examples
///
/// ```gleam
/// let keep = hook.OnContext(fn(context) {
///   list.filter_map(context.messages, fn(message) {
///     hook.rendered(message) |> result.replace_error(Nil)
///   })
/// })
/// ```
///
pub fn rendered(value: Dynamic) -> Result(Json, String) {
  decode.run(value, renderer())
  |> result.replace_error("the value is not a JSON document")
}

// The seven shapes a JSON document is made of. `decode.one_of` tries
// them in order, and the containers recurse through this same decoder,
// so an object of arrays of numbers comes back as itself. Null is last
// and is written as an optional *string* rather than as an optional
// anything: `decode.optional(decode.dynamic)` would succeed on every
// value that reached it and render it `null`, turning a shape this
// decoder does not know into silent data loss instead of the `Error`
// the caller is promised.
fn renderer() -> decode.Decoder(Json) {
  decode.one_of(decode.map(decode.string, json.string), or: [
    decode.map(decode.int, json.int),
    decode.map(decode.float, json.float),
    decode.map(decode.bool, json.bool),
    decode.map(decode.list(renderer_thunk()), json.preprocessed_array),
    decode.map(decode.dict(decode.string, renderer_thunk()), object_of),
    decode.map(decode.optional(decode.string), fn(_null) { json.null() }),
  ])
}

// The recursion, deferred. A decoder that named `renderer()` directly
// inside its own body would build the whole tree of decoders before
// running any of it, which does not terminate; `decode.recursive` is
// what the standard library provides for exactly this.
fn renderer_thunk() -> decode.Decoder(Json) {
  decode.recursive(renderer)
}

fn object_of(fields: dict.Dict(String, Json)) -> Json {
  json.object(dict.to_list(fields))
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

fn field_bool(document: Dynamic, name: String) -> Result(Bool, String) {
  decode.run(document, decode.at([name], decode.bool))
  |> result.replace_error("the hook arguments have no boolean " <> name)
}

fn field_float(document: Dynamic, name: String) -> Result(Float, String) {
  decode.run(document, decode.at([name], decode.float))
  |> result.replace_error("the hook arguments have no number " <> name)
}

// A field that is absent, or present and null, or present and of the
// wrong shape, is all one answer: nothing. These are the fields the
// harness itself carries as `Option`, so "not reported" is the value
// rather than a disagreement about the wire.
fn optional_string(document: Dynamic, name: String) -> Option(String) {
  case decode.run(document, decode.at([name], decode.string)) {
    Ok(value) -> Some(value)
    Error(_absent) -> None
  }
}

fn optional_int(document: Dynamic, name: String) -> Option(Int) {
  case decode.run(document, decode.at([name], decode.int)) {
    Ok(value) -> Some(value)
    Error(_absent) -> None
  }
}

fn field_list(
  document: Dynamic,
  name: String,
) -> Result(List(Dynamic), String) {
  decode.run(document, decode.at([name], decode.list(decode.dynamic)))
  |> result.replace_error("the hook arguments have no array " <> name)
}
