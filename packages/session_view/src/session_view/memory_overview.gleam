//// The memory overview: the daemon's board, decoded totally, and the words
//// both hosts use for it (protocol-change/087).
////
//// The overview answers four questions an owner has about the daemon's
//// memory without opening a file: what does each run receive, which notes
//// has the agent written, which rules has a person approved, and how many
//// proposals wait. The daemon answers a `memory_get` read with one board.
//// This module is the client's half of that exchange, and it is read-only:
//// there is nothing to decide, edit or delete here, and a note's body is not
//// in the board at all. The agent reads a body through
//// `history_search kind=note`, and the overview says so.
////
//// Every string in a board is text a model wrote, or a person approved after
//// a model wrote it. The words here pass them through `text_hygiene`, and a
//// host draws them as text. A value this client does not know (an injection
//// mode, a file's state) is kept and shown as unknown, so a daemon ahead of
//// this client does not close the lane.
////
//// The board is a snapshot, not a stream: a host reads it when the overview
//// opens and again after `backstop_ms`, and no push announces a change.

import core/json
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/text_hygiene

/// How long a host that is showing the overview waits before it reads the
/// board again, in milliseconds. A change to memory pushes nothing, so this is
/// the only way an open overview learns of one.
pub const backstop_ms = 60_000

/// The most rows a section carries; the daemon's bound. A longer list is cut
/// rather than refused, so a daemon ahead of this client cannot close the lane
/// with a board it could not draw.
pub const row_limit = 50

/// The words a host shows while the board has not been read.
pub const loading_words = "Reading memory..."

/// The words under the notes heading when there are none.
pub const notes_empty_words =
  "No notes yet. The agent writes one when it learns something worth keeping."

/// The words under the rules heading when there are none.
pub const rules_empty_words = "No approved rules."

/// The sentence that says where a note's body is, since the board carries
/// none.
pub const body_words =
  "Note bodies are not shown here. The agent reads one with history_search kind=note."

/// The sentence that says which setting decides what a run receives.
pub const config_words =
  "Set by [memory] inject in the configuration: off or notes."

/// The sentence that says where the files live, by name only. The directory
/// is the daemon's and is never shown.
pub const files_words =
  "loom-memory.notes (the notes index) and loom-rules.md (the approved rules) live beside the memory store, outside the workspace."

/// The overview the daemon reports.
pub type Board {
  Board(
    /// What `[memory] inject` selects for each run.
    inject: Inject,
    /// The files a run may receive.
    receives: List(Receives),
    /// The newest notes.
    notes: Section(Note),
    /// The approved rules, newest first.
    rules: Section(Rule),
    /// How many proposals wait for a person.
    proposals: Waiting,
  )
}

/// What `[memory] inject` selects.
pub type Inject {
  /// Nothing from the memory store reaches a run.
  InjectsNothing

  /// A bounded index of note titles reaches every run.
  InjectsNotes

  /// A mode this client does not know, as the daemon named it.
  UnknownInject(mode: String)
}

/// What a run does with one file.
pub type Reach {
  /// Every run reads it.
  Injected

  /// It exists and is not read, because `[memory] inject` is off.
  NotInjected

  /// It has not been written yet.
  Missing

  /// It exists and a run leaves it out, for this reason.
  Unreadable(reason: String)

  /// A state this client does not know, as the daemon named it.
  UnknownReach(state: String)
}

/// One file a run may receive, by name, with its size on disk.
pub type Receives {
  Receives(
    /// The file's name. It is a name and never a path.
    file: String,
    /// Its size in bytes, zero when it does not exist.
    bytes: Int,
    /// What a run does with it.
    reach: Reach,
  )
}

/// Whether a note carries the typed fields.
pub type Typing {
  Typed
  Legacy
}

/// One note, without its body.
pub type Note {
  Note(
    /// The note's kind as the daemon named it.
    kind: String,
    /// The UTC date it was written, `YYYY-MM-DD`.
    date: String,
    /// Its title, one line.
    title: String,
    /// Its one-line description; empty for a legacy note.
    description: String,
    /// Whether it was written with the typed fields.
    typing: Typing,
  )
}

/// One approved rule: where it came from and its first line.
pub type Rule {
  Rule(
    /// The proposal that became the rule.
    id: String,
    /// The UTC date of the approval; empty if the file did not say.
    approved: String,
    /// The session that proposed it; empty if the file did not say.
    session: String,
    /// The rule's first line.
    line: String,
  )
}

/// A list the daemon could read, or the reason it could not.
pub type Section(row) {
  /// The rows shown, newest first, how many the store held, and how many of
  /// those the board leaves out.
  Listed(rows: List(row), total: Int, omitted: Int)

  /// The source could not be read. This is never an empty list.
  Unavailable(reason: String)
}

/// How many proposals wait, or why that is unknown.
pub type Waiting {
  Waiting(count: Int)
  WaitingUnavailable(reason: String)
}

/// Decodes the board of a `memory` snapshot. Total: a malformed board is an
/// error, and a mode or state this client does not know is not.
///
/// ## Examples
///
/// ```gleam
/// assert memory_overview.decode(json.Object([])) |> result.is_error
/// ```
pub fn decode(value: json.JsonValue) -> Result(Board, String) {
  use fields <- result.try(object(value, "board"))
  use inject <- result.try(text(fields, "inject"))

  // Decode the receives files array up to the bound.
  use receives <- result.try(case list.key_find(fields, "receives") {
    Ok(json.Array(raw)) -> list.try_map(list.take(raw, 8), decode_receives)
    Ok(_) | Error(Nil) -> Error("missing memory receives")
  })

  use notes <- result.try(section(fields, "notes", decode_note))
  use rules <- result.try(section(fields, "rules", decode_rule))
  use proposals <- result.try(decode_waiting(fields))
  Ok(Board(
    inject: case inject {
      "off" -> InjectsNothing
      "notes" -> InjectsNotes
      other -> UnknownInject(text_hygiene.single_line(other))
    },
    receives:,
    notes:,
    rules:,
    proposals:,
  ))
}

/// Decodes a receives entry for a memory file into a Receives record.
fn decode_receives(value: json.JsonValue) -> Result(Receives, String) {
  use fields <- result.try(object(value, "file"))
  use file <- result.try(text(fields, "file"))
  use state <- result.try(text(fields, "state"))
  use bytes <- result.try(count(fields, "bytes"))

  // Extract the reason text if present, otherwise empty string.
  let reason = case text(fields, "reason") {
    Ok(reason) -> text_hygiene.single_line(reason)
    Error(_) -> ""
  }

  Ok(
    Receives(file: text_hygiene.single_line(file), bytes:, reach: case state {
      "injected" -> Injected
      "off" -> NotInjected
      "missing" -> Missing
      "unavailable" -> Unreadable(reason:)
      other -> UnknownReach(text_hygiene.single_line(other))
    }),
  )
}

/// Decodes a memory section (like notes or rules) from the board fields.
fn section(
  fields: List(#(String, json.JsonValue)),
  name: String,
  decode_row: fn(json.JsonValue) -> Result(row, String),
) -> Result(Section(row), String) {
  // Extract section object by name.
  use body <- result.try(case list.key_find(fields, name) {
    Ok(value) -> object(value, name)
    Error(Nil) -> Error("missing memory section: " <> name)
  })

  use state <- result.try(text(body, "state"))

  // Parse section rows if ok, otherwise return unavailable section.
  case state {
    "ok" -> {
      use total <- result.try(count(body, "total"))
      use omitted <- result.try(count(body, "omitted"))

      // Extract the raw rows array from the section body.
      use raw <- result.try(case list.key_find(body, "rows") {
        Ok(json.Array(raw)) -> Ok(raw)
        Ok(_) | Error(Nil) -> Error("missing memory rows: " <> name)
      })

      use rows <- result.map(list.try_map(list.take(raw, row_limit), decode_row))
      Listed(rows:, total:, omitted:)
    }
    _ ->
      Ok(Unavailable(
        reason: result.unwrap(text(body, "reason"), "unavailable")
        |> text_hygiene.single_line,
      ))
  }
}

/// Decodes a single note JSON object into a Note record.
fn decode_note(value: json.JsonValue) -> Result(Note, String) {
  use fields <- result.try(object(value, "note"))
  use kind <- result.try(text(fields, "kind"))
  use date <- result.try(text(fields, "date"))
  use title <- result.try(text(fields, "title"))
  let description = result.unwrap(text(fields, "description"), "")

  // Check if note is flagged with legacy typing.
  let typing = case list.key_find(fields, "legacy") {
    Ok(json.Bool(True)) -> Legacy
    Ok(_) | Error(Nil) -> Typed
  }

  Ok(Note(
    kind: text_hygiene.single_line(kind),
    date: text_hygiene.single_line(date),
    title: text_hygiene.single_line(title),
    description: text_hygiene.single_line(description),
    typing:,
  ))
}

/// Decodes a single rule JSON object into a Rule record.
fn decode_rule(value: json.JsonValue) -> Result(Rule, String) {
  use fields <- result.try(object(value, "rule"))
  use id <- result.try(text(fields, "id"))
  Ok(Rule(
    id: text_hygiene.single_line(id),
    approved: text_hygiene.single_line(result.unwrap(
      text(fields, "approved"),
      "",
    )),
    session: text_hygiene.single_line(result.unwrap(text(fields, "session"), "")),
    line: text_hygiene.single_line(result.unwrap(text(fields, "line"), "")),
  ))
}

/// Decodes the proposals waiting state into a Waiting record.
fn decode_waiting(
  fields: List(#(String, json.JsonValue)),
) -> Result(Waiting, String) {
  // Extract proposals section object.
  use body <- result.try(case list.key_find(fields, "proposals") {
    Ok(value) -> object(value, "proposals")
    Error(Nil) -> Error("missing memory proposals")
  })

  use state <- result.try(text(body, "state"))

  // Extract pending count if status is ok, otherwise record unavailable.
  case state {
    "ok" -> count(body, "pending") |> result.map(Waiting)
    _ ->
      Ok(WaitingUnavailable(
        reason: result.unwrap(text(body, "reason"), "unavailable")
        |> text_hygiene.single_line,
      ))
  }
}

/// How many notes the board holds in all, or nothing when the notes could not
/// be read.
///
/// ## Examples
///
/// ```gleam
/// assert memory_overview.note_total(board) == Some(3)
/// ```
pub fn note_total(board: Board) -> Option(Int) {
  case board.notes {
    Listed(total:, ..) -> Some(total)
    Unavailable(..) -> None
  }
}

/// How many approved rules the file holds in all, or nothing when it could
/// not be read.
///
/// ## Examples
///
/// ```gleam
/// assert memory_overview.rule_total(board) == Some(2)
/// ```
pub fn rule_total(board: Board) -> Option(Int) {
  case board.rules {
    Listed(total:, ..) -> Some(total)
    Unavailable(..) -> None
  }
}

/// The bytes the files a run reads add up to. A file that exists but is not
/// read, and one that is missing or left out, adds nothing.
///
/// ## Examples
///
/// ```gleam
/// assert memory_overview.injected_bytes(board) == 912
/// ```
pub fn injected_bytes(board: Board) -> Int {
  list.fold(board.receives, 0, fn(sum, file) {
    case file.reach {
      Injected -> sum + file.bytes
      NotInjected | Missing | Unreadable(..) | UnknownReach(..) -> sum
    }
  })
}

/// The four counts a header shows, as a label and its value: notes, approved
/// rules, pending proposals and injected bytes. A value that could not be read
/// is `unavailable`, never zero.
///
/// ## Examples
///
/// ```gleam
/// assert memory_overview.tiles(board) == [#("notes", "3"), ...]
/// ```
pub fn tiles(board: Board) -> List(#(String, String)) {
  [
    #("notes", total_words(note_total(board))),
    #("approved rules", total_words(rule_total(board))),
    #("pending proposals", case board.proposals {
      Waiting(count:) -> int.to_string(count)
      WaitingUnavailable(..) -> "unavailable"
    }),
    #("injected", size_words(injected_bytes(board))),
  ]
}

fn total_words(total: Option(Int)) -> String {
  case total {
    Some(count) -> int.to_string(count)
    None -> "unavailable"
  }
}

/// A size in bytes, in the unit that reads shortest.
///
/// ## Examples
///
/// ```gleam
/// assert memory_overview.size_words(512) == "512 B"
/// assert memory_overview.size_words(1536) == "1.5 KiB"
/// ```
pub fn size_words(bytes: Int) -> String {
  // Format byte size in bytes or KiB depending on threshold.
  case bytes < 1024 {
    True -> int.to_string(bytes) <> " B"
    False -> {
      let tenths = bytes * 10 / 1024
      int.to_string(tenths / 10) <> "." <> int.to_string(tenths % 10) <> " KiB"
    }
  }
}

/// The line that says what `[memory] inject` selects.
///
/// ## Examples
///
/// ```gleam
/// assert memory_overview.inject_words(board) == "[memory] inject = notes"
/// ```
pub fn inject_words(board: Board) -> String {
  // Format injection mode words.
  let mode = case board.inject {
    InjectsNothing -> "off"
    InjectsNotes -> "notes"
    UnknownInject(mode:) -> "unknown (" <> mode <> ")"
  }

  "[memory] inject = " <> mode
}

/// What one file is, in the words the overview uses for it, and what a run
/// does with it.
///
/// ## Examples
///
/// ```gleam
/// assert memory_overview.receives_words(file) == "loom-rules.md · 912 B · every new session reads it"
/// ```
pub fn receives_words(file: Receives) -> String {
  // Normalize memory file names with explanatory labels.
  let name = case file.file {
    "loom-rules.md" -> "loom-rules.md (approved rules)"
    "loom-memory.notes" -> "loom-memory.notes (notes index)"
    other -> other
  }

  name
  <> " · "
  <> case file.reach {
    Injected -> size_words(file.bytes) <> " · every run reads it"
    NotInjected ->
      size_words(file.bytes) <> " · not read, [memory] inject is off"
    Missing -> "not written yet"
    Unreadable(reason:) -> "left out of runs: " <> reason
    UnknownReach(state:) -> "unknown state (" <> state <> ")"
  }
}

/// The first part of a note's row: its kind and date, and a `legacy` marker
/// for a note written before notes were typed.
///
/// ## Examples
///
/// ```gleam
/// assert memory_overview.note_head(note) == "fact · 2026-10-11"
/// ```
pub fn note_head(note: Note) -> String {
  let base = note.kind <> " · " <> note.date

  // Format note header suffix according to typing.
  case note.typing {
    Typed -> base
    Legacy -> base <> " · legacy"
  }
}

/// A note's title with its description after it, when it has one.
///
/// ## Examples
///
/// ```gleam
/// assert memory_overview.note_text(note) == "Tabs: use tabs"
/// ```
pub fn note_text(note: Note) -> String {
  case note.description {
    "" -> note.title
    description -> note.title <> ": " <> description
  }
}

/// The first part of a rule's row: its proposal, the approval date and the
/// short source session, leaving out whatever the file did not say.
///
/// ## Examples
///
/// ```gleam
/// assert memory_overview.rule_head(rule) == "prop-0123456789 · approved 2026-10-11 · session 0198c0de"
/// ```
pub fn rule_head(rule: Rule) -> String {
  // Format approved date if present.
  let approved = case rule.approved {
    "" -> []
    date -> ["approved " <> date]
  }

  // Format short session identity if present.
  let session = case rule.session {
    "" -> []
    session -> ["session " <> string.slice(session, 0, 8)]
  }

  string.join(list.flatten([[rule.id], approved, session]), " · ")
}

/// The line that says rows were left out of a list, or nothing when none were.
/// `pointer` says where the rest can be found.
///
/// ## Examples
///
/// ```gleam
/// assert memory_overview.omitted_words(3, "history_search kind=note finds them") == "+3 more not shown; history_search kind=note finds them"
/// ```
pub fn omitted_words(omitted: Int, pointer: String) -> String {
  case omitted > 0 {
    True -> "+" <> int.to_string(omitted) <> " more not shown; " <> pointer
    False -> ""
  }
}

/// The pointer a list of notes gives for the rows it left out.
pub const notes_pointer = "history_search kind=note finds them"

/// The pointer a list of rules gives for the rows it left out.
pub const rules_pointer = "they are all in loom-rules.md"

/// The sentence about the proposals queue, which this overview counts and
/// does not duplicate. `where` names how the host opens the review.
///
/// ## Examples
///
/// ```gleam
/// assert memory_overview.proposals_words(Waiting(2), "Alt+p") == "2 proposals pending. Review them with Alt+p."
/// ```
pub fn proposals_words(waiting: Waiting, where: String) -> String {
  case waiting {
    Waiting(count: 0) ->
      "No proposals pending. Review them with " <> where <> "."
    Waiting(count: 1) -> "1 proposal pending. Review it with " <> where <> "."
    Waiting(count:) ->
      int.to_string(count)
      <> " proposals pending. Review them with "
      <> where
      <> "."
    WaitingUnavailable(reason:) -> "Proposals unavailable: " <> reason
  }
}

/// The words for a command the daemon refused, by its error code. A code this
/// client does not know is shown with the daemon's own message.
///
/// ## Examples
///
/// ```gleam
/// assert memory_overview.refusal_words("forbidden", "") == "Only the daemon's owner can read the memory overview."
/// ```
pub fn refusal_words(code: String, message: String) -> String {
  case code {
    "forbidden" -> "Only the daemon's owner can read the memory overview."
    "unsupported" -> "This daemon keeps no memory overview."
    _ -> code <> ": " <> text_hygiene.single_line(message)
  }
}

/// Validates that a JSON value is an object and extracts its fields.
fn object(
  value: json.JsonValue,
  what: String,
) -> Result(List(#(String, json.JsonValue)), String) {
  case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error("expected a memory " <> what <> " object")
  }
}

/// Extracts a required string field from key-value pairs.
fn text(
  fields: List(#(String, json.JsonValue)),
  name: String,
) -> Result(String, String) {
  case list.key_find(fields, name) {
    Ok(json.String(value)) -> Ok(value)
    _ -> Error("missing memory text: " <> name)
  }
}

/// Extracts a required non-negative integer count field from key-value pairs.
fn count(
  fields: List(#(String, json.JsonValue)),
  name: String,
) -> Result(Int, String) {
  case list.key_find(fields, name) {
    Ok(json.Int(value)) if value >= 0 -> Ok(value)
    _ -> Error("invalid memory count: " <> name)
  }
}
