//// A host-defined seam on an untrusted executor, end to end
//// (protocol-change/111 over protocol-change/109).
////
//// The executor is the real one: `executor_plane`'s factory over a checkout of
//// a small Gleam project, with the repository's build seed and a `gleam lsp`
//// server in its own machine configuration, behind the untrusted gateway. The
//// orchestrator side is the link, an owner port whose plan carries aegis's seam
//// and whose capability answer is the owner's arms with the host's tools, and a
//// surface attached through the link's name. Nothing is a distribution peer.
////
//// One program is vetted, compiled and run in a satellite in the executor's
//// jail. It greps the checkout with `cap/search` and asks `cap/lsp` for a hover,
//// both answered on the executor, and calls `cap/aegis.file_finding` twice;
//// each host call returns over the link as an owner callback and is answered by
//// the host's own tool on the orchestrator. The second is refused by the tool
//// and the program reads the tool's own sentence. A program importing
//// `cap/fs` is refused at vetting on the executor.
////
//// It needs the build seed (`make codemode-seed`), `gleam` on `PATH` and a
//// kernel that can jail, and prints a `SKIP` line naming what is missing.

import broker/exec
import client/catalog
import client/codemode
import client/executor_plane
import client/internal/ffi_os
import client/jobs
import client/owner_codemode
import client/owner_codemode_test
import client/owner_services
import client/remote/host
import client/remote/owner_port
import client/remote/protocol
import client/remote/surface
import client/remote/untrusted_gateway
import client/remote/untrusted_link
import client/state_transfer
import client/workspaces
import core/clock
import core/json
import core/message
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import provider/secret
import runtime/effects.{type ToolOutcome, type ToolRun}
import simplifile
import storage/exec_ledger
import support/host_fixtures
import support/remote_fixtures as fixtures
import support/untrusted_rig as rig
import telemetry/log

// The project the executor's checkout holds.
const gleam_toml = "name = \"app\"\nversion = \"1.0.0\"\ntarget = \"erlang\"\n"

const util_source =
  "pub fn greet(name: String) -> String {
  \"Hello, \" <> name
}
"

// The executor's language-server table, from its own configuration.
const lsp_table =
  "
[lsp.gleam]
command = [\"gleam\", \"lsp\"]
extensions = [\".gleam\"]
root_markers = [\"gleam.toml\"]
project = \"writable\"
"

const program =
  "import cap/aegis
import cap/lsp
import cap/mcp
import cap/report
import cap/search
import gleam/int
import gleam/string

pub fn main() -> report.Outcome {
  let query = lsp.in(lsp.at_line(lsp.symbol(\"greet\"), 1), \"src/app/util.gleam\")
  case
    search.grep_text(under: \"src\", matching: \"pub fn greet\"),
    lsp.hover(query),
    aegis.file_finding(title: \"greet\", stage: \"hypotheses\", options: aegis.file_finding_defaults),
    aegis.file_finding(title: \"greet\", stage: \"validation\", options: aegis.file_finding_defaults)
  {
    Ok(lines), Ok(hover), Ok(filed), Error(mcp.ToolFailed(message:, ..)) ->
      report.text(
        \"grep \" <> string.join(lines, \",\")
        <> \"\\nhover \" <> hover
        <> \"\\nfiled \" <> int.to_string(filed.id)
        <> \"\\nrefused \" <> message,
      )
    grep, hover, filed, refused ->
      report.failure(string.inspect(#(grep, hover, filed, refused)))
  }
}
"

const refused_program =
  "import cap/fs
import cap/report

pub fn main() -> report.Outcome {
  case fs.read(\"gleam.toml\") {
    Ok(_) -> report.text(\"read\")
    Error(_) -> report.failure(\"no\")
  }
}
"

pub fn a_program_on_an_untrusted_executor_reaches_the_hosts_tools_test() {
  case prerequisites() {
    Error(reason) ->
      io.println_error("SKIP untrusted host code mode: " <> reason)
    Ok(seed) -> drive(seed)
  }
}

fn prerequisites() -> Result(String, String) {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner has a working directory"
  let seed = here <> "/../../build/codemode-seed"
  case
    exec.unjailed_skip_reason(exec.host_platform()),
    codemode.discover(seed),
    bootstrap.find_executable("gleam")
  {
    Some(reason), _, _ -> Error(reason)
    None, Error(reason), _ -> Error(reason)
    None, Ok(_), Error(_) -> Error("gleam is not on PATH")
    None, Ok(_), Ok(_) -> Ok(seed)
  }
}

fn drive(seed: String) -> Nil {
  let scratch = shallow_scratch()
  let checkout = scratch <> "/checkout"
  let state = scratch <> "/state"
  let assert Ok(Nil) = simplifile.create_directory_all(checkout <> "/src/app")
    as "the checkout is created"
  let assert Ok(Nil) = simplifile.write(checkout <> "/gleam.toml", gleam_toml)
    as "the project file is written"
  let assert Ok(Nil) =
    simplifile.write(checkout <> "/src/app/util.gleam", util_source)
    as "the module is written"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(state)
    as "the state root is created"
  let assert Ok(checkout) = bootstrap.canonical_directory(checkout)
    as "the checkout resolves"
  let assert Ok(state) = bootstrap.canonical_directory(state)
    as "the state root resolves"
  establish(state)

  // The executor: the real factory, its host, and the gateway in front of it.
  let machine = machine(state, seed)
  let served = [workspaces.shared("proj", checkout)]
  let assert Ok(trees) = executor_plane.worktrees_of(machine, served)
    as "the worktrees start"
  let assert Ok(started) =
    host.start(host.Config(
      name: process.new_name("untrusted_host_codemode_host"),
      ledger_path: state <> "/exec-ledger.db",
      limits: exec_ledger.default_limits(),
      max_result_bytes: host.default_max_result_bytes,
      clock: clock.from_function(ffi_os.system_time_ms),
      factory: executor_plane.factory(machine, served, trees),
      execution_result_bytes: host.default_execution_result_bytes,
      states: state_transfer.declining(),
    ))
    as "the host starts"
  let pair = rig.pair("host-codemode")
  let assert Ok(gateway) =
    untrusted_gateway.start(untrusted_gateway.Config(
      address: "127.0.0.1",
      port: 0,
      credentials: pair.executor,
      orchestrators: [pair.orchestrator_pin],
      host: started.data,
      logger: log.discard(),
    ))
    as "the gateway starts"

  // The orchestrator: the link, and an owner port that sends aegis's seam and
  // answers the host module from the host's tools.
  let name = process.new_name("untrusted_host_codemode_link")
  let assert Ok(link) =
    untrusted_link.start(untrusted_link.Config(
      executor: "pod",
      name:,
      host: "127.0.0.1",
      port: gateway.port,
      pin: pair.executor_pin,
      credentials: pair.orchestrator,
      mint: untrusted_link.strong_binding,
      logger: log.discard(),
    ))
    as "the link starts"
  let layer = host_fixtures.layer()
  let seen = process.new_subject()
  let side =
    codemode.OwnerSide(
      ..codemode.owner_serving(
        codemode.BothSeams,
        over: owner_codemode_test.agency_over(seen),
        schedules: None,
      ),
      host: Some(codemode.OwnerHost(
        layer,
        clock.fixed(at: 0),
        Some(fn(_caller, _tool) { Ok(Nil) }),
      )),
    )
  let services =
    owner_services.OwnerServices(
      ..fixtures.quiet_services(),
      capability: owner_codemode.answering(
        side,
        peers: owner_codemode_test.mailbox(seen),
      ),
      holds: fn(_caller, _tool) { Ok(Nil) },
    )
  let assert Ok(port) =
    owner_port.start(owner_port.Config(
      services:,
      clock: clock.fixed(at: 1000),
      settled: fn(_key) { False },
      reconcile_every_ms: 60_000,
      executions: owner_port.no_executions(),
      mcp: protocol.McpPlan(
        ..protocol.empty_mcp_plan(),
        host: owner_codemode.host_plan(Some(layer)),
      ),
      git_identity: None,
    ))
    as "the owner port starts"
  let assert Ok(attachment) =
    surface.attach(surface.Config(
      address: untrusted_link.address(name),
      session: "s1",
      workspace: "proj",
      incarnation: 0,
      port:,
      read_authority: fn(_run) { Ok(fixtures.authority()) },
      reconnect: fn() { Ok(Nil) },
      remote_tools: ["code_mode"],
      attach_within_ms: 120_000,
      mint_token: surface.strong_token,
    ))
    as "the session attaches through the link"

  // The executor describes the seam it was sent: the host module in the index
  // (its full types are a `cap://aegis` read away), and none of the modules
  // the host refused.
  let assert Ok(code_mode) =
    list.find(attachment.attached.census.tools, fn(described) {
      described.name == "code_mode"
    })
    as "the executor registers code_mode"
  assert string.contains(code_mode.description, "### cap/aegis")
  assert !string.contains(code_mode.description, "cap/fs")

  // The program, on the executor, through the link.
  let ran =
    surface.run(attachment.surface, call(program, "call_1", 0))
    |> text_of
  let assert Ok(text) = ran as "the program ran"
  assert string.contains(text, "grep src/app/util.gleam:1:pub fn greet")
  assert string.contains(text, "hover ")
  assert string.contains(text, "filed 7")
  assert string.contains(text, "refused " <> host_fixtures.refusal)

  // A program importing a module the host refused is refused at vetting.
  let refused =
    surface.run(attachment.surface, call(refused_program, "call_2", 1))
    |> text_of
  let assert Ok(rejection) = refused as "the refusal is a result"
  assert string.contains(rejection, "import not allowed")
  assert string.contains(rejection, "cap/fs")

  process.unlink(link)
  process.kill(link)
  process.unlink(started.pid)
  process.kill(started.pid)
  let _removed = simplifile.delete_all([scratch])
  Nil
}

fn machine(state: String, seed: String) -> executor_plane.Machine {
  let assert Ok(lsp_servers) = catalog.parse_lsp(lsp_table)
    as "the language-server table parses"
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner has a working directory"
  executor_plane.Machine(
    state_root: state,
    helper_path: here <> "/../sandbox/loom-exec",
    helper_pool_size: 4,
    demand: exec.BestEffort,
    workspace: catalog.default_workspace(),
    tools: catalog.default_tools(),
    deactivated_tools: [],
    lsp_servers:,
    jobs_policy: jobs.default_policy,
    codemode_seed: Some(seed),
    secrets: secret.env(),
    home: None,
    logger: log.discard(),
    mcp_servers: [],
    credentials: [],
  )
}

// The entries a daemon creates in its state root before any session's policy
// is built, which the jail masks and so must exist.
fn establish(state: String) -> Nil {
  list.each(["owner.token", "catalogue.db", "daemon.lock"], fn(name) {
    let assert Ok(Nil) = simplifile.write(state <> "/" <> name, "")
      as "a state root entry is created"
    Nil
  })
  list.each(
    [
      "sessions", "run", "workspaces", "domains", "repository-snapshots",
      "states",
    ],
    fn(name) {
      let assert Ok(Nil) = simplifile.create_directory_all(state <> "/" <> name)
        as "a state root directory is created"
      Nil
    },
  )
}

// A cap socket path is limited to about a hundred bytes and the jail replaces
// /tmp, so the state lives in a shallow directory of its own.
fn shallow_scratch() -> String {
  let directory =
    "/var/tmp/.loom-host-seam-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let _removed = simplifile.delete_all([directory])
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
    as "the shallow scratch directory is created"
  directory
}

fn call(source: String, call_id: String, source_index: Int) -> ToolRun {
  let base = fixtures.tool_run(call_id, source_index)
  let arguments =
    json.Object([
      #("program", json.String(source)),
      #("within_ms", json.Int(300_000)),
    ])
  effects.ToolRun(
    ..base,
    call: message.ToolCall(..base.call, name: "code_mode", arguments:),
    arguments:,
  )
}

// The text a completed tool call returned, or the reason it failed.
fn text_of(outcome: ToolOutcome) -> Result(String, String) {
  case outcome {
    effects.ToolFailed(reason:) -> Error(reason)
    effects.ToolCompleted(result: message.ToolResultMessage(content:, ..), ..) ->
      Ok(
        list.filter_map(content, fn(part) {
          case part {
            message.ToolResultText(text:, ..) -> Ok(text)
            message.ToolResultImage(..) -> Error(Nil)
          }
        })
        |> string.join("\n"),
      )
    effects.ToolCompleted(..) -> Error("not a tool result")
  }
}
