//// `loomd seat-usage`: read what each provider says about a list of seats.
////
//// The command takes subscription seats on standard input, asks each seat's
//// provider one read-only question about its remaining allowance, and prints a
//// table or one JSON object per seat. It is the gauge the account pool will
//// read (`docs/design-notes/account-pool.md`, section 3); nothing here wires
//// the pool into a request path. `client/seat_usage` holds the pure decisions
//// and cites where each provider mechanism was verified; this module owns the
//// effects: standard input, the bounded HTTP fetch, concurrency and the exit
//// status.
////
//// ## Where tokens may come from
////
//// Seats arrive only as JSON lines on standard input,
//// `{"label": "...", "provider": "claude" | "codex", "token": "..."}`, so a
//// token never appears in a process listing, an environment or shell history.
//// There is no flag, variable or file argument that supplies one, and an
//// unknown argument is refused without being echoed, since an operator may have
//// mistyped a token onto the command line.
////
//// ## What it never sends
////
//// No request here is a model request, so it spends no allowance. The usage
//// endpoints are enough to read a seat, which is why there is no `--probe`
//// flag: a probe would be the only way to learn a seat's state from a response
//// header, and no mechanism needs it.
////
//// ## Bounds
////
//// Each fetch has its own timeout (`--timeout-ms`), a response body over
//// 256 KiB is refused, seats are read by at most `--concurrency` workers, and
//// at most `seat_usage.max_seats` seats are accepted. A worker that fails or
//// crashes becomes a `cancelled` report for its seat, so one seat's failure
//// never hides another's reading.
////
//// ## Flow
////
//// `main` reads standard input with `read_lines`, passes it to `execute`, and
//// prints what `execute` returns. `execute` parses `parse_arguments`, then the
//// seats, then `read_all` runs one `read_seat` per seat, and `render_table` or
//// `render_json` produces the output. The exit status is 0 when every seat was
//// read, 1 when any could not be, and 2 when the input or arguments were
//// refused before any request was made.

import client/codex/network
import client/internal/ffi_os
import client/seat_usage.{type Report, type Seat}
import gleam/bit_array
import gleam/float
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp
import host/bootstrap
import provider/http
import weft

/// Usage for `loomd seat-usage`.
pub const usage =
  "usage: loomd seat-usage [--json] [--model NAME] [--timeout-ms N] [--concurrency N]\n\nReads subscription seats from standard input, one JSON object per line:\n  {\"label\": \"seat-a\", \"provider\": \"claude\" | \"codex\", \"token\": \"...\"}\nand prints what each provider says about the seat's remaining allowance.\n\nA token is accepted only on standard input, never as an argument, an\nenvironment variable or a file, so it stays out of process listings and shell\nhistory. Unknown keys and malformed lines are refused with the line number.\n\nThis command never sends a model request and spends no allowance: it reads\neach provider's usage endpoint. A seat the provider will not answer for is\nreported `unknown` with an error code, never guessed.\n\n  --json            One JSON object per seat instead of a table.\n  --model NAME      Also report whether NAME is available to each seat:\n                    yes, no or unknown.\n  --timeout-ms N    Per-request timeout, 100 to 120000 (default 15000).\n  --concurrency N   Seats read at once, 1 to 16 (default 4).\n\nExit status: 0 when every seat was read, 1 when any could not be, 2 when the\ninput or arguments were refused.\n\nExample, with the seats in a file kept off the command line:\n  loomd seat-usage --json < seats.jsonl"

/// The most response bytes read from one request.
const body_limit = 262_144

/// The most input lines read before refusing the rest.
const max_lines = 1024

/// How output is rendered.
pub type Format {
  /// A fixed-width table.
  Table

  /// One JSON object per line.
  Json
}

/// The parsed command line.
pub type Options {
  Options(
    /// The output format.
    format: Format,
    /// The model to report availability for, if asked.
    model: Option(String),
    /// The per-request timeout in milliseconds.
    timeout_ms: Int,
    /// How many seats are read at once.
    concurrency: Int,
  )
}

/// What a run produced, so a test can assert on everything written.
pub type Execution {
  Execution(
    /// What goes to standard output.
    stdout: String,
    /// What goes to standard error.
    stderr: String,
    /// The process exit status.
    exit_code: Int,
  )
}

/// Reads seats from standard input, prints the readings and exits non-zero
/// when any seat could not be read.
///
/// ## Examples
///
/// ```gleam
/// // loomd seat-usage --json < seats.jsonl
/// ```
pub fn main(arguments: List(String)) -> Nil {
  // A refused input stops before any request; otherwise the run proceeds.
  let execution = case read_lines(1, []) {
    Ok(lines) ->
      execute(
        arguments,
        lines,
        http.httpc_transport(),
        bootstrap.system_time_ms(),
      )
    Error(refusal) ->
      Execution("", failure_line(seat_usage.refusal_text(refusal)), 2)
  }

  // Only nonempty output is printed.
  case execution.stdout {
    "" -> Nil
    text -> io.println(text)
  }

  // Only nonempty diagnostics are printed.
  case execution.stderr {
    "" -> Nil
    text -> io.println_error(text)
  }

  // A zero status exits normally; anything else halts with it.
  case execution.exit_code {
    0 -> Nil
    code -> ffi_os.halt(code)
  }
}

/// Reads numbered raw lines until standard input closes.
fn read_lines(
  number: Int,
  collected: List(#(Int, seat_usage.RawLine)),
) -> Result(List(#(Int, seat_usage.RawLine)), seat_usage.LineRefusal) {
  // Standard input ends the fold; a long line is kept as a refusal; text is checked as UTF-8.
  case ffi_os.read_stdin_line(seat_usage.max_line_bytes) {
    ffi_os.EndOfInput -> Ok(list.reverse(collected))
    _ if number > max_lines ->
      Error(seat_usage.LineRefusal(number, None, seat_usage.TooManySeats))
    ffi_os.TooLong ->
      read_lines(number + 1, [#(number, seat_usage.Oversized), ..collected])
    ffi_os.Text(bytes) -> {
      // Bytes that are not UTF-8 are a refused line, not a crash.
      let line = case bit_array.to_string(bytes) {
        Ok(text) -> seat_usage.Raw(text)
        Error(Nil) -> seat_usage.NotText
      }

      read_lines(number + 1, [#(number, line), ..collected])
    }
  }
}

/// Runs the command over already-read input lines. The transport and clock are
/// arguments so a test supplies scripted responses and a fixed time.
///
/// ## Examples
///
/// ```gleam
/// let run = seat_usage_cli.execute(["--json"], lines, scripted, 0)
/// assert run.exit_code == 0
/// ```
pub fn execute(
  arguments: List(String),
  lines: List(#(Int, seat_usage.RawLine)),
  transport: http.Transport,
  now_ms: Int,
) -> Execution {
  let refused = fn(text) { Execution("", failure_line(text), 2) }

  // Arguments are checked before input, and input before any request.
  case parse_arguments(arguments) {
    Error(text) -> refused(text <> "\n" <> usage)
    Ok(options) ->
      case seat_usage.parse_seats(lines) {
        Error(refusal) -> refused(seat_usage.refusal_text(refusal))
        Ok(seats) -> {
          let reports = read_all(seats, options, transport, now_ms)

          Execution(
            stdout: render(reports, options),
            stderr: "",
            exit_code: exit_code(reports),
          )
        }
      }
  }
}

/// The stderr line for a refusal.
fn failure_line(text: String) -> String {
  "loom seat-usage: " <> text
}

/// 0 when every seat was read, 1 otherwise.
fn exit_code(reports: List(Report)) -> Int {
  case list.all(reports, fn(report) { result.is_ok(report.outcome) }) {
    True -> 0
    False -> 1
  }
}

// --- Arguments ---------------------------------------------------------------

/// Parses the flags. An unknown argument is refused without echoing it, since
/// it may be a token typed onto the command line by mistake.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(options) = seat_usage_cli.parse_arguments(["--json"])
/// assert options.format == seat_usage_cli.Json
/// ```
pub fn parse_arguments(arguments: List(String)) -> Result(Options, String) {
  parse_flags(arguments, Options(Table, None, 15_000, 4), [])
}

/// Folds flags into options, remembering which were seen so none repeats.
fn parse_flags(
  arguments: List(String),
  options: Options,
  seen: List(String),
) -> Result(Options, String) {
  // Each flag consumes its value and may appear once.
  case arguments {
    [] -> Ok(options)
    [flag, ..rest] -> {
      // A repeated flag is refused before it is interpreted.
      use Nil <- result.try(case list.contains(seen, flag) {
        True -> Error("an option was given twice")
        False -> Ok(Nil)
      })

      // Each known flag sets one option; anything else is refused unechoed.
      case flag, rest {
        "--json", _ ->
          parse_flags(rest, Options(..options, format: Json), [flag, ..seen])
        "--model", [name, ..tail] -> {
          use Nil <- result.try(check_model(name))
          parse_flags(tail, Options(..options, model: Some(name)), [
            flag,
            ..seen
          ])
        }
        "--timeout-ms", [text, ..tail] -> {
          use timeout_ms <- result.try(bounded(text, 100, 120_000))
          parse_flags(tail, Options(..options, timeout_ms:), [flag, ..seen])
        }
        "--concurrency", [text, ..tail] -> {
          use concurrency <- result.try(bounded(text, 1, 16))
          parse_flags(tail, Options(..options, concurrency:), [flag, ..seen])
        }
        "--model", [] | "--timeout-ms", [] | "--concurrency", [] ->
          Error("an option is missing its value")
        _, _ -> Error("unknown argument")
      }
    }
  }
}

/// An integer within bounds.
fn bounded(text: String, low: Int, high: Int) -> Result(Int, String) {
  case int.parse(text) {
    Ok(value) if value >= low && value <= high -> Ok(value)
    _ -> Error("a number option is not an integer in range")
  }
}

/// A model name is 1 to 128 characters of letters, digits and `_-.:/`.
fn check_model(name: String) -> Result(Nil, String) {
  let permitted =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-.:/"
  let valid =
    name != ""
    && string.byte_size(name) <= 128
    && list.all(string.to_graphemes(name), fn(char) {
      string.contains(permitted, char)
    })

  // Only a nonempty, bounded name of permitted characters is a model.
  case valid {
    True -> Ok(Nil)
    False -> Error("the model name is not valid")
  }
}

// --- Reading -----------------------------------------------------------------

/// Reads every seat with bounded concurrency, in input order. A worker that
/// does not return a report still yields one for its seat.
fn read_all(
  seats: List(Seat),
  options: Options,
  transport: http.Transport,
  now_ms: Int,
) -> List(Report) {
  let tasks =
    list.map(seats, fn(seat) {
      weft.managed(fn(ledger) {
        Ok(read_seat(ledger, transport, options, now_ms, seat))
      })
    })
  let outcomes =
    weft.new_prepared(tasks)
    |> weft.limit(options.concurrency)
    |> weft.start

  list.zip(seats, outcomes)
  |> list.map(fn(pair) {
    case pair.1 {
      weft.Completed(_, report) -> report
      weft.Failed(_, Nil)
      | weft.Crashed(_, _)
      | weft.Abandoned(_)
      | weft.NeverStarted(_)
      | weft.DrainProofLost(_, _)
      | weft.CancellationUnconfirmed(_) ->
        seat_usage.Report(
          pair.0.label,
          pair.0.provider,
          Error(seat_usage.Cancelled),
        )
    }
  })
}

/// Reads one seat: its usage, then its model listing when a model was asked
/// about and the usage did not already answer.
fn read_seat(
  ledger: weft.Ledger,
  transport: http.Transport,
  options: Options,
  now_ms: Int,
  seat: Seat,
) -> Report {
  let fetch = fn(request) { fetch(ledger, transport, options, request) }
  let outcome = {
    use body <- result.try(fetch(seat_usage.usage_request(seat)))
    use reading <- result.try(seat_usage.read_usage(
      seat.provider,
      body,
      options.model,
      now_ms,
    ))

    // A listing is fetched only when a model was asked about, the usage did not answer it, and the provider has a listing.
    case options.model, reading.model, seat_usage.models_request(seat) {
      Some(model), None, Some(request) ->
        Ok(seat_usage.answer_model(reading, model, fetch(request)))
      _, _, _ -> Ok(reading)
    }
  }

  seat_usage.Report(seat.label, seat.provider, outcome)
}

/// One bounded GET, returning the body of a 200 and a closed failure code
/// otherwise.
fn fetch(
  ledger: weft.Ledger,
  transport: http.Transport,
  options: Options,
  request: http.HttpRequest,
) -> Result(String, seat_usage.Failure) {
  case
    network.fetch_adopted(
      ledger,
      transport,
      request,
      body_limit,
      options.timeout_ms,
    )
  {
    Ok(network.Response(200, body)) -> Ok(body)
    Ok(network.Response(status, _)) -> Error(seat_usage.HttpStatus(status))
    Error(code) -> Error(seat_usage.failure_from_fetch(code))
  }
}

// --- Rendering ---------------------------------------------------------------

/// Renders every report in the chosen format.
fn render(reports: List(Report), options: Options) -> String {
  case options.format {
    Table -> render_table(reports, options.model)
    Json -> string.join(list.map(reports, render_json), "\n")
  }
}

/// A moment as an RFC 3339 UTC time.
fn time_text(ms: Int) -> String {
  timestamp.to_rfc3339(
    timestamp.from_unix_seconds(ms / 1000),
    calendar.utc_offset,
  )
}

/// The state's word.
fn state_word(state: seat_usage.State) -> String {
  case state {
    seat_usage.Available -> "available"
    seat_usage.Exhausted -> "exhausted"
    seat_usage.Unknown(_) -> "unknown"
  }
}

/// The reason attached to an unknown state, if any.
fn state_reason(state: seat_usage.State) -> Option(String) {
  case state {
    seat_usage.Unknown(reason) -> Some(reason)
    seat_usage.Available | seat_usage.Exhausted -> None
  }
}

/// The model answer's word.
fn model_word(answer: seat_usage.ModelAnswer) -> String {
  case answer {
    seat_usage.ModelAvailable -> "yes"
    seat_usage.ModelUnavailable(_) -> "no"
    seat_usage.ModelUnknown(_) -> "unknown"
  }
}

/// The reason attached to a model answer, if any.
fn model_reason(answer: seat_usage.ModelAnswer) -> Option(String) {
  case answer {
    seat_usage.ModelAvailable -> None
    seat_usage.ModelUnavailable(reason) | seat_usage.ModelUnknown(reason) ->
      Some(reason)
  }
}

/// One seat as a JSON object on one line.
fn render_json(report: Report) -> String {
  let reading = option.from_result(report.outcome)
  let state =
    option.map(reading, fn(read) { read.state })
    |> option.unwrap(seat_usage.Unknown("the seat could not be read"))

  // A seat that could not be read has no windows.
  let windows = case reading {
    Some(read) -> read.windows
    None -> []
  }

  json.object([
    #("label", json.string(report.label)),
    #("provider", json.string(seat_usage.provider_name(report.provider))),
    #(
      "plan",
      json.nullable(option.then(reading, fn(read) { read.plan }), json.string),
    ),
    #("state", json.string(state_word(state))),
    #("state_reason", json.nullable(state_reason(state), json.string)),
    #("windows", json.array(windows, window_json)),
    #(
      "model",
      json.nullable(option.then(reading, fn(read) { read.model }), fn(answer) {
        json.object([
          #("available", json.string(model_word(answer))),
          #("reason", json.nullable(model_reason(answer), json.string)),
        ])
      }),
    ),
    #("error", json.nullable(failure_of(report), json.string)),
  ])
  |> json.to_string
}

/// The failure code of a report that could not be read.
fn failure_of(report: Report) -> Option(String) {
  case report.outcome {
    Ok(_) -> None
    Error(failure) -> Some(seat_usage.failure_code(failure))
  }
}

/// One window as JSON.
fn window_json(window: seat_usage.Window) -> json.Json {
  json.object([
    #("name", json.string(window.name)),
    #("used_fraction", json.float(window.used_fraction)),
    #(
      "resets_at",
      json.nullable(option.map(window.resets_at_ms, time_text), json.string),
    ),
    #("window_seconds", json.nullable(window.span_seconds, json.int)),
  ])
}

/// The windows cell of a table row.
fn windows_cell(windows: List(seat_usage.Window)) -> String {
  case windows {
    [] -> "-"
    _ ->
      list.map(windows, fn(window) {
        let percent = float.round(window.used_fraction *. 100.0)

        // A window with no reset time is shown without one.
        let reset = case window.resets_at_ms {
          Some(ms) -> " resets " <> time_text(ms)
          None -> ""
        }

        window.name <> " " <> int.to_string(percent) <> "%" <> reset
      })
      |> string.join("; ")
  }
}

/// A table row: label, provider, plan, state, windows, the model answer (when
/// a model was asked about) and a note carrying the failure code or the reason
/// a state or model is unknown.
fn row(report: Report, model: Option(String)) -> List(String) {
  // A failed seat has no plan, windows or answer, only its failure code.
  let #(plan, state, windows, answer, note) = case report.outcome {
    Error(failure) -> #(
      "-",
      "unknown",
      "-",
      "-",
      "error " <> seat_usage.failure_code(failure),
    )
    Ok(reading) -> #(
      option.unwrap(reading.plan, "-"),
      state_word(reading.state),
      windows_cell(reading.windows),
      option.map(reading.model, model_word) |> option.unwrap("-"),
      note(reading),
    )
  }

  // The model column exists only when a model was asked about.
  let answers = case model {
    Some(_) -> [answer]
    None -> []
  }

  let identity = [report.label, seat_usage.provider_name(report.provider)]

  list.flatten([identity, [plan, state, windows], answers, [note]])
}

/// The note for a read seat: why its state or model is unknown, or `-`.
fn note(reading: seat_usage.Reading) -> String {
  let reasons =
    [state_reason(reading.state), option.then(reading.model, model_reason)]
    |> option.values

  // A seat with nothing unknown has no note.
  case reasons {
    [] -> "-"
    [_, ..] -> string.join(reasons, "; ")
  }
}

/// The table, with a header row and padded columns.
fn render_table(reports: List(Report), model: Option(String)) -> String {
  // The model column is added to the header only when a model was asked about.
  let header = case model {
    Some(_) -> [
      "LABEL",
      "PROVIDER",
      "PLAN",
      "STATE",
      "WINDOWS",
      "MODEL",
      "NOTE",
    ]
    None -> ["LABEL", "PROVIDER", "PLAN", "STATE", "WINDOWS", "NOTE"]
  }

  let rows = [header, ..list.map(reports, row(_, model))]
  let widths =
    list.index_map(header, fn(_, column) {
      list.map(rows, fn(cells) {
        list.drop(cells, column)
        |> list.first
        |> result.unwrap("")
        |> string.length
      })
      |> list.fold(0, int.max)
    })

  list.map(rows, fn(cells) {
    list.zip(cells, widths)
    |> list.map(fn(pair) { string.pad_end(pair.0, pair.1, " ") })
    |> string.join("  ")
    |> string.trim_end
  })
  |> string.join("\n")
}
