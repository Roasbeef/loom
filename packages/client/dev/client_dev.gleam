//// Repeatable benchmarks for the server's per-step hot paths, run against a
//// real session store (issue #359).
////
//// A strand driver's step reads the strand's whole branch from the store
//// and decodes every entry, projects it to messages, walks that projection
//// for the compaction threshold and again for the reminder, and encodes the
//// whole context to JSON for the provider request. Each of those is O(the
//// conversation so far) per step, and the issue's native stack sample was
//// dominated by binary building from lists and UTF-8 and by the heap sweeps
//// that follow. This module times each of them in isolation over a copied
//// store, so a change to any one can be measured rather than argued.
////
//// It stays in `dev/` so neither its runner nor `gleamy_bench` enters the
//// shipped client. Run it with `make bench-server DB=<copy of a session db>`;
//// the store is opened for writing because the session layer takes a writer
//// lease, so point it at a copy, never at a live daemon's file.

import argv
import core/clock
import core/entry.{type Entry}
import core/ids.{type EntryId}
import core/message.{type AgentMessage}
import gleam/bit_array
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleamy/bench
import provider/adapter/anthropic
import provider/adapter/openai
import provider/http
import provider/model
import runtime/hooks
import session/session.{type Session}
import storage/storage

/// A session store opened for the benchmark, with the primary strand's leaf
/// and the projection every step starts from.
pub type Rig {
  Rig(session: Session, leaf: EntryId, projected: hooks.Projected)
}

/// Runs the benchmark table over the store named on the command line.
pub fn main() {
  case argv.load().arguments {
    [path, ..] -> run(path)
    [] -> io.println("usage: gleam dev -- <path to a copied session .db>")
  }
}

/// Opens the store and reads what every step starts from.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(rig) = client_dev.open("/tmp/copy.db")
/// ```
pub fn open(path: String) -> Result(Rig, String) {
  let clock = clock.fixed(at: 1_757_700_000_000)
  case
    session.open_sqlite(path:, owner: "bench", lease_ttl_ms: 600_000, clock:)
  {
    Error(error) -> Error("open failed: " <> string.inspect(error))
    Ok(opened) ->
      case session.strand_leaf(opened, "main") {
        Ok(Some(session.Cell(value: Some(leaf), ..))) ->
          Ok(Rig(session: opened, leaf:, projected: project(opened)))
        other -> Error("no main leaf: " <> string.inspect(other))
      }
  }
}

fn scan(rig: Rig) -> List(Entry) {
  storage.branch_scan(from: rig.leaf)
  |> storage.branch_stop_at_kind(storage.Compaction)
  |> storage.scan_branch(rig.session.store, _)
  |> result_or_empty
}

fn result_or_empty(scanned: Result(List(Entry), e)) -> List(Entry) {
  case scanned {
    Ok(entries) -> entries
    Error(_) -> []
  }
}

fn project(opened: Session) -> hooks.Projected {
  hooks.project(opened, "main")
}

fn estimate(rig: Rig) -> Int {
  hooks.context_tokens(rig.projected, hooks.estimate_message)
}

// The O(1) estimate the issue proposes: bytes over four, no grapheme walk
// and no JSON rendering.
fn estimate_bytes(rig: Rig) -> Int {
  hooks.context_tokens(rig.projected, fn(message) { message_bytes(message) / 4 })
}

fn message_bytes(message: AgentMessage) -> Int {
  case message {
    message.UserMessage(content:, ..) ->
      list.fold(content, 0, fn(acc, block) {
        case block {
          message.UserText(text:, ..) -> acc + byte_size(text)
          message.UserImage(..) -> acc + hooks.image_characters
        }
      })
    message.AssistantMessage(content:, ..) ->
      list.fold(content, 0, fn(acc, block) {
        case block {
          message.AssistantText(text:, ..) -> acc + byte_size(text)
          message.AssistantThinking(thinking:, ..) -> acc + byte_size(thinking)
          message.AssistantToolCall(call:) -> acc + byte_size(call.name) + 256
        }
      })
    message.ToolResultMessage(content:, tool_name:, ..) ->
      list.fold(content, byte_size(tool_name), fn(acc, block) {
        case block {
          message.ToolResultText(text:, ..) -> acc + byte_size(text)
          message.ToolResultImage(..) -> acc + hooks.image_characters
        }
      })
    message.CustomMessage(schema:, ..) -> byte_size(schema) + 256
  }
}

fn byte_size(text: String) -> Int {
  bit_array.byte_size(<<text:utf8>>)
}

fn resolved() -> model.ResolvedModel {
  model.ResolvedModel(
    provider: "bench",
    model_id: "bench-model",
    thinking: model.ThinkingOff,
    context_window: 200_000,
    max_output_tokens: 8192,
  )
}

fn provider_request(rig: Rig) -> model.ProviderRequest {
  model.ProviderRequest(
    target: model.ForResolved(resolved()),
    system: Some(string.repeat("system prompt ", 400)),
    messages: rig.projected.messages,
    tools: [],
    max_output_tokens: None,
  )
}

fn encode_openai(rig: Rig) -> http.HttpRequest {
  openai.build_request(
    base_url: "https://bench.invalid/v1",
    api_key: "k",
    resolved: resolved(),
    request: provider_request(rig),
  )
}

fn encode_anthropic(rig: Rig) -> http.HttpRequest {
  anthropic.build_request(
    base_url: "https://bench.invalid",
    api_key: "k",
    resolved: resolved(),
    request: provider_request(rig),
  )
}

/// One driver step's worth of the paths above, in the order the driver
/// takes them: the driver's own projection, the threshold hook's, the
/// reminder's, and the request encode. For the profiler.
///
/// ## Examples
///
/// ```gleam
/// // client_dev.step(rig)
/// ```
pub fn step(rig: Rig) -> Int {
  let _driver = scan(rig)
  let _threshold = project(rig.session)
  let _reminder = project(rig.session)
  let _estimate = estimate(rig)
  string.byte_size(encode_openai(rig).body)
}

fn run(path: String) -> Nil {
  case open(path) {
    Error(reason) -> io.println(reason)
    Ok(rig) -> {
      let entries = scan(rig)
      io.println(
        "branch entries: "
        <> int.to_string(list.length(entries))
        <> ", projected messages: "
        <> int.to_string(list.length(rig.projected.messages))
        <> ", estimate: "
        <> int.to_string(estimate(rig))
        <> " tokens (bytes/4: "
        <> int.to_string(estimate_bytes(rig))
        <> "), openai body: "
        <> int.to_string(string.byte_size(encode_openai(rig).body))
        <> " bytes, anthropic body: "
        <> int.to_string(string.byte_size(encode_anthropic(rig).body))
        <> " bytes",
      )
      bench.run(
        [bench.Input("store", rig)],
        [
          bench.Function("scan+decode", fn(rig: Rig) { list.length(scan(rig)) }),
          bench.Function("project", fn(rig: Rig) {
            list.length(project(rig.session).messages)
          }),
          bench.Function("estimate (graphemes)", estimate),
          bench.Function("estimate (bytes/4)", estimate_bytes),
          bench.Function("encode openai", fn(rig: Rig) {
            string.byte_size(encode_openai(rig).body)
          }),
          bench.Function("encode anthropic", fn(rig: Rig) {
            string.byte_size(encode_anthropic(rig).body)
          }),
          bench.Function("driver step", step),
        ],
        [bench.Warmup(2), bench.Duration(4000), bench.Decimals(2)],
      )
      |> bench.table([bench.IPS, bench.Min, bench.Mean, bench.P(99)])
      |> io.println
    }
  }
}
