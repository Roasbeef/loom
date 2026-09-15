//// `cap/memory` — one durable note, written for the sessions that come
//// after this one.
////
//// This is the code-mode door onto the same memory session the
//// `remember` tool writes through: the same file beside this session's,
//// the same `memory/note` entry type, the same redaction, the same
//// character cap and the same lifetime ceiling. One implementation sits
//// behind both doors, so a note written from a program is
//// indistinguishable from one written as a tool call.
////
//// # Write-only, and that is the shape rather than a gap
////
//// There is no read call here and there will not be one. Memory reaches
//// a later session as quoted context the harness injects at run start,
//// so there is no read door to poison and no argument that could name
//// one. A program cannot choose the entry type either: the host writes
//// `memory/note` and nothing else, which is what keeps a model unable to
//// forge one of the distillation pipeline's own consolidated facts.
////
//// # Every cap is enforced on the far side
////
//// Redaction runs first, the character limit is measured over the
//// *redacted* text, and the lifetime ceiling is a durable counter
//// committed in the note's own transaction. None of the three can be
//// checked from inside a satellite — the first two because this side
//// cannot redact, the third because this side cannot read the counter —
//// so the constants below are what a program plans against and the
//// refusals below are what it actually meets. Write the lesson, not the
//// transcript, and read `NoteTooLong` as arithmetic rather than as an
//// argument.
////
//// # Absent rather than refusing
////
//// A host whose memory store would not open routes this capability to
//// nothing, and a call meets the ordinary unknown-capability denial —
//// `MemoryRefused("unsupported_cap", …)`. Memory holds authority over
//// nothing, so a program that cannot write one carries on.

import cap/internal/channel.{type CallError, Denied, Unreachable}
import cap/internal/dispatch
import cap/internal/wire
import gleam/result

/// The most characters one note may occupy, **measured after
/// redaction** — which is why a note that fits here may still be
/// refused. Two thousand characters is a long paragraph.
pub const max_note_chars = 2000

/// The most notes one repository's memory will accept over its whole
/// life. A lifetime ceiling rather than a rate: the digest that carries
/// memory forward is byte-capped, so an unbounded note count does not
/// grow the injection, it grows the file.
pub const max_notes = 256

/// Why a note could not be written.
///
/// Every variant carries the harness's own sentence, because the harness
/// is where every one of these decisions is made. `MemoryBusy` is the
/// only one worth retrying unchanged.
pub type MemoryError {
  /// The memory session is open for writing elsewhere — a distillation
  /// run holds its lease. Nothing is lost by saying it again later.
  MemoryBusy(message: String)

  /// The note, after redaction, is longer than `max_note_chars`.
  NoteTooLong(message: String)

  /// This repository's memory has already taken `max_notes` notes and
  /// accepts no more.
  MemoryFull(message: String)

  /// The note was empty, or was nothing but whitespace.
  NothingToRemember(message: String)

  /// Memory could not be written at all: the store would not open, or
  /// the capability channel could not carry the call. One variant for
  /// both because a program can do nothing different about either —
  /// carry on without it.
  MemoryUnavailable(reason: String)

  /// Any other in-band refusal, code preserved. A host that routes no
  /// memory store at all answers here, under `unsupported_cap`.
  MemoryRefused(code: String, message: String)
}

/// Writes one durable note into this repository's memory.
///
/// Use it for a lesson, a preference the user stated, or a fact about
/// this repository that cost effort to learn — not for what is already
/// in the files, and not as a scratchpad for the running program. Write
/// it so it still makes sense to a reader with none of this execution's
/// context, because that reader is a session months from now.
///
/// The text is sent exactly as given, untrimmed: trimming here would be
/// a second place deciding what the stored bytes are, and the emptiness
/// question is asked on the far side where the redaction happens.
///
/// Capability: `memory.remember`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(Nil) =
///   memory.remember("The seed cache must be primed before a fresh drive.")
/// ```
///
/// ```gleam
/// case memory.remember(note) {
///   Ok(Nil) -> report.text("remembered")
///   Error(memory.MemoryFull(message:)) -> report.text(message)
///   Error(_other) -> report.text("memory is unavailable; carrying on")
/// }
/// ```
///
pub fn remember(note: String) -> Result(Nil, MemoryError) {
  let args = wire.args([#("note", wire.string(note))])
  dispatch.call("memory.remember", args)
  |> result.replace(Nil)
  |> result.map_error(map_error)
}

// The codes are `codemode/recall`'s own constants, which are in turn the
// strings the `remember` tool puts in its failure details — so a refusal
// a model reads through the tool and one a program branches on here are
// one fact under one name.
fn map_error(error: CallError) -> MemoryError {
  case error {
    Unreachable(reason:) -> MemoryUnavailable(reason:)

    Denied(code:, message:) ->
      case code {
        "memory_busy" -> MemoryBusy(message:)

        "memory_unavailable" -> MemoryUnavailable(reason: message)

        "note_too_long" -> NoteTooLong(message:)

        "memory_full" -> MemoryFull(message:)

        "note_empty" -> NothingToRemember(message:)

        _other -> MemoryRefused(code:, message:)
      }
  }
}
