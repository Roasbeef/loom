//// Code mode: `tools/codemode`'s seam, implemented over the real
//// pipeline.
////
//// `tools` cannot see `codemode` — `codemode` already depends on `tools`
//// for the `tool.Collected` its capability router renders — so the two
//// meet here, in the only package that depends on both. `tools/codemode`
//// declares a record of closures in plain data, this module fills it, and
//// the `code_mode` tool stays what a tool is in this codebase: a name, a
//// schema, and a total `run` that turns every failure into a structured
//// result the model can act on.
////
//// ## Two seams, one pipeline
////
//// There are two code-mode seams, and `Config.surface` says which of them
//// this host serves. The **workspace** seam is what `default_config`
//// builds: `cap/{fs, proc, net, git, lsp, report, task, actor, kv}`, routed
//// by `satellite.default_router`, a program that orchestrates *effects*.
//// The **orchestration** seam is `cap/strand` plus `cap/report` and
//// nothing else, routed onto the Agency closures the `agent_*` tools call,
//// a program that orchestrates *agents*. A host may serve either alone or
//// both (`Surface`, `serving`); when it serves both, a submission names
//// the one it wants and the tool defaults it to the workspace seam.
////
//// One field rather than two, because the vetting allowlist and the
//// capability router have to agree and a host that could set them apart
//// would eventually set them apart. Which capabilities travel together is
//// the point of the separation, so it is not a thing to be assembled from
//// two places.
////
//// The two halves are read from different places on purpose, and the
//// asymmetry is the security property. The **allowlist follows the
//// submission**: a program is vetted against exactly the seam it named,
//// so a refusal it reads is about the surface it asked for. The **router
//// follows the host**: a surface serving one seam hands out that seam's
//// router whatever a request names, so no submission can widen what the
//// host wired. Where the two could disagree — a request naming a seam
//// this host does not serve — `execute` refuses before anything is
//// dispatched, and the fallback under that refusal is narrowing in both
//// directions anyway: a program vetted against one seam's imports and
//// routed by the other's can call nothing at all, because it cannot
//// import the modules whose calls that router services.
////
//// `client/serve` defaults to the workspace seam and takes the choice as
//// a setting; a host assembling its own registry passes
//// `codemode.seam(codemode.orchestrating(config, over: agency))`, or
//// `codemode.serving(config, codemode.BothSeams, over: agency)` to leave
//// the choice to the model.
////
//// ## One execution, one identity, one budget
////
//// Everything a code-mode call does — the hermetic `gleam build`, the
//// jailed `erl`, and every capability call the running program makes —
//// is dispatched under the calling strand's own `{op_id, step_id}`. That
//// pair is the *batch* identity the broker pools budget on
//// (`packages/broker/CLAUDE.md`, "Budget is pooled per execution"), so
//// using it rather than a minted one has three consequences worth stating
//// plainly: the compile and the run draw on one ledger and one wall
//// deadline instead of two, `broker.abort` on the operation reaches the
//// build and the node alike, and a program that fans out buys parallelism
//// rather than extra resources.
////
//// The pair is not unique per execution and nothing here should assume it
//// is: `code_mode` is `tool.Exclusive`, which forbids a concurrent start
//// and nothing more, so one batch may hold two `code_mode` calls at
//// different source indices. `{op_id, step_id, source_index}` is the
//// execution identity; `exec_root` digests that triple, and the ledger
//// keys on the pair deliberately (`docs/adr/005-budget-pooling-
//// granularity.md`, "Two programs in one batch").
////
//// The pooled cap must be at least two — the satellite node itself holds
//// one outstanding effect for its whole life, so a cap of one would starve
//// every `cap_call` the program makes; `launch` refuses such a budget in
//// band rather than hanging.
////
//// ## What an approved escalation widens
////
//// The same threaded identity carries the grants an approval attributed
//// to this execution (`identity.widened_by`), and the pipeline composes
//// them at the *run* phase alone: the satellite node's clearance and
//// every capability call the program makes. The hermetic build is never
//// widened — see `codemode/identity`, "The widening, and why it lives
//// here" — and there is no session-wide grant list anywhere below, so an
//// approval that cannot be attributed to one execution widens nothing.
////
//// `approved_grants` reads `Request.grants`, which `tools/codemode.request`
//// fills from `tool.Ctx.grants` — so an approval consumed for this call
//// reaches the run phase, and only the run phase.
////
//// ## Reporting a refusal outward, so that something can mint one
////
//// The paragraph above is the half of the loop that *spends* an approval.
//// The other half is where one comes from, and for a long time there was
//// nowhere: this module clears through the broker it holds rather than
//// through `tool.Ctx.clear_call`, so a policy refusal inside a code-mode
//// execution reached no escalation plane and no durable record, and there
//// was nothing for a human to approve (#97).
////
//// So `execute` **watches** the one stage an approval could widen and
//// reports what composition refused, as a `codemode_tool.PolicyRefusal`
//// beside the outcome. It is a peer of the enforcement report and not a
//// field inside it, for the reason `codemode`'s own `widening` is one: an
//// enforcement report is the helper's verbatim account of a stage that
//// *ran*, and a refusal is the harness deciding a stage may not.
////
//// That stage is the satellite **launch**, and it is the only one, which
//// is a decision about what "a policy refusal for a whole execution"
//// means rather than an omission. The pipeline clears on policy in three
//// places and the other two are unraisable, each for its own reason.
////
//// The **hermetic build** clears with no grants at all:
//// `identity.build_phase` drops this execution's approval before the
//// build composes anything, because grants apply *after* the meet and one
//// reaching the build would undo the offline, pinned property the build
//// exists to have. A build refused on policy is therefore an operator's
//// misconfiguration and no answer a human could give would change it —
//// asking would be filing a decision nobody can act on. The model reads
//// the build's own verbatim reason in `CompileFailed` regardless.
////
//// A **capability call** refused inside a running program is refused
//// after the program has already performed effects. The one thing an
//// approval buys is a re-execution (design §5.3), `code_mode` is
//// `replay: tool.Never` precisely because a program's capability calls
//// have nothing to reconcile onto, and re-running a submission to widen
//// its seventh call would replay the first six. The consent unit would be
//// wrong too: a human is asked about the *program*, and by then the
//// program is half-spent. So that refusal is handed to the program, which
//// is the party that can still route around it, and to the model in the
//// outcome the program returns.
////
//// The launch is the one refusal with none of those problems: the node
//// has not started, so no capability call has been serviced and nothing
//// of the program has run. A re-execution under the widened policy
//// repeats no effect, and the action a human consents to is still the
//// whole submitted program.
////
//// The watching is done by wrapping the `satellite.Launcher` the pipeline
//// already takes as an injected value, and asking — only once the launch
//// has already refused — the same policy question the launch asked:
//// `policy.compose` over the same base, the same requirements (through
//// `launch.node_requirements`, the launch's own function, so there is
//// nothing here to drift), and the same grants. Nothing is
//// re-implemented and no reason text is parsed.
////
//// ## The two env names, and why they are added here
////
//// The boot runtime inside the satellite finds its socket and its token
//// through `LOOM_CAP_SOCK` and `LOOM_CAP_TOKEN_FILE`, which the launcher
//// sets itself and a caller's `env` cannot shadow. Policy composition
//// takes the meet, so an execution whose base policy does not *name* those
//// two variables composes them away and the node comes up unable to find
//// the channel it exists to speak on — reported honestly as a launch
//// refusal, but a dead feature all the same.
////
//// `execution_policy` therefore derives the base a code-mode execution
//// runs under from the session base by adding exactly those two names and
//// nothing else. Their values are the harness's own paths, minted per
//// execution and never model-supplied, so this widens what the launcher
//// may *state* rather than what a program may reach: the jail, the token
//// binding, and the broker's per-call policy check are all untouched. It
//// is written as one small named function precisely so it stays auditable
//// rather than diffusing into the wiring.
////
//// ## Where an execution's files live
////
//// Under `work_root`, one directory per `{op_id, step_id, source_index}`
//// — named by a short digest of that triple, for reasons `exec_root`
//// explains — holding
//// the cloned build seed, the compiled `.beam` set, the cap socket, and
//// the private token file. Two properties fall out of the placement. It
//// is inside the workspace, so the session base already makes it writable
//// and no policy has to be widened to build there; and it is unique per
//// execution, so neither two strands running code mode at the same time
//// nor two `code_mode` calls in one batch can share a build root. The
//// directory is removed once the execution
//// settles — the seed clone is large and every build clones it fresh
//// anyway.

import broker/broker.{type Broker}
import broker/budget.{type Budget}
import broker/escalation
import broker/policy.{type Grant, type SandboxPolicy}
import broker/token
import client/install
import client/internal/ffi_os
import client/mcp as mcp_wiring
import client/scheduleseam
import client/scratch
import codemode/artifact
import codemode/build
import codemode/codemode as pipeline
import codemode/compile
import codemode/enforcement
import codemode/identity
import codemode/launch
import codemode/orchestration
import codemode/satellite
import codemode/seed
import codemode/vet
import codemode/vet/policy as vet_policy
import codemode/workspace
import core/clock.{type Clock}
import core/ids.{type OpId}
import gleam/bit_array
import gleam/bool
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import tools/agent.{type Agency}
import tools/blob
import tools/codemode as codemode_tool
import tools/fs
import tools/schedule as schedule_tool
import tools/tool

/// The smallest pooled outstanding-effect cap a satellite can live under:
/// the node holds one for its whole life, so anything less starves the
/// program's first capability call. `launch` enforces the same floor.
pub const minimum_outstanding = 2

/// Everything the production seam needs beyond one request.
///
/// Constructor invariants: `work_root` is an absolute directory inside the
/// workspace the sessions' base policy makes writable; `gleam_path`,
/// `erl_path` and `seed_root` are the located toolchain
/// (`discover`); `toolchain_path` is a `PATH` covering both executables,
/// because `gleam build` shells out to `erl`; `max_outstanding` is at
/// least `minimum_outstanding`; and `default_within_ms` is at most
/// `max_within_ms`.
pub type Config {
  Config(
    /// The running broker every jailed stage is dispatched through.
    broker: Broker,
    /// The session's one clock; deadlines here are absolute Unix ms.
    clock: Clock,
    /// Token entropy for the cap channel.
    entropy: fn(Int) -> BitArray,
    /// Where per-execution directories are created.
    work_root: String,
    /// The prepared build seed (`make codemode-seed`).
    seed_root: String,
    /// Absolute path to `gleam`.
    gleam_path: String,
    /// Absolute path to `erl`.
    erl_path: String,
    /// A `PATH` for the hermetic build, covering both executables.
    toolchain_path: String,
    /// Which of the two seams this host's `code_mode` serves. It decides
    /// the vetting allowlist *and* the capability router together; see
    /// the module doc for why that is one field.
    surface: Surface,
    /// Where the session keeps its content-addressed blobs, and
    /// therefore where a `report.emit` artifact lands.
    ///
    /// The *same* directory `tool.Ctx.blob_root` names, deliberately: an
    /// artifact a program emitted and an oversized `bash` output that
    /// overflowed are the same kind of thing under the same addressing
    /// scheme, and two stores would mean an id that means one thing here
    /// and another there. `default_config` derives it from the workspace
    /// exactly as `client/serve` does, through the one shared
    /// `blob_directory` constant, so the two cannot drift.
    blob_root: String,
    /// The ephemeral scratch store `kv.*` reads and writes.
    ///
    /// A seam over a process name rather than a store of its own: the
    /// store is session-scoped and supervised, and this configuration is
    /// assembled before it is started (`client/scratch`). A host that
    /// wired none hands out `scratch.none()`, whose calls refuse in band
    /// naming the reason — never a silent success, which a program would
    /// read as an eviction and loop on.
    scratch: Scratch,
    /// The scheduling door `schedule.*` reaches, or `None` when the
    /// operator shut it.
    ///
    /// A door rather than a runtime, for the same reason `scratch` is a
    /// seam over a name: this configuration is assembled before
    /// `api.open` has returned a runtime, and the door closes over the
    /// borrow instead (`client/scheduleseam.door`). `None` leaves the
    /// three capabilities unrouted, so a program calling one meets the
    /// ordinary unknown-capability denial rather than a door that always
    /// refuses — the same posture the tool registry takes, one layer
    /// down.
    schedules: Option(scheduleseam.Door),
    /// The MCP servers this host reached at boot, if any.
    ///
    /// One field for the same reason `surface` is one: a configured
    /// server widens the workspace seam's allowlist, adds its rendered
    /// module surface to the description, puts its generated source in
    /// the hermetic build, and adds a router arm — four halves of one
    /// decision, and a host that could set them apart would eventually
    /// set them apart. `mcp.none()` is the empty layer every host has
    /// until an operator configures a server.
    mcp: McpLayer,
    /// The pooled outstanding-effect cap for a whole execution.
    max_outstanding: Int,
    /// How long the hermetic build itself may take.
    build_timeout_ms: Int,
    /// How long to wait for the satellite to connect back.
    accept_timeout_ms: Int,
    /// How long to wait for one capability call's settlement.
    call_timeout_ms: Int,
    /// The wall budget used when a call names none.
    default_within_ms: Int,
    /// The ceiling a call's `within_ms` is clamped to.
    max_within_ms: Int,
  )
}

/// The MCP layer a host serves code mode over: `client/mcp`'s own type,
/// aliased so a `Config` reads without a second import at every call
/// site.
pub type McpLayer =
  mcp_wiring.Layer

/// The scratch-store seam a host serves `kv.*` over: `client/scratch`'s
/// own type, aliased for the reason `McpLayer` is.
pub type Scratch =
  scratch.Scratch

/// The same host configuration, serving `kv.*` over a running scratch
/// store.
///
/// A host that never calls this serves `scratch.none()`, and every
/// `kv.*` call refuses in band saying so. That is the honest default: a
/// store nobody started cannot hold anything, and answering `Ok` to a
/// `set` that vanished is worse than refusing it.
///
/// ## Examples
///
/// ```gleam
/// // codemode.default_config(broker, clock, workspace, toolchain)
/// // |> codemode.over_scratch(scratch.seam(name, timeout_ms: 1000))
/// ```
///
pub fn over_scratch(config: Config, store: Scratch) -> Config {
  Config(..config, scratch: store)
}

/// The same host configuration, serving `schedule.*` over one scheduling
/// door.
///
/// A host that never calls this leaves the three capabilities unrouted,
/// so a program calling one meets the ordinary unknown-capability denial
/// — which is what an operator who shut the door should get, and is a
/// clearer answer than a door that exists and always refuses.
///
/// ## Examples
///
/// ```gleam
/// // codemode.over_schedules(config, scheduleseam.door(wiring))
/// ```
///
pub fn over_schedules(
  config: Config,
  door: Option(scheduleseam.Door),
) -> Config {
  Config(..config, schedules: door)
}

/// The same host configuration, writing `report.emit` artifacts into a
/// blob root other than the one derived from the workspace.
///
/// ## Examples
///
/// ```gleam
/// // codemode.into_blobs(config, "/var/lib/loom/blobs")
/// ```
///
pub fn into_blobs(config: Config, blob_root: String) -> Config {
  Config(..config, blob_root:)
}

/// Which of the two code-mode seams a host serves, and what the
/// orchestration one needs to be served with.
///
/// The variants carry different things because they *are* different
/// things: a workspace program needs nothing beyond the pipeline, and an
/// orchestration program needs the messaging plane it orchestrates
/// through and the ceiling on how much of it one execution may spend.
///
/// A host with no messaging plane simply does not build the second one.
/// There is deliberately no `Orchestration` without an `Agency`: a seam
/// that vetted `cap/strand` and then answered every call
/// `strands_unavailable` would be a tool surface the model is charged for
/// on every request and can never use.
///
/// `Both` is a third variant rather than a flag on the second, for the
/// same reason: an orchestration-only host is a real posture — code mode
/// that can start agents and touch neither disk, process nor socket — and
/// folding it into "orchestration implies workspace" would quietly take
/// it away.
pub type Surface {
  /// `cap/{fs, proc, net, git, lsp, report, task, actor, kv}`, routed by
  /// `satellite.default_router`.
  Workspace

  /// `cap/strand` + `cap/report`, routed onto the Agency closures.
  Orchestration(agency: Agency, spawn_ceiling: Int)

  /// Both, with each submission naming the seam it wants; the workspace
  /// seam is what one that names none is judged against.
  Both(agency: Agency, spawn_ceiling: Int)
}

/// Which seams a host means to serve, as a *setting*: the choice a flag
/// or a config file can carry, before there is an `Agency` to serve the
/// orchestration seam with. `serving` turns one of these plus an Agency
/// into the `Surface` a `Config` holds.
pub type Seams {
  /// The workspace seam alone — the shipped default.
  WorkspaceOnly

  /// The orchestration seam alone.
  OrchestrationOnly

  /// Both, with the submission choosing.
  BothSeams
}

/// The same host configuration, serving the seams a setting names over a
/// messaging plane.
///
/// The allowlist a submission is judged against, the router that services
/// it and the spawn ceiling all move together, because they are one
/// field.
///
/// ## Examples
///
/// ```gleam
/// // codemode.default_config(broker, clock, workspace, toolchain)
/// // |> codemode.serving(codemode.BothSeams, over: agency_seam)
/// ```
///
pub fn serving(config: Config, seams: Seams, over agency: Agency) -> Config {
  let spawn_ceiling = orchestration.default_spawn_ceiling
  Config(..config, surface: case seams {
    WorkspaceOnly -> Workspace
    OrchestrationOnly -> Orchestration(agency:, spawn_ceiling:)
    BothSeams -> Both(agency:, spawn_ceiling:)
  })
}

/// The same host configuration, serving the orchestration seam over a
/// messaging plane instead of the workspace seam.
///
/// ## Examples
///
/// ```gleam
/// // codemode.default_config(broker, clock, workspace, toolchain)
/// // |> codemode.orchestrating(over: agency.seam(agency_config))
/// ```
///
pub fn orchestrating(config: Config, over agency: Agency) -> Config {
  serving(config, OrchestrationOnly, over: agency)
}

/// The same host configuration, serving the workspace seam over the MCP
/// servers this host reached at boot.
///
/// A layer with no servers changes nothing — no module is allowed, no
/// surface rendered, no arm routed — so a host may call this
/// unconditionally with whatever `client/mcp.start` returned.
///
/// ## Examples
///
/// ```gleam
/// // codemode.default_config(broker, clock, workspace, toolchain)
/// // |> codemode.over_mcp(layer)
/// ```
///
pub fn over_mcp(config: Config, layer: McpLayer) -> Config {
  Config(..config, mcp: layer)
}

/// The vetting allowlist one seam judges a submission against.
///
/// Indexed by the seam and not by the surface: a program is vetted
/// against exactly the seam it named, so the refusal it reads is about
/// the surface it asked for rather than about the host's default.
///
/// ## Examples
///
/// ```gleam
/// // codemode.seam_policy(vet_policy.WorkspaceSeam) == vet_policy.default()
/// ```
///
pub fn seam_policy(seam: vet_policy.Seam) -> vet_policy.VetPolicy {
  vet_policy.for_seam(seam)
}

/// The vetting allowlist *this host* judges a submission against: the
/// seam's own, widened by the capability modules the MCP layer
/// generated at boot.
///
/// The widening is per host and cannot be otherwise. A generated
/// `cap/mcp/<server>` façade exists only where that server is
/// configured, so no static list in `codemode/vet/policy` could name
/// one; `cap/mcp` — the types-only vocabulary the façades import — stays
/// off every static seam for the same reason, and is allowed here
/// beside them (`vet_policy.harness_only_cap_modules`).
///
/// It widens nothing on a host with no servers, which is every host
/// until an operator configures one.
///
/// ## Examples
///
/// ```gleam
/// // vet_policy.allowed_imports(codemode.seam_allowlist(config, seam))
/// ```
///
pub fn seam_allowlist(
  config: Config,
  seam: vet_policy.Seam,
) -> vet_policy.VetPolicy {
  mcp_wiring.allowed_imports(seam_mcp(config, seam))
  |> list.fold(seam_policy(seam), vet_policy.allow)
}

// The MCP layer one seam sees, and the one place that decision is made.
//
// **The orchestration seam sees none of it, ever.** Which capabilities
// travel together is the whole of what the two-seam split buys: an
// orchestrator that could also call out to a third-party MCP server is
// a materially worse thing to hand a model than one that cannot, and
// the disjointness a test pins is over the two allowlists — so a
// per-host widening that reached both would walk straight past it.
// Every derived thing an MCP server contributes — the allowlist entry,
// the rendered surface, the generated source, the serviced capability
// name — reads its layer through here, so there is one arm to get wrong
// rather than four.
fn seam_mcp(config: Config, seam: vet_policy.Seam) -> McpLayer {
  case seam {
    vet_policy.WorkspaceSeam -> config.mcp

    // The extension seam sees none of it either, and for a different
    // reason than the orchestration seam's: an extension's allowlist is
    // fixed at install and recorded, and a per-host widening applied
    // afterwards would make an installed extension's reach depend on
    // configuration the record never saw.
    // The resident seam has no loader and therefore no host to widen
    // from; it reaches nothing at all, MCP included.
    vet_policy.ExtensionSeam
    | vet_policy.OrchestrationSeam
    | vet_policy.ResidentSeam -> mcp_wiring.none()
  }
}

/// Every seam a surface serves, the default first.
///
/// ## Examples
///
/// ```gleam
/// assert codemode.surface_seams(codemode.Workspace)
///   == [vet_policy.WorkspaceSeam]
/// ```
///
pub fn surface_seams(surface: Surface) -> List(vet_policy.Seam) {
  case surface {
    Workspace -> [vet_policy.WorkspaceSeam]
    Orchestration(..) -> [vet_policy.OrchestrationSeam]
    Both(..) -> [vet_policy.WorkspaceSeam, vet_policy.OrchestrationSeam]
  }
}

/// The seam a submission that names none is judged against: the first one
/// this surface serves.
///
/// ## Examples
///
/// ```gleam
/// assert codemode.surface_seam(codemode.Workspace)
///   == vet_policy.WorkspaceSeam
/// ```
///
pub fn surface_seam(surface: Surface) -> vet_policy.Seam {
  case surface {
    Workspace | Both(..) -> vet_policy.WorkspaceSeam
    Orchestration(..) -> vet_policy.OrchestrationSeam
  }
}

/// The capability names one seam's router actually services. Published
/// through the seam so the tool's description tells the model the truth
/// rather than a copy that can drift from the router.
///
/// ## Examples
///
/// The workspace seam's list is two routers' worth: `satellite.default_
/// router`'s jailed `proc.run`, and `codemode/workspace`'s harness-side
/// arm. Both are read off the modules that answer them rather than
/// written out here, so a capability that stops being serviced stops
/// being advertised in the same commit.
///
/// ## Examples
///
/// ```gleam
/// // codemode.seam_caps(vet_policy.WorkspaceSeam)
/// //   == ["proc.run", "fs.read", "fs.list", "kv.get", …]
/// ```
///
pub fn seam_caps(seam: vet_policy.Seam) -> List(String) {
  case seam {
    vet_policy.WorkspaceSeam ->
      list.append(serviced_caps, workspace.serviced_caps)
    vet_policy.OrchestrationSeam -> orchestration.serviced_caps

    // Phase 1 installs and compiles an extension; nothing dispatches one
    // yet, so no router services this seam and advertising a capability
    // would be a claim about a door that is not there. Written as its own
    // arm rather than folded into the workspace one, so phase 2 has to
    // change it deliberately.
    vet_policy.ExtensionSeam -> []

    // The resident seam services nothing by construction: a body admitted
    // under it reaches no capability at all, which is the whole of what
    // makes a harness-resident body safe to consider (#33).
    vet_policy.ResidentSeam -> []
  }
}

/// The capability names one seam's router services *on this host*: the
/// seam's own, plus one `mcp.<server>` per MCP server the layer
/// reached.
///
/// Read off the running layer rather than copied, for the reason
/// `seam_caps` is: the sentence the model is charged for on every
/// request must not be able to drift from the router that answers it.
///
/// ## Examples
///
/// ```gleam
/// // codemode.seam_caps_on(config, vet_policy.WorkspaceSeam)
/// //   == ["proc.run", "mcp.github"]
/// ```
///
pub fn seam_caps_on(config: Config, seam: vet_policy.Seam) -> List(String) {
  list.append(seam_caps(seam), mcp_wiring.serviced_caps(seam_mcp(config, seam)))
}

/// The pooled outstanding-effect cap one execution runs under. Above the
/// floor of two the satellite needs for itself, so a program can fan a few
/// capability calls out at once — sharing this cap and one deadline, which
/// is the point of pooling.
pub const default_outstanding = 6

/// The wall budget a `code_mode` call gets when it names none. A hermetic
/// build is tens of seconds before the program starts, so the default is
/// generous.
pub const default_within_ms = 300_000

/// The ceiling a call's `within_ms` is clamped to: where an operator would
/// rather abort than keep waiting.
pub const max_within_ms = 900_000

/// How long the hermetic build itself may take. Under `max_within_ms`, so
/// a build that hangs still leaves the execution's deadline to end it.
pub const default_build_timeout_ms = 180_000

/// How long to wait for a launched satellite to connect back to the cap
/// socket, and how long one capability call may take to settle.
pub const default_accept_timeout_ms = 30_000

/// How long one capability call may take to settle.
///
/// Must stay **above** every bound a serviced capability answers under,
/// so the capability's own bound is the one that fires and the program
/// reads that answer rather than silence. Two are pinned by tests in this
/// package: `client/mcp.default_call_timeout_ms` (60 s), and
/// `client/agency.default_config`'s `max_wait_ms` (30 s), the ceiling a
/// `strand.wait` is clamped to. Invert either and the host gives up
/// first — a `ServedHere` call it abandons is answered `unsettled` and
/// its worker killed, so every `wait` would trade a real answer for that
/// refusal, and the work behind it would be stopped half-done rather
/// than finished for nobody.
pub const default_call_timeout_ms = 120_000

/// Where an execution's directories are created, relative to the
/// workspace. Inside it, so the session base already makes it writable.
pub const work_directory = ".codemode"

/// Where the session's content-addressed blobs live, relative to the
/// workspace.
///
/// Stated once, here, and read by both the place that fills
/// `tool.Ctx.blob_root` (`client/serve`) and the place that fills
/// `Config.blob_root`. Two literals would be two stores the day one of
/// them moved, and an artifact id that resolves in one and not the other
/// is the worst shape that failure could take — it would look like a
/// missing artifact rather than like a misconfiguration.
pub const blob_directory = ".blobs"

/// The shipped configuration for a located toolchain: the vetting default,
/// the pooled budget, the timeouts, and a work root inside the workspace.
///
/// One place holds the numbers, so `serve` states none of them and a host
/// that wants different ones edits the record it is handed rather than
/// re-deriving the whole configuration.
///
/// ## Examples
///
/// ```gleam
/// // codemode.default_config(broker, clock, "/work", toolchain).work_root
/// //   == "/work/.codemode"
/// ```
///
pub fn default_config(
  broker broker: Broker,
  clock clock: Clock,
  workspace workspace: String,
  toolchain toolchain: Toolchain,
) -> Config {
  Config(
    broker:,
    clock:,
    entropy: token.production_entropy(),
    work_root: workspace <> "/" <> work_directory,
    seed_root: toolchain.seed_root,
    gleam_path: toolchain.gleam_path,
    erl_path: toolchain.erl_path,
    toolchain_path: toolchain_path(toolchain),
    surface: Workspace,
    blob_root: workspace <> "/" <> blob_directory,
    scratch: scratch.none(),
    // No scheduling plane by default, the same posture `scratch.none()`
    // and `mcp.none()` take: a host wires one deliberately, and
    // `client/serve` does when the operator's policy leaves the door
    // open.
    schedules: None,
    mcp: mcp_wiring.none(),
    max_outstanding: default_outstanding,
    build_timeout_ms: default_build_timeout_ms,
    accept_timeout_ms: default_accept_timeout_ms,
    call_timeout_ms: default_call_timeout_ms,
    default_within_ms:,
    max_within_ms:,
  )
}

/// The located toolchain a code-mode execution needs on this host.
pub type Toolchain {
  Toolchain(gleam_path: String, erl_path: String, seed_root: String)
}

/// The capability names the shipped *default* router services — the ones
/// that become a jailed clearance. Published through the seam so the
/// tool's description tells the model the truth rather than a copy that
/// can drift from `satellite.default_router`.
///
/// This is not the whole workspace seam: `seam_caps` appends
/// `codemode/workspace.serviced_caps`, the harness-side arm, and
/// `seam_caps_on` appends one `mcp.<server>` per configured server. Three
/// routers, three lists, each read off its own module.
pub const serviced_caps = ["proc.run"]

// --- discovery -------------------------------------------------------------

/// Locates what this host needs to run code mode, or says what is missing
/// *and how to supply it*.
///
/// Three questions, each answered against the host rather than assumed:
/// where `gleam` is, where `erl` is, and whether there is a prepared build
/// seed at `seed_root` whose dependency table is byte-identical to the one
/// the compile service generates. The last is `seed.verify`, and it is the
/// interesting one: a seed prepared from a different table resolved a
/// different dependency graph, so building against it would pin something
/// other than what the compile service says it pins.
///
/// The first two used to be "is it on `PATH`", and that is what made code
/// mode absent from an unpacked release even though **the release ships
/// `erl` inside it** — `erts-<vsn>/bin/erl`, sitting in the tarball, never
/// on `PATH`. Both now ask `client/install` first; see `locate`.
///
/// A host that fails any of them registers no `code_mode` tool at all,
/// which is why this returns the reason: a tool definition is a cache
/// prefix paid on every request of every strand for the life of the
/// session, so advertising one that can only refuse is worse than
/// omitting it. What the boot prints therefore has to carry the whole
/// remedy, because it is the only thing anybody will ever see about it.
///
/// ## Examples
///
/// ```gleam
/// // let assert Error(reason) = codemode.discover("/nowhere")
/// ```
///
pub fn discover(seed_root: String) -> Result(Toolchain, String) {
  use gleam_path <- result.try(locate(
    "gleam",
    beside: install.gleam_compiler(),
    remedy: "code mode compiles the model's program with it, so put `gleam` "
      <> "(>= 1.18) on PATH, or run the `bin/loomd` of a release built with "
      <> "the code-mode bundle, which ships one",
  ))
  use erl_path <- result.try(locate(
    "erl",
    beside: install.erl(),
    remedy: "code mode runs the compiled program in a jailed BEAM, so put "
      <> "`erl` (OTP >= 29) on PATH",
  ))
  use _verified <- result.try(
    seed.verify(seed_root, compile.default_dependencies())
    |> result.map_error(seed_remedy),
  )
  Ok(Toolchain(gleam_path:, erl_path:, seed_root:))
}

/// One executable of the code-mode toolchain: the copy shipped beside
/// this server if there is one, then `PATH`.
///
/// `beside` outranks `PATH` for both of the toolchain's executables, and
/// for `erl` it is not merely a fallback for releases. `install.erl()` is
/// the emulator of the ERTS *this VM is running*, and a satellite loads
/// `.beam` files the hermetic build produced against that same OTP —
/// whereas the first `erl` on `PATH` is whichever installation a shell
/// profile points at, which on a host with two OTPs is a coin flip.
///
/// The failure is one sentence naming both places that were looked and
/// the way out, because it is the only thing the operator will ever see:
/// there is no tool to fail later.
///
/// ## Examples
///
/// ```gleam
/// // codemode.locate("sh", beside: "/bin/sh", remedy: "…") == Ok("/bin/sh")
/// ```
///
pub fn locate(
  name: String,
  beside beside: String,
  remedy remedy: String,
) -> Result(String, String) {
  install.existing_file(beside)
  |> result.lazy_or(fn() { ffi_os.find_executable(name) })
  // map_error rather than replace_error: the message concatenates four
  // strings and is wanted on approximately no boots at all.
  |> result.map_error(fn(_nil) {
    name
    <> " is not beside this server at "
    <> beside
    <> " and not on PATH; "
    <> remedy
    <> ". No code_mode tool is registered."
  })
}

// `seed.verify` says exactly what is wrong with a seed and points at the
// one command that repairs a checkout's own. What it cannot know is that
// this server might be an unpacked release, where there is no checkout
// and no `make`, so the two other ways to supply a seed are added here —
// where `client/install` is in scope and the question "is this a
// release" is answerable.
fn seed_remedy(reason: String) -> String {
  reason
  <> " — or pass --codemode-seed <dir>. A release built with the code-mode "
  <> "bundle ships a prepared seed at "
  <> install.seed()
  <> ". No code_mode tool is registered."
}

/// A `PATH` for the hermetic build, built from where the executables were
/// actually found rather than guessed. `gleam build` shells out to `erl`,
/// so both directories have to be on it.
///
/// ## Examples
///
/// ```gleam
/// // codemode.toolchain_path(found) == "/usr/local/bin:/usr/bin:/bin"
/// ```
///
pub fn toolchain_path(toolchain: Toolchain) -> String {
  [
    directory_of(toolchain.gleam_path),
    directory_of(toolchain.erl_path),
    "/usr/local/bin",
    "/usr/bin",
    "/bin",
  ]
  |> list.unique
  |> string.join(":")
}

// --- the seam --------------------------------------------------------------

/// Builds the production seam: the closure `tools/codemode` calls, plus
/// the allowlist and the serviced capability names its description states.
///
/// ## Examples
///
/// ```gleam
/// // contributions.built_in(_, option.Some(codemode.seam(config)), ..)
/// ```
///
pub fn seam(config: Config) -> codemode_tool.CodeMode {
  codemode_tool.CodeMode(
    execute: fn(request) { execute(config, request) },
    seams: offered_seams(config),
    default_within_ms: config.default_within_ms,
    max_within_ms: config.max_within_ms,
  )
}

// What the tool may offer a model: exactly the seams this surface serves,
// each carrying the allowlist `execute` will judge that seam's
// submissions against and the capabilities its router will service. The
// tool refuses anything else, so a model can never name a seam that would
// arrive here unserved.
//
// `surface_seams` is non-empty for every surface, so the fallback below
// is unreachable; it is a workspace-seam offer rather than a panic
// because a `code_mode` that vanished would be a worse answer to a bug
// than one that serves the narrower of the two.
fn offered_seams(config: Config) -> codemode_tool.Seams {
  let offers =
    list.filter_map(surface_seams(config.surface), fn(seam) {
      use named <- result.map(tool_seam(seam))
      seam_offer(config, seam, named)
    })
  case offers {
    [] ->
      codemode_tool.one_seam(seam_offer(
        config,
        vet_policy.WorkspaceSeam,
        codemode_tool.WorkspaceSeam,
      ))
    [default, ..alternates] -> codemode_tool.Seams(default:, alternates:)
  }
}

// Everything a seam offers, read off this host's running configuration:
// the allowlist `execute` will judge that seam's submissions against,
// the capabilities its router will service, and the module surfaces the
// host generated rather than shipped.
fn seam_offer(
  config: Config,
  seam: vet_policy.Seam,
  named: codemode_tool.Seam,
) -> codemode_tool.SeamOffer {
  codemode_tool.SeamOffer(
    seam: named,
    allowed_imports: vet_policy.allowed_imports(seam_allowlist(config, seam)),
    serviced_caps: seam_caps_on(config, seam),
    extra_surfaces: mcp_wiring.surfaces(seam_mcp(config, seam)),
  )
}

/// One seam in the vocabulary the tool speaks. `tools` cannot see
/// `codemode`, so the two `Seam` types are mirrors — the same arrangement
/// `Outcome` and `Enforcement` already use.
///
/// ## Examples
///
/// ```gleam
/// assert codemode.tool_seam(vet_policy.WorkspaceSeam)
///   == Ok(codemode_tool.WorkspaceSeam)
/// ```
///
/// ```gleam
/// assert codemode.tool_seam(vet_policy.ExtensionSeam) == Error(Nil)
/// ```
///
pub fn tool_seam(seam: vet_policy.Seam) -> Result(codemode_tool.Seam, Nil) {
  case seam {
    vet_policy.WorkspaceSeam -> Ok(codemode_tool.WorkspaceSeam)
    vet_policy.OrchestrationSeam -> Ok(codemode_tool.OrchestrationSeam)

    // The `code_mode` tool has no name for the extension seam, and the
    // absence is the point rather than a gap: an extension is dispatched
    // by the harness from an install record, never named by a model in a
    // `code_mode` call, so there is no seam here for a model to select.
    // A `Result` rather than a third mirrored variant keeps that fact in
    // the type, where a caller has to answer it.
    // The resident seam is not a `code_mode` seam either, and for a
    // stronger reason: nothing loads a resident body at all (#32).
    vet_policy.ExtensionSeam | vet_policy.ResidentSeam -> Error(Nil)
  }
}

/// And back: the seam a request named, in the pipeline's vocabulary.
///
/// ## Examples
///
/// ```gleam
/// assert codemode.vetting_seam(codemode_tool.WorkspaceSeam)
///   == vet_policy.WorkspaceSeam
/// ```
///
pub fn vetting_seam(seam: codemode_tool.Seam) -> vet_policy.Seam {
  case seam {
    codemode_tool.WorkspaceSeam -> vet_policy.WorkspaceSeam
    codemode_tool.OrchestrationSeam -> vet_policy.OrchestrationSeam
  }
}

/// Runs one submitted program end to end and reports what ran.
///
/// Total: every failure of every stage is a value in the `Execution` this
/// returns, including the two this module owns — a work directory that
/// cannot be created, and a report that never arrived.
///
/// ## Examples
///
/// ```gleam
/// // codemode.execute(config, request).result
/// ```
///
pub fn execute(
  config: Config,
  request: codemode_tool.Request,
) -> codemode_tool.Execution {
  // A seam this host does not serve, before anything is dispatched. The
  // tool shell has already refused one, so this is for a caller that
  // built its own `Request`: it must not be silently reinterpreted as the
  // seam the host does serve, in either direction — one way that is a
  // refusal naming an allowlist the submission never asked for, the other
  // a widening nobody chose.
  use <- bool.lazy_guard(
    when: !list.contains(
      surface_seams(config.surface),
      vetting_seam(request.seam),
    ),
    return: fn() { unserved(config.surface, request.seam) },
  )

  // Vetting is pure, so a rejected program must not create, clear, or even
  // validate an execution directory. The pipeline repeats this check because
  // its public seam accepts source rather than a `Vetted` value; keeping that
  // boundary intact preserves its compile-to-run guarantee.
  case
    vet.vet(request.source, seam_allowlist(config, vetting_seam(request.seam)))
  {
    vet.Rejected(rejections) -> vet_rejected_execution(rejections)
    vet.Passed(_vetted) -> execute_after_vetting(config, request)
  }
}

// The filesystem-owning half of an execution. This is called only after the
// submission has passed the same seam-specific policy the pipeline will use.
fn execute_after_vetting(
  config: Config,
  request: codemode_tool.Request,
) -> codemode_tool.Execution {
  let root = exec_root(config, request)

  // The socket check first: it is pure, and failing it after creating the
  // directory would leave one behind for an execution that never ran.
  case check_socket_path(root) |> result.try(fn(_) { prepare_root(root) }) {
    Error(reason) ->
      codemode_tool.Execution(
        result: codemode_tool.CompileFailed(codemode_tool.WorkspaceSetupFailed(
          reason:,
        )),
        enforcement: nothing_dispatched(
          "the code-mode work directory could not be created, so nothing "
          <> "was dispatched",
        ),
        refusal: codemode_tool.NothingRefused,
      )
    Ok(Nil) -> {
      let #(now, _clock) = clock.read(config.clock)
      let deadline_ms = now + request.within_ms
      let shortfalls = process.new_subject()
      let execution =
        pipeline.execute(
          request.source,
          watching(
            exec_config(
              config,
              request,
              root,
              deadline_ms,
              widened_by: approved_grants(request),
            ),
            config.clock,
            reporting: shortfalls,
            until: deadline_ms,
          ),
        )

      // The whole execution is over: the node is destroyed, the socket and
      // token are unlinked by the host's own teardown, and nothing but the
      // outcome outlives it. The seed clone is large and every build makes
      // a fresh one, so the directory goes too.
      let _removed = simplifile.delete(root)
      codemode_tool.Execution(
        result: translate(execution.outcome),
        enforcement: translate_enforcement(execution.enforcement),
        refusal: reported_refusal(shortfalls),
      )
    }
  }
}

// The pipeline's rejection translated before any execution resources exist.
// These report strings match the pipeline because the observable result must
// not depend on which side of the filesystem boundary performed the vet.
fn vet_rejected_execution(
  rejections: List(vet.Rejection),
) -> codemode_tool.Execution {
  codemode_tool.Execution(
    result: codemode_tool.VetRejected(list.map(rejections, rejection)),
    enforcement: codemode_tool.Enforcement(
      build: codemode_tool.Unreported(
        "vetting refused the program, so no build was dispatched",
      ),
      node: codemode_tool.Unreported(
        "vetting refused the program, so no node was launched",
      ),
    ),
    refusal: codemode_tool.NothingRefused,
  )
}

// The grants an approved escalation attributed to *this* `code_mode`
// call, which is what an execution re-run under an approval is allowed to
// compose with.
//
// They ride the request rather than the surface because an approval
// widens one re-execution of one action, never a session: a grant list
// configured on the seam would outlive the call that was consented to.
// And they are not folded into `request.base_policy` on the way past,
// which would be a second widening path and would reach the hermetic
// build — `identity.widened_by` puts them on the run phase alone
// (`codemode/identity`, "The widening, and why it lives here").
//
// Two ways in, one destination. A call arrives carrying grants when the
// *driver* consumed an approval for it at clearance time (`Ctx.grants`,
// through `tools/codemode.request`); a call acquires them mid-flight when
// this module reported a refusal outward and a human answered, which
// `tools/codemode` appends to the same field before executing once more.
// Both are approvals attributed to this one call, so both compose in the
// same place.
fn approved_grants(request: codemode_tool.Request) -> List(Grant) {
  request.grants
}

// --- watching the stage a human can widen ----------------------------------

// The same execution configuration, with the satellite launcher wrapped
// so that a launch refused on *policy* is reported outward as a
// structured denial rather than only as the reason text the run settles
// with.
//
// Wrapping is the whole trick, and it is what keeps this honest. The
// pipeline flattens every refusal to prose on its way to the model — that
// is right for a model and useless for consent, because an approval
// grants `denial.wanted` and prose has no wanted. Rather than parse the
// prose back, or re-derive what the node asks for, the wrapper calls
// `launch`'s *own* public `node_requirements` against the spec the
// pipeline actually built and asks `policy.compose` the same question the
// launch asked. There is nothing here for the two to drift apart on: if
// the node's requirements change, this changes with them.
//
// **The launch, and only the launch.** The hermetic build clears on
// policy too, and it is deliberately unwatched. `identity.build_phase`
// drops this execution's grants before the build composes anything —
// grants apply *after* the meet, so one reaching the build would undo the
// offline, pinned property the build exists to have — so a build refused
// on policy is an operator's misconfiguration and no answer a human could
// give would change it. Filing that as a question would be filing a
// decision nobody can act on, and it would be inexact into the bargain:
// the build prepares its seed before it clears, so "the build failed and
// the base is narrow" is not the same statement as "the build was refused
// on policy". The model reads the build's verbatim reason in
// `CompileFailed` either way. A capability call refused inside a *running*
// program is unwatched for a different reason, argued in the module doc:
// by then the program has performed effects, and the one thing an
// approval buys is a re-execution.
fn watching(
  exec: pipeline.ExecConfig,
  session_clock: Clock,
  reporting shortfalls: Subject(codemode_tool.PolicyRefusal),
  until deadline_ms: Int,
) -> pipeline.ExecConfig {
  pipeline.ExecConfig(
    ..exec,
    launch: watched_launcher(
      exec.launch,
      session_clock,
      shortfalls,
      deadline_ms,
    ),
  )
}

// The satellite launch, watched.
//
// The composition is only run once the launcher has already refused.
// That ordering costs nothing on a working execution and answers "was
// policy the reason?" without a second oracle: `launch` composes `base ⊕
// requirements ⊕ grants` before it binds a socket or spawns anything, so
// a launch that failed *and* narrows is a launch that narrowed, and a
// launch that failed on a socket it could not bind composes cleanly and
// reports nothing.
//
// A plain `case` rather than a `result.map_error`: the error arm reports
// on a subject, and a combinator that reads like a rename is the last
// place a side effect should be hiding (`docs/gleam-style.md` Part III,
// "Where the lineage stops").
fn watched_launcher(
  launcher: satellite.Launcher,
  session_clock: Clock,
  shortfalls: Subject(codemode_tool.PolicyRefusal),
  deadline_ms: Int,
) -> satellite.Launcher {
  fn(spec) {
    case launcher(spec) {
      Ok(connection) -> Ok(connection)
      Error(reason) -> {
        let #(now, _clock) = clock.read(session_clock)

        // Both variants named: a bare variable in the second arm would
        // be a catch-all whatever it is called, and a third kind of
        // refusal added later would start being reported here with
        // nobody having decided that it should be.
        case launch_refusal(spec, now, reason, deadline_ms) {
          codemode_tool.NothingRefused -> Nil
          codemode_tool.RunRefused(..) as refused ->
            process.send(shortfalls, refused)
        }
        Error(reason)
      }
    }
  }
}

/// What composition would refuse this satellite launch for, if anything:
/// `RunRefused` carrying the exact grants that would satisfy it, or
/// `NothingRefused` when the session base already covers the node.
///
/// Public because it is the whole of the decision `watched_launcher`
/// makes, and the only part of it a test can hold still: a `LaunchSpec`
/// is a value, and the answer to "what does this base owe this node" is a
/// pure function of one.
///
/// `reason` is the launcher's own sentence, carried into the denial
/// verbatim so a human reads "the session base cannot host a satellite
/// node: environment variable LOOM_CAP_SOCK" rather than a paraphrase of
/// it. The wanted diff is never taken from a caller: it can only come
/// from `policy.wanted_grants` over the narrowings computed here, so
/// nothing can offer a human a diff of its own invention.
///
/// `policy.narrow_unenforceable` is deliberately not applied. The node
/// requires `NetworkOff`, composition takes the meet, and the one
/// downgrade that rule performs turns `NetworkProxy` into `NetworkOff` —
/// so it cannot fire here, and applying it would invite the belief that
/// this is a second implementation of the broker's clearance rather than
/// a re-run of the one question the launch already asked.
///
/// ## Examples
///
/// ```gleam
/// // codemode.launch_refusal(spec, now, reason, deadline_ms)
/// //   == codemode_tool.RunRefused(denial:, deadline_ms:)
/// ```
///
pub fn launch_refusal(
  spec: satellite.LaunchSpec,
  now_ms: Int,
  reason: String,
  deadline_ms: Int,
) -> codemode_tool.PolicyRefusal {
  let #(_effective, narrowings) =
    policy.compose(
      base: spec.base_policy,
      requirements: launch.node_requirements(spec, now_ms),
      grants: identity.grants(spec.identity),
    )
  case narrowings {
    [] -> codemode_tool.NothingRefused
    [_, ..] ->
      codemode_tool.RunRefused(
        denial: escalation.Denial(
          reason:,
          source: escalation.PolicyDenial,
          wanted: policy.wanted_grants(narrowings),
        ),
        deadline_ms:,
      )
  }
}

// What the watcher reported, or that nothing did.
//
// The receive is bounded at zero and that is not optimism. The wrapper
// runs on this very process — `satellite.run` calls the launcher from
// `dispatch_launch`, before it starts waiting on anything — so by the
// time `pipeline.execute` has returned, a report that was going to be
// made is already in this mailbox. Should the pipeline ever move the
// launch onto a process of its own, the report is simply lost and the
// refusal settles in band with no record raised, which is the direction
// every other failure in this seam falls.
//
// A subject rather than a return value because the launcher is a
// callback: its shape is the pipeline's contract and its return type has
// no room for anything but the connection. One report at most can arrive
// — a launch happens once per execution.
fn reported_refusal(
  shortfalls: Subject(codemode_tool.PolicyRefusal),
) -> codemode_tool.PolicyRefusal {
  // The eager `unwrap` is right here: the fallback is a bare constructor
  // over nothing, so computing it on every execution costs a word.
  result.unwrap(
    process.receive(shortfalls, within: 0),
    codemode_tool.NothingRefused,
  )
}

// Nothing started, and the reason names both the seam that was asked for
// and the ones on offer. `StartFailed` rather than a vetting rejection
// because the program was never judged at all: no allowlist was applied
// to it, and saying one was would be the lie this whole path exists to
// avoid.
fn unserved(
  surface: Surface,
  seam: codemode_tool.Seam,
) -> codemode_tool.Execution {
  let served =
    surface_seams(surface)
    |> list.filter_map(tool_seam)
    |> list.map(codemode_tool.seam_name)
    |> string.join(", ")
  codemode_tool.Execution(
    result: codemode_tool.RunFailed(codemode_tool.StartFailed(
      reason: "this host does not serve the "
      <> codemode_tool.seam_name(seam)
      <> " code-mode seam; it serves: "
      <> served,
    )),
    enforcement: nothing_dispatched(
      "the submission named a seam this host does not serve, so nothing "
      <> "was dispatched",
    ),
    refusal: codemode_tool.NothingRefused,
  )
}

/// A fresh directory per execution. `delete` first because a directory
/// left by a previous execution under the same coordinates — a replayed
/// step, an interrupted run — must not have its stale contents join this
/// build.
///
/// Public because an extension dispatch stands up a satellite under the
/// same work root without compiling anything first
/// (`client/extension/dispatch`), and a second implementation of "make me
/// a clean execution directory" is a second answer to what a stale one
/// means.
///
/// ## Examples
///
/// ```gleam
/// // codemode.prepare_root("/w/.codemode/9f2b") == Ok(Nil)
/// ```
///
pub fn prepare_root(root: String) -> Result(Nil, String) {
  let _cleared = simplifile.delete(root)
  simplifile.create_directory_all(root)
  |> result.map_error(fn(error) {
    "could not create the code-mode work directory "
    <> root
    <> ": "
    <> simplifile.describe_error(error)
  })
}

/// An AF_UNIX socket the kernel will not bind is worth catching before a
/// directory exists, where the workspace can be named in the answer,
/// rather than as an `einval` from `listen` three stages later.
///
/// Public for the reason `prepare_root` is: the extension dispatch binds a
/// socket under the same root and must ask the same question in the same
/// place in the order.
///
/// ## Examples
///
/// ```gleam
/// // codemode.check_socket_path("/w/.codemode/9f2b") == Ok(Nil)
/// ```
///
pub fn check_socket_path(root: String) -> Result(Nil, String) {
  let path = socket_path(root)
  case bit_array.byte_size(<<path:utf8>>) > max_socket_path_bytes {
    False -> Ok(Nil)
    True ->
      Error(
        "the code-mode cap socket would be "
        <> path
        <> ", which is longer than the "
        <> int.to_string(max_socket_path_bytes)
        <> " bytes a unix socket path may have; run the session from a "
        <> "shallower workspace",
      )
  }
}

/// This execution's own directory: the build root, the `.beam` set, the
/// cap socket, and the private token file all live under it.
///
/// The name is a 64-bit FNV-1a digest of `{op_id, step_id, source_index}`
/// rendered as sixteen hex characters, and its shortness is the point
/// rather than an aesthetic. The cap socket lives inside this directory
/// and an AF_UNIX path is capped at about 108 bytes by the kernel, so a
/// directory named for a full operation id and a step id spends forty-odd
/// of them before the workspace prefix is counted; a workspace a couple of
/// levels deeper then fails at `listen` with `einval`, which is a poor way
/// to learn about a path limit. The digest cannot carry a separator, a dot
/// segment or a space out of the work root the way a step id could. The
/// directory is removed when the execution settles, and the artifact's
/// `manifest_hash` remains the durable fingerprint of what ran.
///
/// ## Why the source index is in the key
///
/// `{op_id, step_id}` is the **batch** identity the broker pools budget
/// on; `{op_id, step_id, source_index}` is the **execution** identity.
/// `code_mode` is `tool.Exclusive`, which forbids a concurrent *start* and
/// nothing more, so one batch may hold two `code_mode` calls at different
/// source indices that run back to back under one operation and one step.
/// Keyed on the pair, both would build in this same directory, bind this
/// same socket, and write this same token file — and the launcher's
/// janitor is an unlinked process that runs teardown *after* the host
/// dies, on ordinary exits too, so the first execution's cleanup could
/// unlink the second execution's live socket and token. `prepare_root`
/// begins with a recursive delete, which races the same janitor from the
/// other direction. The third field ends both races by construction.
///
/// `request.source_index` is filled from the dispatching `tool.Ctx` and
/// never from the model's arguments, so it is a coordinate the program
/// cannot state. No length prefixing is needed here (unlike
/// `agent.call_site_digest`): there are exactly three fields, in a fixed
/// order, and the last is an integer rendering that cannot contain the
/// separator.
///
/// ## Examples
///
/// ```gleam
/// // codemode.exec_root(config, request) == "/work/.codemode/9f2b1c0ad3e45871"
/// ```
///
pub fn exec_root(config: Config, request: codemode_tool.Request) -> String {
  work_root(
    config,
    op_id: request.op_id,
    step_id: request.step_id,
    source_index: request.source_index,
  )
}

/// The same directory, named from the three coordinates directly.
///
/// Public and separate from `exec_root` because an extension dispatch has
/// a `tool.Ctx` rather than a `codemode_tool.Request` and needs the very
/// same digest: an extension tool call and a `code_mode` call in one
/// assistant message are two executions at two source indices, and it is
/// this one keying rule that stops them sharing a directory, a socket and
/// a token file. Two implementations of it would be two chances to
/// collide.
///
/// ## Examples
///
/// ```gleam
/// // codemode.work_root(config, op_id:, step_id: "turn-4", source_index: 0)
/// ```
///
pub fn work_root(
  config: Config,
  op_id op_id: OpId,
  step_id step_id: String,
  source_index source_index: Int,
) -> String {
  config.work_root
  <> "/"
  <> digest(
    ids.op_id_to_string(op_id)
    <> "\n"
    <> step_id
    <> "\n"
    <> int.to_string(source_index),
  )
}

/// The work root a session-lived extension host runs under.
///
/// Keyed on the extension's name rather than on `{op_id, step_id,
/// source_index}`, because a host outlives every one of those: it is
/// launched on an extension's first use and reaped at session end, and its
/// socket and token file have to stay where they were put for the whole of
/// that. Two extensions get two roots; one extension gets one, whichever
/// call happened to start it.
///
/// ## Examples
///
/// ```gleam
/// // codemode.host_root(config, "web_search") != codemode.work_root(...)
/// ```
///
pub fn host_root(config: Config, extension extension: String) -> String {
  config.work_root <> "/" <> digest("host\n" <> extension)
}

/// The cap-channel socket for an execution rooted at `root`. One
/// character, for the same reason `exec_root` is a digest.
///
/// ## Examples
///
/// ```gleam
/// assert codemode.socket_path("/w/.codemode/9f2b") == "/w/.codemode/9f2b/s"
/// ```
///
pub fn socket_path(root: String) -> String {
  root <> "/s"
}

/// The longest cap-socket path this wiring will attempt.
///
/// The kernel's `sun_path` is 108 bytes including its terminator on Linux
/// and 104 on macOS; a few bytes of margin under the smaller of the two
/// turns an opaque `einval` from `listen` into a worded refusal that names
/// the real problem — the workspace sits too deep for a code-mode socket.
pub const max_socket_path_bytes = 100

// FNV-1a 64 over the key's codepoints, rendered as sixteen lowercase hex
// characters. A path-naming digest, not a security primitive: nothing is
// authenticated by it, and a collision would only mean two executions
// sharing a directory — which is why the key is the triple that is
// already unique per execution.
fn digest(key: String) -> String {
  key
  |> string.to_utf_codepoints
  |> list.fold(fnv_offset_basis, fn(hash, point) {
    let mixed =
      int.bitwise_exclusive_or(hash, string.utf_codepoint_to_int(point))
    int.bitwise_and(mixed * fnv_prime, mask_64)
  })
  |> int.to_base16
  |> string.lowercase
  |> string.pad_start(to: 16, with: "0")
}

const fnv_offset_basis = 14_695_981_039_346_656_037

const fnv_prime = 1_099_511_628_211

const mask_64 = 18_446_744_073_709_551_615

/// The pipeline configuration for one execution: the vetting policy, the
/// hermetic build, the pooled identity and budget, the satellite host, and
/// the production launcher.
///
/// Public because the identity threading is the property worth pinning in
/// a test: one `ExecIdentity` is minted here from the caller's own
/// coordinates, and both stages derive their phase from it rather than
/// being handed coordinates of their own.
///
/// The build shares the run's ledger. Production has always built under
/// the unsuffixed step id, so this is today's behaviour spelled in the
/// type rather than a change: `with_own_build_ledger` is the e2e's
/// deliberate split, not the default.
///
/// `widened_by` is the approval this execution carries, and it goes onto
/// the same identity for the same reason the budget does — one threaded
/// value, phases derived from it, nowhere for a caller to write a second.
/// The run phase composes them; the hermetic build never sees them
/// (`codemode/identity`, "The widening, and why it lives here"). Passing
/// `[]` is an unapproved execution and is exactly as wide as this
/// pipeline has always been.
///
/// ## Examples
///
/// ```gleam
/// // identity.ledger_keys(exec_config(c, r, root, ms).identity)
/// //   == [#(r.op_id, r.step_id)]
/// ```
///
pub fn exec_config(
  config: Config,
  request: codemode_tool.Request,
  root: String,
  deadline_ms: Int,
  widened_by grants: List(Grant),
) -> pipeline.ExecConfig {
  let pooled = pooled_budget(config, deadline_ms)
  let base_policy = execution_policy(request.base_policy)
  let seam = vetting_seam(request.seam)
  pipeline.ExecConfig(
    vet_policy: seam_allowlist(config, seam),
    compile: compile.CompileConfig(
      build_root: root,
      dependencies: compile.default_dependencies(),
      // The whole table this host generated; `pipeline.execute` narrows
      // it to the vetted program's own imports before a byte is
      // written, so a configured server a program never names costs it
      // no build time at all.
      generated: mcp_wiring.generated(seam_mcp(config, seam)),
      build: build.builder(build_config(config, request)),
    ),
    broker: config.broker,
    identity: identity.for_execution(
      op_id: request.op_id,
      step_id: request.step_id,
      budget: pooled,
    )
      |> identity.widened_by(grants:),
    satellite: satellite.SatelliteConfig(
      base_policy:,
      demand: request.demand,
      // The program's own children inherit the driver's constructed
      // environment, not the build's: what a program shells out to is the
      // agent's toolchain, the same one `bash` would reach.
      env: request.env,
      cwd: request.workspace,
      cap_socket_path: socket_path(root),
      entropy: config.entropy,
      clock: config.clock,
      write_token_file: satellite.private_token_writer(root <> "/token"),
      unlink_token_file: satellite.unlink_token_file,
      router: surface_router(config, request),
      ceilings: surface_ceilings(config, request),
      call_timeout_ms: config.call_timeout_ms,
    ),
    launch: launch.launcher(launch.LaunchConfig(
      broker: config.broker,
      clock: config.clock,
      erl_path: config.erl_path,
      demand: request.demand,
      accept_timeout_ms: config.accept_timeout_ms,
    )),
  )
}

// The capability router one execution runs behind, and the strand every
// Agency call it makes is judged as.
//
// The strand comes from the request — which `tools/codemode.request`
// filled from the dispatching `Ctx` and never from the model's arguments
// — so a program cannot claim to be another strand, and the addressing
// rule the Agency enforces stays enforceable.
//
// The *surface* picks the router, and the request only chooses among the
// seams the surface already serves. A host that wired one seam therefore
// hands out that seam's router whatever a submission names, so nothing a
// model says can widen what the operator wired; and the mismatch that
// arrangement allows — vetted against one seam's imports, routed by the
// other's — can only narrow, because a program that may not import
// `cap/proc` cannot call `proc.run` however willing the router is.
fn surface_router(
  config: Config,
  request: codemode_tool.Request,
) -> satellite.CapRouter {
  case config.surface, vetting_seam(request.seam) {
    Workspace, _seam -> workspace_router(config, request)
    Both(..), vet_policy.WorkspaceSeam -> workspace_router(config, request)
    Orchestration(agency:, ..), _seam | Both(agency:, ..), _seam ->
      orchestration.router(orchestration.Orchestration(
        agency:,
        strand: request.strand,
        source_index: request.source_index,
        // `cap/report` is on both allowlists, so `report.emit` is
        // serviced on both seams — by the same closure, writing into the
        // same store under the same content address. An orchestration
        // program that could not emit had `cap/report`'s one effectful
        // function refused on every call (issue #91, item 1).
        //
        // The closure directly, not `workspace_seam(..).emit`: this seam
        // routes none of the other seven arms, so building all eight to
        // read one field would state — in the one place a reader checks
        // what an orchestration program can reach — that a workspace
        // bridge was constructed for it. `emitting` is what both seams
        // share, so it is what both seams call.
        emit: emitting(fs.real_filesystem(), config.blob_root, config.entropy),
        emit_ceiling: artifact.default_emit_ceiling,
      ))
  }
}

// The workspace seam's router: three arms over the shipped table.
//
// Outermost is the harness-side bridge — `fs.read`, `fs.list`, `kv.*`,
// `report.emit` — then the MCP arm answering `mcp.<server>`, then
// `satellite.default_router`, which clears `proc.run` into a jail and
// refuses everything it does not know. Each arm hands what it does not
// answer to the one beneath, so nothing about `proc.run` or about what
// the default table refuses changes shape.
//
// Only the innermost arm builds a `broker.CallSpec`. The other two
// return `satellite.ServedHere` plans exclusively: a workspace read, a
// process-local store write and a blob mint are requests the harness
// answers itself, entering no jail and composing no policy, for the
// reason `codemode/workspace`'s module doc argues at length — a policy
// whose enforcer is not present is not a check.
//
// The layer, the store and the blob root are all read off the *host*,
// like every other router choice here, so a submission that named the
// orchestration seam on a workspace-only host is still routed by this
// one — and reaches nothing through it, because a program vetted against
// the orchestration allowlist cannot import the modules whose calls
// these arms service.
fn workspace_router(
  config: Config,
  request: codemode_tool.Request,
) -> satellite.CapRouter {
  workspace.routing(
    workspace_seam(config, request),
    over: mcp_wiring.routing(config.mcp, over: satellite.default_router),
  )
}

/// The harness-side closures the workspace seam's router calls, bound to
/// one execution's workspace root and this host's stores.
///
/// Public because it is the whole of what the bridge authorizes, and a
/// test that wants to prove a path is contained should be able to hold
/// exactly these six functions still rather than standing up a satellite
/// to reach them.
///
/// **Every filesystem decision here is `tools/fs`'s.** `resolve_real` is
/// the harness's sole path boundary and `read_text_file` is `fs_read`'s
/// own large-file guard and UTF-8 rule; nothing about either is restated.
/// The one operation with no counterpart in the tool set is *listing* a
/// directory, which the `tool.FileSystem` seam has no primitive for — so
/// the enumeration is `simplifile`'s, exactly as `fs.real_filesystem`'s
/// other primitives are, and it happens only on a path `resolve_real` has
/// already resolved and contained.
///
/// ## Examples
///
/// ```gleam
/// // codemode.workspace_seam(config, request).fs_read("src/main.gleam")
/// ```
///
pub fn workspace_seam(
  config: Config,
  request: codemode_tool.Request,
) -> workspace.Workspace {
  workspace_seam_for(
    config,
    workspace: request.workspace,
    strand: request.strand,
    // The protected list rides the request's own base policy — the same
    // value the launch composes against — so the bridge's write boundary
    // and the jail's mask are fed from one source.
    protected: request.base_policy.protected,
  )
}

/// The same bridge, built from the three values it actually reads.
///
/// Separate from `workspace_seam` because an extension dispatch has a
/// `tool.Ctx` and no `codemode_tool.Request`, and an extension satellite
/// reaches `fs.*`, `kv.*`, `schedule.*` and `report.emit` through exactly
/// this bridge (`client/extension/dispatch`). A second construction of
/// these closures would be a second answer to what a jailed program may
/// touch on the host, which is the one question this seam exists to
/// answer once.
///
/// ## Examples
///
/// ```gleam
/// // codemode.workspace_seam_for(config, workspace: "/w", strand: "main",
/// //   protected: []).fs_read("src/main.gleam")
/// ```
///
pub fn workspace_seam_for(
  config: Config,
  workspace workspace_root: String,
  strand strand: String,
  protected protected: List(String),
) -> workspace.Workspace {
  let filesystem = fs.real_filesystem()
  let root = workspace_root
  let request_strand = strand
  workspace.Workspace(
    fs_read: fn(path) { read_in(filesystem, root, path) },
    fs_list: fn(path) { list_in(filesystem, root, path) },
    fs_write: fn(path, contents) {
      write_in(filesystem, root, protected, path, contents)
    },
    fs_edit: fn(path, edits) {
      edit_in(filesystem, root, protected, path, edits)
    },
    kv_get: config.scratch.get,
    kv_set: config.scratch.set,
    kv_delete: config.scratch.delete,
    // The *caller* is bound here, from the request, and never travels
    // over the cap channel: a program cannot name the strand its own
    // authority comes from. A `target` it does name is checked against
    // that caller by the door, which reads the lineage ledger — so a
    // program reaches its own strand and strands it spawned, and
    // nothing else.
    schedule_create: fn(request) {
      schedule_create_in(config.schedules, request, on: request_strand)
    },
    schedule_list: fn() { schedule_list_in(config.schedules, request_strand) },
    schedule_cancel: fn(name, target) {
      schedule_cancel_in(config.schedules, name, target, on: request_strand)
    },
    emit: emitting(filesystem, config.blob_root, config.entropy),
    emit_ceiling: artifact.default_emit_ceiling,
  )
}

// --- schedule.* ------------------------------------------------------------
//
// The bridge between two refusal vocabularies that say the same things.
// `codemode` may not depend on `client`, so `workspace.ScheduleRefusal`
// restates `tools/schedule.Refusal` in its own terms and these three
// functions map across. The mapping is total on both sides by
// construction: every arm below names one constructor, so a new refusal
// on either side fails to compile here rather than silently becoming
// something else.
//
// A shut door answers `ScheduleUnavailable` rather than being routed at
// all — see `Config.schedules`. It cannot be reached in practice, because
// a `None` door leaves the capabilities unrouted; the arm exists so the
// closure is total without a panic.

fn schedule_create_in(
  door: Option(scheduleseam.Door),
  request: workspace.ScheduleRequest,
  on strand: String,
) -> Result(workspace.ScheduleCreated, workspace.ScheduleRefusal) {
  use door <- with_door(door)
  use timing <- result.try(schedule_timing(request))
  door.create(
    strand,
    schedule_tool.Request(
      name: request.name,
      target: request.target,
      timing:,
      max_fires: request.max_fires,
      expires_after_s: request.expires_after_s,
      wake: requested_wake(request.wake),
      body: request.body,
    ),
  )
  |> result.map(fn(created: schedule_tool.Created) {
    workspace.ScheduleCreated(
      name: created.name,
      target: created.target,
      when: created.when,
      wake: granted_wake(created.wake),
    )
  })
  |> result.map_error(schedule_refusal)
}

// `codemode` may not depend on `tools` either, so a wake crossing this
// seam is translated the same way a refusal is. The two directions get a
// function each because different sides read them: `requested_wake`
// carries what the program asked into the door's vocabulary, and
// `granted_wake` carries what the host granted back out.
fn requested_wake(wake: workspace.ScheduleWake) -> schedule_tool.Wake {
  case wake {
    workspace.WakesIdle -> schedule_tool.WakesIdle
    workspace.SteersOnly -> schedule_tool.SteersOnly
  }
}

fn granted_wake(wake: schedule_tool.Wake) -> workspace.ScheduleWake {
  case wake {
    schedule_tool.WakesIdle -> workspace.WakesIdle
    schedule_tool.SteersOnly -> workspace.SteersOnly
  }
}

fn schedule_timing(
  request: workspace.ScheduleRequest,
) -> Result(schedule_tool.RequestedTiming, workspace.ScheduleRefusal) {
  let named =
    [
      option.map(request.in_seconds, schedule_tool.In),
      option.map(request.every_seconds, schedule_tool.Every),
      option.map(request.cron, fn(expression) {
        schedule_tool.Cron(expression:, utc_offset: request.utc_offset)
      }),
      option.map(request.at, schedule_tool.At),
    ]
    |> option.values

  case named {
    [only] -> Ok(only)

    // The router has already refused none and more than one, so both of
    // these are unreachable in practice; the arm exists so this closure
    // is total without a panic, and says so in the one vocabulary the
    // caller can read.
    [] | [_first, _second, ..] ->
      Error(workspace.ScheduleInvalid(
        reason: "give exactly one of in_seconds, every_seconds, cron or at",
      ))
  }
}

fn schedule_list_in(
  door: Option(scheduleseam.Door),
  strand: String,
) -> Result(List(workspace.ScheduleRow), workspace.ScheduleRefusal) {
  use door <- with_door(door)
  door.list(strand)
  |> result.map(fn(rows) {
    list.map(rows, fn(row: schedule_tool.Listed) {
      workspace.ScheduleRow(
        name: row.name,
        target: row.target,
        when: row.when,
        wake: granted_wake(row.wake),
        fired: row.fired,
        body: row.body,
      )
    })
  })
  |> result.map_error(schedule_refusal)
}

fn schedule_cancel_in(
  door: Option(scheduleseam.Door),
  name: String,
  target: Option(String),
  on strand: String,
) -> Result(Nil, workspace.ScheduleRefusal) {
  use door <- with_door(door)
  door.cancel(strand, name, target) |> result.map_error(schedule_refusal)
}

fn with_door(
  door: Option(scheduleseam.Door),
  then: fn(scheduleseam.Door) -> Result(a, workspace.ScheduleRefusal),
) -> Result(a, workspace.ScheduleRefusal) {
  case door {
    None ->
      Error(workspace.ScheduleUnavailable(
        reason: "this session serves no scheduling plane",
      ))
    Some(door) -> then(door)
  }
}

fn schedule_refusal(
  refusal: schedule_tool.Refusal,
) -> workspace.ScheduleRefusal {
  case refusal {
    schedule_tool.Invalid(reason:) -> workspace.ScheduleInvalid(reason:)
    schedule_tool.CeilingReached(..) ->
      workspace.ScheduleLimitReached(reason: schedule_tool.refusal_reason(
        refusal,
      ))
    schedule_tool.NameTaken(..) ->
      workspace.ScheduleNameTaken(reason: schedule_tool.refusal_reason(refusal))
    schedule_tool.NotFound(..) ->
      workspace.ScheduleNotFound(reason: schedule_tool.refusal_reason(refusal))
    schedule_tool.Unavailable(reason:) -> workspace.ScheduleUnavailable(reason:)
  }
}

// `fs.read`: resolve, then read, with both refusals kept structured.
// This is the whole of it — every decision belongs to one of the two
// `tools/fs` functions called here, and the bridge's contribution is to
// name the seam the failure came from.
fn read_in(
  filesystem: tool.FileSystem,
  root: String,
  path: String,
) -> Result(String, workspace.FsRefusal) {
  use resolved <- result.try(
    fs.resolve_real(filesystem:, workspace: root, path:)
    |> result.map_error(workspace.PathRefused),
  )
  fs.read_text_file(filesystem:, resolved:)
  |> result.map_error(workspace.ReadRefused)
}

// `fs.write`: resolve through `resolve_writable` — containment plus the
// protected-path refusal, the same one function the model's own
// `fs_write` calls (#105) — then write whole through the seam. Both
// decisions are `tools/fs`'s; the bridge's contribution is the seam name
// on the refusal.
//
// The write itself is `fs.write_whole`, which is what `fs_write` calls
// too, so **both doors create missing parent directories**. The
// alternative was a bridge where `fs.write("new_dir/file.txt", ..)`
// failed with an errno while the model's own tool, given the same path,
// succeeded — one workspace behaving two ways depending on which door a
// write came through, and the difference discoverable only by hitting
// it. `fs_write`'s description promises parents are created; a program
// reading `cap/fs.write`'s "creating or replacing the whole file" has
// every reason to expect the same file to appear.
fn write_in(
  filesystem: tool.FileSystem,
  root: String,
  protected: List(String),
  path: String,
  contents: String,
) -> Result(Nil, workspace.FsRefusal) {
  use resolved <- result.try(
    fs.resolve_writable(filesystem:, workspace: root, protected:, path:)
    |> result.map_error(workspace.PathRefused),
  )
  fs.write_whole(filesystem:, resolved:, bytes: <<contents:utf8>>)
  |> result.map_error(workspace.WriteRefused)
}

// `fs.edit`: read-apply-write inside this one closure, which is the
// tightest window the seam can offer (the module doc of
// `codemode/workspace` carries the ruling). The read reuses
// `read_text_file`, so an edit of a too-large or non-text file is
// refused with the same guards a read is; the apply is
// `workspace.apply_replacements`, pure and corpus-pinned; the write goes
// through the same resolved, protected-checked path the read used.
fn edit_in(
  filesystem: tool.FileSystem,
  root: String,
  protected: List(String),
  path: String,
  edits: List(workspace.Replacement),
) -> Result(Nil, workspace.FsRefusal) {
  use resolved <- result.try(
    fs.resolve_writable(filesystem:, workspace: root, protected:, path:)
    |> result.map_error(workspace.PathRefused),
  )
  use text <- result.try(
    fs.read_text_file(filesystem:, resolved:)
    |> result.map_error(workspace.ReadRefused),
  )
  use edited <- result.try(
    workspace.apply_replacements(text, edits)
    |> result.map_error(workspace.EditRefused),
  )
  filesystem.write(resolved, <<edited:utf8>>)
  |> result.map_error(workspace.WriteRefused)
}

// `fs.list`: resolve through the same boundary, then enumerate.
//
// Two properties are worth stating because neither is obvious.
//
// The listing is bounded *before* it is built: `simplifile.read_directory`
// hands back every name, and the count is checked against
// `workspace.max_list_entries` before a single entry is classified, so a
// directory with a hundred thousand files costs one readdir rather than a
// hundred thousand `read_link` calls followed by a refusal.
//
// `is_directory` is answered with lstat semantics, through the seam's own
// `read_link`: a symlink is reported as **not** a directory whatever it
// points at. That is the safe direction — the answer says nothing about a
// target that may lie outside the workspace — and the honest one, since
// `fs.read` through that link would be refused by `resolve_real` anyway.
fn list_in(
  filesystem: tool.FileSystem,
  root: String,
  path: String,
) -> Result(List(workspace.DirEntry), workspace.FsRefusal) {
  use resolved <- result.try(
    fs.resolve_real(filesystem:, workspace: root, path:)
    |> result.map_error(workspace.PathRefused),
  )
  use names <- result.try(
    simplifile.read_directory(resolved)
    |> result.map_error(listing_refusal(resolved, _)),
  )
  use bounded <- result.try(within_listing_bound(names))
  Ok(list.map(bounded, fn(name) { classify(filesystem, resolved, name) }))
}

// Why a listing did not happen. `ENOTDIR` is pulled out of the errno
// crowd because it is the one a program can act on: it means the path is
// there and `fs.read` is the call that was wanted, which is a repair,
// where "filesystem error on /work/x: enotdir" is a puzzle. Everything
// else keeps the backend's own description, since inventing a sentence
// for an errno nobody anticipated is how a refusal starts lying.
//
// `simplifile.read_directory` is what classifies here rather than a
// prior stat, which also settles the special files: a FIFO, a socket or
// a device node is not a directory and `readdir` says so with the same
// `Enotdir`, so all of them reach a program under the honest name
// without this needing a file-type vocabulary the `tool.FileSystem`
// seam does not have.
fn listing_refusal(
  resolved: String,
  error: simplifile.FileError,
) -> workspace.FsRefusal {
  case error {
    simplifile.Enotdir -> workspace.NotADirectory(path: resolved)
    _other ->
      workspace.ListRefused(tool.FsFailure(
        path: resolved,
        reason: simplifile.describe_error(error),
      ))
  }
}

// The count check, kept as its own function so the O(n) walk it needs is
// visible: `list.length` over a directory listing is a walk of exactly
// the thing being bounded, which is the one shape where it is the right
// answer rather than lint R5's.
fn within_listing_bound(
  names: List(String),
) -> Result(List(String), workspace.FsRefusal) {
  let count = list.length(names)
  case count > workspace.max_list_entries {
    True ->
      Error(workspace.TooManyEntries(count:, limit: workspace.max_list_entries))
    False -> Ok(names)
  }
}

fn classify(
  filesystem: tool.FileSystem,
  directory: String,
  name: String,
) -> workspace.DirEntry {
  let child = directory <> "/" <> name
  let is_directory = case filesystem.read_link(child) {
    // A symlink, a path that vanished between the readdir and this call,
    // or a seam that would not answer: none of them is a directory this
    // listing should send a program into.
    Ok(tool.LinkTarget(..)) | Ok(tool.LinkMissing) | Error(_) -> False

    // "Not a regular file" stands in for "directory", which over-reports
    // on the special files: a FIFO, a socket or a device node in the
    // workspace is reported here as a directory. `tool.LinkStatus`
    // cannot separate them — it answers link / not-a-link / missing —
    // and the seam has no `is_directory`, so the honest answer is not
    // reachable from what this function is handed. The consequence is
    // bounded: a program that follows the listing into one gets
    // `NotADirectory` from `fs.list` naming the path. An `fs.read` of a
    // FIFO is worse than a refusal — `file:read_file` on a reader-less
    // pipe blocks, so the call hangs against its own timeout rather
    // than answering `WrongKind`. Widening the seam is the fix if this
    // ever costs anything real.
    Ok(tool.NotALink) -> filesystem.is_file(child) == Ok(False)
  }
  workspace.DirEntry(name:, is_directory:)
}

// `report.emit`: the same content-addressed write `tools/blob` performs
// for an overflowed tool output, into the same store, through the same
// `blob.write_addressed`.
//
// Idempotent by construction, which is why nothing here checks for a
// prior emission: the id *is* the SHA-256 of the bytes, so emitting the
// same artifact twice answers the same id and writes the file once. The
// `is_file` probe before the write is not a correctness guard — it saves
// rewriting bytes that are already there, exactly as `blob.bound` does.
//
// The write is staged and renamed rather than performed in place. An
// address that vouches for content is only worth anything if nothing can
// ever be reached under it but that content, and a direct write leaves
// exactly that: a torn file whose SHA-256 name says it is whole, which
// every later reader believes. `blob.write_addressed`'s doc carries the
// argument; what this side owes it is a staging name unique to one
// write, since two concurrent first emissions of identical bytes are
// precisely what a content address cannot tell apart. Eight bytes off
// the session's own entropy is that, and the `.tmp` it leaves behind on
// a crash is garbage rather than a lie.
fn emitting(
  filesystem: tool.FileSystem,
  blob_root: String,
  entropy: fn(Int) -> BitArray,
) -> artifact.Emit {
  fn(art: artifact.Artifact) {
    let ref = blob.ref_for(art.bytes)
    let path = blob.ref_path(blob_root, ref)
    use Nil <- result.try(
      filesystem.create_directory_all(blob_root)
      |> result.map_error(store_failed),
    )
    use present <- result.try(
      filesystem.is_file(path) |> result.map_error(store_failed),
    )
    use Nil <- result.try(case present {
      True -> Ok(Nil)
      False ->
        blob.write_addressed(
          filesystem:,
          path:,
          temporary: blob.temp_path(blob_root, ref, staging_tag(entropy)),
          bytes: art.bytes,
        )
        |> result.map_error(store_failed)
    })
    Ok(ref)
  }
}

// What makes one emission's staging file its own. Random rather than
// derived, because nothing in an `artifact.Artifact` distinguishes two
// concurrent emissions of the same bytes — that is what a content
// address means — and the emit closure is built once per execution, so
// there is no per-call coordinate to reach for either.
const staging_tag_bytes = 8

fn staging_tag(entropy: fn(Int) -> BitArray) -> String {
  entropy(staging_tag_bytes) |> bit_array.base16_encode |> string.lowercase
}

fn store_failed(error: tool.FsError) -> artifact.EmitRefusal {
  artifact.StoreFailed(reason: case error {
    tool.FsNotFound(path:) -> "the blob store is missing: " <> path
    tool.FsPermissionDenied(path:) -> "the blob store is not writable: " <> path
    tool.FsFailure(path:, reason:) ->
      "the blob store would not take the artifact (" <> path <> "): " <> reason
  })
}

// The lifetime admission ceilings the execution runs under.
//
// **Both seams declare one, and they overlap in exactly one capability.**
// The test a capability has to meet is `satellite.CapCeiling`'s: does a
// call *mint something that outlives the execution*. On the orchestration
// seam four of the six `strand.*` calls do — a child strand, a durable
// message that can start a run, a durable register, and the scan that
// reads them. On the workspace seam none of `fs.read`, `fs.list` or
// `kv.*` does: two are reads bounded by their own size guards, and the
// scratch store is bounded store-side by a byte cap with eviction, which
// is the right instrument for something that must not *grow* rather than
// something that must not be called often.
//
// `fs.write` and `fs.edit` are the arms that argument has to be made
// about rather than around, because they are writes and what they write
// outlives the execution. They have no ceiling because the numbers
// already bound them and a ceiling would not. One bridged write is
// capped by the 16 MiB cap-channel frame — far under the 1 GiB
// `limits.fsize_bytes` the same execution's jailed `proc.run` writes
// under, so the bridge is the *narrower* door onto the same workspace —
// and the loop is bounded by the wall deadline and the pooled
// outstanding-effect cap, exactly as a jailed write loop is. What
// separates them from `report.emit` is the kind of thing written: a
// workspace file is the program's working state, overwritten by the
// next write to the same path, inside a tree the operator already made
// writable; an artifact is a mint into a store the session curates,
// which nothing replaces. `codemode/workspace.ceilings` carries the
// whole of it.
//
// `report.emit` is the one that meets the test on both seams, because it
// is the one capability both allowlists carry: every admitted call writes
// a content-addressed file into a store that outlives the session. So the
// workspace seam's ceiling list is not empty — it was, and this comment
// said so, until `report.emit` routed.
//
// Read off the surface beside the router, and for the same reason: the
// ceilings belong to the router whose calls mint things, so the two can
// never be chosen apart. Only the spawn number is a surface setting; the
// rest are the seams' own constants.
fn surface_ceilings(
  config: Config,
  request: codemode_tool.Request,
) -> List(satellite.CapCeiling) {
  case config.surface, vetting_seam(request.seam) {
    Workspace, _seam | Both(..), vet_policy.WorkspaceSeam ->
      workspace.ceilings(workspace_seam(config, request))
    Orchestration(spawn_ceiling:, ..), _seam
    | Both(spawn_ceiling:, ..), _seam
    ->
      orchestration.ceilings(
        spawn_ceiling,
        emit_admissions: artifact.default_emit_ceiling,
      )
  }
}

/// The hermetic build's configuration. It carries no operation, step or
/// budget of its own any more: those arrive with the `PhaseIdentity` the
/// pipeline derives, which is what stops a second set of coordinates from
/// being written here.
///
/// ## Examples
///
/// ```gleam
/// // codemode.build_config(config, request).timeout_ms
/// //   == config.build_timeout_ms
/// ```
///
pub fn build_config(
  config: Config,
  request: codemode_tool.Request,
) -> build.BuildConfig {
  build.BuildConfig(
    broker: config.broker,
    seed_root: config.seed_root,
    gleam_path: config.gleam_path,
    base_policy: execution_policy(request.base_policy),
    // The Gleam and Erlang toolchains live outside the workspace; the
    // build root is the only thing it may write.
    toolchain_roots: ["/"],
    demand: request.demand,
    env: [#("PATH", config.toolchain_path)],
    dependencies: compile.default_dependencies(),
    timeout_ms: config.build_timeout_ms,
  )
}

/// The one pooled budget the whole execution draws on: the build, the
/// node, and every capability call the program makes.
///
/// ## Examples
///
/// ```gleam
/// // codemode.pooled_budget(config, 9000).deadline_ms == 9000
/// ```
///
pub fn pooled_budget(config: Config, deadline_ms: Int) -> Budget {
  budget.Budget(
    max_outstanding: config.max_outstanding,
    deadline_ms: deadline_ms,
  )
}

/// The base policy a code-mode execution is judged against: the session's
/// own, plus the two cap-channel environment names and nothing else.
///
/// See the module doc for why the addition is necessary and what it does
/// not widen. Every other dimension — writable roots, readable roots,
/// protected paths, the network posture, the limits, the scratch — is the
/// session's, unchanged, and each jailed stage then narrows it further.
///
/// ## Examples
///
/// ```gleam
/// // codemode.execution_policy(base).writable_roots == base.writable_roots
/// ```
///
pub fn execution_policy(base: SandboxPolicy) -> SandboxPolicy {
  policy.SandboxPolicy(
    ..base,
    env_allow: list.unique(
      list.append(base.env_allow, [launch.sock_env, launch.token_env]),
    ),
  )
}

// --- translating the pipeline's vocabulary --------------------------------

/// One pipeline outcome in the vocabulary the tool speaks.
///
/// The narrowing is deliberate on one axis only: `satellite.RunError`'s
/// eight variants collapse to the four that read differently to a model —
/// you ran out of time, your program died, it never started, the channel
/// broke — with the pipeline's own reason text carried through verbatim so
/// nothing diagnostic is lost.
///
/// ## Examples
///
/// ```gleam
/// // codemode.translate(pipeline.RunFailed(satellite.DeadlineExceeded))
/// //   == codemode_tool.RunFailed(codemode_tool.DeadlineExceeded)
/// ```
///
pub fn translate(outcome: pipeline.ExecOutcome) -> codemode_tool.ExecResult {
  case outcome {
    pipeline.VetRejected(rejections:) ->
      codemode_tool.VetRejected(list.map(rejections, rejection))
    pipeline.CompileFailed(error:) ->
      codemode_tool.CompileFailed(compile_failure(error))
    pipeline.RunFailed(error:) -> codemode_tool.RunFailed(run_failure(error))
    pipeline.Ran(source: _, artifact:, outcome:) ->
      codemode_tool.Ran(
        outcome: program_outcome(outcome),
        manifest_hash: artifact.manifest_hash,
      )
  }
}

fn rejection(rejection: vet.Rejection) -> codemode_tool.Rejection {
  codemode_tool.Rejection(
    rule: case rejection.rule {
      vet.NoForeignInterface -> codemode_tool.NoForeignInterface
      vet.ImportNotAllowed -> codemode_tool.ImportNotAllowed
      vet.Unparseable -> codemode_tool.Unparseable
    },
    detail: rejection.detail,
    location: case rejection.location {
      vet.SourceSpan(start:, end:) -> codemode_tool.SourceSpan(start:, end:)
      vet.SourcePoint(byte_offset:) -> codemode_tool.SourcePoint(byte_offset:)
      vet.Unlocated -> codemode_tool.Unlocated
    },
  )
}

fn compile_failure(
  error: compile.CompileError,
) -> codemode_tool.CompileFailure {
  case error {
    compile.WorkspaceSetupFailed(reason:) ->
      codemode_tool.WorkspaceSetupFailed(reason:)
    compile.BuildRejected(diagnostics:) ->
      codemode_tool.BuildRejected(diagnostics:)
    compile.BuildUnavailable(reason:) -> codemode_tool.BuildUnavailable(reason:)
    compile.ArtifactIncomplete(reason:) ->
      codemode_tool.ArtifactIncomplete(reason:)
  }
}

fn run_failure(error: satellite.RunError) -> codemode_tool.RunFailure {
  case error {
    satellite.DeadlineExceeded -> codemode_tool.DeadlineExceeded
    satellite.SatelliteGone(reason:) -> codemode_tool.SatelliteGone(reason:)
    satellite.ChannelFaulted(reason:) -> codemode_tool.ChannelFaulted(reason:)
    satellite.OutcomeMalformed(reason:) ->
      codemode_tool.ChannelFaulted(
        reason: "malformed outcome frame: " <> reason,
      )
    satellite.TokenMintFailed(reason:) ->
      codemode_tool.StartFailed(
        reason: "the cap token would not mint: " <> reason,
      )
    satellite.TokenFileFailed(reason:) ->
      codemode_tool.StartFailed(
        reason: "the cap token file could not be written: " <> reason,
      )
    satellite.HostUnavailable(reason:) ->
      codemode_tool.StartFailed(reason: "the cap-channel host: " <> reason)
    satellite.LaunchRejected(reason:) -> codemode_tool.StartFailed(reason:)
  }
}

fn program_outcome(outcome: satellite.Outcome) -> codemode_tool.Outcome {
  case outcome {
    satellite.Completed(value:) -> codemode_tool.Completed(value:)
    satellite.Errored(message:, details:) ->
      codemode_tool.Errored(message:, details:)
  }
}

// --- what actually ran -----------------------------------------------------

// Restates the pipeline's enforcement reports in the tool's own vocabulary
// (`tools` cannot see `codemode`, so the two shapes are mirrors, as
// `Outcome` already is).
//
// The applied layers and the skipped ones are separated here rather than
// left as one list with `skip:` prefixes in it, so no renderer downstream
// can present a layer the kernel did not provide as one it did.
fn translate_enforcement(
  reports: enforcement.Enforcement,
) -> codemode_tool.Enforcement {
  codemode_tool.Enforcement(
    build: stage_report(reports.build),
    node: stage_report(reports.node),
  )
}

fn stage_report(report: enforcement.Report) -> codemode_tool.Report {
  case report {
    enforcement.Unreported(reason:) -> codemode_tool.Unreported(reason:)
    enforcement.Reported(entries: _, degraded:) -> {
      let #(applied, skipped) = enforcement.layers(report)
      codemode_tool.Enforced(applied:, skipped:, degraded:)
    }
  }
}

// Neither stage ran, and the result says so for both rather than leaving
// a silence for a reader to fill in.
fn nothing_dispatched(reason: String) -> codemode_tool.Enforcement {
  codemode_tool.Enforcement(
    build: codemode_tool.Unreported(reason:),
    node: codemode_tool.Unreported(reason:),
  )
}

fn directory_of(path: String) -> String {
  case string.split(path, "/") {
    [_file] -> "."
    parts ->
      case list.reverse(parts) {
        [_file, ..rest] ->
          case string.join(list.reverse(rest), "/") {
            "" -> "/"
            directory -> directory
          }
        [] -> "."
      }
  }
}
