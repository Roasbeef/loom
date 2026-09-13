//// How the terminal loop paces its frames and walks its viewport.
////
//// Two rates live here and neither knows about the model. Frame pacing
//// decides whether one input event's visible change is painted now or held
//// as debt until a burst has drained, and how long the loop then waits
//// before its next poll. Viewport pacing decides how many of the rows a
//// projection already holds the bottom-anchored transcript reveals per
//// rendered frame, so a provider chunk reads as scrolling rather than as a
//// jump. Both are arithmetic over a handful of integers and a
//// classification of the event that arrived, which is why they take those
//// values rather than the model that owns them.
////
//// The boundary is a design one. Everything here is testable without a
//// `Model`, and a call across a module boundary is never an inline attempt,
//// so the Erlang inliner has nothing to expand at these call sites. The
//// glue that reads and writes the model stays in `tui`, and is thin.

import etui/backend
import etui/keys
import gleam/bool
import gleam/int

// Recent terminal or websocket activity keeps input and stream latency
// below a perceptible delay. After a quiet window, the loop backs off so
// reading a completed response does not keep waking and rebuilding the
// terminal.
const active_poll_ms = 40

const quiet_poll_ms = 400

/// How long without activity before the loop moves to the quiet poll.
///
/// It is also the ceiling the inactivity counter saturates at, so a model
/// built by hand starts in the quiet regime by initialising its counter to
/// this value.
pub const quiet_after_ms = 320

/// The shortest gap between two rendered frames while events keep arriving.
///
/// Sixty frames a second is faster than any terminal repaints a full
/// viewport, so a burst paced to this never shows less motion than the
/// terminal could have drawn. It is also the wait between two steps of the
/// viewport walk, since one row is revealed per rendered frame.
pub const frame_interval_ms = 16

// How many transcript rows one rendered frame reveals.
//
// One row is what makes a streamed answer read as scrolling rather than as
// a sequence of jumps. At the frame interval it is still sixty rows a
// second, which is faster than any provider produces them.
const rows_per_frame = 1

// The backlog past which a frame reveals more than `rows_per_frame`.
//
// Twenty-four rows at one row a frame is about four hundred milliseconds
// of lag. Beyond that the reader is watching output the model already
// finished with, which is a worse fault than a slightly larger step.
const catch_up_threshold = 24

// How much of a backlog above the threshold one frame takes.
//
// An eighth is a decay rather than a fixed rate: the step shrinks as the
// backlog does, so the walk lands back on single rows instead of stopping
// dead at the threshold.
const catch_up_divisor = 8

// How long a poll waits for more input before a deferred frame is rendered.
//
// The read only starts once etui's event queue is empty, so this is the gap
// that separates one burst from the next rather than a delay added to each.
const deferred_frame_poll_ms = 8

/// Whether the cached frame still shows every visible change.
///
/// Etui draws one frame per input event, and a wheel flick or a held Page
/// key arrives as a burst of events decoded from one read. Rendering each
/// of them costs a full frame and a viewport-sized terminal diff per event,
/// so a change that lands inside the pacing interval is recorded here
/// instead and rendered once the burst has drained or the interval has
/// passed.
pub type FrameDebt {
  /// The cached frame shows every visible change.
  FrameSettled

  /// A visible change is on screen only as a stale frame, waiting for the
  /// next tick or the next event outside the pacing interval.
  FrameDeferred
}

/// How one input event relates to frame pacing.
pub type FrameBoundary {
  /// A quiet tick or a resize. A tick only arrives once the input queue has
  /// drained and the read has waited without more bytes, so it is where a
  /// deferred frame is flushed; a resize always redraws because the screen
  /// changed shape under the stale frame.
  FlushPoint

  /// A keyboard, paste, or mouse event, which may be one of a burst, or a
  /// tick that carried stream traffic and so belongs to the stream's rate.
  Paced
}

/// Whether the cached frame matches the current screen and revision.
pub type CacheFreshness {
  /// The cached frame is the frame this model would render.
  FrameCurrent

  /// The cache is empty, sized for another screen, or behind the revision.
  FrameStale
}

/// What the terminal loop does with the frame after one event.
pub type FrameDecision {
  /// The cached frame is current; return the exact same term.
  KeepCachedFrame

  /// Render now and restart the pacing interval.
  RenderFrame

  /// Leave the stale frame on screen and render at the next flush point.
  DeferFrame
}

/// Whether the bottom-anchored transcript has shown every row it holds.
///
/// A provider chunk lands as two to five new rows at once. Moving the
/// viewport by all of them in one frame reads as a jump, so the viewport
/// keeps its own position and walks toward the newest row a frame at a
/// time. This says which of the two states that walk is in, and it is the
/// reason a loop with no socket traffic left must still be woken: the rows
/// already in the model have not all been shown yet.
pub type ViewportPacing {
  /// Every rendered row has been revealed; the viewport is at the tail.
  ViewportSettled

  /// Rows are still being revealed a frame at a time.
  ViewportCatchingUp
}

/// What a terminal tick found when it drained the connection.
///
/// A tick is both the idle event that flushes a burst's last deferred frame
/// and the carrier for every stream delta. Those two want opposite pacing,
/// so the tick reports which one it was rather than being classified by its
/// event constructor alone.
pub type TickTraffic {
  /// The tick moved the transcript, so its frame belongs to the stream and
  /// is paced with every other streamed frame.
  TranscriptMoved

  /// The tick changed no transcript row. It is the boundary at which an
  /// earlier burst's deferred frame is rendered.
  TranscriptQuiet
}

/// Whether an input event asks the transcript to move.
///
/// The distinction is what keeps typing from undoing the pacing. Composing
/// a prompt while an answer streams says nothing about where the transcript
/// should be, and snapping on each inserted character would restore the
/// very motion the walk removes; the reference terminal never moves its
/// transcript for a keystroke either. A wheel, a click, a page key or a
/// resize does address it, and the walk must not stand in front of them.
pub type ViewportAddress {
  /// The event asks for a transcript position, so the walk ends here.
  AddressesTranscript

  /// The event is aimed at the composer, at another surface, or at nothing
  /// at all, and the walk continues under it.
  AddressesElsewhere
}

/// How fast a bottom-anchored viewport catches up with rows it has not shown.
///
/// The three bounds answer three different questions, so they are named
/// rather than folded into one rate. `rows_per_frame` is the ordinary step
/// and is what makes streaming read as scrolling. `catch_up_threshold` is
/// the backlog past which a fixed step would leave the reader watching
/// stale output, so the step grows with the backlog. `snap_above` is the
/// growth at which there is no continuity left to preserve — a jump larger
/// than the viewport replaced everything the reader could see — and the
/// viewport moves to the tail in one frame.
pub type PacePolicy {
  PacePolicy(rows_per_frame: Int, catch_up_threshold: Int, snap_above: Int)
}

/// The policy the terminal walks under, with the snap bound supplied.
///
/// The step and the threshold are properties of how streaming should read
/// and so are constants here. The snap bound is the viewport rather than a
/// constant: what makes a jump worth smoothing is that the reader can still
/// see where the text came from, and a growth taller than the screen leaves
/// nothing of it.
///
/// ## Examples
///
/// ```gleam
/// assert pacing.policy(snap_above: 30).snap_above == 30
/// ```
pub fn policy(snap_above snap_above: Int) -> PacePolicy {
  PacePolicy(rows_per_frame:, catch_up_threshold:, snap_above:)
}

/// Advances a revealed row count one frame's worth toward the newest row.
///
/// Walking is for a viewport that already holds a position worth keeping, so
/// three shapes bypass it. A viewport that has revealed nothing has no such
/// position: its first projection is the screen the reader has yet to see,
/// and revealing it a row at a time would animate an arrival rather than a
/// change. A shrink — a tool tail collapsing, a generation cleared — is
/// adopted at once, because there is nothing to reveal and holding retired
/// rows would show text the model no longer has. A growth of `snap_above`
/// or more replaced everything the viewport could show, so there is no
/// continuity left to preserve. Everything else is the ordinary case: one
/// step, enlarged in proportion to the backlog once a fixed step would lag.
///
/// The result never passes `target` and never moves away from it, so the
/// walk terminates for any policy whose `rows_per_frame` is at least one.
///
/// ## Examples
///
/// ```gleam
/// let policy = pacing.PacePolicy(1, 24, 200)
/// assert pacing.pace(10, 15, policy) == 11
/// assert pacing.pace(10, 10, policy) == 10
/// assert pacing.pace(10, 4, policy) == 4
/// assert pacing.pace(0, 15, policy) == 15
/// ```
pub fn pace(revealed: Int, target: Int, policy: PacePolicy) -> Int {
  let backlog = target - revealed
  use <- bool.guard(
    revealed <= 0 || backlog <= 0 || backlog >= policy.snap_above,
    target,
  )

  let step = case backlog > policy.catch_up_threshold {
    True -> int.max(policy.rows_per_frame, backlog / catch_up_divisor)
    False -> policy.rows_per_frame
  }
  revealed + int.min(step, backlog)
}

/// Classifies which way a backlog of unrevealed rows leaves the viewport.
///
/// ## Examples
///
/// ```gleam
/// assert pacing.viewport_pacing(backlog: 0) == pacing.ViewportSettled
/// assert pacing.viewport_pacing(backlog: 3) == pacing.ViewportCatchingUp
/// ```
pub fn viewport_pacing(backlog backlog: Int) -> ViewportPacing {
  case backlog > 0 {
    True -> ViewportCatchingUp
    False -> ViewportSettled
  }
}

/// Reports whether a tick moved the transcript, from the revision it left.
///
/// The transcript revision is bumped at every mutation of the projection's
/// source data and nowhere else, so comparing it across the event is the
/// same question as "did this tick carry a delta, a record or a cut".
///
/// ## Examples
///
/// ```gleam
/// assert pacing.tick_traffic(before: 4, after: 4) == pacing.TranscriptQuiet
/// assert pacing.tick_traffic(before: 4, after: 5) == pacing.TranscriptMoved
/// ```
pub fn tick_traffic(before before: Int, after after: Int) -> TickTraffic {
  case after != before {
    True -> TranscriptMoved
    False -> TranscriptQuiet
  }
}

/// Classifies one event for frame pacing.
///
/// A resize always flushes, because the screen changed shape under the
/// stale frame. Everything a person or a terminal can produce in a burst is
/// paced. A tick is decided by what it carried rather than by being a tick:
/// a tick is both the idle event that flushes a burst's last frame and the
/// carrier for every stream delta, and the second of those was, until this
/// split, the one path with the most traffic and no budget at all. A tick
/// that carried nothing keeps its flushing duty, because a deferred frame
/// has no other event waiting to pay it off.
///
/// Mouse buttons are listed rather than swept up by a catch-all so a new
/// etui event variant is a compile error here, not a silent default.
///
/// ## Examples
///
/// ```gleam
/// assert pacing.frame_boundary(backend.Tick, pacing.TranscriptQuiet)
///   == pacing.FlushPoint
/// assert pacing.frame_boundary(backend.Tick, pacing.TranscriptMoved)
///   == pacing.Paced
/// ```
pub fn frame_boundary(
  event: backend.InputEvent,
  traffic: TickTraffic,
) -> FrameBoundary {
  case event {
    backend.Resize(..) -> FlushPoint
    backend.Tick ->
      case traffic {
        TranscriptQuiet -> FlushPoint
        TranscriptMoved -> Paced
      }
    backend.KeyPress(_)
    | backend.Paste(_)
    | backend.MouseScroll(..)
    | backend.MousePress(..)
    | backend.MouseRelease(..)
    | backend.MouseDrag(..)
    | backend.MouseMove(..) -> Paced
  }
}

/// Decides whether an event's visible change is rendered now or deferred.
///
/// A current cache is always kept. A stale one is rendered at a flush point,
/// or once `frame_interval_ms` has passed since the previous frame; inside
/// the interval it is deferred, which caps a burst at one frame per interval
/// instead of one per event while still moving the screen as the burst runs.
///
/// ## Examples
///
/// ```gleam
/// assert pacing.frame_decision(pacing.Paced, pacing.FrameCurrent, 0)
///   == pacing.KeepCachedFrame
/// assert pacing.frame_decision(pacing.Paced, pacing.FrameStale, 3)
///   == pacing.DeferFrame
/// assert pacing.frame_decision(pacing.Paced, pacing.FrameStale, 16)
///   == pacing.RenderFrame
/// assert pacing.frame_decision(pacing.FlushPoint, pacing.FrameStale, 3)
///   == pacing.RenderFrame
/// ```
pub fn frame_decision(
  boundary: FrameBoundary,
  freshness: CacheFreshness,
  elapsed_ms: Int,
) -> FrameDecision {
  case freshness, boundary {
    FrameCurrent, _ -> KeepCachedFrame
    FrameStale, FlushPoint -> RenderFrame
    FrameStale, Paced ->
      case elapsed_ms >= frame_interval_ms {
        True -> RenderFrame
        False -> DeferFrame
      }
  }
}

/// Says whether an input event addresses the transcript or something else.
///
/// The mouse addresses the transcript whatever it lands on. A press is how
/// the jump hint under a scrolled viewport is taken and it promises the
/// newest row, and a selection drag is a reader holding a position that
/// must not move under the pointer.
///
/// A tick and a bare mouse move are the two events that ask for nothing.
/// The move is listed with the tick rather than with the other buttons for
/// that reason: hover reporting during a generation would otherwise snap the
/// transcript on every motion event and undo the pacing entirely. A paste
/// goes with them because it is composer text arriving in one piece.
///
/// ## Examples
///
/// ```gleam
/// assert pacing.viewport_address(backend.Tick) == pacing.AddressesElsewhere
/// assert pacing.viewport_address(backend.MouseScroll(0, 0, True))
///   == pacing.AddressesTranscript
/// ```
pub fn viewport_address(event: backend.InputEvent) -> ViewportAddress {
  case event {
    backend.Tick | backend.MouseMove(..) | backend.Paste(_) ->
      AddressesElsewhere
    backend.Resize(..)
    | backend.MouseScroll(..)
    | backend.MousePress(..)
    | backend.MouseRelease(..)
    | backend.MouseDrag(..) -> AddressesTranscript
    backend.KeyPress(raw) -> key_viewport_address(keys.match(raw))
  }
}

// The keys that move, submit to, or reshape the transcript. Escape closes
// help, notes and the changes view, each of which returns the reader to a
// transcript that was projected while another surface owned the screen;
// Enter is the submitted prompt appearing at the tail; Ctrl+g re-expands
// every tool block and so replaces the rows outright. A strand or session
// switch needs no key here because the projection it produces is adopted
// whole by the render cache.
//
// Everything else is composition or navigation inside the composer, and the
// modifier keys are listed rather than swept up by a catch-all so a new
// binding is a decision taken here.
fn key_viewport_address(key: keys.Key) -> ViewportAddress {
  case key {
    keys.PageUp
    | keys.PageDown
    | keys.Home
    | keys.End
    | keys.Escape
    | keys.Enter -> AddressesTranscript
    keys.Ctrl("g") -> AddressesTranscript
    keys.Char(_)
    | keys.Up
    | keys.Down
    | keys.Left
    | keys.Right
    | keys.Backspace
    | keys.Delete
    | keys.Tab
    | keys.BackTab
    | keys.Insert
    | keys.F(_)
    | keys.Ctrl(_)
    | keys.Alt(_)
    | keys.Unknown(_) -> AddressesElsewhere
  }
}

/// Returns the active or quiet poll timeout for an inactivity duration.
///
/// ## Examples
///
/// ```gleam
/// assert pacing.poll_timeout_for(0) == 40
/// assert pacing.poll_timeout_for(320) == 400
/// ```
pub fn poll_timeout_for(quiet_for_ms: Int) -> Int {
  case quiet_for_ms >= quiet_after_ms {
    True -> quiet_poll_ms
    False -> active_poll_ms
  }
}

/// Returns the poll timeout, shortened while a deferred frame is waiting.
///
/// The deferred frame is rendered by the tick that follows the burst, and
/// the tick arrives only after a read has waited this long without more
/// bytes. Holding the wait short keeps the last position of a flick from
/// lagging the hand by a whole quiet poll.
///
/// ## Examples
///
/// ```gleam
/// assert pacing.paced_poll_timeout(pacing.FrameDeferred, 0) == 8
/// assert pacing.paced_poll_timeout(pacing.FrameSettled, 0) == 40
/// assert pacing.paced_poll_timeout(pacing.FrameSettled, 320) == 400
/// ```
pub fn paced_poll_timeout(debt: FrameDebt, quiet_for_ms: Int) -> Int {
  case debt {
    FrameDeferred -> deferred_frame_poll_ms
    FrameSettled -> poll_timeout_for(quiet_for_ms)
  }
}

/// Advances inactivity after one poll, resetting immediately on activity.
///
/// The counter saturates at `quiet_after_ms`, so a long idle stretch cannot
/// overflow it and the first activity after one resets it in one step.
///
/// ## Examples
///
/// ```gleam
/// assert pacing.next_quiet_for(100, 40, False) == 140
/// assert pacing.next_quiet_for(100, 40, True) == 0
/// ```
pub fn next_quiet_for(
  quiet_for_ms: Int,
  elapsed_ms: Int,
  activity_seen: Bool,
) -> Int {
  case activity_seen {
    True -> 0
    False -> int.min(quiet_after_ms, quiet_for_ms + elapsed_ms)
  }
}
