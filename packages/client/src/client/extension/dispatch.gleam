//// From an install record to a tool the model can call: one satellite per
//// call, under the extension seam.
////
//// `client/extension/installed` says which extensions are still what an
//// operator approved. This module turns each of those into
//// `tools.Tool` values the registry carries, and answers a call to one by
//// launching a jailed node on the artifact the install compiled. The
//// registry itself learns nothing new: an extension tool is a `Tool` like
//// every other, dispatched by name through `tool.dispatch`, and its
//// `run` happens to spend a satellite where `bash`'s spends a jailed
//// process.
////
//// # One execution per call, and what that costs
////
//// A satellite boot per tool call is the price ADR-007 accepted, for the
//// reason code mode accepts it: the hermetic build already happened, at
//// install, so a call pays a node launch and nothing else. Decision 3
//// (phase 3) keeps a satellite alive across calls and removes it; nothing
//// here is shaped to make that harder, because the call is handed over on
//// the capability channel (`cap/ext`) rather than through the node's
//// environment, and a channel can carry a second call where an
//// environment cannot.
////
//// # The router, in three layers
////
//// Outermost is `client/extension/seam`, answering `ext.call` and
//// `net.request`. Beneath it is `codemode/workspace.routing` over the
//// very bridge a code-mode program gets — `fs.*`, `kv.*`, `schedule.*`,
//// `report.emit` — built by `client/codemode.workspace_seam_for`, so an
//// extension reads and writes exactly what a code-mode program reads and
//// writes, under the same containment. Innermost is
//// `satellite.default_router`, which clears `proc.run` into a jail and
//// refuses every name nothing above it answered.
////
//// The MCP arm is deliberately absent. `cap/mcp` is on no seam — it is a
//// `harness_only_cap_module` — so an extension cannot import it, and a
//// router arm for a capability nothing can name would be a claim about
//// reach that the vetting allowlist has already denied.
////
//// # What an escalation approval does not widen
////
//// `tool.Ctx.grants` are not composed onto the run phase. An extension
//// runs at exactly the policy its install approved, and a grant a human
//// approved for *this call* would widen the jail past the terms of that
//// approval — which the operator gave once, at install, having read a
//// manifest. A `code_mode` call is the opposite case and does compose
//// them: the model wrote that program in this turn and the human approved
//// this turn's widening. So the difference is not an oversight, it is the
//// two approvals meaning different things.
////
//// # The secret is not here
////
//// A `[[net.secret]]` binding names an environment variable, a host and a
//// header. The *name* travels into `broker/egress.Policy`; the value is
//// read through the `secrets` function this module is handed, inside
//// `egress.request`, and placed on the matching hop. It is never in the
//// satellite's environment (`launch.node_env` is allowlist-constructed
//// from `Ctx.env` plus the two cap handles, and no arm here adds to it),
//// never in a frame (`seam.Answer` has no field for it and `egress`'s own
//// refusals have none either), and never in a log line
//// (`policy.summary` counts bindings rather than naming values).

import broker/egress
import broker/policy.{type SandboxPolicy}
import client/codemode
import client/extension/manifest.{type Manifest}
import client/extension/policy as ext_policy
import client/extension/record.{type Record}
import client/extension/seam
import codemode/compile
import codemode/enforcement
import codemode/identity
import codemode/launch
import codemode/satellite
import codemode/workspace
import core/clock
import core/json.{type JsonValue}
import core/msgpack.{type MsgPackValue}
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import simplifile
import tools/blob
import tools/codemode as codemode_tool
import tools/tool.{type Ctx, type Tool, type ToolOutcome}

/// Everything a dispatch needs that the install record does not carry.
pub type Config {
  Config(
    /// The code-mode host configuration: the broker every jailed stage
    /// goes through, the clock, the cap-token entropy, the work root, the
    /// `erl` a node boots from, the blob root a `report.emit` lands in,
    /// and the scratch and schedule doors the workspace bridge closes
    /// over.
    ///
    /// One field rather than fifteen because an extension satellite and a
    /// code-mode satellite are the same node under the same base: a host
    /// that could configure them apart would eventually configure them
    /// apart.
    host: codemode.Config,
    /// Reads an environment variable by name, for the secret bindings.
    ///
    /// Injected rather than read here so that this module holds no
    /// environment access at all: the one place a credential value exists
    /// in this process is inside `egress.request`, between this function
    /// returning it and the header going on the wire.
    secrets: fn(String) -> Result(String, Nil),
    /// Which certificate authorities an extension's requests may chain
    /// to. `egress.SystemRoots` in production; a test pins the loopback
    /// origin's own root.
    trust: egress.Trust,
    /// How a satellite node is launched, given the launch configuration
    /// this dispatch composes.
    ///
    /// A seam for the reason `satellite.Launcher` is one at all: the
    /// production launcher listens on the cap socket and dispatches a
    /// jailed `erl` through the broker, and a test needs to be able to
    /// wrap that — to tap the wire and prove a credential reaches no
    /// frame — or replace it with an in-process peer. Production passes
    /// `codemode/launch.launcher` and nothing else does.
    launch: fn(launch.LaunchConfig) -> satellite.Launcher,
  )
}

/// The production launcher: the one value `Config.launch` takes outside a
/// test.
///
/// ## Examples
///
/// ```gleam
/// // dispatch.Config(host:, secrets:, trust:, launch: dispatch.jailed_node)
/// ```
///
pub fn jailed_node(config: launch.LaunchConfig) -> satellite.Launcher {
  launch.launcher(config)
}

/// The tools one ready extension contributes to the registry.
///
/// `Error` refuses the whole extension rather than registering some of
/// its tools: a manifest names its tools together and an operator
/// approved them together, so a schema that will not parse is a broken
/// install to be reported, not a smaller extension to be quietly served.
///
/// The schema is read from the installed source tree, where the manifest
/// promised it would be. `manifest.decode` already checked at install and
/// again at discovery that the path is under `schema/`, that the tree
/// holds it, and that it parses — so a failure here is a file that moved
/// between discovery and boot, which is worth naming rather than
/// assuming away.
///
/// ## Examples
///
/// ```gleam
/// // dispatch.tools(config, written, decoded, sources:, artifact:)
/// ```
///
pub fn tools(
  config: Config,
  written: Record,
  decoded: Manifest,
  sources sources: String,
  artifact artifact: String,
) -> Result(List(Tool), String) {
  let egress = ext_policy.egress_for(decoded.net, trust: config.trust)
  list.try_map(decoded.tools, fn(declared) {
    use schema <- result.try(schema_of(sources, declared))
    Ok(tool_for(config, written, decoded, declared, schema, egress, artifact))
  })
}

/// The one line a boot logs per registered extension: what it is, what it
/// registers, and what it may reach.
///
/// Named here rather than in `client/serve` because the sentence is about
/// the dispatch's own terms — the tools it registered and the network
/// policy it will compose — and the two would drift if the log read one
/// value and the dispatch another.
///
/// ## Examples
///
/// ```gleam
/// // dispatch.summary(written, decoded)
/// //   == "hello 0.1.0 (local): tools hello; no network"
/// ```
///
pub fn summary(written: Record, decoded: Manifest) -> String {
  written.name
  <> " "
  <> written.version
  <> " ("
  <> written.revision
  <> "): tools "
  <> string.join(list.map(decoded.tools, fn(each) { each.name }), ", ")
  <> "; "
  <> ext_policy.summary(decoded.net)
}

// --- one tool ---------------------------------------------------------------

// The `Tool` an extension's `[[tool]]` becomes.
//
// `replay: tool.Never` because an extension call is an external effect by
// construction: the one thing an extension has that a built-in read does
// not is `net.request`, and a replay after a crash could repeat a POST
// nobody meant to send twice. `execution_mode: tool.Exclusive` for the
// same reason `code_mode` is — the call spends a jailed node, a socket
// and a token file under a directory keyed on `{op_id, step_id,
// source_index}`, and `Exclusive` is what the batch scheduler reads to
// keep two of them from starting together. The manifest declares neither,
// deliberately: both are judgements about what the harness may do with a
// call, and an extension author is not the party who gets to relax them.
fn tool_for(
  config: Config,
  written: Record,
  decoded: Manifest,
  declared: manifest.Tool,
  schema: JsonValue,
  egress: ext_policy.Egress,
  artifact: String,
) -> Tool {
  tool.Tool(
    name: declared.name,
    description: declared.description,
    prompt_snippet: Some(declared.prompt_snippet),
    schema:,
    replay: tool.Never,
    execution_mode: tool.Exclusive,
    // The same declaration `code_mode` makes, and for the same reason:
    // the work root under the workspace is written, the toolchain and the
    // artifact outside it are read, and every jailed stage inside the
    // execution then composes its own far narrower requirements.
    requirements: fn(workspace_root) { requirements(workspace_root) },
    run: fn(ctx, arguments) {
      call(config, written, decoded, declared, egress, artifact, ctx, arguments)
    },
  )
}

/// What an extension tool declares it needs of the session base.
///
/// Identical to `tools/codemode.requirements`, and identical for the same
/// reason: the execution writes a work directory under the workspace and
/// reads a toolchain and an artifact outside it. Declarative only —
/// nothing is cleared through `Ctx.clear_call` here, because the node is
/// cleared inside `codemode/launch` against its own requirements and
/// refused in band when the session base cannot cover them.
///
/// ## Examples
///
/// ```gleam
/// // dispatch.requirements("/work").writable_roots == ["/work"]
/// ```
///
pub fn requirements(workspace_root: String) -> SandboxPolicy {
  codemode_tool.requirements(workspace_root)
}

// --- one call ---------------------------------------------------------------

// One tool call: prepare a directory, run a satellite on the installed
// artifact, settle the outcome, remove the directory.
//
// The directory check comes first and is pure, because failing it after
// creating the directory would leave one behind for an execution that
// never ran — the ordering `client/codemode.execute_after_vetting` takes,
// for the same reason.
fn call(
  config: Config,
  written: Record,
  decoded: Manifest,
  declared: manifest.Tool,
  egress: ext_policy.Egress,
  artifact: String,
  ctx: Ctx,
  arguments: JsonValue,
) -> ToolOutcome {
  let root =
    codemode.work_root(
      config.host,
      op_id: ctx.op_id,
      step_id: ctx.step_id,
      source_index: ctx.source_index,
    )
  case
    codemode.check_socket_path(root)
    |> result.try(fn(_ok) { codemode.prepare_root(root) })
  {
    Error(reason) -> failed(ctx, written.name, declared.name, reason)
    Ok(Nil) -> {
      let #(now, _clock) = clock.read(config.host.clock)
      let deadline_ms = now + declared.timeout_ms
      let ran =
        satellite.run(
          artifact_at(artifact, written),
          identity.run_phase(identity.for_execution(
            op_id: ctx.op_id,
            step_id: ctx.step_id,
            budget: codemode.pooled_budget(config.host, deadline_ms),
          )),
          config.host.broker,
          satellite_config(
            config,
            written,
            decoded,
            declared,
            egress,
            ctx,
            arguments,
            root,
            deadline_ms,
          ),
          config.launch(launch.LaunchConfig(
            broker: config.host.broker,
            clock: config.host.clock,
            erl_path: config.host.erl_path,
            demand: ctx.demand,
            accept_timeout_ms: config.host.accept_timeout_ms,
          )),
        )

      // The execution is over: the node is destroyed and the socket and
      // token are unlinked by the host's own teardown. The directory held
      // only those two, and it goes with them — the artifact it ran is
      // the install's and is not under here.
      let _removed = simplifile.delete(root)
      settle(ctx, written, declared, ran)
    }
  }
}

// The installed artifact as the satellite host reads it. The beam set is
// the install's `artifact/` directory and the entry module is the one the
// generated entry source declared, so the two halves of what the install
// wrote are named from the same constants the install wrote them under.
//
// `manifest_hash` is the record's, which `installed.discover` has just
// re-derived from the bytes on disk with the build's own fingerprint
// function — so the address this execution reports is a fact about the
// beams that actually ran.
fn artifact_at(artifact: String, written: Record) -> compile.Artifact {
  compile.Artifact(
    build_root: artifact,
    beam_dir: artifact,
    entry_module: compile.entry_module,
    manifest_hash: written.manifest_hash,
  )
}

// The satellite host's configuration for one extension call.
//
// Every field is either the host's (broker, clock, entropy, timeouts) or
// this call's (base policy, environment, working directory, socket,
// router, ceilings). Nothing is the extension's: an install approved a
// manifest, not a launch.
fn satellite_config(
  config: Config,
  written: Record,
  decoded: Manifest,
  declared: manifest.Tool,
  egress: ext_policy.Egress,
  ctx: Ctx,
  arguments: JsonValue,
  root: String,
  deadline_ms: Int,
) -> satellite.SatelliteConfig {
  satellite.SatelliteConfig(
    base_policy: codemode.execution_policy(ctx.base_policy),
    demand: ctx.demand,
    // The satellite's children inherit the driver's constructed
    // environment, exactly as a code-mode program's do. No binding's
    // variable is added to it: a credential the jail could read would
    // defeat the whole arrangement, and the allowlist is what makes that
    // checkable from the policy alone.
    env: ctx.env,
    cwd: ctx.workspace,
    cap_socket_path: codemode.socket_path(root),
    entropy: config.host.entropy,
    clock: config.host.clock,
    write_token_file: satellite.private_token_writer(root <> "/token"),
    unlink_token_file: satellite.unlink_token_file,
    router: router(
      config,
      written,
      decoded,
      declared,
      egress,
      ctx,
      arguments,
      deadline_ms,
    ),
    ceilings: list.append(
      ext_policy.ceilings(decoded.net),
      workspace.ceilings(bridge(config, ctx)),
    ),
    call_timeout_ms: config.host.call_timeout_ms,
  )
}

// The three layers, outermost first. See the module doc for why the MCP
// arm is not among them.
fn router(
  config: Config,
  written: Record,
  decoded: Manifest,
  declared: manifest.Tool,
  egress: ext_policy.Egress,
  ctx: Ctx,
  arguments: JsonValue,
  deadline_ms: Int,
) -> satellite.CapRouter {
  // The model's arguments verbatim, as JSON text. Re-serialising the
  // value the driver decoded is the one step where the harness and the
  // extension could disagree about what was asked, and `core/json`'s
  // round trip over the driver's own `JsonValue` is the shortest route
  // through it.
  let args = json.to_string(arguments)
  seam.routing(
    seam.Extension(
      // Read when the satellite asks, not when the router is built: what
      // the tool wants to know is how long it has left, and the launch
      // has already spent some of it by then.
      call: fn() {
        let #(now, _clock) = clock.read(config.host.clock)
        seam.Call(
          tool: declared.name,
          args:,
          strand: ctx.strand,
          deadline_ms: int.max(deadline_ms - now, 0),
        )
      },
      egress: reaching(config, written, decoded, egress),
    ),
    over: workspace.routing(bridge(config, ctx), over: satellite.default_router),
  )
}

// The workspace bridge this call reaches the host through: the very
// closures a code-mode program on this host gets, bound to this call's
// workspace and strand.
fn bridge(config: Config, ctx: Ctx) -> workspace.Workspace {
  codemode.workspace_seam_for(
    config.host,
    workspace: ctx.workspace,
    strand: ctx.strand,
    protected: ctx.base_policy.protected,
  )
}

// How `net.request` is answered, with the policy and the credential
// lookup closed over.
//
// The closure is where the value of a bound secret exists and the only
// place it does: `egress.request` reads it through `config.secrets` after
// the origin and the method have already been judged, places it on the
// matching hop, and returns a `Response` that has no field for it. A
// refusal has none either, so the mapping below cannot leak one however
// it is worded.
fn reaching(
  config: Config,
  written: Record,
  decoded: Manifest,
  egress: ext_policy.Egress,
) -> seam.Egress {
  case egress {
    ext_policy.ReachesNothing ->
      seam.ReachesNothing(refusal: ext_policy.network_off(written.name))

    ext_policy.Reaches(policy:) ->
      seam.Reaches(perform: fn(ask: seam.Ask) {
        use method <- result.try(requested_method(ask.method, decoded))
        egress.request(
          policy,
          egress.Request(
            method:,
            url: ask.url,
            headers: ask.headers,
            body: ask.body,
          ),
          secrets: config.secrets,
        )
        |> result.map(answered)
        |> result.map_error(ext_policy.denial)
      })
  }
}

// The method as the closed-set value `egress` judges, or the refusal that
// names what this extension's manifest permits.
//
// Refused here rather than inside `egress` because `egress.Request.method`
// is already the closed set: a name outside it has no value to carry, so
// the refusal has to be composed where the text is still available.
fn requested_method(
  name: String,
  decoded: Manifest,
) -> Result(egress.Method, satellite.CapDenial) {
  case name {
    "GET" -> Ok(egress.Get)
    "POST" -> Ok(egress.Post)
    "PUT" -> Ok(egress.Put)
    "DELETE" -> Ok(egress.Delete)
    "PATCH" -> Ok(egress.Patch)
    "HEAD" -> Ok(egress.Head)
    other ->
      Error(satellite.CapDenial(
        code: ext_policy.denied_code,
        message: "`"
          <> other
          <> "` is not an HTTP method this client can send; this extension's "
          <> "manifest permits "
          <> string.join(decoded.net.methods, ", "),
      ))
  }
}

fn answered(response: egress.Response) -> seam.Answer {
  seam.Answer(
    status: response.status,
    headers: response.headers,
    body: response.body,
  )
}

// --- the settle -------------------------------------------------------------

/// The `outcome` frame as a tool reply, on the model `tools/codemode`'s
/// own settle sets: a completed outcome is `is_error: False`, an errored
/// one is `is_error: True`, and every failure of every stage is a value
/// rather than a crash.
///
/// The one thing this settle has that code mode's does not is
/// `terminate`. `ext.Outcome` carries it, `ext/runtime` puts it on the
/// wire as a boolean, and it lands on `ToolOutcome.terminate` — the field
/// `core/entry.terminate` reads. An errored outcome never terminates: a
/// refusal is something the model repairs on its next turn, and a tool
/// that ended the run by failing would take that turn away.
///
/// Public because it is the one part of a dispatch a test can hold still.
/// A `satellite.Run` is a value, and turning one into a tool reply is a
/// pure function of it — where the rest of a call needs a broker, a
/// toolchain and a jailed node before it says anything at all.
///
/// ## Examples
///
/// ```gleam
/// // dispatch.settle(ctx, written, declared, run).is_error == False
/// ```
///
pub fn settle(
  ctx: Ctx,
  written: Record,
  declared: manifest.Tool,
  ran: satellite.Run,
) -> ToolOutcome {
  case ran.outcome {
    Error(error) ->
      failed(ctx, written.name, declared.name, run_error_text(error, ran.node))

    Ok(satellite.Errored(message:, details:)) ->
      bounded(
        ctx,
        "the extension `"
          <> written.name
          <> "` refused this call: "
          <> message
          <> details_text(details),
        errored_details(written, declared, message, details),
        tool.ContinueRun,
        True,
      )

    Ok(satellite.Completed(value:)) -> completed(ctx, written, declared, value)
  }
}

fn completed(
  ctx: Ctx,
  written: Record,
  declared: manifest.Tool,
  value: MsgPackValue,
) -> ToolOutcome {
  let reply = read_reply(value)
  bounded(
    ctx,
    string.join(reply.blocks, "\n"),
    json.Object([
      #("status", json.String("completed")),
      #("extension", json.String(written.name)),
      #("tool", json.String(declared.name)),
      #("manifest_hash", json.String(written.manifest_hash)),
      #("value", value_json(value)),
    ]),
    reply.terminate,
    False,
  )
}

// What an extension's `outcome` value says, read totally.
//
// A malformed body is not a crash and not a silent empty reply: it
// renders as the whole value's JSON, which is the honest thing to show
// when the shape `ext/runtime` promised is not what arrived. The only way
// that happens is an artifact built against a different `ext` than this
// server serves, and the operator needs to see what it actually sent.
type Reply {
  Reply(blocks: List(String), terminate: tool.Terminate)
}

fn read_reply(value: MsgPackValue) -> Reply {
  case field(value, "content") {
    Ok(msgpack.ArrayValue(items:)) ->
      Reply(
        blocks: list.map(items, block_text),
        terminate: terminate_of(field(value, "terminate")),
      )

    Ok(_other) | Error(Nil) ->
      Reply(blocks: [value_text(value)], terminate: tool.ContinueRun)
  }
}

// One content block. `ext/runtime` sends `{type: "text", text}` or
// `{type: "json", json}` where the JSON block's payload is already its
// serialization — the channel speaks msgpack, and a round trip through
// two structured encodings is a place for the two sides to disagree about
// numbers. So both arms are a string lookup, and a block of neither shape
// renders as itself rather than vanishing.
fn block_text(block: MsgPackValue) -> String {
  case field(block, "type") {
    Ok(msgpack.StringValue("text")) -> string_field(block, "text")
    Ok(msgpack.StringValue("json")) -> string_field(block, "json")
    Ok(_other) | Error(Nil) -> value_text(block)
  }
}

fn string_field(value: MsgPackValue, key: String) -> String {
  case field(value, key) {
    Ok(msgpack.StringValue(text)) -> text
    Ok(other) -> value_text(other)
    Error(Nil) -> value_text(value)
  }
}

// A `terminate` the extension did not send, or sent as something other
// than a boolean, is `ContinueRun`. Ending a run is the exceptional
// answer and a malformed field must never be read as the exceptional one.
fn terminate_of(found: Result(MsgPackValue, Nil)) -> tool.Terminate {
  case found {
    Ok(msgpack.BoolValue(value: True)) -> tool.TerminateRun
    Ok(_other) | Error(Nil) -> tool.ContinueRun
  }
}

fn field(value: MsgPackValue, key: String) -> Result(MsgPackValue, Nil) {
  case value {
    msgpack.MapValue(entries:) ->
      list.find_map(entries, fn(entry) {
        case entry.0 == msgpack.StringValue(key) {
          True -> Ok(entry.1)
          False -> Error(Nil)
        }
      })

    msgpack.NilValue
    | msgpack.BoolValue(..)
    | msgpack.IntValue(..)
    | msgpack.FloatValue(..)
    | msgpack.StringValue(..)
    | msgpack.BinaryValue(..)
    | msgpack.ArrayValue(..) -> Error(Nil)
  }
}

fn errored_details(
  written: Record,
  declared: manifest.Tool,
  message: String,
  details: MsgPackValue,
) -> JsonValue {
  json.Object([
    #("status", json.String("extension_failed")),
    #("extension", json.String(written.name)),
    #("tool", json.String(declared.name)),
    #("manifest_hash", json.String(written.manifest_hash)),
    #("message", json.String(message)),
    #("details", value_json(details)),
  ])
}

fn details_text(details: MsgPackValue) -> String {
  case details {
    msgpack.NilValue -> ""
    other -> "\ndetails: " <> value_text(other)
  }
}

// A run that never produced an outcome: the node did not start, outran
// its deadline, died, or broke the channel. The enforcement report goes
// with it for the reason `codemode/enforcement` gives — a failure that
// says nothing about what confined the node invites the reader to assume
// the strongest thing.
fn run_error_text(
  error: satellite.RunError,
  node: enforcement.Report,
) -> String {
  let reason = case error {
    satellite.TokenMintFailed(reason:) ->
      "the capability token could not be minted: " <> reason
    satellite.TokenFileFailed(reason:) ->
      "the capability token file could not be written: " <> reason
    satellite.HostUnavailable(reason:) ->
      "the satellite host would not start: " <> reason
    satellite.LaunchRejected(reason:) ->
      "the satellite node was not launched: " <> reason
    satellite.DeadlineExceeded ->
      "the call did not finish inside the extension's own timeout"
    satellite.SatelliteGone(reason:) ->
      "the satellite exited before reporting an outcome: " <> reason
    satellite.ChannelFaulted(reason:) ->
      "the capability channel faulted: " <> reason
    satellite.OutcomeMalformed(reason:) ->
      "the satellite's outcome frame was malformed: " <> reason
  }
  reason <> "\n" <> node_text(node)
}

fn node_text(node: enforcement.Report) -> String {
  case node {
    enforcement.Unreported(reason:) ->
      "the node made no enforcement report: " <> reason
    enforcement.Reported(entries: _, degraded:) -> {
      let #(applied, skipped) = enforcement.layers(node)
      "the node enforced ["
      <> string.join(applied, ", ")
      <> "]"
      <> case skipped {
        [] -> ""
        missing -> ", SKIPPED [" <> string.join(missing, ", ") <> "]"
      }
      <> case degraded {
        True -> " (DEGRADED)"
        False -> ""
      }
    }
  }
}

fn failed(
  ctx: Ctx,
  extension: String,
  name: String,
  reason: String,
) -> ToolOutcome {
  bounded(
    ctx,
    "the extension `"
      <> extension
      <> "` could not serve "
      <> name
      <> ": "
      <> reason,
    json.Object([
      #("status", json.String("dispatch_failed")),
      #("extension", json.String(extension)),
      #("tool", json.String(name)),
      #("reason", json.String(reason)),
    ]),
    tool.ContinueRun,
    True,
  )
}

// The same blob overflow every other unbounded tool reply goes through
// (spec §3.2). An extension's reply is unbounded by construction — it may
// be a whole HTTP body — and a store failure falls back to the inline text
// rather than losing the result.
fn bounded(
  ctx: Ctx,
  text: String,
  details: JsonValue,
  terminate: tool.Terminate,
  is_error: Bool,
) -> ToolOutcome {
  case blob.bound(ctx, text) {
    Error(_error) ->
      tool.ToolOutcome(
        content: [tool.text_block(text)],
        details: Some(details),
        is_error:,
        terminate:,
      )

    Ok(held) ->
      tool.ToolOutcome(
        content: [tool.text_block(blob.bounded_text(held))],
        details: Some(details),
        is_error:,
        terminate:,
      )
      |> blob.with_blob_details(held)
  }
}

// --- the schema -------------------------------------------------------------

fn schema_of(
  sources: String,
  declared: manifest.Tool,
) -> Result(JsonValue, String) {
  let path = sources <> "/" <> declared.parameters
  use text <- result.try(
    simplifile.read(from: path)
    |> result.map_error(fn(error) {
      "the schema for the tool `"
      <> declared.name
      <> "` is unreadable at "
      <> path
      <> ": "
      <> simplifile.describe_error(error)
    }),
  )
  json.parse(text)
  |> result.map_error(fn(_report) {
    "the schema for the tool `"
    <> declared.name
    <> "` at "
    <> path
    <> " is not valid JSON"
  })
}

// --- msgpack rendering ------------------------------------------------------
//
// `tools/codemode.value_text` and `value_json` are public and do exactly
// this, so they are called rather than restated: a program's structured
// value and an extension's are the same kind of thing crossing the same
// channel, and rendering them two ways would put two different accounts of
// one msgpack value in front of one model.

fn value_text(value: MsgPackValue) -> String {
  codemode_tool.value_text(value)
}

fn value_json(value: MsgPackValue) -> JsonValue {
  codemode_tool.value_json(value)
}
