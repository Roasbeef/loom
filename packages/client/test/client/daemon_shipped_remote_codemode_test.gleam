//// Code mode and language servers on a registered session, against the shipped
//// daemon: an orchestrator and an executor, two real `bin/loomd` processes that
//// trust each other over TLS distribution (issue #697, protocol-change/078).
////
//// `daemon_shipped_remote_test` proves that the plain workspace tools reach the
//// executor's checkout. Phase 1 of the distributed runtime also requires the
//// two heavier effects to work there: code mode's Compile and Launch, and the
//// language-server queries, rename and diagnostics. Both run beside the
//// checkout on the executor, so the orchestrator holds no source, no toolchain
//// and no language server. This module drives each one through a model turn and
//// reads the result where the model reads it.
////
//// ## What it proves
////
//// `daemon_shipped_remote_codemode_test_`, one session with two `code_mode`
//// calls.
////
//// - The executor was handed the repository's build seed with `--codemode-seed`,
////   as a local daemon is; the orchestrator was given none. The program's
////   build directory is in the executor's checkout and the orchestrator holds
////   no directory of that name.
//// - A program is vetted, compiled against the executor's toolchain and seed,
////   launched in a satellite on the executor, and reports a value computed in
////   the program together with the text of `README.md`, which only the
////   executor's checkout holds. The program also writes a file through
////   `cap/fs`. That file lands in the executor's checkout and nowhere on the
////   orchestrator, and the result reaches the model.
//// - A program that does not compile comes back to the model as an error
////   result that names the compiler's diagnostic.
//// - Stopping the session closes the executor's scope `closed` with
////   `all_retired`, so the satellites and the build were retired with it.
////
//// `daemon_shipped_remote_lsp_test_`, one session over a Gleam project.
////
//// - The executor's `loom.toml` carries an `[lsp.gleam]` table running
////   `gleam lsp`. The orchestrator's has none. A `cap/lsp` program asks for the
////   hover, definition and references of `greet`, and the answers come from the
////   server the executor started in its jail.
//// - A rename preview names the three files and writes nothing. The apply then
////   edits every file in the executor's checkout, byte for byte, and reports
////   settled diagnostics with no entry.
//// - An `fs_write` of a file that does not type check returns, in the same
////   result the model reads, a settled diagnostics block with one error. A
////   `cap/lsp.diagnostics` program reads the same error back.
//// - None of the project's files, or the new one, exists on the orchestrator,
////   and stopping the session closes the executor's scope `all_retired`, which
////   covers the language server.
////
//// ## Prerequisites and skips
////
//// The code-mode test needs the build seed `make codemode-seed` prepares. The
//// language-server test needs that and `gleam` and `rg` on `PATH`, because the
//// server is `gleam lsp` and a bare symbol is found with `rg`. A host without
//// one prints a `SKIP shipped remote code mode: ...` line naming it and passes,
//// as the other shipped fixtures do, so a host without a prerequisite is not a
//// failure and a host with all of them runs both tests.
////
//// ## Running it
////
//// ```sh
//// make server-shipment
//// make sandbox && install -m 0755 packages/sandbox/loom-exec bin/loom-exec
//// export LOOM_BOOTSTRAP_E2E_SERVER=$PWD/bin/loomd
//// export LOOM_TEST_PROVIDER_KEY=loom-provider-fixture-key
//// bash scripts/test.sh client --match 'client@daemon_shipped_remote_codemode_test:'
//// ```
////
//// The fixture is the one `daemon_shipped_remote_test` documents: openssl-minted
//// credentials, a cookie at each node's own home, and `loomd distribution
//// options` for each daemon's boot flags. It needs no probe node, because
//// neither test asks who is connected.

import broker/token
import client/tui_e2e_test.{type EunitTest, Timeout}
import core/json
import filepath
import gleam/bit_array
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/string
import host/bootstrap as native
import simplifile
import storage/exec_ledger
import support/enforcement
import support/provider_http as provider
import support/remote_daemons.{type Identity, type Layout, type Running, Trust}
import support/tui_driver
import tui/daemon
import weft

// The executor's name for its checkout and the orchestrator's name for the
// executor, as in `daemon_shipped_remote_test`.
const workspace_name = "repo"

const executor_name = "box"

// The provider callback boots two daemons, compiles a program or starts a
// language server, and drives several turns, so it states a budget well past
// the default 120 seconds. The fixture's own deadline outlasts it, and the
// EUnit timeout (scaled by ten by the runner) outlasts both.
const callback_ms = 420_000

const body_ms = 480_000

const eunit_seconds = 60

// How long a terminal waits for a turn to finish. A first compile clones the
// build seed and a first language-server query compiles the project.
const turn_ms = 240_000

/// Compiles and launches code-mode programs on the executor.
///
/// ## Examples
///
/// `bash scripts/test.sh client --match 'client@daemon_shipped_remote_codemode_test:'`.
pub fn daemon_shipped_remote_codemode_test_() -> EunitTest {
  shipped(NeedsSeed, code_mode_session)
}

/// Queries, renames and diagnoses a Gleam project through the executor's
/// language server.
///
/// ## Examples
///
/// `bash scripts/test.sh client --match 'client@daemon_shipped_remote_codemode_test:'`.
pub fn daemon_shipped_remote_lsp_test_() -> EunitTest {
  shipped(NeedsSeedAndGleam, lsp_session)
}

// What a test needs from the host beyond the shipped daemon and a jail.
type Needs {
  NeedsSeed
  NeedsSeedAndGleam
}

fn shipped(needs: Needs, body: fn(Fixture, String) -> Nil) -> EunitTest {
  Timeout(eunit_seconds, fn() {
    case native.getenv("LOOM_BOOTSTRAP_E2E_SERVER") {
      Error(Nil) ->
        io.println_error(
          "SKIP shipped remote: LOOM_BOOTSTRAP_E2E_SERVER is unset",
        )

      // The executor jails every call, so a host whose helper cannot enforce a
      // policy declines the fixture under the label and reason the other remote
      // fixture declares.
      Ok(server) ->
        case enforcement.probe(server, "shipped remote") {
          enforcement.EnforcementAbsent -> Nil
          enforcement.EnforcementLive ->
            case prerequisites(needs) {
              Ok(seed) -> fixture(fn(prepared) { body(prepared, seed) })
              Error(reason) ->
                io.println_error("SKIP shipped remote code mode: " <> reason)
            }
        }
    }
  })
}

// The build seed's path, or the first thing the host lacks. The seed is
// `make codemode-seed`'s output at the repository root, which is two levels up
// from the client package the tests run in.
fn prerequisites(needs: Needs) -> Result(String, String) {
  case native.canonical_directory("../../build/codemode-seed") {
    Error(_) -> Error("no code-mode build seed at build/codemode-seed")
    Ok(seed) ->
      case needs {
        NeedsSeed -> Ok(seed)
        NeedsSeedAndGleam ->
          case native.find_executable("gleam"), native.find_executable("rg") {
            Ok(_), Ok(_) -> Ok(seed)
            Error(_), _ -> Error("gleam is not on PATH")
            _, Error(_) -> Error("rg is not on PATH")
          }
      }
  }
}

// Everything the body needs to be retired, fixed before anything starts.
//
// The fixture's directory is a short one under `/var/tmp`, not under `build/`.
// The executor binds code mode's capability socket below its state root, and
// an AF_UNIX path has a budget of about a hundred bytes that a worktree's
// `packages/client/build/...` spends before the socket's own name. It is
// `/var/tmp` and not `/tmp` because the jail replaces `/tmp` with its scratch
// tmpfs. The directory is removed when the body passes and kept, with both
// daemons' logs, when it fails.
type Fixture {
  Fixture(
    directory: String,
    orchestrator: Layout,
    executor: Layout,
    checkout: String,
  )
}

fn fixture(body: fn(Fixture) -> Nil) -> Nil {
  let directory =
    "/var/tmp/loom-rcm-"
    <> string.lowercase(bit_array.base16_encode(token.production_entropy()(4)))
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
    )
  io.println_error("shipped remote code mode fixture: " <> directory)
  let outcomes =
    weft.new([
      fn() {
        body(prepared)
        Ok(Nil)
      },
    ])
    |> weft.deadline(body_ms)
    |> weft.start

  // Native cleanup runs outside the body's deadline and before the outcome is
  // read, so a body that failed mid-drive still retires every daemon.
  list.each([prepared.orchestrator, prepared.executor], fn(l) {
    remote_daemons.retire(l.paths)
  })
  let assert [weft.Completed(0, Nil)] = outcomes
    as "the shipped remote body completes before native teardown"
  let _removed = simplifile.delete_all([prepared.directory])
  Nil
}

// The two nodes of the trust graph, with every credential they need.
type Credentials {
  Credentials(
    authority: remote_daemons.Authority,
    orchestrator: Identity,
    executor: Identity,
  )
}

fn provision(prepared: Fixture) -> Credentials {
  let secrets = prepared.directory <> "/credentials"
  let assert Ok(Nil) = native.ensure_private_directory(secrets)
    as "the credentials directory is private"
  let authority = remote_daemons.mint_authority(secrets)
  let suffix = remote_daemons.random_hex(4)
  let name = fn(role) { "loom_e2e_" <> role <> "_" <> suffix <> "@127.0.0.1" }
  let keys =
    Credentials(
      authority:,
      orchestrator: remote_daemons.issue(
        authority,
        secrets,
        "orchestrator",
        name("orch"),
        prepared.orchestrator.home,
      ),
      executor: remote_daemons.issue(
        authority,
        secrets,
        "executor",
        name("exec"),
        prepared.executor.home,
      ),
    )

  // One cookie for the whole cluster. Each VM reads it from its own home.
  let cookie = "loom-e2e-cookie-" <> remote_daemons.random_hex(16)
  list.each([keys.orchestrator, keys.executor], fn(identity) {
    remote_daemons.write_cookie(identity, cookie)
  })
  keys
}

// The orchestrator's one model is the scripted provider at `provider_url`; the
// executor never takes a model turn. `executor_tables` is whatever else the
// executor's own `loom.toml` carries, which is where a language server is
// configured: it names a command on the executor's machine.
fn configure(
  prepared: Fixture,
  keys: Credentials,
  provider_url: String,
  executor_tables: String,
) -> Nil {
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
        remote_daemons.distribution_table(keys.executor, keys.authority, [
          Trust(keys.orchestrator.node, keys.orchestrator.pin),
        ]),
        remote_daemons.workspace_table(workspace_name, prepared.checkout),
        executor_tables,
      ],
      "\n",
    ),
  )
  write(
    prepared.orchestrator,
    string.join(
      [
        remote_daemons.model_table(provider_url),
        remote_daemons.distribution_table(keys.orchestrator, keys.authority, [
          Trust(keys.executor.node, keys.executor.pin),
        ]),
        remote_daemons.executor_table(executor_name, keys.executor.node),
      ],
      "\n",
    ),
  )
}

fn write_checkout(prepared: Fixture, files: List(#(String, String))) -> Nil {
  list.each(files, fn(file) {
    let path = prepared.checkout <> "/" <> file.0
    let assert Ok(Nil) = simplifile.create_directory_all(parent_directory(path))
      as "the executor checkout directory is created"
    let assert Ok(Nil) = simplifile.write(path, file.1)
      as "the executor checkout file is written"
    Nil
  })
}

fn parent_directory(path: String) -> String {
  let segments = string.split(path, "/")
  segments
  |> list.take(list.length(segments) - 1)
  |> string.join("/")
}

fn read_checkout(prepared: Fixture, path: String) -> String {
  let assert Ok(text) = simplifile.read(prepared.checkout <> "/" <> path)
    as { "the executor checkout holds " <> path }
  text
}

// Opens a registered session on the executor and returns the orchestrator, its
// control socket and the session. The executor starts first so that the daemon
// which dials it finds it up.
fn open_registered(
  prepared: Fixture,
  executor_flags: List(String),
  key: String,
) -> #(Running, remote_daemons.Control, String) {
  let _executor = remote_daemons.start_with(prepared.executor, executor_flags)
  let orchestrator = remote_daemons.start(prepared.orchestrator)
  let control = remote_daemons.open_control(orchestrator)
  let #(session, settled) =
    remote_daemons.create_and_settle(
      control,
      1,
      key,
      executor_name,
      workspace_name,
    )
  assert remote_daemons.settled_state(settled) == "resident"
  #(orchestrator, control, session)
}

// Sends one prompt and waits for the turn's final text.
fn converse_for(
  orchestrator: Running,
  session: String,
  prompt: String,
  answer: String,
) -> Nil {
  let terminal = remote_daemons.attach(orchestrator, session)
  remote_daemons.say(terminal, prompt)
  remote_daemons.await_answers(terminal, [answer], turn_ms)
  tui_driver.stop(terminal)
}

// Stops the session and reads how the executor closed its scope.
fn assert_closes_clean(
  prepared: Fixture,
  orchestrator: Running,
  control: remote_daemons.Control,
  session: String,
) -> Nil {
  remote_daemons.stop_session(orchestrator, control, 100, session)
  let scope =
    remote_daemons.executor_scope(
      prepared.executor,
      prepared.directory <> "/ledger-copies",
      session,
    )
  assert scope.incarnation == 1
  assert scope.state == exec_ledger.Closed(exec_ledger.AllRetired)
  assert scope.workspace == workspace_name
}

fn close_daemons(running: List(Running)) -> Nil {
  list.each(running, fn(each) { daemon.close(each.connected.control) })
}

// --- code mode ---------------------------------------------------------------

const readme = "executor only\n"

// The program writes a file and reads one back through `cap/fs`, and computes a
// number. The product is arithmetic only a compiled program produces; the text
// is only in the executor's checkout.
const program_written = "program-wrote.txt"

const program_written_text = "written by a program on the executor\n"

fn working_program() -> String {
  "import cap/fs\n"
  <> "import cap/report\n"
  <> "import gleam/int\n"
  <> "\n"
  <> "pub fn main() -> report.Outcome {\n"
  <> "  case fs.write(\""
  <> program_written
  <> "\", \"written by a program on the executor\\n\") {\n"
  <> "    Ok(Nil) ->\n"
  <> "      case fs.read(\"README.md\") {\n"
  <> "        Ok(text) ->\n"
  <> "          report.text(\"code-mode-ok \" <> int.to_string(6 * 7) <> \" \" <> text)\n"
  <> "        Error(error) -> report.failure(fs.error_text(error))\n"
  <> "      }\n"
  <> "    Error(error) -> report.failure(fs.error_text(error))\n"
  <> "  }\n"
  <> "}\n"
}

// `report.text` takes a String, not an Int, so this does not compile.
fn broken_program() -> String {
  "import cap/report\n"
  <> "\n"
  <> "pub fn main() -> report.Outcome {\n"
  <> "  report.text(1)\n"
  <> "}\n"
}

fn program_arguments(source: String) -> json.JsonValue {
  json.Object([
    #("program", json.String(source)),
    #("within_ms", json.Int(240_000)),
  ])
}

const code_prompt = "run the programs"

const code_answer = "code mode done"

fn code_mode_script() -> List(provider.Exchange) {
  [
    provider.ToolUseExchange(
      code_prompt,
      "program-call",
      "code_mode",
      program_arguments(working_program()),
    ),
    provider.ComputedExchange(
      provider.AwaitToolResult("program-call"),
      fn(_seen) {
        provider.ReplyToolUse(
          "broken-call",
          "code_mode",
          program_arguments(broken_program()),
        )
      },
    ),
    provider.ComputedExchange(
      provider.AwaitFailedToolResult("broken-call"),
      fn(_seen) { provider.ReplyText(code_answer) },
    ),
  ]
}

fn code_mode_session(prepared: Fixture, seed: String) -> Nil {
  let keys = provision(prepared)
  write_checkout(prepared, [#("README.md", readme)])
  let #(Nil, report) =
    provider.with_server_for(
      code_mode_script(),
      provider.AlsoFailed,
      callback_ms,
      fn(url) {
        configure(prepared, keys, url, "")
        let #(orchestrator, control, session) =
          open_registered(prepared, ["--codemode-seed", seed], "e2e-code-mode")
        converse_for(orchestrator, session, code_prompt, code_answer)
        assert_code_mode_state_on_executor(prepared, orchestrator)

        // The program's file is where the executor keeps its checkout, with
        // the content the program wrote, and the orchestrator holds nothing
        // by that name.
        assert read_checkout(prepared, program_written) == program_written_text
        remote_daemons.assert_absent_from(
          [orchestrator.layout.directory, orchestrator.layout.home],
          program_written,
        )
        assert_closes_clean(prepared, orchestrator, control, session)
        close_daemons([orchestrator])
      },
    )
  let assert Ok(requests) = report
    as "the provider saw both programs' results and nothing else"
  let ran = remote_daemons.result_text(requests, "program-call")
  assert string.contains(ran, "code-mode-ok 42 executor only")
  let broken = remote_daemons.failed_result_text(requests, "broken-call")
  assert string.contains(broken, "did not compile")
  assert string.contains(broken, "report.text")
}

// The program's build and its blobs are in the executor's checkout, which is
// where the workspace plane keeps them, and the orchestrator holds no directory
// of either name. The orchestrator was given no seed, so it could not have
// compiled the program itself.
fn assert_code_mode_state_on_executor(
  prepared: Fixture,
  orchestrator: Running,
) -> Nil {
  assert simplifile.is_directory(prepared.checkout <> "/.codemode") == Ok(True)
  list.each([".codemode", ".blobs"], fn(name) {
    remote_daemons.assert_absent_from(
      [orchestrator.layout.directory, orchestrator.layout.home],
      name,
    )
  })
}

// --- language server ----------------------------------------------------------

// The sandbox helper by its real path. The isolated launcher puts a symbolic
// link to the helper beside itself, and the daemon is given that link as its
// `--helper`. The helper runs a jailed command by re-executing itself inside
// the sandbox profile, and a language server's profile reads only the system
// directories and the project, so the profile cannot follow a link that lives
// in the fixture's home. `bash` and code mode run under a profile that reads the
// whole host and never notice. A real installation names the helper where it is.
fn real_helper() -> String {
  let assert Ok(server) = native.getenv("LOOM_BOOTSTRAP_E2E_SERVER")
    as "the shipped server is named, or this test was skipped"
  let assert Ok(directory) =
    native.canonical_directory(filepath.directory_name(server))
    as "the shipped server's directory exists"
  filepath.join(directory, "loom-exec")
}

// The Gleam project the executor holds: three modules and one function they
// share, as the conformance fixture has it. `greet` is defined in `app/util`,
// called twice on one line of `app/other`, and once from the entry module.
const gleam_toml_text =
  "name = \"app\"\nversion = \"1.0.0\"\ntarget = \"erlang\"\n"

const util_source =
  "pub fn greet(name: String) -> String {
  \"Hello, \" <> name
}
"

const other_source =
  "import app/util

pub fn twice(name: String) -> String {
  util.greet(name) <> util.greet(name)
}
"

const app_source =
  "import app/other
import app/util

pub fn main() -> String {
  util.greet(\"world\") <> other.twice(\"again\")
}
"

// The three files after the rename, byte for byte.
const util_renamed =
  "pub fn welcome(name: String) -> String {
  \"Hello, \" <> name
}
"

const other_renamed =
  "import app/util

pub fn twice(name: String) -> String {
  util.welcome(name) <> util.welcome(name)
}
"

const app_renamed =
  "import app/other
import app/util

pub fn main() -> String {
  util.welcome(\"world\") <> other.twice(\"again\")
}
"

// A module that does not type check: a function declared to return an `Int`
// that returns a string.
const broken_path = "src/app/broken.gleam"

const broken_source =
  "pub fn broken() -> Int {
  \"not an int\"
}
"

// The executor's language-server table: `gleam lsp` writes its manifest and
// `build/` into the project, so the project is writable. It is the documented
// table, and it is the executor's machine configuration, not the orchestrator's.
const lsp_table =
  "
[lsp.gleam]
command = [\"gleam\", \"lsp\"]
extensions = [\".gleam\"]
root_markers = [\"gleam.toml\"]
project = \"writable\"
"

const query_program =
  "import cap/lsp
import cap/report
import gleam/int
import gleam/list
import gleam/string

fn site(value: lsp.Site) -> String {
  value.path <> \":\" <> int.to_string(value.line)
}

pub fn main() -> report.Outcome {
  let query = lsp.in(lsp.at_line(lsp.symbol(\"greet\"), 1), \"src/app/util.gleam\")
  case lsp.hover(query), lsp.definition(query), lsp.references(query) {
    Ok(hover), Ok(definitions), Ok(references) ->
      report.text(
        \"hover \" <> hover
        <> \"\\ndefinition \" <> string.join(list.map(definitions.items, site), \",\")
        <> \"\\nreferences \" <> int.to_string(references.total) <> \" \"
        <> string.join(list.map(references.items, fn(reference) { site(reference.site) }), \",\"),
      )
    hover, definitions, references ->
      report.failure(string.inspect(#(hover, definitions, references)))
  }
}
"

const preview_program =
  "import cap/lsp
import cap/report
import gleam/list
import gleam/string

pub fn main() -> report.Outcome {
  case lsp.rename(lsp.symbol(\"greet\"), \"welcome\", lsp.Preview) {
    Ok(lsp.Previewed(files)) ->
      report.text(\"previewed \" <> string.join(list.map(files, fn(file) { file.path }), \",\"))
    Ok(lsp.Applied(_, _)) -> report.failure(\"a preview applied\")
    Error(error) -> report.failure(string.inspect(error))
  }
}
"

const apply_program =
  "import cap/lsp
import cap/report
import gleam/int
import gleam/list
import gleam/string

fn landed(file: lsp.Landing) -> Bool {
  case file {
    lsp.Landed(_, _) -> True
    lsp.Rejected(_, _) | lsp.NotAttempted(_) -> False
  }
}

pub fn main() -> report.Outcome {
  case lsp.rename(lsp.symbol(\"greet\"), \"welcome\", lsp.Apply) {
    Ok(lsp.Applied(files, after)) -> {
      let #(status, count) = case after {
        lsp.Settled(items) -> #(\"settled\", list.length(items))
        lsp.Unsettled(items) -> #(\"unsettled\", list.length(items))
      }
      report.text(
        \"applied \" <> int.to_string(list.count(files, landed)) <> \" of \"
        <> int.to_string(list.length(files)) <> \" \" <> status <> \" \"
        <> int.to_string(count),
      )
    }
    Ok(lsp.Previewed(_)) -> report.failure(\"an apply only previewed\")
    Error(error) -> report.failure(string.inspect(error))
  }
}
"

const diagnostics_program =
  "import cap/lsp
import cap/report
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string

pub fn main() -> report.Outcome {
  case lsp.diagnostics(Some(\"src/app/broken.gleam\")) {
    Ok(lsp.Settled(items)) ->
      report.text(
        \"settled \" <> int.to_string(list.length(items)) <> \" \"
        <> string.join(list.map(items, fn(item) { item.message }), \" | \"),
      )
    Ok(lsp.Unsettled(_)) -> report.failure(\"diagnostics did not settle\")
    Error(error) -> report.failure(string.inspect(error))
  }
}
"

const lsp_prompt = "work on the project"

const lsp_answer = "lsp done"

// The model's side: query, preview, apply, write a broken file, read its
// diagnostics, answer. The reply to the preview's result first reads the three
// files from the executor's disk and sends them to `snapshots`, so the test can
// say what the preview left there.
fn lsp_script(
  prepared: Fixture,
  snapshots: process.Subject(#(String, String, String)),
) -> List(provider.Exchange) {
  let next = fn(after: String, call: String, tool: String, arguments) {
    provider.ComputedExchange(provider.AwaitToolResult(after), fn(_seen) {
      provider.ReplyToolUse(call, tool, arguments)
    })
  }
  [
    provider.ToolUseExchange(
      lsp_prompt,
      "query-call",
      "code_mode",
      program_arguments(query_program),
    ),
    next(
      "query-call",
      "preview-call",
      "code_mode",
      program_arguments(preview_program),
    ),
    provider.ComputedExchange(
      provider.AwaitToolResult("preview-call"),
      fn(_seen) {
        process.send(snapshots, read_project(prepared))
        provider.ReplyToolUse(
          "apply-call",
          "code_mode",
          program_arguments(apply_program),
        )
      },
    ),
    next(
      "apply-call",
      "write-call",
      "fs_write",
      json.Object([
        #("path", json.String(broken_path)),
        #("content", json.String(broken_source)),
      ]),
    ),
    next(
      "write-call",
      "diagnostics-call",
      "code_mode",
      program_arguments(diagnostics_program),
    ),
    provider.ComputedExchange(
      provider.AwaitToolResult("diagnostics-call"),
      fn(_seen) { provider.ReplyText(lsp_answer) },
    ),
  ]
}

// The three modules as the executor's disk holds them, util first.
fn read_project(prepared: Fixture) -> #(String, String, String) {
  #(
    read_checkout(prepared, "src/app/util.gleam"),
    read_checkout(prepared, "src/app/other.gleam"),
    read_checkout(prepared, "src/app.gleam"),
  )
}

fn lsp_session(prepared: Fixture, seed: String) -> Nil {
  let keys = provision(prepared)
  write_checkout(prepared, [
    #("gleam.toml", gleam_toml_text),
    #("src/app/util.gleam", util_source),
    #("src/app/other.gleam", other_source),
    #("src/app.gleam", app_source),
  ])
  let snapshots = process.new_subject()
  let #(Nil, report) =
    provider.with_server_for(
      lsp_script(prepared, snapshots),
      provider.OnlySuccessful,
      callback_ms,
      fn(url) {
        configure(prepared, keys, url, lsp_table)
        let #(orchestrator, control, session) =
          open_registered(
            prepared,
            ["--codemode-seed", seed, "--helper", real_helper()],
            "e2e-lsp",
          )
        converse_for(orchestrator, session, lsp_prompt, lsp_answer)

        // The rename edited the executor's files, and the new file is there.
        assert read_project(prepared)
          == #(util_renamed, other_renamed, app_renamed)
        assert read_checkout(prepared, broken_path) == broken_source

        // The orchestrator holds no part of the project.
        list.each(
          ["gleam.toml", "util.gleam", "other.gleam", "broken.gleam"],
          fn(name) {
            remote_daemons.assert_absent_from(
              [orchestrator.layout.directory, orchestrator.layout.home],
              name,
            )
          },
        )
        assert_closes_clean(prepared, orchestrator, control, session)
        close_daemons([orchestrator])
      },
    )
  let assert Ok(requests) = report
    as "the provider saw the five tool results and nothing else"
  assert_queries(requests)
  assert_rename(requests, snapshots)
  assert_diagnostics(requests)
}

// The hover, the definition and the references, as the model read them.
fn assert_queries(requests: List(provider.ObservedRequest)) -> Nil {
  let answer = remote_daemons.result_text(requests, "query-call")
  assert string.contains(answer, "fn(String) -> String")
  assert string.contains(answer, "definition src/app/util.gleam:1")
  assert string.contains(answer, "references 4 ")
  assert string.contains(answer, "src/app/other.gleam:4")
  assert string.contains(answer, "src/app.gleam:5")
}

// The preview named all three files and wrote none; the apply landed all three
// and the server settled with nothing to report.
fn assert_rename(
  requests: List(provider.ObservedRequest),
  snapshots: process.Subject(#(String, String, String)),
) -> Nil {
  let preview = remote_daemons.result_text(requests, "preview-call")
  assert string.contains(preview, "previewed ")
  assert string.contains(preview, "src/app/util.gleam")
  assert string.contains(preview, "src/app/other.gleam")
  assert string.contains(preview, "src/app.gleam")
  let assert Ok(before_apply) = process.receive(snapshots, within: 0)
    as "the script read the disk between the preview and the apply"
  assert before_apply == #(util_source, other_source, app_source)
  let applied = remote_daemons.result_text(requests, "apply-call")
  assert string.contains(applied, "applied 3 of 3 settled 0")
}

// The write's own result carries the settled block with the one error, and a
// program reads the same error back.
fn assert_diagnostics(requests: List(provider.ObservedRequest)) -> Nil {
  let written = remote_daemons.result_text(requests, "write-call")
  assert string.contains(written, "diagnostics (settled): 1 (1 error)")
  assert string.contains(written, broken_path)
  let read = remote_daemons.result_text(requests, "diagnostics-call")
  assert string.contains(read, "settled 1 ")
}
