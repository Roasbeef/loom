//// The memory overview: a read-only snapshot of what the daemon remembers
//// for this workspace and what each run is handed of it
//// (protocol-change/087).
////
//// Memory has four moving parts that were only visible one at a time. The
//// `[memory] inject` key decides whether a run carries the notes index or
//// nothing. The typed notes are the model's own
//// record, searchable with `history_search kind=note`. The approved rules
//// are the standing instructions a person admitted from the proposal queue.
//// The queue itself holds what is waiting. This module reads all four once,
//// bounds what it found, and answers the owner's `memory_get` with one board.
////
//// The board is a snapshot, not a stream. Nothing here pushes: a client reads
//// it when the overview opens and again no more than once a minute, and the
//// `proposals_changed` push is the only invalidation the queue already has.
////
//// ## Flow
////
//// `admin` → `read` → `read_receives` → `read_notes` → `read_rules` → `board`
////
//// 1. `admin` hands the gateway one function over a `Wiring` of the files the
////    host already chose, so the overview can only describe files the host
////    itself reads.
//// 2. `read` assembles an `Overview` from five independent reads. A fault in
////    one is that section's `Unavailable`, never an empty section, so a
////    broken store never reads as "no notes".
//// 3. `read_receives` stats each file the prompt or a run hook reads and
////    reports its size, using the same ceilings those readers refuse above.
//// 4. `read_notes` scans the newest notes through `memory.read_note_entries`,
////    which takes no lease, so a running note write is never waited on and
////    never raced.
//// 5. `read_rules` reads the approved-rules file and lists the rules its
////    `### Rule <id> (approved <date>, from session <sid>)` headers name.
//// 6. `board` encodes the overview. It trims rows until the encoded board
////    fits its byte bound, and every cut shows in the section's omitted
////    count.
////
//// ## What the board does not carry
////
//// Note bodies are not in it: the model reads a body through
//// `history_search`, and the overview points there. No absolute path is in it
//// either, only the files' names. A rule's text beyond its first line is not
//// in it, and text in the rules file outside a header, which only a hand edit
//// can leave, is counted in the file's bytes but listed nowhere.
////
//// ## Bounds
////
//// At most `max_notes_listed` notes and `max_rules_listed` rules, each string
//// clipped to its own limit, and the whole board to `max_board_bytes`. Notes
//// are counted up to the store's lifetime ceiling (`remember.max_notes`), the
//// most a scan reads.

import client/memory
import client/memory_config.{type Injection, type Options}
import client/proposals
import core/entry.{type Entry}
import core/json.{type JsonValue}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import simplifile
import tools/remember

/// The most notes one board lists, newest first.
pub const max_notes_listed = 50

/// The most approved rules one board lists, newest first.
pub const max_rules_listed = 50

/// The longest a note's title may be on the board, in characters.
pub const max_title_chars = 80

/// The longest a note's one-line description may be on the board.
pub const max_description_chars = 160

/// The longest the first line of a rule may be on the board.
pub const max_line_chars = 200

/// The most bytes the encoded board may occupy. Rows are cut from the end of
/// the longer list until it fits, and the cut is counted in `omitted`.
pub const max_board_bytes = 48_000

// The longest reason a fault may carry, so an error from a library cannot
// push the board past its bound on its own.
const max_reason_chars = 200

/// Whether a note was written with the typed fields.
pub type Typing {
  /// Carries a title, a description and a kind.
  Typed

  /// Written before notes were typed: only its text exists, and the title is
  /// that text's first words.
  Legacy
}

/// One note as the board lists it. The body is not here.
///
/// Constructor invariants: every string is one line and within its limit;
/// `date` is the UTC calendar date as `YYYY-MM-DD`.
pub type Note {
  Note(
    kind: String,
    date: String,
    title: String,
    description: String,
    typing: Typing,
  )
}

/// One approved rule as the board lists it: where it came from and its first
/// line. A header that does not carry a date or a session leaves them empty.
pub type Rule {
  Rule(id: String, approved: String, session: String, line: String)
}

/// A list the daemon could read, with how many rows of all it found, or the
/// reason it could not read it.
pub type Section(row) {
  /// `rows` is at most the section's bound, newest first, and `total` is how
  /// many the store held; the difference is what the board omits.
  Listed(rows: List(row), total: Int)

  /// The source could not be read. This is never an empty list.
  Unavailable(reason: String)
}

/// What a run does with one of the files.
pub type Reach {
  /// The file is read into every run.
  Injected

  /// The file exists and is not read, because `[memory] inject` selects
  /// another source.
  NotInjected

  /// The file does not exist yet, which is the ordinary state before the
  /// first note or rule.
  Missing

  /// The file exists and cannot be used, so a run leaves it out.
  Unreadable(reason: String)
}

/// One file a run may receive, by name, with its size on disk.
///
/// Constructor invariants: `file` is a file name and never a path; `bytes` is
/// zero unless the file exists.
pub type Receives {
  Receives(file: String, bytes: Int, reach: Reach)
}

/// How many proposals wait for a person, or why that is unknown.
pub type Waiting {
  Waiting(count: Int)
  WaitingUnavailable(reason: String)
}

/// Everything one `memory_get` reports.
pub type Overview {
  Overview(
    inject: Injection,
    receives: List(Receives),
    notes: Section(Note),
    rules: Section(Rule),
    waiting: Waiting,
  )
}

/// What the host gives this module: the files it already chose and the two
/// settings it already holds.
///
/// Constructor invariants: every path is absolute and chosen by the host from
/// the domain, never by a client or a model; `pending` is total.
pub type Wiring {
  Wiring(
    store_path: String,
    notes_path: String,
    rules_path: String,
    memory: Options,
    pending: fn() -> Result(Int, String),
  )
}

/// The operator's door, for the gateway.
///
/// Constructor invariants: `read` is total.
pub type Admin {
  Admin(read: fn() -> Overview)
}

/// The owner's door over one wiring.
///
/// ## Examples
///
/// ```gleam
/// // gateway.with_memory_overview(options, memory_overview.admin(wiring))
/// ```
///
pub fn admin(wiring: Wiring) -> Admin {
  Admin(read: fn() { read(wiring) })
}

/// Reads the overview. Total: a fault is a section's `Unavailable`.
///
/// ## Examples
///
/// ```gleam
/// // memory_overview.read(wiring)
/// ```
///
pub fn read(wiring: Wiring) -> Overview {
  Overview(
    inject: wiring.memory.inject,
    receives: read_receives(wiring),
    notes: read_notes(wiring.store_path),
    rules: read_rules(wiring.rules_path),
    waiting: case wiring.pending() {
      Ok(count) -> Waiting(count:)
      Error(reason) ->
        WaitingUnavailable(reason: clip(reason, max_reason_chars))
    },
  )
}

// --- the files a run receives -----------------------------------------------

// The rules file is read into every new session's prompt whatever `inject`
// says. The notes index is read only when `inject` names it.
/// Reads read receives through the memory store’s validated path.
fn read_receives(wiring: Wiring) -> List(Receives) {
  let selected = wiring.memory.inject
  [
    stat_file(
      proposals.rules_file,
      wiring.rules_path,
      proposals.max_rules_bytes,
      Injected,
    ),
    stat_file(
      memory.notes_file,
      wiring.notes_path,
      memory.max_notes_sidecar_bytes,
      case selected {
        memory_config.InjectsNotes -> Injected
        memory_config.InjectsNothing -> NotInjected
      },
    ),
  ]
}

// One `stat`, as the readers a run uses do: a file over its ceiling is
// refused unread, so the overview reports what they would, and never reads a
// byte of it.
/// Projects stat file into the bounded memory overview representation.
fn stat_file(
  file: String,
  path: String,
  ceiling: Int,
  reach: Reach,
) -> Receives {
  case simplifile.file_info(path) {
    Error(simplifile.Enoent) -> Receives(file:, bytes: 0, reach: Missing)
    Error(error) ->
      Receives(
        file:,
        bytes: 0,
        reach: Unreadable(reason: clip(string.inspect(error), max_reason_chars)),
      )
    Ok(info) ->
      case info.size > ceiling {
        True ->
          Receives(
            file:,
            bytes: info.size,
            reach: Unreadable(
              reason: "larger than "
              <> int.to_string(ceiling)
              <> " bytes, so a run leaves it out",
            ),
          )
        False -> Receives(file:, bytes: info.size, reach: reach)
      }
  }
}

// --- the notes ---------------------------------------------------------------

// The store is read through `memory.read_note_entries`, the lease-free,
// identity-checked path the history source uses and never opened, so a
// `remember` call holding the writer lease is neither delayed nor raced.
/// Reads read notes through the memory store’s validated path.
fn read_notes(store_path: String) -> Section(Note) {
  // read notes handles the memory.read_note_entries(store_path) outcomes before continuing the operation.
  case memory.read_note_entries(store_path) {
    Error(reason) -> unreadable(reason)
    Ok(found) -> {
      let notes = list.filter_map(found, note_row)
      Listed(
        rows: list.take(notes, max_notes_listed),
        total: list.length(notes),
      )
    }
  }
}

fn unreadable(reason: String) -> Section(row) {
  Unavailable(reason: clip(reason, max_reason_chars))
}

// A note as a row. `note_of` already decodes a legacy payload, so the only
// thing left to ask the entry is whether it had the typed fields.
/// Projects note row into the bounded memory overview representation.
fn note_row(item: Entry) -> Result(Note, Nil) {
  use stored <- result.map(memory.note_of(item))
  Note(
    kind: remember.kind_name(stored.kind),
    date: utc_date(stored.at_ms),
    title: clip(stored.title, max_title_chars),
    description: clip(stored.description, max_description_chars),
    typing: typing_of(item),
  )
}

// The first ten characters of the RFC 3339 form are the UTC date, which is how
// the notes index dates the same note.
fn utc_date(at_ms: Int) -> String {
  timestamp.from_unix_seconds(at_ms / 1000)
  |> timestamp.to_rfc3339(duration.seconds(0))
  |> string.slice(0, 10)
}

/// Projects typing of into the bounded memory overview representation.
fn typing_of(item: Entry) -> Typing {
  case item {
    entry.CustomEntry(data: Some(json.Object(fields)), ..) ->
      case list.key_find(fields, "title") {
        Ok(json.String(_)) -> Typed
        Ok(_) | Error(Nil) -> Legacy
      }
    entry.CustomEntry(..)
    | entry.MessageEntry(..)
    | entry.CompactionEntry(..)
    | entry.BranchSummaryEntry(..) -> Legacy
  }
}

// --- the approved rules ------------------------------------------------------

// The file is small and bounded by the proposal queue's own ceiling. One
// `stat` answers whether it is worth a read, and a file the prompt would
// refuse is reported, not listed.
/// Reads read rules through the memory store’s validated path.
fn read_rules(rules_path: String) -> Section(Rule) {
  case simplifile.file_info(rules_path) {
    Error(simplifile.Enoent) -> Listed(rows: [], total: 0)
    Error(error) -> unreadable(string.inspect(error))
    Ok(info) ->
      case info.size > proposals.max_rules_bytes {
        True -> unreadable("the rules file is over its size limit")
        False ->
          case proposals.read_rules(rules_path) {
            Error(reason) -> unreadable(reason)
            Ok(found) -> listed_rules(proposals.rules_text(found))
          }
      }
  }
}

/// Projects listed rules into the bounded memory overview representation.
fn listed_rules(text: String) -> Section(Rule) {
  let newest_first = rules_in(text)
  Listed(
    rows: list.take(newest_first, max_rules_listed),
    total: list.length(newest_first),
  )
}

/// The rules a rules file lists, newest first, from the headers
/// `client/proposals` writes: `### Rule <id> (approved <date>, from session
/// <sid>)`. A rule's line is the first non-blank line after its header. Text
/// before the first header is not a rule and is skipped. Total.
///
/// ## Examples
///
/// ```gleam
/// assert memory_overview.rules_in("") == []
/// ```
///
pub fn rules_in(text: String) -> List(Rule) {
  collect_rules(string.split(text, "\n"), None, [])
}

// The rules finish in file order, which is approval order, and each is
// pushed on the front of the accumulator, so the accumulator at the end is
// already newest first.
/// Projects collect rules into the bounded memory overview representation.
fn collect_rules(
  lines: List(String),
  current: Option(Rule),
  finished: List(Rule),
) -> List(Rule) {
  case lines {
    [] ->
      case current {
        Some(rule) -> [rule, ..finished]
        None -> finished
      }

    // A header closes the rule before it and opens the next.
    [line, ..rest] ->
      case string.starts_with(line, rule_header) {
        True ->
          collect_rules(rest, Some(header_rule(line)), case current {
            Some(rule) -> [rule, ..finished]
            None -> finished
          })
        False -> collect_rules(rest, with_first_line(current, line), finished)
      }
  }
}

const rule_header = "### Rule "

// The first non-blank line below a header is the rule's line, and later lines
// leave it alone.
/// Projects with first line into the bounded memory overview representation.
fn with_first_line(current: Option(Rule), line: String) -> Option(Rule) {
  case current, string.trim(line) {
    Some(Rule(line: "", ..) as rule), text if text != "" ->
      Some(Rule(..rule, line: clip(text, max_line_chars)))
    _, _ -> current
  }
}

// A header is read leniently: one that does not carry both the date and the
// session still names its rule by whatever follows `### Rule `.
/// Projects header rule into the bounded memory overview representation.
fn header_rule(line: String) -> Rule {
  let rest = string.drop_start(line, string.length(rule_header))

  // header rule handles the string.split_once(rest, " (approved ") outcomes before continuing the operation.
  case string.split_once(rest, " (approved ") {
    Error(Nil) -> Rule(id: clip(rest, 80), approved: "", session: "", line: "")
    Ok(#(id, tail)) ->
      case string.split_once(tail, ", from session ") {
        Error(Nil) ->
          Rule(
            id: clip(id, 80),
            approved: clip(tail, 40),
            session: "",
            line: "",
          )
        Ok(#(approved, session)) ->
          Rule(
            id: clip(id, 80),
            approved: clip(approved, 40),
            session: clip(string.replace(session, ")", ""), 80),
            line: "",
          )
      }
  }
}

// --- the wire ------------------------------------------------------------------

/// Folds a text to one line and cuts it to `limit` characters, marking the
/// cut with an ellipsis.
///
/// ## Examples
///
/// ```gleam
/// assert memory_overview.clip("abcdef", 4) == "abc…"
/// ```
///
pub fn clip(text: String, limit: Int) -> String {
  let one_line =
    text
    |> string.replace("\r", " ")
    |> string.replace("\n", " ")
    |> string.replace("\t", " ")
    |> string.trim

  // clip handles the string.drop_start(one_line, limit) outcomes before continuing the operation.
  case string.drop_start(one_line, limit) {
    "" -> one_line
    _over -> string.slice(one_line, 0, int.max(0, limit - 1)) <> "…"
  }
}

/// The `memory` snapshot's board.
///
/// ```json
/// {"inject":"notes",
///  "receives":[{"file":"loom-rules.md","state":"injected","bytes":512}],
///  "notes":{"state":"ok","total":1,"omitted":0,"rows":[
///    {"kind":"fact","date":"2026-10-11","title":"Tabs","description":"Use tabs","legacy":false}]},
///  "rules":{"state":"ok","total":1,"omitted":0,"rows":[
///    {"id":"prop-0123456789","approved":"2026-10-11","session":"s1","line":"Run make check."}]},
///  "proposals":{"state":"ok","pending":2}}
/// ```
///
/// The board is cut to `max_board_bytes` by dropping rows from the end of the
/// longer list, so the bound holds whatever the store holds, and `omitted`
/// counts every row it leaves out.
///
/// ## Examples
///
/// ```gleam
/// // memory_overview.board(memory_overview.read(wiring))
/// ```
///
pub fn board(overview: Overview) -> JsonValue {
  encode(fitted(overview))
}

// Cuts rows until the encoded board fits. Each pass removes one row, so the
// loop ends, and when both lists are empty there is nothing left to cut.
/// Projects fitted into the bounded memory overview representation.
fn fitted(overview: Overview) -> Overview {
  case bit_array.byte_size(<<json.to_string(encode(overview)):utf8>>) {
    size if size > max_board_bytes ->
      case shrunk(overview) {
        Ok(smaller) -> fitted(smaller)
        Error(Nil) -> overview
      }
    _ -> overview
  }
}

/// Projects shrunk into the bounded memory overview representation.
fn shrunk(overview: Overview) -> Result(Overview, Nil) {
  let notes = listed_count(overview.notes)
  let rules = listed_count(overview.rules)

  // shrunk handles the notes, rules outcomes before continuing the operation.
  case notes, rules {
    0, 0 -> Error(Nil)
    _, _ if notes >= rules ->
      Ok(Overview(..overview, notes: without_last(overview.notes)))
    _, _ -> Ok(Overview(..overview, rules: without_last(overview.rules)))
  }
}

fn listed_count(section: Section(row)) -> Int {
  case section {
    Listed(rows:, ..) -> list.length(rows)
    Unavailable(..) -> 0
  }
}

/// Projects without last into the bounded memory overview representation.
fn without_last(section: Section(row)) -> Section(row) {
  case section {
    Listed(rows:, total:) ->
      Listed(rows: list.take(rows, list.length(rows) - 1), total:)
    Unavailable(..) -> section
  }
}

/// Projects encode into the bounded memory overview representation.
fn encode(overview: Overview) -> JsonValue {
  json.Object([
    #("inject", json.String(inject_word(overview.inject))),
    #("receives", json.Array(list.map(overview.receives, encode_receives))),
    #("notes", encode_section(overview.notes, encode_note)),
    #("rules", encode_section(overview.rules, encode_rule)),
    #("proposals", encode_waiting(overview.waiting)),
  ])
}

fn inject_word(inject: Injection) -> String {
  case inject {
    memory_config.InjectsNothing -> "off"
    memory_config.InjectsNotes -> "notes"
  }
}

/// Projects encode receives into the bounded memory overview representation.
fn encode_receives(receives: Receives) -> JsonValue {
  // encode receives handles the the selected value outcomes before continuing the operation.
  let #(state, reason) = case receives.reach {
    Injected -> #("injected", [])
    NotInjected -> #("off", [])
    Missing -> #("missing", [])
    Unreadable(reason:) -> #("unavailable", [
      #("reason", json.String(reason)),
    ])
  }

  json.Object(
    list.flatten([
      [
        #("file", json.String(receives.file)),
        #("state", json.String(state)),
        #("bytes", json.Int(receives.bytes)),
      ],
      reason,
    ]),
  )
}

/// Projects encode section into the bounded memory overview representation.
fn encode_section(
  section: Section(row),
  encode_row: fn(row) -> JsonValue,
) -> JsonValue {
  case section {
    Listed(rows:, total:) ->
      json.Object([
        #("state", json.String("ok")),
        #("total", json.Int(total)),
        #("omitted", json.Int(int.max(0, total - list.length(rows)))),
        #("rows", json.Array(list.map(rows, encode_row))),
      ])
    Unavailable(reason:) ->
      json.Object([
        #("state", json.String("unavailable")),
        #("reason", json.String(reason)),
      ])
  }
}

/// Projects encode note into the bounded memory overview representation.
fn encode_note(note: Note) -> JsonValue {
  json.Object([
    #("kind", json.String(note.kind)),
    #("date", json.String(note.date)),
    #("title", json.String(note.title)),
    #("description", json.String(note.description)),
    #("legacy", case note.typing {
      Legacy -> json.Bool(True)
      Typed -> json.Bool(False)
    }),
  ])
}

/// Projects encode rule into the bounded memory overview representation.
fn encode_rule(rule: Rule) -> JsonValue {
  json.Object([
    #("id", json.String(rule.id)),
    #("approved", json.String(rule.approved)),
    #("session", json.String(rule.session)),
    #("line", json.String(rule.line)),
  ])
}

/// Projects encode waiting into the bounded memory overview representation.
fn encode_waiting(waiting: Waiting) -> JsonValue {
  case waiting {
    Waiting(count:) ->
      json.Object([
        #("state", json.String("ok")),
        #("pending", json.Int(count)),
      ])
    WaitingUnavailable(reason:) ->
      json.Object([
        #("state", json.String("unavailable")),
        #("reason", json.String(reason)),
      ])
  }
}
