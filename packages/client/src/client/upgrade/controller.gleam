//// The surviving custodian owns both suspend and resume, from the same PID.
////
//// Loading finishes before the selected component pauses. An unlinked weft
//// actor monitors the accepted operation's owner, while an existing bounded
//// weft run performs the sys change-code call. Caller loss cancels that run;
//// terminal delivery always resumes and observes the actual component before
//// releasing slot custody. A timeout is never treated as proof of rollback.

import client/internal/ffi_upgrade as native
import client/scratch
import client/upgrade/slots
import client/upgrade/source
import client/upgrade/state as abi
import gleam/bool
import gleam/erlang/process.{type Pid, type Subject}
import gleam/option.{type Option, None, Some}
import gleam/result
import host/bootstrap as host
import host/claim
import weft
import weft/actor
import weft/registry

/// Native owner-supplied selection; JSON carries no authority or raw bytes.
pub type Request {
  Request(
    /// Idempotence key retained by the asynchronous native control owner.
    request_id: String,
    /// The sole opted-in harness component.
    component: String,
    /// Version expected to be currently executing.
    expected_version: String,
    /// Exact currently installed artifact digest.
    expected_digest: String,
    /// Official reviewed release tag, or builtin for current-state downgrade.
    target_release: String,
    /// Exact reviewed manifest digest; builtin has the literal builtin identity.
    manifest_digest: String,
    /// Finite pause budget, including suspend, migration and resume custody.
    pause_ms: Int,
  )
}

/// Observed outcome without any scratch value or native credential.
pub type Receipt {
  Receipt(
    /// Native idempotence key for this accepted operation.
    request_id: String,
    /// The exact actor PID which was admitted and remained the recipient.
    pid: Pid,
    /// Identity and aggregate state observed after resume.
    observation: abi.Observation,
    /// Successful installation or retained old implementation.
    status: String,
    /// Actual suspend-to-resume acknowledgement duration.
    pause_ms: Int,
    /// A migration or recovery refusal, if one occurred.
    error: Option(String),
  )
}

type Wiring {
  Wiring(
    subject: Subject(abi.Message),
    pid: Pid,
    owner: Pid,
    slots: slots.Slots,
    request: Request,
    artifact: source.Artifact,
    expected: abi.Identity,
    token: String,
    reply: Subject(Result(Receipt, String)),
  )
}

type Phase {
  Parked
  RetiringAdmission
  Changing
  Recovering
}

type State {
  State(
    wiring: Wiring,
    started_at: Int,
    outcome: Option(Result(Nil, String)),
    phase: Phase,
    selector: process.Selector(Message),
  )
}

type Message {
  Begin
  Abort
  Recover
  Report(weft.Pulled(Nil, String))
  OwnerLost
  TargetLost
}

/// Execute an accepted native operation under surviving bounded resume custody.
///
/// The gateway queues this on its control owner rather than calling it inside
/// the gateway actor. The owner must outlive the CLI's queued acknowledgement.
/// ## Examples
/// `apply(name, request, operation_owner)` preserves the populated scratch PID.
pub fn apply(
  name: registry.Address(scratch.Message),
  request: Request,
  owner: Pid,
) -> Result(Receipt, String) {
  apply_on(name, request, owner, source.resolve)
}

/// Trusted resolver seam for compiled native fixtures, never user arguments.
/// ## Examples
/// `apply_on(name, request, owner, fixture_resolver)` exercises production custody.
pub fn apply_on(
  name: registry.Address(scratch.Message),
  request: Request,
  owner: Pid,
  resolve: fn(String, String) -> Result(source.Artifact, String),
) -> Result(Receipt, String) {
  case
    weft.new_prepared([prepared_on(name, request, owner, resolve)])
    |> weft.deadline(130_000)
    |> weft.cancel_grace(3000)
    |> weft.start
  {
    [weft.Completed(value:, ..)] -> Ok(value)
    [weft.Failed(error:, ..)] -> Error(error)
    _ -> Error("harness operation failed or cleanup remains unconfirmed")
  }
}

/// A managed native operation whose custodian is published before suspension.
/// ## Examples
/// `prepared(name, request, owner)` proves resume before normal task drain.
pub fn prepared(
  name: registry.Address(scratch.Message),
  request: Request,
  owner: Pid,
) -> weft.PreparedTask(Receipt, String) {
  prepared_on(name, request, owner, source.resolve)
}

/// Trusted artifact resolver seam retaining the same managed custody contract.
/// ## Examples
/// `prepared_on(name, request, owner, resolve)` admits no raw operator bytes.
pub fn prepared_on(
  name: registry.Address(scratch.Message),
  request: Request,
  owner: Pid,
  resolve: fn(String, String) -> Result(source.Artifact, String),
) -> weft.PreparedTask(Receipt, String) {
  weft.managed(fn(ledger) { execute(name, request, owner, resolve, ledger) })
}

fn execute(
  name: registry.Address(scratch.Message),
  request: Request,
  _owner: Pid,
  resolve: fn(String, String) -> Result(source.Artifact, String),
  ledger: weft.Ledger,
) -> Result(Receipt, String) {
  let owner = process.self()
  use _ <- result.try(validate(request))
  use artifact <- result.try(case request.target_release {
    "builtin" ->
      case request.manifest_digest {
        "builtin" -> Ok(source.builtin())
        _ -> Error("builtin downgrade has no downloaded manifest")
      }
    _ -> resolve(request.target_release, request.manifest_digest)
  })
  use slot_owner <- result.try(slots.owner())
  use subject <- result.try(
    registry.lookup(name)
    |> result.replace_error("scratch component is unavailable"),
  )
  use pid <- result.try(
    process.subject_owner(subject)
    |> result.replace_error("scratch recipient is unavailable"),
  )
  use observed <- result.try(scratch.observe_subject(subject, 100))
  use <- bool.guard(
    observed.identity.version != request.expected_version
      || observed.identity.digest != request.expected_digest,
    Error("scratch implementation differs from expected version or digest"),
  )
  use <- bool.guard(
    observed.reported_version != observed.identity.version,
    Error("scratch callback version differs from installed artifact identity"),
  )
  let reply = process.new_subject()
  let wiring =
    Wiring(
      subject,
      pid,
      owner,
      slot_owner,
      request,
      artifact,
      observed.identity,
      claim.random_credential(),
      reply,
    )
  let started =
    actor.new_with_initialiser(1000, fn(inbox) {
      let owner_watch = process.monitor(owner)
      let target_watch = process.monitor(pid)
      let selector =
        process.new_selector()
        |> process.select(inbox)
        |> process.select_specific_monitor(owner_watch, fn(_) { OwnerLost })
        |> process.select_specific_monitor(target_watch, fn(_) { TargetLost })
      Ok(
        actor.initialised(State(wiring, 0, None, Parked, selector))
        |> actor.selecting(selector)
        |> actor.returning(inbox),
      )
    })
    |> actor.on_message(fn(state, message) { handle(state, message) })
    |> actor.periodic(every: 1000, sending: Recover)
    |> actor.unlinked
    |> actor.start
  use started <- result.try(
    started |> result.replace_error("scratch upgrade custodian could not start"),
  )

  // Publish cleanup custody before permitting the custodian to suspend anything.
  case
    weft.adopt(ledger, started.pid, fn() { process.send(started.data, Abort) })
  {
    weft.Adopted -> process.send(started.data, Begin)
    weft.Refused -> process.send(started.data, Abort)
  }

  // The custodian is independent of this waiting worker and monitors its owner.
  let monitor = process.monitor(started.pid)
  let answer =
    process.new_selector()
    |> process.select_map(reply, Ok)
    |> process.select_specific_monitor(monitor, fn(_) {
      Error("scratch upgrade custodian exited without a receipt")
    })
    |> process.selector_receive(5000)
  process.demonitor_process(monitor)
  result.unwrap(
    answer,
    Error(
      "scratch upgrade custody remains pending; inspect its current identity",
    ),
  )
  |> result.flatten
}

fn validate(request: Request) -> Result(Nil, String) {
  use <- bool.guard(
    request.component != "scratch",
    Error("harness component is outside the upgrade allowlist"),
  )
  use <- bool.guard(
    !source.basename(request.request_id),
    Error("invalid harness request identity"),
  )
  use <- bool.guard(
    request.pause_ms < 400 || request.pause_ms > 1000,
    Error("scratch pause budget must be between 400 and 1000 milliseconds"),
  )
  Ok(Nil)
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Begin -> begin(state)
    Report(weft.PulledOutcome(outcome)) ->
      actor.continue(State(..state, outcome: Some(outcome_result(outcome))))
    Report(weft.AllDelivered) -> finish(State(..state, phase: Recovering))
    Report(weft.NotYet) -> actor.continue(state)
    Report(weft.RunLost(_)) ->
      finish(
        State(
          ..state,
          outcome: Some(Error("scratch migration task ownership was lost")),
          phase: Recovering,
        ),
      )
    Abort | OwnerLost ->
      case state.phase {
        Parked -> {
          process.send(
            state.wiring.reply,
            Error("harness operation cancelled before suspension"),
          )
          actor.stop()
        }
        RetiringAdmission -> retire_admission(state)
        Changing -> actor.continue(state)
        Recovering -> finish(state)
      }
    Recover ->
      case state.phase {
        Parked | Changing -> actor.continue(state)
        RetiringAdmission -> retire_admission(state)
        Recovering -> finish(state)
      }
    TargetLost -> {
      // The existing run watches both lifetimes and joins its cancelled worker.
      // Its terminal delivery owns resume; an early resume could race change_code.
      actor.continue(state)
    }
  }
}

fn begin(state: State) -> actor.Next(State, Message) {
  let wiring = state.wiring
  let prepared = prepare(wiring)
  case prepared {
    Error(reason) ->
      retire_admission(
        State(..state, phase: RetiringAdmission, outcome: Some(Error(reason))),
      )
    Ok(Nil) ->
      start_change(State(..state, started_at: host.monotonic_time_ms()))
  }
}

fn prepare(wiring: Wiring) -> Result(Nil, String) {
  use <- bool.guard(
    !native.deliver_signals(wiring.owner),
    Error("accepted harness operation owner exited"),
  )
  use _ <- result.try(slots.acquire(
    wiring.slots,
    wiring.pid,
    wiring.token,
    wiring.expected,
    wiring.artifact,
  ))
  let expires_at = host.monotonic_time_ms() + wiring.request.pause_ms - 100
  scratch.arm_subject(
    wiring.subject,
    abi.Permit(
      wiring.token,
      wiring.expected,
      source.identity(wiring.artifact),
      expires_at,
    ),
    100,
  )
}

// A timeout does not retract an already-sent Acquire or Arm. The same custodian
// orders Disarm after Arm and confirmation after Acquire, and retains ownership
// until both receivers acknowledge those token-scoped effects. It never resumes
// a process it has not attempted to suspend.
fn retire_admission(state: State) -> actor.Next(State, Message) {
  let wiring = state.wiring
  let disarmed = case process.is_alive(wiring.pid) {
    True -> scratch.disarm_subject(wiring.subject, wiring.token, 100)
    False -> Ok(Nil)
  }

  // Send both retirements even if one acknowledgement is delayed. No change
  // request was issued, and an old Arm is followed by its matching Disarm.
  let confirmed =
    slots.confirm(wiring.slots, wiring.pid, wiring.token, wiring.expected)
  let retired = {
    use _ <- result.try(disarmed)
    confirmed
  }
  case retired {
    Error(_) -> actor.continue(state)
    Ok(Nil) -> {
      let reason = case state.outcome {
        Some(Error(reason)) -> reason
        Some(Ok(Nil)) | None -> "harness admission was cancelled"
      }
      process.send(wiring.reply, Error(reason))
      actor.stop()
    }
  }
}

fn start_change(state: State) -> actor.Next(State, Message) {
  let wiring = state.wiring
  case native.suspend(wiring.pid, 100) {
    Error(reason) ->
      finish(State(..state, outcome: Some(Error(reason)), phase: Recovering))
    Ok(Nil) -> {
      let reports = process.new_subject()
      let selector =
        process.new_selector() |> process.select_map(reports, Report)
      let run =
        weft.new([
          fn() {
            native.change(
              wiring.pid,
              source.identity(wiring.artifact).slot,
              wiring.expected.version,
              wiring.token,
              250,
            )
          },
        ])
        |> weft.deadline(300)
        |> weft.cancel_when_exits(wiring.owner)
        |> weft.cancel_when_exits(wiring.pid)
      let _relay = weft.start_relayed(run, to: reports)

      // Preserve the lifetime monitors and inbox while adding the result stream.
      actor.continue(State(..state, phase: Changing))
      |> actor.with_selector(process.merge_selector(selector, state.selector))
    }
  }
}

fn outcome_result(outcome: weft.Outcome(Nil, String)) -> Result(Nil, String) {
  case outcome {
    weft.Completed(value:, ..) -> Ok(value)
    weft.Failed(error:, ..) -> Error(error)
    weft.Crashed(..) -> Error("scratch migration call crashed")
    weft.Abandoned(..) | weft.NeverStarted(..) ->
      Error("scratch migration call was cancelled or expired")
    weft.DrainProofLost(..) | weft.CancellationUnconfirmed(..) ->
      Error("scratch migration call cleanup was not confirmed")
  }
}

fn finish(state: State) -> actor.Next(State, Message) {
  let wiring = state.wiring
  let resumed = native.resume(wiring.pid, 100)
  let elapsed = host.monotonic_time_ms() - state.started_at
  let _retired = scratch.disarm_subject(wiring.subject, wiring.token, 100)
  let observed = scratch.observe_subject(wiring.subject, 100)
  let receipt = settle(wiring, observed, resumed, state.outcome, elapsed)
  case receipt, process.is_alive(wiring.pid) {
    Ok(_), _ | Error(_), False -> {
      process.send(wiring.reply, receipt)
      actor.stop()
    }
    Error(_), True -> actor.continue(state)
  }
}

fn settle(
  wiring: Wiring,
  observed: Result(abi.Observation, String),
  resumed: Result(Nil, String),
  outcome: Option(Result(Nil, String)),
  elapsed: Int,
) -> Result(Receipt, String) {
  use observed <- result.try(observed)
  use _ <- result.try(resumed)
  use _ <- result.try(slots.confirm(
    wiring.slots,
    wiring.pid,
    wiring.token,
    observed.identity,
  ))
  let status = case observed.identity == source.identity(wiring.artifact) {
    True -> "installed"
    False -> "retained"
  }
  let error = case outcome {
    Some(Error(reason)) -> Some(reason)
    Some(Ok(Nil)) -> None
    None -> Some("migration produced no result")
  }
  Ok(Receipt(
    wiring.request.request_id,
    wiring.pid,
    observed,
    status,
    elapsed,
    error,
  ))
}
