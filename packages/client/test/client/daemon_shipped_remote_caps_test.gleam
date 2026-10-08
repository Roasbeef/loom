//// A remote session's code-mode program reaches the orchestrator's state, two
//// real `bin/loomd` processes across TLS distribution (issue #697,
//// protocol-change/078).
////
//// The orchestrator holds the conversation and the executor holds the
//// checkout. The program is compiled and run on the executor, in a satellite
//// jailed beside the checkout, and its `strand.*` and `notes.*` capabilities
//// live on the orchestrator: the Agency and the blackboard are in the session
//// store there. This fixture shows the two ends meet. The executor sends each
//// owner-bound call through the owner port, and the orchestrator answers it
//// with the session's own doors.
////
//// ## What it proves
////
//// `daemon_shipped_remote_caps_test_`, one registered session and one scripted
//// model.
////
//// - The model submits one `code_mode` program. The program calls
////   `strand.roster`, then writes a note with `notes.put`, and reports.
//// - The program's own report reaches the model, so both capability calls
////   returned to the satellite on the executor.
//// - The model then reads the blackboard with `agent_notes`, a tool that runs
////   on the orchestrator. Its result holds the note, under the calling strand's
////   namespace, so the write landed in the orchestrator's session store and
////   under the strand the dispatching call named.
////
//// ## What it needs
////
//// Code mode on the executor needs a toolchain and the build seed, and the
//// jail needs platform enforcement. Without enforcement the fixture declines
//// as the other shipped fixtures do. Without `gleam`, `erl` or a seed at
//// `build/codemode-seed` it prints a skip line naming what is missing, because
//// the fixture then proves nothing about this route. `make codemode-seed`
//// prepares the seed. The fixture copies it into the executor's checkout, which
//// is the first place the executor's seed ladder looks.
////
//// ## Running it
////
//// ```sh
//// make codemode-seed
//// make server-shipment
//// make sandbox && install -m 0755 packages/sandbox/loom-exec bin/loom-exec
//// export LOOM_BOOTSTRAP_E2E_SERVER=$PWD/bin/loomd
//// export LOOM_TEST_PROVIDER_KEY=loom-provider-fixture-key
//// bash scripts/test.sh client --match 'client@daemon_shipped_remote_caps_test:'
//// ```
////
//// Without the variable the test prints a skip line and passes. It needs
//// `openssl`, `erl` and `epmd` on `PATH`, and permission to listen on loopback.
//// The coordinator retains every daemon's endpoint outside the bounded body, so
//// a failed assertion still retires the daemons it started.

import broker/token
import client/codemode
import client/tui_e2e_test.{type EunitTest, Timeout}
import core/json
import gleam/bit_array
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import host/bootstrap as native
import simplifile
import support/enforcement
import support/provider_http as provider
import support/remote_daemons.{type Identity, type Layout, Trust}
import support/tui_driver
import tui/daemon
import weft

// The executor's name for its checkout, and the name the orchestrator's
// sessions use for it.
const workspace_name = "repo"

// The orchestrator's name for the executor, an `[executors.<name>]` key.
const executor_name = "box"

// Where the executor's seed ladder looks first, relative to the checkout.
const seed_in_checkout = "build/codemode-seed"

// The key the program writes, and the text it stores. The blackboard prefixes
// the key with the calling strand, so the model reads it back under `main/`.
const note_key = "remote-proof"

const note_text = "written by a remote program"

const prompt = "run the remote program"

const answer = "remote capabilities done"

/// Starts an orchestrator and an executor from the shipment and runs one
/// code-mode program on the executor whose capabilities the orchestrator
/// answers.
///
/// ## Examples
///
/// `bash scripts/test.sh client --match 'client@daemon_shipped_remote_caps_test:'`.
pub fn daemon_shipped_remote_caps_test_() -> EunitTest {
  // The runner scales EUnit timeouts by ten: 300 seconds around the 240-second
  // body, which boots two daemons and compiles a program in a jail, and the
  // independent native cleanup after it.
  Timeout(30, fn() {
    case native.getenv("LOOM_BOOTSTRAP_E2E_SERVER") {
      Error(Nil) ->
        io.println_error(
          "SKIP shipped remote caps: LOOM_BOOTSTRAP_E2E_SERVER is unset",
        )
      Ok(server) -> gated(server)
    }
  })
}

// The jail must enforce, and code mode must have what it builds with. Both
// are properties of the host and are measured here, before any daemon starts.
fn gated(server: String) -> Nil {
  case enforcement.probe(server, "shipped remote caps") {
    enforcement.EnforcementAbsent -> Nil
    enforcement.EnforcementLive ->
      case prepared_seed() {
        Error(reason) ->
          io.println_error(
            "SKIP shipped remote caps: code mode cannot build here: " <> reason,
          )
        Ok(seed) -> fixture(seed)
      }
  }
}

// The prepared seed, when it exists beside the repository and the toolchain
// that builds from it can be found. This is the same discovery the executor
// runs, so a verdict here is the verdict there.
fn prepared_seed() -> Result(String, String) {
  use seed <- result.try(
    native.canonical_directory("../../" <> seed_in_checkout)
    |> result.replace_error(
      "no seed at build/codemode-seed (run make codemode-seed)",
    ),
  )
  use _toolchain <- result.try(codemode.discover(seed))
  Ok(seed)
}

// Everything the body needs to be retired, fixed before anything starts.
//
// The fixture lives in a shallow directory of its own, and under `/var/tmp`
// rather than `/tmp`, which the jail replaces. A code-mode execution binds a
// unix socket under the executor's state root, a socket path may be about a
// hundred bytes, and a fixture root under `packages/client/build` spends most
// of that before the socket's own name is appended.
type Fixture {
  Fixture(
    directory: String,
    orchestrator: Layout,
    executor: Layout,
    checkout: String,
    seed: String,
  )
}

fn fixture(seed: String) -> Nil {
  let directory =
    "/var/tmp/loom-remote-caps-"
    <> string.lowercase(bit_array.base16_encode(token.production_entropy()(8)))
  let assert Ok(Nil) = native.ensure_private_directory(directory)
    as "the fixture's state stays private"
  let assert Ok(directory) = native.canonical_directory(directory)
    as "the daemons receive absolute paths"
  let prepared =
    Fixture(
      directory:,
      orchestrator: remote_daemons.layout(directory, "orchestrator"),
      executor: remote_daemons.layout(directory, "executor"),
      checkout: directory <> "/executor-checkout",
      seed:,
    )
  io.println_error("shipped remote caps fixture: " <> directory)
  let outcomes =
    weft.new([
      fn() {
        remote_program(prepared)
        Ok(Nil)
      },
    ])
    |> weft.deadline(240_000)
    |> weft.start

  // Native cleanup runs outside the body's deadline and before the outcome is
  // read, so a body that failed mid-drive still retires every daemon.
  list.each([prepared.orchestrator, prepared.executor], fn(layout) {
    remote_daemons.retire(layout.paths)
  })
  let assert [weft.Completed(0, Nil)] = outcomes
    as "the shipped remote caps body completes before native teardown"
  let _removed = simplifile.delete_all([directory])
  Nil
}

// The two nodes' credentials, a cookie both read from their own homes, and
// each daemon's configuration. The executor trusts the orchestrator and the
// orchestrator trusts the executor, by pin. The orchestrator's one model is the
// scripted provider at `provider_url`.
fn configure(prepared: Fixture, provider_url: String) -> Nil {
  let secrets = prepared.directory <> "/credentials"
  let assert Ok(Nil) = native.ensure_private_directory(secrets)
    as "the credentials directory is private"
  let authority = remote_daemons.mint_authority(secrets)
  let suffix = remote_daemons.random_hex(4)
  let name = fn(role) { "loom_e2e_" <> role <> "_" <> suffix <> "@127.0.0.1" }
  let orchestrator =
    remote_daemons.issue(
      authority,
      secrets,
      "orchestrator",
      name("orch"),
      prepared.orchestrator.home,
    )
  let executor =
    remote_daemons.issue(
      authority,
      secrets,
      "executor",
      name("exec"),
      prepared.executor.home,
    )
  let cookie = "loom-e2e-cookie-" <> remote_daemons.random_hex(16)
  list.each([orchestrator, executor], fn(identity) {
    remote_daemons.write_cookie(identity, cookie)
  })
  let trust = fn(identity: Identity) { Trust(identity.node, identity.pin) }
  let write = fn(layout: Layout, text) {
    let assert Ok(Nil) = simplifile.write(layout.config, text)
      as "the daemon configuration is written"
    remote_daemons.write_options(layout)
  }
  write(
    prepared.executor,
    string.join(
      [
        remote_daemons.model_table("http://127.0.0.1:9"),
        remote_daemons.distribution_table(executor, authority, [
          trust(orchestrator),
        ]),
        remote_daemons.workspace_table(workspace_name, prepared.checkout),
      ],
      "\n",
    ),
  )
  write(
    prepared.orchestrator,
    string.join(
      [
        remote_daemons.model_table(provider_url),
        remote_daemons.distribution_table(orchestrator, authority, [
          trust(executor),
        ]),
        remote_daemons.executor_table(executor_name, executor.node),
      ],
      "\n",
    ),
  )
}

// The executor's checkout, with the build seed where its seed ladder looks
// first. The orchestrator is never told where either is.
fn make_checkout(prepared: Fixture) -> Nil {
  let assert Ok(Nil) = simplifile.create_directory_all(prepared.checkout)
    as "the executor checkout is created"
  let assert Ok(Nil) =
    simplifile.create_directory_all(prepared.checkout <> "/build")
    as "the executor checkout has a build directory"
  let assert Ok(Nil) =
    simplifile.copy_directory(
      at: prepared.seed,
      to: prepared.checkout <> "/" <> seed_in_checkout,
    )
    as "the executor checkout has the code-mode seed"
  Nil
}

// The program the model submits. Both capabilities are owner-bound: the
// roster is read from the lineage ledger and the note is written to the
// blackboard, and the executor holds neither.
fn program() -> String {
  string.join(
    [
      "import cap/notes",
      "import cap/report",
      "import cap/strand",
      "import gleam/int",
      "import gleam/list",
      "",
      "pub fn main() -> report.Outcome {",
      "  case strand.roster() {",
      "    Ok(peers) -> write(list.length(peers))",
      "    Error(error) -> report.failure(strand.error_text(error))",
      "  }",
      "}",
      "",
      "fn write(peers: Int) -> report.Outcome {",
      "  case notes.put(\""
        <> note_key
        <> "\", report.string(\""
        <> note_text
        <> "\")) {",
      "    Ok(Nil) -> report.text(\"note written, roster of \" <> int.to_string(peers))",
      "    Error(error) -> report.failure(notes.error_text(error))",
      "  }",
      "}",
      "",
    ],
    "\n",
  )
}

// The model's side: submit the program, read the blackboard, answer.
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
      provider.AwaitToolResult("program-call"),
      fn(_seen) {
        provider.ReplyToolUse(
          "notes-call",
          "agent_notes",
          json.Object([#("prefix", json.String("main/"))]),
        )
      },
    ),
    provider.ComputedExchange(provider.AwaitToolResult("notes-call"), fn(_seen) {
      provider.ReplyText(answer)
    }),
  ]
}

fn remote_program(prepared: Fixture) -> Nil {
  make_checkout(prepared)
  let #(Nil, report) =
    provider.with_server(script(), fn(url) {
      configure(prepared, url)

      // The executor starts first so that the daemon which dials it finds it up.
      let executor = remote_daemons.start(prepared.executor)
      let orchestrator = remote_daemons.start(prepared.orchestrator)
      let control = remote_daemons.open_control(orchestrator)
      let #(session, settled) =
        remote_daemons.create_and_settle(
          control,
          1,
          "e2e-remote-caps",
          executor_name,
          workspace_name,
        )
      assert remote_daemons.settled_state(settled) == "resident"
      let terminal = remote_daemons.attach(orchestrator, session)
      remote_daemons.say(terminal, prompt)

      // Compiling a program in a jail takes tens of seconds before it runs.
      remote_daemons.await_answers(terminal, [answer], 200_000)
      tui_driver.stop(terminal)
      list.each([executor, orchestrator], fn(running) {
        daemon.close(running.connected.control)
      })
    })
  let assert Ok(requests) = report
    as "the provider saw exactly the scripted conversation"
  assert_results(requests)
}

// What the model was handed back. The program's report holds the text it ends
// with, so the satellite on the executor got an answer to both calls. The
// blackboard read holds the note under the calling strand's namespace, so the
// write reached the orchestrator's session store for strand `main`.
fn assert_results(requests: List(provider.ObservedRequest)) -> Nil {
  let program_result = remote_daemons.result_text(requests, "program-call")
  assert string.contains(program_result, "note written, roster of ")
  let blackboard = remote_daemons.result_text(requests, "notes-call")
  assert string.contains(blackboard, "main/" <> note_key)
  assert string.contains(blackboard, note_text)
}
