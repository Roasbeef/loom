//// Writes an evaluation task as a Harbor task directory.
////
//// Harbor is the harness other people run agents in, and Terminal-Bench is a
//// Harbor dataset. A task that only Loom can run can only be compared with
//// itself; a task laid out the way Harbor expects can be run by any agent
//// Harbor knows, and the result read back beside Loom's own. This module is
//// the one-directional export: it renders a task to files and never runs,
//// builds or uploads anything.
////
//// ## Flow
////
//// `export` fetches the one thing that needs the repository, the reference
//// solution, and hands everything to `render`, which is pure and answers the
//// whole directory as data. `slug` gives the task the handle that names both
//// its directory and its Harbor name, and `timeout_seconds` converts the
//// verifier's ceiling. Nothing here runs, builds or uploads anything.
////
//// ## The directory
////
//// - `instruction.md` is the prompt.
//// - `task.toml` is schema 1.3, naming the task `loom/<slug>`, giving the
////   verifier its timeout and `environment_mode = "separate"`, and putting
////   the environment offline.
//// - `environment/Dockerfile` starts from a base image the operator pins. A
////   git task clones the repository at the task's commit and **deletes
////   `.git`**, because an agent that can read the object store can read the
////   fix; an inline task copies `environment/workspace/`.
//// - `tests/test.sh` and its support files, which Harbor uploads only after
////   the agent has finished.
//// - `solution/solve.sh`, the reference solution when one exists.
////
//// ## What the verifier script does
////
//// A program verifier's `test.sh` copies the hidden files into the
//// workspace, runs the task's argv, and hands the output to `reward.py`,
//// which reads EUnit result lines the way `eval/eunit_ids` does (ANSI
//// stripped, `module: name...ok`, last line for an id wins) and writes
//// `/logs/verifier/reward.json` as `{"f2p": x, "p2p": y}`, each the fraction
//// of that set that passed (an empty set scores 1.0). It needs `python3`;
//// the Dockerfile installs it when the base image lacks it. An
//// expected-files verifier compares each file byte for byte and writes
//// `{"files": fraction}`. Both scripts take the workspace and log directory
//// from `LOOM_WORKSPACE` and `LOOM_VERIFIER_LOGS` (defaulting to `/app` and
//// `/logs/verifier`) so the generated script can be run on a host.
////
//// ## Limits
////
//// A reference solution exists for a mined git task (the fix commit's diff
//// minus tests and documentation) and for an expected-files task (the
//// expected files). Any other task gets a `solve.sh` that fails and says
//// why, which Harbor's oracle run reports rather than hides.

import client/secrets.{type Runner}
import core/json
import eval/git
import eval/task.{
  type Task, type Verifier, type Workspace, ExpectedFiles, GitTree, Inline,
  MinedCommit, Program,
}
import eval/wire
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// What the operator must supply for a git task.
pub type Options {
  Options(
    /// Where the container clones the repository from. The task records only
    /// a local path, which means nothing inside a container.
    repo_url: String,
    /// The pinned image the Dockerfile starts from, for example
    /// `ubuntu@sha256:...`.
    base_image: String,
  )
}

/// Whether a written file is run or only read.
pub type Mode {
  /// Written with mode 0755.
  Executable

  /// Written with mode 0644.
  Plain
}

/// One file of the exported directory.
pub type File {
  File(
    /// Path relative to the task directory.
    path: String,
    /// The file's text.
    content: String,
    /// Whether the file is run.
    mode: Mode,
  )
}

/// The reference solution a task can offer.
pub type Solution {
  /// A patch that turns the starting tree into a passing one.
  Gold(patch: String)

  /// The task has no reference solution.
  NoSolution
}

/// The longest verifier ceiling Harbor is given, in seconds, from the task's
/// milliseconds rounded up.
///
/// ## Examples
///
/// ```gleam
/// assert harbor.timeout_seconds(1500) == 2
/// ```
///
pub fn timeout_seconds(timeout_ms: Int) -> Int {
  { timeout_ms + 999 } / 1000
}

/// A directory- and Harbor-safe handle for a task name: lowercase letters,
/// digits, `.` and `-`, with every other run of characters becoming one `-`.
///
/// ## Examples
///
/// ```gleam
/// assert harbor.slug("mined/machine/ECCD") == "mined-machine-eccd"
/// ```
///
pub fn slug(name: String) -> String {
  let mapped =
    name
    |> string.lowercase
    |> string.to_graphemes
    |> list.map(fn(char) {
      case string.contains("abcdefghijklmnopqrstuvwxyz0123456789.", char) {
        True -> char
        False -> "-"
      }
    })
    |> string.concat
  let collapsed = collapse_dashes(mapped)

  // A name made only of separators still needs a handle.
  case trim_dashes(collapsed) {
    "" -> "task"
    trimmed -> trimmed
  }
}

/// Renders a task as the files of its Harbor directory. Pure: the same task,
/// options and solution give the same files. A git task needs a repository
/// URL, a base image and a commit that look safe to put in a Dockerfile; each
/// is refused by name when they do not.
///
/// ## Examples
///
/// ```gleam
/// // harbor.render(task, Options("https://example.org/r.git", "ubuntu:24.04"), NoSolution)
/// // -> Ok([File("instruction.md", ..), File("task.toml", ..), ..])
/// ```
///
pub fn render(
  task: Task,
  options: Options,
  solution: Solution,
) -> Result(List(File), String) {
  use dockerfile <- result.try(dockerfile(task.workspace, options))

  Ok(
    list.flatten([
      [
        File("instruction.md", task.prompt <> "\n", Plain),
        File("task.toml", task_toml(task), Plain),
        File("environment/Dockerfile", dockerfile, Plain),
      ],
      workspace_files(task.workspace),
      verifier_files(task.verifier),
      solution_files(task.verifier, solution),
    ]),
  )
}

/// Writes a task's Harbor directory into `out_dir`.
///
/// A mined git task's reference solution is read from the task's own
/// repository: `git diff <parent> <fix>` with tests and documentation split
/// off by `git.split_patch`. The runner is the host runner in the CLI and a
/// scripted one in tests.
///
/// ## Examples
///
/// ```gleam
/// // harbor.export(task, "out/mined-machine-eccd", options, secrets.host_runner())
/// ```
///
pub fn export(
  task: Task,
  out_dir: String,
  options: Options,
  runner: Runner,
) -> Result(Nil, String) {
  use solution <- result.try(solution(task, runner))
  use files <- result.try(render(task, options, solution))

  list.try_each(files, write_file(out_dir, _))
}

/// The reference solution for a mined git task, read from its repository.
fn solution(task: Task, runner: Runner) -> Result(Solution, String) {
  // Only a mined git task has a fix commit to diff; an expected-files task carries its own solution and the rest have none.
  case task.workspace, task.verifier, task.provenance {
    GitTree(repository:, ..), Program(..), MinedCommit(fix:, parent:, ..) -> {
      use diff <- result.try(git.ask(
        runner,
        repository,
        [
          "diff", "--binary", "--no-renames", "--no-ext-diff", "--no-color",
          parent, fix,
        ],
        120_000,
      ))
      use split <- result.try(git.split_patch(diff))

      // A fix with nothing outside tests and docs has nothing to apply, and an empty patch would make `git apply` fail in the oracle.
      case string.trim(split.src) {
        "" -> Error("the fix commit changes nothing but tests and documents")
        _ -> Ok(Gold(split.src))
      }
    }

    _, ExpectedFiles(..), _ -> Ok(NoSolution)

    _, Program(..), _ -> Ok(NoSolution)
  }
}

/// The Dockerfile: base image, tools, then the starting tree.
fn dockerfile(
  workspace: Workspace,
  options: Options,
) -> Result(String, String) {
  use _ <- result.try(check_image(options.base_image))

  // An inline tree travels in the build context; a git tree is cloned at its commit.
  case workspace {
    Inline(..) ->
      Ok(
        lines([
          "FROM " <> options.base_image,
          tools_line,
          "WORKDIR /app",
          "COPY workspace/ /app/",
        ]),
      )

    GitTree(commit:, prepare:, ..) -> {
      use _ <- result.try(check_url(options.repo_url))
      use _ <- result.try(check_commit(commit))
      use prepared <- result.map(prepare_lines(prepare))

      lines(
        list.flatten([
          ["FROM " <> options.base_image, tools_line, "WORKDIR /app"],
          [clone_line(options.repo_url, commit)],
          prepared,
        ]),
      )
    }
  }
}

// Installs what the generated scripts need when the image lacks it.
const tools_line =
  "RUN command -v git >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || (apt-get update && apt-get install -y --no-install-recommends git python3 ca-certificates && rm -rf /var/lib/apt/lists/*)"

/// Clones, checks out the task's commit and removes the object store: an agent
/// able to read it could read the fix commit that follows.
fn clone_line(url: String, commit: String) -> String {
  "RUN git clone --no-checkout -- "
  <> git.shell_quote(url)
  <> " /app && git -C /app checkout --detach "
  <> commit
  <> " && rm -rf /app/.git"
}

/// One RUN per prepare step, in the package the verifier names.
fn prepare_lines(prepare: List(List(String))) -> Result(List(String), String) {
  list.try_map(prepare, fn(argv) {
    case list.any(argv, fn(word) { string.contains(word, "\n") }) {
      True -> Error("a prepare step contains a newline")
      False -> Ok("RUN " <> git.quoted(argv))
    }
  })
}

/// Refuses a base image reference that is not a plain image name.
fn check_image(image: String) -> Result(Nil, String) {
  let allowed =
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/:@-"
  let clean =
    image != ""
    && !string.starts_with(image, "-")
    && list.all(string.to_graphemes(image), string.contains(allowed, _))

  // A reference is spliced into a Dockerfile line, so one stray character could start another instruction.
  case clean {
    True -> Ok(Nil)
    False -> Error("--base-image is not an image reference: " <> image)
  }
}

/// Refuses a repository URL that could break out of its shell word.
fn check_url(url: String) -> Result(Nil, String) {
  let clean =
    url != ""
    && !string.starts_with(url, "-")
    && list.all(string.to_graphemes(url), fn(char) {
      char != "'"
      && char != "\""
      && char != "\\"
      && char != "\n"
      && char != "\r"
      && char != " "
    })

  // The URL is quoted for the shell, but a leading dash would still be read by git as an option.
  case clean {
    True -> Ok(Nil)
    False -> Error("--repo-url is not a usable repository URL: " <> url)
  }
}

/// Refuses a commit that is not a full hex object name.
fn check_commit(commit: String) -> Result(Nil, String) {
  // The name is spliced into a shell line, so only a full SHA-1 or SHA-256 object name is accepted.
  case wire.is_hex(commit, 40) || wire.is_hex(commit, 64) {
    True -> Ok(Nil)
    False -> Error("the task's commit is not a hex object name: " <> commit)
  }
}

/// The TOML a Harbor 1.3 task carries. Every interpolated value is a slug, a
/// digest or a number, so none needs escaping.
fn task_toml(task: Task) -> String {
  lines([
    "schema_version = \"1.3\"",
    "",
    "[task]",
    "name = \"loom/" <> slug(task.name) <> "\"",
    "",
    "[metadata]",
    "loom_task_id = \"" <> task.id <> "\"",
    "",
    "[verifier]",
    "timeout_sec = " <> int.to_string(timeout_seconds(verifier_timeout(task))),
    "environment_mode = \"separate\"",
    "",
    "[environment]",
    "network_mode = \"no-network\"",
  ])
}

fn verifier_timeout(task: Task) -> Int {
  case task.verifier {
    Program(timeout_ms:, ..) -> timeout_ms
    ExpectedFiles(..) -> 60_000
  }
}

/// Inline files travel in the build context.
fn workspace_files(workspace: Workspace) -> List(File) {
  case workspace {
    Inline(files:) ->
      list.map(files, fn(file) {
        File("environment/workspace/" <> file.0, file.1, Plain)
      })
    GitTree(..) -> []
  }
}

/// The files of `tests/`: the script, its support files and the hidden inputs.
fn verifier_files(verifier: Verifier) -> List(File) {
  case verifier {
    Program(files:, argv:, fail_to_pass:, pass_to_pass:, ..) ->
      list.flatten([
        [
          File("tests/test.sh", program_script(argv), Executable),
          File("tests/reward.py", reward_script, Plain),
          File(
            "tests/ids.json",
            json.to_string(
              json.Object([
                #("fail_to_pass", strings(fail_to_pass)),
                #("pass_to_pass", strings(pass_to_pass)),
              ]),
            )
              <> "\n",
            Plain,
          ),
        ],
        list.map(files, fn(file) {
          File("tests/files/" <> file.0, file.1, Plain)
        }),
      ])

    ExpectedFiles(expected:) -> [
      File("tests/test.sh", expected_script(expected), Executable),
      ..list.map(expected, fn(file) {
        File("tests/expected/" <> file.0, file.1, Plain)
      })
    ]
  }
}

fn strings(items: List(String)) -> json.JsonValue {
  json.Array(list.map(items, json.String))
}

/// The files of `solution/`, or a script that says there is none.
fn solution_files(verifier: Verifier, solution: Solution) -> List(File) {
  case solution, verifier {
    Gold(patch:), _ -> [
      File("solution/solve.sh", apply_script, Executable),
      File("solution/gold.patch", patch, Plain),
    ]

    NoSolution, ExpectedFiles(expected:) -> [
      File("solution/solve.sh", copy_script, Executable),
      ..list.map(expected, fn(file) {
        File("solution/files/" <> file.0, file.1, Plain)
      })
    ]

    NoSolution, Program(..) -> [
      File("solution/solve.sh", no_solution_script, Executable),
    ]
  }
}

const header =
  "#!/bin/bash
set -u
HERE=\"$(cd \"$(dirname \"${BASH_SOURCE[0]}\")\" && pwd)\"
WORKSPACE=\"${LOOM_WORKSPACE:-/app}\"
LOGS=\"${LOOM_VERIFIER_LOGS:-/logs/verifier}\"
mkdir -p \"$LOGS\"
"

/// Runs the task's argv over the hidden files and reduces its output to the
/// two pass fractions. A workspace that cannot be entered scores zero.
fn program_script(argv: List(String)) -> String {
  header
  <> "cd \"$WORKSPACE\" || { echo '{\"f2p\": 0.0, \"p2p\": 0.0}' > \"$LOGS/reward.json\"; exit 0; }
if [ -d \"$HERE/files\" ]; then cp -R \"$HERE/files/.\" . ; fi
"
  <> git.quoted(argv)
  <> " > \"$LOGS/output.txt\" 2>&1
python3 \"$HERE/reward.py\" \"$HERE/ids.json\" \"$LOGS/output.txt\" \"$LOGS/reward.json\"
exit 0
"
}

/// Compares each expected file byte for byte.
fn expected_script(expected: List(#(String, String))) -> String {
  let checks =
    list.map(expected, fn(file) { "check " <> git.shell_quote(file.0) <> "\n" })

  header <> "ok=0
total=0
check() {
  total=$((total + 1))
  if cmp -s \"$HERE/expected/$1\" \"$WORKSPACE/$1\"; then ok=$((ok + 1)); fi
}
" <> string.concat(checks) <> "awk -v a=\"$ok\" -v t=\"$total\" 'BEGIN { printf \"{\\\"files\\\": %.6f}\\n\", (t == 0 ? 1 : a / t) }' > \"$LOGS/reward.json\"
exit 0
"
}

const apply_script =
  "#!/bin/bash
set -eu
HERE=\"$(cd \"$(dirname \"${BASH_SOURCE[0]}\")\" && pwd)\"
cd \"${LOOM_WORKSPACE:-/app}\"
git apply --whitespace=nowarn \"$HERE/gold.patch\"
"

const copy_script =
  "#!/bin/bash
set -eu
HERE=\"$(cd \"$(dirname \"${BASH_SOURCE[0]}\")\" && pwd)\"
cd \"${LOOM_WORKSPACE:-/app}\"
cp -R \"$HERE/files/.\" .
"

const no_solution_script =
  "#!/bin/bash
echo 'this task has no reference solution' >&2
exit 1
"

// Reads EUnit result lines as eval/eunit_ids does and writes the fractions.
const reward_script =
  "\"\"\"Reduces a test run's output to f2p and p2p pass fractions.\"\"\"
import json
import re
import sys

ids = json.load(open(sys.argv[1]))
text = open(sys.argv[2], errors=\"replace\").read()
text = re.sub(chr(27) + r\"\\[[0-9;?]*[@-~]\", \"\", text)

outcome = {}
for line in text.splitlines():
    head, sep, tail = line.strip().partition(\"...\")
    if not sep:
        continue
    tail = tail.strip()
    if tail.startswith(\"[\"):
        _, closed, rest = tail.partition(\"] \")
        if closed:
            tail = rest.strip()
    module, sep, name = head.partition(\": \")
    module = module.split(\":\")[0]
    name = name.split(\" (\")[0]
    if not sep or not module or \" \" in module or not name or \" \" in name:
        continue
    if tail == \"ok\":
        outcome[module + \".\" + name] = True
    elif tail in (\"*failed*\", \"*timed out*\", \"*aborted*\", \"*skipped*\", \"*did not run*\"):
        outcome[module + \".\" + name] = False


def fraction(members):
    if not members:
        return 1.0
    return sum(1 for each in members if outcome.get(each) is True) / len(members)


reward = {\"f2p\": fraction(ids[\"fail_to_pass\"]), \"p2p\": fraction(ids[\"pass_to_pass\"])}
json.dump(reward, open(sys.argv[3], \"w\"))
"

fn lines(items: List(String)) -> String {
  string.join(items, "\n") <> "\n"
}

/// Removes the dashes at both ends of a handle.
fn trim_dashes(text: String) -> String {
  case string.starts_with(text, "-"), string.ends_with(text, "-") {
    True, _ -> trim_dashes(string.drop_start(text, 1))
    False, True -> trim_dashes(string.drop_end(text, 1))
    False, False -> text
  }
}

fn collapse_dashes(text: String) -> String {
  case string.contains(text, "--") {
    True -> collapse_dashes(string.replace(text, "--", "-"))
    False -> text
  }
}

/// Writes one file under `out_dir`, creating its directories and setting its mode.
fn write_file(out_dir: String, file: File) -> Result(Nil, String) {
  use _ <- result.try(safe_path(file.path))
  let target = out_dir <> "/" <> file.path
  let fail = fn(error) {
    "cannot write " <> target <> ": " <> simplifile.describe_error(error)
  }

  use _ <- result.try(
    simplifile.create_directory_all(parent_of(target)) |> result.map_error(fail),
  )
  use _ <- result.try(
    simplifile.write(target, file.content) |> result.map_error(fail),
  )

  simplifile.set_permissions_octal(target, permissions(file.mode))
  |> result.map_error(fail)
}

/// Refuses an export path that could leave the output directory.
fn safe_path(path: String) -> Result(Nil, String) {
  // Paths come from task files, which are untrusted, so each is checked again at the point of writing.
  case wire.safe_path(path) {
    True -> Ok(Nil)
    False -> Error("unsafe path in the export: " <> path)
  }
}

/// The file mode a `Mode` stands for.
fn permissions(mode: Mode) -> Int {
  // Only the generated scripts are run, so they alone get the execute bits.
  case mode {
    Executable -> 0o755
    Plain -> 0o644
  }
}

/// The directory part of a slash-separated path.
fn parent_of(path: String) -> String {
  path
  |> string.split("/")
  |> list.reverse
  |> list.drop(1)
  |> list.reverse
  |> string.join("/")
}
