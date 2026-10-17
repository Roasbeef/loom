//// qcheck generators for every durable core type: the JSON and msgpack value
//// trees, the typed ids, and the message, entry and usage-row records the
//// codec round-trips.
////
//// Each generator carries its own shrink tree, so a failing roundtrip is
//// reported as the smallest value that still fails rather than as a seed.
//// What shrinks toward what is chosen deliberately. A variant is drawn as an
//// index with the plainest constructor at zero, and a recursive value is
//// drawn by `bind` on that index, so a failing document collapses toward
//// `Null` or an empty container before its leaves are touched. Numbers
//// shrink toward zero, strings toward the empty string and then the
//// first palette character, and optional fields toward `None`.
////
//// Nothing here is random on its own: a property supplies the seed, so the
//// gate stays deterministic.

import core/clock
import core/entry
import core/ids.{type EntryId, type OpId, type SessionId, type UsageId}
import core/json.{type JsonValue}
import core/message.{
  type AgentMessage, type AssistantBlock, type ToolResultBlock, type Usage,
  type UserBlock,
}
import core/msgpack.{type MsgPackValue}
import core/usage_evidence
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import qcheck.{type Generator}

// --- scalars -------------------------------------------------------------

// Deliberately unicode-heavy: ascii, escapes, accents, combining marks,
// CJK, and astral-plane emoji all appear in generated strings. The plain
// ascii letter comes first, because shrinking moves toward index zero.
const palette = [
  "a", "Z", "0", "_", " ", "\"", "\\", "/", "\n", "\t", "\u{0001}", "é", "ß",
  "Ħ", "Ж", "š", "\u{0301}", "€", "こ", "漢", "中", "🌀", "😀", "🦊", "𝄞",
]

/// A short string mixing ascii, escapes, and multi-byte codepoints, up to
/// twelve characters. Shrinks toward the empty string.
pub fn small_string() -> Generator(String) {
  let character =
    qcheck.bounded_int(from: 0, to: list.length(palette) - 1)
    |> qcheck.map(fn(index) {
      case list.drop(palette, index) {
        [chosen, ..] -> chosen
        [] -> "a"
      }
    })
  qcheck.generic_list(
    elements_from: character,
    length_from: qcheck.bounded_int(from: 0, to: 12),
  )
  |> qcheck.map(string.concat)
}

// The scales a float's integer mantissa is multiplied by: unit first, then
// a spread of magnitudes either side of it.
const float_scales = [1.0, 0.001, 1000.0, 0.0000001, 1.0e12]

/// A finite float across many magnitudes. Shrinks toward zero.
pub fn float_value() -> Generator(Float) {
  let scale =
    qcheck.bounded_int(from: 0, to: list.length(float_scales) - 1)
    |> qcheck.map(fn(index) {
      case list.drop(float_scales, index) {
        [chosen, ..] -> chosen
        [] -> 1.0
      }
    })
  qcheck.map2(
    qcheck.bounded_int(from: -1_000_000_000, to: 1_000_000_000),
    scale,
    fn(mantissa, scale) { int.to_float(mantissa) *. scale },
  )
}

/// A non-negative token count up to two million.
pub fn token_count() -> Generator(Int) {
  qcheck.bounded_int(from: 0, to: 2_000_000)
}

/// A Unix-ms timestamp within the 48-bit uuid range.
pub fn timestamp() -> Generator(Int) {
  qcheck.bounded_int(from: 0, to: 0xFFFFFFFFFFFF)
}

/// A byte string of up to `max_length` bytes. Shrinks toward fewer bytes.
pub fn byte_array(max_length max_length: Int) -> Generator(BitArray) {
  qcheck.generic_list(
    elements_from: qcheck.bounded_int(from: 0, to: 255),
    length_from: qcheck.bounded_int(from: 0, to: max_length),
  )
  |> qcheck.map(fn(bytes) {
    list.fold(bytes, from: <<>>, with: fn(accumulator, byte) {
      bit_array.append(accumulator, <<byte:size(8)>>)
    })
  })
}

// --- ids -----------------------------------------------------------------

// An id is minted from a generator whose clock is fixed at a drawn
// timestamp and whose state is a drawn seed, which is the same shape the
// production generator takes, so a shrunk id is one with a small time prefix
// and a small seed.
fn minted(mint: fn(ids.Generator) -> #(id, ids.Generator)) -> Generator(id) {
  qcheck.map2(
    timestamp(),
    qcheck.bounded_int(from: 0, to: 0xFFFFFFFFFFFFFFFF),
    fn(ts, id_seed) {
      let #(id, _generator) =
        mint(ids.generator(clock.fixed(at: ts), seed: id_seed))
      id
    },
  )
}

/// A minted `EntryId`.
pub fn entry_id() -> Generator(EntryId) {
  minted(ids.mint_entry)
}

/// A minted `UsageId`.
pub fn usage_id() -> Generator(UsageId) {
  minted(ids.mint_usage)
}

/// A minted `OpId`.
pub fn op_id() -> Generator(OpId) {
  minted(ids.mint_op)
}

/// A minted `SessionId`.
pub fn session_id() -> Generator(SessionId) {
  minted(ids.mint_session)
}

// --- json ----------------------------------------------------------------

/// An arbitrary `JsonValue` with nesting bounded by `depth`. The kind is
/// drawn first, so a failing document shrinks toward `Null`, then the other
/// scalars, then empty containers, before any leaf is simplified.
pub fn json_value(depth: Int) -> Generator(JsonValue) {
  let kinds = case depth <= 0 {
    True -> 4
    False -> 6
  }
  use kind <- qcheck.bind(qcheck.bounded_int(from: 0, to: kinds))
  case kind {
    0 -> qcheck.return(json.Null)
    1 -> qcheck.map(qcheck.bool(), json.Bool)
    2 ->
      qcheck.map(
        qcheck.bounded_int(
          from: -9_007_199_254_740_991,
          to: 9_007_199_254_740_991,
        ),
        json.Int,
      )
    3 -> qcheck.map(float_value(), json.Float)
    4 -> qcheck.map(small_string(), json.String)
    5 ->
      qcheck.generic_list(
        elements_from: json_value(depth - 1),
        length_from: qcheck.bounded_int(from: 0, to: 4),
      )
      |> qcheck.map(json.Array)
    _ ->
      qcheck.generic_list(
        elements_from: qcheck.tuple2(small_string(), json_value(depth - 1)),
        length_from: qcheck.bounded_int(from: 0, to: 4),
      )
      |> qcheck.map(fn(fields) { json.Object(unique_by_key(fields)) })
  }
}

// Keeps the first entry per key: parsed documents never carry duplicate
// keys (`core/json.parse` and `core/msgpack.decode` reject them), so
// generated containers must not either, or roundtrips would fail.
fn unique_by_key(pairs: List(#(k, v))) -> List(#(k, v)) {
  unique_by_key_loop(pairs, [], [])
}

fn unique_by_key_loop(
  pairs: List(#(k, v)),
  seen: List(k),
  accumulator: List(#(k, v)),
) -> List(#(k, v)) {
  case pairs {
    [] -> list.reverse(accumulator)
    [#(key, value), ..rest] ->
      case list.contains(seen, key) {
        True -> unique_by_key_loop(rest, seen, accumulator)
        False ->
          unique_by_key_loop(rest, [key, ..seen], [#(key, value), ..accumulator])
      }
  }
}

// --- msgpack -------------------------------------------------------------

// The integers where msgpack changes its encoding width, with the small
// ones first.
const interesting_ints = [
  0, 1, -1, 31, 32, 127, 128, 255, 256, -32, -33, -128, -129, 65_535, 65_536,
  -32_768, -32_769, 4_294_967_295, 4_294_967_296, -2_147_483_648, -2_147_483_649,
  9_223_372_036_854_775_807, -9_223_372_036_854_775_808,
  18_446_744_073_709_551_615,
]

// An integer that is either one of the encoding boundaries or anywhere in
// the signed 64-bit range, an even split.
fn msgpack_int() -> Generator(Int) {
  let boundary =
    qcheck.bounded_int(from: 0, to: list.length(interesting_ints) - 1)
    |> qcheck.map(fn(index) {
      case list.drop(interesting_ints, index) {
        [chosen, ..] -> chosen
        [] -> 0
      }
    })
  let anywhere =
    qcheck.bounded_int(
      from: -9_223_372_036_854_775_808,
      to: 9_223_372_036_854_775_807,
    )
  qcheck.from_generators(boundary, [anywhere])
}

/// An arbitrary `MsgPackValue` with nesting bounded by `depth`. Map keys are
/// scalars or one-level containers, as before, and shrink like any other
/// value: toward `NilValue`.
pub fn msgpack_value(depth: Int) -> Generator(MsgPackValue) {
  let kinds = case depth <= 0 {
    True -> 5
    False -> 7
  }
  use kind <- qcheck.bind(qcheck.bounded_int(from: 0, to: kinds))
  case kind {
    0 -> qcheck.return(msgpack.NilValue)
    1 -> qcheck.map(qcheck.bool(), msgpack.BoolValue)
    2 -> qcheck.map(msgpack_int(), msgpack.IntValue)
    3 -> qcheck.map(float_value(), msgpack.FloatValue)
    4 -> qcheck.map(small_string(), msgpack.StringValue)
    5 -> qcheck.map(byte_array(max_length: 8), msgpack.BinaryValue)
    6 ->
      qcheck.generic_list(
        elements_from: msgpack_value(depth - 1),
        length_from: qcheck.bounded_int(from: 0, to: 4),
      )
      |> qcheck.map(msgpack.ArrayValue)
    _ ->
      qcheck.generic_list(
        elements_from: qcheck.tuple2(msgpack_value(0), msgpack_value(depth - 1)),
        length_from: qcheck.bounded_int(from: 0, to: 4),
      )
      |> qcheck.map(fn(entries) { msgpack.MapValue(unique_by_key(entries)) })
  }
}

// --- messages ------------------------------------------------------------

fn money() -> Generator(Float) {
  qcheck.bounded_int(from: 0, to: 100_000)
  |> qcheck.map(fn(cents) { int.to_float(cents) *. 0.0001 })
}

/// An `Option` of the generated value. Shrinks toward `None`.
pub fn option_of(generator: Generator(a)) -> Generator(Option(a)) {
  qcheck.option_from(generator)
}

/// A `Usage`. Its optional token breakdowns are clamped to the counts they
/// are parts of, since a cache-write-1h count above the cache-write total
/// is not a usage the accounting would ever record.
pub fn usage() -> Generator(Usage) {
  let counts =
    qcheck.tuple4(token_count(), token_count(), token_count(), token_count())
  let breakdowns =
    qcheck.tuple2(option_of(token_count()), option_of(token_count()))
  let costs = qcheck.tuple5(money(), money(), money(), money(), money())
  qcheck.map3(counts, breakdowns, costs, fn(counts, breakdowns, costs) {
    let #(input, output, cache_read, cache_write) = counts
    let #(cache_write_1h, reasoning) = breakdowns
    let #(cost_input, cost_output, cost_cache_read, cost_cache_write, total) =
      costs
    message.Usage(
      input:,
      output:,
      cache_read:,
      cache_write:,
      cache_write_1h: option.map(cache_write_1h, fn(count) {
        int.min(count, cache_write)
      }),
      reasoning: option.map(reasoning, fn(count) { int.min(count, output) }),
      total_tokens: input + output,
      cost: message.UsageCost(
        input: cost_input,
        output: cost_output,
        cache_read: cost_cache_read,
        cache_write: cost_cache_write,
        total:,
      ),
      evidence: usage_evidence.with_price(
        usage_evidence.reported(usage_evidence.Api),
        usage_evidence.ApiRates,
      ),
    )
  })
}

fn user_block() -> Generator(UserBlock) {
  use kind <- qcheck.bind(qcheck.bounded_int(from: 0, to: 1))
  case kind {
    0 ->
      qcheck.map2(
        small_string(),
        option_of(small_string()),
        fn(text, text_signature) { message.UserText(text:, text_signature:) },
      )
    _ ->
      qcheck.map(small_string(), fn(data) {
        message.UserImage(data:, mime_type: "image/png")
      })
  }
}

fn assistant_block() -> Generator(AssistantBlock) {
  use kind <- qcheck.bind(qcheck.bounded_int(from: 0, to: 2))
  case kind {
    0 ->
      qcheck.map2(
        small_string(),
        option_of(small_string()),
        fn(text, text_signature) {
          message.AssistantText(text:, text_signature:)
        },
      )
    1 ->
      qcheck.map3(
        small_string(),
        option_of(small_string()),
        qcheck.bool(),
        fn(thinking, thinking_signature, redacted) {
          message.AssistantThinking(thinking:, thinking_signature:, redacted:)
        },
      )
    _ ->
      qcheck.map4(
        qcheck.tuple2(small_string(), small_string()),
        json_value(2),
        option_of(small_string()),
        option_of(small_string()),
        fn(names, arguments, thought_signature, namespace) {
          let #(id, name) = names
          message.AssistantToolCall(call: message.ToolCall(
            id:,
            name:,
            arguments:,
            thought_signature:,
            namespace:,
          ))
        },
      )
  }
}

fn tool_result_block() -> Generator(ToolResultBlock) {
  use kind <- qcheck.bind(qcheck.bounded_int(from: 0, to: 1))
  case kind {
    0 ->
      qcheck.map2(
        small_string(),
        option_of(small_string()),
        fn(text, text_signature) {
          message.ToolResultText(text:, text_signature:)
        },
      )
    _ ->
      qcheck.map(small_string(), fn(data) {
        message.ToolResultImage(data:, mime_type: "image/jpeg")
      })
  }
}

// A list of zero to `max_length` elements. Shrinks toward the empty list.
fn blocks(
  block: Generator(a),
  max_length max_length: Int,
) -> Generator(List(a)) {
  qcheck.generic_list(
    elements_from: block,
    length_from: qcheck.bounded_int(from: 0, to: max_length),
  )
}

fn deferred_handle() -> Generator(message.DeferredHandle) {
  qcheck.map4(
    small_string(),
    option_of(timestamp()),
    option_of(qcheck.bounded_int(from: 0, to: 60_000)),
    option_of(json_value(1)),
    fn(id, expires_at, poll_after_ms, data) {
      message.DeferredHandle(
        provider: "anthropic",
        model_id: "test-model",
        api: "anthropic-messages",
        id:,
        expires_at:,
        poll_after_ms:,
        data:,
      )
    },
  )
}

const stop_reasons = [
  message.Stop,
  message.Length,
  message.ToolUse,
  message.Errored,
  message.Aborted,
  message.Deferred,
  message.Pending,
]

fn user_message() -> Generator(AgentMessage) {
  qcheck.map3(
    blocks(user_block(), max_length: 3),
    timestamp(),
    qcheck.bounded_int(from: 0, to: 1),
    fn(content, ts, attributed) {
      let origin = case attributed {
        0 -> None
        _ -> Some(message.Origin("historical-author", "Name at admission"))
      }
      message.UserMessage(content:, timestamp: ts, origin:)
    },
  )
}

fn assistant_message() -> Generator(AgentMessage) {
  let stop_reason =
    qcheck.bounded_int(from: 0, to: list.length(stop_reasons) - 1)
    |> qcheck.map(fn(index) {
      case list.drop(stop_reasons, index) {
        [chosen, ..] -> chosen
        [] -> message.Stop
      }
    })
  let strings =
    qcheck.tuple4(
      option_of(small_string()),
      option_of(small_string()),
      option_of(small_string()),
      option_of(small_string()),
    )
  let structured =
    qcheck.tuple3(
      option_of(json_value(1)),
      option_of(deferred_handle()),
      option_of(qcheck.bool()),
    )
  qcheck.map5(
    qcheck.tuple2(blocks(assistant_block(), max_length: 3), usage()),
    stop_reason,
    strings,
    structured,
    timestamp(),
    fn(body, stop_reason, strings, structured, ts) {
      let #(content, usage) = body
      let #(response_model, response_id, error_message, raw_stop_reason) =
        strings
      let #(diagnostics, deferred, end_turn) = structured
      message.AssistantMessage(
        content:,
        api: "anthropic-messages",
        provider: "anthropic",
        model: "test-model",
        response_model:,
        response_id:,
        diagnostics:,
        usage:,
        stop_reason:,
        deferred:,
        error_message:,
        raw_stop_reason:,
        end_turn:,
        timestamp: ts,
      )
    },
  )
}

fn tool_result_message() -> Generator(AgentMessage) {
  let head = qcheck.tuple2(small_string(), small_string())
  let body =
    qcheck.tuple3(
      blocks(tool_result_block(), max_length: 3),
      option_of(json_value(2)),
      option_of(usage()),
    )
  let tail =
    qcheck.tuple3(
      option_of(blocks(small_string(), max_length: 3)),
      qcheck.bool(),
      timestamp(),
    )
  qcheck.map3(head, body, tail, fn(head, body, tail) {
    let #(tool_call_id, tool_name) = head
    let #(content, details, usage) = body
    let #(added_tool_names, is_error, ts) = tail
    message.ToolResultMessage(
      tool_call_id:,
      tool_name:,
      content:,
      details:,
      usage:,
      added_tool_names:,
      is_error:,
      timestamp: ts,
    )
  })
}

/// An `AgentMessage` of any role, shrinking toward a user message with no
/// content blocks.
pub fn agent_message() -> Generator(AgentMessage) {
  use role <- qcheck.bind(qcheck.bounded_int(from: 0, to: 3))
  case role {
    0 -> user_message()
    1 -> assistant_message()
    2 -> tool_result_message()
    _ ->
      qcheck.map2(small_string(), json_value(2), fn(schema, payload) {
        message.CustomMessage(schema:, payload:)
      })
  }
}

// --- entries and usage rows ----------------------------------------------

/// An `Entry` of any variant, shrinking toward a message entry with no
/// parent and sequence zero.
pub fn entry() -> Generator(entry.Entry) {
  let header =
    qcheck.tuple4(
      entry_id(),
      option_of(entry_id()),
      qcheck.bounded_int(from: 0, to: 1_000_000),
      timestamp(),
    )
  use #(id, parent, seq, ts) <- qcheck.bind(header)
  use kind <- qcheck.bind(qcheck.bounded_int(from: 0, to: 3))
  case kind {
    0 ->
      qcheck.map2(agent_message(), qcheck.bool(), fn(message_value, terminate) {
        entry.MessageEntry(
          id:,
          parent:,
          seq:,
          ts:,
          message: message_value,
          terminate:,
        )
      })
    1 ->
      qcheck.map5(
        small_string(),
        blocks(agent_message(), max_length: 2),
        token_count(),
        qcheck.bool(),
        option_of(usage()),
        fn(summary, retained_tail, tokens_before, from_hook, usage_value) {
          entry.CompactionEntry(
            id:,
            parent:,
            seq:,
            ts:,
            summary:,
            retained_tail:,
            tokens_before:,
            from_hook:,
            usage: usage_value,
          )
        },
      )
    2 ->
      qcheck.map4(
        option_of(entry_id()),
        small_string(),
        qcheck.bool(),
        option_of(usage()),
        fn(from_id, summary, from_hook, usage_value) {
          entry.BranchSummaryEntry(
            id:,
            parent:,
            seq:,
            ts:,
            from_id:,
            summary:,
            from_hook:,
            usage: usage_value,
          )
        },
      )
    _ ->
      qcheck.map2(
        small_string(),
        option_of(json_value(2)),
        fn(custom_type, data) {
          entry.CustomEntry(id:, parent:, seq:, ts:, custom_type:, data:)
        },
      )
  }
}

/// A `UsageRow`.
pub fn usage_row() -> Generator(entry.UsageRow) {
  let head =
    qcheck.tuple3(
      usage_id(),
      qcheck.bounded_int(from: 0, to: 1_000_000),
      option_of(entry_id()),
    )
  qcheck.map4(
    head,
    qcheck.bool(),
    usage(),
    option_of(json_value(2)),
    fn(head, adjustment, usage_value, details) {
      let #(id, seq, row_entry_id) = head
      entry.UsageRow(
        id:,
        seq:,
        entry_id: row_entry_id,
        adjustment:,
        usage: usage_value,
        details:,
      )
    },
  )
}
