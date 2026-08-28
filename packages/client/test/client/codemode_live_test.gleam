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
//// `erl` on `PATH`, a prepared seed (`make codemode-seed`) and a *current*
//// helper (`make binaries`) — built no earlier than the Go sources under
//// `packages/sandbox`, not merely present (issue #61: a helper built
//// before the wire protocol's most recent required-field change passes a
//// bare presence check and then fails as an anonymous protocol break,
//// which cost an hour to diagnose the one time it happened). Without a
//// satisfied prerequisite each test prints a skip reason and passes, so
//// `make check` stays hermetic and fast.

import broker/broker
import broker/escalation
import broker/exec
import broker/policy
import broker/token
import client/catalog
import client/codemode
import client/install
import client/internal/ffi_os
import client/mcp as mcp_wiring
import client/scratch
import core/clock
import core/ids
import core/json
import core/message
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import mcp/client as mcp_client
import mcp/codegen
import simplifile
import support/fake_mcp
import tools/agent
import tools/blob
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
  let rig = rig(ready, under: ready.root)
  let seam =
    codemode.seam(codemode.default_config(
      broker: rig.broker,
      clock: wall_clock(),
      workspace: rig.workspace,
      toolchain: rig.toolchain,
    ))
  let outcome =
    codemode_tool.tool_for(seam).run(
      live_ctx(rig.workspace, rig.base_policy, wall_clock()),
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
  // implying a jail. Both jailed stages are named on a healthy run — the
  // node's report used to be lost to the abort that settles the outcome,
  // so this line named the build alone and the tool had to say it could
  // not vouch for the stage the program actually ran in (issue #5).
  let sandbox = sandbox_line(text)
  assert string.contains(sandbox, codemode_tool.build_stage <> " enforced [")
  assert string.contains(
    sandbox,
    codemode_tool.satellite_stage <> " enforced [",
  )
  assert !string.contains(sandbox, "made NO enforcement report")
  // Printed, so a degraded run is visible rather than silently green:
  // *which* layers held is a property of this kernel, not of the harness.
  io.println("code-mode tool e2e: " <> sandbox)
  stop_rig(rig)
}

fn sandbox_line(text: String) -> String {
  case
    list.filter(string.split(text, "\n"), string.starts_with(_, "sandbox:"))
  {
    [line, ..] -> line
    [] -> "no sandbox line in the result"
  }
}

// --- minting an escalation from a real refusal (#97) ------------------------

// The environment name the session base does not allow. The node's
// requirements name every variable the launcher will set — the two cap
// handles plus whatever the caller's `env` holds — so a name in `env`
// that the base does not allow is a shortfall the *node* has and the
// hermetic build does not: the build is passed `PATH` alone. That
// asymmetry is what makes this a run-phase refusal rather than a build
// one, which is the whole distinction the seam turns on.
const unallowed_env = "LOOM_ESCALATION_PROBE"

pub fn a_narrowed_base_mints_an_approval_the_retry_spends_test() {
  case prerequisites() {
    Error(reason) ->
      io.println(
        "SKIP a_narrowed_base_mints_an_approval_the_retry_spends: " <> reason,
      )
    Ok(ready) -> run_escalating(ready)
  }
}

// The whole loop against the real pipeline: a real vet, a real hermetic
// build, a real satellite launch refused on a real narrowed base, the
// structured diff that refusal reports outward, and — once the host
// answers with exactly that diff — a real jailed program that runs.
//
// Before #97 the first half of that sentence ended in prose. The pipeline
// flattens every refusal to a reason string on its way to the model, so
// the `wanted` an approval is granted against did not exist anywhere
// above the composition that computed it, and nothing could mint a
// record for a human to answer. The assertion on `raised.denial.wanted`
// is the one that was impossible.
fn run_escalating(ready: Ready) -> Nil {
  let rig = rig(ready, under: ready.root <> "-escalation")
  let seam =
    codemode.seam(codemode.default_config(
      broker: rig.broker,
      clock: wall_clock(),
      workspace: rig.workspace,
      toolchain: rig.toolchain,
    ))
  // The host, standing in for `client/wiring` plus a human at a client:
  // it records what it was asked and answers with exactly the diff the
  // refusal named. Approving the *reported* wanted set rather than a
  // hand-written one is the point — a diff that satisfies nothing would
  // let this test pass while a human's yes bought nothing.
  let asked = process.new_subject()
  let ctx =
    tool.Ctx(
      ..live_ctx(rig.workspace, rig.base_policy, wall_clock()),
      env: [
        #("PATH", "/usr/local/bin:/usr/bin:/bin"),
        #(unallowed_env, "probe"),
      ],
      raise_refusal: fn(refusal: tool.RaisedRefusal) {
        process.send(asked, refusal)
        tool.Resume(grants: refusal.denial.wanted)
      },
    )
  let outcome =
    codemode_tool.tool_for(seam).run(
      ctx,
      json.Object([
        #("program", json.String(program_source())),
        #("within_ms", json.Int(600_000)),
      ]),
    )
  // Exactly one question, about the whole submission.
  let assert Ok(raised) = process.receive(asked, within: 0)
    as "the refused launch must reach the host exactly once"
  assert process.receive(asked, within: 0) == Error(Nil)
  // And it names the grant that actually opens the door, derived from
  // composition's own narrowings rather than written down here.
  assert raised.denial.wanted == [policy.GrantEnv(name: unallowed_env)]
  assert raised.denial.source == escalation.PolicyDenial
  assert string.contains(raised.denial.reason, unallowed_env)
  // The re-execution ran under what the host granted, and the program
  // reached a real jailed process through the cap channel.
  assert !outcome.is_error
  assert string.contains(rendered_text(outcome), echoed <> " exit=0")
  io.println(
    "code-mode tool e2e: a narrowed base minted [env="
    <> unallowed_env
    <> "]; the approved re-execution ran",
  )
  stop_rig(rig)
}

// --- a configured MCP server, end to end (#106) ------------------------------

// What the fake server answers, and therefore what has to survive a real
// generated façade, a real hermetic build, the cap channel and the
// router to reach the tool result.
const mcp_answer = "loom-mcp-round-trip"

/// A program of the kind a model would submit against a configured MCP
/// server: one typed façade call and a structured report. The signature
/// is `mcp/codegen`'s — every parameter is labelled, and optionals ride
/// in `options` by wire name.
pub fn mcp_program_source() -> String {
  "import cap/mcp\n"
  <> "import cap/mcp/alpha\n"
  <> "import cap/report\n"
  <> "\n"
  <> "pub fn main() -> report.Outcome {\n"
  <> "  case alpha.search(query: \"loom\", options: []) {\n"
  <> "    Ok(found) -> report.text(mcp.text(found))\n"
  <> "    Error(_error) -> report.failure(\"the mcp call did not settle\")\n"
  <> "  }\n"
  <> "}\n"
}

pub fn a_program_calls_a_configured_mcp_server_test() {
  case prerequisites() {
    Error(reason) ->
      io.println("SKIP a_program_calls_a_configured_mcp_server: " <> reason)
    Ok(ready) -> run_mcp(ready)
  }
}

// The whole #106 pipeline against the real one: a real `mcp/codegen`
// module generated from a real `tools/list`, vendored into the real
// prelude inside a real hermetic build, imported by a vetted program,
// and called through the cap channel to a server the harness holds.
//
// What is fake is the server's *transport* and nothing else: the client
// actor, the handshake, the framing, the JSON-RPC correlation and the
// result decoding are the production ones, over
// `mcp/transport.ChannelTransport`. Spawning a third-party binary is
// what the fake replaces, and it is the one part of this path that has
// no bearing on whether a generated façade compiles and dispatches.
fn run_mcp(ready: Ready) -> Nil {
  let rig = rig(ready, under: ready.root <> "-mcp")
  let layer = live_layer()
  // The generated module is the real artifact: the façade the model
  // writes against and the source the build compiles are the same
  // bytes, produced by `mcp/codegen` from the server's own listing.
  let assert [#("cap/mcp/alpha", generated_source)] =
    mcp_wiring.generated(layer)
    as "one server generates one module"
  assert string.contains(
    generated_source,
    "import cap/internal/mcp as internal",
  )
  assert string.contains(generated_source, "pub fn search(")
  let seam =
    codemode.seam(
      codemode.default_config(
        broker: rig.broker,
        clock: wall_clock(),
        workspace: rig.workspace,
        toolchain: rig.toolchain,
      )
      |> codemode.over_mcp(layer),
    )
  let outcome =
    codemode_tool.tool_for(seam).run(
      live_ctx(rig.workspace, rig.base_policy, wall_clock()),
      json.Object([
        #("program", json.String(mcp_program_source())),
        #("within_ms", json.Int(600_000)),
      ]),
    )
  let text = rendered_text(outcome)
  // The server's own text, through `cap/internal/mcp`, the cap channel,
  // the router, a real JSON-RPC round trip, and back out as a tool
  // result.
  assert !outcome.is_error
  assert string.contains(text, mcp_answer)
  io.println(
    "code-mode mcp e2e: a generated façade compiled inside the vendored "
    <> "prelude and reached its server",
  )
  mcp_wiring.stop(layer)
  stop_rig(rig)
}

// The layer a host would have after `mcp.start`, minus the spawn: a real
// client over the fake transport, a real `tools/list`, and a real
// generated module.
fn live_layer() -> mcp_wiring.Layer {
  let assert Ok(client) =
    mcp_client.start(
      fake_mcp.seam(
        tools: [fake_mcp.tool("search", ["query"])],
        call: fn(_name, _arguments) {
          fake_mcp.Answers(fake_mcp.text_result(mcp_answer, False))
        },
      ),
      mcp_client.options("live"),
    )
    as "the fake server completes the handshake"
  let assert Ok(tools) = mcp_client.list_tools(client, 5000)
    as "the fake server lists its tools"
  let assert Ok(generated) =
    codegen.generate("alpha", tools, mcp_wiring.sha256_hex)
    as "a one-tool listing generates"
  mcp_wiring.Layer(
    servers: [
      mcp_wiring.Server(name: "alpha", client:, generated:, tools: 1),
    ],
    call_timeout_ms: 30_000,
  )
}

// --- a real MCP server process, end to end (#106) ----------------------------

// What the program sends and what the fixture server must hand back
// byte for byte. Neither value is a Gleam identifier and neither is
// touched by anything on the way: the *wire* names are what travel, and
// the mangled Gleam names are display artifacts. This is the assertion
// `mcp/codegen`'s whole wire-fidelity invariant reduces to, made against
// a real pipe rather than an in-process peer.
const wire_message = "loom-mcp-wire-fidelity"

const wire_tag = "Tag-With_Mixed.Case"

// The three tools `test/support/mcp_fixture.escript` lists.
const fixture_tools = 3

// The catalogue key, which is also the `cap/mcp/<name>` module segment
// and the `mcp.<name>` capability suffix.
const fixture_server = "fixture"

// What the fixture's one failing tool says, verbatim, and the label the
// program puts in front of it when it read the failure as `ToolFailed`.
// `isError: true` is a *tool* verdict on a call that settled, so the
// whole claim is that the program branched on it as such rather than on
// a transport error — a distinction nothing below the program can make
// for it.
const wire_failure = "the issue tracker refused"

const tool_failed_label = "tool-failed "

const wrong_failure = "the failing tool failed the wrong way"

const no_failure = "the failing tool did not fail"

/// The program a model would write against a configured MCP server: one
/// typed façade call carrying a required argument and an optional one,
/// a report that reads the server's structured answer back out field by
/// field, and a second call to the tool that answers `isError: true`,
/// whose failure the program has to read as `mcp.ToolFailed` rather than
/// as a call that did not settle. What it prints is what crossed.
pub fn mcp_process_program_source() -> String {
  "import cap/mcp\n"
  <> "import cap/mcp/"
  <> fixture_server
  <> "\n"
  <> "import cap/report\n"
  <> "import gleam/option\n"
  <> "import gleam/result\n"
  <> "\n"
  <> "pub fn main() -> report.Outcome {\n"
  <> "  case "
  <> fixture_server
  <> ".echo_args(\n"
  <> "    message: \""
  <> wire_message
  <> "\",\n"
  <> "    options: [#(\"tag\", report.string(\""
  <> wire_tag
  <> "\"))],\n"
  <> "  ) {\n"
  <> "    Error(_error) -> report.failure(\"the mcp call did not settle\")\n"
  <> "    Ok(found) ->\n"
  <> "      report.text(\n"
  <> "        mcp.text(found) <> \" \" <> echoed(found) <> \" \" <> refused(),\n"
  <> "      )\n"
  <> "  }\n"
  <> "}\n"
  <> "\n"
  <> "fn refused() -> String {\n"
  <> "  case "
  <> fixture_server
  <> "."
  <> digested("create_issue", "Create-Issue!")
  <> "(title: \"anything\", options: []) {\n"
  <> "    Ok(_result) -> \""
  <> no_failure
  <> "\"\n"
  // Written out rather than as label shorthand: vetting parses a
  // slightly narrower Gleam than the compiler, and `message:` in a
  // pattern is one of the things it does not take.
  <> "    Error(mcp.ToolFailed(message: message, content: _content)) -> \""
  <> tool_failed_label
  <> "\" <> message\n"
  <> "    Error(_other) -> \""
  <> wrong_failure
  <> "\"\n"
  <> "  }\n"
  <> "}\n"
  <> "\n"
  <> "fn echoed(found: mcp.ToolResult) -> String {\n"
  <> "  let read = {\n"
  <> "    use echo_of <- result.try(option.to_result(found.structured, Nil))\n"
  <> "    use message <- result.try(report.field(echo_of, \"message\"))\n"
  <> "    use message <- result.try(report.as_string(message))\n"
  <> "    use tag <- result.try(report.field(echo_of, \"tag\"))\n"
  <> "    use tag <- result.try(report.as_string(tag))\n"
  <> "    Ok(\"message=\" <> message <> \" tag=\" <> tag)\n"
  <> "  }\n"
  <> "  case read {\n"
  <> "    Ok(rendered) -> rendered\n"
  <> "    Error(Nil) -> \"the structured echo did not carry both fields\"\n"
  <> "  }\n"
  <> "}\n"
}

pub fn a_program_reaches_a_real_mcp_server_process_test() {
  case mcp_process_rig() {
    Error(reason) ->
      io.println("SKIP a_program_reaches_a_real_mcp_server_process: " <> reason)
    Ok(rig) -> run_mcp_process(rig)
  }
}

// Everything the fixture-server run needs beyond the live rig: the
// `escript` that will run the server and the checked-in server itself.
type Fixture {
  Fixture(ready: Ready, escript: String, script: String)
}

// The whole of #106 against a real third party: a real `escript` child
// process on a real pipe, spawned by `client/mcp.start` from a real
// `catalog.McpServer`, hand-shaken and listed by the production client,
// generated into a real `cap/mcp/fixture` module, vendored into a real
// hermetic build, imported by a vetted program, and called through the
// cap channel and the router back out to that child.
//
// `a_program_calls_a_configured_mcp_server_test` above proves the same
// pipeline with the *transport* faked. What this adds is the one thing
// that fake cannot: an OS process, its stdio framing, its argv and its
// death.
fn run_mcp_process(fixture: Fixture) -> Nil {
  // Short on purpose: the execution's cap socket sits under this root
  // and an AF_UNIX path is capped near 100 bytes, which the tree already
  // refuses in band rather than failing as an opaque `einval`.
  let rig = rig(fixture.ready, under: fixture.ready.root <> "-mcp-live")
  // The pid file is the child's own account of itself, written before it
  // answers anything, so a completed handshake means it is there.
  let pid_file = rig.root <> "/server.pid"
  let _ = simplifile.delete(pid_file)
  let configured =
    catalog.McpServer(
      name: fixture_server,
      command: [fixture.escript, fixture.script, pid_file],
      api_key_env: option.None,
    )
  // The production boot: a real spawn, a real handshake, a real
  // `tools/list`, a real generated module.
  let #(layer, refusals) =
    mcp_wiring.start([configured], mcp_wiring.default_options())
  assert refusals == []
  assert mcp_wiring.serving(layer)
  // The `mcp.ready` payload: the server answered and listed all three.
  assert mcp_wiring.listings(layer) == [#(fixture_server, fixture_tools)]
  assert mcp_wiring.serviced_caps(layer) == ["mcp." <> fixture_server]
  let assert [#("cap/mcp/fixture", generated_source)] =
    mcp_wiring.generated(layer)
    as "one server generates one module"
  let assert [surface] = mcp_wiring.surfaces(layer)
    as "one server renders one surface"
  assert_generated_names(generated_source, surface)
  let seam =
    codemode.seam(
      codemode.default_config(
        broker: rig.broker,
        clock: wall_clock(),
        workspace: rig.workspace,
        toolchain: rig.toolchain,
      )
      |> codemode.over_mcp(layer),
    )
  let outcome =
    codemode_tool.tool_for(seam).run(
      live_ctx(rig.workspace, rig.base_policy, wall_clock()),
      json.Object([
        #("program", json.String(mcp_process_program_source())),
        #("within_ms", json.Int(600_000)),
      ]),
    )
  let text = rendered_text(outcome)
  assert !outcome.is_error
  // (a) The wire-fidelity assertion. Both values crossed the generated
  // façade, `cap/internal/mcp`, the cap channel, the router, a real pipe
  // into another OS process and all the way back — under their original
  // parameter names, since the server echoes the `arguments` object it
  // received and the program reads it back by wire name. "ok" is the
  // server's own text block, so the whole line is the server's answer.
  assert string.contains(
    text,
    "ok message=" <> wire_message <> " tag=" <> wire_tag,
  )
  // (c) A tool-level failure, across the same boundary. The call
  // settled; the *tool* said no, and `is_error` carried that verdict
  // through the router, the cap wire and `cap/internal/mcp` to reach the
  // program as `ToolFailed` with the server's own text as its message.
  // Asserted on what the program composed, because the claim is that the
  // program observed the failure — not that the harness saw one.
  assert string.contains(text, tool_failed_label <> wire_failure)
  assert !string.contains(text, wrong_failure)
  assert !string.contains(text, no_failure)
  // (d) And stopping the layer takes the child down. Alive first, so a
  // fixture that had already exited could not pass this by default.
  let pid = recorded_pid(pid_file)
  assert alive(pid)
  mcp_wiring.stop(layer)
  assert gone_within(pid, teardown_polls)
  io.println(
    "code-mode mcp e2e: a real escript MCP server answered through the "
    <> "generated façade, answered one call `isError: true`, and stopping "
    <> "the layer reaped pid "
    <> pid,
  )
  stop_rig(rig)
}

// (b) What the generator made of a hostile listing, in the two artifacts
// that reach a model and the compiler. The wire names are intact in the
// source; the Gleam names are mangled and digested; and the two never
// travel as each other.
fn assert_generated_names(source: String, surface: String) -> Nil {
  // The ordinary tool: a legal Gleam name survives whole, so the label
  // and the wire name coincide and nothing is digested.
  assert string.contains(source, "pub fn echo_args(")
  assert string.contains(source, "  message message: String,")
  assert string.contains(source, "\"echo_args\",")
  // The hostile tool name mangles *and* digests — `create_issue` alone
  // would be a name two different originals could reach.
  let renamed = digested("create_issue", "Create-Issue!")
  assert string.contains(source, "pub fn " <> renamed <> "(")
  assert string.contains(surface, "pub fn " <> renamed <> "(")
  // …and the *wire* name is what the body sends. This is the pair the
  // whole invariant is about: a display name that changed, beside a wire
  // name that did not.
  assert string.contains(source, "\"Create-Issue!\",")
  assert !string.contains(source, "\"" <> renamed <> "\",")
  // The tier-2 parameter: a nested object schema is one structured
  // value, and its hostile name mangles into the label while the wire
  // name stays in the marshalling line.
  let label = digested("target_repo", "Target-Repo")
  assert string.contains(
    source,
    "  " <> label <> " " <> label <> ": report.Value,",
  )
  assert string.contains(source, "#(\"Target-Repo\", " <> label <> "),")
  Nil
}

// A renamed identifier as `mcp/name` builds it: the mangled base, then
// eight characters of the digest of the *original*.
fn digested(base: String, original: String) -> String {
  base <> "_" <> string.slice(mcp_wiring.sha256_hex(original), 0, 8)
}

// --- locating the fixture and its interpreter -------------------------------

fn mcp_process_rig() -> Result(Fixture, String) {
  use ready <- result.try(prerequisites())
  use Nil <- result.try(observable_processes())
  use escript <- result.try(escript_path())
  use script <- result.try(fixture_script())
  Ok(Fixture(ready:, escript:, script:))
}

// `escript`, looked for the way `client/install` looks for every other
// component of Loom's own tree: beside the emulator this VM is actually
// running before `PATH`. OTP ships `escript` in the same `erts-<vsn>/bin`
// as `erl` and again in the installation's `bin`, so the first two rungs
// find the interpreter belonging to *this* OTP rather than whichever one
// a shell profile points at — the same argument `install.erl` makes for
// the emulator. `PATH` is the last rung, for a host that installed OTP
// some other way.
fn escript_path() -> Result(String, String) {
  install.first_of([
    fn() { install.existing_file(erts_bin(escript_name)) },
    fn() { install.existing_file(install.root() <> "/bin/" <> escript_name) },
    fn() { ffi_os.find_executable(escript_name) },
  ])
  |> result.replace_error(
    "no "
    <> escript_name
    <> " beside "
    <> install.erl()
    <> " or on PATH; the fixture MCP server is an OTP escript",
  )
}

const escript_name = "escript"

// The sibling of `install.erl()`, built the same way it is rather than
// by cutting its last segment off.
fn erts_bin(name: String) -> String {
  install.root() <> "/erts-" <> ffi_os.erts_version() <> "/bin/" <> name
}

fn fixture_script() -> Result(String, String) {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner must have a working directory"
  let path = here <> "/test/support/mcp_fixture.escript"
  install.existing_file(path)
  |> result.replace_error("no MCP fixture server at " <> path)
}

// --- watching a child die ----------------------------------------------------

// Whether a pid can be observed at all on this host. The teardown claim
// is "the OS process is gone", and the only thing in reach that can say
// so without an FFI of its own is `/proc`; a host without it skips
// loudly rather than asserting something weaker under the same name.
fn observable_processes() -> Result(Nil, String) {
  install.existing_directory(proc_root)
  |> result.replace(Nil)
  |> result.replace_error(
    "no "
    <> proc_root
    <> " on this host, so a stopped server's death cannot be observed by pid",
  )
}

const proc_root = "/proc"

const poll_interval_ms = 50

// Two seconds of polling. `mcp/transport`'s close shuts the child's
// stdin and then signals it, and neither the exit nor the reap is
// synchronous with the call that asked for them.
const teardown_polls = 40

fn recorded_pid(pid_file: String) -> String {
  let assert Ok(contents) = simplifile.read(pid_file)
    as "the fixture server must record its OS pid before it answers"
  string.trim(contents)
}

fn alive(pid: String) -> Bool {
  simplifile.is_directory(proc_root <> "/" <> pid) == Ok(True)
}

fn gone_within(pid: String, polls: Int) -> Bool {
  case alive(pid), polls <= 0 {
    False, _ -> True
    True, True -> False
    True, False -> {
      process.sleep(poll_interval_ms)
      gone_within(pid, polls - 1)
    }
  }
}

// --- the harness-side capability bridge, end to end (#16) --------------------

// The fixture the program reads, and therefore what has to survive
// `resolve_real`, the closure, the cap channel and `cap/fs`'s own result
// decoding to come back out as a tool result.
const bridged_file = "notes/fixture.txt"

const bridged_contents = "loom-workspace-bridge"

// What the program stashes and reads back, and what it emits. The
// artifact's bytes are asserted on disk afterwards, at the content
// address `cap/report` handed the program.
const bridged_key = "seen"

const bridged_artifact = "loom-bridge-artifact\n"

/// A program of the kind a model would submit against the harness-side
/// bridge: one read, one listing, a scratch round trip and an artifact,
/// composed into a single structured outcome.
///
/// Written to exercise all four capabilities in one execution
/// deliberately. They are one mechanism — one router, one seam record,
/// one set of injected closures — and a suite that reached them one at a
/// time would not notice a seam whose second arm was wired to the first
/// one's closure.
pub fn bridge_program_source() -> String {
  "import cap/fs\n"
  <> "import cap/kv\n"
  <> "import cap/report\n"
  <> "import gleam/list\n"
  <> "import gleam/option\n"
  <> "\n"
  <> "pub fn main() -> report.Outcome {\n"
  <> "  case fs.read(\""
  <> bridged_file
  <> "\") {\n"
  <> "    Error(_error) -> report.failure(\"fs.read did not settle\")\n"
  <> "    Ok(contents) -> after_read(contents)\n"
  <> "  }\n"
  <> "}\n"
  <> "\n"
  <> "fn after_read(contents: String) -> report.Outcome {\n"
  <> "  case fs.list(\"notes\") {\n"
  <> "    Error(_error) -> report.failure(\"fs.list did not settle\")\n"
  <> "    Ok(entries) -> after_list(contents, entries)\n"
  <> "  }\n"
  <> "}\n"
  <> "\n"
  <> "fn after_list(contents: String, entries: List(fs.DirEntry)) -> report.Outcome {\n"
  <> "  let names = list.map(entries, fn(entry) { entry.name })\n"
  <> "  case kv.set(\""
  <> bridged_key
  <> "\", <<\"stashed\":utf8>>) {\n"
  <> "    Error(_error) -> report.failure(\"kv.set did not settle\")\n"
  <> "    Ok(Nil) -> after_set(contents, list.length(names))\n"
  <> "  }\n"
  <> "}\n"
  <> "\n"
  <> "fn after_set(contents: String, listed: Int) -> report.Outcome {\n"
  <> "  case kv.get(\""
  <> bridged_key
  <> "\") {\n"
  <> "    Error(_error) -> report.failure(\"kv.get did not settle\")\n"
  <> "    Ok(option.None) -> report.failure(\"kv.get lost the value\")\n"
  <> "    Ok(option.Some(stashed)) -> emitting(contents, listed, stashed)\n"
  <> "  }\n"
  <> "}\n"
  <> "\n"
  <> "fn emitting(contents: String, listed: Int, stashed: BitArray) -> report.Outcome {\n"
  <> "  case\n"
  <> "    report.emit(\n"
  <> "      name: \"bridge.txt\",\n"
  <> "      content_type: \"text/plain\",\n"
  <> "      bytes: <<\""
  <> bridged_artifact_literal()
  <> "\":utf8>>,\n"
  <> "    )\n"
  <> "  {\n"
  <> "    Error(_error) -> report.failure(\"report.emit did not settle\")\n"
  <> "    Ok(reference) ->\n"
  <> "      report.value(\n"
  <> "        report.object([\n"
  <> "          #(\"contents\", report.string(contents)),\n"
  <> "          #(\"listed\", report.int(listed)),\n"
  <> "          #(\"stashed\", report.int(byte_count(stashed))),\n"
  <> "          #(\"artifact\", report.string(reference.id)),\n"
  <> "        ]),\n"
  <> "      )\n"
  <> "  }\n"
  <> "}\n"
  <> "\n"
  // `gleam/bit_array` is not on the seam's stdlib allowlist, so the
  // program counts its own bytes rather than importing a module vetting
  // would refuse. What it is proving is that the bytes crossed at all.
  <> "fn byte_count(bytes: BitArray) -> Int {\n"
  <> "  case bytes {\n"
  <> "    <<_byte, rest:bits>> -> 1 + byte_count(rest)\n"
  <> "    _empty -> 0\n"
  <> "  }\n"
  <> "}\n"
}

// The artifact's bytes as a Gleam string literal: the trailing newline
// has to reach the source as an escape rather than as a line break.
fn bridged_artifact_literal() -> String {
  string.replace(bridged_artifact, "\n", "\\n")
}

pub fn a_program_reaches_the_harness_side_capability_bridge_test() {
  case prerequisites() {
    Error(reason) ->
      io.println(
        "SKIP a_program_reaches_the_harness_side_capability_bridge: " <> reason,
      )
    Ok(ready) -> run_bridge(ready)
  }
}

// The whole of #16's first slice against the real pipeline: a real vet
// against the workspace allowlist, a real hermetic build, a real jailed
// satellite, and four capabilities answered by the harness itself rather
// than by a jail — over `tools/fs`'s own path resolution, the session's
// own scratch store, and the session's own blob root.
//
// The decisive assertion is the last one. A program is told an artifact's
// content address; this reads the file *at that address* off the disk and
// compares its bytes. An id a program cannot resolve to bytes is a
// capability that reported success and did nothing.
fn run_bridge(ready: Ready) -> Nil {
  let rig = rig(ready, under: ready.root <> "-bridge")
  let assert Ok(Nil) =
    simplifile.create_directory_all(rig.workspace <> "/notes")
    as "the fixture directory must be creatable"
  let assert Ok(Nil) =
    simplifile.write(rig.workspace <> "/" <> bridged_file, bridged_contents)
    as "the fixture file must be writable"
  let store = process.new_name(prefix: "loom_scratch_e2e")
  let assert Ok(_started) = scratch.start(store, scratch.default_bounds())
    as "the scratch store must start"
  let seam =
    codemode.seam(
      codemode.default_config(
        broker: rig.broker,
        clock: wall_clock(),
        workspace: rig.workspace,
        toolchain: rig.toolchain,
      )
      |> codemode.over_scratch(scratch.seam(
        store,
        timeout_ms: scratch.default_timeout_ms,
      )),
    )
  let outcome =
    codemode_tool.tool_for(seam).run(
      live_ctx(rig.workspace, rig.base_policy, wall_clock()),
      json.Object([
        #("program", json.String(bridge_program_source())),
        #("within_ms", json.Int(600_000)),
      ]),
    )
  let text = rendered_text(outcome)
  assert !outcome.is_error
  // The file's own bytes, through `resolve_real`, the closure, the cap
  // channel and `cap/fs`'s result decoding.
  assert string.contains(text, bridged_contents)
  // The listing found the one fixture, and the scratch store handed back
  // the seven bytes the program stashed.
  // The listing found the one fixture file, and the scratch store handed
  // back exactly the seven bytes the program stashed — not a truncation,
  // not an eviction, and not a `None` the program had to route around.
  assert string.contains(text, "\"listed\":1")
  assert string.contains(text, "\"stashed\":7")
  let id = artifact_id(outcome)
  assert string.starts_with(id, "sha256-")
  // The artifact is a real file, at the address the program was told, in
  // the blob root this host derives from the workspace — the same one
  // `tool.Ctx.blob_root` names.
  let path = blob.ref_path(rig.workspace <> "/" <> codemode.blob_directory, id)
  assert simplifile.read_bits(path) == Ok(<<bridged_artifact:utf8>>)
  // And the id really is the content address of those bytes rather than
  // a name the harness invented, which is what makes a re-emission free.
  assert id == blob.ref_for(<<bridged_artifact:utf8>>)
  io.println(
    "code-mode bridge e2e: fs.read + fs.list + kv.set/get + report.emit "
    <> "through the real pipeline; the artifact is on disk at "
    <> id,
  )
  scratch.stop(store)
  stop_rig(rig)
}

// The `artifact` field of the program's structured outcome, read out of
// the rendered result text. The tool renders a completed program's value
// as JSON, so this is a search rather than a decode — what is being
// proved is that the id crossed, not how the tool renders one.
fn artifact_id(outcome: tool.ToolOutcome) -> String {
  let text = rendered_text(outcome)
  case string.split(text, "sha256-") {
    [_before, rest, ..] ->
      "sha256-"
      <> string.slice(rest, 0, 64)
      |> string.replace("\"", "")
    _other -> "no artifact id in " <> text
  }
}

// --- the bridge's write arms, end to end (#16, #105) -------------------------

// The file the program creates, edits and re-reads. At the workspace
// root on purpose: `fs.write` writes whole files and creates no parent
// directories, so a path needing one would be testing `simplifile`'s
// `enoent` rather than the bridge.
const written_file = "written.txt"

const written_contents = "loom-bridge-write:alpha"

// The one replacement the edit leg makes, and the text it must produce.
// `alpha` occurs exactly once in the file, which is what
// `apply_replacements` requires and what makes the *second* attempt at
// the same find a stale one rather than an ambiguous one.
const edit_find = "alpha"

const edit_replace = "omega"

const edited_contents = "loom-bridge-write:omega"

// The protected directory, and the path inside it the program tries to
// write. A repository's hooks are the canonical reason the never-writable
// list exists: a file dropped here executes on the *human's* next
// checkout, outside every jail this tree builds.
const protected_dir = ".git"

const protected_hook = ".git/hooks/post-checkout"

const hook_contents = "#!/bin/sh"

// What the program reports having observed on each of the two refusal
// legs. Every branch is labelled, including the ones that must not
// happen, so a leg that succeeded and a leg that failed the wrong way are
// distinguishable in the outcome text rather than both reading as "the
// expected label is absent".
const stale_label = "stale-content"

const denied_label = "permission-denied"

const not_refused = "not-refused"

const wrong_refusal = "wrong-refusal"

/// A program of the kind a model would submit against the bridge's write
/// arms: a write, a read back, an edit, a read back, an edit whose `find`
/// no longer matches, and a write at a protected path. Both refusals are
/// pattern-matched on the *variant* and reported by label, because the
/// claim is that the program observed `StaleContent` and
/// `PermissionDenied` — not that the harness produced them.
///
/// One program for all six legs, for the reason `bridge_program_source`
/// gives: they are one seam record and one router, and a suite reaching
/// them one at a time would not notice an arm wired to its neighbour's
/// closure.
pub fn write_bridge_program_source() -> String {
  "import cap/fs\n"
  <> "import cap/report\n"
  <> "\n"
  <> "pub fn main() -> report.Outcome {\n"
  <> "  case fs.write(\""
  <> written_file
  <> "\", \""
  <> written_contents
  <> "\") {\n"
  <> "    Error(_error) -> report.failure(\"fs.write did not settle\")\n"
  <> "    Ok(Nil) -> after_write()\n"
  <> "  }\n"
  <> "}\n"
  <> "\n"
  <> "fn after_write() -> report.Outcome {\n"
  <> "  case fs.read(\""
  <> written_file
  <> "\") {\n"
  <> "    Error(_error) -> report.failure(\"the read back did not settle\")\n"
  <> "    Ok(written) -> after_read(written)\n"
  <> "  }\n"
  <> "}\n"
  <> "\n"
  <> "fn after_read(written: String) -> report.Outcome {\n"
  <> "  case fs.edit(\""
  <> written_file
  <> "\", ["
  <> replacement(edit_find, edit_replace)
  <> "]) {\n"
  <> "    Error(_error) -> report.failure(\"fs.edit did not settle\")\n"
  <> "    Ok(Nil) -> after_edit(written)\n"
  <> "  }\n"
  <> "}\n"
  <> "\n"
  <> "fn after_edit(written: String) -> report.Outcome {\n"
  <> "  case fs.read(\""
  <> written_file
  <> "\") {\n"
  <> "    Error(_error) -> report.failure(\"the re-read did not settle\")\n"
  <> "    Ok(edited) -> reporting(written, edited)\n"
  <> "  }\n"
  <> "}\n"
  <> "\n"
  <> "fn reporting(written: String, edited: String) -> report.Outcome {\n"
  <> "  let stale = stale_edit()\n"
  <> "  let protected = refused_write()\n"
  <> "  report.text(\n"
  <> "    \"wrote=\"\n"
  <> "    <> written\n"
  <> "    <> \" edited=\"\n"
  <> "    <> edited\n"
  <> "    <> \" stale=\"\n"
  <> "    <> stale\n"
  <> "    <> \" protected=\"\n"
  <> "    <> protected,\n"
  <> "  )\n"
  <> "}\n"
  <> "\n"
  // The same find again, against text that no longer holds it: zero
  // matches, which the ruling in `codemode/workspace`'s module doc gives
  // the honest meaning "the file no longer contains your text".
  <> "fn stale_edit() -> String {\n"
  <> "  case fs.edit(\""
  <> written_file
  <> "\", ["
  <> replacement(edit_find, edit_replace)
  <> "]) {\n"
  <> "    Ok(Nil) -> \""
  <> not_refused
  <> "\"\n"
  // Written out rather than as label shorthand: vetting parses a
  // slightly narrower Gleam than the compiler does.
  <> "    Error(fs.StaleContent(path: _path, message: _message)) -> \""
  <> stale_label
  <> "\"\n"
  <> "    Error(_other) -> \""
  <> wrong_refusal
  <> "\"\n"
  <> "  }\n"
  <> "}\n"
  <> "\n"
  <> "fn refused_write() -> String {\n"
  <> "  case fs.write(\""
  <> protected_hook
  <> "\", \""
  <> hook_contents
  <> "\") {\n"
  <> "    Ok(Nil) -> \""
  <> not_refused
  <> "\"\n"
  <> "    Error(fs.PermissionDenied(path: _path)) -> \""
  <> denied_label
  <> "\"\n"
  <> "    Error(_other) -> \""
  <> wrong_refusal
  <> "\"\n"
  <> "  }\n"
  <> "}\n"
}

// One `fs.Replacement` as a Gleam expression.
fn replacement(find: String, replace_with: String) -> String {
  "fs.Replacement(find: \""
  <> find
  <> "\", replace_with: \""
  <> replace_with
  <> "\")"
}

pub fn a_program_writes_edits_and_is_refused_a_protected_path_test() {
  case prerequisites() {
    Error(reason) ->
      io.println(
        "SKIP a_program_writes_edits_and_is_refused_a_protected_path: "
        <> reason,
      )
    Ok(ready) -> run_write_bridge(ready)
  }
}

// The bridge's write half against the real pipeline: a real vet, a real
// hermetic build, a real jailed satellite, and four `cap/fs` calls the
// harness answers itself over `tools/fs.resolve_writable` and
// `codemode/workspace.apply_replacements`.
//
// The decisive leg is the last one. `fs.write` at `.git/hooks/…` is the
// case that made bridging a write wait for the protected-path check
// (#105): without it a vetted program would hold *strictly more*
// filesystem authority than its own jailed `proc.run`, whose bwrap masks
// honour the never-writable list. So the refusal is asserted twice over —
// on the text the program composed, because the claim is that the program
// met `PermissionDenied` and could branch on it, and on the disk
// afterwards, because a refusal that reported itself and wrote the file
// anyway would satisfy the first assertion alone.
fn run_write_bridge(ready: Ready) -> Nil {
  let root = ready.root <> "-write"
  let workspace = workspace_in(root)
  let protected = workspace <> "/" <> protected_dir
  // Made before the rig, so the path the base policy protects — and the
  // jail therefore masks — exists by the time the first helper spawns.
  // The hooks directory in particular is what makes the refusal load
  // bearing: without it the write would fail for want of a parent, which
  // is a different sentence about a different thing.
  let assert Ok(Nil) = simplifile.create_directory_all(protected <> "/hooks")
    as "the protected fixture directory must be creatable"
  // A rig root outlives the run that made it, so the hook is removed
  // before rather than after: the closing assertion is "this file does
  // not exist", and a file some earlier run left there would otherwise
  // make it fail — or, worse, an earlier run that wrote it would make a
  // *later* one pass on a stale absence.
  let _ = simplifile.delete(workspace <> "/" <> protected_hook)
  let rig = rig_protecting(ready, under: root, protected: [protected])
  let seam =
    codemode.seam(codemode.default_config(
      broker: rig.broker,
      clock: wall_clock(),
      workspace: rig.workspace,
      toolchain: rig.toolchain,
    ))
  let outcome =
    codemode_tool.tool_for(seam).run(
      live_ctx(rig.workspace, rig.base_policy, wall_clock()),
      json.Object([
        #("program", json.String(write_bridge_program_source())),
        #("within_ms", json.Int(600_000)),
      ]),
    )
  let text = rendered_text(outcome)
  assert !outcome.is_error
  // (1) The round trip: the bytes the program wrote came back through a
  // second call, so the write reached a real file rather than being
  // answered `Ok` by a closure that did nothing.
  assert string.contains(text, "wrote=" <> written_contents)
  // (2) The edit applied, and the program read the edited text.
  assert string.contains(text, "edited=" <> edited_contents)
  // (3) and (4): both refusals, as the program itself classified them.
  assert string.contains(text, "stale=" <> stale_label)
  assert string.contains(text, "protected=" <> denied_label)
  assert !string.contains(text, not_refused)
  assert !string.contains(text, wrong_refusal)
  // On disk: the legitimate file holds the *edited* bytes — so the second
  // edit really was all-or-nothing and left nothing behind — and the hook
  // the program was refused does not exist.
  assert simplifile.read(rig.workspace <> "/" <> written_file)
    == Ok(edited_contents)
  assert simplifile.is_file(rig.workspace <> "/" <> protected_hook) == Ok(False)
  io.println(
    "code-mode bridge e2e: fs.write + fs.read + fs.edit through the real "
    <> "pipeline; a stale find and a write at "
    <> protected_hook
    <> " were both refused in band",
  )
  stop_rig(rig)
}

// --- report.emit on the orchestration seam (#91 item 1) ----------------------

/// The smallest program that proves the shared capability: an
/// orchestration submission that emits an artifact and reports its id.
///
/// `cap/report` is on both vetting allowlists and is the only module they
/// share, but `orchestration.serviced_caps` used to omit `emit` — so the
/// module's one effectful function was advertised in the description a
/// model is charged for on every request and refused every time it was
/// called. This is the test that would have caught that.
pub fn orchestration_emit_program_source() -> String {
  "import cap/report\n"
  <> "\n"
  <> "pub fn main() -> report.Outcome {\n"
  <> "  case\n"
  <> "    report.emit(\n"
  <> "      name: \"orchestrated.txt\",\n"
  <> "      content_type: \"text/plain\",\n"
  <> "      bytes: <<\""
  <> bridged_artifact_literal()
  <> "\":utf8>>,\n"
  <> "    )\n"
  <> "  {\n"
  <> "    Error(_error) -> report.failure(\"report.emit did not settle\")\n"
  <> "    Ok(reference) -> report.text(reference.id)\n"
  <> "  }\n"
  <> "}\n"
}

pub fn an_orchestration_program_emits_an_artifact_test() {
  case prerequisites() {
    Error(reason) ->
      io.println("SKIP an_orchestration_program_emits_an_artifact: " <> reason)
    Ok(ready) -> run_orchestration_emit(ready)
  }
}

// The orchestration seam, over an Agency that can do nothing at all. That
// is the point: the program touches no strand, so what is being proved is
// that `report.emit` is serviced *on this seam* rather than that the
// messaging plane works — which `orchestration_sample_test` proves
// elsewhere, against a real one.
fn run_orchestration_emit(ready: Ready) -> Nil {
  let rig = rig(ready, under: ready.root <> "-orch-emit")
  let seam =
    codemode.seam(
      codemode.default_config(
        broker: rig.broker,
        clock: wall_clock(),
        workspace: rig.workspace,
        toolchain: rig.toolchain,
      )
      |> codemode.orchestrating(over: unreachable_agency()),
    )
  let outcome =
    codemode_tool.tool_for(seam).run(
      live_ctx(rig.workspace, rig.base_policy, wall_clock()),
      json.Object([
        #("program", json.String(orchestration_emit_program_source())),
        #("within_ms", json.Int(600_000)),
        #("seam", json.String("orchestration")),
      ]),
    )
  let text = rendered_text(outcome)
  assert !outcome.is_error
  let id = artifact_id(outcome)
  assert id == blob.ref_for(<<bridged_artifact:utf8>>)
  // Same store, same address: an artifact minted from an orchestration
  // program and one minted from a workspace program are the same kind of
  // thing, which is what "one mechanism" has to mean to be worth saying.
  let path = blob.ref_path(rig.workspace <> "/" <> codemode.blob_directory, id)
  assert simplifile.read_bits(path) == Ok(<<bridged_artifact:utf8>>)
  assert string.contains(text, id)
  io.println(
    "code-mode orchestration e2e: report.emit is serviced on the "
    <> "orchestration seam and wrote "
    <> id,
  )
  stop_rig(rig)
}

// An Agency that refuses everything. The emitting program never asks it
// anything; a seam that had wired `report.emit` onto a `strand.*` arm by
// mistake would come back `strands_unavailable` rather than with an id.
fn unreachable_agency() -> agent.Agency {
  agent.Agency(
    spawn: fn(_caller, _request) { Error(agent.AgencyUnavailable) },
    wait: fn(_caller, _handles, _within) { Error(agent.AgencyUnavailable) },
    send: fn(_caller, _to, _text) { Error(agent.AgencyUnavailable) },
    note: fn(_caller, _key, _value) { Error(agent.AgencyUnavailable) },
    notes: fn(_caller, _prefix) { Error(agent.AgencyUnavailable) },
    roster: fn(_caller) { Error(agent.AgencyUnavailable) },
    max_wait_ms: 30_000,
  )
}

// --- the rig ---------------------------------------------------------------

fn prerequisites() -> Result(Ready, String) {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner must have a working directory"
  let repo = here <> "/../.."
  let helper_path = repo <> "/bin/loom-exec"
  let seed_root = repo <> "/build/codemode-seed"
  use Nil <- result.try(check_helper_current(
    helper_path,
    repo <> "/packages/sandbox",
  ))
  case codemode.discover(seed_root) {
    Error(reason) -> Error(reason)
    Ok(_toolchain) ->
      Ok(Ready(
        helper_path:,
        seed_root:,
        root: here <> "/build/codemode-tool-e2e",
      ))
  }
}

// --- helper staleness (issue #61) -------------------------------------------
//
// `bin/loom-exec` is a checked-in artifact, refreshed only by `make
// binaries`; every other live-helper suite in this tree builds its own
// helper from source into its own build directory on every run and so can
// never go stale (`broker/integration_test`, `codemode/support/rig`,
// `conformance/support/jail`, `tools/integration_test` — grepped for
// `loom-exec` across `packages/*/test` to confirm this is the one site
// with the trap). A helper from any commit before the wire protocol's
// most recent required-field change passes a bare `simplifile.is_file`
// check and then fails 3/3 as an anonymous `ChannelFault` — the decode is
// correctly refusing a frame the stale helper never learned to send — so
// the check here establishes *currency*, not merely presence.
//
// Absent and stale are told apart in the message even though `make
// binaries` remedies both, because only one of them looks like a missing
// file. And this is a skip, not a failure: a stale checked-in artifact is
// the same category of unsatisfied local prerequisite as a missing `go`
// or `erl` toolchain, which every other guard in this file already treats
// as a skip — failing it would turn "you forgot to run a make target"
// into a red `make check` for a reason no code change in this tree
// caused, which is exactly the wrong signal to send from a suite whose
// whole point is to be hermetic when its prerequisites are not met.

fn check_helper_current(
  helper_path: String,
  sandbox_root: String,
) -> Result(Nil, String) {
  case simplifile.is_file(helper_path) {
    Ok(True) -> check_helper_freshness(helper_path, sandbox_root)
    _absent_or_unreadable ->
      Error("no loom-exec at " <> helper_path <> "; run `make binaries`")
  }
}

fn check_helper_freshness(
  helper_path: String,
  sandbox_root: String,
) -> Result(Nil, String) {
  use info <- result.try(
    simplifile.file_info(helper_path)
    |> result.replace_error(
      "cannot read the mtime of " <> helper_path <> "; run `make binaries`",
    ),
  )
  use sources <- result.try(go_source_mtimes(sandbox_root))
  case freshness(info.mtime_seconds, sources) {
    Current -> Ok(Nil)
    Stale(newer_source:) ->
      Error(
        "loom-exec at "
        <> helper_path
        <> " is stale (older than "
        <> newer_source
        <> "); run `make binaries`",
      )
  }
}

// Every `.go` file's path and mtime under the sandbox package. The
// `build/` directory it also contains holds transient test binaries, not
// sources, so filtering on the `.go` suffix rather than excluding a path
// keeps this honest if that directory is ever renamed.
fn go_source_mtimes(
  sandbox_root: String,
) -> Result(List(#(String, Int)), String) {
  use paths <- result.try(
    simplifile.get_files(in: sandbox_root)
    |> result.replace_error(
      "cannot list " <> sandbox_root <> " to check loom-exec staleness",
    ),
  )
  paths
  |> list.filter(string.ends_with(_, ".go"))
  |> list.try_map(go_source_mtime)
}

fn go_source_mtime(path: String) -> Result(#(String, Int), String) {
  simplifile.file_info(path)
  |> result.map(fn(info) { #(path, info.mtime_seconds) })
  |> result.replace_error("cannot read the mtime of " <> path)
}

/// Whether a binary built at `binary_mtime` is at least as new as every
/// source in `sources` — `Current`, or `Stale` naming the newest source
/// that outdates it. Pure and total: split out from the filesystem walk
/// above so the comparison itself is fixture-testable without touching
/// the filesystem or rebuilding anything real, which is the property the
/// live test's staleness check needs to prove on its own.
type Freshness {
  Current
  Stale(newer_source: String)
}

fn freshness(binary_mtime: Int, sources: List(#(String, Int))) -> Freshness {
  case freshest(sources) {
    option.None -> Current
    option.Some(#(path, mtime)) ->
      case mtime > binary_mtime {
        True -> Stale(path)
        False -> Current
      }
  }
}

fn freshest(sources: List(#(String, Int))) -> option.Option(#(String, Int)) {
  list.fold(sources, option.None, fn(acc, entry) {
    case acc {
      option.None -> option.Some(entry)
      option.Some(#(_, best)) ->
        case entry.1 > best {
          True -> option.Some(entry)
          False -> acc
        }
    }
  })
}

pub fn freshness_flags_a_binary_older_than_its_newest_source_test() {
  let sources = [
    #("packages/sandbox/cmd/loom-exec/main.go", 150),
    #("packages/sandbox/internal/jail/cancel.go", 200),
  ]
  let assert Stale(newer_source:) = freshness(100, sources)
  assert newer_source == "packages/sandbox/internal/jail/cancel.go"
}

pub fn freshness_accepts_a_binary_at_least_as_new_as_every_source_test() {
  let sources = [
    #("packages/sandbox/cmd/loom-exec/main.go", 50),
    #("packages/sandbox/internal/jail/cancel.go", 100),
  ]
  assert freshness(100, sources) == Current
}

pub fn freshness_with_no_sources_is_current_test() {
  assert freshness(0, []) == Current
}

// Everything the four live runs stand up before they can execute
// anything: a workspace and its tmp directory, the session base, a
// helper pool over the checked-in `loom-exec`, a broker over that pool,
// and the located toolchain. One helper because the four wanted exactly
// the same rig and said so four times over.
//
// Each run still names its own root, and that is load-bearing rather
// than tidiness: a run's build directory, its cap socket and its token
// file all live under it, and the launcher's janitor runs teardown
// asynchronously — two runs sharing a root would race each other's
// cleanup (issue #87).
type Rig {
  Rig(
    root: String,
    workspace: String,
    base_policy: policy.SandboxPolicy,
    pool: exec.Pool,
    broker: broker.Broker,
    toolchain: codemode.Toolchain,
  )
}

// The workspace inside a rig root. Named rather than inlined because a
// run that has to state a path *inside* the workspace in the base policy
// it hands the rig — the protected-path run below — needs the derivation
// before the rig exists.
fn workspace_in(root: String) -> String {
  root <> "/work"
}

fn rig(ready: Ready, under root: String) -> Rig {
  rig_protecting(ready, under: root, protected: [])
}

fn rig_protecting(
  ready: Ready,
  under root: String,
  protected protected: List(String),
) -> Rig {
  let workspace = workspace_in(root)
  let assert Ok(Nil) = simplifile.create_directory_all(workspace <> "/tmp")
    as "the live rig must have a workspace"
  let base = policy.SandboxPolicy(..base_policy(root), protected:)
  let assert Ok(pool) =
    exec.start_pool(size: 3, spawn: fn() {
      exec.spawn_helper(exec.SpawnConfig(
        helper_path: ready.helper_path,
        shell_path: "/bin/sh",
        base_policy: base,
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
  Rig(
    root:,
    workspace:,
    base_policy: base,
    pool:,
    broker: broker_actor,
    toolchain:,
  )
}

fn stop_rig(rig: Rig) -> Nil {
  broker.stop(rig.broker)
  exec.stop_pool(rig.pool)
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
    raise_refusal: tool.no_raise(),
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
