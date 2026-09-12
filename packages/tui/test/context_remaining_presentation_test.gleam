//// `context_remaining` has model-facing prose and structured details. The
//// compact transcript keeps the successful call and its shortest useful
//// measurement; expanded detail adds the checkpoint and notes count.

import core/codec
import core/entry
import core/json
import core/message
import etui/backend
import etui/geometry
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tui
import tui/connection
import tui/frame
import tui/protocol
import tui/workspace
import tui_test/gateway

fn call() {
  let assert Ok(protocol.EntryAdded(record)) =
    protocol.decode_event(gateway.tool_call_entry(
      "main",
      "context_remaining",
      "context",
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
        "context",
        "context_remaining",
        json.Object([]),
        None,
        None,
      )),
    ]),
  )
}

fn outcome() {
  let assert Ok(protocol.EntryAdded(record)) =
    protocol.decode_event(gateway.tool_call_entry("main", "bash", "other", 2))
    as "the fixture supplies an entry envelope"
  let assert entry.MessageEntry(..) as placed = record.entry
    as "the fixture carries a message"
  entry.MessageEntry(
    ..placed,
    message: message.ToolResultMessage(
      tool_call_id: "context",
      tool_name: "context_remaining",
      content: [
        message.ToolResultText(
          "Context window 2 of strand `main`: about 143000 of 200000 tokens in use. Write with agent_note whatever you will still need.",
          None,
        ),
      ],
      details: Some(
        json.Object([
          #("window", json.Int(2)),
          #("context_window", json.Int(200_000)),
          #("used_tokens", json.Int(143_000)),
          #("remaining_tokens", json.Int(40_616)),
          #("checkpoint_at", json.Int(183_616)),
          #("notes", json.Int(7)),
        ]),
      ),
      usage: None,
      added_tool_names: None,
      is_error: False,
      timestamp: 0,
    ),
  )
}

fn received(model, value) {
  tui.accept_connection_message(
    model,
    connection.Incoming(
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
  let #(buffer, _) = tui.view(model, geometry.rect_new(0, 0, 120, 40))
  #(model, frame.buffer_to_text(buffer))
}

pub fn compact_and_expanded_context_results_use_measurements_test() {
  let base =
    tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
  let #(compact, compact_text) =
    base |> received(call()) |> received(outcome()) |> text
  assert string.contains(compact_text, "✓ context remaining")
  assert string.contains(
    compact_text,
    "~143k / 200k used · ~40k until checkpoint",
  )
  assert !string.contains(compact_text, "Write with agent_note")

  let #(_, expanded_text) =
    compact |> tui.update(backend.KeyPress("ctrl+g"), _) |> text
  assert string.contains(expanded_text, "context remaining · window 2")
  assert string.contains(
    expanded_text,
    "~143k / 200k used · ~40k until checkpoint",
  )
  assert string.contains(expanded_text, "checkpoint at 183k · 7 saved notes")
  assert !string.contains(expanded_text, "Write with agent_note")
}

pub fn disabled_checkpoint_names_the_context_limit_test() {
  let assert entry.MessageEntry(message: body, ..) as placed = outcome()
    as "the result has an entry envelope"
  let assert message.ToolResultMessage(details: Some(json.Object(fields)), ..) =
    body
    as "the result has context measurements"
  let result =
    entry.MessageEntry(
      ..placed,
      message: message.ToolResultMessage(
        ..body,
        details: Some(
          json.Object(
            list.map(fields, fn(field) {
              case field.0 {
                "checkpoint_at" -> #("checkpoint_at", json.Null)
                _ -> field
              }
            }),
          ),
        ),
      ),
    )
  let base =
    tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
  let #(compact, compact_text) =
    base |> received(call()) |> received(result) |> text
  assert string.contains(compact_text, "before context limit")
  assert !string.contains(compact_text, "until checkpoint")
  let #(_, expanded_text) =
    compact |> tui.update(backend.KeyPress("ctrl+g"), _) |> text
  assert string.contains(expanded_text, "before context limit")
  assert string.contains(expanded_text, "no checkpoint")
}

pub fn a_context_result_without_details_keeps_its_text_test() {
  let assert entry.MessageEntry(message: body, ..) as placed = outcome()
    as "the result has an entry envelope"
  let assert message.ToolResultMessage(..) = body
    as "the entry contains the tool result"
  let result =
    entry.MessageEntry(
      ..placed,
      message: message.ToolResultMessage(..body, details: None),
    )
  let base =
    tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
  let #(_, compact_text) = base |> received(call()) |> received(result) |> text
  assert string.contains(compact_text, "Context window 2")
}
