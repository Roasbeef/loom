//// Remote evolution against the shipped daemon: an orchestrator and an
//// executor, two real `bin/loomd` processes that trust each other over TLS
//// distribution, with a session registered on the executor
//// (protocol-change/098, slice 3).
////
//// `evolution_acceptance_test` proves the governed lifecycle for a session
//// whose workspace is in its own VM. This module proves the same sequence for a
//// session whose workspace is on another machine. The model writes a candidate
//// into the executor's checkout with the ordinary file tools, proposes and
//// tests it through `cap/evolution` in a `code_mode` program, the owner approves
//// and selects it through the session socket's `evolution` commands, and the
//// model invokes it. Only the model is scripted. The orchestrator keeps the
//// catalogue, the evidence and the selection; the executor snapshots the
//// candidate, compiles it, serves it from a satellite in its own jail and runs
//// each invocation.
////
//// ## What it proves
////
//// - `fixed_executor`: an extension written into the executor's checkout is
////   proposed, tested, approved, selected and invoked, and the answer carries
////   the implementation's own marker. The checkout holds the candidate's source
////   and the orchestrator holds no file of that name, and the executor's
////   evolution scratch holds the compiled generation, which the orchestrator's
////   state does not.
//// - `program_candidate`: a program candidate goes through the same lifecycle
////   and the invocation writes a file with `cap/fs`. The file exists in the
////   executor's checkout only, so the program ran there, under the session's
////   policy.
//// - `executor_restart`: after the session is stopped, the executor is
////   restarted and the session is opened again, the selection is still in the
////   orchestrator's catalogue, the executor stages it afresh and the same
////   extension answers again. The first executor's generation died with its
////   process, so the second answer cannot be a survivor of the first stage.
////
//// ## What it does not prove
////
//// A link cut during staging, an orchestrator restart with a selection in
//// flight, a pool of executors and trials of a candidate are later slices. The
//// executor's close of each scope is read from its ledger, which is the
//// witness that its generation was retired, not a count of processes.
////
//// ## Prerequisites and skips
////
//// The executor compiles every candidate, so the host needs the code-mode seed
//// `make codemode-seed` prepares, `gleam` on `PATH`, the shipped daemon and a
//// helper that enforces a policy. A host without one prints a
//// `SKIP remote evolution acceptance: ...` line on standard error naming it and
//// passes, as the other shipped fixtures do.
////
//// ## Running it
////
//// ```sh
//// make e2e-evolution-remote
//// ```
////
//// The target builds the helper, the seed and the shipment and runs this
//// module with `LOOM_BOOTSTRAP_E2E_SERVER` set.

import client/evolution/record
import client/evolution_acceptance_test as acceptance
import client/tui_e2e_test.{type EunitTest, Timeout}
import core/json.{type JsonValue}
import gleam/erlang/process.{type Subject}
import gleam/io
import gleam/list
import gleam/option.{Some}
import gleam/string
import host/endpoint
import simplifile
import support/evolution as extension_fixture
import support/evolution_program as program_fixture
import support/evolution_programs as programs
import support/provider_http as provider
import support/remote_daemons
import support/remote_pair.{type Opened, type Pair, type SessionSocket}
import support/tui_driver
import weft/actor
import weft/poll

// The skip label and the budget of one turn. A turn that proposes or tests a
// candidate compiles it on the executor, which clones the build seed first, so
// it is given far longer than a plain turn.
const label = "remote evolution acceptance"

const turn_ms = 280_000

// The deadline a selection carries, which the control protocol bounds at 120
// seconds, and how long the fixture polls for its commit. The executor builds
// the generation and starts its satellite before the commit is recorded.
const select_deadline_ms = 120_000

const select_ms = 130_000

// --- the cases ---------------------------------------------------------------

/// An extension is authored, selected and invoked on a fixed executor.
///
/// ## Examples
///
/// `make e2e-evolution-remote`.
pub fn fixed_executor_test_() -> EunitTest {
  shipped(fixed_executor)
}

/// A program candidate is authored, selected and invoked on a fixed executor.
///
/// ## Examples
///
/// `make e2e-evolution-remote`.
pub fn program_candidate_test_() -> EunitTest {
  shipped(program_candidate)
}

/// A selected extension is staged afresh by a restarted executor.
///
/// ## Examples
///
/// `make e2e-evolution-remote`.
pub fn executor_restart_test_() -> EunitTest {
  shipped(executor_restart)
}

// The test is declined, under the label this module declares, when the host
// lacks the code-mode seed, and by `remote_pair.shipped` when it lacks the
// shipment, `gleam` or an enforcing helper. Both go to standard error, which is
// where the skip census reads them.
fn shipped(body: fn(Pair, String) -> Nil) -> EunitTest {
  case remote_pair.code_mode_seed() {
    Error(reason) ->
      Timeout(5, fn() { io.println_error("SKIP " <> label <> ": " <> reason) })
    Ok(seed) ->
      remote_pair.shipped(label, ["gleam"], fn(pair) { body(pair, seed) })
  }
}

// --- a fixed executor --------------------------------------------------------

const first_answer = "author evidence retained v1"

const invoked_answer = "invocation verified version-1:fresh"

fn fixed_executor(pair: Pair, seed: String) -> Nil {
  let receipts = collector()
  let script =
    list.append(
      acceptance.author_script_with(1, receipts, extension_fixture.extension(1)),
      acceptance.invoke_script("invoke version 1", "version-1:fresh"),
    )
  let requests =
    session(pair, seed, script, "e2e-evolution", fn(opened) {
      turn(opened, "author version 1", [first_answer])
      operate(opened, authored(receipts), 0, "activate-v1")
      turn(opened, "invoke version 1", [first_answer, invoked_answer])
      assert_staged_on_executor(pair, opened.session)
      remote_pair.stop_and_close(pair, opened, 1)
    })
  assert list.length(requests) == list.length(script)
    as "every scripted step consumed a request"
  assert_source_on_executor(pair, "v1/extension.toml")
}

// --- a program candidate -----------------------------------------------------

// The file the retained program writes through `cap/fs`, and its content. The
// path is relative to the session's workspace, which is the executor's checkout.
const ran_file = "program-ran.txt"

const ran_text = "ran by the retained program\n"

fn program_candidate(pair: Pair, seed: String) -> Nil {
  let receipts = collector()
  let script =
    list.append(
      program_authoring(receipts),
      program_invocation("invoke program"),
    )
  let requests =
    session(pair, seed, script, "e2e-program", fn(opened) {
      turn(opened, "author program", ["program evidence retained"])
      operate(opened, authored(receipts), 0, "activate-program")
      turn(opened, "invoke program", [
        "program evidence retained",
        "program invocation verified",
      ])
      remote_pair.stop_and_close(pair, opened, 1)
    })
  assert list.length(requests) == list.length(script)
    as "every scripted step consumed a request"

  // The side effect is where the program ran, and nowhere the orchestrator
  // keeps files.
  assert remote_pair.read_file(pair.checkout, ran_file) == ran_text
  remote_daemons.assert_absent_from(
    [pair.orchestrator.directory, pair.orchestrator.home],
    ran_file,
  )
}

// The retained program is the fixture skill with one more branch. Handed the
// probe input it records that it ran, through `cap/fs`, before it echoes.
fn program_source() -> String {
  program_fixture.source()
  |> string.replace("import cap/proc\n", "import cap/fs\nimport cap/proc\n")
  |> string.replace(
    "    Ok(say) -> native_echo(say)",
    "    Ok(\"fs-probe\") -> record_then_echo()\n    Ok(say) -> native_echo(say)",
  )
  |> string.append(
    "\nfn record_then_echo() -> report.Outcome {\n"
    <> "  case fs.write("
    <> programs.literal(ran_file)
    <> ", "
    <> programs.literal(ran_text)
    <> ") {\n"
    <> "    Ok(Nil) -> native_echo(\"fs-probe\")\n"
    <> "    Error(error) -> report.failure(fs.error_text(error))\n"
    <> "  }\n}\n",
  )
}

// The model writes the source with a file tool and proposes and tests it in one
// program. The receipt of that program names the candidate and its evidence,
// and the script hands both to the test body.
fn program_authoring(
  receipts: Subject(acceptance.ReceiptMessage),
) -> List(provider.Exchange) {
  [
    provider.ToolUseExchange(
      "author program",
      "program-write",
      "fs_write",
      json.Object([
        #("path", json.String("skill/program.gleam")),
        #("content", json.String(program_source())),
      ]),
    ),
    provider.ComputedExchange(provider.AwaitToolResult("program-write"), fn(_) {
      provider.ReplyToolUse(
        "program-author",
        programs.tool_name,
        programs.arguments(programs.propose_and_test(
          directory: "skill",
          name: "fresh_echo",
          kind: "program",
          test_entry: "author_checks",
          description: "Run an immutable native echo skill with fresh input.",
          schema: json.to_string(program_fixture.schema()),
        )),
      )
    }),
    provider.ComputedExchange(
      provider.AwaitToolResult("program-author"),
      fn(requests) {
        let receipt = programs.result_value(requests)
        process.send(
          receipts,
          acceptance.Published(acceptance.Authored(
            acceptance.required_text(receipt, "candidate_id"),
            acceptance.required_text(receipt, "evidence_id"),
            acceptance.required_text(receipt, "evidence"),
          )),
        )
        provider.ReplyText("program evidence retained")
      },
    ),
  ]
}

fn program_invocation(prompt: String) -> List(provider.Exchange) {
  let id = "invoke-program"
  [
    provider.ToolUseExchange(
      prompt,
      id,
      programs.tool_name,
      programs.arguments(programs.catalogue_and_invoke("fs-probe")),
    ),
    provider.ComputedExchange(provider.AwaitToolResult(id), fn(requests) {
      let outcome = programs.result_value(requests)
      let assert json.Array([active]) = acceptance.field(outcome, "active")
        as "discovery yields the single selected program"
      assert acceptance.field(active, "kind") == json.String("program")
        as "the catalogue names the candidate's kind"
      let execution = acceptance.field(outcome, "invoked")
      assert acceptance.field(execution, "status") == json.String("completed")
        && acceptance.field(execution, "value")
        == json.String("skill-v1:fs-probe")
        as "the executor ran the retained program with the fresh input"
      provider.ReplyText("program invocation verified")
    }),
  ]
}

// --- an executor restart -----------------------------------------------------

const after_restart_prompt = "invoke after restart"

fn executor_restart(pair: Pair, seed: String) -> Nil {
  let receipts = collector()
  let script =
    list.flatten([
      acceptance.author_script_with(1, receipts, extension_fixture.extension(1)),
      acceptance.invoke_script("invoke version 1", "version-1:fresh"),
      acceptance.invoke_script(after_restart_prompt, "version-1:fresh"),
    ])
  let requests =
    session(pair, seed, script, "e2e-evolution-restart", fn(opened) {
      turn(opened, "author version 1", [first_answer])
      operate(opened, authored(receipts), 0, "activate-v1")
      turn(opened, "invoke version 1", [first_answer, invoked_answer])
      remote_pair.stop_and_close(pair, opened, 1)

      // The executor's process, its satellite and its helper pool end with it.
      // Its state directory keeps the ledger and the checkout.
      let before = executor_process(pair)
      remote_daemons.retire(pair.executor.paths)
      let _executor =
        remote_daemons.start_with(pair.executor, executor_flags(seed))
      assert executor_process(pair) != before as "the executor is a new process"

      remote_pair.reopen(opened, 2000)
      turn(opened, after_restart_prompt, [
        first_answer,
        invoked_answer,
        invoked_answer,
      ])
      remote_pair.stop_and_close(pair, opened, 2)
    })
  assert list.length(requests) == list.length(script)
    as "every scripted step consumed a request"
}

// The executor's operating-system process id, from the endpoint record the
// daemon published. A restarted daemon publishes a new one.
fn executor_process(pair: Pair) -> Int {
  let assert Ok(Some(record)) = endpoint.load(pair.executor.paths)
    as "the executor published an endpoint"
  record.fence.pid
}

// --- one session on the pair ---------------------------------------------------

fn executor_flags(seed: String) -> List(String) {
  ["--codemode-seed", seed]
}

// Boots the pair against the scripted model, registers one session on the
// executor and runs `body` on it. Returns what the provider observed, after the
// orchestrator's owner connection is closed.
fn session(
  pair: Pair,
  seed: String,
  script: List(provider.Exchange),
  key: String,
  body: fn(Opened) -> Nil,
) -> List(provider.ObservedRequest) {
  let keys = remote_pair.provision(pair)
  let #(Nil, report) =
    provider.with_server_for(
      script,
      provider.OnlySuccessful,
      remote_pair.callback_ms,
      fn(url) {
        remote_pair.configure(pair, keys, remote_pair.plain(url))
        let opened =
          remote_pair.open_registered(pair, executor_flags(seed), key)
        body(opened)
        remote_pair.close_daemons([opened.orchestrator])
      },
    )
  let assert Ok(requests) = report
    as "the provider reports the finite script it served"
  requests
}

// One user turn, driven through a terminal. `answers` lists every final text
// the session has produced so far, because a terminal replays the transcript.
fn turn(opened: Opened, prompt: String, answers: List(String)) -> Nil {
  let terminal = remote_daemons.attach(opened.orchestrator, opened.session)
  remote_daemons.say(terminal, prompt)
  remote_daemons.await_answers(terminal, answers, turn_ms)
  tui_driver.stop(terminal)
}

// The scripted model's replies are computed in the provider's process, and a
// subject can be received from only by the process that made it, so the
// receipts go to an actor that holds them until the body asks.
fn collector() -> Subject(acceptance.ReceiptMessage) {
  let assert Ok(started) =
    actor.new([])
    |> actor.on_message(fn(held: List(acceptance.Authored), message) {
      case message {
        acceptance.Published(receipt) ->
          actor.continue(list.append(held, [receipt]))
        acceptance.Take(reply) -> {
          process.send(reply, list.first(held) |> option.from_result)
          actor.continue(list.drop(held, 1))
        }
        acceptance.Done -> actor.stop()
      }
    })
    |> actor.start
    as "the receipt collector starts"
  started.data
}

// The receipt the scripted model published after its authoring program.
fn authored(
  receipts: Subject(acceptance.ReceiptMessage),
) -> acceptance.Authored {
  acceptance.authored_result(receipts)
}

// --- the owner's side ----------------------------------------------------------

// Reads the evidence, approves it and selects the candidate at
// `expected` generation, then waits for the commit.
//
// The socket is opened here, after the turn that produced the candidate. A
// subscribed socket is pushed every event of every turn, and the command
// protocol reads only a bounded run of pushes before its reply.
fn operate(
  opened: Opened,
  authored: acceptance.Authored,
  expected: Int,
  request_id: String,
) -> Nil {
  let socket = verify_evidence(remote_pair.session_socket(opened), authored)
  let #(_approved, socket) =
    command(
      socket,
      "approve",
      json.Object([
        #("candidate_id", json.String(authored.candidate_id)),
        #("evidence_id", json.String(authored.evidence_id)),
      ]),
    )
  let #(receipt, socket) =
    command(
      socket,
      "select",
      json.Object([
        #("candidate_id", json.String(authored.candidate_id)),
        #("evidence_id", json.String(authored.evidence_id)),
        #("expected_generation", json.Int(expected)),
        #("request_id", json.String(request_id)),
        #("deadline_ms", json.Int(select_deadline_ms)),
        #("reason", json.String("remote acceptance fixture")),
      ]),
    )
  assert acceptance.field(receipt, "state") == json.String("queued")
  let _socket =
    await_committed(socket, request_id, authored.candidate_id, expected + 1)
  Nil
}

// The stored evidence is the envelope the model's program returned, and it
// records a passing author test of this candidate.
fn verify_evidence(
  socket: SessionSocket,
  authored: acceptance.Authored,
) -> SessionSocket {
  let #(observed, socket) =
    command(
      socket,
      "evidence",
      json.Object([#("evidence_id", json.String(authored.evidence_id))]),
    )
  let assert Ok(evidence) = record.decode_evidence(authored.evidence)
    as "the author-test envelope is totally decoded"
  assert evidence.verdict == record.Passed as evidence.observation
  assert record.id_string(evidence.candidate_id) == authored.candidate_id
  let assert Ok(expected) = json.parse(authored.evidence)
    as "the stored evidence is canonical JSON"
  assert observed == expected
    as "the owner reads the evidence the executor produced"
  socket
}

// A selection compiles on the executor outside the command's reply window, so
// the original request is polled to its durable commit.
fn await_committed(
  socket: SessionSocket,
  request_id: String,
  candidate_id: String,
  generation: Int,
) -> SessionSocket {
  let verdict =
    poll.fold_until(
      clock: poll.monotonic(),
      within: select_ms,
      every: poll.Fixed(200),
      from: socket,
      attempt: fn(current) {
        let #(status, next) =
          command(
            current,
            "status",
            json.Object([#("request_id", json.String(request_id))]),
          )
        case acceptance.field(status, "state") {
          json.String("completed") -> poll.Settled(#(status, next))
          json.String("queued")
          | json.String("running")
          | json.String("committed") -> poll.Pending(next)
          other ->
            poll.Broken(json.to_string(other) <> ": " <> json.to_string(status))
        }
      },
    )
  let assert poll.Answer(#(completed, socket)) = verdict
    as "the admitted selection reaches a conclusive receipt"
  let committed = acceptance.field(completed, "committed")
  assert acceptance.field(committed, "candidate_id")
    == json.String(candidate_id)
  assert acceptance.field(committed, "generation") == json.Int(generation)
  assert acceptance.field(completed, "published") == committed
    as "publication follows the executor's commit"
  socket
}

// One `evolution` command on the session socket, answered with the board the
// reply carries.
fn command(
  socket: SessionSocket,
  action: String,
  arguments: JsonValue,
) -> #(JsonValue, SessionSocket) {
  let #(reply, next) =
    remote_pair.session_command(
      socket,
      "evolution",
      json.Object([
        #("action", json.String(action)),
        #("arguments", arguments),
      ]),
    )
  assert remote_daemons.field(reply, "event") == json.String("snapshot")
    as { action <> " was refused: " <> json.to_string(reply) }
  let body = remote_daemons.field(reply, "body")
  #(remote_daemons.field(body, "board"), next)
}

// --- where the work happened -----------------------------------------------------

// The executor's evolution scratch for the session holds the compiled
// generation, and the orchestrator's holds nothing of the session: its state
// has the catalogue and no build.
fn assert_staged_on_executor(pair: Pair, session: String) -> Nil {
  let scratch = pair.executor.paths.root <> "/evolution/run/" <> session
  assert built_under(scratch, "evolution_echo")
    as "the executor's scratch holds the extension's build"
  assert built_under(pair.orchestrator.paths.root, "evolution_echo") == False
    as "the orchestrator holds no build of the extension"
}

// Whether any file or directory beneath `root` has a name containing `part`.
fn built_under(root: String, part: String) -> Bool {
  case simplifile.read_directory(root) {
    Error(_) -> False
    Ok(names) ->
      list.any(names, fn(name) {
        string.contains(name, part)
        || case simplifile.is_directory(root <> "/" <> name) {
          Ok(True) -> built_under(root <> "/" <> name, part)
          Ok(False) | Error(_) -> False
        }
      })
  }
}

// The candidate's source is in the executor's checkout and in no directory of
// the orchestrator's.
fn assert_source_on_executor(pair: Pair, path: String) -> Nil {
  assert result_is_file(pair.checkout <> "/" <> path)
    as "the model wrote the candidate into the executor's checkout"
  remote_daemons.assert_absent_from(
    [pair.orchestrator.directory, pair.orchestrator.home],
    "extension.toml",
  )
}

fn result_is_file(path: String) -> Bool {
  simplifile.is_file(path) == Ok(True)
}
