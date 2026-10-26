//// Tests for the Harbor export: the directory a task becomes, the refusals
//// that keep hostile input out of the Dockerfile, and the generated verifier
//// script, which is run here on the host because it is our own output.

import client/secrets
import core/json
import eval/harbor
import eval/repos
import eval/task.{
  type Task, AllRewardsOne, ExpectedFiles, GitTree, HandWritten, Inline,
  MinedCommit, Program, Task,
}
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import simplifile

const commit = "2b3c46a8599ef7374ca6d73dbcee679996c76963"

const fix = "eccdddad0c6f92b4bd8812246d36753477eae4b1"

const options =
  harbor.Options(
    repo_url: "https://example.org/loom.git",
    base_image: "ubuntu@sha256:0123abcd",
  )

const diff =
  "diff --git a/packages/machine/src/machine/x.gleam b/packages/machine/src/machine/x.gleam
--- a/packages/machine/src/machine/x.gleam
+++ b/packages/machine/src/machine/x.gleam
@@ -1,1 +1,2 @@
 a
+b
diff --git a/packages/machine/test/machine/x_test.gleam b/packages/machine/test/machine/x_test.gleam
--- a/packages/machine/test/machine/x_test.gleam
+++ b/packages/machine/test/machine/x_test.gleam
@@ -1,1 +1,2 @@
 a
+c
"

fn scratch(name: String) -> String {
  let assert Ok(cwd) = simplifile.current_directory()
  let directory = cwd <> "/build/harbor-test/" <> name
  let _ = simplifile.delete(directory)
  let assert Ok(Nil) = simplifile.create_directory_all(directory)

  directory
}

fn mined() -> Task {
  task.mint(Task(
    id: "",
    name: "mined/machine/ECCD",
    prompt: "machine: keep the run alive",
    workspace: GitTree(repository: "loom", commit:, tree: commit, prepare: [
      ["gleam", "deps", "download"],
    ]),
    verifier: Program(
      files: [#("packages/machine/test/machine/x_test.gleam", "HIDDEN-TEST")],
      argv: ["bash", "scripts/test.sh", "machine", "--match", "x_test:"],
      fail_to_pass: ["x_test.a_test"],
      pass_to_pass: ["x_test.b_test"],
      timeout_ms: 119_500,
      scoring: AllRewardsOne,
    ),
    tags: [],
    provenance: MinedCommit(fix:, parent: commit, subject: "s"),
  ))
}

fn inline_program(argv: List(String)) -> Task {
  task.mint(Task(
    id: "",
    name: "inline",
    prompt: "edit it",
    workspace: Inline([#("a.txt", "start\n")]),
    verifier: Program(
      files: [#("hidden.txt", "secret\n")],
      argv:,
      fail_to_pass: ["my_test.a_test"],
      pass_to_pass: ["my_test.b_test", "my_test.c_test"],
      timeout_ms: 5000,
      scoring: AllRewardsOne,
    ),
    tags: [],
    provenance: HandWritten("test"),
  ))
}

// The clone answers the tree check with the tree the task recorded and
// every other question with the diff.
fn answers() -> secrets.Runner {
  fn(argv, _timeout) {
    case string.contains(string.join(argv, " "), "rev-parse") {
      True -> Ok(secrets.Capture(status: 0, output: commit <> "\n"))
      False -> Ok(secrets.Capture(status: 0, output: diff))
    }
  }
}

fn known() -> repos.Repos {
  let assert Ok(known) = repos.add(repos.empty(), "loom", "/srv/clone/loom")

  known
}

fn read(path: String) -> String {
  let assert Ok(text) = simplifile.read(path)

  text
}

fn is_executable(path: String) -> Bool {
  let assert Ok(info) = simplifile.file_info(path)

  int.bitwise_and(info.mode, 0o111) != 0
}

pub fn harbor_layout_test() {
  let out = scratch("layout")
  let assert Ok(Nil) = harbor.export(mined(), out, options, known(), answers())

  let toml = read(out <> "/task.toml")
  let docker = read(out <> "/environment/Dockerfile")
  let lines = string.split(toml, "\n")

  assert read(out <> "/instruction.md") == "machine: keep the run alive\n"
  assert list.contains(lines, "schema_version = \"1.3\"")
  assert list.contains(lines, "name = \"loom/mined-machine-eccd\"")
  assert list.contains(lines, "timeout_sec = 120")
  assert list.contains(lines, "environment_mode = \"separate\"")
  assert list.contains(lines, "network_mode = \"no-network\"")

  assert string.starts_with(docker, "FROM ubuntu@sha256:0123abcd\n")
  assert string.contains(docker, "checkout --detach " <> commit)
  assert string.contains(docker, "rm -rf /app/.git")
  assert string.contains(docker, "RUN 'gleam' 'deps' 'download'")
  assert !string.contains(docker, "HIDDEN-TEST")

  assert read(out <> "/tests/files/packages/machine/test/machine/x_test.gleam")
    == "HIDDEN-TEST"
  assert string.contains(read(out <> "/tests/test.sh"), "'scripts/test.sh'")
  assert is_executable(out <> "/tests/test.sh")
  assert is_executable(out <> "/solution/solve.sh")

  // The reference solution is the source half of the fix, never the tests.
  let patch = read(out <> "/solution/gold.patch")

  assert string.contains(patch, "machine/src/machine/x.gleam")
  assert !string.contains(patch, "x_test.gleam")
}

pub fn harbor_refuses_hostile_inputs_test() {
  let bad_image = harbor.Options(..options, base_image: "ubuntu\nRUN evil")
  let bad_url = harbor.Options(..options, repo_url: "--upload-pack=evil")

  assert result.is_error(harbor.render(mined(), bad_image, harbor.NoSolution))
  assert result.is_error(harbor.render(mined(), bad_url, harbor.NoSolution))
  assert harbor.slug("A b/C") == "a-b-c"
  assert harbor.slug("///") == "task"
}

pub fn harbor_test_sh_writes_reward_json_test() {
  let out = scratch("reward")
  let workspace = scratch("reward-workspace")
  let logs = scratch("reward-logs")
  let argv = [
    "bash", "-c",
    "test -f hidden.txt && printf '  my_test: a_test...[0.001 s] ok\\n  my_test: b_test...ok\\n  my_test: c_test...*failed*\\n'",
  ]
  let assert Ok(Nil) =
    harbor.export(inline_program(argv), out, options, known(), answers())

  let run =
    "LOOM_WORKSPACE="
    <> workspace
    <> " LOOM_VERIFIER_LOGS="
    <> logs
    <> " bash "
    <> out
    <> "/tests/test.sh"
  let assert Ok(secrets.Capture(status: 0, ..)) =
    secrets.host_runner()(["bash", "-c", run], 30_000)
  let assert Ok(reward) = json.parse(read(logs <> "/reward.json"))

  assert reward
    == json.Object([#("f2p", json.Float(1.0)), #("p2p", json.Float(0.5))])
}

pub fn harbor_expected_files_compare_bytes_test() {
  let verified =
    task.mint(
      Task(
        ..inline_program([]),
        verifier: ExpectedFiles([#("a.txt", "done\n"), #("b.txt", "want\n")]),
      ),
    )
  let out = scratch("expected")
  let workspace = scratch("expected-workspace")
  let logs = scratch("expected-logs")
  let assert Ok(Nil) = harbor.export(verified, out, options, known(), answers())
  let assert Ok(Nil) = simplifile.write(workspace <> "/a.txt", "done\n")
  let assert Ok(Nil) = simplifile.write(workspace <> "/b.txt", "other\n")

  let run =
    "LOOM_WORKSPACE="
    <> workspace
    <> " LOOM_VERIFIER_LOGS="
    <> logs
    <> " bash "
    <> out
    <> "/tests/test.sh"
  let assert Ok(secrets.Capture(status: 0, ..)) =
    secrets.host_runner()(["bash", "-c", run], 30_000)
  let assert Ok(reward) = json.parse(read(logs <> "/reward.json"))

  assert reward == json.Object([#("files", json.Float(0.5))])
  assert read(out <> "/environment/workspace/a.txt") == "start\n"
  assert string.contains(
    read(out <> "/environment/Dockerfile"),
    "COPY workspace/ /app/",
  )
}
