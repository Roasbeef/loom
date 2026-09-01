//// The command line: find sources, lint them, print the findings and the
//// census.
////
//// This is the only module in the package that does I/O. It also applies
//// the staging decision: **every rule warns except the ones
//// `finding.error_by_default` names** — R0, R2, R4 and R6, each with its
//// census and its argument in that function. `scripts/lint.sh` reads the
//// trailing `# <errors> <warnings>` line to decide its exit code, exactly
//// as `scripts/doc_check.sh` does. Promoting one of the remaining three is
//// `--error=R5` and nothing else; the census is what argues for or against
//// doing so, and for R3 it argues permanently against.
////
//// Manifests are linted too, and are found rather than given: `make lint`
//// points at `packages/*/src`, so R6's `gleam.toml` half would never be
//// reached if it waited to be named. Every source tree the run touched
//// contributes its package's manifest, which is what keeps `scripts/lint.sh
//// packages/core/src` checking the whole of core's rule rather than half of
//// it.

import argv
import gleam/dict.{type Dict}
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/pair
import gleam/result
import gleam/string
import lint
import lint/finding.{type Finding, type Rule}
import lint/policy.{type Eager, type Policy}
import simplifile

/// Parsed command line.
type Options {
  Options(
    paths: List(String),
    policy: Policy,
    errors: List(Rule),
    include_tests: Bool,
    limit: Int,
    quiet: Bool,
    help: Bool,
  )
}

const usage: String = "loom lint — the house rules gleam check does not know

usage: gleam run -m lint/cli -- [options] <path>...

  --depth=N       R2 fires above this `case` nesting depth (default 3)
  --error=R1,R5   promote these rules to error level (R0, R2, R4, R6 are)
  --tests         also lint test/ sources (R4 and R7 are off for them)
  --limit=N       list at most N findings per rule (default 25; 0 = all)
  --quiet         print the census only
  --help          this

R0, R2, R4 and R6 gate by default and their censuses must stay zero; every
other rule warns unless named by --error. The last line of output is
`# <errors> <warnings>`, which is what the wrapper script reads.
"

pub fn main() -> Nil {
  let options = parse(argv.load().arguments, defaults())
  case options.help || options.paths == [] {
    True -> io.println(usage)
    False -> run(options)
  }
}

fn defaults() -> Options {
  Options(
    paths: [],
    policy: policy.default(),
    errors: finding.error_by_default(),
    include_tests: False,
    limit: 25,
    quiet: False,
    help: False,
  )
}

fn parse(arguments: List(String), options: Options) -> Options {
  case arguments {
    [] -> Options(..options, paths: list.reverse(options.paths))
    [argument, ..rest] -> parse(rest, apply(argument, options))
  }
}

fn apply(argument: String, options: Options) -> Options {
  case string.split_once(argument, "=") {
    Ok(#("--depth", value)) ->
      Options(
        ..options,
        policy: policy.Policy(
          ..options.policy,
          nesting_threshold: number(value, options.policy.nesting_threshold),
        ),
      )
    Ok(#("--error", value)) ->
      Options(..options, errors: list.append(options.errors, promoted(value)))
    Ok(#("--limit", value)) ->
      Options(..options, limit: number(value, options.limit))
    Ok(#(_, _)) -> options
    Error(Nil) ->
      case argument {
        "--tests" -> Options(..options, include_tests: True)
        "--quiet" -> Options(..options, quiet: True)
        "--help" | "-h" -> Options(..options, help: True)
        "--multi-subject" ->
          Options(
            ..options,
            policy: policy.Policy(
              ..options.policy,
              catch_all_multi_subject: True,
            ),
          )
        path -> Options(..options, paths: [path, ..options.paths])
      }
  }
}

fn number(value: String, fallback: Int) -> Int {
  case int.parse(value) {
    Ok(parsed) -> parsed
    Error(Nil) -> fallback
  }
}

fn promoted(value: String) -> List(Rule) {
  value
  |> string.split(",")
  |> list.filter_map(finding.parse)
}

// --- running ----------------------------------------------------------------

fn run(options: Options) -> Nil {
  let files =
    options.paths
    |> list.flat_map(sources)
    |> list.filter(fn(path) { options.include_tests || !is_test(path) })
    |> list.sort(string.compare)

  // Read once, lint twice. R1's structural half needs a table of every
  // `use`-compatible combinator the run can see before it can judge any one
  // call site: a combinator defined in `tools/tool` is called from sixteen
  // other modules, and a per-file table saw none of them (issue #73, D).
  let read = list.filter_map(files, contents)
  let combinators =
    list.flat_map(read, fn(source) {
      lint.exported_combinators(display(source.0), source.1)
    })
  let findings =
    read
    |> list.flat_map(fn(source) { lint_source(source, options, combinators) })
    |> list.append(list.flat_map(manifests_of(files), lint_manifest))
  case options.quiet {
    True -> Nil
    False -> print_findings(findings, options.limit)
  }
  print_census(findings, files)
  print_summary(findings, options.errors)
}

/// A source and its text, or nothing when it cannot be read. A file that
/// vanished between discovery and reading is not a finding.
fn contents(path: String) -> Result(#(String, String), Nil) {
  case simplifile.read(path) {
    Error(_) -> Error(Nil)
    Ok(source) -> Ok(#(path, source))
  }
}

fn lint_source(
  source: #(String, String),
  options: Options,
  combinators: List(Eager),
) -> List(Finding) {
  let #(path, code) = source
  let file_policy = case is_test(path) {
    True -> policy.for_tests_like(options.policy)
    False -> options.policy
  }
  lint.check_with(display(path), code, file_policy, combinators)
}

fn lint_manifest(path: String) -> List(Finding) {
  case simplifile.read(path) {
    Error(_) -> []
    Ok(source) -> lint.check_manifest(display(path), source)
  }
}

/// The manifest of every package a run's sources belong to, deduplicated.
///
/// Derived from the sources rather than discovered, because the paths this
/// tool is pointed at are source trees; see the module doc.
fn manifests_of(files: List(String)) -> List(String) {
  files
  |> list.filter_map(package_root)
  |> list.unique
  |> list.map(fn(root) { root <> "/gleam.toml" })
}

/// The package root above a source path. `src/` or `test/`, whichever this
/// path went through — a run given `--tests` and nothing else still has a
/// manifest to check.
fn package_root(path: String) -> Result(String, Nil) {
  string.split_once(path, "/src/")
  |> result.lazy_or(fn() { string.split_once(path, "/test/") })
  |> result.map(pair.first)
}

/// Every `.gleam` file under a path, which may itself be a file.
fn sources(path: String) -> List(String) {
  case simplifile.get_files(path) {
    Ok(files) -> list.filter(files, is_gleam)
    Error(_) ->
      case is_gleam(path) {
        True -> [path]
        False -> []
      }
  }
}

fn is_gleam(path: String) -> Bool {
  string.ends_with(path, ".gleam") && !string.contains(path, "/build/")
}

fn is_test(path: String) -> Bool {
  string.contains(path, "/test/")
}

/// Report a path the way the repository refers to it.
fn display(path: String) -> String {
  case string.split_once(path, "packages/") {
    Ok(#(_, rest)) -> "packages/" <> rest
    Error(Nil) -> path
  }
}

/// The package a path belongs to, for the census rows. The same judgement
/// R6 makes about a path, so a manifest finding lands on its package's row
/// rather than in a column of its own.
fn package_of(path: String) -> String {
  option.unwrap(lint.package_of(path), "(other)")
}

// --- printing ---------------------------------------------------------------

fn print_findings(findings: List(Finding), limit: Int) -> Nil {
  list.each(finding.rules(), fn(rule) {
    let matching = list.filter(findings, fn(found) { found.rule == rule })
    case matching {
      [] -> Nil
      _ -> {
        io.println("")
        io.println(
          finding.id(rule)
          <> " "
          <> finding.name(rule)
          <> " — "
          <> count_text(matching)
          <> " finding(s)",
        )
        let shown = case limit > 0 {
          True -> list.take(matching, limit)
          False -> matching
        }
        list.each(shown, fn(found) { io.println("  " <> finding.render(found)) })
        elision(matching, shown)
      }
    }
  })
}

fn elision(matching: List(Finding), shown: List(Finding)) -> Nil {
  let hidden = list.length(matching) - list.length(shown)
  case hidden > 0 {
    False -> Nil
    True ->
      io.println(
        "  … " <> int.to_string(hidden) <> " more (--limit=0 lists every one)",
      )
  }
}

fn count_text(findings: List(Finding)) -> String {
  int.to_string(list.length(findings))
}

fn print_census(findings: List(Finding), files: List(String)) -> Nil {
  let by_package = tally(findings)
  let packages =
    files
    |> list.map(package_of)
    |> list.unique
    |> list.sort(string.compare)
  io.println("")
  io.println("census — findings per rule, per package")
  io.println("")
  io.println(header())
  list.each(packages, fn(package) {
    io.println(row(package, fn(rule) { count(by_package, package, rule) }))
  })
  io.println(
    row("TOTAL", fn(rule) {
      list.length(list.filter(findings, fn(found) { found.rule == rule }))
    }),
  )
}

fn header() -> String {
  list.fold(finding.rules(), pad("package", 14), fn(line, rule) {
    line <> pad_left(finding.id(rule), 6)
  })
  <> pad_left("total", 8)
}

fn row(label: String, counter: fn(Rule) -> Int) -> String {
  let counts = list.map(finding.rules(), counter)
  let cells =
    list.fold(counts, pad(label, 14), fn(line, value) {
      line <> pad_left(int.to_string(value), 6)
    })
  cells <> pad_left(int.to_string(int.sum(counts)), 8)
}

fn tally(findings: List(Finding)) -> Dict(#(String, Rule), Int) {
  list.fold(findings, dict.new(), fn(counts, found) {
    let key = #(package_of(found.path), found.rule)
    let seen = case dict.get(counts, key) {
      Ok(value) -> value
      Error(Nil) -> 0
    }
    dict.insert(counts, key, seen + 1)
  })
}

fn count(
  counts: Dict(#(String, Rule), Int),
  package: String,
  rule: Rule,
) -> Int {
  case dict.get(counts, #(package, rule)) {
    Ok(value) -> value
    Error(Nil) -> 0
  }
}

fn print_summary(findings: List(Finding), errors: List(Rule)) -> Nil {
  let #(gated, warned) = finding.gate(findings, errors)
  io.println("")
  case errors {
    [] ->
      io.println("every rule is at warning level; nothing here fails the build")
    promoted ->
      io.println(
        "error level: "
        <> string.join(list.map(promoted, finding.id), ", ")
        <> " — every other rule warns",
      )
  }
  io.println(
    "lint: "
    <> int.to_string(gated)
    <> " error(s), "
    <> int.to_string(warned)
    <> " warning(s)",
  )
  io.println("# " <> int.to_string(gated) <> " " <> int.to_string(warned))
}

/// A census cell, padded to its column — and a label already at or past
/// the column keeps one space, so the row still reads as a row.
///
/// `pad_end` returns the text unchanged when it is already wide enough,
/// which is the same question `string.length(text) >= width` asks and
/// answers without walking a label to its end (R5, this tool's own rule).
fn pad(text: String, width: Int) -> String {
  let padded = string.pad_end(text, width, " ")
  case padded == text {
    True -> text <> " "
    False -> padded
  }
}

fn pad_left(text: String, width: Int) -> String {
  string.pad_start(text, width, " ")
}
