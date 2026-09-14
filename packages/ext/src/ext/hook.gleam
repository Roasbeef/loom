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
//// Nine events are notifications or one-shot questions the harness fans
//// out to every extension. Two — `context` and `tool_result` — are
//// *chained transforms*: the harness folds them over the installed
//// extensions in load order, and each one is handed its predecessor's
//// output rather than the original. An author writing one should assume
//// somebody else has already been here.
////
//// `provider_request` and `provider_challenge` are the two questions
//// with a race for the answer: the harness fans each out in load order
//// and takes the first extension that answers with something — a
//// non-empty header list, or a `Retry` — because what the answer
//// authorises happens once and a second set of headers would have
//// nowhere to go. Everything else about them is an ordinary fan-out.
////
//// The two are halves of one arrangement, and neither is useful alone.
//// `provider_request` runs before every attempt on an
//// `auth = "extension"` entry and asks what to send; `provider_challenge`
//// runs after the provider refuses and asks what to send instead. The
//// credential that connects them lives in the extension's own durable
//// store: the harness caches nothing between the two, so an extension
//// that paid for a token on a challenge is the thing that remembers it
//// and hands it back on the next request.

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

/// What a `provider_request` hook is told: which catalogue entry is
/// about to be asked, which model on it, and when.
///
/// Deliberately no body and no messages. This event is the pre-request
/// half of the credential seam, not a view of the conversation: an
/// extension that needs what the harness is about to say has the
/// separately installed `context` capability, and widening this event
/// would hand every credential holder the transcript as a side effect.
///
/// The model is here because a credential is not always per-provider. A
/// proxy that prices each model separately hands out a token per model,
/// and an extension told only the entry name would have to guess which
/// of its tokens to send.
pub type Request {
  Request(
    /// The catalogue entry — the provider name — about to be asked.
    provider: String,
    /// The model on that entry the request targets.
    model_id: String,
    /// Wall-clock milliseconds since the Unix epoch, read from the
    /// harness's clock. It rides on the payload because the extension
    /// seam has no clock of its own, and a hook deciding whether the
    /// credential it holds has expired needs to know the time.
    now_unix_ms: Int,
  )
}

/// What a `provider_challenge` hook is told: one provider response that
/// asked the caller to authenticate, handed over raw.
///
/// The harness parses nothing here. It knows only that HTTP has
/// statuses meaning "authenticate and try again", and that the grammar
/// of the challenge — whatever scheme the provider speaks — belongs to
/// whichever extension was installed to answer it. So the status, the
/// response headers (names lowercased) and the body cross verbatim, and
/// an extension reads whichever of them its scheme lives in.
pub type Challenge {
  Challenge(
    /// The catalogue entry — the provider name — whose request was
    /// challenged.
    provider: String,
    /// The HTTP status the provider answered with.
    status: Int,
    /// The response headers, lowercase names, in the order the provider
    /// sent them.
    headers: List(#(String, String)),
    /// The response body, verbatim.
    body: String,
    /// Wall-clock milliseconds since the Unix epoch, read from the
    /// harness's clock. It rides on the payload because the extension
    /// seam has no clock of its own, and a hook enforcing a daily
    /// ceiling needs to know where the day boundary is.
    now_unix_ms: Int,
  )
}

/// What a `provider_challenge` hook answers.
pub type Answer {
  /// Retry the request with these headers appended to the adapter's
  /// own. Their values are secrets: the harness scrubs every one of
  /// them out of logs and errors, and never renders them back.
  Retry(headers: List(#(String, String)))

  /// Nothing to answer with, and a reason the harness surfaces to the
  /// caller as the provider error's text. Declining is the right answer
  /// for a challenge in a scheme this extension does not speak, or one
  /// whose price is unknown or over a ceiling.
  Declined(reason: String)
}

/// The typed behaviour behind one `[[hook]]` entry.
///
/// One variant per event, so an entry that answers the wrong event is a
/// compile error in the extension rather than a shape mismatch on the
/// wire. The generated entry module pairs each of these with the event
/// name its manifest declared.
///
/// All but two of them are notifications or questions about the
/// harness's own timeline. `OnProviderRequest` and
/// `OnProviderChallenge` are the exceptions worth naming: they are the
/// hooks whose answers change what the harness then puts on the wire,
/// because the headers they return are sent to the provider.
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

  /// `provider_request`: an `auth = "extension"` entry is about to be
  /// asked. Answer the headers to send, appended to the adapter's own,
  /// or `[]` to send none.
  ///
  /// The extension owns the credential cache; the harness owns none.
  /// This runs before *every* attempt, and whatever it answers is what
  /// is sent, so an extension holding a token durably (`ext/memory`)
  /// recalls it here and an extension holding nothing yet answers `[]`
  /// and lets the provider state its terms. Every subscriber is asked
  /// and the first non-empty answer in load order wins; the values are
  /// treated as secrets and scrubbed out of logs and errors.
  OnProviderRequest(run: fn(Request) -> List(#(String, String)))

  /// `provider_challenge`: a provider answered a request with an HTTP
  /// authentication challenge the harness cannot satisfy on its own.
  /// Answer `Retry` with the headers to send, or `Declined` with a
  /// reason the harness surfaces.
  ///
  /// The seam is protocol-agnostic by ruling: the harness hands over the
  /// raw challenge and retries the request exactly once with whatever
  /// headers come back, so a scheme it has never heard of is an
  /// extension rather than a change here.
  ///
  /// Every subscriber is asked, and the first `Retry` in load order
  /// wins. An extension whose answer arrives after another's has done
  /// work the harness discards, so a hook that spends something to
  /// answer should be the only one installed for the providers it
  /// covers.
  OnProviderChallenge(run: fn(Challenge) -> Answer)
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
    OnProviderRequest(..) -> "provider_request"
    OnProviderChallenge(..) -> "provider_challenge"
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

    OnProviderRequest(run:) -> {
      use request <- result.try(request_of(document))
      Ok(json.to_string(supplied(run(request))))
    }

    OnProviderChallenge(run:) -> {
      use challenge <- result.try(challenge_of(document))
      Ok(json.to_string(answered(run(challenge))))
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

// The headers a `provider_request` hook supplies. One shape for both
// outcomes, because holding no credential is not an error and has
// nothing to explain: an empty array says "send none", which is what
// the harness does with it.
fn supplied(headers: List(#(String, String))) -> Json {
  json.object([#("headers", json.array(headers, pair))])
}

// The entry about to be asked, read field by field. Nothing here is
// optional: the harness knows all three before it dials, so an absent
// one means the two sides disagree about the shape.
fn request_of(document: Dynamic) -> Result(Request, String) {
  use provider <- result.try(field_string(document, "provider"))
  use model_id <- result.try(field_string(document, "model_id"))
  use now_unix_ms <- result.try(field_int(document, "now_unix_ms"))
  Ok(Request(provider:, model_id:, now_unix_ms:))
}

// The answer to a provider challenge. Two documents rather than one
// with nullable headers, because the two outcomes are not the same
// fact: the harness retries the request from the first and raises a
// provider error carrying the second, and a reader of either document
// should not have to work out which happened from a null.
fn answered(answer: Answer) -> Json {
  case answer {
    Retry(headers:) ->
      json.object([
        #("answer", json.string("retry")),
        #("headers", json.array(headers, pair)),
      ])
    Declined(reason:) ->
      json.object([
        #("answer", json.string("declined")),
        #("reason", json.string(reason)),
      ])
  }
}

// A header as a two-element array rather than an object field, in both
// directions. JSON objects have no duplicate keys and no order, and a
// challenge that sends `www-authenticate` twice is an ordinary HTTP
// response the extension must see both halves of.
fn pair(header: #(String, String)) -> Json {
  json.preprocessed_array([json.string(header.0), json.string(header.1)])
}

// The challenged response, read field by field. Nothing here is
// optional: the harness writes every field on every challenge — an empty
// body is `""` and a response with no headers is `[]` — so an absent one
// means the two sides disagree about the shape rather than a provider
// that sent less.
fn challenge_of(document: Dynamic) -> Result(Challenge, String) {
  use provider <- result.try(field_string(document, "provider"))
  use status <- result.try(field_int(document, "status"))
  use headers <- result.try(field_pairs(document, "headers"))
  use body <- result.try(field_string(document, "body"))
  use now_unix_ms <- result.try(field_int(document, "now_unix_ms"))
  Ok(Challenge(provider:, status:, headers:, body:, now_unix_ms:))
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

// The header list, as the pairs the wire carries. A member that is not
// exactly two strings is a disagreement about the wire, not a header to
// skip: the harness builds this array from a header list it already
// holds, so a malformed member means one of the two sides is wrong about
// the shape and guessing past it would hand a hook half a challenge.
fn field_pairs(
  document: Dynamic,
  name: String,
) -> Result(List(#(String, String)), String) {
  let member = {
    use first <- decode.field(0, decode.string)
    use second <- decode.field(1, decode.string)
    decode.success(#(first, second))
  }
  decode.run(document, decode.at([name], decode.list(member)))
  |> result.map_error(fn(_malformed) {
    "the hook arguments have no name/value pairs " <> name
  })
}
