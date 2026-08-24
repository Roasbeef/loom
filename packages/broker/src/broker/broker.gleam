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
import gleam/erlang/process.{type Subject}
import gleam/int
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
    /// aggregate wall deadline (also the token deadline).
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
  StopBroker
}

type Active {
  Active(helper: Helper, op_id: OpId, token_bytes: BitArray)
}

type State {
  State(
    config: BrokerConfig,
    clock: Clock,
    vault: token.Vault,
    next_call: Int,
    active: Dict(Int, Active),
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
        self: subject,
      )
    actor.initialised(state)
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
      actor.continue(State(..state, vault:))
    }
    Settle(call_id:) ->
      case dict.get(state.active, call_id) {
        Error(Nil) -> actor.continue(state)
        Ok(active) -> {
          state.config.checkin(active.helper)
          // Tokens are single-use: settlement revokes.
          let vault = token.revoke(state.vault, active.token_bytes)
          let active = dict.delete(state.active, call_id)
          actor.continue(State(..state, vault:, active:))
        }
      }
    StopBroker -> actor.stop()
  }
}

fn do_clear_call(
  state: State,
  spec: CallSpec,
  events: Subject(CallEvent),
) -> #(State, Result(CallHandle, Refusal)) {
  // 1. Policy composition: most-restrictive-wins except explicit grants.
  let #(final_policy, narrowings) =
    policy.compose(
      base: spec.base_policy,
      requirements: spec.requirements,
      grants: spec.grants,
    )
  case narrowings, spec.response {
    [_, ..], RefuseNarrowed -> {
      let denial =
        escalation.Denial(
          reason: "tool requirements exceed the session policy",
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
  // 2. Budget: reserve the one exec slot against cap and deadline.
  let #(now, clock) = clock.read(state.clock)
  let state = State(..state, clock:)
  case budget.reserve(budget.open(spec.budget), now:) {
    Error(refusal) -> #(state, Error(BudgetRefused(refusal:)))
    Ok(_ledger) ->
      // 3. Token: mint bound to {op_id, step_id, policy, deadline}.
      case
        token.mint(
          state.vault,
          token.Binding(
            op_id: spec.op_id,
            step_id: spec.step_id,
            policy: final_policy,
            deadline_ms: spec.budget.deadline_ms,
          ),
        )
      {
        Error(error) -> #(state, Error(MintRefused(error:)))
        Ok(#(vault, minted)) -> {
          let state = State(..state, vault:)
          // 4. Helper: borrow through the pool seam.
          case state.config.checkout() {
            Error(error) -> #(state, Error(NoHelper(error:)))
            Ok(helper) ->
              dispatch(state, spec, final_policy, minted, helper, events)
          }
        }
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
) -> #(State, Result(CallHandle, Refusal)) {
  let call_id = state.next_call
  let broker_subject = state.self
  // 5. Relay: a per-call process owning the exec-event subject. It
  // forwards output to the caller, enforces the aggregate wall
  // deadline, and reports settlement back to the broker.
  let ready = process.new_subject()
  let _relay =
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
  case process.receive(ready, 1000) {
    Error(Nil) -> {
      state.config.checkin(helper)
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
        Active(helper:, op_id: spec.op_id, token_bytes: token.to_bytes(minted))
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
