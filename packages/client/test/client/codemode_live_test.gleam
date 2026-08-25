//// The `code_mode` tool against the real pipeline: a model-written
//// program goes in as tool arguments, a real hermetic build and a real
//// jailed satellite run it, and what comes back is an ordinary
//// `ToolOutcome` — the thing a strand would commit and a model would
//// read.
////
//// `packages/codemode`'s own end-to-end proves the pipeline. This proves
//// the *wiring*: that the seam `client/codemode` builds is one a real
//// execution survives, that the identity and budget threaded through it
//// are ones the broker accepts, and that the two env names
//// `execution_policy` adds are the two the launcher actually needed.
////
//// Feature-detected, like the pipeline's own suite. It needs `gleam` and
//// `erl` on `PATH`, a prepared seed (`make codemode-seed`) and a built
//// helper (`make binaries`); without them each test prints a skip reason
//// and passes, so `make check` stays hermetic and fast.

import broker/broker
import broker/exec
import broker/policy
import broker/token
import client/codemode
import client/internal/ffi_os
import core/clock
import core/ids
import core/json
import core/message
import gleam/io
import gleam/list
import gleam/option
import gleam/string
import simplifile
import tools/codemode as codemode_tool
import tools/tool

// What the jailed `/bin/echo` prints, and therefore what has to survive
// three trust boundaries to reach the tool result.
const echoed = "loom-code-mode-tool"

/// A program of the kind the model would submit: one real capability call
/// and a structured report.
pub fn program_source() -> String {
  "import cap/proc\n"
  <> "import cap/report\n"
  <> "import gleam/int\n"
  <> "import gleam/string\n"
  <> "\n"
  <> "pub fn main() -> report.Outcome {\n"
  <> "  case proc.run(proc.command([\"/bin/echo\", \""
  <> echoed
  <> "\"])) {\n"
  <> "    Ok(output) ->\n"
  <> "      report.text(\n"
  <> "        string.trim(output.stdout)\n"
  <> "        <> \" exit=\"\n"
  <> "        <> int.to_string(output.exit_code),\n"
  <> "      )\n"
  <> "    Error(_error) -> report.failure(\"proc.run did not settle\")\n"
  <> "  }\n"
  <> "}\n"
}

pub fn a_submitted_program_runs_and_reports_through_the_tool_test() {
  case prerequisites() {
    Error(reason) ->
      io.println("SKIP a_submitted_program_runs_through_the_tool: " <> reason)
    Ok(ready) -> run_live(ready)
  }
}

// --- the run ---------------------------------------------------------------

type Ready {
  Ready(helper_path: String, seed_root: String, root: String)
}

fn run_live(ready: Ready) -> Nil {
  let workspace = ready.root <> "/work"
  let assert Ok(Nil) = simplifile.create_directory_all(workspace <> "/tmp")
    as "the live rig must have a workspace"
  let base_policy = base_policy(ready.root)
  let assert Ok(pool) =
    exec.start_pool(size: 3, spawn: fn() {
      exec.spawn_helper(exec.SpawnConfig(
        helper_path: ready.helper_path,
        shell_path: "/bin/sh",
        base_policy:,
        helper_args: [],
        tmp_dir: workspace <> "/tmp",
        handshake_timeout_ms: 5000,
        cancel_grace_ms: 3000,
        heartbeat_interval_ms: 0,
      ))
    })
    as "the helper pool must start"
  let assert Ok(broker_actor) =
    broker.start(
      broker.BrokerConfig(
        entropy: broker_entropy(),
        clock: wall_clock(),
        checkout: fn() { exec.checkout(pool, waiting: 20_000) },
        checkin: fn(helper) { exec.checkin(pool, helper) },
      ),
    )
    as "the broker must start"
  let assert Ok(toolchain) = codemode.discover(ready.seed_root)
    as "the toolchain must be located"
  let seam =
    codemode.seam(codemode.default_config(
      broker: broker_actor,
      clock: wall_clock(),
      workspace:,
      toolchain:,
    ))
  let outcome =
    codemode_tool.tool_for(seam).run(
      live_ctx(workspace, base_policy, wall_clock()),
      json.Object([
        #("program", json.String(program_source())),
        #("within_ms", json.Int(600_000)),
      ]),
    )
  let text = rendered_text(outcome)
  // What the jailed `/bin/echo` printed, through the cap channel, the
  // broker's policy check, a second jail, and out as a tool result.
  assert !outcome.is_error
  assert string.contains(text, echoed <> " exit=0")
  // The result is a whole tool result, not a string: the content address
  // of exactly what ran travels with it, which is what a durable entry
  // for this execution would be fingerprinted by.
  let assert option.Some(json.Object(fields)) = outcome.details
    as "a live run must carry structured details"
  assert list.contains(fields, #("status", json.String("completed")))
  let assert Ok(json.String(hash)) = list.key_find(fields, "manifest_hash")
    as "a live run must carry its artifact's content address"
  assert string.starts_with(hash, "sha256-")
  // And the result says what the kernel actually provided rather than
  // implying a jail. Printed, so a degraded run is visible rather than
  // silently green.
  io.println("code-mode tool e2e: " <> sandbox_line(text))
  broker.stop(broker_actor)
  exec.stop_pool(pool)
}

fn sandbox_line(text: String) -> String {
  case
    list.filter(string.split(text, "\n"), string.starts_with(_, "sandbox:"))
  {
    [line, ..] -> line
    [] -> "no sandbox line in the result"
  }
}

// --- the rig ---------------------------------------------------------------

fn prerequisites() -> Result(Ready, String) {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner must have a working directory"
  let repo = here <> "/../.."
  let helper_path = repo <> "/bin/loom-exec"
  let seed_root = repo <> "/build/codemode-seed"
  case simplifile.is_file(helper_path) {
    Ok(True) ->
      case codemode.discover(seed_root) {
        Error(reason) -> Error(reason)
        Ok(_toolchain) ->
          Ok(Ready(
            helper_path:,
            seed_root:,
            root: here <> "/build/codemode-tool-e2e",
          ))
      }
    _absent ->
      Error("no loom-exec at " <> helper_path <> "; run `make binaries`")
  }
}

// The session base a live code-mode execution runs under: its own root
// writable, the filesystem readable (the toolchain and the BEAM live
// outside it), network off. Deliberately *without* the two cap-channel
// env names: `client/codemode.execution_policy` is what adds them, and a
// base that already carried them would hide whether it does.
fn base_policy(root: String) -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    ..policy.workspace_default(root),
    writable_roots: [root],
    readable_roots: ["/"],
    env_allow: ["PATH"],
  )
}

fn live_ctx(
  workspace: String,
  base: policy.SandboxPolicy,
  wall: clock.Clock,
) -> tool.Ctx {
  let #(op, _generator) = ids.mint_op(ids.generator(wall, seed: 20_260_825))
  tool.Ctx(
    workspace:,
    strand: "main",
    op_id: op,
    step_id: "turn-1:tools",
    source_index: 0,
    base_policy: base,
    grants: [],
    // The kernels this runs on vary; the point here is the wiring, and
    // the result says which layers were really applied.
    demand: exec.BestEffort,
    env: [#("PATH", "/usr/local/bin:/usr/bin:/bin")],
    clock: wall,
    filesystem: no_filesystem(),
    blob_root: workspace <> "/.blobs",
    clear_call: fn(_spec, _events) { Error(broker.BrokerUnavailable) },
  )
}

// The `code_mode` tool touches neither seam: its effects go through the
// pipeline's own clearances, not through `Ctx`.
fn no_filesystem() -> tool.FileSystem {
  tool.FileSystem(
    read: fn(path) { Error(tool.FsNotFound(path:)) },
    write: fn(path, _bytes) { Error(tool.FsNotFound(path:)) },
    create_directory_all: fn(path) { Error(tool.FsNotFound(path:)) },
    is_file: fn(_path) { Ok(False) },
    read_link: fn(_path) { Ok(tool.LinkMissing) },
  )
}

fn rendered_text(outcome: tool.ToolOutcome) -> String {
  outcome.content
  |> list.map(fn(block) {
    case block {
      message.ToolResultText(text:, ..) -> text
      _other -> ""
    }
  })
  |> string.join("\n")
}

// A real wall clock and real token entropy: a jailed node really does die
// at an absolute deadline, so a fixture clock would be measuring a
// different universe from the kernel.
fn wall_clock() -> clock.Clock {
  clock.from_function(ffi_os.system_time_ms)
}

fn broker_entropy() -> fn(Int) -> BitArray {
  token.production_entropy()
}
