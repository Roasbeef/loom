//// Background code mode on a registered session, against the shipped daemon: an
//// orchestrator and an executor, two real `bin/loomd` processes that trust each
//// other over TLS distribution (protocol-change/078, the addendum on background
//// code mode).
////
//// A `code_mode` call with `mode: "launch"` starts a program that outlives the
//// call. On a registered session the program runs on the executor beside the
//// checkout, while its record, its input journal and its progress stay on the
//// orchestrator. The executor's ledger keeps the program's key admitted until
//// the program ends and then keeps its result until the orchestrator
//// acknowledges it. These tests drive one such program through each event the
//// design names: input, a cut link, an executor restart and an orchestrator
//// restart.
////
//// ## What it proves
////
//// `daemon_shipped_remote_background_test_`, one session and one counter.
////
//// - The model launches a program that registers one typed endpoint and waits
////   for input. The program is compiled and run on the executor. The launch
////   returns at once with the record's id, and the record turns ready once the
////   program has registered its endpoint.
//// - The model sends `2` to the endpoint. The program adds it to its count,
////   publishes the count as progress and writes it to `sum.txt` in the
////   checkout.
//// - A probe has the orchestrator drop its connection to the executor while the
////   program waits for its next input. Both daemons stay up. The model's `check`
////   after the cut reads the record still running, with progress `2`.
//// - The model sends `5`, and `sum.txt` reaches `7`. The program received input
////   after the cut, so the cut did not stop it, and its owner-bound receive
////   waited the cut out rather than failing.
//// - The executor is killed with `SIGKILL` and started again on the same
////   state. The orchestrator hears that the program's key is unknown, records
////   the execution lost, and wakes the session with a notice that says so. The
////   record in the orchestrator's store is lost with the executor's reason, and
////   the executor's ledger holds no admitted execution once the session stops.
////
//// `daemon_shipped_remote_background_recovery_test_`, a result kept across an
//// orchestrator restart.
////
//// - The model launches a program that runs a command on the executor. The
////   command appends `ran` to `ran.log` and waits for a file named `release`.
//// - The orchestrator is killed with `SIGKILL` while the program waits. The test
////   writes `release`, and the program finishes on the executor while no
////   orchestrator is running. The executor's ledger then holds the program's
////   result, unacknowledged.
//// - The orchestrator is started again on the same state and the session is
////   opened again. Recovery asks the executor for the key, finds the stored
////   result and keeps it: the session is woken with a notice that the execution
////   finished, quoting the program's result, and the model's `check` reads the
////   record finished with that result.
//// - `ran.log` holds `ran` and `done` once each, so the program ran once and
////   was neither stopped nor started again.
////
//// ## Prerequisites and skips
////
//// Code mode on the executor needs a toolchain and the build seed
//// `make codemode-seed` prepares, the probe needs `erl`, and the jail needs
//// platform enforcement. Without enforcement the fixture declines as the other
//// shipped fixtures do, and without the seed it prints a skip line naming what
//// is missing.
////
//// ## Running it
////
//// ```sh
//// make codemode-seed
//// make server-shipment
//// make sandbox && install -m 0755 packages/sandbox/loom-exec bin/loom-exec
//// export LOOM_BOOTSTRAP_E2E_SERVER=$PWD/bin/loomd
//// export LOOM_TEST_PROVIDER_KEY=loom-provider-fixture-key
//// bash scripts/test.sh client --match 'client@daemon_shipped_remote_background_test:'
//// ```
////
//// The fixture is the one `daemon_shipped_remote_test` documents, arranged for
//// a single pair by `support/remote_pair`, with the probe it describes.

import client/tui_e2e_test.{type EunitTest}
import core/json.{type JsonValue}
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile
import storage/exec_ledger
import support/provider_http as provider
import support/remote_daemons
import support/remote_pair.{type Pair}
import weft/poll

const skip_label = "shipped remote background"

/// Drives a background counter on the executor through input, a cut link and
/// an executor restart.
///
/// ## Examples
///
/// `bash scripts/test.sh client --match 'client@daemon_shipped_remote_background_test:'`.
pub fn daemon_shipped_remote_background_test_() -> EunitTest {
  remote_pair.shipped(skip_label, [], fn(prepared) {
    gated(prepared, counter_session)
  })
}

/// Keeps a background program's result across an orchestrator restart.
///
/// ## Examples
///
/// `bash scripts/test.sh client --match 'client@daemon_shipped_remote_background_test:'`.
pub fn daemon_shipped_remote_background_recovery_test_() -> EunitTest {
  remote_pair.shipped(skip_label, [], fn(prepared) {
    gated(prepared, recovery_session)
  })
}

// Code mode must have what it builds with. That is a property of the host and is
// measured here, before any daemon starts.
fn gated(prepared: Pair, body: fn(Pair, String) -> Nil) -> Nil {
  case remote_pair.code_mode_seed() {
    Error(reason) ->
      io.println_error(
        "SKIP " <> skip_label <> ": code mode cannot build here: " <> reason,
      )
    Ok(seed) -> body(prepared, seed)
  }
}

// --- the counter -------------------------------------------------------------

// The program the model launches. An actor holds the count, so the endpoint's
// delivery closure, which runs once per input, can add to it. Each delivery
// publishes the new count as progress and only then writes it to `sum.txt`, so
// a test that has read a count from the file knows the orchestrator was handed
// that count as progress. The idle bound is the longest `serve` accepts, far
// past anything the test waits for.
fn counter_program() -> String {
  "import cap/actor
import cap/execution
import cap/fs
import cap/report
import gleam/int
import gleam/result

pub type CounterMessage {
  Add(value: Int, reply: actor.Reply(Int))
}

pub fn main() -> report.Outcome {
  case actor.spawn(0, handle_counter) {
    Error(_) -> report.failure(\"actor start failed\")
    Ok(counter) ->
      case number_endpoint(counter) {
        Error(reason) -> report.failure(reason)
        Ok(endpoint) ->
          case execution.serve([endpoint], idle_within_ms: 300_000) {
            Error(_) -> report.failure(\"endpoint service failed\")
            Ok(_) -> report.text(\"counter stopped serving\")
          }
      }
  }
}

fn handle_counter(sum: Int, message: CounterMessage) -> actor.Next(Int) {
  case message {
    Add(value, reply) -> {
      let sum = sum + value
      actor.reply(reply, sum)
      actor.continue(sum)
    }
  }
}

fn number_endpoint(
  counter: actor.Address(Int, CounterMessage),
) -> Result(execution.Endpoint, String) {
  execution.endpoint(
    name: \"number\",
    decode: fn(value) {
      report.as_int(value) |> result.replace_error(\"expected integer\")
    },
    deliver: fn(value) {
      use sum <- result.try(
        actor.call(counter, fn(reply) { Add(value, reply) }, timeout: 1000)
        |> result.replace_error(\"actor delivery failed\"),
      )
      use _ <- result.try(
        execution.progress(report.int(sum))
        |> result.replace_error(\"progress publication failed\"),
      )
      fs.write(\"sum.txt\", int.to_string(sum))
      |> result.replace_error(\"the count could not be written\")
    },
  )
  |> result.map_error(fn(_) { \"invalid endpoint\" })
}
"
}

const launch_prompt = "launch the counter"

const launched = "counter launched"

const send_prompt = "send two"

const sent_two = "sent two"

const check_prompt = "check the counter and send five"

const sent_five = "sent five"

const lost_answer = "counter lost"

// The notice the orchestrator wakes an idle strand with when an execution ends,
// up to the record's id.
const notice_head = "[loom] async code-mode execution "

// The model's side. The handle is minted at runtime and appears only in the
// launch's result, so every later call reads it from there. The step after the
// launch also writes the handle where the test body can read it, because the
// body runs in another process and has to wait for the record by its key.
fn counter_script(prepared: Pair) -> List(provider.Exchange) {
  [
    provider.ToolUseExchange(
      launch_prompt,
      "launch-call",
      "code_mode",
      json.Object([
        #("mode", json.String("launch")),
        #("program", json.String(counter_program())),
        #("within_ms", json.Int(600_000)),
      ]),
    ),
    provider.ComputedExchange(provider.AwaitToolResult("launch-call"), fn(seen) {
      publish_handle(prepared, handle_of(seen))
      provider.ReplyText(launched)
    }),
    provider.ComputedExchange(provider.AwaitPrompt(send_prompt), fn(seen) {
      provider.ReplyToolUse("send-two", "code_mode", send(handle_of(seen), 2))
    }),
    provider.ComputedExchange(provider.AwaitToolResult("send-two"), fn(_seen) {
      provider.ReplyText(sent_two)
    }),
    provider.ComputedExchange(provider.AwaitPrompt(check_prompt), fn(seen) {
      provider.ReplyToolUse("check-live", "code_mode", check(handle_of(seen)))
    }),
    provider.ComputedExchange(provider.AwaitToolResult("check-live"), fn(seen) {
      provider.ReplyToolUse("send-five", "code_mode", send(handle_of(seen), 5))
    }),
    provider.ComputedExchange(provider.AwaitToolResult("send-five"), fn(_seen) {
      provider.ReplyText(sent_five)
    }),
    provider.ComputedExchange(
      provider.AwaitPromptPrefix(notice_head),
      fn(_seen) { provider.ReplyText(lost_answer) },
    ),
  ]
}

fn send(handle: String, value: Int) -> JsonValue {
  json.Object([
    #("mode", json.String("send")),
    #("handle", json.String(handle)),
    #("endpoint", json.String("number")),
    #("value", json.Int(value)),
  ])
}

// A check that answers at once. Without `within_ms` a check waits up to thirty
// seconds for the execution to end, and the counter does not end on its own.
fn check(handle: String) -> JsonValue {
  json.Object([
    #("mode", json.String("check")),
    #("handle", json.String(handle)),
    #("within_ms", json.Int(0)),
  ])
}

fn counter_session(prepared: Pair, seed: String) -> Nil {
  let keys = remote_pair.provision(prepared)
  let probe = remote_pair.probe_identity(prepared, keys)
  let flags = ["--codemode-seed", seed]
  let #(Nil, report) =
    provider.with_server_for(
      counter_script(prepared),
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
          remote_pair.open_registered(prepared, flags, "e2e-background")
        remote_pair.converse_for(opened, launch_prompt, [launched])
        let handle = await_handle(prepared)
        await_ready(prepared, opened.session, handle)
        remote_pair.converse_for(opened, send_prompt, [launched, sent_two])
        await_sum(prepared, "2")

        // The program is waiting for its next input, an owner-bound receive,
        // when the link goes.
        remote_pair.drop_link(prepared, keys, probe)
        remote_pair.converse_for(opened, check_prompt, [
          launched,
          sent_two,
          sent_five,
        ])
        await_sum(prepared, "7")

        // The executor dies with the program running and comes back on the
        // same state. The orchestrator's worker sends the start again, hears
        // that the key is unknown, and the record is lost.
        remote_daemons.crash(prepared.executor)
        let _restarted = remote_daemons.start_with(prepared.executor, flags)
        remote_pair.await_answers(opened, [
          launched,
          sent_two,
          sent_five,
          lost_answer,
        ])
        assert_lost_record(prepared, opened.session, handle)
        remote_daemons.stop_session(
          opened.orchestrator,
          opened.control,
          100,
          opened.session,
        )
        assert read_ledger(prepared, fn(ledger) {
            exec_ledger.admitted(ledger, opened.session, "execution")
          })
          == []
        remote_pair.close_daemons([opened.orchestrator])
      },
    )
  let assert Ok(requests) = report
    as "the provider saw the launch, two sends, the check and the notice"
  assert_counter_requests(requests)
}

// What the model read. The check after the cut found the record running and
// ready, with the progress the first input produced. The notice named the
// execution lost by the executor.
fn assert_counter_requests(requests: List(provider.ObservedRequest)) -> Nil {
  let checked = parsed(remote_daemons.result_text(requests, "check-live"))
  assert remote_daemons.field(checked, "phase") == json.String("running")
  assert remote_daemons.field(checked, "readiness") == json.String("ready")
  let progress = remote_daemons.field(checked, "progress")
  assert remote_daemons.field(progress, "value") == json.Int(2)
  let notices =
    list.filter_map(requests, fn(request) {
      case request.latest {
        provider.UserPrompt(text) ->
          case string.starts_with(text, notice_head) {
            True -> Ok(text)
            False -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    })
  let assert [notice] = notices as "one notice woke the session"
  assert string.contains(notice, "was lost: the executor lost the execution")
}

// The record the orchestrator keeps for the counter, read from a copy of its
// store, is lost with the executor's reason.
fn assert_lost_record(prepared: Pair, session: String, handle: String) -> Nil {
  let assert Some(record) =
    remote_pair.session_fact(prepared, session, record_key(handle))
    as "the orchestrator keeps the execution's record"
  assert remote_daemons.field(record, "phase") == json.String("lost")
  let assert json.String(reason) = remote_daemons.field(record, "result")
    as "a lost record carries its reason"
  assert string.contains(reason, "the executor lost the execution")
}

// Waits until `sum.txt` in the executor's checkout holds `expected`.
fn await_sum(prepared: Pair, expected: String) -> Nil {
  let path = prepared.checkout <> "/sum.txt"
  let assert poll.Answered(Nil) =
    poll.until(within: 90_000, every: 100, attempt: fn() {
      case simplifile.read(path) {
        Ok(text) if text == expected -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as { "the counter on the executor reaches " <> expected }
  Nil
}

// Waits until the program has registered its endpoint, which the orchestrator
// records as the execution's readiness. A send before that is refused.
fn await_ready(prepared: Pair, session: String, handle: String) -> Nil {
  let assert poll.Answered(Nil) =
    poll.until(within: 240_000, every: 250, attempt: fn() {
      case remote_pair.session_fact(prepared, session, ready_key(handle)) {
        Some(_) -> poll.Done(Nil)
        None -> poll.Retry
      }
    })
    as "the counter registers its endpoint"
  Nil
}

// --- the result kept across an orchestrator restart ------------------------

// The program the model launches. Its one command appends `ran`, waits for the
// test to write `release`, appends `done` and prints what `release` holds, so
// the side-effect file counts the runs and the result names the release.
fn waiter_program() -> String {
  "import cap/proc
import cap/report

pub fn main() -> report.Outcome {
  let command =
    proc.command([
      \"sh\",
      \"-c\",
      \"echo ran >> ran.log; while [ ! -f release ]; do sleep 0.1; done; echo done >> ran.log; cat release\",
    ])
  case proc.stdout(command) {
    Ok(text) -> report.text(\"released \" <> text)
    Error(reason) -> report.failure(reason)
  }
}
"
}

const waiter_prompt = "launch the waiter"

const waiter_launched = "waiter launched"

const recovered_answer = "waiter recovered"

const release_text = "go"

fn recovery_script(prepared: Pair) -> List(provider.Exchange) {
  [
    provider.ToolUseExchange(
      waiter_prompt,
      "launch-call",
      "code_mode",
      json.Object([
        #("mode", json.String("launch")),
        #("program", json.String(waiter_program())),
        #("within_ms", json.Int(600_000)),
      ]),
    ),
    provider.ComputedExchange(provider.AwaitToolResult("launch-call"), fn(seen) {
      publish_handle(prepared, handle_of(seen))
      provider.ReplyText(waiter_launched)
    }),
    provider.ComputedExchange(provider.AwaitPromptPrefix(notice_head), fn(seen) {
      provider.ReplyToolUse("check-kept", "code_mode", check(handle_of(seen)))
    }),
    provider.ComputedExchange(provider.AwaitToolResult("check-kept"), fn(_seen) {
      provider.ReplyText(recovered_answer)
    }),
  ]
}

fn recovery_session(prepared: Pair, seed: String) -> Nil {
  let keys = remote_pair.provision(prepared)
  let #(Nil, report) =
    provider.with_server_for(
      recovery_script(prepared),
      provider.OnlySuccessful,
      remote_pair.callback_ms,
      fn(url) {
        remote_pair.configure(
          prepared,
          keys,
          remote_pair.Tables(
            models: remote_pair.models_without_glance(url),
            orchestrator: "",
            executor: "",
          ),
        )
        let opened =
          remote_pair.open_registered(
            prepared,
            ["--codemode-seed", seed],
            "e2e-background-recovery",
          )
        remote_pair.converse_for(opened, waiter_prompt, [waiter_launched])
        let handle = await_handle(prepared)
        await_log(prepared, "ran\n")

        // The orchestrator dies while the program waits, and the program
        // finishes with no orchestrator running. The executor stores its
        // result and keeps it until someone acknowledges it.
        remote_daemons.crash(prepared.orchestrator)
        let assert Ok(Nil) =
          simplifile.write(prepared.checkout <> "/release", release_text)
          as "the release file is written"
        await_log(prepared, "ran\ndone\n")
        await_stored(prepared, opened.session, handle)

        // The restarted orchestrator reopens the session, and recovery reads
        // the stored result instead of losing the record.
        let second = remote_daemons.start(prepared.orchestrator)
        let control = remote_daemons.open_control(second)
        let reopened =
          remote_daemons.reopen_session(control, 10, opened.session)
        assert remote_daemons.settled_state(reopened) == "resident"
        let terminal = remote_daemons.attach(second, opened.session)
        remote_daemons.await_answers(
          terminal,
          [waiter_launched, recovered_answer],
          remote_pair.turn_ms,
        )
        remote_pair.close_daemons([second])
      },
    )
  let assert Ok(requests) = report
    as "the provider saw the launch, the notice and the check"
  assert_kept(prepared, requests)
}

// The notice and the check both carry the program's own result, and the
// command ran once.
fn assert_kept(
  prepared: Pair,
  requests: List(provider.ObservedRequest),
) -> Nil {
  let notice =
    list.find_map(requests, fn(request) {
      case request.latest {
        provider.UserPrompt(text) ->
          case string.starts_with(text, notice_head) {
            True -> Ok(text)
            False -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    })
  let assert Ok(notice) = notice as "a notice woke the reopened session"
  assert string.contains(notice, " finished")
  assert string.contains(notice, "released " <> release_text)
  let checked = parsed(remote_daemons.result_text(requests, "check-kept"))
  assert remote_daemons.field(checked, "phase") == json.String("finished")
  assert string.contains(
    json.to_string(remote_daemons.field(checked, "result")),
    "released " <> release_text,
  )
  assert remote_pair.read_file(prepared.checkout, "ran.log") == "ran\ndone\n"
}

// Waits until the executor's ledger holds the program's result, unacknowledged.
fn await_stored(prepared: Pair, session: String, handle: String) -> Nil {
  let assert poll.Answered(Nil) =
    poll.until(within: 60_000, every: 250, attempt: fn() {
      let unacked =
        read_ledger(prepared, fn(ledger) {
          exec_ledger.unacked(ledger, session)
        })
      case
        list.any(unacked.terminal, fn(key) { key.step == "async/" <> handle })
      {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
    as "the executor stores the program's result"
  Nil
}

// Waits until `ran.log` holds exactly `expected`. Every line the command writes
// is a whole line, so a longer file is a command that ran again.
fn await_log(prepared: Pair, expected: String) -> Nil {
  let path = prepared.checkout <> "/ran.log"
  let assert poll.Answered(Nil) =
    poll.until(within: 240_000, every: 100, attempt: fn() {
      case simplifile.read(path) {
        Ok(text) if text == expected -> poll.Done(Nil)
        Ok(text) ->
          case string.length(text) > string.length(expected) {
            True -> poll.Fail("the command ran again: " <> text)
            False -> poll.Retry
          }
        Error(_) -> poll.Retry
      }
    })
    as { "ran.log reaches " <> string.inspect(expected) }
  Nil
}

// --- the handle and the stores ----------------------------------------------

// The id the launch's result names. The result is the record as JSON.
fn handle_of(seen: List(provider.ObservedRequest)) -> String {
  let record = parsed(remote_daemons.result_text(seen, "launch-call"))
  let assert json.String(id) = remote_daemons.field(record, "id")
    as "a launch answers with the record's id"
  id
}

// The provider's script runs in its own process, so the handle reaches the test
// body through a file in the pair's directory.
fn publish_handle(prepared: Pair, handle: String) -> Nil {
  let assert Ok(Nil) = simplifile.write(handle_file(prepared), handle)
    as "the handle is published to the test body"
  Nil
}

fn await_handle(prepared: Pair) -> String {
  let assert poll.Answered(handle) =
    poll.until(within: 30_000, every: 50, attempt: fn() {
      case simplifile.read(handle_file(prepared)) {
        Ok(handle) if handle != "" -> poll.Done(handle)
        _ -> poll.Retry
      }
    })
    as "the launch's handle is published"
  handle
}

fn handle_file(prepared: Pair) -> String {
  prepared.directory <> "/launched-handle"
}

fn record_key(handle: String) -> String {
  "client/async/record/" <> handle
}

fn ready_key(handle: String) -> String {
  "client/async/ready/" <> handle
}

fn parsed(text: String) -> JsonValue {
  let assert Ok(value) = json.parse(text) as "the tool result is JSON"
  value
}

// Reads the executor's ledger from a copy of the file and its write-ahead log,
// as `remote_daemons.executor_scope` does, so the live ledger is never opened
// by the test.
fn read_ledger(
  prepared: Pair,
  read: fn(exec_ledger.Ledger) -> Result(answer, exec_ledger.Error),
) -> answer {
  let scratch = prepared.directory <> "/ledger-copies"
  let assert Ok(Nil) = simplifile.create_directory_all(scratch)
    as "the ledger copy has a directory"
  let source = prepared.executor.paths.root <> "/exec-ledger.db"
  let copy = scratch <> "/exec-ledger-" <> remote_daemons.random_hex(4) <> ".db"
  list.each(["", "-wal", "-shm"], fn(suffix) {
    case simplifile.is_file(source <> suffix) {
      Ok(True) -> {
        let assert Ok(Nil) =
          simplifile.copy_file(source <> suffix, copy <> suffix)
          as "the ledger file is copied"
        Nil
      }
      _ -> Nil
    }
  })
  let assert Ok(ledger) = exec_ledger.open(copy) as "the copied ledger opens"
  let assert Ok(answer) = read(ledger) as "the copied ledger answers"
  let assert Ok(Nil) = exec_ledger.close(ledger) as "the copy closes"
  answer
}
