//// From an install record to a tool the model can call, and to the recipe
//// the session's host registry launches that extension's satellite from.
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
//// # One satellite per session, not one per call
////
//// ADR-007 accepted a node boot per tool call and Decision 3 removed it.
//// A call now reaches `client/extension/hosts`, which holds one satellite
//// per installed extension for the life of the session and sends this
//// call to it as a `hook_call` (`protocol-change/012`). What this module
//// still owns is everything either side of that: the `Tool` the registry
//// carries, the coordinates one invocation is judged under, the router
//// its `cap_call`s meet, and the settle from the answer to a tool reply.
////
//// Holding a node open widens nothing. The satellite host mints a token
//// per invocation and revokes it on the answer, so an extension may keep
//// actors between calls and may not reach a capability between them; the
//// terms this module composes are per invocation for exactly that reason.
////
//// # The router, in three layers
////
//// Outermost is `client/extension/seam`, answering `net.request`.
//// Beneath it is `codemode/workspace.routing` over the
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
import client/extension/hosts.{type Hosts}
import client/extension/manifest.{type Manifest}
import client/extension/policy as ext_policy
import client/extension/record.{type Record}
import client/extension/seam
import codemode/compile
import codemode/identity
import codemode/launch
import codemode/satellite
import codemode/workspace
import core/clock
import core/ids.{type OpId}
import core/json.{type JsonValue}
import core/msgpack.{type MsgPackValue}
import gleam/bit_array
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
    /// The session's satellite registry: which extension has a node, and
    /// the one door an invocation goes through.
    ///
    /// A seam rather than a subject because the registry starts under the
    /// session's supervisor, after this configuration is assembled, and a
    /// captured subject would go stale the first time it restarted.
    hosts: Hosts,
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

// Everything one call is dispatched under, in one value.
//
// A record rather than seven positional parameters threaded through four
// functions, and the reason is not only length. `written` and `declared`
// are both records with a `name` field, so a signature carrying both is
// one a caller can get the wrong way round with every type still
// agreeing — and the two names differ (an extension is `web_search` and
// so is its tool, until an extension registers two). Fields close that.
type Dispatching {
  Dispatching(
    config: Config,
    written: Record,
    decoded: Manifest,
    declared: manifest.Tool,
    egress: ext_policy.Egress,
    artifact: String,
    ctx: Ctx,
    arguments: JsonValue,
  )
}

// The `Tool` an extension's `[[tool]]` becomes.
//
// `replay: tool.Never` because an extension call is an external effect by
// construction: the one thing an extension has that a built-in read does
// not is `net.request`, and a replay after a crash could repeat a POST
// nobody meant to send twice. `execution_mode: tool.Exclusive` for the
// same reason `code_mode` is — the call holds the extension's one
// satellite for the whole of its deadline, because the protocol allows
// one outstanding invocation per node, and `Exclusive` is what the batch
// scheduler reads to keep two of them from starting together. The
// manifest declares neither, deliberately: both are judgements about what
// the harness may do with a call, and an extension author is not the
// party who gets to relax them.
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
    requirements:,
    run: fn(ctx, arguments) {
      call(Dispatching(
        config:,
        written:,
        decoded:,
        declared:,
        egress:,
        artifact:,
        ctx:,
        arguments:,
      ))
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

// --- one invocation ---------------------------------------------------------

// One tool call: build this invocation's coordinates and hand them to the
// session's host registry, which starts a satellite if this extension has
// none yet, sends the `hook_call`, and answers.
//
// No directory is prepared and none is removed. A host's socket and token
// file live under a root keyed on the *extension* rather than on this
// call, because they outlive it: `client/extension/hosts` prepares that
// root when it launches, and the launcher's teardown unlinks what it put
// there.
fn call(dispatching: Dispatching) -> ToolOutcome {
  let Dispatching(config:, written:, declared:, ctx:, arguments:, ..) =
    dispatching
  hosts.invoke(
    config.hosts,
    extension: written.name,
    invocation: satellite.Tool(name: declared.name),
    // The model's arguments verbatim, as JSON text, in the envelope
    // `ext/runtime` reads. Re-serialising the value the driver decoded is
    // the one step where the harness and the extension could disagree
    // about what was asked, and `core/json`'s round trip over the
    // driver's own `JsonValue` is the shortest route through it.
    args: msgpack.MapValue([
      #(
        msgpack.StringValue("args"),
        msgpack.StringValue(json.to_string(arguments)),
      ),
      #(msgpack.StringValue("strand"), msgpack.StringValue(ctx.strand)),
    ]),
    at: coordinates(ctx),
    within: within(config, declared),
  )
  |> settle(ctx, written, declared, _)
}

/// This call's coordinates as the host registry reads them.
///
/// Public because it is the one place a `tool.Ctx` becomes the record a
/// hook bus builds by hand, and the two have to agree about which fields
/// matter.
///
/// `grants` are deliberately absent. An extension runs at exactly the
/// policy its install approved, and a grant a human approved for *this
/// call* would widen the jail past the terms of that approval.
///
/// ## Examples
///
/// ```gleam
/// // dispatch.coordinates(ctx).strand == ctx.strand
/// ```
///
pub fn coordinates(ctx: Ctx) -> hosts.Coordinates {
  hosts.Coordinates(
    op_id: ctx.op_id,
    step_id: ctx.step_id,
    strand: ctx.strand,
    workspace: ctx.workspace,
    base_policy: ctx.base_policy,
    demand: ctx.demand,
    env: ctx.env,
  )
}

/// The recipe the session's host registry launches this extension's
/// satellite from.
///
/// Built from the same install record and the same host configuration the
/// tools are built from, in the same call, so a host and a tool cannot end
/// up describing different extensions.
///
/// ## Examples
///
/// ```gleam
/// // dispatch.hosting(config, written, decoded, artifact).name == written.name
/// ```
///
pub fn hosting(
  config: Config,
  written: Record,
  decoded: Manifest,
  artifact artifact: String,
) -> hosts.Extension {
  let egress = ext_policy.egress_for(decoded.net, trust: config.trust)
  hosts.Extension(
    name: written.name,
    start: fn(at) { start_host(config, written, artifact, at) },
    invoking: fn(at) { invoking(config, written, decoded, egress, at) },
  )
}

// Launches this extension's satellite under the coordinates of whichever
// call was first to need it.
//
// The enforcement demand is that call's, and so is the environment and the
// workspace: a session runs every extension call under one base, so the
// first call's terms are the session's terms, and re-launching a node to
// pick up a later call's would be re-launching it for no difference.
fn start_host(
  config: Config,
  written: Record,
  artifact: String,
  at: hosts.Coordinates,
) -> Result(satellite.Host, String) {
  use host <- result.try(host_config(config, written, at))
  satellite.start(
    artifact_at(artifact, written),
    host,
    config.launch(launch.LaunchConfig(
      broker: config.host.broker,
      clock: config.host.clock,
      erl_path: config.host.erl_path,
      demand: at.demand,
      accept_timeout_ms: config.host.accept_timeout_ms,
    )),
  )
  |> result.map_error(fn(error) {
    "the satellite for "
    <> written.name
    <> " would not start: "
    <> start_text(error)
  })
}

// A launch failure as one line. Every variant is written rather than
// swallowed, so a new one fails exhaustiveness here.
fn start_text(error: satellite.RunError) -> String {
  case error {
    satellite.TokenMintFailed(reason:) ->
      "its capability token could not be minted: " <> reason
    satellite.TokenFileFailed(reason:) ->
      "its capability token file could not be written: " <> reason
    satellite.HostUnavailable(reason:) -> reason
    satellite.LaunchRejected(reason:) -> "the node was not launched: " <> reason
    satellite.DeadlineExceeded -> "the launch outran its own deadline"
    satellite.SatelliteGone(reason:) -> "the node exited at once: " <> reason
    satellite.ChannelFaulted(reason:) ->
      "the capability channel faulted at once: " <> reason
    satellite.OutcomeMalformed(reason:) ->
      "the node answered malformed bytes at once: " <> reason
  }
}

// The satellite host's configuration for one extension's node.
//
// Every field is either the host's (broker, clock, entropy, timeouts) or
// the session's (base policy, environment, workspace, socket). Nothing is
// the extension's: an install approved a manifest, not a launch.
//
// The node's own budget deadline is the session's ceiling on how long a
// satellite may live, not any one call's: an invocation's deadline is a
// state timeout on the host and is enforced there.
fn host_config(
  config: Config,
  written: Record,
  at: hosts.Coordinates,
) -> Result(satellite.HostConfig, String) {
  let root = codemode.host_root(config.host, extension: written.name)
  use _ok <- result.try(codemode.check_socket_path(root))
  use _ok <- result.try(codemode.prepare_root(root))
  let #(now, _clock) = clock.read(config.host.clock)
  Ok(satellite.HostConfig(
    broker: config.host.broker,
    identity: identity.run_phase(identity.for_execution(
      op_id: node_operation(config),
      step_id: host_step_id,
      budget: codemode.pooled_budget(config.host, now + host_lifetime_ms),
    )),
    base_policy: session_lived(codemode.execution_policy(at.base_policy)),
    demand: at.demand,
    // The satellite's children inherit the driver's constructed
    // environment, exactly as a code-mode program's do. No binding's
    // variable is added to it: a credential the jail could read would
    // defeat the whole arrangement, and the allowlist is what makes that
    // checkable from the policy alone.
    env: at.env,
    cwd: at.workspace,
    cap_socket_path: codemode.socket_path(root),
    entropy: config.host.entropy,
    clock: config.host.clock,
    write_token_file: satellite.private_token_writer(root <> "/token"),
    unlink_token_file: satellite.unlink_token_file,
    call_timeout_ms: config.host.call_timeout_ms,
  ))
}

/// The step a satellite node is dispatched under. One name, because a
/// node is one long-running dispatch rather than a sequence of them.
pub const host_step_id = "extension-host"

/// A fresh operation for one satellite node, minted here rather than
/// borrowed from whichever call happened to launch it.
///
/// This is the difference between an abort that means "tear down this
/// node" and one that means "tear down everything this run is doing", and
/// it is load-bearing rather than tidy. `broker.abort(op_id)` cancels
/// every active execution under that operation, and it is issued
/// *routinely*: `codemode/satellite.cleanup` runs it at the end of every
/// code-mode execution, successful ones included, and
/// `codemode/launch.destroy` runs it for every node it tears down. Under
/// the launching call's operation that makes two ordinary sequences
/// fatal.
///
/// A tool call launches an extension's satellite, and a `code_mode` call
/// in the same run then finishes and aborts the operation they share:
/// the satellite dies, its host reads the closed socket as
/// `SatelliteGone`, and the extension is `Departed` for the rest of the
/// session. Worse, every hook-launched host shares the single operation
/// `client/serve.hook_coordinates` mints for the session's hooks, so one
/// oversleeping extension's teardown would abort that operation and take
/// every other extension's satellite down with it.
///
/// Its own operation scopes `destroy`'s abort to the node being
/// destroyed, which is the only thing it ever meant.
///
/// The cost is one sentence, and it is a cost rather than a wash: a
/// launching call's own `cap_call`s no longer draw on the node's ledger,
/// because the node's ledger is not theirs. Nothing about what an
/// invocation may spend changes, because every invocation clears under
/// `Invoking.identity`, which stays the caller's.
fn node_operation(config: Config) -> OpId {
  let #(operation, _generator) =
    ids.mint_op(ids.generator(config.host.clock, seed: node_seed(config)))
  operation
}

// Eight bytes of the host's own entropy as a generator seed. The seed
// only has to be unrepeatable within a session — two hosts sharing an
// operation is the very thing above — and the host's entropy is the same
// source every cap token is minted from.
fn node_seed(config: Config) -> Int {
  config.host.entropy(8)
  |> bit_array.base16_encode
  |> int.base_parse(16)
  |> result.unwrap(0)
}

/// How long a satellite may live before its own jail's wall deadline kills
/// it, whatever any invocation asks for.
///
/// A node held open still has to have an end: the jail's wall limit is
/// what a runaway node dies against, and a satellite with no bound would
/// be one the operator could only stop by ending the session. Twelve hours
/// is far longer than a session and far shorter than forever, which is the
/// property wanted — this is a backstop, not a policy anybody tunes.
pub const host_lifetime_ms = 43_200_000

/// The session base with its two *time* limits cleared, so a node held
/// open for the session is bounded by the session rather than by the
/// numbers that bound one execution.
///
/// This is the difference between the two host shapes stated as code. A
/// code-mode node runs one program and dies, so the operator's `wall_s`
/// and `cpu_s` are exactly right for it. An extension's node runs no
/// program of its own: it waits, answers an invocation, and waits again.
/// Left alone, `codemode/launch.node_requirements` would clamp its wall
/// to the base's `wall_s` — ten minutes by default — and every session
/// would lose its extensions ten minutes in, whatever `host_lifetime_ms`
/// said. Zero means "no limit of its own" to `bound_wall`, which then
/// takes the pooled deadline, and that pooled deadline *is*
/// `host_lifetime_ms`.
///
/// What still bounds the extension's work is not weakened by this, and
/// it is worth being exact about what does. Every invocation is bounded
/// by the host's own state timeout, and a satellite that overruns one
/// loses its node; every jailed effect it clears goes through the broker
/// under a policy composed per call, carrying the base's limits
/// unmodified. What is genuinely unbounded is an extension burning CPU
/// *between* invocations, holding no capability — which is the authority
/// Decision 3 grants on purpose, and which the twelve-hour wall is the
/// backstop for.
///
/// Every other field of the base — the roots, the protected paths, the
/// network mode, the memory and process ceilings, the environment
/// allowlist — is passed through untouched.
fn session_lived(base: SandboxPolicy) -> SandboxPolicy {
  policy.SandboxPolicy(
    ..base,
    limits: policy.Limits(..base.limits, wall_s: 0, cpu_s: 0),
  )
}

// What one invocation is judged under: this call's clearance coordinates,
// this call's base policy, the extension's own router and its ceilings.
fn invoking(
  config: Config,
  written: Record,
  decoded: Manifest,
  egress: ext_policy.Egress,
  at: hosts.Coordinates,
) -> satellite.Invoking {
  satellite.Invoking(
    identity: identity.run_phase(identity.for_execution(
      op_id: at.op_id,
      step_id: at.step_id,
      budget: codemode.pooled_budget(config.host, invocation_deadline(config)),
    )),
    base_policy: codemode.execution_policy(at.base_policy),
    demand: at.demand,
    router: router(config, written, decoded, egress, at),
    ceilings: list.append(
      ext_policy.ceilings(decoded.net),
      workspace.ceilings(bridge(config, at)),
    ),
  )
}

// The wall bound the pooled budget of one invocation carries. The host's
// own state timeout is what ends an invocation; this is the ledger's copy
// of the same ceiling and is deliberately the operator's maximum rather
// than the manifest's, because a router refusing on a bound the host has
// not reached yet would refuse the wrong thing.
fn invocation_deadline(config: Config) -> Int {
  let #(now, _clock) = clock.read(config.host.clock)
  now + config.host.max_within_ms
}

// The installed artifact as the satellite host reads it. The beam set is
// the install's `artifact/` directory and the entry module is the one the
// generated entry source declared, so the two halves of what the install
// wrote are named from the same constants the install wrote them under.
//
// `manifest_hash` is the record's, which `installed.discover` has just
// re-derived from the bytes on disk with the build's own fingerprint
// function — so the address this session reports is a fact about the beams
// that actually ran.
fn artifact_at(artifact: String, written: Record) -> compile.Artifact {
  compile.Artifact(
    build_root: artifact,
    beam_dir: artifact,
    entry_module: compile.entry_module,
    manifest_hash: written.manifest_hash,
  )
}

/// How long this call may take: the manifest's `timeout_ms`, clamped to
/// the operator's ceiling on any one invocation.
///
/// The clamp is the same one `tools/codemode` applies to a `within_ms` a
/// model wrote, and it is here for the same reason one layer out. An
/// extension tool is `tool.Exclusive`, so the call holds the strand's
/// exclusive slot for the whole of its deadline, and `timeout_ms` is a
/// number in somebody else's repository — decoded as positive and
/// otherwise unbounded. The operator's `max_within_ms` is what says how
/// long *this host* will hold a strand for one call, and an install is not
/// a way to raise it.
///
/// ## Examples
///
/// ```gleam
/// // dispatch.within(config, declared) <= config.host.max_within_ms
/// ```
///
pub fn within(config: Config, declared: manifest.Tool) -> Int {
  int.min(declared.timeout_ms, config.host.max_within_ms)
}

// The two layers beneath the extension arm. See the module doc for why
// the MCP arm is not among them.
fn router(
  config: Config,
  written: Record,
  decoded: Manifest,
  egress: ext_policy.Egress,
  at: hosts.Coordinates,
) -> satellite.CapRouter {
  seam.routing(
    seam.Extension(egress: reaching(config, written, decoded, egress)),
    over: workspace.routing(bridge(config, at), over: satellite.default_router),
  )
}

// The workspace bridge this invocation reaches the host through: the very
// closures a code-mode program on this host gets, bound to this call's
// workspace and strand.
fn bridge(config: Config, at: hosts.Coordinates) -> workspace.Workspace {
  codemode.workspace_seam_for(
    config.host,
    workspace: at.workspace,
    strand: at.strand,
    protected: at.base_policy.protected,
  )
}

// How `net.request` is answered, with the policy and the credential
// lookup closed over.
//
// The closure is where the value of a bound secret exists and the only
// place it does: `egress.request` reads it through `config.secrets` after
// the origin and the method have already been judged, places it on the
// matching hop, and returns a `Response` that has no field for it. A
// refusal has none either, so the mapping below cannot leak one however it
// is worded.
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
  ext_policy.method(name)
  |> result.map_error(fn(_nil) {
    satellite.CapDenial(
      code: ext_policy.denied_code,
      message: "`"
        <> name
        <> "` is not an HTTP method this client can send; this extension's "
        <> "manifest permits "
        <> string.join(decoded.net.methods, ", "),
    )
  })
}

fn answered(response: egress.Response) -> seam.Answer {
  seam.Answer(
    status: response.status,
    headers: response.headers,
    body: response.body,
  )
}

// --- the settle -------------------------------------------------------------

/// The satellite's answer as a tool reply, on the model
/// `tools/codemode`'s own settle sets: a value is `is_error: False`, every
/// failure is `is_error: True`, and every one of them is a value rather
/// than a crash.
///
/// The one thing this settle has that code mode's does not is
/// `terminate`. `ext.Outcome` carries it, `ext/runtime` puts it on the
/// wire as a boolean, and it lands on `ToolOutcome.terminate` — the field
/// `core/entry.terminate` reads. A failed invocation never terminates: a
/// refusal is something the model repairs on its next turn, and a tool
/// that ended the run by failing would take that turn away.
///
/// Public because it is the one part of a dispatch a test can hold still.
/// An invocation's answer is a value, and turning one into a tool reply is
/// a pure function of it — where the rest of a call needs a broker, a
/// toolchain and a jailed node before it says anything at all.
///
/// ## Examples
///
/// ```gleam
/// // dispatch.settle(ctx, written, declared, Ok(value)).is_error == False
/// ```
///
pub fn settle(
  ctx: Ctx,
  written: Record,
  declared: manifest.Tool,
  answer: Result(MsgPackValue, hosts.HookFailure),
) -> ToolOutcome {
  case answer {
    Ok(value) -> completed(ctx, written, declared, value)

    Error(hosts.Refused(message:)) ->
      bounded(
        ctx,
        "the extension `" <> written.name <> "` refused this call: " <> message,
        failure_details(written, declared, "extension_failed", message),
        tool.ContinueRun,
        Refused,
      )

    Error(failure) ->
      failed(ctx, written.name, declared.name, failure_text(written, failure))
  }
}

// Why there is no answer at all, in one line for the model to read.
//
// Each is a different instruction. An unhandled event is nothing to
// repair; a crash is the extension's bug; a deadline and a departed host
// both mean the satellite is gone, and the second says it will stay gone,
// so a model that reads it stops trying.
fn failure_text(written: Record, failure: hosts.HookFailure) -> String {
  case failure {
    hosts.Unhandled -> "this extension registers no handler for that event"
    hosts.Refused(message:) -> message
    hosts.Crashed(reason:) ->
      "the extension's code crashed while answering: " <> reason
    hosts.Deadline ->
      "the call did not finish inside the extension's own timeout, so its "
      <> "satellite was destroyed and this extension is unavailable for the "
      <> "rest of this session"

    // The reason says whether this is permanent — a satellite destroyed
    // is out for the session, a registry that did not answer in time is
    // not — because a model told "unavailable for the rest of this
    // session" about a busy moment would stop trying for no reason.
    hosts.Gone(reason:) ->
      "the extension `" <> written.name <> "` could not be reached: " <> reason
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
    Answered,
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

fn failure_details(
  written: Record,
  declared: manifest.Tool,
  status: String,
  message: String,
) -> JsonValue {
  json.Object([
    #("status", json.String(status)),
    #("extension", json.String(written.name)),
    #("tool", json.String(declared.name)),
    #("manifest_hash", json.String(written.manifest_hash)),
    #("message", json.String(message)),
  ])
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
    Refused,
  )
}

// Whether a reply is the model's to act on or the model's to repair.
//
// `ToolOutcome.is_error` is the frozen field underneath, and this is the
// domain name for it: `bounded(ctx, text, details, ContinueRun, True)`
// says nothing at the call site about which `True` means, and there are
// four such call sites here.
type Standing {
  /// The extension answered. `is_error: False`.
  Answered

  /// The extension refused, or the execution never produced an outcome.
  /// `is_error: True`, in band, for the model to read and repair.
  Refused
}

fn errored(standing: Standing) -> Bool {
  case standing {
    Answered -> False
    Refused -> True
  }
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
  standing: Standing,
) -> ToolOutcome {
  let is_error = errored(standing)
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
