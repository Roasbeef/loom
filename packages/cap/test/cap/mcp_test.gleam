//// `cap/internal/mcp` marshaling and `cap/mcp` decoding, over a fake
//// channel: the wire-shape pin the harness router will be written
//// against, the pinned result shape's happy paths, every malformed
//// shape, and the `CallError` mapping.

import cap/internal/channel
import cap/internal/dispatch
import cap/internal/mcp as mcp_internal
import cap/internal/wire
import cap/mcp
import core/msgpack
import gleam/erlang/process
import gleam/option.{None, Some}

// --- helpers ------------------------------------------------------------

// Install a fake channel whose `call` is the given function, bypassing
// the actor so marshaling and error mapping are tested deterministically
// (the same shape as `cap_test.install_fake`).
fn install_fake(
  with call: fn(String, msgpack.MsgPackValue, Int) ->
    Result(msgpack.MsgPackValue, channel.CallError),
) -> Nil {
  dispatch.install(channel.Channel(call:))
}

fn map(entries: List(#(String, msgpack.MsgPackValue))) -> msgpack.MsgPackValue {
  wire.args(entries)
}

fn text_block(text: String) -> msgpack.MsgPackValue {
  map([
    #("type", msgpack.StringValue("text")),
    #("text", msgpack.StringValue(text)),
  ])
}

// A well-formed success result carrying the given blocks and nothing else.
fn result_of(blocks: List(msgpack.MsgPackValue)) -> msgpack.MsgPackValue {
  map([
    #("content", msgpack.ArrayValue(blocks)),
    #("is_error", msgpack.BoolValue(False)),
  ])
}

fn invoke_against(
  result: Result(msgpack.MsgPackValue, channel.CallError),
) -> Result(mcp.ToolResult, mcp.McpError) {
  install_fake(with: fn(_cap, _args, _deadline) { result })
  mcp_internal.invoke("github", "get_issue", map([]))
}

// --- the wire-shape pin ---------------------------------------------------

// THE CONTRACT TEST: the exact capability name and the exact args map an
// `invoke` puts on the wire. The harness-side router (which shares no
// dependency with this package — two ends of one wire, per cap/CLAUDE.md)
// will be written against precisely this shape, restated on its own side:
// capability `"mcp." <> server`, args `{tool, arguments}` with `tool` the
// server's original tool name verbatim. Changing anything this test pins
// is a protocol change, not a refactor.
pub fn invoke_wire_shape_is_pinned_test() {
  let seen = process.new_subject()
  install_fake(with: fn(cap, args, _deadline) {
    process.send(seen, #(cap, args))
    Ok(result_of([]))
  })
  let arguments =
    map([
      #("title", msgpack.StringValue("Bug: satellite leaks a socket")),
      #("labels", msgpack.ArrayValue([msgpack.StringValue("bug")])),
    ])
  let assert Ok(_) = mcp_internal.invoke("github", "create_issue", arguments)
  let assert Ok(#(cap, args)) = process.receive(seen, 1000)
  assert cap == "mcp.github"
  assert args
    == map([
      #("tool", msgpack.StringValue("create_issue")),
      #("arguments", arguments),
    ])
}

// --- decoding the pinned result shape -------------------------------------

pub fn text_result_decodes_test() {
  let result =
    invoke_against(Ok(result_of([text_block("hello"), text_block("world")])))
  assert result
    == Ok(mcp.ToolResult(
      content: [mcp.Text("hello"), mcp.Text("world")],
      structured: None,
    ))
  let assert Ok(tool_result) = result
  assert mcp.text(tool_result) == "hello\nworld"
}

pub fn other_block_kinds_are_carried_by_kind_test() {
  let image =
    map([
      #("type", msgpack.StringValue("image")),
      #("data", msgpack.StringValue("aGk=")),
    ])
  assert invoke_against(Ok(result_of([image, text_block("caption")])))
    == Ok(mcp.ToolResult(
      content: [mcp.Other("image"), mcp.Text("caption")],
      structured: None,
    ))
}

pub fn absent_is_error_reads_as_success_test() {
  // The harness always writes `is_error`; a result without it still
  // decodes, as success — the tolerant posture `cap/internal/mcp`
  // documents.
  assert invoke_against(Ok(map([#("content", msgpack.ArrayValue([]))])))
    == Ok(mcp.ToolResult(content: [], structured: None))
}

pub fn structured_output_is_carried_test() {
  let structured = map([#("count", msgpack.IntValue(3))])
  let value =
    map([
      #("content", msgpack.ArrayValue([text_block("3 issues")])),
      #("is_error", msgpack.BoolValue(False)),
      #("structured", structured),
    ])
  assert invoke_against(Ok(value))
    == Ok(mcp.ToolResult(
      content: [mcp.Text("3 issues")],
      structured: Some(structured),
    ))
}

pub fn is_error_true_becomes_tool_failed_test() {
  let value =
    map([
      #(
        "content",
        msgpack.ArrayValue([text_block("no such repo"), text_block("sorry")]),
      ),
      #("is_error", msgpack.BoolValue(True)),
    ])
  assert invoke_against(Ok(value))
    == Error(
      mcp.ToolFailed(message: "no such repo\nsorry", content: [
        mcp.Text("no such repo"),
        mcp.Text("sorry"),
      ]),
    )
}

// --- each malformed shape names its fault ----------------------------------

pub fn result_that_is_not_a_map_is_malformed_test() {
  assert invoke_against(Ok(msgpack.StringValue("done")))
    == Error(mcp.ResultMalformed("bad mcp result: expected a map, got a scalar"))
}

pub fn missing_content_is_malformed_test() {
  assert invoke_against(Ok(map([#("is_error", msgpack.BoolValue(False))])))
    == Error(mcp.ResultMalformed("bad mcp result: missing field content"))
}

pub fn content_that_is_not_an_array_is_malformed_test() {
  assert invoke_against(Ok(map([#("content", msgpack.StringValue("hello"))])))
    == Error(mcp.ResultMalformed(
      "bad mcp result: field content is not an array",
    ))
}

pub fn block_missing_its_type_is_malformed_test() {
  assert invoke_against(
      Ok(result_of([map([#("text", msgpack.StringValue("hi"))])])),
    )
    == Error(mcp.ResultMalformed("bad mcp result: missing field type"))
}

pub fn block_with_a_non_string_type_is_malformed_test() {
  assert invoke_against(Ok(result_of([map([#("type", msgpack.IntValue(1))])])))
    == Error(mcp.ResultMalformed("bad mcp result: field type is not a string"))
}

pub fn text_block_missing_its_text_is_malformed_test() {
  assert invoke_against(
      Ok(result_of([map([#("type", msgpack.StringValue("text"))])])),
    )
    == Error(mcp.ResultMalformed("bad mcp result: missing field text"))
}

pub fn non_boolean_is_error_is_malformed_test() {
  let value =
    map([
      #("content", msgpack.ArrayValue([])),
      #("is_error", msgpack.StringValue("true")),
    ])
  assert invoke_against(Ok(value))
    == Error(mcp.ResultMalformed(
      "bad mcp result: field is_error is not a boolean",
    ))
}

// --- CallError mapping ------------------------------------------------------

pub fn denied_maps_to_mcp_denied_with_the_code_verbatim_test() {
  assert invoke_against(Error(channel.Denied("unsupported_cap", "no router")))
    == Error(mcp.McpDenied(code: "unsupported_cap", message: "no router"))
}

pub fn unreachable_maps_to_server_unavailable_test() {
  assert invoke_against(Error(channel.Unreachable("channel gone")))
    == Error(mcp.ServerUnavailable("channel gone"))
}
