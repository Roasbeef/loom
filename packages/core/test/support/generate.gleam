//// Deterministic pseudo-random value generation for property-style tests.
////
//// A tiny seeded SplitMix64 generator plus generators for every durable
//// core type. Everything is a pure function of the threaded `Seed`, so a
//// failing property reproduces from its seed alone.

import core/clock
import core/entry
import core/ids.{type EntryId, type OpId, type SessionId, type UsageId}
import core/json.{type JsonValue}
import core/message.{
  type AgentMessage, type AssistantBlock, type ToolResultBlock, type Usage,
  type UserBlock,
}
import core/msgpack.{type MsgPackValue}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// Pseudo-random generator state.
pub type Seed {
  Seed(state: Int)
}

const mask_64 = 0xFFFFFFFFFFFFFFFF

/// Builds a seed from any integer.
pub fn seed(n: Int) -> Seed {
  Seed(state: int.bitwise_and(n, mask_64))
}

/// Draws the next 64-bit value.
pub fn next(seed: Seed) -> #(Int, Seed) {
  let state = int.bitwise_and(seed.state + 0x9E3779B97F4A7C15, mask_64)
  let z = state
  let z =
    int.bitwise_and(
      int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 30))
        * 0xBF58476D1CE4E5B9,
      mask_64,
    )
  let z =
    int.bitwise_and(
      int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 27))
        * 0x94D049BB133111EB,
      mask_64,
    )
  let z = int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 31))
  #(z, Seed(state:))
}

/// An inclusive integer range as a list. Requires `start <= stop`.
pub fn range(from start: Int, to stop: Int) -> List(Int) {
  int.range(from: start, to: stop + 1, with: [], run: fn(acc, n) { [n, ..acc] })
  |> list.reverse
}

/// Draws an integer in `[min, max]`, both inclusive.
pub fn int_between(seed: Seed, min: Int, max: Int) -> #(Int, Seed) {
  let #(raw, seed) = next(seed)
  #(min + raw % { max - min + 1 }, seed)
}

/// Draws a boolean.
pub fn bool(seed: Seed) -> #(Bool, Seed) {
  let #(n, seed) = int_between(seed, 0, 1)
  #(n == 1, seed)
}

/// Draws `Some` of the generated value half the time.
pub fn option_of(
  seed: Seed,
  generate: fn(Seed) -> #(a, Seed),
) -> #(Option(a), Seed) {
  let #(present, seed) = bool(seed)
  case present {
    True -> {
      let #(value, seed) = generate(seed)
      #(Some(value), seed)
    }
    False -> #(None, seed)
  }
}

/// Draws a list of `count` generated values.
pub fn list_of(
  seed: Seed,
  count: Int,
  generate: fn(Seed) -> #(a, Seed),
) -> #(List(a), Seed) {
  list_of_loop(seed, count, generate, [])
}

fn list_of_loop(
  seed: Seed,
  remaining: Int,
  generate: fn(Seed) -> #(a, Seed),
  accumulator: List(a),
) -> #(List(a), Seed) {
  case remaining <= 0 {
    True -> #(list.reverse(accumulator), seed)
    False -> {
      let #(value, seed) = generate(seed)
      list_of_loop(seed, remaining - 1, generate, [value, ..accumulator])
    }
  }
}

/// Picks one element of a non-empty list; the first is the fallback.
pub fn one_of(seed: Seed, choices: List(a), fallback: a) -> #(a, Seed) {
  let #(index, seed) = int_between(seed, 0, list.length(choices) - 1)
  case list.drop(choices, index) {
    [chosen, ..] -> #(chosen, seed)
    [] -> #(fallback, seed)
  }
}

// Deliberately unicode-heavy: ascii, escapes, accents, combining marks,
// CJK, and astral-plane emoji all appear in generated strings.
const palette = [
  "a", "Z", "0", "_", " ", "\"", "\\", "/", "\n", "\t", "\u{0001}", "é", "ß",
  "Ħ", "Ж", "š", "\u{0301}", "€", "こ", "漢", "中", "🌀", "😀", "🦊", "𝄞",
]

/// Draws a short string mixing ascii, escapes, and multi-byte codepoints.
pub fn small_string(seed: Seed) -> #(String, Seed) {
  let #(length, seed) = int_between(seed, 0, 12)
  let #(chunks, seed) =
    list_of(seed, length, fn(seed) { one_of(seed, palette, "a") })
  #(string.concat(chunks), seed)
}

/// Draws a finite float across many magnitudes.
pub fn float(seed: Seed) -> #(Float, Seed) {
  let #(mantissa, seed) = int_between(seed, -1_000_000_000, 1_000_000_000)
  let #(scale, seed) =
    one_of(seed, [1.0, 0.001, 1000.0, 0.0000001, 1.0e12], 1.0)
  #(int.to_float(mantissa) *. scale, seed)
}

/// Draws a small non-negative token count.
pub fn token_count(seed: Seed) -> #(Int, Seed) {
  int_between(seed, 0, 2_000_000)
}

/// Draws a Unix-ms timestamp within the 48-bit uuid range.
pub fn timestamp(seed: Seed) -> #(Int, Seed) {
  int_between(seed, 0, 0xFFFFFFFFFFFF)
}

// --- ids ----------------------------------------------------------------

/// Mints a random `EntryId` from the seed.
pub fn entry_id(seed: Seed) -> #(EntryId, Seed) {
  let #(ts, seed) = timestamp(seed)
  let #(id_seed, seed) = next(seed)
  let #(id, _generator) =
    ids.mint_entry(ids.generator(clock.fixed(at: ts), seed: id_seed))
  #(id, seed)
}

/// Mints a random `UsageId` from the seed.
pub fn usage_id(seed: Seed) -> #(UsageId, Seed) {
  let #(ts, seed) = timestamp(seed)
  let #(id_seed, seed) = next(seed)
  let #(id, _generator) =
    ids.mint_usage(ids.generator(clock.fixed(at: ts), seed: id_seed))
  #(id, seed)
}

/// Mints a random `OpId` from the seed.
pub fn op_id(seed: Seed) -> #(OpId, Seed) {
  let #(ts, seed) = timestamp(seed)
  let #(id_seed, seed) = next(seed)
  let #(id, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: ts), seed: id_seed))
  #(id, seed)
}

/// Mints a random `SessionId` from the seed.
pub fn session_id(seed: Seed) -> #(SessionId, Seed) {
  let #(ts, seed) = timestamp(seed)
  let #(id_seed, seed) = next(seed)
  let #(id, _generator) =
    ids.mint_session(ids.generator(clock.fixed(at: ts), seed: id_seed))
  #(id, seed)
}

// --- json ---------------------------------------------------------------

/// Draws an arbitrary `JsonValue` with nesting bounded by `depth`.
pub fn json_value(seed: Seed, depth: Int) -> #(JsonValue, Seed) {
  let #(kind, seed) = case depth <= 0 {
    True -> int_between(seed, 0, 4)
    False -> int_between(seed, 0, 6)
  }
  case kind {
    0 -> #(json.Null, seed)
    1 -> {
      let #(flag, seed) = bool(seed)
      #(json.Bool(flag), seed)
    }
    2 -> {
      let #(value, seed) =
        int_between(seed, -9_007_199_254_740_991, 9_007_199_254_740_991)
      #(json.Int(value), seed)
    }
    3 -> {
      let #(value, seed) = float(seed)
      #(json.Float(value), seed)
    }
    4 -> {
      let #(value, seed) = small_string(seed)
      #(json.String(value), seed)
    }
    5 -> {
      let #(length, seed) = int_between(seed, 0, 4)
      let #(items, seed) =
        list_of(seed, length, fn(seed) { json_value(seed, depth - 1) })
      #(json.Array(items), seed)
    }
    _ -> {
      let #(length, seed) = int_between(seed, 0, 4)
      let #(fields, seed) =
        list_of(seed, length, fn(seed) {
          let #(name, seed) = small_string(seed)
          let #(value, seed) = json_value(seed, depth - 1)
          #(#(name, value), seed)
        })
      #(json.Object(unique_by_key(fields)), seed)
    }
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

// --- msgpack ------------------------------------------------------------

const interesting_ints = [
  0, 1, -1, 31, 32, 127, 128, 255, 256, -32, -33, -128, -129, 65_535, 65_536,
  -32_768, -32_769, 4_294_967_295, 4_294_967_296, -2_147_483_648, -2_147_483_649,
  9_223_372_036_854_775_807, -9_223_372_036_854_775_808,
  18_446_744_073_709_551_615,
]

/// Draws an arbitrary `MsgPackValue` with nesting bounded by `depth`.
pub fn msgpack_value(seed: Seed, depth: Int) -> #(MsgPackValue, Seed) {
  let #(kind, seed) = case depth <= 0 {
    True -> int_between(seed, 0, 5)
    False -> int_between(seed, 0, 7)
  }
  case kind {
    0 -> #(msgpack.NilValue, seed)
    1 -> {
      let #(flag, seed) = bool(seed)
      #(msgpack.BoolValue(flag), seed)
    }
    2 -> {
      let #(boundary, seed) = bool(seed)
      let #(value, seed) = case boundary {
        True -> one_of(seed, interesting_ints, 0)
        False ->
          int_between(
            seed,
            -9_223_372_036_854_775_808,
            9_223_372_036_854_775_807,
          )
      }
      #(msgpack.IntValue(value), seed)
    }
    3 -> {
      let #(value, seed) = float(seed)
      #(msgpack.FloatValue(value), seed)
    }
    4 -> {
      let #(value, seed) = small_string(seed)
      #(msgpack.StringValue(value), seed)
    }
    5 -> {
      let #(length, seed) = int_between(seed, 0, 8)
      let #(bytes, seed) = byte_array(seed, length)
      #(msgpack.BinaryValue(bytes), seed)
    }
    6 -> {
      let #(length, seed) = int_between(seed, 0, 4)
      let #(items, seed) =
        list_of(seed, length, fn(seed) { msgpack_value(seed, depth - 1) })
      #(msgpack.ArrayValue(items), seed)
    }
    _ -> {
      let #(length, seed) = int_between(seed, 0, 4)
      let #(entries, seed) =
        list_of(seed, length, fn(seed) {
          let #(key, seed) = msgpack_value(seed, 0)
          let #(value, seed) = msgpack_value(seed, depth - 1)
          #(#(key, value), seed)
        })
      #(msgpack.MapValue(unique_by_key(entries)), seed)
    }
  }
}

/// Draws `count` random bytes.
pub fn byte_array(seed: Seed, count: Int) -> #(BitArray, Seed) {
  let #(bytes, seed) =
    list_of(seed, count, fn(seed) { int_between(seed, 0, 255) })
  let bits =
    list.fold(bytes, from: <<>>, with: fn(accumulator, byte) {
      bit_array.append(accumulator, <<byte:size(8)>>)
    })
  #(bits, seed)
}

// --- messages -----------------------------------------------------------

/// Draws a random `Usage`.
pub fn usage(seed: Seed) -> #(Usage, Seed) {
  let #(input, seed) = token_count(seed)
  let #(output, seed) = token_count(seed)
  let #(cache_read, seed) = token_count(seed)
  let #(cache_write, seed) = token_count(seed)
  let #(cache_write_1h, seed) = option_of(seed, token_count)
  let #(reasoning, seed) = option_of(seed, token_count)
  let #(cost_input, seed) = money(seed)
  let #(cost_output, seed) = money(seed)
  let #(cost_cache_read, seed) = money(seed)
  let #(cost_cache_write, seed) = money(seed)
  let #(cost_total, seed) = money(seed)
  #(
    message.Usage(
      input:,
      output:,
      cache_read:,
      cache_write:,
      cache_write_1h:,
      reasoning:,
      total_tokens: input + output,
      cost: message.UsageCost(
        input: cost_input,
        output: cost_output,
        cache_read: cost_cache_read,
        cache_write: cost_cache_write,
        total: cost_total,
      ),
    ),
    seed,
  )
}

fn money(seed: Seed) -> #(Float, Seed) {
  let #(cents, seed) = int_between(seed, 0, 100_000)
  #(int.to_float(cents) *. 0.0001, seed)
}

fn user_block(seed: Seed) -> #(UserBlock, Seed) {
  let #(image, seed) = bool(seed)
  case image {
    True -> {
      let #(data, seed) = small_string(seed)
      #(message.UserImage(data:, mime_type: "image/png"), seed)
    }
    False -> {
      let #(text, seed) = small_string(seed)
      let #(text_signature, seed) = option_of(seed, small_string)
      #(message.UserText(text:, text_signature:), seed)
    }
  }
}

fn assistant_block(seed: Seed) -> #(AssistantBlock, Seed) {
  let #(kind, seed) = int_between(seed, 0, 2)
  case kind {
    0 -> {
      let #(text, seed) = small_string(seed)
      let #(text_signature, seed) = option_of(seed, small_string)
      #(message.AssistantText(text:, text_signature:), seed)
    }
    1 -> {
      let #(thinking, seed) = small_string(seed)
      let #(thinking_signature, seed) = option_of(seed, small_string)
      let #(redacted, seed) = bool(seed)
      #(
        message.AssistantThinking(thinking:, thinking_signature:, redacted:),
        seed,
      )
    }
    _ -> {
      let #(id, seed) = small_string(seed)
      let #(name, seed) = small_string(seed)
      let #(arguments, seed) = json_value(seed, 2)
      let #(thought_signature, seed) = option_of(seed, small_string)
      let #(namespace, seed) = option_of(seed, small_string)
      #(
        message.AssistantToolCall(call: message.ToolCall(
          id:,
          name:,
          arguments:,
          thought_signature:,
          namespace:,
        )),
        seed,
      )
    }
  }
}

fn tool_result_block(seed: Seed) -> #(ToolResultBlock, Seed) {
  let #(image, seed) = bool(seed)
  case image {
    True -> {
      let #(data, seed) = small_string(seed)
      #(message.ToolResultImage(data:, mime_type: "image/jpeg"), seed)
    }
    False -> {
      let #(text, seed) = small_string(seed)
      let #(text_signature, seed) = option_of(seed, small_string)
      #(message.ToolResultText(text:, text_signature:), seed)
    }
  }
}

/// Draws a random `AgentMessage` of any role.
pub fn agent_message(seed: Seed) -> #(AgentMessage, Seed) {
  let #(role, seed) = int_between(seed, 0, 3)
  case role {
    0 -> {
      let #(length, seed) = int_between(seed, 0, 3)
      let #(content, seed) = list_of(seed, length, user_block)
      let #(ts, seed) = timestamp(seed)
      #(message.UserMessage(content:, timestamp: ts), seed)
    }
    1 -> {
      let #(length, seed) = int_between(seed, 0, 3)
      let #(content, seed) = list_of(seed, length, assistant_block)
      let #(usage_value, seed) = usage(seed)
      let #(stop_reason, seed) =
        one_of(
          seed,
          [
            message.Stop,
            message.Length,
            message.ToolUse,
            message.Errored,
            message.Aborted,
            message.Deferred,
            message.Pending,
          ],
          message.Stop,
        )
      let #(response_model, seed) = option_of(seed, small_string)
      let #(response_id, seed) = option_of(seed, small_string)
      let #(diagnostics, seed) =
        option_of(seed, fn(seed) { json_value(seed, 1) })
      let #(deferred, seed) = option_of(seed, deferred_handle)
      let #(error_message, seed) = option_of(seed, small_string)
      let #(raw_stop_reason, seed) = option_of(seed, small_string)
      let #(end_turn, seed) = option_of(seed, bool)
      let #(ts, seed) = timestamp(seed)
      #(
        message.AssistantMessage(
          content:,
          api: "anthropic-messages",
          provider: "anthropic",
          model: "test-model",
          response_model:,
          response_id:,
          diagnostics:,
          usage: usage_value,
          stop_reason:,
          deferred:,
          error_message:,
          raw_stop_reason:,
          end_turn:,
          timestamp: ts,
        ),
        seed,
      )
    }
    2 -> {
      let #(tool_call_id, seed) = small_string(seed)
      let #(tool_name, seed) = small_string(seed)
      let #(length, seed) = int_between(seed, 0, 3)
      let #(content, seed) = list_of(seed, length, tool_result_block)
      let #(details, seed) = option_of(seed, fn(seed) { json_value(seed, 2) })
      let #(usage_value, seed) = option_of(seed, usage)
      let #(added_tool_names, seed) =
        option_of(seed, fn(seed) {
          let #(length, seed) = int_between(seed, 0, 3)
          list_of(seed, length, small_string)
        })
      let #(is_error, seed) = bool(seed)
      let #(ts, seed) = timestamp(seed)
      #(
        message.ToolResultMessage(
          tool_call_id:,
          tool_name:,
          content:,
          details:,
          usage: usage_value,
          added_tool_names:,
          is_error:,
          timestamp: ts,
        ),
        seed,
      )
    }
    _ -> {
      let #(schema, seed) = small_string(seed)
      let #(payload, seed) = json_value(seed, 2)
      #(message.CustomMessage(schema:, payload:), seed)
    }
  }
}

// --- entries and usage rows ---------------------------------------------

/// Draws a random `Entry` of any variant.
pub fn entry(seed: Seed) -> #(entry.Entry, Seed) {
  let #(id, seed) = entry_id(seed)
  let #(parent, seed) = option_of(seed, entry_id)
  let #(seq, seed) = int_between(seed, 0, 1_000_000)
  let #(ts, seed) = timestamp(seed)
  let #(kind, seed) = int_between(seed, 0, 3)
  case kind {
    0 -> {
      let #(message_value, seed) = agent_message(seed)
      let #(terminate, seed) = bool(seed)
      #(
        entry.MessageEntry(
          id:,
          parent:,
          seq:,
          ts:,
          message: message_value,
          terminate:,
        ),
        seed,
      )
    }
    1 -> {
      let #(summary, seed) = small_string(seed)
      let #(length, seed) = int_between(seed, 0, 2)
      let #(retained_tail, seed) = list_of(seed, length, agent_message)
      let #(tokens_before, seed) = token_count(seed)
      let #(from_hook, seed) = bool(seed)
      let #(usage_value, seed) = option_of(seed, usage)
      #(
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
        ),
        seed,
      )
    }
    2 -> {
      let #(from_id, seed) = option_of(seed, entry_id)
      let #(summary, seed) = small_string(seed)
      let #(from_hook, seed) = bool(seed)
      let #(usage_value, seed) = option_of(seed, usage)
      #(
        entry.BranchSummaryEntry(
          id:,
          parent:,
          seq:,
          ts:,
          from_id:,
          summary:,
          from_hook:,
          usage: usage_value,
        ),
        seed,
      )
    }
    _ -> {
      let #(custom_type, seed) = small_string(seed)
      let #(data, seed) = option_of(seed, fn(seed) { json_value(seed, 2) })
      #(entry.CustomEntry(id:, parent:, seq:, ts:, custom_type:, data:), seed)
    }
  }
}

/// Draws a random `UsageRow`.
pub fn usage_row(seed: Seed) -> #(entry.UsageRow, Seed) {
  let #(id, seed) = usage_id(seed)
  let #(seq, seed) = int_between(seed, 0, 1_000_000)
  let #(row_entry_id, seed) = option_of(seed, entry_id)
  let #(adjustment, seed) = bool(seed)
  let #(usage_value, seed) = usage(seed)
  let #(details, seed) = option_of(seed, fn(seed) { json_value(seed, 2) })
  #(
    entry.UsageRow(
      id:,
      seq:,
      entry_id: row_entry_id,
      adjustment:,
      usage: usage_value,
      details:,
    ),
    seed,
  )
}

fn deferred_handle(seed: Seed) -> #(message.DeferredHandle, Seed) {
  let #(id, seed) = small_string(seed)
  let #(expires_at, seed) = option_of(seed, timestamp)
  let #(poll_after_ms, seed) =
    option_of(seed, fn(seed) { int_between(seed, 0, 60_000) })
  let #(data, seed) = option_of(seed, fn(seed) { json_value(seed, 1) })
  #(
    message.DeferredHandle(
      provider: "anthropic",
      model_id: "test-model",
      api: "anthropic-messages",
      id:,
      expires_at:,
      poll_after_ms:,
      data:,
    ),
    seed,
  )
}
