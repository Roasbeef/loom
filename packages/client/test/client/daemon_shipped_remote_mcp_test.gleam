//// MCP servers for a registered session, against the shipped daemon: an
//// orchestrator and an executor, two real `bin/loomd` processes that trust each
//// other over TLS distribution (protocol-change/078, the addendum on MCP
//// placement).
////
//// A code-mode program on a registered session runs on the executor, and it
//// reaches a configured MCP server through the generated `cap/mcp/<name>`
//// façade. `runs_on` in the orchestrator's `[mcp.<name>]` table says which
//// machine runs the server. The default, `"orchestrator"`, spawns it on the
//// orchestrator with the key the orchestrator holds, and the program's calls
//// reach it through the owner port. `"executor"` names a server the executor
//// runs from its own `[mcp.<name>]` table, beside the checkout, and the calls
//// never leave the executor. Each test boots one pair with one placement and
//// has a program call the server.
////
//// The server is the repository's fixture, `test/support/mcp_fixture.escript`,
//// a real OS process speaking JSON-RPC on stdio. It answers `echo_args` with the
//// arguments it received and `Create-Issue!` with a tool failure, so the
//// program's report shows what crossed. Its last argument is a file it writes
//// its OS pid into before it answers anything, so the file names the machine
//// that spawned it: each daemon's table names a pid file in that daemon's own
//// directory.
////
//// ## What it proves
////
//// `daemon_shipped_remote_mcp_orchestrator_test_`, the default placement.
////
//// - The orchestrator's table names the server and the executor's names none.
////   The program on the executor calls `echo_args` and `Create-Issue!` through
////   the façade, and its report carries the echoed arguments and the tool's
////   failure text. The orchestrator's pid file exists, so the orchestrator ran
////   the server.
////
//// `daemon_shipped_remote_mcp_executor_test_`, executor placement.
////
//// - The orchestrator's table says `runs_on = "executor"` and names a command
////   that would write the orchestrator's pid file. The executor's own table
////   names the server with a command that writes the executor's pid file.
////   The program's report is the same as above. The executor's pid file exists
////   and the orchestrator's does not, so the executor ran the server and the
////   orchestrator's command was never run.
//// - The orchestrator logs `mcp.ready` for the server with
////   `placement: executor` and the three tools the executor listed, which is
////   the census the executor returned at attach.
////
//// `daemon_shipped_remote_mcp_mismatch_test_`, a configuration mismatch.
////
//// - The orchestrator expects the server on the executor and the executor has
////   no table for it. The orchestrator logs `mcp.unavailable` for the server
////   with `placement: executor` and the executor's reason, which names the
////   missing table. A program that imports the façade is refused, and the
////   refusal the model reads names the module.
////
//// Every test stops the session and finds the executor's scope closed with
//// `all_retired`, so the server, wherever it ran, did not hold the close up.
////
//// ## Prerequisites and skips
////
//// Code mode on the executor needs a toolchain and the build seed
//// `make codemode-seed` prepares, the fixture server needs `escript` on
//// `PATH`, and the jail needs platform enforcement. Without enforcement the
//// fixture declines as the other shipped fixtures do, and without the seed or
//// `escript` it prints a skip line naming what is missing.
////
//// ## Running it
////
//// ```sh
//// make codemode-seed
//// make server-shipment
//// make sandbox && install -m 0755 packages/sandbox/loom-exec bin/loom-exec
//// export LOOM_BOOTSTRAP_E2E_SERVER=$PWD/bin/loomd
//// export LOOM_TEST_PROVIDER_KEY=loom-provider-fixture-key
//// bash scripts/test.sh client --match 'client@daemon_shipped_remote_mcp_test:'
//// ```
////
//// The fixture is the one `daemon_shipped_remote_test` documents, arranged for
//// a single pair by `support/remote_pair`.

import client/codemode_live_test
import client/tui_e2e_test.{type EunitTest}
import core/json
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import host/bootstrap as native
import simplifile
import support/provider_http as provider
import support/remote_daemons
import support/remote_pair.{type Pair}

const skip_label = "shipped remote mcp"

/// Calls an MCP server the orchestrator runs from a program on the executor.
///
/// ## Examples
///
/// `bash scripts/test.sh client --match 'client@daemon_shipped_remote_mcp_test:'`.
pub fn daemon_shipped_remote_mcp_orchestrator_test_() -> EunitTest {
  remote_pair.shipped(skip_label, [], fn(prepared) {
    gated(prepared, orchestrator_placed)
  })
}

/// Calls an MCP server the executor runs from a program on the executor.
///
/// ## Examples
///
/// `bash scripts/test.sh client --match 'client@daemon_shipped_remote_mcp_test:'`.
pub fn daemon_shipped_remote_mcp_executor_test_() -> EunitTest {
  remote_pair.shipped(skip_label, [], fn(prepared) {
    gated(prepared, executor_placed)
  })
}

/// Finds an MCP server the orchestrator expects on an executor that has no
/// table for it.
///
/// ## Examples
///
/// `bash scripts/test.sh client --match 'client@daemon_shipped_remote_mcp_test:'`.
pub fn daemon_shipped_remote_mcp_mismatch_test_() -> EunitTest {
  remote_pair.shipped(skip_label, [], fn(prepared) {
    gated(prepared, mismatched)
  })
}

// What the fixture server runs with: the interpreter, the checked-in script,
// and the build seed the executor compiles programs against.
type Server {
  Server(escript: String, script: String, seed: String)
}

// The host must be able to build a program and run the fixture server. Both are
// properties of the host, measured before any daemon starts.
fn gated(prepared: Pair, body: fn(Pair, Server) -> Nil) -> Nil {
  let found = {
    use seed <- result.try(remote_pair.code_mode_seed())
    use escript <- result.try(
      native.find_executable("escript")
      |> result.replace_error("escript is not on PATH"),
    )
    use here <- result.try(
      simplifile.current_directory()
      |> result.replace_error("the test runner has no working directory"),
    )
    let script = here <> "/test/support/mcp_fixture.escript"
    case simplifile.is_file(script) {
      Ok(True) -> Ok(Server(escript:, script:, seed:))
      _ -> Error("no MCP fixture server at " <> script)
    }
  }
  case found {
    Error(reason) -> io.println_error("SKIP " <> skip_label <> ": " <> reason)
    Ok(server) -> body(prepared, server)
  }
}

// The catalogue key, which is also the `cap/mcp/<name>` module segment.
const server_name = "fixture"

// What the program's report carries when the server answered: the server's own
// text block, the arguments it echoed by their wire names, and the tool failure
// it answered `Create-Issue!` with. The values are the ones
// `codemode_live_test.mcp_process_program_source` sends.
const echoed = "ok message=loom-mcp-wire-fidelity tag=Tag-With_Mixed.Case"

const tool_failed = "tool-failed the issue tracker refused"

// An `[mcp.fixture]` table whose server writes its pid to `pid_file`, with the
// `runs_on` line given, which may be empty.
fn mcp_table(server: Server, pid_file: String, runs_on: String) -> String {
  "[mcp."
  <> server_name
  <> "]\ncommand = [\""
  <> server.escript
  <> "\", \""
  <> server.script
  <> "\", \""
  <> pid_file
  <> "\"]\n"
  <> runs_on
}

const on_executor = "runs_on = \"executor\"\n"

// Each daemon's pid file is in that daemon's own directory.
fn orchestrator_pid(prepared: Pair) -> String {
  prepared.orchestrator.directory <> "/mcp-server.pid"
}

fn executor_pid(prepared: Pair) -> String {
  prepared.executor.directory <> "/mcp-server.pid"
}

const prompt = "call the mcp server"

const answer = "mcp called"

// How the program's call is expected to end, which decides the step that
// answers it.
type Expected {
  Answered
  Refused
}

// The model submits the program that calls the server and answers once it has
// read the result.
fn program_script(expected: Expected) -> List(provider.Exchange) {
  let awaited = case expected {
    Answered -> provider.AwaitToolResult("mcp-call")
    Refused -> provider.AwaitFailedToolResult("mcp-call")
  }
  [
    provider.ToolUseExchange(
      prompt,
      "mcp-call",
      "code_mode",
      json.Object([
        #(
          "program",
          json.String(codemode_live_test.mcp_process_program_source()),
        ),
        #("within_ms", json.Int(240_000)),
      ]),
    ),
    provider.ComputedExchange(awaited, fn(_seen) { provider.ReplyText(answer) }),
  ]
}

// Boots the pair with the two `[mcp.fixture]` tables given, has the program
// call the server, stops the session and returns what the provider saw.
fn drive(
  prepared: Pair,
  server: Server,
  orchestrator_table: String,
  executor_table: String,
  expected: Expected,
  key: String,
) -> List(provider.ObservedRequest) {
  let keys = remote_pair.provision(prepared)
  let admission = case expected {
    Answered -> provider.OnlySuccessful
    Refused -> provider.AlsoFailed
  }
  let #(Nil, report) =
    provider.with_server_for(
      program_script(expected),
      admission,
      remote_pair.callback_ms,
      fn(url) {
        remote_pair.configure(
          prepared,
          keys,
          remote_pair.Tables(
            models: remote_pair.models_without_glance(url),
            orchestrator: orchestrator_table,
            executor: executor_table,
          ),
        )
        let opened =
          remote_pair.open_registered(
            prepared,
            ["--codemode-seed", server.seed],
            key,
          )
        remote_pair.converse_for(opened, prompt, [answer])
        remote_pair.stop_and_close(prepared, opened, 1)
        remote_pair.close_daemons([opened.orchestrator])
      },
    )
  let assert Ok(requests) = report
    as "the provider saw the program's result and nothing else"
  requests
}

// The program's report carries the server's answers, so the call crossed to the
// server and back.
fn assert_answered(requests: List(provider.ObservedRequest)) -> Nil {
  let report = remote_daemons.result_text(requests, "mcp-call")
  assert string.contains(report, echoed)
  assert string.contains(report, tool_failed)
}

fn orchestrator_placed(prepared: Pair, server: Server) -> Nil {
  let requests =
    drive(
      prepared,
      server,
      mcp_table(server, orchestrator_pid(prepared), ""),
      "",
      Answered,
      "e2e-mcp-orchestrator",
    )
  assert_answered(requests)
  assert simplifile.is_file(orchestrator_pid(prepared)) == Ok(True)
  assert simplifile.is_file(executor_pid(prepared)) == Ok(False)
}

fn executor_placed(prepared: Pair, server: Server) -> Nil {
  let requests =
    drive(
      prepared,
      server,
      mcp_table(server, orchestrator_pid(prepared), on_executor),
      mcp_table(server, executor_pid(prepared), ""),
      Answered,
      "e2e-mcp-executor",
    )
  assert_answered(requests)
  assert simplifile.is_file(executor_pid(prepared)) == Ok(True)
  assert simplifile.is_file(orchestrator_pid(prepared)) == Ok(False)
  let assert Ok(ready) = orchestrator_event(prepared, "mcp.ready", server_name)
    as "the orchestrator logs the server the executor started"
  assert string.contains(ready, "\"placement\":\"executor\"")
  assert string.contains(ready, "\"tools\":3")
}

fn mismatched(prepared: Pair, server: Server) -> Nil {
  let requests =
    drive(
      prepared,
      server,
      mcp_table(server, orchestrator_pid(prepared), on_executor),
      "",
      Refused,
      "e2e-mcp-mismatch",
    )
  let assert Ok(unavailable) =
    orchestrator_event(prepared, "mcp.unavailable", server_name)
    as "the orchestrator logs the server the executor could not start"
  assert string.contains(unavailable, "\"placement\":\"executor\"")
  assert string.contains(
    unavailable,
    "this executor declares no [mcp." <> server_name <> "] table",
  )
  let refusal = remote_daemons.failed_result_text(requests, "mcp-call")
  assert string.contains(refusal, "cap/mcp/" <> server_name)
  assert simplifile.is_file(orchestrator_pid(prepared)) == Ok(False)
}

// The first line of the orchestrator's log that records `event` for `server`.
fn orchestrator_event(
  prepared: Pair,
  event: String,
  server: String,
) -> Result(String, Nil) {
  let assert Ok(log) = simplifile.read(prepared.orchestrator.paths.log)
    as "the orchestrator's log is readable"
  string.split(log, "\n")
  |> list.find(fn(line) {
    string.contains(line, "\"event\":\"" <> event <> "\"")
    && string.contains(line, "\"server\":\"" <> server <> "\"")
  })
}
