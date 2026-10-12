//// A `history_search` call in the terminal: the compact transcript names the
//// query and lists what the search found, one row to a hit, and expanding the
//// details adds the hits a collapsed result left out. A result whose details
//// are not the record the tool writes keeps the tool's own prose.

import core/codec
import core/entry
import core/json
import core/message
import etui/backend
import etui/geometry
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import session_view/connection_event
import session_view/protocol
import tui
import tui/connection
import tui/frame
import tui/inbound
import tui/render
import tui/workspace
import tui_test/gateway

const session = "019a3c1e-5b7d-7c3e-9a10-2f4b6c8d0e1f"

fn call() {
  let assert Ok(protocol.EntryAdded(record)) =
    protocol.decode_event(gateway.tool_call_entry(
      "main",
      "history_search",
      "recall",
      1,
    ))
    as "the fixture is a valid tool-call entry"
  let assert entry.MessageEntry(message: body, ..) as placed = record.entry
    as "the fixture carries a message"
  let assert message.AssistantMessage(..) = body
    as "the fixture carries an assistant message"
  entry.MessageEntry(
    ..placed,
    message: message.AssistantMessage(..body, content: [
      message.AssistantToolCall(message.ToolCall(
        "recall",
        "history_search",
        json.Object([
          #("query", json.String("deploy")),
          #("kind", json.String("assistant")),
        ]),
        None,
        None,
      )),
    ]),
  )
}

fn hit(tail: String, kind: String, snippet: String) -> json.JsonValue {
  json.Object([
    #("session", json.String(session)),
    #("entry", json.String("019a3c1e-aaaa-7bbb-8ccc-0123456789" <> tail)),
    #("kind", json.String(kind)),
    #("ts", json.Int(1_760_140_800_000)),
    #("snippet", json.String(snippet)),
  ])
}

fn outcome(details: Option(json.JsonValue)) {
  let assert Ok(protocol.EntryAdded(record)) =
    protocol.decode_event(gateway.tool_call_entry("main", "bash", "other", 2))
    as "the fixture supplies an entry envelope"
  let assert entry.MessageEntry(..) as placed = record.entry
    as "the fixture carries a message"
  entry.MessageEntry(
    ..placed,
    message: message.ToolResultMessage(
      tool_call_id: "recall",
      tool_name: "history_search",
      content: [
        message.ToolResultText(
          "3 hits from the repository history index, best match first.",
          None,
        ),
      ],
      details:,
      usage: None,
      added_tool_names: None,
      is_error: False,
      timestamp: 0,
    ),
  )
}

fn found(hits: List(json.JsonValue)) -> Option(json.JsonValue) {
  Some(
    json.Object([
      #("hits", json.Array(hits)),
      #("hit_count", json.Int(list.length(hits))),
      #("scope", json.String("repository")),
      #("limit", json.Int(10)),
    ]),
  )
}

fn received(model, value) {
  inbound.accept_connection_message(
    model,
    connection_event.Incoming(
      json.to_string(
        json.Object([
          #("v", json.Int(1)),
          #("event", json.String("entry")),
          #(
            "body",
            json.Object([
              #("strand", json.String("main")),
              #("entry", codec.encode_entry(value)),
            ]),
          ),
        ]),
      ),
    ),
  )
}

fn text(model) {
  let model = tui.update(backend.Resize(120, 40), model)
  let #(buffer, _) = render.view(model, geometry.rect_new(0, 0, 120, 40))
  #(model, frame.buffer_to_text(buffer))
}

fn base() {
  tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
}

pub fn a_search_lists_its_hits_under_its_query_test() {
  let hits = [
    hit("a1", "assistant", "we deploy with make release"),
    hit("b2", "assistant", "the deploy script lives in scripts"),
    hit("c3", "assistant", "deploys go through the queue"),
  ]
  let #(_, shown) =
    base() |> received(call()) |> received(outcome(found(hits))) |> text
  assert string.contains(
    shown,
    "✓ history_search · \"deploy\" · kind assistant · 3 hits",
  )
  assert string.contains(
    shown,
    "019a3c1e · 456789a1 · assistant · 2025-10-11 · we deploy with make release",
  )
  assert string.contains(shown, "456789c3 · assistant · 2025-10-11")
  assert !string.contains(shown, "best match first")
}

pub fn expanding_the_details_shows_the_hits_a_collapsed_result_left_out_test() {
  let hits =
    list.map(["a1", "b2", "c3", "d4", "e5"], fn(tail) {
      hit(tail, "user", "snippet " <> tail)
    })
  let #(compact, compact_text) =
    base() |> received(call()) |> received(outcome(found(hits))) |> text
  assert string.contains(compact_text, "snippet c3")
  assert !string.contains(compact_text, "snippet d4")
  assert string.contains(compact_text, "… 2 more · Ctrl+g shows all")

  let #(_, expanded_text) =
    compact |> tui.update(backend.KeyPress("ctrl+g"), _) |> text
  assert string.contains(expanded_text, "history_search · 5 hits")
  assert string.contains(expanded_text, "snippet d4")
  assert string.contains(expanded_text, "snippet e5")
  assert !string.contains(expanded_text, "2 more")
}

pub fn a_search_with_no_hits_says_so_test() {
  let #(_, shown) =
    base() |> received(call()) |> received(outcome(found([]))) |> text
  assert string.contains(shown, "history_search · \"deploy\"")
  assert string.contains(shown, "no hits")
}

pub fn malformed_details_do_not_break_the_row_test() {
  let #(_, shown) =
    base()
    |> received(call())
    |> received(outcome(Some(json.String("junk"))))
    |> text
  assert string.contains(
    shown,
    "✓ history_search · \"deploy\" · kind assistant",
  )
  assert !string.contains(shown, "hits")
}
