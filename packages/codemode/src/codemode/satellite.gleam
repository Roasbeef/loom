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
//// # The satellite launch contract (the Go/sandbox agent's spec, J3c)
////
//// The host hands a `LaunchSpec` to an injected `Launcher`. Production's
//// launcher creates and listens on the cap socket, then dispatches a
//// jailed `erl` through the broker exec path (`broker.clear_call`, the
//// exec-control channel) with the shape below; a deterministic test
//// injects an in-process peer instead. The contract:
////
//// - **cap socket first.** Before launching the node the launcher creates
////   and listens on an AF_UNIX stream socket at `cap_socket_path`
////   (`gen_tcp` with `{local, Path}`, or an FFI equivalent), then accepts
////   the satellite's connection. Frames are length-prefixed msgpack
////   (`u32_be length ++ msgpack`); Gleam owns frame boundaries (packet
////   raw). The launcher wires the socket's inbound bytes to
////   `LaunchSpec.wire` and returns a `CapConnection` whose `send` writes
////   outbound frames and whose `destroy` closes the socket, reaps the
////   node, and hands back what the kernel enforced on it.
//// - **argv** launches the compiled artifact's boot entry with Erlang
////   distribution OFF and no epmd, e.g.:
////   ```
////   erl -noshell -boot no_dot_erlang -pa <artifact.beam_dir> \
////       -proto_dist none -start_epmd false \
////       -run <artifact.entry_module> main -s init stop
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
////   enforces the wall deadline itself: on expiry it `broker.abort`s the
////   operation and closes the socket, killing the node and every executor
////   it fanned out. Closing the socket mid-`cap_call` surfaces to the
////   program as an `Unreachable` capability error before the node dies
////   (J3a EOF semantics), a clean way to unblock it.
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
//// Revoking it (`broker.abort` on teardown) shuts the channel.
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
//// Every `cap_call` becomes a `broker.clear_call` under one shared
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
//// `broker/framing` does not know the `outcome` kind — it would classify
//// the frame as `UnknownKind` and discard the body — so the host runs its
//// *own* small deframer over the cap socket: it splits length-prefixed
//// payloads itself, hands `cap_call`/`cancel`/`heartbeat` payloads to
//// `broker/framing` for typed decoding, and decodes the one `outcome`
//// frame's body itself into an `Outcome`. That frame is the signal the
//// program finished; the host destroys the node and then reports the
//// outcome — in that order, so the node's enforcement report, which
//// `destroy` returns, travels out with it (issue #5).

import broker/broker.{type Broker, type CallSpec}
import broker/budget.{type Budget}
import broker/exec.{type EnforcementDemand}
import broker/framing.{type CapOutcome}
import broker/policy.{type SandboxPolicy}
import broker/token
import codemode/compile.{type Artifact}
import codemode/enforcement.{type Report}
import codemode/identity.{type PhaseIdentity}
import core/clock.{type Clock}
import core/msgpack.{type MsgPackValue}
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
import tools/tool.{type Collected}

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

/// One satellite run: the program's outcome, and what the kernel actually
/// enforced on the node that produced it.
///
/// The report is a field of the result rather than a side-channel, so
/// there is no way to obtain an outcome without also obtaining the node's
/// report. A run whose node was never launched, or whose helper never
/// reported, carries an `Unreported` saying which — never silence for a
/// reader to mistake for confinement (`codemode/enforcement`, issue #5).
pub type Run {
  Run(outcome: Result(Outcome, RunError), node: Report)
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
/// seam's calls onto the Agency are the first of these, and the
/// harness-side `fs`/`kv`/`report` rows of `default_router`'s table will
/// be the next.
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
  /// It is unlinked and bounded by `call_timeout_ms`, so a wall deadline
  /// that fires mid-call tears the node down and leaves the served call
  /// to finish into a stopped host, where its answer is dropped. That is
  /// the honest shape: there is no executor process group to revoke, and
  /// the Agency call it wraps is itself bounded — a `wait` by the
  /// Agency's own ceiling, everything else by a store round trip.
  ServedHere(serve: fn() -> CapOutcome)
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
    /// `broker.abort` at the deadline reach it — and the pooled budget
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

/// The host's configuration: the session base and the injected effect
/// seams (entropy, clock, token-file I/O, and the cap router).
///
/// Carries no operation, step or budget: the run phase's identity is an
/// argument to `run`, derived from the execution's one `ExecIdentity`, so
/// a host cannot be configured to run under coordinates of its own
/// (`codemode/identity`).
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
    /// Lifetime admission ceilings, by capability. Empty for a seam that
    /// needs none; see `CapCeiling` for why the orchestration seam does.
    ceilings: List(CapCeiling),
    /// How long to wait for one cap call's settlement.
    call_timeout_ms: Int,
  )
}

// --- run ------------------------------------------------------------------

/// Runs a compiled artifact in a jailed satellite, servicing its
/// capability calls through `broker` under the run phase's identity, and
/// returns the program's structured `Outcome` together with what the
/// kernel enforced on the node.
///
/// Mints and delivers the cap-channel token, launches the node, owns the
/// broker end of the cap channel, enforces the wall deadline, and destroys
/// the node and unlinks the token file on every exit path the host itself
/// takes — including a launch that outran the deadline, whose connection is
/// destroyed by `hand_over` when the host has already stopped. What is not
/// covered is a host actor killed from outside: cleanup runs inside that
/// actor, so a monitor-based janitor mirroring the broker's fd-3 safety net
/// is still owed (M4 triage CH-F3(b)).
pub fn run(
  artifact: Artifact,
  phase: PhaseIdentity,
  broker: Broker,
  config: SatelliteConfig,
  launch: Launcher,
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
    Error(mint_error) ->
      never_launched(TokenMintFailed(mint_error_text(mint_error)))
    Ok(#(vault, minted)) ->
      case config.write_token_file(token.to_bytes(minted)) {
        Error(reason) -> never_launched(TokenFileFailed(reason))
        Ok(token_path) ->
          run_launched(
            artifact,
            phase,
            broker,
            config,
            launch,
            vault,
            token_path,
          )
      }
  }
}

// A run that never got a node: the failure, and a node report that says
// outright that nothing was launched rather than leaving a silence.
fn never_launched(error: RunError) -> Run {
  Run(
    outcome: Error(error),
    node: enforcement.Unreported("no node was launched"),
  )
}

fn run_launched(
  artifact: Artifact,
  phase: PhaseIdentity,
  broker: Broker,
  config: SatelliteConfig,
  launch: Launcher,
  vault: token.Vault,
  token_path: String,
) -> Run {
  let #(now, _clock) = clock.read(config.clock)
  let result_subject = process.new_subject()
  case start_host(phase, broker, config, vault, token_path, result_subject) {
    Error(start_error) -> {
      config.unlink_token_file(token_path)
      never_launched(HostUnavailable(start_error_text(start_error)))
    }
    Ok(host) ->
      dispatch_launch(
        artifact,
        phase,
        token_path,
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
  token_path: String,
  config: SatelliteConfig,
  launch: Launcher,
  host: Host,
  now: Int,
  result_subject: Subject(Run),
) -> Run {
  let spec =
    LaunchSpec(
      artifact:,
      token_path:,
      cap_socket_path: config.cap_socket_path,
      identity: phase,
      base_policy: config.base_policy,
      env: config.env,
      cwd: config.cwd,
      wire: host.wire,
    )
  case launch(spec) {
    Error(reason) -> {
      process.send(host.commands, Stop)
      never_launched(LaunchRejected(reason))
    }
    Ok(connection) -> await_result(phase, host, connection, now, result_subject)
  }
}

// Waits for the host's terminal result, bounded by the wall deadline plus
// slack for the host's own teardown (`result_margin_ms`). The node's
// enforcement report comes from whichever side actually ran `destroy`:
// the host, ordinarily, or `hand_over` here when the host was already
// gone before it could take the connection (CH-F3).
fn await_result(
  phase: PhaseIdentity,
  host: Host,
  connection: CapConnection,
  now: Int,
  result_subject: Subject(Run),
) -> Run {
  let handed = hand_over(host, connection)
  let deadline_ms = identity.pooled_budget(phase).deadline_ms
  let wait = int.max(deadline_ms - now, 0) + result_margin_ms
  case process.receive(result_subject, wait) {
    // The host took the connection and destroyed it itself, so its
    // report is the authoritative one — unless the host was gone before
    // it could take it, in which case `hand_over` destroyed the node
    // here and holds the only report there is.
    Ok(settled) ->
      case handed {
        None -> settled
        Some(node) -> Run(..settled, node:)
      }
    Error(Nil) -> {
      process.send(host.commands, Stop)
      // The host owns `destroy`, and with it the node's report; a host
      // that never answered never handed one back.
      Run(
        outcome: Error(HostUnavailable("no terminal result within the deadline")),
        node: enforcement.Unreported(
          "the host produced no terminal result, so the node's report was "
          <> "never collected",
        ),
      )
    }
  }
}

// Whether the host took ownership of the connection before it stopped.
type HandOver {
  HostTook
  HostGone
}

// Hands the launched node's connection to the host, and destroys it here if
// the host stopped before it could take it — in which case the node's
// enforcement report comes back here, since the host is not around to
// carry it.
//
// `Connected` carries the node's `destroy`, the host's only handle on the
// launched node and its socket. A message to a stopped actor is dropped, so
// a bare send would leak the node whenever the host settled during the
// launch. Monitoring the host closes the race: the acknowledgement and the
// host's death are ordered signals from the same process, so exactly one of
// them arrives first, and a death that beats the acknowledgement means the
// host never took the connection (CH-F3).
fn hand_over(host: Host, connection: CapConnection) -> Option(Report) {
  let ack = process.new_subject()
  let monitor = process.monitor(host.pid)
  let outcome =
    process.new_selector()
    |> process.select_map(ack, fn(_nil) { HostTook })
    |> process.select_specific_monitor(monitor, fn(_down) { HostGone })
  process.send(
    host.commands,
    Connected(send: connection.send, destroy: connection.destroy, ack:),
  )
  let handed = case process.selector_receive(outcome, hand_over_timeout_ms) {
    // The host is gone, so it will never destroy the node — nor report
    // what confined it. Both fall to the caller here.
    Ok(HostGone) -> Some(connection.destroy())
    // Taken, or the host is alive but wedged; either way it owns `destroy`
    // and destroying here as well would reap the node twice.
    Ok(HostTook) | Error(Nil) -> None
  }
  process.demonitor_process(monitor)
  handed
}

// --- the host actor -------------------------------------------------------

// The started host: `commands` for internal messages, `wire` for the
// launcher's inbound bytes, and the actor's pid, which `run_launched`
// monitors so a host that stopped before taking the connection does not
// leave the node unreaped.
type Host {
  Host(pid: Pid, commands: Subject(Msg), wire: Subject(WireIn))
}

/// The host actor's message set. Opaque: only this module constructs it,
/// so nothing outside can inject a forged capability settlement.
pub opaque type Msg {
  FromWire(event: WireIn)
  Connected(
    send: fn(BitArray) -> Nil,
    destroy: fn() -> Report,
    ack: Subject(Nil),
  )
  CapStarted(id: Int, handle: broker.CallHandle)
  CapDone(id: Int, outcome: CapOutcome)
  Deadline
  Stop
}

// One in-flight routed capability call.
type InFlight {
  InFlight(handle: Option(broker.CallHandle), cancelled: Bool)
}

type State {
  State(
    broker: Broker,
    // The run phase, threaded whole: every clearance the host makes takes
    // its `{op_id, step_id}` and its budget from here, so the host cannot
    // drift onto a second ledger part-way through an execution.
    identity: PhaseIdentity,
    base_policy: SandboxPolicy,
    demand: EnforcementDemand,
    env: List(#(String, String)),
    cwd: String,
    router: CapRouter,
    // The lifetime admission ceilings this execution runs under, and the
    // tally they are checked against. Both live here rather than in the
    // router because the host is the one thing there is exactly one of
    // per execution — see `CapCeiling`.
    ceilings: List(CapCeiling),
    admitted: Dict(String, Int),
    clock: Clock,
    call_timeout_ms: Int,
    vault: token.Vault,
    token_path: String,
    unlink_token_file: fn(String) -> Nil,
    commands: Subject(Msg),
    // Raw carry for the host's own length-prefix deframer over the cap
    // socket. The host owns frame boundaries so it can extract the
    // `outcome` frame's body, which `broker/framing` discards.
    buffer: BitArray,
    // The outbound writer, once the launcher has connected. Frames emitted
    // before then buffer in `pending_out` and flush on `Connected`.
    send: Option(fn(BitArray) -> Nil),
    destroy: Option(fn() -> Report),
    pending_out: List(BitArray),
    inflight: Dict(Int, InFlight),
    result: Subject(Run),
  )
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
  config: SatelliteConfig,
  vault: token.Vault,
  token_path: String,
  result_subject: Subject(Run),
) -> Result(Host, actor.StartError) {
  let #(_now, clock) = clock.read(config.clock)
  actor.new_with_initialiser(host_init_timeout_ms, fn(commands) {
    let wire = process.new_subject()
    let selector =
      process.new_selector()
      |> process.select(commands)
      |> process.select_map(wire, FromWire)
    // The wall deadline is armed on `Connected`, not here: a launch that
    // outlasted a deadline armed up front stopped the host before the
    // connection arrived, and the `destroy` it carried — the host's only
    // handle on the node and its socket — was dropped (CH-F3).
    let state =
      State(
        broker:,
        identity: phase,
        base_policy: config.base_policy,
        demand: config.demand,
        env: config.env,
        cwd: config.cwd,
        router: config.router,
        ceilings: config.ceilings,
        admitted: dict.new(),
        clock:,
        call_timeout_ms: config.call_timeout_ms,
        vault:,
        token_path:,
        unlink_token_file: config.unlink_token_file,
        commands:,
        buffer: <<>>,
        send: None,
        destroy: None,
        pending_out: [],
        inflight: dict.new(),
        result: result_subject,
      )
    actor.initialised(state)
    |> actor.selecting(selector)
    |> actor.returning(#(commands, wire))
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) {
    let #(commands, wire) = started.data
    Host(pid: started.pid, commands:, wire:)
  })
}

fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Connected(send:, destroy:, ack:) ->
      handle_connected(state, send, destroy, ack)
    FromWire(WireBytes(data:)) -> handle_bytes(state, data)
    FromWire(WireClosed(reason:)) ->
      terminate(state, Error(SatelliteGone(reason)))
    CapStarted(id:, handle:) -> handle_cap_started(state, id, handle)
    CapDone(id:, outcome:) -> handle_cap_done(state, id, outcome)
    Deadline -> terminate(state, Error(DeadlineExceeded))
    Stop -> {
      let _node = cleanup(state)
      actor.stop()
    }
  }
}

fn handle_connected(
  state: State,
  send: fn(BitArray) -> Nil,
  destroy: fn() -> Report,
  ack: Subject(Nil),
) -> actor.Next(State, Msg) {
  // Flush anything buffered before the launcher connected.
  list.each(list.reverse(state.pending_out), send)
  // The node exists from here, so the wall deadline starts here: after it,
  // the node dies as a unit (`broker.abort` plus `destroy`).
  let #(now, clock) = clock.read(state.clock)
  let delay = int.max(pooled(state).deadline_ms - now, 0)
  let _ = process.send_after(state.commands, delay, Deadline)
  // The host now owns `destroy`. Telling `run_launched` so is what lets it
  // distinguish this from a host that stopped first (CH-F3).
  process.send(ack, Nil)
  actor.continue(
    State(
      ..state,
      clock:,
      send: Some(send),
      destroy: Some(destroy),
      pending_out: [],
    ),
  )
}

fn handle_cap_started(
  state: State,
  id: Int,
  handle: broker.CallHandle,
) -> actor.Next(State, Msg) {
  case dict.get(state.inflight, id) {
    // Already settled and removed: nothing to track.
    Error(Nil) -> actor.continue(state)
    Ok(entry) -> {
      // A cancel that raced ahead of the clearance fires now.
      case entry.cancelled {
        True -> broker.cancel(state.broker, handle)
        False -> Nil
      }
      let inflight =
        dict.insert(state.inflight, id, InFlight(..entry, handle: Some(handle)))
      actor.continue(State(..state, inflight:))
    }
  }
}

fn handle_cap_done(
  state: State,
  id: Int,
  outcome: CapOutcome,
) -> actor.Next(State, Msg) {
  case dict.get(state.inflight, id) {
    Error(Nil) -> actor.continue(state)
    Ok(_) -> {
      let state = emit(state, id, outcome)
      actor.continue(State(..state, inflight: dict.delete(state.inflight, id)))
    }
  }
}

// The step a single inbound frame produces.
type FrameStep {
  FrameContinue(state: State)
  FrameDone(state: State, result: Result(Outcome, RunError))
}

fn handle_bytes(state: State, data: BitArray) -> actor.Next(State, Msg) {
  let buffer = bit_array.append(state.buffer, data)
  let Deframed(payloads:, buffer:, fault:) = deframe(buffer)
  let state = State(..state, buffer:)
  case handle_payloads(state, payloads) {
    Error(#(state, result)) -> terminate(state, result)
    Ok(state) ->
      case fault {
        None -> actor.continue(state)
        Some(reason) -> terminate(state, Error(ChannelFaulted(reason)))
      }
  }
}

// Folds the payloads of one chunk, short-circuiting on the terminal frame.
fn handle_payloads(
  state: State,
  payloads: List(BitArray),
) -> Result(State, #(State, Result(Outcome, RunError))) {
  case payloads {
    [] -> Ok(state)
    [payload, ..rest] ->
      case handle_payload(state, payload) {
        FrameContinue(state:) -> handle_payloads(state, rest)
        FrameDone(state:, result:) -> Error(#(state, result))
      }
  }
}

// Classifies one payload. `broker/framing` decodes every payload exactly
// once, so the host applies the same strict envelope rules — version, `id`,
// the exact key set — to the terminal `outcome` frame as to every broker
// frame (CH-F5), and the two decoders cannot disagree about what is
// well-formed (CH-F7). `framing` knows no `outcome` kind, so it validates
// that envelope and then reports the kind as unknown; only then does the
// host read the body out itself.
fn handle_payload(state: State, payload: BitArray) -> FrameStep {
  case framing.decode_payload(payload) {
    Ok(frame) -> handle_frame(state, frame)
    Error(framing.UnknownKind(id: _, kind:)) if kind == outcome_kind ->
      finish_from_payload(state, payload)
    // Any other unknown kind is ignored (forward compatibility); a
    // genuinely malformed frame closes the channel.
    Error(framing.UnknownKind(..)) -> FrameContinue(state)
    Error(_) -> FrameDone(state, Error(ChannelFaulted("malformed cap frame")))
  }
}

fn handle_frame(state: State, frame: framing.Frame) -> FrameStep {
  case frame.body {
    framing.CapCall(token:, cap:, args:, deadline_ms: _) ->
      handle_cap_call(state, frame.id, token, cap, args)
    framing.Cancel -> FrameContinue(handle_cancel(state, frame.id))
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
    Ok(_binding) -> FrameContinue(route_cap_call(state, id, cap, args))
  }
}

// The terminal outcome frame: its envelope is already validated, so read
// the body out and decode it into an `Outcome`.
fn finish_from_payload(state: State, payload: BitArray) -> FrameStep {
  case outcome_body(payload) {
    Error(reason) -> FrameDone(state, Error(ChannelFaulted(reason)))
    Ok(body) ->
      case decode_outcome(body) {
        Ok(outcome) -> FrameDone(state, Ok(outcome))
        Error(reason) -> FrameDone(state, Error(OutcomeMalformed(reason)))
      }
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
      emit(
        state,
        id,
        framing.CapErr(code: denial.code, message: denial.message),
      )
    Ok(plan) -> admit_cap_call(state, id, cap, plan)
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
fn admit_cap_call(state: State, id: Int, cap: String, plan: CapPlan) -> State {
  let already = admitted_count(state, cap)
  case ceiling_reached(state, cap, already) {
    Some(ceiling) -> emit(state, id, ceiling_denial(ceiling))
    None -> {
      let outstanding = pooled(state).max_outstanding
      case dict.size(state.inflight) >= outstanding {
        True -> emit(state, id, budget_denial(outstanding))
        False -> dispatch_cap_call(state, id, cap, already, plan)
      }
    }
  }
}

// Admitted for real: the tally moves, the call becomes cancellable, and a
// process of its own carries it.
fn dispatch_cap_call(
  state: State,
  id: Int,
  cap: String,
  already: Int,
  plan: CapPlan,
) -> State {
  let inflight =
    dict.insert(state.inflight, id, InFlight(handle: None, cancelled: False))
  let admitted = dict.insert(state.admitted, cap, already + 1)
  spawn_worker(state.commands, state.broker, plan, id, state.call_timeout_ms)
  State(..state, inflight:, admitted:)
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

// Services one admitted call off the actor's timeline. A jailed clearance
// goes through the broker and reports its handle back so a `Cancel` can
// reach it; a harness-served call has no handle, because there is no
// executor process group to revoke — it runs to its own end and its
// answer is emitted, which a program that cancelled has already stopped
// listening for.
fn spawn_worker(
  host: Subject(Msg),
  broker: Broker,
  plan: CapPlan,
  id: Int,
  call_timeout_ms: Int,
) -> Nil {
  process.spawn_unlinked(fn() {
    case plan {
      ClearedCall(spec:, render:) ->
        run_collector(host, broker, spec, render, id, call_timeout_ms)
      ServedHere(serve:) -> run_service(host, serve, id, call_timeout_ms)
    }
  })
  Nil
}

fn run_collector(
  host: Subject(Msg),
  broker: Broker,
  spec: CallSpec,
  render: fn(Collected) -> CapOutcome,
  id: Int,
  call_timeout_ms: Int,
) -> Nil {
  let events = process.new_subject()
  case broker.clear_call(broker, spec, events:, waiting: clear_timeout_ms) {
    Error(refusal) ->
      process.send(host, CapDone(id:, outcome: refusal_outcome(refusal)))
    Ok(handle) -> {
      process.send(host, CapStarted(id:, handle:))
      report_collected(host, id, render, events, call_timeout_ms)
    }
  }
}

fn report_collected(
  host: Subject(Msg),
  id: Int,
  render: fn(Collected) -> CapOutcome,
  events: Subject(broker.CallEvent),
  call_timeout_ms: Int,
) -> Nil {
  case tool.collect_events(events, waiting: call_timeout_ms) {
    Ok(collected) ->
      process.send(host, CapDone(id:, outcome: render(collected)))
    Error(Nil) -> process.send(host, CapDone(id:, outcome: unsettled_outcome()))
  }
}

// A harness-served call, run on a grandchild process this one monitors.
//
// The indirection buys totality. `serve` is an injected closure reaching
// a seam this module knows nothing about, so it may block for as long as
// that seam allows and it may die; either would leave the program waiting
// on a `cap_result` that never comes, until the wall deadline killed the
// node. Monitoring settles both cases in band — too slow is `unsettled`,
// dead is `cap_failed` naming the death — which is the same posture
// `report_collected` takes toward a clearance that never settles.
fn run_service(
  host: Subject(Msg),
  serve: fn() -> CapOutcome,
  id: Int,
  call_timeout_ms: Int,
) -> Nil {
  let answers = process.new_subject()
  let worker = process.spawn_unlinked(fn() { process.send(answers, serve()) })
  let monitor = process.monitor(worker)
  let settled =
    process.new_selector()
    |> process.select_map(answers, Ok)
    |> process.select_specific_monitor(monitor, fn(_down) { Error(Nil) })
  let outcome = case process.selector_receive(settled, call_timeout_ms) {
    Ok(Ok(answer)) -> answer
    Ok(Error(Nil)) -> served_died_outcome()
    Error(Nil) -> unsettled_outcome()
  }
  process.demonitor_process(monitor)
  process.send(host, CapDone(id:, outcome:))
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
    Ok(entry) -> {
      // Cancel the clearance now if it has one; otherwise mark it so the
      // pending `CapStarted` cancels on arrival.
      case entry.handle {
        Some(handle) -> broker.cancel(state.broker, handle)
        None -> Nil
      }
      State(
        ..state,
        inflight: dict.insert(
          state.inflight,
          id,
          InFlight(..entry, cancelled: True),
        ),
      )
    }
  }
}

// Destroys the satellite, then reports the terminal result — carrying
// what the node's teardown learned about its jail — and stops.
//
// The order is the fix for issue #5. Reporting first and cleaning up
// afterwards left the node's enforcement report chasing an outcome that
// had already been delivered, so a healthy run said nothing about the
// stage whose confinement matters most. Teardown now happens first and
// hands the report back, so the outcome cannot leave without it.
fn terminate(
  state: State,
  outcome_result: Result(Outcome, RunError),
) -> actor.Next(State, Msg) {
  let node = cleanup(state)
  process.send(state.result, Run(outcome: outcome_result, node:))
  actor.stop()
}

// Destroys the satellite as a unit and unlinks the token file, returning
// what the kernel enforced on the node. `abort` revokes every token of the
// operation and cancels every executor it fanned out; `destroy` closes the
// socket, reaps the node, and hands back its helper's report.
//
// `abort` comes first, exactly as before: the deadline path must not wait
// on anything before killing the node. What the launcher's `destroy` then
// waits for is the settlement the abort itself provokes — a cancelled
// execution still answers with `exec_exit`, and that report is the ground
// truth this whole path exists to carry.
fn cleanup(state: State) -> Report {
  broker.abort(state.broker, identity.op_id(state.identity))
  let node = case state.destroy {
    Some(destroy) -> destroy()
    None -> enforcement.Unreported("no node was launched")
  }
  state.unlink_token_file(state.token_path)
  node
}

// Encodes and writes one frame, buffering until the launcher connects.
fn send_frame(state: State, frame: framing.Frame) -> State {
  case framing.encode(frame) {
    // An unencodable cap_result would be a host bug (ids are positive,
    // bodies typed); drop it rather than crash — the deadline still bounds
    // the execution.
    Error(_) -> state
    Ok(bytes) ->
      case state.send {
        Some(send) -> {
          send(bytes)
          state
        }
        None -> State(..state, pending_out: [bytes, ..state.pending_out])
      }
  }
}

fn emit(state: State, id: Int, outcome: CapOutcome) -> State {
  send_frame(
    state,
    framing.Frame(id:, body: framing.CapResult(outcome:, usage: None)),
  )
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

// Reads the `body` out of an already-validated envelope, totally. The one
// place the host decodes a payload itself, and only for the single terminal
// `outcome` frame per execution, whose body `broker/framing` discards.
fn outcome_body(payload: BitArray) -> Result(MsgPackValue, String) {
  case msgpack.decode(payload) {
    Error(_) -> Error("a cap frame payload did not parse")
    Ok(value) -> map_field(value, "body")
  }
}

// --- the default cap router ----------------------------------------------

/// The default capability router.
///
/// It services the process-spawning capabilities that map cleanly onto a
/// jailed `broker.clear_call` — today `proc.run`, whose argv is the
/// command to run. The full cap→tool table the satellite ultimately serves
/// is:
///
/// | cap | maps to | via |
/// |---|---|---|
/// | `proc.run` | the jailed executor (bash-style argv) | `clear_call` |
/// | `git.*` / `lsp.*` | their CLIs as argv | `clear_call` |
/// | `fs.read`/`write`/`list`/`edit` | the harness-side `tools/fs` tools | direct (not a jailed exec) |
/// | `net.*` | the egress-proxied executor | `clear_call` (proxy pending) |
/// | `report.emit` / `kv.*` | harness-side stores | direct |
///
/// The rows beyond `proc.run` need the harness-side tool bridge that lands
/// with the fuller runtime; until then they are refused in-band, and
/// callers inject a fuller router. The result-shape of each `cap_result`
/// is the cap module's contract in `packages/cap`.
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

// Decodes the marshalled outcome (mirrors `cap/report`'s `to_msgpack`):
// `{ok: true, value}` or `{ok: false, message, details}`. Total: a
// malformed shape is a `String` fault, never a crash.
fn decode_outcome(value: MsgPackValue) -> Result(Outcome, String) {
  use ok <- result.try(map_bool(value, "ok"))
  case ok {
    True -> {
      use payload <- result.try(map_field(value, "value"))
      Ok(Completed(value: payload))
    }
    False -> {
      use message <- result.try(map_string(value, "message"))
      let details = case map_field(value, "details") {
        Ok(details) -> details
        Error(_) -> msgpack.NilValue
      }
      Ok(Errored(message:, details:))
    }
  }
}

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

fn map_bool(value: MsgPackValue, key: String) -> Result(Bool, String) {
  use found <- result.try(map_field(value, key))
  case found {
    msgpack.BoolValue(flag) -> Ok(flag)
    _ -> Error("field `" <> key <> "` is not a bool")
  }
}

fn map_string(value: MsgPackValue, key: String) -> Result(String, String) {
  use found <- result.try(map_field(value, key))
  case found {
    msgpack.StringValue(text) -> Ok(text)
    _ -> Error("field `" <> key <> "` is not a string")
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
    broker.InvalidPolicy(error: _) ->
      framing.CapErr(
        code: "invalid_policy",
        message: "the composed policy is invalid",
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
