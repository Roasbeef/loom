import client/secrets
import eval/git
import eval/materialise
import eval/repos.{type Repos}
import eval/task.{type Task, ExpectedFiles, GitTree, HandWritten, Inline, Task}
import gleam/option.{None, Some}
import gleam/string
import simplifile
import support/scripted

fn task_over(workspace: task.Workspace) -> Task {
  Task(
    id: "",
    name: "materialise",
    prompt: "p",
    workspace:,
    verifier: ExpectedFiles([]),
    tags: [],
    provenance: HandWritten("test"),
  )
}

// The operator's side of the name: `fixture` is wherever the scratch clone is.
fn known(repo: String) -> Repos {
  let assert Ok(known) = repos.add(repos.empty(), "fixture", repo)
    as "a scratch path is absolute"

  known
}

fn sh(command: String) -> String {
  let assert Ok(capture) =
    secrets.host_runner()(["bash", "-c", command <> " 2>&1"], 60_000)
  let assert 0 = capture.status as command

  string.trim(capture.output)
}

// A one-commit repository whose own path contains a single quote, the case
// that breaks a command string built by plain concatenation.
fn quoted_repository() -> #(String, String, String) {
  let repo = scripted.scratch("repo") <> "/it's a repo"
  let quoted = git.shell_quote(repo)

  sh("mkdir -p " <> quoted <> " && cd " <> quoted <> " && git init -q")
  sh(
    "cd "
    <> quoted
    <> " && printf 'one\\n' > one.txt && mkdir sub && printf 'two\\n' > sub/two.txt",
  )
  sh(
    "cd "
    <> quoted
    <> " && git add -A && git -c user.name=t -c user.email=t@t commit -q -m first",
  )

  #(
    repo,
    sh("git -C " <> quoted <> " rev-parse HEAD"),
    sh("git -C " <> quoted <> " rev-parse 'HEAD^{tree}'"),
  )
}

pub fn an_inline_workspace_is_written_to_the_trial_workspace_test() {
  let root = scripted.scratch("inline")
  let inline = task_over(Inline([#("a.txt", "A\n"), #("deep/b.txt", "B\n")]))

  let assert Ok(prepared) =
    materialise.run(secrets.host_runner(), repos.empty(), inline, root)

  assert prepared.workspace == root <> "/work"
  assert simplifile.read(root <> "/work/a.txt") == Ok("A\n")
  assert simplifile.read(root <> "/work/deep/b.txt") == Ok("B\n")
}

pub fn a_git_tree_is_archived_without_history_and_prepared_in_place_test() {
  let #(repo, commit, tree) = quoted_repository()
  let root = scripted.scratch("archive")
  let archived =
    task_over(GitTree("fixture", commit, tree, [["touch", "prepared.marker"]]))

  let assert Ok(prepared) =
    materialise.run(secrets.host_runner(), known(repo), archived, root)

  assert simplifile.read(prepared.workspace <> "/sub/two.txt") == Ok("two\n")
  assert simplifile.is_file(prepared.workspace <> "/prepared.marker")
    == Ok(True)
  assert simplifile.is_directory(prepared.workspace <> "/.git") == Ok(False)
  assert prepared.prepare_ms >= 0
}

pub fn a_tree_that_differs_from_the_recorded_one_is_refused_test() {
  let #(repo, commit, _tree) = quoted_repository()
  let root = scripted.scratch("wrong-tree")
  let wrong = string.repeat("0", 40)
  let mismatched = task_over(GitTree("fixture", commit, wrong, []))

  let assert Error(reason) =
    materialise.run(secrets.host_runner(), known(repo), mismatched, root)

  assert string.contains(reason, "tree mismatch")
  assert simplifile.is_file(root <> "/work/one.txt") == Ok(False)
}

pub fn a_failing_prepare_step_is_an_error_naming_it_test() {
  let #(repo, commit, tree) = quoted_repository()
  let root = scripted.scratch("bad-prepare")
  let failing = task_over(GitTree("fixture", commit, tree, [["false"]]))

  let assert Error(reason) =
    materialise.run(secrets.host_runner(), known(repo), failing, root)

  assert string.contains(reason, "prepare `false` exited 1")
}

pub fn git_workspace_has_no_history_test_() -> scripted.EunitTest {
  scripted.Timeout(300, fn() {
    let assert Ok(here) = simplifile.current_directory()
    let assert Ok(top) =
      git.ask(
        secrets.host_runner(),
        here,
        ["rev-parse", "--show-toplevel"],
        30_000,
      )
    let repo = string.trim(top)
    let assert Ok(commit) =
      git.ask(secrets.host_runner(), repo, ["rev-parse", "HEAD~1"], 30_000)
    let commit = string.trim(commit)
    let assert Ok(tree) =
      git.ask(
        secrets.host_runner(),
        repo,
        ["rev-parse", commit <> "^{tree}"],
        30_000,
      )
    let tree = string.trim(tree)
    let root = scripted.scratch("loom-parent")

    let assert Ok(prepared) =
      materialise.run(
        secrets.host_runner(),
        known(repo),
        task_over(GitTree("fixture", commit, tree, [])),
        root,
      )

    // No repository of any kind travels with the files.
    assert simplifile.is_directory(prepared.workspace <> "/.git") == Ok(False)
    assert simplifile.is_file(prepared.workspace <> "/.git") == Ok(False)
    assert simplifile.is_file(prepared.workspace <> "/CLAUDE.md") == Ok(True)

    // The tree id was verified against the repository, and a wrong one is refused.
    let other = scripted.scratch("loom-wrong")
    let assert Error(reason) =
      materialise.run(
        secrets.host_runner(),
        known(repo),
        task_over(GitTree("fixture", commit, string.repeat("0", 40), [])),
        other,
      )
    assert string.contains(reason, "tree mismatch")
  })
}

// A repository shaped like Loom: no project at the root, a Gleam project under
// `packages/demo`, and a verifier that names that package.
fn packaged_repository() -> #(String, String, String) {
  let repo = scripted.scratch("packaged")
  let quoted = git.shell_quote(repo)

  sh(
    "mkdir -p "
    <> quoted
    <> "/packages/demo/src && cd "
    <> quoted
    <> "/packages/demo && printf 'name = \"demo\"\\nversion = \"0.1.0\"\\n' > gleam.toml && printf 'pub fn one() { 1 }\\n' > src/demo.gleam",
  )
  sh(
    "cd "
    <> quoted
    <> " && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -q -m first",
  )

  #(
    repo,
    sh("git -C " <> quoted <> " rev-parse HEAD"),
    sh("git -C " <> quoted <> " rev-parse 'HEAD^{tree}'"),
  )
}

pub fn prepare_runs_in_the_verifiers_package_and_warms_its_build_test() {
  let #(repo, commit, tree) = packaged_repository()
  let root = scripted.scratch("package-prepare")
  let mined =
    task_over(GitTree("fixture", commit, tree, [["gleam", "deps", "download"]]))
  let mined =
    Task(
      ..mined,
      verifier: task.Program(
        files: [],
        argv: ["bash", "scripts/test.sh", "demo", "--match", "m:"],
        fail_to_pass: [],
        pass_to_pass: [],
        timeout_ms: 1000,
        scoring: task.AllRewardsOne,
      ),
    )

  let assert Ok(prepared) =
    materialise.run(secrets.host_runner(), known(repo), mined, root)

  // The step found a project to run in, and the warm build compiled it there.
  assert simplifile.is_directory(prepared.workspace <> "/packages/demo/build")
    == Ok(True)
  assert simplifile.is_directory(prepared.workspace <> "/build") == Ok(False)

  // The pristine copy of that build sits beside the workspace, outside the
  // agent's reach, at the same relative path.
  assert prepared.pristine == Some(root <> "/pristine")
  assert simplifile.is_directory(root <> "/pristine/packages/demo/build")
    == Ok(True)
  assert simplifile.is_directory(root <> "/pristine/build") == Ok(False)
}

pub fn prepare_finds_the_package_from_the_pkg_tag_and_chained_argv_test() {
  let #(repo, commit, tree) = packaged_repository()
  let root = scripted.scratch("package-tag")
  let mined =
    task_over(GitTree("fixture", commit, tree, [["gleam", "deps", "download"]]))
  let mined =
    Task(
      ..mined,
      tags: ["pkg:demo"],
      verifier: task.Program(
        files: [],
        argv: [
          "bash", "-c",
          "status=0; 'bash' 'scripts/test.sh' 'demo' '--match' 'a:' || status=1; exit $status",
        ],
        fail_to_pass: [],
        pass_to_pass: [],
        timeout_ms: 1000,
        scoring: task.AllRewardsOne,
      ),
    )

  let assert Ok(prepared) =
    materialise.run(secrets.host_runner(), known(repo), mined, root)
  assert simplifile.is_directory(prepared.workspace <> "/packages/demo/build")
    == Ok(True)
  assert prepared.pristine == Some(root <> "/pristine")
}

pub fn a_tree_with_no_build_has_no_pristine_copy_test() {
  let root = scripted.scratch("no-pristine")
  let assert Ok(prepared) =
    materialise.run(
      secrets.host_runner(),
      repos.empty(),
      task_over(Inline([#("a.txt", "a\n")])),
      root,
    )
  assert prepared.pristine == None
}
