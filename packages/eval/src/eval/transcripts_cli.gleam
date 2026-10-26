//// The transcript export's command line.
////
//// `gleam run -m eval/transcripts_cli -- export --state DIR [--db PATH ...]
//// --since ISO --out DIR` writes one scrubbed JSONL per session, and
//// `-- sample --dir DIR --n 40 --seed S` prints a reproducible stratified
//// sample of those files, one path per line. `--db` names databases
//// explicitly and, when given, replaces the search of `DIR/sessions`.
////
//// `--since` takes `YYYY-MM-DD` or `YYYY-MM-DDTHH:MM:SSZ`, always UTC. A
//// timestamp with an offset is refused rather than guessed at, because a
//// cut-off off by a few hours silently changes which sessions are read.
//// A usage error exits 2 and a failed export exits 1.

import argv
import client/internal/ffi_os
import eval/transcripts
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string

/// What the command line asked for.
pub type Command {
  /// Export session transcripts.
  Export(state: String, dbs: List(String), since_ms: Int, out: String)

  /// Sample exported session files.
  Sample(dir: String, n: Int, seed: String)
}

/// Runs the command named on the command line.
///
/// ## Examples
///
/// ```gleam
/// // gleam run -m eval/transcripts_cli -- sample --dir out --n 40 --seed s
/// ```
pub fn main() -> Nil {
  // A request that does not parse is a usage error, distinct from a failed run.
  case parse(argv.load().arguments) {
    Error(reason) -> {
      io.println_error("eval/transcripts_cli: " <> reason)
      io.println_error(usage)
      ffi_os.halt(2)
    }
    Ok(command) ->
      // A failed export or sample exits 1; success prints its summary.
      case run(command) {
        Ok(text) -> io.println(text)
        Error(reason) -> {
          io.println_error("eval/transcripts_cli: " <> reason)
          ffi_os.halt(1)
        }
      }
  }
}

const usage =
  "usage: export --state DIR [--db PATH ...] --since ISO --out DIR | sample --dir DIR --n N --seed S"

/// Parses the arguments into a command, naming the first thing wrong.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(Sample("d", 40, "s")) =
///   parse(["sample", "--dir", "d", "--n", "40", "--seed", "s"])
/// ```
pub fn parse(arguments: List(String)) -> Result(Command, String) {
  case arguments {
    ["export", ..flags] -> parse_export(flags, Export("", [], -1, ""))
    ["sample", ..flags] -> parse_sample(flags, Sample("", 0, ""))
    [] | [_, ..] -> Error("expected `export` or `sample`")
  }
}

/// Reads export flags one at a time; `--db` repeats.
fn parse_export(
  flags: List(String),
  so_far: Command,
) -> Result(Command, String) {
  // Flags are consumed in order; the end checks that every required one came.
  case flags, so_far {
    [], Export(state:, dbs:, since_ms:, out:) ->
      case since_ms >= 0, out, state == "" && dbs == [] {
        False, _, _ -> Error("--since is required")
        True, "", _ -> Error("--out is required")
        True, _, True -> Error("--state or --db is required")
        True, _, False -> Ok(so_far)
      }
    ["--state", value, ..rest], Export(..) ->
      parse_export(rest, Export(..so_far, state: value))
    ["--db", value, ..rest], Export(..) ->
      parse_export(rest, Export(..so_far, dbs: [value, ..so_far.dbs]))
    ["--out", value, ..rest], Export(..) ->
      parse_export(rest, Export(..so_far, out: value))
    ["--since", value, ..rest], Export(..) -> {
      use since_ms <- result.try(parse_since(value))
      parse_export(rest, Export(..so_far, since_ms:))
    }
    [flag, ..], _ -> Error("unknown or incomplete flag: " <> flag)
    [], Sample(..) -> Error("internal: wrong command")
  }
}

/// Reads sample flags one at a time.
fn parse_sample(
  flags: List(String),
  so_far: Command,
) -> Result(Command, String) {
  // Flags are consumed in order; the end checks that every required one came.
  case flags, so_far {
    [], Sample(dir:, n:, seed:) ->
      case dir, n > 0, seed {
        "", _, _ -> Error("--dir is required")
        _, False, _ -> Error("--n must be a positive integer")
        _, True, "" -> Error("--seed is required")
        _, True, _ -> Ok(so_far)
      }
    ["--dir", value, ..rest], Sample(..) ->
      parse_sample(rest, Sample(..so_far, dir: value))
    ["--seed", value, ..rest], Sample(..) ->
      parse_sample(rest, Sample(..so_far, seed: value))
    ["--n", value, ..rest], Sample(..) -> {
      use n <- result.try(
        int.parse(value) |> result.replace_error("--n is not an integer"),
      )
      parse_sample(rest, Sample(..so_far, n:))
    }
    [flag, ..], _ -> Error("unknown or incomplete flag: " <> flag)
    [], Export(..) -> Error("internal: wrong command")
  }
}

/// Reads a UTC instant as Unix milliseconds.
///
/// ## Examples
///
/// ```gleam
/// assert parse_since("1970-01-02") == Ok(86_400_000)
/// assert parse_since("1970-01-01T00:00:01Z") == Ok(1000)
/// ```
pub fn parse_since(text: String) -> Result(Int, String) {
  let refused = Error("--since is not YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ UTC")

  // A bare date is midnight UTC; a date with a time must end in Z.
  case string.split(text, "T") {
    [date] -> date_ms(date) |> result.replace_error("bad date")
    [date, clock] ->
      case
        string.ends_with(clock, "Z"),
        string.split(string.drop_end(clock, 1), ":")
      {
        True, [h, m, s] -> {
          use day <- result.try(date_ms(date))
          use hour <- result.try(int.parse(h))
          use minute <- result.try(int.parse(m))
          use second <- result.try(int.parse(s))
          Ok(day + { { hour * 60 + minute } * 60 + second } * 1000)
        }
        _, _ -> Error(Nil)
      }
      |> result.replace_error("bad time")
    _ -> refused
  }
  |> result.map_error(fn(_) {
    "--since is not YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ UTC"
  })
}

/// Midnight UTC of a `YYYY-MM-DD` date, by days-from-civil arithmetic.
fn date_ms(date: String) -> Result(Int, Nil) {
  // Exactly year, month and day; anything else is not a date.
  case string.split(date, "-") {
    [y, m, d] -> {
      use year <- result.try(int.parse(y))
      use month <- result.try(int.parse(m))
      use day <- result.try(int.parse(d))

      // Only the ranges are checked; a day past a month's end is the operator's typo.
      case month >= 1 && month <= 12 && day >= 1 && day <= 31 {
        True -> Ok(days_from_civil(year, month, day) * 86_400_000)
        False -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

/// Days since 1970-01-01 of a proleptic Gregorian date.
fn days_from_civil(year: Int, month: Int, day: Int) -> Int {
  // January and February belong to the previous year, so the leap day is the
  // last day of the shifted year.
  let y = case month <= 2 {
    True -> year - 1
    False -> year
  }

  let era = y / 400
  let yoe = y - era * 400

  // March is month zero of the shifted year.
  let shifted = case month > 2 {
    True -> month - 3
    False -> month + 9
  }

  let doy = { 153 * shifted + 2 } / 5 + day - 1
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy

  era * 146_097 + doe - 719_468
}

/// Does the work and renders the summary or the sample.
fn run(command: Command) -> Result(String, String) {
  // Each command has its own work and its own rendering.
  case command {
    Export(state:, dbs:, since_ms:, out:) -> {
      // An explicit database list replaces the search of the state directory.
      let exported = case dbs {
        [] -> transcripts.export(state, since_ms, out)
        [_, ..] -> transcripts.export_dbs(list.reverse(dbs), since_ms, out)
      }

      result.map(exported, render_census)
    }
    Sample(dir:, n:, seed:) ->
      Ok(string.join(transcripts.sample(dir, n, seed), "\n"))
  }
}

/// A short human summary; failures are listed because they are the sessions
/// the owner has to go and fix.
fn render_census(census: transcripts.Census) -> String {
  let models =
    list.map(census.by_model, fn(pair) {
      "  " <> pair.0 <> ": " <> int.to_string(pair.1)
    })
  let failures =
    list.map(census.failed, fn(failure) {
      "  FAILED " <> failure.path <> ": " <> failure.reason
    })

  string.join(
    list.flatten([
      [
        "sessions " <> int.to_string(census.sessions),
        "entries " <> int.to_string(census.entries),
        "marked " <> int.to_string(census.marked),
        "unmarked " <> int.to_string(census.unmarked),
        "skipped " <> int.to_string(census.skipped),
        "by model:",
      ],
      models,
      failures,
    ]),
    "\n",
  )
}
