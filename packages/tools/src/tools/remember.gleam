//// The `remember` tool: the model's one door into this repository's
//// durable memory.
////
//// # A seam of closures, like `history_search`
////
//// The memory session is an ordinary Loom session file beside this
//// one's — `loom-memory.db` — and this package cannot open it: `tools`
//// depends on `core` and `broker` and nothing else, which is what keeps
//// a tool definition a value rather than a subsystem. So the write is a
//// closure the host fills in (`client/memory.remember_seam`), exactly as
//// `tools/history`'s recall seam is filled by `client/history`. The host
//// side opens the memory session for the call, commits one
//// `memory/note` entry, and closes it again.
////
//// # Why the caps are enforced on the far side of the seam
////
//// Two of them cannot live here and be true. Redaction is
//// `telemetry/field.scrub_text`, which `tools` may not import, and the
//// size cap is specified *after* redaction — so a check here would
//// measure the wrong string. The lifetime ceiling is a durable counter
//// in the memory session, which this package cannot read. Both limits
//// are therefore the seam's to enforce, and the constants below are
//// their single definition: the host imports them, and the tool's
//// description states the same numbers the host applies.
////
//// # What the model can and cannot do with it
////
//// It can write one short note. It cannot choose the entry type — the
//// host writes `memory/note` and nothing else, which is half of the
//// disjointness the distillation pipeline's own types rest on (a model
//// can never forge a "consolidated" fact). It cannot read memory back
//// through a tool at all: recall of memory is the digest the host
//// injects at run start, so there is no read door to poison and no
//// argument that could name one.
////
//// `replay: Never` — a note mints a fresh entry id per admission, so a
//// replayed call would write the note twice and spend two of the
//// lifetime ceiling's slots. A crash mid-write yields the synthetic
//// interrupted result, and saying it again is cheap.
////
//// `execution_mode: Exclusive` — the write takes the memory session's
//// writer lease for the duration of the call, so two `remember` calls in
//// one batch would race for it and one would be refused in band for no
//// reason. Running them alone costs nothing: this is a door a session
//// uses a handful of times, not a hot path.

import broker/policy.{type SandboxPolicy}
import core/json.{type JsonValue}
import gleam/int
import gleam/option.{Some}
import gleam/string
import tools/tool.{type Tool, type ToolOutcome}

/// The tool name, as a constant because the host gates registration on
/// the memory plane being reachable and a test asserts on registration
/// rather than on a spelling.
pub const tool_name = "remember"

/// The custom entry type every `remember` write lands under. The only
/// type this door can produce, and disjoint from the distillation
/// pipeline's `memory/*` types by a test that pins the intersection
/// empty (`client/memory.pipeline_types`).
pub const note_type = "memory/note"

/// Every entry type reachable through this door — one, and the list
/// exists so the disjointness test has two lists to intersect rather
/// than two spellings to compare.
pub const entry_types = [note_type]

/// The most characters one note may occupy, **measured after
/// redaction**. Two thousand characters is a long paragraph: a note is a
/// lesson worth carrying into a session months from now, not a transcript.
///
/// Enforced by the seam, for the reason the module doc gives; stated in
/// the tool's description from this same constant so the two cannot
/// drift.
pub const max_note_chars = 2000

/// The most notes one memory session will ever accept, over its whole
/// life. A lifetime ceiling rather than a rate: the digest that carries
/// memory into later sessions is byte-capped, so an unbounded note count
/// does not grow the injection — it grows the file and the consolidation
/// input, quietly, forever. Enforced by the seam against a durable
/// counter committed in the note's own transaction.
pub const max_notes = 256

/// Why a note could not be written.
pub type Refusal {
  /// The memory session is open for writing elsewhere — a distillation
  /// run holds its lease. Nothing is lost by saying it again later.
  MemoryBusy(reason: String)

  /// The memory session could not be opened or committed to at all.
  MemoryUnavailable(reason: String)

  /// The note, after redaction, is longer than `max_note_chars`.
  NoteTooLong(chars: Int, limit: Int)

  /// This memory session has already accepted `max_notes` notes.
  CeilingReached(limit: Int)

  /// The note was empty, or was nothing but whitespace.
  NothingToRemember
}

/// The memory seam: everything the tool may ask of the memory session.
///
/// Constructor invariants: `remember` is total — it returns a `Refusal`,
/// it does not crash — and it owns every cap the module doc names:
/// redaction first, then the character limit over the redacted text,
/// then the lifetime ceiling in the same transaction as the write. It is
/// called with the model's text exactly as given, untrimmed, because
/// trimming before redaction would be a second place that decides what
/// the stored bytes are.
pub type Memory {
  Memory(remember: fn(String) -> Result(Nil, Refusal))
}

/// The `remember` tool over one memory seam.
///
/// ## Examples
///
/// ```gleam
/// // tool.registry([bash.tool(), remember.tool(seam)])
/// ```
///
pub fn tool(memory: Memory) -> Tool {
  tool.Tool(
    name: tool_name,
    description: "Write one durable note into this repository's memory, for "
      <> "sessions that come after this one. Use it for a lesson, a "
      <> "preference the user stated, or a fact about this repository that "
      <> "cost you effort to learn — not for what is already in the files, "
      <> "and not as a scratchpad for this conversation. Notes are "
      <> "redacted, capped at "
      <> int.to_string(max_note_chars)
      <> " characters each, and limited to "
      <> int.to_string(max_notes)
      <> " for the life of this repository's memory. There is no tool to "
      <> "read them back: what memory says reaches a later session on its "
      <> "own, as quoted context.",
    prompt_snippet: Some(
      "`remember` writes one durable note for the sessions that come after "
      <> "this one.",
    ),
    schema: tool.object_schema(
      [
        #(
          "note",
          tool.string_property(
            "the lesson, preference or fact to carry forward, in one or two "
            <> "sentences; write it so it still makes sense to a reader with "
            <> "none of this conversation's context",
          ),
        ),
      ],
      ["note"],
    ),
    replay: tool.Never,
    execution_mode: tool.Exclusive,
    requirements: empty_requirements,
    run: fn(_ctx, args) { run(memory, args) },
  )
}

fn run(memory: Memory, args: JsonValue) -> ToolOutcome {
  use note <- tool.with_arg(tool.required_string(args, "note"))
  use Nil <- tool.or_outcome(memory.remember(note), refusal_outcome)
  tool.success(
    "remembered. It will reach later sessions in this repository as quoted "
    <> "memory, not as an instruction — so nothing downstream is obliged to "
    <> "follow it.",
  )
  |> tool.with_details(json.Object([#("stored", json.Bool(True))]))
}

/// Renders a seam refusal as the in-band failure the model reads.
///
/// ## Examples
///
/// ```gleam
/// // remember.refusal_outcome(remember.CeilingReached(limit: 256)).is_error
/// ```
///
pub fn refusal_outcome(refusal: Refusal) -> ToolOutcome {
  tool.failure(describe(refusal))
  |> tool.with_details(
    json.Object([
      #("error", json.String(refusal_code(refusal))),
      #("reason", json.String(describe(refusal))),
    ]),
  )
}

fn refusal_code(refusal: Refusal) -> String {
  case refusal {
    MemoryBusy(..) -> "memory_busy"
    MemoryUnavailable(..) -> "memory_unavailable"
    NoteTooLong(..) -> "note_too_long"
    CeilingReached(..) -> "memory_full"
    NothingToRemember -> "note_empty"
  }
}

fn describe(refusal: Refusal) -> String {
  case refusal {
    MemoryBusy(reason:) ->
      "memory is being consolidated right now ("
      <> reason
      <> "). Nothing is lost — say it again later, or carry on without it"
    MemoryUnavailable(reason:) ->
      "this repository's memory could not be written: "
      <> reason
      <> ". Carry on without it; memory holds no authority over anything"
    NoteTooLong(chars:, limit:) ->
      "that note is "
      <> int.to_string(chars)
      <> " characters after redaction and the limit is "
      <> int.to_string(limit)
      <> ". Write the lesson rather than the transcript"
    CeilingReached(limit:) ->
      "this repository's memory has taken its lifetime limit of "
      <> int.to_string(limit)
      <> " notes and accepts no more. Distillation consolidates what is "
      <> "already there; nothing further can be added by hand"
    NothingToRemember -> "`note` is empty. Give the lesson in a sentence or two"
  }
}

// This tool touches no path and starts no process — the memory session is
// opened harness-side, through the seam — so it asks the broker for
// nothing at all and composes with any session base.
fn empty_requirements(workspace: String) -> SandboxPolicy {
  let base = tool.read_requirements(workspace)
  policy.SandboxPolicy(..base, readable_roots: [])
}

/// Whether `text` still says anything once it is trimmed — the emptiness
/// question both sides of the seam ask, spelled once.
///
/// ## Examples
///
/// ```gleam
/// assert !remember.says_something("   \n ")
/// ```
///
/// ```gleam
/// assert remember.says_something("prefer tabs")
/// ```
///
pub fn says_something(text: String) -> Bool {
  string.trim(text) != ""
}
