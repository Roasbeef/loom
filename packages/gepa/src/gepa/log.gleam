//// The search log's line format: one event per line, total to decode,
//// owned by this library so a host can persist and resume a search
//// without sharing anyone's JSON module.
////
//// A line is the event's kind, then `key=value` fields separated by
//// single spaces, the first field always the format version (`v=1`).
//// Every value is an atom escaped so it holds no space, newline, comma
//// or semicolon (`\s`, `\n`, `\t`, `\r`, `\c`, `\p`, and `\\` for the
//// backslash itself); a list is atoms joined by commas, a record by
//// semicolons, and a repeated key is a list of records. The kind tag
//// picks the keys a row must carry and nothing else, so a new kind is one
//// constructor plus one encode and one decode arm, and a row of a version
//// this reader does not know is refused by its number rather than
//// misread.
////
//// Decoding is total: every malformed line is an `Error` naming what was
//// wrong, never a panic, and a whole log stops at its first bad line with
//// the line number, as a ledger does, so a torn last row is never read as
//// the end of the search.

import gepa.{type Event, type Measured, type Score, type Stage}
import gepa/budget
import gepa/verdict
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

/// The format version this module writes and reads.
pub const version = 1

/// One event as the line the log holds, without its newline.
///
/// ## Examples
///
/// ```gleam
/// assert log.encode(gepa.Stopped(budget.Steps)) == "stopped v=1 reason=steps"
/// ```
///
pub fn encode(event: Event) -> String {
  // Each kind carries its own fields after the shared version tag.
  let #(kind, fields) = case event {
    gepa.Seeded(candidate:, components:) -> #("seeded", [
      #("candidate", atom(candidate)),
      ..list.map(components, fn(component) {
        #("component", atoms([component.0, component.1]))
      })
    ])
    gepa.Evaluated(
      stage:,
      step:,
      candidate:,
      tasks:,
      cap:,
      ref:,
      measured:,
      cost:,
    ) -> #("evaluated", [
      #("stage", stage_name(stage)),
      #("step", int.to_string(step)),
      #("candidate", atom(candidate)),
      #("tasks", atoms(tasks)),
      #("cap", float.to_string(cap)),
      #("ref", atom(ref)),
      #("cost", float.to_string(cost)),
      ..list.map(measured, fn(each) { #("measured", measured_text(each)) })
    ])
    gepa.Reflected(step:, cost:, ref:, finish:) -> #("reflected", [
      #("step", int.to_string(step)),
      #("cost", float.to_string(cost)),
      #("ref", atom(ref)),
      #("finish", finish_name(finish)),
    ])
    gepa.Minted(candidate:, parent:, step:, slot:, text:) -> #("minted", [
      #("candidate", atom(candidate)),
      #("parent", atom(parent)),
      #("step", int.to_string(step)),
      #("slot", atom(slot)),
      #("text", atom(text)),
    ])
    gepa.Refused(step:, candidate:, reason:) -> #("refused", [
      #("step", int.to_string(step)),
      ..list.append(
        case candidate {
          Some(id) -> [#("candidate", atom(id))]
          None -> []
        },
        [#("reason", atom(reason))],
      )
    ])
    gepa.Judged(candidate:, against:, basis:, acceptance:, disposition:, ref:) -> #(
      "judged",
      [
        #("candidate", atom(candidate)),
        #("against", atom(against)),
        #("basis", verdict.basis_name(basis)),
        #("acceptance", verdict.acceptance_name(acceptance)),
        #("disposition", verdict.disposition_name(disposition)),
        #("ref", atom(ref)),
      ],
    )
    gepa.Stopped(reason:) -> #("stopped", [
      #("reason", budget.stop_name(reason)),
    ])
  }

  [
    kind,
    "v=" <> int.to_string(version),
    ..list.map(fields, fn(field) { field.0 <> "=" <> field.1 })
  ]
  |> string.join(" ")
}

/// One candidate's measurements: the id, then a `task,value,feedback`
/// record per score, semicolon-joined.
fn measured_text(measured: Measured) -> String {
  [atom(measured.candidate), ..list.map(measured.scores, score_text)]
  |> string.join(";")
}

fn score_text(score: Score) -> String {
  atoms([score.task, float.to_string(score.value), score.feedback])
}

/// Decodes one line. Total: every malformed line is an `Error`.
///
/// ## Examples
///
/// ```gleam
/// assert log.decode("stopped v=1 reason=steps") == Ok(gepa.Stopped(budget.Steps))
/// assert log.decode("") == Error("an empty line")
/// ```
///
pub fn decode(line: String) -> Result(Event, String) {
  use #(kind, fields) <- result.try(tokens(line))
  use v <- result.try(int_field(fields, "v"))
  use Nil <- result.try(require(v == version, "unsupported log version"))

  // The kind tag picks which keys the row must carry.
  case kind {
    "seeded" -> decode_seeded(fields)
    "evaluated" -> decode_evaluated(fields)
    "reflected" -> decode_reflected(fields)
    "minted" -> decode_minted(fields)
    "refused" -> decode_refused(fields)
    "judged" -> decode_judged(fields)
    "stopped" -> {
      use Nil <- result.try(only(fields, ["v", "reason"]))
      use reason <- result.try(
        text_field(fields, "reason") |> result.try(budget.parse_stop),
      )
      Ok(gepa.Stopped(reason:))
    }
    other -> Error("unknown log row kind \"" <> other <> "\"")
  }
}

/// Decodes a whole log. A trailing partial line (a crash mid-write) is
/// refused, so a torn row is never read as the end of the search.
///
/// ## Examples
///
/// ```gleam
/// assert log.parse("") == Ok([])
/// ```
///
pub fn parse(text: String) -> Result(List(Event), String) {
  text
  |> string.split("\n")
  |> list.filter(fn(line) { line != "" })
  |> list.index_map(fn(line, position) { #(position + 1, line) })
  |> list.try_map(fn(numbered) {
    decode(numbered.1)
    |> result.map_error(fn(reason) {
      "search row " <> int.to_string(numbered.0) <> ": " <> reason
    })
  })
}

/// Encodes a whole log, one line per event, newline-terminated.
///
/// ## Examples
///
/// ```gleam
/// assert log.parse(log.render(events)) == Ok(events)
/// ```
///
pub fn render(events: List(Event)) -> String {
  list.map(events, fn(event) { encode(event) <> "\n" }) |> string.concat
}

// --- the row kinds ----------------------------------------------------------------------

/// A `seeded` row.
fn decode_seeded(fields: Fields) -> Result(Event, String) {
  use Nil <- result.try(only(fields, ["v", "candidate", "component"]))
  use candidate <- result.try(id_field(fields, "candidate"))
  use components <- result.try(
    list.try_map(all(fields, "component"), fn(raw) {
      use parts <- result.try(atoms_of(raw))
      pair(parts, "a component is a name and a text")
    }),
  )

  Ok(gepa.Seeded(candidate:, components:))
}

/// An `evaluated` row.
fn decode_evaluated(fields: Fields) -> Result(Event, String) {
  use Nil <- result.try(
    only(fields, [
      "v", "stage", "step", "candidate", "tasks", "cap", "ref", "cost",
      "measured",
    ]),
  )
  use stage <- result.try(
    text_field(fields, "stage") |> result.try(parse_stage),
  )
  use step <- result.try(int_field(fields, "step"))
  use candidate <- result.try(id_field(fields, "candidate"))
  use tasks <- result.try(raw_field(fields, "tasks") |> result.try(ids_of))
  use cap <- result.try(float_field(fields, "cap"))
  use ref <- result.try(text_field(fields, "ref"))
  use cost <- result.try(float_field(fields, "cost"))
  use measured <- result.try(list.try_map(all(fields, "measured"), measured_of))

  Ok(gepa.Evaluated(
    stage:,
    step:,
    candidate:,
    tasks:,
    cap:,
    ref:,
    measured:,
    cost:,
  ))
}

/// A `measured` value: the id, then the score records.
fn measured_of(raw: String) -> Result(Measured, String) {
  // The id leads; each record after it is a task, a value and a feedback.
  case string.split(raw, ";") {
    [id, ..records] -> {
      use candidate <- result.try(unescape(id))
      use Nil <- result.try(require(candidate != "", "an id is nonempty"))
      use scores <- result.try(list.try_map(records, score_of))

      Ok(gepa.Measured(candidate:, scores:))
    }
    [] -> Error("a measurement names a candidate")
  }
}

/// One `task,value,feedback` record.
fn score_of(raw: String) -> Result(Score, String) {
  use parts <- result.try(atoms_of(raw))

  // Exactly three atoms, the middle one a number.
  case parts {
    [task, value, feedback] -> {
      use Nil <- result.try(require(task != "", "an id is nonempty"))
      use value <- result.try(number(value))
      Ok(gepa.Score(task:, value:, feedback:))
    }
    _ -> Error("a score is a task, a value and a feedback")
  }
}

/// A `reflected` row.
fn decode_reflected(fields: Fields) -> Result(Event, String) {
  use Nil <- result.try(only(fields, ["v", "step", "cost", "ref", "finish"]))
  use step <- result.try(int_field(fields, "step"))
  use cost <- result.try(float_field(fields, "cost"))
  use ref <- result.try(text_field(fields, "ref"))
  use finish <- result.try(
    text_field(fields, "finish") |> result.try(parse_finish),
  )

  Ok(gepa.Reflected(step:, cost:, ref:, finish:))
}

/// A `minted` row.
fn decode_minted(fields: Fields) -> Result(Event, String) {
  use Nil <- result.try(
    only(fields, ["v", "candidate", "parent", "step", "slot", "text"]),
  )
  use candidate <- result.try(id_field(fields, "candidate"))
  use parent <- result.try(id_field(fields, "parent"))
  use step <- result.try(int_field(fields, "step"))
  use slot <- result.try(text_field(fields, "slot"))
  use text <- result.try(text_field(fields, "text"))

  Ok(gepa.Minted(candidate:, parent:, step:, slot:, text:))
}

/// A `refused` row; the candidate key is absent when none was minted.
fn decode_refused(fields: Fields) -> Result(Event, String) {
  use Nil <- result.try(only(fields, ["v", "step", "candidate", "reason"]))
  use step <- result.try(int_field(fields, "step"))

  // An absent candidate key is a refusal before any child was minted.
  use candidate <- result.try(case list.key_find(fields, "candidate") {
    Ok(_) -> id_field(fields, "candidate") |> result.map(Some)
    Error(Nil) -> Ok(None)
  })

  use reason <- result.try(text_field(fields, "reason"))

  Ok(gepa.Refused(step:, candidate:, reason:))
}

/// A `judged` row.
fn decode_judged(fields: Fields) -> Result(Event, String) {
  use Nil <- result.try(
    only(fields, [
      "v", "candidate", "against", "basis", "acceptance", "disposition", "ref",
    ]),
  )
  use candidate <- result.try(id_field(fields, "candidate"))
  use against <- result.try(id_field(fields, "against"))
  use basis <- result.try(
    text_field(fields, "basis") |> result.try(verdict.parse_basis),
  )
  use acceptance <- result.try(
    text_field(fields, "acceptance") |> result.try(verdict.parse_acceptance),
  )
  use disposition <- result.try(
    text_field(fields, "disposition")
    |> result.try(verdict.parse_disposition),
  )
  use ref <- result.try(text_field(fields, "ref"))

  Ok(gepa.Judged(candidate:, against:, basis:, acceptance:, disposition:, ref:))
}

// --- spellings --------------------------------------------------------------------------

/// The spelling of a stage.
///
/// ## Examples
///
/// ```gleam
/// assert log.stage_name(gepa.ParentMinibatch) == "parent_minibatch"
/// ```
///
pub fn stage_name(stage: Stage) -> String {
  case stage {
    gepa.SeedValidate -> "seed_validate"
    gepa.ParentMinibatch -> "parent_minibatch"
    gepa.ChildMinibatch -> "child_minibatch"
    gepa.Validate -> "validate"
    gepa.Confirm -> "confirm"
  }
}

/// Parses a stage's spelling.
///
/// ## Examples
///
/// ```gleam
/// assert log.parse_stage("confirm") == Ok(gepa.Confirm)
/// ```
///
pub fn parse_stage(name: String) -> Result(Stage, String) {
  case name {
    "seed_validate" -> Ok(gepa.SeedValidate)
    "parent_minibatch" -> Ok(gepa.ParentMinibatch)
    "child_minibatch" -> Ok(gepa.ChildMinibatch)
    "validate" -> Ok(gepa.Validate)
    "confirm" -> Ok(gepa.Confirm)
    other -> Error("unknown stage \"" <> other <> "\"")
  }
}

/// The spelling of how an answer ended.
///
/// ## Examples
///
/// ```gleam
/// assert log.finish_name(gepa.Truncated) == "truncated"
/// ```
///
pub fn finish_name(finish: gepa.Finish) -> String {
  case finish {
    gepa.Complete -> "complete"
    gepa.Truncated -> "truncated"
    gepa.Unknown -> "unknown"
  }
}

/// Parses a finish's spelling.
///
/// ## Examples
///
/// ```gleam
/// assert log.parse_finish("unknown") == Ok(gepa.Unknown)
/// ```
///
pub fn parse_finish(name: String) -> Result(gepa.Finish, String) {
  case name {
    "complete" -> Ok(gepa.Complete)
    "truncated" -> Ok(gepa.Truncated)
    "unknown" -> Ok(gepa.Unknown)
    other -> Error("unknown finish \"" <> other <> "\"")
  }
}

// --- atoms and fields -------------------------------------------------------------------

/// The fields of one line, in order, keys repeated where the row repeats
/// them.
type Fields =
  List(#(String, String))

/// Splits a line into its kind and its raw `key=value` fields. An empty
/// token (two spaces, a trailing space) is malformed, as is a field with
/// no `=`.
fn tokens(line: String) -> Result(#(String, Fields), String) {
  // The kind leads; every later token is a field.
  case string.split(line, " ") {
    [""] -> Error("an empty line")
    [kind, ..rest] -> {
      use fields <- result.try(
        list.try_map(rest, fn(token) {
          string.split_once(token, "=")
          |> result.map_error(fn(_) { "malformed field \"" <> token <> "\"" })
        }),
      )
      use Nil <- result.try(require(
        !list.any(fields, fn(field) { field.0 == "" }),
        "a field has a name",
      ))

      Ok(#(kind, fields))
    }
    [] -> Error("an empty line")
  }
}

/// Refuses a key the kind does not carry.
fn only(fields: Fields, allowed: List(String)) -> Result(Nil, String) {
  list.find(fields, fn(field) { !list.contains(allowed, field.0) })
  |> option.from_result
  |> option.map(fn(field) { Error("unexpected field \"" <> field.0 <> "\"") })
  |> option.unwrap(Ok(Nil))
}

/// Every raw value of a repeated key, in order.
fn all(fields: Fields, key: String) -> List(String) {
  list.filter_map(fields, fn(field) {
    case field.0 == key {
      True -> Ok(field.1)
      False -> Error(Nil)
    }
  })
}

/// A required field, present exactly once, unescaped.
fn text_field(fields: Fields, key: String) -> Result(String, String) {
  raw_field(fields, key) |> result.try(unescape)
}

/// A required field, present exactly once, still escaped: a list-valued
/// field is split on its separators before its atoms are unescaped,
/// since an escaped separator inside an atom must survive the split.
fn raw_field(fields: Fields, key: String) -> Result(String, String) {
  // Exactly one occurrence; a repeated scalar is malformed.
  case all(fields, key) {
    [raw] -> Ok(raw)
    [] -> Error("missing field \"" <> key <> "\"")
    [_, _, ..] -> Error("repeated field \"" <> key <> "\"")
  }
}

/// A required field that is a nonempty id.
fn id_field(fields: Fields, key: String) -> Result(String, String) {
  use value <- result.try(text_field(fields, key))

  require(value != "", "\"" <> key <> "\" is nonempty") |> result.replace(value)
}

/// A required integer field, non-negative.
fn int_field(fields: Fields, key: String) -> Result(Int, String) {
  use value <- result.try(text_field(fields, key))

  int.parse(value)
  |> result.map_error(fn(_) { "\"" <> key <> "\" must be an integer" })
  |> result.try(fn(parsed) {
    require(parsed >= 0, "\"" <> key <> "\" must not be negative")
    |> result.replace(parsed)
  })
}

/// A required number field.
fn float_field(fields: Fields, key: String) -> Result(Float, String) {
  use value <- result.try(text_field(fields, key))

  number(value)
  |> result.map_error(fn(_) { "\"" <> key <> "\" must be a number" })
}

/// A number as `float.to_string` writes it, or an integer literal.
fn number(text: String) -> Result(Float, String) {
  float.parse(text)
  |> result.lazy_or(fn() { int.parse(text) |> result.map(int.to_float) })
  |> result.replace_error("not a number")
}

/// Nonempty ids, comma-joined; an empty value is no ids.
fn ids_of(raw: String) -> Result(List(String), String) {
  use ids <- result.try(atoms_of(raw))

  // An empty value decodes as no ids, so a list of none has a spelling.
  case ids {
    [""] -> Ok([])
    _ ->
      require(list.all(ids, fn(id) { id != "" }), "an id is nonempty")
      |> result.replace(ids)
  }
}

/// Exactly two atoms.
fn pair(
  parts: List(String),
  message: String,
) -> Result(#(String, String), String) {
  case parts {
    [first, second] -> Ok(#(first, second))
    _ -> Error(message)
  }
}

/// Atoms joined by commas.
fn atoms(values: List(String)) -> String {
  list.map(values, atom) |> string.join(",")
}

/// The atoms of a comma-joined value, unescaped.
fn atoms_of(raw: String) -> Result(List(String), String) {
  string.split(raw, ",") |> list.try_map(unescape)
}

/// Escapes a value so it holds no space, newline, comma or semicolon.
fn atom(text: String) -> String {
  text
  |> string.replace(each: "\\", with: "\\\\")
  |> string.replace(each: " ", with: "\\s")
  |> string.replace(each: "\n", with: "\\n")
  |> string.replace(each: "\t", with: "\\t")
  |> string.replace(each: "\r", with: "\\r")
  |> string.replace(each: ",", with: "\\c")
  |> string.replace(each: ";", with: "\\p")
}

/// Reverses `atom`, refusing an escape it does not know and a trailing
/// lone backslash.
fn unescape(raw: String) -> Result(String, String) {
  unescape_graphemes(string.to_graphemes(raw), [])
}

/// Walks the graphemes, turning each escape back into its character.
fn unescape_graphemes(
  graphemes: List(String),
  done: List(String),
) -> Result(String, String) {
  // A backslash takes the next grapheme as the escape's name.
  case graphemes {
    [] -> Ok(string.concat(list.reverse(done)))
    ["\\", name, ..rest] -> {
      // The name after the backslash is one of the seven escapes.
      use character <- result.try(case name {
        "\\" -> Ok("\\")
        "s" -> Ok(" ")
        "n" -> Ok("\n")
        "t" -> Ok("\t")
        "r" -> Ok("\r")
        "c" -> Ok(",")
        "p" -> Ok(";")
        other -> Error("unknown escape \"\\" <> other <> "\"")
      })

      unescape_graphemes(rest, [character, ..done])
    }
    ["\\"] -> Error("a value ends in a lone backslash")
    [grapheme, ..rest] -> unescape_graphemes(rest, [grapheme, ..done])
  }
}

fn require(condition: Bool, message: String) -> Result(Nil, String) {
  case condition {
    True -> Ok(Nil)
    False -> Error(message)
  }
}
