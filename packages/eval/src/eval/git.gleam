//// Everything the miner needs to know about a git repository, split into
//// the part that decides and the part that runs.
////
//// The deciding part is pure text in and text out. Which commits are worth
//// mining, how one commit's diff divides into the hidden tests and the fix,
//// which single line of a fix to revert for the sabotage census, and what
//// argv asks git each question are all functions of strings, so they are
//// tested against captured text and never need a repository. The running
//// part is three small functions over `client/secrets.Runner`, the same
//// seam the secret resolver uses to run a program on the host with a
//// deadline; a test hands it a scripted runner and a real run hands it
//// `secrets.host_runner()`.
////
//// Every shell string in the module passes through `shell_quote`. The
//// runner takes an argv and has no working directory, so running a command
//// inside a worktree means `bash -c 'cd <dir> && <argv> 2>&1'`, and the
//// directory, the arguments and the commit hashes are all interpolated into
//// that one string. A path with a quote in it must stay one word, and the
//// property test on `shell_quote` is what holds that.
////
//// The ruling about history lives here too, because every function below
//// serves it: an agent is never handed a git worktree. A worktree carries
//// the whole object store, so `git log --all` inside one would print the
//// fix. The miner uses `worktree add --detach` for its own before/after
//// runs and removes each one afterwards; the task records the commit and
//// tree, and the runner materialises the starting files with `git archive`.

import client/secrets.{type Capture, type Runner}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// A commit that looks like a bug fix with its own regression test.
pub type Candidate {
  Candidate(
    /// The full commit hash.
    commit: String,
    /// The first line of the commit message.
    subject: String,
    /// The one package the commit touches (`machine` for `packages/machine`).
    package: String,
    /// Paths of the changed `.gleam` sources, one or two.
    src_files: List(String),
    /// Paths of the changed `*_test.gleam` files, one or two. These name the
    /// test modules the verifier runs.
    test_files: List(String),
  )
}

/// A commit's diff divided into the part the agent must not see and the
/// part it is asked to reproduce.
pub type PatchSplit {
  PatchSplit(
    /// Diff sections for `packages/*/test/**`: the hidden verifier files.
    tests: String,
    /// Diff sections for everything else except documentation: the fix.
    src: String,
    /// The paths in `tests`, in diff order.
    test_paths: List(String),
    /// The paths in `src`, in diff order.
    src_paths: List(String),
  )
}

/// One edit that undoes a single changed line of a fix, expressed against
/// the file as it stands after the fix. Line numbers are one-based.
pub type Edit {
  /// Put `with` where the fix's `expected` line now stands.
  Replace(line: Int, expected: String, with: String)

  /// Remove the line the fix added.
  Delete(line: Int, expected: String)

  /// Restore a line the fix removed, ahead of the line now at `before`.
  Insert(before: Int, text: String)
}

/// An `Edit` and the file it applies to.
pub type Revert {
  Revert(path: String, edit: Edit)
}

/// Quotes a string as one shell word. Single quotes keep everything literal
/// except the single quote itself, which is closed, escaped and reopened.
///
/// ## Examples
///
/// ```gleam
/// assert git.shell_quote("it's") == "'it'\\''s'"
/// ```
///
pub fn shell_quote(text: String) -> String {
  "'" <> string.replace(text, "'", "'\\''") <> "'"
}

/// The argv that runs `argv` with `dir` as its working directory and its
/// error stream folded into its output, so a failed build and a failed test
/// arrive in one capture in the order they happened.
///
/// ## Examples
///
/// ```gleam
/// assert git.in_dir("/w", ["git", "status"])
///   == ["bash", "-c", "cd '/w' && 'git' 'status' 2>&1"]
/// ```
///
pub fn in_dir(dir: String, argv: List(String)) -> List(String) {
  ["bash", "-c", "cd " <> shell_quote(dir) <> " && " <> quoted(argv) <> " 2>&1"]
}

/// Joins an argv into one shell command with every word quoted.
///
/// ## Examples
///
/// ```gleam
/// assert git.quoted(["a", "b c"]) == "'a' 'b c'"
/// ```
///
pub fn quoted(argv: List(String)) -> String {
  argv |> list.map(shell_quote) |> string.join(" ")
}

/// Runs an argv in a directory and answers its capture. `Error` means no
/// process ran to completion (spawn refused, deadline); a nonzero exit is a
/// successful `Capture` for the caller to judge.
///
/// ## Examples
///
/// ```gleam
/// // git.run_in(secrets.host_runner(), "/w", ["gleam", "build"], 60_000)
/// ```
///
pub fn run_in(
  runner: Runner,
  dir: String,
  argv: List(String),
  timeout_ms: Int,
) -> Result(Capture, String) {
  runner(in_dir(dir, argv), timeout_ms)
}

/// Runs a git command in a repository and answers its output only when it
/// exited zero, with the output in the error otherwise.
///
/// ## Examples
///
/// ```gleam
/// // git.ask(runner, repo, ["rev-parse", "HEAD"], 30_000) == Ok("3f9a…\n")
/// ```
///
pub fn ask(
  runner: Runner,
  repo: String,
  args: List(String),
  timeout_ms: Int,
) -> Result(String, String) {
  use capture <- result.try(run_in(runner, repo, ["git", ..args], timeout_ms))

  // Only a zero exit makes the output an answer; anything else carries the command and its output as the reason.
  case capture.status {
    0 -> Ok(capture.output)
    status ->
      Error(
        "git "
        <> string.join(args, " ")
        <> " exited "
        <> int.to_string(status)
        <> ": "
        <> string.trim(capture.output),
      )
  }
}

/// The log that lists every non-merge commit with the files it changed.
///
/// ## Examples
///
/// ```gleam
/// assert list.contains(git.candidate_log_args("main"), "--name-status")
/// ```
///
pub fn candidate_log_args(rev: String) -> List(String) {
  [
    "log", "--no-merges", "--no-renames", "--name-status",
    "--format=commit %H %s", rev,
  ]
}

/// The argument list that prints a commit's whole message.
///
/// ## Examples
///
/// ```gleam
/// assert git.message_args("abc") == ["log", "-1", "--format=%B", "abc"]
/// ```
///
pub fn message_args(commit: String) -> List(String) {
  ["log", "-1", "--format=%B", commit]
}

/// The argument list that prints the tree digest of a commit. The tree is a
/// content digest of every file, which is why a task records it and needs no
/// second hash of the workspace.
///
/// ## Examples
///
/// ```gleam
/// assert git.tree_args("abc") == ["rev-parse", "abc^{tree}"]
/// ```
///
pub fn tree_args(commit: String) -> List(String) {
  ["rev-parse", commit <> "^{tree}"]
}

/// The argument list that prints a commit's first parent.
///
/// ## Examples
///
/// ```gleam
/// assert git.parent_args("abc") == ["rev-parse", "abc^"]
/// ```
///
pub fn parent_args(commit: String) -> List(String) {
  ["rev-parse", commit <> "^"]
}

/// The argument list that prints the full diff from a commit's parent to the
/// commit, with binary content and no rename detection so every file is one
/// plain section.
///
/// ## Examples
///
/// ```gleam
/// assert list.contains(git.diff_args("abc"), "--binary")
/// ```
///
pub fn diff_args(commit: String) -> List(String) {
  [
    "diff",
    "--binary",
    "--no-renames",
    "--no-ext-diff",
    "--no-color",
    commit <> "^",
    commit,
  ]
}

/// The argument list that adds a detached worktree at a revision.
///
/// ## Examples
///
/// ```gleam
/// assert git.worktree_add_args("/w/x", "abc")
///   == ["worktree", "add", "--detach", "/w/x", "abc"]
/// ```
///
pub fn worktree_add_args(path: String, rev: String) -> List(String) {
  ["worktree", "add", "--detach", path, rev]
}

/// The argument list that removes a worktree even if a build dirtied it.
///
/// ## Examples
///
/// ```gleam
/// assert git.worktree_remove_args("/w/x")
///   == ["worktree", "remove", "--force", "/w/x"]
/// ```
///
pub fn worktree_remove_args(path: String) -> List(String) {
  ["worktree", "remove", "--force", path]
}

/// The argument list that applies a patch file to the working tree.
///
/// ## Examples
///
/// ```gleam
/// assert git.apply_args("/w/p.patch") == ["apply", "--whitespace=nowarn", "/w/p.patch"]
/// ```
///
pub fn apply_args(patch_file: String) -> List(String) {
  ["apply", "--whitespace=nowarn", patch_file]
}

/// Splits a commit message into its subject and its trimmed body.
///
/// ## Examples
///
/// ```gleam
/// assert git.message_parts("fix: a\n\nWhy.\n") == #("fix: a", "Why.")
/// ```
///
pub fn message_parts(message: String) -> #(String, String) {
  case string.split_once(string.trim(message), "\n") {
    Ok(#(subject, body)) -> #(string.trim(subject), string.trim(body))
    Error(Nil) -> #(string.trim(message), "")
  }
}

/// The Erlang module name of a test file, as EUnit prints it:
/// `packages/machine/test/machine/failure_test.gleam` is
/// `machine@failure_test`. `Error` when the path is not a Gleam file under a
/// package's `test/` directory.
///
/// ## Examples
///
/// ```gleam
/// assert git.test_module("packages/lint/test/lint_test.gleam") == Ok("lint_test")
/// ```
///
pub fn test_module(path: String) -> Result(String, Nil) {
  // The path must be `packages/<pkg>/test/<file>...` to name a test module at all.
  case string.split(path, "/") {
    ["packages", _, "test", ..rest] if rest != [] -> {
      let joined = string.join(rest, "@")

      // Only a Gleam file is a module EUnit can run.
      case string.ends_with(joined, ".gleam") {
        True -> Ok(string.drop_end(joined, 6))
        False -> Error(Nil)
      }
    }

    _ -> Error(Nil)
  }
}

/// Reads the output of `candidate_log_args` and keeps the commits that look
/// like a fix with its regression test.
///
/// A candidate touches one or two `.gleam` files under one package's `src/`
/// and one or two `*_test.gleam` files under the same package's `test/`.
/// Other files under `test/` (fixtures, support modules, Erlang helpers) and
/// under `src/` ride along, because they travel with the tests or the fix.
/// That package's `CLAUDE.md` and `AGENTS.md` are allowed. Anything else, a
/// second package or a deleted file, disqualifies the commit: it is a feature
/// or a refactor, and the miner wants the narrow shape where one test module
/// pins one behaviour.
///
/// `packages` restricts the answer to those packages; an empty list keeps
/// them all.
///
/// ## Examples
///
/// ```gleam
/// let log = "commit abc fix: x\n\nM\tpackages/core/src/core/a.gleam\nM\tpackages/core/test/core/a_test.gleam\n"
/// assert list.length(git.parse_candidates(log, [])) == 1
/// ```
///
pub fn parse_candidates(
  log: String,
  packages: List(String),
) -> List(Candidate) {
  log
  |> string.split("\n")
  |> list.fold([], collect_line)
  |> list.reverse
  |> list.filter_map(fn(record) { classify(record.0, record.1) })
  |> list.filter(fn(candidate) {
    packages == [] || list.contains(packages, candidate.package)
  })
}

// One commit's header and its changed files, newest line first while the
// fold is still running.
type Record =
  #(#(String, String), List(#(String, String)))

/// One step of the log fold: a `commit` line opens a record and a status line
/// adds a file to the newest one. Lines that are neither, such as the blank
/// line git prints after the header, change nothing.
fn collect_line(records: List(Record), line: String) -> List(Record) {
  case line {
    "commit " <> rest ->
      case string.split_once(rest, " ") {
        Ok(#(hash, subject)) -> [#(#(hash, subject), []), ..records]
        Error(Nil) -> [#(#(rest, ""), []), ..records]
      }

    _ ->
      case records, string.split_once(line, "\t") {
        [#(header, files), ..older], Ok(#(status, path)) -> [
          #(header, [#(status, path), ..files]),
          ..older
        ]
        _, _ -> records
      }
  }
}

/// Decides whether one commit has the narrow fix-with-test shape and, if so,
/// collects its source and test files. The shape is the whole definition of a
/// candidate, so every refusal here is a commit the miner never spends a build
/// on.
fn classify(
  header: #(String, String),
  files: List(#(String, String)),
) -> Result(Candidate, Nil) {
  let paths = list.map(files, fn(file) { string.split(file.1, "/") })
  use package <- result.try(sole_package(paths))

  // A deleted file cannot be staged as a hidden verifier file, so the commit is refused.

  // A deleted file cannot be staged as a hidden verifier file, so the commit is refused.
  use Nil <- result.try(case list.all(files, fn(file) { file.0 != "D" }) {
    True -> Ok(Nil)
    False -> Error(Nil)
  })

  use Nil <- result.try(list.try_each(paths, allowed_path))

  let all = list.map(files, fn(file) { file.1 })
  let src_files =
    list.filter(all, fn(path) {
      string.starts_with(path, "packages/" <> package <> "/src/")
      && string.ends_with(path, ".gleam")
    })
  let test_files =
    list.filter(all, fn(path) {
      string.starts_with(path, "packages/" <> package <> "/test/")
      && string.ends_with(path, "_test.gleam")
    })

  // The count bounds are the narrow shape: one or two sources and one or two test modules.
  case within(src_files, 1, 2) && within(test_files, 1, 2) {
    True ->
      Ok(Candidate(
        commit: header.0,
        subject: header.1,
        package:,
        src_files:,
        test_files:,
      ))
    False -> Error(Nil)
  }
}

fn within(items: List(a), low: Int, high: Int) -> Bool {
  let count = list.length(items)
  count >= low && count <= high
}

/// The one package every path belongs to; `Error(Nil)` if any path is outside
/// `packages/` or two packages appear.
fn sole_package(paths: List(List(String))) -> Result(String, Nil) {
  let packages =
    paths
    |> list.map(fn(path) {
      case path {
        ["packages", package, ..] -> Ok(package)
        _ -> Error(Nil)
      }
    })
    |> result.all
    |> result.map(list.unique)

  // Exactly one package, or the commit crosses a boundary the miner does not handle.
  case packages {
    Ok([only]) -> Ok(only)
    _ -> Error(Nil)
  }
}

/// A path a candidate may touch: anything under a package's `src/` or `test/`,
/// or its `CLAUDE.md` or `AGENTS.md`.
fn allowed_path(path: List(String)) -> Result(Nil, Nil) {
  case path {
    ["packages", _, "src", _, ..] | ["packages", _, "test", _, ..] -> Ok(Nil)
    ["packages", _, "CLAUDE.md"] | ["packages", _, "AGENTS.md"] -> Ok(Nil)
    _ -> Error(Nil)
  }
}

/// Divides a commit's diff into the hidden tests and the fix.
///
/// A section goes to `tests` when its path is under `packages/*/test/`. It is
/// dropped when its file is a `CLAUDE.md` or `AGENTS.md`, or lives under
/// `docs/`, because prose about the change is not part of the behaviour the
/// verifier checks and would leak the fix into the agent's patch. Everything
/// else is the fix. `Error` names a header that cannot be read, which only a
/// quoted path or a rename (excluded by `--no-renames`) would produce.
///
/// ## Examples
///
/// ```gleam
/// let diff = "diff --git a/docs/x.md b/docs/x.md\n+++ b/docs/x.md\n"
/// assert git.split_patch(diff) == Ok(git.PatchSplit("", "", [], []))
/// ```
///
pub fn split_patch(diff: String) -> Result(PatchSplit, String) {
  use sections <- result.try(sections_of(diff))
  let kept = list.filter(sections, fn(section) { !documentation(section.0) })
  let #(tests, src) = list.partition(kept, fn(section) { is_test(section.0) })

  Ok(PatchSplit(
    tests: render(tests),
    src: render(src),
    test_paths: list.map(tests, fn(section) { section.0 }),
    src_paths: list.map(src, fn(section) { section.0 }),
  ))
}

fn is_test(path: String) -> Bool {
  case string.split(path, "/") {
    ["packages", _, "test", ..] -> True
    _ -> False
  }
}

/// Whether a path is prose about the change (a package note or anything under
/// `docs/`) rather than behaviour.
fn documentation(path: String) -> Bool {
  let segments = string.split(path, "/")

  // Package notes are prose about the change; they never reach the fix or the tests.
  case list.last(segments) {
    Ok("CLAUDE.md") | Ok("AGENTS.md") -> True
    _ -> string.starts_with(path, "docs/")
  }
}

fn render(sections: List(#(String, List(String)))) -> String {
  sections
  |> list.map(fn(section) { string.join(section.1, "\n") <> "\n" })
  |> string.concat
}

/// Groups diff lines into one section per file, keyed by its path. The sections
/// keep every byte of their lines, so rendering them again reproduces the diff
/// text exactly.
fn sections_of(diff: String) -> Result(List(#(String, List(String))), String) {
  // A diff text ends with a newline, which would otherwise read as an empty trailing line.
  let lines = case list.reverse(string.split(diff, "\n")) {
    ["", ..rest] -> list.reverse(rest)
    all -> list.reverse(all)
  }

  use grouped <- result.try(
    list.try_fold(lines, [], fn(sections, line) {
      // A header line opens a new file section; any other line belongs to the section already open.
      case line {
        "diff --git a/" <> rest -> {
          use path <- result.map(header_path(rest))
          [#(path, [line]), ..sections]
        }

        _ ->
          case sections {
            [#(path, body), ..older] -> Ok([#(path, [line, ..body]), ..older])
            [] -> Error("diff text before the first file header")
          }
      }
    }),
  )

  Ok(
    grouped
    |> list.map(fn(section) { #(section.0, list.reverse(section.1)) })
    |> list.reverse,
  )
}

/// Reads the path out of `a/P b/P`. Without renames both halves are the same
/// path, so the first half is taken by length and the second must repeat it;
/// anything else, such as a quoted name, is refused rather than guessed.
fn header_path(rest: String) -> Result(String, String) {
  let length = string.length(rest)
  let path = string.slice(rest, 0, { length - 3 } / 2)

  // Both halves of the header must agree, which is what rules out a rename and a quoted path.
  case path != "" && rest == path <> " b/" <> path {
    True -> Ok(path)
    False -> Error("unreadable diff header: diff --git a/" <> rest)
  }
}

/// Finds the first changed line of a fix that is code (not blank, not a
/// comment, not an `import`) and the edit that undoes
/// it in the post-fix file. A removed line and the added line in the same
/// block of changes pair off in order, so reverting a modified line puts the
/// old text back instead of leaving both. `Error(Nil)` when the patch changes
/// nothing but blank lines, which makes the sabotage census not applicable.
///
/// ## Examples
///
/// ```gleam
/// let patch = "+++ b/f.gleam\n@@ -1,1 +1,2 @@\n a\n+b\n"
/// assert git.first_revert(patch) == Ok(git.Revert("f.gleam", git.Delete(2, "b")))
/// ```
///
pub fn first_revert(patch: String) -> Result(Revert, Nil) {
  scan(string.split(patch, "\n"), Scan("", Outside, 0, [], []))
}

// Whether the walk is inside a hunk's body, where `+`, `-` and space lines
// mean changes, or in a header, where the same characters begin file names.
type Region {
  Outside
  InHunk
}

// Where the line walk stands: the file and hunk it is in, the next line
// number in the post-fix file, and the block of changes collected so far.
type Scan {
  Scan(
    path: String,
    region: Region,
    new_line: Int,
    minus: List(String),
    plus: List(#(Int, String)),
  )
}

/// Walks a patch line by line, collecting each block of consecutive changes,
/// and stops at the first block that has a code line to revert. A file
/// header resets the walk, a hunk header sets the post-fix line counter, and a
/// context line ends the block.
fn scan(lines: List(String), state: Scan) -> Result(Revert, Nil) {
  case lines {
    [] -> block_revert(state)

    [line, ..rest] ->
      case line {
        "+++ b/" <> path ->
          scan_after(block_revert(state), rest, Scan(path, Outside, 0, [], []))

        "+++ " <> _ ->
          scan_after(block_revert(state), rest, Scan("", Outside, 0, [], []))

        "@@ " <> header ->
          scan_after(
            block_revert(state),
            rest,
            Scan(
              ..state,
              region: InHunk,
              new_line: hunk_start(header),
              minus: [],
              plus: [],
            ),
          )

        _ if state.region == Outside -> scan(rest, state)

        "+" <> text ->
          scan(
            rest,
            Scan(..state, new_line: state.new_line + 1, plus: [
              #(state.new_line, text),
              ..state.plus
            ]),
          )

        "-" <> text -> scan(rest, Scan(..state, minus: [text, ..state.minus]))

        " " <> _ ->
          scan_after(
            block_revert(state),
            rest,
            Scan(..state, new_line: state.new_line + 1, minus: [], plus: []),
          )

        _ -> scan(rest, state)
      }
  }
}

/// Continues the walk only when the finished block gave no revert.
fn scan_after(
  found: Result(Revert, Nil),
  rest: List(String),
  next: Scan,
) -> Result(Revert, Nil) {
  case found {
    Ok(revert) -> Ok(revert)
    Error(Nil) -> scan(rest, next)
  }
}

/// The first post-fix line number of a hunk header `-3,4 +7,5 @@`, which is 7;
/// a header without a count is one line.
fn hunk_start(header: String) -> Int {
  let new_range =
    header
    |> string.split(" ")
    |> list.find(fn(word) { string.starts_with(word, "+") })
    |> result.unwrap("+1")

  // A hunk header may omit the count after the start when it is one line.
  let start = case string.split_once(string.drop_start(new_range, 1), ",") {
    Ok(#(first, _count)) -> first
    Error(Nil) -> string.drop_start(new_range, 1)
  }

  result.unwrap(int.parse(start), 1)
}

/// The revert for one block of changes: removed lines are listed before added
/// ones, and the first code line of that order is the line to undo.
fn block_revert(state: Scan) -> Result(Revert, Nil) {
  let minus = list.reverse(state.minus)
  let plus = list.reverse(state.plus)
  let marked =
    list.append(
      list.map(minus, fn(text) { #(Removed, text) }),
      list.map(plus, fn(entry) { #(Added, entry.1) }),
    )

  use #(index, _) <- result.try(
    marked
    |> list.index_map(fn(entry, index) { #(index, entry) })
    |> list.find(fn(entry) { is_code(entry.1.1) }),
  )

  // A change outside any known file, such as a deletion, has nothing to revert.
  use Nil <- result.try(case state.path {
    "" -> Error(Nil)
    _ -> Ok(Nil)
  })

  // The first code change is a removed line while the index is inside the removals, and an added line after them.
  let removed_count = list.length(minus)

  // The combined list puts removed lines first, so an index that lands in
  // them reverts a removal and any later index reverts an addition.
  let edit = case list.drop(minus, index) {
    [_, ..] -> revert_removed(minus, plus, index, state.new_line)
    [] -> revert_added(minus, plus, index - removed_count)
  }

  result.map(edit, fn(edit) { Revert(state.path, edit) })
}

/// Whether a changed line is code worth reverting. Blank lines, comments of
/// any `//` kind and imports are excluded: reverting them cannot change what a
/// test sees, so a "survived" there would measure the choice of line and not
/// the tests.
fn is_code(line: String) -> Bool {
  let text = string.trim(line)

  text != ""
  && !string.starts_with(text, "//")
  && !string.starts_with(text, "import ")
}

/// Which side of the diff a changed line came from.
type Side {
  Removed
  Added
}

/// Undoes a removed line by putting it back, over the added line at the same
/// position when the fix replaced it, or ahead of the line after the block when
/// the fix only removed it.
fn revert_removed(
  minus: List(String),
  plus: List(#(Int, String)),
  index: Int,
  block_end: Int,
) -> Result(Edit, Nil) {
  use old <- result.try(nth(minus, index))

  // A removed line is paired with the added line at the same position when there is one, replacing it; otherwise it is put back.
  case nth(plus, index) {
    Ok(#(line, new)) -> Ok(Replace(line, new, old))
    Error(Nil) -> Ok(Insert(block_end, old))
  }
}

/// Undoes an added line by restoring the removed line at the same position when
/// the fix replaced one, and deleting it otherwise.
fn revert_added(
  minus: List(String),
  plus: List(#(Int, String)),
  index: Int,
) -> Result(Edit, Nil) {
  use #(line, new) <- result.try(nth(plus, index))

  // An added line is paired with the removed line at the same position when there is one, replacing it; otherwise it is deleted.
  case nth(minus, index) {
    Ok(old) -> Ok(Replace(line, new, old))
    Error(Nil) -> Ok(Delete(line, new))
  }
}

fn nth(items: List(a), index: Int) -> Result(a, Nil) {
  items |> list.drop(index) |> list.first
}

/// Applies a revert's edit to the text of the file. `Error(Nil)` when the
/// line it expects is not there, which means the file is not the post-fix
/// text the edit was computed against.
///
/// ## Examples
///
/// ```gleam
/// assert git.apply_edit("a\nb\n", git.Delete(2, "b")) == Ok("a\n")
/// ```
///
pub fn apply_edit(content: String, edit: Edit) -> Result(String, Nil) {
  let lines = string.split(content, "\n")

  // Each edit kind checks its anchor line first, so an edit computed against a different file text is refused.
  case edit {
    Replace(line:, expected:, with:) ->
      expect_line(lines, line, expected)
      |> result.map(fn(_) { join_replacing(lines, line, Some(with)) })

    Delete(line:, expected:) ->
      expect_line(lines, line, expected)
      |> result.map(fn(_) { join_replacing(lines, line, None) })

    Insert(before:, text:) ->
      Ok(string.join(
        list.append(list.take(lines, before - 1), [
          text,
          ..list.drop(lines, before - 1)
        ]),
        "\n",
      ))
  }
}

/// Checks that the line an edit expects is where the edit says it is, so an
/// edit computed against another text is refused.
fn expect_line(
  lines: List(String),
  line: Int,
  expected: String,
) -> Result(Nil, Nil) {
  case nth(lines, line - 1) {
    Ok(actual) if actual == expected -> Ok(Nil)
    _ -> Error(Nil)
  }
}

/// Rebuilds the file text with one line replaced or removed.
fn join_replacing(
  lines: List(String),
  line: Int,
  with: Option(String),
) -> String {
  let head = list.take(lines, line - 1)
  let tail = list.drop(lines, line)

  // A delete leaves no middle; a replace leaves the new text.
  let middle = case with {
    Some(text) -> [text]
    None -> []
  }

  string.join(list.flatten([head, middle, tail]), "\n")
}
