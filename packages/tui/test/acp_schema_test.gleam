//// The ACP vocabulary: what a method's params must look like, what the
//// server answers, and what each refusal says. Decoding is total, so every
//// malformed shape here is an `Error` carrying the JSON-RPC code the client
//// should see, never a crash.

import core/json
import core/message
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tui/acp/rpc
import tui/acp/schema

fn text_block(text: String) -> json.JsonValue {
  json.Object([#("type", json.String("text")), #("text", json.String(text))])
}

fn params(members: List(#(String, json.JsonValue))) -> json.JsonValue {
  json.Object(members)
}

fn code_of(result: Result(a, rpc.WireError)) -> Int {
  let assert Error(error) = result as "this decode must fail"
  error.code
}

pub fn initialize_carries_the_clients_version_test() {
  assert schema.request(
      "initialize",
      params([#("protocolVersion", json.Int(1))]),
    )
    == Ok(schema.Initialize(1))
}

pub fn initialize_without_a_version_is_invalid_params_test() {
  assert code_of(schema.request("initialize", params([]))) == rpc.invalid_params
  assert code_of(schema.request(
      "initialize",
      params([#("protocolVersion", json.String("1"))]),
    ))
    == rpc.invalid_params
}

pub fn an_unknown_method_is_method_not_found_test() {
  assert code_of(schema.request("fs/read_text_file", params([])))
    == rpc.method_not_found
  assert code_of(schema.request("session/set_mode", params([])))
    == rpc.method_not_found
}

pub fn params_that_are_not_an_object_are_invalid_test() {
  assert code_of(schema.request("session/new", json.Array([])))
    == rpc.invalid_params
}

pub fn a_new_session_needs_a_cwd_and_reads_its_meta_test() {
  let meta =
    json.Object([
      #(
        "loom",
        json.Object([
          #("workspace", json.String("repo")),
          #("executor", json.String("builder")),
          #("model", json.String("fast")),
          #("project_instructions", json.Bool(False)),
        ]),
      ),
    ])
  let request =
    schema.request(
      "session/new",
      params([
        #("cwd", json.String("/work")),
        #("mcpServers", json.Array([])),
        #("_meta", meta),
      ]),
    )

  let assert Ok(schema.NewSession(cwd: "/work", mcp_servers: [], meta:)) =
    request
  assert meta.workspace == Some("repo")
  assert meta.executor == Some("builder")
  assert meta.pool == None
  assert meta.model == Some("fast")
  assert meta.guidance == schema.GuidanceOmitted
}

pub fn a_session_without_meta_takes_the_defaults_test() {
  let assert Ok(schema.NewSession(meta:, ..)) =
    schema.request("session/new", params([#("cwd", json.String("/w"))]))

  assert meta.workspace == None
  assert meta.guidance == schema.GuidanceLoaded
}

pub fn a_wrongly_typed_meta_member_is_refused_not_ignored_test() {
  let bad = fn(loom) {
    schema.request(
      "session/new",
      params([
        #("cwd", json.String("/w")),
        #("_meta", json.Object([#("loom", loom)])),
      ]),
    )
  }

  assert code_of(bad(json.Object([#("workspace", json.Int(1))])))
    == rpc.invalid_params
  assert code_of(
      bad(json.Object([#("project_instructions", json.String("no"))])),
    )
    == rpc.invalid_params
  assert code_of(bad(json.String("x"))) == rpc.invalid_params
}

pub fn offered_mcp_servers_are_named_for_the_server_to_refuse_test() {
  let servers =
    json.Array([
      json.Object([
        #("name", json.String("lint")),
        #("command", json.String("lint-mcp")),
      ]),
    ])

  let assert Ok(schema.NewSession(mcp_servers:, ..)) =
    schema.request(
      "session/new",
      params([#("cwd", json.String("/w")), #("mcpServers", servers)]),
    )
  assert mcp_servers == ["lint"]
  assert code_of(schema.request(
      "session/new",
      params([
        #("cwd", json.String("/w")),
        #("mcpServers", json.Array([json.Int(1)])),
      ]),
    ))
    == rpc.invalid_params
}

pub fn a_load_names_the_session_to_resume_test() {
  let request =
    schema.request(
      "session/load",
      params([
        #("sessionId", json.String("01J")),
        #("cwd", json.String("/w")),
      ]),
    )

  let assert Ok(schema.LoadSession(session_id: "01J", cwd: "/w", ..)) = request
  assert code_of(schema.request(
      "session/load",
      params([#("cwd", json.String("/w"))]),
    ))
    == rpc.invalid_params
}

pub fn a_prompt_maps_every_supported_block_kind_test() {
  let blocks =
    json.Array([
      text_block("look at this"),
      json.Object([
        #("type", json.String("image")),
        #("data", json.String("AAAA")),
        #("mimeType", json.String("image/png")),
      ]),
      json.Object([
        #("type", json.String("resource_link")),
        #("uri", json.String("file:///a.go")),
        #("name", json.String("a.go")),
      ]),
      json.Object([
        #("type", json.String("resource")),
        #(
          "resource",
          json.Object([
            #("uri", json.String("file:///b.go")),
            #("text", json.String("package b")),
          ]),
        ),
      ]),
    ])
  let request =
    schema.request(
      "session/prompt",
      params([#("sessionId", json.String("s")), #("prompt", blocks)]),
    )

  let assert Ok(schema.Prompt(session_id: "s", content:)) = request
  let assert [
    message.UserText("look at this", None),
    message.UserImage("AAAA", "image/png"),
    message.UserText(link, None),
    message.UserText(embedded, None),
  ] = content
  assert string.contains(link, "file:///a.go")
  assert string.contains(embedded, "package b")
  assert string.contains(embedded, "file:///b.go")
}

pub fn an_embedded_image_blob_becomes_an_image_test() {
  let block =
    json.Object([
      #("type", json.String("resource")),
      #(
        "resource",
        json.Object([
          #("uri", json.String("file:///s.png")),
          #("blob", json.String("QUJD")),
          #("mimeType", json.String("image/png")),
        ]),
      ),
    ])

  assert schema.blocks([block]) == Ok([message.UserImage("QUJD", "image/png")])
}

pub fn unsupported_or_malformed_blocks_are_invalid_params_test() {
  let audio =
    json.Object([
      #("type", json.String("audio")),
      #("data", json.String("AAAA")),
      #("mimeType", json.String("audio/wav")),
    ])
  let fake_image =
    json.Object([
      #("type", json.String("image")),
      #("data", json.String("AAAA")),
      #("mimeType", json.String("text/html")),
    ])
  let opaque_blob =
    json.Object([
      #("type", json.String("resource")),
      #(
        "resource",
        json.Object([
          #("uri", json.String("file:///x.bin")),
          #("blob", json.String("AAAA")),
          #("mimeType", json.String("application/octet-stream")),
        ]),
      ),
    ])

  assert code_of(schema.blocks([audio])) == rpc.invalid_params
  assert code_of(schema.blocks([fake_image])) == rpc.invalid_params
  assert code_of(schema.blocks([opaque_blob])) == rpc.invalid_params
  assert code_of(
      schema.blocks([json.Object([#("type", json.String("hologram"))])]),
    )
    == rpc.invalid_params
  assert code_of(schema.blocks([json.String("text")])) == rpc.invalid_params
  assert code_of(schema.blocks([json.Object([#("type", json.String("text"))])]))
    == rpc.invalid_params
}

pub fn an_empty_prompt_is_refused_test() {
  let request =
    schema.request(
      "session/prompt",
      params([#("sessionId", json.String("s")), #("prompt", json.Array([]))]),
    )

  assert code_of(request) == rpc.invalid_params
}

pub fn set_model_names_a_session_and_a_model_test() {
  let request =
    schema.request(
      "session/set_model",
      params([
        #("sessionId", json.String("s")),
        #("modelId", json.String("fast")),
      ]),
    )

  assert request == Ok(schema.SetModel("s", "fast"))
}

pub fn cancel_is_the_only_client_notification_test() {
  assert schema.notification(
      "session/cancel",
      params([#("sessionId", json.String("s"))]),
    )
    == Ok(schema.Cancel("s"))
  assert code_of(schema.notification("session/prompt", params([])))
    == rpc.method_not_found
  assert code_of(schema.notification("session/cancel", params([])))
    == rpc.invalid_params
}

pub fn a_permission_reply_is_a_selection_or_a_dismissal_test() {
  let selected =
    json.Object([
      #(
        "outcome",
        json.Object([
          #("outcome", json.String("selected")),
          #("optionId", json.String("allow")),
        ]),
      ),
    ])
  let cancelled =
    json.Object([
      #("outcome", json.Object([#("outcome", json.String("cancelled"))])),
    ])

  assert schema.permission_choice(selected) == Ok(schema.Selected("allow"))
  assert schema.permission_choice(cancelled) == Ok(schema.Dismissed)
}

pub fn a_malformed_permission_reply_is_refused_test() {
  let unknown =
    json.Object([
      #("outcome", json.Object([#("outcome", json.String("maybe"))])),
    ])
  let no_option =
    json.Object([
      #("outcome", json.Object([#("outcome", json.String("selected"))])),
    ])

  assert code_of(schema.permission_choice(json.Object([])))
    == rpc.invalid_params
  assert code_of(schema.permission_choice(unknown)) == rpc.invalid_params
  assert code_of(schema.permission_choice(no_option)) == rpc.invalid_params
  assert code_of(schema.permission_choice(json.Null)) == rpc.invalid_params
}

pub fn initialize_advertises_load_session_images_and_no_auth_test() {
  let assert json.Object(fields) = schema.initialize_result("9.9.9")

  assert list.key_find(fields, "protocolVersion") == Ok(json.Int(1))
  assert list.key_find(fields, "authMethods") == Ok(json.Array([]))
  let assert Ok(json.Object(capabilities)) =
    list.key_find(fields, "agentCapabilities")
  assert list.key_find(capabilities, "loadSession") == Ok(json.Bool(True))
  let assert Ok(json.Object(prompt)) =
    list.key_find(capabilities, "promptCapabilities")
  assert list.key_find(prompt, "image") == Ok(json.Bool(True))
  assert list.key_find(prompt, "embeddedContext") == Ok(json.Bool(True))
  assert list.key_find(prompt, "audio") == Ok(json.Bool(False))
  let assert Ok(json.Object(info)) = list.key_find(fields, "agentInfo")
  assert list.key_find(info, "name") == Ok(json.String("loom"))
  assert list.key_find(info, "version") == Ok(json.String("9.9.9"))
}

pub fn a_session_result_lists_models_only_when_there_are_some_test() {
  let bare = schema.session_result("s", None)
  let with_models =
    schema.session_result(
      "s",
      Some(
        schema.ModelState("fast", [
          schema.ModelChoice("fast", "m-1"),
          schema.ModelChoice("deep", "m-2"),
        ]),
      ),
    )

  assert bare == json.Object([#("sessionId", json.String("s"))])
  let assert json.Object(fields) = with_models
  let assert Ok(json.Object(models)) = list.key_find(fields, "models")
  assert list.key_find(models, "currentModelId") == Ok(json.String("fast"))
  let assert Ok(json.Array([first, ..])) =
    list.key_find(models, "availableModels")
  assert first
    == json.Object([
      #("modelId", json.String("fast")),
      #("name", json.String("m-1")),
    ])
}

pub fn a_prompt_result_names_the_stop_reason_and_the_turns_tokens_test() {
  let usage =
    schema.TurnUsage(
      input: 10,
      output: 4,
      total: 14,
      thought: Some(2),
      cached_read: 3,
      cached_write: 1,
    )

  assert schema.prompt_result(schema.Cancelled, None)
    == json.Object([#("stopReason", json.String("cancelled"))])
  let assert json.Object(fields) =
    schema.prompt_result(schema.EndTurn, Some(usage))
  assert list.key_find(fields, "stopReason") == Ok(json.String("end_turn"))
  let assert Ok(json.Object(counts)) = list.key_find(fields, "usage")
  assert list.key_find(counts, "inputTokens") == Ok(json.Int(10))
  assert list.key_find(counts, "outputTokens") == Ok(json.Int(4))
  assert list.key_find(counts, "totalTokens") == Ok(json.Int(14))
  assert list.key_find(counts, "thoughtTokens") == Ok(json.Int(2))
  assert list.key_find(counts, "cachedReadTokens") == Ok(json.Int(3))
}

pub fn every_update_kind_names_its_session_update_test() {
  let call =
    schema.ToolCall(
      "c1",
      "bash: ls",
      schema.Execute,
      schema.Pending,
      json.Object([#("command", json.String("ls"))]),
    )
  let kind = fn(update) {
    let assert json.Object(fields) = schema.update_params("s", update)
    let assert Ok(json.Object(body)) = list.key_find(fields, "update")
    let assert Ok(json.String(kind)) = list.key_find(body, "sessionUpdate")
    kind
  }

  assert kind(schema.AgentText("a")) == "agent_message_chunk"
  assert kind(schema.AgentThought("a")) == "agent_thought_chunk"
  assert kind(schema.UserText("a")) == "user_message_chunk"
  assert kind(schema.ToolStarted(call)) == "tool_call"
  assert kind(schema.ToolProgress("c1", schema.Completed, None, None))
    == "tool_call_update"
  assert kind(schema.Usage(5, 10, Some(0.25))) == "usage_update"
}

pub fn a_tool_call_carries_its_id_status_and_raw_input_test() {
  let call =
    schema.ToolCall(
      "c1",
      "bash: ls",
      schema.Execute,
      schema.Pending,
      json.Object([#("command", json.String("ls"))]),
    )

  assert json.to_string(schema.update_params("s", schema.ToolStarted(call)))
    == "{\"sessionId\":\"s\",\"update\":{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"c1\",\"title\":\"bash: ls\",\"kind\":\"execute\",\"status\":\"pending\",\"rawInput\":{\"command\":\"ls\"}}}"
}

pub fn a_tool_update_carries_content_and_raw_output_test() {
  let update =
    schema.ToolProgress(
      "c1",
      schema.Failed,
      Some("boom"),
      Some(json.Object([#("output", json.String("boom"))])),
    )

  assert json.to_string(schema.update_params("s", update))
    == "{\"sessionId\":\"s\",\"update\":{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"c1\",\"status\":\"failed\",\"content\":[{\"type\":\"content\",\"content\":{\"type\":\"text\",\"text\":\"boom\"}}],\"rawOutput\":{\"output\":\"boom\"}}}"
}

pub fn a_usage_update_prices_in_dollars_test() {
  assert json.to_string(schema.update_params(
      "s",
      schema.Usage(5, 10, Some(0.5)),
    ))
    == "{\"sessionId\":\"s\",\"update\":{\"sessionUpdate\":\"usage_update\",\"used\":5,\"size\":10,\"cost\":{\"amount\":0.5,\"currency\":\"USD\"}}}"
  assert json.to_string(schema.update_params("s", schema.Usage(5, 10, None)))
    == "{\"sessionId\":\"s\",\"update\":{\"sessionUpdate\":\"usage_update\",\"used\":5,\"size\":10}}"
}

pub fn a_permission_request_offers_each_option_by_kind_test() {
  let call =
    schema.ToolCall(
      "escalation-e1",
      "Allow",
      schema.Edit,
      schema.Pending,
      json.Null,
    )
  let options = [
    schema.PermissionOption("allow", "Allow once", schema.AllowOnce),
    schema.PermissionOption("allow_session", "Always", schema.AllowAlways),
    schema.PermissionOption("reject", "Deny", schema.RejectOnce),
  ]

  let encoded = json.to_string(schema.permission_params("s", call, options))
  assert string.contains(encoded, "\"toolCallId\":\"escalation-e1\"")
  assert string.contains(encoded, "\"kind\":\"allow_once\"")
  assert string.contains(encoded, "\"kind\":\"allow_always\"")
  assert string.contains(encoded, "\"kind\":\"reject_once\"")
  assert string.contains(encoded, "\"optionId\":\"reject\"")
}

pub fn set_config_option_distinguishes_a_choice_from_a_switch_test() {
  let request = fn(value) {
    schema.request(
      "session/set_config_option",
      params([
        #("sessionId", json.String("s")),
        #("configId", json.String("model")),
        #("value", value),
      ]),
    )
  }

  assert request(json.String("fast"))
    == Ok(schema.SetConfigOption("s", "model", schema.Choice("fast")))
  assert request(json.Bool(True))
    == Ok(schema.SetConfigOption("s", "model", schema.Switch))
  assert code_of(request(json.Int(3))) == rpc.invalid_params
  assert code_of(schema.request(
      "session/set_config_option",
      params([#("sessionId", json.String("s")), #("value", json.String("x"))]),
    ))
    == rpc.invalid_params
}

pub fn the_catalogue_is_offered_as_a_model_select_option_test() {
  let state =
    schema.ModelState("fast", [
      schema.ModelChoice("fast", "m-1"),
      schema.ModelChoice("deep", "m-2"),
    ])
  let assert json.Object(fields) = schema.session_result("s", Some(state))
  let assert Ok(json.Array([json.Object(option)])) =
    list.key_find(fields, "configOptions")

  assert list.key_find(option, "id") == Ok(json.String("model"))
  assert list.key_find(option, "category") == Ok(json.String("model"))
  assert list.key_find(option, "type") == Ok(json.String("select"))
  assert list.key_find(option, "currentValue") == Ok(json.String("fast"))
  let assert Ok(json.Array([first, ..])) = list.key_find(option, "options")
  assert first
    == json.Object([
      #("value", json.String("fast")),
      #("name", json.String("m-1")),
    ])
}

pub fn a_load_result_names_no_session_and_an_empty_catalogue_names_no_models_test() {
  assert schema.load_result(None) == json.Object([])
  let assert json.Object(fields) =
    schema.load_result(
      Some(schema.ModelState("a", [schema.ModelChoice("a", "m")])),
    )
  assert !list.contains(list.map(fields, fn(field) { field.0 }), "sessionId")
  assert list.key_find(fields, "models") != Error(Nil)
}

pub fn a_model_switch_is_answered_in_the_shape_it_was_asked_test() {
  let state = schema.ModelState("deep", [schema.ModelChoice("deep", "m-2")])

  assert schema.model_answer(schema.LegacyAnswer, Some(state))
    == json.Object([])
  let assert json.Object(fields) =
    schema.model_answer(schema.ConfigAnswer, Some(state))
  let assert Ok(json.Array([json.Object(option)])) =
    list.key_find(fields, "configOptions")
  assert list.key_find(option, "currentValue") == Ok(json.String("deep"))
  assert schema.model_answer(schema.ConfigAnswer, None)
    == json.Object([#("configOptions", json.Array([]))])
}
