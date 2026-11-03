//// Proposing a project's `setup` and `check` from its repository, so that a
//// person confirms a command instead of composing one (protocol-change/106,
//// "Settings held per project").
////
//// The rule is derive before asking, and the derivation is deliberately
//// small. The daemon looks at a handful of well-known files in the root of the
//// project's repository and answers from a fixed table: a `Makefile` with a
//// `check`, `test`, `unit` or `lint` target, a `go.mod`, a `gleam.toml`, a
//// `Cargo.toml`, a `package.json` with a `check`, `test` or `lint` script, a
//// `pyproject.toml`. No model is asked and nothing in the repository is run.
////
//// Repository text is untrusted: anyone who can open a pull request can edit a
//// `Makefile`. So the files are read as data and never executed, never
//// followed through a symbolic link, bounded in size, and parsed only for the
//// *names* of targets and scripts. A proposal is never text from a file. Its
//// command is one of the fixed strings in this module, chosen by whether a
//// name from a short allow-list is present, so what a person is asked to
//// confirm is a string this module wrote. Nothing is applied here: the owner
//// confirms a proposal by setting the value (`projects.set_settings`).
////
//// ## Flow
////
//// `read` → `propose` → `Proposal`
////
//// 1. `read` loads the marker files that exist as regular files within the
////    size bound, and records those it refused and why.
//// 2. `propose` is pure over those files, so the table is tested on small
////    fixtures without a disk.

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import simplifile

/// The largest marker file read, in bytes. A real `Makefile` or manifest is far
/// smaller; a larger one is not read, and the proposal says so.
pub const max_file_bytes = 262_144

/// The most lines of a `Makefile` looked at for target names.
pub const max_make_lines = 5000

/// The marker files the table reads, by name. A file that is absent is simply
/// not a marker.
const marker_files = [
  "Makefile", "makefile", "GNUmakefile", "go.mod", "gleam.toml", "Cargo.toml",
  "package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock",
  "pyproject.toml", "uv.lock",
]

/// The `Makefile` targets that can be a check, best first.
const check_targets = ["check", "test", "unit", "lint"]

/// The `Makefile` targets that can be a setup, best first.
const setup_targets = ["deps", "setup", "bootstrap", "vendor"]

/// A command proposed for one key, with where it came from.
pub type Proposal {
  Proposal(
    /// The command. It is always one of this module's fixed strings.
    command: String,
    /// Why it was proposed, in words this module wrote, for example
    /// `Makefile target check`.
    because: String,
  )
}

/// What the table proposes for a repository.
pub type Proposals {
  Proposals(
    /// The proposed check, or none when no marker gave one.
    check: Option(Proposal),
    /// The proposed setup, or none when no marker gave one.
    setup: Option(Proposal),
    /// Marker files that were present and not read, as fixed sentences. A
    /// person who sees one knows the proposal is missing something.
    notes: List(String),
  )
}

/// The marker files of a repository: their text, by name. A file only its
/// presence matters for holds the empty string.
pub type Repository {
  Repository(
    /// The files that were read, by name in the repository root.
    files: Dict(String, String),
    /// Marker files present but not read, as fixed sentences.
    notes: List(String),
  )
}

/// Reads the marker files from a repository's root. A file is read only when it
/// is a regular file reached without a symbolic link, within `max_file_bytes`.
/// Everything else is left unread and noted, so a `Makefile` that links to a
/// file outside the repository is never opened.
///
/// ## Examples
///
/// ```gleam
/// // project_proposal.read("/work/repo")
/// ```
pub fn read(root: String) -> Repository {
  list.fold(
    marker_files,
    Repository(files: dict.new(), notes: []),
    fn(acc, name) {
      case simplifile.link_info(root <> "/" <> name) {
        Error(_) -> acc
        Ok(info) ->
          case simplifile.file_info_type(info), info.size <= max_file_bytes {
            simplifile.File, True -> keep(acc, root, name)
            simplifile.File, False ->
              note(acc, name <> " is larger than 256 KiB and was not read")
            simplifile.Symlink, _ ->
              note(acc, name <> " is a symbolic link and was not followed")
            simplifile.Directory, _ | simplifile.Other, _ ->
              note(acc, name <> " is not a regular file and was not read")
          }
      }
    },
  )
}

/// Loads one regular file into the repository.
fn keep(acc: Repository, root: String, name: String) -> Repository {
  case simplifile.read(root <> "/" <> name) {
    Ok(text) -> Repository(..acc, files: dict.insert(acc.files, name, text))
    Error(_) -> note(acc, name <> " could not be read")
  }
}

/// Adds a note to a repository.
fn note(acc: Repository, words: String) -> Repository {
  Repository(..acc, notes: list.append(acc.notes, [words]))
}

/// Proposes a check and a setup from the files of a repository. A key no
/// marker speaks for is left empty, which means a person writes one.
///
/// ## Examples
///
/// ```gleam
/// let repo = project_proposal.Repository(dict.from_list([#("go.mod", "module x")]), [])
/// let proposed = project_proposal.propose(repo)
/// assert proposed.setup == option.Some(project_proposal.Proposal("go mod download", "go.mod"))
/// ```
pub fn propose(repository: Repository) -> Proposals {
  let targets = make_targets(repository.files)
  Proposals(
    check: first_of([
      from_targets(targets, check_targets, "make"),
      from_manifests(repository.files, Check),
    ]),
    setup: first_of([
      from_targets(targets, setup_targets, "make"),
      from_manifests(repository.files, Setup),
    ]),
    notes: repository.notes,
  )
}

/// Which of the two keys a manifest is asked about.
type Want {
  Check
  Setup
}

/// The first proposal in a list that exists.
fn first_of(candidates: List(Option(Proposal))) -> Option(Proposal) {
  list.find_map(candidates, option.to_result(_, Nil)) |> option.from_result
}

/// The first allow-listed target the `Makefile` defines, as `<tool> <target>`.
/// The target in the command is the allow-list's own spelling.
fn from_targets(
  targets: set.Set(String),
  wanted: List(String),
  tool: String,
) -> Option(Proposal) {
  list.find(wanted, fn(name) { set.contains(targets, name) })
  |> result.map(fn(name) {
    Proposal(command: tool <> " " <> name, because: "Makefile target " <> name)
  })
  |> option.from_result
}

/// The proposal a language manifest gives for one key, trying the manifests in
/// a fixed order.
fn from_manifests(files: Dict(String, String), want: Want) -> Option(Proposal) {
  first_of([
    go_module(files, want),
    gleam_project(files, want),
    cargo_crate(files, want),
    node_package(files, want),
    python_project(files, want),
  ])
}

fn go_module(files: Dict(String, String), want: Want) -> Option(Proposal) {
  case dict.has_key(files, "go.mod"), want {
    True, Setup -> Some(Proposal("go mod download", "go.mod"))
    True, Check -> Some(Proposal("go test ./...", "go.mod"))
    False, _ -> None
  }
}

fn gleam_project(files: Dict(String, String), want: Want) -> Option(Proposal) {
  case dict.has_key(files, "gleam.toml"), want {
    True, Setup -> Some(Proposal("gleam deps download", "gleam.toml"))
    True, Check -> Some(Proposal("gleam test", "gleam.toml"))
    False, _ -> None
  }
}

fn cargo_crate(files: Dict(String, String), want: Want) -> Option(Proposal) {
  case dict.has_key(files, "Cargo.toml"), want {
    True, Setup -> Some(Proposal("cargo fetch", "Cargo.toml"))
    True, Check -> Some(Proposal("cargo test --offline", "Cargo.toml"))
    False, _ -> None
  }
}

/// A Node package: the lock file picks the installer, and a `check`, `test` or
/// `lint` script, found by name only, picks the check.
fn node_package(files: Dict(String, String), want: Want) -> Option(Proposal) {
  case dict.get(files, "package.json"), want {
    Error(Nil), _ -> None
    Ok(_), Setup -> Some(node_install(files))
    Ok(text), Check ->
      list.find(["check", "test", "lint"], fn(name) {
        list.contains(script_names(text), name)
      })
      |> result.map(fn(name) {
        case name {
          "test" -> Proposal("npm test", "package.json script test")
          _ -> Proposal("npm run " <> name, "package.json script " <> name)
        }
      })
      |> option.from_result
  }
}

fn node_install(files: Dict(String, String)) -> Proposal {
  case
    dict.has_key(files, "pnpm-lock.yaml"),
    dict.has_key(files, "yarn.lock"),
    dict.has_key(files, "package-lock.json")
  {
    True, _, _ -> Proposal("pnpm install --frozen-lockfile", "pnpm-lock.yaml")
    False, True, _ -> Proposal("yarn install --frozen-lockfile", "yarn.lock")
    False, False, True -> Proposal("npm ci", "package-lock.json")
    False, False, False -> Proposal("npm install", "package.json")
  }
}

/// A Python project: `uv.lock` picks `uv sync`, and a check is proposed only
/// when `pyproject.toml` mentions `pytest`.
fn python_project(files: Dict(String, String), want: Want) -> Option(Proposal) {
  case dict.get(files, "pyproject.toml"), want {
    Error(Nil), _ -> None
    Ok(_), Setup ->
      case dict.has_key(files, "uv.lock") {
        True -> Some(Proposal("uv sync", "uv.lock"))
        False -> Some(Proposal("python3 -m pip install -e .", "pyproject.toml"))
      }
    Ok(text), Check ->
      case string.contains(text, "pytest") {
        True ->
          Some(Proposal("python3 -m pytest", "pyproject.toml mentions pytest"))
        False -> None
      }
  }
}

/// The names of the scripts a `package.json` declares, or none when it is not
/// the object it should be. Only the names are read.
fn script_names(text: String) -> List(String) {
  let decoder =
    decode.at(["scripts"], decode.dict(decode.string, decode.dynamic))
  case json.parse(text, decoder) {
    Ok(scripts) -> dict.keys(scripts)
    Error(_) -> []
  }
}

/// The names a `Makefile` defines as targets and that pass `valid_target`,
/// from its first `max_make_lines` lines. A name is taken from the left of a
/// colon on a line that does not start with a tab, a space or a comment mark.
/// Nothing else on the line is read.
///
/// ## Examples
///
/// ```gleam
/// let targets = project_proposal.make_targets(dict.from_list([#("Makefile", "check: build\n\ttrue\n")]))
/// assert set.contains(targets, "check")
/// ```
pub fn make_targets(files: Dict(String, String)) -> set.Set(String) {
  let text =
    list.find_map(["Makefile", "makefile", "GNUmakefile"], fn(name) {
      dict.get(files, name)
    })
    |> result.unwrap("")

  string.split(text, "\n")
  |> list.take(max_make_lines)
  |> list.flat_map(target_names)
  |> set.from_list
}

/// The valid target names on one `Makefile` line.
fn target_names(line: String) -> List(String) {
  case string.first(line) {
    Error(Nil) -> []
    Ok(first) if first == "\t" || first == " " || first == "#" -> []
    Ok(_) ->
      case string.split_once(line, ":") {
        Error(Nil) -> []
        Ok(#(names, after)) ->
          case string.first(after) {
            // `:=` and `::=` assign a variable and name no target.
            Ok("=") | Ok(":") -> []
            _ ->
              string.split(names, " ")
              |> list.filter(valid_target)
          }
      }
  }
}

/// Whether a name is a plain target: a lower-case letter, then at most thirty
/// more lower-case letters, digits, hyphens or underscores. Variables,
/// patterns, paths and special targets all fail it.
///
/// ## Examples
///
/// ```gleam
/// assert project_proposal.valid_target("check-client")
/// assert !project_proposal.valid_target("$(shell id)")
/// ```
pub fn valid_target(name: String) -> Bool {
  let letters = string.to_graphemes(name)
  case letters {
    [first, ..rest] ->
      is_lower(first)
      && list.length(rest) <= 31
      && list.all(rest, fn(each) {
        is_lower(each) || is_digit(each) || each == "-" || each == "_"
      })
    [] -> False
  }
}

fn is_lower(letter: String) -> Bool {
  string.contains("abcdefghijklmnopqrstuvwxyz", letter) && letter != ""
}

fn is_digit(letter: String) -> Bool {
  string.contains("0123456789", letter) && letter != ""
}
