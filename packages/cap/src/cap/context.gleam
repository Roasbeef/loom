//// `cap/context` — how full the calling strand's context window is,
//// asked by a program rather than by the model.
////
//// This is the code-mode door onto the same arithmetic the
//// `context_remaining` tool reads, over the very same seam: one
//// projection, one estimate, one boundary. A report a program reads and
//// a report a model is told are the same numbers about the same moment,
//// which is the ruling `cap/history` states in its own header and the
//// reason this module exists rather than a second accounting.
////
//// # Why a program wants the number at all
////
//// A model that is nearly full can only be *told* so, by the near-limit
//// reminder the harness appends inside the last reserve. A program can
//// compute on it: hand a repository-wide scan to a subagent rather than
//// reading it into this context, summarise a build log instead of
//// returning it whole, or stop short of a fan-out whose joined reports
//// would not fit. The report's fields are the inputs to that arithmetic
//// and nothing here does it for the caller — `boundary` says where the
//// cut is and `used_tokens` says where the context is, and the
//// subtraction is the program's own.
////
//// # The numbers are the harness's estimate, and that is the point
////
//// They are the newest provider-reported usage plus a
//// characters-over-four count for everything after it. They are not the
//// provider's own tokenizer and they do not claim to be. What they are
//// is exactly what the compaction threshold will act on, so a program
//// planning against them is planning against the decision that will
//// actually be taken.
////
//// # What this call cannot do
////
//// It reads. There is no call that moves the boundary, asks for a
//// checkpoint early, or reports on another strand: the strand is the
//// one whose driver dispatched this execution, read by the harness from
//// the dispatching call and never named on the wire. A program that
//// could name a strand could read the context of a sibling it did not
//// start.
////
//// # Absent rather than refusing
////
//// A host that wired no context seam routes this capability to nothing
//// and a call meets the ordinary unknown-capability denial —
//// `ContextRefused("unsupported_cap", …)`. That is `cap/schedule`'s
//// posture: the report holds authority over nothing, so a program that
//// cannot read one carries on with whatever it would have done anyway.

import cap/internal/channel.{type CallError, Denied, Unreachable}
import cap/internal/dispatch
import cap/internal/wire
import core/msgpack.{type MsgPackValue}
import gleam/result

/// Where the strand's window ends, as its compaction settings put it.
///
/// The two variants are the two regimes a program plans differently
/// against: under `CheckpointAt` the older part of the context is
/// replaced by the strand's own notes and work continues, while under
/// `NoCheckpoint` nothing is cut and a request that outgrows the window
/// is refused by the provider outright.
pub type Boundary {
  /// Compaction is on: the threshold compacts once the context passes
  /// `tokens`, keeping the newest `keep_recent_tokens` verbatim.
  CheckpointAt(tokens: Int, keep_recent_tokens: Int)

  /// Compaction is off on this host. Nothing is cut, and the window
  /// itself is the only ceiling.
  NoCheckpoint
}

/// One answer: the calling strand's window as the harness measures it.
///
/// Constructor invariants, restated from the harness that fills them:
/// `window` is the one-based ordinal of the window the strand is in, so
/// a strand that has never compacted is in window one; `used_tokens` is
/// the threshold's own estimate of the current context; `notes` counts
/// the strand's blackboard cells, which is what survives a checkpoint.
pub type Report {
  Report(
    /// The strand the answer is about — the calling one, always.
    strand: String,
    /// Which window this is, counting from one.
    window: Int,
    /// The strand's context window, in tokens.
    context_window: Int,
    /// What the context costs now, as the threshold estimates it.
    used_tokens: Int,
    /// Where the boundary is.
    boundary: Boundary,
    /// How many notes the strand has written.
    notes: Int,
  )
}

/// Why a context report could not be read.
///
/// Both variants are `carry on` rather than `repair the call`: there is
/// no argument to get wrong, so nothing a program could send differently
/// would change the answer.
pub type ContextError {
  /// The report could not be built: the strand's branch or its notes
  /// would not read, the capability channel could not carry the call, or
  /// the answer was not the shape this module decodes. One variant for
  /// all of them because a program can do nothing different about any.
  ContextUnavailable(reason: String)

  /// Any other in-band refusal, code preserved. A host that wired no
  /// context seam at all answers here, under `unsupported_cap`.
  ContextRefused(code: String, message: String)
}

/// Reads the calling strand's context report.
///
/// Takes no arguments, because the only thing it could take is the
/// identity of somebody else. Use it to decide *where* work happens
/// rather than whether it happens: a program that finds little room left
/// should delegate the reading of a large result to a subagent, or
/// summarise rather than return, and one that finds plenty should get on
/// with it.
///
/// Capability: `context.report`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(report) = context.report()
/// let room = case report.boundary {
///   context.CheckpointAt(tokens:, ..) -> tokens - report.used_tokens
///   context.NoCheckpoint -> report.context_window - report.used_tokens
/// }
/// ```
///
/// ```gleam
/// let crowded = case context.report() {
///   Ok(context.Report(used_tokens:, context_window:, ..)) ->
///     used_tokens * 4 > context_window * 3
///   Error(_unavailable) -> False
/// }
/// ```
///
pub fn report() -> Result(Report, ContextError) {
  use value <- result.try(
    dispatch.call("context.report", wire.args([]))
    |> result.map_error(map_error),
  )
  decode_report(value)
  |> result.map_error(fn(reason) {
    ContextUnavailable("bad context.report result: " <> reason)
  })
}

// --- total decoders ------------------------------------------------------

fn decode_report(value: MsgPackValue) -> Result(Report, String) {
  use strand <- result.try(wire.string_field(value, "strand"))
  use window <- result.try(wire.int_field(value, "window"))
  use context_window <- result.try(wire.int_field(value, "context_window"))
  use used_tokens <- result.try(wire.int_field(value, "used_tokens"))
  use boundary <- result.try(decode_boundary(value))
  use notes <- result.try(wire.int_field(value, "notes"))
  Ok(Report(strand:, window:, context_window:, used_tokens:, boundary:, notes:))
}

// The boundary travels as a tag beside its own two numbers rather than
// as a nested map, because msgpack has no variant shape and a nested map
// would need the same tag one level down. An unrecognised tag is a
// decode failure rather than a defaulted `NoCheckpoint`: reading "the
// host names a boundary this program does not know" as "there is no
// boundary" would have a program plan for a cut that is coming.
fn decode_boundary(value: MsgPackValue) -> Result(Boundary, String) {
  use tag <- result.try(wire.string_field(value, "boundary"))
  case tag {
    "checkpoint" -> {
      use tokens <- result.try(wire.int_field(value, "checkpoint_tokens"))
      use keep <- result.try(wire.int_field(value, "keep_recent_tokens"))
      Ok(CheckpointAt(tokens:, keep_recent_tokens: keep))
    }

    "none" -> Ok(NoCheckpoint)

    other -> Error("unknown boundary `" <> other <> "`")
  }
}

// The code is `codemode/recall`'s own constant, which is in turn the
// sentence the harness's seam answered with — so a refusal a model reads
// through the tool and one a program branches on here are one fact under
// one name.
fn map_error(error: CallError) -> ContextError {
  case error {
    Unreachable(reason:) -> ContextUnavailable(reason:)

    Denied(code:, message:) ->
      case code {
        "context_unavailable" -> ContextUnavailable(reason: message)

        _other -> ContextRefused(code:, message:)
      }
  }
}
