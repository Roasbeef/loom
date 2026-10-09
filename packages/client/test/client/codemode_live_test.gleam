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
import broker/budget
import broker/escalation
import broker/exec
import broker/policy
import broker/token
import client/catalog
import client/codemode
import client/gateway_test
import client/install
import client/internal/ffi_os
import client/mcp as mcp_wiring
import client/peer_mail
import client/peers
import client/schedule
import client/scheduleseam
import client/scratch
import client/serve
import client/working_directory
import core/clock
import core/ids
import core/json
import core/message
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleam_mcp/client as mcp_client
import gleam_mcp/json as mcp_json
import machine/operation
import mcp/codegen
import provider/secret
import runtime/api
import session/session
import simplifile
import support/addresses
import support/fake_mcp
import support/notes_session
import tools/agent
import tools/blob
import tools/codemode as codemode_tool
import tools/codemode_recipes
import tools/directory_access
import tools/fs
import tools/tool
import tools/working_directory as directory
import weft/poll

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
      io.println_error(
        "SKIP a_submitted_program_runs_through_the_tool: " <> reason,
      )
    Ok(ready) -> run_live(ready)
  }
}

// --- the run ---------------------------------------------------------------

type Ready {
  Ready(helper_path: String, seed_root: String, root: String)
}

type Prepared {
  Prepared(helper_path: String, seed_root: String)
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
  assert string.contains(sandbox, " enforced [")
  assert !string.contains(sandbox, "made NO enforcement report")
  assert string.contains(sandbox, "build and node enforced [")
    || {
      string.contains(sandbox, codemode_tool.build_stage <> " enforced [")
      && string.contains(
        sandbox,
        codemode_tool.satellite_stage <> " enforced [",
      )
    }
  // Printed, so a degraded run is visible rather than silently green:
  // *which* layers held is a property of this kernel, not of the harness.
  io.println("code-mode tool e2e: " <> sandbox)
  directory_case(rig)
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
      io.println_error(
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
  let rig = rig(ready, under: ready.root)
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
/// is `mcp/codegen`'s: required parameters are labelled, and an options
/// record admits only the optional fields the server declared.
pub fn mcp_program_source() -> String {
  "import cap/mcp\n"
  <> "import cap/mcp/alpha\n"
  <> "import cap/report\n"
  <> "\n"
  <> "pub fn main() -> report.Outcome {\n"
  <> "  case alpha.search(query: \"loom\", options: alpha.search_defaults) {\n"
  <> "    Ok(found) -> report.text(mcp.text(found))\n"
  <> "    Error(_error) -> report.failure(\"the mcp call did not settle\")\n"
  <> "  }\n"
  <> "}\n"
}

pub fn a_program_calls_a_configured_mcp_server_test() {
  case prerequisites() {
    Error(reason) ->
      io.println_error(
        "SKIP a_program_calls_a_configured_mcp_server: " <> reason,
      )
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
// `gleam_mcp/transport.ChannelTransport`. Spawning a third-party binary is
// what the fake replaces, and it is the one part of this path that has
// no bearing on whether a generated façade compiles and dispatches.
fn run_mcp(ready: Ready) -> Nil {
  let rig = rig(ready, under: ready.root)
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
    custody: [client],
  )
}

// Shape errors must be rejected before a request can reach a server. These
// programs use the discovered API, so the actual hermetic compiler is the
// argument validator rather than a source-text assertion.
/// Checks typed inputs and decoded outputs against the actual capability channel.
///
/// Omitted options, explicit null, enum constructors, and nested records must
/// preserve their distinct wire meanings through compilation and dispatch.
///
/// ## Examples
///
/// This regression runs when the real code-mode prerequisites are available.
pub fn typed_mcp_inputs_and_results_cross_the_real_channel_test() {
  case prerequisites() {
    Error(reason) ->
      io.println_error("SKIP typed_mcp_inputs_and_results: " <> reason)
    Ok(ready) -> run_typed_mcp_round_trip(ready)
  }
}

fn run_typed_mcp_round_trip(ready: Ready) -> Nil {
  let rig = rig(ready, under: ready.root)
  let seen = process.new_subject()
  let layer = typed_mcp_layer(seen)
  let outcome =
    run_notes_program(
      typed_mcp_config(rig, layer),
      rig,
      typed_mcp_program("valid"),
      "typed-mcp",
    )
  assert !outcome.is_error as rendered_text(outcome)
  assert notes_program_value(outcome) == json.String("application-1")
  let assert Ok(#("list_applications", arguments)) = process.receive(seen, 1000)
    as "the typed call must reach the server exactly once"
  assert arguments
    == mcp_json.Object([
      #("job_id", mcp_json.String("valid")),
      #(
        "filter",
        mcp_json.Object([
          #("region", mcp_json.String("north")),
          #("tags", mcp_json.Array([])),
        ]),
      ),
      #("status", mcp_json.String("active")),
      #("cursor", mcp_json.Null),
      #("limit", mcp_json.Int(0)),
    ])
  assert process.receive(seen, 0) == Error(Nil)
  mcp_wiring.stop(layer)
  stop_rig(rig)
}

fn typed_mcp_program(job_id: String) -> String {
  "import cap/mcp/typed\nimport cap/report\nimport gleam/option.{Some, None}\n"
  <> "pub fn main() -> report.Outcome {\n"
  <> "  let filter = typed.Filter(region: \"north\", tags: [])\n"
  <> "  let options = typed.ListApplicationsOptions(..typed.list_applications_defaults, status: Some(typed.StatusActive2), cursor: Some(None), limit: Some(0))\n"
  <> "  case typed.list_applications(job_id: \""
  <> job_id
  <> "\", filter: filter, options: options) {\n"
  <> "    Ok(found) -> case found.results, found.next_cursor {\n"
  <> "      [row], Some(None) -> case row.status, row.active {\n"
  <> "        typed.StatusActive, typed.ActiveEnabled -> report.text(row.id)\n"
  <> "        _, _ -> report.failure(\"wrong decoded enum or boolean\")\n"
  <> "      }\n"
  <> "      _, _ -> report.failure(\"wrong result or null presence\")\n"
  <> "    }\n"
  <> "    Error(_) -> report.failure(\"typed result was refused\")\n"
  <> "  }\n}\n"
}

/// Checks that an invalid output retains its text and exact nested failure path.
///
/// The fixture sends an integer where the result record requires a string; the
/// program must receive ResultSchemaMismatch rather than a successful record.
///
/// ## Examples
///
/// This regression runs when the real code-mode prerequisites are available.
pub fn typed_mcp_schema_mismatch_retains_text_and_path_test() {
  case prerequisites() {
    Error(reason) ->
      io.println_error("SKIP typed_mcp_schema_mismatch: " <> reason)
    Ok(ready) -> run_typed_mcp_mismatch(ready)
  }
}

fn run_typed_mcp_mismatch(ready: Ready) -> Nil {
  let rig = rig(ready, under: ready.root)
  let seen = process.new_subject()
  let layer = typed_mcp_layer(seen)
  let source =
    "import cap/mcp\nimport cap/mcp/typed\nimport cap/report\nimport gleam/list\n"
    <> "pub fn main() -> report.Outcome {\n"
    <> "  case typed.list_applications(job_id: \"malformed\", filter: typed.Filter(region: \"north\", tags: []), options: typed.list_applications_defaults) {\n"
    <> "    Error(mcp.ResultSchemaMismatch(error, result)) -> report.value(report.object([#(\"path\", report.list(list.map(error.path, report.string))), #(\"text\", report.string(mcp.text(result)))]))\n"
    <> "    _ -> report.failure(\"the malformed answer did not fail typed decoding\")\n"
    <> "  }\n}\n"
  let outcome =
    run_notes_program(
      typed_mcp_config(rig, layer),
      rig,
      source,
      "typed-mismatch",
    )
  assert !outcome.is_error as rendered_text(outcome)
  assert notes_program_value(outcome)
    == json.Object([
      #(
        "path",
        json.Array([
          json.String("results"),
          json.String("0"),
          json.String("id"),
        ]),
      ),
      #("text", json.String("Readable fixture result.")),
    ])
  let assert Ok(#("list_applications", _)) = process.receive(seen, 1000)
    as "the malformed result must follow a real server call"
  assert process.receive(seen, 0) == Error(Nil)
  mcp_wiring.stop(layer)
  stop_rig(rig)
}

/// Checks that enum, option-label, and nested-field mistakes fail compilation.
///
/// A recording subject proves that none of these rejected programs reaches the
/// configured MCP server.
///
/// ## Examples
///
/// This regression runs when the real code-mode prerequisites are available.
pub fn typed_mcp_mistakes_fail_before_server_execution_test() {
  case prerequisites() {
    Error(reason) ->
      io.println_error("SKIP typed_mcp_compile_refusals: " <> reason)
    Ok(ready) -> run_typed_mcp_compile_refusals(ready)
  }
}

fn run_typed_mcp_compile_refusals(ready: Ready) -> Nil {
  let rig = rig(ready, under: ready.root)
  let seen = process.new_subject()
  let layer = typed_mcp_layer(seen)
  let config = typed_mcp_config(rig, layer)
  let valid = typed_mcp_program("valid")
  let mistakes = [
    #(
      "enum",
      string.replace(valid, "Some(typed.StatusActive2)", "Some(\"active\")"),
      "Type mismatch",
    ),
    #(
      "option",
      string.replace(valid, "limit: Some(0)", "limti: Some(0)"),
      "limti",
    ),
    #(
      "nested",
      string.replace(valid, "region: \"north\"", "region: 12"),
      "Type mismatch",
    ),
  ]
  list.each(mistakes, fn(mistake) {
    let #(name, source, diagnostic) = mistake
    let outcome =
      run_notes_program(config, rig, source, "typed-refusal-" <> name)
    assert outcome.is_error as rendered_text(outcome)
    assert string.contains(rendered_text(outcome), diagnostic)
      as rendered_text(outcome)
    assert process.receive(seen, 0) == Error(Nil)
      as "compile refusals must never call the MCP server"
  })
  mcp_wiring.stop(layer)
  stop_rig(rig)
}

/// Preserves a valid answer after nested fallback removes a union discriminator.
///
/// ## Examples
///
/// This regression exercises the generated decoder inside the real satellite.
pub fn rendered_mcp_union_fallback_preserves_valid_output_test() {
  case prerequisites() {
    Error(reason) -> io.println_error("SKIP rendered_mcp_union: " <> reason)
    Ok(ready) -> run_rendered_mcp_union(ready)
  }
}

fn run_rendered_mcp_union(ready: Ready) -> Nil {
  let rig = rig(ready, under: ready.root)
  let seen = process.new_subject()
  let layer = typed_mcp_layer(seen)
  let source =
    "import cap/mcp/typed\nimport cap/report\n"
    <> "pub fn main() -> report.Outcome {\n"
    <> "  case typed.zz_union_probe(options: typed.zz_union_probe_defaults) {\n"
    <> "    Ok(value) -> report.value(value)\n"
    <> "    Error(_) -> report.failure(\"valid union result was rejected\")\n"
    <> "  }\n}\n"
  let outcome =
    run_notes_program(
      typed_mcp_config(rig, layer),
      rig,
      source,
      "rendered-mcp-union",
    )
  assert !outcome.is_error as rendered_text(outcome)
  assert notes_program_value(outcome)
    == json.Object([
      #(
        "box",
        json.Object([
          #("tag", json.String("left")),
          #("A", json.String("a")),
          #("a_559aead0", json.String("b")),
        ]),
      ),
    ])
  let assert Ok(#("zz_union_probe", _)) = process.receive(seen, 1000)
    as "the valid union answer must follow a real server call"
  assert process.receive(seen, 0) == Error(Nil)
  mcp_wiring.stop(layer)
  stop_rig(rig)
}

/// Compiles every facade from the existing GitHub-shaped listing in the jail.
///
/// Referencing one function admits the module without calling the server, while
/// Gleam checks all its declarations and bodies with warnings treated as errors.
///
/// ## Examples
///
/// This regression runs when the real code-mode prerequisites are available.
pub fn github_mcp_fixture_compiles_in_the_real_jail_test() {
  case prerequisites() {
    Error(reason) -> io.println_error("SKIP github_mcp_compile: " <> reason)
    Ok(ready) -> run_github_mcp_compile(ready)
  }
}

fn run_github_mcp_compile(ready: Ready) -> Nil {
  let rig = rig(ready, under: ready.root)
  let seen = process.new_subject()
  let layer = fixture_mcp_layer("github", "github.json", seen)
  let source =
    "import cap/mcp/github\nimport cap/report\n"
    <> "pub fn main() -> report.Outcome {\n"
    <> "  let _ = github.list_issues\n"
    <> "  report.text(\"GitHub facade compiled.\")\n}\n"
  let outcome =
    run_notes_program(
      typed_mcp_config(rig, layer),
      rig,
      source,
      "github-mcp-compile",
    )
  assert !outcome.is_error as rendered_text(outcome)
  assert notes_program_value(outcome) == json.String("GitHub facade compiled.")
  assert process.receive(seen, 0) == Error(Nil)
    as "compilation must not issue an MCP tool call"
  mcp_wiring.stop(layer)
  stop_rig(rig)
}

/// Decodes schemas captured from the official Go MCP SDK through the jail.
///
/// SDK slice nullability and nested records are retained rather than rewritten
/// to fit a hand-authored schema. The fixture provenance pins its real server.
///
/// ## Examples
///
/// This regression reads a nested stage from the returned application record.
pub fn go_sdk_mcp_output_crosses_the_real_jail_test() {
  case prerequisites() {
    Error(reason) -> io.println_error("SKIP go_sdk_mcp_output: " <> reason)
    Ok(ready) -> run_go_sdk_mcp(ready)
  }
}

fn run_go_sdk_mcp(ready: Ready) -> Nil {
  let rig = rig(ready, under: ready.root)
  let seen = process.new_subject()
  let layer = fixture_mcp_layer("go_sdk", "go_sdk.json", seen)
  let source =
    "import cap/mcp/go_sdk as sdk\n"
    <> "import cap/report\n"
    <> "import gleam/option.{Some}\n"
    <> "pub fn main() -> report.Outcome {\n"
    <> "  case sdk.list_applications(job_id: \"go-sdk\", filter: sdk.Filter(region: \"north\", tags: Some([])), options: sdk.list_applications_defaults) {\n"
    <> "    Ok(found) -> case found.applications, found.has_more {\n"
    <> "      Some([row, ..]), sdk.HasMoreDisabled -> report.text(row.id <> \"/\" <> row.stage.name)\n"
    <> "      _, _ -> report.failure(\"The SDK fixture returned no application.\")\n"
    <> "    }\n"
    <> "    Error(_reason) -> report.failure(\"The SDK fixture did not decode.\")\n"
    <> "  }\n"
    <> "}\n"
  let outcome =
    run_notes_program(
      typed_mcp_config(rig, layer),
      rig,
      source,
      "go-sdk-mcp-output",
    )
  assert !outcome.is_error as rendered_text(outcome)
  assert notes_program_value(outcome) == json.String("application-1/Screen")
  let assert Ok(#(tool_name, arguments)) = process.receive(seen, 0)
    as "the generated facade must invoke the SDK fixture"
  assert tool_name == "list_applications"
  assert arguments
    == mcp_json.Object([
      #("job_id", mcp_json.String("go-sdk")),
      #(
        "filter",
        mcp_json.Object([
          #("region", mcp_json.String("north")),
          #("tags", mcp_json.Array([])),
        ]),
      ),
    ])
  mcp_wiring.stop(layer)
  stop_rig(rig)
}

/// Executes the documented structured fixture example without rewriting it.
///
/// The block is extracted from the architecture guide so a schema-name change
/// cannot leave a plausible-looking program that the actual compiler rejects.
///
/// ## Examples
///
/// This regression runs the guide's entry point through the satellite.
pub fn documented_typed_mcp_example_runs_test() {
  case prerequisites() {
    Error(reason) -> io.println_error("SKIP documented_typed_mcp: " <> reason)
    Ok(ready) -> run_documented_typed_mcp(ready)
  }
}

fn run_documented_typed_mcp(ready: Ready) -> Nil {
  let rig = rig(ready, under: ready.root)
  let seen = process.new_subject()
  let layer = fixture_mcp_layer("structured", "structured.json", seen)
  let assert Ok(document) = simplifile.read("../../docs/architecture/mcp.md")
    as "the architecture guide must be available"
  let assert Ok(block) =
    list.find(string.split(document, "```gleam\n"), fn(block) {
      string.starts_with(block, "import cap/mcp\nimport cap/mcp/structured")
    })
    as "the guide must contain its complete structured example"
  let assert [source, ..] = string.split(block, "```")
    as "the guide's Gleam fence must close"
  let outcome =
    run_notes_program(
      typed_mcp_config(rig, layer),
      rig,
      source,
      "documented-typed-mcp",
    )
  assert !outcome.is_error as rendered_text(outcome)
  assert notes_program_value(outcome) == json.Int(1)
  let assert Ok(#("list_applications", _)) = process.receive(seen, 1000)
    as "the documented query must reach the server"
  assert process.receive(seen, 0) == Error(Nil)
  mcp_wiring.stop(layer)
  stop_rig(rig)
}

/// Runs the documented concise Jev batch through the compiler and cap channel.
///
/// The fixture uses schemas discovered from the installed Jevelin server. One
/// typed constructor selects each request tag; returned variants must decode
/// before the documented program can extract their choice and score fields.
///
/// ## Examples
///
/// This regression runs the guide's complete entry point in the satellite.
pub fn documented_jev_batch_uses_typed_variants_test() {
  case prerequisites() {
    Error(reason) -> io.println_error("SKIP documented_jev_batch: " <> reason)
    Ok(ready) -> run_documented_jev_batch(ready)
  }
}

fn run_documented_jev_batch(ready: Ready) -> Nil {
  let rig = rig(ready, under: ready.root)
  let seen = process.new_subject()
  let layer = fixture_mcp_layer("jev", "jev.json", seen)
  let outcome =
    run_notes_program(
      typed_mcp_config(rig, layer),
      rig,
      documented_jev_program(),
      "documented-jev-batch",
    )
  assert !outcome.is_error as rendered_text(outcome)
  assert notes_program_value(outcome)
    == json.Object([
      #("model", json.String("jev-fixture")),
      #("choice", json.String("logs")),
      #("confidence", json.Float(0.9)),
      #("score", json.Float(0.25)),
      #(
        "usage",
        json.Object([
          #("input_tokens", json.Int(10)),
          #("output_tokens", json.Int(3)),
        ]),
      ),
    ])
  let assert Ok(#("jev_batch", arguments)) = process.receive(seen, 1000)
    as "one batch must reach the production MCP client"
  assert arguments
    == mcp_json.Object([
      #("state", mcp_json.String("The user wants to inspect a failed build.")),
      #(
        "questions",
        mcp_json.Array([
          mcp_json.Object([
            #("name", mcp_json.String("route")),
            #("type", mcp_json.String("choice")),
            #(
              "choices",
              mcp_json.Array([
                mcp_json.Object([
                  #("label", mcp_json.String("logs")),
                  #("description", mcp_json.String("Read compiler logs")),
                ]),
                mcp_json.Object([#("label", mcp_json.String("tests"))]),
              ]),
            ),
          ]),
          mcp_json.Object([
            #("name", mcp_json.String("priority")),
            #("type", mcp_json.String("score")),
            #(
              "levels",
              mcp_json.Array([mcp_json.String("low"), mcp_json.String("high")]),
            ),
          ]),
        ]),
      ),
    ])
  assert process.receive(seen, 0) == Error(Nil)
    as "the batch must be the only server call"
  mcp_wiring.stop(layer)
  stop_rig(rig)
}

/// Refuses incompatible variant fields before any Jev tool is invoked.
///
/// ## Examples
///
/// A ScoreQuestion cannot be constructed with Choice criteria.
pub fn concise_jev_variant_mistakes_fail_before_execution_test() {
  case prerequisites() {
    Error(reason) -> io.println_error("SKIP concise_jev_refusals: " <> reason)
    Ok(ready) -> run_jev_variant_refusals(ready)
  }
}

fn run_jev_variant_refusals(ready: Ready) -> Nil {
  let rig = rig(ready, under: ready.root)
  let seen = process.new_subject()
  let layer = fixture_mcp_layer("jev", "jev.json", seen)
  let source = documented_jev_program()
  let mistakes = [
    #(
      "fields",
      string.replace(source, "jev.ScoreQuestion(", "jev.ChoiceQuestion("),
      "levels",
    ),
    #(
      "level",
      string.replace(source, "jev.LevelText(\"low\")", "\"low\""),
      "Type mismatch",
    ),
  ]
  list.each(mistakes, fn(mistake) {
    let #(name, program, diagnostic) = mistake
    let outcome =
      run_notes_program(
        typed_mcp_config(rig, layer),
        rig,
        program,
        "jev-refusal-" <> name,
      )
    assert outcome.is_error as rendered_text(outcome)
    assert string.contains(rendered_text(outcome), diagnostic)
      as rendered_text(outcome)
    assert process.receive(seen, 0) == Error(Nil)
      as "an invalid variant must never reach the MCP server"
  })
  mcp_wiring.stop(layer)
  stop_rig(rig)
}

/// Checks missing and wrong tags through the generated satellite decoder.
///
/// ## Examples
///
/// Malformed tagged answers retain the schema-mismatch error channel.
pub fn concise_jev_output_requires_its_exact_tag_test() {
  case prerequisites() {
    Error(reason) -> io.println_error("SKIP concise_jev_tags: " <> reason)
    Ok(ready) -> run_jev_tag_refusals(ready)
  }
}

fn run_jev_tag_refusals(ready: Ready) -> Nil {
  let rig = rig(ready, under: ready.root)
  let seen = process.new_subject()
  let layer = fixture_mcp_layer("jev", "jev.json", seen)
  let source =
    documented_jev_program()
    |> string.replace(
      "import cap/mcp/jev\n",
      "import cap/mcp\nimport cap/mcp/jev\n",
    )
    |> string.replace(
      "Error(_) -> report.failure(\"The Jev batch was refused.\")",
      "Error(mcp.ResultSchemaMismatch(_, _)) -> report.text(\"tag refused\")\n"
        <> "Error(_) -> report.failure(\"Wrong error channel.\")",
    )
  list.each(["missing-tag", "wrong-tag"], fn(state) {
    let program =
      string.replace(source, "The user wants to inspect a failed build.", state)
    let outcome =
      run_notes_program(
        typed_mcp_config(rig, layer),
        rig,
        program,
        "jev-" <> state,
      )
    assert !outcome.is_error as rendered_text(outcome)
    assert notes_program_value(outcome) == json.String("tag refused")
    let assert Ok(#("jev_batch", _)) = process.receive(seen, 1000)
      as "the tag refusal must follow one actual server response"
    assert process.receive(seen, 0) == Error(Nil)
  })
  mcp_wiring.stop(layer)
  stop_rig(rig)
}

fn documented_jev_program() -> String {
  let assert Ok(document) = simplifile.read("../../docs/jev-mcp.md")
    as "the Jev guide must be available"
  let assert Ok(block) =
    list.find(string.split(document, "```gleam\n"), fn(block) {
      string.contains(block, "import cap/mcp/jev\n")
    })
    as "the guide must contain the complete Jev batch program"
  let assert [source, ..] = string.split(block, "```")
    as "the guide's Gleam fence must close"
  source
}

// The typed fixture owns no process transport. The production MCP client,
// generated module, hermetic compiler, satellite, and capability router all
// run; a subject records each request before the fixture answers it.
fn typed_mcp_layer(
  seen: process.Subject(#(String, mcp_json.JsonValue)),
) -> mcp_wiring.Layer {
  fixture_mcp_layer("typed", "structured.json", seen)
}

fn fixture_mcp_layer(
  server: String,
  filename: String,
  seen: process.Subject(#(String, mcp_json.JsonValue)),
) -> mcp_wiring.Layer {
  let assert Ok(source) =
    simplifile.read("../mcp/test/mcp/fixtures/" <> filename)
    as "the structured tools/list fixture must exist"
  let assert Ok(mcp_json.Object(fields)) = mcp_json.parse(source)
    as "the fixture must be a JSON object"
  let assert Ok(mcp_json.Array(tools)) = list.key_find(fields, "tools")
    as "the fixture must list tools"
  let assert Ok(client) =
    mcp_client.start(
      fake_mcp.seam(tools:, call: fn(name, arguments) {
        process.send(seen, #(name, arguments))
        fake_mcp.Answers(fixture_mcp_result(name, arguments))
      }),
      mcp_client.options("typed-fixture"),
    )
    as "the fixture must complete the MCP handshake"
  let assert Ok(listed) = mcp_client.list_tools(client, 5000)
    as "the fixture must list its typed tools"
  let assert Ok(generated) =
    codegen.generate(server, listed, mcp_wiring.sha256_hex)
    as "hostile names and structured schemas must generate safely"
  mcp_wiring.Layer(
    servers: [
      mcp_wiring.Server(
        name: server,
        client:,
        generated:,
        tools: list.length(listed),
      ),
    ],
    call_timeout_ms: 30_000,
    custody: [client],
  )
}

// A rendered union can lose its discriminator when a nested record falls back.
// The valid original wire answer must still arrive as a raw value, not be
// rejected by two overlapping decoders derived from the earlier schema plan.
fn fixture_mcp_result(
  name: String,
  arguments: mcp_json.JsonValue,
) -> mcp_json.JsonValue {
  case name {
    "jev_batch" -> concise_jev_result(arguments)
    "zz_union_probe" ->
      mcp_json.Object([
        #("content", mcp_json.Array([])),
        #(
          "structuredContent",
          mcp_json.Object([
            #(
              "box",
              mcp_json.Object([
                #("tag", mcp_json.String("left")),
                #("A", mcp_json.String("a")),
                #("a_559aead0", mcp_json.String("b")),
              ]),
            ),
          ]),
        ),
      ])
    _ -> fixture_application_result(arguments)
  }
}

// These literal answers obey the installed server's advertised schema. The
// real client still decodes them through the generated satellite codec.
fn concise_jev_result(arguments: mcp_json.JsonValue) -> mcp_json.JsonValue {
  let state = case arguments {
    mcp_json.Object(fields) -> list.key_find(fields, "state")
    _ -> Error(Nil)
  }
  let tag = case state {
    Ok(mcp_json.String("missing-tag")) -> []
    Ok(mcp_json.String("wrong-tag")) -> [#("type", mcp_json.String("invalid"))]
    _ -> [#("type", mcp_json.String("choice"))]
  }

  mcp_json.Object([
    #("content", mcp_json.Array([])),
    #(
      "structuredContent",
      mcp_json.Object([
        #("model", mcp_json.String("jev-fixture")),
        #(
          "answers",
          mcp_json.Object([
            #(
              "route",
              mcp_json.Object(
                list.append(tag, [
                  #("choice", mcp_json.String("logs")),
                  #("confidence", mcp_json.Float(0.9)),
                  #(
                    "probabilities",
                    mcp_json.Object([
                      #("logs", mcp_json.Float(1.0)),
                      #("tests", mcp_json.Float(0.0)),
                    ]),
                  ),
                ]),
              ),
            ),
            #(
              "priority",
              mcp_json.Object([
                #("type", mcp_json.String("score")),
                #("score", mcp_json.Float(0.25)),
                #("confidence", mcp_json.Float(0.5)),
                #(
                  "probabilities",
                  mcp_json.Object([
                    #("0", mcp_json.Float(0.75)),
                    #("1", mcp_json.Float(0.25)),
                  ]),
                ),
                #(
                  "legend",
                  mcp_json.Object([
                    #("0", mcp_json.String("low")),
                    #("1", mcp_json.String("high")),
                  ]),
                ),
              ]),
            ),
          ]),
        ),
        #(
          "usage",
          mcp_json.Object([
            #("input_tokens", mcp_json.Int(10)),
            #("output_tokens", mcp_json.Int(3)),
          ]),
        ),
      ]),
    ),
  ])
}

fn fixture_application_result(
  arguments: mcp_json.JsonValue,
) -> mcp_json.JsonValue {
  let sdk_result = case arguments {
    mcp_json.Object(fields) ->
      list.contains(fields, #("job_id", mcp_json.String("go-sdk")))
    _ -> False
  }
  case sdk_result {
    False -> typed_mcp_result(arguments)
    True ->
      mcp_json.Object([
        #("content", mcp_json.Array([])),
        #(
          "structuredContent",
          mcp_json.Object([
            #(
              "applications",
              mcp_json.Array([
                mcp_json.Object([
                  #("id", mcp_json.String("application-1")),
                  #("score", mcp_json.Float(0.75)),
                  #(
                    "stage",
                    mcp_json.Object([
                      #("id", mcp_json.String("stage-1")),
                      #("name", mcp_json.String("Screen")),
                    ]),
                  ),
                ]),
              ]),
            ),
            #("has_more", mcp_json.Bool(False)),
          ]),
        ),
      ])
  }
}

fn typed_mcp_result(arguments: mcp_json.JsonValue) -> mcp_json.JsonValue {
  let id = case arguments {
    mcp_json.Object(fields) -> {
      case list.key_find(fields, "job_id") {
        Ok(mcp_json.String("malformed")) -> mcp_json.Int(12)
        _ -> mcp_json.String("application-1")
      }
    }
    _ -> mcp_json.String("application-1")
  }
  mcp_json.Object([
    #(
      "content",
      mcp_json.Array([
        mcp_json.Object([
          #("type", mcp_json.String("text")),
          #("text", mcp_json.String("Readable fixture result.")),
        ]),
      ]),
    ),
    #(
      "structuredContent",
      mcp_json.Object([
        #(
          "results",
          mcp_json.Array([
            mcp_json.Object([
              #("id", id),
              #("status", mcp_json.String("active")),
              #("active", mcp_json.Bool(True)),
            ]),
          ]),
        ),
        #("next_cursor", mcp_json.Null),
      ]),
    ),
  ])
}

fn typed_mcp_config(rig: Rig, layer: mcp_wiring.Layer) -> codemode.Config {
  codemode.default_config(
    broker: rig.broker,
    clock: wall_clock(),
    workspace: rig.workspace,
    toolchain: rig.toolchain,
  )
  |> codemode.over_mcp(layer)
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
  <> "    options: fixture.EchoArgsOptions(tag: option.Some(\""
  <> wire_tag
  <> "\")),\n"
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
  <> "(title: \"anything\", options: fixture."
  <> digested("create_issue", "Create-Issue!")
  <> "_defaults) {\n"
  <> "    Ok(_result) -> \""
  <> no_failure
  <> "\"\n"
  // The live program deliberately uses house-style label shorthand so the
  // end-to-end gate catches parser drift before stored programs encounter it.
  <> "    Error(mcp.ToolFailed(message:, content: _content)) -> \""
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
      io.println_error(
        "SKIP a_program_reaches_a_real_mcp_server_process: " <> reason,
      )
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
  let rig = rig(fixture.ready, under: fixture.ready.root)
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
  // Nested fields now become a record; the hostile outer wire name remains
  // a literal and the generated field names describe the admitted value.
  let label = digested("target_repo", "Target-Repo")
  assert string.contains(
    source,
    "  " <> label <> " " <> label <> ": TargetRepo",
  )
  assert string.contains(source, "\"Target-Repo\"")
  assert string.contains(source, "owner: String")
  assert string.contains(source, "repo: String")
  Nil
}

// A renamed identifier as `mcp/name` builds it: the mangled base, then
// eight characters of the digest of the *original*.
fn digested(base: String, original: String) -> String {
  base <> "_" <> string.slice(mcp_wiring.sha256_hex(original), 0, 8)
}

// --- locating the fixture and its interpreter -------------------------------

fn mcp_process_rig() -> Result(Fixture, String) {
  // The declared platform skip wins before fixture-specific observations.
  // Everything after it is non-owning until the final root reservation.
  use Nil <- result.try(platform_prerequisite())
  use Nil <- result.try(observable_processes())
  use escript <- result.try(escript_path())
  use script <- result.try(fixture_script())
  use prepared <- result.try(prepare_live_run())
  use ready <- result.try(reserve_live_run(prepared))
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

// Two seconds of polling. `gleam_mcp/transport` requests native termination
// while retaining the port. Neither exit nor reap is synchronous with
// the call that requested it.
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
      io.println_error(
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
  let rig = rig(ready, under: ready.root)
  let assert Ok(Nil) =
    simplifile.create_directory_all(rig.workspace <> "/notes")
    as "the fixture directory must be creatable"
  let assert Ok(Nil) =
    simplifile.write(rig.workspace <> "/" <> bridged_file, bridged_contents)
    as "the fixture file must be writable"
  let store = addresses.new()
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
  let path = blob.ref_path(codemode.default_blob_root(rig.workspace), id)
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
      io.println_error(
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
  let root = ready.root
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
      io.println_error(
        "SKIP an_orchestration_program_emits_an_artifact: " <> reason,
      )
    Ok(ready) -> run_orchestration_emit(ready)
  }
}

// The orchestration seam, over an Agency that can do nothing at all. That
// is the point: the program touches no strand, so what is being proved is
// that `report.emit` is serviced *on this seam* rather than that the
// messaging plane works — which `orchestration_sample_test` proves
// elsewhere, against a real one.
fn run_orchestration_emit(ready: Ready) -> Nil {
  let rig = rig(ready, under: ready.root)
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
  let path = blob.ref_path(codemode.default_blob_root(rig.workspace), id)
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
    send: fn(_caller, _to, _text, _within_ms) { Error(agent.AgencyUnavailable) },
    note: fn(_caller, _key, _value) { Error(agent.AgencyUnavailable) },
    notes: fn(_caller, _prefix) { Error(agent.AgencyUnavailable) },
    todos: fn(_caller, _step) { Error(agent.AgencyUnavailable) },
    roster: fn(_caller) { Error(agent.AgencyUnavailable) },
    max_wait_ms: 30_000,
    model_names: [],
    holds: fn(_caller, _tool) { Ok(Nil) },
  )
}

// --- the rig ---------------------------------------------------------------

fn prerequisites() -> Result(Ready, String) {
  use Nil <- result.try(platform_prerequisite())
  use prepared <- result.try(prepare_live_run())
  reserve_live_run(prepared)
}

fn platform_prerequisite() -> Result(Nil, String) {
  // Match every other real-helper suite: a current binary on a platform with
  // no jail is not a runnable prerequisite, and the shared reason is what the
  // declared-skip census audits.
  case exec.unjailed_skip_reason(exec.host_platform()) {
    option.Some(reason) -> Error(reason)
    option.None -> Ok(Nil)
  }
}

fn prepare_live_run() -> Result(Prepared, String) {
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
    Ok(_toolchain) -> Ok(Prepared(helper_path:, seed_root:))
  }
}

fn reserve_live_run(prepared: Prepared) -> Result(Ready, String) {
  use root <- result.try(live_root())
  Ok(Ready(
    helper_path: prepared.helper_path,
    seed_root: prepared.seed_root,
    root:,
  ))
}

// A shallow base keeps every fixture's AF_UNIX socket below the portable byte
// budget. Each run atomically reserves a production-random directory of its
// own, so concurrent worktrees cannot share server.pid, sockets or cleanup.
fn live_root() -> Result(String, String) {
  let discriminator =
    token.production_entropy()(8)
    |> bit_array.base16_encode
    |> string.lowercase
  let scratch = case secret.lookup(secret.env(), "LOOM_TEST_SCRATCH") {
    Ok(path) -> [path]
    Error(Nil) -> []
  }
  select_live_root(
    list.append(scratch, ["/var/tmp"]),
    discriminator,
    reserve_root,
  )
  |> result.replace_error(
    "no safe code-mode live root: LOOM_TEST_SCRATCH and /var/tmp were "
    <> "relative, private /tmp, over the socket-path budget, or unwritable",
  )
}

fn select_live_root(
  bases: List(String),
  discriminator: String,
  reserve: fn(String, String) -> Result(Nil, Nil),
) -> Result(String, Nil) {
  case bases {
    [] -> Error(Nil)
    [base, ..rest] ->
      case candidate_root(base, discriminator) {
        Error(Nil) -> select_live_root(rest, discriminator, reserve)
        Ok(#(normalized, candidate)) ->
          case reserve(normalized, candidate) {
            Ok(Nil) -> Ok(candidate)
            Error(Nil) -> select_live_root(rest, discriminator, reserve)
          }
      }
  }
}

fn candidate_root(
  base: String,
  discriminator: String,
) -> Result(#(String, String), Nil) {
  case string.starts_with(base, "/"), simplifile.resolve(base) {
    True, Ok(normalized) -> {
      let candidate = normalized <> "/.loom-client-live-" <> discriminator
      let socket =
        candidate
        <> "/work/"
        <> codemode.work_directory
        <> "/0000000000000000/s"
      case
        normalized != "/tmp"
        && !string.starts_with(normalized, "/tmp/")
        && bit_array.byte_size(<<socket:utf8>>)
        <= codemode.max_socket_path_bytes
      {
        True -> Ok(#(normalized, candidate))
        False -> Error(Nil)
      }
    }
    _, _ -> Error(Nil)
  }
}

fn reserve_root(base: String, root: String) -> Result(Nil, Nil) {
  use Nil <- result.try(
    simplifile.create_directory_all(base) |> result.replace_error(Nil),
  )
  use Nil <- result.try(
    simplifile.create_directory(root) |> result.replace_error(Nil),
  )
  case simplifile.write(root <> "/.write-probe", "writable") {
    Ok(Nil) -> Ok(Nil)
    Error(_) -> {
      let _cleaned = simplifile.delete_all([root])
      Error(Nil)
    }
  }
}

pub fn live_root_rejects_bad_candidates_and_falls_through_test() {
  let too_deep = "/" <> string.repeat("d", 96)
  let selected =
    select_live_root(
      [
        "relative",
        "/var/tmp/../../tmp",
        too_deep,
        "/unwritable",
        "/safe",
      ],
      "0000000000000000",
      fn(_base, root) {
        case string.starts_with(root, "/unwritable/") {
          True -> Error(Nil)
          False -> Ok(Nil)
        }
      },
    )
  assert selected == Ok("/safe/.loom-client-live-0000000000000000")
}

pub fn live_root_discriminators_make_reserved_roots_unique_test() {
  let reserve = fn(_base, _root) { Ok(Nil) }
  assert select_live_root(["/safe"], "0000000000000000", reserve)
    != select_live_root(["/safe"], "1111111111111111", reserve)
}

// --- helper staleness (issues #61, #64) -------------------------------------
//
// `bin/loom-exec` is the one helper path in this tree that is not rebuilt
// by the suite that uses it: `make binaries` refreshes it and nothing
// else does. Every other live-helper suite builds its own from source
// into its own build directory on every run and so can never go stale
// (`broker/integration_test`, `codemode/support/rig`,
// `conformance/support/jail`, `tools/integration_test` — grepped for
// `loom-exec` across `packages/*/test` to confirm this is the one site
// with the trap). So the check here establishes *currency*, not merely
// presence.
//
// This is no longer the mechanism that catches a wire mismatch. Issue #64
// gave the helper a protocol version in its `hello`, so a binary
// predating a required-key change now dies at the handshake with
// `exec.ProtocolVersionMismatch` naming both numbers and the remedy —
// wherever it happens, in production as much as here, and including the
// case an mtime cannot see at all: a helper copied in from another
// checkout with a plausible timestamp.
//
// What is left for the mtime comparison is the question the version check
// deliberately does not answer: **was this binary built from the sources
// beside it**, when the protocol did not move. A jail fix, an enforcement
// change, a cancel-ladder repair — none of those bump a version, and all
// of them are things these four live runs exist to exercise. Running them
// against last week's binary would give a confident wrong answer with
// nothing to explain it, which is the shape of #61 with the wire part
// removed. The two checks are therefore not the same question, and the
// mtime one is kept for the narrower half.
//
// It is kept honest about its limits, too: mtimes are not preserved
// across checkouts, so this comparison is only meaningful in the tree that
// built the binary. That is exactly the tree a developer runs `make check`
// in, and outside it the binary is absent rather than misleading.
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
  rig_sized(ready, under: root, protected:, helpers: 3)
}

// The rig with a helper pool of a stated size. Two executions running at
// once each hold a build helper, then a node helper and a `proc.run`
// helper, so the concurrent run below needs more than the default three
// to avoid measuring pool congestion instead of socket placement.
fn rig_sized(
  ready: Ready,
  under root: String,
  protected protected: List(String),
  helpers helpers: Int,
) -> Rig {
  let workspace = workspace_in(root)
  let assert Ok(Nil) = simplifile.create_directory_all(workspace <> "/tmp")
    as "the live rig must have a workspace"
  let assert Ok(toolchain) = codemode.discover(ready.seed_root)
    as "the toolchain must be located"

  // The base is assembled the way a real session's is, and for the same
  // reasons. It carries the toolchain's mounts because the satellite
  // launch requires them and composition takes the meet by path
  // (`client/serve.admitting_codemode`); it carries the per-user set
  // because that is what a host with a toolchain under `$HOME` needs; and
  // it merges by path last, because two steps naming one region produce a
  // policy `broker/policy.validate` refuses.
  let base =
    policy.SandboxPolicy(
      ..base_policy(root),
      protected:,
      mounts: codemode.toolchain_mounts(toolchain),
    )
    |> serve.merging_mounts
  let assert Ok(pool) =
    exec.start_pool(size: helpers, spawn: fn() {
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
  // The outcome follows host teardown; its janitor can only repeat idempotent
  // unlinks, so the settled per-run root is safe to remove here.
  let assert Ok(Nil) = simplifile.delete_all([rig.root])
    as "the live rig must remove its per-run roots"
  Nil
}

// The session base a live code-mode execution runs under: its own root
// writable and readable, network off, and every region outside it stated
// as a mount by the caller. It used to grant `readable_roots: ["/"]`,
// under which a missing or duplicated mount changed nothing about what
// the jail could reach, so this suite could not have caught either.
//
// Deliberately *without* the two cap-channel env names:
// `client/codemode.execution_policy` is what adds them, and a base that
// already carried them would hide whether it does.
fn base_policy(root: String) -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    ..policy.workspace_default(root),
    writable_roots: [root],
    readable_roots: [root],
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
    directory_access: directory_access.none(),
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
    observe_output: tool.ignore_output(),
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
    rename: fn(from, _to) { Error(tool.FsNotFound(path: from)) },
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

// --- the search bridge, end to end (#365) -----------------------------------

// The fixture tree the search program walks. Four facts are being set up
// at once, and each one is a claim the program's outcome has to carry:
// an ordinary source file to find and read, a file that is not source so
// the glob has something to *not* match, a hidden directory whose
// contents must stay invisible to a default walk, and a symlink out of
// the workspace whose target must stay unreachable while the link itself
// stays visible.
const searched_dir = "sfind"

const searched_file = "sfind/a.gleam"

const searched_line = "pub fn needle() -> Nil"

const searched_other = "sfind/b.txt"

const searched_hidden = "sfind/.hidden/c.gleam"

const searched_link = "sfind/away"

// The two labels the refusal legs report. Written as labels rather than
// asserted on the harness's sentence because the claim is that the
// *program* observed `outside_readable_roots` and `InvalidArgument` — a
// substring of a message would pass on any refusal at all.
const escape_denied = "escape-denied"

const bad_regex_refused = "bad-regex-refused"

const wrong_refusal_label = "wrong-refusal"

/// A program of the kind a model would submit against `cap/search`: one
/// glob, one grep, one stat of a symlink, one read, one read through an
/// escaping link, and one regex that does not compile.
///
/// One program for all six legs, for the reason `bridge_program_source`
/// gives: they are one seam record and one router, and a suite reaching
/// them one at a time would not notice an arm wired to its neighbour's
/// closure.
pub fn search_program_source() -> String {
  "import cap/report\n"
  <> "import cap/search\n"
  <> "\n"
  <> "pub fn main() -> report.Outcome {\n"
  <> "  case search.glob(search.glob_query(under: \""
  <> searched_dir
  <> "\", matching: \"*.gleam\")) {\n"
  <> "    Error(_error) -> report.failure(\"search.glob did not settle\")\n"
  <> "    Ok(listing) -> after_glob(listing)\n"
  <> "  }\n"
  <> "}\n"
  <> "\n"
  <> "fn after_glob(listing: search.Listing) -> report.Outcome {\n"
  <> "  case search.grep(search.grep_query(under: \""
  <> searched_dir
  <> "\", matching: \"needle\")) {\n"
  <> "    Error(_error) -> report.failure(\"search.grep did not settle\")\n"
  <> "    Ok(found) -> after_grep(listing, found)\n"
  <> "  }\n"
  <> "}\n"
  <> "\n"
  <> "fn after_grep(listing: search.Listing, found: search.Found)"
  <> " -> report.Outcome {\n"
  <> "  case search.stat(\""
  <> searched_link
  <> "\") {\n"
  <> "    Error(_error) -> report.failure(\"search.stat did not settle\")\n"
  <> "    Ok(entry) -> after_stat(listing, found, entry)\n"
  <> "  }\n"
  <> "}\n"
  <> "\n"
  <> "fn after_stat(listing: search.Listing, found: search.Found,"
  <> " entry: search.Entry) -> report.Outcome {\n"
  <> "  case search.read_lines(\""
  <> searched_file
  <> "\", from: 1, to: 1) {\n"
  <> "    Error(_error) -> report.failure(\"search.read_lines did not settle\")\n"
  <> "    Ok(lines) -> after_read(listing, found, entry, lines)\n"
  <> "  }\n"
  <> "}\n"
  <> "\n"
  <> "fn after_read(listing: search.Listing, found: search.Found,"
  <> " entry: search.Entry, lines: search.Lines) -> report.Outcome {\n"
  <> "  let escaped = case search.read_lines(\""
  <> searched_link
  <> "/secret.gleam\", from: 1, to: 1) {\n"
  <> "    Error(search.SearchFailed(code: \"outside_readable_roots\", message: _message)) -> \""
  <> escape_denied
  <> "\"\n"
  <> "    Error(_other) -> \""
  <> wrong_refusal_label
  <> "\"\n"
  <> "    Ok(_read) -> \"not-refused\"\n"
  <> "  }\n"
  <> "  let refused = case search.grep(search.grep_query(under: \""
  <> searched_dir
  <> "\", matching: \"[\")) {\n"
  <> "    Error(search.InvalidArgument(_message)) -> \""
  <> bad_regex_refused
  <> "\"\n"
  <> "    Error(_other) -> \""
  <> wrong_refusal_label
  <> "\"\n"
  <> "    Ok(_found) -> \"not-refused\"\n"
  <> "  }\n"
  <> "  report.value(\n"
  <> "    report.object([\n"
  <> "      #(\"globbed\", report.int(count(listing.entries, 0))),\n"
  <> "      #(\"first\", report.string(first_path(listing.entries))),\n"
  <> "      #(\"matched\", report.int(count(found.matches, 0))),\n"
  <> "      #(\"scanned\", report.int(found.files_scanned)),\n"
  <> "      #(\"link\", report.string(kind_label(entry.kind))),\n"
  <> "      #(\"line\", report.string(lines.text)),\n"
  <> "      #(\"escaped\", report.string(escaped)),\n"
  <> "      #(\"refused\", report.string(refused)),\n"
  <> "    ]),\n"
  <> "  )\n"
  <> "}\n"
  <> "\n"
  // `gleam/list` is on the seam's stdlib allowlist, but counting by hand
  // keeps the program's imports to the two modules the claim is about.
  <> "fn count(items: List(a), so_far: Int) -> Int {\n"
  <> "  case items {\n"
  <> "    [] -> so_far\n"
  <> "    [_one, ..rest] -> count(rest, so_far + 1)\n"
  <> "  }\n"
  <> "}\n"
  <> "\n"
  <> "fn first_path(entries: List(search.Entry)) -> String {\n"
  <> "  case entries {\n"
  <> "    [] -> \"none\"\n"
  <> "    [entry, ..] -> entry.path\n"
  <> "  }\n"
  <> "}\n"
  <> "\n"
  <> "fn kind_label(kind: search.Kind) -> String {\n"
  <> "  case kind {\n"
  <> "    search.Symlink(target: _target) -> \"symlink\"\n"
  <> "    search.File -> \"file\"\n"
  <> "    search.Directory -> \"directory\"\n"
  <> "    search.Other -> \"other\"\n"
  <> "  }\n"
  <> "}\n"
}

pub fn a_program_navigates_and_searches_through_the_bridge_test() {
  case prerequisites() {
    Error(reason) ->
      io.println_error(
        "SKIP a_program_navigates_and_searches_through_the_bridge: " <> reason,
      )
    Ok(ready) -> run_search(ready)
  }
}

// The whole of #365's wiring against the real pipeline: a real vet
// against the workspace allowlist (which now carries `cap/search`), a
// real hermetic build, a real jailed satellite, and four capabilities
// answered by the harness through `tools/fs.resolve_real` and
// `tools/search`.
//
// The two decisive assertions are the negative ones. Nothing under the
// hidden directory and nothing behind the escaping symlink may appear in
// any answer, and the read through that symlink must be refused rather
// than served — those are the properties the walk's never-follow rule and
// the single resolution boundary exist for, and a walk that quietly
// widened itself would still produce a green count.
fn run_search(ready: Ready) -> Nil {
  let rig = rig(ready, under: ready.root)

  // The escape target is a sibling of the rig root rather than a child of
  // it: the rig's base reads `[root]`, and native reads follow the base
  // policy, so a target under the root would be readable and the escape
  // leg would prove nothing. A sibling sharing the root as a string prefix
  // also holds the containment check to whole path components.
  let outside = ready.root <> "-outside"
  let assert Ok(Nil) = simplifile.create_directory_all(outside)
    as "the escape target must be creatable"
  let assert Ok(Nil) =
    simplifile.write(outside <> "/secret.gleam", "pub const secret = 1\n")
    as "the escape target's file must be writable"
  let assert Ok(Nil) =
    simplifile.create_directory_all(rig.workspace <> "/" <> searched_dir)
    as "the fixture directory must be creatable"
  let assert Ok(Nil) =
    simplifile.create_directory_all(
      rig.workspace <> "/" <> searched_dir <> "/.hidden",
    )
    as "the hidden fixture directory must be creatable"
  let assert Ok(Nil) =
    simplifile.write(
      rig.workspace <> "/" <> searched_file,
      searched_line <> "\n",
    )
    as "the fixture source file must be writable"
  let assert Ok(Nil) =
    simplifile.write(rig.workspace <> "/" <> searched_other, "needle\n")
    as "the fixture text file must be writable"
  let assert Ok(Nil) =
    simplifile.write(rig.workspace <> "/" <> searched_hidden, "needle\n")
    as "the hidden fixture file must be writable"
  let assert Ok(Nil) =
    simplifile.create_symlink(outside, rig.workspace <> "/" <> searched_link)
    as "the escaping symlink must be creatable"

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
        #("program", json.String(search_program_source())),
        #("within_ms", json.Int(600_000)),
      ]),
    )
  let text = rendered_text(outcome)
  assert !outcome.is_error
  // One `*.gleam` under the root: the hidden directory's is not visited
  // and the symlink is not descended, so neither can inflate the count.
  assert string.contains(text, "\"globbed\":1,")
  assert string.contains(text, "\"first\":\"" <> searched_file <> "\"")
  assert !string.contains(text, ".hidden")
  assert !string.contains(text, "secret.gleam")
  // The grep read the two ordinary files and found `needle` in both; the
  // hidden one and everything behind the link were never opened.
  assert string.contains(text, "\"matched\":2")
  assert string.contains(text, "\"scanned\":2")
  // The link is reported as a link rather than followed, and the one-line
  // read came back through `resolve_real`.
  assert string.contains(text, "\"link\":\"symlink\"")
  assert string.contains(text, "\"line\":\"" <> searched_line <> "\"")
  // And the two refusals the program pattern-matched on the variant.
  assert string.contains(text, "\"escaped\":\"" <> escape_denied <> "\"")
  assert string.contains(text, "\"refused\":\"" <> bad_regex_refused <> "\"")
  io.println(
    "code-mode search e2e: search.glob + grep + stat + read_lines through "
    <> "the real pipeline; the hidden tree and the escaping link stayed out",
  )
  stop_rig(rig)
  let assert Ok(Nil) = simplifile.delete_all([outside])
    as "the escape target sits outside the rig root, so it is removed here"
  Nil
}

// Two real jailed programs, separated by SQLite close/reopen, prove that
// default workspace code mode owns a usable persistent data path.
pub fn workspace_notes_survive_sqlite_reopen_and_feed_a_fresh_program_test() {
  case prerequisites() {
    Error(reason) ->
      io.println_error("SKIP workspace_notes_round_trip: " <> reason)
    Ok(ready) -> run_notes_round_trip(ready)
  }
}

fn run_notes_round_trip(ready: Ready) -> Nil {
  let rig = rig(ready, under: ready.root)
  let path = rig.root <> "/notes.db"
  let first = notes_session.open(path, wall_clock())
  let base =
    codemode.default_config(
      broker: rig.broker,
      clock: wall_clock(),
      workspace: rig.workspace,
      toolchain: rig.toolchain,
    )
  let writer =
    codemode.serving(base, codemode.WorkspaceOnly, over: first.agency)
  let assert Ok(Nil) =
    simplifile.write(rig.workspace <> "/input.json", "[3,5,8]")
    as "analysis input must exist"
  let assert Ok(source) =
    simplifile.read("../../docs/examples/notes_analysis.gleam")
    as "the documented writer must exist"
  let outcome = run_notes_program(writer, rig, source, "notes-write")
  assert !outcome.is_error as rendered_text(outcome)
  assert string.contains(rendered_text(outcome), "Saved analysis")
  let assert Ok(Nil) = api.close(first.runtime)
    as "the first runtime must close its SQLite writer"

  let second = notes_session.open(path, wall_clock())
  let reader =
    codemode.serving(base, codemode.WorkspaceOnly, over: second.agency)
  let assert Ok(source) =
    simplifile.read("../../docs/examples/notes_reuse.gleam")
    as "the documented reader must exist"
  let outcome = run_notes_program(reader, rig, source, "notes-read")
  case outcome.is_error {
    True -> io.println_error(rendered_text(outcome))
    False -> Nil
  }
  assert !outcome.is_error as rendered_text(outcome)
  assert notes_program_value(outcome)
    == json.Object([
      #("saved_sum", json.Int(16)),
      #("next_sum", json.Int(17)),
    ])
  let quota =
    run_notes_program(reader, rig, notes_quota_source(), "notes-quota")
  assert !quota.is_error as rendered_text(quota)
  assert notes_program_value(quota) == json.String("admission_ceiling")
  let assert Ok(Nil) = api.close(second.runtime)
    as "the reopened runtime must close"
  stop_rig(rig)
}

fn run_notes_program(
  config: codemode.Config,
  rig: Rig,
  source: String,
  step: String,
) -> tool.ToolOutcome {
  let ctx =
    tool.Ctx(
      ..live_ctx(rig.workspace, rig.base_policy, wall_clock()),
      strand: "main",
      step_id: step,
    )
  codemode_tool.tool_for(codemode.seam(config)).run(
    ctx,
    json.Object([
      #("program", json.String(source)),
      #("within_ms", json.Int(600_000)),
    ]),
  )
}

fn notes_quota_source() -> String {
  "import cap/fs\nimport cap/report\nimport gleam/list\n"
  <> "pub fn main() -> report.Outcome {\n"
  <> "  let results = list.map(list.repeat(Nil, 65), fn(_) { fs.read(\"note://main/analysis\") })\n"
  <> "  case list.last(results) {\n"
  <> "    Ok(Error(fs.FsFailed(code: \"admission_ceiling\", message: _))) -> report.text(\"admission_ceiling\")\n"
  <> "    _ -> report.failure(\"virtual read quota was not enforced\")\n"
  <> "  }\n}\n"
}

// Compare structured results directly so unrelated diagnostic numbers cannot
// make a wrong computed value look like a successful persistence round trip.
fn notes_program_value(outcome: tool.ToolOutcome) -> json.JsonValue {
  let assert option.Some(json.Object(fields)) = outcome.details
    as "a completed program must retain structured details"
  let assert Ok(value) = list.key_find(fields, "value")
    as "a completed program must retain its returned value"
  value
}

pub fn advertised_recipes_execute_verbatim_on_both_default_seams_test() {
  case prerequisites() {
    Error(reason) -> io.println_error("SKIP advertised_recipes: " <> reason)
    Ok(ready) -> run_advertised_recipes(ready)
  }
}

// Children are scripted at the Agency boundary; notes use the real SQLite
// writer. Vetting, compilation, jail execution, and both routers are real.
fn run_advertised_recipes(ready: Ready) -> Nil {
  let rig = rig(ready, under: ready.root)
  let session = notes_session.open(rig.root <> "/recipe-notes.db", wall_clock())
  let seen = process.new_subject()
  let agency = recipe_agency(session.agency, seen)
  let assert Ok(seams) = serve.parse_codemode_seams(option.None)
    as "default server exposes both seams"
  let config =
    codemode.default_config(
      broker: rig.broker,
      clock: wall_clock(),
      workspace: rig.workspace,
      toolchain: rig.toolchain,
    )
    |> codemode.serving(seams, over: agency)
  let description = codemode_tool.description(codemode.seam(config))
  assert string.contains(description, codemode_recipes.workspace())
  assert string.contains(description, codemode_recipes.orchestration())
  assert simplifile.read("../../docs/examples/workspace_analysis.gleam")
    == Ok(codemode_recipes.workspace())
  assert simplifile.read("../../docs/examples/strand_map.gleam")
    == Ok(codemode_recipes.orchestration())
  let assert Ok(Nil) =
    simplifile.write(rig.workspace <> "/input-a.json", "{\"count\":3}")
    as "first input exists"
  let assert Ok(Nil) =
    simplifile.write(rig.workspace <> "/input-b.json", "{\"count\":5}")
    as "second input exists"
  let outcome =
    run_notes_program(
      config,
      rig,
      codemode_recipes.workspace(),
      "recipe-workspace",
    )
  assert !outcome.is_error as rendered_text(outcome)
  assert notes_program_value(outcome) == json.Object([#("count", json.Int(8))])
  assert simplifile.read(rig.workspace <> "/analysis.json")
    == Ok("{\"count\":8}")

  // The shell-probe recipe must vet, compile without warnings and run. Whether
  // `git` and `gh` exist or are permitted here is not the claim: a probe that
  // fails must come back as text in its own section, not as a failed run.
  assert string.contains(description, codemode_recipes.shell_probes())
  assert simplifile.read("../../docs/examples/shell_probes.gleam")
    == Ok(codemode_recipes.shell_probes())
  let probes =
    run_notes_program(
      config,
      rig,
      codemode_recipes.shell_probes(),
      "recipe-shell-probes",
    )
  assert !probes.is_error as rendered_text(probes)
  assert string.contains(rendered_text(probes), "log:")
  assert string.contains(rendered_text(probes), "fix PRs:")
  assert !string.contains(rendered_text(probes), "removed unused")

  let ctx =
    tool.Ctx(
      ..live_ctx(rig.workspace, rig.base_policy, wall_clock()),
      strand: "main",
      step_id: "recipe-orchestration",
    )
  let outcome =
    codemode_tool.tool_for(codemode.seam(config)).run(
      ctx,
      json.Object([
        #("program", json.String(codemode_recipes.orchestration())),
        #("seam", json.String("orchestration")),
        #("within_ms", json.Int(600_000)),
      ]),
    )
  assert !outcome.is_error as rendered_text(outcome)
  let assert json.Array(rows) = notes_program_value(outcome)
    as "reviews return structured rows"
  assert list.length(rows) == 2
  list.each(rows, fn(row) {
    let assert json.Object(fields) = row as "each review is an object"
    assert list.key_find(fields, "status") == Ok(json.String("completed"))
    assert list.key_find(fields, "value")
      == Ok(json.Object([#("count", json.Int(2))]))
  })
  assert process.receive(seen, 100) == Ok("spawn:review core")
  assert process.receive(seen, 100) == Ok("spawn:review client")
  assert process.receive(seen, 100) == Ok("wait:2")

  // Read the orchestration's saved output in a fresh workspace execution.
  let saved =
    run_notes_program(
      config,
      rig,
      "import cap/notes\nimport cap/report\nimport gleam/option.{Some}\npub fn main() -> report.Outcome { case notes.get(\"main/reviews\") { Ok(Some(value)) -> report.value(value) _ -> report.failure(\"missing reviews\") } }",
      "recipe-reuse",
    )
  assert !saved.is_error as rendered_text(saved)
  assert notes_program_value(saved) == notes_program_value(outcome)
  let assert Ok(Nil) = api.close(session.runtime) as "recipe database closes"
  stop_rig(rig)
}

fn recipe_agency(
  base: agent.Agency,
  seen: process.Subject(String),
) -> agent.Agency {
  agent.Agency(
    ..base,
    spawn: fn(caller: agent.Caller, request: agent.SpawnRequest) {
      process.send(seen, "spawn:" <> request.purpose)
      assert request.result_schema != option.None
      let name = "sub:main/" <> string.replace(request.purpose, " ", "-")
      Ok(agent.Spawned(
        handle: agent.Handle(name, caller.operation),
        strand: name,
        tools: [],
        model: "fixture",
        model_id: "fixture",
        deadline_ms: option.None,
      ))
    },
    wait: fn(_, handles, within_ms) {
      assert within_ms == 20_000
      process.send(seen, "wait:" <> int.to_string(list.length(handles)))
      Ok(
        list.map(handles, fn(handle) {
          agent.Ready(
            handle:,
            outcome: agent.Completed,
            report: "done",
            result: agent.ResultGiven(json.Object([#("count", json.Int(2))])),
            notes: [],
          )
        }),
      )
    },
  )
}

// --- the cap socket outside the workspace (#611) ------------------------------

// The workspace length the deep-workspace runs pad to. Under the old
// placement the socket path would have been this plus thirty bytes, well
// past the 100-byte budget.
const deep_workspace_bytes = 150

// A directory name placed in the socket root by the masking run, so that
// a listing which could see the root would print it.
const socket_marker = "611marker"

pub fn a_deep_workspace_binds_its_socket_under_the_runtime_root_test() {
  case prerequisites() {
    Error(reason) ->
      io.println_error(
        "SKIP a_deep_workspace_binds_its_socket_under_the_runtime_root: "
        <> reason,
      )
    Ok(ready) -> run_deep_workspace(ready)
  }
}

pub fn two_concurrent_executions_bind_separate_sockets_test() {
  case prerequisites() {
    Error(reason) ->
      io.println_error(
        "SKIP two_concurrent_executions_bind_separate_sockets: " <> reason,
      )
    Ok(ready) -> run_concurrent_sockets(ready)
  }
}

pub fn an_unrelated_jail_cannot_see_the_socket_root_test() {
  case prerequisites() {
    Error(reason) ->
      io.println_error(
        "SKIP an_unrelated_jail_cannot_see_the_socket_root: " <> reason,
      )
    Ok(ready) -> run_socket_mask(ready)
  }
}

// The socket root inside a rig, standing in for `<state root>/run`. It is
// created before the rig for the reason the daemon creates the real one
// at startup: the base masks it, and a mask over a missing path is one
// the jail may refuse to build.
fn socket_root_in(root: String) -> String {
  let sockets = root <> "/" <> codemode.runtime_directory
  let assert Ok(Nil) = simplifile.create_directory_all(sockets)
    as "the socket root must be creatable"
  sockets
}

// A workspace padded to exactly `deep_workspace_bytes`, inside the rig's
// root so the rig's base covers it.
fn deep_workspace(root: String) -> String {
  let prefix = workspace_in(root) <> "/"
  let padding = deep_workspace_bytes - string.byte_size(prefix)
  let workspace = prefix <> string.repeat("d", padding)
  let assert Ok(Nil) = simplifile.create_directory_all(workspace)
    as "the deep workspace must be creatable"
  workspace
}

// The shipped wiring, with the daemon's socket placement.
fn socket_rooted_config(
  rig: Rig,
  workspace: String,
  sockets: String,
) -> codemode.Config {
  codemode.default_config(
    broker: rig.broker,
    clock: wall_clock(),
    workspace:,
    toolchain: rig.toolchain,
  )
  |> codemode.sockets_under(option.Some(sockets))
}

fn program_arguments() -> json.JsonValue {
  json.Object([
    #("program", json.String(program_source())),
    #("within_ms", json.Int(600_000)),
  ])
}

// Issue #611's acceptance: a workspace of 150 bytes runs a real program
// through the real pipeline, jailed, with the session base masking the
// socket root exactly as a daemon session's does. The echo proves the cap
// channel carried a capability call both ways, so the satellite reached
// its socket through the mask.
fn run_deep_workspace(ready: Ready) -> Nil {
  let root = ready.root
  let sockets = socket_root_in(root)
  let workspace = deep_workspace(root)
  assert string.byte_size(workspace) == deep_workspace_bytes
  let rig = rig_protecting(ready, under: root, protected: [sockets])

  // The old placement is refused for this workspace, and the refusal
  // names the root that is too deep rather than failing at `listen`.
  let assert Error(old) =
    codemode.check_socket_path(
      workspace <> "/" <> codemode.work_directory <> "/0000000000000000",
    )
    as "a socket inside a 150-byte workspace must be over the budget"
  assert string.contains(old, workspace <> "/" <> codemode.work_directory)

  let outcome =
    codemode_tool.tool_for(
      codemode.seam(socket_rooted_config(rig, workspace, sockets)),
    ).run(
      live_ctx(workspace, rig.base_policy, wall_clock()),
      program_arguments(),
    )
  let text = rendered_text(outcome)
  assert !outcome.is_error as text
  assert string.contains(text, echoed <> " exit=0")

  // The execution settled and took its socket directory with it.
  assert simplifile.read_directory(sockets) == Ok([])
  io.println(
    "code-mode deep workspace: a "
    <> int.to_string(deep_workspace_bytes)
    <> "-byte workspace ran with its socket under "
    <> sockets,
  )
  stop_rig(rig)
}

// Issue #87 with the new placement: two executions run at the same time
// against one socket root. Each must bind its own directory; a shared one
// would let the first execution's cleanup remove the second's live socket.
//
// The two executions belong to different steps of one operation, not to
// one step. `code_mode` is `tool.Exclusive`, so a real batch never runs
// two of its calls at once, and an execution's teardown sweeps its whole
// step (`broker.abort_step`): two concurrent executions under one
// `{op_id, step_id}` let whichever finishes first cancel the other's
// `/bin/echo`, which then exits 143 and fails the assertion below. That
// was this test's flake, and it depended on one teardown landing while
// the other's command was in flight. Separate steps are the shape that
// can occur, and the sweep leaves a sibling step alone. The
// source-index-only difference is a property of pure paths, so it is
// asserted before anything runs.
fn run_concurrent_sockets(ready: Ready) -> Nil {
  let root = ready.root
  let sockets = socket_root_in(root)
  let rig = rig_sized(ready, under: root, protected: [sockets], helpers: 6)
  let config = socket_rooted_config(rig, rig.workspace, sockets)
  let code_mode = codemode_tool.tool_for(codemode.seam(config))
  let ctx = live_ctx(rig.workspace, rig.base_policy, wall_clock())

  // The two directories differ before anything runs, which is the
  // property the race depends on.
  assert codemode.socket_directory(
      config,
      op_id: ctx.op_id,
      step_id: ctx.step_id,
      source_index: 0,
    )
    != codemode.socket_directory(
      config,
      op_id: ctx.op_id,
      step_id: ctx.step_id,
      source_index: 1,
    )

  // The directories the two runs actually bind differ as well.
  assert codemode.socket_directory(
      config,
      op_id: ctx.op_id,
      step_id: ctx.step_id <> "-0",
      source_index: 0,
    )
    != codemode.socket_directory(
      config,
      op_id: ctx.op_id,
      step_id: ctx.step_id <> "-1",
      source_index: 1,
    )

  let settled = process.new_subject()
  list.each([0, 1], fn(index) {
    let step = ctx.step_id <> "-" <> int.to_string(index)
    process.spawn(fn() {
      let outcome =
        code_mode.run(
          tool.Ctx(..ctx, step_id: step, source_index: index),
          program_arguments(),
        )
      process.send(settled, #(index, outcome))
    })
  })
  let assert Ok(#(_, first)) = process.receive(settled, 900_000)
    as "the first concurrent execution must settle"
  let assert Ok(#(_, second)) = process.receive(settled, 900_000)
    as "the second concurrent execution must settle"
  assert !first.is_error as rendered_text(first)
  assert !second.is_error as rendered_text(second)
  assert string.contains(rendered_text(first), echoed <> " exit=0")
  assert string.contains(rendered_text(second), echoed <> " exit=0")
  assert simplifile.read_directory(sockets) == Ok([])
  stop_rig(rig)
}

// The mask, from outside a satellite. A jailed command under the session
// base, which is what `bash` runs under, lists the socket root and must
// not see the directory in it. The same command under the satellite's
// derivation for that one directory (`codemode.reaching_socket`) must see
// the socket file inside it, so the test cannot pass because the listing
// failed for some other reason.
fn run_socket_mask(ready: Ready) -> Nil {
  let root = ready.root
  let sockets = socket_root_in(root)
  let directory = sockets <> "/" <> socket_marker
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
    as "the marker directory must be creatable"
  let assert Ok(Nil) = simplifile.write(directory <> "/s", "")
    as "the marker socket stand-in must be writable"
  let rig = rig_protecting(ready, under: root, protected: [sockets])

  let masked = jailed_stdout(rig, rig.base_policy, ["/bin/ls", "-a", sockets])
  assert !string.contains(masked, socket_marker) as masked

  let granted =
    codemode.reaching_socket(rig.base_policy, under: sockets, directory:)
  assert granted.protected == []
  let reached = jailed_stdout(rig, granted, ["/bin/ls", directory])
  assert string.contains(reached, "s") as reached

  let assert Ok(Nil) = simplifile.delete(directory)
    as "the marker directory must be removable"
  stop_rig(rig)
}

// One jailed command through the rig's broker, as a built-in tool clears
// one, returning what it printed. A command the jail kept from reading
// its target still exits; only a refused clearance is a failure here.
fn jailed_stdout(
  rig: Rig,
  base: policy.SandboxPolicy,
  argv: List(String),
) -> String {
  let wall = wall_clock()
  let #(now, _) = clock.read(wall)
  let #(operation, _) = ids.mint_op(ids.generator(wall, seed: 611))
  let events = process.new_subject()
  let assert Ok(call) =
    broker.clear_call(
      rig.broker,
      broker.CallSpec(
        op_id: operation,
        step_id: "socket-mask",
        base_policy: base,
        requirements: base,
        grants: [],
        response: broker.RefuseNarrowed,
        demand: exec.BestEffort,
        argv:,
        env: [#("PATH", "/usr/bin:/bin")],
        cwd: rig.workspace,
        budget: budget.Budget(1, now + 30_000),
      ),
      events:,
      waiting: 20_000,
    )
    as "the listing must be admitted"
  broker.stdin(rig.broker, call, data: <<>>, eof: True)
  let assert Ok(collected) = tool.collect_events(events, waiting: 30_000)
    as "the listing must settle"
  let assert Ok(text) = bit_array.to_string(collected.stdout)
    as "a listing is UTF-8"
  text
}

pub fn caller_owned_messages_cross_the_real_cap_channel_test() {
  case prerequisites() {
    Error(reason) -> io.println_error("SKIP own_message_channel: " <> reason)
    Ok(ready) -> run_message_inspection(ready)
  }
}

fn run_message_inspection(ready: Ready) -> Nil {
  let rig = rig(ready, under: ready.root)
  let owner = notes_session.open(rig.root <> "/messages.db", wall_clock())
  let assert Ok(op) =
    api.prompt(owner.runtime, [
      message.UserMessage(
        [message.UserText("own transcript proof", option.None)],
        1,
        option.None,
      ),
    ])
    as "the recipient has a real active transcript"

  // Admission follows the initial checkpoint so both messages remain pending.
  let assert poll.Answered(Nil) =
    poll.until(within: 5000, every: 5, attempt: fn() {
      case session.op_state(owner.runtime.session, op) {
        Ok(option.Some(session.Cell(
          value: operation.RunState(phase: operation.Assistant(_), ..),
          ..,
        ))) -> poll.Done(Nil)
        Ok(_) -> poll.Retry
        Error(error) -> poll.Fail(error)
      }
    })
    as "the provider is parked after draining the initial prompt"
  let endpoint =
    peer_mail.Endpoint("00000000-0000-7000-8000-000000000002", fn(command) {
      peer_mail.handle(owner.runtime, wall_clock(), command)
    })
  let assert Ok(_) =
    endpoint.call(
      peer_mail.Allow(peer_mail.Grant(
        "00000000-0000-7000-8000-000000000001",
        "reviewer",
        "main",
        peer_mail.BusyOnly,
      )),
    )
    as "the existing transport admits an authorized sender"
  let assert Ok(_) =
    endpoint.call(peer_mail.Deliver(
      peer_mail.Source(
        "00000000-0000-7000-8000-000000000001",
        "reviewer",
        json.Null,
      ),
      "main",
      "proof",
      "remote receipt proof",
    ))
    as "the remote body has a durable admission receipt"
  let assert Ok(id) =
    api.steer(
      owner.runtime,
      message.UserMessage(
        [message.UserText("local pending proof", option.None)],
        1,
        option.None,
      ),
    )
    as "the caller has an inspectable queued input"
  let id = ids.entry_id_to_string(id)
  let wiring = peers.Wiring(endpoint, json.Null, option.None)
  let base =
    codemode.serving(
      codemode.default_config(
        broker: rig.broker,
        clock: wall_clock(),
        workspace: rig.workspace,
        toolchain: rig.toolchain,
      ),
      codemode.BothSeams,
      over: owner.agency,
    )
  let config =
    codemode.Config(
      ..base,
      wrap_router: fn(request: codemode_tool.Request, router) {
        peers.router(wiring, request.strand, router)
      },
    )
  let mode = codemode.seam(config)
  let offer = fn(offered: codemode_tool.SeamOffer) {
    codemode_tool.SeamOffer(
      ..offered,
      serviced_caps: list.append(offered.serviced_caps, peers.serviced_caps),
    )
  }
  let mode =
    codemode_tool.CodeMode(
      ..mode,
      seams: codemode_tool.Seams(
        default: offer(mode.seams.default),
        alternates: list.map(mode.seams.alternates, offer),
      ),
    )
  let source =
    "import cap/peer\nimport cap/report\nimport gleam/list\npub fn main() -> report.Outcome {\n"
    <> "  case peer.parse_entry_id(\""
    <> id
    <> "\"), peer.parse_session_id(\"00000000-0000-7000-8000-000000000001\"), peer.parse_session_id(\"00000000-0000-7000-8000-000000000003\") {\n"
    <> "    Ok(id), Ok(source), Ok(unlinked) -> inspect(id, source, unlinked)\n    _, _, _ -> report.failure(\"bad persisted identity\")\n  }\n}\n"
    <> "fn inspect(id: peer.EntryId, source: peer.SessionId, unlinked: peer.SessionId) -> report.Outcome {\n"
    <> "  case peer.inbox(after: peer.first_pending(), limit: 12), peer.inbox_get(id: id), peer.history(before: peer.first_history(), limit: 64), peer.received(after: peer.first_receipt(), limit: 64), peer.received_get(source_session: source, source_strand: \"reviewer\", message_id: \"proof\"), peer.roster(), peer.sent_receipt(session: unlinked, message_id: \"proof\") {\n"
    <> "    Ok(pending), Ok(Some(peer.Pending(id: exact, queue: peer.Steer, payload: local_payload))), Ok(history), Ok(received), Ok(Some(peer.Admitted(request:, ..))), Ok([]), Error(peer.PeerDenied(..)) -> {\n"
    <> "      case exact == id && list.length(pending.items) == 2 && list.length(history.items) == 1 && list.length(received.items) == 1 && pending_text(local_payload) == Ok(\"local pending proof\") && list.any(pending.items, fn(input) { case input { peer.Pending(payload:, ..) -> pending_text(payload) == Ok(\"remote receipt proof\") peer.Materialized(..) -> False } }) && list.any(history.items, fn(input) { case input { peer.Materialized(entry:, ..) -> materialized_text(entry) == Ok(\"own transcript proof\") peer.Pending(..) -> False } }) && list.any(received.items, fn(item) { let peer.Admitted(page_request, _) = item.receipt page_request.body == \"remote receipt proof\" }) && request.body == \"remote receipt proof\" && peer.entry_id_to_string(exact) == \""
    <> id
    <> "\" { True -> report.text(\"inspection channel proved\") False -> report.failure(\"missing owned body\") }\n"
    <> "    }\n    _, _, _, _, _, _, _ -> report.failure(\"inspection capability refused\")\n  }\n}\n"
  let source =
    source
    <> "fn pending_text(payload: report.Value) -> Result(String, Nil) { use message <- result.try(report.field(payload, \"payload\")) message_text(message) }\n"
    <> "fn materialized_text(entry: report.Value) -> Result(String, Nil) { use message <- result.try(report.field(entry, \"message\")) message_text(message) }\n"
    <> "fn message_text(message: report.Value) -> Result(String, Nil) { use content <- result.try(report.field(message, \"content\")) use blocks <- result.try(report.as_list(content)) case blocks { [block] -> { use text <- result.try(report.field(block, \"text\")) report.as_string(text) } _ -> Error(Nil) } }\n"
  let source = "import gleam/option.{Some}\nimport gleam/result\n" <> source
  list.each(["workspace", "orchestration"], fn(selection) {
    let outcome =
      codemode_tool.tool_for(mode).run(
        live_ctx(rig.workspace, rig.base_policy, wall_clock()),
        json.Object([
          #("program", json.String(source)),
          #("seam", json.String(selection)),
          #("within_ms", json.Int(600_000)),
        ]),
      )
    assert notes_program_value(outcome)
      == json.String("inspection channel proved")
  })
  api.abort(owner.runtime)
}

pub fn structured_cadence_crosses_the_real_default_host_test() {
  case prerequisites() {
    Error(reason) -> io.println_error("SKIP typed_schedule_channel: " <> reason)
    Ok(ready) -> run_schedule_cadence(ready)
  }
}

fn run_schedule_cadence(ready: Ready) -> Nil {
  let rig = rig(ready, under: ready.root)
  let owner = notes_session.open(rig.root <> "/cadence.db", wall_clock())
  let runtime = owner.runtime
  let schedules =
    scheduleseam.door(scheduleseam.Wiring(
      runtime: fn() { Ok(runtime) },
      policy: schedule.ModelSchedulesSteer,
      operator_schedules: [],
      scanner: addresses.new(),
    ))
  let config =
    codemode.default_config(
      broker: rig.broker,
      clock: wall_clock(),
      workspace: rig.workspace,
      toolchain: rig.toolchain,
    )
    |> codemode.serving(codemode.BothSeams, over: owner.agency)
    |> codemode.over_schedules(option.Some(schedules))
  let source =
    "import cap/schedule\nimport cap/report\npub fn main() -> report.Outcome {\n"
    <> "  case schedule.every_within(\"typed-cadence\", 300, schedule.Bounds(max_fires: 4, expires_after_s: 3600), schedule.SteersOnly, \"Check.\") {\n"
    <> "    Ok(created) -> verify(created.cadence)\n    Error(_) -> report.failure(\"create refused\")\n  }\n}\n"
    <> "fn verify(cadence: schedule.Cadence) -> report.Outcome {\n"
    <> "  case schedule.list() {\n    Ok([row]) -> {\n"
    <> "      case cadence == schedule.Interval(seconds: 300, expiry: schedule.Expiry(max_fires: 4, expires_after_s: 3600)) && row.cadence == cadence {\n"
    <> "        True -> case schedule.cancel(\"typed-cadence\") { Ok(_) -> report.text(\"cadence channel proved\") Error(_) -> report.failure(\"cancel refused\") }\n"
    <> "        False -> report.failure(\"wrong granted cadence\")\n      }\n    }\n    _ -> report.failure(\"list refused\")\n  }\n}\n"
  let outcome = run_notes_program(config, rig, source, "typed-cadence")
  assert notes_program_value(outcome) == json.String("cadence channel proved")
}

fn directory_case(rig: Rig) -> Nil {
  let selected = rig.workspace <> "/review"
  let assert Ok(Nil) = simplifile.create_directory_all(selected)
    as "create review directory"
  let id = ids.mint_session(ids.generator(clock.fixed(1000), 641)).0
  let harness = gateway_test.reserved_fixture(id)
  let facts = api.fact_handle(harness.runtime)
  let supplier = fn() { Ok(facts) }
  let ctx =
    tool.Ctx(
      ..live_ctx(rig.workspace, rig.base_policy, wall_clock()),
      filesystem: fs.real_filesystem(),
    )
  let remembered =
    directory.tool(working_directory.door(supplier)).run(
      ctx,
      json.Object([#("path", json.String(selected))]),
    )
  assert !remembered.is_error
  let assert Ok(canonical_selected) = working_directory.door(supplier).read(ctx)
    as "remembered directory is canonical"
  let assert Ok(canonical_workspace) =
    directory.select(
      directory.workspace_only(),
      ctx,
      option.Some(rig.workspace),
    )
    as "workspace is canonical"
  let config =
    codemode.default_config(
      rig.broker,
      wall_clock(),
      rig.workspace,
      rig.toolchain,
    )
  let seam = codemode.seam(working_directory.over_code_mode(config, supplier))
  let source =
    "import cap/proc\nimport cap/report\nimport gleam/result\nimport gleam/string\n\npub fn main() -> report.Outcome {\n  case paths() {\n    Ok(text) -> report.text(text)\n    Error(error) -> report.failure(string.inspect(error))\n  }\n}\n\nfn paths() {\n  use inherited <- result.try(proc.run(proc.command([\"/bin/pwd\"])))\n  use override <- result.try(proc.run(proc.command([\"/bin/pwd\"]) |> proc.in_dir(\"..\")))\n  Ok(string.trim(inherited.stdout) <> \"|\" <> string.trim(override.stdout))\n}\n"
  let outcome =
    codemode_tool.tool_for(seam).run(
      ctx,
      json.Object([
        #("program", json.String(source)),
        #("within_ms", json.Int(600_000)),
      ]),
    )
  let assert False = outcome.is_error as rendered_text(outcome)
  assert string.contains(
    rendered_text(outcome),
    canonical_selected <> "|" <> canonical_workspace,
  )
  assert working_directory.door(supplier).read(ctx) == Ok(canonical_selected)
  let assert Ok(Nil) = simplifile.delete_all([canonical_selected])
    as "replace saved directory"
  let assert Ok(Nil) =
    simplifile.create_symlink(canonical_workspace, canonical_selected)
    as "redirect saved directory within workspace"
  let redirected_source =
    "import cap/proc\nimport cap/report\nimport gleam/string\npub fn main() -> report.Outcome {\n  case proc.run(proc.command([\"/bin/pwd\"]) |> proc.in_dir(\".\")) {\n    Ok(_) -> report.text(\"unexpected execution\")\n    Error(error) -> report.failure(string.inspect(error))\n  }\n}\n"
  let refused =
    codemode_tool.tool_for(seam).run(
      ctx,
      json.Object([
        #("program", json.String(redirected_source)),
        #("within_ms", json.Int(600_000)),
      ]),
    )
  assert refused.is_error
  assert string.contains(
    rendered_text(refused),
    "remembered cwd changed its canonical target",
  )
  assert api.close(harness.runtime) == Ok(Nil)
}
