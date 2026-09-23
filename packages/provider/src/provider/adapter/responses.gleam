//// The public API-key Responses dialect, independent of Chat Completions.
////
//// Each output item owns indexed parts until their delta, part, item and
//// final-response witnesses agree. Deltas remain ephemeral; only the final
//// verified response settles. Authentication appears only in build_request's
//// outbound header, never in the pure accumulator or diagnostic metadata.

import core/corruption
import core/json.{type JsonValue}
import core/message
import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import provider/http
import provider/internal/diagnostic
import provider/internal/responses_items as items
import provider/internal/responses_request
import provider/internal/wire
import provider/model.{type ProviderRequest, type ResolvedModel}
import provider/retry
import provider/stream.{type StreamEvent}

/// The distinct durable API identity for this adapter.
pub const api_name = "openai-responses"

/// Builds a stateless streaming Responses request. The base includes the API
/// root; the gateway normalizes its trailing slash before dispatch.
///
/// ## Examples
///
/// ```gleam
/// // responses.build_request(base_url: "https://api.openai.com/v1",
/// //   api_key: key, resolved: resolved, request: request)
/// ```
pub fn build_request(
  base_url base_url: String,
  api_key api_key: String,
  resolved resolved: ResolvedModel,
  request request: ProviderRequest,
) -> http.HttpRequest {
  http.HttpRequest(
    method: "POST",
    url: base_url <> "/responses",
    headers: [
      #("authorization", "Bearer " <> api_key),
      #("content-type", "application/json"),
      #("accept", "text/event-stream"),
    ],
    body: responses_request.body(resolved, request),
  )
}

// A failed semantic witness closes the attempt just as settlement does. Both
// paths enter Terminal before returning their one public terminal event.
type Life {
  Streaming
  Terminal
}

// TextDone proves the byte-level witness; Closed separately proves the whole
// part, including annotations. An item cannot skip either boundary.
type Closure {
  Open
  TextDone
  Closed
}

// Summary indices have their own namespace. The other three kinds share the
// content-index namespace and therefore cannot reuse each other's positions.
type PartKind {
  OutputText
  Refusal
  Summary
  Reasoning
}

// The wire index routes provider events, while block names the immutable Loom
// delta position. Neither is inferred later from the position in this list.
type Part {
  Part(
    index: Int,
    block: Int,
    kind: PartKind,
    text: String,
    annotations: List(JsonValue),
    closure: Closure,
  )
}

// Function calls own argument bytes directly. Messages and reasoning items own
// typed parts; the distinction prevents a text event from editing a call.
type ItemKind {
  Message
  Thought
  Function(
    call_id: String,
    name: String,
    block: Int,
    arguments: String,
    closure: Closure,
  )
}

// A canonical done item replaces no live content: it is retained only after
// agreeing with the accumulated parts. Encrypted-only reasoning has no part
// event, so its durable empty block receives an index at item completion.
type Item {
  Item(
    index: Int,
    id: String,
    kind: ItemKind,
    phase: Option(String),
    parts: List(Part),
    done: Option(JsonValue),
    empty_block: Option(Int),
  )
}

/// Pure state for one attempt. Items remain keyed by both provider index and
/// identity; terminal state makes every later chunk an explicit no-op.
pub opaque type Accumulator {
  /// One attempt's parser and validation state; no request or credential is
  /// retained here. The response byte count includes discarded SSE framing.
  Accumulator(
    /// Configured identity and limits, not the remote model's claims.
    resolved: ResolvedModel,
    /// Injected settlement timestamp.
    now: Int,
    /// HTTP status received before body chunks.
    status: Int,
    /// Parsed retry delay, used only for HTTP errors.
    retry_after: Option(Int),
    /// Error-body bytes retained under the shared 64 KiB bound.
    error_body: BitArray,
    /// Shared bounded incremental SSE parser.
    sse: stream.SseParser,
    /// Whether further remote input may still change the attempt.
    life: Life,
    /// Original response ID and remote model, checked at every witness.
    identity: Option(#(String, String)),
    /// Last present sequence number; omission does not erase it.
    sequence: Option(Int),
    /// Independently addressable item states, retained through final proof.
    items: List(Item),
    /// Next never-reused durable block position.
    next_block: Int,
    /// Total delivered body bytes for this attempt.
    bytes: Int,
  )
}

/// Supplies the same sans-I/O fold as the other adapters. EOF cannot substitute
/// for a final Responses witness.
///
/// ## Examples
///
/// ```gleam
/// // let machine = responses.response_machine(resolved, now: 1000)
/// ```
pub fn response_machine(
  resolved: ResolvedModel,
  now now: Int,
) -> stream.ResponseMachine(Accumulator) {
  stream.ResponseMachine(
    init: Accumulator(
      resolved:,
      now:,
      status: 0,
      retry_after: None,
      error_body: <<>>,
      sse: stream.new_parser(),
      life: Streaming,
      identity: None,
      sequence: None,
      items: [],
      next_block: 0,
      bytes: 0,
    ),
    on_status: fn(acc, status, headers) {
      case acc.life {
        Terminal -> acc
        Streaming ->
          Accumulator(..acc, status:, retry_after: wire.retry_after_ms(headers))
      }
    },
    on_chunk: on_chunk,
    on_end: fn(acc) {
      case acc.life, acc.status {
        Terminal, _ -> []
        Streaming, 200 -> [
          stream.Failed(stream.StreamDisconnected(
            "Responses ended before a verified terminal",
          )),
        ]
        Streaming, status -> [stream.Failed(http_error(acc, status))]
      }
    },
    on_failure: fn(acc, _) {
      case acc.life {
        Terminal -> []
        Streaming -> [
          stream.Failed(stream.TransportFailed("Responses transport failed")),
        ]
      }
    },
  )
}

// Framing and attempt limits are independent of semantic assembly. Reverse
// accumulation avoids copying every earlier delta for each event in a chunk.
fn on_chunk(
  acc: Accumulator,
  chunk: BitArray,
) -> #(Accumulator, List(StreamEvent)) {
  use <- bool.guard(acc.life == Terminal, #(acc, []))
  use <- bool.lazy_guard(
    acc.bytes + bit_array.byte_size(chunk) > 16_777_216,
    fn() { malformed(acc) },
  )
  let acc = Accumulator(..acc, bytes: acc.bytes + bit_array.byte_size(chunk))
  case acc.status {
    200 -> {
      let #(sse, events) = stream.feed(acc.sse, chunk)
      let #(acc, reversed) =
        list.fold(events, #(Accumulator(..acc, sse:), []), fn(state, event) {
          let #(acc, emitted) = state
          let #(acc, next) = handle_sse(acc, event)
          #(
            acc,
            list.fold(next, emitted, fn(events, event) { [event, ..events] }),
          )
        })
      #(acc, list.reverse(reversed))
    }
    _ ->
      case diagnostic.append_error_body(acc.error_body, chunk) {
        Ok(error_body) -> #(Accumulator(..acc, error_body:), [])
        Error(Nil) -> malformed(acc)
      }
  }
}

// The failure describes the violated boundary, never the remote data. A JSON
// parser excerpt could otherwise copy provider-reflected credentials here.
fn malformed(acc: Accumulator) -> #(Accumulator, List(StreamEvent)) {
  fail(
    acc,
    stream.MalformedStream(corruption.report(
      at: "provider/adapter/responses",
      on: "provider stream",
      expected: "consistent Responses item and terminal witnesses",
      context: "invalid Responses stream",
    )),
  )
}

fn fail(
  acc: Accumulator,
  error: stream.ProviderError,
) -> #(Accumulator, List(StreamEvent)) {
  case acc.life {
    Terminal -> #(acc, [])
    Streaming -> #(Accumulator(..acc, life: Terminal), [stream.Failed(error)])
  }
}

// The adapter's short-circuit combinator keeps decoder failures on the same
// once-only terminal path as failures discovered by the transition guards.
fn or_malformed(
  value: Result(a, Nil),
  acc: Accumulator,
  then: fn(a) -> #(Accumulator, List(StreamEvent)),
) -> #(Accumulator, List(StreamEvent)) {
  case value {
    Ok(value) -> then(value)
    Error(Nil) -> malformed(acc)
  }
}

// SSE event names, when present, must agree with the JSON discriminator.
// Parsing remains total, and an already terminal attempt ignores even junk.
fn handle_sse(
  acc: Accumulator,
  event: stream.SseEvent,
) -> #(Accumulator, List(StreamEvent)) {
  use <- bool.guard(acc.life == Terminal, #(acc, []))
  case event {
    stream.SseMalformed(..) -> malformed(acc)
    stream.SseMessage(event: name, data:) -> {
      use value <- or_malformed(
        result.replace_error(json.parse(data), Nil),
        acc,
      )
      use kind <- or_malformed(wire.string_field(value, "type"), acc)
      use <- bool.lazy_guard(name != None && name != Some(kind), fn() {
        malformed(acc)
      })
      use sequence <- or_malformed(sequence(acc.sequence, value), acc)
      dispatch(Accumulator(..acc, sequence:), kind, value)
    }
  }
}

// Compatible endpoints may omit sequence numbers. A later present value must
// still advance beyond the last observed one, including across omissions.
fn sequence(
  previous: Option(Int),
  value: JsonValue,
) -> Result(Option(Int), Nil) {
  case wire.field(value, "sequence_number") {
    Error(Nil) -> Ok(previous)
    Ok(json.Int(next)) ->
      case previous {
        Some(old) if next <= old -> Error(Nil)
        _ if next < 0 -> Error(Nil)
        _ -> Ok(Some(next))
      }
    Ok(_) -> Error(Nil)
  }
}

// Every supported semantic event has an explicit transition. Unknown content
// fails instead of silently changing the meaning of a tool or assistant turn.
fn dispatch(
  acc: Accumulator,
  kind: String,
  value: JsonValue,
) -> #(Accumulator, List(StreamEvent)) {
  case kind {
    "response.created" | "response.in_progress" -> {
      use response <- or_malformed(wire.field(value, "response"), acc)
      use identity <- or_malformed(identity(acc, response), acc)
      use <- bool.lazy_guard(
        wire.string_field(response, "status") != Ok("in_progress"),
        fn() { malformed(acc) },
      )
      #(Accumulator(..acc, identity: Some(identity)), [])
    }
    "response.output_item.added" -> add_item(acc, value)
    "response.content_part.added" | "response.reasoning_summary_part.added" ->
      add_part(acc, kind, value)
    "response.output_text.delta"
    | "response.refusal.delta"
    | "response.reasoning_summary_text.delta"
    | "response.reasoning_text.delta" -> change_part(acc, kind, value)
    "response.output_text.done"
    | "response.refusal.done"
    | "response.reasoning_summary_text.done"
    | "response.reasoning_text.done" -> change_part(acc, kind, value)
    "response.content_part.done" | "response.reasoning_summary_part.done" ->
      close_part(acc, kind, value)
    "response.output_text.annotation.added" -> add_annotation(acc, value)
    "response.function_call_arguments.delta"
    | "response.function_call_arguments.done" -> arguments(acc, kind, value)
    "response.output_item.done" -> close_item(acc, value)
    "response.completed" | "response.incomplete" | "response.cancelled" ->
      terminal(acc, kind, value)
    "response.failed" | "error" -> {
      let error = case kind {
        "response.failed" ->
          value
          |> wire.field("response")
          |> result.try(wire.field(_, "error"))
          |> result.unwrap(json.Null)
        _ -> value
      }
      let #(code, description) = error_fields(error)
      fail(acc, stream.StreamError(code, description))
    }
    _ -> malformed(acc)
  }
}

fn identity(
  acc: Accumulator,
  response: JsonValue,
) -> Result(#(String, String), Nil) {
  use id <- result.try(items.nonempty(response, "id"))
  use model <- result.try(items.nonempty(response, "model"))
  case acc.identity {
    None -> Ok(#(id, model))
    Some(existing) if existing == #(id, model) -> Ok(existing)
    Some(_) -> Error(Nil)
  }
}

// Known error codes retain retry and overflow semantics without copying the
// remote message, which may contain request headers or credentials.
fn error_fields(value: JsonValue) -> #(String, String) {
  let code =
    wire.string_field_or(value, "code", wire.string_field_or(value, "type", ""))
  case code {
    "overloaded_error"
    | "rate_limit_error"
    | "api_error"
    | "timeout_error"
    | "server_error"
    | "internal_server_error" -> #(
      code,
      "Responses provider reported a transient failure",
    )
    "rate_limit_exceeded" -> #(
      "rate_limit_error",
      "Responses provider rate limit exceeded",
    )
    "context_length_exceeded" -> #(
      "context_length_exceeded",
      "maximum context length exceeded",
    )
    _ -> #("responses_error", "Responses provider reported failure")
  }
}

fn http_error(acc: Accumulator, status: Int) -> stream.ProviderError {
  let value =
    acc.error_body
    |> bit_array.to_string
    |> result.try(fn(text) { json.parse(text) |> result.replace_error(Nil) })
    |> result.try(wire.field(_, "error"))
    |> result.unwrap(json.Null)
  let #(code, description) = error_fields(value)
  stream.HttpError(status, code, description, acc.retry_after)
}

// Item publication reserves both identities before any deltas are accepted.
// A call's synthetic block is allocated here because it has no part-added event.
fn add_item(
  acc: Accumulator,
  value: JsonValue,
) -> #(Accumulator, List(StreamEvent)) {
  use index <- or_malformed(wire.int_field(value, "output_index"), acc)
  use value <- or_malformed(wire.field(value, "item"), acc)
  use id <- or_malformed(items.nonempty(value, "id"), acc)
  use kind <- or_malformed(wire.string_field(value, "type"), acc)
  use phase <- or_malformed(
    case kind {
      "message" -> items.message_phase(value)
      _ -> Ok(None)
    },
    acc,
  )
  use start_status <- or_malformed(items.optional_string(value, "status"), acc)
  use <- bool.lazy_guard(
    start_status != None && start_status != Some("in_progress"),
    fn() { malformed(acc) },
  )
  use <- bool.lazy_guard(
    acc.identity == None
      || index < 0
      || list.any(acc.items, fn(item) { item.index == index || item.id == id }),
    fn() { malformed(acc) },
  )
  use kind <- or_malformed(
    case kind {
      "message" -> {
        use <- bool.guard(
          wire.string_field(value, "role") != Ok("assistant")
            || wire.array_field(value, "content") != Ok([]),
          Error(Nil),
        )
        Ok(Message)
      }
      "reasoning" -> {
        use <- bool.guard(
          wire.array_field(value, "summary") != Ok([]),
          Error(Nil),
        )
        Ok(Thought)
      }
      "function_call" -> {
        use call_id <- result.try(items.nonempty(value, "call_id"))
        use name <- result.try(items.nonempty(value, "name"))
        use <- bool.guard(
          wire.string_field(value, "arguments") != Ok(""),
          Error(Nil),
        )
        use <- bool.guard(
          list.any(acc.items, fn(item) {
            case item.kind {
              Function(call_id: other, ..) -> other == call_id
              _ -> False
            }
          }),
          Error(Nil),
        )
        Ok(Function(
          call_id:,
          name:,
          block: acc.next_block,
          arguments: "",
          closure: Open,
        ))
      }
      _ -> Error(Nil)
    },
    acc,
  )
  let next_block = case kind {
    Function(..) -> acc.next_block + 1
    _ -> acc.next_block
  }
  #(
    Accumulator(
      ..acc,
      items: [
        Item(
          index:,
          id:,
          kind:,
          phase:,
          parts: [],
          done: None,
          empty_block: None,
        ),
        ..acc.items
      ],
      next_block:,
    ),
    [],
  )
}

// Both provider keys must name the same live item. A late fragment cannot
// reopen an item whose closing witness has already been accepted.
fn find_item(acc: Accumulator, value: JsonValue) -> Result(Item, Nil) {
  use index <- result.try(wire.int_field(value, "output_index"))
  use id <- result.try(items.nonempty(value, "item_id"))
  list.find(acc.items, fn(item) {
    item.index == index && item.id == id && item.done == None
  })
}

fn replace(acc: Accumulator, item: Item) -> Accumulator {
  Accumulator(
    ..acc,
    items: list.map(acc.items, fn(old) {
      case old.index == item.index {
        True -> item
        False -> old
      }
    }),
  )
}

fn part_index(kind: String, value: JsonValue) -> Result(Int, Nil) {
  case kind {
    "response.reasoning_summary_part.added"
    | "response.reasoning_summary_part.done"
    | "response.reasoning_summary_text.delta"
    | "response.reasoning_summary_text.done" ->
      wire.int_field(value, "summary_index")
    _ -> wire.int_field(value, "content_index")
  }
}

// A part starts empty and receives its permanent delta index exactly once.
// The event family and part kind must agree on the index namespace.
fn add_part(
  acc: Accumulator,
  event: String,
  value: JsonValue,
) -> #(Accumulator, List(StreamEvent)) {
  use item <- or_malformed(find_item(acc, value), acc)
  use index <- or_malformed(part_index(event, value), acc)
  use raw <- or_malformed(wire.field(value, "part"), acc)
  use raw <- or_malformed(items.part(raw), acc)
  use kind <- or_malformed(
    case wire.string_field(raw, "type"), item.kind {
      Ok("output_text"), Message -> Ok(OutputText)
      Ok("refusal"), Message -> Ok(Refusal)
      Ok("summary_text"), Thought -> Ok(Summary)
      Ok("reasoning_text"), Thought -> Ok(Reasoning)
      _, _ -> Error(Nil)
    },
    acc,
  )
  use <- bool.lazy_guard(
    index < 0
      || list.any(item.parts, fn(part) {
      part.index == index && same_namespace(part.kind, kind)
    })
      || { kind == Summary }
      != { event == "response.reasoning_summary_part.added" }
      || part_text(raw, kind) != ""
      || result.unwrap(wire.array_field(raw, "annotations"), []) != [],
    fn() { malformed(acc) },
  )
  let part =
    Part(
      index:,
      block: acc.next_block,
      kind:,
      text: "",
      annotations: [],
      closure: Open,
    )
  #(
    Accumulator(
      ..replace(acc, Item(..item, parts: [part, ..item.parts])),
      next_block: acc.next_block + 1,
    ),
    [],
  )
}

fn event_part_kind(kind: String) -> PartKind {
  case kind {
    "response.refusal.delta" | "response.refusal.done" -> Refusal
    "response.reasoning_summary_text.delta"
    | "response.reasoning_summary_text.done" -> Summary
    "response.reasoning_text.delta" | "response.reasoning_text.done" ->
      Reasoning
    _ -> OutputText
  }
}

fn same_namespace(left: PartKind, right: PartKind) -> Bool {
  { left == Summary } == { right == Summary }
}

fn part_text(value: JsonValue, kind: PartKind) -> String {
  wire.string_field_or(
    value,
    case kind {
      Refusal -> "refusal"
      _ -> "text"
    },
    "",
  )
}

// A text-done event compares exact bytes and emits nothing. Only an open part
// accepts deltas, so duplicate completion cannot append content twice.
fn change_part(
  acc: Accumulator,
  event: String,
  value: JsonValue,
) -> #(Accumulator, List(StreamEvent)) {
  use item <- or_malformed(find_item(acc, value), acc)
  use index <- or_malformed(part_index(event, value), acc)
  let kind = event_part_kind(event)
  use part <- or_malformed(
    list.find(item.parts, fn(part) {
      part.index == index && part.kind == kind && part.closure == Open
    }),
    acc,
  )
  let done =
    list.contains(
      [
        "response.output_text.done",
        "response.refusal.done",
        "response.reasoning_summary_text.done",
        "response.reasoning_text.done",
      ],
      event,
    )
  use text <- or_malformed(
    wire.string_field(value, case done, kind {
      False, _ -> "delta"
      True, Refusal -> "refusal"
      True, _ -> "text"
    }),
    acc,
  )
  use <- bool.lazy_guard(done && text != part.text, fn() { malformed(acc) })
  let next = case done {
    True -> Part(..part, closure: TextDone)
    False -> Part(..part, text: part.text <> text)
  }
  let item =
    Item(
      ..item,
      parts: list.map(item.parts, fn(old) {
        case old.block == part.block {
          True -> next
          False -> old
        }
      }),
    )
  let events = case done, kind {
    True, _ -> []
    False, OutputText | False, Refusal -> [
      stream.Delta(stream.TextDelta(part.block, text)),
    ]
    False, Summary | False, Reasoning -> [
      stream.Delta(stream.ThinkingDelta(part.block, text)),
    ]
  }
  #(replace(acc, item), events)
}

fn part_value(part: Part) -> JsonValue {
  case part.kind {
    OutputText ->
      json.Object([
        #("type", json.String("output_text")),
        #("text", json.String(part.text)),
        #("annotations", json.Array(part.annotations)),
      ])
    Refusal ->
      json.Object([
        #("type", json.String("refusal")),
        #("refusal", json.String(part.text)),
      ])
    Summary ->
      json.Object([
        #("type", json.String("summary_text")),
        #("text", json.String(part.text)),
      ])
    Reasoning ->
      json.Object([
        #("type", json.String("reasoning_text")),
        #("text", json.String(part.text)),
      ])
  }
}

// The part witness additionally covers annotations and the content kind;
// equal text alone is not enough to close a different semantic part.
fn close_part(
  acc: Accumulator,
  event: String,
  value: JsonValue,
) -> #(Accumulator, List(StreamEvent)) {
  use item <- or_malformed(find_item(acc, value), acc)
  use index <- or_malformed(part_index(event, value), acc)
  use raw <- or_malformed(wire.field(value, "part"), acc)
  use raw <- or_malformed(items.part(raw), acc)
  use <- bool.lazy_guard(
    { wire.string_field(raw, "type") == Ok("summary_text") }
      != { event == "response.reasoning_summary_part.done" },
    fn() { malformed(acc) },
  )
  use part <- or_malformed(
    list.find(item.parts, fn(part) {
      part.index == index && part.closure == TextDone && part_value(part) == raw
    }),
    acc,
  )
  #(
    replace(
      acc,
      Item(
        ..item,
        parts: list.map(item.parts, fn(old) {
          case old.block == part.block {
            True -> Part(..old, closure: Closed)
            False -> old
          }
        }),
      ),
    ),
    [],
  )
}

// An annotation is a bounded replay field, not a new text delta. Its index
// must append to the exact part's citation sequence before that part closes.
fn add_annotation(
  acc: Accumulator,
  value: JsonValue,
) -> #(Accumulator, List(StreamEvent)) {
  use item <- or_malformed(find_item(acc, value), acc)
  use index <- or_malformed(wire.int_field(value, "content_index"), acc)
  use part <- or_malformed(
    list.find(item.parts, fn(part) {
      part.index == index && part.kind == OutputText && part.closure != Closed
    }),
    acc,
  )
  use annotation_index <- or_malformed(
    wire.int_field(value, "annotation_index"),
    acc,
  )
  use <- bool.lazy_guard(
    annotation_index != list.length(part.annotations),
    fn() { malformed(acc) },
  )
  use raw <- or_malformed(wire.field(value, "annotation"), acc)
  use annotation <- or_malformed(items.annotation(raw), acc)
  let next =
    Part(..part, annotations: list.append(part.annotations, [annotation]))
  #(
    replace(
      acc,
      Item(
        ..item,
        parts: list.map(item.parts, fn(old) {
          case old.block == part.block {
            True -> next
            False -> old
          }
        }),
      ),
    ),
    [],
  )
}

// Argument text is provider protocol until all witnesses agree. Whether that
// agreed text is valid model-authored JSON is decided later by wire.tool_arguments.
fn arguments(
  acc: Accumulator,
  event: String,
  value: JsonValue,
) -> #(Accumulator, List(StreamEvent)) {
  use item <- or_malformed(find_item(acc, value), acc)
  use fields <- or_malformed(
    case item.kind {
      Function(call_id:, name:, block:, arguments:, closure: Open) ->
        Ok(#(call_id, name, block, arguments))
      _ -> Error(Nil)
    },
    acc,
  )
  let #(call_id, name, block, previous) = fields
  use named <- or_malformed(items.optional_string(value, "name"), acc)
  use called <- or_malformed(items.optional_string(value, "call_id"), acc)
  use <- bool.lazy_guard(
    { named != None && named != Some(name) }
      || { called != None && called != Some(call_id) },
    fn() { malformed(acc) },
  )
  let done = event == "response.function_call_arguments.done"
  use text <- or_malformed(
    wire.string_field(value, case done {
      True -> "arguments"
      False -> "delta"
    }),
    acc,
  )
  use <- bool.lazy_guard(done && text != previous, fn() { malformed(acc) })
  let #(arguments, closure, events) = case done {
    True -> #(previous, TextDone, [])
    False -> #(previous <> text, Open, [
      stream.Delta(stream.ToolCallDelta(block, call_id, name, text)),
    ])
  }
  #(
    replace(
      acc,
      Item(
        ..item,
        kind: Function(call_id:, name:, block:, arguments:, closure:),
      ),
    ),
    events,
  )
}

// Canonicalization removes unknown metadata before comparison, but it cannot
// replace any streamed content. Every part must already have its own closure.
fn close_item(
  acc: Accumulator,
  value: JsonValue,
) -> #(Accumulator, List(StreamEvent)) {
  use index <- or_malformed(wire.int_field(value, "output_index"), acc)
  use raw <- or_malformed(wire.field(value, "item"), acc)
  use canonical <- or_malformed(items.item(raw), acc)
  use item <- or_malformed(
    list.find(acc.items, fn(item) {
      item.index == index
      && item.done == None
      && wire.string_field(canonical, "id") == Ok(item.id)
    }),
    acc,
  )
  use Nil <- or_malformed(verify_item(item, canonical), acc)
  let #(empty_block, next_block) = case item.kind, item.parts {
    Thought, [] -> #(Some(acc.next_block), acc.next_block + 1)
    _, _ -> #(None, acc.next_block)
  }
  #(
    Accumulator(
      ..replace(acc, Item(..item, done: Some(canonical), empty_block:)),
      next_block:,
    ),
    [],
  )
}

// Part arrays are indexed arrays, not sparse maps. Summary and content arrays
// each prove their own contiguous positions before matching the item witness.
fn verify_item(item: Item, canonical: JsonValue) -> Result(Nil, Nil) {
  // A supplied initial phase is a witness, not a default. An omitted phase
  // may be learned at completion, but an observed one cannot be rewritten.
  use <- bool.guard(
    item.phase != None
      && item.phase != option.from_result(wire.string_field(canonical, "phase")),
    Error(Nil),
  )
  use <- bool.guard(
    list.any(item.parts, fn(part) { part.closure != Closed }),
    Error(Nil),
  )
  use <- bool.guard(
    wire.string_field(canonical, "status") == Ok("in_progress"),
    Error(Nil),
  )
  let parts = list.sort(item.parts, fn(a, b) { int.compare(a.index, b.index) })
  use <- bool.guard(
    !contiguous(list.filter(parts, fn(part) { part.kind == Summary }))
      || !contiguous(list.filter(parts, fn(part) { part.kind != Summary })),
    Error(Nil),
  )
  case item.kind {
    Function(call_id:, name:, arguments:, closure: TextDone, ..) -> {
      use <- bool.guard(
        wire.string_field(canonical, "type") != Ok("function_call")
          || wire.string_field(canonical, "call_id") != Ok(call_id)
          || wire.string_field(canonical, "name") != Ok(name)
          || wire.string_field(canonical, "arguments") != Ok(arguments),
        Error(Nil),
      )
      Ok(Nil)
    }
    Function(..) -> Error(Nil)
    Message -> {
      use <- bool.guard(
        wire.string_field(canonical, "type") != Ok("message")
          || wire.array_field(canonical, "content")
          != Ok(list.map(parts, part_value)),
        Error(Nil),
      )
      Ok(Nil)
    }
    Thought -> {
      let summary = list.filter(parts, fn(part) { part.kind == Summary })
      let content = list.filter(parts, fn(part) { part.kind == Reasoning })
      use <- bool.guard(
        wire.string_field(canonical, "type") != Ok("reasoning")
          || wire.array_field(canonical, "summary")
          != Ok(list.map(summary, part_value))
          || result.unwrap(wire.array_field(canonical, "content"), [])
          != list.map(content, part_value),
        Error(Nil),
      )
      Ok(Nil)
    }
  }
}

fn contiguous(parts: List(Part)) -> Bool {
  list.all(
    list.index_map(parts, fn(part, index) { part.index == index }),
    fn(value) { value },
  )
}

// The response body is the final independent witness: same identity, exact
// closed output items, consistent status and no error. EOF is never this proof.
fn terminal(
  acc: Accumulator,
  event: String,
  value: JsonValue,
) -> #(Accumulator, List(StreamEvent)) {
  use response <- or_malformed(wire.field(value, "response"), acc)
  use identity <- or_malformed(identity(acc, response), acc)
  use <- bool.lazy_guard(
    acc.identity == None || wire.field(response, "error") != Error(Nil),
    fn() { malformed(acc) },
  )
  use output <- or_malformed(wire.array_field(response, "output"), acc)
  use output <- or_malformed(list.try_map(output, items.item), acc)
  let ordered = list.sort(acc.items, fn(a, b) { int.compare(a.index, b.index) })
  let expected =
    list.filter_map(ordered, fn(item) {
      case item.done {
        Some(value) -> Ok(value)
        None -> Error(Nil)
      }
    })
  use <- bool.lazy_guard(
    output != expected
      || list.length(output) != list.length(ordered)
      || !list.all(
      list.index_map(ordered, fn(item, index) { item.index == index }),
      fn(value) { value },
    ),
    fn() { malformed(acc) },
  )
  use status <- or_malformed(wire.string_field(response, "status"), acc)
  use <- bool.lazy_guard(
    status == "completed"
      && list.any(output, fn(item) {
      wire.string_field(item, "status") == Ok("incomplete")
    }),
    fn() { malformed(acc) },
  )
  let has_calls =
    list.any(ordered, fn(item) {
      case item.kind {
        Function(..) -> True
        _ -> False
      }
    })
  let refusal =
    list.any(ordered, fn(item) {
      list.any(item.parts, fn(part) { part.kind == Refusal })
    })
  let stop = case event, status {
    "response.completed", "completed" ->
      Ok(#(
        case has_calls {
          True -> message.ToolUse
          False -> message.Stop
        },
        "completed",
        None,
      ))
    "response.cancelled", "cancelled" ->
      Ok(#(message.Aborted, "cancelled", None))
    "response.incomplete", "incomplete" -> incomplete(response)
    _, _ -> Error("invalid_status")
  }
  case stop {
    Error("invalid_status") -> malformed(acc)
    Error(_reason) ->
      fail(
        acc,
        stream.UnmappedStopReason("Responses incomplete reason is unsupported"),
      )
    Ok(#(stop, raw, error)) -> {
      let #(stop, raw, error) = case refusal {
        True -> #(
          message.Errored,
          "refusal",
          Some("Responses provider refused the request"),
        )
        False -> #(stop, raw, error)
      }
      settle(acc, identity, output, response, stop, raw, error)
    }
  }
}

// Only the two known incomplete reasons carry defined partial-result semantics.
// Unknown provider labels are not copied into errors or interpreted as success.
fn incomplete(
  response: JsonValue,
) -> Result(#(message.StopReason, String, Option(String)), String) {
  let reason =
    response
    |> wire.field("incomplete_details")
    |> result.try(wire.string_field(_, "reason"))
    |> result.unwrap("")
  case reason {
    "max_output_tokens" -> Ok(#(message.Length, reason, None))
    "content_filter" ->
      Ok(#(message.Errored, reason, Some("Responses provider content filter")))
    _ -> Error(reason)
  }
}

// Accounting uses the shared clamped vocabulary and overflow rule. Content is
// then ordered by the delta indices already exposed to callers, while replay
// retains the provider order through compact, independently validated metadata.
fn settle(
  acc: Accumulator,
  identity: #(String, String),
  output: List(JsonValue),
  response: JsonValue,
  stop: message.StopReason,
  raw: String,
  error: Option(String),
) -> #(Accumulator, List(StreamEvent)) {
  let usage =
    usage(result.unwrap(wire.field(response, "usage"), json.Object([])))
  let prompt = usage.input + usage.cache_read + usage.cache_write
  let #(stop, error) = case
    prompt > acc.resolved.context_window && usage.output <= 64
  {
    True -> #(
      message.Errored,
      Some(retry.overflow_message(prompt, acc.resolved.context_window)),
    )
    False -> #(stop, error)
  }
  let ordered = list.sort(acc.items, fn(a, b) { int.compare(a.index, b.index) })
  let order = list.flat_map(ordered, block_order)
  let content =
    list.zip(order, items.blocks(output))
    |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
    |> list.map(fn(pair) { pair.1 })
  let diagnostics =
    json.Object([
      #(
        items.namespace,
        json.Object([
          #("output", json.Array(list.map(output, items.template))),
          #("block_order", json.Array(list.map(order, json.Int))),
        ]),
      ),
    ])

  // A reasoning item requires its original ID. Refuse a witness which cannot
  // fit the bounded metadata rather than settle history that cannot replay.
  use <- bool.lazy_guard(
    bit_array.byte_size(bit_array.from_string(json.to_string(diagnostics)))
      > 65_536,
    fn() { malformed(acc) },
  )
  let assistant =
    message.AssistantMessage(
      content:,
      api: api_name,
      provider: acc.resolved.provider,
      model: acc.resolved.model_id,
      response_model: Some(identity.1),
      response_id: Some(identity.0),
      diagnostics: Some(diagnostics),
      usage:,
      stop_reason: stop,
      deferred: None,
      error_message: error,
      raw_stop_reason: Some(raw),
      end_turn: Some(stop == message.Stop),
      timestamp: acc.now,
    )
  use settled <- or_malformed(stream.settle(assistant), acc)
  #(Accumulator(..acc, life: Terminal), [stream.Settled(settled, usage)])
}

// Wire output order and delta arrival order can differ under interleaving.
// This permutation keeps durable block indices equal to the emitted indices,
// while the compact replay template restores the provider's own item order.
fn block_order(item: Item) -> List(Int) {
  let parts = list.sort(item.parts, fn(a, b) { int.compare(a.index, b.index) })
  case item.kind {
    Function(block:, ..) -> [block]
    Message -> list.map(parts, fn(part) { part.block })
    Thought ->
      case parts, item.empty_block {
        [], Some(block) -> [block]
        _, _ ->
          list.append(
            list.filter(parts, fn(part) { part.kind == Summary }),
            list.filter(parts, fn(part) { part.kind == Reasoning }),
          )
          |> list.map(fn(part) { part.block })
      }
  }
}

// Reported input includes cache reads and writes. Clamp before subtracting so
// the split conserves the whole prompt even when a proxy reports impossible counts.
fn usage(value: JsonValue) -> message.Usage {
  let prompt = wire.count_field_or(value, "input_tokens", 0)
  let output = wire.count_field_or(value, "output_tokens", 0)
  let input_details =
    result.unwrap(wire.field(value, "input_tokens_details"), json.Null)
  let output_details =
    result.unwrap(wire.field(value, "output_tokens_details"), json.Null)
  let cache_read =
    int.min(prompt, wire.count_field_or(input_details, "cached_tokens", 0))
  let cache_write =
    int.min(
      prompt - cache_read,
      wire.count_field_or(input_details, "cache_write_tokens", 0),
    )
  message.Usage(
    input: prompt - cache_read - cache_write,
    output:,
    cache_read:,
    cache_write:,
    cache_write_1h: None,
    reasoning: wire.optional_count_field(output_details, "reasoning_tokens"),
    total_tokens: wire.count_field_or(value, "total_tokens", prompt + output),
    cost: message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0),
  )
}
