//// Tests for the miner's decisions: which pair of runs makes a regression
//// test, what the prompt may say, and the integration against the commit
//// the design was measured on.

import client/secrets
import eval/eunit_ids
import eval/mine.{FullMessage, Judged, Rejected, SubjectOnly}
import eval/task.{GitTree, MinedCommit, Program}
import gleam/io
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import simplifile

fn report(results: List(#(String, eunit_ids.Outcome))) -> eunit_ids.TestReport {
  eunit_ids.TestReport(results:, summary: None)
}

pub fn judge_splits_flipped_and_held_tests_test() {
  let before =
    report([
      #("m.a_test", eunit_ids.Failed),
      #("m.b_test", eunit_ids.Passed),
      #("m.c_test", eunit_ids.Passed),
    ])
  let after =
    report([
      #("m.a_test", eunit_ids.Passed),
      #("m.b_test", eunit_ids.Passed),
      #("m.c_test", eunit_ids.Passed),
    ])

  assert mine.judge(before, after)
    == Judged(fail_to_pass: ["m.a_test"], pass_to_pass: ["m.b_test", "m.c_test"])
}

pub fn feature_commit_is_culled_test() {
  let all_pass = report([#("m.a_test", eunit_ids.Passed)])
  let uncompiled = report([])
  let still_failing =
    report([#("m.a_test", eunit_ids.Failed), #("m.b_test", eunit_ids.Passed)])

  assert mine.judge(all_pass, all_pass)
    == Rejected("no fail-to-pass test: feature, not fix")
  assert mine.judge(uncompiled, all_pass)
    == Rejected("before run reported no tests (did not compile)")
  assert mine.judge(still_failing, still_failing)
    == Rejected("fix does not pass its own test")
  assert mine.judge(still_failing, uncompiled)
    == Rejected("after run reported no tests")
}

pub fn prompt_redacts_named_tests_test() {
  let files = ["packages/m/test/m/failure_test.gleam"]
  let ids = ["m@failure_test.keeps_the_run_alive_test"]

  assert mine.prompt("fix: x", "It was wrong.", ids, files)
    == #("fix: x\n\nIt was wrong.", FullMessage)
  assert mine.prompt("fix: x", "see keeps_the_run_alive_test", ids, files)
    == #("fix: x", SubjectOnly)
  assert mine.prompt("fix: x", "added failure_test.gleam cases", ids, files)
    == #("fix: x", SubjectOnly)
  assert mine.prompt("fix: x", "", ids, files) == #("fix: x", SubjectOnly)
  assert mine.prompt("fix: x", string.repeat("y", 9000), ids, files)
    == #("fix: x", SubjectOnly)
}

pub fn network_only_failures_are_the_offline_minus_online_test() {
  let offline =
    eunit_ids.parse(
      "  m: listens_test...*failed*\n  m: pure_test...ok\n  m: broken_test...*failed*\n",
    )
  let online =
    eunit_ids.parse(
      "  m: listens_test...ok\n  m: pure_test...ok\n  m: broken_test...*failed*\n",
    )
  assert mine.network_only_failures(offline, online) == ["m.listens_test"]
  assert mine.network_only_failures(online, online) == []
  assert mine.offline(["bash", "x"]) == ["unshare", "-rn", "--", "bash", "x"]
}

pub fn verifier_argv_chains_modules_test() {
  assert mine.verifier_argv("m", ["m@a_test"])
    == ["bash", "scripts/test.sh", "m", "--match", "m@a_test:"]

  let assert ["bash", "-c", script] =
    mine.verifier_argv("m", ["a_test", "b_test"])
  assert string.contains(script, "'a_test:' || status=1")
  assert string.contains(script, "'b_test:' || status=1")
  assert string.ends_with(script, "exit $status")
}

pub fn timeout_is_four_times_the_slower_run_bounded_test() {
  assert mine.timeout_for(1000, 2000) == 60_000
  assert mine.timeout_for(30_000, 20_000) == 120_000
  assert mine.timeout_for(10_000_000, 0) == task.max_timeout_ms
}

const probe_commit = "eccdddad0c6f92b4bd8812246d36753477eae4b1"

pub fn eccdddad0_reproduces_probe_test() {
  let repo = absolute_repo("../..")
  let present =
    secrets.host_runner()(
      ["git", "-C", repo, "cat-file", "-e", probe_commit <> "^{commit}"],
      30_000,
    )

  case present {
    Ok(secrets.Capture(status: 0, ..)) -> reproduce(repo)
    _ -> io.println_error("SKIP eccdddad0_reproduces_probe_test: commit absent")
  }
}

fn reproduce(repo: String) {
  let assert Ok(home) =
    simplifile.read("/proc/self/environ") |> result.replace_error(Nil)
    as "the process environment is readable on linux"
  let work = home_from(home) <> "/evalwt/mine-test"
  let config =
    mine.Config(
      name: "loom",
      repo:,
      work:,
      runner: secrets.host_runner(),
      run_timeout_ms: 900_000,
    )
  let assert Ok(found) = mine.candidates(config, probe_commit, ["machine"])
  let assert Ok(candidate) =
    list.find(found, fn(candidate) { candidate.commit == probe_commit })
  let mined = mine.mine(config, candidate)
  let assert Ok(minted) = mined.result

  let assert Program(fail_to_pass:, pass_to_pass:, files:, ..) = minted.verifier

  // The runner is always among the hidden files, so the verifier never runs
  // the agent's copy of it.
  assert list.key_find(files, "scripts/test.sh") |> result.is_ok
  assert fail_to_pass
    == [
      "machine@failure_test.threshold_summarizer_unresolved_keeps_the_run_alive_test",
      "machine@failure_test.threshold_summary_failure_past_the_ladder_keeps_the_run_alive_test",
    ]
  assert list.length(pass_to_pass) == 7
  let assert GitTree(commit:, ..) = minted.workspace
  assert string.starts_with(commit, "2b3c46a85")
  assert minted.provenance
    == MinedCommit(
      fix: probe_commit,
      parent: commit,
      subject: "machine: a summarizer being down should not end the run",
    )
}

fn home_from(environ: String) -> String {
  environ
  |> string.split("\u{0}")
  |> list.find_map(fn(entry) {
    case entry {
      "HOME=" <> home -> Ok(home)
      _ -> Error(Nil)
    }
  })
  |> result.unwrap("/root")
}

// A task records its repository, which the task format requires to be an
// absolute path.
fn absolute_repo(relative: String) -> String {
  let assert Ok(secrets.Capture(status: 0, output:)) =
    secrets.host_runner()(
      ["bash", "-c", "cd " <> relative <> " && pwd -P"],
      10_000,
    )
    as "the repository root is reachable from the package directory"

  string.trim(output)
}
