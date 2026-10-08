//// The ToolBroker front door: the single door between the harness and
//// the outside world (design §5.3).
////
//// `clear_call` is the whole story: compose the policy (session base ⊕
//// tool requirements ⊕ escalation grants), refuse or surface the
//// narrowings, reserve budget, mint a capability token bound to
//// `{op_id, step_id, policy, deadline}`, hand the cleared call to the
//// dispatcher seam, stream its output to the caller, and settle: revoke
//// the single-use token and release the budget. `abort` revokes every token of an operation and cancels
//// its running executions — revocation kills the OS process group via
//// the helper's cancel ladder. `abort_step` is the same sweep narrowed
//// to one `{op_id, step_id}`, for a caller that owns a step rather than
//// the operation it belongs to.
////
//// ## Flow
////
//// `clear_call` → `clear_awaiting_helper` → `handle` → `do_clear_call` →
//// `authorize` → `start_execution` → `reclaim`
////
//// 1. `clear_call` is the caller's entry; it hands the spec to
////    `clear_awaiting_helper`, which asks the broker actor and, on a full pool,
////    retries in the caller's own process within its waiting budget.
//// 2. `handle` is the broker actor's one message handler; a `ClearCall` is
////    judged against the abort epoch there, then given to `do_clear_call`.
//// 3. `do_clear_call` composes the policy with `policy.compose`, refuses or
////    narrows, and validates what remains.
//// 4. `authorize` reserves a budget slot (`reserve_budget`), then `mint_token`
////    binds a single-use token and `start_execution` hands the call to the
////    dispatcher.
//// 5. The dispatcher (`broker/dispatch`; `broker/executor` is its one
////    implementation) borrows a helper, forwards output through the
////    deliver closure the broker built, enforces the wall deadline, and
////    reports the one terminal verdict through the settle closure.
//// 6. Settling tells the broker the call ended; `reclaim` revokes the token
////    and releases the budget, and `handle_guarantor_down` runs the same tail
////    after abandoning the execution when the process that would have
////    settled dies unsettled.
////
//// ## The pooled budget is keyed per execution: `{op_id, step_id}`
////
//// Design §6.5 pools broker-side limits "per execution, not per call":
//// one token backs many in-flight effects, and a token is valid for
//// exactly one `{op_id, step_id}` (spec Part 1.4) — so that pair *is*
//// the batch identity the broker pools on, and it holds one
//// `budget.Ledger` per live `{op_id, step_id}`. (A batch may hold two
//// `code_mode` calls, whose execution identity is
//// `{op_id, step_id, source_index}`; that finer coordinate names paths
//// and must never reach this key — ADR-005, "Two programs in one
//// batch".) Every clearance reserves against the
//// stored ledger (the first clearance for a key opens it with that
//// call's budget; later clearances under the same key reserve against
//// the stored budget, which their own budget field cannot widen), so
//// 10,000 polite parallel reads under one execution share one
//// `max_outstanding` cap and one aggregate wall deadline. Reservations
//// are released on settlement, freed wholesale on `abort`, and
//// reclaimed when a call's guarantor process dies unsettled (the broker
//// monitors every guarantor), so a crashed or cancelled call cannot leak a
//// slot. Releases are generation-checked: a stale settlement from
//// before an abort never frees budget of a later ledger under the same
//// key.
////
//// ## A full pool is congestion, not a refusal
////
//// The pool is a real resource ceiling — every helper is an OS process
//// running bwrap and a jail — and a parallel tool batch can easily be
//// wider than it. `clear_call` therefore waits out a full pool in the
//// *caller's* process and retries, within the caller's own `waiting`
//// budget, rather than handing the model a resource error for the
//// third call of a batch of five. The wait cannot be moved inside the
//// broker: the broker checks helpers out synchronously inside its own
//// message handler and checks them back in from `Settle`, so a broker
//// that parked on a checkout would be waiting for something only its
//// own message loop could release. See `clear_awaiting_helper`.
////
//// ## Network proxy mode fails closed (phase 1)
////
//// The egress proxy sidecar is unimplemented, so a composed policy
//// asking for `NetworkProxy` cannot be enforced as requested. Rather
//// than silently widening, `clear_call` narrows it to `NetworkOff` via
//// `policy.narrow_unenforceable` before dispatch: under
//// `RefuseNarrowed` the caller gets a structured denial naming the
//// unenforceable grant; under `ProceedNarrowed` the execution runs
//// with no network at all. Either way nothing ever claims a proxy
//// allowlist was enforced (see the `broker/policy` module doc).
////
//// Effects are injected: execution is a `Dispatcher` (the executor service,
//// over a pool or over a pair of checkout/checkin functions) and entropy/time
//// are injected values, so the entire flow runs against an in-process fake
//// helper, or a fake dispatcher, in tests.
////
//// The MCP adapter (spawn-in-sandbox, schema validation, provenance
//// tagging) is deliberately not here yet: it is later (post-M2) work
//// layered on the same `clear_call` path.

import broker/budget.{type Budget}
import broker/dispatch.{type Dispatcher}
import broker/escalation.{type Denial}
import broker/exec.{type ExecFailure, type ExecResult, type Helper}
import broker/executor
import broker/framing.{type OutputStream}
import broker/internal/call
import broker/policy.{type Grant, type SandboxPolicy}
import broker/token
import core/clock.{type Clock}
import core/ids.{type OpId}
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import telemetry/log

/// What to do when composition gives the tool less than it required.
pub type NarrowingResponse {
  /// Refuse the call with a structured denial carrying the wanted
  /// grants — the escalation path (pre-declared needs).
  RefuseNarrowed

  /// Run anyway under the narrowed policy; the sandbox denial, if any,
  /// then surfaces from the execution itself.
  ProceedNarrowed
}

/// Everything needed to clear one tool call.
pub type CallSpec {
  CallSpec(
    /// The operation this effect belongs to.
    op_id: OpId,
    /// The step within the operation; one token per `{op_id, step_id}`.
    step_id: String,
    /// The session's base policy.
    base_policy: SandboxPolicy,
    /// What the tool requires (its own policy-shaped request).
    requirements: SandboxPolicy,
    /// Grants from consumed escalation approvals, if any.
    grants: List(Grant),
    /// Behavior when the composed policy narrows the requirements.
    response: NarrowingResponse,
    /// Enforcement strictness passed to the exec pool.
    demand: exec.EnforcementDemand,
    /// The command to run.
    argv: List(String),
    /// The child environment (allowlist-constructed by the caller).
    env: List(#(String, String)),
    /// Working directory inside the jail.
    cwd: String,
    /// The pooled per-execution budget: outstanding-effect cap and the
    /// aggregate wall deadline (also the token deadline). The first
    /// clearance for an `{op_id, step_id}` opens the execution's ledger
    /// with this budget; later clearances under the same key reserve
    /// against the stored ledger, and their own budget field cannot
    /// widen it (see the module doc).
    budget: Budget,
  )
}

/// Events streamed to the subject passed to `clear_call`. Exactly one
/// `CallSettled` arrives per successful clearance.
pub type CallEvent {
  /// One chunk of jailed output.
  CallOutput(
    stream: OutputStream,
    data: BitArray,
    total_bytes: Int,
    truncated: Bool,
  )

  /// The call is settled; the helper is back in the pool and the token
  /// revoked.
  CallSettled(outcome: CallOutcome)
}

/// How a cleared call ended.
pub type CallOutcome {
  /// The execution completed under the demanded enforcement.
  CallExited(result: ExecResult)

  /// The execution settled as an in-band failure (helper refusal,
  /// channel death, degraded enforcement, cancel escalation...).
  CallFailed(failure: ExecFailure)
}

/// Why `clear_call` refused before dispatching anything.
pub type Refusal {
  /// Composition narrowed the requirements and the spec said refuse;
  /// the denial carries the exact grants that would satisfy the tool.
  PolicyRefused(denial: Denial)

  /// The composed policy is structurally invalid (relative path,
  /// negative limit).
  InvalidPolicy(error: policy.PolicyError)

  /// The pooled budget refused the reservation.
  BudgetRefused(refusal: budget.Refusal)

  /// Token minting failed (entropy fault).
  MintRefused(error: token.MintError)

  /// No helper could be borrowed. For a full pool this arrives only
  /// after `clear_call` spent the caller's `waiting` budget down to the
  /// last window it can honour — the ordinary
  /// batch-wider-than-the-pool case waits and then runs rather than
  /// reaching here.
  NoHelper(error: exec.CheckoutError)

  /// The operation was aborted, so nothing more may be dispatched under
  /// it. Reachable because clearance is not instantaneous: a caller
  /// waiting out a congested pool can have `abort` land underneath it,
  /// and the retry that follows must not become the one execution the
  /// abort cannot reach.
  OperationAborted

  /// The broker could not be reached far enough to decide anything: its
  /// internal relay would not start, or the clearance exchange itself
  /// went unanswered — the broker did not reply inside the caller's
  /// `waiting` budget, or it had stopped underneath a caller waiting out
  /// a congested pool. Nothing was dispatched in any of those cases.
  BrokerUnavailable
}

/// A cleared call, for stdin/cancel correlation. Opaque; token bytes
/// never leave the broker through it.
pub opaque type CallHandle {
  /// Invariant: `id` names an entry in the broker's active-call table
  /// (or a settled one, in which case operations on it are no-ops).
  CallHandle(id: Int)
}

/// Wiring for a broker: entropy, time, and the exec pool seam. `start`
/// builds an executor service over the pool seam; a caller that holds its
/// own service, as a session does, uses `start_dispatching` and has no use
/// for this.
pub type BrokerConfig {
  BrokerConfig(
    /// Token entropy; production passes `token.production_entropy()`.
    entropy: fn(Int) -> BitArray,
    /// The injected time source for deadlines.
    clock: Clock,
    /// Borrows a ready helper; usually `exec.checkout` applied to a
    /// pool, but any source works — this is the test seam.
    checkout: fn() -> Result(Helper, exec.CheckoutError),
    /// Returns a helper after settlement.
    checkin: fn(Helper) -> Nil,
  )
}

/// A running ToolBroker.
pub opaque type Broker {
  /// `clock` is the session's own clock, copied here so `clear_call`
  /// can charge a congestion wait against real elapsed time from the
  /// borrower's process without a round trip to the actor.
  Broker(subject: Subject(Msg), clock: Clock)
}

/// The broker actor's message type. Opaque.
pub opaque type Msg {
  ClearCall(
    spec: CallSpec,
    events: Subject(CallEvent),
    /// The sweep count this caller last observed for the spec's own
    /// `{op_id, step_id}`, on a retry; `None` on a first attempt, which
    /// has no earlier observation to invalidate. The reply carries the
    /// current count back so the next retry can say what it is resuming
    /// from. See `sweeps_over`.
    since: Option(Int),
    reply: Subject(#(Result(CallHandle, Refusal), Int)),
  )
  SendStdin(handle: CallHandle, data: BitArray, eof: dispatch.Eof)
  CancelCall(handle: CallHandle)
  AbortOp(op_id: OpId)
  AbortStep(op_id: OpId, step_id: String)
  Settle(call_id: Int)
  GuarantorDown(down: process.Down)
  QueryRelay(handle: CallHandle, reply: Subject(Result(Pid, Nil)))
  QueryEpochs(reply: Subject(Int))
  StopBroker
}

type Active {
  Active(
    // The started execution. Its closures are the broker's only way to
    // reach the helper behind it; the broker holds no `Helper`.
    execution: dispatch.Execution,
    op_id: OpId,
    step_id: String,
    token_bytes: BitArray,
    // The monitor on `execution.guarantor`; its unsettled death abandons
    // the execution and reclaims the call's budget slot and token.
    monitor: process.Monitor,
    // Which incarnation of the execution's ledger this call reserved
    // against; releases only apply to a matching generation.
    ledger_generation: Int,
  )
}

// One execution's pooled budget account. The generation distinguishes
// ledger incarnations under a reused key: after an abort drops a
// ledger, late settlements of its calls carry the old generation and
// release nothing from any successor ledger.
type LedgerSlot {
  LedgerSlot(generation: Int, ledger: budget.Ledger)
}

type State {
  State(
    dispatcher: Dispatcher,
    clock: Clock,
    vault: token.Vault,
    next_call: Int,
    active: Dict(Int, Active),
    // Pooled per-execution budgets, keyed by execution identity (see
    // the module doc). A key is present exactly while it has
    // outstanding reservations.
    ledgers: Dict(#(OpId, String), LedgerSlot),
    next_generation: Int,
    // How many times `abort` has swept each operation. Not a record of
    // which operations are finished: `abort` is a scoped cancel, not a
    // terminal one, and a strand goes on clearing calls under the same
    // key afterwards. What the count is for is telling a *resumed*
    // clearance from a fresh one; see `clear_awaiting_helper`.
    //
    // Entries are never removed, and that is a decision (#104). An
    // entry cannot be dropped without dropping the refusal it encodes:
    // a missing key reads as epoch 0, and a waiter that took its first
    // attempt before any abort of its operation holds `Some(0)`, so
    // pruning that operation's entry is exactly what makes its retry
    // compare 0 against 0 and be *admitted* — the resumption across an
    // abort this table exists to refuse, back again and now invisible.
    // (A waiter that started after two aborts holds `Some(2)` and takes
    // the opposite spurious answer, so pruning is not fail-safe in
    // either direction.) `release_slot` can delete a ledger with
    // nothing outstanding because absence and emptiness mean the same
    // thing there; here absence means "never aborted", which is the one
    // thing a pruned entry is not.
    //
    // What is left is the size, and it is small and bounded. This grows
    // by one entry per *operation ever aborted*, not per abort: repeat
    // aborts of one operation `upsert` its counter. The step table below
    // is bounded the same way at its own key: its one routine caller is
    // code mode's teardown, which sweeps the tool batch's step on every
    // execution — the successful ones included — so it costs one entry
    // per *batch that ran a program*, however many programs that batch
    // ran. Nothing sweeps a `"job/<id>"` step, so jobs add none. An entry
    // measures ~110 bytes, and the
    // broker's lifetime is exactly one `loomd` process serving
    // one session (its death is fatal to the server; nothing restarts
    // it), so ten thousand such operations in a session hold about a
    // megabyte — against a conversation store that has committed
    // durable rows for every one of those turns. The alternative was a
    // retention window the broker would have to take as configuration,
    // whose wrong value in the short direction is not a crash but a
    // silent hole in exactly the confinement above.
    abort_epochs: Dict(OpId, Int),
    // The same counter one key finer: how many times `abort_step` has
    // swept each `{op_id, step_id}`. A clearance is judged against the
    // sum of this and its operation's count (`sweeps_over`), and the sum
    // is a faithful composite because both counters only ever increase —
    // it changes exactly when at least one of them does.
    //
    // The operation's own count cannot serve for both, and the reason is
    // the whole point of the step scope. A step abort that bumped
    // `abort_epochs` would refuse every resumed clearance of the
    // operation, its *sibling* steps included — and the sibling is the
    // detached job the step abort exists to spare. Refusing the job's
    // own congestion retry because the satellite beside it was reaped is
    // the collision restated, not a smaller version of it.
    //
    // The growth law and the argument against pruning are the field
    // above's, unchanged: entries are never removed because absence
    // reads as "never swept", and code mode's abort-on-every-teardown
    // costs one entry per batch that ran a program, however many
    // programs it ran.
    step_abort_epochs: Dict(#(OpId, String), Int),
    // The broker's own subject, which each call's `settle` closure uses
    // to report the call's end.
    self: Subject(Msg),
  )
}

/// Starts a broker whose executions run on helpers borrowed through
/// `config.checkout` and returned through `config.checkin`, carried out by an
/// executor service that this call starts over those two seams.
///
/// The service is linked to the caller, so it dies if the caller crashes.
/// A caller that returns normally does not take it down, and `stop` stops
/// only the broker, so the service then stays idle, holding no rows or
/// monitors, until the node ends. Every caller of this function is a test or
/// the demo, where that is the whole of the cost. It answers no custody
/// (`config` has no pool to ask, so a snapshot reports the pool as not
/// answering) and closes no helpers, so a caller that owns a pool stops the
/// pool itself, which is what every caller of this function already does. A
/// session, which needs the service's `close` as a custody step, starts the
/// service itself and uses `start_dispatching`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(started) =
///   broker.start(broker.BrokerConfig(
///     entropy: token.production_entropy(),
///     clock: clock.system(),
///     checkout: fn() { exec.checkout(pool, waiting: 15_000) },
///     checkin: fn(helper) { exec.checkin(pool, helper) },
///   ))
/// ```
///
pub fn start(config: BrokerConfig) -> Result(Broker, actor.StartError) {
  use service <- result.try(
    executor.start(executor.ExecutorConfig(
      checkout: config.checkout,
      checkin: config.checkin,
      custody: fn() { Error(exec.PoolUnavailable) },
      close_helpers: fn(_ms) { Ok(Nil) },
      incarnation: 0,
      log: log.discard(),
    )),
  )
  start_dispatching(
    entropy: config.entropy,
    clock: config.clock,
    dispatcher: executor.dispatcher(service),
  )
}

/// Starts a broker over any `Dispatcher`. Everything the broker decides —
/// policy, budget, tokens, abort epochs — is the same whichever dispatcher
/// carries the cleared call out; only what happens after clearance differs.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(started) =
///   broker.start_dispatching(
///     entropy: token.production_entropy(),
///     clock: clock.system(),
///     dispatcher: executor.dispatcher(service),
///   )
/// ```
///
pub fn start_dispatching(
  entropy entropy: fn(Int) -> BitArray,
  clock clock: Clock,
  dispatcher dispatcher: Dispatcher,
) -> Result(Broker, actor.StartError) {
  actor.new_with_initialiser(1000, fn(subject) {
    let state =
      State(
        dispatcher:,
        clock:,
        vault: token.new(entropy:),
        next_call: 1,
        active: dict.new(),
        ledgers: dict.new(),
        next_generation: 1,
        abort_epochs: dict.new(),
        step_abort_epochs: dict.new(),
        self: subject,
      )

    // The broker monitors every guarantor it is handed; the selector
    // routes their DOWN messages so an unsettled death abandons the
    // execution and reclaims the call's reservations.
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(GuarantorDown)
    actor.initialised(state)
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { Broker(subject: started.data, clock:) })
}

/// Clears and dispatches one tool call. On `Ok` the call is running:
/// output streams to `events` and exactly one `CallSettled` follows —
/// dispatch-stage failures included (they arrive as
/// `CallSettled(CallFailed(_))`, e.g. a degraded helper against a
/// `FullEnforcement` demand). On `Error` nothing was dispatched and no
/// event will arrive.
///
/// `waiting` bounds two different things, deliberately: each exchange
/// with the broker actor, and — as one budget, not per attempt — the
/// total time this call may spend waiting out a full helper pool. A
/// batch wider than the pool is congestion, not a verdict about any
/// call in it, so it waits here rather than coming back as a resource
/// error the model has to read (see `clear_awaiting_helper`).
pub fn clear_call(
  broker: Broker,
  spec: CallSpec,
  events events: Subject(CallEvent),
  waiting timeout: Int,
) -> Result(CallHandle, Refusal) {
  clear_awaiting_helper(broker, spec, events, broker.clock, timeout, None)
}

// Clears, and on a full pool waits for a slot instead of refusing.
//
// **The wait happens here, in the borrower's own process, and that is
// the whole design.** The broker calls its `checkout` seam
// synchronously inside its own message handler, and the only thing that
// ever returns a helper is `checkin`, which the broker reaches from
// `Settle` and `RelayDown` — messages it can only process while it is
// not blocked. A pool that deferred its checkout reply, or a broker
// that parked on one, would therefore be waiting for a resource that
// only its own message loop can release: a deadlock by construction.
// Retrying from outside the broker cannot hit that, because the broker
// stays free to settle the very calls whose helpers this one is waiting
// for.
//
// Nothing is held across the wait. The broker's helper-checkout failure
// path already hands back the reserved budget slot and revokes the
// minted token before it answers, so a waiting caller owns no ledger
// slot, no token and no helper — progress depends only on the running
// executions ending, which their own wall deadlines guarantee.
//
// The wait is bounded rather than indefinite, which is what keeps a
// nested borrower (a code-mode satellite holding one helper while its
// capability calls ask for another) degrading into the same refusal it
// gets today instead of into a stall. Waiters are not queued, so a
// contended pool hands slots out in no particular order; every waiter
// still leaves within its own budget.
//
// **Every waiter leaves with a verdict, too**, and that takes two
// things beyond the arithmetic. The exchange is a `try_call`, because
// `process.call` panics on a timeout and on a dead callee and this
// caller is a strand effect process holding the refusal the model is
// meant to read: a panic here loses it and settles as a synthetic
// zero-usage abort instead. And a retry is only issued with a window
// the broker could plausibly answer in (`min_retry_window_ms`), so the
// loop stops waiting rather than spending its last few milliseconds on
// an exchange it does not expect to win.
fn clear_awaiting_helper(
  broker: Broker,
  spec: CallSpec,
  events: Subject(CallEvent),
  clock: Clock,
  remaining: Int,
  since: Option(Int),
) -> Result(CallHandle, Refusal) {
  let #(started, clock) = clock.read(clock)

  // Each attempt is capped at what is left, not at the original
  // budget, so the total cannot outrun `waiting` however slow an
  // individual exchange with the broker turns out to be.
  use #(outcome, epoch) <- or_unavailable(
    call.try_call(
      broker.subject,
      waiting: int.max(1, remaining),
      sending: fn(reply) { ClearCall(spec:, events:, since:, reply:) },
    ),
  )
  use <- bool.guard(when: !congested(outcome), return: outcome)

  // Charge the attempt itself, not only the nap. Under the congestion
  // this loop exists for, the broker is at its busiest and an exchange
  // is not free; charging naps alone let a nominally 30 s budget run
  // for minutes.
  let #(answered, clock) = clock.read(clock)
  let remaining = remaining - int.max(0, answered - started)

  // The nap is always a whole interval: the guard has to clear a floor
  // that is itself far larger than one, so there is no tail here where
  // a caller sleeps for a fraction of an interval to reach a window it
  // cannot use.
  let after_nap = remaining - helper_wait_interval_ms
  use <- bool.guard(when: after_nap < min_retry_window_ms, return: outcome)
  process.sleep(helper_wait_interval_ms)
  clear_awaiting_helper(broker, spec, events, clock, after_nap, Some(epoch))
}

// use #(outcome, epoch) <- or_unavailable(call.try_call(..))
//
// Turns an exchange that produced no reply into a refusal. The broker
// is a serial actor: an exchange waits behind whatever handler is
// running, so a late answer is congestion wearing a different hat, and
// a caller that died of it would have had no verdict to hand back at
// all. A broker that has stopped underneath a parked waiter reaches the
// same place — the operation cannot run, and saying so beats faulting
// the strand.
fn or_unavailable(
  attempt: Result(a, call.CallFault),
  then: fn(a) -> Result(CallHandle, Refusal),
) -> Result(CallHandle, Refusal) {
  case attempt {
    Error(call.NoReply) | Error(call.CalleeGone) -> Error(BrokerUnavailable)
    Ok(answer) -> then(answer)
  }
}

// Whether a clearance came back because the pool is momentarily full,
// as opposed to because something decided this call may not run. Only
// `AllBusy` with slots that can still lend qualifies. `size` counts the
// entries that may return to lending, not the configured pool size, so
// zero means either a pool sized zero (the seam tests wire when they want
// a broker that always refuses) or a pool whose every slot is held by an
// unconfirmed retirement. Neither will ever check a helper back in, so
// waiting on one would stall the caller for its whole budget to reach the
// same answer.
fn congested(outcome: Result(CallHandle, Refusal)) -> Bool {
  case outcome {
    Error(NoHelper(error: exec.AllBusy(size:))) -> size > 0

    // A pool that did not answer is not a pool that is full. Waiting
    // is the answer to contention, and this is the pool being unable
    // to say anything at all — a caller that napped on it would spend
    // its whole budget re-asking a question nobody is answering, and
    // arrive at the same refusal with the strand's clearance window
    // gone.
    Error(NoHelper(error: exec.PoolUnavailable))
    | Error(NoHelper(error: exec.SpawnFailed(error: _)))
    | Error(PolicyRefused(denial: _))
    | Error(InvalidPolicy(error: _))
    | Error(BudgetRefused(refusal: _))
    | Error(MintRefused(error: _))
    | Error(OperationAborted)
    | Error(BrokerUnavailable)
    | Ok(_) -> False
  }
}

// How long a caller naps between attempts while every helper slot is
// lent out. Short against the lifetime of a jailed execution, so a
// freed helper is picked up promptly; long enough that a waiter costs a
// few dozen wakeups a second rather than a spin.
const helper_wait_interval_ms = 25

// The smallest window `clear_awaiting_helper` will issue a retry with.
//
// The naps are short and the budget is finite, so without a floor the
// tail of a wait is a run of exchanges with windows of a few
// milliseconds — 25, then 1. The broker cannot honour those. It is a
// serial actor and every clearance it *grants* blocks it: up to a
// second waiting for the new relay to hand back its subject, five more
// on the helper's exec handshake, and however long the checkout seam
// takes (fifteen seconds in production). A retry with less than a
// second left is therefore not a wait, it is a bet that the broker is
// idle at the exact moment this loop has given up on it being idle.
//
// The bet is not free even though a lost exchange is now a refusal
// rather than a crash: the exchange most likely to time out is the one
// where a helper came free and the broker dispatched, and a caller that
// walks away from that answer leaves a jailed execution running with
// nobody listening for its settlement. So the loop reserves this much
// of the caller's budget for its last attempt and stops there. It
// cannot guarantee an answer — no floor derived from a congestion
// budget covers a fifteen-second checkout — but it stops the loop from
// manufacturing the case.
const min_retry_window_ms = 1000

/// Streams stdin to a cleared call; `eof: True` closes the child's
/// stdin after `data`. No-op once the call settled.
pub fn stdin(
  broker: Broker,
  handle: CallHandle,
  data data: BitArray,
  eof eof: Bool,
) -> Nil {
  process.send(broker.subject, SendStdin(handle:, data:, eof: eof_of(eof)))
}

// The wire's end-of-input flag as the seam's own two-variant type.
fn eof_of(eof: Bool) -> dispatch.Eof {
  case eof {
    True -> dispatch.EndOfInput
    False -> dispatch.MoreInput
  }
}

/// Cancels a cleared call. Idempotent; the helper's pgroup dies within
/// its 2s ladder or the exec pool kills the helper outright.
pub fn cancel(broker: Broker, handle: CallHandle) -> Nil {
  process.send(broker.subject, CancelCall(handle:))
}

/// Aborts an operation: every token of `op_id` is revoked and every
/// running execution under it cancelled. Each affected call still
/// settles in-band with a `CallSettled` to its caller.
pub fn abort(broker: Broker, op_id: OpId) -> Nil {
  process.send(broker.subject, AbortOp(op_id:))
}

/// Aborts one step of an operation: the tokens bound to exactly this
/// `{op_id, step_id}` are revoked, the executions running under it are
/// cancelled, and its pooled ledger is dropped. Every other step of the
/// same operation is untouched. Each affected call still settles in-band
/// with a `CallSettled` to its caller.
///
/// This is the reaper a caller wants when it owns one step rather than
/// the operation. A code-mode satellite's teardown is the case that
/// forced it: the satellite must die when the program returns, while a
/// background job the program started clears under a sibling step
/// (`{op_id, "job/" <> id}`) and is meant to outlive it. An operator's
/// `abort` of the whole operation still reaches that job, which is what
/// an operator means.
///
/// ## Examples
///
/// ```gleam
/// // broker.abort_step(broker, op_id, step_id: "turn-4")
/// // -> the program's own step is reaped; "job/j1" keeps running
/// ```
///
pub fn abort_step(broker: Broker, op_id: OpId, step_id step_id: String) -> Nil {
  process.send(broker.subject, AbortStep(op_id:, step_id:))
}

/// Stops the broker actor. Callers should abort operations first.
pub fn stop(broker: Broker) -> Nil {
  process.send(broker.subject, StopBroker)
}

/// The broker actor's own pid. Exists so tests can assert that the
/// broker outlived a peer that faulted underneath it — a refusal is
/// only evidence of survival if the thing that issued it is still
/// there, and every one of those tests is about a `process.call` that
/// used to take the broker down with its callee. Not part of the
/// broker's API.
@internal
pub fn pid(broker: Broker) -> Result(Pid, Nil) {
  process.subject_owner(broker.subject)
}

/// The broker actor's subject, as plain data that may cross to another
/// trusted node.
///
/// A `Broker` holds a clock, which is a function and cannot travel. A session
/// whose workspace runs on an executor sends only this subject to its
/// orchestrator, which rebuilds a handle with `over` and its own clock. The
/// `Msg` vocabulary is plain data, so every call works across the node
/// boundary unchanged.
///
/// ## Examples
///
/// ```gleam
/// // let subject = broker.subject(running)
/// ```
///
pub fn subject(broker: Broker) -> Subject(Msg) {
  broker.subject
}

/// A handle over a broker actor that may live on another trusted node.
///
/// `clock` charges congestion waits from the borrower's side, as a local
/// handle does; deadlines inside a `CallSpec` remain the caller's to
/// express on the clock the broker enforces against.
///
/// ## Examples
///
/// ```gleam
/// // let remote = broker.over(census_subject, clock)
/// ```
///
pub fn over(subject: Subject(Msg), clock: Clock) -> Broker {
  Broker(subject:, clock:)
}

/// How many operations the broker holds an abort epoch for. Exists so
/// a test can pin the growth law of that table — one entry per
/// operation *ever aborted*, not one per abort — which is the whole of
/// the answer to whether it needs pruning (#104, and the comment on the
/// field). Not part of the broker's API.
@internal
pub fn abort_epoch_count(broker: Broker, waiting timeout: Int) -> Int {
  process.call(broker.subject, waiting: timeout, sending: QueryEpochs)
}

/// The pid of a cleared call's guarantor (the process whose unsettled
/// death means the call will never settle), or `Error(Nil)` once the call
/// settled. For the executor service that is the call's relay. Exists so
/// tests can kill it and prove the broker reclaims the call's budget slot,
/// token, and helper; not part of the broker's API.
@internal
pub fn relay_pid(
  broker: Broker,
  handle: CallHandle,
  waiting timeout: Int,
) -> Result(Pid, Nil) {
  process.call(broker.subject, waiting: timeout, sending: fn(reply) {
    QueryRelay(handle:, reply:)
  })
}

/// The structured denial hiding in an execution failure, when the
/// failure is an enforcement denial worth escalating (a degraded helper
/// or a degraded enforcement report against a full-enforcement demand).
///
/// Every `ExecFailure` is spelled out rather than swept into a final
/// catch-all, because the two classes are not symmetric in what a
/// mistake costs. `None` settles the call in band and asks nobody; a
/// missed `Some` is an enforcement shortfall that never reaches an
/// operator. The failure vocabulary grows on the enforcement side —
/// which is precisely the side that must not default to silence — so
/// the compiler is made to stop on the next variant and demand the
/// judgment be written here.
///
/// ## Examples
///
/// ```gleam
/// assert broker.denial_for_failure(exec.HelperBusy) == option.None
/// ```
///
pub fn denial_for_failure(failure: ExecFailure) -> Option(Denial) {
  case failure {
    // The helper's hello already fell short of `FullEnforcement`, so
    // nothing ran. The features it *does* have are the diff a human
    // decides about.
    exec.DegradedHelper(features:) ->
      Some(
        escalation.Denial(
          reason: "helper cannot provide the demanded enforcement",
          source: escalation.ExecutionDenial(enforcement: features),
          wanted: [],
        ),
      )

    // Worse: this one ran. The enforcement list on the result is what
    // the layers actually applied, and the gap between it and the
    // demand is what the operator is being asked to accept.
    exec.DegradedExecution(result:) ->
      Some(
        escalation.Denial(
          reason: "execution ran without the demanded enforcement",
          source: escalation.ExecutionDenial(enforcement: result.enforcement),
          wanted: [],
        ),
      )

    // Availability, not enforcement: the helper was absent, still
    // shaking hands, or already busy. Nothing was weakened and no
    // policy question is open, so there is nothing for a human to
    // approve — a retry or a different helper is the whole answer.
    exec.NotReady | exec.HandshakeTimeout | exec.HelperBusy -> None

    // The helper declined the dispatch itself (busy, bad_policy,
    // spawn_failed, malformed). A refusal is the sandbox holding, not
    // yielding; escalating it would offer an approval for a call that
    // was never weakened.
    exec.RefusedByHelper(..) -> None

    // The channel broke or the helper died — framing fault, exit
    // status, a frame kind that never flows this way, a failed stdin
    // write, a cancel that had to be escalated to a kill, a missed
    // heartbeat. Each closes the channel, and a dead channel enforces
    // everything by executing nothing.
    exec.ChannelFault(..)
    | exec.ChannelClosed(..)
    | exec.ProtocolViolation(..)
    | exec.SendFailed
    | exec.CancelEscalated
    | exec.HeartbeatMissed -> None

    // The helper *actor* was out of reach, so no execution was
    // dispatched and nothing is known about the helper behind it. An
    // unknown is not a denial: inventing one would put a policy
    // question to a human that no execution ever asked.
    exec.HelperUnresponsive -> None

    // The execution may have run and its outcome is unknown, because the
    // machinery that would have reported it was lost. That is the
    // opposite of a weakened enforcement: nothing here says the jail was
    // thinner than demanded, and an approval would invite a retry of work
    // that may already have happened, which the failure forbids.
    exec.ExecutionLost(..) -> None

    // The two ends of the exec wire disagree on what they speak, so the
    // channel was closed before any execution and nothing was weakened.
    // The remedy is a rebuild on one side, which the rendered failure
    // already names; a human approval has nothing to grant.
    exec.ProtocolVersionMismatch(..) -> None
  }
}

// --- actor internals ----------------------------------------------------

// How many sweeps a clearance under `{op_id, step_id}` has had to
// survive: the operation's abort count plus this step's own.
//
// One number rather than two travels to the waiter and back, because a
// waiter has nothing to do with the difference — either kind of sweep
// invalidates the observation it is resuming from, and neither is
// something it can retry past. The sum is faithful for that purpose
// because both counters are monotone: it changes if and only if at
// least one of them changed, so equal sums mean no sweep of either kind
// landed underneath the wait.
fn sweeps_over(state: State, op_id: OpId, step_id: String) -> Int {
  let op_sweeps = dict.get(state.abort_epochs, op_id) |> result.unwrap(0)
  let step_sweeps =
    dict.get(state.step_abort_epochs, #(op_id, step_id)) |> result.unwrap(0)
  op_sweeps + step_sweeps
}

fn handle(state: State, message: Msg) -> actor.Next(State, Msg) {
  case message {
    ClearCall(spec:, events:, since:, reply:) -> {
      let epoch = sweeps_over(state, spec.op_id, spec.step_id)

      // A clearance that began before a sweep of this operation — or of
      // this step of it — must not dispatch after it: the sweep revoked
      // the tokens and cancelled the running calls it could see, so
      // admitting this one would leave exactly the execution the sweep
      // could not reach. A first attempt carries no count and is judged
      // on its own merits, which is what lets a strand go on working
      // after code mode's teardown reaps its step.
      let resumed_across_abort = case since {
        Some(seen) -> seen != epoch
        None -> False
      }
      let #(state, outcome) = case resumed_across_abort {
        True -> #(state, Error(OperationAborted))
        False -> do_clear_call(state, spec, events)
      }
      process.send(reply, #(outcome, epoch))
      actor.continue(state)
    }
    SendStdin(handle:, data:, eof:) -> {
      case dict.get(state.active, handle.id) {
        Ok(active) -> active.execution.stdin(data, eof)
        Error(Nil) -> Nil
      }
      actor.continue(state)
    }
    CancelCall(handle:) -> {
      case dict.get(state.active, handle.id) {
        Ok(active) -> active.execution.cancel()
        Error(Nil) -> Nil
      }
      actor.continue(state)
    }
    AbortOp(op_id:) -> {
      let vault = token.revoke_all(state.vault, op_id)
      dict.each(state.active, fn(_id, active) {
        case active.op_id == op_id {
          True -> active.execution.cancel()
          False -> Nil
        }
      })

      // Abort frees the operation's pooled reservations wholesale; the
      // late settlements of its cancelled calls carry retired ledger
      // generations and release nothing further.
      let ledgers =
        dict.filter(state.ledgers, fn(key, _slot) { key.0 != op_id })

      // Bumping the epoch is what closes the window `clear_call`'s
      // congestion wait opens. A caller napping on a full pool wakes
      // and retries, and without this the retry would compose a fresh
      // policy, open a fresh ledger, mint a token `revoke_all` has
      // already passed over, and dispatch a jailed execution under an
      // operation this very abort was emptying — with nothing left to
      // cancel it. Comparing epochs refuses exactly that resumption
      // while leaving a clearance begun *after* the abort to proceed,
      // which is what code mode's teardown-then-continue needs.
      let abort_epochs =
        dict.upsert(state.abort_epochs, op_id, fn(seen) {
          option.unwrap(seen, 0) + 1
        })
      actor.continue(State(..state, vault:, ledgers:, abort_epochs:))
    }
    AbortStep(op_id:, step_id:) -> {
      let vault = token.revoke_step(state.vault, op_id, step_id:)
      dict.each(state.active, fn(_id, active) {
        case active.op_id == op_id && active.step_id == step_id {
          True -> active.execution.cancel()
          False -> Nil
        }
      })

      // One ledger, not the operation's: a sibling step's pooled
      // reservations are exactly what this sweep is careful not to
      // release, since the calls holding them are still running.
      let ledgers =
        dict.filter(state.ledgers, fn(key, _slot) { key != #(op_id, step_id) })

      // The step's own counter closes the same congestion window
      // `AbortOp` closes for the operation, and closes it only for this
      // step; the field's comment argues why the operation's counter
      // cannot stand in for it.
      let step_abort_epochs =
        dict.upsert(state.step_abort_epochs, #(op_id, step_id), fn(seen) {
          option.unwrap(seen, 0) + 1
        })
      actor.continue(State(..state, vault:, ledgers:, step_abort_epochs:))
    }
    Settle(call_id:) ->
      case dict.get(state.active, call_id) {
        Error(Nil) -> actor.continue(state)
        Ok(active) -> {
          // The guarantor exits right after settling; with the settlement
          // in hand its death is expected, so stop watching (which also
          // flushes an already-queued DOWN).
          process.demonitor_process(active.monitor)

          // The demonitor above is what makes `release` and `abandon`
          // exclusive: a DOWN that arrives later finds no active call. The
          // helper goes back here, ahead of the token and the slot, as it
          // did when the broker held it.
          active.execution.release()
          actor.continue(reclaim(state, call_id, active))
        }
      }
    GuarantorDown(down:) -> handle_guarantor_down(state, down)
    QueryEpochs(reply:) -> {
      process.send(reply, dict.size(state.abort_epochs))
      actor.continue(state)
    }
    QueryRelay(handle:, reply:) -> {
      case dict.get(state.active, handle.id) {
        Ok(active) -> process.send(reply, Ok(active.execution.guarantor))
        Error(Nil) -> process.send(reply, Error(Nil))
      }
      actor.continue(state)
    }
    StopBroker -> actor.stop()
  }
}

// A guarantor died without settling (a normal exit settles first, and
// settlement demonitors): its call can no longer reach the caller, so
// fail closed — abandon the execution, which stops it and returns the
// helper (the pool retires it if it died too), revoke the token, and free
// the budget slot so a crashed call never leaks a reservation.
fn handle_guarantor_down(
  state: State,
  down: process.Down,
) -> actor.Next(State, Msg) {
  case down {
    // Unreachable in practice: the selector only monitors guarantor pids
    // via `process.select_monitors`, and a guarantor is an ordinary
    // process, never a port. Handled anyway because `Down` is exhaustive
    // over both.
    process.PortDown(..) -> actor.continue(state)
    process.ProcessDown(pid:, monitor: _, reason: _) ->
      case call_of_guarantor(state.active, pid) {
        Error(Nil) -> actor.continue(state)
        Ok(#(call_id, active)) -> {
          active.execution.abandon()
          actor.continue(reclaim(state, call_id, active))
        }
      }
  }
}

// Revokes a settled call's token and returns its budget slot — the common
// tail of both an in-band `Settle` and a guarantor dying unsettled. The
// helper is not returned here: the `Settle` arm called the execution's
// `release` before reclaiming, and the unsettled path called `abandon`,
// so exactly one of the two has already returned it.
fn reclaim(state: State, call_id: Int, active: Active) -> State {
  // Tokens are single-use: settlement (or the fail-closed reclaim of an
  // unsettled death) revokes.
  let vault = retired_token(state, active.token_bytes)
  let state = release_budget(state, active)
  State(..state, vault:, active: dict.delete(state.active, call_id))
}

// A session token has no temporal expiry, so revocation is also its
// reclamation point. Pruning here prevents settled session jobs retaining
// vault entries forever while preserving the finite-token grace.
fn retired_token(state: State, bytes: BitArray) -> token.Vault {
  let #(now, _) = clock.read(state.clock)
  token.revoke(state.vault, bytes)
  |> token.drop_expired(now:, grace_ms: 5000)
}

// The active call whose guarantor is `pid`, if any.
fn call_of_guarantor(
  active: Dict(Int, Active),
  pid: Pid,
) -> Result(#(Int, Active), Nil) {
  dict.fold(active, Error(Nil), fn(found, call_id, call) {
    case call.execution.guarantor == pid {
      True -> Ok(#(call_id, call))
      False -> found
    }
  })
}

fn do_clear_call(
  state: State,
  spec: CallSpec,
  events: Subject(CallEvent),
) -> #(State, Result(CallHandle, Refusal)) {
  // 1. Policy composition: most-restrictive-wins except explicit
  // grants — then the phase-1 downgrade of enforcement that does not
  // exist yet (network proxy mode), which fails closed as one more
  // narrowing rather than dispatching an unconfined jail.
  let #(composed, narrowings) =
    policy.compose(
      base: spec.base_policy,
      requirements: spec.requirements,
      grants: spec.grants,
    )
  let #(final_policy, unenforceable) = policy.narrow_unenforceable(composed)
  let narrowings = list.append(narrowings, unenforceable)
  case narrowings, spec.response {
    [_, ..], RefuseNarrowed -> {
      let reason = case unenforceable {
        [] -> "tool requirements exceed the session policy"
        [_, ..] ->
          "network proxy mode is not enforceable in phase 1 (the egress proxy sidecar is unimplemented); proxy-mode calls fail closed"
      }
      let denial =
        escalation.Denial(
          reason:,
          source: escalation.PolicyDenial,
          wanted: policy.wanted_grants(narrowings),
        )
      #(state, Error(PolicyRefused(denial:)))
    }
    [], _ | [_, ..], ProceedNarrowed ->
      case policy.validate(final_policy) {
        Error(error) -> #(state, Error(InvalidPolicy(error:)))
        Ok(Nil) -> authorize(state, spec, final_policy, events)
      }
  }
}

fn authorize(
  state: State,
  spec: CallSpec,
  final_policy: SandboxPolicy,
  events: Subject(CallEvent),
) -> #(State, Result(CallHandle, Refusal)) {
  // 2. Budget: reserve one effect slot in the execution's pooled
  // ledger, against its aggregate cap and wall deadline.
  let #(now, clock) = clock.read(state.clock)
  let state = State(..state, clock:)
  case reserve_budget(state, spec, now) {
    Error(refusal) -> #(state, Error(BudgetRefused(refusal:)))
    Ok(#(state, generation)) ->
      mint_token(state, spec, final_policy, events, generation)
  }
}

// 3. Token: mint bound to {op_id, step_id, policy, deadline}.
fn mint_token(
  state: State,
  spec: CallSpec,
  final_policy: SandboxPolicy,
  events: Subject(CallEvent),
  generation: Int,
) -> #(State, Result(CallHandle, Refusal)) {
  let binding =
    token.Binding(
      op_id: spec.op_id,
      step_id: spec.step_id,
      policy: final_policy,
      deadline_ms: spec.budget.deadline_ms,
    )
  case token.mint(state.vault, binding) {
    Error(error) -> {
      // Nothing dispatched: hand the slot back.
      let state = release_slot(state, spec.op_id, spec.step_id, generation)
      #(state, Error(MintRefused(error:)))
    }
    Ok(#(vault, minted)) ->
      start_execution(
        State(..state, vault:),
        spec,
        final_policy,
        events,
        minted,
        generation,
      )
  }
}

// 4. Dispatch: hand the cleared call to the dispatcher, which borrows a
// helper and starts the execution.
fn start_execution(
  state: State,
  spec: CallSpec,
  final_policy: SandboxPolicy,
  events: Subject(CallEvent),
  minted: token.Token,
  generation: Int,
) -> #(State, Result(CallHandle, Refusal)) {
  // The identity is spent by the attempt, not by its success. A dispatcher
  // that gave up on (or was refused) a start may still go on to hold state
  // under this number, so reusing it for the next call would let that
  // leftover be mistaken for the new execution. `Dispatch.seq` promises
  // dispatchers that a number is never offered twice.
  let call_id = state.next_call
  let state = State(..state, next_call: call_id + 1)
  let request =
    exec.ExecRequest(
      argv: spec.argv,
      env: spec.env,
      cwd: spec.cwd,
      policy: Some(final_policy),
      token: token.to_bytes(minted),
      demand: spec.demand,
    )
  let dispatch_request =
    dispatch.Dispatch(
      request:,
      seq: call_id,
      deadline_ms: spec.budget.deadline_ms,
      clock: state.clock,
      caller: option.from_result(process.subject_owner(events)),
      deliver: deliver_to(events),
      settle: settle_to(state.self, events, call_id),
    )
  case state.dispatcher.start(dispatch_request) {
    Error(refusal) -> {
      // Nothing is running, so nothing will settle: hand back the slot
      // and the token (its bytes never left the broker, but a live entry
      // for an execution that will not run has no business in the vault).
      let state = release_slot(state, spec.op_id, spec.step_id, generation)
      let vault = retired_token(state, token.to_bytes(minted))
      #(State(..state, vault:), Error(refusal_of(refusal)))
    }
    Ok(execution) -> {
      let active =
        Active(
          execution:,
          op_id: spec.op_id,
          step_id: spec.step_id,
          token_bytes: token.to_bytes(minted),
          monitor: process.monitor(execution.guarantor),
          ledger_generation: generation,
        )
      let state =
        State(..state, active: dict.insert(state.active, call_id, active))
      #(state, Ok(CallHandle(id: call_id)))
    }
  }
}

// What a refused start means to the caller: a missing helper is the
// pool's verdict, carried through as it always was, and a dispatcher that
// could not set itself up is the broker being unable to decide anything.
fn refusal_of(refusal: dispatch.StartRefusal) -> Refusal {
  case refusal {
    dispatch.NoHelper(error:) -> NoHelper(error:)
    dispatch.NotStarted -> BrokerUnavailable
  }
}

// Forwards one output chunk to the caller. It runs in whatever process the
// dispatcher drives the execution from, and the caller sees the chunks in
// the order the dispatcher delivers them.
fn deliver_to(events: Subject(CallEvent)) -> fn(dispatch.Chunk) -> Nil {
  fn(chunk: dispatch.Chunk) {
    process.send(
      events,
      CallOutput(
        stream: chunk.stream,
        data: chunk.data,
        total_bytes: chunk.total_bytes,
        truncated: chunk.truncated,
      ),
    )
  }
}

// Reports a call's end with two messages, in this order: the broker
// first, so it reclaims the budget slot and token, then the caller. Both
// leave from the process the dispatcher settles in, so a caller that reacts
// to `CallSettled` by clearing another call finds the slot already queued
// for release ahead of its own clearance.
//
// The order is also a proof the service lane relies on. A process's
// messages reach the broker before its own death notice, so a guarantor
// that ran this closure at all is seen as settled and never abandoned;
// `Abandon` therefore means no settlement send happened, and the service
// may settle the caller itself without a second settlement.
fn settle_to(
  broker_subject: Subject(Msg),
  events: Subject(CallEvent),
  call_id: Int,
) -> fn(dispatch.Terminal) -> Nil {
  fn(terminal) {
    process.send(broker_subject, Settle(call_id:))
    process.send(events, CallSettled(outcome: outcome_of(terminal)))
  }
}

// The dispatcher's two terminal verdicts as the broker's two outcomes.
fn outcome_of(terminal: dispatch.Terminal) -> CallOutcome {
  case terminal {
    dispatch.Completed(result:) -> CallExited(result:)
    dispatch.Failed(failure:) -> CallFailed(failure:)
  }
}

// Reserves one effect slot in the execution's pooled ledger, opening a
// fresh ledger (with this call's budget) when the key has none.
fn reserve_budget(
  state: State,
  spec: CallSpec,
  now: Int,
) -> Result(#(State, Int), budget.Refusal) {
  let key = #(spec.op_id, spec.step_id)
  let #(slot, next_generation) = case dict.get(state.ledgers, key) {
    Ok(slot) -> #(slot, state.next_generation)
    Error(Nil) -> #(
      LedgerSlot(
        generation: state.next_generation,
        ledger: budget.open(spec.budget),
      ),
      state.next_generation + 1,
    )
  }
  use ledger <- result.map(budget.reserve(slot.ledger, now:))
  let ledgers = dict.insert(state.ledgers, key, LedgerSlot(..slot, ledger:))
  #(State(..state, ledgers:, next_generation:), slot.generation)
}

// Releases the reservation an active call holds.
fn release_budget(state: State, active: Active) -> State {
  release_slot(state, active.op_id, active.step_id, active.ledger_generation)
}

// Returns one reserved slot to an execution's ledger, provided the
// reservation belongs to the ledger's current incarnation — a stale
// release from before an abort must not free budget of a successor
// ledger under the same key. A ledger with nothing outstanding leaves
// the table.
fn release_slot(
  state: State,
  op_id: OpId,
  step_id: String,
  generation: Int,
) -> State {
  let key = #(op_id, step_id)
  case dict.get(state.ledgers, key) {
    Error(Nil) -> state

    // A stale release from before an abort: the key now names a later
    // ledger incarnation, or none at all, and must not be touched.
    Ok(slot) if slot.generation != generation -> state
    Ok(slot) -> {
      let ledger = budget.settle(slot.ledger)
      let ledgers = case budget.outstanding(ledger) {
        0 -> dict.delete(state.ledgers, key)
        _ -> dict.insert(state.ledgers, key, LedgerSlot(..slot, ledger:))
      }
      State(..state, ledgers:)
    }
  }
}
