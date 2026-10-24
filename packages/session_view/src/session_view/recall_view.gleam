//// How a `history_search` call and its hits read on a screen.
////
//// The tool answers a model in prose, a numbered list of hits inside a
//// `history` fence, because the model reads text. A reader following the
//// work wants something else: which words were searched for, under which
//// filters, how many hits came back, and one scannable line for each hit
//// that says where it came from. The tool also puts every hit in its
//// result's `details`, as data, so this module reads that and never parses
//// the prose back out.
////
//// Everything here is session text. A query is what the model typed, a
//// snippet is something some model or person wrote months ago in another
//// session, and the hits are decoded from a record that may be old, cut or
//// hand-edited. The decoders are total: a `details` that is not the shape
//// the tool writes yields `None`, and the host falls back to the plain
//// rendering every tool has. Nothing is trusted to be well formed, and
//// nothing here can fail a render.
////
//// The module draws nothing and holds no `@external`. `transcript_lines`
//// turns its strings into rows, and `step_words` counts the decoded hits for
//// the step's done words, so the terminal and the web view agree on both.
////
//// ## Flow
////
//// `call_summary` → `hits` → `hit_rows`
////
//// 1. `call_summary` words the call from its arguments: the query and any
////    filters, or the entry a read names.
//// 2. `hits` decodes a settled call's details record into `Hit`s, or `None`.
//// 3. `count_text` and `hit_rows` say how many came back and show one row
////    for each, at the extent the host asked for.

import core/json.{type JsonValue}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/notes_view
import session_view/text_hygiene

/// The tool whose calls and results this module words.
pub const tool_name = "history_search"

/// How many hits a collapsed result shows before it says how many more
/// there are. The expanded result shows every one.
pub const excerpt_hits = 3

// The most characters of a snippet a collapsed hit row keeps, and the most
// an expanded one keeps. The tool already returns excerpts, so the second
// is a bound on a record that holds something longer, not a cut of a
// normal one.
const excerpt_snippet = 100

const complete_snippet = 400

// The most characters of a query a summary keeps.
const query_limit = 80

/// One hit of a search, as the tool's result recorded it.
///
/// Constructor invariants: `session` and `entry` are the identifier texts
/// the entry was indexed under, kept whole; `kind` is empty for a row the
/// index recorded before it kept kinds; `ts` is milliseconds since the
/// epoch, or 0 for such a row; `snippet` is session text, possibly spanning
/// lines.
pub type Hit {
  Hit(
    /// The session the entry belongs to.
    session: String,
    /// The entry that matched.
    entry: String,
    /// What the entry was: `user`, `assistant`, `tool`, `summary`, `note`.
    kind: String,
    /// When the entry was written, in milliseconds since the epoch.
    ts: Int,
    /// The words around the match.
    snippet: String,
  )
}

/// The hits a settled search recorded in its result's `details`, in the order
/// the tool ranked them, or `None` when `details` is not that record.
///
/// One malformed hit makes the whole record unusable rather than quietly
/// dropping it, so a count shown beside the rows is never smaller than the
/// tool said. A `read` result carries blob details and no hits, so it is
/// `None` here as well and keeps the plain rendering.
///
/// ## Examples
///
/// ```gleam
/// assert recall_view.hits(json.Object([#("hits", json.Array([]))])) == Some([])
/// assert recall_view.hits(json.String("oops")) == None
/// ```
pub fn hits(details: JsonValue) -> Option(List(Hit)) {
  case details {
    json.Object(fields) ->
      case list.key_find(fields, "hits") {
        Ok(json.Array(entries)) ->
          entries |> list.try_map(hit) |> option.from_result
        _ -> None
      }
    _ -> None
  }
}

/// Decodes one search hit from its JSON object fields.
fn hit(value: JsonValue) -> Result(Hit, Nil) {
  // Decode the hit from an object shape or fail if malformed.
  case value {
    json.Object(fields) -> {
      use session <- result.try(text(fields, "session"))
      use entry <- result.try(text(fields, "entry"))
      use snippet <- result.try(text(fields, "snippet"))
      Ok(Hit(
        session:,
        entry:,
        kind: result.unwrap(text(fields, "kind"), ""),
        ts: result.unwrap(whole(fields, "ts"), 0),
        snippet:,
      ))
    }
    _ -> Error(Nil)
  }
}

/// How many hits a result found, as a reader says it: `3 hits`, `1 hit`,
/// `no hits`.
///
/// ## Examples
///
/// ```gleam
/// assert recall_view.count_text(0) == "no hits"
/// assert recall_view.count_text(1) == "1 hit"
/// assert recall_view.count_text(3) == "3 hits"
/// ```
pub fn count_text(count: Int) -> String {
  case count {
    0 -> "no hits"
    1 -> "1 hit"
    _ -> int.to_string(count) <> " hits"
  }
}

/// The rows under a result's count: one for each hit, naming its session,
/// entry, kind and UTC date before the snippet. A collapsed result keeps the
/// first `excerpt_hits` and ends in a row that says how many it left out; an
/// expanded one keeps every hit and a longer snippet.
///
/// ## Examples
///
/// ```gleam
/// // hit_rows([Hit("019a3c1e-…", "…-7f2a91b4c0d1", "assistant", 1_760_140_800_000, "deploy")], notes_view.Complete)
/// //   == ["019a3c1e · 7f2a91b4c0d1 · assistant · 2025-10-11 · deploy"]
/// ```
pub fn hit_rows(found: List(Hit), extent: notes_view.Extent) -> List(String) {
  // Render all hits or the excerpt window depending on the requested extent.
  case extent {
    notes_view.Complete -> list.map(found, hit_row(_, complete_snippet))
    notes_view.Excerpt -> {
      let shown = list.take(found, excerpt_hits)
      let left_out = list.length(list.drop(found, excerpt_hits))
      let rows = list.map(shown, hit_row(_, excerpt_snippet))

      // Append a trailing row when some hits were omitted from the excerpt.
      case left_out {
        0 -> rows
        _ ->
          list.append(rows, [
            "… " <> int.to_string(left_out) <> " more · Ctrl+g shows all",
          ])
      }
    }
  }
}

/// Formats one search hit into an interpunct-separated row.
fn hit_row(hit: Hit, snippet_limit: Int) -> String {
  string.join(
    [
      short_session(hit.session),
      short_entry(hit.entry),
      kind_text(hit.kind),
      utc_date(hit.ts),
      clipped(hit.snippet, snippet_limit),
    ],
    " · ",
  )
}

// A row the index recorded before it kept kinds has none to show.
fn kind_text(kind: String) -> String {
  case kind {
    "" -> "unknown kind"
    named -> named
  }
}

/// A session identifier as a row names it: the eight characters before the
/// first dash of a UUID, as the session picker names one, and any other text
/// whole.
///
/// ## Examples
///
/// ```gleam
/// assert recall_view.short_session("019a3c1e-5b7d-7c3e-9a10-2f4b6c8d0e1f") == "019a3c1e"
/// ```
pub fn short_session(session: String) -> String {
  case string.slice(session, 8, 1) {
    "-" -> string.slice(session, 0, 8)
    _ -> clipped(session, 12)
  }
}

/// An entry identifier as a row names it: the last eight characters of a UUID.
/// An entry's identifier is a UUIDv7, whose head is a timestamp that the
/// neighbouring entries of one search share, so the head would make every hit
/// of a session look like the same entry. Any other text is cut to twelve
/// characters.
///
/// ## Examples
///
/// ```gleam
/// assert recall_view.short_entry("019a3c1e-5b7d-7c3e-9a10-2f4b6c8d0e1f") == "6c8d0e1f"
/// ```
pub fn short_entry(entry: String) -> String {
  case string.length(entry) == 36 && string.slice(entry, 8, 1) == "-" {
    True -> string.slice(entry, 28, 8)
    False -> clipped(entry, 12)
  }
}

/// The words of a call for the transcript's summary row, or `None` when its
/// arguments name neither a query nor an entry to read, so the host falls back
/// to the plain `name · arguments` row.
///
/// A search names its query in quotation marks, then each filter it carries
/// (`kind`, `before`, `scope`). A search with no query is the browse of this
/// session's recent entries. A read names the entry it fetches and how many
/// neighbours it asked for.
///
/// ## Examples
///
/// ```gleam
/// assert recall_view.call_summary(json.Object([#("query", json.String("deploy")), #("kind", json.String("assistant"))]))
///   == Some("history_search · \"deploy\" · kind assistant")
/// ```
pub fn call_summary(arguments: JsonValue) -> Option(String) {
  case arguments {
    json.Object(fields) ->
      case text(fields, "action") {
        Ok("read") -> read_summary(fields)
        Ok("search") | Error(Nil) -> Some(search_summary(fields))
        Ok(_) -> None
      }
    _ -> None
  }
}

/// Summarizes a search call with its query and filters.
fn search_summary(fields: List(#(String, JsonValue))) -> String {
  // Extract the trimmed query string or fall back to recent entries.
  let subject = case text(fields, "query") |> result.map(string.trim) {
    Ok(query) if query != "" -> "\"" <> clipped(query, query_limit) <> "\""
    _ -> "recent entries"
  }

  let filters =
    [
      filter(fields, "kind", "kind "),
      filter(fields, "before", "before "),
      filter(fields, "scope", "scope "),
    ]
    |> list.filter_map(fn(found) { found })
  string.join([tool_name <> " · " <> subject, ..filters], " · ")
}

/// Formats one search filter argument when present in the call fields.
fn filter(
  fields: List(#(String, JsonValue)),
  name: String,
  words: String,
) -> Result(String, Nil) {
  use value <- result.map(text(fields, name))

  // Format entry identifiers shortened and generic filters clipped.
  case name {
    "before" -> words <> short_entry(value)
    _ -> words <> clipped(value, 24)
  }
}

/// Summarizes a read call naming session, entry, and context window.
fn read_summary(fields: List(#(String, JsonValue))) -> Option(String) {
  // Extract the session and entry identifiers required for reading.
  case text(fields, "session"), text(fields, "entry") {
    Ok(session), Ok(entry) -> {
      // Format the around context window if one was requested.
      let around = case whole(fields, "around") {
        Ok(count) if count > 0 -> " · around " <> int.to_string(count)
        _ -> ""
      }

      Some(
        tool_name
        <> " · read "
        <> short_session(session)
        <> " · "
        <> short_entry(entry)
        <> around,
      )
    }
    _, _ -> None
  }
}

/// The UTC calendar date of a time in milliseconds since the epoch, as
/// `YYYY-MM-DD`, or `unknown date` for the 0 an old index row carries.
///
/// The tool words the same date in its own text. It lives in a package this
/// one does not depend on, so the arithmetic is here a second time.
///
/// ## Examples
///
/// ```gleam
/// assert recall_view.utc_date(1_760_140_800_000) == "2025-10-11"
/// assert recall_view.utc_date(0) == "unknown date"
/// ```
pub fn utc_date(ms: Int) -> String {
  // Non-positive millisecond timestamps represent an unknown epoch date.
  case ms > 0 {
    False -> "unknown date"
    True -> {
      // The proleptic Gregorian date of a day count, by the era-based
      // algorithm: shift the epoch to 0000-03-01 so the leap day ends a year,
      // split into 400-year eras, and read the date out of the position
      // within the era.
      let z = ms / 86_400_000 + 719_468
      let era = z / 146_097
      let day_of_era = z - era * 146_097
      let year_of_era =
        {
          day_of_era
          - day_of_era
          / 1460
          + day_of_era
          / 36_524
          - day_of_era
          / 146_096
        }
        / 365
      let day_of_year =
        day_of_era - { 365 * year_of_era + year_of_era / 4 - year_of_era / 100 }

      // Months count from March, so January and February belong to the next
      // calendar year and are renumbered here.
      let shifted_month = { 5 * day_of_year + 2 } / 153
      let day = day_of_year - { 153 * shifted_month + 2 } / 5 + 1

      // Adjust the shifted calendar month index back to conventional calendar months.
      let month = case shifted_month < 10 {
        True -> shifted_month + 3
        False -> shifted_month - 9
      }

      let year = year_of_era + era * 400

      // Increment the calendar year for January and February in the shifted system.
      let year = case month <= 2 {
        True -> year + 1
        False -> year
      }

      int.to_string(year) <> "-" <> two_digits(month) <> "-" <> two_digits(day)
    }
  }
}

fn two_digits(n: Int) -> String {
  string.pad_start(int.to_string(n), to: 2, with: "0")
}

/// Clips a string to a single line and cuts with an ellipsis at the limit.
fn clipped(value: String, limit: Int) -> String {
  let one_line = text_hygiene.single_line(value)

  // Clip if the string exceeds the maximum character limit.
  case string.drop_start(one_line, limit) {
    "" -> one_line
    _ -> string.slice(one_line, 0, limit - 1) <> "…"
  }
}

/// Reads a string field by name from a JSON object field list.
fn text(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(String, Nil) {
  case list.key_find(fields, name) {
    Ok(json.String(value)) -> Ok(value)
    _ -> Error(Nil)
  }
}

fn whole(fields: List(#(String, JsonValue)), name: String) -> Result(Int, Nil) {
  case list.key_find(fields, name) {
    Ok(json.Int(value)) -> Ok(value)
    _ -> Error(Nil)
  }
}
