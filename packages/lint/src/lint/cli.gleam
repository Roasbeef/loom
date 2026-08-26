//// The command line: find sources, lint them, print the findings and the
//// census.
////
//// This is the only module in the package that does I/O. It also holds the
//// staging decision: **every rule is a warning**. The linter never sets a
//// non-zero exit code on its own, and `scripts/lint.sh` reads the trailing
//// `# <errors> <warnings>` line to decide, exactly as `scripts/doc_check.sh`
//// does. Promoting a rule is `--error=R4` and nothing else; the census is
//// what argues for or against doing so.

import argv
import gleam/dict.{type Dict}
import gleam/int
import gleam/io
import gleam/list
import gleam/string
import lint
import lint/finding.{type Finding, type Rule}
import lint/policy.{type Policy}
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
  --error=R1,R4   promote these rules to error level (default: none)
  --tests         also lint test/ sources (R4 is off for them)
  --limit=N       list at most N findings per rule (default 25; 0 = all)
  --quiet         print the census only
  --help          this

Every rule is a warning unless named by --error. The last line of output is
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
    errors: [],
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
  let findings = list.flat_map(files, fn(path) { lint_file(path, options) })
  case options.quiet {
    True -> Nil
    False -> print_findings(findings, options.limit)
  }
  print_census(findings, files)
  print_summary(findings, options.errors)
}

fn lint_file(path: String, options: Options) -> List(Finding) {
  case simplifile.read(path) {
    Error(_) -> []
    Ok(source) -> {
      let file_policy = case is_test(path) {
        True -> policy.Policy(..options.policy, allow_panic: True)
        False -> options.policy
      }
      lint.check(display(path), source, file_policy)
    }
  }
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

/// The package a path belongs to, for the census rows.
fn package_of(path: String) -> String {
  case string.split_once(display(path), "packages/") {
    Ok(#(_, rest)) ->
      case string.split(rest, "/") {
        [name, ..] -> name
        [] -> rest
      }
    Error(Nil) -> "(other)"
  }
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
  let #(gated, warned) =
    list.partition(findings, fn(found) { list.contains(errors, found.rule) })
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
    <> count_text(gated)
    <> " error(s), "
    <> count_text(warned)
    <> " warning(s)",
  )
  io.println("# " <> count_text(gated) <> " " <> count_text(warned))
}

fn pad(text: String, width: Int) -> String {
  case string.length(text) >= width {
    True -> text <> " "
    False -> string.pad_end(text, width, " ")
  }
}

fn pad_left(text: String, width: Int) -> String {
  string.pad_start(text, width, " ")
}
