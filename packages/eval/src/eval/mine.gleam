//// The miner: turns a fix commit from Loom's own history into a regression
//// task whose grader is the commit's own tests.
////
//// A fix commit is a free experiment. Its parent is a tree with a bug, its
//// test changes are a hidden verifier that fails on that tree, and its
//// source changes are the answer key. The miner reproduces the experiment
//// rather than trusting it: it checks out the parent, applies only the test
//// changes and runs the touched test modules, applies the fix and runs them
//// again. A test that failed first and passed second is the fail-to-pass
//// set; a test that passed both times is the pass-to-pass set. Both are
//// scoped to the touched modules, never the package, so a verifier costs
//// seconds.
////
//// Work moves through four stages, and a commit leaves at the first stage
//// that cannot hold it, with a reason that goes into the census.
////
//// 1. Cheap refusals from the repository alone: the parent has no test
////    runner (the runner script postdates much of the history), or the diff
////    cannot be divided into tests and fix.
//// 2. The before run. If the module does not compile or runs no tests, the
////    commit is a feature that added the API its test calls.
//// 3. The after run. Any failure after the fix means the commit does not
////    pass its own test; zero fail-to-pass tests means the new tests never
////    failed, so the commit is a feature or the test is vacuous.
//// 4. The sabotage census: the first changed code line of the fix (not blank, not a comment, not an
////    import) is
////    reverted and the verifier run once more. Whether the fail-to-pass set
////    still passes is recorded as a tag. It measures how sharply the tests
////    pin the fix and never decides admission, because some fixes are one
////    line.
////
//// Everything a decision needs is a pure function over two parsed reports,
//// so the judgements are tested without a repository. The runs themselves
//// go through an injected `Runner`; the miner's worktrees live under the
//// work directory, never under `/tmp` (the code-mode jail replaces `/tmp`),
//// and are removed on every path out.

import client/secrets.{type Runner}
import core/json
import eval/eunit_ids.{type TestReport}
import eval/git.{type Candidate, type PatchSplit}
import eval/task.{type Task, GitTree, MinedCommit, Program}
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import simplifile
import weft/poll

/// Where and how the miner runs.
pub type Config {
  Config(
    /// The logical name the mined tasks record as their repository.
    name: String,
    /// The clone whose history is mined: an operator path, never recorded.
    repo: String,
    /// The directory that holds worktrees and patch files. It must not be
    /// under `/tmp`.
    work: String,
    /// How a program is run; `secrets.host_runner()` in production.
    runner: Runner,
    /// The ceiling for one verifier run, in milliseconds.
    run_timeout_ms: Int,
  )
}

/// What became of one candidate.
pub type Mined {
  Mined(
    /// The candidate commit.
    candidate: Candidate,
    /// Admitted with its task, or culled with the reason.
    result: Result(Task, String),
    /// Wall time of the run with only the tests applied, or 0 if it never
    /// ran.
    before_ms: Int,
    /// Wall time of the run with the fix applied, or 0 if it never ran.
    after_ms: Int,
  )
}

/// The two sets a mined task is graded on.
pub type Judgement {
  /// The commit reproduces: these tests flip, these hold.
  Judged(fail_to_pass: List(String), pass_to_pass: List(String))

  /// The commit does not reproduce, for this reason.
  Rejected(reason: String)
}

/// What the prompt carries of the commit message.
pub type PromptKind {
  /// The subject and the body.
  FullMessage

  /// The subject alone, because the body would name a hidden test or does
  /// not fit.
  SubjectOnly
}

/// What reverting the fix's first changed line did to the fail-to-pass set.
pub type Sabotage {
  /// Some fail-to-pass test failed: the tests notice a damaged fix.
  Caught

  /// Every fail-to-pass test still passed: the tests do not pin that line.
  Survived

  /// There was no changed code line to revert, or it would not apply.
  NotApplicable
}

/// The `[tag]` text of a sabotage result.
///
/// ## Examples
///
/// ```gleam
/// assert mine.sabotage_tag(mine.Caught) == "sabotage:caught"
/// ```
///
pub fn sabotage_tag(sabotage: Sabotage) -> String {
  case sabotage {
    Caught -> "sabotage:caught"
    Survived -> "sabotage:survived"
    NotApplicable -> "sabotage:not_applicable"
  }
}

/// Decides whether a before report and an after report make a regression
/// test. Total over any pair of reports.
///
/// ## Examples
///
/// ```gleam
/// // mine.judge(before_with_one_failure, after_all_passing)
/// // == mine.Judged(["m.t_test"], ["m.u_test"])
/// ```
///
pub fn judge(before: TestReport, after: TestReport) -> Judgement {
  let passed_after = eunit_ids.ids(after, eunit_ids.Passed)
  let failed_before = eunit_ids.ids(before, eunit_ids.Failed)

  // An empty report on either side means that run never got as far as running tests, which no judgement can be drawn from.
  case before.results, after.results {
    [], _ -> Rejected("before run reported no tests (did not compile)")
    _, [] -> Rejected("after run reported no tests")
    _, _ ->
      case eunit_ids.ids(after, eunit_ids.Failed) {
        [_, ..] -> Rejected("fix does not pass its own test")
        [] -> {
          let fail_to_pass =
            failed_before
            |> list.filter(list.contains(passed_after, _))
            |> list.unique
          let pass_to_pass =
            eunit_ids.ids(before, eunit_ids.Passed)
            |> list.filter(list.contains(passed_after, _))
            |> list.unique

          // No test flipped from failing to passing means the new tests never failed on the parent: a feature or a vacuous test.
          case fail_to_pass {
            [] -> Rejected("no fail-to-pass test: feature, not fix")
            _ -> Judged(fail_to_pass:, pass_to_pass:)
          }
        }
      }
  }
}

/// Builds the prompt from the commit message. The body is dropped, leaving
/// the subject, when it names any fail-to-pass function or any touched test
/// file, because the message of a fix often explains the test that was added
/// and the agent must not be told what is hidden. It is dropped too when the
/// whole message would not fit the task's prompt limit.
///
/// ## Examples
///
/// ```gleam
/// assert mine.prompt("fix: x", "see a_test", ["m.a_test"], ["packages/m/test/m_test.gleam"])
///   == #("fix: x", mine.SubjectOnly)
/// ```
///
pub fn prompt(
  subject: String,
  body: String,
  fail_to_pass: List(String),
  test_files: List(String),
) -> #(String, PromptKind) {
  let function_names =
    list.map(fail_to_pass, fn(id) {
      case string.split_once(id, ".") {
        Ok(#(_module, name)) -> name
        Error(Nil) -> id
      }
    })
  let file_names =
    list.map(test_files, fn(path) {
      let base = list.last(string.split(path, "/")) |> result.unwrap(path)
      string.replace(base, ".gleam", "")
    })
  let names = list.append(function_names, file_names)
  let full = subject <> "\n\n" <> body
  let leaks =
    list.any(names, fn(name) { name != "" && string.contains(body, name) })

  // A body that is empty, names a hidden test, or does not fit is not shown; the subject stands alone.
  case body == "" || leaks || string.byte_size(full) > task.max_prompt_bytes {
    True -> #(subject, SubjectOnly)
    False -> #(full, FullMessage)
  }
}

/// The command a verifier runs for a set of touched test modules. One module
/// is one `scripts/test.sh` call; several are chained so that every module
/// runs even when an earlier one fails, and the exit status is nonzero if
/// any did. The match ends in a colon so `lint_test` does not also select
/// `other_lint_test`.
///
/// ## Examples
///
/// ```gleam
/// assert mine.verifier_argv("lint", ["lint_test"])
///   == ["bash", "scripts/test.sh", "lint", "--match", "lint_test:"]
/// ```
///
pub fn verifier_argv(package: String, modules: List(String)) -> List(String) {
  // One module is one call; several chain so a failure in an early module cannot hide a later one.
  case modules {
    [only] -> ["bash", "scripts/test.sh", package, "--match", only <> ":"]
    _ -> {
      let calls =
        list.map(modules, fn(module) {
          git.quoted([
            "bash",
            "scripts/test.sh",
            package,
            "--match",
            module <> ":",
          ])
          <> " || status=1"
        })

      [
        "bash",
        "-c",
        "status=0; " <> string.join(calls, "; ") <> "; exit $status",
      ]
    }
  }
}

/// The verifier ceiling for a measured pair of runs: four times the slower
/// one, never under a minute, never over the task format's limit.
///
/// ## Examples
///
/// ```gleam
/// assert mine.timeout_for(1000, 2000) == 60_000
/// ```
///
pub fn timeout_for(before_ms: Int, after_ms: Int) -> Int {
  int.min(
    int.max(60_000, 4 * int.max(before_ms, after_ms)),
    task.max_timeout_ms,
  )
}

/// Lists the commits worth trying, newest first, optionally narrowed to some
/// packages.
///
/// ## Examples
///
/// ```gleam
/// // mine.candidates(config, "HEAD", ["machine"])
/// ```
///
pub fn candidates(
  config: Config,
  rev: String,
  packages: List(String),
) -> Result(List(Candidate), String) {
  use log <- result.map(git.ask(
    config.runner,
    config.repo,
    git.candidate_log_args(rev),
    600_000,
  ))

  git.parse_candidates(log, packages)
}

/// Mines one candidate. Never raises: every way a commit can fail to be a
/// task becomes the `Error` reason of the result.
///
/// ## Examples
///
/// ```gleam
/// // mine.mine(config, candidate).result
/// ```
///
pub fn mine(config: Config, candidate: Candidate) -> Mined {
  let #(outcome, timing) = attempt(config, candidate, Timing(0, 0))

  Mined(
    candidate:,
    result: outcome,
    before_ms: timing.before,
    after_ms: timing.after,
  )
}

/// Wall times accumulated while a candidate is worked on, so a cull after
/// the before run still reports how long that run took.
type Timing {
  Timing(before: Int, after: Int)
}

/// Runs one candidate through its stages and answers the task or the reason it
/// was culled, with the wall times spent so far. The worktree is removed on
/// every path, including a failed `worktree add`, because a leaked one would
/// keep a copy of the fix on disk.
fn attempt(
  config: Config,
  candidate: Candidate,
  timing: Timing,
) -> #(Result(Task, String), Timing) {
  // Anything the repository alone can refuse is refused before a worktree is made.
  case prepare(config, candidate) {
    Error(reason) -> #(Error(reason), timing)
    Ok(prepared) -> {
      let path = config.work <> "/wt/" <> short(candidate.commit)
      let _ =
        git.ask(
          config.runner,
          config.repo,
          git.worktree_remove_args(path),
          120_000,
        )
      let outcome = in_worktree(config, candidate, prepared, path, timing)
      let _ =
        git.ask(
          config.runner,
          config.repo,
          git.worktree_remove_args(path),
          120_000,
        )

      outcome
    }
  }
}

/// What the repository alone says about a candidate, before any worktree.
type Prepared {
  Prepared(
    parent: String,
    tree: String,
    runner_files: List(#(String, String)),
    split: PatchSplit,
    body: String,
  )
}

/// Everything the repository alone can say about a candidate: its parent, tree,
/// message and the divided diff. A refusal here costs no build.
fn prepare(config: Config, candidate: Candidate) -> Result(Prepared, String) {
  let runner = config.runner
  let repo = config.repo
  let ask = fn(args) { git.ask(runner, repo, args, 120_000) }
  use parent <- result.try(ask(git.parent_args(candidate.commit)))
  let parent = string.trim(parent)

  use runner_files <- result.try(runner_files(config))
  use tree <- result.try(ask(git.tree_args(parent)))
  use message <- result.try(ask(git.message_args(candidate.commit)))
  use diff <- result.try(ask(git.diff_args(candidate.commit)))
  use split <- result.try(git.split_patch(diff))

  // A commit with no test changes or no source changes is not a fix with a regression test.
  case split.tests, split.src {
    "", _ -> Error("diff has no test changes")
    _, "" -> Error("diff has no source changes")
    _, _ ->
      Ok(Prepared(
        parent:,
        tree: string.trim(tree),
        runner_files:,
        split:,
        body: git.message_parts(message).1,
      ))
  }
}

/// The test runner the verifier needs when the parent commit predates it.
/// `scripts/test.sh` was added long after much of the history, so for an
/// older parent the miner carries the runner from its own checkout as hidden
/// verifier files. They become part of the task's identity, which pins the
/// exact runner that produced the recorded test ids.
const runner_paths = [
  "scripts/test.sh",
  "scripts/with_timeout.py",
  "scripts/serial-tests",
]

/// The runner files every task carries, read from the miner's own checkout.
/// Always, not only when the parent predates the runner: the verifier
/// refuses to run a script from the agent's workspace unless the task stages
/// it, because an agent that owns `scripts/test.sh` grades its own work.
fn runner_files(config: Config) -> Result(List(#(String, String)), String) {
  list.try_map(runner_paths, fn(path) {
    simplifile.read(config.repo <> "/" <> path)
    |> result.map(fn(content) { #(path, content) })
    |> result.map_error(fn(e) {
      "runner file " <> path <> ": " <> simplifile.describe_error(e)
    })
  })
}

/// The twelve-character prefix that names a commit's files and worktree.
fn short(commit: String) -> String {
  string.slice(commit, 0, 12)
}

/// Everything the stages share about one candidate once its worktree exists:
/// where it is, which patch files are staged, and the command that grades it.
type Job {
  Job(
    config: Config,
    candidate: Candidate,
    prepared: Prepared,
    /// The worktree directory.
    path: String,
    /// The patch files' common path prefix under the work directory.
    stem: String,
    /// The verifier command, run identically in every stage.
    argv: List(String),
  )
}

/// What the stages measured, handed to `assemble` to become a task.
type Measured {
  Measured(
    fail_to_pass: List(String),
    pass_to_pass: List(String),
    /// Every hidden file the verifier stages: vendored runner files first,
    /// then the test patch's post-images.
    files: List(#(String, String)),
    sabotage: Sabotage,
    timing: Timing,
  )
}

/// Adds the detached worktree at the parent and runs the stages inside it.
fn in_worktree(
  config: Config,
  candidate: Candidate,
  prepared: Prepared,
  path: String,
  timing: Timing,
) -> #(Result(Task, String), Timing) {
  let added =
    git.ask(
      config.runner,
      config.repo,
      git.worktree_add_args(path, prepared.parent),
      300_000,
    )

  // A worktree that cannot be made ends the candidate here; nothing has run
  // yet, so there is nothing to remove.
  case added {
    Error(reason) -> #(Error("worktree: " <> reason), timing)
    Ok(_) -> {
      let modules = list.filter_map(candidate.test_files, git.test_module)
      let stem = config.work <> "/patch/" <> short(candidate.commit)
      let argv = verifier_argv(candidate.package, modules)

      run_stages(
        Job(config:, candidate:, prepared:, path:, stem:, argv:),
        timing,
      )
    }
  }
}

/// The before run. Stages the runner (when vendored) and the test patch, runs
/// the touched modules, and reads the post-image of every test file for the
/// verifier before the fix is applied.
fn run_stages(job: Job, timing: Timing) -> #(Result(Task, String), Timing) {
  let split = job.prepared.split
  let setup = {
    use _ <- result.try(
      simplifile.create_directory_all(job.config.work <> "/patch")
      |> result.map_error(fn(e) {
        "patch dir: " <> simplifile.describe_error(e)
      }),
    )
    use _ <- result.try(write(job.stem <> ".tests.patch", split.tests))
    use _ <- result.try(write(job.stem <> ".src.patch", split.src))
    use _ <- result.try(stage_files(job.path, job.prepared.runner_files))

    apply(job.config, job.path, job.stem <> ".tests.patch")
  }

  // Setup failure ends the candidate; otherwise the before run is the first
  // measurement.
  case setup {
    Error(reason) -> #(Error(reason), timing)
    Ok(Nil) -> {
      let #(before, before_ms) = timed(job.config, job.path, job.argv)
      let timing = Timing(..timing, before: before_ms)

      // A run that did not execute, or test files that cannot be read, ends
      // the candidate with the time already spent.
      case before, post_images(job.path, split.test_paths) {
        Error(reason), _ -> #(Error(reason), timing)
        _, Error(reason) -> #(Error(reason), timing)
        Ok(before), Ok(images) -> {
          let files = list.append(job.prepared.runner_files, images)

          after_fix(job, before, files, timing)
        }
      }
    }
  }
}

/// The after run and the census. Applies the fix, runs again, and lets `judge`
/// decide; only a reproduced fix is sabotaged and assembled into a task.
fn after_fix(
  job: Job,
  before: TestReport,
  files: List(#(String, String)),
  timing: Timing,
) -> #(Result(Task, String), Timing) {
  // The fix must apply cleanly to the parent with only the tests applied, or
  // the diff split was not a partition.
  case apply(job.config, job.path, job.stem <> ".src.patch") {
    Error(reason) -> #(Error(reason), timing)
    Ok(Nil) -> {
      let #(after, after_ms) = timed_offline(job.config, job.path, job.argv)
      let timing = Timing(..timing, after: after_ms)

      // The judgement decides admission; only a reproduced fix gets the
      // sabotage census.
      case after |> result.map(judge_offline(job, before, _)) {
        Error(reason) -> #(Error(reason), timing)
        Ok(Rejected(reason)) -> #(Error(reason), timing)
        Ok(Judged(fail_to_pass:, pass_to_pass:)) -> {
          let sabotage = sabotage(job, fail_to_pass)
          let measured =
            Measured(fail_to_pass:, pass_to_pass:, files:, sabotage:, timing:)

          #(assemble(job, measured), timing)
        }
      }
    }
  }
}

/// The judgement, with one more question when the after run failed: did it
/// fail only for want of the network? The verifier's jail has the network
/// off, so a test that opens a socket can never pass there, and a task whose
/// fix passes on the host but not without the network is culled by name
/// rather than admitted and refused at proof time.
fn judge_offline(job: Job, before: TestReport, after: TestReport) -> Judgement {
  // Only a failing after run needs the second, networked run to explain it.
  case eunit_ids.ids(after, eunit_ids.Failed), offline_available(job.config) {
    [], _ | _, False -> judge(before, after)
    [_, ..], True -> {
      let #(plain, _) = timed(job.config, job.path, job.argv)

      // Ids that pass with the network and fail without it need it.
      case plain |> result.map(network_only_failures(after, _)) {
        Ok([]) | Error(_) -> judge(before, after)
        Ok(needs) ->
          Rejected(
            "tests need the network, which the verifier jail has off: "
            <> string.join(needs, ", "),
          )
      }
    }
  }
}

/// The ids a run without the network failed that the same run with it
/// passed: the tests that need a socket.
///
/// ## Examples
///
/// ```gleam
/// // mine.network_only_failures(offline, online) == ["m@t.listens_test"]
/// ```
///
pub fn network_only_failures(
  offline: TestReport,
  online: TestReport,
) -> List(String) {
  let passed_online = eunit_ids.ids(online, eunit_ids.Passed)

  eunit_ids.ids(offline, eunit_ids.Failed)
  |> list.filter(list.contains(passed_online, _))
  |> list.unique
}

/// The argv that runs a program in a fresh, empty network namespace, which
/// is the nearest a host-side run comes to the verifier's network-off jail:
/// no interface is up, so a test that listens and connects fails as it
/// will in the jail.
///
/// ## Examples
///
/// ```gleam
/// assert mine.offline(["bash", "x.sh"]) == ["unshare", "-rn", "--", "bash", "x.sh"]
/// ```
///
pub fn offline(argv: List(String)) -> List(String) {
  ["unshare", "-rn", "--", ..argv]
}

/// Whether this host can unshare a network namespace unprivileged. A host
/// that cannot (macOS, a locked-down kernel) runs the after run with the
/// network and the proof step catches a networked test instead.
fn offline_available(config: Config) -> Bool {
  case git.run_in(config.runner, config.repo, offline(["true"]), 10_000) {
    Ok(capture) -> capture.status == 0
    Error(_) -> False
  }
}

/// The after run without the network when the host can arrange it, else
/// with it.
fn timed_offline(
  config: Config,
  dir: String,
  argv: List(String),
) -> #(Result(TestReport, String), Int) {
  case offline_available(config) {
    True -> timed(config, dir, offline(argv))
    False -> timed(config, dir, argv)
  }
}

/// The census run. A revert that could not be built or applied is not
/// applicable, since the census measures the tests and not the miner's editing;
/// a run that no longer passes every fail-to-pass test, a compile failure
/// included, is caught.
fn sabotage(job: Job, fail_to_pass: List(String)) -> Sabotage {
  let reverted = {
    use revert <- result.try(git.first_revert(job.prepared.split.src))
    let file = job.path <> "/" <> revert.path
    use content <- result.try(
      simplifile.read(file) |> result.replace_error(Nil),
    )
    use edited <- result.try(git.apply_edit(content, revert.edit))

    simplifile.write(file, edited) |> result.replace_error(Nil)
  }

  // Nothing to revert, or a revert that does not apply, is not a measurement.
  case reverted {
    Error(Nil) -> NotApplicable
    Ok(Nil) -> {
      let #(run, _) = timed(job.config, job.path, job.argv)

      // A run that produced no report (a compile error from the revert)
      // counts as caught: the fail-to-pass tests did not pass.
      case run {
        Ok(report) -> survived_or_caught(report, fail_to_pass)
        Error(_) -> Caught
      }
    }
  }
}

/// Whether every fail-to-pass test still passes in the sabotaged run.
fn survived_or_caught(
  report: TestReport,
  fail_to_pass: List(String),
) -> Sabotage {
  let all_pass =
    list.all(fail_to_pass, fn(id) {
      eunit_ids.outcome(report, id) == Ok(eunit_ids.Passed)
    })

  // One failing test is enough to say the tests notice the damage.
  case all_pass {
    True -> Survived
    False -> Caught
  }
}

/// Builds the task from what the stages measured and checks it with the task
/// format's own decoder, which is where the size limits are enforced.
fn assemble(job: Job, measured: Measured) -> Result(Task, String) {
  let candidate = job.candidate
  let prepared = job.prepared
  let subject = candidate.subject
  let #(text, kind) =
    prompt(subject, prepared.body, measured.fail_to_pass, candidate.test_files)

  // A source file under the package names the family the split quotas group by.
  let family = case list.first(candidate.src_files) {
    Ok(first) -> [
      "family:packages/"
      <> candidate.package
      <> "/"
      <> module_of(first, candidate.package),
    ]
    Error(Nil) -> []
  }

  let tags =
    list.flatten([
      family,
      ["pkg:" <> candidate.package, sabotage_tag(measured.sabotage)],
      case prepared.runner_files {
        [] -> []
        _ -> ["runner:vendored"]
      },
      case kind {
        SubjectOnly -> ["prompt:subject-only"]
        FullMessage -> []
      },
    ])
    |> list.unique

  let minted =
    task.mint(task.Task(
      id: "",
      name: "mined/" <> candidate.package <> "/" <> short(candidate.commit),
      prompt: text,
      workspace: GitTree(
        repository: job.config.name,
        commit: prepared.parent,
        tree: prepared.tree,
        prepare: [["gleam", "deps", "download"]],
      ),
      verifier: Program(
        files: measured.files,
        argv: job.argv,
        fail_to_pass: measured.fail_to_pass,
        pass_to_pass: measured.pass_to_pass,
        timeout_ms: timeout_for(measured.timing.before, measured.timing.after),
        scoring: task.AllRewardsOne,
      ),
      tags:,
      provenance: MinedCommit(
        fix: candidate.commit,
        parent: prepared.parent,
        subject:,
      ),
    ))

  // The task format's own decoder is the admission check for size limits.
  task.decode(task.to_json(minted))
  |> result.map(fn(_) { minted })
  |> result.map_error(fn(reason) { "task rejected: " <> reason })
}

/// The module path of a source file inside its package, which is what the
/// family tag names.
fn module_of(src_path: String, package: String) -> String {
  src_path
  |> string.replace("packages/" <> package <> "/src/", "")
  |> string.replace(".gleam", "")
}

/// Writes files into the worktree, creating their directories.
fn stage_files(
  dir: String,
  files: List(#(String, String)),
) -> Result(Nil, String) {
  list.try_each(files, fn(file) {
    let target = dir <> "/" <> file.0
    let parent =
      string.join(
        list.reverse(list.drop(list.reverse(string.split(target, "/")), 1)),
        "/",
      )

    simplifile.create_directory_all(parent)
    |> result.map_error(fn(e) { parent <> ": " <> simplifile.describe_error(e) })
    |> result.try(fn(_) { write(target, file.1) })
  })
}

/// Writes a file, naming the path in the error.
fn write(path: String, content: String) -> Result(Nil, String) {
  simplifile.write(path, content)
  |> result.map_error(fn(e) { path <> ": " <> simplifile.describe_error(e) })
}

/// Applies a patch file to the worktree.
fn apply(config: Config, dir: String, patch: String) -> Result(Nil, String) {
  git.ask(config.runner, dir, git.apply_args(patch), 120_000)
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(reason) { "apply: " <> reason })
}

/// Reads each touched test file as the patch left it, which is the exact text
/// the verifier will stage.
fn post_images(
  dir: String,
  paths: List(String),
) -> Result(List(#(String, String)), String) {
  list.try_map(paths, fn(path) {
    simplifile.read(dir <> "/" <> path)
    |> result.map(fn(content) { #(path, content) })
    |> result.map_error(fn(e) {
      "test file " <> path <> " unreadable: " <> simplifile.describe_error(e)
    })
  })
}

/// Runs the verifier argv in the worktree and reads its report with its wall
/// time. A runner failure (deadline, spawn) is an `Error`; a nonzero exit with
/// a readable report is data, because a failing test is exactly what the before
/// run looks for.
fn timed(
  config: Config,
  dir: String,
  argv: List(String),
) -> #(Result(TestReport, String), Int) {
  let clock = poll.monotonic()
  let started = clock.now()
  let run = git.run_in(config.runner, dir, argv, config.run_timeout_ms)
  let elapsed = clock.now() - started

  #(
    run
      |> result.map(fn(capture) { eunit_ids.parse(capture.output) })
      |> result.map_error(fn(reason) { "run: " <> reason }),
    elapsed,
  )
}

/// One census line for a mined candidate: JSON with the commit, package,
/// subject, the outcome, and timings.
///
/// ## Examples
///
/// ```gleam
/// // mine.census_line(mined) starts with {"after_ms":
/// ```
///
pub fn census_line(mined: Mined) -> String {
  // An admitted task reports its identity and sizes, a culled one only its reason.
  let outcome = case mined.result {
    Ok(task) -> [
      #("outcome", json.String("admitted")),
      #("task", json.String(task.id)),
      #("tags", json.Array(list.map(task.tags, json.String))),
      #("counts", counts(task)),
    ]
    Error(reason) -> [
      #("outcome", json.String("culled")),
      #("reason", json.String(reason)),
    ]
  }

  json.Object(list.append(
    [
      #("commit", json.String(mined.candidate.commit)),
      #("package", json.String(mined.candidate.package)),
      #("subject", json.String(mined.candidate.subject)),
      #("before_ms", json.Int(mined.before_ms)),
      #("after_ms", json.Int(mined.after_ms)),
    ],
    outcome,
  ))
  |> json.to_string
}

/// The sizes of a task's two test sets, for the census.
fn counts(task: Task) -> json.JsonValue {
  case task.verifier {
    Program(fail_to_pass:, pass_to_pass:, ..) ->
      json.Object([
        #("fail_to_pass", json.Int(list.length(fail_to_pass))),
        #("pass_to_pass", json.Int(list.length(pass_to_pass))),
      ])
    task.ExpectedFiles(..) -> json.Null
  }
}

/// A task's file name inside the output directory.
///
/// ## Examples
///
/// ```gleam
/// // mine.task_file(task) == task.id <> ".json"
/// ```
///
pub fn task_file(task: Task) -> String {
  task.id <> ".json"
}
