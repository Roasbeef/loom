//// The command line for `lint/affected`: read the tree, make the selection,
//// print it.
////
//// Usage: `gleam run -m lint/affected_cli -- --root DIR --tracked FILE
//// [--paths FILE] [--format text|lanes] [PATH...]`
////
//// `--root` is the repository root and `--tracked` a file listing every
//// tracked path, one per line, as `git ls-files` prints them. The changed
//// paths are the lines of `--paths` followed by any positional paths. Git
//// stays outside on purpose: `scripts/check_affected.sh` runs it and passes
//// the answers in, so this module reads files and nothing else, and the
//// selection it prints is a pure function of what it was handed.
////
//// # The last line is the status
////
//// A Gleam program run with `gleam run` has no way to set its exit status
//// without a foreign call, and this package holds none. So, as
//// `lint/cli` ends with `# <errors> <warnings>`, the last line here is
//// `# ok` when the selection was made and `# error <why>` when it was not.
//// The caller reads that line and strips it; everything above it is the
//// report, byte for byte what `lint/affected` renders.

import argv
import gleam/bit_array
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lint/affected
import lint/affected_graph
import simplifile

/// How the selection is printed.
type Format {
  /// The human-readable report of `affected.render`.
  Text

  /// The plan `scripts/check_affected.sh` runs, from `affected.render_lanes`.
  Lanes
}

/// The parsed command line.
type Options {
  Options(
    root: Option(String),
    tracked: Option(String),
    paths_file: Option(String),
    format: Format,
    paths: List(String),
  )
}

pub fn main() -> Nil {
  case run(argv.load().arguments) {
    Ok(report) -> {
      io.println(report)
      io.println("# ok")
    }
    Error(why) -> io.println("# error " <> why)
  }
}

fn run(arguments: List(String)) -> Result(String, String) {
  use options <- result.try(parse(arguments, start()))
  use root <- result.try(required(options.root, "--root"))
  use tracked_file <- result.try(required(options.tracked, "--tracked"))
  use tracked <- result.try(read_lines(tracked_file))
  use listed <- result.try(case options.paths_file {
    Some(file) -> read_lines(file)
    None -> Ok([])
  })
  use patterns <- result.try(affected_graph.patterns())
  use entries <- result.try(package_entries(root))
  use graph <- result.try(
    affected_graph.build_graph(patterns, entries, tracked, fn(path) {
      read_source(root <> "/" <> path)
    }),
  )
  let selection = affected.select(list.append(listed, options.paths), graph)
  Ok(case options.format {
    Text -> affected.render(selection)
    Lanes -> affected.render_lanes(selection)
  })
}

fn start() -> Options {
  Options(root: None, tracked: None, paths_file: None, format: Text, paths: [])
}

fn parse(arguments: List(String), options: Options) -> Result(Options, String) {
  case arguments {
    [] -> Ok(Options(..options, paths: list.reverse(options.paths)))
    ["--root", value, ..rest] ->
      parse(rest, Options(..options, root: Some(value)))
    ["--tracked", value, ..rest] ->
      parse(rest, Options(..options, tracked: Some(value)))
    ["--paths", value, ..rest] ->
      parse(rest, Options(..options, paths_file: Some(value)))
    ["--format", "text", ..rest] ->
      parse(rest, Options(..options, format: Text))
    ["--format", "lanes", ..rest] ->
      parse(rest, Options(..options, format: Lanes))
    ["--format", other, ..] -> Error("unknown --format " <> other)
    [argument, ..rest] ->
      case string.starts_with(argument, "--") {
        True -> Error("unknown option " <> argument)
        False ->
          parse(rest, Options(..options, paths: [argument, ..options.paths]))
      }
  }
}

fn required(value: Option(String), flag: String) -> Result(String, String) {
  option.to_result(value, flag <> " is required")
}

// A file of paths, one per line. Blank lines are not paths: a diff that
// changed nothing leaves an empty file, and that is an empty change.
fn read_lines(path: String) -> Result(List(String), String) {
  use text <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(why) {
      "cannot read " <> path <> ": " <> simplifile.describe_error(why)
    }),
  )
  Ok(string.split(text, "\n") |> list.filter(fn(line) { line != "" }))
}

// Every directory under `packages/`, with its manifest text when it has one.
fn package_entries(root: String) -> Result(List(affected_graph.Entry), String) {
  let base = root <> "/packages"
  use names <- result.try(
    simplifile.read_directory(base)
    |> result.map_error(fn(why) {
      "cannot list " <> base <> ": " <> simplifile.describe_error(why)
    }),
  )
  Ok(
    names
    |> list.sort(string.compare)
    |> list.filter(fn(name) {
      simplifile.is_directory(base <> "/" <> name) |> result.unwrap(False)
    })
    |> list.map(fn(name) {
      affected_graph.Entry(
        name:,
        manifest: simplifile.read(base <> "/" <> name <> "/gleam.toml")
          |> option.from_result,
      )
    }),
  )
}

// A source's text for the literal scan. The patterns match ASCII only, so a
// file that is not valid UTF-8 is scanned with each non-ASCII byte replaced
// by a character no pattern accepts, which keeps a match from spanning it.
fn read_source(path: String) -> Result(String, Nil) {
  use bytes <- result.try(
    simplifile.read_bits(path) |> result.replace_error(Nil),
  )
  case bit_array.to_string(bytes) {
    Ok(text) -> Ok(text)
    Error(Nil) -> Ok(ascii_only(bytes))
  }
}

fn ascii_only(bytes: BitArray) -> String {
  ascii_loop(bytes, "")
}

fn ascii_loop(bytes: BitArray, text: String) -> String {
  case bytes {
    <<byte, rest:bits>> if byte < 128 ->
      case bit_array.to_string(<<byte>>) {
        Ok(character) -> ascii_loop(rest, text <> character)
        Error(Nil) -> ascii_loop(rest, text <> "?")
      }
    <<_, rest:bits>> -> ascii_loop(rest, text <> "?")
    _ -> text
  }
}
