//// The direct dispatcher: one helper borrowed from the pool seam, one relay
//// process per call, and nothing else between them.
////
//// ## Not a production lane
////
//// Production has one execution model, the executor service
//// (`broker/executor`): a session, the extension build plane and
//// `loom ext check` all start it and give the broker its dispatcher. This
//// module is reached only through `broker.start(BrokerConfig)`, which is
//// built over it, and that entry point has about forty-three callers, all
//// tests and the M3 demo (`client/demo`, whose fake checkout is why it is
//// left on `broker.start`: it is a demonstration, not a production path).
//// `lane_equivalence_test` and `real_lane_test` are the evidence that the two
//// dispatchers agree.
////
//// This is the dispatch machinery the broker carried inline before
//// `broker/dispatch` existed, moved here unchanged behind the seam. A call
//// borrows a helper with the injected `checkout`, spawns a relay process
//// that owns the helper's event subject, sends the helper its `exec_start`,
//// and returns an `Execution` whose closures talk to that helper. The relay
//// forwards output to the caller, enforces the aggregate wall deadline,
//// notices that the caller died, and on the helper's terminal event returns
//// the helper and settles.
////
//// ## Flow
////
//// `dispatcher` → `start` → `relay` → `relay_wake` → `finish`
////
//// 1. `dispatcher` closes the pool's checkout and checkin seams into the
////    record of functions the broker holds.
//// 2. `start` borrows a helper, spawns the relay, waits for its handshake,
////    and sends the helper its exec start before returning.
//// 3. `relay` is the per-call loop. Each turn waits on `relay_wake` for the
////    helper to speak, the caller to die, or the deadline to pass.
//// 4. `finish` reports the terminal verdict; the helper's return is the
////    broker's release call, made when it handles that verdict.
////
//// ## The relay owns the event subject, so `start` waits for it
////
//// A subject is tied to the process that created it, so the relay creates
//// its own `exec_events` subject and hands it back over a `ready` subject.
//// `start` sends nothing to the helper until it holds that subject, which
//// closes the race where `exec_start` could produce output before the relay
//// was listening. If the handshake does not arrive within a second the
//// dispatch is refused as `NotStarted`, after returning the helper.
////
//// `exec.run` stays synchronous inside `start`. A caller that sends stdin
//// the moment `start` returns therefore reaches the helper after the `Run`
//// that began the execution, because both are casts into the one helper
//// mailbox and `Run` was answered first.
////
//// ## Settlement and the helper's return
////
//// The relay only settles; it never returns the helper. The helper goes
//// back to the pool from the `release` closure of the `Execution`, which
//// the broker calls while it processes the relay's `Settle` message, and
//// from `abandon` when the relay dies unsettled. That is exactly where the
//// broker returned the helper before the seam existed, so the ordering is
//// identical to the old code: the relay's `Settle` reaches the broker, the
//// broker demonitors the relay (flushing any queued DOWN) and returns the
//// helper, and a relay that dies after settling can never cause a second
//// return or a cancel of a helper that has been lent to another call. The
//// broker calls `release` or `abandon`, never both, because the one path
//// that demonitors is the one that has seen `Settle`.

import broker/dispatch.{type Dispatcher, type Execution, type StartRefusal}
import broker/exec.{type Helper}
import core/clock.{type Clock}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result

// How long `start` waits for the relay to hand back its event subject.
const relay_ready_ms = 1000

// How long `start` waits for the helper to accept `exec_start`.
const run_wait_ms = 5000

/// Builds the direct dispatcher over a pool's checkout and checkin seams.
/// The returned record holds no process: every call's state lives in that
/// call's own relay and helper.
///
/// ## Examples
///
/// ```gleam
/// let dispatcher =
///   direct.dispatcher(
///     checkout: fn() { exec.checkout(pool, waiting: 15_000) },
///     checkin: fn(helper) { exec.checkin(pool, helper) },
///   )
/// ```
///
pub fn dispatcher(
  checkout checkout: fn() -> Result(Helper, exec.CheckoutError),
  checkin checkin: fn(Helper) -> Nil,
) -> Dispatcher {
  dispatch.Dispatcher(start: fn(request) { start(checkout, checkin, request) })
}

// What a relay does between two turns: the mode it is in. Streaming forwards
// output and watches the wall deadline; Draining is the grace after a
// cancel, waiting for the helper's terminal event.
type RelayMode {
  Streaming
  Draining
}

// Everything one relay loop iteration carries. `caller_watch` is the
// monitor on the process that asked for the call, `None` once it has fired
// or when the call named no live owner.
type Relay {
  Relay(
    exec_events: Subject(exec.ExecEvent),
    caller_watch: Option(process.Monitor),
    deliver: fn(dispatch.Chunk) -> Nil,
    settle: fn(dispatch.Terminal) -> Nil,
    helper: Helper,
    clock: Clock,
    deadline_ms: Int,
    mode: RelayMode,
  )
}

// What wakes a relay: the helper spoke, or the caller died.
type RelayWake {
  FromExec(event: exec.ExecEvent)
  CallerGone
}

// Borrows a helper, starts the relay and dispatches the execution.
fn start(
  checkout: fn() -> Result(Helper, exec.CheckoutError),
  checkin: fn(Helper) -> Nil,
  request: dispatch.Dispatch,
) -> Result(Execution, StartRefusal) {
  use helper <- result.try(
    checkout() |> result.map_error(dispatch.NoHelper(error: _)),
  )

  // A per-call process owning the exec-event subject. It forwards output
  // to the caller, enforces the aggregate wall deadline, and reports
  // settlement. The relay in turn monitors the caller: a tool effect that
  // is killed mid-call can no longer cancel its own execution, and without
  // this watch the jailed command would run on to its wall limit with
  // nobody left to want its output.
  let ready = process.new_subject()
  let relay_pid =
    process.spawn_unlinked(fn() {
      let exec_events = process.new_subject()
      let caller_watch = case request.caller {
        Some(pid) -> Some(process.monitor(pid))
        None -> None
      }
      process.send(ready, exec_events)
      relay(Relay(
        exec_events:,
        caller_watch:,
        deliver: request.deliver,
        settle: request.settle,
        helper:,
        clock: request.clock,
        deadline_ms: request.deadline_ms,
        mode: Streaming,
      ))
    })

  // The relay must own the subject it receives exec events on (subjects
  // are tied to their owning process), so it creates `exec_events` itself
  // and hands it back before anything is dispatched to it. A relay that
  // never answers leaves nothing running, so the helper goes straight back.
  case process.receive(ready, relay_ready_ms) {
    Error(Nil) -> {
      checkin(helper)
      Error(dispatch.NotStarted)
    }
    Ok(exec_events) -> {
      // A refusal here still settles through the relay, so the caller
      // sees exactly one settlement either way.
      case
        exec.run(
          helper,
          request.request,
          events: exec_events,
          waiting: run_wait_ms,
        )
      {
        Ok(Nil) -> Nil
        Error(failure) -> process.send(exec_events, exec.Failed(failure:))
      }

      Ok(execution(request.seq, relay_pid, helper, checkin))
    }
  }
}

// The broker's handle on a started execution: closures over the helper.
fn execution(
  seq: Int,
  relay_pid: process.Pid,
  helper: Helper,
  checkin: fn(Helper) -> Nil,
) -> Execution {
  dispatch.Execution(
    id: dispatch.execution_id(incarnation: 0, seq:),
    guarantor: relay_pid,
    cancel: fn() { exec.cancel(helper) },
    stdin: fn(data, eof) {
      exec.stdin(helper, data:, eof: is_end_of_input(eof))
    },
    // The broker calls this while processing the relay's `Settle`, which
    // is where the helper went back to the pool before the seam existed.
    release: fn() { checkin(helper) },
    // The guarantor died before it could settle: stop whatever it left
    // running, then return the helper, which the pool retires if it died
    // too. The order matters only in that the cancel is a cast into the
    // helper's mailbox ahead of the pool learning it is free.
    abandon: fn() {
      exec.cancel(helper)
      checkin(helper)
    },
  )
}

// The helper's wire flag for the seam's `Eof`.
fn is_end_of_input(eof: dispatch.Eof) -> Bool {
  case eof {
    dispatch.EndOfInput -> True
    dispatch.MoreInput -> False
  }
}

fn relay_wake(link: Relay, within: Int) -> Result(RelayWake, Nil) {
  let selector =
    process.new_selector()
    |> process.select_map(link.exec_events, FromExec)
  let selector = case link.caller_watch {
    Some(monitor) ->
      process.select_specific_monitor(selector, monitor, fn(_down) {
        CallerGone
      })
    None -> selector
  }

  // A streaming relay with no wall deadline waits for as long as it takes;
  // every other turn is bounded by `within`.
  case link.mode, link.deadline_ms {
    Streaming, 0 -> Ok(process.selector_receive_forever(selector))
    Streaming, _finite | Draining, _deadline ->
      process.selector_receive(selector, within)
  }
}

fn relay(link: Relay) -> Nil {
  let #(now, relay_clock) = clock.read(link.clock)
  let link = Relay(..link, clock: relay_clock)
  let remaining = int.max(link.deadline_ms - now, 0)
  case relay_wake(link, remaining + 20) {
    Ok(FromExec(exec.Output(stream:, data:, total_bytes:, truncated:))) -> {
      link.deliver(dispatch.Chunk(stream:, data:, total_bytes:, truncated:))
      relay(link)
    }
    Ok(FromExec(exec.Exited(result:))) ->
      finish(link, dispatch.Completed(result:))
    Ok(FromExec(exec.Failed(failure:))) ->
      finish(link, dispatch.Failed(failure:))

    // The caller is gone, so nothing wants this execution any more:
    // cancel it and drain to the helper's terminal event, which is what
    // returns the helper and the budget slot to the pool. A caller that
    // dies during the drain changes nothing; the cancel is already in.
    Ok(CallerGone) ->
      case link.mode {
        Streaming -> {
          exec.cancel(link.helper)
          let #(cancelled_at, relay_clock) = clock.read(link.clock)

          // Caller death may follow a long quiet receive. The drain gets
          // its full grace from cancellation, rather than from that wait.
          relay(
            Relay(
              ..link,
              clock: relay_clock,
              caller_watch: None,
              deadline_ms: cancelled_at + dispatch.relay_grace_ms,
              mode: Draining,
            ),
          )
        }
        Draining -> relay(Relay(..link, caller_watch: None))
      }
    Error(Nil) ->
      case link.mode {
        // Wall deadline hit: cancel and drain. The helper's own ladder
        // (TERM then KILL, then the pool's outright kill) guarantees a
        // terminal event; Draining's window bounds our trust in that.
        Streaming -> {
          exec.cancel(link.helper)
          let #(cancelled_at, relay_clock) = clock.read(link.clock)

          // The wall wait has finished; the cancellation grace starts now.
          // Reusing its earlier timestamp would immediately expire a quiet
          // execution's drain before the helper could report its exit.
          relay(
            Relay(
              ..link,
              clock: relay_clock,
              deadline_ms: cancelled_at + dispatch.relay_grace_ms,
              mode: Draining,
            ),
          )
        }
        Draining -> finish(link, dispatch.Failed(failure: exec.CancelEscalated))
      }
  }
}

// Ends the relay by reporting the verdict. The helper stays borrowed until
// the broker handles the settlement and calls `release`; returning it here
// would let a relay killed between the return and the settlement make the
// broker `abandon` — and so cancel — a helper another call may already hold.
fn finish(link: Relay, terminal: dispatch.Terminal) -> Nil {
  link.settle(terminal)
}
