//// The scripted replay that opens the landing page.
////
//// It is a recording of the kind of session the terminal client shows,
//// played back from a script. Nothing in it runs: no model, no daemon and
//// no sandbox. The project, the file names, the counts and the path under
//// `~/.cache` are examples, and the page says so beside the terminal. What
//// the replay shows follows the repository's documents: the terminal's boxes
//// and its approval dialog (`docs/architecture/approvals.md`, "Deciding"),
//// tool calls as two commits (`docs/architecture/orchestration.md`), code
//// mode (`docs/code-mode.md`), `fs_edit`'s hash anchors
//// (`docs/architecture/tools.md`), and the six steps of `sessions.move`
//// (`docs/architecture/distributed.md`).
////
//// A step adds lines to the transcript and has a short explanation beside
//// it. A step can point at one step of a figure lower on the page, which is
//// how the replay connects what a visitor sees to the mechanism under it.
////
//// ## Flow
////
//// - `steps` is the script. `gate` is the index of the approval step, where
////   playback stops until the visitor answers.
//// - `lines` is the transcript up to a step, which depends on the answer.
//// - `body` is a step's explanation, which also depends on the answer.
//// - `next_index` and `dwell_ms` are what the update function needs to step
////   forward on a timer.

import gleam/list
import gleam/option.{type Option, None, Some}
import site/msg.{type Decision, type FigureId, AllowOnce, AllowSession, Deny}

/// One line of the transcript.
pub type Line {
  /// What the visitor typed.
  UserLine(String)
  /// What the agent says.
  AgentLine(String)
  /// A tool call: the tool name and its arguments.
  ToolLine(tool: String, args: String)
  /// A tool result. It appears a moment after its call.
  OutLine(text: String, delay_ms: Int)
  /// A program, shown as code.
  CodeBlock(String)
  /// A line the harness writes about itself.
  NoteLine(text: String, delay_ms: Int)
  /// A refusal.
  WarnLine(text: String, delay_ms: Int)
  /// A line in a second shell, which is not part of the transcript.
  ShellLine(text: String, delay_ms: Int)
}

/// A step of a figure that explains this replay step.
pub type Underneath {
  Underneath(figure: FigureId, step: Int, label: String)
}

/// One step of the replay.
pub type Step {
  Step(
    /// The short name on the step chip.
    chip: String,
    /// The headline of the explanation.
    title: String,
    /// The explanation. It may depend on the visitor's answer.
    body: fn(Option(Decision)) -> String,
    /// The lines this step adds to the transcript.
    lines: fn(Option(Decision)) -> List(Line),
    /// How long playback stays on this step, in milliseconds.
    dwell_ms: Int,
    /// The figure step that explains this one, if there is one.
    underneath: Option(Underneath),
  )
}

/// The index of the approval step, where playback waits for an answer.
pub const gate = 4

/// The program the model writes in the third step. It follows the first
/// example in `docs/code-mode.md`: imports are the program's permissions.
pub const program =
  "import cap/fs
import cap/report
import cap/task
import gleam/list
import gleam/result
import gleam/string

pub fn main() -> report.Outcome {
  let files = [\"src/boot.gleam\", \"src/cli.gleam\", \"src/config.gleam\"]
  case task.parallel_map(files, max_concurrency: 3, with: uses) {
    Ok(counts) ->
      list.zip(files, counts)
      |> list.map(fn(pair) { #(pair.0, report.int(pair.1)) })
      |> report.object
      |> report.value
    Error(failures) -> report.failure(string.inspect(failures))
  }
}

fn uses(path: String) -> Result(Int, fs.FsError) {
  use text <- result.map(fs.read(path))
  list.length(string.split(text, \"parse_config\")) - 1
}"

/// The layers the helper reports for a command that may not use the network.
/// The names are the ones in `docs/architecture/executor.md`.
const layers =
  "enforced: bwrap, mounts, landlock, no-new-privs, seccomp-net, rlimit-cpu, rlimit-fsize"

/// The script.
pub fn steps() -> List(Step) {
  [
    Step(
      chip: "Ask",
      title: "You send a prompt",
      body: fn(_) {
        "The prompt is committed to the session's SQLite file as entries in the conversation tree. In this example the session is distributed: its runtime is on an orchestrator named `alpha`, and its checkout and its tools are on an executor named `box`."
      },
      lines: fn(_) {
        [
          UserLine(
            "Rename parse_config to load_config in every caller and run the tests.",
          ),
          AgentLine("I will find every caller first."),
        ]
      },
      dwell_ms: 3400,
      underneath: None,
    ),
    Step(
      chip: "Search",
      title: "A tool call is committed twice",
      body: fn(_) {
        "Loom commits the call's intent before it runs the tool and commits the result when the tool finishes. After a crash, a tool that is safe to repeat runs again, and any other tool gets an explicit failure in place of a silent second run."
      },
      lines: fn(_) {
        [
          ToolLine("grep", "parse_config"),
          OutLine("completed: 9 matches in 3 files", 800),
        ]
      },
      dwell_ms: 3600,
      underneath: Some(Underneath(
        msg.Crash,
        1,
        "See the two commits in the crash figure",
      )),
    ),
    Step(
      chip: "Program",
      title: "One program in place of three tool calls",
      body: fn(_) {
        "This is code mode. The program's imports are its permissions: it imports `cap/fs`, `cap/task` and `cap/report`, so it can read files and nothing else. Loom vets the source, compiles it offline and runs it in a jailed BEAM node. Only the structured result returns to the conversation."
      },
      lines: fn(_) {
        [
          AgentLine("One program can count the uses in all three files."),
          ToolLine("code_mode", "seam: workspace"),
          CodeBlock(program),
          OutLine(
            "completed: {\"src/boot.gleam\":2,\"src/cli.gleam\":1,\"src/config.gleam\":6}",
            1800,
          ),
        ]
      },
      dwell_ms: 6200,
      underneath: Some(Underneath(
        msg.CodeMode,
        1,
        "Follow a program through vetting, the jail and the broker",
      )),
    ),
    Step(
      chip: "Edit",
      title: "Edits name lines by anchor",
      body: fn(_) {
        "`fs_read` returns each line with an anchor derived from its text. An edit names lines by number and anchor and is bound to the file's digest, so an edit planned against a file that has changed since it was read is rejected before anything is written."
      },
      lines: fn(_) {
        [
          AgentLine("Renaming it in those three files."),
          ToolLine("fs_edit", "src/config.gleam"),
          OutLine("completed: 6 lines changed", 600),
          ToolLine("fs_edit", "src/cli.gleam"),
          OutLine("completed: 1 line changed", 1000),
          ToolLine("fs_edit", "src/boot.gleam"),
          OutLine("completed: 2 lines changed", 1400),
        ]
      },
      dwell_ms: 4400,
      underneath: None,
    ),
    Step(
      chip: "Approve",
      title: "The sandbox refused a write, and your answer decides",
      body: fn(decision) {
        case decision {
          None ->
            "`make test` writes a cache outside the workspace. The broker refused the call before it spent budget or started a process, and the refusal became a stored question. The dialog selects nothing when it opens, and your answer applies to this exact action."
          Some(AllowOnce) ->
            "You chose allow once. That approval authorizes one run of this one call."
          Some(AllowSession) ->
            "You chose allow for the session. This call runs once now, and the grant is also stored as a session fact that later calls pick up."
          Some(Deny) ->
            "You denied it. The call settles with the refusal, and the model decides what to do next."
        }
      },
      lines: fn(decision) {
        let tail = case decision {
          None -> []
          Some(AllowOnce) -> [NoteLine("approved once", 0)]
          Some(AllowSession) -> [NoteLine("approved for the session", 0)]
          Some(Deny) -> [NoteLine("denied", 0)]
        }
        [
          AgentLine("Now the tests."),
          ToolLine("bash", "make test"),
          WarnLine(
            "Refused by policy: wants write access to /home/dev/.cache/fixtures",
            500,
          ),
          ..tail
        ]
      },
      dwell_ms: 5200,
      underneath: Some(Underneath(
        msg.Approval,
        3,
        "See how the refusal reaches the dialog",
      )),
    ),
    Step(
      chip: "Run",
      title: "The command runs in a jail",
      body: fn(decision) {
        case decision {
          Some(Deny) ->
            "Nothing ran outside the workspace. The refusal came back as an ordinary tool result, the model chose a different command, and that command ran in the same jail."
          Some(AllowSession) ->
            "The approval was spent once and the call was cleared again under the wider policy. Because you chose the session, the next call that wants the same access finds the stored grant and does not ask. A call that is already running keeps the authority it started with."
          _ ->
            "The approval was spent once, and the call was cleared again under the wider policy. The helper, `loom-exec`, restricted itself with bubblewrap mounts, Landlock, a seccomp filter and limits, and only then ran the command. The next call that wants the same access asks again."
        }
      },
      lines: fn(decision) {
        case decision {
          Some(Deny) -> [
            AgentLine("The tests need that cache. I will run them without it."),
            ToolLine("bash", "make test CACHE=off"),
            OutLine("completed: exit 0", 800),
            NoteLine(layers, 1100),
          ]
          Some(AllowSession) -> [
            ToolLine("bash", "make test"),
            OutLine("completed: exit 0", 800),
            NoteLine(layers, 1100),
            AgentLine("A lint run needs the same cache."),
            ToolLine("bash", "make lint"),
            OutLine("completed: exit 0, no question asked", 1900),
          ]
          _ -> [
            ToolLine("bash", "make test"),
            OutLine("completed: exit 0", 800),
            NoteLine(layers, 1100),
          ]
        }
      },
      dwell_ms: 5400,
      underneath: Some(Underneath(
        msg.Approval,
        6,
        "See the layers close around the command",
      )),
    ),
    Step(
      chip: "Done",
      title: "The session is on disk",
      body: fn(_) {
        "Close the terminal or restart the daemon and the conversation is still in the SQLite file. Open the session again from the picker and Loom reconciles any unfinished work with each tool's replay policy."
      },
      lines: fn(_) {
        [
          AgentLine(
            "Renamed parse_config to load_config in 3 files. The tests pass.",
          ),
        ]
      },
      dwell_ms: 4200,
      underneath: Some(Underneath(
        msg.Crash,
        4,
        "See what recovery does after a kill",
      )),
    ),
    Step(
      chip: "Move",
      title: "A session can change orchestrator",
      body: fn(_) {
        "This session's checkout is on an executor, so it can move. `loom sessions move` hands the conversation file to another orchestrator, here `bravo`. The checkout and the executor stay where they are, and the command returns while the daemon carries out the six steps."
      },
      lines: fn(_) {
        [
          ShellLine("$ loom sessions move <id> --to bravo", 0),
          ShellLine("moving <id> to bravo (operation <id>)", 700),
        ]
      },
      dwell_ms: 5200,
      underneath: Some(Underneath(
        msg.Migration,
        1,
        "Follow the six steps of a move",
      )),
    ),
  ]
}

/// The index of the last step.
pub fn last() -> Int {
  list.length(steps()) - 1
}

/// The step at an index.
pub fn step_at(index: Int) -> Option(Step) {
  case list.drop(steps(), index) {
    [step, ..] if index >= 0 -> Some(step)
    _ -> None
  }
}

/// Every transcript line up to and including the step at `index`.
pub fn lines(index: Int, decision: Option(Decision)) -> List(Line) {
  steps()
  |> list.take(index + 1)
  |> list.flat_map(fn(step) { step.lines(decision) })
}

/// A step's explanation under the visitor's answer so far.
pub fn body(index: Int, decision: Option(Decision)) -> String {
  case step_at(index) {
    Some(step) -> step.body(decision)
    None -> ""
  }
}

/// Whether the replay is stopped at the approval dialog.
pub fn waiting(index: Int, decision: Option(Decision)) -> Bool {
  index == gate && decision == None
}

/// The step that follows `index` in playback, or the same step when there is
/// nowhere to go: at the last step, or at the dialog with no answer.
pub fn next_index(index: Int, decision: Option(Decision)) -> Int {
  case waiting(index, decision) || index >= last() {
    True -> index
    False -> index + 1
  }
}

/// The furthest step the visitor can reach by hand before answering.
pub fn furthest(decision: Option(Decision)) -> Int {
  case decision {
    None -> gate
    Some(_) -> last()
  }
}

/// How long playback stays on a step, in milliseconds.
pub fn dwell_ms(index: Int) -> Int {
  case step_at(index) {
    Some(step) -> step.dwell_ms
    None -> 3000
  }
}
