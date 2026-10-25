//// A task is the unit the instrument measures: one prompt, one starting
//// workspace and one hidden verifier, addressed by the digest of its own
//// canonical bytes.
////
//// Three producers mint tasks — a person writing a small fixture, the miner
//// turning a fix commit from Loom's own history into a regression task, and
//// an importer reading a Harbor dataset — and the runner never branches on
//// which one did. Provenance is recorded and hashed, but nothing trusts it:
//// what the runner acts on is the workspace and the verifier.
////
//// Identity is the rule that keeps a benchmark honest. A task's `id` is the
//// SHA-256 of its canonical encoding with the `id` field blank, so editing
//// any byte of the prompt, workspace or verifier mints a different task.
//// "Fixing" a task to make an agent pass is therefore not an edit but a new
//// task, and the old one stays in every ledger that measured it.
////
//// The verifier is hidden by construction rather than by convention. Its
//// files live here, outside the workspace, and the runner writes them into
//// a copy of the frozen workspace only after the agent's session has been
//// retired, then runs the verifier in a fresh jail
//// (`docs/design-notes/eval-instrument.md` §3).

import client/mcp
import core/json.{type JsonValue}
import eval/wire
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// The task encoding version. Version one is the governed fixture format in
/// `client/evolution/tasks`; this is its successor and carries its version in
/// every file so a reader never has to guess.
pub const version = 2

/// The longest prompt a task may carry, in bytes.
pub const max_prompt_bytes = 8192

/// The most files an inline workspace or an expected-file set may hold.
pub const max_inline_files = 64

/// The most bytes (paths plus contents) any one file set may hold.
pub const max_file_bytes = 262_144

/// The longest verifier wall-clock ceiling a task may request, one hour.
pub const max_timeout_ms = 3_600_000

/// One versioned, content-addressed evaluation task.
pub type Task {
  Task(
    /// SHA-256 hex of the canonical encoding with this field blank. Any
    /// change to any other field is a different task.
    id: String,
    /// A human handle for reports. Informational only: rows are paired by
    /// `id`, never by name.
    name: String,
    /// What the agent is told, at most 8 KiB. For a mined task this is the
    /// commit subject (and body, unless the body names a hidden test).
    prompt: String,
    /// The tree the agent starts from.
    workspace: Workspace,
    /// How the agent's result is graded once the agent is gone.
    verifier: Verifier,
    /// Failure-taxonomy and family tags, used for split quotas and for
    /// per-tag pass rates in reports.
    tags: List(String),
    /// Where the task came from. Hashed into `id`, never trusted.
    provenance: Provenance,
  )
}

/// The starting tree for a trial.
pub type Workspace {
  /// A small fixture carried in the task itself: at most 64 files and
  /// 256 KiB, the bounds `client/evolution/tasks.Fixture` already uses.
  Inline(files: List(#(String, String)))

  /// A tree from a git repository. `tree` is `git rev-parse <commit>^{tree}`,
  /// which is already a content digest of the whole worktree, so the task
  /// needs no second hash of it. `prepare` is the argv run on the host, at a
  /// trusted commit, before the agent starts (for Loom,
  /// `gleam deps download` and a warm build), and its time is the trial's
  /// cold start.
  GitTree(
    repository: String,
    commit: String,
    tree: String,
    prepare: List(List(String)),
  )
}

/// How a finished trial is graded.
pub type Verifier {
  /// Exact expected file contents: the version-one scorer
  /// (`client/evolution/fixture.score`), kept so hand-written fixtures and
  /// the governed task sets they came from stay expressible.
  ExpectedFiles(expected: List(#(String, String)))

  /// A program run in a fresh jail over a copy of the agent's frozen
  /// workspace, after `files` have been written into that copy.
  Program(
    /// Hidden files staged into the copy: for a mined task, the commit's
    /// own test changes.
    files: List(#(String, String)),
    /// The command, run with the copy as its working directory.
    argv: List(String),
    /// Test ids that failed before the fix and passed after it. Every one
    /// must pass for full reward.
    fail_to_pass: List(String),
    /// Test ids that passed both before and after the fix. A regression in
    /// any of them costs reward.
    pass_to_pass: List(String),
    /// Wall-clock ceiling for the verifier run. Exceeding it is a failed
    /// grade, never an exclusion.
    timeout_ms: Int,
    /// How the rewards in `/logs/verifier/reward.json` (Harbor's contract)
    /// reduce to a pass.
    scoring: Scoring,
  )
}

/// The reduction from a verifier's reward map to a pass, after Harbor and
/// nanocodex's two policies.
pub type Scoring {
  /// Every reported reward must equal 1.0.
  AllRewardsOne

  /// Every reported reward must be strictly positive.
  AllRewardsPositive
}

/// Where a task came from: recorded and hashed, never trusted.
pub type Provenance {
  /// Written by a person.
  HandWritten(author: String)

  /// Mined from a fix commit of a repository's own history.
  MinedCommit(fix: String, parent: String, subject: String)

  /// Imported from a Harbor dataset at a pinned revision.
  HarborImport(dataset: String, revision: String, task: String)
}

/// The canonical encoding of a task, the bytes its identity is the digest of.
/// Object keys are sorted by `core/json.canonical`, so two encoders cannot
/// disagree about them, and file sets are objects keyed by path for the same
/// reason. Lists the task orders itself (argv, tags, prepare steps) keep
/// their order because the order is part of their meaning.
///
/// ## Examples
///
/// ```gleam
/// // json.to_string(task.to_json(fixture)) starts with {"id":"…
/// ```
///
pub fn to_json(task: Task) -> JsonValue {
  json.canonical(
    json.Object([
      #("v", json.Int(version)),
      #("id", json.String(task.id)),
      #("name", json.String(task.name)),
      #("prompt", json.String(task.prompt)),
      #("workspace", workspace_json(task.workspace)),
      #("verifier", verifier_json(task.verifier)),
      #("tags", strings_json(task.tags)),
      #("provenance", provenance_json(task.provenance)),
    ]),
  )
}

/// Returns the task with its `id` set to the digest of its own canonical
/// encoding taken with the `id` blank. Minting twice is idempotent, and any
/// edit to any other field followed by a mint yields a different task.
///
/// ## Examples
///
/// ```gleam
/// // task.mint(task.mint(t)) == task.mint(t)
/// ```
///
pub fn mint(task: Task) -> Task {
  Task(..task, id: digest(task))
}

/// Refuses a task whose `id` is not the digest of its content. The message
/// names both digests because the usual cause is a hand edit that forgot to
/// re-mint, and the person needs the new name.
///
/// ## Examples
///
/// ```gleam
/// // task.verify_id(task.mint(t)) == Ok(task.mint(t))
/// ```
///
pub fn verify_id(task: Task) -> Result(Task, String) {
  let actual = digest(task)

  // A mismatch means the task was edited after minting; refusing here is what
  // makes an edit a new task rather than a silent rewrite.
  case actual == task.id {
    True -> Ok(task)
    False ->
      Error(
        "task content changed: id "
        <> task.id
        <> " but the content digests to "
        <> actual,
      )
  }
}

/// Reads a task file, decodes it, checks its digest and checks that the file
/// is named for the id it carries. The name check is what makes a copied or
/// renamed file visible: the same bytes under another name would otherwise
/// be silently filed as a task nobody can find.
///
/// ## Examples
///
/// ```gleam
/// // task.load("tasks/3f9a….json")
/// ```
///
pub fn load(path: String) -> Result(Task, String) {
  use body <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(reason) {
      "cannot read " <> path <> ": " <> simplifile.describe_error(reason)
    }),
  )
  use value <- result.try(
    json.parse(body)
    |> result.map_error(fn(_report) { path <> ": not valid JSON" }),
  )
  use task <- result.try(decode(value))
  use task <- result.try(verify_id(task))

  // The filename must be the task's own digest, so a copied or renamed file
  // cannot be mistaken for a catalogued task.
  case basename(path) == task.id <> ".json" {
    True -> Ok(task)
    False ->
      Error(
        path
        <> ": a task file must be named "
        <> task.id
        <> ".json after its own digest",
      )
  }
}

/// Decodes and bounds-checks a task. Total: any value at all yields `Ok` or
/// an `Error` naming the first problem, never a crash. The `id` is read as
/// written; `verify_id` is the separate question of whether it is honest.
///
/// ## Examples
///
/// ```gleam
/// // task.decode(task.to_json(t)) == Ok(t) for a task with sorted files
/// ```
///
pub fn decode(value: JsonValue) -> Result(Task, String) {
  use fields <- result.try(wire.object(value, task_keys))
  use v <- result.try(wire.int(fields, "v"))
  use Nil <- result.try(check(v == version, "unsupported task version"))
  use id <- result.try(wire.text(fields, "id"))
  use Nil <- result.try(check(id == "" || wire.is_hex(id, 64), "bad task id"))
  use name <- result.try(wire.text(fields, "name"))
  use Nil <- result.try(check(wire.bytes(name) <= 256, "name is too long"))
  use prompt <- result.try(wire.text(fields, "prompt"))
  use Nil <- result.try(check(
    prompt != "" && wire.bytes(prompt) <= max_prompt_bytes,
    "prompt must be 1 byte to 8 KiB",
  ))
  use workspace <- result.try(
    wire.required(fields, "workspace") |> result.try(decode_workspace),
  )
  use verifier <- result.try(
    wire.required(fields, "verifier") |> result.try(decode_verifier),
  )
  use tags <- result.try(wire.strings(fields, "tags"))
  use Nil <- result.try(check(
    list.length(tags) <= 64
      && list.all(tags, fn(tag) { tag != "" && wire.bytes(tag) <= 128 }),
    "tags must be at most 64 nonempty strings of at most 128 bytes",
  ))
  use provenance <- result.try(
    wire.required(fields, "provenance") |> result.try(decode_provenance),
  )

  Ok(Task(id:, name:, prompt:, workspace:, verifier:, tags:, provenance:))
}

// Every key the encoding may carry. A key outside this list is refused.
const task_keys = [
  "v", "id", "name", "prompt", "workspace", "verifier", "tags", "provenance",
]

/// The digest of the canonical encoding with the id blanked.
fn digest(task: Task) -> String {
  Task(..task, id: "")
  |> to_json
  |> json.to_string
  |> mcp.sha256_hex
}

/// The final path segment, which is all the filename check needs.
fn basename(path: String) -> String {
  case list.last(string.split(path, "/")) {
    Ok(last) -> last
    Error(Nil) -> path
  }
}

/// Turns a boolean condition into the `Result` the decoders chain on.
fn check(condition: Bool, message: String) -> Result(Nil, String) {
  case condition {
    True -> Ok(Nil)
    False -> Error(message)
  }
}

fn strings_json(items: List(String)) -> JsonValue {
  json.Array(list.map(items, json.String))
}

fn argv_json(items: List(List(String))) -> JsonValue {
  json.Array(list.map(items, strings_json))
}

fn files_json(files: List(#(String, String))) -> JsonValue {
  json.Object(list.map(files, fn(file) { #(file.0, json.String(file.1)) }))
}

/// Encodes the workspace sum with its `kind` tag.
fn workspace_json(workspace: Workspace) -> JsonValue {
  case workspace {
    Inline(files:) ->
      json.Object([
        #("kind", json.String("inline")),
        #("files", files_json(files)),
      ])
    GitTree(repository:, commit:, tree:, prepare:) ->
      json.Object([
        #("kind", json.String("git_tree")),
        #("repository", json.String(repository)),
        #("commit", json.String(commit)),
        #("tree", json.String(tree)),
        #("prepare", argv_json(prepare)),
      ])
  }
}

/// Encodes the verifier sum with its `kind` tag.
fn verifier_json(verifier: Verifier) -> JsonValue {
  case verifier {
    ExpectedFiles(expected:) ->
      json.Object([
        #("kind", json.String("expected_files")),
        #("expected", files_json(expected)),
      ])
    Program(files:, argv:, fail_to_pass:, pass_to_pass:, timeout_ms:, scoring:) ->
      json.Object([
        #("kind", json.String("program")),
        #("files", files_json(files)),
        #("argv", strings_json(argv)),
        #("fail_to_pass", strings_json(fail_to_pass)),
        #("pass_to_pass", strings_json(pass_to_pass)),
        #("timeout_ms", json.Int(timeout_ms)),
        #("scoring", json.String(scoring_name(scoring))),
      ])
  }
}

fn scoring_name(scoring: Scoring) -> String {
  case scoring {
    AllRewardsOne -> "all_rewards_one"
    AllRewardsPositive -> "all_rewards_positive"
  }
}

/// Encodes the provenance sum with its `kind` tag.
fn provenance_json(provenance: Provenance) -> JsonValue {
  case provenance {
    HandWritten(author:) ->
      json.Object([
        #("kind", json.String("hand_written")),
        #("author", json.String(author)),
      ])
    MinedCommit(fix:, parent:, subject:) ->
      json.Object([
        #("kind", json.String("mined_commit")),
        #("fix", json.String(fix)),
        #("parent", json.String(parent)),
        #("subject", json.String(subject)),
      ])
    HarborImport(dataset:, revision:, task:) ->
      json.Object([
        #("kind", json.String("harbor_import")),
        #("dataset", json.String(dataset)),
        #("revision", json.String(revision)),
        #("task", json.String(task)),
      ])
  }
}

/// Decodes the workspace sum, dispatching on its `kind` tag.
fn decode_workspace(value: JsonValue) -> Result(Workspace, String) {
  use kind <- result.try(kind_of(value))

  // The kind tag selects which fields the workspace must carry; an unknown
  // kind is refused rather than guessed.
  case kind {
    "inline" -> decode_inline(value)
    "git_tree" -> decode_git_tree(value)
    other -> Error("unknown workspace kind \"" <> other <> "\"")
  }
}

/// Decodes an inline workspace, bounded at 64 files and 256 KiB.
fn decode_inline(value: JsonValue) -> Result(Workspace, String) {
  use fields <- result.try(wire.object(value, ["kind", "files"]))
  use files <- result.try(
    wire.required(fields, "files")
    |> result.try(decode_files(_, max_inline_files)),
  )

  Ok(Inline(files:))
}

/// Decodes a git-tree workspace, requiring 40-digit commit and tree digests so a task names exactly one tree.
fn decode_git_tree(value: JsonValue) -> Result(Workspace, String) {
  use fields <- result.try(
    wire.object(value, ["kind", "repository", "commit", "tree", "prepare"]),
  )
  use repository <- result.try(wire.text(fields, "repository"))
  use commit <- result.try(wire.text(fields, "commit"))
  use tree <- result.try(wire.text(fields, "tree"))
  use prepare <- result.try(wire.list_of(
    fields,
    "prepare",
    decode_argv("prepare"),
  ))
  use Nil <- result.try(check(
    repository != "" && wire.bytes(repository) <= 1024,
    "repository must be 1 to 1024 bytes",
  ))
  use Nil <- result.try(check(
    wire.is_hex(commit, 40) && wire.is_hex(tree, 40),
    "commit and tree must be 40-digit lowercase hex",
  ))
  use Nil <- result.try(check(
    list.length(prepare) <= 16,
    "at most 16 prepare steps",
  ))

  Ok(GitTree(repository:, commit:, tree:, prepare:))
}

/// Decodes one argv: a nonempty array of strings without NUL bytes.
fn decode_argv(name: String) -> fn(JsonValue) -> Result(List(String), String) {
  fn(value) {
    // Only an array can be an argv; any other JSON shape is refused with the
    // field named.
    case value {
      json.Array(items:) -> {
        use argv <- result.try(
          list.try_map(items, fn(item) { wire.string_value(item, name) }),
        )
        use Nil <- result.try(check(
          argv != [] && list.length(argv) <= 64,
          name <> " argv must hold 1 to 64 words",
        ))
        check(
          list.all(argv, fn(word) { !string.contains(word, "\u{0}") }),
          name <> " argv words must not contain NUL",
        )
        |> result.replace(argv)
      }
      json.Object(..)
      | json.String(..)
      | json.Int(..)
      | json.Float(..)
      | json.Bool(..)
      | json.Null -> Error(name <> " argv must be an array")
    }
  }
}

/// Decodes the verifier sum, dispatching on its `kind` tag.
fn decode_verifier(value: JsonValue) -> Result(Verifier, String) {
  use kind <- result.try(kind_of(value))

  // The kind tag selects which fields the verifier must carry; an unknown kind
  // is refused rather than guessed.
  case kind {
    "expected_files" -> decode_expected(value)
    "program" -> decode_program(value)
    other -> Error("unknown verifier kind \"" <> other <> "\"")
  }
}

/// Decodes an expected-files verifier; an empty set would pass every agent, so it is refused.
fn decode_expected(value: JsonValue) -> Result(Verifier, String) {
  use fields <- result.try(wire.object(value, ["kind", "expected"]))
  use expected <- result.try(
    wire.required(fields, "expected")
    |> result.try(decode_files(_, max_inline_files)),
  )
  use Nil <- result.try(check(
    expected != [],
    "expected files must not be empty",
  ))

  Ok(ExpectedFiles(expected:))
}

/// Decodes a program verifier with its argv, test lists, bounded timeout and scoring.
fn decode_program(value: JsonValue) -> Result(Verifier, String) {
  use fields <- result.try(
    wire.object(value, [
      "kind", "files", "argv", "fail_to_pass", "pass_to_pass", "timeout_ms",
      "scoring",
    ]),
  )
  use files <- result.try(
    wire.required(fields, "files") |> result.try(decode_files(_, 256)),
  )
  use argv <- result.try(
    wire.required(fields, "argv") |> result.try(decode_argv("verifier")),
  )
  use fail_to_pass <- result.try(wire.strings(fields, "fail_to_pass"))
  use pass_to_pass <- result.try(wire.strings(fields, "pass_to_pass"))
  use timeout_ms <- result.try(wire.int_between(
    fields,
    "timeout_ms",
    1,
    max_timeout_ms,
  ))
  use scoring <- result.try(
    wire.text(fields, "scoring") |> result.try(decode_scoring),
  )
  use Nil <- result.try(check(
    fail_to_pass != [],
    "a program verifier needs at least one fail_to_pass test",
  ))

  Ok(Program(files:, argv:, fail_to_pass:, pass_to_pass:, timeout_ms:, scoring:))
}

/// Parses a scoring policy's wire spelling.
fn decode_scoring(name: String) -> Result(Scoring, String) {
  case name {
    "all_rewards_one" -> Ok(AllRewardsOne)
    "all_rewards_positive" -> Ok(AllRewardsPositive)
    other -> Error("unknown scoring \"" <> other <> "\"")
  }
}

/// Decodes the provenance sum. Provenance is recorded and hashed but never
/// trusted, so the only checks are the shape and a size bound.
fn decode_provenance(value: JsonValue) -> Result(Provenance, String) {
  use kind <- result.try(kind_of(value))

  // The kind tag selects which provenance fields are required; an unknown kind
  // is refused rather than guessed.
  case kind {
    "hand_written" -> {
      use fields <- result.try(wire.object(value, ["kind", "author"]))
      use author <- result.map(wire.text(fields, "author"))
      HandWritten(author:)
    }
    "mined_commit" -> {
      use fields <- result.try(
        wire.object(value, ["kind", "fix", "parent", "subject"]),
      )
      use fix <- result.try(wire.text(fields, "fix"))
      use parent <- result.try(wire.text(fields, "parent"))
      use subject <- result.map(wire.text(fields, "subject"))
      MinedCommit(fix:, parent:, subject:)
    }
    "harbor_import" -> {
      use fields <- result.try(
        wire.object(value, ["kind", "dataset", "revision", "task"]),
      )
      use dataset <- result.try(wire.text(fields, "dataset"))
      use revision <- result.try(wire.text(fields, "revision"))
      use task <- result.map(wire.text(fields, "task"))
      HarborImport(dataset:, revision:, task:)
    }
    other -> Error("unknown provenance kind \"" <> other <> "\"")
  }
}

/// Reads the `kind` tag of a tagged object without validating the rest.
fn kind_of(value: JsonValue) -> Result(String, String) {
  case value {
    json.Object(fields:) -> wire.text(fields, "kind")
    json.Array(..)
    | json.String(..)
    | json.Int(..)
    | json.Float(..)
    | json.Bool(..)
    | json.Null -> Error("expected an object")
  }
}

/// Decodes an object of path to contents. Paths must stay inside the
/// workspace, the set must fit `max_files` and `max_file_bytes` in total,
/// and the result is sorted by path so decoding does not depend on the order
/// a person typed the files in.
fn decode_files(
  value: JsonValue,
  max_files: Int,
) -> Result(List(#(String, String)), String) {
  // A file set is an object keyed by path; any other shape is refused.
  use fields <- result.try(case value {
    json.Object(fields:) -> Ok(fields)
    json.Array(..)
    | json.String(..)
    | json.Int(..)
    | json.Float(..)
    | json.Bool(..)
    | json.Null -> Error("a file set must be an object of path to contents")
  })

  use files <- result.try(
    list.try_map(fields, fn(field) {
      use contents <- result.try(wire.string_value(field.1, field.0))
      use Nil <- result.try(check(
        safe_path(field.0),
        "unsafe path \"" <> field.0 <> "\"",
      ))
      Ok(#(field.0, contents))
    }),
  )
  let total =
    list.fold(files, 0, fn(sum, file) {
      sum + wire.bytes(file.0) + wire.bytes(file.1)
    })
  use Nil <- result.try(check(
    list.length(files) <= max_files,
    "a file set may hold at most " <> int.to_string(max_files) <> " files",
  ))
  use Nil <- result.try(check(
    list.length(list.unique(list.map(files, fn(file) { file.0 })))
      == list.length(files),
    "repeated path in a file set",
  ))
  use Nil <- result.try(check(
    total <= max_file_bytes,
    "a file set may hold at most 256 KiB",
  ))

  Ok(list.sort(files, fn(left, right) { string.compare(left.0, right.0) }))
}

/// A path the instrument will write under a workspace root: relative, free
/// of `.` and `..` pieces, of NUL and of backslashes, and clear of the
/// directories (`.git`, `.loom`) that carry harness state. This mirrors
/// `client/evolution/tasks`, so a v1 fixture's paths remain admissible.
fn safe_path(path: String) -> Bool {
  path != ""
  && wire.bytes(path) <= 256
  && !string.starts_with(path, "/")
  && !string.contains(path, "\\")
  && !string.contains(path, "\u{0}")
  && list.all(string.split(path, "/"), fn(piece) {
    piece != ""
    && piece != "."
    && piece != ".."
    && piece != ".git"
    && piece != ".loom"
  })
}
