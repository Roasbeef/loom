//// The MCP layer's router arm: what a `mcp.<server>` capability call
//// turns into on the way out, and what a server's answer turns into on
//// the way back.
////
//// Every test here drives a *real* `mcp/client` actor over the real
//// `ChannelTransport` seam, so the whole round trip — argument
//// translation, framing, JSON-RPC correlation, result decoding, result
//// translation — runs exactly as it does against a spawned server. What
//// is faked is the server, and only the server.
////
//// The last section is about `client/codemode` rather than this module:
//// what a configured server does to the seam a model is offered. It
//// lives here because the layer fixture does, and a layer needs a
//// started client.

import broker/broker
import broker/budget
import broker/exec
import broker/framing
import broker/policy
import client/codemode
import client/mcp
import codemode/identity
import codemode/satellite
import codemode/vet/policy as vet_policy
import core/clock
import core/ids
import core/json
import core/msgpack
import gleam/int
import gleam/list
import gleam/option
import gleam/string
import mcp/client as mcp_client
import mcp/codegen
import mcp/protocol
import support/fake_mcp

const t = 1_700_000_000_000

// --- fixtures --------------------------------------------------------------

fn started_client(
  tools: List(json.JsonValue),
  call: fn(String, json.JsonValue) -> fake_mcp.Answer,
) -> mcp_client.Client {
  let assert Ok(client) =
    mcp_client.start(
      fake_mcp.seam(tools: tools, call: call),
      mcp_client.options("test"),
    )
    as "the fake server completes the handshake"
  client
}

// A layer of one server named `alpha`, answering every call through
// `call`. The generated module is a stub: the router keys on the
// server's *name*, and what a façade compiles to is `mcp/codegen`'s
// business, proven there.
fn layer_of(call: fn(String, json.JsonValue) -> fake_mcp.Answer) -> mcp.Layer {
  mcp.Layer(
    servers: [
      mcp.Server(
        name: "alpha",
        client: started_client([fake_mcp.tool("search", ["query"])], call),
        generated: codegen.Generated(
          module_name: "cap/mcp/alpha",
          source: "// alpha\n",
          surface: "### cap/mcp/alpha\n",
        ),
        tools: 1,
      ),
    ],
    call_timeout_ms: 5000,
  )
}

fn always(
  answer: fake_mcp.Answer,
) -> fn(String, json.JsonValue) -> fake_mcp.Answer {
  fn(_name, _arguments) { answer }
}

fn op_id() -> ids.OpId {
  let #(op, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: t), seed: 5))
  op
}

fn request(cap: String, args: msgpack.MsgPackValue) -> satellite.CapRequest {
  satellite.CapRequest(
    cap:,
    args:,
    identity: identity.for_execution(
      op_id: op_id(),
      step_id: "step-1",
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

// The frame `cap/internal/mcp.invoke` builds: `{tool, arguments}`.
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

// A router beneath the arm that answers nothing, so a call reaching it
// is visible as its own value rather than as a `proc.run` dispatch.
fn beneath(
  request: satellite.CapRequest,
) -> Result(satellite.CapPlan, satellite.CapDenial) {
  Error(satellite.CapDenial(code: "delegated", message: request.cap))
}

fn served(
  layer: mcp.Layer,
  request: satellite.CapRequest,
) -> framing.CapOutcome {
  let assert Ok(satellite.ServedHere(serve:)) =
    mcp.routing(layer, over: beneath)(request)
    as "an mcp call plans as ServedHere"
  serve()
}

// --- the arm picks its own calls and no others ------------------------------

pub fn a_capability_outside_the_prefix_is_delegated_test() {
  let layer =
    layer_of(always(fake_mcp.Answers(fake_mcp.text_result("x", False))))
  let router = mcp.routing(layer, over: beneath)
  // The delegation is visible: the router beneath answers with the cap
  // name it was handed.
  assert router(request("proc.run", msgpack.MapValue([])))
    == Error(satellite.CapDenial(code: "delegated", message: "proc.run"))
  // A capability that merely *contains* the prefix is not one of ours.
  assert router(request("proc.mcp.run", msgpack.MapValue([])))
    == Error(satellite.CapDenial(code: "delegated", message: "proc.mcp.run"))
  mcp.stop(layer)
}

pub fn an_unconfigured_server_is_unsupported_test() {
  let layer =
    layer_of(always(fake_mcp.Answers(fake_mcp.text_result("x", False))))
  let assert Error(denial) =
    mcp.routing(layer, over: beneath)(request(
      "mcp.beta",
      invocation("search", []),
    ))
    as "no server named beta is configured"
  assert denial.code == mcp.unsupported_cap_code
  assert string.contains(denial.message, "beta")
  mcp.stop(layer)
}

// --- out: arguments ---------------------------------------------------------

pub fn the_tool_name_and_arguments_reach_the_server_test() {
  // The fake echoes back what it was called with, so the assertion is on
  // what actually crossed rather than on what was intended.
  let layer =
    layer_of(fn(name, arguments) {
      fake_mcp.Answers(fake_mcp.text_result(
        name <> " " <> json.to_string(arguments),
        False,
      ))
    })
  let outcome =
    served(
      layer,
      request(
        "mcp.alpha",
        invocation("search", [
          #("query", msgpack.StringValue("loom")),
          #("limit", msgpack.IntValue(3)),
        ]),
      ),
    )
  let assert framing.CapOk(value:) = outcome as "the call succeeded"
  assert text_of(value) == Ok("search {\"query\":\"loom\",\"limit\":3}")
  mcp.stop(layer)
}

pub fn an_argument_that_does_not_cross_is_refused_before_the_call_test() {
  let layer =
    layer_of(always(fake_mcp.Answers(fake_mcp.text_result("x", False))))
  let assert Error(denial) =
    mcp.routing(layer, over: beneath)(request(
      "mcp.alpha",
      invocation("search", [#("blob", msgpack.BinaryValue(<<1, 2>>))]),
    ))
    as "a byte string has no JSON to become"
  assert denial.code == mcp.invalid_argument_code
  assert string.contains(denial.message, "byte string")
  mcp.stop(layer)
}

pub fn a_frame_without_a_tool_is_refused_test() {
  let layer =
    layer_of(always(fake_mcp.Answers(fake_mcp.text_result("x", False))))
  let assert Error(denial) =
    mcp.routing(layer, over: beneath)(request(
      "mcp.alpha",
      msgpack.MapValue([
        #(msgpack.StringValue("arguments"), msgpack.MapValue([])),
      ]),
    ))
    as "the frame carries no tool name"
  assert denial.code == mcp.invalid_argument_code
  mcp.stop(layer)
}

// --- back: results ----------------------------------------------------------

pub fn a_text_result_crosses_back_test() {
  let layer =
    layer_of(always(fake_mcp.Answers(fake_mcp.text_result("found it", False))))
  let assert framing.CapOk(value:) =
    served(layer, request("mcp.alpha", invocation("search", [])))
    as "the call succeeded"
  assert text_of(value) == Ok("found it")
  assert field(value, "is_error") == Ok(msgpack.BoolValue(False))
  // Absent rather than nil: `cap/internal/mcp` reads a missing
  // `structured` as `None`, and writing one would be a claim the server
  // never made.
  assert field(value, "structured") == Error(Nil)
  mcp.stop(layer)
}

pub fn a_tool_level_failure_crosses_back_as_is_error_test() {
  // `isError` is a *tool* verdict, not a transport failure: the call
  // succeeded and the flag is what `cap/internal/mcp` turns into
  // `ToolFailed`.
  let layer =
    layer_of(
      always(fake_mcp.Answers(fake_mcp.text_result("no such repo", True))),
    )
  let assert framing.CapOk(value:) =
    served(layer, request("mcp.alpha", invocation("search", [])))
    as "a tool-level failure is still a settled call"
  assert field(value, "is_error") == Ok(msgpack.BoolValue(True))
  assert text_of(value) == Ok("no such repo")
  mcp.stop(layer)
}

pub fn structured_content_crosses_back_test() {
  let layer =
    layer_of(
      always(
        fake_mcp.Answers(
          json.Object([
            #("content", json.Array([])),
            #("isError", json.Bool(False)),
            #(
              "structuredContent",
              json.Object([
                #("count", json.Int(2)),
                #("names", json.Array([json.String("a"), json.String("b")])),
              ]),
            ),
          ]),
        ),
      ),
    )
  let assert framing.CapOk(value:) =
    served(layer, request("mcp.alpha", invocation("search", [])))
    as "the call succeeded"
  assert field(value, "structured")
    == Ok(
      msgpack.MapValue([
        #(msgpack.StringValue("count"), msgpack.IntValue(2)),
        #(
          msgpack.StringValue("names"),
          msgpack.ArrayValue([
            msgpack.StringValue("a"),
            msgpack.StringValue("b"),
          ]),
        ),
      ]),
    )
  mcp.stop(layer)
}

pub fn a_non_text_block_keeps_its_kind_test() {
  let layer =
    layer_of(
      always(
        fake_mcp.Answers(
          json.Object([
            #(
              "content",
              json.Array([
                json.Object([#("type", json.String("image"))]),
                json.Object([
                  #("type", json.String("text")),
                  #("text", json.String("caption")),
                ]),
              ]),
            ),
          ]),
        ),
      ),
    )
  let assert framing.CapOk(value:) =
    served(layer, request("mcp.alpha", invocation("search", [])))
    as "the call succeeded"
  let assert Ok(msgpack.ArrayValue(blocks)) = field(value, "content")
    as "content is an array"
  assert list.length(blocks) == 2
  let assert [image, ..] = blocks as "the image block came first"
  assert field(image, "type") == Ok(msgpack.StringValue("image"))
  assert field(image, "text") == Error(Nil)
  mcp.stop(layer)
}

pub fn a_structured_value_that_does_not_cross_fails_the_result_test() {
  // An integer past msgpack's range is refused whole rather than
  // wrapped: `mcp/interchange` argues why.
  let layer =
    layer_of(
      always(
        fake_mcp.Answers(
          json.Object([
            #("content", json.Array([])),
            #(
              "structuredContent",
              json.Object([
                #("count", json.Int(18_446_744_073_709_551_616)),
              ]),
            ),
          ]),
        ),
      ),
    )
  let assert framing.CapErr(code:, message:) =
    served(layer, request("mcp.alpha", invocation("search", [])))
    as "the result cannot cross"
  assert code == mcp.malformed_code
  assert string.contains(message, "outside msgpack's range")
  mcp.stop(layer)
}

// --- one hostile answer costs one call, not the channel ---------------------

// The deepest structured value one `cap_result` frame can carry: the
// msgpack decoder's own ceiling, less the two containers of the frame
// envelope (`{v, id, kind, body}` holding `{ok, value}`) and the one of
// the result map the value sits in.
const deepest_carriable = 253

// Both depths below survive `core/json.parse` on the way in — a JSON-RPC
// response costs two levels before `structuredContent`, and 254 + 2 is
// the parser's own ceiling — which is the whole point: what a server can
// legally *say* is deeper than what this wire can legally carry.
pub fn a_result_too_deep_for_one_frame_is_refused_test() {
  let layer = layer_of(always(fake_mcp.Answers(nested(deepest_carriable + 1))))
  let assert framing.CapErr(code:, message:) =
    served(layer, request("mcp.alpha", invocation("search", [])))
    as "a result the satellite could not decode is refused, not sent"
  assert code == mcp.malformed_code
  assert string.contains(message, "nests deeper")
  mcp.stop(layer)
}

pub fn a_result_at_the_frame_depth_limit_still_crosses_test() {
  let layer = layer_of(always(fake_mcp.Answers(nested(deepest_carriable))))
  let assert framing.CapOk(value: _) =
    served(layer, request("mcp.alpha", invocation("search", [])))
    as "the deepest carriable answer is carried"
  mcp.stop(layer)
}

// The size half. Driven through `tool_result` directly because the ways
// in are all bounded below the ceiling: a fake server's line has to
// survive `mcp/stdio`'s own 16 MiB cap, and it is the *re-encoding* that
// grows past the frame cap.
pub fn a_result_too_large_for_one_frame_is_refused_test() {
  let assert framing.CapErr(code:, message:) =
    mcp.tool_result(protocol.CallToolResult(
      content: [protocol.Text(text: grown("loom", mcp.max_result_bytes()))],
      is_error: False,
      structured_content: option.None,
    ))
    as "a result past the frame cap is refused rather than dropped unsent"
  assert code == mcp.malformed_code
  assert string.contains(message, int.to_string(mcp.max_result_bytes()))
}

pub fn the_frame_margin_leaves_room_for_the_envelope_test() {
  assert mcp.max_result_bytes() < framing.max_frame_bytes
}

// A structured answer nested `depth` containers deep.
fn nested(depth: Int) -> json.JsonValue {
  json.Object([
    #("content", json.Array([])),
    #("structuredContent", chain(depth)),
  ])
}

fn chain(depth: Int) -> json.JsonValue {
  case depth <= 0 {
    True -> json.Int(1)
    False -> json.Array([chain(depth - 1)])
  }
}

// A string of at least `bytes` bytes, grown by doubling: a per-grapheme
// repeat of sixteen million would build a list that long first.
fn grown(seed: String, bytes: Int) -> String {
  case string.byte_size(seed) >= bytes {
    True -> seed
    False -> grown(seed <> seed, bytes)
  }
}

// --- the denial codes -------------------------------------------------------

// The vocabulary a program reads through `cap/mcp.McpDenied`. Pinned
// here because it is a contract with the far side of the cap wire: a
// code nothing decodes reaches a program as an unnamed refusal.
pub fn the_denial_codes_are_pinned_test() {
  assert mcp.unavailable_code == "mcp_unavailable"
  assert mcp.timeout_code == "mcp_timeout"
  assert mcp.malformed_code == "mcp_malformed"
  assert mcp.server_error_prefix == "jsonrpc_"
  assert mcp.unsupported_cap_code == "unsupported_cap"
  assert mcp.invalid_argument_code == "invalid_argument"
  assert mcp.cap_prefix == "mcp."
}

pub fn the_mcp_call_timeout_wins_the_race_test() {
  // The MCP bound must be the one that fires. A `ServedHere` call the
  // satellite host gives up on is *dropped*, so if the host's bound came
  // first a program that asked a server a question would get silence
  // where the seam promises it `mcp_timeout`.
  assert mcp.default_call_timeout_ms < codemode.default_call_timeout_ms
}

pub fn a_jsonrpc_error_carries_its_own_code_test() {
  let layer =
    layer_of(always(fake_mcp.Fails(code: -32_601, message: "no such tool")))
  let assert framing.CapErr(code:, message:) =
    served(layer, request("mcp.alpha", invocation("search", [])))
    as "the server answered an error"
  // The integer goes into the string: `jsonrpc_-32601`, not a category.
  assert code == mcp.server_error_prefix <> "-32601"
  assert message == "no such tool"
  mcp.stop(layer)
}

pub fn a_dead_server_is_unavailable_test() {
  let layer =
    layer_of(always(fake_mcp.Answers(fake_mcp.text_result("x", False))))
  // Stopping the client is what a dead server looks like from here: the
  // actor settles every later call in band rather than dying.
  mcp.stop(layer)
  let assert framing.CapErr(code:, message: _) =
    served(layer, request("mcp.alpha", invocation("search", [])))
    as "a stopped client refuses in band"
  assert code == mcp.unavailable_code
}

// --- what the layer publishes ----------------------------------------------

pub fn an_empty_layer_widens_nothing_test() {
  assert mcp.allowed_imports(mcp.none()) == []
  assert mcp.surfaces(mcp.none()) == []
  assert mcp.generated(mcp.none()) == []
  assert mcp.serviced_caps(mcp.none()) == []
  assert mcp.listings(mcp.none()) == []
  assert !mcp.serving(mcp.none())
}

pub fn a_served_layer_publishes_its_server_test() {
  let layer =
    layer_of(always(fake_mcp.Answers(fake_mcp.text_result("x", False))))
  assert mcp.serving(layer)
  // The vocabulary module comes first, then one module per server: a
  // façade imports `cap/mcp`, so allowing one without the other would
  // admit a program the compiler then refuses.
  assert mcp.allowed_imports(layer) == ["cap/mcp", "cap/mcp/alpha"]
  assert mcp.surfaces(layer) == ["### cap/mcp/alpha\n"]
  assert mcp.generated(layer) == [#("cap/mcp/alpha", "// alpha\n")]
  assert mcp.serviced_caps(layer) == ["mcp.alpha"]
  assert mcp.listings(layer) == [#("alpha", 1)]
  mcp.stop(layer)
}

// --- the digest -------------------------------------------------------------

pub fn the_digest_is_bare_lowercase_hex_test() {
  let hex = mcp.sha256_hex("github")
  // Sixty-four lowercase hex characters and no `sha256-` label: the
  // mangler slices the first eight, and a label would make every
  // renamed identifier's suffix identical.
  assert string.length(hex) == 64
  assert !string.contains(hex, "sha256")
  assert string.lowercase(hex) == hex
  assert mcp.sha256_hex("github") != mcp.sha256_hex("gitlab")
}

// --- reading a result -------------------------------------------------------

fn field(
  value: msgpack.MsgPackValue,
  key: String,
) -> Result(msgpack.MsgPackValue, Nil) {
  case value {
    msgpack.MapValue(entries:) ->
      list.find_map(entries, fn(entry) {
        case entry.0 == msgpack.StringValue(key) {
          True -> Ok(entry.1)
          False -> Error(Nil)
        }
      })
    _other -> Error(Nil)
  }
}

// The joined text of a result's content, the way `cap/mcp.text` reads it.
fn text_of(value: msgpack.MsgPackValue) -> Result(String, Nil) {
  case field(value, "content") {
    Ok(msgpack.ArrayValue(blocks)) ->
      Ok(
        blocks
        |> list.filter_map(fn(block) {
          case field(block, "text") {
            Ok(msgpack.StringValue(text)) -> Ok(text)
            _other -> Error(Nil)
          }
        })
        |> string.join("\n"),
      )
    _other -> Error(Nil)
  }
}

// --- what a layer does to the seam a model is offered -----------------------

fn idle_broker() -> broker.Broker {
  let assert Ok(started) =
    broker.start(
      broker.BrokerConfig(
        entropy: fn(bytes) { <<0:size(bytes)-unit(8)>> },
        clock: clock.fixed(at: t),
        checkout: fn() { Error(exec.AllBusy(size: 0)) },
        checkin: fn(_helper) { Nil },
      ),
    )
    as "the broker must start"
  started
}

// The host configuration a layer produces, and the broker behind it, so
// the caller can stop what it started — the cleanup discipline every
// `mcp.stop(layer)` above already follows.
fn host(broker_actor: broker.Broker, layer: mcp.Layer) -> codemode.Config {
  codemode.default_config(
    broker: broker_actor,
    clock: clock.fixed(at: t),
    workspace: "/work",
    toolchain: codemode.Toolchain(
      gleam_path: "/opt/gleam/bin/gleam",
      erl_path: "/usr/lib/erlang/bin/erl",
      seed_root: "/opt/loom/codemode-seed",
    ),
  )
  |> codemode.over_mcp(layer)
}

pub fn a_configured_server_widens_the_workspace_allowlist_test() {
  let layer =
    layer_of(always(fake_mcp.Answers(fake_mcp.text_result("x", False))))
  let broker_actor = idle_broker()
  let allowed =
    vet_policy.allowed_imports(codemode.seam_allowlist(
      host(broker_actor, layer),
      vet_policy.WorkspaceSeam,
    ))
  // The façade and the vocabulary it imports, both of which are on no
  // static seam (`vet_policy.harness_only_cap_modules`).
  assert list.contains(allowed, "cap/mcp/alpha")
  assert list.contains(allowed, "cap/mcp")
  // Nothing the seam already allowed has gone.
  assert list.contains(allowed, "cap/proc")
  broker.stop(broker_actor)
  mcp.stop(layer)
}

pub fn the_orchestration_seam_is_widened_by_nothing_test() {
  let layer =
    layer_of(always(fake_mcp.Answers(fake_mcp.text_result("x", False))))
  let broker_actor = idle_broker()
  let config = host(broker_actor, layer)
  let allowed =
    vet_policy.allowed_imports(codemode.seam_allowlist(
      config,
      vet_policy.OrchestrationSeam,
    ))
  // Which capabilities travel together is the whole of what the split
  // buys: an orchestrator that could also reach a third-party server is
  // a materially worse thing to hand a model.
  assert !list.contains(allowed, "cap/mcp/alpha")
  assert !list.contains(allowed, "cap/mcp")
  assert codemode.seam_caps_on(config, vet_policy.OrchestrationSeam)
    == codemode.seam_caps(vet_policy.OrchestrationSeam)
  broker.stop(broker_actor)
  mcp.stop(layer)
}

pub fn a_configured_server_is_named_in_what_the_seam_services_test() {
  let layer =
    layer_of(always(fake_mcp.Answers(fake_mcp.text_result("x", False))))
  let broker_actor = idle_broker()
  let config = host(broker_actor, layer)
  // The server's name lands *after* the seam's own capabilities, so a
  // configured server widens the list rather than reordering it.
  assert codemode.seam_caps_on(config, vet_policy.WorkspaceSeam)
    == list.append(codemode.seam_caps(vet_policy.WorkspaceSeam), [
      "mcp.alpha",
    ])
  broker.stop(broker_actor)
  mcp.stop(layer)
}

pub fn a_host_with_no_servers_offers_exactly_what_it_did_before_test() {
  let broker_actor = idle_broker()
  let config = host(broker_actor, mcp.none())
  assert vet_policy.allowed_imports(codemode.seam_allowlist(
      config,
      vet_policy.WorkspaceSeam,
    ))
    == vet_policy.allowed_imports(codemode.seam_policy(vet_policy.WorkspaceSeam))
  assert codemode.seam_caps_on(config, vet_policy.WorkspaceSeam)
    == codemode.seam_caps(vet_policy.WorkspaceSeam)
  broker.stop(broker_actor)
}
