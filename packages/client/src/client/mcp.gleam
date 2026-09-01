//// The MCP layer: the configured servers this host actually reached,
//// what they let a code-mode program import, and the router arm that
//// carries a `mcp.<server>` capability call out to one of them.
////
//// This is the harness wiring `packages/mcp` deliberately does not do
//// (issue #106). That package holds the protocol, the client actor and
//// the generator; `client/catalog` holds the `[mcp.<name>]` tables. Here
//// the two meet: for every configured server, spawn it, hand-shake,
//// list its tools, generate the `cap/mcp/<server>` façade module, and
//// keep the client running for the life of the session, because the
//// dispatch path is the same client.
////
//// ## MCP reaches a model through code mode, and nowhere else
////
//// Nothing here registers a tool. A server's tools are a *module* a
//// program may import — `import cap/mcp/github` — which is what makes
//// the cost of a 300-tool server the same as a 3-tool one: the model
//// reads a rendered module surface it was going to pay for anyway
//// rather than 300 tool schemas in the cached prefix of every request.
//// It is also what makes trust per server: the vetting allowlist names
//// one module per server, so a program that imported `cap/mcp/github`
//// has been handed that server and no other, visibly, in its first few
//// lines.
////
//// ## What a per-server failure does, and does not, do
////
//// Every step of a server's boot is a place a third party can fail:
//// the executable is missing, the handshake times out, the negotiated
//// revision is one this client will not speak, `tools/list` is hostile
//// or enormous, two tool names collide after renaming. Each of those
//// refuses **that server** — one `mcp.unavailable` log line naming the
//// server and the reason, the same shape `codemode.unavailable` uses —
//// and the boot continues without it. The reason is not decoration: a
//// refused server has no module, so a program importing it is rejected
//// by vetting with no explanation of why the module is absent, and this
//// line is the only place an operator will ever see the cause.
////
//// ## Secrets are read at spawn and never held
////
//// A `[mcp.<name>]` table names an environment *variable*
//// (`api_key_env`), never a key. The value is read from the harness's
//// own environment at spawn, put into the child's environment under the
//// same name, and never stored in a record, a log line, or a refusal
//// message. A configured variable that is unset refuses that server
//// before anything is spawned: starting a server without the key it was
//// configured with fails later, further away, and in the server's own
//// words.
////
//// ## The client actor is not linked to the server
////
//// `mcp/client.start` links its actor to whoever calls it, and this
//// boot runs on the host process every fatal child is linked to. An MCP
//// server is third-party code and its client actor is driven by that
//// server's bytes, so the actors are started from a throwaway unlinked
//// process instead: the starter exits normally the moment it has the
//// handle, and a normal exit is not a signal any linked process acts
//// on, so what is left is an actor no link reaches. The handle in the
//// `Layer` is the only way to stop it, which `shutdown` does.
////
//// That is also why the boot's own wait has a watcher between it and
//// the starter. A start that lands after the boot has given up would
//// otherwise hand its client to nobody — an actor and a server process
//// with no handle anywhere, alive for the life of the VM — so the
//// watcher holds the reply subject, answers the boot inside the window,
//// and stops a late arrival itself.

import broker/framing.{type CapOutcome}
import client/catalog
import codemode/satellite.{
  type CapDenial, type CapPlan, type CapRequest, type CapRouter, CapDenial,
  ServedHere,
}
import core/json.{type JsonValue}
import core/msgpack.{type MsgPackValue}
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mcp/client as mcp_client
import mcp/codegen
import mcp/interchange
import mcp/protocol
import mcp/transport
import provider/secret.{type SecretStore}
import tools/blob

/// The capability-name prefix every MCP call arrives under. The suffix
/// is the configured server's name, which is also its module's last
/// segment (`cap/internal/mcp.invoke` builds `"mcp." <> server`).
pub const cap_prefix = "mcp."

/// The types-only vocabulary module every generated façade imports. A
/// host with at least one reachable server allows it on the workspace
/// seam; a host with none allows neither it nor any façade.
pub const vocabulary_module = "cap/mcp"

/// The in-band code for a server that is not running or whose client
/// has gone. A server this host never configured is refused earlier, at
/// plan time, as `unsupported_cap`. The cap side reads this code back
/// into its own `ServerUnavailable` variant.
pub const unavailable_code = "mcp_unavailable"

/// The in-band code for a `tools/call` that did not settle in time.
pub const timeout_code = "mcp_timeout"

/// The in-band code for a server answer that was not the shape the
/// method promises, or that carries a value this wire cannot represent.
pub const malformed_code = "mcp_malformed"

/// The prefix a JSON-RPC error's own code travels under, so a server
/// error reaches the program as itself rather than as a category: a
/// `-32601` becomes `jsonrpc_-32601`. The integer goes into the string
/// deliberately — the code vocabulary is strings all the way to
/// `cap/mcp.McpDenied`, and folding every server error onto one name
/// would throw away the one fact a program could branch on.
pub const server_error_prefix = "jsonrpc_"

/// The in-band code a capability no router services comes back under —
/// `satellite.default_router`'s own, reused here so a `mcp.<server>`
/// naming a server this host never configured is refused exactly as any
/// other unrouted capability is.
pub const unsupported_cap_code = "unsupported_cap"

/// The in-band code for a call whose arguments this seam could not
/// carry: the vocabulary `satellite.default_router` already uses for a
/// call it can read but not serve as given.
pub const invalid_argument_code = "invalid_argument"

/// How long one server's whole `tools/list` may take at boot.
pub const default_list_timeout_ms = 30_000

/// How long one `tools/call` may take before the program is answered
/// `mcp_timeout`.
///
/// Below the satellite host's own `call_timeout_ms` (120 s) on purpose:
/// a `ServedHere` call the host gives up on is answered `unsettled` and
/// its worker killed, and a program that asked an MCP server a question
/// deserves `mcp_timeout` — the refusal naming what happened — rather
/// than a generic one over a call cut off mid-flight. It is a constant
/// rather than a share of the execution's
/// deadline because a `CapRequest` carries an absolute deadline and no
/// clock to read it against; the execution's own deadline still bounds
/// the whole program from outside, and the node dies with it.
pub const default_call_timeout_ms = 60_000

/// One server this host reached: the client that owns its process, the
/// module generated from its tool listing, and how many tools that
/// listing held.
///
/// Constructor invariants: `name` is the catalogue key, which is also
/// the `mcp.<name>` capability suffix and the module's last segment;
/// `client` is started and handshaken; `generated.module_name` is
/// `cap/mcp/<name>`.
pub type Server {
  Server(
    name: String,
    client: mcp_client.Client,
    generated: codegen.Generated,
    tools: Int,
  )
}

/// Why one configured server is not in the layer. `server` is the
/// catalogue key and `reason` is worded for an operator's log line; no
/// secret ever reaches either.
pub type Refusal {
  Refusal(server: String, reason: String)
}

/// The servers this host reached, in catalogue order, and how long one
/// `tools/call` to any of them may take.
///
/// The timeout rides the layer rather than reaching the router
/// separately because it is settled once, at boot, by the same options
/// that started the servers: a dispatch path that had to be told again
/// is a dispatch path that could be told something else.
///
/// `none()` is the empty layer, and it is what every host has until an
/// operator configures a server: it allows no module, generates no
/// source, renders no surface, and routes nothing.
pub type Layer {
  Layer(servers: List(Server), call_timeout_ms: Int)
}

/// Everything `start` needs beyond the configured servers.
///
/// Constructor invariants: `secrets` is the env-lookup seam
/// `api_key_env` is resolved against; `digest` is lowercase hex over the
/// input's UTF-8 bytes (`sha256_hex` in production), which is what
/// `mcp/name` suffixes a renamed identifier with.
pub type Options {
  Options(
    client_version: String,
    handshake_timeout_ms: Int,
    list_timeout_ms: Int,
    call_timeout_ms: Int,
    secrets: SecretStore,
    digest: fn(String) -> String,
  )
}

/// The version this harness introduces itself to an MCP server as, in
/// `initialize`'s `clientInfo`. It tracks the package version; nothing
/// negotiates on it, and a server that branches on it is branching on
/// something Loom does not promise.
pub const client_version = "0.1.0"

/// The shipped options: the real environment, the real hash, and the
/// default timeouts.
///
/// ## Examples
///
/// ```gleam
/// assert mcp.default_options().list_timeout_ms == mcp.default_list_timeout_ms
/// ```
///
pub fn default_options() -> Options {
  Options(
    client_version:,
    handshake_timeout_ms: mcp_client.default_handshake_timeout_ms,
    list_timeout_ms: default_list_timeout_ms,
    call_timeout_ms: default_call_timeout_ms,
    secrets: secret.env(),
    digest: sha256_hex,
  )
}

/// Lowercase hex of SHA-256 over the text's UTF-8 bytes — the digest
/// `mcp/name` takes eight characters of when it has had to rename
/// something.
///
/// It is `tools/blob`'s content address with its `sha256-` label
/// removed rather than a second hash: the tree has exactly one SHA-256
/// and it is behind `tools`' FFI. The label must come off — the mangler
/// slices the *first* eight characters, and `"sha256-x"` would be the
/// same eight for every name in the tree, turning a collision-avoidance
/// suffix into a constant.
///
/// ## Examples
///
/// ```gleam
/// // string.length(mcp.sha256_hex("github")) == 64
/// ```
///
pub fn sha256_hex(text: String) -> String {
  blob.ref_for(bit_array.from_string(text))
  |> string.drop_start(string.length(blob_prefix))
}

const blob_prefix = "sha256-"

/// A host with no MCP servers.
///
/// ## Examples
///
/// ```gleam
/// assert mcp.none().servers == []
/// ```
///
pub fn none() -> Layer {
  Layer(servers: [], call_timeout_ms: default_call_timeout_ms)
}

/// Whether this layer reached any server at all. What the boot asks
/// before it widens an allowlist or renders a surface.
///
/// ## Examples
///
/// ```gleam
/// assert !mcp.serving(mcp.none())
/// ```
///
pub fn serving(layer: Layer) -> Bool {
  layer.servers != []
}

// --- boot ------------------------------------------------------------------

/// Starts every configured server, generating one capability module per
/// server that answers.
///
/// Returns the layer of servers that came up and one `Refusal` per
/// server that did not, in catalogue order. A refusal is never a boot
/// failure: an operator who configured a server that cannot serve should
/// see why, once, and keep their session.
///
/// Every failing step tears its own client down before returning, so a
/// server whose `tools/list` was refused leaves no process behind.
///
/// ## Examples
///
/// ```gleam
/// // let #(layer, refusals) = mcp.start(catalogue.mcp_servers, options)
/// ```
///
pub fn start(
  servers: List(catalog.McpServer),
  options: Options,
) -> #(Layer, List(Refusal)) {
  let started = list.map(servers, fn(server) { start_one(server, options) })
  #(
    Layer(
      servers: list.filter_map(started, fn(one) { one }),
      call_timeout_ms: options.call_timeout_ms,
    ),
    list.filter_map(started, fn(one) {
      case one {
        Ok(_started) -> Error(Nil)
        Error(refusal) -> Ok(refusal)
      }
    }),
  )
}

/// Stops every server in the layer: each client closes its child's
/// stdin and kills it. Fire-and-forget and idempotent, so `shutdown` may
/// run it twice.
pub fn stop(layer: Layer) -> Nil {
  list.each(layer.servers, fn(server) { mcp_client.stop(server.client) })
}

fn start_one(
  configured: catalog.McpServer,
  options: Options,
) -> Result(Server, Refusal) {
  let refuse = fn(reason) { Refusal(server: configured.name, reason:) }
  use env <- result.try(
    server_env(configured, options.secrets) |> result.map_error(refuse),
  )
  use client <- result.try(
    start_client(configured, env, options)
    |> result.map_error(fn(error) {
      refuse("it did not start: " <> describe_start_error(error))
    }),
  )
  use tools <- result.try(
    mcp_client.list_tools(client, options.list_timeout_ms)
    |> result.map_error(fn(error) {
      stopping(
        client,
        refuse("its tools could not be listed: " <> describe_call_error(error)),
      )
    }),
  )
  use generated <- result.try(
    codegen.generate(configured.name, tools, options.digest)
    |> result.map_error(fn(error) {
      stopping(client, refuse(codegen.describe(error)))
    }),
  )
  Ok(Server(
    name: configured.name,
    client:,
    generated:,
    tools: list.length(tools),
  ))
}

// The child's environment: the API key alone, read from this harness's
// own environment under the name the catalogue gave and passed through
// under the same name. A configured variable that is unset is a worded
// refusal *before* anything spawns, and neither the value nor its
// absence is ever quoted with the value beside it.
fn server_env(
  configured: catalog.McpServer,
  secrets: SecretStore,
) -> Result(List(#(String, String)), String) {
  case configured.api_key_env {
    None -> Ok([])
    Some(name) ->
      case secret.lookup(secrets, name) {
        Ok(value) -> Ok([#(name, value)])
        Error(Nil) ->
          Error(
            "its api_key_env names "
            <> name
            <> ", which is not set in this server's environment",
          )
      }
  }
}

// The client actor, started from processes of its own so that no link
// reaches back here. See the module doc; the receive is bounded past
// everything `mcp/client.start` bounds itself by, so a timeout here
// means the starter died or the host is wedged rather than that a server
// was merely slow.
fn start_client(
  configured: catalog.McpServer,
  env: List(#(String, String)),
  options: Options,
) -> Result(mcp_client.Client, mcp_client.StartError) {
  let spec = transport.PortTransport(spawn: spawn_of(configured.command, env))
  let client_options =
    mcp_client.options(options.client_version)
    |> mcp_client.with_handshake_timeout(options.handshake_timeout_ms)
  let window = start_window_ms(options.handshake_timeout_ms)
  let verdicts = process.new_subject()
  let _watcher =
    process.spawn_unlinked(fn() {
      watch_start(spec, client_options, window, verdicts)
    })
  case process.receive(verdicts, within: window + hop_margin_ms) {
    Ok(verdict) -> verdict

    // The watcher answers inside `window` either way, so reaching this
    // is the watcher itself having died.
    Error(Nil) -> Error(mcp_client.TransportFailed(reason: too_slow(window)))
  }
}

// The window a start is given: `mcp/client.start` opens the transport
// inside its own initialiser and *then* runs the handshake, so the two
// budgets are consecutive and the window is their sum plus real slack.
// Stated as the relationship rather than as a number near it — the
// window used to be the handshake budget alone plus five seconds, which
// is *shorter* than the worst case it was meant to cover.
fn start_window_ms(handshake_timeout_ms: Int) -> Int {
  mcp_client.init_timeout_ms + handshake_timeout_ms + start_margin_ms
}

// Slack over the two budgets `mcp/client.start` spends, covering the
// margin it adds to its own handshake reply and a host under load.
const start_margin_ms = 5000

// One message hop: the watcher decides at `window` and forwards, so this
// only has to cover the send landing here.
const hop_margin_ms = 1000

// Runs `mcp/client.start` on a process of its own and answers inside
// `window` whatever happens.
//
// The drain is the point. A start that lands *after* the window would
// otherwise leave a client actor — and the third-party server process
// under it — running for the life of the VM with nothing holding a
// handle on it, because `Layer` is the only handle and this server never
// reached one. It has to be drained here rather than by the caller: a
// `Subject` is read only by the process that created it, so the only
// process that can receive a late `started` is the one that made it.
fn watch_start(
  spec: transport.Transport,
  client_options: mcp_client.Options,
  window: Int,
  verdicts: process.Subject(Result(mcp_client.Client, mcp_client.StartError)),
) -> Nil {
  let started = process.new_subject()
  let _starter =
    process.spawn_unlinked(fn() {
      process.send(started, mcp_client.start(spec, client_options))
    })
  case process.receive(started, within: window) {
    Ok(verdict) -> process.send(verdicts, verdict)
    Error(Nil) -> {
      process.send(
        verdicts,
        Error(mcp_client.TransportFailed(reason: too_slow(window))),
      )
      drain_late_start(started)
    }
  }
}

fn drain_late_start(
  started: process.Subject(Result(mcp_client.Client, mcp_client.StartError)),
) -> Nil {
  case process.receive(started, within: drain_window_ms) {
    Ok(Ok(client)) -> mcp_client.stop(client)
    Ok(Error(_refused)) -> Nil
    Error(Nil) -> Nil
  }
}

// How long the drainer waits for a start that already missed its window.
// Bounded rather than forever: the watcher is unlinked, and a process
// waiting on a subject nobody will ever write to is itself the leak this
// exists to prevent.
const drain_window_ms = 120_000

fn too_slow(window: Int) -> String {
  "the client did not answer within " <> int.to_string(window) <> "ms"
}

// A configured argv, executable first. `catalog` guarantees it is
// non-empty, and a shell string is not a thing `transport.Spawn` can
// express, so nothing here is interpretable by a shell.
fn spawn_of(
  command: List(String),
  env: List(#(String, String)),
) -> transport.Spawn {
  case command {
    [executable, ..args] ->
      transport.spawn(executable, args) |> transport.with_env(env)

    // Unreachable: `catalog.parse` refuses an empty command. Refusing to
    // invent an executable is the only honest answer if it ever were.
    [] -> transport.spawn("", []) |> transport.with_env(env)
  }
}

fn stopping(client: mcp_client.Client, refusal: Refusal) -> Refusal {
  mcp_client.stop(client)
  refusal
}

// --- what the layer publishes ----------------------------------------------

/// The module names this layer's servers generated, plus the shared
/// vocabulary module they all import — exactly what the workspace seam's
/// allowlist is widened by, and empty when no server came up.
///
/// ## Examples
///
/// ```gleam
/// assert mcp.allowed_imports(mcp.none()) == []
/// ```
///
pub fn allowed_imports(layer: Layer) -> List(String) {
  case layer.servers {
    [] -> []
    servers -> [
      vocabulary_module,
      ..list.map(servers, fn(server) { server.generated.module_name })
    ]
  }
}

/// The rendered description surface of every generated module, in
/// catalogue order — what `tools/codemode.SeamOffer.extra_surfaces`
/// carries.
pub fn surfaces(layer: Layer) -> List(String) {
  list.map(layer.servers, fn(server) { server.generated.surface })
}

/// The generated modules as the hermetic build takes them:
/// `#(module name, source)`. `codemode.execute` narrows this to the
/// program's own imports before anything is written.
pub fn generated(layer: Layer) -> List(#(String, String)) {
  list.map(layer.servers, fn(server) {
    #(server.generated.module_name, server.generated.source)
  })
}

/// The capability names this layer's router services: one per server.
pub fn serviced_caps(layer: Layer) -> List(String) {
  list.map(layer.servers, fn(server) { cap_prefix <> server.name })
}

/// Each server's name and how many tools it listed — the `mcp.ready`
/// log line's payload.
pub fn listings(layer: Layer) -> List(#(String, Int)) {
  list.map(layer.servers, fn(server) { #(server.name, server.tools) })
}

// --- the router arm --------------------------------------------------------

/// The capability router for one execution: `mcp.<server>` served here,
/// everything else handed to `inner` untouched.
///
/// The plan is always `satellite.ServedHere` — a request the harness
/// answers over a socket it already owns, entering no jail and building
/// no `broker.CallSpec`, exactly as the orchestration seam does
/// (`codemode/orchestration`). There is no policy to compose for a call
/// that spawns nothing: what bounds it is the pooled outstanding-effect
/// cap the host applies before any plan is served, the execution's wall
/// deadline, and this seam's own call timeout.
///
/// A `mcp.<server>` naming a server this host did not configure is
/// refused as `unsupported_cap`. A vetted program cannot produce one —
/// it could not have imported a module that does not exist — so that arm
/// answers a hand-written `.beam` rather than a program.
///
/// ## Examples
///
/// ```gleam
/// // satellite.SatelliteConfig(..config, router: mcp.routing(layer, over: base))
/// ```
///
pub fn routing(layer: Layer, over inner: CapRouter) -> CapRouter {
  fn(request: CapRequest) {
    case string.starts_with(request.cap, cap_prefix) {
      False -> inner(request)
      True -> call_plan(layer, request, layer.call_timeout_ms)
    }
  }
}

fn call_plan(
  layer: Layer,
  request: CapRequest,
  timeout_ms: Int,
) -> Result(CapPlan, CapDenial) {
  let name = string.drop_start(request.cap, string.length(cap_prefix))
  use server <- result.try(find(layer, name))
  use tool <- result.try(
    string_arg(request.args, "tool")
    |> result.map_error(fn(reason) {
      CapDenial(code: invalid_argument_code, message: reason)
    }),
  )
  use arguments <- result.try(arguments_json(request.args))
  Ok(
    ServedHere(fn() {
      case mcp_client.call_tool(server.client, tool, arguments, timeout_ms) {
        Error(error) -> call_failure(error)
        Ok(result) -> tool_result(result)
      }
    }),
  )
}

fn find(layer: Layer, name: String) -> Result(Server, CapDenial) {
  // `map_error` rather than `replace_error`: the message concatenates
  // four strings and names every configured server, and it is wanted on
  // approximately no calls at all.
  list.find(layer.servers, fn(server) { server.name == name })
  |> result.map_error(fn(_nil) {
    CapDenial(
      code: unsupported_cap_code,
      message: "no MCP server named "
        <> name
        <> " is configured on this host; it serves: "
        <> configured_names(layer),
    )
  })
}

fn configured_names(layer: Layer) -> String {
  case list.map(layer.servers, fn(server) { server.name }) {
    [] -> "none"
    names -> string.join(names, ", ")
  }
}

// The tool's arguments, as the JSON the server is sent. Converted here,
// at plan time, so a value this wire cannot carry is refused before the
// call is admitted rather than after a round trip that could not have
// happened.
fn arguments_json(args: MsgPackValue) -> Result(JsonValue, CapDenial) {
  use value <- result.try(
    field(args, "arguments")
    |> result.map_error(fn(reason) {
      CapDenial(code: invalid_argument_code, message: reason)
    }),
  )
  interchange.to_json(value)
  |> result.map_error(fn(fault) {
    CapDenial(
      code: invalid_argument_code,
      message: "the tool arguments do not cross to JSON: "
        <> interchange.describe(fault),
    )
  })
}

// --- rendering an answer ----------------------------------------------------

/// The `cap_result` outcome one `tools/call` answer becomes: the pinned
/// result shape `cap/internal/mcp` decodes,
/// `{content: [<block>...], is_error: Bool, structured?: <value>}`.
/// `structured` is present only when the server sent one, which is what
/// `wire.optional_field` reads as `None`.
///
/// Public because it is the whole of what a server's answer turns into
/// and the only part of the answer path a hermetic test can hold still:
/// the two ceilings below are reachable from a hostile server but not
/// from a fake one, whose own answer has to survive `core/json.parse`
/// and `mcp/stdio`'s line cap on the way in.
///
/// ## Examples
///
/// ```gleam
/// // mcp.tool_result(protocol.CallToolResult(content: [], is_error: False,
/// //   structured_content: None))
/// ```
///
pub fn tool_result(answer: protocol.CallToolResult) -> CapOutcome {
  case structured_value(answer.structured_content) {
    Error(fault) ->
      framing.CapErr(
        code: malformed_code,
        message: "the server's structured content does not cross to the "
          <> "capability wire: "
          <> interchange.describe(fault),
      )
    Ok(structured) ->
      carriable(
        msgpack.MapValue(list.append(
          [
            #(
              msgpack.StringValue("content"),
              msgpack.ArrayValue(list.map(answer.content, content_block)),
            ),
            #(
              msgpack.StringValue("is_error"),
              msgpack.BoolValue(answer.is_error),
            ),
          ],
          structured,
        )),
      )
  }
}

// One hostile answer must cost one call, not the channel.
//
// A `tools/call` result is bounded by everything upstream at *JSON* size
// and *JSON* depth, and neither bound is the one the cap channel
// enforces. A legal line just under `mcp/stdio.max_line_bytes` can
// re-encode larger — a JSON `0.1` is three bytes and a msgpack float64
// is nine — and the frame the host builds around this value is two
// containers deep, so a structured value at the JSON parser's own
// ceiling clears `core/msgpack.max_depth` once wrapped. An oversized
// `cap_result` is dropped unsent by `codemode/satellite`, which leaves
// the program blocked on an answer that will never come until its wall
// deadline; an over-deep one decodes as an `inbound.Fault` on the
// satellite, which settles every in-flight call and closes the channel.
// Both are the whole execution paying for one call.
//
// So the value is measured here, where it is still a refusal a program
// reads. The encode is bought rather than free — its bytes are thrown
// away and the host encodes the frame again — but asking "will this
// frame fit" any other way means estimating, and it happens at most once
// per MCP call.
fn carriable(value: MsgPackValue) -> CapOutcome {
  case fits_depth(value, msgpack.max_depth - envelope_depth) {
    False ->
      framing.CapErr(
        code: malformed_code,
        message: "the server's answer nests deeper than the "
          <> int.to_string(msgpack.max_depth)
          <> " levels one capability frame carries",
      )
    True ->
      case msgpack.encode(value) {
        Error(_unencodable) ->
          framing.CapErr(
            code: malformed_code,
            message: "the server's answer has no msgpack encoding",
          )
        Ok(bytes) -> carriable_size(value, bit_array.byte_size(bytes))
      }
  }
}

fn carriable_size(value: MsgPackValue, size: Int) -> CapOutcome {
  case size > max_result_bytes() {
    True ->
      framing.CapErr(
        code: malformed_code,
        message: "the server's answer encodes to "
          <> int.to_string(size)
          <> " bytes, past the "
          <> int.to_string(max_result_bytes())
          <> " one capability frame carries",
      )
    False -> framing.CapOk(value:)
  }
}

/// The largest a rendered result may encode to: the cap channel's own
/// frame cap (`broker/framing.max_frame_bytes`, which is what
/// `codemode/satellite` measures an outbound frame against) less room
/// for the frame the host wraps it in.
///
/// Read from that constant rather than restated, so the two cannot
/// drift. The margin is deliberately far larger than the envelope it
/// covers — a version, an id, a kind and two short keys — because what
/// it must never do is let a value through that the frame encoder then
/// refuses, and 64 KiB of slack costs a hostile server nothing it could
/// have used.
///
/// ## Examples
///
/// ```gleam
/// assert mcp.max_result_bytes() < framing.max_frame_bytes
/// ```
///
pub fn max_result_bytes() -> Int {
  framing.max_frame_bytes - envelope_margin_bytes
}

const envelope_margin_bytes = 65_536

// The frame the host builds is a map (`{v, id, kind, body}`) holding a
// map (`{ok, value}`), so the value itself starts two containers down
// and may nest that much less than `core/msgpack.max_depth`.
const envelope_depth = 2

// Whether `value` nests within `budget` container levels, short-circuit:
// a hostile value is refused as soon as it runs past the budget rather
// than after it has been walked to the bottom.
fn fits_depth(value: MsgPackValue, budget: Int) -> Bool {
  case value {
    msgpack.ArrayValue(items:) ->
      budget > 0 && list.all(items, fits_depth(_, budget - 1))
    msgpack.MapValue(entries:) ->
      budget > 0
      && list.all(entries, fn(entry) {
        fits_depth(entry.0, budget - 1) && fits_depth(entry.1, budget - 1)
      })
    msgpack.NilValue
    | msgpack.BoolValue(..)
    | msgpack.IntValue(..)
    | msgpack.FloatValue(..)
    | msgpack.StringValue(..)
    | msgpack.BinaryValue(..) -> True
  }
}

fn structured_value(
  content: Option(JsonValue),
) -> Result(List(#(MsgPackValue, MsgPackValue)), interchange.InterchangeFault) {
  case content {
    None -> Ok([])
    Some(value) ->
      interchange.to_msgpack(value)
      |> result.map(fn(converted) {
        [#(msgpack.StringValue("structured"), converted)]
      })
  }
}

// A text block keeps its text; every other kind travels as its `type`
// alone, which is what `cap/mcp.Other` carries. The payload of a
// non-text block is dropped by `mcp/protocol` before it reaches here.
fn content_block(block: protocol.ContentBlock) -> MsgPackValue {
  case block {
    protocol.Text(text:) ->
      msgpack.MapValue([
        #(msgpack.StringValue("type"), msgpack.StringValue("text")),
        #(msgpack.StringValue("text"), msgpack.StringValue(text)),
      ])
    protocol.Other(kind:) ->
      msgpack.MapValue([
        #(msgpack.StringValue("type"), msgpack.StringValue(kind)),
      ])
  }
}

// Every way a `tools/call` fails, under a code the program can branch
// on. Matched variant by variant rather than with a catch-all, so a
// sixth `ClientError` cannot inherit somebody else's code.
fn call_failure(error: mcp_client.ClientError) -> CapOutcome {
  case error {
    mcp_client.Unavailable(reason:) ->
      framing.CapErr(code: unavailable_code, message: reason)
    mcp_client.CallTimedOut(after_ms:) ->
      framing.CapErr(
        code: timeout_code,
        message: "the server did not answer within "
          <> int.to_string(after_ms)
          <> "ms",
      )
    mcp_client.ServerError(code:, message:) ->
      framing.CapErr(code: server_error_prefix <> int.to_string(code), message:)
    mcp_client.ResultMalformed(reason:) ->
      framing.CapErr(code: malformed_code, message: reason)

    // Pagination is a `tools/list` failure and cannot reach a call; it
    // is named rather than folded so the match stays exhaustive by
    // construction.
    mcp_client.TooManyPages(cap:) ->
      framing.CapErr(
        code: malformed_code,
        message: "the server paginated past " <> int.to_string(cap) <> " pages",
      )
  }
}

/// One `mcp/client.StartError`, worded for a boot log line. The two
/// sides of a version refusal are both named, because "unsupported
/// protocol version" without either is a line an operator cannot act on.
///
/// ## Examples
///
/// ```gleam
/// // mcp.describe_start_error(mcp_client.ToolsNotDeclared)
/// ```
///
pub fn describe_start_error(error: mcp_client.StartError) -> String {
  case error {
    mcp_client.TransportFailed(reason:) -> reason
    mcp_client.HandshakeFailed(error:) ->
      "the initialize handshake failed: " <> describe_call_error(error)
    mcp_client.VersionUnsupported(server:, supported:) ->
      "it negotiated protocol version "
      <> server
      <> ", and this client speaks "
      <> string.join(supported, ", ")
    mcp_client.ToolsNotDeclared ->
      "it declares no tools capability, and tools are the only thing this "
      <> "client reaches an MCP server for"
  }
}

/// One `mcp/client.ClientError`, worded for a boot log line.
///
/// ## Examples
///
/// ```gleam
/// // mcp.describe_call_error(mcp_client.CallTimedOut(5)) == "it timed out after 5ms"
/// ```
///
pub fn describe_call_error(error: mcp_client.ClientError) -> String {
  case error {
    mcp_client.Unavailable(reason:) -> reason
    mcp_client.CallTimedOut(after_ms:) ->
      "it timed out after " <> int.to_string(after_ms) <> "ms"
    mcp_client.ServerError(code:, message:) ->
      "the server answered error " <> int.to_string(code) <> ": " <> message
    mcp_client.ResultMalformed(reason:) -> reason
    mcp_client.TooManyPages(cap:) ->
      "it paginated past " <> int.to_string(cap) <> " pages"
  }
}

// --- reading the call's own arguments ---------------------------------------

// `cap/internal/mcp` sends `{tool, arguments}` and nothing else. Decoded
// rather than assumed: the satellite is untrusted, so a wrong-shaped
// frame is a refusal the program reads and not a call made with a
// guessed value.
fn field(args: MsgPackValue, key: String) -> Result(MsgPackValue, String) {
  case args {
    msgpack.MapValue(entries:) ->
      list.find_map(entries, fn(entry) {
        case entry.0 == msgpack.StringValue(key) {
          True -> Ok(entry.1)
          False -> Error(Nil)
        }
      })
      |> result.map_error(fn(_nil) {
        "the call carries no `" <> key <> "` field"
      })
    _other -> Error("the call arguments are not a map")
  }
}

fn string_arg(args: MsgPackValue, key: String) -> Result(String, String) {
  use value <- result.try(field(args, key))
  case value {
    msgpack.StringValue(text) -> Ok(text)
    _other -> Error("`" <> key <> "` is not a string")
  }
}
