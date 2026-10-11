//// The executor loses its owner while an owner-bound capability call is in
//// flight, against the shipped daemon: an orchestrator and an executor, two
//// real `bin/loomd` processes that trust each other over TLS distribution
//// (issue #697, protocol-change/078).
////
//// `client/owner_codemode_test` proves that a call to an owner whose port is
//// dead answers `owner_unavailable` at once, but it does so in one VM, where a
//// dead port is a dead process. Across two nodes the owner's death looks
//// different. The executor's monitor on the owner port fires with
//// `noconnection` when the distribution link is lost, and nothing else about
//// the owner has changed. This fixture cuts that link while a call is waiting
//// on the owner, and reads what the program on the executor is told.
////
//// ## What it proves
////
//// `daemon_shipped_remote_owner_loss_test_`, one registered session and one
//// scripted model that also plays the child.
////
//// - The model submits one `code_mode` program. It runs on the executor,
////   spawns a detached child strand with `strand.spawn`, and joins it with
////   `strand.wait` for up to 100 seconds. The child's one tool call, a `bash`
////   command on the executor, takes 40 seconds, so the join is an owner-bound
////   capability call that cannot return on its own inside the test's bound.
////   The capability's budget on the executor is 120 seconds.
//// - The test waits until the child's command has started, then has a probe,
////   a third distribution node, tell the orchestrator to drop its connection to
////   the executor. Both daemons stay up.
//// - The program is told `owner_unavailable` and reports it, and the model
////   receives that report and answers, within 20 seconds of the cut. A call
////   that waited for its budget, or for the child, would miss that bound.
//// - Nothing ran twice. The provider saw one `code_mode` prompt and one brief,
////   in the order the script lists them, the model was handed one result for
////   the program, and the child's command appended `ran` and `done` to its log
////   once each. The child, which the cut also interrupted, finishes on the
////   executor and its run settles on the orchestrator.
//// - Stopping the session closes the executor's scope `closed` with
////   `all_retired`.
////
//// ## An owner that is up and silent
////
//// This fixture does not cover it. A silent owner is bounded by the call's own
//// budget, which is a constant of the executor (15 seconds for a record, 120
//// for a capability), and no daemon can be made to hold a reply back without a
//// hook in production code. Stopping the orchestrator's whole VM would not
//// test the budget either, since the executor would see the link time out
//// first. The in-VM `a_call_with_the_owner_gone_is_denied_at_once_test` covers
//// the dead port, and this fixture covers the severed link.
////
//// ## What it needs
////
//// Code mode on the executor needs a toolchain and the build seed
//// `make codemode-seed` prepares, and the jail needs platform enforcement.
//// Without enforcement the fixture declines as the other shipped fixtures do.
//// Without `gleam`, `erl` or the seed it prints a skip line naming what is
//// missing. The probe needs `erl` on `PATH`, which the daemons need too.
////
//// ## Running it
////
//// ```sh
//// make codemode-seed
//// make server-shipment
//// make sandbox && install -m 0755 packages/sandbox/loom-exec bin/loom-exec
//// export LOOM_BOOTSTRAP_E2E_SERVER=$PWD/bin/loomd
//// export LOOM_TEST_PROVIDER_KEY=loom-provider-fixture-key
//// bash scripts/test.sh client --match 'client@daemon_shipped_remote_owner_loss_test:'
//// ```
////
//// The fixture is the one `daemon_shipped_remote_test` documents, arranged for
//// a single pair by `support/remote_pair`, with the probe it describes.

import client/internal/ffi_os
import client/tui_e2e_test.{type EunitTest}
import core/json
import gleam/io
import gleam/list
import gleam/string
import session_view/strand_framing
import simplifile
import support/provider_http as provider
import support/remote_daemons
import support/remote_pair.{type Pair}
import support/tui_driver
import weft/poll

const skip_label = "shipped remote owner loss"

const prompt = "join the slow child"

const answer = "join was denied"

const child_text = "child finished"

// The side-effect file of the child's command. Each line is appended by the
// command itself, so a command that ran twice would leave `ran` twice.
const child_log = "child.log"

// The child's one tool call. The first line proves the command started; the
// last proves it ended; the forty seconds between are far longer than the
// bound the test puts on the denial.
const child_command = "echo ran >> child.log; sleep 40; echo done >> child.log"

// How long after the cut the model may take to answer. The capability's own
// budget is 120 seconds and the child runs 40, so a join that waited for either
// would miss it.
const denial_bound_ms = 20_000

/// Starts an orchestrator and an executor from the shipment, cuts the link
/// between them while a program's `strand.wait` is in flight, and reads what the
/// program was told.
///
/// ## Examples
///
/// `bash scripts/test.sh client --match 'client@daemon_shipped_remote_owner_loss_test:'`.
pub fn daemon_shipped_remote_owner_loss_test_() -> EunitTest {
  remote_pair.shipped(skip_label, [], gated)
}

// Code mode must have what it builds with. That is a property of the host and is
// measured here, before any daemon starts.
fn gated(prepared: Pair) -> Nil {
  case remote_pair.code_mode_seed() {
    Error(reason) ->
      io.println_error(
        "SKIP " <> skip_label <> ": code mode cannot build here: " <> reason,
      )
    Ok(seed) -> cut_while_joining(prepared, seed)
  }
}

// The program the model submits. The spawn is detached so that the end of the
// parent's run does not reap the child, which is still running when the model
// answers. A join that returns is a failure of this test, so it reports
// differently from the denial the test expects.
fn program() -> String {
  string.join(
    [
      "import cap/report",
      "import cap/strand",
      "import gleam/list",
      "import gleam/string",
      "",
      "pub fn main() -> report.Outcome {",
      "  let child =",
      "    strand.assignment(purpose: \"outlive the link\", brief: \"run the slow command\")",
      "    |> strand.detached",
      "  case strand.spawn(child) {",
      "    Ok(handle) -> join(handle)",
      "    Error(error) -> report.text(\"spawn refused: \" <> strand.error_text(error))",
      "  }",
      "}",
      "",
      "fn join(handle: strand.Handle) -> report.Outcome {",
      "  case strand.wait([handle], within_ms: 100_000) {",
      "    Ok(waited) ->",
      "      report.text(\"the join returned: \" <> string.join(list.map(waited, strand.waited_text), \"; \"))",
      "    Error(error) -> report.text(\"join denied: \" <> strand.error_text(error))",
      "  }",
      "}",
      "",
    ],
    "\n",
  )
}

// The conversation in the order the provider is asked: the parent's prompt, the
// child's brief, the parent's program result, which the cut brings forward, and
// only then the child's tool result, forty seconds after it started. A join
// that waited for the child would reverse the last two and the provider would
// refuse the script.
fn script() -> List(provider.Exchange) {
  [
    provider.ToolUseExchange(
      prompt,
      "program-call",
      "code_mode",
      json.Object([
        #("program", json.String(program())),
        #("within_ms", json.Int(180_000)),
      ]),
    ),
    provider.ComputedExchange(
      provider.AwaitPromptPrefix(strand_framing.brief_head("main")),
      fn(_seen) {
        provider.ReplyToolUse(
          "child-call",
          "bash",
          json.Object([#("command", json.String(child_command))]),
        )
      },
    ),
    provider.ComputedExchange(
      provider.AwaitToolResult("program-call"),
      fn(_seen) { provider.ReplyText(answer) },
    ),
    provider.ComputedExchange(provider.AwaitToolResult("child-call"), fn(_seen) {
      provider.ReplyText(child_text)
    }),
  ]
}

fn cut_while_joining(prepared: Pair, seed: String) -> Nil {
  let keys = remote_pair.provision(prepared)
  let probe = remote_pair.probe_identity(prepared, keys)
  let #(Nil, report) =
    provider.with_server_for(
      script(),
      provider.OnlySuccessful,
      remote_pair.callback_ms,
      fn(url) {
        remote_pair.configure_trusting(
          prepared,
          keys,
          remote_pair.Tables(
            models: remote_pair.models_without_glance(url),
            orchestrator: "",
            executor: "",
          ),
          [probe],
        )
        let opened =
          remote_pair.open_registered(
            prepared,
            ["--codemode-seed", seed],
            "e2e-owner-loss",
          )
        let terminal =
          remote_daemons.attach(opened.orchestrator, opened.session)
        remote_daemons.say(terminal, prompt)

        // The child's command has started, so the program's join is waiting on
        // the orchestrator for a child that has thirty-odd seconds to go.
        await_log(prepared, "ran\n")
        remote_pair.drop_link(prepared, keys, probe)
        let cut_at = ffi_os.system_time_ms()
        remote_daemons.await_answers(terminal, [answer], denial_bound_ms)
        let denied_after = ffi_os.system_time_ms() - cut_at
        io.println_error(
          "shipped remote owner loss: denied "
          <> string.inspect(denied_after)
          <> " ms after the cut",
        )
        assert denied_after < denial_bound_ms
        tui_driver.stop(terminal)

        // The child outlives the program and the cut, and finishes once.
        await_log(prepared, "ran\ndone\n")
        await_child_settled(prepared)
        remote_pair.stop_and_close(prepared, opened, 1)
        remote_pair.close_daemons([opened.orchestrator])
      },
    )
  let assert Ok(requests) = report
    as "the provider saw the parent, the child and nothing else, in order"
  assert_results(prepared, requests)
}

// Waits until the child's log holds exactly `expected`. Every line the command
// writes is a whole line, so a longer file is a command that ran again.
fn await_log(prepared: Pair, expected: String) -> Nil {
  let path = prepared.checkout <> "/" <> child_log
  let assert poll.Answered(Nil) =
    poll.until(within: 90_000, every: 100, attempt: fn() {
      case simplifile.read(path) {
        Ok(text) if text == expected -> poll.Done(Nil)
        Ok(text) ->
          case string.length(text) > string.length(expected) {
            True -> poll.Fail("the child's command ran again: " <> text)
            False -> poll.Retry
          }
        Error(_) -> poll.Retry
      }
    })
    as { "the child's log reaches " <> string.inspect(expected) }
  Nil
}

// The orchestrator logs a run's end when its last entry is committed, and the
// child's run ends after its tool result reaches the model and the model
// answers. Waiting for that line is how the test knows the child's last
// exchange has been served before the session is stopped.
fn await_child_settled(prepared: Pair) -> Nil {
  let log = prepared.orchestrator.paths.log
  let assert poll.Answered(Nil) =
    poll.until(within: 60_000, every: 100, attempt: fn() {
      case simplifile.read(log) {
        Ok(text) ->
          case
            list.any(string.split(text, "\n"), fn(line) {
              string.contains(line, "\"event\":\"operation.settled\"")
              && string.contains(line, "\"strand\":\"sub:main/")
            })
          {
            True -> poll.Done(Nil)
            False -> poll.Retry
          }
        Error(_) -> poll.Retry
      }
    })
    as "the child's run settles on the orchestrator"
  Nil
}

// What was run and what was told. The program's report names the denial, so the
// capability answered the satellite with the code it should. The provider saw
// one prompt for the program and one brief for the child, and the model was
// handed one result for each call.
fn assert_results(
  prepared: Pair,
  requests: List(provider.ObservedRequest),
) -> Nil {
  let program_result = remote_daemons.result_text(requests, "program-call")
  assert string.contains(program_result, "join denied: owner_unavailable")
  let prompts =
    list.filter(requests, fn(request) {
      case request.latest {
        provider.UserPrompt(text) -> text == prompt
        _ -> False
      }
    })
  assert list.length(prompts) == 1
  let briefs =
    list.filter(requests, fn(request) {
      case request.latest {
        provider.UserPrompt(text) ->
          string.starts_with(text, strand_framing.brief_head("main"))
        _ -> False
      }
    })
  assert list.length(briefs) == 1
  assert list.length(requests) == 4
  let assert Ok(log) = simplifile.read(prepared.checkout <> "/" <> child_log)
    as "the child's log exists under the executor checkout"
  assert log == "ran\ndone\n"
  remote_daemons.assert_absent_from(
    [prepared.orchestrator.directory, prepared.orchestrator.home],
    child_log,
  )
}
