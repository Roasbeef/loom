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
//// It can write one short, typed note: a `title`, a one-line `description`,
//// the `note` itself and a `kind` drawn from a closed list. A note is never
//// held for approval; the model writes it and the owner reads the index
//// afterwards. It cannot choose the entry type — the
//// host writes `memory/note` and nothing else. It cannot read memory back
//// through this tool at all: recall is the bounded index of titles the
//// host injects at run start and `history_search kind=note`, so there is
//// no read door here to poison and no argument that could name one.
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
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import tools/tool.{type Tool, type ToolOutcome}

/// The tool name, as a constant because the host gates registration on
/// the memory plane being reachable and a test asserts on registration
/// rather than on a spelling.
pub const tool_name = "remember"

/// The custom entry type every `remember` write lands under. The only
/// type this door can produce.
pub const note_type = "memory/note"

/// The most characters one note may occupy, **measured after
/// redaction**. Two thousand characters is a long paragraph: a note is a
/// lesson worth carrying into a session months from now, not a transcript.
///
/// Enforced by the seam, for the reason the module doc gives; stated in
/// the tool's description from this same constant so the two cannot
/// drift.
pub const max_note_chars = 2000

/// The most notes one memory session will ever accept, over its whole
/// life. A lifetime ceiling rather than a rate: the index that carries
/// memory into later sessions is byte-capped, so an unbounded note count
/// does not grow the injection — it grows the file, quietly, forever.
/// Enforced by the seam against a durable counter committed in the note's own
/// transaction.
pub const max_notes = 256

/// What a note is for, as a closed list so the index can show it and a
/// search can filter on it. The model picks one; it cannot invent a fourth.
pub type Kind {
  /// A correction or a confirmed way of working the user asked for.
  Feedback

  /// A fact about this repository that cost effort to learn.
  Fact

  /// A choice that was made, with the reason it was made.
  Decision
}

/// Every kind, in the order the tool's schema lists them.
pub const kinds = [Feedback, Fact, Decision]

/// The spelling of a kind in the tool's arguments, the stored entry and
/// the index line.
///
/// ## Examples
///
/// ```gleam
/// assert remember.kind_name(remember.Decision) == "decision"
/// ```
///
pub fn kind_name(kind: Kind) -> String {
  case kind {
    Feedback -> "feedback"
    Fact -> "fact"
    Decision -> "decision"
  }
}

/// The kind a spelling denotes, or `Error(Nil)` for anything else.
///
/// ## Examples
///
/// ```gleam
/// assert remember.kind_named("fact") == Ok(remember.Fact)
/// ```
///
/// ```gleam
/// assert remember.kind_named("lesson") == Error(Nil)
/// ```
///
pub fn kind_named(name: String) -> Result(Kind, Nil) {
  list.find(kinds, fn(kind) { kind_name(kind) == name })
}

/// One note as the model wrote it, before the host redacts and stores it.
///
/// Constructor invariants: none are enforced by the type. `check_line`
/// judges `title` and `description` after redaction, on the far side of the
/// seam, for the reason the module doc gives.
pub type Note {
  Note(kind: Kind, title: String, description: String, text: String)
}

/// The most characters a note's title may occupy, after redaction.
pub const max_title_chars = 80

/// The most characters a note's one-line description may occupy, after
/// redaction.
pub const max_description_chars = 160

/// Why a note could not be written.
pub type Refusal {
  /// A `title` or `description` is empty, runs over its limit, or spans
  /// more than one line. The index prints each on a single line, so a
  /// second line would let a note forge the entries around it.
  FieldInvalid(field: String, reason: String)

  /// The memory session is open for writing elsewhere, such as another
  /// `remember` call holding its lease. Nothing is lost by saying it again
  /// later.
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
/// called with the model's fields exactly as given, untrimmed, because
/// trimming before redaction would be a second place that decides what
/// the stored bytes are.
pub type Memory {
  Memory(remember: fn(Note) -> Result(Nil, Refusal))
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
      <> "sessions that come after this one. Use it for a correction the "
      <> "user gave, a fact about this repository that cost you effort to "
      <> "learn, or a decision and what drove it — not for what is already "
      <> "in the files, and not as a scratchpad for this conversation. "
      <> "State the reason as well as the rule, and say how to apply it, so "
      <> "a reader with none of this conversation can use the note. A note "
      <> "is saved at once and never asks the user. Notes are redacted, "
      <> "capped at "
      <> int.to_string(max_note_chars)
      <> " characters each, and limited to "
      <> int.to_string(max_notes)
      <> " for the life of this repository's memory. Every session starts "
      <> "with an index of titles and descriptions; `history_search` with "
      <> "kind=note returns a note's full text.",
    prompt_snippet: Some(
      "`remember` saves one typed note (feedback, fact or decision) for the "
      <> "sessions that come after this one.",
    ),
    schema: tool.object_schema(
      [
        #(
          "title",
          tool.string_property(
            "a short name for the note, at most "
            <> int.to_string(max_title_chars)
            <> " characters, on one line",
          ),
        ),
        #(
          "description",
          tool.string_property(
            "one line, at most "
            <> int.to_string(max_description_chars)
            <> " characters, saying what the note is about so a later session "
            <> "can decide whether to read it",
          ),
        ),
        #(
          "kind",
          tool.enum_property(
            list.map(kinds, kind_name),
            "feedback: a correction or preference from the user; fact: "
              <> "something true of this repository; decision: a choice and "
              <> "its reason",
          ),
        ),
        #(
          "note",
          tool.string_property(
            "the lesson, preference or fact to carry forward, in one or two "
            <> "sentences, with the reason behind it and how to apply it; "
            <> "write it so it still makes sense to a reader with none of "
            <> "this conversation's context",
          ),
        ),
      ],
      ["title", "description", "kind", "note"],
    ),
    replay: tool.Never,
    execution_mode: tool.Exclusive,
    requirements: empty_requirements,
    run: fn(_ctx, args) { run(memory, args) },
  )
}

fn run(memory: Memory, args: JsonValue) -> ToolOutcome {
  use note <- tool.with_arg(decoded_note(args))
  use Nil <- tool.or_outcome(memory.remember(note), refusal_outcome)
  tool.success(
    "remembered. It will reach later sessions in this repository as quoted "
    <> "memory, not as an instruction — so nothing downstream is obliged to "
    <> "follow it.",
  )
  |> tool.with_details(json.Object([#("stored", json.Bool(True))]))
}

// A missing field, a field of the wrong type and a kind outside the list
// are each refused in band by name, so the model can say it again.
fn decoded_note(args: JsonValue) -> Result(Note, String) {
  use title <- result.try(tool.required_string(args, "title"))
  use description <- result.try(tool.required_string(args, "description"))
  use name <- result.try(tool.required_string(args, "kind"))
  use kind <- result.try(
    kind_named(name)
    |> result.replace_error(
      "`kind` must be one of "
      <> string.join(list.map(kinds, kind_name), ", ")
      <> ", not `"
      <> name
      <> "`",
    ),
  )
  use text <- result.map(tool.required_string(args, "note"))
  Note(kind:, title:, description:, text:)
}

/// Judges one single-line field of a note, after redaction: it must say
/// something, fit its limit, and stay on one line.
///
/// ## Examples
///
/// ```gleam
/// assert remember.check_line("title", "Use tabs", 80) == Ok(Nil)
/// ```
///
/// ```gleam
/// assert remember.check_line("title", "a\nb", 80)
///   == Error(remember.FieldInvalid("title", "must be a single line"))
/// ```
///
pub fn check_line(
  field: String,
  text: String,
  limit: Int,
) -> Result(Nil, Refusal) {
  case
    says_something(text),
    string.contains(text, "\n") || string.contains(text, "\r")
  {
    False, _ -> Error(FieldInvalid(field:, reason: "is empty"))
    True, True -> Error(FieldInvalid(field:, reason: "must be a single line"))

    // Whether the field is over its limit is a question about the first
    // `limit` graphemes, so it is asked that way rather than by measuring
    // the whole string (lint R5). The full length is measured only on the
    // refusal path, where it is the number the model needs.
    True, False ->
      case string.drop_start(text, limit) {
        "" -> Ok(Nil)
        _over ->
          Error(FieldInvalid(
            field:,
            reason: "is "
              <> int.to_string(string.length(text))
              <> " characters and the limit is "
              <> int.to_string(limit),
          ))
      }
  }
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
    FieldInvalid(..) -> "note_field_invalid"
  }
}

fn describe(refusal: Refusal) -> String {
  case refusal {
    MemoryBusy(reason:) ->
      "memory is being written by another call right now ("
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
      <> " notes and accepts no more. Nothing further can be added"
    NothingToRemember -> "`note` is empty. Give the lesson in a sentence or two"
    FieldInvalid(field:, reason:) ->
      "`" <> field <> "` " <> reason <> ". Say it again with that fixed"
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
