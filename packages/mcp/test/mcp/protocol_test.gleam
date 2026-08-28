import core/json
import gleam/list
import gleam/option.{None, Some}
import mcp/jsonrpc
import mcp/protocol

// --- versions ----------------------------------------------------------------

pub fn supported_versions_newest_first_test() {
  assert protocol.supported_versions()
    == ["2025-06-18", "2025-03-26", "2024-11-05"]
}

pub fn requested_version_is_supported_test() {
  assert list.contains(
    protocol.supported_versions(),
    protocol.requested_version,
  )
}

// --- initialize --------------------------------------------------------------

pub fn initialize_request_shape_test() {
  assert json.to_string(protocol.initialize_request(jsonrpc.IdInt(1), "0.1.0"))
    == "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":"
    <> "{\"protocolVersion\":\"2025-06-18\","
    <> "\"capabilities\":{},"
    <> "\"clientInfo\":{\"name\":\"loom\",\"version\":\"0.1.0\"}}}"
}

// The empty capabilities object is a security decision (issue #106): no
// sampling, no roots, no elicitation. This pin is what makes a widening
// a deliberate, test-breaking act rather than a drive-by field.
pub fn initialize_declares_no_capabilities_test() {
  let assert json.Object(fields) =
    protocol.initialize_request(jsonrpc.IdInt(1), "0.1.0")
  let assert Ok(json.Object(params)) = list.key_find(fields, "params")
  assert list.key_find(params, "capabilities") == Ok(json.Object([]))
}

pub fn decode_initialize_result_full_test() {
  let assert Ok(value) =
    json.parse(
      "{\"protocolVersion\":\"2025-06-18\","
      <> "\"capabilities\":{\"tools\":{\"listChanged\":true}},"
      <> "\"serverInfo\":{\"name\":\"srv\",\"version\":\"9.9\"},"
      <> "\"instructions\":\"be kind\"}",
    )
  assert protocol.decode_initialize_result(value)
    == Ok(protocol.InitializeResult(
      protocol_version: "2025-06-18",
      tools: Some(protocol.ToolsCapability(list_changed: True)),
      server_name: Some("srv"),
      server_version: Some("9.9"),
      instructions: Some("be kind"),
    ))
}

pub fn decode_initialize_result_minimal_test() {
  let assert Ok(value) = json.parse("{\"protocolVersion\":\"2024-11-05\"}")
  assert protocol.decode_initialize_result(value)
    == Ok(protocol.InitializeResult(
      protocol_version: "2024-11-05",
      tools: None,
      server_name: None,
      server_version: None,
      instructions: None,
    ))
}

pub fn decode_initialize_accepts_every_supported_version_test() {
  assert accepted("2025-06-18")
  assert accepted("2025-03-26")
  assert accepted("2024-11-05")
}

fn accepted(version: String) -> Bool {
  let assert Ok(value) =
    json.parse("{\"protocolVersion\":\"" <> version <> "\"}")
  case protocol.decode_initialize_result(value) {
    Ok(result) -> result.protocol_version == version
    Error(_) -> False
  }
}

pub fn decode_initialize_refuses_unknown_version_test() {
  let assert Ok(value) = json.parse("{\"protocolVersion\":\"2026-07-28\"}")
  assert protocol.decode_initialize_result(value)
    == Error(
      protocol.UnsupportedVersion(server: "2026-07-28", supported: [
        "2025-06-18",
        "2025-03-26",
        "2024-11-05",
      ]),
    )
}

pub fn decode_initialize_missing_version_is_refused_test() {
  let assert Ok(value) = json.parse("{}")
  let assert Error(protocol.BadResult(reason)) =
    protocol.decode_initialize_result(value)
  assert reason == "protocolVersion is required"
}

pub fn decode_initialize_non_string_version_is_refused_test() {
  let assert Ok(value) = json.parse("{\"protocolVersion\":20250618}")
  let assert Error(protocol.BadResult(_)) =
    protocol.decode_initialize_result(value)
}

pub fn decode_initialize_non_object_result_is_refused_test() {
  let assert Error(protocol.BadResult(_)) =
    protocol.decode_initialize_result(json.Array([]))
}

pub fn decode_initialize_tools_without_list_changed_test() {
  let assert Ok(value) =
    json.parse(
      "{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{}}}",
    )
  let assert Ok(result) = protocol.decode_initialize_result(value)
  assert result.tools == Some(protocol.ToolsCapability(list_changed: False))
}

pub fn decode_initialize_non_bool_list_changed_is_refused_test() {
  let assert Ok(value) =
    json.parse(
      "{\"protocolVersion\":\"2025-06-18\","
      <> "\"capabilities\":{\"tools\":{\"listChanged\":\"yes\"}}}",
    )
  let assert Error(protocol.BadResult(_)) =
    protocol.decode_initialize_result(value)
}

pub fn decode_initialize_other_capabilities_are_ignored_test() {
  let assert Ok(value) =
    json.parse(
      "{\"protocolVersion\":\"2025-06-18\","
      <> "\"capabilities\":{\"prompts\":{},\"logging\":{}}}",
    )
  let assert Ok(result) = protocol.decode_initialize_result(value)
  assert result.tools == None
}

pub fn decode_initialize_non_object_capabilities_is_refused_test() {
  let assert Ok(value) =
    json.parse("{\"protocolVersion\":\"2025-06-18\",\"capabilities\":7}")
  let assert Error(protocol.BadResult(_)) =
    protocol.decode_initialize_result(value)
}

pub fn decode_initialize_non_object_server_info_is_refused_test() {
  let assert Ok(value) =
    json.parse("{\"protocolVersion\":\"2025-06-18\",\"serverInfo\":\"srv\"}")
  let assert Error(protocol.BadResult(_)) =
    protocol.decode_initialize_result(value)
}

pub fn decode_initialize_non_string_instructions_is_refused_test() {
  let assert Ok(value) =
    json.parse("{\"protocolVersion\":\"2025-06-18\",\"instructions\":[]}")
  let assert Error(protocol.BadResult(_)) =
    protocol.decode_initialize_result(value)
}

pub fn initialized_notification_test() {
  assert json.to_string(protocol.initialized())
    == "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"
}

// --- tools/list ----------------------------------------------------------------

pub fn list_tools_request_without_cursor_test() {
  assert json.to_string(protocol.list_tools_request(jsonrpc.IdInt(2), None))
    == "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}"
}

pub fn list_tools_request_with_cursor_test() {
  assert json.to_string(protocol.list_tools_request(
      jsonrpc.IdInt(3),
      Some("page-2"),
    ))
    == "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\","
    <> "\"params\":{\"cursor\":\"page-2\"}}"
}

pub fn decode_tools_page_test() {
  let assert Ok(value) =
    json.parse(
      "{\"tools\":[{\"name\":\"echo\",\"title\":\"Echo\","
      <> "\"description\":\"says it back\","
      <> "\"inputSchema\":{\"type\":\"object\"},"
      <> "\"outputSchema\":{\"type\":\"object\"}}],"
      <> "\"nextCursor\":\"page-2\"}",
    )
  assert protocol.decode_tools_page(value)
    == Ok(protocol.ToolsPage(
      tools: [
        protocol.ToolDescriptor(
          name: "echo",
          title: Some("Echo"),
          description: Some("says it back"),
          input_schema: json.Object([#("type", json.String("object"))]),
          output_schema: Some(json.Object([#("type", json.String("object"))])),
        ),
      ],
      next_cursor: Some("page-2"),
    ))
}

pub fn decode_tools_page_minimal_tool_test() {
  let assert Ok(value) =
    json.parse("{\"tools\":[{\"name\":\"t\",\"inputSchema\":{}}]}")
  assert protocol.decode_tools_page(value)
    == Ok(protocol.ToolsPage(
      tools: [
        protocol.ToolDescriptor(
          name: "t",
          title: None,
          description: None,
          input_schema: json.Object([]),
          output_schema: None,
        ),
      ],
      next_cursor: None,
    ))
}

pub fn decode_tools_page_empty_list_test() {
  let assert Ok(value) = json.parse("{\"tools\":[]}")
  assert protocol.decode_tools_page(value)
    == Ok(protocol.ToolsPage(tools: [], next_cursor: None))
}

// The input schema crosses this layer raw: whatever JSON the server
// declared is what downstream sees, uninterpreted.
pub fn decode_tools_page_keeps_schema_raw_test() {
  let assert Ok(value) =
    json.parse(
      "{\"tools\":[{\"name\":\"t\",\"inputSchema\":"
      <> "{\"anyOf\":[{\"type\":\"string\"},17]}}]}",
    )
  let assert Ok(protocol.ToolsPage(tools: [tool], ..)) =
    protocol.decode_tools_page(value)
  assert tool.input_schema
    == json.Object([
      #(
        "anyOf",
        json.Array([
          json.Object([#("type", json.String("string"))]),
          json.Int(17),
        ]),
      ),
    ])
}

pub fn decode_tools_page_missing_tools_is_refused_test() {
  let assert Ok(value) = json.parse("{\"nextCursor\":\"c\"}")
  let assert Error(protocol.BadResult(reason)) =
    protocol.decode_tools_page(value)
  assert reason == "tools is required"
}

pub fn decode_tools_page_non_array_tools_is_refused_test() {
  let assert Ok(value) = json.parse("{\"tools\":{}}")
  let assert Error(protocol.BadResult(_)) = protocol.decode_tools_page(value)
}

// One bad entry fails the whole page, and the fault names the index.
pub fn decode_tools_page_non_object_entry_fails_whole_list_test() {
  let assert Ok(value) =
    json.parse("{\"tools\":[{\"name\":\"good\",\"inputSchema\":{}},\"bad\"]}")
  let assert Error(protocol.BadResult(reason)) =
    protocol.decode_tools_page(value)
  assert reason == "tools[1] must be an object"
}

pub fn decode_tools_page_missing_name_names_the_index_test() {
  let assert Ok(value) = json.parse("{\"tools\":[{\"inputSchema\":{}}]}")
  let assert Error(protocol.BadResult(reason)) =
    protocol.decode_tools_page(value)
  assert reason == "tools[0].name must be a string"
}

pub fn decode_tools_page_empty_name_is_refused_test() {
  let assert Ok(value) =
    json.parse("{\"tools\":[{\"name\":\"\",\"inputSchema\":{}}]}")
  let assert Error(protocol.BadResult(reason)) =
    protocol.decode_tools_page(value)
  assert reason == "tools[0].name must be non-empty"
}

pub fn decode_tools_page_non_string_name_is_refused_test() {
  let assert Ok(value) =
    json.parse("{\"tools\":[{\"name\":7,\"inputSchema\":{}}]}")
  let assert Error(protocol.BadResult(_)) = protocol.decode_tools_page(value)
}

pub fn decode_tools_page_missing_schema_is_refused_test() {
  let assert Ok(value) = json.parse("{\"tools\":[{\"name\":\"t\"}]}")
  let assert Error(protocol.BadResult(reason)) =
    protocol.decode_tools_page(value)
  assert reason == "tools[0].inputSchema is required"
}

pub fn decode_tools_page_non_string_title_is_refused_test() {
  let assert Ok(value) =
    json.parse("{\"tools\":[{\"name\":\"t\",\"title\":1,\"inputSchema\":{}}]}")
  let assert Error(protocol.BadResult(reason)) =
    protocol.decode_tools_page(value)
  assert reason == "tools[0].title must be a string"
}

pub fn decode_tools_page_non_string_cursor_is_refused_test() {
  let assert Ok(value) = json.parse("{\"tools\":[],\"nextCursor\":7}")
  let assert Error(protocol.BadResult(_)) = protocol.decode_tools_page(value)
}

// --- tools/call ----------------------------------------------------------------

pub fn call_tool_request_shape_test() {
  let arguments = json.Object([#("text", json.String("hi"))])
  assert json.to_string(protocol.call_tool_request(
      jsonrpc.IdInt(4),
      "echo",
      arguments,
    ))
    == "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\","
    <> "\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"hi\"}}}"
}

pub fn decode_call_tool_result_text_test() {
  let assert Ok(value) =
    json.parse("{\"content\":[{\"type\":\"text\",\"text\":\"hello\"}]}")
  assert protocol.decode_call_tool_result(value)
    == Ok(protocol.CallToolResult(
      content: [protocol.Text("hello")],
      is_error: False,
      structured_content: None,
    ))
}

pub fn decode_call_tool_result_is_error_true_test() {
  let assert Ok(value) =
    json.parse(
      "{\"content\":[{\"type\":\"text\",\"text\":\"boom\"}],\"isError\":true}",
    )
  let assert Ok(result) = protocol.decode_call_tool_result(value)
  assert result.is_error == True
}

// Absent isError reads as False — the schema's default. The mutation
// test for this claim flips the default and watches this fail.
pub fn decode_call_tool_result_absent_is_error_reads_false_test() {
  let assert Ok(value) = json.parse("{\"content\":[]}")
  let assert Ok(result) = protocol.decode_call_tool_result(value)
  assert result.is_error == False
}

pub fn decode_call_tool_result_non_bool_is_error_is_refused_test() {
  let assert Ok(value) = json.parse("{\"content\":[],\"isError\":\"yes\"}")
  let assert Error(protocol.BadResult(_)) =
    protocol.decode_call_tool_result(value)
}

pub fn decode_call_tool_result_other_kind_kept_test() {
  let assert Ok(value) =
    json.parse(
      "{\"content\":[{\"type\":\"image\",\"data\":\"...\","
      <> "\"mimeType\":\"image/png\"}]}",
    )
  let assert Ok(result) = protocol.decode_call_tool_result(value)
  assert result.content == [protocol.Other(kind: "image")]
}

pub fn decode_call_tool_result_structured_content_kept_raw_test() {
  let assert Ok(value) =
    json.parse("{\"content\":[],\"structuredContent\":{\"n\":1}}")
  let assert Ok(result) = protocol.decode_call_tool_result(value)
  assert result.structured_content == Some(json.Object([#("n", json.Int(1))]))
}

pub fn decode_call_tool_result_missing_content_is_refused_test() {
  let assert Ok(value) = json.parse("{\"isError\":false}")
  let assert Error(protocol.BadResult(reason)) =
    protocol.decode_call_tool_result(value)
  assert reason == "content is required"
}

pub fn decode_call_tool_result_non_array_content_is_refused_test() {
  let assert Ok(value) = json.parse("{\"content\":\"hello\"}")
  let assert Error(protocol.BadResult(_)) =
    protocol.decode_call_tool_result(value)
}

pub fn decode_call_tool_result_block_without_type_is_refused_test() {
  let assert Ok(value) = json.parse("{\"content\":[{\"text\":\"orphan\"}]}")
  let assert Error(protocol.BadResult(reason)) =
    protocol.decode_call_tool_result(value)
  assert reason == "content[0].type must be a string"
}

pub fn decode_call_tool_result_non_string_type_is_refused_test() {
  let assert Ok(value) = json.parse("{\"content\":[{\"type\":7}]}")
  let assert Error(protocol.BadResult(_)) =
    protocol.decode_call_tool_result(value)
}

pub fn decode_call_tool_result_text_block_without_text_is_refused_test() {
  let assert Ok(value) = json.parse("{\"content\":[{\"type\":\"text\"}]}")
  let assert Error(protocol.BadResult(reason)) =
    protocol.decode_call_tool_result(value)
  assert reason == "content[0].text must be a string"
}

pub fn decode_call_tool_result_non_object_block_names_index_test() {
  let assert Ok(value) =
    json.parse("{\"content\":[{\"type\":\"text\",\"text\":\"ok\"},null]}")
  let assert Error(protocol.BadResult(reason)) =
    protocol.decode_call_tool_result(value)
  assert reason == "content[1] must be an object"
}

// --- ping ----------------------------------------------------------------------

pub fn ping_request_test() {
  assert json.to_string(protocol.ping_request(jsonrpc.IdInt(5)))
    == "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"ping\"}"
}

pub fn decode_ping_result_empty_object_test() {
  assert protocol.decode_ping_result(json.Object([])) == Ok(Nil)
}

pub fn decode_ping_result_tolerates_extra_fields_test() {
  assert protocol.decode_ping_result(json.Object([#("x", json.Int(1))]))
    == Ok(Nil)
}

pub fn decode_ping_result_non_object_is_refused_test() {
  let assert Error(protocol.BadResult(_)) =
    protocol.decode_ping_result(json.String("pong"))
}
