//// The capability channel: the single framed seam between a running
//// program and the ToolBroker, and the one place that holds the
//// execution's token.
////
//// ## Why a program cannot forge or bypass it
////
//// This module is an *internal* module (`cap/internal/*`), which the
//// Gleam compiler forbids any other package from importing. A submitted
//// program is a separate package compiled against the cap prelude, so it
//// cannot name this module at all — a compile error caught in the
//// sandboxed build, before a satellite ever runs. The public cap
//// modules (`cap/fs`, `cap/proc`, …) are its only door, and none of them
//// take a channel or a token as an argument: both are held here and
//// fetched per call through `cap/internal/dispatch`. The program can
//// neither supply, read, nor replace them.
////
//// The token itself is 32 broker-minted random bytes, injected once by
//// the boot module (`start`) and never surfaced to *pure* program code. A
//// `cap_call` a program makes always carries *its* token for *its*
//// `{op_id, step_id}`; ordinary program code cannot fabricate a different
//// token to widen policy, and the satellite has no network or distribution
//// to reach another execution's channel.
////
//// ## What the token does and does not defend (CH-F4)
////
//// The token's real job is narrow and worth stating precisely. It
//// **authenticates the channel** — it rejects a socket peer that never
//// read the token file (a cross-execution or external-socket caller) — and
//// it **enables revocation and binds the channel to one
//// `{op_id, step_id, deadline}`**, so a captured token cannot be replayed
//// into another execution or after the deadline.
////
//// The token does **not** confine a hostile `.beam` that slipped vetting.
//// Such a `.beam` carries its own `@external`, so it can read
//// `LOOM_CAP_TOKEN_FILE` and present the genuine token; the token check
//// then passes. What confines that adversary is the **kernel jail** (the
//// cap socket is its only reachable effect) and the **broker's per-call
//// policy check**, which composes and checks policy on every `cap_call`
//// regardless of the token. Confinement is policy plus jail, not the
//// token — do not overstate it.
////
//// ## Kept-alive re-install depends on external reaping (C-F1)
////
//// The channel lives in a VM-global slot the boot module installs per
//// execution. The isolation guarantee for the kept-alive satellite mode is
//// therefore contingent on the executor reaping every process a program
//// spawned before the next execution re-installs: a survivor would
//// otherwise read the new execution's channel on its next cap call.
//// `cap/internal/dispatch.install_exclusive` refuses to overwrite a slot
//// whose channel actor is still alive precisely to make that contingency
//// fail loudly rather than silently.
////
//// ## The channel is an actor
////
//// One actor owns the token, a monotonic call-id counter, and the table
//// of in-flight calls. It marshals each request to a `cap_call` frame
//// (via `cap/internal/wire`) through an injected `send` function — the
//// real framed port write in production, a recorder in tests — and
//// correlates the `cap_result` the broker returns.
////
//// ## The cancel path (structured concurrency's teeth)
////
//// When a `cap/task.race` loser is reaped, structured concurrency simply
//// kills the loser process. That process was blocked awaiting a
//// `cap_result`, so the channel actor — which monitors the caller of
//// every in-flight call — receives a `DOWN` and emits a `cancel` frame
//// correlated to that call's id. The broker revokes the token's effect
//// and kills its executor pgroup. Cancellation is therefore real, not
//// advisory, and needs no cooperation from the dying process.

import cap/internal/wire
import core/msgpack.{type MsgPackValue}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result

/// How long the channel actor's initialiser may take before start fails.
const init_timeout_ms = 1000

/// Slack added to a call's own deadline before the caller gives up
/// waiting for the actor to answer: the broker enforces the real
/// deadline, so this only guards against a wholly dead channel.
const reply_margin_ms = 5000

/// The outcome half of a `cap_result`, decoupled from `broker/framing`
/// so the cap package need not depend on the broker. The J3 satellite
/// read loop maps the broker's `CapOutcome` onto this one when it feeds
/// `deliver`.
pub type CapOutcome {
  /// The capability call succeeded with this value.
  CapOk(value: MsgPackValue)

  /// The capability call failed in-band with a broker error code.
  CapErr(code: String, message: String)
}

/// Why a `cap_call` did not return a value. `Denied` is the broker's own
/// in-band refusal (a policy denial, a bad argument); `Unreachable` is a
/// transport-level failure (the channel was never installed, the frame
/// would not encode, or no answer arrived). Public cap modules map both
/// onto their own typed errors.
pub type CallError {
  /// The broker answered `cap_result` with an error `{code, message}`.
  Denied(code: String, message: String)

  /// The call could not complete at the transport level.
  Unreachable(reason: String)
}

/// The seam the public cap modules consume. `call` performs one
/// synchronous `cap_call`: the cap name, its msgpack args, and a
/// per-call deadline in milliseconds. The token, id allocation, framing,
/// send, and reply correlation are all hidden inside.
pub type Channel {
  Channel(
    call: fn(String, MsgPackValue, Int) -> Result(MsgPackValue, CallError),
  )
}

/// An opaque handle to a started channel actor. The boot module keeps it
/// to `deliver` inbound frames and to `stop` the channel; program code
/// never sees it.
pub opaque type Handle {
  Handle(subject: Subject(Msg))
}

/// The channel actor's message set. Opaque: only this module constructs
/// these, so a program cannot inject a forged `Perform` with someone
/// else's token — it has no way to name the actor's subject.
pub opaque type Msg {
  Perform(
    cap: String,
    args: MsgPackValue,
    deadline_ms: Int,
    caller: Pid,
    reply: Subject(Result(MsgPackValue, CallError)),
  )
  Deliver(id: Int, outcome: CapOutcome)
  CallerDown(down: process.Down)

  /// The inbound reader hit a channel-fatal condition (a malformed frame,
  /// an unsupported version, a closed transport). Every in-flight caller
  /// is answered `Unreachable(reason)` at once instead of being left to
  /// block until its deadline, and the channel latches `failed` so later
  /// calls fail fast the same way — the controlled-shutdown half of the
  /// two-channel doctrine, driven by the J3 boot reader.
  Fail(reason: String)
  Stop
}

type InFlight {
  InFlight(
    reply: Subject(Result(MsgPackValue, CallError)),
    monitor: Monitor,
    caller: Pid,
  )
}

type State {
  State(
    token: BitArray,
    send: fn(BitArray) -> Nil,
    next_id: Int,
    inflight: Dict(Int, InFlight),
    // `Some(reason)` once the reader has reported the channel dead: no
    // further `cap_result` can arrive, so new calls are refused in-band
    // rather than waiting out their deadline.
    failed: Option(String),
  )
}

/// Starts the channel actor holding `token`, writing frames through
/// `send`.
///
/// The boot module (J3) calls this exactly once per execution, before
/// running the program's `main`, then installs `to_channel(handle)` via
/// `cap/internal/dispatch.install` and feeds every inbound `cap_result`
/// frame it deframes to `deliver`. `send` is the framed port write; in
/// tests it is a recorder so the whole marshalling and cancel path is
/// exercised without a live satellite.
pub fn start(
  token: BitArray,
  send: fn(BitArray) -> Nil,
) -> Result(Handle, actor.StartError) {
  actor.new_with_initialiser(init_timeout_ms, fn(subject) {
    let state =
      State(token:, send:, next_id: 0, inflight: dict.new(), failed: None)

    // Select the actor's own subject and, crucially, every monitor DOWN
    // this process sets up — the caller monitors that drive cancellation.
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(CallerDown)
    actor.initialised(state)
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { Handle(subject: started.data) })
}

/// Builds the `Channel` seam over a started handle. Its `call` blocks the
/// calling process until the correlated `cap_result` arrives (or the
/// deadline lapses), which is what lets a killed caller's in-flight call
/// be cancelled by the actor's monitor.
pub fn to_channel(handle: Handle) -> Channel {
  Channel(call: fn(cap, args, deadline_ms) {
    perform(handle.subject, cap, args, deadline_ms)
  })
}

/// Feeds one decoded inbound `cap_result` to the actor. Called by the J3
/// read loop for each such frame, and by tests to simulate the broker.
pub fn deliver(handle: Handle, id: Int, outcome: CapOutcome) -> Nil {
  process.send(handle.subject, Deliver(id:, outcome:))
}

/// Fails the channel: answers every in-flight call `Unreachable(reason)`
/// and latches the channel dead so later calls fail the same way. Called
/// by the J3 boot reader when a frame is malformed or the transport
/// closes — a program blocked awaiting a `cap_result` unblocks at once
/// instead of hanging until its deadline. Fire-and-forget.
pub fn fail(handle: Handle, reason: String) -> Nil {
  process.send(handle.subject, Fail(reason:))
}

/// Stops the channel actor, settling any in-flight calls `Unreachable`
/// in-band on the way out (C-F3) so a blocked program unblocks at once
/// rather than waiting out its deadline. Fire-and-forget; killing the
/// satellite reaps it regardless.
pub fn stop(handle: Handle) -> Nil {
  process.send(handle.subject, Stop)
}

/// Exposes the actor's subject to the boot module, e.g. to build a read
/// loop that forwards frames. Kept internal to the package.
pub fn subject(handle: Handle) -> Subject(Msg) {
  handle.subject
}

fn perform(
  subject: Subject(Msg),
  cap: String,
  args: MsgPackValue,
  deadline_ms: Int,
) -> Result(MsgPackValue, CallError) {
  let reply = process.new_subject()
  process.send(
    subject,
    Perform(cap:, args:, deadline_ms:, caller: process.self(), reply:),
  )
  case process.receive(reply, deadline_ms + reply_margin_ms) {
    Ok(outcome) -> outcome
    Error(Nil) -> Error(Unreachable("no cap_result within deadline"))
  }
}

fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Perform(cap:, args:, deadline_ms:, caller:, reply:) ->
      handle_perform(state, cap, args, deadline_ms, caller, reply)

    Deliver(id:, outcome:) -> handle_deliver(state, id, outcome)

    CallerDown(down:) ->
      case down {
        process.ProcessDown(pid:, ..) -> cancel_for_caller(state, pid)
        process.PortDown(..) -> actor.continue(state)
      }

    Fail(reason:) -> {
      // Unblock every caller waiting on a result that will never arrive,
      // drop their monitors, and latch the failure for subsequent calls.
      settle_inflight(state, reason)
      actor.continue(State(..state, inflight: dict.new(), failed: Some(reason)))
    }

    // Teardown settles in-flight calls in-band before stopping, the same
    // way `Fail` does — a program blocked on a call unblocks with
    // `Unreachable` at once rather than waiting out its deadline (C-F3).
    Stop -> {
      settle_inflight(state, "cap channel stopped")
      actor.stop()
    }
  }
}

// A program asked to perform one capability call. An already-failed
// channel refuses in-band at once; otherwise the call is marshalled and
// tracked in-flight against a monitor on its caller — the tracking that
// makes a killed caller's call cancellable.
fn handle_perform(
  state: State,
  cap: String,
  args: MsgPackValue,
  deadline_ms: Int,
  caller: Pid,
  reply: Subject(Result(MsgPackValue, CallError)),
) -> actor.Next(State, Msg) {
  case state.failed {
    // The reader already declared the channel dead: no result can
    // ever come back, so refuse now rather than after the deadline.
    Some(reason) -> {
      process.send(reply, Error(Unreachable(reason)))
      actor.continue(state)
    }
    None -> {
      let id = state.next_id
      case wire.encode_cap_call(id, state.token, cap, args, deadline_ms) {
        Error(_) -> {
          process.send(reply, Error(Unreachable("cap_call did not encode")))
          actor.continue(State(..state, next_id: id + 1))
        }
        Ok(bytes) -> {
          state.send(bytes)
          let monitor = process.monitor(caller)
          let inflight =
            dict.insert(state.inflight, id, InFlight(reply:, monitor:, caller:))
          actor.continue(State(..state, next_id: id + 1, inflight:))
        }
      }
    }
  }
}

// A `cap_result` arrived for `id`. A result for a call already
// cancelled or already answered is dropped — idempotent by
// construction, since a stale `Deliver` after the caller's monitor
// fired finds nothing left in `inflight`.
fn handle_deliver(
  state: State,
  id: Int,
  outcome: CapOutcome,
) -> actor.Next(State, Msg) {
  case dict.get(state.inflight, id) {
    Error(Nil) -> actor.continue(state)
    Ok(in_flight) -> {
      process.demonitor_process(in_flight.monitor)
      process.send(in_flight.reply, outcome_to_result(outcome))
      actor.continue(State(..state, inflight: dict.delete(state.inflight, id)))
    }
  }
}

// Answers every in-flight caller `Unreachable(reason)` and drops its
// monitor. Shared by the `Fail` (reader-driven) and `Stop` (teardown)
// paths so neither abandons a blocked caller.
fn settle_inflight(state: State, reason: String) -> Nil {
  list.each(dict.to_list(state.inflight), fn(entry) {
    let in_flight = entry.1
    process.demonitor_process(in_flight.monitor)
    process.send(in_flight.reply, Error(Unreachable(reason)))
  })
}

// A monitored caller died before its `cap_result` arrived — the race /
// parallel_map cancellation path. Emit a `cancel` frame for each of its
// in-flight calls so the broker revokes and kills, then drop them. A
// caller has at most one call in flight (a `call` blocks its caller), so
// this is normally a single frame.
fn cancel_for_caller(state: State, pid: Pid) -> actor.Next(State, Msg) {
  let #(dead, alive) =
    list.partition(dict.to_list(state.inflight), fn(entry) {
      { entry.1 }.caller == pid
    })
  list.each(dead, fn(entry) {
    case wire.encode_cancel(entry.0) {
      Ok(bytes) -> state.send(bytes)
      Error(_) -> Nil
    }
  })
  actor.continue(State(..state, inflight: dict.from_list(alive)))
}

fn outcome_to_result(outcome: CapOutcome) -> Result(MsgPackValue, CallError) {
  case outcome {
    CapOk(value:) -> Ok(value)
    CapErr(code:, message:) -> Error(Denied(code:, message:))
  }
}
