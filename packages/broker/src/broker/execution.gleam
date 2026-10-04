//// The pure core of one execution's relay: what to do when something
//// happens, with no process in sight.
////
//// An execution has one process watching it, the relay in `broker/relay`.
//// That process hears from four directions: the helper (output, an exit, a
//// failure), the caller (it may die), the clock (a wall deadline and then a
//// grace), and the service that owns it (a cancel the broker asked for).
//// It also learns, newly in this lane, that its helper's actor died. Each
//// of those is an `Event`, and what the relay does about it is a list of
//// `Effect`s. This module is the function between the two: `step` takes
//// the relay's `Core` and one `Event` and answers the next `Core` and the
//// effects to carry out.
////
//// ## Why it is a function and not a process
////
//// The invariant the relay exists to hold is that an execution is settled
//// **exactly once**, and that is a statement about every possible order of
//// events: a terminal frame racing a deadline, a caller dying during the
//// grace, the helper's death arriving after its own exit. A process can
//// only be tested by scheduling those orders, and the schedulings it gets
//// are the lucky ones. A function can be given every sequence a generator
//// can produce, and `execution_test` does: it feeds random sequences to
//// `step` and checks that no sequence produces two settlements, that none
//// delivers output after settling, and that every terminal event settles.
////
//// The shell, `broker/relay`, only translates: it turns a mailbox message
//// into an `Event`, calls `step`, and performs the `Effect`s. Everything
//// that decides lives here, which is also why this module imports no
//// process library. It does import `broker/exec` for the helper's result
//// and failure types and `broker/dispatch` for the seam's `Chunk` and
//// `Terminal`, because the core settles in the seam's own vocabulary and
//// translating at the edge would only add a place for the two to drift.
////
//// ## What `settled` absorbs
////
//// `Core.settled` starts `Open` and becomes `Settling(terminal)` at the
//// step that emits `Settle`. From then on every event answers
//// `#(core, [])`: no delivery, no cancel, no second settlement. That is
//// how at-most-one settlement is a property of the function and not a
//// discipline of its callers. The name says *settling* and not *settled*
//// because the verdict has only been decided here; the relay still has to
//// ask the service for permission to report it (`MaySettle`) before the
//// broker hears it, and that handshake is `broker/relay`'s.
////
//// ## Cancel, and who sends it
////
//// A cancel can start three ways, and the core treats them differently on
//// purpose.
////
//// - **The caller died** (`CallerDown`) or **the wall deadline passed**
////   (`DeadlineReached`): nobody asked the helper to stop, so the core
////   emits `SendCancel` and `EnterDraining`. Draining is the grace window
////   in which the helper's own TERM-then-KILL ladder is trusted to produce
////   a terminal event; if the grace expires first the execution settles
////   `Failed(CancelEscalated)`, exactly as the direct relay always has.
//// - **The broker cancelled** (`CancelRequested`): the service already
////   forwarded that cancel to the helper before it told the relay, so the
////   core records that a cancel was asked and emits nothing. It does not
////   enter draining either, because today's broker cancel does not move
////   the relay to a draining window: the helper's own cancel grace bounds
////   the wait and reports `CancelEscalated` itself.
////
//// Each of the two timeouts is only meaningful in one mode. A
//// `DeadlineReached` in `Draining` and a `GraceExpired` in `Streaming`
//// cannot fire, since the shell arms each as the state timeout of its own
//// mode and leaving the mode cancels it; the core still answers them with
//// no effect, so that a stale fire the timer book failed to drop could not
//// settle an execution early.
//// ## Transitions
////
//// What each event does in each mode, before the core has settled. Once
//// `settled` is `Settling` every cell is "nothing".
////
//// <!-- transitions: execution.Mode -->
////
//// | state | output | exit or failure | broker cancel | caller down | helper down | deadline reached | grace expired |
//// | --- | --- | --- | --- | --- | --- | --- | --- |
//// | `Streaming` | delivered and counted | settles `Completed` or `Failed` | recorded; mode unchanged; nothing sent | `SendCancel` and `EnterDraining`, mode becomes `Draining` | settles `Failed(ExecutionLost(HelperActorDown))` | `SendCancel` and `EnterDraining`, mode becomes `Draining` | stale, ignored |
//// | `Draining` | delivered and counted | settles `Completed` or `Failed` | recorded; mode unchanged; nothing sent | ignored, the cancel is already in | settles `Failed(ExecutionLost(HelperActorDown))` | stale, ignored | settles `Failed(CancelEscalated)` |

import broker/dispatch
import broker/exec
import broker/framing
import gleam/bit_array

/// Which of the relay's two modes the execution is in. This is the shell's
/// `weft/state_machine` state, and it carries nothing: a state's payload
/// must not change while the machine is in it, because a state timeout
/// dies only when the state compares unequal, and everything that moves
/// per event lives in `Core` instead.
pub type Mode {
  /// Forwarding output and waiting for a terminal event, bounded by the
  /// wall deadline (when there is one).
  Streaming

  /// A cancel has been sent and the relay is waiting, for a bounded grace,
  /// for the helper's terminal event.
  Draining
}

/// Whether any chunk the helper reported had been truncated at its
/// stream's cap. A two-variant type and not a flag, so a field of this
/// type names its question at the call site.
pub type Truncation {
  /// Every chunk seen was complete.
  Whole

  /// At least one chunk arrived after its stream hit the helper's cap.
  Truncated
}

/// What the relay has forwarded so far. Counters only: the execution's
/// output goes to the caller as it arrives and nothing here retains it.
pub type Output {
  Output(
    /// Bytes of stdout delivered to the caller.
    stdout_bytes: Int,
    /// Bytes of stderr delivered to the caller.
    stderr_bytes: Int,
    /// How many chunks were delivered, on both streams.
    chunks: Int,
    /// Whether the helper reported truncation on any delivered chunk.
    truncated: Truncation,
  )
}

/// Who started a cancel. The first cause is the one kept: a later cause
/// does not rewrite the history of why the helper was told to stop.
pub type CancelCause {
  /// The broker cancelled the call (`Broker.cancel`, an abort, a step
  /// abort).
  ByBroker

  /// The process that cleared the call died, so nothing wants the output.
  CallerGone

  /// The aggregate wall deadline passed.
  WallDeadline
}

/// Whether a cancel has been asked of the helper.
pub type CancelState {
  /// No cancel has been sent or recorded.
  NotAsked

  /// A cancel was sent or recorded, for this first cause.
  Asked(cause: CancelCause)
}

/// Whether the core has decided the execution's verdict.
pub type Settledness {
  /// No verdict yet; events can still produce effects.
  Open

  /// The verdict was decided and `Settle` was emitted for it. Absorbing:
  /// no event after this produces an effect.
  Settling(terminal: dispatch.Terminal)
}

/// Everything the core knows about one execution. The shell keeps one per
/// relay and replaces it with the one `step` returns.
pub type Core {
  Core(
    /// Mirrors the shell's state. `EnterDraining` is how the core tells
    /// the shell to follow it.
    mode: Mode,
    /// What has been forwarded so far.
    output: Output,
    /// Whether and why a cancel was asked.
    cancel: CancelState,
    /// Whether the verdict is decided.
    settled: Settledness,
  )
}

/// Something that happened to the execution. Each is the shell's
/// translation of one mailbox message.
pub type Event {
  /// The helper produced a chunk of output.
  ExecOutput(chunk: dispatch.Chunk)

  /// The helper reported the execution complete.
  ExecExited(result: exec.ExecResult)

  /// The helper machine settled the execution as an in-band failure, or
  /// the dispatch itself was refused.
  ExecFailed(failure: exec.ExecFailure)

  /// The broker cancelled the call, and the service has already forwarded
  /// that cancel to the helper.
  CancelRequested

  /// The process that cleared the call died.
  CallerDown

  /// The helper's actor died. Nothing it could have reported will arrive,
  /// because a helper's death notice runs inside the dying actor.
  HelperDown

  /// The wall deadline passed: the `Streaming` state timeout fired.
  DeadlineReached

  /// The grace after a cancel passed: the `Draining` state timeout fired.
  GraceExpired
}

/// What the shell must do after a step, in order.
pub type Effect {
  /// Hand this chunk to the caller.
  Deliver(chunk: dispatch.Chunk)

  /// Ask the service to cancel the helper. The relay never casts to the
  /// helper itself: the service is the helper's only sender, which is what
  /// orders a cancel before the next execution's `Run` by mailbox order.
  SendCancel

  /// Move the shell to `Draining`, arming the grace as its state timeout.
  EnterDraining

  /// Report this verdict. Always the last effect of its step, and emitted
  /// at most once over the life of a core.
  Settle(terminal: dispatch.Terminal)
}

/// A core for an execution that has just started: streaming, nothing
/// forwarded, no cancel asked, no verdict.
///
/// ## Examples
///
/// ```gleam
/// let core = execution.new()
/// assert core.settled == execution.Open
/// ```
///
pub fn new() -> Core {
  Core(
    mode: Streaming,
    output: Output(
      stdout_bytes: 0,
      stderr_bytes: 0,
      chunks: 0,
      truncated: Whole,
    ),
    cancel: NotAsked,
    settled: Open,
  )
}

/// Applies one event to a core, answering the next core and the effects
/// to perform in order.
///
/// The function is total and pure. Once a core has settled it answers
/// `#(core, [])` for every event, so over any sequence of events at most
/// one `Settle` is ever produced, and nothing is delivered after it.
///
/// ## Examples
///
/// ```gleam
/// let #(core, effects) = execution.step(execution.new(), execution.HelperDown)
/// assert effects
///   == [
///     execution.Settle(
///       dispatch.Failed(exec.ExecutionLost(cause: exec.HelperActorDown)),
///     ),
///   ]
/// assert execution.step(core, execution.CallerDown) == #(core, [])
/// ```
///
pub fn step(core: Core, event: Event) -> #(Core, List(Effect)) {
  case core.settled {
    Settling(_) -> #(core, [])
    Open -> step_open(core, event)
  }
}

// The events of an execution that has not yet settled. Every event is
// written out, with no catch-all, so a new event is a compile error here.
fn step_open(core: Core, event: Event) -> #(Core, List(Effect)) {
  case event {
    // Output is forwarded in arrival order in both modes: a draining
    // execution is still producing the bytes the caller will want to see
    // if the cancel arrives late.
    ExecOutput(chunk:) -> #(Core(..core, output: tally(core.output, chunk)), [
      Deliver(chunk:),
    ])

    // The two terminal events of the helper's own contract. Whichever
    // arrives first is the verdict.
    ExecExited(result:) -> settle(core, dispatch.Completed(result:))
    ExecFailed(failure:) -> settle(core, dispatch.Failed(failure:))

    // The broker's cancel reached the helper through the service before
    // the relay heard of it, so there is nothing for the relay to send.
    // The mode stays `Streaming`, as the direct relay's did: it never
    // learned of a broker cancel at all, and the helper's own cancel
    // grace is what bounds the wait.
    CancelRequested -> #(Core(..core, cancel: ask(core.cancel, ByBroker)), [])

    // Nobody wants this execution any more: cancel and drain to the
    // helper's terminal event, which is what returns the helper and the
    // budget slot. A caller that dies during the drain changes nothing;
    // the cancel is already in.
    CallerDown -> start_draining(core, CallerGone)

    // The wall deadline: cancel and drain, as for a dead caller. The
    // helper's ladder guarantees a terminal event and the grace bounds
    // our trust in that.
    DeadlineReached -> start_draining(core, WallDeadline)

    // The grace ran out in `Draining`: the helper did not answer its own
    // ladder within the window, so the execution is declared unkillable.
    // In `Streaming` the fire cannot happen, and if it did it would have
    // no cancel behind it to have expired.
    GraceExpired ->
      case core.mode {
        Draining -> settle(core, dispatch.Failed(failure: exec.CancelEscalated))
        Streaming -> #(core, [])
      }

    // The helper's actor is gone, so no terminal event will ever come: a
    // dying helper notifies from inside itself, and a relay that waited
    // would wait until a deadline that may not exist. The execution may
    // have started, so the verdict is a loss and never a refusal.
    HelperDown ->
      settle(
        core,
        dispatch.Failed(failure: exec.ExecutionLost(cause: exec.HelperActorDown)),
      )
  }
}

// Decides the verdict: record it and emit it, once.
fn settle(core: Core, terminal: dispatch.Terminal) -> #(Core, List(Effect)) {
  #(Core(..core, settled: Settling(terminal:)), [Settle(terminal:)])
}

// Asks for a cancel and begins the grace. Only a streaming execution does:
// a draining one has its cancel in already.
fn start_draining(core: Core, cause: CancelCause) -> #(Core, List(Effect)) {
  case core.mode {
    Streaming -> #(
      Core(..core, mode: Draining, cancel: ask(core.cancel, cause)),
      [SendCancel, EnterDraining],
    )
    Draining -> #(core, [])
  }
}

// Records the first cause for a cancel and ignores later ones.
fn ask(state: CancelState, cause: CancelCause) -> CancelState {
  case state {
    NotAsked -> Asked(cause:)
    Asked(_) -> state
  }
}

// Adds one delivered chunk to the counters.
fn tally(output: Output, chunk: dispatch.Chunk) -> Output {
  let size = bit_array.byte_size(chunk.data)
  let #(stdout_bytes, stderr_bytes) = case chunk.stream {
    framing.Stdout -> #(output.stdout_bytes + size, output.stderr_bytes)
    framing.Stderr -> #(output.stdout_bytes, output.stderr_bytes + size)
  }
  Output(
    stdout_bytes:,
    stderr_bytes:,
    chunks: output.chunks + 1,
    truncated: case chunk.truncated, output.truncated {
      True, _ | False, Truncated -> Truncated
      False, Whole -> Whole
    },
  )
}
