//// The ToolBroker front door: the single door between the harness and
//// the outside world (design §5.3).
////
//// `clear_call` is the whole story: compose the policy (session base ⊕
//// tool requirements ⊕ escalation grants), refuse or surface the
//// narrowings, reserve budget, mint a capability token bound to
//// `{op_id, step_id, policy, deadline}`, borrow a helper from the pool
//// seam, dispatch the execution, stream its output to the caller, and
//// settle: check in the helper, revoke the single-use token, release
//// the budget. `abort` revokes every token of an operation and cancels
//// its running executions — revocation kills the OS process group via
//// the helper's cancel ladder.
////
//// ## The pooled budget is keyed per execution: `{op_id, step_id}`
////
//// Design §6.5 pools broker-side limits "per execution, not per call":
//// one token backs many in-flight effects, and a token is valid for
//// exactly one `{op_id, step_id}` (spec Part 1.4) — so that pair *is*
//// the execution identity, and the broker holds one `budget.Ledger`
//// per live `{op_id, step_id}`. Every clearance reserves against the
//// stored ledger (the first clearance for a key opens it with that
//// call's budget; later clearances under the same key reserve against
//// the stored budget, which their own budget field cannot widen), so
//// 10,000 polite parallel reads under one execution share one
//// `max_outstanding` cap and one aggregate wall deadline. Reservations
//// are released on settlement, freed wholesale on `abort`, and
//// reclaimed when a call's relay process dies unsettled (the broker
//// monitors every relay), so a crashed or cancelled call cannot leak a
//// slot. Releases are generation-checked: a stale settlement from
//// before an abort never frees budget of a later ledger under the same
//// key.
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
//// Effects are injected: the pool is a pair of checkout/checkin
//// functions and entropy/time are injected values, so the entire flow
//// runs against an in-process fake helper in tests.
////
//// The MCP adapter (spawn-in-sandbox, schema validation, provenance
//// tagging) is deliberately not here yet: it is later (post-M2) work
//// layered on the same `clear_call` path.

import broker/budget.{type Budget}
import broker/escalation.{type Denial}
import broker/exec.{type ExecFailure, type ExecResult, type Helper}
import broker/framing.{type OutputStream}
import broker/policy.{type Grant, type SandboxPolicy}
import broker/token
import core/clock.{type Clock}
import core/ids.{type OpId}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result

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
  /// No helper could be borrowed.
  NoHelper(error: exec.CheckoutError)
  /// The broker's internal relay could not start.
  BrokerUnavailable
}

/// A cleared call, for stdin/cancel correlation. Opaque; token bytes
/// never leave the broker through it.
pub opaque type CallHandle {
  /// Invariant: `id` names an entry in the broker's active-call table
  /// (or a settled one, in which case operations on it are no-ops).
  CallHandle(id: Int)
}

/// Wiring for a broker: entropy, time, and the exec pool seam.
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
  Broker(subject: Subject(Msg))
}

/// The broker actor's message type. Opaque.
pub opaque type Msg {
  ClearCall(
    spec: CallSpec,
    events: Subject(CallEvent),
    reply: Subject(Result(CallHandle, Refusal)),
  )
  SendStdin(handle: CallHandle, data: BitArray, eof: Bool)
  CancelCall(handle: CallHandle)
  AbortOp(op_id: OpId)
  Settle(call_id: Int)
  RelayDown(down: process.Down)
  QueryRelay(handle: CallHandle, reply: Subject(Result(Pid, Nil)))
  StopBroker
}

type Active {
  Active(
    helper: Helper,
    op_id: OpId,
    step_id: String,
    token_bytes: BitArray,
    // The monitored relay process; its unsettled death reclaims the
    // call's budget slot, token, and helper.
    relay_pid: Pid,
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
    config: BrokerConfig,
    clock: Clock,
    vault: token.Vault,
    next_call: Int,
    active: Dict(Int, Active),
    // Pooled per-execution budgets, keyed by execution identity (see
    // the module doc). A key is present exactly while it has
    // outstanding reservations.
    ledgers: Dict(#(OpId, String), LedgerSlot),
    next_generation: Int,
    // The broker's own subject, handed to relays for Settle reports.
    self: Subject(Msg),
  )
}

// How long after the wall deadline (plus the helper's cancel ladder) a
// relay waits before declaring the execution unkillable.
const relay_grace_ms = 5000

/// Starts a broker.
pub fn start(config: BrokerConfig) -> Result(Broker, actor.StartError) {
  actor.new_with_initialiser(1000, fn(subject) {
    let state =
      State(
        config:,
        clock: config.clock,
        vault: token.new(entropy: config.entropy),
        next_call: 1,
        active: dict.new(),
        ledgers: dict.new(),
        next_generation: 1,
        self: subject,
      )
    // The broker monitors every relay it spawns; the selector routes
    // their DOWN messages so an unsettled relay death reclaims the
    // call's reservations.
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(RelayDown)
    actor.initialised(state)
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { Broker(subject: started.data) })
}

/// Clears and dispatches one tool call. On `Ok` the call is running:
/// output streams to `events` and exactly one `CallSettled` follows —
/// dispatch-stage failures included (they arrive as
/// `CallSettled(CallFailed(_))`, e.g. a degraded helper against a
/// `FullEnforcement` demand). On `Error` nothing was dispatched and no
/// event will arrive.
pub fn clear_call(
  broker: Broker,
  spec: CallSpec,
  events events: Subject(CallEvent),
  waiting timeout: Int,
) -> Result(CallHandle, Refusal) {
  process.call(broker.subject, waiting: timeout, sending: fn(reply) {
    ClearCall(spec:, events:, reply:)
  })
}

/// Streams stdin to a cleared call; `eof: True` closes the child's
/// stdin after `data`. No-op once the call settled.
pub fn stdin(
  broker: Broker,
  handle: CallHandle,
  data data: BitArray,
  eof eof: Bool,
) -> Nil {
  process.send(broker.subject, SendStdin(handle:, data:, eof:))
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

/// Stops the broker actor. Callers should abort operations first.
pub fn stop(broker: Broker) -> Nil {
  process.send(broker.subject, StopBroker)
}

/// The pid of a cleared call's relay process, or `Error(Nil)` once the
/// call settled. Exists so tests can kill a relay and prove the broker
/// reclaims the call's budget slot, token, and helper; not part of the
/// broker's API.
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
/// ## Examples
///
/// ```gleam
/// assert broker.denial_for_failure(exec.HelperBusy) == option.None
/// ```
///
pub fn denial_for_failure(failure: ExecFailure) -> Option(Denial) {
  case failure {
    exec.DegradedHelper(features:) ->
      Some(
        escalation.Denial(
          reason: "helper cannot provide the demanded enforcement",
          source: escalation.ExecutionDenial(enforcement: features),
          wanted: [],
        ),
      )
    exec.DegradedExecution(result:) ->
      Some(
        escalation.Denial(
          reason: "execution ran without the demanded enforcement",
          source: escalation.ExecutionDenial(enforcement: result.enforcement),
          wanted: [],
        ),
      )
    _ -> None
  }
}

// --- actor internals ----------------------------------------------------

fn handle(state: State, message: Msg) -> actor.Next(State, Msg) {
  case message {
    ClearCall(spec:, events:, reply:) -> {
      let #(state, outcome) = do_clear_call(state, spec, events)
      process.send(reply, outcome)
      actor.continue(state)
    }
    SendStdin(handle:, data:, eof:) -> {
      case dict.get(state.active, handle.id) {
        Ok(active) -> exec.stdin(active.helper, data:, eof:)
        Error(Nil) -> Nil
      }
      actor.continue(state)
    }
    CancelCall(handle:) -> {
      case dict.get(state.active, handle.id) {
        Ok(active) -> exec.cancel(active.helper)
        Error(Nil) -> Nil
      }
      actor.continue(state)
    }
    AbortOp(op_id:) -> {
      let vault = token.revoke_all(state.vault, op_id)
      dict.each(state.active, fn(_id, active) {
        case active.op_id == op_id {
          True -> exec.cancel(active.helper)
          False -> Nil
        }
      })
      // Abort frees the operation's pooled reservations wholesale; the
      // late settlements of its cancelled calls carry retired ledger
      // generations and release nothing further.
      let ledgers =
        dict.filter(state.ledgers, fn(key, _slot) { key.0 != op_id })
      actor.continue(State(..state, vault:, ledgers:))
    }
    Settle(call_id:) ->
      case dict.get(state.active, call_id) {
        Error(Nil) -> actor.continue(state)
        Ok(active) -> {
          // The relay exits right after settling; with the settlement
          // in hand its death is expected, so stop watching (which also
          // flushes an already-queued DOWN).
          process.demonitor_process(active.monitor)
          actor.continue(reclaim(state, call_id, active))
        }
      }
    RelayDown(down:) -> handle_relay_down(state, down)
    QueryRelay(handle:, reply:) -> {
      case dict.get(state.active, handle.id) {
        Ok(active) -> process.send(reply, Ok(active.relay_pid))
        Error(Nil) -> process.send(reply, Error(Nil))
      }
      actor.continue(state)
    }
    StopBroker -> actor.stop()
  }
}

// A relay died without settling (a normal exit settles first, and
// settlement demonitors): its call can no longer reach the caller, so
// fail closed — cancel the execution, return the helper (the pool
// retires it if it died too), revoke the token, and free the budget
// slot so a crashed call never leaks a reservation.
fn handle_relay_down(
  state: State,
  down: process.Down,
) -> actor.Next(State, Msg) {
  case down {
    // Unreachable in practice: the selector only monitors relay pids via
    // `process.select_monitors`, and relays are ordinary processes, never
    // ports. Handled anyway because `Down` is exhaustive over both.
    process.PortDown(..) -> actor.continue(state)
    process.ProcessDown(pid:, monitor: _, reason: _) ->
      case call_of_relay(state.active, pid) {
        Error(Nil) -> actor.continue(state)
        Ok(#(call_id, active)) -> {
          exec.cancel(active.helper)
          actor.continue(reclaim(state, call_id, active))
        }
      }
  }
}

// Returns a settled call's helper and budget slot and revokes its token
// — the common tail of both an in-band `Settle` and a relay dying
// unsettled. The caller decides beforehand whether the execution itself
// still needs cancelling (a `Settle` means it already finished; an
// unsettled relay death means it might not have).
fn reclaim(state: State, call_id: Int, active: Active) -> State {
  state.config.checkin(active.helper)
  // Tokens are single-use: settlement (or the fail-closed reclaim of an
  // unsettled death) revokes.
  let vault = token.revoke(state.vault, active.token_bytes)
  let state = release_budget(state, active)
  State(..state, vault:, active: dict.delete(state.active, call_id))
}

// The active call whose relay is `pid`, if any.
fn call_of_relay(
  active: Dict(Int, Active),
  pid: Pid,
) -> Result(#(Int, Active), Nil) {
  dict.fold(active, Error(Nil), fn(found, call_id, call) {
    case call.relay_pid == pid {
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
      checkout_helper(
        State(..state, vault:),
        spec,
        final_policy,
        events,
        minted,
        generation,
      )
  }
}

// 4. Helper: borrow through the pool seam.
fn checkout_helper(
  state: State,
  spec: CallSpec,
  final_policy: SandboxPolicy,
  events: Subject(CallEvent),
  minted: token.Token,
  generation: Int,
) -> #(State, Result(CallHandle, Refusal)) {
  case state.config.checkout() {
    Error(error) -> {
      // Nothing dispatched: hand back the slot and the token (its bytes
      // never left the broker, but a live entry for an execution that
      // will not run has no business in the vault).
      let state = release_slot(state, spec.op_id, spec.step_id, generation)
      let vault = token.revoke(state.vault, token.to_bytes(minted))
      #(State(..state, vault:), Error(NoHelper(error:)))
    }
    Ok(helper) ->
      dispatch(state, spec, final_policy, minted, helper, events, generation)
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

fn dispatch(
  state: State,
  spec: CallSpec,
  final_policy: SandboxPolicy,
  minted: token.Token,
  helper: Helper,
  events: Subject(CallEvent),
  generation: Int,
) -> #(State, Result(CallHandle, Refusal)) {
  let call_id = state.next_call
  let broker_subject = state.self
  // 5. Relay: a per-call process owning the exec-event subject. It
  // forwards output to the caller, enforces the aggregate wall
  // deadline, and reports settlement back to the broker. The broker
  // monitors it so an unsettled death reclaims the call's reservations.
  let ready = process.new_subject()
  let relay_pid =
    process.spawn_unlinked(fn() {
      let exec_events = process.new_subject()
      process.send(ready, exec_events)
      relay(
        exec_events,
        events,
        broker_subject,
        call_id,
        helper,
        state.clock,
        spec.budget.deadline_ms,
        Streaming,
      )
    })
  let monitor = process.monitor(relay_pid)
  // The relay must own the subject it receives exec events on (subjects
  // are tied to their owning process), so it creates `exec_events` itself
  // and hands it back over `ready` before this function dispatches
  // anything to it — closing the race where exec.run could fire before
  // the relay is listening.
  case process.receive(ready, 1000) {
    Error(Nil) -> {
      process.demonitor_process(monitor)
      state.config.checkin(helper)
      let state = release_slot(state, spec.op_id, spec.step_id, generation)
      #(
        State(..state, vault: token.revoke(state.vault, token.to_bytes(minted))),
        Error(BrokerUnavailable),
      )
    }
    Ok(exec_events) -> {
      let request =
        exec.ExecRequest(
          argv: spec.argv,
          env: spec.env,
          cwd: spec.cwd,
          policy: Some(final_policy),
          token: token.to_bytes(minted),
          demand: spec.demand,
        )
      let active =
        Active(
          helper:,
          op_id: spec.op_id,
          step_id: spec.step_id,
          token_bytes: token.to_bytes(minted),
          relay_pid:,
          monitor:,
          ledger_generation: generation,
        )
      let state =
        State(
          ..state,
          next_call: call_id + 1,
          active: dict.insert(state.active, call_id, active),
        )
      // 6. Dispatch. A refusal here still settles through the relay so
      // the caller sees exactly one CallSettled either way.
      case exec.run(helper, request, events: exec_events, waiting: 5000) {
        Ok(Nil) -> Nil
        Error(failure) -> process.send(exec_events, exec.Failed(failure:))
      }
      #(state, Ok(CallHandle(id: call_id)))
    }
  }
}

type RelayMode {
  Streaming
  Draining
}

fn relay(
  exec_events: Subject(exec.ExecEvent),
  caller: Subject(CallEvent),
  broker_subject: Subject(Msg),
  call_id: Int,
  helper: Helper,
  relay_clock: Clock,
  deadline_ms: Int,
  mode: RelayMode,
) -> Nil {
  let #(now, relay_clock) = clock.read(relay_clock)
  let remaining = int.max(deadline_ms - now, 0)
  case process.receive(exec_events, remaining + 20) {
    Ok(exec.Output(stream:, data:, total_bytes:, truncated:)) -> {
      process.send(caller, CallOutput(stream:, data:, total_bytes:, truncated:))
      relay(
        exec_events,
        caller,
        broker_subject,
        call_id,
        helper,
        relay_clock,
        deadline_ms,
        mode,
      )
    }
    Ok(exec.Exited(result:)) ->
      settle(caller, broker_subject, call_id, CallExited(result:))
    Ok(exec.Failed(failure:)) ->
      settle(caller, broker_subject, call_id, CallFailed(failure:))
    Error(Nil) ->
      case mode {
        // Wall deadline hit: cancel and drain. The helper's own ladder
        // (TERM then KILL, then the pool's outright kill) guarantees a
        // terminal event; Draining's window bounds our trust in that.
        Streaming -> {
          exec.cancel(helper)
          relay(
            exec_events,
            caller,
            broker_subject,
            call_id,
            helper,
            relay_clock,
            now + relay_grace_ms,
            Draining,
          )
        }
        Draining ->
          settle(
            caller,
            broker_subject,
            call_id,
            CallFailed(failure: exec.CancelEscalated),
          )
      }
  }
}

fn settle(
  caller: Subject(CallEvent),
  broker_subject: Subject(Msg),
  call_id: Int,
  outcome: CallOutcome,
) -> Nil {
  process.send(broker_subject, Settle(call_id:))
  process.send(caller, CallSettled(outcome:))
}
