//// The `[secrets]` table: credential values obtained from the host once,
//// at daemon boot, and held in memory for the life of the process.
////
//// ## Why the table exists
////
//// Every credential this harness spends is named rather than written
//// down: a model entry's `api_key_env`, an MCP server's `api_key_env`,
//// and a `[tools] env` name are all *variable names* resolved through
//// `provider/secret.SecretStore`. The default store is the daemon's own
//// process environment, which works only when the operator's shell has
//// already exported the value. Plenty of host credentials are not
//// exported anywhere: `gh` keeps its token in the macOS keychain, `op`
//// and `pass` keep theirs in a vault, and inside a jail none of those is
//// reachable — the keychain is unavailable by design and `HOME` is not
//// the operator's home. The result was a daemon that warned
//// `tools.env_unset GH_TOKEN` at every session open and a `gh` that
//// answered 401.
////
//// A `[secrets]` entry lets the operator say *how to obtain* a value
//// instead of assuming it is already in the environment:
////
//// ```toml
//// [secrets]
//// GH_TOKEN = { command = ["gh", "auth", "token"] }
//// ```
////
//// ## What resolution promises
////
//// The command runs once, at boot, on the host and outside every jail,
//// as the operator, with the daemon's own environment — the same trust
//// the operator already extends to `helper_path`. Its stdout, less one
//// trailing newline, is the value, and empty stdout is a failure rather
//// than an empty value: a helper that exits 0 with nothing to say has
//// not produced a credential, and recording `""` would shadow an
//// environment variable of the same name without a word of warning. A
//// resolved value lives in daemon
//// memory only: it is never written to the catalogue, a session, a
//// transcript or a log, and `Failure` carries a name and an exit status
//// rather than any output. The command's own stderr is not captured; it
//// is inherited, so it reaches the daemon log the way any other boot
//// diagnostic does, and the harness never has to decide whether a line
//// of it was a value.
////
//// A command that fails or overruns its deadline is one warned line and
//// not a boot failure, exactly as an unset `[tools] env` name is: a
//// missing `gh` login must not stop a daemon whose other work does not
//// need it, and the tool or provider that did need it fails in band when
//// it runs.
////
//// ## What a resolved value covers
////
//// `store` layers the resolved pairs *over* a base store rather than
//// replacing it, so one seam serves all three lookups. A name the table
//// resolved wins; every other name falls through to the environment,
//// which is why a catalogue that names no secrets behaves exactly as it
//// did before this table existed.

import client/internal/ffi_os
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import provider/secret.{type SecretStore}
import tom

/// Where one secret's value comes from.
///
/// One variant today. It is a custom type rather than a record field so
/// that the vault and keychain backends of issue #181 arrive as new
/// variants, each with the fields its own backend needs, instead of a
/// widening row of optional keys nobody can tell apart.
pub type Source {
  /// An argv run on the host at boot. Invariants (owed by `parse`, and
  /// by any hand construction): `argv` is non-empty and every element is
  /// a whole argument, never a shell word — nothing splits or expands
  /// it, so no quoting rule applies and no metacharacter is honoured.
  Command(argv: List(String))
}

/// One `[secrets]` entry: the variable name an `api_key_env` or a
/// `[tools] env` list may mention, and where its value comes from.
///
/// Constructor invariants: `name` is non-empty, and no two entries in a
/// parsed list share one — TOML keys are unique, which is what carries
/// it.
pub type Entry {
  Entry(name: String, source: Source)
}

/// Why one entry did not resolve. Carries the variable's name and a
/// reason built from the command's exit status or the deadline, and
/// never any of the command's output: a failing credential helper often
/// prints the credential it did find on the way to failing.
pub type Failure {
  Failure(name: String, reason: String)
}

/// What running one host command came to: the process's exit status and
/// everything it wrote to stdout, undecorated.
///
/// Constructor invariants: `output` is the whole of stdout as valid
/// UTF-8; a command whose stdout is not UTF-8 is a runner error rather
/// than a `Capture`, because a value the harness cannot hold as a
/// `String` is not a value it can put in a header.
pub type Capture {
  Capture(status: Int, output: String)
}

/// The injected seam `resolve` runs a `Command` through: an argv and a
/// deadline in milliseconds, answering a `Capture` or the reason no
/// process ran to completion.
///
/// It is a parameter rather than a direct call so the resolution rules —
/// which status counts, what the trailing newline means, what a failure
/// says — are testable against a scripted command without a real vault.
pub type Runner =
  fn(List(String), Int) -> Result(Capture, String)

/// How long one secret command may take before it is killed and its
/// entry reported unresolved. Ten seconds is chosen against the slowest
/// realistic helper — an `op read` that has to touch the network and
/// possibly prompt a local agent — while staying short enough that a
/// wedged helper cannot hold a whole daemon boot.
pub const default_timeout_ms = 10_000

// --- the [secrets] table ---------------------------------------------------

/// Parses the optional `[secrets]` table out of the same `loom.toml`
/// `client/catalog` reads, in name order.
///
/// The order is sorted rather than the file's, for the reason the model
/// entries are: TOML hands its keys back through a dict, so file order
/// is not recoverable, and a boot's warning lines should not depend on
/// which order a dict happened to iterate.
///
/// The top-level key `secrets` must also appear in `client/catalog`'s
/// allowed list, which is the one place table names are checked; that is
/// the same obligation `[[rule]]` and `[memory]` carry.
///
/// ## Examples
///
/// ```gleam
/// assert secrets.parse("") == Ok([])
/// ```
///
/// ```gleam
/// assert secrets.parse("[secrets]\nGH_TOKEN = { command = [\"gh\"] }\n")
///   == Ok([secrets.Entry("GH_TOKEN", secrets.Command(["gh"]))])
/// ```
///
pub fn parse(text: String) -> Result(List(Entry), String) {
  use document <- result.try(
    tom.parse(text)
    |> result.map_error(fn(error) {
      "the configuration is not valid TOML: " <> string.inspect(error)
    }),
  )

  // An absent table is the whole of the old behaviour, written down: no
  // entry resolves, and every name still falls through to the process
  // environment.
  case dict.get(document, "secrets") {
    Error(Nil) -> Ok([])
    Ok(tom.Table(fields)) | Ok(tom.InlineTable(fields)) -> entries(fields)
    Ok(_other) ->
      Error("secrets must be a [secrets] table naming one variable per entry")
  }
}

// Each key of `[secrets]` is a variable name and each value is that
// entry's source table. Sorting happens before the per-entry parse so
// that a file with two bad entries always names the same one first.
fn entries(fields: Dict(String, tom.Toml)) -> Result(List(Entry), String) {
  fields
  |> dict.to_list
  |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
  |> list.try_map(fn(pair) { entry(pair.0, pair.1) })
}

// One entry. The place string is what every message about it is anchored
// to, so an operator with several entries is told which one is wrong.
fn entry(name: String, value: tom.Toml) -> Result(Entry, String) {
  let place = "secrets." <> name

  use Nil <- result.try(case name {
    "" -> Error("a [secrets] entry must have a non-empty name")
    _named -> Ok(Nil)
  })

  use fields <- result.try(case value {
    tom.Table(fields) | tom.InlineTable(fields) -> Ok(fields)
    _other ->
      Error(
        place
        <> " must be a table naming a source, as in "
        <> "`{ command = [\"gh\", \"auth\", \"token\"] }`",
      )
  })

  // Exactly one source key is known, so an unknown one is refused rather
  // than ignored: a typoed `commnad` silently dropped would leave the
  // operator with an entry that resolves nothing and no word about why.
  use Nil <- result.try(known_keys(dict.keys(fields), ["command"], place))

  use source <- result.map(command_source(fields, place))
  Entry(name:, source:)
}

// The `command` key: a non-empty array of whole arguments.
fn command_source(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(Source, String) {
  let malformed =
    place <> ".command must be an array of strings, each one whole argument"

  use items <- result.try(case dict.get(fields, "command") {
    Ok(tom.Array(items)) -> Ok(items)
    Ok(_other) -> Error(malformed)
    Error(Nil) -> Error(place <> " needs a command")
  })

  use argv <- result.try(
    list.try_map(items, fn(item) {
      case item {
        tom.String("") -> Error(place <> ".command arguments must be non-empty")
        tom.String(argument) -> Ok(argument)
        _other -> Error(malformed)
      }
    }),
  )

  case argv {
    [] -> Error(place <> ".command must name a program to run")
    _argv -> Ok(Command(argv:))
  }
}

fn known_keys(
  present: List(String),
  allowed: List(String),
  place: String,
) -> Result(Nil, String) {
  case list.find(present, fn(key) { !list.contains(allowed, key) }) {
    Error(Nil) -> Ok(Nil)
    Ok(unknown) ->
      Error(
        "unknown key `"
        <> unknown
        <> "` in "
        <> place
        <> " (allowed: "
        <> string.join(allowed, ", ")
        <> ")",
      )
  }
}

// --- resolution ------------------------------------------------------------

/// Runs every entry's source once and answers the pairs that resolved
/// alongside the entries that did not.
///
/// Both halves are returned rather than logged here because this module
/// performs no I/O of its own beyond the injected runner: the caller owns
/// the logger, and it is the caller that must decide a failure is a
/// warning rather than a refusal. The pairs are in the entry order
/// `parse` fixed.
///
/// ## Examples
///
/// ```gleam
/// let runner = fn(_argv, _ms) { Ok(secrets.Capture(0, "value\n")) }
/// assert secrets.resolve(
///   [secrets.Entry("K", secrets.Command(["true"]))],
///   running: runner,
///   within: secrets.default_timeout_ms,
/// )
///   == #([#("K", "value")], [])
/// ```
///
pub fn resolve(
  entries: List(Entry),
  running runner: Runner,
  within timeout_ms: Int,
) -> #(List(#(String, String)), List(Failure)) {
  let outcomes =
    list.map(entries, fn(entry) {
      case resolve_one(entry, runner, timeout_ms) {
        Ok(value) -> Ok(#(entry.name, value))
        Error(reason) -> Error(Failure(name: entry.name, reason:))
      }
    })

  #(list.filter_map(outcomes, fn(outcome) { outcome }), failures(outcomes))
}

// `list.filter_map` keeps the Ok side; the Error side needs the mirror of
// it, and the stdlib has no `filter_errors`.
fn failures(
  outcomes: List(Result(#(String, String), Failure)),
) -> List(Failure) {
  list.filter_map(outcomes, fn(outcome) {
    case outcome {
      Error(failure) -> Ok(failure)
      Ok(_pair) -> Error(Nil)
    }
  })
}

// One entry. A non-zero status is the ordinary "not logged in" answer
// and is reported as itself; the status is safe to say out loud where
// the output is not.
fn resolve_one(
  entry: Entry,
  runner: Runner,
  timeout_ms: Int,
) -> Result(String, String) {
  let Command(argv:) = entry.source
  use capture <- result.try(runner(argv, timeout_ms))

  case capture.status {
    0 -> resolved_value(without_trailing_newline(capture.output))
    status -> Error("the command exited " <> int.to_string(status))
  }
}

// A successful command that wrote nothing has not produced a credential,
// and saying so is what keeps the name unset. Several helpers exit 0 with
// empty stdout when the operator is signed out, and an empty string
// recorded here would be a `dict.get` hit in `store` — the environment
// fallback would never be consulted, so an operator who had also exported
// the variable would get an authentication failure and no warning, because
// `resolve` recorded no failure. Refusing the empty result puts the entry
// on the failure side instead, where `log_secret_failures` names it.
fn resolved_value(value: String) -> Result(String, String) {
  case value {
    "" -> Error("the command produced no output")
    _value -> Ok(value)
  }
}

// Exactly one trailing newline comes off, not every trailing space: a
// credential helper ends its one line with `\n` (and on some hosts with
// `\r\n`), while whitespace inside or after the value is the value's,
// and trimming it would silently hand a different credential to the
// wire than the one the vault holds.
fn without_trailing_newline(output: String) -> String {
  case string.ends_with(output, "\r\n"), string.ends_with(output, "\n") {
    True, _crlf -> string.drop_end(output, 2)
    False, True -> string.drop_end(output, 1)
    False, False -> output
  }
}

/// Layers resolved pairs over a base store: a resolved name wins, and
/// every other name is answered by the base.
///
/// The precedence is deliberate and is the point of the table. An
/// operator who writes a `[secrets]` entry for a name their shell also
/// exports has said which of the two they mean, and it is the one they
/// took the trouble to configure.
///
/// ## Examples
///
/// ```gleam
/// let base = secret.from_list([#("K", "from the environment")])
/// let store = secrets.store([#("K", "from the vault")], beneath: base)
/// assert secret.lookup(store, "K") == Ok("from the vault")
/// ```
///
/// ```gleam
/// let base = secret.from_list([#("OTHER", "environment")])
/// let store = secrets.store([], beneath: base)
/// assert secret.lookup(store, "OTHER") == Ok("environment")
/// ```
///
pub fn store(
  resolved: List(#(String, String)),
  beneath base: SecretStore,
) -> SecretStore {
  let table = dict.from_list(resolved)
  secret.from_function(fn(name) {
    case dict.get(table, name) {
      Ok(value) -> Ok(value)
      Error(Nil) -> secret.lookup(base, name)
    }
  })
}

// --- the host runner -------------------------------------------------------

/// The shipped runner: resolves the program against `PATH` and runs it
/// on the host, outside every jail, with the daemon's own environment.
///
/// The program is resolved here rather than inside the shim because
/// which executable a name means is a decision, and `Error` for a name
/// `PATH` does not answer is the diagnostic the operator needs — an
/// unfound program and a program that ran and failed are different
/// mistakes with different fixes.
///
/// ## Examples
///
/// ```gleam
/// // secrets.host_runner()(["gh", "auth", "token"], 10_000)
/// // -> Ok(secrets.Capture(0, "gho_...\n"))
/// ```
///
pub fn host_runner() -> Runner {
  fn(argv, timeout_ms) {
    case argv {
      [] -> Error("the entry names no program to run")
      [program, ..arguments] -> {
        use executable <- result.try(
          ffi_os.find_executable(program)
          |> result.replace_error("`" <> program <> "` is not on PATH"),
        )
        use #(status, output) <- result.map(ffi_os.run_capture(
          executable,
          arguments,
          timeout_ms,
        ))
        Capture(status:, output:)
      }
    }
  }
}
