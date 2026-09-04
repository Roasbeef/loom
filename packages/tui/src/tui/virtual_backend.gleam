//// An etui backend with no terminal behind it.
////
//// The client's whole behaviour — wrapping, the frame cache, the pacing
//// rules, the order a snapshot and a stream delta land in — only happens
//// inside etui's event loop. Testing `render_frame` alone tests the last
//// step of that and none of it, and an agent asked to check what the client
//// draws had, until now, no way to ask at all. This backend answers a
//// scripted list of events instead of reading a file descriptor, so the real
//// loop can be driven from a test or from `loom replay` and the frames it
//// produced read back as text.
////
//// ## Who owns what
////
//// Etui owns the backend state: `app.run_buffered_cursor_adaptive` threads it
//// through `init`, `render`, `poll` and `next_size` and never hands it back.
//// A rendered frame is therefore not reachable from the backend at all —
//// and it would not be the frame we want if it were, because etui hands a
//// backend the *diff* between two frames as `RenderOp`s, not the grid. The
//// complete grid exists in exactly one place, the render callback, which is
//// a pure function that cannot accumulate.
////
//// So `run_script` wraps that callback and sends every rendered `Buffer` to
//// a `Subject` it creates itself. The loop, the callback and the receive all
//// run in one process, so the send is an append to this process's own
//// mailbox rather than inter-process traffic, and the frames are drained in
//// order once the loop has returned. The `Subject` is created here rather
//// than passed in because a `Subject` delivers to its creator: one made by a
//// caller that then handed the run to another process would deliver frames
//// nobody could receive.
////
//// ## How a script ends
////
//// A poll with a zero timeout is etui's burst drain, never a wait the
//// application asked for — `paced_poll_timeout` returns 8, 40 or 400 — so
//// this backend answers a zero timeout with `Tick`, which ends the burst
//// without being delivered. One scripted event therefore reaches `update`
//// per loop iteration, and each iteration draws one frame.
////
//// Once the steps run out the backend emits a few settling ticks, so a
//// deferred frame is flushed and the inbox is drained, and then reports
//// `Interrupted`. A poll error is how etui's loop ends without a quit key,
//// and it leaves the final model intact.

import etui/app
import etui/backend
import etui/buffer.{type Buffer}
import etui/geometry.{type Position, type Rect}
import gleam/erlang/process.{type Subject}
import gleam/list
import tui/connection

/// One scripted moment in a run.
pub type Step {
  /// An input event delivered to the application exactly as a terminal
  /// backend would deliver it. A `Resize` also changes the size
  /// `next_size` reports from then on, so the two accounts of the screen
  /// cannot drift.
  Input(event: backend.InputEvent)

  /// A connection message placed in the terminal's inbox. The poll that
  /// delivers it returns `Tick`, which is what makes the application drain
  /// the inbox: nothing else in the loop reads it.
  Deliver(message: connection.Message)
}

/// Everything a run needs that is not the application itself.
pub type Script {
  Script(
    /// The screen the run starts at, before any scripted `Resize`.
    size: backend.TerminalSize,
    /// The moments to play, in order.
    steps: List(Step),
    /// The terminal-owned inbox a `Deliver` step sends to. It must be the
    /// same `Subject` the application drains, and it must have been created
    /// by the process calling `run_script`.
    inbox: Subject(connection.Message),
    /// Ticks emitted after the last step, before the run ends. Two is
    /// enough to flush a deferred frame and drain the inbox; a run whose
    /// last step is a `Deliver` that triggers more work may want more.
    settle_ticks: Int,
  )
}

/// The application's side of etui's loop, as four functions.
///
/// Passing these in rather than importing the client keeps this module free
/// of any dependency on `tui`, which is what lets `tui` use it: the replay
/// command lives there and would otherwise close a cycle.
pub type Loop(state) {
  Loop(
    /// The event handler etui calls for every input event.
    update: fn(backend.InputEvent, state) -> state,
    /// The renderer, returning the frame and where the cursor belongs.
    view: fn(state, Rect) -> #(Buffer, Result(Position, Nil)),
    /// Whether the run should stop after the event just applied.
    should_quit: fn(state) -> Bool,
    /// The poll timeout the application would ask a real terminal for.
    poll_timeout: fn(state) -> Int,
  )
}

/// What a finished run produced.
pub type Run(state) {
  Run(
    /// The application state after the last event was applied.
    final: state,
    /// Every frame the loop rendered, oldest first. There is one per loop
    /// iteration, so a frame the client deliberately left stale to pace a
    /// burst appears here as the stale frame it was.
    frames: List(Buffer),
  )
}

/// The backend state. Opaque: only `new` and the loop touch it.
pub opaque type VirtualState {
  VirtualState(
    size: backend.TerminalSize,
    remaining: List(Step),
    inbox: Subject(connection.Message),
    settling: Int,
  )
}

/// A script with two settling ticks, which is what most runs want.
///
/// ## Examples
///
/// ```gleam
/// let script =
///   virtual_backend.script(
///     backend.TerminalSize(width: 80, height: 24),
///     [virtual_backend.Input(backend.KeyPress("/"))],
///     inbox,
///   )
/// ```
pub fn script(
  size: backend.TerminalSize,
  steps: List(Step),
  inbox: Subject(connection.Message),
) -> Script {
  Script(size:, steps:, inbox:, settle_ticks: 2)
}

/// The etui backend a script drives.
///
/// Exposed separately from `run_script` so a caller that wants etui's loop
/// arranged differently — a different `app.run_*`, an `etui/terminal` of its
/// own — still gets the same scripted input.
///
/// ## Examples
///
/// ```gleam
/// let terminal_backend = virtual_backend.new(script)
/// ```
pub fn new(script: Script) -> backend.Backend(VirtualState) {
  let Script(size:, steps:, inbox:, settle_ticks:) = script
  backend.Backend(
    init: fn() {
      Ok(VirtualState(size:, remaining: steps, inbox:, settling: settle_ticks))
    },
    render: fn(state, _ops) { Ok(state) },
    poll: poll,
    next_size: fn(state) { Ok(#(state.size, state)) },
    cleanup: fn(_state) { Nil },
  )
}

/// Runs one script through an application's own loop.
///
/// The error is etui's, and on this backend it can only mean the loop
/// refused to start, which `new` makes unreachable; it is answered rather
/// than asserted away so a future etui that fails differently says so.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(run) = virtual_backend.run_script(loop, model, script)
/// let assert Ok(last) = list.last(run.frames)
/// ```
pub fn run_script(
  loop: Loop(state),
  initial: state,
  script: Script,
) -> Result(Run(state), String) {
  let frames = process.new_subject()

  // The wrapper is the only place a complete frame and a value that outlives
  // the loop are both in scope, so it is where the frame leaves.
  let render = fn(state, screen) {
    let rendered = loop.view(state, screen)
    let #(drawn, _cursor) = rendered
    process.send(frames, drawn)
    rendered
  }
  let outcome =
    app.run_buffered_cursor_adaptive(
      new(script),
      initial,
      render,
      loop.update,
      loop.should_quit,
      loop.poll_timeout,
    )
  case outcome {
    app.Success(final) -> Ok(Run(final:, frames: drain(frames, [])))
    app.Error(reason) -> Error("the virtual terminal loop failed: " <> reason)
  }
}

// Every scripted event goes through here, including the ones etui invents.
// The zero-timeout case is first because it is a question about the loop's
// batching rather than about the script: answering it from the script would
// drain the whole script into one burst and collapse the run to one frame.
fn poll(
  state: VirtualState,
  timeout_ms: Int,
) -> Result(#(backend.InputEvent, VirtualState), backend.Error) {
  case timeout_ms <= 0 {
    True -> Ok(#(backend.Tick, state))
    False -> next_scripted(state)
  }
}

fn next_scripted(
  state: VirtualState,
) -> Result(#(backend.InputEvent, VirtualState), backend.Error) {
  case state.remaining {
    [Input(event: backend.Resize(width, height)), ..rest] -> {
      // The reported size moves with the event so a later `next_size` — an
      // etui restart, an inline viewport recomputation — agrees with what
      // the application was told.
      let resized =
        VirtualState(
          ..state,
          size: backend.TerminalSize(width:, height:),
          remaining: rest,
        )
      Ok(#(backend.Resize(width, height), resized))
    }

    [Input(event:), ..rest] ->
      Ok(#(event, VirtualState(..state, remaining: rest)))

    // The send precedes the tick because the tick is what drains: a message
    // posted after it would wait for the following iteration and land in a
    // frame the script did not intend.
    [Deliver(message:), ..rest] -> {
      process.send(state.inbox, message)
      Ok(#(backend.Tick, VirtualState(..state, remaining: rest)))
    }

    [] -> settle(state)
  }
}

// The script is spent. A few ticks let the application flush a deferred
// frame and drain anything the last step delivered; then the poll fails,
// which is how etui's loop ends when no quit key was scripted.
fn settle(
  state: VirtualState,
) -> Result(#(backend.InputEvent, VirtualState), backend.Error) {
  case state.settling > 0 {
    True ->
      Ok(#(backend.Tick, VirtualState(..state, settling: state.settling - 1)))
    False -> Error(backend.Interrupted)
  }
}

// Frames were appended to this process's own mailbox during the loop, so a
// zero wait is not a race: everything that was sent has already arrived.
fn drain(frames: Subject(Buffer), collected: List(Buffer)) -> List(Buffer) {
  case process.receive(frames, 0) {
    Ok(frame) -> drain(frames, [frame, ..collected])
    Error(Nil) -> list.reverse(collected)
  }
}
