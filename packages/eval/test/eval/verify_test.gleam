//// The jailed verifier's proofs: the hidden files reach only the graded
//// copy, the copy is the only place a verifier can write, the network is
//// off, the wall is a zero grade, the reward file outranks the exit status,
//// and the side information is bounded and scrubbed.
////
//// Linux selects nineteen real jailed proofs. Darwin selects the production
//// refusal instead: its missing process-lifecycle guarantee prevents a verifier
//// from opening, so this suite claims no real verifier proof on that platform.
//// Pure checks run everywhere. The generator prints the selected coverage.
////
//// Every Linux proof opens a real helper pool under the operator's home.
//// Production demand is asked for first; only a cgroup v2 shortfall permits
//// best-effort enforcement, retaining the required filesystem and network layers.

import broker/exec
import client/catalog
import client/codemode
import client/evolution/rollout
import client/internal/ffi_os
import client/jobs
import client/memory_config
import client/retryconf
import client/schedule
import client/secrets
import client/serve
import client/workspace_policy
import core/clock
import eval/task.{type Task, AllRewardsOne, AllRewardsPositive, Inline, Program}
import eval/verify.{type Jail}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/operation
import machine/strand
import provider/adapter/anthropic
import provider/http
import provider/model
import provider/secret
import simplifile

// --- pure ------------------------------------------------------------------

pub fn scoring_policies_test() {
  assert verify.reduce(AllRewardsOne, [#("a", 1.0), #("b", 1.0)]) == 1.0
  assert verify.reduce(AllRewardsOne, [#("a", 1.0), #("b", 0.5)]) == 0.0
  assert verify.reduce(AllRewardsPositive, [#("a", 0.5), #("b", 1.0)]) == 1.0
  assert verify.reduce(AllRewardsPositive, [#("a", 0.0)]) == 0.0
  assert verify.reduce(AllRewardsOne, []) == 1.0
}

pub fn parse_rewards_is_total_test() {
  assert verify.parse_rewards("{\"a\": 1, \"b\": 0.5}")
    == Ok([#("a", 1.0), #("b", 0.5)])
  assert verify.parse_rewards("[1]") == Error("is not an object")
  assert verify.parse_rewards("{\"a\": \"x\"}")
    == Error("field \"a\" is not a number")
  assert verify.parse_rewards("not json") == Error("is not valid JSON")
  assert verify.parse_rewards("") == Error("is not valid JSON")
}

pub fn open_jail_refuses_a_relative_root_test() {
  let assert Error(reason) = verify.open_jail(settings("/nowhere"), "relative")
  assert string.contains(reason, "absolute")
}

// --- jailed ---------------------------------------------------------------

/// Selects real verifier proofs on Linux and the production refusal on Darwin.
///
/// ## Examples
///
/// `scripts/test.sh eval --match eval@verify_test:jailed_verifier_proofs_test_`.
pub fn jailed_verifier_proofs_test_() -> List(#(String, fn() -> Nil)) {
  let #(platform, _) = ffi_os.platform()
  case platform {
    "linux" -> {
      io.println_error("NOTE verifier coverage: linux real proofs assigned=19")
      [
        #(
          "verifier_files_absent_from_workspace_test",
          verifier_files_absent_from_workspace,
        ),
        #(
          "verifier_cannot_write_outside_verify_dir_test",
          verifier_cannot_write_outside_verify_dir,
        ),
        #("verifier_network_is_off_test", verifier_network_is_off),
        #(
          "verifier_timeout_is_zero_reward_test",
          verifier_timeout_is_zero_reward,
        ),
        #("reward_json_gates_the_pass_test", reward_json_gates_the_pass),
        #(
          "exit_status_grades_when_no_reward_file_test",
          exit_status_grades_when_no_reward_file,
        ),
        #(
          "side_info_is_bounded_and_scrubbed_test",
          side_info_is_bounded_and_scrubbed,
        ),
        #(
          "failing_tests_are_named_in_side_info_test",
          failing_tests_are_named_in_side_info,
        ),
        #(
          "grade_refuses_an_out_dir_outside_the_root_test",
          grade_refuses_an_out_dir_outside_the_root,
        ),
        #(
          "planted_reward_json_is_discarded_test",
          planted_reward_json_is_discarded,
        ),
        #(
          "runner_from_the_workspace_is_refused_unless_staged_test",
          runner_from_the_workspace_is_refused_unless_staged,
        ),
        #(
          "agents_build_is_discarded_and_the_pristine_one_restored_test",
          agents_build_is_discarded_and_the_pristine_one_restored,
        ),
        #(
          "hidden_files_never_follow_the_agents_symlinks_test",
          hidden_files_never_follow_the_agents_symlinks,
        ),
        #(
          "symlinked_logs_disclose_nothing_test",
          symlinked_logs_disclose_nothing,
        ),
        #("fifos_are_refused_not_read_test", fifos_are_refused_not_read),
        #("dotdot_hidden_path_is_refused_test", dotdot_hidden_path_is_refused),
        #(
          "a_pass_needs_exit_ids_and_reward_map_test",
          a_pass_needs_exit_ids_and_reward_map,
        ),
        #(
          "oversize_files_are_dropped_within_the_caps_test",
          oversize_files_are_dropped_within_the_caps,
        ),
        #(
          "a_timeout_over_the_cap_is_a_zero_grade_not_infra_test",
          a_timeout_over_the_cap_is_a_zero_grade_not_infra,
        ),
      ]
    }
    "darwin" -> {
      io.println_error(
        "NOTE verifier coverage: darwin real proofs assigned=0; production refusal assigned=1; Linux proof coverage is not claimed",
      )
      [
        #(
          "darwin_refuses_unenforceable_verifier",
          darwin_refuses_unenforceable_verifier,
        ),
      ]
    }
    other -> panic as { "unsupported verifier proof platform: " <> other }
  }
}

fn verifier_files_absent_from_workspace() {
  use jail, root <- with_jail("files-absent")
  let workspace = root <> "/frozen"
  write(workspace <> "/README.md", "agent's tree\n")
  let graded =
    verify.grade(
      program_task(
        ["bash", "-c", "test -f hidden/secret_test.txt"],
        [#("hidden/secret_test.txt", "the hidden check\n")],
        60_000,
        AllRewardsOne,
      ),
      workspace,
      root <> "/out",
      jail,
      None,
    )

  // The verifier saw its file inside the copy, and nowhere else.
  let assert Ok(rollout.Grade(reward: 1.0, ..)) = graded
  assert simplifile.is_file(root <> "/out/verify/hidden/secret_test.txt")
    == Ok(True)
  assert simplifile.is_file(workspace <> "/hidden/secret_test.txt") == Ok(False)
  assert simplifile.is_file(root <> "/out/verify/README.md") == Ok(True)
}

fn verifier_cannot_write_outside_verify_dir() {
  use jail, root <- with_jail("no-escape")
  let workspace = root <> "/frozen"
  let home = root <> "/home"
  write(workspace <> "/README.md", "agent's tree\n")
  let assert Ok(Nil) = simplifile.create_directory_all(home)
  let graded =
    verify.grade(
      program_task(
        [
          "bash",
          "-c",
          "touch "
            <> workspace
            <> "/escaped; echo frozen=$?; "
            <> "touch \"$HOME\"/escaped; echo home=$?; "
            <> "touch inside; echo inside=$?",
        ],
        [],
        60_000,
        AllRewardsOne,
      ),
      workspace,
      root <> "/out",
      jail,
      None,
    )

  // The frozen tree and the home are untouched; the copy took the write.
  let assert Ok(rollout.Grade(side_info:, ..)) = graded
  assert simplifile.is_file(workspace <> "/escaped") == Ok(False)
  assert simplifile.is_file(home <> "/escaped") == Ok(False)
  assert simplifile.is_file(root <> "/out/verify/inside") == Ok(True)
  assert string.contains(side_info, "frozen=1")
  assert string.contains(side_info, "home=1")
  assert string.contains(side_info, "inside=0")
}

fn verifier_network_is_off() {
  use jail, root <- with_jail("network-off")
  let workspace = root <> "/frozen"
  write(workspace <> "/README.md", "agent's tree\n")

  // The program exits 0 only when opening a TCP socket is refused, so a
  // reward of 1 is the proof and anything else names what got through.
  let graded =
    verify.grade(
      program_task(
        [
          "python3",
          "-c",
          "import socket, sys\n"
            <> "try:\n"
            <> "    socket.socket(socket.AF_INET, socket.SOCK_STREAM).connect(('127.0.0.1', 9))\n"
            <> "    print('connected'); sys.exit(1)\n"
            <> "except OSError as e:\n"
            <> "    print('refused:', e); sys.exit(0)\n",
        ],
        [],
        60_000,
        AllRewardsOne,
      ),
      workspace,
      root <> "/out",
      jail,
      None,
    )
  let assert Ok(rollout.Grade(reward: 1.0, side_info:, ..)) = graded
  assert string.contains(side_info, "refused:")

  // Refused at the socket call, not at the connection: a host with the
  // network on would say "Connection refused" for the discard port.
  assert string.contains(side_info, "Operation not permitted")
  assert !string.contains(side_info, "Connection refused")
}

fn verifier_timeout_is_zero_reward() {
  use jail, root <- with_jail("timeout")
  let workspace = root <> "/frozen"
  write(workspace <> "/README.md", "agent's tree\n")
  let graded =
    verify.grade(
      program_task(["sleep", "30"], [], 1000, AllRewardsOne),
      workspace,
      root <> "/out",
      jail,
      None,
    )

  // Too slow is a failed grade with the reason, never an infrastructure
  // error, and it carries no invented exit status.
  let assert Ok(rollout.Grade(reward: 0.0, side_info:, verifier:, ..)) = graded
  assert string.contains(side_info, "verifier timed out")
  let assert rollout.ProgramRun(exit_status:, wall_ms:, ..) = verifier
  assert exit_status == verify.no_exit_status
  assert wall_ms >= 1000 && wall_ms < 30_000
}

fn reward_json_gates_the_pass() {
  use jail, root <- with_jail("reward-json")
  let workspace = root <> "/frozen"
  write(workspace <> "/README.md", "agent's tree\n")
  let graded = fn(script, out) {
    verify.grade(
      program_task(["bash", "-c", script], [], 60_000, AllRewardsOne),
      workspace,
      root <> "/" <> out,
      jail,
      None,
    )
  }

  // A reward map of ones with a clean exit passes and its entries become
  // named scores; the same map with a failing exit does not pass; a map with
  // a zero fails a clean exit.
  let assert Ok(rollout.Grade(reward: 1.0, scores:, ..)) =
    graded(
      "mkdir -p logs/verifier; echo '{\"build\": 1, \"tests\": 1.0}' > logs/verifier/reward.json; exit 0",
      "ones",
    )
  assert list.key_find(scores, "build") == Ok(1.0)
  assert list.key_find(scores, "tests") == Ok(1.0)
  let assert Ok(rollout.Grade(reward: 0.0, side_info:, ..)) =
    graded(
      "mkdir -p logs/verifier; echo '{\"build\": 1}' > logs/verifier/reward.json; exit 3",
      "ones-failing",
    )
  assert string.contains(side_info, "exit status 3")
  let assert Ok(rollout.Grade(reward: 0.0, ..)) =
    graded(
      "mkdir -p logs/verifier; echo '{\"tests\": 0}' > logs/verifier/reward.json; exit 0",
      "zero",
    )

  // A reward file that is not a map is a zero grade that says so, and the
  // file itself is copied out beside the streams.
  let assert Ok(rollout.Grade(reward: 0.0, side_info:, ..)) =
    graded(
      "mkdir -p logs/verifier; echo 'nope' > logs/verifier/reward.json; exit 0",
      "bad",
    )
  assert string.contains(side_info, "reward.json is not valid JSON")
  assert simplifile.is_file(root <> "/bad/verifier/reward.json") == Ok(True)
  assert simplifile.is_file(root <> "/bad/verifier/stdout") == Ok(True)
}

fn exit_status_grades_when_no_reward_file() {
  use jail, root <- with_jail("exit-status")
  let workspace = root <> "/frozen"
  write(workspace <> "/README.md", "agent's tree\n")
  let assert Ok(rollout.Grade(reward: 1.0, verifier:, ..)) =
    verify.grade(
      program_task(["true"], [], 60_000, AllRewardsOne),
      workspace,
      root <> "/pass",
      jail,
      None,
    )
  let assert rollout.ProgramRun(exit_status: 0, ..) = verifier
  let assert Ok(rollout.Grade(reward: 0.0, side_info:, verifier:, ..)) =
    verify.grade(
      program_task(["bash", "-c", "exit 7"], [], 60_000, AllRewardsOne),
      workspace,
      root <> "/fail",
      jail,
      None,
    )
  let assert rollout.ProgramRun(exit_status: 7, ..) = verifier
  assert string.contains(side_info, "exit status 7")
}

fn side_info_is_bounded_and_scrubbed() {
  use jail, root <- with_jail("side-info")
  let workspace = root <> "/frozen"
  write(workspace <> "/README.md", "agent's tree\n")
  let graded =
    verify.grade(
      program_task(
        [
          "bash",
          "-c",
          "for i in $(seq 1 1500); do echo line-$i- xxxx xxxx; done; "
            <> "echo token sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789; "
            <> "echo '  a_test: last_test...*failed*'; exit 1",
        ],
        [],
        60_000,
        AllRewardsOne,
      ),
      workspace,
      root <> "/out",
      jail,
      None,
    )

  // Bounded by bytes, the end of the output kept, and the credential gone.
  let assert Ok(rollout.Grade(side_info:, ..)) = graded
  assert string.byte_size(side_info) <= verify.max_side_info_bytes
  assert string.contains(side_info, "line-1500-")
  assert !string.contains(side_info, "line-1-")
  assert !string.contains(side_info, "sk-ant-api03-abcdefghijklmnopqrstuvwxyz")
  assert string.contains(side_info, "<redacted>")
}

fn failing_tests_are_named_in_side_info() {
  use jail, root <- with_jail("test-names")
  let workspace = root <> "/frozen"
  write(workspace <> "/README.md", "agent's tree\n")
  let output =
    "  pkg@m_test: alpha_test...[0.001 s] ok\n"
    <> "  pkg@m_test: beta_test...*failed*\n"
    <> "  Failed: 1.  Skipped: 0.  Passed: 1.\n"
  let graded =
    verify.grade(
      task.Task(
        ..program_task(["true"], [], 60_000, AllRewardsOne),
        verifier: Program(
          files: [#("output.txt", output)],
          argv: ["bash", "-c", "cat output.txt; exit 1"],
          fail_to_pass: ["pkg@m_test.beta_test"],
          pass_to_pass: ["pkg@m_test.alpha_test", "pkg@m_test.gamma_test"],
          timeout_ms: 60_000,
          scoring: AllRewardsOne,
        ),
      ),
      workspace,
      root <> "/out",
      jail,
      None,
    )

  // The two test sets become fractions, and the ids that did not pass —
  // including one the run never named — are listed by name.
  let assert Ok(rollout.Grade(reward: 0.0, scores:, side_info:, ..)) = graded
  assert list.key_find(scores, "f2p") == Ok(0.0)
  assert list.key_find(scores, "p2p") == Ok(0.5)
  assert string.contains(
    side_info,
    "fail_to_pass not passing: pkg@m_test.beta_test",
  )
  assert string.contains(
    side_info,
    "pass_to_pass not passing: pkg@m_test.gamma_test",
  )
}

fn grade_refuses_an_out_dir_outside_the_root() {
  use jail, root <- with_jail("outside-root")
  let workspace = root <> "/frozen"
  write(workspace <> "/README.md", "agent's tree\n")
  let assert Error(reason) =
    verify.grade(
      program_task(["true"], [], 60_000, AllRewardsOne),
      workspace,
      home() <> "/evalwt/verify-test-elsewhere",
      jail,
      None,
    )
  assert string.contains(reason, "is not under the jail root")
}

// --- the agent's tree is adversarial -----------------------------------------

fn planted_reward_json_is_discarded() {
  use jail, root <- with_jail("planted-reward")
  let workspace = root <> "/frozen"
  write(workspace <> "/logs/verifier/reward.json", "{\"tests\": 1}\n")
  let graded =
    verify.grade(
      program_task(
        ["bash", "-c", "echo real tests FAILED; exit 1"],
        [],
        60_000,
        AllRewardsOne,
      ),
      workspace,
      root <> "/out",
      jail,
      None,
    )

  // The agent's logs never reach the copy, so the planted map is not read,
  // the failing exit decides, and the drop is on the record.
  let assert Ok(rollout.Grade(reward: 0.0, scores:, side_info:, ..)) = graded
  assert list.key_find(scores, "tests") == Error(Nil)
  assert string.contains(side_info, "exit status 1")
  assert string.contains(side_info, "dropped from the copy")
  assert simplifile.is_file(workspace <> "/logs/verifier/reward.json")
    == Ok(True)
}

fn runner_from_the_workspace_is_refused_unless_staged() {
  use jail, root <- with_jail("agent-runner")
  let workspace = root <> "/frozen"
  write(workspace <> "/scripts/test.sh", "echo '  m: beta_test...ok'; exit 0\n")
  let refused =
    verify.grade(
      program_task(["bash", "scripts/test.sh", "m"], [], 60_000, AllRewardsOne),
      workspace,
      root <> "/refused",
      jail,
      None,
    )
  let assert Error(reason) = refused
  assert string.contains(reason, "scripts/test.sh")
  assert string.contains(reason, "the agent owned")

  // A `-c` script naming the path is read the same way, and `./` is the same
  // path.
  let assert Error(_) =
    verify.grade(
      program_task(
        ["bash", "-c", "./scripts/test.sh m && exit 0"],
        [],
        60_000,
        AllRewardsOne,
      ),
      workspace,
      root <> "/refused-c",
      jail,
      None,
    )

  // The same argv with the runner among the hidden files runs the task's
  // runner, written over the agent's: the agent's exits 1, the task's 0.
  write(workspace <> "/scripts/test.sh", "exit 1\n")
  let assert Ok(rollout.Grade(reward: 1.0, ..)) =
    verify.grade(
      program_task(
        ["bash", "scripts/test.sh", "m"],
        [
          #("scripts/test.sh", "test \"$(cat marker)\" = task\n"),
          #("marker", "task\n"),
        ],
        60_000,
        AllRewardsOne,
      ),
      workspace,
      root <> "/staged",
      jail,
      None,
    )
  assert simplifile.read(root <> "/staged/verify/scripts/test.sh")
    == Ok("test \"$(cat marker)\" = task\n")
}

fn agents_build_is_discarded_and_the_pristine_one_restored() {
  use jail, root <- with_jail("pristine-build")
  let workspace = root <> "/frozen"
  let pristine = root <> "/pristine"
  write(workspace <> "/README.md", "agent's tree\n")
  write(workspace <> "/build/dev/erlang/eunit/ebin/eunit.beam", "forged\n")
  write(workspace <> "/packages/p/build/forged.txt", "forged\n")
  write(pristine <> "/build/dev/real.txt", "real\n")
  write(pristine <> "/packages/p/build/real.txt", "real\n")
  let graded =
    verify.grade(
      program_task(
        [
          "bash",
          "-c",
          "test ! -e build/dev/erlang && test -f build/dev/real.txt"
            <> " && test ! -e packages/p/build/forged.txt"
            <> " && test -f packages/p/build/real.txt",
        ],
        [],
        60_000,
        AllRewardsOne,
      ),
      workspace,
      root <> "/out",
      jail,
      Some(pristine),
    )

  // The program saw only the host's build at both depths.
  let assert Ok(rollout.Grade(reward: 1.0, side_info:, ..)) = graded
  assert string.contains(side_info, "2 build/logs directories")
}

fn hidden_files_never_follow_the_agents_symlinks() {
  use jail, root <- with_jail("symlink-stage")
  let workspace = root <> "/frozen"
  let victim_dir = root <> "/sibling-live-tree"
  let victim_file = root <> "/victim.txt"
  write(workspace <> "/README.md", "agent's tree\n")
  write(victim_dir <> "/keep.txt", "keep\n")
  write(victim_file, "ORIGINAL\n")
  let assert Ok(Nil) =
    simplifile.create_symlink(to: victim_dir, from: workspace <> "/test")
  let assert Ok(Nil) =
    simplifile.create_symlink(to: victim_file, from: workspace <> "/notes.txt")
  let graded =
    verify.grade(
      program_task(
        ["bash", "-c", "test -f test/m_test.gleam && test -f notes.txt"],
        [
          #("test/m_test.gleam", "HIDDEN TEST BODY\n"),
          #("notes.txt", "HIDDEN2\n"),
        ],
        60_000,
        AllRewardsOne,
      ),
      workspace,
      root <> "/out",
      jail,
      None,
    )

  // The hidden bytes landed in the copy as regular files; the link targets
  // on the host are untouched and the links themselves never reached the
  // copy.
  let assert Ok(rollout.Grade(reward: 1.0, side_info:, ..)) = graded
  assert simplifile.read(root <> "/out/verify/test/m_test.gleam")
    == Ok("HIDDEN TEST BODY\n")
  assert simplifile.is_symlink(root <> "/out/verify/test") == Ok(False)
  assert simplifile.is_file(victim_dir <> "/m_test.gleam") == Ok(False)
  assert simplifile.read(victim_file) == Ok("ORIGINAL\n")
  assert string.contains(side_info, "2 symlinks")
}

fn symlinked_logs_disclose_nothing() {
  use jail, root <- with_jail("symlink-logs")
  let workspace = root <> "/frozen"
  let secret = root <> "/host-secret"
  write(workspace <> "/README.md", "agent's tree\n")
  write(secret <> "/id_key", "HOSTSECRET-CONTENTS\n")
  write(secret <> "/stdout.tail", "HOSTSECRET-STDOUT\n")
  write(secret <> "/reward.json", "{\"tests\": 1}\n")
  let assert Ok(Nil) = simplifile.create_directory_all(workspace <> "/logs")
  let assert Ok(Nil) =
    simplifile.create_symlink(to: secret, from: workspace <> "/logs/verifier")
  let graded =
    verify.grade(
      program_task(
        ["bash", "-c", "echo ran; exit 1"],
        [],
        60_000,
        AllRewardsOne,
      ),
      workspace,
      root <> "/out",
      jail,
      None,
    )

  // The run wrote its own logs in a fresh directory, and nothing of the
  // host's reached the grade or the artifacts.
  let assert Ok(rollout.Grade(reward: 0.0, scores:, side_info:, ..)) = graded
  assert string.contains(side_info, "ran")
  assert !string.contains(side_info, "HOSTSECRET")
  assert list.key_find(scores, "tests") == Error(Nil)
  assert simplifile.is_file(root <> "/out/verifier/id_key") == Ok(False)
  assert simplifile.read(root <> "/out/verifier/stdout") == Ok("ran\n")
  assert simplifile.is_symlink(root <> "/out/verify/logs/verifier") == Ok(False)
}

fn fifos_are_refused_not_read() {
  use jail, root <- with_jail("fifo")
  let workspace = root <> "/frozen"
  write(workspace <> "/README.md", "agent's tree\n")
  let assert Ok(Nil) = simplifile.create_directory_all(workspace <> "/hidden")
  let assert Ok(secrets.Capture(status: 0, ..)) =
    secrets.host_runner()(["mkfifo", workspace <> "/hidden/pipe.txt"], 10_000)
  let graded =
    verify.grade(
      program_task(
        [
          "bash",
          "-c",
          "test -f hidden/pipe.txt && mkdir -p logs/verifier && mkfifo logs/verifier/reward.json && exit 0",
        ],
        [#("hidden/pipe.txt", "regular now\n")],
        60_000,
        AllRewardsOne,
      ),
      workspace,
      root <> "/out",
      jail,
      None,
    )

  // The fifo in the agent's tree was dropped and the hidden file written as
  // a regular file; the fifo the program left as its reward was refused
  // without being opened, so the grade returned instead of hanging.
  let assert Ok(rollout.Grade(reward: 0.0, side_info:, ..)) = graded
  assert simplifile.read(root <> "/out/verify/hidden/pipe.txt")
    == Ok("regular now\n")
  assert string.contains(side_info, "reward.json is not a regular file")
  assert string.contains(side_info, "1 special files")
}

fn dotdot_hidden_path_is_refused() {
  use jail, root <- with_jail("dotdot")
  let workspace = root <> "/frozen"
  write(workspace <> "/README.md", "agent's tree\n")
  let assert Error(reason) =
    verify.grade(
      task.Task(
        ..program_task(["true"], [], 60_000, AllRewardsOne),
        verifier: Program(
          files: [#("../escape.txt", "x\n")],
          argv: ["true"],
          fail_to_pass: [],
          pass_to_pass: [],
          timeout_ms: 60_000,
          scoring: AllRewardsOne,
        ),
      ),
      workspace,
      root <> "/out",
      jail,
      None,
    )
  assert string.contains(reason, "unsafe hidden file path: ../escape.txt")
  assert simplifile.is_file(root <> "/escape.txt") == Ok(False)
}

fn a_pass_needs_exit_ids_and_reward_map() {
  use jail, root <- with_jail("pass-rule")
  let workspace = root <> "/frozen"
  write(workspace <> "/README.md", "agent's tree\n")
  let passing_output =
    "  pkg@m_test: alpha_test...ok\n  pkg@m_test: beta_test...ok\n"
  let graded = fn(script, out) {
    verify.grade(
      task.Task(
        ..program_task(["true"], [], 60_000, AllRewardsOne),
        verifier: Program(
          files: [#("output.txt", passing_output)],
          argv: ["bash", "-c", script],
          fail_to_pass: ["pkg@m_test.alpha_test"],
          pass_to_pass: ["pkg@m_test.beta_test"],
          timeout_ms: 60_000,
          scoring: AllRewardsOne,
        ),
      ),
      workspace,
      root <> "/" <> out,
      jail,
      None,
    )
  }

  // Exit 0 with every id passing and no map is the pass.
  let assert Ok(rollout.Grade(reward: 1.0, ..)) =
    graded("cat output.txt; exit 0", "pass")

  // Exit 0 alone is not: a forged exit with no test lines fails on the ids.
  let assert Ok(rollout.Grade(reward: 0.0, side_info:, ..)) =
    graded("echo nothing; exit 0", "ids")
  assert string.contains(
    side_info,
    "fail_to_pass not passing: pkg@m_test.alpha_test",
  )

  // Passing ids with a failing exit are not either.
  let assert Ok(rollout.Grade(reward: 0.0, side_info:, ..)) =
    graded("cat output.txt; exit 2", "exit")
  assert string.contains(side_info, "exit status 2")

  // And a reward map that fails the policy fails the run however the tests
  // went.
  let assert Ok(rollout.Grade(reward: 0.0, side_info:, ..)) =
    graded(
      "cat output.txt; mkdir -p logs/verifier; echo '{\"tests\": 0.5}' > logs/verifier/reward.json; exit 0",
      "map",
    )
  assert string.contains(side_info, "reward.json fails all_rewards_one")
}

fn oversize_files_are_dropped_within_the_caps() {
  use jail, root <- with_jail("oversize")
  let workspace = root <> "/frozen"
  let bytes = fn(n) { string.repeat("x", n) }
  write(workspace <> "/a.txt", bytes(900))
  write(workspace <> "/b.txt", bytes(900))
  write(workspace <> "/big.txt", bytes(3000))
  write(workspace <> "/c.txt", bytes(900))
  write(workspace <> "/small.txt", bytes(10))
  let graded =
    verify.grade_within(
      program_task(
        [
          "bash",
          "-c",
          "test -f a.txt && test -f b.txt && test ! -e big.txt"
            <> " && test ! -e c.txt && test -f small.txt",
        ],
        [],
        60_000,
        AllRewardsOne,
      ),
      workspace,
      root <> "/out",
      jail,
      None,
      verify.Caps(file_bytes: 1000, copy_bytes: 2500),
    )

  // `big.txt` is over the file cap and `c.txt` would take the copy past
  // its cap; the walk is in name order, so `small.txt` still fits after.
  let assert Ok(rollout.Grade(reward: 1.0, side_info:, ..)) = graded
  assert string.contains(side_info, "2 oversize files")
  assert simplifile.is_file(workspace <> "/big.txt") == Ok(True)
}

fn a_timeout_over_the_cap_is_a_zero_grade_not_infra() {
  use jail, root <- with_jail("over-cap")
  let workspace = root <> "/frozen"
  write(workspace <> "/README.md", "agent's tree\n")
  let graded =
    verify.grade(
      task.Task(
        ..program_task(["true"], [], 60_000, AllRewardsOne),
        verifier: Program(
          files: [],
          argv: ["true"],
          fail_to_pass: [],
          pass_to_pass: [],
          timeout_ms: 700_000,
          scoring: AllRewardsOne,
        ),
      ),
      workspace,
      root <> "/out",
      jail,
      None,
    )

  // The task is malformed, so it is graded zero with the cap named and never
  // reaches the broker, whose refusal would have been an `Infra` row.
  let assert Ok(rollout.Grade(reward: 0.0, side_info:, verifier:, ..)) = graded
  assert string.contains(
    side_info,
    "timeout_ms 700000 exceeds the cap of 600000",
  )
  let assert rollout.ProgramRun(exit_status:, ..) = verifier
  assert exit_status == verify.no_exit_status
  assert simplifile.is_directory(root <> "/out/verify") == Ok(False)
}

pub fn command_paths_read_command_position_only_test() {
  assert verify.command_paths(["bash", "scripts/test.sh", "m", "--match", "x:"])
    == ["scripts/test.sh"]
  assert verify.command_paths(["./run_tests", "-v"]) == ["run_tests"]
  assert verify.command_paths(["bash", "-c", "test -f build/x && ./bin/go y"])
    == ["bin/go"]
  assert verify.command_paths([
      "bash",
      "-c",
      "cat a/b; python3 t/run.py | tee c/d",
    ])
    == ["t/run.py"]
  assert verify.command_paths(["bash", "-c", "touch $HOME/x; exit 0"]) == []
  assert verify.command_paths(["bash", "-o", "pipefail", "-c", "x/y"])
    == ["x/y"]
  assert verify.command_paths(["true"]) == []
  assert verify.command_paths([]) == []
}

pub fn foreign_skips_tolerate_only_cgroup_test() {
  assert verify.foreign_skips(["bwrap", "skip:cgroup-v2: no cgroup here"]) == []
  assert verify.foreign_skips(["skip:seccomp-net: off", "skip:cgroup-v2: x"])
    == ["skip:seccomp-net: off"]
  assert verify.foreign_skips([]) == []
}

// --- fixtures ---------------------------------------------------------------

/// Checks that production enforcement refuses a Darwin verifier jail.
///
/// ## Examples
///
/// The platform generators retain this check in focused Darwin module runs.
pub fn darwin_refuses_unenforceable_verifier() {
  let root =
    home()
    <> "/evalwt/darwin-refusal-"
    <> int.to_string(ffi_os.system_time_ms())
  let assert Ok(Nil) = simplifile.create_directory_all(root)
    as "the refusal fixture owns its root"
  let opened = verify.open_jail(settings(root), root)
  case opened {
    Error(reason) -> {
      let assert Ok(Nil) = simplifile.delete(root)
        as "the refused jail leaves a removable fixture"
      assert string.contains(reason, "skip:darwin-process-lifecycle")
        as "production refuses the missing process-lifecycle guarantee"
    }
    Ok(jail) -> {
      let retired = verify.close_jail(jail)
      let removed = simplifile.delete(root)
      assert retired == Ok(Nil)
        as "an unexpected jail is retired before failure"
      assert removed == Ok(Nil) as "an unexpected jail's fixture is removed"
      panic as "Darwin unexpectedly admitted the production verifier jail"
    }
  }
}

/// Opens a jail under a fresh root, runs the test, closes the jail and
/// removes the root. See the module doc for the demand ladder.
pub fn with_jail(name: String, run: fn(Jail, String) -> Nil) -> Nil {
  let root =
    home()
    <> "/evalwt/verify-test/"
    <> name
    <> "-"
    <> int.to_string(ffi_os.system_time_ms())
  let assert Ok(Nil) = simplifile.create_directory_all(root)

  case open(root, name) {
    Error(Nil) -> Nil
    Ok(jail) -> {
      run(jail, root)
      let assert Ok(Nil) = verify.close_jail(jail)
      case simplifile.delete(root) {
        Ok(Nil) -> Nil
        Error(e) ->
          io.println_error(
            "DELETE " <> root <> ": " <> simplifile.describe_error(e),
          )
      }

      Nil
    }
  }
}

/// The production demand first; best-effort only when the one skipped
/// layer is the cgroup v2 ceilings, which no filesystem or network proof
/// here depends on. Anything else is a skip naming the refusal.
fn open(root: String, name: String) -> Result(Jail, Nil) {
  case verify.open_jail(settings(root), root) {
    Ok(jail) -> Ok(jail)
    Error(reason) ->
      case only_cgroup_skipped(reason) {
        True -> {
          io.println_error(
            "NOTE "
            <> name
            <> ": cgroup-v2 ceilings (memory.max, pids.max) are not enforceable on this host; running under best-effort enforcement",
          )
          let eased = serve.Settings(..settings(root), demand: exec.BestEffort)

          verify.open_jail(eased, root)
          |> result_or_skip(name)
        }
        False -> result_or_skip(Error(reason), name)
      }
  }
}

/// Whether every `skip:` entry in a refusal is the cgroup v2 one: the
/// refusal joins every skipped layer, so a mere `contains` would also pass a
/// host missing its network or mount layer.
fn only_cgroup_skipped(reason: String) -> Bool {
  let skips = list.length(string.split(reason, "skip:")) - 1
  let cgroup = list.length(string.split(reason, "skip:cgroup-v2")) - 1

  skips > 0 && skips == cgroup
}

fn result_or_skip(
  opened: Result(Jail, String),
  name: String,
) -> Result(Jail, Nil) {
  case opened {
    Ok(jail) -> Ok(jail)
    Error(reason) -> {
      io.println_error("SKIP " <> name <> ": the jail refused: " <> reason)
      Error(Nil)
    }
  }
}

/// A task whose verifier is `argv` over `files`, on an empty inline tree.
pub fn program_task(
  argv: List(String),
  files: List(#(String, String)),
  timeout_ms: Int,
  scoring: task.Scoring,
) -> Task {
  task.mint(task.Task(
    id: "",
    name: "verify-test",
    prompt: "do the thing",
    workspace: Inline(files: []),
    verifier: Program(
      files:,
      argv:,
      fail_to_pass: [],
      pass_to_pass: [],
      timeout_ms:,
      scoring:,
    ),
    tags: [],
    provenance: task.HandWritten(author: "verify_test"),
  ))
}

fn write(path: String, content: String) -> Nil {
  let assert Ok(Nil) =
    simplifile.create_directory_all(string.join(
      list.reverse(list.drop(list.reverse(string.split(path, "/")), 1)),
      "/",
    ))
  let assert Ok(Nil) = simplifile.write(path, content)

  Nil
}

pub fn home() -> String {
  let assert Some(home) = workspace_policy.home_directory()
    as "the operator has a home directory"
  home
}

/// The settings a jail is opened from: the real helper beside the package,
/// the production demand, and a model nothing calls.
pub fn settings(root: String) -> serve.Settings {
  let assert Ok(here) = simplifile.current_directory() as "package directory"
  let catalogue =
    catalog.Catalog(
      models: [
        catalog.CatalogModel(
          name: "test",
          dialect: catalog.Anthropic,
          base_url: "https://unused.test",
          api_key_env: "UNUSED",
          model_id: "test",
          context_window: 100_000,
          max_output_tokens: 4096,
          thinking: model.ThinkingOff,
          pricing: None,
          vision: catalog.TextOnly,
          max_images: 8,
          cyber_access: None,
          service_tier: None,
        ),
      ],
      roles: [#(model.Main, ["test"])],
      profiles: [],
      mcp_servers: [],
      lsp_servers: [],
    )
  serve.Settings(
    evolution_role: serve.Source,
    pack: None,
    peer_directory: None,
    peer_defaults: None,
    remote_reach: None,
    deadline_tick_ms: None,
    depth_cap: None,
    metering: None,
    spawner: None,
    laptop: None,
    first_prompt: None,
    profile_desk: None,
    codemode_sockets: None,
    secrets: secret.env(),
    secret_failures: [],
    session_path: root <> "/session.db",
    domain_paths: None,
    bind_host: "invalid",
    bind_port: -1,
    token_path: root <> "/never-created.token",
    workspace: root <> "/work",
    base_policy: workspace_policy.base_policy(root <> "/work"),
    helper_path: here <> "/../sandbox/loom-exec",
    helper_pool_size: 2,
    session_id: "verify-test",
    demand: exec.PlatformEnforcement,
    gateway: catalog.gateway(
      catalogue,
      transport: http.httpc_transport(),
      secrets: secret.from_list([]),
      clock: clock.fixed(at: 0),
    ),
    catalog: catalogue,
    system: None,
    home: Some(root <> "/absent-home"),
    model: strand.ModelIdentity(provider: "test", model_id: "test"),
    context_window: 100_000,
    max_output_tokens: 4096,
    api: anthropic.api_name,
    compaction: operation.CompactionSettings(
      enabled: True,
      reserve_tokens: 16_384,
      keep_recent_tokens: 20_000,
    ),
    codemode_seed: root <> "/absent-seed",
    codemode_seams: codemode.WorkspaceOnly,
    rules: [],
    schedules: [],
    schedule_policy: schedule.ModelSchedulesOff,
    jobs_policy: jobs.default_policy,
    retry_policy: retryconf.default_policy,
    deactivated_tools: [],
    memory: memory_config.default_options(),
    tools: catalog.default_tools(),
    advisor: None,
    go_caches: None,
  )
}
