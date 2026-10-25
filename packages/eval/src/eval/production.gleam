//// The join between what operators said about production answers and what the
//// holdout measured for the same prompt profile.
////
//// A holdout pass rate says how a profile does on tasks nothing learned from.
//// Production marks say how the same profile fared on the work operators
//// actually gave it. Putting the two side by side is the check that a
//// profile's holdout rate is not a story about the benchmark alone
//// (`docs/design-notes/eval-instrument.md` section 6).
////
//// ## Flow
////
//// `join` lists `<state>/sessions/*.db`, copies each database beside itself
//// (never opening an original, which would claim or contend for its writer
//// lease), reads the copy, and deletes it. `read_session` pulls three things
//// from a copy: the assistant answers since the cutoff, the profile journal
//// (`evolution/attempt/*` facts) and the operator marks
//// (`prompt/evolution-outcome/*` facts). `tally` is the pure join: each
//// answer takes the profile of the latest attempt journaled before it for
//// the same provider, model and API, and the mark of its own entry id.
//// `rows` folds the tallies of every session into one row per profile and
//// sets the holdout rates beside them.
////
//// ## The unmarked ruling
////
//// An answer nobody marked is not a failure and not a success. It is counted
//// in its own column and left out of the rate, which is `succeeded / (succeeded
//// + failed)`. Counting it as neutral would reward a profile for making
//// operators not bother to mark, and counting it as failure would punish the
//// profiles on the sessions that are watched least.
////
//// ## Limits
////
//// The attempt journal records no entry id, so the join is by order: an
//// attempt is journaled before its request begins and the answer is committed
//// after it, both under one storage-wide sequence. With several strands in
//// flight on the same provider, model and API the latest earlier attempt may
//// belong to a sibling strand; both then carry the same profile unless a
//// selection changed between them. An answer with no earlier attempt, or whose
//// attempt names no profile, is reported under the absent profile.

import client/internal/ffi_os
import core/clock
import core/entry.{MessageEntry}
import core/ids
import core/json.{type JsonValue}
import core/message.{AssistantMessage}
import core/register
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import storage/sqlite
import storage/storage

/// The most message entries read from one session, a ceiling so a runaway
/// session cannot make a report unbounded.
pub const max_entries = 100_000

const attempt_prefix = "evolution/attempt/"

const outcome_prefix = "prompt/evolution-outcome/"

/// What the holdout measured for one profile, supplied by the caller from a
/// holdout run's report.
pub type HoldoutRate {
  HoldoutRate(
    /// The profile id the holdout arm ran under.
    profile: String,
    /// Holdout trials that passed.
    passed: Int,
    /// Holdout trials that were graded.
    trials: Int,
  )
}

/// One profile's production record beside its holdout rate.
pub type Row {
  Row(
    /// The profile id, or `None` for answers made with no profile.
    profile: Option(String),
    /// Answers an operator marked as succeeded.
    succeeded: Int,
    /// Answers an operator marked as failed.
    failed: Int,
    /// Answers nobody marked; never part of the rate.
    unmarked: Int,
    /// The holdout result for the same profile id, when one was supplied.
    holdout: Option(HoldoutRate),
  )
}

/// An operator's mark on one answer, or its absence.
pub type Mark {
  Succeeded
  Failed
  Unmarked
}

/// One assistant answer, with the position that places it among the attempts.
pub type Answer {
  Answer(
    /// The entry id as text, the key of its mark.
    entry: String,
    /// The storage sequence it was committed under.
    seq: Int,
    /// Provider that served it.
    provider: String,
    /// Model that served it.
    model: String,
    /// API dialect that served it.
    api: String,
  )
}

/// One journaled provider attempt.
pub type Attempt {
  Attempt(
    /// The storage sequence the fact was written under.
    seq: Int,
    /// Provider the attempt targeted.
    provider: String,
    /// Model the attempt targeted.
    model: String,
    /// API dialect the attempt used.
    api: String,
    /// The profile applied, or `None` for the base request.
    profile: Option(String),
  )
}

/// Everything one session copy contributes.
pub type Session {
  Session(
    /// Answers at or after the cutoff.
    answers: List(Answer),
    /// Every journaled attempt.
    attempts: List(Attempt),
    /// Marks keyed by entry id text.
    marks: Dict(String, Mark),
  )
}

/// Joins production marks to profiles over every session under `state_dir`
/// whose answers are at or after `since_ms`, and sets `holdout` beside them.
/// Databases are read through copies; an original is never opened.
///
/// ## Examples
///
/// ```gleam
/// // production.join("/var/lib/loom", 1_760_000_000_000, [])
/// ```
///
pub fn join(
  state_dir: String,
  since_ms: Int,
  holdout: List(HoldoutRate),
) -> Result(List(Row), String) {
  let directory = state_dir <> "/sessions"

  use names <- result.try(
    simplifile.read_directory(directory)
    |> result.map_error(fn(error) {
      "cannot read " <> directory <> ": " <> simplifile.describe_error(error)
    }),
  )
  let databases =
    names
    |> list.filter(string.ends_with(_, ".db"))
    |> list.sort(string.compare)
    |> list.map(fn(name) { directory <> "/" <> name })

  use sessions <- result.try(
    list.try_map(databases, fn(path) { read_copy(path, since_ms) }),
  )
  Ok(rows(list.flat_map(sessions, tally), holdout))
}

/// Joins one session: each answer takes the mark of its entry and the profile
/// of the latest attempt journaled before it for the same target.
///
/// ## Examples
///
/// ```gleam
/// // production.tally(Session([], [], dict.new())) == []
/// ```
///
pub fn tally(session: Session) -> List(#(Option(String), Mark)) {
  list.map(session.answers, fn(answer) {
    let mark = dict.get(session.marks, answer.entry) |> result.unwrap(Unmarked)

    #(profile_of(answer, session.attempts), mark)
  })
}

/// Folds tallies into one row per profile, ordered by profile, and sets each
/// holdout rate beside the row of the same profile id. A profile the holdout
/// measured but production never used still gets a row, with zero counts, so
/// the table shows what has no production evidence.
///
/// ## Examples
///
/// ```gleam
/// // production.rows([#(None, production.Failed)], []) has one row with failed: 1
/// ```
///
pub fn rows(
  tallies: List(#(Option(String), Mark)),
  holdout: List(HoldoutRate),
) -> List(Row) {
  let counted =
    list.fold(tallies, dict.new(), fn(table, each) {
      let row =
        dict.get(table, each.0)
        |> result.unwrap(Row(each.0, 0, 0, 0, None))

      dict.insert(table, each.0, add(row, each.1))
    })
  let seeded =
    list.fold(holdout, counted, fn(table, rate) {
      case dict.has_key(table, Some(rate.profile)) {
        True -> table
        False ->
          dict.insert(
            table,
            Some(rate.profile),
            Row(Some(rate.profile), 0, 0, 0, None),
          )
      }
    })

  seeded
  |> dict.values
  |> list.map(fn(row) {
    Row(..row, holdout: case row.profile {
      Some(id) ->
        list.find(holdout, fn(rate) { rate.profile == id })
        |> option.from_result
      None -> None
    })
  })
  |> list.sort(fn(left, right) {
    string.compare(profile_text(left.profile), profile_text(right.profile))
  })
}

/// The marked success rate: `succeeded / (succeeded + failed)`, absent when
/// nothing was marked. Unmarked answers are not in the denominator.
///
/// ## Examples
///
/// ```gleam
/// assert production.marked_rate(Row(None, 1, 1, 8, None)) == Some(0.5)
/// ```
///
pub fn marked_rate(row: Row) -> Option(Float) {
  case row.succeeded + row.failed {
    0 -> None
    marked -> Some(int.to_float(row.succeeded) /. int.to_float(marked))
  }
}

/// Renders the table with the unmarked column beside the rate it is excluded
/// from.
///
/// ## Examples
///
/// ```gleam
/// // production.render(rows) starts with "profile | succeeded | failed | unmarked"
/// ```
///
pub fn render(table: List(Row)) -> String {
  let header =
    "profile | succeeded | failed | unmarked | marked rate | holdout pass rate"
  let lines =
    list.map(table, fn(row) {
      string.join(
        [
          profile_text(row.profile),
          int.to_string(row.succeeded),
          int.to_string(row.failed),
          int.to_string(row.unmarked),
          rate_text(marked_rate(row)),
          case row.holdout {
            Some(rate) -> holdout_text(rate)
            None -> "n/a"
          },
        ],
        " | ",
      )
    })

  string.join([header, ..lines], "\n")
}

/// A holdout rate with its counts, or `n/a` when it graded nothing.
fn holdout_text(rate: HoldoutRate) -> String {
  case rate.trials {
    0 -> "n/a"
    trials ->
      rate_text(Some(int.to_float(rate.passed) /. int.to_float(trials)))
      <> " ("
      <> int.to_string(rate.passed)
      <> "/"
      <> int.to_string(trials)
      <> ")"
  }
}

fn rate_text(rate: Option(Float)) -> String {
  case rate {
    Some(value) -> float.to_string(float.to_precision(value, 3))
    None -> "n/a"
  }
}

fn profile_text(profile: Option(String)) -> String {
  case profile {
    Some(id) -> id
    None -> "(no profile)"
  }
}

/// Counts one mark in its own column.
fn add(row: Row, mark: Mark) -> Row {
  case mark {
    Succeeded -> Row(..row, succeeded: row.succeeded + 1)
    Failed -> Row(..row, failed: row.failed + 1)
    Unmarked -> Row(..row, unmarked: row.unmarked + 1)
  }
}

/// The profile of the latest attempt journaled before the answer for the same
/// provider, model and API.
fn profile_of(answer: Answer, attempts: List(Attempt)) -> Option(String) {
  attempts
  |> list.filter(fn(each) {
    each.seq < answer.seq
    && each.provider == answer.provider
    && each.model == answer.model
    && each.api == answer.api
  })
  |> list.sort(fn(left, right) { int.compare(right.seq, left.seq) })
  |> list.first
  |> result.map(fn(each) { each.profile })
  |> result.unwrap(None)
}

/// Copies one database, reads the copy, and removes the copy on every path.
fn read_copy(path: String, since_ms: Int) -> Result(Session, String) {
  let copy =
    path <> ".production-" <> int.to_string(ffi_os.unique_positive_integer())

  use Nil <- result.try(copy_database(path, copy))
  let read = open_and_read(copy, since_ms)
  remove_copy(copy)

  result.map_error(read, fn(reason) { path <> ": " <> reason })
}

const siblings = ["", "-wal", "-shm"]

/// Copies the database and whichever siblings exist; the log holds commits
/// the main file has not absorbed, so a copy without it reads a past state.
fn copy_database(path: String, copy: String) -> Result(Nil, String) {
  list.try_each(siblings, fn(suffix) {
    case simplifile.is_file(path <> suffix) {
      Ok(True) ->
        simplifile.copy_file(path <> suffix, copy <> suffix)
        |> result.map_error(fn(error) {
          "cannot copy "
          <> path
          <> suffix
          <> ": "
          <> simplifile.describe_error(error)
        })
      Ok(False) | Error(_) -> Ok(Nil)
    }
  })
}

/// Deletes a copy and its siblings. A leftover is only disk, never evidence.
fn remove_copy(copy: String) -> Nil {
  list.each(siblings, fn(suffix) {
    let _ = simplifile.delete(copy <> suffix)
    Nil
  })
}

/// Opens the copy with a clock beyond any lease expiry, so a lease copied from
/// a live writer reads as expired in the copy alone, then reads and closes it.
fn open_and_read(copy: String, since_ms: Int) -> Result(Session, String) {
  let beyond_any_lease = clock.fixed(at: 4_000_000_000_000_000)

  use store <- result.try(
    sqlite.open(
      sqlite.config(path: copy, owner: "eval-production"),
      beyond_any_lease,
    )
    |> result.map_error(fn(_) { "the session database could not be opened" }),
  )
  let read = read_session(store, since_ms)
  let _closed = storage.close(store)

  read
}

/// Reads the answers, journaled attempts and marks of one open session copy.
fn read_session(store, since_ms: Int) -> Result(Session, String) {
  use entries <- result.try(
    storage.scan_entries(
      store,
      storage.entry_scan()
        |> storage.entry_kind(storage.Message)
        |> storage.entry_limit(max_entries),
    )
    |> result.replace_error("the session's entries could not be read"),
  )
  use facts <- result.try(
    storage.list_registers(store, register.FactCustom, None)
    |> result.replace_error("the session's facts could not be read"),
  )
  use attempts <- result.try(
    facts
    |> list.filter(fn(fact) { string.starts_with(fact.0, attempt_prefix) })
    |> list.try_map(fn(fact) { attempt(fact.1.seq, fact.1.value.payload) }),
  )
  use marks <- result.try(
    facts
    |> list.filter(fn(fact) { string.starts_with(fact.0, outcome_prefix) })
    |> list.try_map(fn(fact) {
      use mark <- result.map(mark(fact.1.value.payload))
      #(string.drop_start(fact.0, string.length(outcome_prefix)), mark)
    }),
  )

  Ok(Session(
    answers: list.filter_map(entries, fn(each) { answer(each, since_ms) }),
    attempts:,
    marks: dict.from_list(marks),
  ))
}

/// An assistant answer at or after the cutoff; any other entry is not one.
fn answer(each: entry.Entry, since_ms: Int) -> Result(Answer, Nil) {
  case each {
    MessageEntry(
      id:,
      seq:,
      ts:,
      message: AssistantMessage(provider:, model:, api:, ..),
      ..,
    )
      if ts >= since_ms
    ->
      Ok(Answer(
        entry: ids.entry_id_to_string(id),
        seq:,
        provider:,
        model:,
        api:,
      ))
    _ -> Error(Nil)
  }
}

/// Decodes one `evolution/attempt/*` fact. Total: a fact of any other shape is
/// an error naming it, because a silently skipped attempt would move answers
/// to the wrong profile.
fn attempt(seq: Int, payload: JsonValue) -> Result(Attempt, String) {
  // Only an object can be a journaled attempt.
  case payload {
    json.Object(fields) -> {
      // The profile is a string, or null for a request made with none.
      let profile = case list.key_find(fields, "profile_id") {
        Ok(json.String(id)) -> Ok(Some(id))
        Ok(json.Null) -> Ok(None)
        _ -> Error(Nil)
      }

      // All three target members must be text; anything else is corruption.
      case
        list.key_find(fields, "provider"),
        list.key_find(fields, "model"),
        list.key_find(fields, "api"),
        profile
      {
        Ok(json.String(provider)),
          Ok(json.String(model)),
          Ok(json.String(api)),
          Ok(profile)
        -> Ok(Attempt(seq:, provider:, model:, api:, profile:))
        _, _, _, _ -> Error("an attempt fact is malformed")
      }
    }
    _ -> Error("an attempt fact is malformed")
  }
}

/// Decodes one operator mark in the shape `client/evolution/trace.mark`
/// writes: version one, a nonempty principal and a verdict word, nothing else.
fn mark(payload: JsonValue) -> Result(Mark, String) {
  case payload {
    json.Object(fields) ->
      case
        list.length(fields) == 3,
        list.key_find(fields, "version"),
        list.key_find(fields, "principal"),
        list.key_find(fields, "outcome")
      {
        True,
          Ok(json.Int(1)),
          Ok(json.String(principal)),
          Ok(json.String("succeeded"))
          if principal != ""
        -> Ok(Succeeded)
        True,
          Ok(json.Int(1)),
          Ok(json.String(principal)),
          Ok(json.String("failed"))
          if principal != ""
        -> Ok(Failed)
        _, _, _, _ -> Error("an operator mark is malformed")
      }
    _ -> Error("an operator mark is malformed")
  }
}
