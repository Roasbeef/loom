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
import host/bootstrap as host
import qcheck
import simplifile
import tui
import tui/bootstrap
import tui/placement
import tui/run
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

// --- loom run -p --vm ------------------------------------------------------------

pub fn run_runs_on_this_machine_without_the_switch_test() {
  let assert Ok(request) = tui.launch_run(["run", "-p", "hi"])
  assert request.tools == run.OnThisMachine
}

pub fn run_takes_vm_anywhere_among_its_flags_test() {
  let assert Ok(request) =
    tui.launch_run([
      "run", "--vm", "-p", "hi", "--workspace", "/src/proj", "--timeout", "30",
    ])
  assert request.tools == run.InTheGuest
  assert request.options.workspace == "/src/proj"
  assert request.prompt == "hi"

  let assert Ok(last) = tui.launch_run(["run", "-p", "hi", "--vm"])
  assert last.tools == run.InTheGuest
}

pub fn run_still_refuses_what_it_never_took_test() {
  // `run` has no way to name an executor, so `--vm` is the only route to one.
  let assert Error(reason) =
    tui.launch_run(["run", "-p", "hi", "--executor", "box"])
  assert string.contains(reason, "unknown run option --executor")
}

// --- what the server is asked ------------------------------------------------------

fn options(workspace: String, config: String) -> bootstrap.Options {
  bootstrap.Options(workspace, "", "", "", config, "", placement.OnThisHost)
}

pub fn the_server_is_asked_for_the_launch_s_directory_test() {
  assert vm_ensure.arguments(options("/src/proj", ""), [])
    == ["vm", "ensure", "--workspace", "/src/proj"]
  assert vm_ensure.arguments(options("", "/c/loom.toml"), [])
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
    flags: [],
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
      flags: [],
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
      flags: [],
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

// --- the guest's own flags ------------------------------------------------------------

pub fn github_and_allow_go_to_ensure_and_nothing_else_does_test() {
  assert vm_ensure.guest_flags([
      "--workspace", "/w", "--github", "off", "--allow", "deb.debian.org",
      "--allow", "*.golang.org", "--config", "/c",
    ])
    == Ok(
      #(
        [
          "--github", "off", "--allow", "deb.debian.org", "--allow",
          "*.golang.org",
        ],
        ["--workspace", "/w", "--config", "/c"],
      ),
    )
  assert vm_ensure.guest_flags([]) == Ok(#([], []))
}

pub fn a_bad_github_or_a_missing_value_is_refused_test() {
  let assert Error(bad) = vm_ensure.guest_flags(["--github", "ssh"])
  assert string.contains(bad, "gh, env or off")
  assert result.is_error(vm_ensure.guest_flags(["--github"]))
  assert result.is_error(vm_ensure.guest_flags(["--allow"]))
  assert result.is_error(vm_ensure.guest_flags(["--allow", ""]))
}

pub fn the_launch_carries_the_guest_flags_to_ensure_test() {
  let assert Ok(flags) =
    tui.launch_vm_flags(["--vm", "--github", "off", "--allow", "h.example.com"])
  assert flags == ["--github", "off", "--allow", "h.example.com"]
  let assert Ok(options) =
    tui.launch_vm(["--vm", "--github", "env", "--workspace", "/w"])
  assert options.workspace == "/w"

  assert vm_ensure.arguments(options, ["--github", "env"])
    == ["vm", "ensure", "--workspace", "/w", "--github", "env"]
  let assert Error(_) = tui.launch_vm(["--vm", "--github", "ssh"])
}

pub fn run_takes_the_guest_flags_with_vm_only_test() {
  let assert Ok(request) =
    tui.launch_run(["run", "-p", "hi", "--vm", "--github", "off"])
  assert request.guest_flags == ["--github", "off"]
  let assert Error(reason) =
    tui.launch_run(["run", "-p", "hi", "--github", "off"])
  assert string.contains(reason, "need --vm")
}

// --- a state directory is another daemon -----------------------------------------------

pub fn a_state_directory_is_refused_with_vm_test() {
  let assert Error(reason) = tui.launch_vm(["--vm", "--state-dir", "/s"])
  assert string.contains(reason, "--state-dir")
  let assert Error(run_reason) =
    tui.launch_run(["run", "-p", "hi", "--vm", "--state-dir", "/s"])
  assert string.contains(run_reason, "--state-dir")

  // Without `--vm` the flag is the plain launch's, unchanged.
  let assert Ok(_) = tui.launch_run(["run", "-p", "hi", "--state-dir", "/s"])
}

// --- which directory the guest serves --------------------------------------------------

pub fn a_subdirectory_launch_serves_the_repository_around_it_test() {
  let root = scratch_root() <> "/vm_launch_test_" <> unique()
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/repo/.git")
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/repo/src/deep")
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/bare/sub")
  let assert Ok(base) = host.absolute_path(root)

  // A repository around the directory is the directory, as for a plain launch.
  assert tui.vm_directory(options(base <> "/repo/src/deep", ""))
    == base <> "/repo"
  assert tui.vm_directory(options(base <> "/repo", "")) == base <> "/repo"

  // A directory with no repository around it is itself, however it is spelled.
  assert tui.vm_directory(options(base <> "/bare/sub", ""))
    == base <> "/bare/sub"
  let _ = simplifile.delete_all([root])
  Nil
}

// A directory with no repository above it. A path inside this checkout has one,
// so the cases that expect none would find the checkout's own.
fn scratch_root() -> String {
  result.unwrap(host.getenv("TMPDIR"), "/tmp")
}

fn unique() -> String {
  string.inspect(host.current_process_id())
  <> "_"
  <> string.inspect(host.system_time_ms())
}

// --- reading the answer from a merged stream -------------------------------------------

pub fn the_last_line_that_reads_as_the_answer_wins_test() {
  // A progress line that lands after the answer does not hide it.
  let assert vm_ensure.Ready(guest, progress) =
    vm_ensure.answer(
      0,
      "booting\nexecutor=g-1 workspace=app\nloom vm ensure: g-1: the guest serves port 9.\n",
    )
  assert guest == vm_ensure.Guest("g-1", "app")
  assert progress == "booting\nloom vm ensure: g-1: the guest serves port 9."

  // The daemon line is found the same way.
  let assert vm_ensure.NeedsDaemon(_) =
    vm_ensure.answer(75, "daemon=required\nloomd: late line\n")

  // An earlier line that parses is not preferred to a later one.
  let assert vm_ensure.Ready(later, _) =
    vm_ensure.answer(0, "executor=a-1 workspace=a\nexecutor=b-2 workspace=b\n")
  assert later == vm_ensure.Guest("b-2", "b")
}

// --- what the launch says --------------------------------------------------------------

fn collecting(events: Subject(String)) -> fn(String) -> Nil {
  fn(text) { process.send(events, text) }
}

pub fn the_launch_says_what_it_does_before_it_does_it_test() {
  let script = script([guest_answer], Ok(Nil))
  let reports = process.new_subject()
  let assert Ok(_) =
    vm_ensure.ensure(
      options("/src/proj", ""),
      flags: [],
      run: script.runner,
      start_daemon: script.start_daemon,
      report: collecting(reports),
    )
  let assert Ok(first) = process.receive(reports, 0)
  assert string.contains(first, "/src/proj")
  assert string.contains(first, "can take minutes")
}

pub fn a_missing_daemon_prints_one_launch_line_not_the_refusal_test() {
  let script = script([daemon_answer, guest_answer], Ok(Nil))
  let reports = process.new_subject()
  let assert Ok(_) =
    vm_ensure.ensure(
      options("/src/proj", ""),
      flags: [],
      run: script.runner,
      start_daemon: script.start_daemon,
      report: collecting(reports),
    )
  let said = drained(reports)
  assert list.contains(said, "starting the daemon so the guest can join")
  assert !list.any(said, string.contains(_, "starts none"))
  assert !list.any(said, string.contains(_, "join needs the daemon"))
}

// --- the terminal wrapper ---------------------------------------------------------------

pub fn the_captured_form_runs_the_server_itself_test() {
  assert vm_ensure.command("/bin/loomd", ["vm", "ensure"], vm_ensure.Captured)
    == #("/bin/loomd", ["vm", "ensure"])
}

pub fn the_terminal_form_passes_the_server_as_parameters_test() {
  let #(program, words) =
    vm_ensure.command("/bin/loomd", ["vm", "ensure"], vm_ensure.OnTerminal)
  assert program == "/bin/sh"
  let assert ["-c", script, "sh", "/bin/loomd", "vm", "ensure"] = words
  assert string.contains(script, "/dev/tty")
  assert string.contains(script, "exec \"$@\"")
}

pub fn the_terminal_form_still_answers_with_or_without_a_terminal_test() {
  // A stand-in server writes progress on standard error and its answer on
  // standard output. Whether this host can open a terminal device or not, the
  // status is the server's and the answer is the last line captured.
  let directory = scratch_root() <> "/vm_launch_test_" <> unique()
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
  let assert Ok(base) = host.absolute_path(directory)
  let server = base <> "/server.sh"
  let assert Ok(Nil) =
    simplifile.write(
      server,
      "#!/bin/sh\necho progress >&2\necho executor=g-1 workspace=app\nexit 0\n",
    )
  let assert Ok(Nil) = simplifile.set_permissions_octal(server, 0o755)

  let #(program, words) = vm_ensure.command(server, [], vm_ensure.OnTerminal)
  let assert Ok(captured) = host.run_captured(program, words, 20_000)
  assert captured.status == 0
  let assert vm_ensure.Ready(guest, _) =
    vm_ensure.answer(captured.status, captured.output)
  assert guest == vm_ensure.Guest("g-1", "app")
  let _ = simplifile.delete_all([directory])
  Nil
}
