//// The ExecPool: supervised lifecycle of `loom-exec` sandbox helpers.
////
//// Each helper is one OS process speaking the Part 1.4 framing protocol
//// on stdio, running **one execution at a time** (the helper answers a
//// second `exec_start` with a `busy` error); concurrency lives here, in
//// the pool, by running more helpers. A broker-side `Helper` machine
//// owns each helper's channel: it performs the hello handshake, deframes
//// inbound bytes with the pure `broker/framing` deframer, streams
//// output events to the caller, heartbeats the helper while idle, and
//// mirrors the cancel escalation (the helper TERMs the payload and then
//// KILLs its pgroup within 2s of `cancel`; if no `exec_exit` arrives
//// within the grace period the machine kills the whole helper — belt and
//// braces). The two rungs are addressed differently under a jail, and
//// what the exit reports differs with them: see `cancel` below.
////
//// ## A kill keeps its witness
////
//// Every failure that finds the port open ends in a SIGKILL of the helper
//// with the port *retained*, and the machine waits in `Dead` for the exit
//// status the kill produces (`PendingExit(AfterKill(..))`). Closing the
//// port first would discard that status, leave the proof lost, and cost the
//// pool a slot for good, although the jail died with its helper all the
//// same. Whether a status after a kill is proof is `native_verdict`'s
//// decision, and it depends on how much jail the helper had when it died
//// (`Exposure`): none, because it was still in its handshake; none left,
//// because it was idle and its last jail was already killed; or a live one.
//// Only a live jail needs bwrap's `--die-with-parent` and PID namespace to
//// make the helper's death the jail's, so only there do degraded Linux and
//// Darwin stay unconfirmed. A helper that dies unasked is judged the same
//// way, so the two cases cannot disagree.
////
//// A failed *write* is the one case that finds the port already closed, and
//// it is not a lost proof yet. A port opened with `exit_status` delivers
//// `{exit_status, S}` and only then closes, so a write that fails after the
//// helper died on its own finds that status already queued in the actor's
//// mailbox. `mark_gone` therefore waits as well, with the port closed and
//// nothing to kill (`PendingExit(Unprompted(..))`), and the same witness
//// timeout turns a status that never comes into `LostExit`.
////
//// ## A `Run` outlives the caller that timed out
////
//// `run` is a `try_call`, so a caller that gives up leaves its `Run` queued
//// in the actor's mailbox, and a recovered actor reads it. `handle_run`
//// refuses it, with `NotReady`, when `events_owner_alive` says nobody is
//// left to receive the events. That fences the broker's relay, which dies
//// with its call; it is a liveness check and not a deadline, so a caller
//// that is alive but stopped waiting must treat `HelperUnresponsive` as
//// "outcome unknown", never as "nothing started".
////
//// ## The helper's lifecycle is a `weft/state_machine`
////
//// `Prepared → AwaitingHello → Idle → Running → Cancelling → Idle`, with
//// `Dead` as the absorbing state every failure settles into. Those six are
//// the `Phase` type — the machine's *state* — and everything else the
//// process carries is its *data*. The split is what makes both of the
//// helper's deadlines structural rather than guarded by hand: the
//// handshake window is a **state timeout** on `AwaitingHello` and the
//// cancel grace is a **state timeout** on `Cancelling`, so each dies
//// with the state that armed it. No handler re-checks whether its own
//// timer is still relevant, no settle site remembers to cancel one, and
//// no timer message carries an execution id for the sole purpose of
//// recognising a stale fire. Reaching `Idle` or `Dead` *is* the
//// cancellation.
////
//// The idle heartbeat is the third, and it is a **periodic timeout**:
//// it must fire every N ms regardless of activity, which is what a
//// liveness probe means and what neither a state timeout (dies with its
//// state) nor an event timeout (measures quiet, so a chatty helper is
//// never probed) says. It is armed on the way out of `AwaitingHello`
//// and cancelled on the way into `Dead`, so the two arms that used to
//// absorb a tick arriving in a phase with nothing to probe are now
//// unreachable rather than merely unlikely.
////
//// ## Policy delivery (the fd-3 gap)
////
//// The helper requires its base `SandboxPolicyV1` on fd 3 at spawn, but
//// Erlang ports cannot map arbitrary file descriptors. Resolution: the
//// policy is written to a mode-0600 file inside a mode-0700 directory,
//// and the helper is spawned through `/bin/sh -c 'exec 3<"$2" "$1"'`
//// so the shell opens the file as fd 3 before exec-ing the helper. The
//// file is unlinked as soon as the helper's hello arrives (proof the
//// policy was read). Recorded in `docs/spec-gaps.md` territory: the
//// per-exec `exec_start.policy` override remains the authoritative
//// policy for each execution; the fd-3 file only seeds the helper.
////
//// Unlinking is guaranteed on every reachable path: in-actor (hello,
//// channel death, `Shutdown`, which covers pool retirement),
//// `spawn_helper`'s own failure branches (unopenable port, actor start
//// failure, handshake failure), and — for deaths the actor never sees,
//// like a supervisor's brutal kill — a janitor process spawned by
//// `spawn_helper` that monitors the helper actor and deletes the file
//// when it goes down, however it went down (`watch_cleanup`; deletion
//// is idempotent, so overlapping with the in-actor unlink is
//// harmless). The one genuinely uncoverable path is the whole VM dying
//// uncleanly (SIGKILL, kernel panic): no process survives to unlink,
//// and the file leaks until the OS or the operator clears `tmp_dir` —
//// a disk-space leak only, never a disclosure, since the file sits in
//// a mode-0700 directory.
////
//// ## Transports
////
//// The channel is a seam: `PortTransport` is the real OS helper;
//// `ChannelTransport` lets tests drive the same machine with an
//// in-process fake speaking the same bytes. Helper failure of any kind
//// settles in-band as an `ExecFailure` event — never a crash of the
//// caller.
////
//// ## Flow
////
//// `spawn_helper` → `prepare` → `begin` → `handle` → `activate` →
//// `handle_bytes` → `handle_run` → `dispatch_exec` → `handle_exec_exit`
////
//// 1. `spawn_helper` builds the transport and the helper's owner with
////    `prepare_helper`, releases it with `begin`, and waits in `await_ready`
////    for the hello to settle; `start_pool` and `checkout` lend those helpers.
//// 2. `handle` is the machine's one step function: it matches the `Phase`
////    against the `Msg`, so every pairing is written out.
//// 3. `activate` opens the transport on `Begin` and moves `Prepared` to
////    `AwaitingHello`, whose `entered` call arms the handshake deadline.
//// 4. `handle_bytes` deframes inbound bytes, and `apply_inbound` gives each
////    frame to `handle_frame`; `handle_hello` and `complete_handshake` move the
////    machine to `Idle`.
//// 5. `handle_run` weighs the hello's features against the request's demand,
////    and `dispatch_exec` records the execution in the `Running` state and
////    writes the exec_start frame.
//// 6. `handle_exec_exit` checks the enforcement report, and `settle` returns
////    the machine to `Idle`; `mark_dead` and `die` are where every failure
////    lands, notifying waiters through `notify_death` and killing the helper
////    with `kill_transport`.
//// 7. `native_exit` receives the status the port reports, and `native_verdict`
////    decides whether it retires the helper.
////
//// Credited execution follows `run_protocol` → `handle_protocol_run` →
//// `protocol_input_ack` / `protocol_output` → `protocol_terminal` →
//// `protocol_reusable` → `consume_protocol_reusable`. `Finishing` keeps the
//// original borrow busy until the final consumer retains and consumes the
//// exact witness. `defer_checkin` owns one immutable original return closure.
////
//// ## Transitions
////
//// <!-- transitions: exec.Phase -->
////
//// | state | `Begin` | hello frame | `Run` | `CancelExec` | exit or error frame | deadline | `Shutdown` | wire closed or fault |
//// | --- | --- | --- | --- | --- | --- | --- | --- | --- |
//// | `Prepared` | `AwaitingHello`, or `Dead` if the transport will not open | ignored | refused, `NotReady` | ignored | ignored | ignored | `Dead`, no native resource | ignored |
//// | `AwaitingHello` | ignored | `Idle`; `Dead` on a protocol version mismatch | refused, `NotReady` | ignored | ignored | `HandshakeDeadline` gives `Dead` | postponed until the handshake settles | `Dead` |
//// | `Idle` | ignored | `Dead`, protocol violation | `Running`; refused if the helper is degraded or the caller's events owner is gone | ignored | ignored | stale, ignored | `Dead` | `Dead`; a missed heartbeat also gives `Dead` |
//// | `Running` | ignored | `Dead`, protocol violation | refused, `HelperBusy` | `Cancelling` after the TERM write, `Dead` if the write fails | the execution's own id gives `Idle`; other ids dropped | stale, ignored | `Dead`, in-flight caller told | `Dead`, in-flight caller told |
//// | `Cancelling` | ignored | `Dead`, protocol violation | refused, `HelperBusy` | ignored, the first deadline keeps running | the execution's own id gives `Idle` and disarms the deadline | `CancelDeadline` kills the helper and keeps its port, `Dead` | `Dead`, in-flight caller told | `Dead`, in-flight caller told |
//// | `Finishing` | ignored | `Dead`, protocol violation | refused, `HelperBusy` | ignored | terminal retained; only matching consumed finite reusable enters `Idle` | none | `Dead`, original retirement | `Dead` |
//// | `Dead` | ignored | dropped | refused with the stored failure | ignored | dropped | stale, ignored; `KillWitnessDeadline` on a killed helper, or one whose write failed, whose status never came closes the port and gives `LostExit` | ignored | the exit status of a retained port is the retirement proof; after a closed port it is ignored |

import broker/framing.{type Fault, type Frame, type OutputStream}
import broker/internal/call
import broker/internal/ffi_crypto
import broker/internal/ffi_os
import broker/internal/ffi_port
import broker/policy.{type SandboxPolicy}
import core/clock
import core/msgpack
import envoy
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/erlang/port.{type Port}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/pair
import gleam/result
import gleam/string
import weft/poll
import weft/state_machine

/// How strictly the caller demands kernel enforcement for an execution.
pub type EnforcementDemand {
  /// Refuse degraded helpers before dispatch and refuse results whose
  /// `exec_exit` reports degraded enforcement — the ground-truth check
  /// the contract requires beyond hello features. Ground truth is the
  /// structured `enforcement` list, not just the `degraded` bool (which
  /// tracks only the bwrap layer): any `skip:` entry means a layer the
  /// policy called for was not applied, and the result is refused even
  /// when the bool stayed false.
  FullEnforcement

  /// Require every kernel boundary the selected platform promises, and
  /// refuse degraded helpers, missing mandatory layers, silent reports,
  /// and unexpected skips. On Darwin only, the three gaps ADR-006 proves
  /// the platform cannot close are accepted when they are reported
  /// explicitly: address-space rlimits, account-wide process rlimits,
  /// and descendant lifecycle containment. This is the production
  /// default: usable on macOS without turning a missing Seatbelt layer
  /// into an accepted best-effort execution.
  PlatformEnforcement

  /// Accept whatever the helper could enforce (development containers,
  /// self-tests). The enforcement report still reaches the caller.
  BestEffort
}

/// One execution request.
pub type ExecRequest {
  ExecRequest(
    /// The program and arguments. Invariant: non-empty.
    argv: List(String),
    /// The child environment (allowlist-constructed by the caller).
    env: List(#(String, String)),
    /// Working directory inside the jail.
    cwd: String,
    /// Per-exec policy override; `None` runs under the helper's fd-3
    /// base policy.
    policy: Option(SandboxPolicy),
    /// The capability token bytes clearing this execution.
    token: BitArray,
    /// Enforcement strictness for this execution.
    demand: EnforcementDemand,
  )
}

/// A completed execution, mirroring the helper's `exec_exit` report.
/// `enforcement` is ground truth for what was actually applied.
pub type ExecResult {
  ExecResult(
    code: Int,
    /// The signal that killed the process the helper waited on, or `0`.
    ///
    /// Under a jail that process is the bwrap supervisor, not the
    /// payload, and it relays a signalled payload by exiting 128+signal
    /// rather than dying of it — so a jailed exec reports `signal: 0`
    /// even when the payload was signalled. Read `code` for the
    /// cross-environment answer; see `cancel`.
    signal: Int,
    stdout_bytes: Int,
    stderr_bytes: Int,
    stdout_truncated: Bool,
    stderr_truncated: Bool,
    enforcement: List(String),
    degraded: Bool,
    wall_ms: Int,
    timed_out: Bool,
    /// The helper stopped this execution rather than the execution
    /// ending of its own accord — the broker's `cancel`, or the policy's
    /// wall-clock deadline, which climbs the same ladder (`timed_out`
    /// separates the two causes).
    ///
    /// Nothing else in this record can say it. A cancelled run whose
    /// payload had backgrounded its work reports `code: 0, signal: 0` —
    /// a clean success for an execution that was truncated — and
    /// `code: 143` is produced by `sh -c 'exit 143'` with no cancel at
    /// all, so it is a byte three different causes share rather than
    /// evidence of a TERM. Only the helper knows, and this is where it
    /// says so (protocol-change/006).
    cancelled: Bool,
  )
}

/// Events streamed to the subject a caller passes to `run`. Exactly one
/// terminal event (`Exited` or `Failed`) arrives per accepted `run`.
pub type ExecEvent {
  /// One chunk of child output; `total_bytes` is cumulative per stream.
  Output(
    stream: OutputStream,
    data: BitArray,
    total_bytes: Int,
    truncated: Bool,
  )

  /// The execution completed and passed the enforcement check.
  Exited(result: ExecResult)

  /// The execution settled as an in-band failure.
  Failed(failure: ExecFailure)
}

/// Every way an execution or helper interaction settles as a failure.
/// Always a value, never a crash.
pub type ExecFailure {
  /// The helper has not completed its handshake (or is dead).
  NotReady

  /// The handshake did not complete within the configured timeout.
  HandshakeTimeout

  /// This helper is already running an execution.
  HelperBusy

  /// The helper's hello reports degraded enforcement and the request
  /// demanded `FullEnforcement`.
  DegradedHelper(features: List(String))

  /// The execution ran but its `exec_exit` reports degraded enforcement
  /// against a `FullEnforcement` demand — the `degraded` bool was set,
  /// or the `enforcement` list carries a `skip:` entry for a layer that
  /// was not applied. The result is attached but must not be trusted as
  /// jailed.
  DegradedExecution(result: ExecResult)

  /// The helper answered the dispatch with a protocol error frame
  /// (busy, bad_policy, spawn_failed, malformed...).
  RefusedByHelper(code: String, message: String)

  /// The inbound byte stream broke the framing protocol; the channel
  /// was closed (spec §3.3 invariant 6).
  ChannelFault(fault: Fault)

  /// The helper process exited with this OS status.
  ChannelClosed(status: Int)

  /// The helper sent a frame kind that never flows helper-to-broker;
  /// the channel was closed.
  ProtocolViolation(kind: String)

  /// The helper's `hello` announced a different exec-protocol version
  /// than this build speaks, so the two cannot agree on what a frame
  /// body means. `helper` is what it said and `broker` is
  /// `framing.exec_protocol_version`; the smaller of the two names the
  /// side that is behind, which is the difference between "rebuild the
  /// helper" and "rebuild the harness".
  ///
  /// Distinct from `ProtocolViolation` because nothing was violated: the
  /// peer spoke its protocol correctly and it is the wrong one. That
  /// distinction is the whole of issue #61, where a helper predating
  /// `protocol-change/006` surfaced as an anonymous decode failure on a
  /// later frame instead of as a version disagreement at the handshake.
  ProtocolVersionMismatch(helper: Int, broker: Int)

  /// Writing to the helper's stdin failed (helper died mid-frame).
  SendFailed

  /// A cancel was not answered by `exec_exit` within the grace period;
  /// the helper was killed outright.
  CancelEscalated

  /// The idle heartbeat went unanswered; the helper was declared dead.
  HeartbeatMissed

  /// The helper *actor* did not answer within the caller's window, or
  /// was not alive to be asked. Distinct from every failure above,
  /// which are things the actor told us: this is the actor itself out
  /// of reach, so nothing is known about the helper process behind it.
  ///
  /// It does **not** say that no execution was dispatched. A `run` that
  /// timed out leaves its request queued in the actor's mailbox, and an
  /// actor that recovers will read it. What stops that late dispatch is
  /// the fence in `handle_run`: a request whose events subject has no
  /// living owner is refused. So the honest reading is that the execution
  /// *may* start after the caller was told it failed, if the caller is
  /// still alive to be sent its events, and the caller must treat the
  /// outcome as unknown rather than as "never ran".
  HelperUnresponsive

  /// The execution may have started and its outcome is unknown: the
  /// machinery that would have reported it was lost, so no exit status,
  /// no output total and no enforcement report exist to settle with.
  ///
  /// This is the one failure that says "something may have run". It must
  /// never be read as "nothing ran" and it must never be replayed
  /// automatically, because a replay of an effect that did happen twice
  /// is worse than an error the caller can see. `cause` names which piece
  /// of machinery was lost, for the human reading the verdict.
  ExecutionLost(cause: LossCause)
}

/// Which piece of machinery an `ExecutionLost` execution lost. These causes
/// are different facts about the world and a reader debugging a stuck
/// session needs to tell them apart, although none of them changes what
/// the caller may do next.
pub type LossCause {
  /// The helper's BEAM actor died while the execution was in flight. The
  /// jail itself does not outlive it: the port closes with the dead owner,
  /// the helper reads end of file, and it cancels and joins its jail. What
  /// is lost is the report, not the cleanup.
  HelperActorDown

  /// The process that relayed the execution's events to the caller died
  /// before it could report a terminal event, so the executor service
  /// settled the caller on its behalf and cancelled the helper.
  RelayDown

  /// The executor service closed with the execution still live and settled
  /// it rather than leave its caller waiting for ever.
  ExecutorClosing

  /// The authenticated remote exchange lost definitive outcome evidence.
  /// The original durable request remains under reconciliation; neither native
  /// retirement nor permission to submit a replacement follows from this event.
  RemoteOutcomeUncertain
}

/// A helper's observable lifecycle position.
pub type HelperStatus {
  /// Handshake still in flight.
  StatusStarting

  /// Handshake done and no execution in flight; these are the helper's
  /// hello features. The only answer that makes a helper fit to lend.
  StatusReady(features: List(String))

  /// Handshake done and an execution is in flight (`Running` or
  /// `Cancelling`); these are the helper's hello features. The helper
  /// is alive and well but occupied, so it is not fit to lend: a
  /// borrower's `run` would be refused in-band with `HelperBusy` for a
  /// call that was never theirs.
  StatusBusy(features: List(String))

  /// The channel is gone; the actor answers every request with this
  /// failure until shut down.
  StatusDead(failure: ExecFailure)

  /// The actor did not answer the question, or was not alive to be
  /// asked. Not a position the helper reported — the absence of one.
  StatusUnresponsive
}

/// How to reach one helper process. A seam: production uses
/// `PortTransport`; tests drive the same actor through
/// `ChannelTransport` with an in-process fake.
///
/// The port itself is opened *inside* the helper actor (ports deliver
/// their messages to the process that opened them), which is why this
/// is a spawn spec rather than an open port.
pub type Transport {
  /// A real OS helper: `executable` is spawned with `args` as an
  /// Erlang port owned by the actor. `cleanup` is called once the
  /// handshake proves the fd-3 policy file was read (and again on
  /// death — it must be idempotent).
  PortTransport(executable: String, args: List(String), cleanup: fn() -> Nil)

  /// An in-process peer: outbound bytes go to `send`; inbound bytes
  /// arrive on the helper's wire subject (see `wire`).
  ChannelTransport(send: fn(BitArray) -> Nil, close: fn() -> Nil)

  /// Acquires a native transport only after its BEAM owner is published.
  /// The factory must clean up any partial acquisition before returning Error.
  DeferredTransport(acquire: fn() -> Result(Transport, String))
}

// The resolved runtime channel held in actor state.
type Wire {
  WireUnopened
  WirePort(port: Port, os_pid: Option(Int), cleanup: fn() -> Nil)
  WireChannel(send: fn(BitArray) -> Nil, close: fn() -> Nil)
}

/// Configuration for one helper actor.
pub type HelperConfig {
  HelperConfig(
    /// The channel to the helper process.
    transport: Transport,
    /// How long the hello exchange may take before the helper is
    /// declared dead.
    handshake_timeout_ms: Int,
    /// How long after `cancel` to wait for `exec_exit` before killing
    /// the helper outright. The helper's own TERM-to-KILL ladder is 2s;
    /// this must exceed it.
    ///
    /// The helper's 2s is a real grace jailed as well as unjailed — a
    /// payload with `SIG_IGN` on TERM outlives it and is ended by the
    /// KILL rung. See `cancel` for who each rung is addressed to.
    cancel_grace_ms: Int,
    /// How long a deliberately killed helper may take to report the exit
    /// status its kill produced before the broker stops waiting and
    /// records the proof as lost. See `kill_witness_ms` for why the
    /// default is generous and why expiry can only lose a proof.
    kill_witness_ms: Int,
    /// Idle liveness probe interval; `0` disables.
    heartbeat_interval_ms: Int,
  )
}

/// Bytes arriving from the helper (used directly by fake transports;
/// the port transport produces these internally).
pub type WireEvent {
  /// Raw protocol bytes from the helper's stdout.
  WireBytes(data: BitArray)

  /// The helper process is gone, with this exit status.
  WireClosed(status: Int)
}

/// A handle to one broker-side helper actor.
pub opaque type Helper {
  /// Invariant: `commands` and `wire` are subjects of the same actor
  /// process `pid`.
  Helper(
    commands: Subject(Msg),
    wire: Subject(WireEvent),
    pid: Pid,
    handshake_wait: Int,
  )
}

/// One original credited execution. Its helper and id cannot be replaced by a peer.
pub opaque type ProtocolExecution {
  ProtocolExecution(helper: Helper, id: Int)
}

/// The outcome of submission, preserving an original handle when a reply was lost.
pub type ProtocolRunFailure {
  /// A definite refusal or failed reservation; no replacement is implied.
  ProtocolRunRefused(failure: ExecFailure)

  /// Original submission may have started. Cleanup keeps this exact handle.
  ProtocolRunUnknown(execution: ProtocolExecution, failure: ExecFailure)
}

/// Credited events have their own consumed transport and never enter ExecEvent.
pub type ProtocolEvent {
  /// Exact stdin queue admission, distinct from delivery to the child.
  ProtocolInputAccepted(ordinal: Int, frame_id: Int)

  /// Definite rejection of one original input frame.
  ProtocolInputRefused(
    ordinal: Int,
    frame_id: Int,
    reason: framing.InputRefusal,
  )

  /// One output offer; consumption must name this original ordinal.
  ProtocolOutput(
    ordinal: Int,
    stream: OutputStream,
    data: BitArray,
    total_bytes: Int,
    disposition: framing.OutputDisposition,
  )

  /// Native verdict and protocol disposition; neither is reusable evidence.
  ProtocolTerminal(
    result: Result(ExecResult, ExecFailure),
    disposition: framing.ProtocolDisposition,
  )

  /// Delivered post-join witness. Retain its original command association before consuming it.
  ProtocolReusable

  /// Transport or identity failed; custody remains unavailable.
  ProtocolFailure(failure: ExecFailure)
}

type EventSink {
  OrdinaryEvents(events: Subject(ExecEvent))
  CreditedEvents(events: Subject(ProtocolEvent))
}

type InputCredit {
  InputAvailable(next: Int)
  InputOffered(ordinal: Int, frame_id: Int, end: framing.InputEnd)
  InputEnded
}

type ReuseCredit {
  ReuseAwaited
  ReuseOffered
  ReuseConsumed
}

type ProtocolRun {
  ProtocolRun(
    id: Int,
    mode: framing.ProtocolMode,
    events: Subject(ProtocolEvent),
    input: InputCredit,
    next_output: Int,
    offered_output: Option(Int),
    consumed_output: Int,
    stdout_bytes: Int,
    stderr_bytes: Int,
    reuse: ReuseCredit,
    deferred: Option(fn() -> Nil),
  )
}

// Existing local callers use the relay's aggregate cancellation deadline. A
// remote admission additionally fences the queued Run at its final BEAM reader.
type RunWindow {
  RelayOwned
  NativeBefore(clock: clock.Clock, deadline_ms: Int)
}

/// The helper machine's message type: every event it dispatches on,
/// whether it came from a caller, from the wire, or from one of the two
/// state timeouts. Opaque; constructed only through this module's API.
pub opaque type Msg {
  Begin
  ReserveProtocol(reply: Subject(Result(Int, ExecFailure)))
  RunProtocol(
    id: Int,
    request: ExecRequest,
    mode: framing.ProtocolMode,
    clock: clock.Clock,
    deadline: Int,
    events: Subject(ProtocolEvent),
    reply: Subject(Result(Int, ExecFailure)),
  )
  FeedProtocol(
    id: Int,
    ordinal: Int,
    frame_id: Int,
    data: BitArray,
    end: framing.InputEnd,
    reply: Subject(Result(Nil, ExecFailure)),
  )
  ConsumeProtocolOutput(id: Int, ordinal: Int)
  ConsumeProtocolReusable(id: Int)
  DeferProtocolCheckin(
    id: Int,
    checkin: fn() -> Nil,
    reply: Subject(Result(Nil, ExecFailure)),
  )
  CancelProtocol(id: Int)
  AwaitReady(reply: Subject(Result(List(String), ExecFailure)))
  QueryStatus(reply: Subject(HelperStatus))
  Run(
    request: ExecRequest,
    window: RunWindow,
    events: Subject(ExecEvent),
    reply: Subject(Result(Nil, ExecFailure)),
  )
  Stdin(data: BitArray, eof: Bool)
  CancelExec

  /// The cancel grace expired. Carries no execution id, because the
  /// state timeout on `Cancelling` that delivers it dies with that
  /// state — and leaving `Cancelling` is the only way the execution it
  /// speaks for can settle.
  CancelDeadline

  /// The handshake window expired. A state timeout on `AwaitingHello`,
  /// so reaching `Idle` or `Dead` cancels it.
  HandshakeDeadline

  /// The killed helper's exit status did not arrive within
  /// `kill_witness_ms`. A state timeout on `Dead(PendingExit(AfterKill(..)))`,
  /// so the status arriving, which moves the machine to `NativeExit`,
  /// cancels it.
  KillWitnessDeadline

  /// The idle liveness probe came round. Carries no execution id and no
  /// generation stamp: it is a periodic timeout armed under one name, so
  /// weft's timer book drops a tick that raced its own cancellation and
  /// nothing here has to recognise a stale one.
  HeartbeatTick

  Heartbeat(reply: Subject(Result(Nil, ExecFailure)))
  Shutdown
  AwaitRetirement(reply: fn(Result(Nil, RetirementFailure)) -> Nil)
  ForgetRetired
  FromWire(event: WireEvent)
}

/// Why orderly native retirement could not be established.
pub type RetirementFailure {
  /// The caller's deadline expired; custody and the port remain live.
  RetirementPending

  /// The BEAM owner disappeared before reporting native exit.
  RetirementOwnerGone

  /// The channel was discarded before its native exit could be observed.
  RetirementProofLost

  /// Native exit was observed, but its status does not attest clean join.
  RetirementExit(status: Int)
}

// Native evidence belongs to the terminal state, not the actor's liveness.
// Changing PendingExit to a verdict replays postponed retirement requests.
//
// These four are protocol-014's whole evidence model, and only the third
// of them is evidence at all.
type Retirement {
  /// No OS process was ever acquired, so there is nothing to witness and
  /// the actor may retire on its own. A parked helper that never reached
  /// `begin` ends here.
  NoNativeResource

  /// The helper has been told to go, by a shutdown frame or by SIGKILL, or a
  /// write to it failed, and the port is deliberately still open or its
  /// status is still queued. This is the state a caller's timeout answers
  /// `RetirementPending` from, and the only one a later exit event can still
  /// improve. `awaiting` is why the exit is awaited,
  /// which is what decides what the status will prove.
  PendingExit(awaiting: Awaiting)

  /// The port reported the child's exit status while it was retained.
  /// `awaited` is carried over from the `PendingExit` it answers, so the
  /// verdict can tell a helper that retired itself from one that was
  /// killed; an exit nobody asked for is recorded as `Unprompted`.
  /// `native_verdict` is where the status becomes a verdict, and why.
  NativeExit(status: Int, awaited: Awaiting)

  /// The channel was discarded before any exit status could be selected:
  /// the port was closed, or its pid could not be signalled, or the witness
  /// timeout expired on a helper whose status never came. The OS process
  /// may still be running, and no later event can repair this: proof lost is
  /// permanent, which is why it is a state and not an absence.
  LostExit
}

// Why a helper's native exit is awaited, or arrived. The same status means
// different things after each, which is why the reason is kept next to the
// wait and not rediscovered when the status arrives.
type Awaiting {
  /// The helper was asked to retire (a `shutdown` frame) and is expected to
  /// cancel and join its jail on the way out. Its exit status 0 is the
  /// witness of that join; any other status proves only that the process is
  /// gone.
  AfterShutdown

  /// The broker sent SIGKILL because the helper could not be trusted to
  /// answer: a missed cancel ladder, a handshake that never completed, a
  /// silent heartbeat, a corrupt or illegal frame. The helper never ran its
  /// join, so no status can attest one; what the status proves is that the
  /// helper process is gone, and whether that is enough depends on how
  /// much jail it had (`exposure`). See `native_verdict`.
  AfterKill(exposure: Exposure)

  /// The port reported an exit nobody asked for: the helper died on its own
  /// in a live phase. It never ran its join either, so the verdict is the
  /// same as for a kill from the same phase, and the two are recorded
  /// separately only so that a reader can tell them apart. It is also what
  /// a failed write awaits: the helper was never asked to go, and the
  /// status that may be queued behind the write is an unasked exit's.
  Unprompted(exposure: Exposure)
}

// How much jail a helper had when it stopped answering, decided by the
// phase it was in. This, and not the hello features alone, is what says
// whether its death leaves anything running.
type Exposure {
  /// The helper had not accepted a hello. The Go helper writes its hello
  /// before it reads any frame, and the broker sends no `exec_start` before
  /// `Idle`, so no jail was ever dispatched.
  NoJail

  /// The helper was `Idle`. That phase is entered on an `exec_exit`, which
  /// the helper writes only after `Settle` returned, and `Settle` has
  /// already SIGKILLed the execution's process group (and, on Darwin, its
  /// tracked descendants). The last jail was killed before the helper was.
  SettledJail

  /// The helper was `Running` or `Cancelling`: a jail may be alive and the
  /// helper's death is the only thing that ends it.
  LiveJail
}

/// Where the helper is in its lifecycle: the machine's *state* in
/// `weft/state_machine`'s sense, which is what makes both deadlines
/// structural instead of guarded by hand.
///
/// `Idle`, `Running` and `Cancelling` are the three ways to be past the
/// handshake, and each carries the hello features so a status query is
/// answered from the state alone. The two busy ones additionally carry
/// the execution in flight, which is how a settlement knows who to tell.
///
/// **A state's payload must not change while the machine is in it.** A
/// state timeout is cancelled by a move to a state that compares
/// *unequal*, and a `transition` to an equal value is not a move at all
/// — so re-entering `Cancelling` with a mutated payload would silently
/// restart the escalation deadline, and re-entering it with an equal one
/// is a no-op that looks like a move. Every field here is fixed at the
/// moment its state is entered: `features` at hello, `RunningExec` at
/// dispatch. Anything that moves per frame belongs in `Data`.
type Phase {
  /// The owner exists, but no transport or policy file has been acquired.
  Prepared

  /// The hello exchange is in flight. Entering this state arms the
  /// handshake deadline.
  AwaitingHello

  /// Handshake done, nothing running.
  Idle(features: List(String))

  /// One execution in flight, running normally.
  Running(features: List(String), exec: RunningExec)

  /// One execution in flight that has been told to stop. Entering this
  /// state arms the cancel-escalation deadline; settling back to `Idle`
  /// is what disarms it.
  Cancelling(features: List(String), exec: RunningExec)

  /// The original credited execution has terminated but its borrow remains held.
  Finishing(features: List(String), exec: RunningExec)

  /// The channel is gone. Absorbing: every request is answered with this
  /// failure until the machine is shut down, and no second failure
  /// re-notifies anyone.
  Dead(failure: ExecFailure, retirement: Retirement)
}

/// The execution a `Running` or `Cancelling` state carries. Immutable
/// for the life of that state — see `Phase`.
type RunningExec {
  RunningExec(
    id: Int,
    events: EventSink,
    demand: EnforcementDemand,
    /// The layer tags this execution's policy calls for, computed at
    /// dispatch and checked against the `exec_exit` report. Held here
    /// because the report arrives long after the request that named
    /// them, and "what was asked for" is half of the check.
    required: List(String),
    /// Platform-known gaps that may be reported as skipped for this
    /// execution. Every one must still appear in the report, either as
    /// applied or as `skip:`; silence is not tolerance.
    tolerated: List(String),
  )
}

/// Everything the machine carries *across* states: the channel, the
/// deframer, and the bookkeeping that belongs to no single phase.
///
/// The split from `Phase` is weft's, and it is load-bearing rather than
/// tidy. Data may change on every frame without disturbing a state
/// timeout; a change of state cancels one. So the deframer, the id
/// counter and the outstanding-tick flag live here — putting any of them
/// in the state would make an ordinary inbound chunk cancel the cancel
/// escalation. The heartbeat itself is in neither: it is a periodic
/// timeout, which belongs to the machine rather than to a phase, and
/// what stays here is only the one-deep record of whether the last probe
/// was answered.
type Data {
  Data(
    config: HelperConfig,
    wire_out: Wire,
    deframer: framing.Deframer,
    next_id: Int,
    pending_heartbeats: List(#(Int, Subject(Result(Nil, ExecFailure)))),
    tick_outstanding: Bool,
    cleaned: Bool,
    /// The features the helper's hello announced, empty until it does.
    /// They are fixed at the hello and so would belong in the phases that
    /// carry them, but those are gone once the machine is `Dead`, and a
    /// retirement verdict is asked for there: it needs to know whether the
    /// helper built its jails under bwrap. See `native_verdict`.
    hello_features: List(String),
    commands: Subject(Msg),
    wire: Subject(WireEvent),
    protocol: Option(ProtocolRun),
    reserved_protocol: Option(Int),
  )
}

/// A phase and its data in one value, for the inbound-frame path.
///
/// One deframed chunk can carry several frames and any of them may move
/// the machine — a hello to `Idle`, an `exec_exit` to `Idle`, a frame the
/// helper had no business sending to `Dead`. Folding over them needs both
/// halves in hand, so the fold threads this and the dispatch arm turns
/// the result back into a step with `advance`.
type Machine {
  Machine(phase: Phase, data: Data)
}

/// A `HelperConfig` with contract-derived defaults: 5s handshake, 3s
/// cancel grace (above the helper's 2s ladder), 30s heartbeats.
pub fn default_config(transport: Transport) -> HelperConfig {
  HelperConfig(
    transport:,
    handshake_timeout_ms: 5000,
    cancel_grace_ms: 3000,
    kill_witness_ms:,
    heartbeat_interval_ms: 30_000,
  )
}

// How long the broker waits, after SIGKILL, for the exit status the kill
// produces. SIGKILL cannot be caught, blocked or ignored, and the kernel
// delivers it to a live process at once, so a status that has not arrived
// five seconds later is one the kill did not produce: the pid was already
// reaped, `kill` could not run, or the helper sits in uninterruptible sleep.
// Waiting longer would only hold a pool slot `Draining` for ever, and the
// timeout cannot grant a proof, only give up one that was never coming.
const kill_witness_ms = 5000

// --- helper lifecycle ---------------------------------------------------

/// Starts a helper state machine over a transport. The handshake runs
/// asynchronously; use `await_ready` (or `spawn_helper`, which does) to
/// learn the features or the failure.
///
/// The return type is `gleam/otp/actor`'s own `StartError`, which is
/// what `weft/state_machine.start` reports: a weft machine is
/// indistinguishable from an upstream actor to whatever starts it, so
/// `spawn_helper`'s `InitFailed` translation below still reads.
pub fn start(config: HelperConfig) -> Result(Helper, actor.StartError) {
  prepare(config)
  |> result.map(fn(helper) {
    begin(helper)
    helper
  })
}

/// Creates a parked owner without opening its transport. The caller must
/// record and monitor this owner before activating it with `begin`.
///
/// ## Examples
///
/// `prepare(config)` performs no native spawn or policy-file acquisition.
pub fn prepare(config: HelperConfig) -> Result(Helper, actor.StartError) {
  // Weft's parent-exit policy includes normal termination. A preparer that
  // exits before publication must not leave a parked resource owner behind.
  state_machine.new_with_initialiser(5000, fn(commands) {
    let wire = process.new_subject()
    let base =
      process.new_selector()
      |> process.select(commands)
      |> process.select_map(wire, FromWire)

    // Native acquisition follows Begin, after the pool has custody. The
    // parked phase owns no deadline because no handshake has begun.
    let data =
      Data(
        protocol: None,
        reserved_protocol: None,
        config:,
        wire_out: WireUnopened,
        deframer: framing.deframer(),
        next_id: 1,
        pending_heartbeats: [],
        tick_outstanding: False,
        cleaned: False,
        hello_features: [],
        commands:,
        wire:,
      )
    state_machine.initialised(Prepared, data)
    |> state_machine.selecting(base)
    |> state_machine.returning(#(commands, wire))
    |> Ok
  })
  |> state_machine.on_event(handle)
  |> state_machine.on_enter(entered)
  |> state_machine.trapping_exits(True)
  |> state_machine.start
  |> result.map(fn(started) {
    let #(commands, wire) = started.data
    Helper(
      commands:,
      wire:,
      pid: started.pid,
      handshake_wait: config.handshake_timeout_ms + 1000,
    )
  })
}

/// Activates a prepared helper once. Repeated activation has no effect.
///
/// ## Examples
///
/// `begin(helper)` is called only after the owner enters its pool inventory.
pub fn begin(helper: Helper) -> Nil {
  process.send(helper.commands, Begin)
}

// Opens the resolved runtime channel for a transport spec. The port
// case must run in the calling (actor) process: port messages are
// delivered to the opener, and the opener is where the selector lives.
fn open_transport(
  transport: Transport,
  base: process.Selector(Msg),
) -> Result(#(Wire, process.Selector(Msg)), String) {
  case transport {
    DeferredTransport(acquire) -> {
      use transport <- result.try(acquire())
      open_transport(transport, base)
    }
    ChannelTransport(send:, close:) -> Ok(#(WireChannel(send:, close:), base))
    PortTransport(executable:, args:, cleanup:) ->
      case ffi_port.open_helper(executable, args) {
        Error(Nil) -> {
          cleanup()
          Error(port_open_failure)
        }
        Ok(opened) -> {
          let os_pid = option.from_result(ffi_port.port_os_pid(opened))
          let selector =
            process.select_record(
              base,
              tag: opened,
              fields: 1,
              mapping: fn(message) { FromWire(port_wire_event(message)) },
            )
          Ok(#(WirePort(port: opened, os_pid:, cleanup:), selector))
        }
      }
  }
}

// The initialiser failure message for an unopenable port; spawn_helper
// translates it back into a structured SpawnError.
const port_open_failure = "helper port could not be opened"

fn port_wire_event(message: Dynamic) -> WireEvent {
  case ffi_port.port_event(message) {
    ffi_port.PortBytes(data:) -> WireBytes(data:)
    ffi_port.PortClosed(status:) -> WireClosed(status:)

    // Not a port message shape; treat as an empty chunk (harmless).
    ffi_port.PortJunk -> WireBytes(data: <<>>)
  }
}

/// Blocks until the handshake settles, returning the helper's hello
/// features. Bounded by the config's handshake timeout — and by
/// `timeout` for the actor's answer, which an actor wedged in a channel
/// write can miss even though its own deadline fired: that is
/// `HelperUnresponsive` rather than a dead caller, because the one
/// production caller is asking this in order to *report* on the helper
/// (`client/serve.degraded`), and a probe that answers with its
/// caller's death has answered nothing.
pub fn await_ready(
  helper: Helper,
  waiting timeout: Int,
) -> Result(List(String), ExecFailure) {
  or_unresponsive(call.try_call(
    helper.commands,
    waiting: timeout,
    sending: AwaitReady,
  ))
}

/// The helper's current lifecycle position, or `StatusUnresponsive`
/// when the actor does not answer within `timeout` or is not alive to
/// be asked. The unresponsive answer is about the actor, not the
/// helper behind it: nothing is known of what the helper is doing.
///
/// This used to be an ordinary `process.call`, which panics on both.
/// The contract was defensible for a caller whose next step needs the
/// answer, and indefensible for the callers this actually has: every
/// one of them is asking whether a helper is fit to use, and the pool
/// had to grow a private `try_call` probe of its own rather than call
/// it, because inside the pool actor that panic is not a retired helper
/// but a dead pool — and a dead pool takes the broker with it. There is
/// now one probe, and `helper_ready` is a policy on top of it.
pub fn status(helper: Helper, waiting timeout: Int) -> HelperStatus {
  case call.try_call(helper.commands, waiting: timeout, sending: QueryStatus) {
    Ok(position) -> position
    Error(call.NoReply) | Error(call.CalleeGone) -> StatusUnresponsive
  }
}

/// Dispatches an execution. On `Ok`, events stream to `events` and end
/// with exactly one `Exited` or `Failed`; an `Error` is a dispatch-time
/// refusal, and nothing was sent to the helper unless it is
/// `HelperUnresponsive`.
///
/// An actor that does not answer the dispatch is `HelperUnresponsive`,
/// not a fault: the broker calls this from inside its own message
/// handler, on a helper it borrowed a few microseconds earlier and
/// which is free to have died in between, and a dispatch that killed
/// the broker would take every other strand's verdict with it. The
/// refusal settles in band like any other dispatch-stage failure.
///
/// That answer says the caller stopped waiting, not that the request was
/// withdrawn: the `Run` stays queued and a recovered actor will read it.
/// It is dispatched only if the owner of `events` is still alive when it
/// does, and refused with `NotReady` otherwise, so a caller that gives up
/// and exits cannot have an execution started on its behalf. A caller
/// that gives up and carries on can, and must treat the outcome as
/// unknown.
pub fn run(
  helper: Helper,
  request: ExecRequest,
  events events: Subject(ExecEvent),
  waiting timeout: Int,
) -> Result(Nil, ExecFailure) {
  or_unresponsive(
    call.try_call(helper.commands, waiting: timeout, sending: fn(reply) {
      Run(request:, window: RelayOwned, events:, reply:)
    }),
  )
}

/// Dispatches only while the unchanged native wall policy fits its admission.
/// The helper actor checks when it consumes Run, after any mailbox delay. An
/// expired request is NotReady and emits no native exec_start frame. Zero is
/// reserved for a session lifetime with an explicit zero-wall policy.
///
/// This is a monotonic admission check, not a hard real-time guarantee across
/// scheduler suspension or native port delivery after the check.
///
/// ## Examples
///
/// ```gleam
/// // exec.run_before(helper, request, clock, deadline, events: events, waiting: 1000)
/// ```
pub fn run_before(
  helper: Helper,
  request: ExecRequest,
  clock: clock.Clock,
  deadline_ms: Int,
  events events: Subject(ExecEvent),
  waiting timeout: Int,
) -> Result(Nil, ExecFailure) {
  or_unresponsive(
    call.try_call(helper.commands, waiting: timeout, sending: fn(reply) {
      Run(request:, window: NativeBefore(clock, deadline_ms), events:, reply:)
    }),
  )
}

/// Tests the immutable policy against the remaining absolute admission budget.
/// Missing policy cannot establish either finite or session lifetime authority.
///
/// ## Examples
///
/// ```gleam
/// // exec.native_wall_fits(request, clock, deadline_ms)
/// ```
pub fn native_wall_fits(
  request: ExecRequest,
  clock: clock.Clock,
  deadline_ms: Int,
) -> Bool {
  case request.policy {
    None -> False
    Some(policy) ->
      case deadline_ms == 0 {
        True -> policy.limits.wall_s == 0
        False -> {
          let #(now, _) = clock.read(clock)
          let remaining = deadline_ms - now
          policy.limits.wall_s > 0 && remaining >= policy.limits.wall_s * 1000
        }
      }
  }
}

/// Sends a chunk of stdin to the running execution; `eof: True` closes
/// the child's stdin after `data`. Ignored when nothing is running.
pub fn stdin(helper: Helper, data data: BitArray, eof eof: Bool) -> Nil {
  process.send(helper.commands, Stdin(data:, eof:))
}

/// Cancels the running execution. Idempotent. If `exec_exit` still does
/// not arrive within the grace period the actor kills the helper process
/// outright and settles the execution as `Failed(CancelEscalated)`.
///
/// ## What the ladder actually addresses
///
/// `TERM` → grace → `KILL`, but the two rungs are not sent to the same
/// set of processes, and the difference is what makes the grace mean
/// anything inside a jail.
///
/// `TERM` goes to the **payload** — the command the broker addressed and
/// whatever it spawned inside the jail — and deliberately spares the
/// jail's own scaffolding. Under bwrap the helper's direct child is a
/// supervisor process that is also the process-group leader, and it is
/// spawned `--die-with-parent`; TERMing the group therefore kills the
/// supervisor, whose death SIGKILLs the PID namespace's init and every
/// process in that namespace with it. That collapsed the grace to under a
/// millisecond and delivered a SIGKILL to a payload nothing had asked to
/// stop. `KILL` does go to the whole group, because by then demolishing
/// the cage is the point. See `packages/sandbox/internal/jail/cancel.go`.
///
/// ## What the exit reports, and why `signal` is not the field to read
///
/// Unjailed, the payload is the helper's direct child: a TERM-compliant
/// payload dies of the signal and `ExecResult` carries `signal: 15`,
/// `code: 143`.
///
/// Jailed, the helper's direct child is the supervisor, which outlives
/// the payload and relays a signalled payload by *exiting* 128+signal
/// itself. `signal` is then `0` — not because nothing was signalled, but
/// because the process the helper waited on was not the one signalled.
/// `code` is 143 either way.
///
/// So `code` is the field that means the same thing on both sides of the
/// jail boundary; `signal` distinguishes them and must not be read as
/// "the payload was/was not signalled".
pub fn cancel(helper: Helper) -> Nil {
  process.send(helper.commands, CancelExec)
}

/// A protocol-level liveness probe: sends `heartbeat` and waits for the
/// echo. An actor that does not answer is `HelperUnresponsive` — the
/// answer to "is this helper alive?" is never the questioner's death.
pub fn heartbeat(
  helper: Helper,
  waiting timeout: Int,
) -> Result(Nil, ExecFailure) {
  or_unresponsive(call.try_call(
    helper.commands,
    waiting: timeout,
    sending: Heartbeat,
  ))
}

// An exchange with the helper actor that produced no reply is a helper
// failure like any the actor could have reported, and every caller of
// these three settles one in band. The distinction the fault carries —
// timed out versus never alive — is not one any of them can act on:
// the actor is out of reach either way and nothing was dispatched.
fn or_unresponsive(
  attempt: Result(Result(a, ExecFailure), call.CallFault),
) -> Result(a, ExecFailure) {
  case attempt {
    Ok(answer) -> answer
    Error(call.NoReply) | Error(call.CalleeGone) -> Error(HelperUnresponsive)
  }
}

/// Requests orderly shutdown and discards the BEAM actor after confirmed
/// native retirement. This cast is not a retirement acknowledgement.
pub fn shutdown(helper: Helper) -> Nil {
  process.send(helper.commands, Shutdown)
  process.send(
    helper.commands,
    AwaitRetirement(fn(outcome) {
      case outcome {
        Ok(Nil) -> process.send(helper.commands, ForgetRetired)
        Error(_) -> Nil
      }
    }),
  )
}

/// Waits for native exit after the helper's shutdown frame, then retires
/// its BEAM owner. A timeout never closes the port or releases custody.
///
/// ## Examples
///
/// `close(helper, waiting: 5000)` requires native status 0 and normal owner
/// exit, or explicit confirmation that no native transport was acquired.
pub fn close(
  helper: Helper,
  waiting timeout: Int,
) -> Result(Nil, RetirementFailure) {
  let deadline = monotonic_ms() + timeout
  let monitor = process.monitor(helper.pid)
  process.send(helper.commands, Shutdown)
  let outcome = case
    call.try_call(helper.commands, waiting: timeout, sending: fn(reply) {
      AwaitRetirement(fn(outcome) { process.send(reply, outcome) })
    })
  {
    Ok(outcome) -> outcome
    Error(call.NoReply) -> Error(RetirementPending)
    Error(call.CalleeGone) -> Error(RetirementOwnerGone)
  }
  let outcome = case outcome {
    Ok(Nil) -> {
      process.send(helper.commands, ForgetRetired)
      await_retired_owner(monitor, deadline)
    }
    Error(failure) -> Error(failure)
  }
  process.demonitor_process(monitor)
  outcome
}

// Native proof and BEAM retirement are separate events. The monitor predates
// both, and the remaining caller budget bounds the second observation too.
fn await_retired_owner(
  monitor: process.Monitor,
  deadline: Int,
) -> Result(Nil, RetirementFailure) {
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(down) {
    case down.reason {
      process.Normal -> Ok(Nil)
      process.Killed | process.Abnormal(_) -> Error(RetirementOwnerGone)
    }
  })
  |> process.selector_receive(int.max(0, deadline - monotonic_ms()))
  |> result.unwrap(Error(RetirementPending))
}

// The two observations share Weft's monotonic clock and one caller budget.
fn monotonic_ms() -> Int {
  let clock = poll.monotonic()
  clock.now()
}

/// The actor's pid, for monitoring.
pub fn pid(helper: Helper) -> Pid {
  helper.pid
}

/// The subject on which the transport delivers inbound bytes. Only fake
/// (`ChannelTransport`) peers send to it; the port transport bypasses
/// it via the port selector.
pub fn wire(helper: Helper) -> Subject(WireEvent) {
  helper.wire
}

// --- machine internals --------------------------------------------------

/// The machine's event handler: one exhaustive matrix over phase and
/// message.
///
/// Every pair is written out, including the ones that cannot happen, and
/// that is the point of the port. Adding a phase or a message makes the
/// compiler name each combination nobody has thought about, where the
/// actor this replaces answered several of them with a guard the handler
/// had to remember to write — `state.phase` re-checked inside the
/// handshake deadline, an execution id carried on the cancel deadline so
/// its handler could recognise its own fire.
fn handle(
  phase: Phase,
  data: Data,
  message: Msg,
) -> state_machine.Next(Phase, Data, Msg) {
  case phase, message {
    Idle(..), ReserveProtocol(reply:) ->
      case data.reserved_protocol {
        None -> {
          let #(data, id) = fresh_id(data)
          process.send(reply, Ok(id))
          state_machine.keep(Data(..data, reserved_protocol: Some(id)))
        }
        Some(_) -> {
          process.send(reply, Error(HelperBusy))
          state_machine.keep(data)
        }
      }
    _phase, ReserveProtocol(reply:) -> {
      process.send(reply, Error(NotReady))
      state_machine.keep(data)
    }

    phase, RunProtocol(id:, request:, mode:, clock:, deadline:, events:, reply:)
    ->
      handle_protocol_run(
        Machine(phase:, data:),
        id,
        request,
        mode,
        clock,
        deadline,
        events,
        reply,
      )
    phase, FeedProtocol(id:, ordinal:, frame_id:, data: bytes, end:, reply:) ->
      handle_protocol_feed(
        Machine(phase:, data:),
        id,
        ordinal,
        frame_id,
        bytes,
        end,
        reply,
      )
    phase, ConsumeProtocolOutput(id:, ordinal:) ->
      advance(consume_protocol_output(Machine(phase:, data:), id, ordinal))
    phase, ConsumeProtocolReusable(id:) ->
      advance(consume_protocol_reusable(Machine(phase:, data:), id))
    phase, DeferProtocolCheckin(id:, checkin:, reply:) ->
      defer_checkin(Machine(phase:, data:), id, checkin, reply)
    phase, CancelProtocol(id:) ->
      case running_with_id(phase, id) {
        Some(_) -> handle(phase, data, CancelExec)
        None -> state_machine.keep(data)
      }
    Finishing(..) as phase, message ->
      handle_finishing(Machine(phase:, data:), message)
    Prepared, Begin -> activate(data)
    AwaitingHello, Begin
    | Idle(..), Begin
    | Running(..), Begin
    | Cancelling(..), Begin
    | Dead(..), Begin
    -> state_machine.keep(data)

    Prepared, FromWire(..)
    | Prepared, Stdin(..)
    | Prepared, CancelExec
    | Prepared, CancelDeadline
    | Prepared, HandshakeDeadline
    | Prepared, KillWitnessDeadline
    | Prepared, HeartbeatTick
    | Prepared, ForgetRetired
    -> state_machine.keep(data)
    Prepared, AwaitReady(..) | Prepared, AwaitRetirement(..) ->
      state_machine.keep(data) |> state_machine.postpone
    Prepared, Run(reply:, ..) -> refuse_run(data, reply, NotReady)
    Prepared, Heartbeat(reply) -> {
      process.send(reply, Error(NotReady))
      state_machine.keep(data)
    }
    Prepared, Shutdown ->
      state_machine.transition(Dead(ChannelClosed(0), NoNativeResource), data)

    // Inbound bytes are deframed in every phase. `apply_inbound` asks
    // the phase question once per frame rather than once per chunk,
    // because a chunk can carry the frame that kills the channel and
    // the frames behind it.
    phase, FromWire(WireBytes(data: bytes)) ->
      advance(handle_bytes(Machine(phase:, data:), bytes))

    phase, FromWire(WireClosed(status:)) ->
      native_exit(Machine(phase:, data:), status)

    Dead(retirement: NativeExit(status:, awaited:), ..), AwaitRetirement(reply)
    -> {
      reply(native_verdict(status, awaited, data.hello_features))
      state_machine.keep(data)
    }
    Dead(retirement: NoNativeResource, ..), AwaitRetirement(reply) -> {
      reply(Ok(Nil))
      state_machine.keep(data)
    }
    Dead(retirement: LostExit, ..), AwaitRetirement(reply) -> {
      reply(Error(RetirementProofLost))
      state_machine.keep(data)
    }
    Dead(retirement: PendingExit(..), ..), AwaitRetirement(..)
    | AwaitingHello, AwaitRetirement(..)
    | Idle(..), AwaitRetirement(..)
    | Running(..), AwaitRetirement(..)
    | Cancelling(..), AwaitRetirement(..)
    -> state_machine.keep(data) |> state_machine.postpone

    // The actor retires only on a verdict that is `Ok`, which is the same
    // test `AwaitRetirement` answers with: the pool sends this after an
    // `Ok` outcome, and `close` does the same, so a status that cannot
    // retire the helper must not be able to retire its owner either.
    Dead(retirement: NativeExit(status:, awaited:), ..), ForgetRetired ->
      case native_verdict(status, awaited, data.hello_features) {
        Ok(Nil) -> state_machine.stop()
        Error(_) -> state_machine.keep(data)
      }
    Dead(retirement: NoNativeResource, ..), ForgetRetired ->
      state_machine.stop()
    Dead(..), ForgetRetired
    | AwaitingHello, ForgetRetired
    | Idle(..), ForgetRetired
    | Running(..), ForgetRetired
    | Cancelling(..), ForgetRetired
    -> state_machine.keep(data)

    // The status query reads the phase alone, which is why the hello
    // features are carried by the three live states rather than beside
    // them.
    phase, QueryStatus(reply:) -> {
      process.send(reply, case data.reserved_protocol, phase {
        Some(_), Idle(features:) -> StatusBusy(features)
        _, _ -> status_of(phase)
      })
      state_machine.keep(data)
    }

    // Shutdown settles what is in flight before the machine stops, so a
    // caller whose execution is still running learns why it ended
    // instead of watching its events subject go quiet.
    AwaitingHello, Shutdown ->
      state_machine.keep(data) |> state_machine.postpone
    Dead(..), Shutdown -> state_machine.keep(data)
    Idle(..) as phase, Shutdown
    | Running(..) as phase, Shutdown
    | Cancelling(..) as phase, Shutdown
    -> handle_shutdown(Machine(phase:, data:))

    // The handshake has not settled, so the asker is parked. `postpone`
    // re-queues this exact event; weft replays it, in arrival order,
    // exactly once, on the next change of state — the hello's move to
    // `Idle` or a death's move to `Dead` — where the arms below answer
    // it with that state's outcome. Invariant: every `AwaitReady` asked
    // during the handshake is answered exactly once with the outcome of
    // the next state.
    AwaitingHello, AwaitReady(..) ->
      state_machine.keep(data) |> state_machine.postpone

    Idle(features:), AwaitReady(reply:)
    | Running(features:, ..), AwaitReady(reply:)
    | Cancelling(features:, ..), AwaitReady(reply:)
    -> {
      process.send(reply, Ok(features))
      state_machine.keep(data)
    }

    Dead(failure:, ..), AwaitReady(reply:) -> {
      process.send(reply, Error(failure))
      state_machine.keep(data)
    }

    // A dispatch is answered now or never: nothing is postponed here,
    // because a caller that cannot run holds a budget reservation and a
    // deadline, and would rather be refused than parked.
    Dead(failure:, ..), Run(reply:, ..) -> refuse_run(data, reply, failure)

    AwaitingHello, Run(reply:, ..) -> refuse_run(data, reply, NotReady)

    // One helper runs one execution at a time, and a cancel in flight is
    // still an execution in flight.
    Running(..), Run(reply:, ..) | Cancelling(..), Run(reply:, ..) ->
      refuse_run(data, reply, HelperBusy)

    Idle(features:), Run(request:, window:, events:, reply:) ->
      case data.reserved_protocol {
        Some(_) -> refuse_run(data, reply, HelperBusy)
        None -> handle_run(data, features, request, window, events, reply)
      }

    // Stdin follows the execution rather than the phase: a payload that
    // has been TERMed but has not exited may still be reading.
    //
    // The frame gets an id of its own and not the execution's. The helper
    // answers a refused write (the payload closed its stdin, or stdin was
    // already at end of file) with `error{no_exec}` carrying the *stdin
    // frame's* id, and `settle` treats an error under the execution's own
    // id as that execution's refusal: the running payload would be settled
    // `Failed` and the machine sent `Idle` while the helper still runs it.
    // The helper uses a stdin frame's id for nothing but addressing that
    // reply, so a fresh id makes the reply correlate to nothing and `settle`
    // drops it. Cancel needs no such care: the helper never answers a
    // `cancel` with an error, and an unknown cancel is a no-op.
    Running(..) as phase, Stdin(data: bytes, eof:)
    | Cancelling(..) as phase, Stdin(data: bytes, eof:)
    -> {
      let #(data, id) = fresh_id(data)
      send_or_die(
        Machine(phase:, data:),
        framing.Frame(id:, body: framing.ExecStdin(data: bytes, eof:)),
      )
    }

    AwaitingHello, Stdin(..) | Idle(..), Stdin(..) | Dead(..), Stdin(..) ->
      state_machine.keep(data)

    // The TERM goes out and the machine moves to `Cancelling`, whose
    // enter call arms the escalation deadline. Arming it there rather
    // than here is what makes a write that fails on the way — landing in
    // `Dead` instead — leave no deadline running against a machine that
    // has already settled.
    Running(features:, exec:), CancelExec ->
      send_or_die(
        Machine(phase: Cancelling(features:, exec:), data:),
        framing.Frame(id: exec.id, body: framing.Cancel),
      )

    // Idempotent: `keep` is not a state change, so the first cancel's
    // deadline keeps running rather than being restarted by the second.
    Cancelling(..), CancelExec -> state_machine.keep(data)

    AwaitingHello, CancelExec | Idle(..), CancelExec | Dead(..), CancelExec ->
      state_machine.keep(data)

    // The helper missed its own 2s TERM-to-KILL ladder. Belt and braces:
    // kill it and settle the execution in band. `die` does the killing,
    // with the port still open (the helper is alive, if unresponsive, or
    // the deadline would not have fired), so the exit status the kill
    // produces can still be selected: this is the witnessed kill.
    Cancelling(..) as phase, CancelDeadline ->
      die(Machine(phase:, data:), CancelEscalated)

    // Unreachable by construction. The escalation deadline is a state
    // timeout on `Cancelling`, so any move out of that state cancels it
    // and a fire that raced the move is dropped by weft's timer book
    // before it reaches this handler. The arm exists because the matrix
    // is exhaustive, not because the case can arise.
    AwaitingHello, CancelDeadline
    | Idle(..), CancelDeadline
    | Running(..), CancelDeadline
    | Dead(..), CancelDeadline
    -> state_machine.keep(data)

    // The helper never reported the status that was owed: its SIGKILL
    // should have produced one, or the port closed under a failed write
    // and its status never reached the mailbox. Closing the port abandons
    // the wait (and is a no-op for a port that has already closed), and
    // the move to `LostExit` is an unequal state, so weft replays every
    // postponed `AwaitRetirement` against it and the pool reads the proof
    // as lost. This can only lose a proof: no arm here grants one.
    Dead(failure:, retirement: PendingExit(AfterKill(..))), KillWitnessDeadline
    | Dead(failure:, retirement: PendingExit(Unprompted(..))),
      KillWitnessDeadline
    ->
      state_machine.transition(
        Dead(failure, close_transport(data.wire_out)),
        data,
      )

    // Unreachable: the status arriving or the port closing leaves
    // `PendingExit`, which cancels the witness timeout, and no other state
    // arms it (`AfterShutdown` waits on the helper's own orderly teardown
    // and is bounded by the caller's deadline instead). The arms exist
    // because the matrix is exhaustive.
    AwaitingHello, KillWitnessDeadline
    | Idle(..), KillWitnessDeadline
    | Running(..), KillWitnessDeadline
    | Cancelling(..), KillWitnessDeadline
    | Dead(retirement: NoNativeResource, ..), KillWitnessDeadline
    | Dead(retirement: PendingExit(AfterShutdown), ..), KillWitnessDeadline
    | Dead(retirement: NativeExit(..), ..), KillWitnessDeadline
    | Dead(retirement: LostExit, ..), KillWitnessDeadline
    -> state_machine.keep(data)

    AwaitingHello, HandshakeDeadline ->
      die(Machine(phase: AwaitingHello, data:), HandshakeTimeout)

    // Unreachable for the same reason the stale `CancelDeadline` is:
    // reaching `Idle` or `Dead` cancels the handshake deadline, and this
    // is where the actor's `case state.phase` guard used to live.
    Idle(..), HandshakeDeadline
    | Running(..), HandshakeDeadline
    | Cancelling(..), HandshakeDeadline
    | Dead(..), HandshakeDeadline
    -> state_machine.keep(data)

    Idle(..) as phase, HeartbeatTick
    | Running(..) as phase, HeartbeatTick
    | Cancelling(..) as phase, HeartbeatTick
    -> handle_heartbeat_tick(Machine(phase:, data:))

    // Unreachable by construction, and written out because weft's
    // exhaustiveness is what proves it: the probe is armed on the way
    // out of `AwaitingHello` and cancelled on the way into `Dead`, and a
    // tick in flight at either boundary is flushed by the timer book.
    AwaitingHello, HeartbeatTick | Dead(..), HeartbeatTick ->
      state_machine.keep(data)

    Idle(..) as phase, Heartbeat(reply:)
    | Running(..) as phase, Heartbeat(reply:)
    | Cancelling(..) as phase, Heartbeat(reply:)
    -> send_heartbeat(Machine(phase:, data:), reply)

    AwaitingHello, Heartbeat(reply:) -> {
      process.send(reply, Error(NotReady))
      state_machine.keep(data)
    }

    Dead(failure:, ..), Heartbeat(reply:) -> {
      process.send(reply, Error(failure))
      state_machine.keep(data)
    }
  }
}

/// The deadline each state owns, armed by every path into it — including
/// the initial entry into `AwaitingHello`, which weft makes for the
/// starting state on the far side of the start acknowledgement.
///
/// This callback is where the port's whole benefit is concentrated. Both
/// deadlines were hand-rolled `send_after` timers whose handlers had to
/// re-establish their own relevance: the handshake one re-read
/// `state.phase`, the cancel one compared an execution id it carried for
/// no other purpose, and three settle sites had to remember to cancel the
/// timer they had armed. As state timeouts they are cancelled by the move
/// out of the state that armed them, so the guards are deleted rather
/// than relocated.
///
/// Arming here rather than at the transition site matters for
/// `Cancelling`: the transition and the TERM write are one step, and a
/// write that fails lands in `Dead` instead. Only a machine that really
/// reached `Cancelling` gets the deadline.
fn entered(
  from: Phase,
  to: Phase,
  data: Data,
) -> state_machine.Enter(Phase, Data, Msg) {
  case to {
    Prepared -> state_machine.keep(data)
    AwaitingHello ->
      state_machine.keep(data)
      |> state_machine.with_state_timeout(
        after: data.config.handshake_timeout_ms,
        sending: HandshakeDeadline,
      )

    Cancelling(..) ->
      state_machine.keep(data)
      |> state_machine.with_state_timeout(
        after: data.config.cancel_grace_ms,
        sending: CancelDeadline,
      )

    // The probe starts when the handshake finishes, and the move out of
    // `AwaitingHello` is the only path that arms it. Arming on every
    // entry to `Idle` would turn a liveness probe into an idle timeout:
    // a helper settling executions faster than the interval would push
    // the next tick out for ever and never be probed at all.
    Idle(..) ->
      case from {
        AwaitingHello -> arm_heartbeat(data)
        Prepared
        | Idle(..)
        | Running(..)
        | Cancelling(..)
        | Finishing(..)
        | Dead(..) -> state_machine.keep(data)
      }

    // Nothing left to probe. Cancelling rather than letting the ticks
    // arrive and be ignored is what makes the `Dead(..), HeartbeatTick`
    // arm in `handle` unreachable: a tick already in flight when the
    // machine dies carries a stale generation stamp and dies in weft's
    // timer book instead of reaching the handler.
    //
    // A kill and a failed write both owe a status that may never come, so
    // both arm the witness timeout. A shutdown does not: the helper is
    // tearing its jail down in an orderly way, and how long that takes is
    // for the caller's own deadline to bound.
    Dead(retirement: PendingExit(AfterKill(..)), ..)
    | Dead(retirement: PendingExit(Unprompted(..)), ..) ->
      state_machine.keep(data)
      |> state_machine.cancel_timeout(name: heartbeat_timer)
      |> state_machine.with_state_timeout(
        after: data.config.kill_witness_ms,
        sending: KillWitnessDeadline,
      )

    Dead(..) ->
      state_machine.keep(data)
      |> state_machine.cancel_timeout(name: heartbeat_timer)

    Running(..) | Finishing(..) -> state_machine.keep(data)
  }
}

// The name the idle liveness probe is armed under.
//
// A periodic timeout shares weft's named-timeout name space, so one
// constant is what keeps the arm in `entered` and the cancel in `Dead`
// talking about the same timer rather than about two.
const heartbeat_timer = "helper.heartbeat"

// Arms the idle liveness probe, unless the configuration disables it.
//
// The zero guard survives the port and is not a leftover: `0` means "do
// not probe", and a periodic timeout armed for zero milliseconds is a
// spin rather than a disabled probe.
fn arm_heartbeat(data: Data) -> state_machine.Enter(Phase, Data, Msg) {
  case data.config.heartbeat_interval_ms > 0 {
    True ->
      state_machine.keep(data)
      |> state_machine.with_periodic_timeout(
        name: heartbeat_timer,
        every: data.config.heartbeat_interval_ms,
        sending: HeartbeatTick,
      )

    False -> state_machine.keep(data)
  }
}

// Hands a phase-and-data pair back to weft as a step.
//
// A `transition` to the phase the machine is already in is not a state
// change — weft compares states structurally — so this arms nothing,
// cancels nothing and runs no enter call when the work left the phase
// alone. When the work did move the machine, the same call is the move,
// and it takes the old phase's deadline with it. That equivalence is why
// the frame path can be written as `Machine -> Machine` and turned into
// a step in one place.
fn advance(machine: Machine) -> state_machine.Next(Phase, Data, Msg) {
  state_machine.transition(to: machine.phase, data: machine.data)
}

// The lifecycle position a `status` query reports. `Running` and
// `Cancelling` are both "busy" to an outside observer: the helper
// answered its hello but its single execution slot is taken, and a
// `Cancelling` helper stays taken until the helper reports the
// execution's exit. Reporting either as ready is what once let the
// pool lend a helper that a relay crash had checked in mid-execution.
fn status_of(phase: Phase) -> HelperStatus {
  case phase {
    Prepared | AwaitingHello -> StatusStarting
    Idle(features:) -> StatusReady(features:)
    Running(features:, ..)
    | Cancelling(features:, ..)
    | Finishing(features:, ..) -> StatusBusy(features:)
    Dead(failure:, ..) -> StatusDead(failure:)
  }
}

// The pool has already published this owner. Port acquisition and selector
// installation occur in that owner, so port messages cannot reach a short-lived
// factory worker. An acquisition error here precedes every native port.
fn activate(data: Data) -> state_machine.Next(Phase, Data, Msg) {
  let base =
    process.new_selector()
    |> process.select(data.commands)
    |> process.select_map(data.wire, FromWire)
  case open_transport(data.config.transport, base) {
    Error(_reason) ->
      state_machine.transition(Dead(SendFailed, NoNativeResource), data)
    Ok(#(wire_out, selector)) ->
      state_machine.transition(AwaitingHello, Data(..data, wire_out:))
      |> state_machine.with_selector(selector)
  }
}

// Settles execution callers before requesting native shutdown. The port stays
// open while the helper cancels and joins its jail; only its exit-status event
// advances PendingExit and releases postponed retirement requests.
fn handle_shutdown(machine: Machine) -> state_machine.Next(Phase, Data, Msg) {
  let data = notify_death(machine, ChannelClosed(status: 0))
  let #(data, id) = fresh_id(data)
  let sent = {
    use bytes <- result.try(
      framing.encode(framing.Frame(id:, body: framing.Shutdown))
      |> result.replace_error(Nil),
    )
    transport_send(data.wire_out, bytes)
  }

  // A write that fails here never delivered the shutdown, so a status is
  // not the helper's account of an orderly teardown it was never asked for.
  // Granting status 0 `AfterShutdown` would credit it with a join it had no
  // request to perform. The exit is judged as one nobody asked for, by the
  // jail of the phase the helper was in, and it is awaited under the
  // witness timeout because the port may have closed with its status
  // already queued, or with none.
  let retirement = case sent {
    Ok(Nil) -> PendingExit(AfterShutdown)
    Error(Nil) -> PendingExit(Unprompted(exposure_of(machine.phase)))
  }
  state_machine.transition(
    Dead(ChannelClosed(0), retirement),
    run_cleanup(data),
  )
}

// Only an exit event selected while the port was retained may establish
// native retirement. A late event after port_close cannot repair lost proof.
//
// A helper already `Dead` because it was shut down or killed keeps the
// failure it died with: a caller who asks it to `Run` is told
// `CancelEscalated`, not a bare exit status that hides why the helper went.
// A helper that dies in a live phase has no earlier failure, so the status
// is the failure, and the exit nobody asked for is judged by the jail it
// leaves behind, exactly as a kill from the same phase would be.
fn native_exit(
  machine: Machine,
  status: Int,
) -> state_machine.Next(Phase, Data, Msg) {
  case machine.phase {
    Prepared
    | Dead(retirement: NoNativeResource, ..)
    | Dead(retirement: LostExit, ..)
    | Dead(retirement: NativeExit(..), ..) -> state_machine.keep(machine.data)
    Dead(failure:, retirement: PendingExit(awaiting:)) ->
      state_machine.transition(
        Dead(failure, NativeExit(status:, awaited: awaiting)),
        machine.data,
      )
    AwaitingHello | Idle(..) | Running(..) | Cancelling(..) | Finishing(..) -> {
      let awaited = Unprompted(exposure_of(machine.phase))
      let data = notify_death(machine, ChannelClosed(status)) |> run_cleanup
      state_machine.transition(
        Dead(ChannelClosed(status), NativeExit(status:, awaited:)),
        data,
      )
    }
  }
}

// What jail a live phase leaves behind when its helper stops. `Prepared` and
// `Dead` have no live port to speak of; they answer `NoJail` so the match is
// total, and no caller reaches them.
fn exposure_of(phase: Phase) -> Exposure {
  case phase {
    Prepared | AwaitingHello | Dead(..) -> NoJail
    Idle(..) | Finishing(..) -> SettledJail
    Running(..) | Cancelling(..) -> LiveJail
  }
}

// Turns a native exit status into the retirement verdict, and is the one
// place that decides what a status is evidence of.
//
// After a shutdown, status 0 is the helper's own account that it cancelled
// and joined its jail, so it is `Ok`; any other status proves the process
// is gone and nothing about the jail's descendants.
//
// After a kill, or an exit nobody asked for, the helper never joined
// anything, and the status (137, when the signal is what ended it) says only
// that the helper process is gone. Whether that retires it depends on how
// much jail it left (`Exposure`):
//
// - `NoJail` and `SettledJail` left none. A helper that never accepted a
//   hello had no jail to leave, and an idle one had already had its last
//   jail killed by `Settle` before it wrote the `exec_exit` that made it
//   idle. Its exit is a complete witness on every platform, Darwin and
//   degraded Linux included, at the grade of the status-0 witness.
// - `LiveJail` is the case that needs the jail's life bounded by the
//   helper's. Under bwrap it is: bwrap is spawned `--die-with-parent`, so
//   the kernel SIGKILLs it when the helper dies, and `--unshare-pid` makes
//   bwrap's child the init of a fresh PID namespace, so the death of that
//   init takes every process in the namespace with it. The `bwrap` feature
//   in the accepted hello is the helper's statement that it built jails
//   that way. This is weaker than the status-0 witness: the payload may
//   keep running for a couple of scheduler wakeups after the status is
//   selected and the namespace tears down over tens of milliseconds, and
//   the per-exec cgroup directory is not removed. Without bwrap nothing
//   promises even that: a degraded Linux payload shares the helper's
//   namespaces and can `setsid` away, and on Darwin the descendant tracker
//   died with the helper. Those stay unconfirmed.
fn native_verdict(
  status: Int,
  awaited: Awaiting,
  features: List(String),
) -> Result(Nil, RetirementFailure) {
  case awaited, status {
    AfterShutdown, 0 -> Ok(Nil)
    AfterShutdown, status -> Error(RetirementExit(status))
    AfterKill(exposure:), status | Unprompted(exposure:), status ->
      case exposure, list.contains(features, "bwrap") {
        NoJail, _ | SettledJail, _ | LiveJail, True -> Ok(Nil)
        LiveJail, False -> Error(RetirementExit(status))
      }
  }
}

// The idle liveness probe. A tick still outstanding when the next one
// comes round is the helper having stopped speaking altogether, which is
// a death rather than one dropped frame.
fn handle_heartbeat_tick(
  machine: Machine,
) -> state_machine.Next(Phase, Data, Msg) {
  case machine.data.tick_outstanding {
    True -> die(machine, HeartbeatMissed)
    False -> send_heartbeat_tick(machine)
  }
}

// Writes this tick's probe; the next one is weft's to arm.
//
// A periodic timeout re-arms itself once this handler has returned, so
// the ordering the hand-rolled version had to arrange by hand — arm
// before the write, so a write that kills the channel leaves no gap —
// comes for free and is now stronger. A write that kills the channel
// lands in `Dead`, whose enter callback cancels the series, so there is
// no tick scheduled for a machine with nothing left to probe.
fn send_heartbeat_tick(
  machine: Machine,
) -> state_machine.Next(Phase, Data, Msg) {
  let #(data, id) = fresh_id(machine.data)
  let data = Data(..data, tick_outstanding: True)
  send_or_die(
    Machine(..machine, data:),
    framing.Frame(id:, body: framing.Heartbeat),
  )
}

// A caller's `heartbeat` probe. The echo is correlated by frame id, so
// several probes and the idle tick can be in flight at once without any
// of them answering for another.
fn send_heartbeat(
  machine: Machine,
  reply: Subject(Result(Nil, ExecFailure)),
) -> state_machine.Next(Phase, Data, Msg) {
  let #(data, id) = fresh_id(machine.data)
  let data =
    Data(..data, pending_heartbeats: [#(id, reply), ..data.pending_heartbeats])
  send_or_die(
    Machine(..machine, data:),
    framing.Frame(id:, body: framing.Heartbeat),
  )
}

// The one dispatch path: `Idle`, with a helper whose hello features the
// request's demand can live with. Every other phase was refused in
// `handle`, so this only has to weigh the caller's liveness and degradation.
//
// The liveness check is the late-`Run` fence. `run` uses `try_call`, and a
// caller whose call times out has already been told `HelperUnresponsive`
// while its `Run` is still queued in a wedged actor's mailbox. When the
// actor recovers it would dispatch an execution that nobody is listening to,
// after the caller was told it had failed. The events subject's owner is
// the process that would receive the outcome, so an owner that is gone
// means the caller gave up, and the `Run` is refused instead. The refusal
// is `NotReady`, the same answer as any other helper that cannot take work,
// and it goes to a reply subject nobody reads.
//
// This is a liveness fence and not a deadline. A caller that is still alive
// but gave up, because it timed out and went on to wait for something else,
// is not caught, and nor is one that dies in the instant after the check.
// The broker's relay dies with its call, which is the case this is for.
fn handle_run(
  data: Data,
  features: List(String),
  request: ExecRequest,
  window: RunWindow,
  events: Subject(ExecEvent),
  reply: Subject(Result(Nil, ExecFailure)),
) -> state_machine.Next(Phase, Data, Msg) {
  let timely = case window {
    RelayOwned -> True
    NativeBefore(clock, deadline) -> native_wall_fits(request, clock, deadline)
  }
  case
    timely && events_owner_alive(events),
    request.demand,
    degraded_features(features)
  {
    False, _, _ -> refuse_run(data, reply, NotReady)
    True, FullEnforcement, True ->
      refuse_run(data, reply, DegradedHelper(features:))
    True, PlatformEnforcement, True ->
      refuse_run(data, reply, DegradedHelper(features:))
    True, _, _ -> dispatch_exec(data, features, request, events, reply)
  }
}

// Whether the process that would receive an execution's events is alive.
// A subject with no owner, a named subject nobody has registered, has no one
// to receive them either.
fn events_owner_alive(events: Subject(a)) -> Bool {
  case process.subject_owner(events) {
    Ok(owner) -> process.is_alive(owner)
    Error(Nil) -> False
  }
}

// The shared shape of every dispatch-time refusal: answer the caller and
// keep the machine where it is, with no execution recorded.
fn refuse_run(
  data: Data,
  reply: Subject(Result(Nil, ExecFailure)),
  failure: ExecFailure,
) -> state_machine.Next(Phase, Data, Msg) {
  process.send(reply, Error(failure))
  state_machine.keep(data)
}

// Records the execution in the state and writes the `exec_start`.
//
// The caller is answered before the write, which is the order the
// contract needs: `run` returning `Ok` promises exactly one terminal
// event on the events subject, and a write that fails settles the
// execution with one — so the acknowledgement must already be out.
//
// Everything the settlement will need is fixed here and never touched
// again, which is what lets `RunningExec` sit inside the state. See
// `Phase` for why a mutable payload there would silently disarm the
// escalation deadline.
fn dispatch_exec(
  data: Data,
  features: List(String),
  request: ExecRequest,
  events: Subject(ExecEvent),
  reply: Subject(Result(Nil, ExecFailure)),
) -> state_machine.Next(Phase, Data, Msg) {
  let #(data, id) = fresh_id(data)

  // A consumed finite execution may retain its original late-checkin window.
  // Starting ordinary work closes that completed association so its controls
  // cannot attach to the successor and ordinary output follows its own lane.
  let data = case data.protocol {
    Some(ProtocolRun(reuse: ReuseConsumed, ..)) -> Data(..data, protocol: None)
    None | Some(_) -> data
  }
  let frame =
    framing.Frame(
      id:,
      body: framing.ExecStart(
        argv: request.argv,
        env: request.env,
        cwd: request.cwd,
        policy: request.policy,
        token: request.token,
        limits: None,
      ),
    )
  let exec =
    RunningExec(
      id:,
      events: OrdinaryEvents(events),
      demand: request.demand,
      required: required_layers_for_demand(
        request.policy,
        features,
        request.demand,
      ),
      tolerated: tolerated_layers_for_demand(
        request.policy,
        features,
        request.demand,
      ),
    )
  process.send(reply, Ok(Nil))
  send_or_die(Machine(phase: Running(features:, exec:), data:), frame)
}

// A helper advertising "degraded" (bwrap unavailable) cannot provide
// full enforcement. Per-exec ground truth is additionally checked on
// exec_exit.
fn degraded_features(features: List(String)) -> Bool {
  list.contains(features, "degraded")
}

/// The prefix the Go helper puts on an enforcement entry for a layer it
/// could not apply (`skip:landlock: unavailable ...`). Every place in this
/// module that recognises or strips a skip uses this one constant, and
/// `enforcement_tags_test` pins it against the helper's sources.
///
/// ## Examples
///
/// ```gleam
/// assert string.starts_with("skip:stage2: no report", skip_prefix)
/// ```
///
pub const skip_prefix = "skip:"

/// The layer tags an execution under `policy` must be able to show as
/// applied. Exported for the enforcement report the caller renders.
///
/// This is the half of the check that #54 was missing. "No `skip:`
/// entries" is a test a *silent* helper passes: a stage 2 that died
/// before writing fd 4 produced `enforcement: ["bwrap"]`, which contains
/// no skip and so satisfied a full-enforcement demand with the whole
/// inner report — Landlock, seccomp, no_new_privs, the rlimits — absent.
/// A layer that says nothing is not a layer that was applied.
///
/// Linux requires `bwrap`, `mounts`, `landlock`, and `no-new-privs`.
/// macOS requires `seatbelt` and `seatbelt-fs`. The rest are asked for by
/// the policy itself, and each platform names its actual mechanism:
///
/// | policy                    | tag            |
/// |---------------------------|----------------|
/// | Linux network off/proxy   | `seccomp-net`  |
/// | macOS network off/proxy   | `seatbelt-net` |
/// | Linux memory/pids > 0     | `cgroup-v2`    |
/// | macOS memory > 0          | `rlimit-address-space` |
/// | macOS pids > 0            | `rlimit-processes` |
/// | `cpu_s` > 0               | `rlimit-cpu`   |
/// | `fsize_bytes` > 0         | `rlimit-fsize` |
///
/// With no per-exec policy the execution runs under the helper's fd-3
/// base, whose conditional layers this actor cannot see; only the
/// unconditional four are required then.
pub fn required_layers(policy: Option(SandboxPolicy)) -> List(String) {
  required_layers_for(policy, ffi_os.os_name())
}

/// The enforcement matrix selected by the helper that will execute the
/// request. Tests and remote helpers may not run the same backend as the
/// broker VM, so the hello frame, not the VM's operating system, chooses it.
pub fn required_layers_for_features(
  policy: Option(SandboxPolicy),
  features: List(String),
) -> List(String) {
  let os_name = case list.contains(features, "seatbelt") {
    True -> "darwin"
    False -> "linux"
  }
  required_layers_for(policy, os_name)
}

// The mandatory half of a demand. PlatformEnforcement keeps the Darwin
// resource layers out of this list because ADR-006 proves they are not
// platform guarantees; `tolerated_layers_for_demand` still requires an
// explicit applied-or-skipped report for each one.
fn required_layers_for_demand(
  policy: Option(SandboxPolicy),
  features: List(String),
  demand: EnforcementDemand,
) -> List(String) {
  let required = required_layers_for_features(policy, features)
  let tolerated = tolerated_layers_for_demand(policy, features, demand)
  list.filter(required, fn(layer) { !list.contains(tolerated, layer) })
}

// Darwin's documented gaps are tolerated only by PlatformEnforcement and
// only when the report names them. Linux has no corresponding relaxation:
// its platform-strict demand is byte-for-byte as strict as full enforcement.
fn tolerated_layers_for_demand(
  policy: Option(SandboxPolicy),
  features: List(String),
  demand: EnforcementDemand,
) -> List(String) {
  case demand, list.contains(features, "seatbelt") {
    PlatformEnforcement, True -> {
      let resource = case policy {
        None -> []
        Some(policy) ->
          list.flatten([
            optional_layer(policy.limits.mem_bytes > 0, "rlimit-address-space"),
            optional_layer(policy.limits.pids > 0, "rlimit-processes"),
          ])
      }
      list.append(resource, ["darwin-process-lifecycle"])
    }
    _, _ -> []
  }
}

/// `required_layers` with an explicit OS name, so both platform matrices are
/// testable on either CI host.
pub fn required_layers_for(
  policy: Option(SandboxPolicy),
  os_name: String,
) -> List(String) {
  let base = base_layers_for(os_name)
  case policy {
    None -> base
    Some(policy) ->
      list.flatten([
        base,
        network_layers_for(policy.network, os_name),
        resource_layers_for(policy.limits, os_name),
        optional_layer(policy.limits.cpu_s > 0, "rlimit-cpu"),
        optional_layer(policy.limits.fsize_bytes > 0, "rlimit-fsize"),
      ])
  }
}

fn base_layers_for(os_name: String) -> List(String) {
  case os_name {
    "darwin" -> ["seatbelt", "seatbelt-fs"]
    "linux" -> ["bwrap", "mounts", "landlock", "no-new-privs"]
    _ -> []
  }
}

fn network_layers_for(
  network: policy.NetworkPolicy,
  os_name: String,
) -> List(String) {
  case network {
    policy.NetworkOff | policy.NetworkProxy(..) ->
      case os_name {
        "darwin" -> ["seatbelt-net"]
        "linux" -> ["seccomp-net"]
        _ -> []
      }
    policy.NetworkFull -> []
  }
}

fn resource_layers_for(limits: policy.Limits, os_name: String) -> List(String) {
  case limits.mem_bytes > 0 || limits.pids > 0 {
    False -> []
    True ->
      case os_name {
        "darwin" ->
          list.flatten([
            optional_layer(limits.mem_bytes > 0, "rlimit-address-space"),
            optional_layer(limits.pids > 0, "rlimit-processes"),
          ])
        "linux" -> ["cgroup-v2"]
        _ -> []
      }
  }
}

fn optional_layer(enabled: Bool, layer: String) -> List(String) {
  case enabled {
    True -> [layer]
    False -> []
  }
}

/// The layers `required` asked for that `enforcement` does not show as
/// applied. Empty is the only acceptable answer to a `FullEnforcement`
/// demand; the entries are what a refusal names.
pub fn unapplied_layers(
  enforcement: List(String),
  required: List(String),
) -> List(String) {
  let applied =
    enforcement
    |> list.filter(fn(entry) { !string.starts_with(entry, skip_prefix) })
    |> list.map(layer_tag)
  list.filter(required, fn(layer) { !list.contains(applied, layer) })
}

// The layer a report entry speaks for, stripped of its detail: the tag
// runs to the first ":" or "=", so "landlock:abi=5" is the landlock
// layer and "mounts:ro=2,rw=1,..." is the mount layer, while a plain
// "seccomp-net" is its own tag.
fn layer_tag(entry: String) -> String {
  let head =
    string.split_once(entry, ":")
    |> result.map(pair.first)
    |> result.unwrap(entry)
  string.split_once(head, "=")
  |> result.map(pair.first)
  |> result.unwrap(head)
}

// Whether an exec_exit's enforcement report falls short of what the
// policy called for: the helper set the degraded bool (bwrap absent),
// any `skip:` entry says a layer was not applied, or a required layer
// is simply absent from the list. The list, not the bool, is the ground
// truth a FullEnforcement demand trusts — and absence counts against it
// exactly as a skip does.
fn degraded_report(
  enforcement: List(String),
  degraded: Bool,
  required: List(String),
) -> Bool {
  degraded
  || list.any(enforcement, fn(entry) { string.starts_with(entry, skip_prefix) })
  || unapplied_layers(enforcement, required) != []
}

// Platform enforcement is strict about the platform's real boundary and
// permissive only about the exact Darwin gaps ADR-006 names. A tolerated
// layer must still speak: accepting an omitted report would recreate #54's
// silent-stage-2 hole under a different demand.
fn platform_degraded_report(
  enforcement: List(String),
  degraded: Bool,
  required: List(String),
  tolerated: List(String),
) -> Bool {
  degraded
  || list.any(enforcement, fn(entry) {
    string.starts_with(entry, skip_prefix)
    && !list.contains(tolerated, report_layer_tag(entry))
  })
  || unapplied_layers(enforcement, required) != []
  || unreported_layers(enforcement, tolerated) != []
}

fn unreported_layers(
  enforcement: List(String),
  expected: List(String),
) -> List(String) {
  let reported = list.map(enforcement, report_layer_tag)
  list.filter(expected, fn(layer) { !list.contains(reported, layer) })
}

// `layer_tag` deliberately sees a skip as the `skip` tag because the full
// demand removes skipped entries before calling it. Platform enforcement
// also needs the name *inside* a skip so it can compare that name with its
// narrow tolerated set.
fn report_layer_tag(entry: String) -> String {
  case string.starts_with(entry, skip_prefix) {
    True -> layer_tag(string.drop_start(entry, string.length(skip_prefix)))
    False -> layer_tag(entry)
  }
}

// Pushes one inbound chunk through the pure deframer and applies
// whatever whole frames came out of it.
//
// The fault is weighed after the frames rather than before them: bytes
// that arrived ahead of the corruption are real and their frames are
// acted on, which is how a helper that dies mid-frame still delivers the
// `exec_exit` it managed to write.
fn handle_bytes(machine: Machine, bytes: BitArray) -> Machine {
  let framing.Pushed(deframer:, inbound:, fault:) =
    framing.push(machine.data.deframer, bytes)
  let machine = Machine(..machine, data: Data(..machine.data, deframer:))
  let machine = list.fold(inbound, machine, apply_inbound)
  case fault, machine.phase {
    _, Dead(..) -> machine
    None, _ -> machine
    Some(fault), _ -> mark_dead(machine, ChannelFault(fault:))
  }
}

// Applies one deframed item to the machine. Once the channel is dead
// further inbound items are dropped rather than acted on.
fn apply_inbound(machine: Machine, item: framing.Inbound) -> Machine {
  case machine.phase {
    Prepared | Dead(..) -> machine
    AwaitingHello | Idle(..) | Running(..) | Cancelling(..) | Finishing(..) ->
      case item {
        framing.Known(frame:) -> handle_frame(machine, frame)
        framing.UnknownInbound(id:, kind:) ->
          // Well-formed but unknown: answer in-band, keep the channel
          // (forward compatibility, mirrors the helper).
          send_frame(
            machine,
            framing.Frame(
              id:,
              body: framing.ErrorBody(code: "unknown_kind", message: kind),
            ),
          )
      }
  }
}

// Handles one well-formed frame. Returns the next machine;
// channel-fatal conditions mark it dead via `mark_dead`.
fn handle_frame(machine: Machine, frame: Frame) -> Machine {
  case frame.body {
    framing.ProtocolStart(..)
    | framing.ProtocolInput(..)
    | framing.ProtocolOutputConsumed(..) ->
      mark_dead(machine, ProtocolViolation("protocol_direction"))
    framing.ProtocolInputAccepted(execution_id:, ordinal:, frame_id:) ->
      protocol_input_ack(
        machine,
        frame.id,
        execution_id,
        ordinal,
        frame_id,
        None,
      )
    framing.ProtocolInputRefused(execution_id:, ordinal:, frame_id:, reason:) ->
      protocol_input_ack(
        machine,
        frame.id,
        execution_id,
        ordinal,
        frame_id,
        Some(reason),
      )
    framing.ProtocolOutput(
      execution_id:,
      ordinal:,
      stream:,
      data:,
      bytes:,
      disposition:,
    ) ->
      protocol_output(
        machine,
        frame.id,
        execution_id,
        ordinal,
        stream,
        data,
        bytes,
        disposition,
      )
    framing.ProtocolReusable(execution_id:) ->
      protocol_reusable(machine, frame.id, execution_id)
    framing.ProtocolExit(terminal:, disposition:) ->
      protocol_terminal(machine, frame.id, terminal, disposition)
    framing.Hello(proto:, peer: _, features:) ->
      handle_hello(machine, proto, features)
    framing.ExecOut(stream:, data:, bytes:, truncated:) ->
      handle_exec_out(machine, frame.id, stream, data, bytes, truncated)
    framing.ExecExit(
      code:,
      signal:,
      stdout_bytes:,
      stderr_bytes:,
      stdout_truncated:,
      stderr_truncated:,
      enforcement:,
      degraded:,
      wall_ms:,
      timed_out:,
      cancelled:,
    ) -> {
      let result =
        ExecResult(
          code:,
          signal:,
          stdout_bytes:,
          stderr_bytes:,
          stdout_truncated:,
          stderr_truncated:,
          enforcement:,
          degraded:,
          wall_ms:,
          timed_out:,
          cancelled:,
        )
      handle_exec_exit(machine, frame.id, result)
    }
    framing.Heartbeat -> handle_heartbeat_frame(machine, frame.id)
    framing.ErrorBody(code:, message:) ->
      handle_error_frame(machine, frame.id, code, message)

    // These kinds never flow helper-to-broker; a peer sending them is
    // broken or hostile, and the channel dies (spec §3.3 invariant 6).
    framing.ExecStart(..) ->
      mark_dead(machine, ProtocolViolation(kind: "exec_start"))
    framing.ExecStdin(..) ->
      mark_dead(machine, ProtocolViolation(kind: "exec_stdin"))
    framing.CapCall(..) ->
      mark_dead(machine, ProtocolViolation(kind: "cap_call"))
    framing.CapResult(..) ->
      mark_dead(machine, ProtocolViolation(kind: "cap_result"))

    // The hook pair belongs to the capability channel between a harness
    // and a persistent satellite (protocol-change/012); it never crosses
    // the exec channel in either direction, so a helper that sends one
    // is as broken as one that sends a `cap_call`.
    framing.HookCall(..) ->
      mark_dead(machine, ProtocolViolation(kind: "hook_call"))
    framing.HookResult(..) ->
      mark_dead(machine, ProtocolViolation(kind: "hook_result"))
    framing.Cancel -> mark_dead(machine, ProtocolViolation(kind: "cancel"))
    framing.Shutdown -> mark_dead(machine, ProtocolViolation(kind: "shutdown"))
  }
}

// The hello is legal exactly once, in exactly one state. A second one —
// or one in any state past the handshake — is a peer that has lost the
// protocol, and the channel dies.
fn handle_hello(
  machine: Machine,
  proto: Int,
  features: List(String),
) -> Machine {
  case machine.phase {
    // A version disagreement is not a malformed frame: the hello parsed,
    // and the two numbers in it are the diagnosis. Carrying both is what
    // turns "the sandbox channel broke protocol" into a sentence naming
    // the stale binary and its remedy.
    AwaitingHello ->
      case proto == framing.exec_protocol_version {
        False ->
          mark_dead(
            machine,
            ProtocolVersionMismatch(
              helper: proto,
              broker: framing.exec_protocol_version,
            ),
          )
        True -> complete_handshake(machine, features)
      }

    Prepared
    | Idle(..)
    | Running(..)
    | Cancelling(..)
    | Finishing(..)
    | Dead(..) -> mark_dead(machine, ProtocolViolation(kind: "hello"))
  }
}

// Answers the helper's hello, unlinks the fd-3 policy file (proof it was
// read), and releases anything blocked on `await_ready`.
//
// The move to `Idle` at the end is also what retires the handshake
// deadline: it is a state timeout on `AwaitingHello`, so leaving that
// state is the cancellation and a fire that raced this transition is
// dropped by weft's timer book rather than handled.
fn complete_handshake(machine: Machine, features: List(String)) -> Machine {
  // Contract: the broker's hello precedes any other frame it sends. The
  // helper has proven it read the fd-3 policy, so the temp file can be
  // unlinked now.
  let #(data, id) = fresh_id(machine.data)
  let machine =
    send_frame(
      Machine(..machine, data:),
      framing.Frame(
        id:,
        body: framing.Hello(
          proto: framing.exec_protocol_version,
          peer: "broker",
          features: [framing.protocol_credit_feature],
        ),
      ),
    )

  // A hello the channel refused to carry has already settled every
  // waiter and closed the transport. Promoting that to `Idle` would
  // resurrect a helper with no channel behind it, and the pool would
  // lend it out.
  //
  // Any `AwaitReady` postponed during the handshake replays against this
  // move to `Idle` — weft delivers it ahead of the mailbox, after this
  // function returns — and the `Idle(..), AwaitReady` arm in `handle`
  // answers it with `features`. Nothing here has to flush a queue.
  case machine.phase {
    Prepared | Dead(..) -> machine
    AwaitingHello | Idle(..) | Running(..) | Cancelling(..) | Finishing(..) -> {
      // The features are kept in the data as well as in the phase because a
      // retirement verdict is asked for in `Dead`, where the phase no
      // longer has them and the verdict needs to know about bwrap.
      let data = Data(..run_cleanup(machine.data), hello_features: features)
      Machine(phase: Idle(features:), data:)
    }
  }
}

fn handle_exec_out(
  machine: Machine,
  id: Int,
  stream: OutputStream,
  data: BitArray,
  bytes: Int,
  truncated: Bool,
) -> Machine {
  case machine.data.protocol {
    Some(_) ->
      mark_dead(machine, ProtocolViolation("ordinary_output_on_protocol"))
    None -> handle_ordinary_out(machine, id, stream, data, bytes, truncated)
  }
}

fn handle_ordinary_out(
  machine: Machine,
  id: Int,
  stream: OutputStream,
  data: BitArray,
  bytes: Int,
  truncated: Bool,
) -> Machine {
  case running_with_id(machine.phase, id) {
    Some(exec) -> {
      send_execution_event(
        exec.events,
        Output(stream:, data:, total_bytes: bytes, truncated:),
      )
      machine
    }

    // Stale output from a settled or unknown execution: dropped.
    None -> machine
  }
}

fn handle_exec_exit(machine: Machine, id: Int, result: ExecResult) -> Machine {
  case machine.data.protocol {
    Some(_) ->
      mark_dead(machine, ProtocolViolation("ordinary_terminal_on_protocol"))
    None -> handle_ordinary_exit(machine, id, result)
  }
}

fn handle_ordinary_exit(
  machine: Machine,
  id: Int,
  result: ExecResult,
) -> Machine {
  use exec <- settle(machine, id)

  // The enforcement report is ground truth: a degraded run against a
  // FullEnforcement demand settles as a failure even though the helper
  // looked healthy at hello. `skip:` entries count as degradation
  // whatever the bool says — the bool only tracks the bwrap layer — and
  // so does a required layer the report never mentions, which is how a
  // dead stage 2 used to pass (#54).
  case
    exec.demand,
    degraded_report(result.enforcement, result.degraded, exec.required),
    platform_degraded_report(
      result.enforcement,
      result.degraded,
      exec.required,
      exec.tolerated,
    )
  {
    FullEnforcement, True, _ -> Failed(failure: DegradedExecution(result:))
    PlatformEnforcement, _, True -> Failed(failure: DegradedExecution(result:))
    FullEnforcement, False, _ -> Exited(result:)
    PlatformEnforcement, _, False -> Exited(result:)
    BestEffort, _, _ -> Exited(result:)
  }
}

fn handle_heartbeat_frame(machine: Machine, id: Int) -> Machine {
  case list.key_pop(machine.data.pending_heartbeats, id) {
    Ok(#(reply, pending_heartbeats)) -> {
      process.send(reply, Ok(Nil))
      Machine(..machine, data: Data(..machine.data, pending_heartbeats:))
    }

    // Not a caller probe: it answers the idle tick.
    Error(Nil) ->
      Machine(..machine, data: Data(..machine.data, tick_outstanding: False))
  }
}

fn handle_error_frame(
  machine: Machine,
  id: Int,
  code: String,
  message: String,
) -> Machine {
  use _exec <- settle(machine, id)
  Failed(failure: RefusedByHelper(code:, message:))
}

// Settles the running execution with `event` and returns the machine to
// `Idle`, if `id` is the execution's own.
//
// This is where a cancel escalation is called off, and it does so by
// arriving at `Idle` rather than by cancelling anything: the deadline is
// a state timeout on `Cancelling`, so the state change *is* the
// cancellation, and a deadline that fired into the mailbox a moment
// before is recognised as stale and dropped. The hand-rolled
// `cancel_pending_timer` this replaces had to be remembered at all three
// settle sites, and the timer's own message had to carry an execution id
// so its handler could tell a stale fire from a live one.
//
// An id that correlates to nothing is dropped: stale output from a
// settled execution, or the id 0 that usually precedes a channel close,
// where the close itself settles what is left.
fn settle(
  machine: Machine,
  id: Int,
  event: fn(RunningExec) -> ExecEvent,
) -> Machine {
  case machine.phase {
    Running(features:, exec:) | Cancelling(features:, exec:) ->
      case exec.id == id {
        True -> {
          send_execution_event(exec.events, event(exec))
          Machine(..machine, phase: Idle(features:))
        }
        False -> machine
      }
    Prepared | AwaitingHello | Idle(..) | Finishing(..) | Dead(..) -> machine
  }
}

// The running execution, when `id` correlates to it. `Cancelling` counts:
// output keeps arriving between the TERM and the exit that answers it.
fn running_with_id(phase: Phase, id: Int) -> Option(RunningExec) {
  case phase {
    Running(exec:, ..) | Cancelling(exec:, ..) ->
      case exec.id == id {
        True -> Some(exec)
        False -> None
      }
    Prepared | AwaitingHello | Idle(..) | Finishing(..) | Dead(..) -> None
  }
}

fn fresh_id(data: Data) -> #(Data, Int) {
  let id = data.next_id
  #(Data(..data, next_id: id + 1), id)
}

// --- sending and death --------------------------------------------------

// Encodes and writes one frame; on any write failure the channel is
// declared dead in the returned machine.
fn send_frame(machine: Machine, frame: Frame) -> Machine {
  case framing.encode(frame) {
    // Unencodable frames are broker bugs (ids are minted positive,
    // bodies are typed); settle as SendFailed rather than crash.
    Error(_) -> mark_dead(machine, SendFailed)
    Ok(bytes) ->
      case transport_send(machine.data.wire_out, bytes) {
        Ok(Nil) -> machine

        // A failed write is the port reporting that it has closed.
        Error(Nil) -> mark_gone(machine, SendFailed)
      }
  }
}

// Writes a frame and hands the machine back to weft as a step.
//
// `advance` is what makes a failed write terminal without a second code
// path: a successful write leaves the phase alone, so the step is not a
// state change and every armed deadline survives it, while a failed one
// has already moved the phase to `Dead` and the same call is that move.
fn send_or_die(
  machine: Machine,
  frame: Frame,
) -> state_machine.Next(Phase, Data, Msg) {
  advance(send_frame(machine, frame))
}

fn transport_send(wire_out: Wire, bytes: BitArray) -> Result(Nil, Nil) {
  case wire_out {
    WireUnopened -> Error(Nil)
    WirePort(port:, os_pid: _, cleanup: _) -> ffi_port.port_send(port, bytes)
    WireChannel(send:, close: _) -> {
      send(bytes)
      Ok(Nil)
    }
  }
}

// Discards a channel that has already failed, and says what is left of its
// exit witness, which is nothing: the port is closed, so no status can be
// selected from it any more.
fn close_transport(wire_out: Wire) -> Retirement {
  case wire_out {
    WireUnopened -> Nil
    WirePort(port:, os_pid: _, cleanup: _) -> ffi_port.close_port(port)
    WireChannel(send: _, close:) -> close()
  }
  LostExit
}

// The witnessed kill: SIGKILL the OS process and keep the port.
//
// Closing the port first, as this once did, discards the very event the
// kill produces. Erlang delivers `{exit_status, N}` to the owner of a port
// whose child was killed by a signal, and only while the port is open, so
// the kill leaves the machine `PendingExit(AfterKill(..))` and waits for that
// status instead of throwing it away. The port's OS pid is the helper itself
// and not the shell that opened fd 3 for it, because that shell `exec`s the
// helper.
//
// A channel transport has no signal to send, and its `close` is the whole
// of its kill. A fake can still report an exit afterwards on its wire, which
// is what tests use to drive the verdict.
//
// A port whose pid is unknown cannot be killed from here, and leaving it
// open would leave a live helper that nothing is waiting on. That case
// falls back to closing the port: the helper reads end of file and retires
// its own jail, as it did before, and the proof is lost.
//
// The `kill -KILL` goes to a pid that `erl_child_setup` may already have
// reaped, so a pid reused in that window would be signalled instead. The
// retained port neither widens nor narrows that window.
fn kill_transport(wire_out: Wire, exposure: Exposure) -> Retirement {
  case wire_out {
    WireUnopened -> LostExit
    WirePort(port: _, os_pid: Some(pid), cleanup: _) if pid > 1 -> {
      ffi_port.kill_os_process(pid)
      PendingExit(AfterKill(exposure:))
    }
    WirePort(port:, os_pid: _, cleanup: _) -> {
      ffi_port.close_port(port)
      LostExit
    }
    WireChannel(send: _, close:) -> {
      close()
      PendingExit(AfterKill(exposure:))
    }
  }
}

fn run_cleanup(data: Data) -> Data {
  case data.cleaned {
    True -> data
    False -> {
      case data.wire_out {
        WireUnopened -> Nil
        WirePort(port: _, os_pid: _, cleanup:) -> cleanup()
        WireChannel(send: _, close: _) -> Nil
      }
      Data(..data, cleaned: True)
    }
  }
}

// Marks the helper dead and settles everything in flight in-band. The
// machine stays alive answering requests with the failure, so callers
// racing the death get errors, not crashed calls; the pool retires it.
//
// `Dead` is absorbing, and the first arm is what makes it so: a second
// failure arriving behind the first — a channel close chasing a framing
// fault — must not re-notify callers who have already been told.
//
// This is the entry for every failure that finds the port still open: a
// missed cancel deadline, a handshake that never completed, a silent
// heartbeat, a framing fault, a frame the helper had no business sending,
// and a frame the broker could not encode (nothing was written, so the
// port is as open as it was). Each kills the helper and keeps the port,
// which leaves it `PendingExit(AfterKill(..))`, tagged with the jail the
// phase it died in had, so the kill's exit status can still be selected. A
// write that failed is the other case, and `mark_gone` takes it.
fn mark_dead(machine: Machine, failure: ExecFailure) -> Machine {
  case machine.phase {
    Prepared -> Machine(Dead(failure, NoNativeResource), machine.data)
    Dead(..) -> machine
    AwaitingHello | Idle(..) | Running(..) | Cancelling(..) | Finishing(..) -> {
      let exposure = exposure_of(machine.phase)
      bury(machine, failure, kill_transport(_, exposure))
    }
  }
}

// `mark_dead` for a write that failed. The port reports a failed write only
// once it has closed, but a closed port is not an exit status lost: the port
// sends `{exit_status, S}` first and closes after it, so a helper that died
// on its own and then met a write leaves its status in the actor's mailbox
// ahead of the failure being handled. Throwing the wait away here, as this
// once did, dropped that status and cost the pool the slot for the life of
// the session.
//
// So the machine waits for the status, as it does after a kill, and there is
// simply nothing to kill and nothing to close: the port is already gone.
// The exit is `Unprompted`, judged by the jail of the phase the helper was
// in, which is how a helper that dies by itself is judged everywhere else.
// A status that was never queued, because the port was closed from outside
// or failed without one, becomes `LostExit` when the witness timeout fires,
// so nothing waits for ever.
//
// A `ChannelTransport` cannot fail a write, so only a real port reaches this;
// `real_helper_failed_write_keeps_a_queued_status_test` queues a real exit
// status behind a write and `real_helper_failed_write_loses_the_proof_test`
// closes a real helper's port from outside.
fn mark_gone(machine: Machine, failure: ExecFailure) -> Machine {
  case machine.phase {
    Prepared -> Machine(Dead(failure, NoNativeResource), machine.data)
    Dead(..) -> machine
    AwaitingHello | Idle(..) | Running(..) | Cancelling(..) | Finishing(..) -> {
      let exposure = exposure_of(machine.phase)
      bury(machine, failure, fn(_) { PendingExit(Unprompted(exposure:)) })
    }
  }
}

// Settles everyone waiting, discards the channel in the way `discard`
// says, and records what that left of the exit witness.
fn bury(
  machine: Machine,
  failure: ExecFailure,
  discard: fn(Wire) -> Retirement,
) -> Machine {
  let data = notify_death(machine, failure)
  let retirement = discard(data.wire_out)
  Machine(phase: Dead(failure:, retirement:), data: run_cleanup(data))
}

// `mark_dead` as a step. The move to `Dead` is a real state change, so
// it takes whichever deadline the phase being left had armed with it.
fn die(
  machine: Machine,
  failure: ExecFailure,
) -> state_machine.Next(Phase, Data, Msg) {
  advance(mark_dead(machine, failure))
}

// Tells everything waiting on this helper that it has failed, and
// returns the data with those queues emptied.
//
// The execution in flight needs no timer cancelled on its way out. It
// lives in the state, and the caller's move to `Dead` is what takes a
// pending cancel escalation with it — the deletion this port is for.
//
// An `AwaitReady` postponed during the handshake needs no flush here
// either: this move to `Dead` is exactly the state change weft replays
// it against, and the `Dead(..), AwaitReady` arm in `handle` answers it
// with `failure`.
fn notify_death(machine: Machine, failure: ExecFailure) -> Data {
  case machine.phase {
    Running(exec:, ..) | Cancelling(exec:, ..) | Finishing(exec:, ..) ->
      send_execution_event(exec.events, Failed(failure:))
    Prepared | AwaitingHello | Idle(..) | Dead(..) -> Nil
  }
  list.each(machine.data.pending_heartbeats, fn(pending) {
    process.send(pending.1, Error(failure))
  })
  Data(..machine.data, pending_heartbeats: [])
}

// --- what this host's helper can be asked to do --------------------------

/// Whether `loom-exec` has a jail for the operating system it will run
/// on. Not a probe of the kernel: the question is whether Loom has a
/// confinement implementation for this OS at all, which is a fact about
/// the helper build and mirrors its own `jail.PlatformFor`.
pub type HostPlatform {
  /// Loom has a jail here. The helper serves with no extra argument,
  /// and a missing kernel layer is reported as a skip, not a refusal.
  JailedHost

  /// Loom has no jail here (the Windows sandbox is WP-H phase 3 and remains
  /// unbuilt). `loom-exec` refuses to serve without `--allow-unenforced`, and
  /// with it confines nothing at all.
  UnjailedHost(os_name: String)
}

/// The platform this VM — and therefore the helper it spawns — runs on.
pub fn host_platform() -> HostPlatform {
  host_platform_for(ffi_os.os_name())
}

/// The pure decision, taking `os:type/0`'s name so the answers no Linux
/// host can reach are still testable from Linux. Kept deliberately in step
/// with the helper's own `PlatformFor`: Linux is phase 1, macOS is phase 2,
/// and Windows remains unimplemented phase 3.
pub fn host_platform_for(os_name: String) -> HostPlatform {
  case os_name {
    "linux" | "darwin" -> JailedHost
    other -> UnjailedHost(os_name: other)
  }
}

/// The extra helper arguments that let `loom-exec` serve on a platform
/// with no jail — and `[]` everywhere else.
///
/// This is the only place `--allow-unenforced` should come from. The
/// flag is not a degraded-mode switch: on a host where Loom *has* a
/// jail, a missing bwrap or Landlock is reported honestly and the
/// broker's own `FullEnforcement` demand decides what to do about it.
/// Passing the flag there would silence a report instead of a refusal.
pub fn unenforced_helper_args(platform: HostPlatform) -> List(String) {
  case platform {
    JailedHost -> []
    UnjailedHost(..) -> ["--allow-unenforced"]
  }
}

/// The marker every declared platform skip carries. `.github/declared-skips`
/// matches on it, so a suite that stops needing to skip stops matching
/// and fails the census — which is the point.
pub const unjailed_skip_marker = "no loom-exec jail for this platform"

/// Why a suite that spawns a real helper must skip rather than run, or
/// `None` when it may run.
///
/// Running under `--allow-unenforced` is the other option and is not
/// what these suites should do: they exercise the sandbox, and a run
/// with nothing enforced would report success for a jail that was never
/// built. Skipping with a reason a machine can check is the honest half
/// of that trade.
pub fn unjailed_skip_reason(platform: HostPlatform) -> Option(String) {
  case platform {
    JailedHost ->
      jailed_session_skip_reason(
        ffi_os.os_name(),
        envoy.get(jail_scratch_variable),
      )
    UnjailedHost(os_name:) ->
      Some(
        unjailed_skip_marker
        <> " ("
        <> os_name
        <> "): loom-exec refuses to serve without --allow-unenforced, and "
        <> "running unenforced would prove nothing about a jail that does "
        <> "not exist",
      )
  }
}

/// The variable `loom-exec` sets in every jailed execution that has a
/// private scratch directory, and the one fact a process can read to learn
/// it is already inside a Loom jail.
const jail_scratch_variable = "LOOM_SCRATCH_DIR"

/// The marker a suite carries when it declines to run because the test
/// process is itself inside a Loom jail. It is deliberately absent from
/// `.github/declared-skips`: CI is never nested, so a declaration would go
/// stale and fail the census.
pub const jailed_session_skip_marker = "already inside a Loom/Seatbelt jail"

/// Why a real-helper suite cannot run because this process is inside a
/// Loom jail, or `None` when it can.
///
/// macOS refuses a second `sandbox_apply` from a process that already has a
/// profile (`Operation not permitted`, exit 71), so the nested helper can
/// never confine anything and every suite that spawns one fails, first on
/// an unwritable scratch parent and then on the refusal itself. Reporting
/// that as a skip keeps a jailed session from spending its time proving the
/// failures are environmental. The decision is limited to Darwin: Linux
/// nests bwrap and Landlock on hosts that allow it, and CI is arbiter there.
/// `scratch` is the `LOOM_SCRATCH_DIR` lookup, taken as an argument so the
/// decision is testable without touching the process environment.
///
/// ## Examples
///
/// ```gleam
/// jailed_session_skip_reason("darwin", Ok("/private/var/folders/x/T/loom"))
/// // -> Some("already inside a Loom/Seatbelt jail: ...")
/// ```
pub fn jailed_session_skip_reason(
  os_name: String,
  scratch: Result(String, Nil),
) -> Option(String) {
  case os_name, scratch {
    "darwin", Ok(directory) if directory != "" ->
      Some(
        jailed_session_skip_marker
        <> ": the kernel refuses a nested sandbox_apply, so the real-helper "
        <> "suites cannot run here; run them from an unjailed shell or in CI",
      )
    _other_host, _scratch -> None
  }
}

// --- spawning the real helper -------------------------------------------

/// Configuration for spawning a real `loom-exec` helper process.
pub type SpawnConfig {
  SpawnConfig(
    /// Absolute path to the `loom-exec` binary.
    helper_path: String,
    /// The POSIX shell used for the fd-3 redirection (usually
    /// "/bin/sh").
    shell_path: String,
    /// The base policy delivered on fd 3.
    base_policy: SandboxPolicy,
    /// Extra arguments appended to the helper's own command line, after
    /// the fd-3 redirection is in place. Almost always `[]`.
    ///
    /// Two things need it and neither can go through the environment: a
    /// delegated cgroup base (`--cgroup-base DIR`), and, on a platform
    /// `loom-exec` has no jail for, the `--allow-unenforced` opt-out
    /// without which the helper refuses to serve at all. Erlang ports
    /// cannot set a child's environment, so the command line is the only
    /// channel the broker has.
    ///
    /// `--allow-unenforced` belongs here only on an *unsupported*
    /// platform, never on a merely degraded one: a Linux host missing
    /// bwrap still enforces something and could enforce the rest, while
    /// a build with no jail enforces nothing. `unenforced_helper_args`
    /// draws that line; do not hand-roll it.
    helper_args: List(String),
    /// Directory for the transient mode-0600 policy file (created
    /// mode 0700).
    tmp_dir: String,
    /// See `HelperConfig`.
    handshake_timeout_ms: Int,
    /// See `HelperConfig`.
    cancel_grace_ms: Int,
    /// See `HelperConfig`.
    heartbeat_interval_ms: Int,
  )
}

/// Why spawning a helper failed.
pub type SpawnError {
  /// The base policy could not be encoded.
  PolicyUnencodable(error: msgpack.EncodeError)

  /// The transient policy file could not be written.
  PolicyFileFailed

  /// The OS process could not be started.
  PortOpenFailed

  /// The broker-side actor failed to start.
  ActorFailed(error: actor.StartError)

  /// The helper started but its handshake failed.
  HandshakeFailed(failure: ExecFailure)
}

/// Spawns a real helper: writes the base policy to a private temp file,
/// starts `loom-exec` through `/bin/sh -c 'exec 3<"$2" "$1"'` so the
/// policy arrives on fd 3, and waits for the handshake. The temp file
/// is unlinked as soon as the helper's hello arrives.
pub fn spawn_helper(config: SpawnConfig) -> Result(Helper, SpawnError) {
  use helper <- result.try(prepare_helper(config))
  begin(helper)
  case await_ready(helper, waiting: helper.handshake_wait) {
    Ok(_) -> Ok(helper)
    Error(failure) -> {
      shutdown(helper)
      Error(HandshakeFailed(failure))
    }
  }
}

/// Prepares a native helper without creating its policy file or OS process.
/// Pools use this factory so acquisition follows inventory publication.
///
/// ## Examples
///
/// `start_pool(size: 2, spawn: fn() { prepare_helper(config) })` owns each
/// helper before its handshake starts.
pub fn prepare_helper(config: SpawnConfig) -> Result(Helper, SpawnError) {
  let transport =
    DeferredTransport(fn() {
      native_transport(config) |> result.map_error(string.inspect)
    })
  prepare(HelperConfig(
    transport:,
    handshake_timeout_ms: config.handshake_timeout_ms,
    cancel_grace_ms: config.cancel_grace_ms,
    kill_witness_ms:,
    heartbeat_interval_ms: config.heartbeat_interval_ms,
  ))
  |> result.map_error(ActorFailed)
}

// Runs only inside the already-published helper owner. The janitor covers
// owner death after policy-file creation, including an untrappable kill.
fn native_transport(config: SpawnConfig) -> Result(Transport, SpawnError) {
  use policy_bytes <- result.try(
    policy.encode(config.base_policy)
    |> result.map_error(fn(error) { PolicyUnencodable(error:) }),
  )
  let file_name =
    "policy-"
    <> bit_array.base16_encode(ffi_crypto.strong_random_bytes(8))
    <> ".msgpack"
  use policy_path <- result.try(
    ffi_port.write_private_file(config.tmp_dir, file_name, policy_bytes)
    |> result.replace_error(PolicyFileFailed),
  )
  let cleanup = fn() { ffi_port.delete_file(policy_path) }
  watch_cleanup(process.self(), cleanup)

  // $0 is a display name; $1 the helper binary; $2 the policy file;
  // everything after that is the helper's own arguments. Positional
  // parameters avoid every quoting pitfall in the paths, and `shift 2`
  // leaves "$@" holding exactly the extra arguments — empty when there
  // are none, which expands to nothing rather than to an empty word.
  let args =
    list.append(
      [
        "-c",
        "helper=$1; policy=$2; shift 2; exec 3<\"$policy\" \"$helper\" \"$@\"",
        "loom-exec",
        config.helper_path,
        policy_path,
      ],
      config.helper_args,
    )
  Ok(PortTransport(executable: config.shell_path, args:, cleanup:))
}

/// Spawns a janitor process that runs `cleanup` when `pid` dies, for
/// whatever reason — including a brutal kill that skips every in-actor
/// path. `cleanup` must be idempotent: the watched process usually also
/// cleans up itself on its graceful paths. A whole-VM SIGKILL still
/// skips this (nothing survives to run it); see the module doc.
@internal
pub fn watch_cleanup(pid: Pid, cleanup: fn() -> Nil) -> Nil {
  process.spawn_unlinked(fn() {
    let monitor = process.monitor(pid)
    let _down =
      process.new_selector()
      |> process.select_specific_monitor(monitor, fn(down) { down })
      |> process.selector_receive_forever
    cleanup()
  })
  Nil
}

// --- the pool -----------------------------------------------------------

/// A fixed-size pool that owns helpers across checkout and checkin. A
/// helper occupies capacity until native exit and normal BEAM retirement
/// are confirmed. Replacement helpers are spawned lazily after that proof.
pub opaque type Pool {
  Pool(subject: Subject(PoolMsg), pid: Pid)
}

/// The pool actor's message type. Opaque.
pub opaque type PoolMsg {
  Checkout(reply: Subject(Result(Helper, CheckoutError)))
  Checkin(helper: Helper)
  PrepareBorrowed(
    helper: Helper,
    observer: TargetedObserver,
    reply: Subject(Result(Nil, RetirementFailure)),
  )
  RetireBorrowed(helper: Helper, registration: Subject(Nil))
  StopPool
  AwaitPoolRetirement(reply: Subject(Result(Nil, RetirementFailure)))
  HelperRetired(pid: Pid, outcome: Result(Nil, RetirementFailure))
  HelperOwnerGone(pid: Pid, reason: process.ExitReason)
  PoolLinkedExit(pid: Pid)
  ForgetPool
  QueryCensus(reply: Subject(PoolCensus))
  QueryCustody(reply: Subject(PoolCustody))
}

/// A count of the pool's inventory by custody, taken at one instant by the
/// pool actor itself. It is the pool's own answer rather than anything
/// reconstructed from outside, so the six numbers always describe one
/// consistent inventory.
///
/// `available + borrowed + draining + retiring + unconfirmed` is the
/// number of entries the pool holds, and it is never more than `size`: an
/// entry occupies its slot until it leaves the inventory, and only the
/// proof of retirement removes it.
///
/// `spawned` and `retired` are the pool's lifetime churn, two monotone
/// counters beside the six gauges: every helper the pool has ever put in
/// its inventory, and every one that has left it through both retirement
/// boundaries. `spawned - retired` is the entries held now, so the pair
/// shows a pool that is replacing helpers faster than it should without
/// any history being kept.
pub type PoolCensus {
  PoolCensus(
    /// The pool's configured ceiling on entries.
    size: Int,
    /// Idle and lendable, subject to the readiness probe at checkout.
    available: Int,
    /// Lent to a borrower. A checkout reply lost to its borrower's deadline
    /// still counts here, because custody never left the pool.
    borrowed: Int,
    /// Shutdown requested; native exit not yet reported.
    draining: Int,
    /// Native exit confirmed; the helper actor is still to exit normally.
    retiring: Int,
    /// Retirement could not be established, so the slot is held for the
    /// life of the pool.
    unconfirmed: Int,
    /// Helpers ever added to the inventory, including one whose handshake
    /// then failed. A spawn the transport refused adds nothing.
    spawned: Int,
    /// Helpers that left the inventory with both retirement boundaries
    /// proved. An unconfirmed helper never counts here.
    retired: Int,
  )
}

/// How the pool stands to lend one helper. The pool's private
/// `Availability` says the same thing with the retirement detail folded in;
/// this is the lending half alone, so an observer can read lending and
/// custody as two separate questions.
pub type Lending {
  /// Idle and lendable, subject to the readiness probe at checkout.
  Lendable

  /// Lent to a borrower, who will check it in.
  Lent

  /// Being retired, or held unconfirmed. It will not be lent again.
  Withdrawn
}

/// What the pool can show of one helper's native resource, in the
/// vocabulary protocol-014 gives the retirement evidence. It is derived from
/// the pool's own books and never asks the helper, so a wedged helper cannot
/// block the answer.
///
/// The helper machine has a fourth state, no native resource ever acquired,
/// and it is not here on purpose: the pool begins a helper the moment it
/// inventories it, so an entry always holds, or held, an OS process. The
/// native exit status behind `Retired` is not kept either: the pool records
/// the verdict (`Ok`) and not the status that produced it.
pub type Custody {
  /// The helper's OS process is live and the pool is responsible for it.
  Held

  /// Shutdown was requested and the native exit has not been reported.
  Retiring

  /// Native exit was witnessed as clean; only the BEAM owner's normal exit
  /// is still awaited before the slot is freed.
  Retired

  /// Retirement could not be established, so the helper's jail may still be
  /// running and the slot is held for the life of the pool. `reason` is the
  /// failure the pool recorded.
  CleanupUnconfirmed(reason: RetirementFailure)

  /// The channel was discarded before the native exit could be observed,
  /// permanently. A subset of unconfirmed cleanup, named separately because
  /// no later event can repair it.
  ProofLost
}

/// One inventoried helper as an observer sees it.
pub type HelperView {
  HelperView(
    /// The helper actor's pid.
    pid: Pid,
    /// Which spawn this helper was, counting from one. With the pid it is
    /// the helper's generation for a reader; it is introspection and not a
    /// fence, because nothing compares it to anything.
    ordinal: Int,
    /// Whether the helper can be lent.
    lending: Lending,
    /// What is known of its native resource.
    custody: Custody,
    /// The features the helper said in its hello, as the pool received them
    /// when the handshake completed. Empty means unknown: a helper whose
    /// handshake has not finished has not said, and a helper that said
    /// nothing is indistinguishable from it.
    features: List(String),
  )
}

/// The pool's census and a view of each entry it counts, taken by the pool
/// actor in one step so the two describe one instant. `helpers` is in spawn
/// order, newest last, and is never longer than `census.size`.
pub type PoolCustody {
  PoolCustody(
    /// The six gauges and two counters over the same inventory.
    census: PoolCensus,
    /// One view per inventoried helper.
    helpers: List(HelperView),
  )
}

/// Why a checkout was refused.
pub type CheckoutError {
  /// Every slot is borrowed or still held by an unreaped helper.
  ///
  /// `size` is how many of those slots can still come back to lending:
  /// the pool's configured size while the occupants are merely lent out
  /// or draining, and smaller once a slot is held by a helper whose
  /// retirement could not be confirmed, since nothing ever clears one of
  /// those. **Zero means waiting cannot help**, which is what separates
  /// congestion from a pool that has run out of helpers it can ever
  /// lend: `broker.congested` naps and retries on a positive count and
  /// refuses a zero at once, instead of spending a caller's whole
  /// clearance budget re-asking a question whose answer cannot change.
  AllBusy(size: Int)

  /// A fresh helper could not be spawned.
  SpawnFailed(error: SpawnError)

  /// The pool itself did not answer, or was not alive to be asked. It
  /// is deliberately not `AllBusy`: a full pool is congestion that
  /// clears as running executions end, and waiting is the right
  /// response to it, while this clears only if the pool recovers and
  /// waiting on it spends a caller's whole budget to learn nothing. A
  /// borrower that cannot tell the two apart cannot choose.
  PoolUnavailable
}

type PoolState {
  PoolState(
    size: Int,
    spawn: fn() -> Result(Helper, SpawnError),
    entries: List(PoolEntry),
    commands: Subject(PoolMsg),
    parent: Pid,
    // Lifetime counters. `spawned` doubles as the ordinal of the next
    // helper; both only grow, so they need no cap.
    spawned: Int,
    retired: Int,
  )
}

// This is the pool's one canonical inventory. Borrowing changes admission,
// never custody, so even a checkout reply lost to a deadline stays owned.
type PoolEntry {
  PoolEntry(
    helper: Helper,
    monitor: process.Monitor,
    availability: Availability,
    targeted: Option(TargetedObserver),
    // Which spawn this was, from one. Introspection only.
    ordinal: Int,
    // The hello features `await_ready` answered at spawn; empty until then.
    features: List(String),
  )
}

// One original send-only observer survives both retirement boundaries. Its
// registration subject binds a retirement door to this concrete borrow.
type TargetedObserver {
  TargetedObserver(
    registration: Subject(Nil),
    completed: fn(Result(Nil, RetirementFailure)) -> Nil,
  )
}

/// A retirement door for one originally observed borrow, never a lookup handle.
pub opaque type BorrowedRetirement {
  BorrowedRetirement(pool: Pool, helper: Helper, registration: Subject(Nil))
}

/// Where one inventoried helper stands with respect to lending and to
/// custody. The pool's custody model in five states: the first two are
/// the ordinary lending cycle, the middle two are the two retirement
/// boundaries protocol-014 demands in order, and the last is the
/// terminal state of a helper that cleared neither.
type Availability {
  /// Idle and lendable, subject to the readiness probe at checkout.
  Available

  /// Lent to a borrower. Custody is unchanged: a checkout reply lost to
  /// the borrower's deadline leaves the helper here, owned and counted.
  Borrowed

  /// Shutdown and `AwaitRetirement` have been sent; the first boundary,
  /// native exit, has not been reported yet.
  Draining

  /// Native exit status 0 was reported and `ForgetRetired` was sent. The
  /// entry leaves the inventory only on the second boundary: the
  /// original monitor's normal `Down` for the helper actor.
  RetiringActor

  /// Retirement could not be established, and nothing clears this. The
  /// slot stays occupied because the helper's jail descendants may still
  /// be running, and `close_pool` reports this failure for the life of
  /// the pool: an unconfirmed cleanup keeps the session's custody.
  Unconfirmed(failure: RetirementFailure)
}

/// The pool's own lifecycle. `PoolClosing` is the window in which every
/// helper has been asked to retire and the answers are still arriving;
/// `PoolFinished` is reached exactly once, and its outcome is the reply
/// every postponed `AwaitPoolRetirement` is replayed onto.
type PoolPhase {
  /// Lending and spawning. The only phase in which a checkout can succeed.
  PoolLive

  /// Admissions are closed and retirement is in flight for every entry.
  PoolClosing

  /// Every entry settled. `Ok` means the inventory emptied through both
  /// retirement boundaries; an `Error` names the first entry that could
  /// not, and holds the pool actor alive so its custody is not silently
  /// dropped by `ForgetPool`.
  PoolFinished(outcome: Result(Nil, RetirementFailure))
}

/// The pool ceiling a host gets when it names no other: the node's
/// scheduler count, clamped by `pool_size_for`. Every helper is an OS
/// process running bwrap and a jail, so this is a real resource limit
/// rather than a policy dial — but it is also the ceiling on how wide a
/// parallel tool batch can actually run, so `2` was never a considered
/// value for it.
pub fn default_pool_size() -> Int {
  pool_size_for(schedulers: ffi_os.schedulers_online())
}

/// The default pool ceiling for a node with `schedulers` schedulers
/// online: the scheduler count, floored at four and capped at sixteen.
///
/// The floor is the point of the derivation. A helper spends nearly all
/// its life blocked on a child process rather than on a scheduler, so
/// scheduler count is a proxy for how big the machine is, not for how
/// much work the pool can carry — a single-core CI box still wants room
/// for a batch of a few concurrent reads. The cap is the other half:
/// sixteen simultaneous jails is already far more memory and pid
/// pressure than any batch we have seen ask for, and a 96-core build
/// server should not silently offer ninety-six.
///
/// ## Examples
///
/// ```gleam
/// assert exec.pool_size_for(schedulers: 1) == 4
/// assert exec.pool_size_for(schedulers: 8) == 8
/// assert exec.pool_size_for(schedulers: 96) == 16
/// ```
///
pub fn pool_size_for(schedulers schedulers: Int) -> Int {
  int.clamp(schedulers, min: min_pool_size, max: max_pool_size)
}

/// The smallest default pool: enough for a handful of concurrent reads
/// even on a one-scheduler node.
pub const min_pool_size = 4

/// The largest default pool. See `pool_size_for`.
pub const max_pool_size = 16

/// Starts a pool of up to `size` helpers, spawned lazily with `spawn`
/// (a seam: production passes `exec.spawn_helper` applied to a
/// `SpawnConfig`; tests pass a fake-transport spawner).
///
/// Spawning runs inside the pool actor, which is deliberate rather than
/// merely tolerated: the pool has exactly one borrower at run time —
/// the broker's `checkout` seam — and the broker is a serial actor, so
/// there is never a second checkout in flight to be delayed behind a
/// spawn. (`client/serve.degraded` borrows once more, at boot, before
/// the broker serves anything.) What growing the pool *does* cost is
/// paid by the broker: it blocks for one helper handshake per slot the
/// pool has not filled yet, so the first wide batch of a session
/// dispatches behind a short series of spawns. Pre-warming is the fix
/// if that ever shows up in a trace; it has not.
pub fn start_pool(
  size size: Int,
  spawn spawn: fn() -> Result(Helper, SpawnError),
) -> Result(Pool, actor.StartError) {
  let parent = process.self()
  state_machine.new_with_initialiser(5000, fn(commands) {
    let state =
      PoolState(
        size:,
        spawn:,
        entries: [],
        commands:,
        parent:,
        spawned: 0,
        retired: 0,
      )
    state_machine.initialised(PoolLive, state)
    |> state_machine.selecting(pool_selector(state))
    |> state_machine.returning(commands)
    |> Ok
  })
  |> state_machine.trapping_exits(True)
  |> state_machine.on_event(handle_pool)
  |> state_machine.start
  |> result.map(fn(started) { Pool(subject: started.data, pid: started.pid) })
}

/// Borrows a ready helper, spawning one if the pool is under capacity.
/// The borrower must `checkin` when done, whatever happened.
///
/// A pool that does not answer within `timeout`, or is not alive to be
/// asked, is `PoolUnavailable` rather than a fault. The borrower this
/// exists for is the broker, calling it from inside its own message
/// handler, so a panic here is not one failed clearance but every
/// in-flight strand's verdict — the very failure the pool's readiness
/// probe was moved onto `try_call` to avoid, one level up.
///
/// The cost is real and worth naming: a pool that answers *after* the
/// window sends `Ok(helper)` to a reply subject nobody is selecting on,
/// and that helper stays in the pool inventory with no borrower to check it
/// in. It is bounded by the pool's own size: a full inventory answers
/// `AllBusy`. This requires a pool that
/// was blocked past a borrower's whole window and then recovered.
/// Against it stands a dead broker, which strands those same helpers
/// and loses everything else besides.
pub fn checkout(
  pool: Pool,
  waiting timeout: Int,
) -> Result(Helper, CheckoutError) {
  case call.try_call(pool.subject, waiting: timeout, sending: Checkout) {
    Ok(outcome) -> outcome
    Error(call.NoReply) | Error(call.CalleeGone) -> Error(PoolUnavailable)
  }
}

/// Counts the pool's inventory by custody, answered by the pool actor in
/// whatever phase it is in: a closing or finished pool still has an
/// inventory worth reporting, and an observer asking during shutdown is
/// the observer most in need of one.
///
/// `waiting` is the caller's window in milliseconds. A pool that does not
/// answer in it, or is not alive to be asked, is `PoolUnavailable` rather
/// than a fault, for the reason `checkout` gives: the asker may be an actor
/// whose death would lose a verdict it owes.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(census) = exec.pool_census(pool, waiting: 1000)
/// assert census.borrowed == 0
/// ```
///
pub fn pool_census(
  pool: Pool,
  waiting timeout: Int,
) -> Result(PoolCensus, CheckoutError) {
  case call.try_call(pool.subject, waiting: timeout, sending: QueryCensus) {
    Ok(census) -> Ok(census)
    Error(call.NoReply) | Error(call.CalleeGone) -> Error(PoolUnavailable)
  }
}

/// The pool's census and one view per inventoried helper, answered by the
/// pool actor in whatever phase it is in. The views are derived from the
/// pool's own books and no helper is asked anything, so a wedged helper
/// cannot delay the answer and nothing is held once it is sent.
///
/// `waiting` and the refusal are those of `pool_census`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(custody) = exec.pool_custody(pool, waiting: 1000)
/// assert list.length(custody.helpers) <= custody.census.size
/// ```
///
pub fn pool_custody(
  pool: Pool,
  waiting timeout: Int,
) -> Result(PoolCustody, CheckoutError) {
  case call.try_call(pool.subject, waiting: timeout, sending: QueryCustody) {
    Ok(custody) -> Ok(custody)
    Error(call.NoReply) | Error(call.CalleeGone) -> Error(PoolUnavailable)
  }
}

/// Returns a borrowed helper. Ready helpers become available; failed
/// helpers retain capacity while their retirement is requested and observed.
pub fn checkin(pool: Pool, helper: Helper) -> Nil {
  process.send(pool.subject, Checkin(helper:))
}

/// Installs exact retirement custody before dispatch without withdrawing the borrow.
/// A lost acknowledgement triggers retirement through the same original door;
/// it grants no dispatch permission and never checks the helper back in.
/// The callback must only send to its original owner.
///
/// ## Examples
///
/// `prepare_borrowed_retirement(pool, helper, completed)` returns one live door.
pub fn prepare_borrowed_retirement(
  pool: Pool,
  helper: Helper,
  completed: fn(Result(Nil, RetirementFailure)) -> Nil,
) -> Result(BorrowedRetirement, RetirementFailure) {
  let registration = process.new_subject()
  let original = BorrowedRetirement(pool, helper, registration)
  let observer = TargetedObserver(registration, completed)
  case
    call.try_call(pool.subject, waiting: 1000, sending: fn(reply) {
      PrepareBorrowed(helper, observer, reply)
    })
  {
    Ok(Ok(Nil)) -> Ok(original)
    Ok(Error(failure)) -> Error(failure)
    Error(call.NoReply) | Error(call.CalleeGone) -> {
      retire_borrowed(original)
      Error(RetirementPending)
    }
  }
}

/// Permanently withdraws the exact observed borrow through its original pool.
/// Duplicate or foreign doors cannot notify success or affect another helper.
///
/// ## Examples
///
/// `retire_borrowed(original)` asks the inventory to retain both cleanup boundaries.
pub fn retire_borrowed(original: BorrowedRetirement) -> Nil {
  process.send(
    original.pool.subject,
    RetireBorrowed(original.helper, original.registration),
  )
}

/// Requests shutdown of every owned helper, including borrowed helpers.
/// The pool stops only after confirmed retirement. Use `close_pool` when
/// the caller needs the outcome; this cast is not proof of cleanup.
pub fn stop_pool(pool: Pool) -> Nil {
  process.send(pool.subject, StopPool)
  process.send(pool.subject, ForgetPool)
}

/// The pool owner, for custody monitors established before shutdown.
///
/// ## Examples
///
/// `process.monitor(pool_pid(pool))` watches the original pool owner.
pub fn pool_pid(pool: Pool) -> Pid {
  pool.pid
}

/// Stops admissions and waits for every owned helper, borrowed or idle,
/// to report orderly native exit. A timeout preserves the inventory.
///
/// ## Examples
///
/// `close_pool(pool, waiting: 5000)` cannot succeed from actor death alone.
pub fn close_pool(
  pool: Pool,
  waiting timeout: Int,
) -> Result(Nil, RetirementFailure) {
  let deadline = monotonic_ms() + timeout
  let monitor = process.monitor(pool.pid)
  process.send(pool.subject, StopPool)
  let outcome = case
    call.try_call(pool.subject, waiting: timeout, sending: AwaitPoolRetirement)
  {
    Ok(outcome) -> outcome
    Error(call.NoReply) -> Error(RetirementPending)
    Error(call.CalleeGone) -> Error(RetirementOwnerGone)
  }
  let outcome = case outcome {
    Ok(Nil) -> {
      process.send(pool.subject, ForgetPool)
      await_retired_owner(monitor, deadline)
    }
    Error(failure) -> Error(failure)
  }
  process.demonitor_process(monitor)
  outcome
}

fn handle_pool(
  phase: PoolPhase,
  state: PoolState,
  message: PoolMsg,
) -> state_machine.Next(PoolPhase, PoolState, PoolMsg) {
  case phase, message {
    PoolLive, Checkout(reply:) -> {
      let #(state, outcome) = next_helper(state)
      process.send(reply, outcome)
      pool_step(PoolLive, state)
    }
    PoolClosing, Checkout(reply) | PoolFinished(..), Checkout(reply) -> {
      process.send(reply, Error(PoolUnavailable))
      state_machine.keep(state)
    }
    PoolLive, Checkin(helper:) ->
      pool_step(PoolLive, handle_checkin(state, helper))
    PoolClosing, Checkin(..) | PoolFinished(..), Checkin(..) ->
      state_machine.keep(state)
    phase, PrepareBorrowed(helper, observer, reply) -> {
      let #(state, outcome) = prepare_targeted(state, helper, observer)
      process.send(reply, outcome)
      pool_step(phase, state)
    }
    phase, RetireBorrowed(helper, registration) -> {
      let entries =
        list.map(state.entries, fn(entry) {
          case entry.helper == helper, entry.targeted {
            True, Some(TargetedObserver(registration: actual, ..)) ->
              case actual == registration {
                True -> retire_entry(entry, state.commands)
                False -> entry
              }
            _, _ -> entry
          }
        })
      pool_step(phase, PoolState(..state, entries:))
    }
    PoolLive, StopPool -> {
      let entries =
        list.map(state.entries, fn(entry) {
          retire_entry(entry, state.commands)
        })
      pool_step(PoolClosing, PoolState(..state, entries:))
    }
    PoolClosing, StopPool | PoolFinished(..), StopPool ->
      state_machine.keep(state)
    PoolFinished(outcome), AwaitPoolRetirement(reply) -> {
      process.send(reply, outcome)
      state_machine.keep(state)
    }
    PoolLive, AwaitPoolRetirement(..) | PoolClosing, AwaitPoolRetirement(..) ->
      state_machine.keep(state) |> state_machine.postpone
    PoolFinished(Ok(Nil)), ForgetPool -> state_machine.stop()
    PoolFinished(Error(_)), ForgetPool -> state_machine.keep(state)
    PoolLive, ForgetPool | PoolClosing, ForgetPool ->
      state_machine.keep(state) |> state_machine.postpone

    // A census is a read of the inventory and changes nothing, so every
    // phase answers it at once: it is never postponed behind a retirement
    // the way `AwaitPoolRetirement` is.
    PoolLive, QueryCensus(reply)
    | PoolClosing, QueryCensus(reply)
    | PoolFinished(..), QueryCensus(reply)
    -> {
      process.send(reply, census_of(state))
      state_machine.keep(state)
    }

    // Custody is a read in the same way, answered in every phase for the same
    // reason: an observer asking during a close is the one who needs it.
    PoolLive, QueryCustody(reply)
    | PoolClosing, QueryCustody(reply)
    | PoolFinished(..), QueryCustody(reply)
    -> {
      process.send(reply, custody_of(state))
      state_machine.keep(state)
    }
    phase, HelperRetired(pid, outcome) ->
      pool_step(phase, record_retirement(state, pid, outcome))
    phase, HelperOwnerGone(pid, reason) ->
      pool_step(phase, record_owner_exit(state, pid, reason))
    phase, PoolLinkedExit(pid) ->
      case pid == state.parent {
        True -> state_machine.stop()
        False -> pool_step(phase, state)
      }
  }
}

// Pure counting over the one canonical inventory. Each entry is in exactly
// one availability, so the five counters partition the entries.
fn census_of(state: PoolState) -> PoolCensus {
  let entries = state.entries
  let counted = fn(wanted: fn(Availability) -> Bool) {
    list.count(entries, fn(entry) { wanted(entry.availability) })
  }
  PoolCensus(
    size: state.size,
    available: counted(fn(availability) { availability == Available }),
    borrowed: counted(fn(availability) { availability == Borrowed }),
    draining: counted(fn(availability) { availability == Draining }),
    retiring: counted(fn(availability) { availability == RetiringActor }),
    unconfirmed: counted(fn(availability) {
      case availability {
        Unconfirmed(_) -> True
        Available | Borrowed | Draining | RetiringActor -> False
      }
    }),
    spawned: state.spawned,
    retired: state.retired,
  )
}

// One view per entry, oldest spawn first, beside the census over the same
// entries. The entries list is newest first, so it is reversed once.
fn custody_of(state: PoolState) -> PoolCustody {
  let helpers =
    list.reverse(state.entries)
    |> list.map(fn(entry) {
      let #(lending, custody) = custody_view(entry.availability)
      HelperView(
        pid: entry.helper.pid,
        ordinal: entry.ordinal,
        lending:,
        custody:,
        features: entry.features,
      )
    })
  PoolCustody(census: census_of(state), helpers:)
}

// The pool's five availabilities, split into the two questions an observer
// asks. `Unconfirmed` is the only one that reads the failure it holds.
fn custody_view(availability: Availability) -> #(Lending, Custody) {
  case availability {
    Available -> #(Lendable, Held)
    Borrowed -> #(Lent, Held)
    Draining -> #(Withdrawn, Retiring)
    RetiringActor -> #(Withdrawn, Retired)
    Unconfirmed(RetirementProofLost) -> #(Withdrawn, ProofLost)
    Unconfirmed(failure) -> #(Withdrawn, CleanupUnconfirmed(reason: failure))
  }
}

fn pool_selector(state: PoolState) -> process.Selector(PoolMsg) {
  let base =
    process.new_selector()
    |> process.select(state.commands)
    |> process.select_trapped_exits(fn(exit) { PoolLinkedExit(exit.pid) })
  list.fold(state.entries, base, fn(selector, entry) {
    process.select_specific_monitor(selector, entry.monitor, fn(down) {
      HelperOwnerGone(entry.helper.pid, down.reason)
    })
  })
}

fn pool_step(
  phase: PoolPhase,
  state: PoolState,
) -> state_machine.Next(PoolPhase, PoolState, PoolMsg) {
  let phase = case phase, state.entries {
    PoolClosing, [] -> PoolFinished(Ok(Nil))
    PoolClosing, [_, ..] ->
      case
        list.find(state.entries, fn(entry) {
          case entry.availability {
            Unconfirmed(_) -> True
            Available | Borrowed | Draining | RetiringActor -> False
          }
        })
      {
        Ok(PoolEntry(availability: Unconfirmed(failure), ..)) ->
          PoolFinished(Error(failure))
        Ok(PoolEntry(availability: Available, ..))
        | Ok(PoolEntry(availability: Borrowed, ..))
        | Ok(PoolEntry(availability: Draining, ..))
        | Ok(PoolEntry(availability: RetiringActor, ..))
        | Error(Nil) -> PoolClosing
      }
    PoolLive, _ | PoolFinished(..), _ -> phase
  }
  state_machine.transition(phase, state)
  |> state_machine.with_selector(pool_selector(state))
}

fn prepare_targeted(
  state: PoolState,
  helper: Helper,
  observer: TargetedObserver,
) -> #(PoolState, Result(Nil, RetirementFailure)) {
  case list.find(state.entries, fn(entry) { entry.helper == helper }) {
    Ok(PoolEntry(availability: Borrowed, targeted: None, ..)) -> {
      let entries =
        list.map(state.entries, fn(entry) {
          case entry.helper == helper {
            True -> PoolEntry(..entry, targeted: Some(observer))
            False -> entry
          }
        })
      #(PoolState(..state, entries:), Ok(Nil))
    }
    Ok(_) | Error(Nil) -> #(state, Error(RetirementProofLost))
  }
}

// Observer publication precedes inventory removal; absence cannot recreate it.
fn finish_targeted(
  entry: PoolEntry,
  outcome: Result(Nil, RetirementFailure),
) -> PoolEntry {
  case entry.targeted {
    Some(observer) -> observer.completed(outcome)
    None -> Nil
  }
  PoolEntry(..entry, targeted: None)
}

fn retire_entry(entry: PoolEntry, commands: Subject(PoolMsg)) -> PoolEntry {
  case entry.availability {
    Draining | RetiringActor | Unconfirmed(_) -> entry
    Available | Borrowed -> {
      process.send(entry.helper.commands, Shutdown)
      process.send(
        entry.helper.commands,
        AwaitRetirement(fn(outcome) {
          process.send(commands, HelperRetired(entry.helper.pid, outcome))
        }),
      )
      PoolEntry(..entry, availability: Draining)
    }
  }
}

fn record_retirement(
  state: PoolState,
  pid: Pid,
  outcome: Result(Nil, RetirementFailure),
) -> PoolState {
  let entries =
    list.filter_map(state.entries, fn(entry) {
      case entry.helper.pid == pid, entry.availability, outcome {
        False, _, _ -> Ok(entry)
        True, Draining, Ok(Nil) -> {
          process.send(entry.helper.commands, ForgetRetired)
          Ok(PoolEntry(..entry, availability: RetiringActor))
        }
        True, Draining, Error(failure) -> {
          let entry = finish_targeted(entry, Error(failure))
          Ok(PoolEntry(..entry, availability: Unconfirmed(failure)))
        }
        True, _, _ -> Ok(entry)
      }
    })
  PoolState(..state, entries:)
}

// A native acknowledgement authorizes asking the actor to exit; only the
// original normal monitor event completes that second retirement boundary.
fn record_owner_exit(
  state: PoolState,
  pid: Pid,
  reason: process.ExitReason,
) -> PoolState {
  let entries =
    list.filter_map(state.entries, fn(entry) {
      case entry.helper.pid == pid, entry.availability, reason {
        False, _, _ -> Ok(entry)
        True, RetiringActor, process.Normal -> {
          process.demonitor_process(entry.monitor)
          let _ = finish_targeted(entry, Ok(Nil))
          Error(Nil)
        }
        True, _, _ -> {
          let entry = finish_targeted(entry, Error(RetirementOwnerGone))
          Ok(PoolEntry(..entry, availability: Unconfirmed(RetirementOwnerGone)))
        }
      }
    })

  // An entry left only through the clean arm, so the difference in length is
  // the number of entries that completed both retirement boundaries.
  let left = list.length(state.entries) - list.length(entries)
  PoolState(..state, entries:, retired: state.retired + left)
}

// Returns a borrowed helper. Only one `helper_ready` accepts rejoins the
// lendable set; a dead, unresponsive or still-busy one is retired, so a
// helper that is mid-execution at checkin is never lent again.
fn handle_checkin(state: PoolState, helper: Helper) -> PoolState {
  let entries =
    list.map(state.entries, fn(entry) {
      case entry.helper.pid == helper.pid, entry.availability {
        True, Borrowed ->
          case entry.targeted, helper_ready(helper) {
            None, True -> PoolEntry(..entry, availability: Available)
            _, _ -> retire_entry(entry, state.commands)
          }
        False, _
        | True, Available
        | True, Draining
        | True, RetiringActor
        | True, Unconfirmed(_)
        -> entry
      }
    })
  PoolState(..state, entries:)
}

fn next_helper(
  state: PoolState,
) -> #(PoolState, Result(Helper, CheckoutError)) {
  case list.find(state.entries, fn(entry) { entry.availability == Available }) {
    Ok(entry) ->
      case helper_ready(entry.helper) {
        True -> {
          let entries =
            list.map(state.entries, fn(candidate) {
              case candidate.helper.pid == entry.helper.pid {
                True -> PoolEntry(..candidate, availability: Borrowed)
                False -> candidate
              }
            })
          #(PoolState(..state, entries:), Ok(entry.helper))
        }
        False -> {
          let entries =
            list.map(state.entries, fn(candidate) {
              case candidate.helper.pid == entry.helper.pid {
                True -> retire_entry(candidate, state.commands)
                False -> candidate
              }
            })
          next_helper(PoolState(..state, entries:))
        }
      }
    Error(Nil) ->
      case state.size > 0 && list.drop(state.entries, state.size - 1) == [] {
        // A refusal has to say whether waiting can change it. Reporting
        // the configured size here made a pool whose every slot was held
        // by an unconfirmed helper indistinguishable from a busy one, so
        // each later clearance napped out its whole budget to be refused
        // for the same permanent reason. Counting the entries that can
        // still return to lending answers the borrower's actual question.
        False -> {
          let returning = list.count(state.entries, lendable_again)
          #(state, Error(AllBusy(size: returning)))
        }
        True -> spawn_new(state)
      }
  }
}

// Whether this entry's slot can still come back to lending. Borrowed
// helpers return on checkin; draining and retiring ones free their slot
// when their retirement completes and the entry leaves the inventory.
// An `Unconfirmed` entry does neither: nothing transitions out of it, by
// design, because the helper's jail descendants may still be running and
// the slot is what keeps a replacement from doubling them.
fn lendable_again(entry: PoolEntry) -> Bool {
  case entry.availability {
    Available | Borrowed | Draining | RetiringActor -> True
    Unconfirmed(_) -> False
  }
}

fn spawn_new(state: PoolState) -> #(PoolState, Result(Helper, CheckoutError)) {
  case state.spawn() {
    Ok(helper) -> {
      let entry =
        PoolEntry(
          helper:,
          monitor: process.monitor(helper.pid),
          availability: Borrowed,
          ordinal: state.spawned + 1,
          features: [],
          targeted: None,
        )
      let state =
        PoolState(
          ..state,
          entries: [entry, ..state.entries],
          spawned: state.spawned + 1,
        )

      // Inventory and the original monitor precede Begin. A checkout
      // caller's deadline can expire during the handshake without losing
      // the owner or converting partial acquisition into an empty slot.
      begin(helper)
      case await_ready(helper, waiting: helper.handshake_wait) {
        Ok(features) -> {
          // The entry is still the head: the pool is one actor and nothing
          // else ran between the insertion and the handshake's answer.
          let known = PoolEntry(..entry, features:)
          #(
            PoolState(..state, entries: [known, ..list.drop(state.entries, 1)]),
            Ok(helper),
          )
        }
        Error(failure) -> {
          let retired = retire_entry(entry, state.commands)
          #(
            PoolState(..state, entries: [retired, ..list.drop(state.entries, 1)]),
            Error(SpawnFailed(HandshakeFailed(failure))),
          )
        }
      }
    }
    Error(error) -> #(state, Error(SpawnFailed(error:)))
  }
}

// Whether an idle helper is still fit to lend. The probe round-trip
// runs inside the pool actor, so its timeout is time the next checkout
// may wait — but an idle helper is by construction running nothing and
// answers in microseconds, and one that cannot answer within
// `ready_probe_ms` is wedged, which is exactly what this is here to
// catch. The cost is therefore bounded by the number of *wedged*
// helpers and paid once each: an unanswered probe removes the helper
// from lending while retaining its custody until retirement is confirmed,
// so it is never probed again. Shortening the timeout
// to make a larger pool cheaper would trade that for retiring healthy
// helpers under load, which is the worse failure.
//
// That accounting is only true because the probe cannot fault. It once
// had to be a private `try_call` to get that, because the public
// `status` panicked on a timeout — inside the pool actor that is not a
// retired helper, it is a dead pool, and a dead pool kills the broker
// with it. `status` now answers `StatusUnresponsive` instead, so the
// probe is the ordinary public question plus this function's policy on
// the answer: only a helper that says it is ready gets lent.
fn helper_ready(helper: Helper) -> Bool {
  case process.is_alive(helper.pid) {
    False -> False
    True ->
      case status(helper, waiting: ready_probe_ms) {
        StatusReady(_) -> True
        StatusStarting | StatusBusy(_) | StatusDead(_) | StatusUnresponsive ->
          False
      }
  }
}

// How long an idle helper has to answer a readiness probe before the
// pool treats it as wedged. See `helper_ready`.
const ready_probe_ms = 1000

/// Starts one credited execution under its original native deadline.
/// Returning success identifies submission; input acceptance and reuse arrive separately.
///
/// ## Examples
///
/// `run_protocol(helper, request, framing.FiniteCollected, clock, deadline, events, 1000)`.
pub fn run_protocol(
  helper: Helper,
  request: ExecRequest,
  mode: framing.ProtocolMode,
  clock: clock.Clock,
  deadline: Int,
  events: Subject(ProtocolEvent),
  waiting timeout: Int,
) -> Result(ProtocolExecution, ProtocolRunFailure) {
  use id <- result.try(
    call.try_call(helper.commands, waiting: timeout, sending: ReserveProtocol)
    |> or_unresponsive
    |> result.map_error(ProtocolRunRefused),
  )
  let execution = ProtocolExecution(helper, id)
  case
    call.try_call(helper.commands, waiting: timeout, sending: fn(reply) {
      RunProtocol(id, request, mode, clock, deadline, events, reply)
    })
  {
    Ok(Ok(_)) -> Ok(execution)
    Ok(Error(failure)) -> Error(ProtocolRunRefused(failure))
    Error(call.NoReply) | Error(call.CalleeGone) ->
      Error(ProtocolRunUnknown(execution, HelperUnresponsive))
  }
}

/// Submits one exact bounded input; only ProtocolInputAccepted attests queue admission.
///
/// ## Examples
///
/// `protocol_input(execution, 1, 2, <<>>, framing.InputEOF, 1000)`.
pub fn protocol_input(
  execution: ProtocolExecution,
  ordinal: Int,
  frame_id: Int,
  data: BitArray,
  end: framing.InputEnd,
  waiting timeout: Int,
) -> Result(Nil, ExecFailure) {
  call.try_call(execution.helper.commands, waiting: timeout, sending: fn(reply) {
    FeedProtocol(execution.id, ordinal, frame_id, data, end, reply)
  })
  |> or_unresponsive
}

/// Returns one output credit after admission by the final bounded consumer.
///
/// ## Examples
///
/// `protocol_output_consumed(execution, ordinal)`.
pub fn protocol_output_consumed(
  execution: ProtocolExecution,
  ordinal: Int,
) -> Nil {
  process.send(
    execution.helper.commands,
    ConsumeProtocolOutput(execution.id, ordinal),
  )
}

/// Consumes the matching reusable witness after retaining its command association.
/// ServerProtocol cannot become reusable through this API.
///
/// ## Examples
///
/// `protocol_reusable_consumed(execution)` follows committed exact witness readback.
pub fn protocol_reusable_consumed(execution: ProtocolExecution) -> Nil {
  process.send(execution.helper.commands, ConsumeProtocolReusable(execution.id))
}

/// Cancels only the original execution, so a late caller cannot stop a successor.
///
/// ## Examples
///
/// `cancel_protocol(execution)`.
pub fn cancel_protocol(execution: ProtocolExecution) -> Nil {
  process.send(execution.helper.commands, CancelProtocol(execution.id))
}

/// Holds one original finite checkin until the exact reuse witness is consumed.
/// A second registration refuses without replacing the first association.
///
/// ## Examples
///
/// `defer_protocol_checkin(execution, fn() { checkin(pool, helper) }, 1000)`.
pub fn defer_protocol_checkin(
  execution: ProtocolExecution,
  checkin: fn() -> Nil,
  waiting timeout: Int,
) -> Result(Nil, ExecFailure) {
  call.try_call(execution.helper.commands, waiting: timeout, sending: fn(reply) {
    DeferProtocolCheckin(execution.id, checkin, reply)
  })
  |> or_unresponsive
}

fn handle_protocol_run(
  machine: Machine,
  id: Int,
  request: ExecRequest,
  mode: framing.ProtocolMode,
  clock: clock.Clock,
  deadline: Int,
  events: Subject(ProtocolEvent),
  reply: Subject(Result(Int, ExecFailure)),
) -> state_machine.Next(Phase, Data, Msg) {
  case machine.phase {
    Idle(features:) -> {
      let ready =
        machine.data.reserved_protocol == Some(id)
        && list.contains(features, framing.protocol_credit_feature)
        && protocol_policy_fits(request, mode)
        && native_wall_fits(request, clock, deadline)
        && events_owner_alive(events)
      case ready, request.demand, degraded_features(features) {
        False, _, _ -> {
          process.send(reply, Error(NotReady))
          state_machine.keep(Data(..machine.data, reserved_protocol: None))
        }
        True, FullEnforcement, True | True, PlatformEnforcement, True -> {
          process.send(reply, Error(DegradedHelper(features)))
          state_machine.keep(Data(..machine.data, reserved_protocol: None))
        }
        True, _, _ -> {
          let data = Data(..machine.data, reserved_protocol: None)
          let protocol =
            ProtocolRun(
              id,
              mode,
              events,
              InputAvailable(1),
              1,
              None,
              0,
              0,
              0,
              ReuseAwaited,
              None,
            )
          let data = Data(..data, protocol: Some(protocol))
          let exec =
            RunningExec(
              id,
              CreditedEvents(events),
              request.demand,
              required_layers_for_demand(
                request.policy,
                features,
                request.demand,
              ),
              tolerated_layers_for_demand(
                request.policy,
                features,
                request.demand,
              ),
            )
          process.send(reply, Ok(id))
          send_or_die(
            Machine(Running(features, exec), data),
            framing.Frame(
              id,
              framing.ProtocolStart(
                framing.ProtocolRequest(
                  request.argv,
                  request.env,
                  request.cwd,
                  request.policy,
                  request.token,
                  None,
                ),
                mode,
              ),
            ),
          )
        }
      }
    }
    Dead(failure:, ..) -> {
      process.send(reply, Error(failure))
      state_machine.keep(machine.data)
    }
    Prepared | AwaitingHello -> {
      process.send(reply, Error(NotReady))
      state_machine.keep(machine.data)
    }
    Running(..) | Cancelling(..) | Finishing(..) -> {
      process.send(reply, Error(HelperBusy))
      state_machine.keep(machine.data)
    }
  }
}

fn handle_protocol_feed(
  machine: Machine,
  id: Int,
  ordinal: Int,
  frame_id: Int,
  bytes: BitArray,
  end: framing.InputEnd,
  reply: Subject(Result(Nil, ExecFailure)),
) -> state_machine.Next(Phase, Data, Msg) {
  case machine.data.protocol, running_with_id(machine.phase, id) {
    Some(p), Some(_) -> {
      let finite =
        p.mode != framing.FiniteCollected
        || ordinal == 1
        && bit_array.byte_size(bytes) == 0
        && end == framing.InputEOF
      case
        p.input,
        p.id == id
        && frame_id > 0
        && bit_array.byte_size(bytes) <= 8192
        && finite
      {
        InputAvailable(next), True if next == ordinal -> {
          let data =
            Data(
              ..machine.data,
              protocol: Some(
                ProtocolRun(..p, input: InputOffered(ordinal, frame_id, end)),
              ),
            )
          process.send(reply, Ok(Nil))
          send_or_die(
            Machine(..machine, data:),
            framing.Frame(
              id,
              framing.ProtocolInput(id, ordinal, frame_id, bytes, end),
            ),
          )
        }
        _, _ -> {
          process.send(reply, Error(ProtocolViolation("input_credit")))
          state_machine.keep(machine.data)
        }
      }
    }
    _, _ -> {
      process.send(reply, Error(NotReady))
      state_machine.keep(machine.data)
    }
  }
}

fn protocol_input_ack(
  machine: Machine,
  envelope: Int,
  id: Int,
  ordinal: Int,
  frame_id: Int,
  refusal: Option(framing.InputRefusal),
) -> Machine {
  case machine.data.protocol, running_with_id(machine.phase, id) {
    Some(p), Some(_) ->
      case p.input {
        InputOffered(expected, expected_frame, end)
          if id == envelope && expected == ordinal && expected_frame == frame_id
        -> {
          let input = case refusal, end {
            None, framing.InputContinues -> InputAvailable(ordinal + 1)
            None, framing.InputEOF -> InputEnded
            Some(_), _ -> InputEnded
          }
          let event = case refusal {
            None -> ProtocolInputAccepted(ordinal, frame_id)
            Some(reason) -> ProtocolInputRefused(ordinal, frame_id, reason)
          }
          process.send(p.events, event)
          Machine(
            ..machine,
            data: Data(..machine.data, protocol: Some(ProtocolRun(..p, input:))),
          )
        }
        _ -> mark_dead(machine, ProtocolViolation("input_ack_identity"))
      }
    _, _ -> mark_dead(machine, ProtocolViolation("input_ack_execution"))
  }
}

fn protocol_output(
  machine: Machine,
  envelope: Int,
  id: Int,
  ordinal: Int,
  stream: OutputStream,
  bytes: BitArray,
  total: Int,
  disposition: framing.OutputDisposition,
) -> Machine {
  case machine.data.protocol, running_with_id(machine.phase, id) {
    Some(p), Some(_) -> {
      let previous = case stream {
        framing.Stdout -> p.stdout_bytes
        framing.Stderr -> p.stderr_bytes
      }
      case
        envelope == id
        && p.id == id
        && ordinal == p.next_output
        && p.offered_output == None
        && total == previous + bit_array.byte_size(bytes)
      {
        True -> {
          process.send(
            p.events,
            ProtocolOutput(ordinal, stream, bytes, total, disposition),
          )
          let p =
            ProtocolRun(
              ..p,
              next_output: ordinal + 1,
              offered_output: Some(ordinal),
              stdout_bytes: case stream {
                framing.Stdout -> total
                framing.Stderr -> p.stdout_bytes
              },
              stderr_bytes: case stream {
                framing.Stderr -> total
                framing.Stdout -> p.stderr_bytes
              },
            )
          Machine(..machine, data: Data(..machine.data, protocol: Some(p)))
        }
        False -> mark_dead(machine, ProtocolViolation("output_credit_or_count"))
      }
    }
    _, _ -> mark_dead(machine, ProtocolViolation("output_execution"))
  }
}

fn consume_protocol_output(machine: Machine, id: Int, ordinal: Int) -> Machine {
  case machine.data.protocol, running_with_id(machine.phase, id) {
    Some(p), Some(_) if p.id == id ->
      case p.offered_output {
        Some(expected) if expected == ordinal -> {
          let data =
            Data(
              ..machine.data,
              protocol: Some(
                ProtocolRun(..p, offered_output: None, consumed_output: ordinal),
              ),
            )
          send_frame(
            Machine(..machine, data:),
            framing.Frame(id, framing.ProtocolOutputConsumed(id, ordinal)),
          )
        }
        _ if ordinal <= p.consumed_output -> machine
        _ -> mark_dead(machine, ProtocolViolation("output_consumer_identity"))
      }
    _, _ -> machine
  }
}

fn protocol_terminal(
  machine: Machine,
  id: Int,
  terminal: framing.ProtocolTerminal,
  disposition: framing.ProtocolDisposition,
) -> Machine {
  case
    machine.data.protocol,
    machine.phase,
    framing.protocol_terminal_body(terminal)
  {
    Some(p),
      Running(features:, exec:),
      framing.ExecExit(
        code:,
        signal:,
        stdout_bytes:,
        stderr_bytes:,
        stdout_truncated:,
        stderr_truncated:,
        enforcement:,
        degraded:,
        wall_ms:,
        timed_out:,
        cancelled:,
      )
    | Some(p),
      Cancelling(features:, exec:),
      framing.ExecExit(
        code:,
        signal:,
        stdout_bytes:,
        stderr_bytes:,
        stdout_truncated:,
        stderr_truncated:,
        enforcement:,
        degraded:,
        wall_ms:,
        timed_out:,
        cancelled:,
      )
      if p.id == id && exec.id == id
    -> {
      let result =
        ExecResult(
          code,
          signal,
          stdout_bytes,
          stderr_bytes,
          stdout_truncated,
          stderr_truncated,
          enforcement,
          degraded,
          wall_ms,
          timed_out,
          cancelled,
        )
      let complete =
        disposition == framing.ProtocolComplete
        && !stdout_truncated
        && !stderr_truncated
        && p.offered_output == None
        && stdout_bytes == p.stdout_bytes
        && stderr_bytes == p.stderr_bytes
      let enforced = case exec.demand {
        BestEffort -> True
        FullEnforcement ->
          !degraded_report(enforcement, degraded, exec.required)
        PlatformEnforcement ->
          !platform_degraded_report(
            enforcement,
            degraded,
            exec.required,
            exec.tolerated,
          )
      }
      case complete, enforced {
        True, True -> {
          process.send(p.events, ProtocolTerminal(Ok(result), disposition))
          Machine(
            Finishing(features, exec),
            Data(
              ..machine.data,
              protocol: Some(ProtocolRun(..p, input: InputEnded)),
            ),
          )
        }
        _, _ -> {
          process.send(
            p.events,
            ProtocolTerminal(
              case enforced {
                True -> Ok(result)
                False -> Error(DegradedExecution(result))
              },
              framing.ProtocolFailed,
            ),
          )
          mark_dead(
            Machine(Finishing(features, exec), machine.data),
            ProtocolViolation("protocol_terminal_failed"),
          )
        }
      }
    }
    _, _, _ ->
      mark_dead(machine, ProtocolViolation("protocol_terminal_identity"))
  }
}

fn protocol_reusable(machine: Machine, envelope: Int, id: Int) -> Machine {
  case machine.phase, machine.data.protocol {
    Finishing(..), Some(p)
      if envelope == id
      && p.id == id
      && p.mode == framing.FiniteCollected
      && p.reuse == ReuseAwaited
    -> {
      process.send(p.events, ProtocolReusable)
      Machine(
        ..machine,
        data: Data(
          ..machine.data,
          protocol: Some(ProtocolRun(..p, reuse: ReuseOffered)),
        ),
      )
    }
    Dead(..), _ -> machine
    _, _ -> mark_dead(machine, ProtocolViolation("reusable_identity_or_mode"))
  }
}

fn consume_protocol_reusable(machine: Machine, id: Int) -> Machine {
  case machine.phase, machine.data.protocol {
    Finishing(features:, ..), Some(p)
      if p.id == id
      && p.mode == framing.FiniteCollected
      && p.reuse == ReuseOffered
    -> {
      let machine =
        Machine(
          Idle(features),
          Data(
            ..machine.data,
            protocol: Some(ProtocolRun(..p, reuse: ReuseConsumed)),
          ),
        )
      case p.deferred {
        Some(checkin) -> {
          checkin()
          Machine(..machine, data: Data(..machine.data, protocol: None))
        }
        None -> machine
      }
    }
    _, _ -> machine
  }
}

fn defer_checkin(
  machine: Machine,
  id: Int,
  checkin: fn() -> Nil,
  reply: Subject(Result(Nil, ExecFailure)),
) -> state_machine.Next(Phase, Data, Msg) {
  case machine.data.protocol, machine.phase {
    Some(p), Idle(..)
      if p.id == id
      && p.mode == framing.FiniteCollected
      && p.reuse == ReuseConsumed
      && p.deferred == None
    -> {
      process.send(reply, Ok(Nil))
      checkin()
      state_machine.keep(Data(..machine.data, protocol: None))
    }
    Some(p), Running(..)
    | Some(p), Cancelling(..)
    | Some(p), Finishing(..)
      if p.id == id && p.mode == framing.FiniteCollected && p.deferred == None
    -> {
      process.send(reply, Ok(Nil))
      state_machine.keep(
        Data(
          ..machine.data,
          protocol: Some(ProtocolRun(..p, deferred: Some(checkin))),
        ),
      )
    }
    _, _ -> {
      process.send(reply, Error(ProtocolViolation("deferred_checkin_identity")))
      state_machine.keep(machine.data)
    }
  }
}

// Finishing keeps the original borrow busy while ordinary reader and retirement
// traffic continue. It owns no timeout and cannot manufacture reuse evidence.
fn handle_finishing(
  machine: Machine,
  message: Msg,
) -> state_machine.Next(Phase, Data, Msg) {
  case message {
    FromWire(WireBytes(bytes)) -> advance(handle_bytes(machine, bytes))
    FromWire(WireClosed(status)) -> native_exit(machine, status)
    QueryStatus(reply) -> {
      process.send(reply, status_of(machine.phase))
      state_machine.keep(machine.data)
    }
    AwaitReady(reply) -> {
      process.send(reply, Ok(machine.data.hello_features))
      state_machine.keep(machine.data)
    }
    AwaitRetirement(_) ->
      state_machine.keep(machine.data) |> state_machine.postpone
    Shutdown -> handle_shutdown(machine)
    Run(reply:, ..) -> refuse_run(machine.data, reply, HelperBusy)
    Heartbeat(reply) -> send_heartbeat(machine, reply)
    HeartbeatTick -> handle_heartbeat_tick(machine)
    _ -> state_machine.keep(machine.data)
  }
}

fn send_execution_event(sink: EventSink, event: ExecEvent) -> Nil {
  case sink, event {
    OrdinaryEvents(events), event -> process.send(events, event)
    CreditedEvents(events), Failed(failure) ->
      process.send(events, ProtocolFailure(failure))
    CreditedEvents(events), Output(..) | CreditedEvents(events), Exited(..) ->
      process.send(
        events,
        ProtocolFailure(ProtocolViolation("ordinary_event_on_protocol")),
      )
  }
}

/// The original wire execution id, for immutable retained command association.
///
/// ## Examples
///
/// `protocol_execution_id(original)` never selects the newest execution.
pub fn protocol_execution_id(execution: ProtocolExecution) -> Int {
  execution.id
}

// Credit bounds are opt-in and cannot widen ordinary native admission.
fn protocol_policy_fits(
  request: ExecRequest,
  mode: framing.ProtocolMode,
) -> Bool {
  case request.policy {
    None -> False
    Some(admitted_policy) -> {
      let maximum_wall = case mode {
        framing.ServerProtocol -> 43_200
        framing.FiniteCollected -> 60
      }
      admitted_policy.limits.wall_s > 0
      && admitted_policy.limits.wall_s <= maximum_wall
      && admitted_policy.limits.output_bytes > 0
      && admitted_policy.limits.output_bytes <= 67_108_864
      && case mode {
        framing.ServerProtocol -> admitted_policy.network == policy.NetworkOff
        framing.FiniteCollected -> True
      }
    }
  }
}
