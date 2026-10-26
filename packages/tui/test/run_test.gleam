//// `loom run`'s pure half: the argument grammar, the verdict and exit
//// mapping, the jail label, the reduction of a captured cut to a verdict,
//// and the one JSON line.
////
//// The real-daemon falsifier (exit 0 with a posture label, `--timeout`
//// exiting 124 with the session stopped, a missing daemon exiting 3) needs
//// the shipped server and a scripted provider, so it lives in the client
//// package's `loom_run_test`, which already owns that fixture.

import core/clock
import core/codec
import core/ids
import core/json
import core/message
import core/register
import core/usage_evidence
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap as host_bootstrap
import machine/codec as machine_codec
import machine/operation
import machine/strand
import session_view/snapshot_view
import simplifile
import tui
import tui/run

fn parsed(arguments: List(String)) -> run.Request {
  let assert Ok(request) = run.parse(arguments)
    as "these arguments are a valid run"
  request
}

pub fn a_prompt_alone_is_a_complete_run_test() {
  let request = parsed(["-p", "hello"])

  assert request.prompt == "hello"
  assert request.timeout_ms == 3_600_000
  assert request.retention == run.StopAtExit
  assert request.model == None
}

pub fn every_flag_lands_where_it_belongs_test() {
  let request =
    parsed([
      "--prompt", "fix it", "--workspace", "/w", "--model", "m1", "--config",
      "/c.toml", "--timeout", "30", "--keep", "--json", "--server", "/s",
      "--state-dir", "/st", "--model-profile", "fast",
    ])

  assert request.prompt == "fix it"
  assert request.options.workspace == "/w"
  assert request.options.config == "/c.toml"
  assert request.options.server == "/s"
  assert request.options.state_directory == "/st"
  assert request.options.profile == "fast"
  assert request.model == Some("m1")
  assert request.timeout_ms == 30_000
  assert request.retention == run.KeepSession
}

pub fn bad_arguments_are_refused_before_any_work_test() {
  assert run.parse([]) == Error("run needs a prompt: loom run -p <text>")
  assert run.parse(["-p", "  "])
    == Error("run needs a prompt: loom run -p <text>")
  assert run.parse(["--keep"])
    == Error("run needs a prompt: loom run -p <text>")
  assert run.parse(["-p"]) == Error("missing value for -p")
  assert run.parse(["-p", "x", "--bogus", "1"])
    == Error("unknown run option --bogus")
  assert run.parse(["-p", "x", "--timeout", "0"])
    == Error("--timeout needs a whole number of seconds above zero")
  assert run.parse(["-p", "x", "--timeout", "soon"])
    == Error("--timeout needs a whole number of seconds above zero")
}

pub fn the_launcher_routes_run_and_hoists_daemon_options_test() {
  let assert Ok(plain) = tui.launch_run(["run", "-p", "hi"])
  assert plain.prompt == "hi"

  let assert Ok(hoisted) =
    tui.launch_run(["--state-dir", "/st", "run", "-p", "hi"])
  assert hoisted.options.state_directory == "/st"

  let assert Error(reason) = tui.launch_run(["run"])
  assert string.contains(reason, "usage: loom run -p <prompt>")
}

pub fn the_verdict_picks_the_exit_status_test() {
  assert run.exit_code(run.Completed) == 0
  assert run.exit_code(run.Failed("x")) == 1
  assert run.exit_code(run.Aborted) == 1
  assert run.exit_code(run.TimedOut) == 124
  assert run.exit_bad_arguments == 2
  assert run.outcome_word(run.Completed) == "completed"
  assert run.outcome_word(run.Failed("x")) == "failed"
  assert run.outcome_word(run.Aborted) == "aborted"
  assert run.outcome_word(run.TimedOut) == "timeout"
  assert run.exit_no_daemon == 3
}

pub fn the_helper_report_earns_a_jail_label_only_when_it_passed_test() {
  let all = "enforced (10):\n  + a\nRESULT: OK (skips are environmental)"
  let some =
    "enforced (10):\n  + a\nskipped (1) — NOT verified:\n  - b\nRESULT: OK"

  assert run.posture_of(0, all) == run.Enforced(10)
  assert run.posture_of(0, some) == run.Degraded(10, 1)
  assert run.posture_of(71, all) == run.Unverified("self-test exited 71")
  assert run.posture_of(0, "RESULT: NOT RUN")
    == run.Unverified("self-test exited 0")
  assert run.posture_of(0, "") == run.Unverified("self-test exited 0")
}

fn zero_usage() -> message.Usage {
  message.Usage(
    0,
    0,
    0,
    0,
    None,
    None,
    0,
    message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0),
    usage_evidence.none(),
  )
}

fn view(cells: List(snapshot_view.Cell)) -> snapshot_view.View {
  snapshot_view.View(
    strands: [],
    leaves: dict.new(),
    configurations: dict.new(),
    operations: dict.new(),
    usage: zero_usage(),
    settings: snapshot_view.RunSettings("one_at_a_time", "parallel", None),
    peers: [],
    cells:,
    preview: None,
    pending_inputs: Some([]),
    tools: None,
  )
}

fn result_cell(
  strand_name: String,
  result: operation.LastResult,
) -> snapshot_view.Cell {
  snapshot_view.Cell(
    register.StrandLastResult,
    strand_name,
    1,
    machine_codec.encode_last_result(result),
  )
}

fn run_result(outcome: operation.RunOutcome) -> operation.LastResult {
  let id = ids.mint_op(ids.generator(clock.fixed(3), 3)).0
  operation.RunLastResult(
    operation: id,
    leaf: None,
    outcome:,
    final_assistant: None,
  )
}

pub fn a_cut_without_a_main_result_says_nothing_yet_test() {
  assert run.settle(view([])) == None

  let elsewhere =
    result_cell(
      "sub:main/x",
      run_result(operation.RunCompleted(operation.CompletedByAssistant)),
    )
  assert run.settle(view([elsewhere])) == None
}

pub fn the_main_strands_run_result_is_the_verdict_test() {
  let completed =
    result_cell(
      "main",
      run_result(operation.RunCompleted(operation.CompletedByAssistant)),
    )
  let aborted = result_cell("main", run_result(operation.RunAborted))
  let failed =
    result_cell(
      "main",
      run_result(
        operation.RunFailed(operation.OperationError(
          "provider_error",
          "x",
          None,
        )),
      ),
    )

  assert run.settle(view([completed])) == Some(run.Completed)
  assert run.settle(view([aborted])) == Some(run.Aborted)
  assert run.settle(view([failed]))
    == Some(run.Failed("the run failed: provider_error"))
}

pub fn a_structural_result_is_not_a_verdict_test() {
  let id = ids.mint_op(ids.generator(clock.fixed(4), 4)).0
  let compaction =
    result_cell(
      "main",
      operation.CompactionLastResult(
        operation: id,
        leaf: None,
        outcome: operation.StructuralCompleted,
      ),
    )

  assert run.settle(view([compaction])) == None
}

fn report(verdict: run.Verdict) -> run.Report {
  run.Report(
    session_id: "s-1",
    state_dir: "/st",
    session_db: Some("/st/sessions/s-1.db"),
    verdict:,
    turns: 2,
    usage: Some(zero_usage()),
    elapsed_ms: 1234,
    posture: run.Degraded(10, 1),
    model: Some(strand.ModelIdentity("anthropic", "fixture")),
  )
}

pub fn the_report_is_one_json_object_with_a_mandatory_jail_label_test() {
  let line = run.render(report(run.Completed))

  assert !string.contains(line, "\n")
  let assert Ok(json.Object(fields)) = json.parse(line)
  assert list.key_find(fields, "session_id") == Ok(json.String("s-1"))
  assert list.key_find(fields, "outcome") == Ok(json.String("completed"))
  assert list.key_find(fields, "turns") == Ok(json.Int(2))
  assert list.key_find(fields, "elapsed_ms") == Ok(json.Int(1234))
  assert list.key_find(fields, "usage") == Ok(codec.encode_usage(zero_usage()))
  let assert Ok(json.Object(jail)) = list.key_find(fields, "jail")
  assert list.key_find(jail, "posture") == Ok(json.String("degraded"))
  let assert Ok(json.Object(model)) = list.key_find(fields, "model")
  assert list.key_find(model, "model_id") == Ok(json.String("fixture"))
}

pub fn an_unlabelled_jail_is_still_labelled_and_a_missing_db_is_left_out_test() {
  let bare =
    run.Report(
      ..report(run.TimedOut),
      session_db: None,
      usage: None,
      model: None,
      posture: run.Unverified("no loom-exec beside the server executable"),
    )
  let assert Ok(json.Object(fields)) = json.parse(run.render(bare))

  assert list.key_find(fields, "session_db") == Error(Nil)
  assert list.key_find(fields, "outcome") == Ok(json.String("timeout"))
  assert list.key_find(fields, "usage") == Ok(json.Null)
  let assert Ok(json.Object(jail)) = list.key_find(fields, "jail")
  assert list.key_find(jail, "posture") == Ok(json.String("unverified"))
}

pub fn a_failed_run_carries_its_reason_test() {
  let assert Ok(json.Object(fields)) =
    json.parse(run.render(report(run.Failed("the run failed: x"))))

  assert list.key_find(fields, "reason") == Ok(json.String("the run failed: x"))
}

pub fn a_missing_daemon_with_no_server_to_launch_exits_three_test() {
  let state =
    "build/run-no-daemon-"
    <> int.to_string(host_bootstrap.current_process_id())
    <> "-"
    <> int.to_string(host_bootstrap.system_time_ms())
  let request =
    parsed([
      "-p",
      "hi",
      "--server",
      "/nonexistent/loomd",
      "--state-dir",
      state,
      "--timeout",
      "5",
    ])

  let assert run.NoDaemon(reason) = run.conduct(request)
    as "no daemon exists and none can be launched"
  assert reason != ""
  assert run.exit_no_daemon == 3
  let _ = simplifile.delete(state)
}
