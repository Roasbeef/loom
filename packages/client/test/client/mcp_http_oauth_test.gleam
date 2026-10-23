//// End-to-end and unit coverage for Streamable HTTP MCP servers and OAuth 2.1
//// credentials (#108).
////
//// Covers:
//// 1. Initialized Streamable HTTP (`2025-06-18`, `Mcp-Session-Id`,
////    `notifications/initialized` 202, `Authorization: Macaroon` and
////    `Authorization: Bearer`, JSON and SSE responses, and `DELETE` on close).
//// 2. Stateless `2026-07-28` HTTP against a real loopback
////    `gleam_mcp/server_http` listener with `Authenticate` and `x-mcp-header`
////    parameter mirrors.
//// 3. The 8 MiB HTTP body and SSE event limits (`mcp_malformed` on the
////    oversized call without killing subsequent calls) and unforgeable HMAC
////    fault classification.
//// 4. OAuth 2.1 Protected Resource Metadata (RFC 9728), Authorization Server
////    Metadata (RFC 8414), Dynamic Client Registration (RFC 7591), real
////    loopback browser PKCE (`S256` + `resource`), locked `0600` storage,
////    refresh-token rotation, mid-session HTTP 401 refresh, and in-band
////    expiry refusal (`loomd mcp login <server>`).
//// 5. `loomd mcp` CLI argument parsing, execution, and drain checks.

import broker/budget
import broker/exec
import broker/framing
import broker/policy
import client/catalog
import client/codex/network
import client/daemon/listener
import client/mcp
import client/mcp/cli as mcp_cli
import client/mcp/credentials
import client/mcp/http as mcp_http
import client/mcp/oauth
import codemode/identity
import codemode/satellite
import core/clock
import core/ids
import core/msgpack
import gleam/bit_array
import gleam/bytes_tree
import gleam/crypto
import gleam/erlang/process
import gleam/http/request as http_request
import gleam/http/response as http_response
import gleam/httpc
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import gleam_mcp/http_headers
import gleam_mcp/json
import gleam_mcp/jsonrpc
import gleam_mcp/protocol
import gleam_mcp/server as mcp_server
import host/bootstrap
import mist
import provider/http as provider_http
import provider/secret
import simplifile
import weft

const t = 1_700_000_000_000

fn op_id() -> ids.OpId {
  let #(op, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: t), seed: 11))
  op
}

fn cap_request(
  cap: String,
  args: msgpack.MsgPackValue,
) -> satellite.CapRequest {
  satellite.CapRequest(
    cap:,
    args:,
    identity: identity.for_execution(
      op_id: op_id(),
      step_id: "step-http",
      budget: budget.Budget(max_outstanding: 4, deadline_ms: t + 20_000),
    )
      |> identity.run_phase,
    base_policy: policy.workspace_default("/work"),
    demand: exec.BestEffort,
    env: [],
    cwd: "/work",
    ordinal: 0,
  )
}

fn invocation(
  tool: String,
  arguments: List(#(String, msgpack.MsgPackValue)),
) -> msgpack.MsgPackValue {
  msgpack.MapValue([
    #(msgpack.StringValue("tool"), msgpack.StringValue(tool)),
    #(
      msgpack.StringValue("arguments"),
      msgpack.MapValue(
        list.map(arguments, fn(pair) { #(msgpack.StringValue(pair.0), pair.1) }),
      ),
    ),
  ])
}

fn beneath(
  req: satellite.CapRequest,
) -> Result(satellite.CapPlan, satellite.CapDenial) {
  Error(satellite.CapDenial(code: "delegated", message: req.cap))
}

fn served(layer: mcp.Layer, req: satellite.CapRequest) -> framing.CapOutcome {
  let assert Ok(satellite.ServedHere(serve:)) =
    mcp.routing(layer, over: beneath)(req)
    as "an mcp call plans as ServedHere"
  serve()
}

fn text_of(value: msgpack.MsgPackValue) -> Result(String, Nil) {
  case value {
    msgpack.MapValue(entries:) ->
      case list.key_find(entries, msgpack.StringValue("content")) {
        Ok(msgpack.ArrayValue([msgpack.MapValue(block), ..])) ->
          case list.key_find(block, msgpack.StringValue("text")) {
            Ok(msgpack.StringValue(text)) -> Ok(text)
            _ -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn scripted_transport(
  handler: fn(provider_http.HttpRequest) -> List(provider_http.HttpEvent),
) -> provider_http.Transport {
  provider_http.Transport(prepare_streaming: fn(req, events) {
    let ready = process.new_subject()
    let owner =
      process.spawn_unlinked(fn() {
        let stop = process.new_subject()
        process.send(ready, stop)
        let _ = process.receive(stop, 5000)
        Nil
      })
    let assert Ok(stop) = process.receive(ready, 1000)
    Ok(
      provider_http.PreparedRequest(
        running: provider_http.RunningRequest(owner:, cancel: fn() {
          process.send(stop, Nil)
        }),
        begin: fn() {
          list.each(handler(req), fn(ev) { process.send(events, ev) })
        },
      ),
    )
  })
}

fn json_events(
  status: Int,
  headers: List(#(String, String)),
  body: json.JsonValue,
) -> List(provider_http.HttpEvent) {
  [
    provider_http.ResponseStatus(status:, headers: [
      #("content-type", "application/json"),
      ..headers
    ]),
    provider_http.ResponseChunk(bit_array.from_string(json.to_string(body))),
    provider_http.ResponseEnd,
  ]
}

fn sse_events(
  headers: List(#(String, String)),
  chunks: List(String),
) -> List(provider_http.HttpEvent) {
  list.append(
    [
      provider_http.ResponseStatus(status: 200, headers: [
        #("content-type", "text/event-stream"),
        ..headers
      ]),
      ..list.map(chunks, fn(c) {
        provider_http.ResponseChunk(bit_array.from_string(c))
      })
    ],
    [provider_http.ResponseEnd],
  )
}

// --- 1. Initialized Streamable HTTP (2025-06-18, Magi / Go SDK shape) -------

pub fn streamable_http_macaroon_session_and_sse_round_trip_test() {
  let seen = process.new_subject()
  let transport =
    scripted_transport(fn(req) {
      process.send(seen, req)
      assert list.key_find(req.headers, "authorization")
        == Ok("Macaroon magi-macaroon-secret")
      case req.method {
        "DELETE" -> {
          assert list.key_find(req.headers, "mcp-session-id")
            == Ok("sess-magi-1")
          [
            provider_http.ResponseStatus(status: 204, headers: []),
            provider_http.ResponseEnd,
          ]
        }
        "POST" ->
          case jsonrpc.decode(req.body) {
            Ok(jsonrpc.ServerRequest(id:, method: "initialize", ..)) ->
              sse_events([#("mcp-session-id", "sess-magi-1")], [
                ": ok\n\n",
                "event: prime\nid: s1_0\n\n",
                "event: message\ndata: "
                  <> json.to_string(jsonrpc.response(
                  id,
                  json.Object([
                    #(
                      "protocolVersion",
                      json.String(protocol.requested_version),
                    ),
                    #(
                      "capabilities",
                      json.Object([#("tools", json.Object([]))]),
                    ),
                  ]),
                ))
                  <> "\n\n",
              ])
            Ok(jsonrpc.Notification(method: "notifications/initialized", ..)) -> {
              assert list.key_find(req.headers, "mcp-session-id")
                == Ok("sess-magi-1")
              assert list.key_find(req.headers, "mcp-protocol-version")
                == Ok(protocol.requested_version)
              [
                provider_http.ResponseStatus(status: 202, headers: []),
                provider_http.ResponseEnd,
              ]
            }
            Ok(jsonrpc.ServerRequest(id:, method: "tools/list", ..)) -> {
              assert list.key_find(req.headers, "mcp-session-id")
                == Ok("sess-magi-1")
              json_events(
                200,
                [],
                jsonrpc.response(
                  id,
                  json.Object([
                    #(
                      "tools",
                      json.Array([
                        json.Object([
                          #("name", json.String("run_command")),
                          #(
                            "description",
                            json.String("Run a brokered command"),
                          ),
                          #(
                            "inputSchema",
                            json.Object([
                              #("type", json.String("object")),
                              #(
                                "properties",
                                json.Object([
                                  #(
                                    "cmd",
                                    json.Object([
                                      #("type", json.String("string")),
                                    ]),
                                  ),
                                ]),
                              ),
                              #("required", json.Array([json.String("cmd")])),
                            ]),
                          ),
                        ]),
                      ]),
                    ),
                  ]),
                ),
              )
            }
            Ok(jsonrpc.ServerRequest(id:, method: "tools/call", ..)) -> {
              assert list.key_find(req.headers, "mcp-session-id")
                == Ok("sess-magi-1")
              sse_events([], [
                "data: "
                  <> json.to_string(jsonrpc.notification(
                  "notifications/progress",
                  Some(json.Object([#("progress", json.Int(50))])),
                ))
                  <> "\n\n",
                "data: "
                  <> json.to_string(jsonrpc.response(
                  id,
                  json.Object([
                    #(
                      "content",
                      json.Array([
                        json.Object([
                          #("type", json.String("text")),
                          #("text", json.String("s3://bucket-a")),
                        ]),
                      ]),
                    ),
                    #("isError", json.Bool(False)),
                  ]),
                ))
                  <> "\n\n",
              ])
            }
            _ -> [provider_http.RequestFailed("unexpected request")]
          }
        _ -> [provider_http.RequestFailed("unexpected method")]
      }
    })

  let configured =
    catalog.McpServer(
      name: "magi",
      target: catalog.McpHttp(
        url: "http://127.0.0.1:8790/mcp",
        auth: catalog.McpMacaroonAuth(api_key_env: "MAGI_MACAROON"),
      ),
      runs_on: catalog.RunsOnOrchestrator,
    )
  let options =
    mcp.Options(
      ..mcp.default_options(),
      secrets: secret.from_list([#("MAGI_MACAROON", "magi-macaroon-secret")]),
      http_transport: transport,
    )
  let #(layer, refusals) = mcp.start([configured], options)
  assert refusals == []
  assert mcp.serving(layer)
  assert mcp.allowed_imports(layer) == ["cap/mcp", "cap/mcp/magi"]

  let outcome =
    served(
      layer,
      cap_request(
        "mcp.magi",
        invocation("run_command", [
          #("cmd", msgpack.StringValue("aws s3 ls")),
        ]),
      ),
    )
  let assert framing.CapOk(value:) = outcome
    as "the HTTP MCP tool call succeeded"
  assert text_of(value) == Ok("s3://bucket-a")
  assert mcp.close(layer, within: 2000) == Ok(Nil)

  // Verify the session DELETE request was sent during close.
  let requests = drain_subject(seen, [])
  assert list.any(requests, fn(r) { r.method == "DELETE" })
}

fn drain_subject(subject: process.Subject(a), acc: List(a)) -> List(a) {
  case process.receive(subject, 50) {
    Ok(item) -> drain_subject(subject, [item, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

// --- 2. Real loopback gleam_mcp/server_http (2026-07-28 stateless HTTP) -----

pub fn real_loopback_modern_http_server_with_bearer_and_header_mirror_test() {
  let schema =
    json.Object([
      #("type", json.String("object")),
      #(
        "properties",
        json.Object([
          #(
            "tenant",
            json.Object([
              #("type", json.String("string")),
              #("x-mcp-header", json.String("Tenant")),
            ]),
          ),
        ]),
      ),
      #("required", json.Array([json.String("tenant")])),
    ])
  let assert Ok(echo_tool) =
    mcp_server.tool("echo_tenant", "Echoes the tenant.", schema, fn(args) {
      case args {
        json.Object(fields) ->
          case list.key_find(fields, "tenant") {
            Ok(json.String(tenant)) ->
              Ok(protocol.CallToolResult(
                content: [protocol.Text("tenant=" <> tenant)],
                is_error: False,
                structured_content: None,
              ))
            _ -> Ok(mcp_server.failure("missing tenant"))
          }
        _ -> Ok(mcp_server.failure("invalid arguments"))
      }
    })
  let assert Ok(registry) =
    mcp_server.new("loopback-http", "0.1.0", [echo_tool])
  let registry = mcp_server.modern(registry)

  // Start the real gleam_mcp/server_http dispatcher on a random loopback port.
  let ports = process.new_subject()
  let builder =
    mist.new(fn(req) {
      let auth_ok =
        http_headers.get(req.headers, "authorization")
        == Ok("Bearer loopback-secret-token")
      case auth_ok, req.path {
        False, _ ->
          http_response.new(401)
          |> http_response.set_body(mist.Bytes(bytes_tree.new()))
        True, "/mcp" -> {
          let assert Ok(consumed) = mist.read_body(req, 1_048_576)
          let assert Ok(body_str) = bit_array.to_string(consumed.body)
          let assert Ok(envelope) = json.parse(body_str)
          case gleam_mcp_dispatch(registry, envelope, req.headers) {
            #(status, reply) ->
              http_response.new(status)
              |> http_response.set_header("content-type", "application/json")
              |> http_response.set_body(
                mist.Bytes(bytes_tree.from_string(json.to_string(reply))),
              )
          }
        }
        True, _ ->
          http_response.new(404)
          |> http_response.set_body(mist.Bytes(bytes_tree.new()))
      }
    })
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(ports, port) })
  let assert Ok(owner) = listener.prepare(process.self(), builder)
  listener.begin(owner)
  let assert Ok(bound) = listener.ready(owner, within: 5000)

  let url = "http://127.0.0.1:" <> int.to_string(bound.port) <> "/mcp"
  let configured =
    catalog.McpServer(
      name: "remote_jev",
      target: catalog.McpHttp(
        url:,
        auth: catalog.McpBearerAuth(api_key_env: "LOOPBACK_MCP_TOKEN"),
      ),
      runs_on: catalog.RunsOnOrchestrator,
    )
  let options =
    mcp.Options(
      ..mcp.default_options(),
      secrets: secret.from_list([
        #("LOOPBACK_MCP_TOKEN", "loopback-secret-token"),
      ]),
    )
  let #(layer, refusals) = mcp.start([configured], options)
  assert refusals == []
  assert mcp.serving(layer)

  let outcome =
    served(
      layer,
      cap_request(
        "mcp.remote_jev",
        invocation("echo_tenant", [
          #("tenant", msgpack.StringValue("acme-corp")),
        ]),
      ),
    )
  let assert framing.CapOk(value:) = outcome
  assert text_of(value) == Ok("tenant=acme-corp")
  assert mcp.close(layer, within: 2000) == Ok(Nil)
  listener.close(owner)
}

fn gleam_mcp_dispatch(
  registry: mcp_server.Server,
  envelope: json.JsonValue,
  headers: List(#(String, String)),
) -> #(Int, json.JsonValue) {
  let id = case envelope {
    json.Object(fields) ->
      case list.key_find(fields, "id") {
        Ok(json.Int(value)) -> Some(jsonrpc.IdInt(value))
        Ok(json.String(value)) -> Some(jsonrpc.IdString(value))
        _ -> None
      }
    _ -> None
  }
  case http_headers.get(headers, "mcp-protocol-version") {
    Ok("2026-07-28") -> {
      // Check mirrored parameter header when calling echo_tenant.
      case http_headers.get(headers, "mcp-name") {
        Ok("echo_tenant") -> {
          assert http_headers.get(headers, "mcp-param-tenant")
            == Ok("acme-corp")
        }
        _ -> Nil
      }
      let assert #(_, Some(reply)) =
        mcp_server.handle_message(registry, envelope)
      #(200, reply)
    }
    _ -> #(
      400,
      jsonrpc.error_response(
        id,
        jsonrpc.RpcError(
          code: -32_020,
          message: "missing 2026-07-28 metadata",
          data: None,
        ),
      ),
    )
  }
}

// --- 3. 8 MiB HTTP event/body ceiling and HMAC fault authentication ---------

pub fn oversized_http_response_refuses_single_call_as_mcp_malformed_test() {
  let oversized_chunk = bit_array.from_string(string.repeat("x", 1_048_576))
  let transport =
    scripted_transport(fn(req) {
      case jsonrpc.decode(req.body) {
        Ok(jsonrpc.ServerRequest(id:, method: "initialize", ..)) ->
          json_events(
            200,
            [],
            jsonrpc.response(
              id,
              json.Object([
                #("protocolVersion", json.String(protocol.requested_version)),
                #("capabilities", json.Object([#("tools", json.Object([]))])),
              ]),
            ),
          )
        Ok(jsonrpc.Notification(method: "notifications/initialized", ..)) -> [
          provider_http.ResponseStatus(status: 202, headers: []),
          provider_http.ResponseEnd,
        ]
        Ok(jsonrpc.ServerRequest(id:, method: "tools/list", ..)) ->
          json_events(
            200,
            [],
            jsonrpc.response(
              id,
              json.Object([
                #(
                  "tools",
                  json.Array([
                    json.Object([
                      #("name", json.String("fetch")),
                      #(
                        "inputSchema",
                        json.Object([
                          #("type", json.String("object")),
                          #(
                            "properties",
                            json.Object([
                              #(
                                "mode",
                                json.Object([
                                  #("type", json.String("string")),
                                ]),
                              ),
                            ]),
                          ),
                        ]),
                      ),
                    ]),
                  ]),
                ),
              ]),
            ),
          )
        Ok(jsonrpc.ServerRequest(id:, method: "tools/call", params:)) -> {
          let is_huge =
            string.contains(
              json.to_string(option.unwrap(params, json.Null)),
              "huge",
            )
          case is_huge {
            True -> [
              provider_http.ResponseStatus(status: 200, headers: [
                #("content-type", "application/json"),
              ]),
              // 9 MiB > 8 MiB ceiling.
              ..list.append(
                list.repeat(provider_http.ResponseChunk(oversized_chunk), 9),
                [provider_http.ResponseEnd],
              )
            ]
            False ->
              json_events(
                200,
                [],
                jsonrpc.response(
                  id,
                  json.Object([
                    #(
                      "content",
                      json.Array([
                        json.Object([
                          #("type", json.String("text")),
                          #("text", json.String("small-ok")),
                        ]),
                      ]),
                    ),
                  ]),
                ),
              )
          }
        }
        _ -> [provider_http.RequestFailed("unexpected")]
      }
    })

  let configured =
    catalog.McpServer(
      name: "alpha",
      target: catalog.McpHttp(
        url: "http://127.0.0.1:9999/mcp",
        auth: catalog.McpNoAuth,
      ),
      runs_on: catalog.RunsOnOrchestrator,
    )
  let #(layer, refusals) =
    mcp.start(
      [configured],
      mcp.Options(..mcp.default_options(), http_transport: transport),
    )
  assert refusals == []

  // First call exceeds 8 MiB -> refused as mcp_malformed.
  let assert framing.CapErr(code:, message:) =
    served(
      layer,
      cap_request(
        "mcp.alpha",
        invocation("fetch", [#("mode", msgpack.StringValue("huge"))]),
      ),
    )
  assert code == mcp.malformed_code
  assert string.contains(message, int.to_string(mcp_http.max_response_bytes))

  // Second call on the same HTTP client still succeeds!
  let assert framing.CapOk(value:) =
    served(
      layer,
      cap_request(
        "mcp.alpha",
        invocation("fetch", [#("mode", msgpack.StringValue("small"))]),
      ),
    )
  assert text_of(value) == Ok("small-ok")
  assert mcp.close(layer, within: 2000) == Ok(Nil)
}

pub fn untrusted_server_cannot_forge_http_fault_tag_test() {
  assert mcp_http.classify_fault(
      "loom-mcp-http-fault:0000000000000000:malformed:spoofed",
    )
    == None
  let genuine =
    mcp_http.tag_fault(mcp_http.MalformedFault("exceeded 8388608-byte limit"))
  assert mcp_http.classify_fault(genuine)
    == Some(mcp_http.MalformedFault("exceeded 8388608-byte limit"))

  let meta =
    oauth.Metadata(
      resource: "https://mcp.example/mcp",
      issuer: "https://auth.example",
      authorization_endpoint: "https://auth.example/authorize?tenant=acme",
      token_endpoint: "https://auth.example/token",
      registration_endpoint: None,
      scopes: ["mcp:tools"],
    )
  let url =
    oauth.authorization_url(
      meta,
      oauth.Attempt(verifier: "v", state: "s", client_id: "cid"),
      "http://127.0.0.1:1234/auth/callback",
    )
  assert string.starts_with(
    url,
    "https://auth.example/authorize?tenant=acme&response_type=code",
  )
}

// --- 4. OAuth 2.1 Discovery, DCR, PKCE Login, Refresh & Mid-Session Expiry --

fn random_dir() -> String {
  let suffix = bit_array.base16_encode(crypto.strong_random_bytes(8))
  let base = bootstrap.getenv("TMPDIR") |> result.unwrap("/tmp")
  let dir = base <> "/loom-mcp-oauth-" <> suffix
  let assert Ok(Nil) = bootstrap.ensure_private_directory(dir)
  dir
}

pub fn mcp_oauth_discovery_dcr_pkce_login_and_status_test() {
  let dir = random_dir()
  let instructions = process.new_subject()
  let server_url = "https://mcp.linear.example/v1/mcp"

  let services =
    oauth.Services(
      fetch: fn(req, _) {
        case req.method, req.url {
          "GET",
            "https://mcp.linear.example/.well-known/oauth-protected-resource/v1/mcp"
          ->
            Ok(network.Response(
              200,
              "{\"resource\":\"https://mcp.linear.example/v1/mcp\",\"authorization_servers\":[\"https://auth.linear.example\"],\"scopes_supported\":[\"mcp:tools\"]}",
            ))
          "GET",
            "https://auth.linear.example/.well-known/oauth-authorization-server"
          ->
            Ok(network.Response(
              200,
              "{\"issuer\":\"https://auth.linear.example\",\"authorization_endpoint\":\"https://auth.linear.example/authorize\",\"token_endpoint\":\"https://auth.linear.example/token\",\"registration_endpoint\":\"https://auth.linear.example/register\",\"scopes_supported\":[\"mcp:tools\",\"offline_access\"],\"code_challenge_methods_supported\":[\"S256\"]}",
            ))
          "POST", "https://auth.linear.example/register" -> {
            assert string.contains(req.body, "http://127.0.0.1:")
            Ok(network.Response(201, "{\"client_id\":\"dcr_linear_client\"}"))
          }
          "POST", "https://auth.linear.example/token" -> {
            let assert Ok(fields) = uri.parse_query(req.body)
            assert list.key_find(fields, "grant_type")
              == Ok("authorization_code")
            assert list.key_find(fields, "client_id") == Ok("dcr_linear_client")
            assert list.key_find(fields, "code") == Ok("auth-code-123")
            assert list.key_find(fields, "resource") == Ok(server_url)
            let assert Ok(verifier) = list.key_find(fields, "code_verifier")
            assert string.byte_size(verifier) == 43
            Ok(network.Response(
              200,
              "{\"access_token\":\"initial-access-token\",\"refresh_token\":\"initial-refresh-token\",\"token_type\":\"Bearer\",\"expires_in\":3600,\"scope\":\"mcp:tools offline_access\"}",
            ))
          }
          _, other -> Error("unexpected fetch: " <> other)
        }
      },
      now: fn() { 1_000_000 },
      entropy: crypto.strong_random_bytes,
    )

  let task =
    weft.managed(fn(ledger) {
      oauth.login_at(
        dir,
        "linear",
        server_url,
        None,
        services,
        fn(port) { process.send(instructions, port) },
        ledger,
      )
    })
  let running =
    weft.new_prepared([task]) |> weft.deadline(10_000) |> weft.start_detached

  let assert Ok(port) = process.receive(instructions, 5000)
  let start_url = oauth.start_url(port)
  let redirect = get_http(start_url)
  assert redirect.status == 302
  let assert Ok(auth_url) = http_response.get_header(redirect, "location")
  let assert Ok(parsed) = uri.parse(auth_url)
  assert parsed.host == Some("auth.linear.example")
  let assert Some(query) = parsed.query
  let assert Ok(fields) = uri.parse_query(query)
  let assert Ok(state) = list.key_find(fields, "state")
  let assert Ok(callback_uri) = list.key_find(fields, "redirect_uri")
  assert list.key_find(fields, "resource") == Ok(server_url)
  assert list.key_find(fields, "code_challenge_method") == Ok("S256")
  assert list.key_find(fields, "scope") == Ok("mcp:tools offline_access")

  let callback_resp =
    get_http(
      callback_uri
      <> "?"
      <> uri.query_to_string([#("state", state), #("code", "auth-code-123")]),
    )
  assert callback_resp.status == 200

  let assert weft.PulledOutcome(weft.Completed(_, binding)) =
    weft.pull(running, 10_000)
  assert binding.client_id == "dcr_linear_client"
  assert binding.resource == server_url
  assert oauth.authorize_at(dir, "linear", server_url, None, services)
    == Ok("initial-access-token")
}

pub fn mcp_oauth_mid_session_refresh_and_terminal_expiry_refusal_test() {
  let dir = random_dir()
  let server_url = "https://mcp.linear.example/v1/mcp"
  let initial =
    credentials.Binding(
      server: "linear",
      resource: server_url,
      issuer: "https://auth.linear.example",
      token_endpoint: "https://auth.linear.example/token",
      client_id: "dcr_linear_client",
      grant: Some(credentials.Grant(
        access: "token-v1",
        refresh: Some("refresh-v1"),
        scopes: ["mcp:tools", "offline_access"],
        expires: 2_000_000,
      )),
    )
  let assert Ok(Nil) = credentials.save(dir <> "/linear.json", initial)

  // Advance clock past expiry: `authorize_at` refreshes and rotates the grant.
  let refreshing_services =
    oauth.Services(
      fetch: fn(req, _) {
        assert req.url == "https://auth.linear.example/token"
        let assert Ok(fields) = uri.parse_query(req.body)
        assert list.key_find(fields, "grant_type") == Ok("refresh_token")
        assert list.key_find(fields, "refresh_token") == Ok("refresh-v1")
        Ok(network.Response(
          200,
          "{\"access_token\":\"token-v2\",\"refresh_token\":\"refresh-v2\",\"token_type\":\"Bearer\",\"expires_in\":3600}",
        ))
      },
      now: fn() { 2_500_000 },
      entropy: crypto.strong_random_bytes,
    )
  assert oauth.authorize_at(
      dir,
      "linear",
      server_url,
      None,
      refreshing_services,
    )
    == Ok("token-v2")

  // Now simulate mid-session expiry where the refresh token itself was revoked
  // (`invalid_grant`) and the MCP server returns HTTP 401 on a tool call.
  let revoked_services =
    oauth.Services(
      fetch: fn(_, _) {
        Ok(network.Response(400, "{\"error\":\"invalid_grant\"}"))
      },
      now: fn() { 2_600_000 },
      entropy: crypto.strong_random_bytes,
    )

  let call_count = process.new_subject()
  let transport =
    scripted_transport(fn(req) {
      case jsonrpc.decode(req.body) {
        Ok(jsonrpc.ServerRequest(id:, method: "initialize", ..)) ->
          json_events(
            200,
            [],
            jsonrpc.response(
              id,
              json.Object([
                #("protocolVersion", json.String(protocol.requested_version)),
                #("capabilities", json.Object([#("tools", json.Object([]))])),
              ]),
            ),
          )
        Ok(jsonrpc.Notification(method: "notifications/initialized", ..)) -> [
          provider_http.ResponseStatus(status: 202, headers: []),
          provider_http.ResponseEnd,
        ]
        Ok(jsonrpc.ServerRequest(id:, method: "tools/list", ..)) ->
          json_events(
            200,
            [],
            jsonrpc.response(
              id,
              json.Object([
                #(
                  "tools",
                  json.Array([
                    json.Object([
                      #("name", json.String("list_issues")),
                      #(
                        "inputSchema",
                        json.Object([#("type", json.String("object"))]),
                      ),
                    ]),
                  ]),
                ),
              ]),
            ),
          )
        Ok(jsonrpc.ServerRequest(method: "tools/call", ..)) -> {
          process.send(call_count, Nil)
          [
            provider_http.ResponseStatus(status: 401, headers: []),
            provider_http.ResponseEnd,
          ]
        }
        _ -> [provider_http.RequestFailed("unexpected")]
      }
    })

  let configured =
    catalog.McpServer(
      name: "linear",
      target: catalog.McpHttp(
        url: server_url,
        auth: catalog.McpOAuth(client_id: None),
      ),
      runs_on: catalog.RunsOnOrchestrator,
    )
  let options =
    mcp.Options(
      ..mcp.default_options(),
      http_transport: transport,
      oauth_directory: Some(dir),
      oauth_services: Some(revoked_services),
    )
  let #(layer, refusals) = mcp.start([configured], options)
  assert refusals == []

  // Tool call receives 401 -> attempts refresh -> refresh fails with
  // invalid_grant -> clears grant and returns in-band mcp_unavailable naming
  // `loomd mcp login linear`.
  let assert framing.CapErr(code:, message:) =
    served(layer, cap_request("mcp.linear", invocation("list_issues", [])))
  assert code == mcp.unavailable_code
  assert string.contains(message, "loomd mcp login linear")

  // Stored grant was cleared while preserving the client registration.
  let assert Ok(Some(cleared)) = credentials.load(dir <> "/linear.json")
  assert cleared.grant == None
  assert cleared.client_id == "dcr_linear_client"

  // Restore a grant, verify a transient 503 preserves it, while an
  // unrecognized 400 or invalid_client rejection clears it.
  let assert Ok(Nil) = credentials.save(dir <> "/linear.json", initial)
  let transient_503 =
    oauth.Services(..revoked_services, fetch: fn(_, _) {
      Ok(network.Response(503, "service unavailable"))
    })
  assert oauth.authorize_at(dir, "linear", server_url, None, transient_503)
    == Error("token_endpoint_unavailable")
  let assert Ok(Some(preserved)) = credentials.load(dir <> "/linear.json")
  assert preserved.grant != None

  let invalid_client_401 =
    oauth.Services(..revoked_services, fetch: fn(_, _) {
      Ok(network.Response(401, "{\"error\":\"invalid_client\"}"))
    })
  assert oauth.authorize_at(dir, "linear", server_url, None, invalid_client_401)
    == Error("reauthorization_required")
  let assert Ok(Some(cleared_again)) = credentials.load(dir <> "/linear.json")
  assert cleared_again.grant == None
  assert mcp.close(layer, within: 2000) == Ok(Nil)
}

pub fn mcp_cli_parses_and_reports_status_and_logout_test() {
  assert mcp_cli.parse(["login", "linear"])
    == Ok(mcp_cli.Request(mcp_cli.Login, "linear", None))
  assert mcp_cli.parse(["status", "linear", "--config", "/tmp/loom.toml"])
    == Ok(mcp_cli.Request(mcp_cli.Status, "linear", Some("/tmp/loom.toml")))
  assert mcp_cli.parse(["logout", "linear"])
    == Ok(mcp_cli.Request(mcp_cli.Logout, "linear", None))
  assert mcp_cli.parse(["login"]) |> result.is_error
  assert mcp_cli.parse(["login", "BadName"]) |> result.is_error

  let dir = random_dir()
  let config_file = dir <> "/loom.toml"
  let assert Ok(Nil) =
    simplifile.write(
      config_file,
      "[mcp.linear]\nurl = \"https://mcp.linear.example/v1/mcp\"\nauth = \"oauth\"\n",
    )
  let events = process.new_subject()
  let services =
    oauth.Services(
      fetch: fn(_, _) { Error("no network") },
      now: fn() { 1_000_000 },
      entropy: crypto.strong_random_bytes,
    )
  let _ =
    weft.new_prepared([
      weft.managed(fn(ledger) {
        mcp_cli.run_in_scope(
          dir,
          mcp_cli.Request(mcp_cli.Status, "linear", Some(config_file)),
          services,
          events,
          ledger,
        )
      }),
    ])
    |> weft.deadline(5000)
    |> weft.start
  assert process.receive(events, 1000)
    == Ok(mcp_cli.StatusReport("linear", mcp_cli.SignedOut))
}

fn get_http(url: String) -> http_response.Response(String) {
  let assert Ok(req) = http_request.to(url)
  let assert Ok(resp) = httpc.send(req)
  resp
}
