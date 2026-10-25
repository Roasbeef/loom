//// Mutation testing of a mined task's verifier: three jailed verifier runs
//// that decide whether the task can tell a fix from its absence.
////
//// A task is a claim — "these tests fail before the fix and pass after it" —
//// made by the miner on a worktree it controlled. Before the task may
//// measure an agent, the claim is re-made the way the runner will make it:
//// from a `git archive` of the parent (no history), prepared on the host as
//// a trial is, and graded by `eval/verify` in the same jail an agent's work
//// is graded in. Three trees are graded.
////
//// - **gold**: the parent with the commit's source patch applied. It must
////   score 1, or the verifier cannot recognise the reference solution.
//// - **null**: the parent untouched. It must score 0, or the verifier
////   passes a tree in which nothing was done.
//// - **sabotaged**: gold with the first changed code line of the source
////   patch reverted. It should score 0, and when it does not the verifier
////   is weak at that line — but some fixes are one line and some reverts
////   do not change behaviour, so this is a census, never a gate.
////
//// Only gold = 1 and null = 0 admit a task. The verdict and the three
//// grades are written to `prove.jsonl` by `eval/prove_cli`, one line per
//// task, so a task set's admission is a file a reader can check.
////
//// The source patch is recovered from the repository rather than carried in
//// the task, because the task must never carry the fix: `git diff <parent>
//// <fix>` less the test directories, the per-package guidance files and
//// `docs/`, which is `eval/git.split_patch`'s own partition.
////
//// Purity: this module runs host git, copies trees and asks `eval/verify`
//// for jailed grades, so it is an effect module. `verdict`, `package_of`
//// and `to_json` are pure and carry the decisions a test can state.

import client/evolution/rollout.{type Grade}
import client/internal/ffi_os
import client/secrets.{type Runner}
import core/json.{type JsonValue}
import eval/git
import eval/mine.{type Sabotage, Caught, NotApplicable, Survived}
import eval/repos.{type Repos}
import eval/task.{
  type Task, ExpectedFiles, GitTree, HandWritten, HarborImport, Inline,
  MinedCommit, Program,
}
import eval/verify.{type Jail}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile

/// How long one host step (archive, prepare, patch) may take. A cold
/// `gleam deps download` on a slow link is the long pole.
pub const host_step_ms = 600_000

/// Whether a task may measure anything.
pub type Verdict {
  /// Gold scored 1 and null scored 0: the verifier recognises the fix and
  /// refuses its absence.
  Admitted

  /// One of the two gates failed; the reason names which and what it scored.
  Refused(reason: String)
}

/// What proving one task found.
pub type Proof {
  Proof(
    /// The task's content address.
    task_id: String,
    /// The task's human handle.
    name: String,
    /// The grade of the parent with the fix applied.
    gold: Grade,
    /// The grade of the parent untouched.
    null: Grade,
    /// The census: whether the tests noticed one reverted line of the fix.
    sabotage: Sabotage,
    /// The sabotaged tree's grade, when a line could be reverted.
    sabotaged: Option(Grade),
    /// The admission decision.
    verdict: Verdict,
    /// Host time spent materialising and preparing the parent, in
    /// milliseconds: the cold start a trial of this task pays.
    prepare_ms: Int,
    /// The enforcement demand the jail ran under: `platform`, `full` or
    /// `best-effort`.
    demand: String,
    /// The kernel's enforcement report for the jail's probe, so a line
    /// says how the three runs were jailed and which layer, if any, was
    /// skipped.
    enforcement: List(String),
  )
}

/// Proves one mined task. `known` maps the task's repository name to the
/// clone whose history holds the fix, and the clone must confirm the task's
/// tree before anything is extracted; `root` is a directory under the jail's root (never `/tmp`) where
/// the parent tree, its patched copies and the verifier runs are laid out
/// under `<root>/<first twelve of the task id>/`; `runner` runs host
/// commands, `secrets.host_runner()` in production.
///
/// `Error` is a step that could not run — a provenance that is not a mined
/// commit, a parent the repository does not have, a patch that does not
/// apply, a jail that refused — never a grade: a failing grade is a
/// `Refused` verdict inside `Ok`.
///
/// ## Examples
///
/// ```gleam
/// // prove.prove(task, repos, home <> "/evalwt/prove/work", jail, secrets.host_runner())
/// // -> Ok(prove.Proof(verdict: prove.Admitted, ..))
/// ```
///
pub fn prove(
  task: Task,
  known: Repos,
  root: String,
  jail: Jail,
  runner: Runner,
) -> Result(Proof, String) {
  use #(fix, parent) <- result.try(mined_commit(task))
  use #(name, commit, tree_id) <- result.try(git_tree(task))
  use Nil <- result.try(same_parent(parent, commit))
  use argv <- result.try(program_argv(task))
  let dir = root <> "/" <> string.slice(task.id, 0, 12)
  use Nil <- result.try(fresh(dir))
  let tree = dir <> "/tree"
  let started = now_ms()
  use repo <- result.try(repos.resolve(known, runner, name, commit, tree_id))
  use Nil <- result.try(materialise(runner, repo, commit, tree))
  use Nil <- result.try(prepare(runner, task, tree, argv))
  let prepare_ms = now_ms() - started

  // The parent is `commit`; the fix is diffed against it from the
  // repository, never read from the task.
  use patch <- result.try(source_patch(runner, repo, parent, fix))
  let patch_file = dir <> "/src.patch"
  use Nil <- result.try(write(patch_file, patch))
  let gold = dir <> "/gold"
  use Nil <- result.try(copy(runner, tree, gold))
  use Nil <- result.try(apply_patch(runner, gold, patch_file))

  stages(task, jail, runner, dir, tree, gold, patch, prepare_ms)
}

/// The three grades and the verdict, once the trees stand.
fn stages(
  task: Task,
  jail: Jail,
  runner: Runner,
  dir: String,
  tree: String,
  gold: String,
  patch: String,
  prepare_ms: Int,
) -> Result(Proof, String) {
  use null_grade <- result.try(
    verify.grade(task, tree, dir <> "/null-run", jail, Some(tree))
    |> result.map_error(fn(reason) { "null: " <> reason }),
  )
  use gold_grade <- result.try(
    verify.grade(task, gold, dir <> "/gold-run", jail, Some(tree))
    |> result.map_error(fn(reason) { "gold: " <> reason }),
  )
  use #(sabotage, sabotaged) <- result.try(sabotage(
    task,
    jail,
    runner,
    dir,
    tree,
    gold,
    patch,
  ))

  Ok(Proof(
    task_id: task.id,
    name: task.name,
    gold: gold_grade,
    null: null_grade,
    sabotage:,
    sabotaged:,
    verdict: verdict(gold_grade, null_grade),
    prepare_ms:,
    demand: verify.demand_text(jail),
    enforcement: verify.enforcement(jail),
  ))
}

/// The admission rule: gold must score exactly 1 with every recorded
/// fail-to-pass and pass-to-pass id passing, and null must score 0 with
/// some fail-to-pass id not passing. The test-id conditions are what make
/// an admitted task known to exercise the ids it recorded rather than an
/// exit status. Every fault is checked and named, so a task failing several
/// ways is reported once with the whole picture.
///
/// ## Examples
///
/// ```gleam
/// // prove.verdict(one, zero) == prove.Admitted
/// // prove.verdict(zero, zero) == prove.Refused("gold reward scored 0.0, wanted 1.0; …")
/// ```
///
pub fn verdict(gold: Grade, null: Grade) -> Verdict {
  let faults =
    list.flatten([
      wanted("gold", "reward", gold.reward, 1.0),
      wanted("gold", "f2p", score(gold, "f2p"), 1.0),
      wanted("gold", "p2p", score(gold, "p2p"), 1.0),
      wanted("null", "reward", null.reward, 0.0),
      case score(null, "f2p") <. 1.0 {
        True -> []
        False -> ["null f2p scored 1.0, wanted below 1.0"]
      },
    ])

  // No fault admits; any fault refuses with all of them named.
  case faults {
    [] -> Admitted
    _some -> Refused(reason: string.join(faults, "; "))
  }
}

/// One fault line when a grade's number is not the wanted one.
fn wanted(
  stage: String,
  what: String,
  actual: Float,
  expected: Float,
) -> List(String) {
  case actual == expected {
    True -> []
    False -> [
      stage
      <> " "
      <> what
      <> " scored "
      <> float.to_string(actual)
      <> ", wanted "
      <> float.to_string(expected),
    ]
  }
}

/// A named score of a grade; a grade that lacks it scored nothing, which is
/// 0.0 for the purpose of the rule.
fn score(grade: Grade, name: String) -> Float {
  list.key_find(grade.scores, name) |> result.unwrap(0.0)
}

/// The census run. The first changed code line of the source patch is
/// reverted in a copy of gold and the copy is graded; a grade below 1 means
/// the tests noticed. A patch with no code line to revert, or a revert that
/// does not apply to the patched file, is not a measurement.
fn sabotage(
  task: Task,
  jail: Jail,
  runner: Runner,
  dir: String,
  tree: String,
  gold: String,
  patch: String,
) -> Result(#(Sabotage, Option(Grade)), String) {
  // A patch with no code line to revert is not a measurement.
  case git.first_revert(patch) {
    Error(Nil) -> Ok(#(NotApplicable, None))

    Ok(revert) -> {
      let sabotaged = dir <> "/sabotaged"
      use Nil <- result.try(copy(runner, gold, sabotaged))
      let file = sabotaged <> "/" <> revert.path
      let edited = {
        use content <- result.try(
          simplifile.read(file) |> result.replace_error(Nil),
        )
        use text <- result.try(git.apply_edit(content, revert.edit))

        simplifile.write(file, text) |> result.replace_error(Nil)
      }

      // A revert the file refuses is the miner's editing, not the tests.
      case edited {
        Error(Nil) -> Ok(#(NotApplicable, None))
        Ok(Nil) -> {
          use grade <- result.try(
            verify.grade(
              task,
              sabotaged,
              dir <> "/sabotaged-run",
              jail,
              Some(tree),
            )
            |> result.map_error(fn(reason) { "sabotaged: " <> reason }),
          )

          Ok(#(caught(grade), Some(grade)))
        }
      }
    }
  }
}

/// Whether a sabotaged tree's grade says the tests noticed the damage.
fn caught(grade: Grade) -> Sabotage {
  case grade.reward <. 1.0 {
    True -> Caught
    False -> Survived
  }
}

// --- what the task must be ------------------------------------------------

/// The fix and parent of a mined task; any other provenance is refused,
/// because only a mined task has a reference patch to prove against.
fn mined_commit(task: Task) -> Result(#(String, String), String) {
  case task.provenance {
    MinedCommit(fix:, parent:, subject: _) -> Ok(#(fix, parent))
    HandWritten(author: _) -> Error("a hand-written task has no fix to prove")
    HarborImport(dataset: _, revision: _, task: _) ->
      Error("a Harbor import has no fix to prove")
  }
}

/// Refuses a task whose archived commit is not the fix's parent: the tree
/// would come from one commit and the patch from another.
fn same_parent(parent: String, commit: String) -> Result(Nil, String) {
  case parent == commit {
    True -> Ok(Nil)
    False ->
      Error(
        "the workspace commit "
        <> commit
        <> " is not the fix's parent "
        <> parent,
      )
  }
}

/// The repository name, commit and tree id of a git-tree workspace.
fn git_tree(task: Task) -> Result(#(String, String, String), String) {
  case task.workspace {
    GitTree(repository:, commit:, tree:, prepare: _) ->
      Ok(#(repository, commit, tree))
    Inline(files: _) -> Error("an inline workspace has no parent to archive")
  }
}

/// The verifier argv of a program task; an expected-files task is graded
/// without a jail and proves nothing about a verifier.
fn program_argv(task: Task) -> Result(List(String), String) {
  case task.verifier {
    Program(argv:, ..) -> Ok(argv)
    ExpectedFiles(expected: _) ->
      Error("an expected-files verifier is not a program to prove")
  }
}

// --- the host steps -------------------------------------------------------

/// Extracts the parent commit as plain files (the clone has already confirmed
/// the tree id the task recorded) and checks that no `.git` came along: an archive carries none,
/// and a tree that had one would show the agent the fix.
fn materialise(
  runner: Runner,
  repo: String,
  commit: String,
  tree: String,
) -> Result(Nil, String) {
  use Nil <- result.try(directory(tree))
  use capture <- result.try(runner(
    [
      "bash",
      "-o",
      "pipefail",
      "-c",
      "git -C "
        <> git.shell_quote(repo)
        <> " archive "
        <> git.shell_quote(commit)
        <> " | tar -x -C "
        <> git.shell_quote(tree),
    ],
    host_step_ms,
  ))
  use Nil <- result.try(exited_zero("archive", capture))

  // An archive carries no history; one that did would show the fix.
  case simplifile.is_directory(tree <> "/.git") {
    Ok(True) -> Error("the archive carried a .git directory")
    Ok(False) | Error(_) -> Ok(Nil)
  }
}

/// Runs the task's `prepare` argvs on the host, each in the directory
/// `prepare_directory` chooses, then warms the build there, so the jailed
/// verifier finds its packages downloaded and its build warm — the cold
/// start a trial pays before the agent starts.
fn prepare(
  runner: Runner,
  task: Task,
  tree: String,
  argv: List(String),
) -> Result(Nil, String) {
  // Only a git tree carries warm-up steps; an inline tree has none.
  let steps = case task.workspace {
    GitTree(prepare:, ..) -> prepare
    Inline(files: _) -> []
  }

  let cwd = prepare_directory(tree, task, argv)
  use Nil <- result.try(
    list.try_each(steps, fn(step) {
      use capture <- result.try(git.run_in(runner, cwd, step, host_step_ms))

      exited_zero("prepare `" <> string.join(step, " ") <> "`", capture)
    }),
  )

  // The warm build the design names beside the download: the task's wall
  // was measured on a worktree whose build was warm, and three cold compiles
  // in the jail would spend it on the compiler rather than the tests.
  use capture <- result.try(git.run_in(
    runner,
    cwd,
    ["gleam", "build"],
    host_step_ms,
  ))

  exited_zero("warm build", capture)
}

/// Where a `prepare` step runs: the tree itself when it is a Gleam project,
/// else the package the verifier names, when the tree has it.
///
/// The second rung exists because a mined Loom task records `gleam deps
/// download` against a tree whose root has no `gleam.toml`: the packages
/// live under `packages/`, and the verifier's `scripts/test.sh <pkg>` says
/// which one. Running the step at the root would fail every mined task for
/// a reason that has nothing to do with the fix.
///
/// ## Examples
///
/// ```gleam
/// // prove.prepare_directory("/work/tree", task, argv) == "/work/tree/packages/machine"
/// ```
///
pub fn prepare_directory(
  tree: String,
  task: Task,
  argv: List(String),
) -> String {
  let at_root = simplifile.is_file(tree <> "/gleam.toml") == Ok(True)
  let in_package =
    package_for(task, argv)
    |> result.map(fn(package) { tree <> "/packages/" <> package })
    |> result.try(fn(dir) {
      case simplifile.is_directory(dir) {
        Ok(True) -> Ok(dir)
        Ok(False) | Error(_) -> Error(Nil)
      }
    })

  // The root wins when it is a project; else the named package; else the
  // root, and the step says why it failed.
  case at_root, in_package {
    True, _ -> tree
    False, Ok(dir) -> dir
    False, Error(Nil) -> tree
  }
}

/// The package a task's verifier works in: the task's `pkg:<name>` tag when
/// it carries one (the miner always writes it), else the package its argv
/// names. `Error(Nil)` when neither says.
///
/// ## Examples
///
/// ```gleam
/// // prove.package_for(task, argv) == Ok("provider")
/// ```
///
pub fn package_for(task: Task, argv: List(String)) -> Result(String, Nil) {
  task.tags
  |> list.find_map(fn(tag) {
    case tag {
      "pkg:" <> package if package != "" -> Ok(package)
      _other -> Error(Nil)
    }
  })
  |> result.lazy_or(fn() { package_of(argv) })
}

/// The package a `scripts/test.sh` verifier names, in the plain form or
/// inside the `bash -c` chain the miner writes for several test modules:
/// the token after any `scripts/test.sh`. `Error(Nil)` for any other
/// command.
///
/// ## Examples
///
/// ```gleam
/// assert prove.package_of(["bash", "scripts/test.sh", "machine", "--match", "m:"])
///   == Ok("machine")
/// assert prove.package_of(["bash", "-c", "'bash' 'scripts/test.sh' 'lint' '--match' 'a:' || status=1"])
///   == Ok("lint")
/// assert prove.package_of(["make", "check"]) == Error(Nil)
/// ```
///
pub fn package_of(argv: List(String)) -> Result(String, Nil) {
  argv
  |> list.flat_map(string.split(_, " "))
  |> list.map(string.replace(_, "'", ""))
  |> list.map(string.replace(_, "\"", ""))
  |> after_runner
}

/// The token after the first `scripts/test.sh`, which is the package.
fn after_runner(tokens: List(String)) -> Result(String, Nil) {
  case tokens {
    [] | [_] -> Error(Nil)
    ["scripts/test.sh", package, ..] if package != "" -> Ok(package)
    [_, ..rest] -> after_runner(rest)
  }
}

/// The fix's source patch: the diff from parent to fix less the test
/// directories, the guidance files and `docs/`, which is the partition the
/// miner used to decide what the agent is asked to write.
fn source_patch(
  runner: Runner,
  repo: String,
  parent: String,
  fix: String,
) -> Result(String, String) {
  use diff <- result.try(git.ask(
    runner,
    repo,
    [
      "diff", parent, fix, "--", ".", ":!packages/*/test/*", ":!*CLAUDE.md",
      ":!*AGENTS.md", ":!docs/*",
    ],
    host_step_ms,
  ))

  // An empty diff is a test-only commit, which has no fix to prove.
  case string.trim(diff) {
    "" -> Error("the fix changes no source files")
    _some -> Ok(diff)
  }
}

/// Applies a patch file to a plain tree. `git apply` needs no repository:
/// outside one it edits the working directory it is given.
fn apply_patch(
  runner: Runner,
  dir: String,
  patch_file: String,
) -> Result(Nil, String) {
  use capture <- result.try(git.run_in(
    runner,
    dir,
    ["git", "apply", "--whitespace=nowarn", patch_file],
    host_step_ms,
  ))

  exited_zero("apply", capture)
}

/// Copies a tree with its modes and times, as the verifier copies the
/// workspace: a build directory whose timestamps moved would be rebuilt.
fn copy(runner: Runner, from: String, to: String) -> Result(Nil, String) {
  use capture <- result.try(runner(["cp", "-a", from, to], host_step_ms))

  exited_zero("copy", capture)
}

/// A capture as a step result: zero is done, anything else names the step
/// and carries its output.
fn exited_zero(step: String, capture: secrets.Capture) -> Result(Nil, String) {
  case capture.status {
    0 -> Ok(Nil)
    status ->
      Error(
        step
        <> " exited "
        <> int.to_string(status)
        <> ": "
        <> string.trim(capture.output),
      )
  }
}

/// Removes whatever a previous attempt left under `dir` and creates it
/// again, so a proof never grades a stale tree.
fn fresh(dir: String) -> Result(Nil, String) {
  let _absent = simplifile.delete(dir)

  directory(dir)
}

/// Creates a directory and its parents, naming it in the error.
fn directory(path: String) -> Result(Nil, String) {
  simplifile.create_directory_all(path)
  |> result.map_error(fn(e) { path <> ": " <> simplifile.describe_error(e) })
}

/// Writes a file, naming it in the error.
fn write(path: String, content: String) -> Result(Nil, String) {
  simplifile.write(path, content)
  |> result.map_error(fn(e) { path <> ": " <> simplifile.describe_error(e) })
}

/// Wall-clock milliseconds, for the prepare timing.
fn now_ms() -> Int {
  ffi_os.system_time_ms()
}

// --- the record -------------------------------------------------------------

/// One proof as a JSON object, the line `prove.jsonl` carries.
///
/// ## Examples
///
/// ```gleam
/// // json.to_string(prove.to_json(proof)) starts with {"gold":
/// ```
///
pub fn to_json(proof: Proof) -> JsonValue {
  json.canonical(
    json.Object([
      #("v", json.Int(1)),
      #("task_id", json.String(proof.task_id)),
      #("name", json.String(proof.name)),
      #("verdict", json.String(verdict_text(proof.verdict))),
      #("gold", grade_json(proof.gold)),
      #("null", grade_json(proof.null)),
      #("sabotage", json.String(mine.sabotage_tag(proof.sabotage))),
      #("sabotaged", case proof.sabotaged {
        None -> json.Null
        Some(grade) -> grade_json(grade)
      }),
      #("prepare_ms", json.Int(proof.prepare_ms)),
      #("demand", json.String(proof.demand)),
      #("enforcement", json.Array(list.map(proof.enforcement, json.String))),
    ]),
  )
}

/// A verdict as one word, or the word and the reason.
///
/// ## Examples
///
/// ```gleam
/// assert prove.verdict_text(prove.Admitted) == "admitted"
/// ```
///
pub fn verdict_text(verdict: Verdict) -> String {
  case verdict {
    Admitted -> "admitted"
    Refused(reason:) -> "refused: " <> reason
  }
}

/// A grade's reward, named scores and the verifier's exit as JSON. The
/// side information is left out of the line: it is in the run's own
/// artifacts, and a census line should stay one screen wide.
fn grade_json(grade: Grade) -> JsonValue {
  json.Object([
    #("reward", json.Float(grade.reward)),
    #(
      "scores",
      json.Object(
        list.map(grade.scores, fn(score) { #(score.0, json.Float(score.1)) }),
      ),
    ),
    #("verifier", case grade.verifier {
      rollout.ExpectedFiles -> json.String("expected-files")
      rollout.ProgramRun(argv: _, exit_status:, wall_ms:) ->
        json.Object([
          #("exit_status", json.Int(exit_status)),
          #("wall_ms", json.Int(wall_ms)),
        ])
    }),
  ])
}
