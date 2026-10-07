//// The satellite host — the trusted, in-harness owner of a code-mode
//// execution and the broker end of its capability channel (design §6.3
//// "Layer two: the satellite node", `docs/architecture/code-mode.md`).
////
//// A compiled `Artifact` runs in a disposable, jailed `erl` node: a full
//// BEAM for real concurrency, but with no network except the one cap
//// channel, no Erlang distribution, and a cgroup + wall deadline over the
//// whole node. This module is the *host* that launches that node, answers
//// its capability calls, enforces the deadline, and destroys it as a unit.
//// It runs in the harness VM; it never runs model-influenced code (Rule
//// Zero, `docs/architecture/effects.md`).
////
//// # Foreground whole Launch and persistent compatibility
////
//// Foreground `run` passes artifact, original identity, token and actual host
//// endpoint together to `run_channel.Launcher`. The selected physical adapter
//// owns token/socket placement and returns a paused connection. The host installs
//// original close and writer custody before acknowledging and activating it.
//// One charged frame window per direction replaces pre-connection buffering.
//// A call remains counted through bounded ReplyReady and ReplySending until the
//// writer acknowledges actual consumption. One immediate refusal/heartbeat slot
//// also holds its inbound delivery until its response is consumed.
////
//// Persistent `start` retains its separate `LaunchSpec`/`CapConnection` contract:
//// its launcher listens on the cap socket and forwards legacy `WireIn` bytes.
//// Both physical paths must preserve the native command and jail shape below.
////
//// - **argv** launches the compiled artifact's boot entry with Erlang
////   distribution OFF and no epmd, e.g.:
////   ```
////   erl -noshell -boot no_dot_erlang -pa <artifact.beam_dir> \
////       -proto_dist none -start_epmd false \
////       -run <compile.artifact_entry(artifact)> main -s init stop
////   ```
////   No `-name`/`-sname` is ever passed, so the node cannot cluster; the
////   framed cap socket is its only link to anything (two-channel doctrine).
////   `-s init stop` is not decoration: `-run` alone leaves a `-noshell`
////   node idling after the entry returns, and the node must die with the
////   program.
//// - **env** is allowlist-constructed (never inherited) and carries the
////   two cap-channel handles the boot runtime reads:
////   - `LOOM_CAP_TOKEN_FILE` — path to the private, mode-0600 token file
////     (inside a mode-0700 dir) the host wrote, readable inside the jail.
////     The runtime reads the 32-byte token and echoes it on every
////     `cap_call`. Be exact about *how* it is readable: `SandboxPolicyV1`
////     has no "bind this path" verb, so the launcher names the token's
////     directory as a readable root and the helper's base view (the whole
////     host filesystem, ro-bound) does the rest. See
////     `protocol-change/004-sandbox-policy-explicit-mounts.md` and the
////     reachability checks in `codemode/launch`.
////   - `LOOM_CAP_SOCK` — path to the AF_UNIX cap socket. The runtime
////     connects it with `gen_tcp:connect({local, Path}, 0, [binary,
////     {active,false}, {packet,raw}])`.
////   plus whatever the program's policy permits (`PATH`, …).
//// - **policy** is network OFF except the one cap socket, the session base
////   composed for this execution, and a cgroup capping memory/CPU/pids
////   with the wall deadline of `budget.deadline_ms`. The host additionally
////   enforces the wall deadline itself: on expiry it sweeps its own step
////   with `broker.abort_step` and closes the socket, killing the node and
////   every executor it fanned out. Closing the socket mid-`cap_call`
////   surfaces to the program as an `Unreachable` capability error before
////   the node dies (J3a EOF semantics), a clean way to unblock it.
////
//// # The cap-channel token: what it defends, and what it does not
////
//// The host mints a 32-byte cap-channel token (via `broker/token`, reusing
//// its constant-time check and injected entropy — no new FFI), writes it
//// to the private token file, and checks it on *every* inbound `cap_call`
//// before routing. This token is entirely separate from the broker's own
//// per-clearance exec tokens, which `clear_call` mints and revokes
//// internally and the satellite never sees.
////
//// What the check buys is **channel authentication and execution
//// binding**. A peer that never read the token file — another execution's
//// satellite, anything that found the socket — is refused, and the token
//// is bound to one `{op_id, step_id, deadline}`, so a captured token
//// cannot be replayed into another execution or after the deadline.
//// Revoking it (`broker.abort_step` on teardown) shuts the channel.
////
//// What the check does **not** buy is confinement of a hostile `.beam`
//// that slipped vetting. The token file is readable inside the jail —
//// `cap/runtime` has to read it — and its path is in an ordinary
//// environment variable. A hand-written `.beam` carries its own
//// `@external`, so it reads the file and presents the genuine token, and
//// the check passes. That adversary is confined by two other things: the
//// **kernel jail**, which leaves the cap socket as its only reachable
//// effect, and the **broker's per-call policy check**, which composes and
//// checks policy on every `cap_call` whatever token came with it. Write it
//// that way round; the token is not a bearer capability, and calling it
//// the defence against the escaped `.beam` overstates it (M4 triage
//// CH-F4).
////
//// # Pooled budget
////
//// Every native `cap_call` clears through the broker under one shared
//// `{op_id, step_id}`, so the broker pools budget across the whole
//// execution: fan-out buys parallelism, not extra resources (design §6.5;
//// the broker `CLAUDE.md` invariant "Budget is pooled per execution").
//// That pair, and the budget, arrive as the run phase's `PhaseIdentity`
//// (`codemode/identity`) — one value threaded from `run` into the host's
//// state and out again into every clearance, rather than three copies a
//// caller filled in separately. The host has no way to reach a second
//// ledger part-way through an execution because it holds no coordinates
//// it did not receive.
////
//// # The terminal outcome frame
////
//// The satellite writes exactly one terminal frame carrying the program's
//// marshalled `report.Outcome` over the same cap socket (J3a contract):
////
//// ```
//// frame = u32_be length ++ msgpack({v:1, id:0, kind:"outcome", body})
//// body  = {ok:true, value} | {ok:false, message, details}
//// ```
////
//// The host splits length-prefixed payloads, then `broker/framing` validates
//// their headers and slices their exact body bytes without allocating trees.
//// An `outcome` body enters `core/report_value.decode_terminal` and its fixed
//// preflight before any generic decoding; other kinds retain the ordinary
//// broker decoder. The persistent host below keeps its separate generic path.
//// The terminal frame is the signal the
//// program finished; the host destroys the node and then reports the
//// outcome — in that order, so the node's enforcement report, which
//// `destroy` returns, travels out with it (issue #5).
////
//// ## Flow
////
//// One execution: `run` → `run_launched` → `start_host` → `dispatch_launch` →
//// `handle_delivery` → `route_cap_call` → `dispatch_cap_call` →
//// `finish_from_payload` → `terminate`
////
//// Held open: `start` → `start_machine` → `invoke` → `host_step` → `begin` →
//// `read_frame` → `perish`
////
//// 1. `run` mints the original token; `dispatch_launch` calls whole Launch and
////    `hand_over` installs paused connection custody in `handle_connected`.
//// 2. `handle_delivery` checks the original directional reservation before
////    `handle_payload` selects raw terminal preflight or the ordinary decoder.
////    `consume_current` returns only an exact actual-consumption acknowledgement.
//// 3. `route_cap_call` and `admit_cap_call` preserve the original authority and
////    ceilings. `dispatch_cap_call` records admission before starting work.
////    `handle_cap_done` settles computation once and retains its bounded reply;
////    `flush_ready` reserves before writer publication, and
////    `handle_write_consumed` alone releases its call or immediate response slot.
//// 4. `finish_from_payload` holds a validated terminal outcome. Its final ACK
////    precedes `terminate` and `cleanup`, which observe original native and
////    transport/resource drains without replacing that known outcome. `Run.custody`
////    separately controls whether enclosing preparation directories may be removed.
//// 5. `start` launches a satellite that outlives one program: `start_machine`
////    runs the `Phase` machine `host_step`, and `invoke` asks it for one
////    answer under a fresh token.
//// 6. `begin` opens an invocation, `read_frame` and `serve_cap_call` serve its
////    capability calls. `admit_invocation_call` checks the same ceilings and
////    `dispatch_invocation_call` derives provenance from this invocation,
////    rather than the node's launch identity. `perish` destroys the host;
////    `stop` asks for the node's report.
////
//// ## Transitions
////
//// <!-- transitions: satellite.Phase -->
////
//// | state | `NodeConnected` | `Ask` | hook_result frame | `WireClosed` | `Expired` | `Halt` | capability events |
//// | --- | --- | --- | --- | --- | --- | --- | --- |
//// | `Idle` | `Idle`, buffered frames flushed | `Answering` once `begin` has minted the token, sent the `hook_call` and armed the deadline | `Destroyed`, `HostFaulted`: it correlates to nothing | `Destroyed`, the node exited | ignored, the deadline is only armed in `Answering` | machine stops, node report returned | a late `ServeStarted` is cancelled, a late `Served` ignored |
//// | `Answering` | `Answering`, buffered frames flushed | refused, `Busy` | the open id gives `Idle` and cancels the deadline; any other id gives `Destroyed` | `Destroyed`, the open caller told `HostGone` | `Destroyed`, `InvocationDeadline` | machine stops, the open caller told `HostGone` | tracked and settled into the open invocation |
//// | `Destroyed` | `Destroyed`, the late node is destroyed and its report kept | refused, `HostGone` with the reason | ignored | ignored | ignored | machine stops, the kept report returned | a late `ServeStarted` is cancelled, a late `Served` ignored |

import broker/broker.{type Broker, type CallSpec}
import broker/budget.{type Budget}
import broker/exec.{type EnforcementDemand}
import broker/framing.{type CapOutcome}
import broker/policy.{type SandboxPolicy}
import broker/token
import codemode/compile.{type Artifact}
import codemode/enforcement.{type Report}
import codemode/identity.{type PhaseIdentity}
import codemode/run_channel
import core/clock.{type Clock}
import core/msgpack.{type MsgPackValue}
import core/remote_tool
import core/report_value
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import simplifile
import tools/call_record.{type CallLog, type Ledger}
import tools/tool.{type Collected}
import weft
import weft/state_machine as sm

/// The frame kind the satellite uses for the terminal outcome (J3a).
pub const outcome_kind = "outcome"

// How long the host actor's initialiser may take.
const host_init_timeout_ms = 1000

// Slack over the wall deadline before `run` gives up on a wholly dead
// host. It has to outlast the host's own teardown, which waits on the
// launcher for the node's settlement — a `run` that gave up first would
// report a wedged host for an execution that was merely being killed
// tidily, and would throw away the node's report with it.
const result_margin_ms = 15_000

// How long a per-cap-call clearance (the synchronous `clear_call`) may take.
const clear_timeout_ms = 5000

// How long to wait for the host to acknowledge the launched connection.
const hand_over_timeout_ms = 5000

/// The structured result a code-mode program returns, decoded from the
/// terminal `outcome` frame's body (mirrors `cap/report`'s wire shape,
/// decoded here without depending on the `cap` package).
pub type Outcome {
  /// The program finished with this structured value.
  Completed(value: MsgPackValue)

  /// The program failed in a controlled way, with a message and details.
  Errored(message: String, details: MsgPackValue)
}

/// Cleanup observations are independent of program outcome and node report.
/// Callers may remove physical directories only after cleanup-safe custody.
pub type RunCustody {
  /// No native dispatch or still-owned original preparation resources remain.
  NoLaunchResources

  /// Original native, transport and physical resources actually settled/released.
  LaunchResourcesReleased

  /// Original preparation/native/resource ownership remains unresolved.
  LaunchResourcesUnresolved(reason: String)
}

/// One satellite run: the program's outcome, and what the kernel actually
/// enforced on the node that produced it.
///
/// The report is a field of the result rather than a side-channel, so
/// there is no way to obtain an outcome without also obtaining the node's
/// report. A run whose node was never launched, or whose helper never
/// reported, carries an `Unreported` saying which — never silence for a
/// reader to mistake for confinement (`codemode/enforcement`, issue #5).
///
/// `calls` applies the same discipline to what the program did. The host
/// writes the record of its capability calls from what the host decided
/// and what its own clock read, never from the program's `outcome` frame,
/// and it rides on the result so a run that failed (a deadline, a dead
/// satellite) still says which calls it had made. A run that never
/// launched carries the empty log.
pub type Run {
  Run(
    /// The known program observation is not overwritten by cleanup uncertainty.
    outcome: Result(Outcome, RunError),
    /// Original native enforcement evidence, never an inferred cleanup proof.
    node: Report,
    /// The host's original admission/completion-time call observations.
    calls: CallLog,
    /// Independent original resource custody for enclosing directory cleanup.
    custody: RunCustody,
  )
}

/// Why an execution did not return an `Outcome`. Every variant is a value;
/// none is a crash.
pub type RunError {
  /// The cap-channel token could not be minted (entropy fault).
  TokenMintFailed(reason: String)

  /// The private token file could not be written.
  TokenFileFailed(reason: String)

  /// The host actor failed to start.
  HostUnavailable(reason: String)

  /// The satellite node could not be launched.
  LaunchRejected(reason: String)

  /// The original attempt may have prepared/dispatched resources; custody stays held.
  LaunchOutcomeUnknown(reason: String)

  /// The wall deadline passed before the program finished; the node was
  /// killed as a unit.
  DeadlineExceeded

  /// The satellite's cap channel closed before the program reported an
  /// outcome (the node died or was reaped).
  SatelliteGone(reason: String)

  /// The cap channel broke the framing protocol; it was closed.
  ChannelFaulted(reason: String)

  /// The satellite's terminal `outcome` frame was malformed.
  OutcomeMalformed(reason: String)
}

// --- the cap router seam -------------------------------------------------

/// One inbound capability call, with the pooled execution context needed
/// to build its clearance.
pub type CapRequest {
  CapRequest(
    /// The capability name (e.g. `proc.run`).
    cap: String,
    /// The marshalled call arguments.
    args: MsgPackValue,
    /// The run phase's identity — the `{op_id, step_id}` this call clears
    /// under and the pooled budget it reserves against. A router receives
    /// it derived; it has no coordinates of its own to substitute
    /// (`codemode/identity`).
    identity: PhaseIdentity,
    /// The session base policy for this execution.
    base_policy: SandboxPolicy,
    /// Enforcement strictness for jailed effects.
    demand: EnforcementDemand,
    /// The allowlist-constructed child environment.
    env: List(#(String, String)),
    /// The working directory inside the jail.
    cwd: String,
    /// This call's index among the calls of *this capability* the
    /// execution has already admitted, counting from zero.
    ///
    /// The same coordinate `tool.Ctx.source_index` is for an ordinary
    /// tool call — which call this is within the artifact that produced
    /// it — for an artifact that is a program rather than an assistant
    /// message. A router servicing a capability whose effect is *minted*
    /// rather than merely performed needs it: the orchestration router
    /// derives a child strand's name partly from it, and without a
    /// per-call ordinal every spawn in one program would derive the same
    /// name and reconcile onto one child.
    ///
    /// A call refused *before* dispatch — by the router's own argument
    /// decoding, by an admission ceiling, or by the outstanding cap —
    /// consumes no ordinal, because nothing was admitted. A call the
    /// harness-side seam then refuses *does* consume one: it was
    /// admitted, it reached the plane, and it did the reads that refusal
    /// took.
    ordinal: Int,
  )
}

/// How to service one routed capability call.
///
/// Two shapes, because two genuinely different things are being asked
/// for. `ClearedCall` is an effect on the world outside the harness — a
/// process, a file, a socket — and goes through `broker.clear_call` into
/// a jail. `ServedHere` is a request the *harness itself* answers, under
/// its own policy, touching nothing outside the VM: the orchestration
/// seam's calls onto the Agency were the first of these, and the
/// workspace seam's `fs.read`, `fs.list`, `kv.*` and `report.emit`
/// (`codemode/workspace`) are the same shape — a harness-side read, a
/// process-local store, a blob write, none of them an effect a jail
/// could contain because none of them leaves the VM.
///
/// The distinction is not cosmetic. A `ClearedCall` carries a `CallSpec`,
/// and a `CallSpec` carries `{op_id, step_id, budget}` a router writes by
/// hand — the boundary `codemode/identity`'s module doc names as still
/// open. A `ServedHere` plan carries none, so a router that only ever
/// returns one cannot state coordinates at all.
pub type CapPlan {
  /// Dispatch a jailed clearance through the broker and render its
  /// settlement.
  ClearedCall(spec: CallSpec, render: fn(Collected) -> CapOutcome)

  /// Answer in the harness. `serve` runs on a process of its own — never
  /// on the host actor, which must go on reading the cap channel and
  /// arming the deadline while a call that may block for tens of seconds
  /// is outstanding.
  ///
  /// It is unlinked and bounded by `call_timeout_ms`, and a call that
  /// reaches that bound is *reaped*, not merely abandoned: the host
  /// answers `unsettled` and kills the process running `serve`, so a
  /// closure that would have gone on polling a store for an answer
  /// nobody is listening for does not outlive its own call. A wall
  /// deadline that fires mid-call still tears the node down and leaves
  /// the served call to finish into a stopped host, where its answer is
  /// dropped. That is the honest shape: there is no executor process
  /// group to revoke — where there *is* one, on `ClearedCall`, the
  /// timeout revokes it, which is what `CapStarted`'s handle is for —
  /// and the Agency call it wraps is itself bounded —
  /// a `wait` by the Agency's own ceiling, which is deliberately below
  /// `client/codemode.default_call_timeout_ms` so that the bound with an
  /// answer is the one that fires, everything else by a store round trip.
  ServedHere(serve: fn() -> CapOutcome)

  /// Answer under the invocation's custody. Host death, invocation release,
  /// explicit call cancellation and the call deadline all reap the worker.
  /// A shared transport must monitor that worker to withdraw its request.
  ScopedService(serve: fn() -> CapOutcome)
}

/// A router's in-band refusal of a capability call.
pub type CapDenial {
  CapDenial(code: String, message: String)
}

/// A lifetime ceiling on how many times one capability may be admitted
/// within a single execution, and the in-band code its refusal travels
/// under.
///
/// ## What earns a ceiling
///
/// A capability needs one when a call **mints something that outlives the
/// execution**. `agent_spawn` is the clearest case: a model pays a
/// provider round trip per spawn, so the economics bound the fan-out
/// without anything in the harness having to, and a program's loop pays
/// nothing — an implicit throttle removed has to be replaced by an
/// explicit one. The same test admits a durable message that starts a
/// run, and a durable write-once register under a program-chosen key. It
/// excludes a call whose whole cost is time, which the per-call clamp and
/// the wall deadline already bind.
///
/// A ceiling is a *lifetime* bound on admissions, deliberately distinct
/// from the pooled `max_outstanding` cap (how many effects may be in
/// flight at once) and from the Agency's `fan_out` / `session_strands`
/// caps (how many children may be live at once). A program that spawns,
/// joins, and spawns again frees a live slot every time round and would
/// pass every one of those checks forever; only a lifetime count stops
/// it. `codemode/orchestration.ceilings` is the table and argues each
/// number.
///
/// ## Why per execution, and not per turn
///
/// The tally lives in the host, so it is per execution: one host is stood
/// up per `run`, one `run` per `execute`, one `execute` per tool call. A
/// batch holding K `code_mode` calls therefore gets K fresh tallies, and
/// it is worth being exact about why that is the right unit rather than a
/// factor the model chose.
///
/// What the turn cost throttled was **zero-marginal-cost iteration**, not
/// turns. Inside one execution a program's loop is free, which is the
/// whole defect; a *second* `code_mode` call is not free — it costs an
/// authored program, a hermetic `gleam build`, a jailed node launch and
/// its own wall deadline. Its marginal cost is spawn-shaped, so a
/// per-execution ceiling reinstates exactly the economics that were lost.
/// Per turn would not be a security boundary in any case: a model that
/// can put K executions in one assistant message can put K in K messages,
/// and nothing bounds turns.
///
/// The host is also the only place the tally can be keyed honestly. One
/// host holds the one `PhaseIdentity` derived from the one `ExecIdentity`
/// a caller may mint (`codemode/identity`), so a count here is keyed to
/// that identity by construction: there is no second host to get a second
/// count from, and a router — which a caller *could* build twice — never
/// holds the tally.
///
/// If a lifetime spawn count per *batch* is ever wanted, the escalation
/// path is a fold rather than a new mechanism: the lineage ledger is
/// durable, records `minted_by: CallSite(operation, step_id,
/// source_index)` for every child, and is already read on the spawn path,
/// so a count per `{operation, step_id}` is a pure fold over data in
/// hand. It generalises to none of the other ceilings — nothing durable
/// records a note, a read or a send by call site — which is a reason to
/// build it only when a spawn count is what is actually wanted.
///
/// ## The code
///
/// `code` is the in-band refusal code, declared here by the seam rather
/// than chosen by the host, because the vocabulary is half of a contract
/// whose other half is `cap/strand.map_error`: a code no `cap` module
/// decodes reaches a program as an unnamed refusal. The host stays
/// generic over the list and knows no capability names.
pub type CapCeiling {
  CapCeiling(cap: String, admissions: Int, code: String)
}

/// Maps a `CapRequest` to a `CapPlan`, or refuses it in-band. Injected so
/// the host stays generic and tests can substitute a stub. See
/// `default_router` for the built-in table.
pub type CapRouter =
  fn(CapRequest) -> Result(CapPlan, CapDenial)

// --- the launch seam -----------------------------------------------------

/// Everything the launcher needs to start the satellite node. This record
/// *is* the launch contract; see the module doc for the socket/argv/env/
/// policy shape the production launcher must realize.
pub type LaunchSpec {
  LaunchSpec(
    /// The compiled artifact to boot.
    artifact: Artifact,
    /// Path to the private cap-channel token file (`LOOM_CAP_TOKEN_FILE`).
    token_path: String,
    /// Path to the cap-channel AF_UNIX socket (`LOOM_CAP_SOCK`).
    cap_socket_path: String,
    /// The run phase's identity: the `{op_id, step_id}` the node is
    /// dispatched under — the host's own, which is what makes
    /// `broker.abort_step` at the deadline reach it — and the pooled budget
    /// and wall deadline it shares with every `cap_call`.
    identity: PhaseIdentity,
    /// The session base policy (network off except the cap socket).
    base_policy: SandboxPolicy,
    /// The allowlist-constructed child environment.
    env: List(#(String, String)),
    /// The working directory inside the jail.
    cwd: String,
    /// Where the launcher must deliver inbound cap-channel bytes.
    wire: Subject(WireIn),
  )
}

/// The host's handle on a launched satellite: how to write outbound
/// frames, and how to destroy the node — which closes the socket and
/// hands back what the kernel enforced on the node it just reaped.
///
/// `destroy` returns the report rather than announcing it on a side
/// channel because destruction is the moment the node's story ends: the
/// host tears the node down and reports its outcome in the same breath,
/// so a report still in flight is a report the outcome cannot carry. A
/// launcher whose node never settled returns `Unreported` with the
/// reason.
pub type CapConnection {
  CapConnection(send: fn(BitArray) -> Nil, destroy: fn() -> Report)
}

/// Launches a satellite node for a `LaunchSpec`, or fails in-band with a
/// reason. Production listens on the cap socket then dispatches a jailed
/// `erl` through the broker exec path; tests inject an in-process peer.
pub type Launcher =
  fn(LaunchSpec) -> Result(CapConnection, String)

/// Inbound cap-channel events delivered to the host by the launcher.
pub type WireIn {
  /// Raw protocol bytes from the satellite.
  WireBytes(data: BitArray)

  /// The cap channel closed, with a reason.
  WireClosed(reason: String)
}

/// Foreground host facts, independent of physical token/socket placement.
/// Whole Launch owns those resources after the original artifact is selected.
pub type RunConfig {
  RunConfig(
    /// The session policy admitted for this run.
    base_policy: SandboxPolicy,
    /// Original enforcement strictness for physical effects.
    demand: EnforcementDemand,
    /// The allowlist-constructed child environment.
    env: List(#(String, String)),
    /// The working directory inside the selected physical jail.
    cwd: String,
    /// Supplies the original cap token's entropy.
    entropy: fn(Int) -> BitArray,
    /// Reads the original run's clock era, without renewing its deadline.
    clock: Clock,
    /// Retains authenticated owner capability authority.
    router: CapRouter,
    /// Runs the authenticated caller check in the admitted call worker.
    /// A refusal settles before the router serves or clears an effect.
    precheck: Precheck,
    /// Existing invocation-global admission ceilings.
    ceilings: List(CapCeiling),
    /// Bounds each original capability operation beneath the run deadline.
    call_timeout_ms: Int,
  )
}

/// The former foreground configuration vocabulary, retained for existing type
/// references. Whole-Launch `run` accepts `RunConfig`; its selected physical
/// adapter now owns token-file and socket placement. Neither configuration can
/// supply another operation, step or budget: those remain original phase facts
/// derived from the execution's one `ExecIdentity` (`codemode/identity`).
pub type SatelliteConfig {
  SatelliteConfig(
    base_policy: SandboxPolicy,
    demand: EnforcementDemand,
    env: List(#(String, String)),
    cwd: String,
    cap_socket_path: String,
    entropy: fn(Int) -> BitArray,
    clock: Clock,
    /// Writes the 32-byte cap token to a private file, returning its path.
    write_token_file: fn(BitArray) -> Result(String, String),
    /// Unlinks the token file on teardown (idempotent).
    unlink_token_file: fn(String) -> Nil,
    /// Maps capability calls to clearances.
    router: CapRouter,
    /// A check run in the call's own worker, after admission and before
    /// anything is served or cleared. An `Error` settles the call with that
    /// refusal and nothing else happens. It runs in the worker and not in
    /// the router because the router runs in this host's actor, which must
    /// only do cheap work: a check that reads durable state belongs on the
    /// process that is allowed to wait. `no_precheck` for a host with
    /// nothing to ask.
    precheck: Precheck,
    /// Lifetime admission ceilings, by capability. Empty for a seam that
    /// needs none; see `CapCeiling` for why the orchestration seam does.
    ceilings: List(CapCeiling),
    /// How long to wait for one cap call's settlement.
    call_timeout_ms: Int,
  )
}

/// The question a worker asks before it serves one call: may this call
/// proceed at all? See `SatelliteConfig.precheck`.
pub type Precheck =
  fn(CapRequest) -> Result(Nil, CapDenial)

// --- the host actor -------------------------------------------------------

// The started single-shot host: `commands` for internal messages, `wire`
// for the launcher's inbound bytes, and the actor's pid, which
// `run_launched` monitors so a host that stopped before taking the
// connection does not leave the node unreaped.
//
// `RunHost` rather than `Host` because `Host` is the *persistent* one
// further down, which a session keeps for many invocations. The two are
// different objects with different lifetimes and the names say so.
type RunHost {
  RunHost(pid: Pid, commands: Subject(Msg), wire: Subject(run_channel.Event))
}

/// The foreground host's private protocol. Only this module constructs settlements.
pub opaque type Msg {
  FromChannel(event: run_channel.Event)
  Connected(connection: run_channel.Connection, ack: Subject(Nil))
  CapStarted(id: Int, handle: broker.CallHandle)
  CapDone(id: Int, outcome: CapOutcome, drain: CapabilityDrain)
  Deadline
  Stop
}

// Reply consumption may forget a slot, but it cannot manufacture a native join.
// These facts belong to original admitted work rather than response storage.
type CapabilityDrain {
  CapabilityJoined
  CapabilityUnresolved
}

// The persistent host keeps the same computation ownership record.
type InFlight {
  InFlight(
    handle: Option(broker.CallHandle),
    cancelled: Bool,
    service: Option(weft.Cancel),
  )
}

// Completion settles the ledger once; consumption alone releases the call slot.
type ReplyDisposition {
  Computing
  ReplyReady(payload: run_channel.Payload)
  ReplySending(frame: run_channel.FrameRef)
}

type RunSlot {
  RunSlot(work: InFlight, ordinal: Int, reply: ReplyDisposition)
}

// The sole immediate response retains its inbound frame until the writer consumes it.
type Immediate {
  EmptyImmediate
  ImmediateReady(delivery: run_channel.Delivery, payload: run_channel.Payload)
  ImmediateSending(delivery: run_channel.Delivery, frame: run_channel.FrameRef)
}

type RunPhase {
  Preparing
  Serving
}

type State {
  State(
    broker: Broker,
    identity: PhaseIdentity,
    base_policy: SandboxPolicy,
    demand: EnforcementDemand,
    env: List(#(String, String)),
    cwd: String,
    router: CapRouter,
    precheck: Precheck,
    // The lifetime admission ceilings this execution runs under, and the
    // tally they are checked against. Both live here rather than in the
    // router because the host is the one thing there is exactly one of
    // per execution — see `CapCeiling`.
    ceilings: List(CapCeiling),
    admitted: Dict(String, Int),
    clock: Clock,
    call_timeout_ms: Int,
    vault: token.Vault,
    commands: Subject(Msg),
    connection: Option(run_channel.Connection),
    writer: Option(run_channel.WriteGrant),
    inbound: Option(run_channel.Window),
    current: Option(run_channel.Delivery),
    immediate: Immediate,
    fault: Option(RunError),
    inflight: Dict(Int, RunSlot),
    // Pending work and lost drains survive independently of consumed replies.
    pending_capability_work: Int,
    capability_drain: CapabilityDrain,
    ledger: Ledger,
    seqs: Dict(Int, Int),
    result: Subject(Run),
  )
}

// --- run ------------------------------------------------------------------

/// The precheck that admits every call.
///
/// ## Examples
///
/// ```gleam
/// // satellite.no_precheck(request) == Ok(Nil)
/// ```
///
pub fn no_precheck(_request: CapRequest) -> Result(Nil, CapDenial) {
  Ok(Nil)
}

/// Runs a compiled artifact in a jailed satellite, servicing its
/// capability calls through `broker` under the run phase's identity, and
/// returns the program's structured `Outcome` together with what the
/// kernel enforced on the node.
///
/// Whole Launch owns the original token/listener/native placement. This host
/// installs the paused connection before activation and retains every reply slot
/// until consumed transport acknowledgement. Cleanup observations are independent
/// of the program's known outcome and never refresh original execution authority.
///
/// ## Examples
///
/// ```gleam
/// // satellite.run(artifact, original_phase, owner_broker, run_config, whole_launch)
/// ```
pub fn run(
  artifact: Artifact,
  phase: PhaseIdentity,
  broker: Broker,
  config: RunConfig,
  launch: run_channel.Launcher,
) -> Run {
  let vault = token.new(config.entropy)
  let binding =
    token.Binding(
      op_id: identity.op_id(phase),
      step_id: identity.step_id(phase),
      policy: config.base_policy,
      deadline_ms: identity.pooled_budget(phase).deadline_ms,
    )
  case token.mint(vault, binding) {
    Error(error) -> never_launched(TokenMintFailed(mint_error_text(error)))
    Ok(#(vault, minted)) ->
      run_launched(
        artifact,
        phase,
        broker,
        config,
        launch,
        vault,
        token.to_bytes(minted),
      )
  }
}

// No Launch request was dispatched, so no asynchronous preparation exists.
fn never_launched(error: RunError) -> Run {
  Run(
    outcome: Error(error),
    node: enforcement.Unreported("no node was launched"),
    calls: call_record.empty(),
    custody: NoLaunchResources,
  )
}

fn run_launched(
  artifact: Artifact,
  phase: PhaseIdentity,
  broker: Broker,
  config: RunConfig,
  launch: run_channel.Launcher,
  vault: token.Vault,
  minted: BitArray,
) -> Run {
  let #(now, _clock) = clock.read(config.clock)
  let result_subject = process.new_subject()
  case start_host(phase, broker, config, vault, result_subject) {
    Error(error) -> never_launched(HostUnavailable(start_error_text(error)))
    Ok(host) ->
      dispatch_launch(
        artifact,
        phase,
        minted,
        config,
        launch,
        host,
        now,
        result_subject,
      )
  }
}

fn dispatch_launch(
  artifact: Artifact,
  phase: PhaseIdentity,
  minted: BitArray,
  config: RunConfig,
  launch: run_channel.Launcher,
  host: RunHost,
  now: Int,
  result_subject: Subject(Run),
) -> Run {
  let request =
    run_channel.request(
      artifact,
      phase,
      config.base_policy,
      config.demand,
      config.env,
      config.cwd,
      minted,
      run_channel.host_endpoint(host.pid, host.wire),
    )
  let launched = request |> result.try(launch)
  case launched {
    Error(run_channel.LaunchRefused(reason, preparation)) -> {
      process.send(host.commands, Stop)
      Run(
        ..never_launched(LaunchRejected(reason)),
        custody: preparation_custody(preparation),
      )
    }
    Error(run_channel.LaunchOutcomeUnknown(reason)) -> {
      process.send(host.commands, Stop)
      Run(
        ..never_launched(LaunchOutcomeUnknown(reason)),
        node: enforcement.Unreported(
          "the original Launch may have prepared or dispatched resources",
        ),
        custody: LaunchResourcesUnresolved(reason),
      )
    }
    Ok(connection) -> await_result(phase, host, connection, now, result_subject)
  }
}

fn preparation_custody(preparation: run_channel.ResourceDrain) -> RunCustody {
  case preparation {
    run_channel.ResourcesReleased -> NoLaunchResources
    run_channel.ResourcesUnresolved(reason) -> LaunchResourcesUnresolved(reason)
  }
}

// Handoff installs custody before activation. A timeout cannot invent an ownership transfer.
fn await_result(
  phase: PhaseIdentity,
  host: RunHost,
  connection: run_channel.Connection,
  now: Int,
  result_subject: Subject(Run),
) -> Run {
  let handed = hand_over(host, connection)
  let wait =
    int.max(identity.pooled_budget(phase).deadline_ms - now, 0)
    + result_margin_ms
  case handed {
    Some(closed) ->
      Run(
        outcome: Error(HostUnavailable(
          "the foreground host did not accept original custody",
        )),
        node: closed.node,
        calls: call_record.empty(),
        custody: close_custody(closed),
      )
    None ->
      case process.receive(result_subject, wait) {
        Ok(settled) -> settled
        Error(Nil) -> {
          process.send(host.commands, Stop)
          Run(
            outcome: Error(HostUnavailable(
              "no terminal result within the deadline",
            )),
            node: enforcement.Unreported(
              "the original host produced no cleanup observation",
            ),
            calls: call_record.empty(),
            custody: LaunchResourcesUnresolved(
              "the original host did not return cleanup custody",
            ),
          )
        }
      }
  }
}

type HandOver {
  RunHostTook
  RunHostGone
}

fn hand_over(
  host: RunHost,
  connection: run_channel.Connection,
) -> Option(run_channel.CloseResult) {
  let ack = process.new_subject()
  let monitor = process.monitor(host.pid)
  let selector =
    process.new_selector()
    |> process.select_map(ack, fn(_) { RunHostTook })
    |> process.select_specific_monitor(monitor, fn(_) { RunHostGone })
  process.send(host.commands, Connected(connection, ack))
  let handed = case process.selector_receive(selector, hand_over_timeout_ms) {
    Ok(RunHostTook) -> None
    Ok(RunHostGone) -> Some(connection.close())

    // Close is original and idempotent. Both participants may observe the same
    // retained result; neither creates another node or resource owner.
    Error(Nil) -> Some(connection.close())
  }
  process.demonitor_process(monitor)
  handed
}

// The one pooled budget every phase of the execution draws on, reached
// through the threaded identity rather than kept as a second copy on the
// state — a copy is exactly how the budget came to be specified in three
// places.
fn pooled(state: State) -> Budget {
  identity.pooled_budget(state.identity)
}

fn start_host(
  phase: PhaseIdentity,
  broker: Broker,
  config: RunConfig,
  vault: token.Vault,
  result_subject: Subject(Run),
) -> Result(RunHost, actor.StartError) {
  let #(started, clock) = clock.read(config.clock)
  sm.new_with_initialiser(host_init_timeout_ms, fn(commands) {
    let wire = process.new_subject()
    let selector =
      process.new_selector()
      |> process.select(commands)
      |> process.select_map(wire, FromChannel)
    let state =
      State(
        broker:,
        identity: phase,
        base_policy: config.base_policy,
        demand: config.demand,
        env: config.env,
        cwd: config.cwd,
        router: config.router,
        precheck: config.precheck,
        ceilings: config.ceilings,
        admitted: dict.new(),
        clock:,
        call_timeout_ms: config.call_timeout_ms,
        vault:,
        commands:,
        connection: None,
        writer: None,
        inbound: None,
        current: None,
        immediate: EmptyImmediate,
        fault: None,
        inflight: dict.new(),
        pending_capability_work: 0,
        capability_drain: CapabilityJoined,
        ledger: call_record.start(started),
        seqs: dict.new(),
        result: result_subject,
      )
    sm.initialised(Preparing, state)
    |> sm.selecting(selector)
    |> sm.returning(#(commands, wire))
    |> Ok
  })
  |> sm.on_event(handle)
  |> sm.start
  |> result.map(fn(started) {
    let #(commands, wire) = started.data
    RunHost(pid: started.pid, commands:, wire:)
  })
}

fn handle(
  _phase: RunPhase,
  state: State,
  msg: Msg,
) -> sm.Next(RunPhase, State, Msg) {
  case msg {
    Connected(connection, ack) -> handle_connected(state, connection, ack)
    FromChannel(run_channel.Frame(delivery)) -> handle_delivery(state, delivery)
    FromChannel(run_channel.WriteConsumed(frame)) ->
      continue_run(handle_write_consumed(state, frame))
    FromChannel(run_channel.End(incarnation, reason)) ->
      channel_ended(state, incarnation, SatelliteGone(reason))
    FromChannel(run_channel.Fault(incarnation, reason)) ->
      channel_ended(state, incarnation, ChannelFaulted(reason))
    CapStarted(id:, handle:) -> handle_cap_started(state, id, handle)
    CapDone(id:, outcome:, drain:) -> handle_cap_done(state, id, outcome, drain)
    Deadline -> terminate(state, Error(DeadlineExceeded))
    Stop -> {
      let _closed = cleanup(state)
      sm.stop()
    }
  }
}

// The installed connection owns cleanup before the adapter may receive a body.
fn handle_connected(
  state: State,
  connection: run_channel.Connection,
  ack: Subject(Nil),
) -> sm.Next(RunPhase, State, Msg) {
  case state.connection {
    Some(_) -> {
      let _closed = connection.close()
      sm.keep(state)
    }
    None -> {
      let prepared =
        run_channel.prepare_direction(
          connection.incarnation,
          run_channel.ToHost,
        )
      case run_channel.activate_direction(prepared) {
        Error(_) ->
          terminate(
            State(..state, connection: Some(connection)),
            Error(ChannelFaulted("inbound activation failed")),
          )
        Ok(inbound) -> {
          let state =
            State(
              ..state,
              connection: Some(connection),
              writer: Some(connection.initial_write_grant),
              inbound: Some(inbound),
            )
          process.send(ack, Nil)
          case connection.activate() {
            Error(_) ->
              terminate(
                state,
                Error(ChannelFaulted("original activation failed")),
              )
            Ok(Nil) -> {
              let #(now, clock) = clock.read(state.clock)
              sm.transition(to: Serving, data: State(..state, clock:))
              |> sm.with_state_timeout(
                after: int.max(pooled(state).deadline_ms - now, 0),
                sending: Deadline,
              )
            }
          }
        }
      }
    }
  }
}

fn channel_ended(
  state: State,
  incarnation: run_channel.Incarnation,
  error: RunError,
) -> sm.Next(RunPhase, State, Msg) {
  case state.connection {
    Some(connection) if connection.incarnation == incarnation ->
      terminate(state, Error(error))
    Some(_) | None -> sm.keep(state)
  }
}

fn handle_cap_started(
  state: State,
  id: Int,
  handle: broker.CallHandle,
) -> sm.Next(RunPhase, State, Msg) {
  case dict.get(state.inflight, id) {
    Error(Nil) -> {
      broker.cancel(state.broker, handle)
      sm.keep(state)
    }
    Ok(slot) -> {
      case slot.work.cancelled, slot.reply {
        False, Computing -> Nil
        True, _ | False, ReplyReady(_) | False, ReplySending(_) ->
          broker.cancel(state.broker, handle)
      }
      let work = InFlight(..slot.work, handle: Some(handle))
      sm.keep(
        State(
          ..state,
          inflight: dict.insert(state.inflight, id, RunSlot(..slot, work:)),
        ),
      )
    }
  }
}

// A computation settles once, but its bounded reply keeps the original slot.
fn handle_cap_done(
  state: State,
  id: Int,
  outcome: CapOutcome,
  drain: CapabilityDrain,
) -> sm.Next(RunPhase, State, Msg) {
  case dict.get(state.inflight, id) {
    Error(Nil) -> sm.keep(state)
    Ok(RunSlot(reply: ReplyReady(_), ..))
    | Ok(RunSlot(reply: ReplySending(_), ..)) -> sm.keep(state)
    Ok(slot) -> {
      // Only this original Computing transition observes one worker's end.
      // Copied or stale completions above cannot reduce unrelated work.
      let state =
        State(
          ..state,
          pending_capability_work: state.pending_capability_work - 1,
          capability_drain: combine_capability_drains(
            state.capability_drain,
            drain,
          ),
        )
      let state = close_call(state, id, slot.work, outcome)
      case encoded_result(id, outcome) {
        Error(reason) -> terminate(state, Error(ChannelFaulted(reason)))
        Ok(payload) -> {
          let slot = RunSlot(..slot, reply: ReplyReady(payload))
          continue_run(flush_ready(
            State(..state, inflight: dict.insert(state.inflight, id, slot)),
          ))
        }
      }
    }
  }
}

type FrameStep {
  FrameContinue(state: State)
  FrameDone(state: State, result: Result(Outcome, RunError))
}

// Sender reservation precedes mailbox publication; this mirror checks exact
// incarnation, direction, sequence and lifetime charge before semantic decode.
fn handle_delivery(
  state: State,
  delivery: run_channel.Delivery,
) -> sm.Next(RunPhase, State, Msg) {
  let #(frame, payload) = run_channel.delivered(delivery)
  let mirrored = case state.inbound, state.current {
    Some(window), None -> {
      use length <- result.try(run_channel.payload_length(
        bit_array.bit_size(run_channel.payload(payload)) / 8,
      ))
      use #(reserved, reservation) <- result.try(run_channel.reserve_frame(
        window,
        length,
      ))
      let #(expected, _) = run_channel.reservation(reservation)
      use Nil <- result.try(case expected == frame {
        True -> Ok(Nil)
        False -> Error(run_channel.StaleReservation)
      })
      run_channel.publish_frame(reserved, reservation)
    }
    None, _ | Some(_), Some(_) -> Error(run_channel.WindowUnavailable)
  }
  case mirrored {
    Error(_) ->
      terminate(
        state,
        Error(ChannelFaulted("stale or unreserved foreground frame")),
      )
    Ok(inbound) -> {
      let state =
        State(..state, inbound: Some(inbound), current: Some(delivery))
      case handle_payload(state, run_channel.payload(payload)) {
        FrameContinue(state) -> continue_run(consume_unheld(state))
        FrameDone(state, result) -> {
          // The validated result is now held. Final ACK cannot reopen the
          // reader and must precede synchronous close joining that reader.
          let state = case result {
            Ok(_) -> consume_current(state, run_channel.Final)
            Error(_) -> state
          }
          terminate(state, result)
        }
      }
    }
  }
}

fn continue_run(state: State) -> sm.Next(RunPhase, State, Msg) {
  case state.fault {
    None -> sm.keep(state)
    Some(error) -> terminate(state, Error(error))
  }
}

fn consume_unheld(state: State) -> State {
  case state.immediate {
    EmptyImmediate -> consume_current(state, run_channel.Continue)
    ImmediateReady(..) | ImmediateSending(..) -> state
  }
}

fn consume_current(
  state: State,
  disposition: run_channel.Consumption,
) -> State {
  case state.inbound, state.current {
    Some(window), Some(delivery) -> {
      let #(frame, _) = run_channel.delivered(delivery)
      let #(window, consumed) =
        run_channel.consume_frame(window, frame, disposition)
      case consumed {
        run_channel.Ignored ->
          State(
            ..state,
            fault: Some(ChannelFaulted("inbound consumption lost correlation")),
          )
        run_channel.Consumed -> {
          run_channel.consume(delivery, disposition)
          State(..state, inbound: Some(window), current: None)
        }
      }
    }
    None, _ | Some(_), None -> state
  }
}

// The raw boundary validates the original header and slices the body before
// any generic decoder can allocate terminal terms. Ordinary capability traffic
// still enters the original decoder, with its unchanged semantic checks.
fn handle_payload(state: State, payload: BitArray) -> FrameStep {
  case framing.decode_raw_envelope(payload) {
    Error(_) -> FrameDone(state, Error(ChannelFaulted("malformed cap frame")))
    Ok(raw) ->
      case framing.raw_kind(raw) == outcome_kind {
        True -> finish_from_payload(state, framing.raw_body(raw))
        False -> handle_ordinary_payload(state, payload)
      }
  }
}

fn handle_ordinary_payload(state: State, payload: BitArray) -> FrameStep {
  case framing.decode_payload(payload) {
    Ok(frame) -> handle_frame(state, frame)

    // Forward compatibility still requires a semantically valid map body.
    Error(framing.UnknownKind(..)) -> FrameContinue(state)
    Error(_) -> FrameDone(state, Error(ChannelFaulted("malformed cap frame")))
  }
}

fn handle_frame(state: State, frame: framing.Frame) -> FrameStep {
  case frame.body {
    framing.CapCall(token:, cap:, args:, deadline_ms: _) ->
      handle_cap_call(state, frame.id, token, cap, args)
    framing.Cancel -> FrameContinue(handle_cancel(state, frame.id))
    framing.Shutdown ->
      FrameDone(state, Error(ChannelFaulted("shutdown on capability channel")))
    framing.Heartbeat ->
      FrameContinue(send_frame(
        state,
        framing.Frame(id: frame.id, body: framing.Heartbeat),
      ))

    // No other kind flows satellite-to-host on the cap channel. A hostile
    // peer's stray well-formed frame is ignored (the deadline bounds it);
    // only a malformed frame closes the channel.
    _ -> FrameContinue(state)
  }
}

fn handle_cap_call(
  state: State,
  id: Int,
  presented: BitArray,
  cap: String,
  args: MsgPackValue,
) -> FrameStep {
  let #(now, clock) = clock.read(state.clock)
  let state = State(..state, clock:)

  // (a) Constant-time token check — channel authentication and the
  // `{op_id, step_id, deadline}` binding, not confinement of an escaped
  // `.beam` (see the module doc). `check_for` scans without early exit.
  case
    token.check_for(
      state.vault,
      presented,
      identity.op_id(state.identity),
      identity.step_id(state.identity),
      now,
    )
  {
    Error(refusal) ->
      FrameContinue(emit(
        state,
        id,
        framing.CapErr(code: "unauthorized", message: refusal_text(refusal)),
      ))
    Ok(_binding) ->
      case dict.has_key(state.inflight, id) {
        // The frame `id` is the satellite's to choose, and a second call
        // under a live one would overwrite its entry and have the second
        // settlement finalise the wrong record. An honest cap runtime
        // allocates each id once, so refusing costs nothing; an id whose
        // call has settled is free to be reused.
        True -> FrameDone(state, Error(ChannelFaulted("duplicate cap_call id")))
        False -> FrameContinue(route_cap_call(state, now, id, cap, args))
      }
  }
}

// Report scanning precedes body decoding, sharing one node budget across all
// keys and siblings. The closed report Outcome preserves every value distinction.
fn finish_from_payload(state: State, body: BitArray) -> FrameStep {
  case report_value.decode_terminal(body) {
    Error(_) ->
      FrameDone(state, Error(OutcomeMalformed("invalid terminal report")))
    Ok(report_value.Completed(value)) -> FrameDone(state, Ok(Completed(value)))
    Ok(report_value.Errored(message, details)) ->
      FrameDone(state, Ok(Errored(message:, details:)))
  }
}

// (b) + (c): map the cap to a plan and service it under the pooled
// `{op_id, step_id}`, tracking it so a `Cancel` can reach it.
//
// The ordinal handed to the router is the count of this capability's
// admissions so far — not of its attempts. A call the router refuses, or
// one refused by a ceiling or by the outstanding cap, mints nothing and
// so leaves the ordinal for the next call to claim.
fn route_cap_call(
  state: State,
  now: Int,
  id: Int,
  cap: String,
  args: MsgPackValue,
) -> State {
  let request =
    CapRequest(
      cap:,
      args:,
      identity: state.identity,
      base_policy: state.base_policy,
      demand: state.demand,
      env: state.env,
      cwd: state.cwd,
      ordinal: admitted_count(state, cap),
    )
  case state.router(request) {
    Error(denial) ->
      refuse_cap_call(
        state,
        now,
        id,
        cap,
        args,
        denial.code,
        framing.CapErr(code: denial.code, message: denial.message),
      )
    Ok(plan) ->
      admit_cap_call(state, now, id, cap, args, plan, fn() {
        state.precheck(request)
        |> result.map_error(fn(denial) {
          framing.CapErr(code: denial.code, message: denial.message)
        })
      })
  }
}

// Two ceilings, checked here in the actor before anything is spawned.
//
// The pooled outstanding-effect cap bounds how many calls may be in
// flight at once. The broker enforces the same cap, but only from inside
// the spawned collector, so a satellite that floods the channel used to
// buy one harness-VM process per `cap_call` up to the wall deadline
// (CH-F6). A refused call costs no process.
//
// The admission ceiling bounds how many calls of one capability an
// *execution* may make in its whole life, and it is the seam's own rule
// rather than the broker's: see `CapCeiling` for why replacing a turn
// with a loop needs one. It is checked before the outstanding cap so that
// a program at its ceiling reads the refusal that will still be true a
// moment later, rather than a transient "too many in flight".
fn admit_cap_call(
  state: State,
  now: Int,
  id: Int,
  cap: String,
  args: MsgPackValue,
  plan: CapPlan,
  check: fn() -> Result(Nil, CapOutcome),
) -> State {
  let already = admitted_count(state, cap)
  case ceiling_reached(state, cap, already) {
    Some(ceiling) ->
      refuse_cap_call(
        state,
        now,
        id,
        cap,
        args,
        ceiling.code,
        ceiling_denial(ceiling),
      )
    None -> {
      let outstanding = pooled(state).max_outstanding
      case dict.size(state.inflight) >= outstanding {
        True ->
          refuse_cap_call(
            state,
            now,
            id,
            cap,
            args,
            "budget",
            budget_denial(outstanding),
          )
        False ->
          dispatch_cap_call(state, now, id, cap, args, already, plan, check)
      }
    }
  }
}

// Both ceilings have passed. Native provenance must validate before the tally
// moves and a cancellable worker is spawned; a refusal leaves the ordinal free.
fn dispatch_cap_call(
  state: State,
  now: Int,
  id: Int,
  cap: String,
  args: MsgPackValue,
  already: Int,
  plan: CapPlan,
  check: fn() -> Result(Nil, CapOutcome),
) -> State {
  case admitted_origin(state.identity, cap, already, plan) {
    Error(reason) ->
      refuse_cap_call(
        state,
        now,
        id,
        cap,
        args,
        "invalid_origin",
        origin_denial(reason),
      )
    Ok(origin) -> {
      let #(ledger, seq) = call_record.admit(state.ledger, cap, args, now)
      let admitted = dict.insert(state.admitted, cap, already + 1)
      let service =
        spawn_worker(
          Settling(
            started: fn(handle) {
              process.send(state.commands, CapStarted(id:, handle:))
            },
            done: fn(outcome, drain) {
              process.send(state.commands, CapDone(id:, outcome:, drain:))
            },
          ),
          state.broker,
          origin,
          plan,
          check,
          state.call_timeout_ms,
        )
      let inflight =
        dict.insert(
          state.inflight,
          id,
          RunSlot(
            work: InFlight(handle: None, cancelled: False, service:),
            ordinal: seq,
            reply: Computing,
          ),
        )
      State(
        ..state,
        inflight:,
        admitted:,
        pending_capability_work: state.pending_capability_work + 1,
        ledger:,
        seqs: dict.insert(state.seqs, id, seq),
      )
    }
  }
}

// A call the host refused before dispatching it: it is on the record as
// failed under the refusal's code, took no time, and is answered at once.
// It never enters `inflight`, so its `id` is free for the satellite's next
// call.
fn refuse_cap_call(
  state: State,
  now: Int,
  id: Int,
  cap: String,
  args: MsgPackValue,
  code: String,
  refusal: CapOutcome,
) -> State {
  let ledger = call_record.refuse(state.ledger, cap, args, code, now)
  emit(State(..state, ledger:), id, refusal)
}

// Puts a settled call on the record. The host's own decision is what is
// recorded: a call the satellite cancelled before it settled is cancelled
// whatever the worker then answered, and the code is the `CapErr` code the
// host holds, never its message.
fn close_call(
  state: State,
  id: Int,
  entry: InFlight,
  outcome: CapOutcome,
) -> State {
  let #(now, clock) = clock.read(state.clock)
  let status = case entry.cancelled, outcome {
    True, _ -> call_record.CallCancelled
    False, framing.CapErr(..) -> call_record.CallFailed
    False, framing.CapOk(..) -> call_record.CallOk
  }
  let error = case outcome {
    framing.CapErr(code:, ..) -> Some(code)
    framing.CapOk(..) -> None
  }
  case dict.get(state.seqs, id) {
    Error(Nil) -> State(..state, clock:)
    Ok(seq) ->
      State(
        ..state,
        clock:,
        ledger: call_record.settle(state.ledger, seq, status, error, now),
        seqs: dict.delete(state.seqs, id),
      )
  }
}

// Native provenance is derived only after routing and both host ceilings.
// Owner callbacks carry no native command, even when they hold scoped custody.
fn admitted_origin(
  phase: PhaseIdentity,
  cap: String,
  ordinal: Int,
  plan: CapPlan,
) -> Result(Option(remote_tool.ChildOrigin), String) {
  case plan {
    ClearedCall(..) ->
      identity.capability_origin(phase, cap, ordinal, remote_tool.NativeCommand)
    ServedHere(_) | ScopedService(_) -> Ok(None)
  }
}

// Constructor errors are bounded fixed prose, never an echoed peer payload.
// Refusal precedes tally and worker creation, so the next admission keeps its ordinal.
fn origin_denial(reason: String) -> CapOutcome {
  framing.CapErr(code: "invalid_origin", message: reason)
}

// How many calls of `cap` this execution has already admitted.
fn admitted_count(state: State, cap: String) -> Int {
  dict.get(state.admitted, cap) |> result.unwrap(0)
}

// The lifetime ceiling `cap` has already reached, if this execution
// declares one for it and the tally is at it. Answering with the whole
// ceiling rather than its number is what lets the refusal travel under
// the code the seam declared: a guard cannot read a record field, and
// asking the question here keeps the admission path two arms deep.
fn ceiling_reached(
  state: State,
  cap: String,
  already: Int,
) -> Option(CapCeiling) {
  list.find(state.ceilings, fn(ceiling) {
    ceiling.cap == cap && already >= ceiling.admissions
  })
  |> option.from_result
}

// The refusal names the capability, the number, and that the bound is for
// the execution's whole lifetime: a program told only "refused" would
// loop, and one told "too many at once" would wait and try again forever.
//
// The code is the seam's, carried on the ceiling. `cap/strand.map_error`
// is the other half of that contract, so a code no `cap` module decodes
// would reach a program as an unnamed refusal — which is why the host,
// which knows no capability names, does not invent one here.
fn ceiling_denial(ceiling: CapCeiling) -> CapOutcome {
  framing.CapErr(
    code: ceiling.code,
    message: "this execution has already admitted its ceiling of "
      <> int.to_string(ceiling.admissions)
      <> " "
      <> ceiling.cap
      <> " calls; that is a lifetime cap for one program, not a "
      <> "live-at-once cap, so waiting and retrying will not free one",
  )
}

fn budget_denial(max_outstanding: Int) -> CapOutcome {
  framing.CapErr(
    code: "budget",
    message: "the pooled outstanding-effect cap "
      <> int.to_string(max_outstanding)
      <> " is reached; the call was refused before dispatch",
  )
}

// The two host shapes have different message types, so callbacks carry the
// broker handle and settlement without sharing either actor's bookkeeping.
// Scoped services publish cancellation before their worker can begin; their
// weft run watches both that signal and the host that admitted the call.
type Settling {
  Settling(
    started: fn(broker.CallHandle) -> Nil,
    done: fn(CapOutcome, CapabilityDrain) -> Nil,
  )
}

fn spawn_worker(
  settling: Settling,
  broker: Broker,
  origin: Option(remote_tool.ChildOrigin),
  plan: CapPlan,
  check: fn() -> Result(Nil, CapOutcome),
  call_timeout_ms: Int,
) -> Option(weft.Cancel) {
  let owner = process.self()

  // Publication precedes spawn, so an immediate Cancel or invocation release
  // can stop collection even before the scoped worker enters its weft run.
  let service = case plan {
    ScopedService(_) -> Some(weft.cancel_signal())
    ClearedCall(..) | ServedHere(_) -> None
  }
  process.spawn_unlinked(fn() {
    // The precheck runs here, on the worker, so a slow answer delays this
    // one call and never the host actor. A refusal settles the call before
    // the plan is touched: nothing is served and nothing is cleared.
    case check() {
      Error(outcome) -> settling.done(outcome, CapabilityJoined)
      Ok(Nil) ->
        case plan {
          ClearedCall(spec:, render:) ->
            run_collector(
              settling,
              broker,
              origin,
              spec,
              render,
              call_timeout_ms,
            )
          ServedHere(serve:) ->
            run_service(settling, serve, call_timeout_ms, None)
          ScopedService(serve:) ->
            run_service(
              settling,
              serve,
              call_timeout_ms,
              option.map(service, fn(signal) { #(signal, owner) }),
            )
        }
    }
  })
  service
}

fn run_collector(
  settling: Settling,
  broker: Broker,
  origin: Option(remote_tool.ChildOrigin),
  spec: CallSpec,
  render: fn(Collected) -> CapOutcome,
  call_timeout_ms: Int,
) -> Nil {
  let events = process.new_subject()
  let cleared = case origin {
    None -> broker.clear_call(broker, spec, events:, waiting: clear_timeout_ms)
    Some(origin) ->
      broker.clear_call_from(
        broker,
        origin,
        spec,
        events:,
        waiting: clear_timeout_ms,
      )
  }
  case cleared {
    Error(refusal) -> {
      // A lost clearance reply may precede the original queued dispatch.
      let drain = case refusal {
        broker.BrokerUnavailable -> CapabilityUnresolved
        broker.PolicyRefused(_)
        | broker.InvalidPolicy(_)
        | broker.BudgetRefused(_)
        | broker.MintRefused(_)
        | broker.NoHelper(_)
        | broker.OperationAborted -> CapabilityJoined
      }
      settling.done(refusal_outcome(refusal), drain)
    }
    Ok(handle) -> {
      settling.started(handle)
      report_collected(
        settling,
        broker,
        handle,
        render,
        events,
        call_timeout_ms,
      )
    }
  }
}

// Collects one cleared call's settlement, and revokes the clearance if
// the deadline arrives first.
//
// The cancel is the same obligation `run_service` discharges by killing
// its worker, discharged through the mechanism this side actually has.
// A `ServedHere` call has no executor process group to revoke, so the
// process running it is the only thing to stop; a `ClearedCall` has one,
// which is the whole reason `CapStarted` carries the handle back to the
// host — and answering `unsettled` while leaving the jailed executor
// running would be reporting the call over while its effect went on.
// Bounded by the kernel and the broker's monitoring rather than
// unbounded like the served orphan was, but latent for the same reason
// and closed the same way.
//
// `broker.cancel` is a send the broker resolves against its own live
// table, so cancelling a call that has already settled — or one a
// program-driven `Cancel` cancelled first — is a no-op there rather than
// a second effect here. That is what makes this safe to issue without
// consulting the host's `cancelled` bookkeeping, which lives on a
// process this one is not.
fn report_collected(
  settling: Settling,
  broker: Broker,
  handle: broker.CallHandle,
  render: fn(Collected) -> CapOutcome,
  events: Subject(broker.CallEvent),
  call_timeout_ms: Int,
) -> Nil {
  case tool.collect_events(events, waiting: call_timeout_ms) {
    Ok(collected) -> {
      // CallSettled can also represent a lost relay whose cancellation merely
      // began. Only the original native exit supplies this boundary's witness.
      let drain = case collected.outcome {
        broker.CallExited(_) -> CapabilityJoined
        broker.CallFailed(_) -> CapabilityUnresolved
      }
      settling.done(render(collected), drain)
    }
    Error(Nil) -> {
      broker.cancel(broker, handle)
      settling.done(unsettled_outcome(), CapabilityUnresolved)
    }
  }
}

// A harness-served call, run through weft under a wall-clock deadline.
//
// The indirection buys totality. `serve` is an injected closure reaching
// a seam this module knows nothing about, so it may block for as long as
// that seam allows and it may die; either would leave the program waiting
// on a `cap_result` that never comes, until the wall deadline killed the
// node. weft settles both cases in band — too slow is `unsettled`, dead
// is `cap_failed` naming the death — which is the same posture
// `report_collected` takes toward a clearance that never settles.
//
// Answering the call is not the whole obligation, though: a `serve`
// closure still polling for an answer this process has already reported
// `unsettled` for is an orphan per timed-out call, holding the seam it
// reached open long after the program stopped listening. So the timeout
// has to reap it — the same obligation `cap/runtime` discharges on its
// blocked reader — and the reap is what makes `unsettled` the *end* of
// the call rather than only the end of the waiting. `weft.deadline` is
// what discharges it here: on a run of one plain task, hitting the
// deadline kills the worker and joins it before `start` returns, so by
// the time this function reads `Abandoned` off the account there is
// nothing left from the run that could still answer late.
fn run_service(
  settling: Settling,
  serve: fn() -> CapOutcome,
  call_timeout_ms: Int,
  custody: Option(#(weft.Cancel, Pid)),
) -> Nil {
  let served = fn() -> Result(CapOutcome, Nil) { Ok(serve()) }
  let run = weft.new([served]) |> weft.deadline(call_timeout_ms)
  let run = case custody {
    None -> run
    Some(#(signal, owner)) ->
      run |> weft.cancel_with(signal) |> weft.cancel_when_exits(owner)
  }
  let outcomes = weft.start(run)

  // The signal is one idle process, so successful settlement releases it too.
  option.map(custody, fn(pair) { weft.cancel(pair.0) })
  let #(outcome, drain) = case outcomes {
    [weft.Completed(value:, ..)] -> #(value, CapabilityJoined)
    [weft.Crashed(..)] -> #(served_died_outcome(), CapabilityJoined)
    [weft.Abandoned(..)] | [weft.NeverStarted(..)] | [weft.Failed(..)] -> #(
      unsettled_outcome(),
      CapabilityJoined,
    )

    // Unconfirmed cancellation is an outcome, never a joined worker witness.
    [weft.DrainProofLost(..)] | [weft.CancellationUnconfirmed(..)] -> #(
      unsettled_outcome(),
      CapabilityUnresolved,
    )
    [] | [_, _, ..] -> #(unsettled_outcome(), CapabilityUnresolved)
  }
  settling.done(outcome, drain)
}

fn served_died_outcome() -> CapOutcome {
  framing.CapErr(
    code: "cap_failed",
    message: "the harness-side capability died before answering",
  )
}

fn unsettled_outcome() -> CapOutcome {
  framing.CapErr(
    code: "unsettled",
    message: "no settlement within the call deadline",
  )
}

fn handle_cancel(state: State, id: Int) -> State {
  case dict.get(state.inflight, id) {
    Error(Nil) -> state
    Ok(slot) -> {
      case slot.reply {
        ReplyReady(_) | ReplySending(_) -> state
        Computing -> {
          option.map(slot.work.handle, fn(handle) {
            broker.cancel(state.broker, handle)
          })
          option.map(slot.work.service, weft.cancel)
          let work = InFlight(..slot.work, cancelled: True)
          State(
            ..state,
            inflight: dict.insert(state.inflight, id, RunSlot(..slot, work:)),
          )
        }
      }
    }
  }
}

// Outcome stays known even when cleanup cannot establish original release.
fn terminate(
  state: State,
  outcome_result: Result(Outcome, RunError),
) -> sm.Next(RunPhase, State, Msg) {
  let #(now, _clock) = clock.read(state.clock)
  let calls = call_record.finish(state.ledger, dict.values(state.seqs), now)
  let closed = cleanup(state)
  process.send(
    state.result,
    Run(
      outcome: outcome_result,
      node: closed.node,
      calls:,
      custody: capability_custody(state, close_custody(closed)),
    ),
  )
  sm.stop()
}

// Original capability uncertainty remains sticky after its response is consumed.
// Closing Launch transport cannot join separately admitted owner or native work.
fn capability_custody(state: State, launch: RunCustody) -> RunCustody {
  case state.pending_capability_work > 0, state.capability_drain, launch {
    True, _, _ | False, CapabilityUnresolved, _ ->
      LaunchResourcesUnresolved(
        "original capability work has no observed drain",
      )
    False, CapabilityJoined, launch -> launch
  }
}

fn combine_capability_drains(
  original: CapabilityDrain,
  observed: CapabilityDrain,
) -> CapabilityDrain {
  case original, observed {
    CapabilityJoined, CapabilityJoined -> CapabilityJoined
    CapabilityUnresolved, _ | _, CapabilityUnresolved -> CapabilityUnresolved
  }
}

fn close_custody(closed: run_channel.CloseResult) -> RunCustody {
  case closed.transport, closed.resources {
    run_channel.TransportJoined, run_channel.ResourcesReleased ->
      LaunchResourcesReleased
    run_channel.TransportUnresolved(reason), _ ->
      LaunchResourcesUnresolved(reason)
    run_channel.TransportJoined, run_channel.ResourcesUnresolved(reason) ->
      LaunchResourcesUnresolved(reason)
  }
}

// Original services cancel before the original physical step and independent close.
fn cleanup(state: State) -> run_channel.CloseResult {
  list.each(dict.values(state.inflight), fn(slot) {
    option.map(slot.work.service, weft.cancel)
  })
  broker.abort_step(
    state.broker,
    identity.op_id(state.identity),
    step_id: identity.step_id(state.identity),
  )
  case state.connection {
    Some(connection) -> connection.close()
    None ->
      run_channel.CloseResult(
        node: enforcement.Unreported("no connection was installed"),
        transport: run_channel.TransportJoined,
        resources: run_channel.ResourcesReleased,
      )
  }
}

// Encoding must succeed before a slot can become ready. Oversize is a channel
// failure, never a dropped successful answer or an unbounded mailbox payload.
fn encoded_frame(frame: framing.Frame) -> Result(run_channel.Payload, String) {
  framing.encode(frame)
  |> result.map_error(fn(_) { "outbound frame exceeds the admitted bound" })
  |> result.try(fn(bytes) {
    run_channel.from_wire(bytes)
    |> result.map_error(fn(_) { "invalid outbound frame" })
  })
}

fn encoded_result(
  id: Int,
  outcome: CapOutcome,
) -> Result(run_channel.Payload, String) {
  encoded_frame(framing.Frame(
    id:,
    body: framing.CapResult(outcome:, usage: None),
  ))
}

// One immediate slot shares the same writer grant as admitted call responses.
fn send_frame(state: State, frame: framing.Frame) -> State {
  case state.current, state.immediate {
    Some(delivery), EmptyImmediate -> {
      case encoded_frame(frame) {
        Error(reason) -> State(..state, fault: Some(ChannelFaulted(reason)))
        Ok(payload) ->
          flush_ready(
            State(..state, immediate: ImmediateReady(delivery, payload)),
          )
      }
    }
    None, _ | Some(_), ImmediateReady(..) | Some(_), ImmediateSending(..) ->
      State(
        ..state,
        fault: Some(ChannelFaulted("immediate response slot unavailable")),
      )
  }
}

fn emit(state: State, id: Int, outcome: CapOutcome) -> State {
  send_frame(
    state,
    framing.Frame(id:, body: framing.CapResult(outcome:, usage: None)),
  )
}

// The serial host alone spends its live grant. No callback owns an unspent copy.
fn flush_ready(state: State) -> State {
  case state.writer, state.connection {
    Some(grant), Some(connection) -> {
      case state.immediate {
        ImmediateReady(delivery, payload) ->
          write_immediate(state, connection, grant, delivery, payload)
        EmptyImmediate | ImmediateSending(..) -> {
          let ready =
            dict.to_list(state.inflight)
            |> list.filter(fn(pair) {
              case pair.1.reply {
                ReplyReady(_) -> True
                Computing | ReplySending(_) -> False
              }
            })
            |> list.sort(fn(a, b) { int.compare(a.1.ordinal, b.1.ordinal) })
          case ready {
            [] -> state
            [#(id, slot), ..] -> write_reply(state, connection, grant, id, slot)
          }
        }
      }
    }
    None, _ | Some(_), None -> state
  }
}

fn write_immediate(
  state: State,
  connection: run_channel.Connection,
  grant: run_channel.WriteGrant,
  delivery: run_channel.Delivery,
  payload: run_channel.Payload,
) -> State {
  case run_channel.reserve_write(grant, payload) {
    Error(run_channel.WindowUnavailable) -> state
    Error(_) ->
      State(
        ..state,
        fault: Some(ChannelFaulted("outbound lifetime allowance exhausted")),
      )
    Ok(#(held, reservation)) -> {
      let #(frame, _) = run_channel.reservation(reservation)
      let state =
        State(
          ..state,
          writer: Some(held),
          immediate: ImmediateSending(delivery, frame),
        )
      offer_reserved(state, connection, reservation, payload)
    }
  }
}

fn write_reply(
  state: State,
  connection: run_channel.Connection,
  grant: run_channel.WriteGrant,
  id: Int,
  slot: RunSlot,
) -> State {
  case slot.reply {
    Computing | ReplySending(_) -> state
    ReplyReady(payload) ->
      case run_channel.reserve_write(grant, payload) {
        Error(run_channel.WindowUnavailable) -> state
        Error(_) ->
          State(
            ..state,
            fault: Some(ChannelFaulted("outbound lifetime allowance exhausted")),
          )
        Ok(#(held, reservation)) -> {
          let #(frame, _) = run_channel.reservation(reservation)
          let slot = RunSlot(..slot, reply: ReplySending(frame))
          let state =
            State(
              ..state,
              writer: Some(held),
              inflight: dict.insert(state.inflight, id, slot),
            )
          offer_reserved(state, connection, reservation, payload)
        }
      }
  }
}

fn offer_reserved(
  state: State,
  connection: run_channel.Connection,
  reservation: run_channel.Reservation,
  payload: run_channel.Payload,
) -> State {
  case connection.offer(reservation, payload) {
    Ok(Nil) -> state
    Error(_) ->
      State(
        ..state,
        fault: Some(ChannelFaulted("original writer refused reserved frame")),
      )
  }
}

// Only the exact writer acknowledgement releases either held response slot.
fn handle_write_consumed(state: State, frame: run_channel.FrameRef) -> State {
  case state.writer {
    None -> state
    Some(grant) -> {
      let #(grant, consumed) = run_channel.consume_write(grant, frame)
      case consumed {
        run_channel.Ignored -> state
        run_channel.Consumed ->
          flush_ready(release_consumed_reply(
            State(..state, writer: Some(grant)),
            frame,
          ))
      }
    }
  }
}

// Matching the immediate slot releases its original inbound ACK. Matching an
// admitted reply removes only that exact counted slot, after computation settled.
fn release_consumed_reply(state: State, frame: run_channel.FrameRef) -> State {
  case state.immediate {
    ImmediateSending(_, original) if original == frame ->
      consume_current(
        State(..state, immediate: EmptyImmediate),
        run_channel.Continue,
      )
    EmptyImmediate | ImmediateReady(..) | ImmediateSending(..) -> {
      let inflight =
        dict.filter(state.inflight, fn(_id, slot) {
          case slot.reply {
            ReplySending(original) -> original != frame
            Computing | ReplyReady(_) -> True
          }
        })
      State(..state, inflight:)
    }
  }
}

// --- the host's own length-prefix deframer -------------------------------

// The host owns frame boundaries on the cap socket so it can reach the
// `outcome` frame's body. `framing.push` splits and decodes in one step and
// hands back an `Inbound` that, for a kind it does not know, carries only
// the id and the kind — the body is gone, and `outcome` is exactly such a
// kind. `broker/framing` is frozen (spec Part 1.4), so the host splits the
// stream itself and hands each payload to `framing.decode_payload`, which
// remains the only decoder. The duplication is therefore confined to the
// u32 length read and the shared `framing.max_frame_bytes` guard; removing
// it needs a `broker/framing` variant that carries the raw body, which is a
// protocol-change proposal rather than a fix (M4 triage CH-F7).
type Deframed {
  Deframed(payloads: List(BitArray), buffer: BitArray, fault: Option(String))
}

fn deframe(buffer: BitArray) -> Deframed {
  deframe_loop(buffer, [])
}

fn deframe_loop(buffer: BitArray, seen: List(BitArray)) -> Deframed {
  case buffer {
    <<size:size(32), rest:bits>> ->
      case size > framing.max_frame_bytes {
        True -> deframe_oversized(buffer, seen, size)
        False ->
          case take_payload(rest, size) {
            // Not enough bytes yet: carry and wait for more.
            Error(Nil) -> deframe_carry(buffer, seen)
            Ok(#(payload, remainder)) ->
              deframe_loop(remainder, [payload, ..seen])
          }
      }

    // Fewer than four bytes buffered: carry.
    _ -> deframe_carry(buffer, seen)
  }
}

fn deframe_oversized(
  buffer: BitArray,
  seen: List(BitArray),
  size: Int,
) -> Deframed {
  Deframed(
    payloads: list.reverse(seen),
    buffer:,
    fault: Some("a cap frame declared " <> int.to_string(size) <> " bytes"),
  )
}

fn deframe_carry(buffer: BitArray, seen: List(BitArray)) -> Deframed {
  Deframed(payloads: list.reverse(seen), buffer:, fault: None)
}

fn take_payload(
  bytes: BitArray,
  size: Int,
) -> Result(#(BitArray, BitArray), Nil) {
  let available = bit_array.byte_size(bytes)
  case available >= size {
    False -> Error(Nil)
    True -> {
      use payload <- result.try(bit_array.slice(from: bytes, at: 0, take: size))
      use remainder <- result.try(bit_array.slice(
        from: bytes,
        at: size,
        take: available - size,
      ))
      Ok(#(payload, remainder))
    }
  }
}

// --- the default cap router ----------------------------------------------

/// The default capability router.
///
/// It services the one capability that maps cleanly onto a jailed
/// `broker.clear_call`: `proc.run`, whose argv is the command to run.
/// Everything else is somebody else's arm, and the table below says
/// whose — because "the default router refuses it" and "nothing in the
/// tree services it" are different facts and only the first is true of
/// most of these rows.
///
/// | cap | serviced by | via |
/// |---|---|---|
/// | `proc.run` | this router — the jailed executor (bash-style argv) | `clear_call` |
/// | `fs.read`, `fs.list` | `codemode/workspace`, over `tools/fs`'s own resolution | `ServedHere` |
/// | `fs.write`, `fs.edit` | `codemode/workspace`, over `tools/fs.resolve_writable` — containment *and* the protected-path refusal (#105) | `ServedHere` |
/// | `kv.get`/`set`/`delete` | `codemode/workspace`, over the host's ephemeral scratch store | `ServedHere` |
/// | `report.emit` | `codemode/artifact`, over the session's blob store | `ServedHere` |
/// | `git.*` | **nothing here, and nothing is owed**: `cap/git` composes `proc.run` inside the satellite | the row above |
/// | `net.request` | `client/extension/seam`, for an extension only, under the policy its manifest declared | `ServedHere` |
/// | `lsp.*` | `codemode/lsp`, over the session's language-server door (ADR-015) | `ServedHere` |
/// | `mcp.<server>` | `client/mcp`, per configured server (#106) | `ServedHere` |
/// | `strand.*` | `codemode/orchestration` — the *other* seam, never this one | `ServedHere` |
///
/// The `git.*` row is the one worth reading twice. `cap/git` holds no
/// capability of its own: every function in it builds a `cap/proc`
/// command and runs it, so it has worked since the day `proc.run` was
/// routed and there is no `git.*` name for any router to map. An earlier
/// version of this table promised one as pending, which over-counted the
/// harness-side bridge by a whole module (issue #16's scoping).
///
/// A caller holding the harness-side seams injects a fuller router by
/// wrapping this one (`codemode/workspace.routing`, `client/mcp.routing`);
/// what this one does not map, it refuses in band as `unsupported_cap`.
/// The result-shape of each `cap_result` is the cap module's contract in
/// `packages/cap`.
pub fn default_router(request: CapRequest) -> Result(CapPlan, CapDenial) {
  case request.cap {
    "proc.run" -> proc_plan(request)
    other ->
      Error(CapDenial(
        code: "unsupported_cap",
        message: "capability "
          <> other
          <> " is not routed by the default router",
      ))
  }
}

fn proc_plan(request: CapRequest) -> Result(CapPlan, CapDenial) {
  use _ <- result.try(reject_unserviced(request.args))
  case decode_argv(request.args) {
    Error(reason) -> Error(CapDenial(code: "invalid_argument", message: reason))
    Ok([]) ->
      Error(CapDenial(
        code: "invalid_argument",
        message: "proc.run needs a non-empty argv",
      ))
    Ok(argv) -> {
      let spec =
        broker.CallSpec(
          op_id: identity.op_id(request.identity),
          step_id: identity.step_id(request.identity),
          base_policy: request.base_policy,
          requirements: request.base_policy,
          // Whatever the run phase carries — which is the execution's
          // approved grants, since a capability call the program makes is
          // the program's own execution and not a stage that produced it.
          // A router reads them off the identity it was handed rather
          // than holding a list of its own, so an injected router cannot
          // widen a call the operator did not approve.
          grants: identity.grants(request.identity),
          response: broker.ProceedNarrowed,
          demand: request.demand,
          argv:,
          env: request.env,
          cwd: request.cwd,
          budget: identity.pooled_budget(request.identity),
        )
      Ok(ClearedCall(spec:, render: proc_render))
    }
  }
}

// The parts of a `cap/proc.Command` the default router does not service
// yet. A `Command` always carries all of them, `NilValue` where unset, so
// only a *set* one is a refusal — and it is a refusal rather than a
// silent drop: running a command in a different directory, without its
// stdin, or without its timeout, and reporting success, would let a
// program believe it did something it did not.
fn reject_unserviced(args: MsgPackValue) -> Result(Nil, CapDenial) {
  list.try_each(["cwd", "stdin", "timeout_ms", "env"], fn(field) {
    check_unserviced_field(args, field)
  })
}

fn check_unserviced_field(
  args: MsgPackValue,
  field: String,
) -> Result(Nil, CapDenial) {
  case map_field(args, field) {
    Error(_) -> Ok(Nil)
    Ok(value) ->
      case is_unset(value) {
        True -> Ok(Nil)
        False ->
          Error(CapDenial(
            code: "unsupported_argument",
            message: "proc.run `"
              <> field
              <> "` is not serviced by the default router; the command "
              <> "would have run without it",
          ))
      }
  }
}

fn is_unset(value: MsgPackValue) -> Bool {
  value == msgpack.NilValue || value == msgpack.MapValue([])
}

/// Renders a jailed process settlement to the `proc.run` result shape
/// (`exit_code`, `stdout`, `stderr`, truncation and timeout flags).
///
/// Output is rendered as msgpack *text*, not binary: `cap/proc.Output`
/// declares `stdout`/`stderr` as `String` and decodes them with
/// `wire.string_field`, which refuses a binary — a binary here would reach
/// every program as `bad proc.run result` instead of its own output.
pub fn proc_render(collected: Collected) -> CapOutcome {
  case collected.outcome {
    broker.CallExited(result:) ->
      framing.CapOk(
        value: msgpack.MapValue([
          #(msgpack.StringValue("exit_code"), msgpack.IntValue(result.code)),
          #(
            msgpack.StringValue("stdout"),
            msgpack.StringValue(output_text(collected.stdout)),
          ),
          #(
            msgpack.StringValue("stderr"),
            msgpack.StringValue(output_text(collected.stderr)),
          ),
          #(
            msgpack.StringValue("stdout_truncated"),
            msgpack.BoolValue(collected.stdout_truncated),
          ),
          #(
            msgpack.StringValue("stderr_truncated"),
            msgpack.BoolValue(collected.stderr_truncated),
          ),
          #(
            msgpack.StringValue("timed_out"),
            msgpack.BoolValue(result.timed_out),
          ),
        ]),
      )
    broker.CallFailed(failure:) ->
      framing.CapErr(
        code: "exec_failed",
        message: tool.exec_failure_text(failure),
      )
  }
}

// Jailed output is expected to be UTF-8; anything else is summarized
// rather than corrupted into a program's `String` (the same rule
// `tools/bash` applies to the transcript).
fn output_text(bytes: BitArray) -> String {
  case bit_array.to_string(bytes) {
    Ok(text) -> text
    Error(Nil) ->
      "["
      <> int.to_string(bit_array.byte_size(bytes))
      <> " bytes of non-UTF-8 output]"
  }
}

// --- token-file I/O helpers ----------------------------------------------

/// A token-file writer that writes the 32 bytes to `<directory>/cap-token`,
/// the directory created mode 0700 and the file set mode 0600. The dir is
/// created and locked down before the file is written, so the token is
/// never world-readable even momentarily. Mirrors the broker's fd-3
/// private-file discipline (`docs/architecture/effects.md`).
pub fn private_token_writer(
  directory: String,
) -> fn(BitArray) -> Result(String, String) {
  fn(bytes) {
    let path = directory <> "/cap-token"
    use _ <- result.try(private_directory(directory))
    use _ <- result.try(
      simplifile.write_bits(to: path, bits: bytes)
      |> file_result("write token file"),
    )
    use _ <- result.try(
      simplifile.set_permissions_octal(for_file_at: path, to: 0o600)
      |> file_result("lock down token file"),
    )
    Ok(path)
  }
}

fn private_directory(directory: String) -> Result(Nil, String) {
  use _ <- result.try(
    simplifile.create_directory_all(directory)
    |> file_result("create token directory"),
  )
  simplifile.set_permissions_octal(for_file_at: directory, to: 0o700)
  |> file_result("lock down token directory")
}

/// Unlinks a token file, ignoring an already-absent file (idempotent).
pub fn unlink_token_file(path: String) -> Nil {
  let _ = simplifile.delete(path)
  Nil
}

fn file_result(
  outcome: Result(a, simplifile.FileError),
  what: String,
) -> Result(a, String) {
  result.map_error(outcome, fn(error) {
    "could not " <> what <> ": " <> simplifile.describe_error(error)
  })
}

// --- total msgpack field decoding ----------------------------------------

fn map_field(value: MsgPackValue, key: String) -> Result(MsgPackValue, String) {
  case value {
    msgpack.MapValue(entries:) ->
      list.find_map(entries, fn(entry) {
        case entry.0 == msgpack.StringValue(key) {
          True -> Ok(entry.1)
          False -> Error(Nil)
        }
      })
      |> result.replace_error("missing field `" <> key <> "`")
    _ -> Error("expected a map, got a scalar")
  }
}

fn decode_argv(value: MsgPackValue) -> Result(List(String), String) {
  use found <- result.try(map_field(value, "argv"))
  case found {
    msgpack.ArrayValue(items:) ->
      list.try_map(items, fn(item) {
        case item {
          msgpack.StringValue(text) -> Ok(text)
          _ -> Error("argv must be an array of strings")
        }
      })
    _ -> Error("argv must be an array of strings")
  }
}

// --- diagnostics ----------------------------------------------------------

fn mint_error_text(error: token.MintError) -> String {
  case error {
    token.EntropyFailure(got_bytes:) ->
      "entropy source returned " <> int.to_string(got_bytes) <> " bytes"
    token.DuplicateToken -> "entropy source repeated a token"
  }
}

fn refusal_text(refusal: token.Refusal) -> String {
  case refusal {
    token.UnknownToken -> "the presented cap token is unknown"
    token.Revoked -> "the presented cap token was revoked"
    token.Expired(deadline_ms:) ->
      "the presented cap token expired at " <> int.to_string(deadline_ms)
    token.WrongBinding ->
      "the presented cap token is bound to another execution"
  }
}

fn start_error_text(error: actor.StartError) -> String {
  "the satellite host actor failed to start: " <> string.inspect(error)
}

fn refusal_outcome(refusal: broker.Refusal) -> CapOutcome {
  case refusal {
    broker.PolicyRefused(denial:) ->
      framing.CapErr(code: "policy", message: denial.reason)

    // The rule that failed travels with the refusal. A program that is
    // told only that its policy was invalid has nothing to act on, and
    // neither does the operator reading its output; the validator's own
    // error names the path and the rule.
    broker.InvalidPolicy(error:) ->
      framing.CapErr(
        code: "invalid_policy",
        message: "the composed policy is invalid: " <> string.inspect(error),
      )
    broker.BudgetRefused(refusal: budget_refusal) ->
      framing.CapErr(code: "budget", message: budget_text(budget_refusal))
    broker.MintRefused(error: _) ->
      framing.CapErr(code: "mint", message: "the broker could not mint a token")
    broker.NoHelper(error: _) ->
      framing.CapErr(
        code: "no_helper",
        message: "no sandbox helper was available",
      )
    broker.OperationAborted ->
      framing.CapErr(code: "aborted", message: "the operation was aborted")
    broker.BrokerUnavailable ->
      framing.CapErr(code: "broker", message: "the tool broker is unavailable")
  }
}

fn budget_text(refusal: budget.Refusal) -> String {
  case refusal {
    budget.OutstandingCapReached(cap:) ->
      "the pooled outstanding-effect cap "
      <> int.to_string(cap)
      <> " is reached"
    budget.DeadlinePassed(deadline_ms:) ->
      "the pooled wall deadline " <> int.to_string(deadline_ms) <> " has passed"
  }
}

// --- the persistent host --------------------------------------------------
//
// Everything above serves one execution: a node is launched, a program
// runs, an `outcome` frame ends it, and the node is destroyed. An
// installed extension is the other shape (ADR-007 Decision 3,
// `protocol-change/012`). Its artifact is compiled once, at install, and
// then invoked many times over a session, so paying a node boot per tool
// call is pure waste and keeping actors alive between calls is impossible.
//
// A `Host` is that node held open. It launches through the same
// `Launcher`, answers `cap_call`s through the same routers, and is
// destroyed through the same `destroy`; what it adds is the reverse
// direction — a `hook_call` out, a `hook_result` back — and the rules
// that make a long-lived node no more powerful than a disposable one.
//
// # The invocation is the unit of authority
//
// A token is minted for one `{op_id, step_id}` and checked on every
// `cap_call`, so a node that outlives an execution has no token of its
// own. `invoke` mints one for *this* invocation, sends it on the
// `hook_call`, and revokes it when the answer comes back. Between
// invocations the host holds none, and a `cap_call` arriving then is
// refused `unauthorized` before any router sees it. That is the property
// the fresh-node-per-execution design had for free and this one has to
// state: **an extension may compute between invocations, and may not
// act**.
//
// The token file the node read at boot is not an exception. It holds
// bytes this host minted nothing for, so a satellite presenting them is
// refused like any other stranger; it exists because `cap/runtime`'s boot
// sequence reads one.
//
// # One invocation at a time, and what a breach costs
//
// The protocol allows one outstanding `hook_call` per satellite, so the
// host serialises: a second `invoke` while one is open is `Busy`, and two
// strands calling one extension queue at whatever actor owns the host
// (`client/extension/hosts`), not here. The two ways the satellite can
// break that rule are answered by destroying the node, because both mean
// the far side is not the protocol this host is speaking:
//
// - a `hook_result` with no invocation open, which correlates to nothing;
// - a deadline that passes with no answer, which is a satellite this host
//   cannot go on trusting with a session's worth of state.
//
// A destroyed host stays destroyed for the rest of the session. Restarting
// one silently would hand an extension a fresh set of the actors it just
// lost without telling anybody it had lost them; the session's next
// `session_start` is where a restart belongs.
//
// # The reaping invariant, restated
//
// `docs/architecture/code-mode.md` states it for the disposable node: the
// executor reaps every process a program spawned before the next execution
// installs its channel. For a persistent satellite it becomes: **a host
// reaps its node before the session's next host for that extension
// starts.** Two things uphold that, and only one of them is a mechanism.
// The mechanism is ownership: a host owns its node's `destroy`, the
// launcher's janitor runs the same teardown when the host machine dies,
// and a destroyed host is never relaunched inside a session — so no path
// here starts a second node while the first lives.
// `cap/internal/dispatch.install_exclusive` would catch a breach and
// cannot see one from here: each satellite is its own OS process, so the
// VM-global channel slot it guards is per node and a second node's boot
// finds it empty. It is the guard for a design that reuses a node's VM,
// which this one does not.

/// A satellite held open across invocations. Opaque: it is a pid, a
/// command subject and a node, and nothing outside this module may reach
/// past `invoke` and `stop` to any of them.
pub opaque type Host {
  Host(pid: Pid, commands: Subject(HostMsg))
}

/// What the harness is asking the satellite for.
///
/// The `kind` field of a `hook_call` is `"tool"` or `"event"` on the wire
/// (Part 1.4); this is that string as a closed set on the harness side, so
/// nothing above this module composes the wire vocabulary by hand.
pub type Invocation {
  /// A model-made tool call, by the manifest's tool name.
  Tool(name: String)

  /// A hook event on the harness's own timeline, by the event's name.
  Event(name: String)
}

/// Why an invocation produced no answer. Every variant is a value.
///
/// There is no malformed-answer variant, and the absence is deliberate:
/// `broker/framing` decodes a `hook_result` body totally, so an answer
/// that will not decode is a malformed *frame*, which faults the channel
/// and arrives here as `HostFaulted`. A satellite cannot send a
/// well-formed answer this host fails to understand.
pub type InvokeError {
  /// An invocation is already open on this host. The protocol allows one,
  /// so the caller serialises rather than the host queueing.
  Busy

  /// The invocation's deadline passed with no answer. The node has been
  /// destroyed; every later `invoke` is `HostGone`.
  InvocationDeadline

  /// The satellite is not there any more, with the reason it went. Once
  /// this is the answer it is the answer for the rest of the session.
  HostGone(reason: String)

  /// The capability channel broke the framing protocol and was closed.
  HostFaulted(reason: String)
}

/// The host's configuration: everything that belongs to the *node* rather
/// than to any one invocation.
///
/// `SatelliteConfig` minus what a single execution owned. The router, the
/// ceilings and the base policy a `cap_call` is judged against are
/// arguments to `invoke` instead, because they genuinely vary per
/// invocation: `net.request`'s policy is the extension's, but its
/// `requests_per_call` ceiling is a per-call number, and the clearance
/// coordinates are the calling tool's.
pub type HostConfig {
  HostConfig(
    /// The broker every jailed effect of every invocation goes through,
    /// and the one the node itself was dispatched under.
    broker: Broker,
    /// The node's own identity: the `{op_id, step_id}` it is dispatched
    /// under and the pooled budget bounding its whole life. Distinct from
    /// any invocation's, and never used to judge a `cap_call`.
    identity: PhaseIdentity,
    /// The session base policy the node's jail is composed from.
    base_policy: SandboxPolicy,
    /// Enforcement strictness demanded of the node.
    demand: EnforcementDemand,
    /// The allowlist-constructed node environment.
    env: List(#(String, String)),
    /// The node's working directory inside the jail.
    cwd: String,
    /// Where the cap socket lives.
    cap_socket_path: String,
    /// Entropy for the token vault and the node's boot-token bytes.
    entropy: fn(Int) -> BitArray,
    /// The wall clock, read for every token check.
    clock: Clock,
    /// Writes the node's boot token to a private file, returning its path.
    write_token_file: fn(BitArray) -> Result(String, String),
    /// Unlinks the token file on teardown (idempotent).
    unlink_token_file: fn(String) -> Nil,
    /// How long to wait for one cap call's settlement.
    call_timeout_ms: Int,
  )
}

/// Everything one invocation is judged under: its clearance coordinates,
/// its policy, and the two seams that decide what its `cap_call`s may do.
///
/// A record rather than five parameters because four of the five are the
/// kind of value a caller can get the wrong way round with every type
/// still agreeing.
pub type Invoking {
  Invoking(
    /// This invocation's `{op_id, step_id}` and pooled budget: the tool
    /// call's, not the node's. The token is minted against it and every
    /// clearance the invocation makes runs under it.
    identity: PhaseIdentity,
    /// The base policy this invocation's effects compose onto.
    base_policy: SandboxPolicy,
    /// Enforcement strictness for this invocation's jailed effects.
    demand: EnforcementDemand,
    /// Maps this invocation's capability calls to plans.
    router: CapRouter,
    /// Lifetime admission ceilings **for this invocation**. The tally is
    /// reset per invocation, which is what makes a manifest's
    /// `requests_per_call` mean per call rather than per session.
    ceilings: List(CapCeiling),
  )
}

/// Launches a satellite and holds it open.
///
/// Mints nothing: the node boots on a token this host never minted, and
/// every token that works arrives on a `hook_call`. On success the node is
/// running and idle; on failure nothing is left behind, including the
/// token file.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(host) = satellite.start(artifact, config, launch)
/// ```
///
pub fn start(
  artifact: Artifact,
  config: HostConfig,
  launch: Launcher,
) -> Result(Host, RunError) {
  case config.write_token_file(config.entropy(token_bytes)) {
    Error(reason) -> Error(TokenFileFailed(reason))
    Ok(token_path) -> start_hosting(artifact, config, launch, token_path)
  }
}

fn start_hosting(
  artifact: Artifact,
  config: HostConfig,
  launch: Launcher,
  token_path: String,
) -> Result(Host, RunError) {
  case start_machine(config, token_path) {
    Error(reason) -> {
      config.unlink_token_file(token_path)
      Error(HostUnavailable(reason))
    }
    Ok(#(host, wire)) ->
      case
        launch(LaunchSpec(
          artifact:,
          token_path:,
          cap_socket_path: config.cap_socket_path,
          identity: config.identity,
          base_policy: config.base_policy,
          env: config.env,
          cwd: config.cwd,
          wire:,
        ))
      {
        Error(reason) -> {
          let _report = stop(host)
          Error(LaunchRejected(reason))
        }

        // The same acknowledged handover `run` uses, and for the same
        // race: a machine that stopped before taking the connection would
        // leave the node unreaped, so the node is destroyed here instead.
        Ok(connection) ->
          case hand_over_to(host, connection) {
            None -> Ok(host)
            Some(_report) ->
              Error(HostUnavailable(
                "the satellite host stopped before it could take the node",
              ))
          }
      }
  }
}

/// Asks the satellite to answer one invocation, and waits for the answer.
///
/// Mints a token bound to `invoking.identity`, sends it on the
/// `hook_call`, serves every `cap_call` that presents it — and refuses
/// every `cap_call` that does not — then revokes it and returns what the
/// satellite answered. A `CapErr` here is the extension's own in-band
/// refusal; an `InvokeError` is the host's account of why there is no
/// answer at all.
///
/// Blocks the caller for at most the invocation's deadline plus the slack
/// the host's own teardown needs. Never exits its caller: a host that died
/// mid-invocation is `HostGone`.
///
/// ## Examples
///
/// ```gleam
/// // satellite.invoke(host, satellite.Tool("search"), args, invoking, 30_000)
/// ```
///
pub fn invoke(
  host: Host,
  invocation: Invocation,
  args: MsgPackValue,
  invoking: Invoking,
  deadline_ms: Int,
) -> Result(CapOutcome, InvokeError) {
  let reply = process.new_subject()
  let monitor = process.monitor(host.pid)
  let selector =
    process.new_selector()
    |> process.select_map(reply, Replied)
    |> process.select_specific_monitor(monitor, AnswerLost)
  process.send(
    host.commands,
    Ask(invocation:, args:, invoking:, deadline_ms:, reply:),
  )

  // The host arms the real deadline and answers on it, so this wait only
  // guards against a host that is wedged or gone — the same relationship
  // `await_result` has to the wall deadline.
  let answer = case
    process.selector_receive(selector, deadline_ms + result_margin_ms)
  {
    Ok(Replied(answer)) -> answer
    Ok(AnswerLost(_down)) ->
      Error(HostGone("the satellite host died mid-invocation"))
    Error(Nil) ->
      Error(HostGone(
        "the satellite host did not answer within the invocation's deadline",
      ))
  }
  process.demonitor_process(monitor)
  answer
}

/// Destroys the node and returns what the kernel enforced on it.
///
/// Idempotent: a host already destroyed by a deadline or a protocol fault
/// hands back the report it kept from that teardown, because the node's
/// story ended then and there is no second one to tell.
///
/// ## Examples
///
/// ```gleam
/// // let report = satellite.stop(host)
/// ```
///
pub fn stop(host: Host) -> Report {
  let reply = process.new_subject()
  let monitor = process.monitor(host.pid)
  let selector =
    process.new_selector()
    |> process.select_map(reply, Reported)
    |> process.select_specific_monitor(monitor, ReportLost)
  process.send(host.commands, Halt(reply:))
  let report = case process.selector_receive(selector, halt_timeout_ms) {
    Ok(Reported(report)) -> report

    // A host that died before answering took its node's report with it;
    // the launcher's janitor is what reaps the node in that case.
    Ok(ReportLost(_down)) ->
      enforcement.Unreported("the satellite host died before it reported")
    Error(Nil) ->
      enforcement.Unreported("the satellite host did not report in time")
  }
  process.demonitor_process(monitor)
  report
}

// What a caller of `invoke` is selecting on: the host's answer, or the
// host's death. Two of them arrive from the same process, so exactly one
// is first and there is nothing to arbitrate.
type Answered {
  Replied(answer: Result(CapOutcome, InvokeError))
  AnswerLost(down: process.Down)
}

// The same shape for `stop`, separately, because a report and an answer
// are different values and one type carrying both would be a type
// parameter nobody reads.
type Halted {
  Reported(report: Report)
  ReportLost(down: process.Down)
}

// --- the host machine -----------------------------------------------------

// How long the host machine's initialiser may take.
const host_machine_init_ms = 1000

// How long `stop` waits for the machine's report before answering
// `Unreported`. It has to outlast the launcher's own bounded wait for the
// node's settlement, for the reason that wait is bounded at all: whichever
// timer expires first decides what the report *says*, and the truthful
// answer comes from the launcher.
const halt_timeout_ms = 10_000

// The boot token's length, matching `broker/token`'s. The bytes are never
// minted, so this is a shape rather than a secret; writing a file of the
// right length is what keeps the node's boot sequence unchanged between
// the two host shapes.
const token_bytes = 32

/// The host machine's message set. Opaque: only this module constructs
/// one, so nothing outside can forge an invocation, a settlement or a
/// deadline.
pub opaque type HostMsg {
  /// Inbound bytes, or the channel closing, from the launcher.
  FromNode(event: WireIn)

  /// The launcher has connected; the machine now owns the node.
  NodeConnected(
    send: fn(BitArray) -> Nil,
    destroy: fn() -> Report,
    ack: Subject(Nil),
  )

  /// A caller wants one invocation answered.
  Ask(
    invocation: Invocation,
    args: MsgPackValue,
    invoking: Invoking,
    deadline_ms: Int,
    reply: Subject(Result(CapOutcome, InvokeError)),
  )

  /// A routed capability call reached the broker under this handle.
  ServeStarted(id: Int, handle: broker.CallHandle)

  /// A routed capability call settled.
  Served(id: Int, outcome: CapOutcome)

  /// The open invocation's deadline passed. Armed as a state timeout on
  /// `Answering`, so leaving that state cancels it and a fire that raced
  /// its own cancellation is dropped by weft rather than delivered.
  Expired

  /// Somebody wants the node destroyed and its report.
  Halt(reply: Subject(Report))
}

// Where the host is. The deadline belongs to `Answering` and dies with it,
// which is the whole reason these are states rather than a field.
type Phase {
  /// The node is up and nothing is open.
  Idle

  /// One invocation is open, under this frame id. The id does not move
  /// while the machine is in this state; everything that does move lives
  /// in `Hosting.open`.
  Answering(id: Int)

  /// The node is gone, with the reason it went. Terminal for the session.
  Destroyed(reason: String)
}

// What the machine carries across its states.
type Hosting {
  Hosting(
    config: HostConfig,
    // The machine's own subject, so a worker spawned off the machine's
    // timeline can report back into it.
    commands: Subject(HostMsg),
    token_path: String,
    // The vault holds at most one minted token: this invocation's. Between
    // invocations it holds none, which is what refuses a `cap_call` made
    // by an actor the extension kept alive.
    vault: token.Vault,
    clock: Clock,
    // The outbound writer, once the launcher has connected. Frames emitted
    // before then buffer and flush on `Connected`.
    send: Option(fn(BitArray) -> Nil),
    destroy: Option(fn() -> Report),
    pending_out: List(BitArray),
    // Raw carry for the length-prefix deframer over the cap socket.
    buffer: BitArray,
    // The next `hook_call` frame id. Ids climb and are never reused, so a
    // late `hook_result` from a destroyed invocation matches nothing.
    next_frame: Int,
    open: Option(Open),
    // The report kept from the teardown that destroyed this host, so a
    // later `stop` is answered from memory rather than from a node that no
    // longer exists.
    node: Option(Report),
  )
}

// The one open invocation's bookkeeping.
type Open {
  Open(
    invoking: Invoking,
    reply: Subject(Result(CapOutcome, InvokeError)),
    inflight: Dict(Int, InFlight),
    // Admissions **this invocation** has spent, per capability. Reset with
    // every invocation, which is what makes a manifest's
    // `requests_per_call` a per-call number.
    admitted: Dict(String, Int),
  )
}

fn start_machine(
  config: HostConfig,
  token_path: String,
) -> Result(#(Host, Subject(WireIn)), String) {
  let #(_now, clock) = clock.read(config.clock)
  let started =
    sm.new_with_initialiser(host_machine_init_ms, fn(commands) {
      let wire = process.new_subject()
      let selector =
        process.new_selector()
        |> process.select(commands)
        |> process.select_map(wire, FromNode)
      sm.initialised(
        Idle,
        Hosting(
          config:,
          commands:,
          token_path:,
          vault: token.new(config.entropy),
          clock:,
          send: None,
          destroy: None,
          pending_out: [],
          buffer: <<>>,
          next_frame: 1,
          open: None,
          node: None,
        ),
      )
      |> sm.selecting(selector)
      |> sm.returning(#(commands, wire))
      |> Ok
    })
    |> sm.on_event(host_step)
    |> sm.start
  case started {
    Error(error) -> Error(start_error_text(error))
    Ok(machine) -> {
      let #(commands, wire) = machine.data
      Ok(#(Host(pid: machine.pid, commands:), wire))
    }
  }
}

// Hands the launched node's connection to the machine, destroying it here
// if the machine stopped before it could take it — the same race
// `hand_over` closes for the single-shot host, closed the same way.
fn hand_over_to(host: Host, connection: CapConnection) -> Option(Report) {
  let ack = process.new_subject()
  let monitor = process.monitor(host.pid)
  let outcome =
    process.new_selector()
    |> process.select_map(ack, fn(_nil) { HostTook })
    |> process.select_specific_monitor(monitor, fn(_down) { HostGoneAway })
  process.send(
    host.commands,
    NodeConnected(send: connection.send, destroy: connection.destroy, ack:),
  )
  let handed = case process.selector_receive(outcome, hand_over_timeout_ms) {
    Ok(HostGoneAway) -> Some(connection.destroy())
    Ok(HostTook) | Error(Nil) -> None
  }
  process.demonitor_process(monitor)
  handed
}

// Whether the machine took ownership of the connection before it stopped.
type Handed {
  HostTook
  HostGoneAway
}

// One event, in one phase. Every pair is written: a new message or a
// fourth phase is a compile error here rather than an event the host
// silently drops.
fn host_step(
  phase: Phase,
  hosting: Hosting,
  msg: HostMsg,
) -> sm.Next(Phase, Hosting, HostMsg) {
  case phase, msg {
    // The launcher connected. The node exists from here; nothing is armed,
    // because a host with no invocation open has no deadline to keep.
    Idle, NodeConnected(send:, destroy:, ack:)
    | Answering(..), NodeConnected(send:, destroy:, ack:)
    -> {
      list.each(list.reverse(hosting.pending_out), send)
      process.send(ack, Nil)
      sm.keep(
        Hosting(
          ..hosting,
          send: Some(send),
          destroy: Some(destroy),
          pending_out: [],
        ),
      )
    }

    // A connection arriving at a destroyed host: the node it names is one
    // nothing will ever reap, so it is destroyed here and its report is
    // kept, which is the only account of that node there will ever be.
    //
    // The acknowledgement still goes out. Withholding it would leave
    // `hand_over_to` waiting out its whole timeout and then reading the
    // silence as "the host took the connection", so `start` would stall
    // and hand back a host that is already dead — where acknowledging
    // makes the *first* `invoke` say `HostGone` with the reason at once.
    Destroyed(..), NodeConnected(send: _, destroy:, ack:) -> {
      let report = destroy()
      process.send(ack, Nil)
      sm.keep(Hosting(..hosting, node: Some(report)))
    }

    // A fresh invocation with nothing open: mint its token, send the
    // `hook_call`, and arm the deadline as this state's own timeout.
    Idle, Ask(invocation:, args:, invoking:, deadline_ms:, reply:) ->
      begin(hosting, invocation, args, invoking, deadline_ms, reply)

    // One at a time is the protocol. The caller serialises; the host says
    // so rather than queueing, because a queue would hold a second token
    // under the first invocation's answer.
    Answering(..), Ask(reply:, ..) -> {
      process.send(reply, Error(Busy))
      sm.keep(hosting)
    }

    Destroyed(reason:), Ask(reply:, ..) -> {
      process.send(reply, Error(HostGone(reason)))
      sm.keep(hosting)
    }

    Idle, FromNode(WireBytes(data:))
    | Answering(..), FromNode(WireBytes(data:))
    -> read_bytes(phase, hosting, data)

    Idle, FromNode(WireClosed(reason:))
    | Answering(..), FromNode(WireClosed(reason:))
    -> perish(hosting, HostGone("the satellite exited: " <> reason))

    // Bytes and a close after the node is gone. Both are the tail of a
    // socket already torn down, and there is nothing left to read them
    // for.
    Destroyed(..), FromNode(..) -> sm.keep(hosting)

    Answering(id: _), ServeStarted(id:, handle:) ->
      sm.keep(track_started(hosting, id, handle))

    Answering(id: _), Served(id:, outcome:) ->
      sm.keep(settle_served(hosting, id, outcome))

    // A clearance that reached the broker after its invocation closed.
    // `release` cancelled everything it had a handle for, and this is the
    // one it could not: the worker was still inside `clear_call`. Cancel
    // it now, or the jailed executor runs on to its own timeout for an
    // invocation nobody is waiting for. Frame ids climb per node, so an
    // id arriving with no invocation open always belongs to a closed one.
    Idle, ServeStarted(id: _, handle:)
    | Destroyed(..), ServeStarted(id: _, handle:)
    -> {
      broker.cancel(hosting.config.broker, handle)
      sm.keep(hosting)
    }

    // A capability settling into a host with no invocation open. Its
    // answer has nowhere to go, which is exactly what `release` intended
    // when it stopped waiting for it.
    Idle, Served(..) | Destroyed(..), Served(..) -> sm.keep(hosting)

    // The invocation's deadline. A satellite that ignores its deadline is
    // not one this host can keep trusting with a session's worth of state,
    // so the node dies with the invocation (012).
    Answering(..), Expired -> perish(hosting, InvocationDeadline)

    // The deadline is armed only on `Answering`, and weft drops a fire
    // that raced its own cancellation, so neither of these is reachable.
    Idle, Expired | Destroyed(..), Expired -> sm.keep(hosting)

    Idle, Halt(reply:) | Answering(..), Halt(reply:) -> {
      let report = teardown(hosting)

      // The stop path owes the same two things every other way out of
      // `Answering` does, and in the same order: the invocation's token
      // revoked and whatever it left in flight cancelled, before its
      // caller is told. Skipping them here left a stopped host's last
      // invocation able to clear an effect for a node that no longer
      // exists.
      let _released = release(hosting)
      answer_open(hosting, Error(HostGone("this host was stopped")))
      process.send(reply, report)
      sm.stop()
    }

    // Already destroyed: the report is the one kept from that teardown, so
    // a second `stop` is answered from memory rather than from a node that
    // is not there.
    Destroyed(..), Halt(reply:) -> {
      process.send(reply, kept_report(hosting))
      sm.stop()
    }
  }
}

// Opens an invocation: mint, send, arm.
//
// The token is minted before the frame is composed, because the frame
// carries it; and the deadline is this state's own timeout, so answering
// cancels it by leaving the state rather than by a handler remembering to.
fn begin(
  hosting: Hosting,
  invocation: Invocation,
  args: MsgPackValue,
  invoking: Invoking,
  deadline_ms: Int,
  reply: Subject(Result(CapOutcome, InvokeError)),
) -> sm.Next(Phase, Hosting, HostMsg) {
  let #(now, clock) = clock.read(hosting.clock)
  let binding =
    token.Binding(
      op_id: identity.op_id(invoking.identity),
      step_id: identity.step_id(invoking.identity),
      policy: invoking.base_policy,
      deadline_ms: now + deadline_ms,
    )
  case token.mint(hosting.vault, binding) {
    Error(mint_error) -> {
      process.send(
        reply,
        Error(HostGone(
          "the invocation's capability token could not be minted: "
          <> mint_error_text(mint_error),
        )),
      )
      sm.keep(Hosting(..hosting, clock:))
    }
    Ok(#(vault, minted)) -> {
      let id = hosting.next_frame
      let hosting =
        Hosting(
          ..hosting,
          clock:,
          vault:,
          next_frame: id + 1,
          open: Some(Open(
            invoking:,
            reply:,
            inflight: dict.new(),
            admitted: dict.new(),
          )),
        )
      let hosting =
        emit_frame(
          hosting,
          framing.Frame(
            id:,
            body: framing.HookCall(
              token: token.to_bytes(minted),
              kind: invocation_kind(invocation),
              name: invocation_name(invocation),
              args:,
              deadline_ms:,
            ),
          ),
        )
      sm.transition(to: Answering(id:), data: hosting)
      |> sm.with_state_timeout(after: deadline_ms, sending: Expired)
    }
  }
}

fn invocation_kind(invocation: Invocation) -> String {
  case invocation {
    Tool(..) -> "tool"
    Event(..) -> "event"
  }
}

fn invocation_name(invocation: Invocation) -> String {
  case invocation {
    Tool(name:) -> name
    Event(name:) -> name
  }
}

// --- inbound frames -------------------------------------------------------

// Where reading a chunk left the machine.
//
// The phase travels with the data because the frame that matters most —
// the answer to the open invocation — is a *state* change: leaving
// `Answering` is what cancels the deadline weft armed with it, and a fold
// that could only return data would leave the machine answering an
// invocation it has already answered.
type Reading {
  Reading(phase: Phase, hosting: Hosting)
}

// The step one chunk of inbound bytes produces.
fn read_bytes(
  phase: Phase,
  hosting: Hosting,
  data: BitArray,
) -> sm.Next(Phase, Hosting, HostMsg) {
  let buffer = bit_array.append(hosting.buffer, data)
  let Deframed(payloads:, buffer:, fault:) = deframe(buffer)
  let reading = Reading(phase:, hosting: Hosting(..hosting, buffer:))
  case read_payloads(reading, payloads), fault {
    Error(step), _ -> step
    Ok(Reading(phase:, hosting:)), None ->
      sm.transition(to: phase, data: hosting)
    Ok(Reading(hosting:, ..)), Some(reason) ->
      perish(hosting, HostFaulted(reason))
  }
}

// Folds the payloads of one chunk, short-circuiting on the one that ends
// the host.
fn read_payloads(
  reading: Reading,
  payloads: List(BitArray),
) -> Result(Reading, sm.Next(Phase, Hosting, HostMsg)) {
  case payloads {
    [] -> Ok(reading)
    [payload, ..rest] ->
      case read_payload(reading, payload) {
        Ok(reading) -> read_payloads(reading, rest)
        Error(step) -> Error(step)
      }
  }
}

fn read_payload(
  reading: Reading,
  payload: BitArray,
) -> Result(Reading, sm.Next(Phase, Hosting, HostMsg)) {
  case framing.decode_payload(payload) {
    Ok(frame) -> read_frame(reading, frame)

    // A well-formed frame of a kind this host does not act on, the
    // single-shot `outcome` among them: dropped, channel kept (forward
    // compatibility). A genuinely malformed frame closes the channel.
    Error(framing.UnknownKind(..)) -> Ok(reading)
    Error(_) ->
      Error(perish(reading.hosting, HostFaulted("a cap frame was malformed")))
  }
}

fn read_frame(
  reading: Reading,
  frame: framing.Frame,
) -> Result(Reading, sm.Next(Phase, Hosting, HostMsg)) {
  let Reading(phase:, hosting:) = reading
  case frame.body, phase {
    framing.CapCall(token: presented, cap:, args:, deadline_ms: _), _ ->
      Ok(carrying(
        reading,
        serve_cap_call(hosting, frame.id, presented, cap, args),
      ))

    framing.Cancel, _ ->
      Ok(carrying(reading, cancel_inflight(hosting, frame.id)))

    // Shutdown belongs only to the exec helper's stdio protocol. A
    // satellite cannot use it to request host or helper retirement.
    framing.Shutdown, _ ->
      Error(perish(hosting, HostFaulted("shutdown on capability channel")))

    framing.Heartbeat, _ ->
      Ok(carrying(
        reading,
        emit_frame(
          hosting,
          framing.Frame(id: frame.id, body: framing.Heartbeat),
        ),
      ))

    // The answer to the open invocation. Matching the frame id is the
    // correlation the protocol specifies, and ids climb, so a late answer
    // from an invocation that already ended matches nothing.
    // Returning to `Idle` is what cancels the deadline.
    framing.HookResult(outcome:), Answering(id:) if id == frame.id ->
      Ok(Reading(phase: Idle, hosting: close_invocation(hosting, Ok(outcome))))

    // A `hook_result` correlating to nothing. That is a satellite not
    // speaking this protocol, and the node dies for it (012): a peer whose
    // frames the host cannot match is one whose next frame it cannot trust
    // either.
    framing.HookResult(..), Idle
    | framing.HookResult(..), Answering(..)
    | framing.HookResult(..), Destroyed(..)
    ->
      Error(perish(
        hosting,
        HostFaulted("a hook_result arrived with no invocation open for it"),
      ))

    // No other kind flows satellite-to-host. A stray well-formed frame is
    // ignored; only a malformed one closes the channel.
    framing.Hello(..), _
    | framing.ExecStart(..), _
    | framing.ExecStdin(..), _
    | framing.ExecOut(..), _
    | framing.ExecExit(..), _
    | framing.ProtocolStart(..), _
    | framing.ProtocolInput(..), _
    | framing.ProtocolInputAccepted(..), _
    | framing.ProtocolInputRefused(..), _
    | framing.ProtocolOutput(..), _
    | framing.ProtocolOutputConsumed(..), _
    | framing.ProtocolReusable(..), _
    | framing.ProtocolExit(..), _
    | framing.CapResult(..), _
    | framing.HookCall(..), _
    | framing.ErrorBody(..), _
    -> Ok(reading)
  }
}

fn carrying(reading: Reading, hosting: Hosting) -> Reading {
  Reading(..reading, hosting:)
}

// --- capability calls, under the open invocation's authority --------------

// A `cap_call` is judged against the *invocation's* token binding, so one
// made when no invocation is open has nothing to check against and is
// refused before any router sees it. That refusal is the persistent
// satellite's whole confinement story stated once.
fn serve_cap_call(
  hosting: Hosting,
  id: Int,
  presented: BitArray,
  cap: String,
  args: MsgPackValue,
) -> Hosting {
  case hosting.open {
    None ->
      emit_cap_result(
        hosting,
        id,
        framing.CapErr(
          code: "unauthorized",
          message: "this satellite has no invocation open, so it holds no "
            <> "token any capability call could be judged under",
        ),
      )
    Some(open) -> check_cap_call(hosting, open, id, presented, cap, args)
  }
}

fn check_cap_call(
  hosting: Hosting,
  open: Open,
  id: Int,
  presented: BitArray,
  cap: String,
  args: MsgPackValue,
) -> Hosting {
  let #(now, clock) = clock.read(hosting.clock)
  let hosting = Hosting(..hosting, clock:)
  case
    token.check_for(
      hosting.vault,
      presented,
      identity.op_id(open.invoking.identity),
      identity.step_id(open.invoking.identity),
      now,
    )
  {
    Error(refusal) ->
      emit_cap_result(
        hosting,
        id,
        framing.CapErr(code: "unauthorized", message: refusal_text(refusal)),
      )
    Ok(_binding) -> route_invocation_call(hosting, open, id, cap, args)
  }
}

fn route_invocation_call(
  hosting: Hosting,
  open: Open,
  id: Int,
  cap: String,
  args: MsgPackValue,
) -> Hosting {
  let already = spent(open, cap)
  let request =
    CapRequest(
      cap:,
      args:,
      identity: open.invoking.identity,
      base_policy: open.invoking.base_policy,
      demand: open.invoking.demand,
      env: hosting.config.env,
      cwd: hosting.config.cwd,
      ordinal: already,
    )
  case open.invoking.router(request) {
    Error(denial) ->
      emit_cap_result(
        hosting,
        id,
        framing.CapErr(code: denial.code, message: denial.message),
      )
    Ok(plan) -> admit_invocation_call(hosting, open, id, cap, already, plan)
  }
}

// The same two ceilings the single-shot host checks, in the same order and
// for the same reasons — a program at its lifetime ceiling should read the
// refusal that will still be true a moment later — with the tally scoped
// to this invocation rather than to the node's whole life.
fn admit_invocation_call(
  hosting: Hosting,
  open: Open,
  id: Int,
  cap: String,
  already: Int,
  plan: CapPlan,
) -> Hosting {
  let outstanding =
    identity.pooled_budget(open.invoking.identity).max_outstanding
  case reached(open.invoking.ceilings, cap, already), dict.size(open.inflight) {
    Some(ceiling), _ -> emit_cap_result(hosting, id, ceiling_denial(ceiling))
    None, live if live >= outstanding ->
      emit_cap_result(hosting, id, budget_denial(outstanding))
    None, _ -> dispatch_invocation_call(hosting, open, id, cap, already, plan)
  }
}

fn dispatch_invocation_call(
  hosting: Hosting,
  open: Open,
  id: Int,
  cap: String,
  already: Int,
  plan: CapPlan,
) -> Hosting {
  case admitted_origin(open.invoking.identity, cap, already, plan) {
    Error(reason) -> emit_cap_result(hosting, id, origin_denial(reason))
    Ok(origin) -> {
      let service =
        spawn_worker(
          host_settling(hosting, id),
          hosting.config.broker,
          origin,
          plan,
          fn() { Ok(Nil) },
          hosting.config.call_timeout_ms,
        )
      Hosting(
        ..hosting,
        open: Some(
          Open(
            ..open,
            inflight: dict.insert(
              open.inflight,
              id,
              InFlight(handle: None, cancelled: False, service:),
            ),
            admitted: dict.insert(open.admitted, cap, already + 1),
          ),
        ),
      )
    }
  }
}

fn spent(open: Open, cap: String) -> Int {
  dict.get(open.admitted, cap) |> result.unwrap(0)
}

fn reached(
  ceilings: List(CapCeiling),
  cap: String,
  already: Int,
) -> Option(CapCeiling) {
  list.find(ceilings, fn(ceiling) {
    ceiling.cap == cap && already >= ceiling.admissions
  })
  |> option.from_result
}

fn track_started(
  hosting: Hosting,
  id: Int,
  handle: broker.CallHandle,
) -> Hosting {
  case hosting.open {
    // The invocation closed while this clearance was still being made.
    // Cancel rather than track: nobody is listening for its answer.
    None -> {
      broker.cancel(hosting.config.broker, handle)
      hosting
    }
    Some(open) ->
      case dict.get(open.inflight, id) {
        Error(Nil) -> {
          broker.cancel(hosting.config.broker, handle)
          hosting
        }
        Ok(entry) -> {
          case entry.cancelled {
            True -> broker.cancel(hosting.config.broker, handle)
            False -> Nil
          }
          with_inflight(
            hosting,
            open,
            dict.insert(
              open.inflight,
              id,
              InFlight(..entry, handle: Some(handle)),
            ),
          )
        }
      }
  }
}

fn settle_served(hosting: Hosting, id: Int, outcome: CapOutcome) -> Hosting {
  case hosting.open {
    None -> hosting
    Some(open) ->
      case dict.get(open.inflight, id) {
        Error(Nil) -> hosting

        // `emit_cap_result` writes a frame and never touches `open`, so
        // the entry read above is still the one to drop.
        Ok(_entry) ->
          with_inflight(
            emit_cap_result(hosting, id, outcome),
            open,
            dict.delete(open.inflight, id),
          )
      }
  }
}

fn cancel_inflight(hosting: Hosting, id: Int) -> Hosting {
  case hosting.open {
    None -> hosting
    Some(open) ->
      case dict.get(open.inflight, id) {
        Error(Nil) -> hosting
        Ok(entry) -> {
          case entry.handle {
            Some(handle) -> broker.cancel(hosting.config.broker, handle)
            None -> Nil
          }
          option.map(entry.service, weft.cancel)
          with_inflight(
            hosting,
            open,
            dict.insert(open.inflight, id, InFlight(..entry, cancelled: True)),
          )
        }
      }
  }
}

fn with_inflight(
  hosting: Hosting,
  open: Open,
  inflight: Dict(Int, InFlight),
) -> Hosting {
  Hosting(..hosting, open: Some(Open(..open, inflight:)))
}

// The two callbacks one routed call reports through. They send into the
// machine's own subject, which the worker holds as a plain `Subject`.
fn host_settling(hosting: Hosting, id: Int) -> Settling {
  let commands = hosting.commands
  Settling(
    started: fn(handle) { process.send(commands, ServeStarted(id:, handle:)) },
    done: fn(outcome, _drain) { process.send(commands, Served(id:, outcome:)) },
  )
}

// --- closing an invocation ------------------------------------------------

// Answers the open invocation and returns to `Idle`: revoke its token,
// cancel anything it left in flight, and clear the slot. Revocation is the
// harness's half of the token rule, and it happens here rather than in the
// caller so that no path out of `Answering` can skip it.
fn close_invocation(
  hosting: Hosting,
  answer: Result(CapOutcome, InvokeError),
) -> Hosting {
  // Released before the caller is answered, so that by the time `invoke`
  // returns the token is already revoked — which is what makes the
  // module doc's "revokes it when the answer comes back" literally true
  // rather than true a scheduling moment later.
  let released = release(hosting)
  answer_open(hosting, answer)
  released
}

fn answer_open(
  hosting: Hosting,
  answer: Result(CapOutcome, InvokeError),
) -> Nil {
  case hosting.open {
    None -> Nil
    Some(open) -> process.send(open.reply, answer)
  }
}

fn release(hosting: Hosting) -> Hosting {
  case hosting.open {
    None -> hosting
    Some(open) -> {
      list.each(dict.to_list(open.inflight), fn(entry) {
        case { entry.1 }.handle {
          Some(handle) -> broker.cancel(hosting.config.broker, handle)
          None -> Nil
        }
        option.map(entry.1.service, weft.cancel)
      })

      // `revoke_all` marks rather than removes, so the vault keeps one
      // dead entry per invocation for the life of the host and
      // `check_for` pays a constant-time compare against each. That is
      // the cost of the constant-time check rather than an oversight —
      // `drop_expired` prunes on the deadline, not on revocation, so it
      // would drop nothing here — and it is linear in a session's
      // invocations rather than in anything an extension controls.
      Hosting(
        ..hosting,
        vault: token.revoke_all(
          hosting.vault,
          identity.op_id(open.invoking.identity),
        ),
        open: None,
      )
    }
  }
}

// Destroys the node, answers whatever invocation was open, and moves to
// `Destroyed` for the rest of the session.
//
// Both callers are protocol breaches rather than ordinary endings: a
// deadline the satellite ignored, or a frame it sent that correlates to
// nothing. A restart here would hand the extension a fresh set of the
// actors it just lost without telling anybody it had lost them; the
// session's next `session_start` is where a restart belongs.
fn perish(
  hosting: Hosting,
  answer: InvokeError,
) -> sm.Next(Phase, Hosting, HostMsg) {
  let report = teardown(hosting)
  answer_open(hosting, Error(answer))
  let hosting = release(hosting)
  sm.transition(
    to: Destroyed(reason: perish_reason(answer)),
    data: Hosting(..hosting, node: Some(report), send: None, destroy: None),
  )
}

fn perish_reason(answer: InvokeError) -> String {
  case answer {
    Busy -> "the host was destroyed while an invocation was open"
    InvocationDeadline ->
      "an invocation passed its deadline with no answer, so the satellite "
      <> "was destroyed; a restart is a session_start away"
    HostGone(reason:) -> reason
    HostFaulted(reason:) -> "the capability channel faulted: " <> reason
  }
}

// Destroys the node as a unit and unlinks its token file, returning what
// the kernel enforced on it. Idempotent: a host whose node is already gone
// hands back the report it kept.
fn teardown(hosting: Hosting) -> Report {
  case hosting.destroy {
    Some(destroy) -> {
      let report = destroy()
      hosting.config.unlink_token_file(hosting.token_path)
      report
    }
    None -> kept_report(hosting)
  }
}

fn kept_report(hosting: Hosting) -> Report {
  case hosting.node {
    Some(report) -> report
    None -> enforcement.Unreported("no node was launched")
  }
}

// --- outbound frames ------------------------------------------------------

fn emit_cap_result(hosting: Hosting, id: Int, outcome: CapOutcome) -> Hosting {
  emit_frame(
    hosting,
    framing.Frame(id:, body: framing.CapResult(outcome:, usage: None)),
  )
}

// Encodes and writes one frame, buffering until the launcher connects. An
// unencodable frame would be a host bug (ids are positive, bodies typed);
// dropping it costs the invocation its deadline rather than the VM.
fn emit_frame(hosting: Hosting, frame: framing.Frame) -> Hosting {
  case framing.encode(frame) {
    Error(_) -> hosting
    Ok(bytes) ->
      case hosting.send {
        Some(send) -> {
          send(bytes)
          hosting
        }
        None -> Hosting(..hosting, pending_out: [bytes, ..hosting.pending_out])
      }
  }
}
