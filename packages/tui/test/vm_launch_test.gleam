//// `loom --vm`: how the launcher reads the flag, what it asks the server to do,
//// how it reads the answer, and the two orderings of `ensure` and the daemon.
////
//// The runner that runs `loomd vm ensure` and the function that starts the
//// daemon are arguments of `vm_ensure.ensure`, so each case here scripts the
//// answers the server would give and records what the launcher did in what
//// order. Nothing starts a guest or a daemon.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/result
import gleam/string
import qcheck
import tui
import tui/bootstrap
import tui/placement
import tui/vm_ensure

const seed = 1114

// --- the flag ------------------------------------------------------------------

pub fn vm_alone_serves_the_current_directory_test() {
  let assert Ok(options) = tui.launch_vm(["--vm"])
  assert options.workspace == ""
  assert options.placement == placement.OnThisHost
}

pub fn vm_keeps_workspace_as_a_directory_test() {
  // Unlike `--executor`, where `--workspace` is a registered name, here it is
  // the directory the guest serves.
  let assert Ok(options) =
    tui.launch_vm([
      "--vm", "--workspace", "/src/proj", "--config", "/c/loom.toml",
      "--model-profile", "cheap",
    ])
  assert options.workspace == "/src/proj"
  assert options.config == "/c/loom.toml"
  assert options.profile == "cheap"
  assert options.placement == placement.OnThisHost
}

pub fn the_switch_may_stand_anywhere_test() {
  let assert Ok(options) = tui.launch_vm(["--workspace", "/w", "--vm"])
  assert options.workspace == "/w"
}

pub fn each_conflicting_flag_is_refused_with_its_reason_test() {
  let cases = [
    #(["--vm", "--executor", "box", "--workspace", "app"], "no --executor"),
    #(["--vm", "--pool", "p", "--workspace", "app"], "not in a pool"),
    #(["--vm", "--session", "abc"], "--session opens an existing one"),
    #(["--vm", "--addr", "ws://x/v2/control"], "--addr attaches to a daemon"),
  ]
  list.each(cases, fn(case_) {
    let #(arguments, reason) = case_
    let assert Error(refusal) = tui.launch_vm(arguments)
    assert string.contains(refusal, reason)
  })
}

pub fn a_plain_launch_is_not_a_vm_launch_test() {
  let assert Error(_) = tui.launch_vm([])
  let assert Error(_) = tui.launch_vm(["--executor", "box", "--workspace", "a"])
}

// --- what the server is asked ------------------------------------------------------

fn options(workspace: String, config: String) -> bootstrap.Options {
  bootstrap.Options(workspace, "", "", "", config, "", placement.OnThisHost)
}

pub fn the_server_is_asked_for_the_launch_s_directory_test() {
  assert vm_ensure.arguments(options("/src/proj", ""))
    == ["vm", "ensure", "--workspace", "/src/proj"]
  assert vm_ensure.arguments(options("", "/c/loom.toml"))
    == ["vm", "ensure", "--workspace", ".", "--config", "/c/loom.toml"]
}

// --- how the answer is read ------------------------------------------------------------

pub fn the_guest_line_is_exact_test() {
  assert vm_ensure.parse_line("executor=proj-1a2b3c workspace=proj")
    == Ok(vm_ensure.Guest("proj-1a2b3c", "proj"))

  // Anything else is an error, not a guess.
  list.each(
    [
      "",
      "executor=proj-1a2b3c",
      "workspace=proj executor=proj-1a2b3c",
      "executor=proj-1a2b3c  workspace=proj",
      "executor=proj-1a2b3c workspace=proj extra=1",
      "executor=Proj workspace=proj",
      "executor=proj workspace=a/b",
      "executor= workspace=proj",
      " executor=proj workspace=proj",
    ],
    fn(line) {
      assert result.is_error(vm_ensure.parse_line(line))
    },
  )
}

pub fn the_guest_line_parser_is_total_and_exact_test() {
  // Arbitrary text never crashes the parser, and a line it accepts is
  // one this module would print for the guest it names.
  qcheck.default_config()
  |> qcheck.with_test_count(500)
  |> qcheck.with_seed(qcheck.seed(seed))
  |> qcheck.run(qcheck.string(), fn(text) {
    case vm_ensure.parse_line(text) {
      Ok(guest) -> {
        assert text
          == "executor=" <> guest.executor <> " workspace=" <> guest.workspace
        Nil
      }
      Error(_) -> Nil
    }
  })
}

pub fn a_printed_line_is_read_back_test() {
  // Names drawn from the grammars a guest name and a directory name have.
  let name =
    qcheck.string_from(qcheck.alphanumeric_ascii_codepoint())
    |> qcheck.map(fn(text) { "g" <> string.lowercase(text) })
  let directory = qcheck.string_from(qcheck.alphanumeric_ascii_codepoint())
  qcheck.default_config()
  |> qcheck.with_test_count(300)
  |> qcheck.with_seed(qcheck.seed(seed + 1))
  |> qcheck.run(qcheck.tuple2(name, directory), fn(pair) {
    let #(executor, workspace) = pair
    case string.length(executor) <= 32 && workspace != "" {
      True -> {
        assert vm_ensure.parse_line(
            "executor=" <> executor <> " workspace=" <> workspace,
          )
          == Ok(vm_ensure.Guest(executor, workspace))
        Nil
      }
      False -> Nil
    }
  })
}

pub fn status_zero_ends_with_a_guest_test() {
  let assert vm_ensure.Ready(guest, progress) =
    vm_ensure.answer(
      0,
      "loom vm ensure: g-1: booting.\nexecutor=g-1 workspace=app\n",
    )
  assert guest == vm_ensure.Guest("g-1", "app")
  assert progress == "loom vm ensure: g-1: booting."

  // Zero with no guest line is the server's fault and is a failure.
  let assert vm_ensure.Failed(1, _) = vm_ensure.answer(0, "booting\n")
  let assert vm_ensure.Failed(1, _) = vm_ensure.answer(0, "")
}

pub fn status_75_with_the_line_is_a_missing_daemon_test() {
  let assert vm_ensure.NeedsDaemon(progress) =
    vm_ensure.answer(75, "loomd: needs the daemon\ndaemon=required\n")
  assert progress == "loomd: needs the daemon"

  // The status alone is not enough, and the line alone is not either.
  let assert vm_ensure.Failed(75, _) = vm_ensure.answer(75, "something\n")
  let assert vm_ensure.Failed(1, _) =
    vm_ensure.answer(1, "loomd: x\ndaemon=required\n")
}

pub fn any_other_status_keeps_the_whole_output_test() {
  let assert vm_ensure.Failed(1, output) =
    vm_ensure.answer(1, "step\nloomd: the guest failed:\nlog line\n")
  assert output == "step\nloomd: the guest failed:\nlog line"
}

// --- the orderings ------------------------------------------------------------------

// Scripts `ensure`'s answers and records, in order, each run and each daemon
// start as the words `ensure` and `daemon`.
type Script {
  Script(
    runner: vm_ensure.Runner,
    start_daemon: fn() -> Result(Nil, String),
    events: Subject(String),
  )
}

fn script(
  answers: List(#(Int, String)),
  daemon: Result(Nil, String),
) -> Script {
  let queue = process.new_subject()
  list.each(answers, fn(answer) { process.send(queue, answer) })
  let events = process.new_subject()
  Script(
    runner: fn(_) {
      process.send(events, "ensure")
      case process.receive(queue, 0) {
        Ok(answer) -> Ok(answer)
        Error(Nil) -> Error("the script has no more answers")
      }
    },
    start_daemon: fn() {
      process.send(events, "daemon")
      daemon
    },
    events:,
  )
}

fn drained(events: Subject(String)) -> List(String) {
  case process.receive(events, 0) {
    Ok(event) -> [event, ..drained(events)]
    Error(Nil) -> []
  }
}

fn run(script: Script) -> Result(bootstrap.Options, vm_ensure.Failure) {
  vm_ensure.ensure(
    options("/src/proj", ""),
    run: script.runner,
    start_daemon: script.start_daemon,
    report: fn(_) { Nil },
  )
}

const guest_answer = #(0, "executor=proj-1a2b3c workspace=proj\n")

const daemon_answer = #(75, "loomd: join needs the daemon\ndaemon=required\n")

pub fn the_first_guest_runs_ensure_before_any_daemon_test() {
  // A daemon that started before the deployment existed would not have read
  // it, so the default is ensure first, with no daemon start in between.
  let script = script([guest_answer], Ok(Nil))
  let assert Ok(chosen) = run(script)
  assert drained(script.events) == ["ensure"]

  // The session then starts as `--executor E --workspace W` would, with no
  // directory of its own.
  assert chosen.placement == placement.OnExecutor("proj-1a2b3c", "proj")
  assert chosen.workspace == ""
}

pub fn a_missing_daemon_is_started_once_and_ensure_runs_again_test() {
  let script = script([daemon_answer, guest_answer], Ok(Nil))
  let assert Ok(chosen) = run(script)
  assert drained(script.events) == ["ensure", "daemon", "ensure"]
  assert chosen.placement == placement.OnExecutor("proj-1a2b3c", "proj")
}

pub fn a_second_missing_daemon_answer_is_an_error_not_a_loop_test() {
  let script = script([daemon_answer, daemon_answer, guest_answer], Ok(Nil))
  let assert Error(vm_ensure.Failure(75, reason)) = run(script)
  assert string.contains(reason, "still needs a running daemon")
  assert drained(script.events) == ["ensure", "daemon", "ensure"]
}

pub fn the_second_run_s_error_is_the_error_test() {
  let script =
    script([daemon_answer, #(1, "loomd: the guest failed\n")], Ok(Nil))
  let assert Error(vm_ensure.Failure(1, reason)) = run(script)
  assert reason == "loomd: the guest failed"
}

pub fn a_daemon_that_cannot_start_ends_the_launch_test() {
  let script = script([daemon_answer, guest_answer], Error("no socket"))
  let assert Error(vm_ensure.Failure(1, reason)) = run(script)
  assert string.contains(reason, "no socket")

  // Ensure was not run again.
  assert drained(script.events) == ["ensure", "daemon"]
}

pub fn a_failed_ensure_ends_with_its_own_status_test() {
  let script = script([#(3, "loomd: refused\n"), guest_answer], Ok(Nil))
  let assert Error(vm_ensure.Failure(3, "loomd: refused")) = run(script)
  assert drained(script.events) == ["ensure"]
}

pub fn a_server_that_cannot_run_is_a_failure_test() {
  let assert Error(vm_ensure.Failure(1, reason)) =
    vm_ensure.ensure(
      options("", ""),
      run: fn(_) { Error("no such file") },
      start_daemon: fn() { Ok(Nil) },
      report: fn(_) { Nil },
    )
  assert string.contains(reason, "no such file")
}

pub fn the_launch_options_other_than_the_workspace_survive_test() {
  let given =
    bootstrap.Options(
      "/src/proj",
      "",
      "/s/loomd",
      "/state",
      "/c/loom.toml",
      "cheap",
      placement.OnThisHost,
    )
  let assert Ok(chosen) =
    vm_ensure.ensure(
      given,
      run: fn(_) { Ok(guest_answer) },
      start_daemon: fn() { Ok(Nil) },
      report: fn(_) { Nil },
    )
  assert chosen.server == "/s/loomd"
  assert chosen.state_directory == "/state"
  assert chosen.config == "/c/loom.toml"
  assert chosen.profile == "cheap"
  assert chosen.workspace == ""
}
