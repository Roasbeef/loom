//// The `code_mode` tool shell: what it decodes, what it clamps, what it
//// hands the seam, and — the load-bearing part — what a refusal looks
//// like by the time the model reads it.
////
//// The seam here is a fake built out of closures. Two shapes are used: a
//// *scripted* one that answers with a fixed `Execution`, for pinning how
//// each stage's failure renders, and an *echoing* one that renders the
//// `Request` it was handed into the program's outcome, so an assertion on
//// the result is an assertion on what the tool passed. The thing worth
//// pinning is not that a program runs but that the identity reaching the
//// pipeline is the driver's `Ctx` — `{op_id, step_id}` above all, because
//// that pair is the execution the broker pools budget under.

import broker/broker.{type CallEvent, type CallSpec, type Refusal}
import broker/exec
import broker/policy
import core/clock
import core/ids.{type OpId}
import core/json
import core/message
import core/msgpack
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{Some}
import gleam/string
import tools/codemode
import tools/tool.{type Ctx}

// --- fixtures --------------------------------------------------------------

fn an_op(seed: Int) -> OpId {
  let #(op, _generator) = ids.mint_op(ids.generator(clock.fixed(at: 0), seed:))
  op
}

fn ctx_for(step: String) -> Ctx {
  let workspace = "/nonexistent/loom-codemode-test"
  tool.Ctx(
    workspace:,
    strand: "main",
    op_id: an_op(7),
    step_id: step,
    source_index: 0,
    base_policy: policy.workspace_default(workspace),
    grants: [],
    demand: exec.FullEnforcement,
    env: [#("PATH", "/usr/bin")],
    clock: clock.fixed(at: 1000),
    filesystem: dead_filesystem(),
    blob_root: workspace <> "/.blobs",
    clear_call: dead_broker,
  )
}

fn dead_broker(
  _spec: CallSpec,
  _events: Subject(CallEvent),
) -> Result(tool.RunningCall, Refusal) {
  Error(broker.BrokerUnavailable)
}

fn dead_filesystem() -> tool.FileSystem {
  tool.FileSystem(
    read: fn(path) { Error(tool.FsNotFound(path:)) },
    write: fn(path, _bytes) { Error(tool.FsNotFound(path:)) },
    create_directory_all: fn(path) { Error(tool.FsNotFound(path:)) },
    is_file: fn(_path) { Ok(False) },
    read_link: fn(_path) { Ok(tool.LinkMissing) },
  )
}

const allowlist = ["cap/proc", "cap/report", "gleam/int"]

// A seam that always answers with the same execution.
fn scripted(execution: codemode.Execution) -> codemode.CodeMode {
  codemode.CodeMode(
    execute: fn(_request) { execution },
    allowed_imports: allowlist,
    serviced_caps: ["proc.run"],
    default_within_ms: 300_000,
    max_within_ms: 900_000,
  )
}

// A seam whose "program" reports the request it was given, so the result
// is a transcript of what crossed the seam.
fn echoing() -> codemode.CodeMode {
  codemode.CodeMode(
    execute: fn(request: codemode.Request) {
      codemode.Execution(
        result: codemode.Ran(
          outcome: codemode.Completed(
            value: msgpack.MapValue([
              #(
                msgpack.StringValue("op"),
                msgpack.StringValue(ids.op_id_to_string(request.op_id)),
              ),
              #(
                msgpack.StringValue("step"),
                msgpack.StringValue(request.step_id),
              ),
              #(
                msgpack.StringValue("strand"),
                msgpack.StringValue(request.strand),
              ),
              #(
                msgpack.StringValue("workspace"),
                msgpack.StringValue(request.workspace),
              ),
              #(
                msgpack.StringValue("within_ms"),
                msgpack.IntValue(request.within_ms),
              ),
              #(
                msgpack.StringValue("source"),
                msgpack.StringValue(request.source),
              ),
            ]),
          ),
          manifest_hash: "sha256-echo",
        ),
        enforcement: jailed(),
      )
    },
    allowed_imports: allowlist,
    serviced_caps: ["proc.run"],
    default_within_ms: 300_000,
    max_within_ms: 900_000,
  )
}

fn ran(outcome: codemode.Outcome) -> codemode.Execution {
  codemode.Execution(
    result: codemode.Ran(outcome:, manifest_hash: "sha256-abc"),
    enforcement: jailed(),
  )
}

// Both stages confined, as a healthy run on a capable kernel reports.
fn jailed() -> codemode.Enforcement {
  codemode.Enforcement(build: enforced(), node: enforced())
}

fn enforced() -> codemode.Report {
  codemode.Enforced(
    applied: ["bwrap", "seccomp-net"],
    skipped: [],
    degraded: False,
  )
}

// Neither stage ran, so neither reports — the shape vetting's refusal and
// a build that never started both produce.
fn nothing_ran() -> codemode.Enforcement {
  codemode.Enforcement(
    build: codemode.Unreported("nothing was dispatched"),
    node: codemode.Unreported("nothing was dispatched"),
  )
}

fn call(seam: codemode.CodeMode, args: List(#(String, json.JsonValue))) {
  codemode.tool_for(seam).run(ctx_for("turn-1:tools"), json.Object(args))
}

fn text_of(outcome: tool.ToolOutcome) -> String {
  outcome.content
  |> list.map(fn(block) {
    case block {
      message.ToolResultText(text:, ..) -> text
      _other -> ""
    }
  })
  |> string.join("\n")
}

// --- a program that ran ----------------------------------------------------

pub fn a_completed_program_reaches_the_caller_test() {
  let outcome =
    call(scripted(ran(codemode.Completed(msgpack.StringValue("counted 3")))), [
      #("program", json.String("pub fn main() { report.text(\"counted 3\") }")),
    ])
  assert !outcome.is_error
  // A `report.text` value is handed over verbatim: quoting it as JSON
  // would only make the common case harder to read.
  assert string.contains(text_of(outcome), "counted 3")
  let assert Some(json.Object(fields)) = outcome.details
    as "a run must carry structured details"
  assert list.contains(fields, #("status", json.String("completed")))
  assert list.contains(fields, #("value", json.String("counted 3")))
  assert list.contains(fields, #("manifest_hash", json.String("sha256-abc")))
}

pub fn a_structured_value_reaches_the_caller_as_json_test() {
  let value =
    msgpack.MapValue([
      #(msgpack.StringValue("stale"), msgpack.IntValue(4)),
      #(
        msgpack.StringValue("packages"),
        msgpack.ArrayValue([
          msgpack.StringValue("core"),
        ]),
      ),
    ])
  let outcome =
    call(scripted(ran(codemode.Completed(value))), [
      #("program", json.String("...")),
    ])
  assert !outcome.is_error
  assert string.contains(text_of(outcome), "\"stale\":4")
  let assert Some(json.Object(fields)) = outcome.details
    as "a run must carry structured details"
  assert list.contains(fields, #(
    "value",
    json.Object([
      #("stale", json.Int(4)),
      #("packages", json.Array([json.String("core")])),
    ]),
  ))
}

pub fn a_program_that_reported_a_failure_is_an_error_result_test() {
  // `report.failure` is the program's own controlled failure: something
  // for the model to react to, so `is_error`, but not a harness fault.
  let outcome =
    call(
      scripted(
        ran(codemode.Errored(
          message: "the sweep did not settle",
          details: msgpack.StringValue("proc.run refused"),
        )),
      ),
      [#("program", json.String("..."))],
    )
  assert outcome.is_error
  assert string.contains(text_of(outcome), "the sweep did not settle")
  assert string.contains(text_of(outcome), "proc.run refused")
  let assert Some(json.Object(fields)) = outcome.details
    as "a failed program must carry structured details"
  assert list.contains(fields, #("status", json.String("program_failed")))
}

// --- a program that was refused before it ran ------------------------------

pub fn a_vetting_rejection_names_the_rule_and_the_import_test() {
  let outcome =
    call(
      scripted(codemode.Execution(
        result: codemode.VetRejected([
          codemode.Rejection(
            rule: codemode.ImportNotAllowed,
            detail: "`gleam/io` is not an allowed import",
            location: codemode.SourceSpan(start: 0, end: 14),
          ),
        ]),
        enforcement: nothing_ran(),
      )),
      [#("program", json.String("import gleam/io"))],
    )
  assert outcome.is_error
  let text = text_of(outcome)
  // Everything a repair needs: the rule, the offending import, where it
  // sits, and the allowlist it was judged against.
  assert string.contains(text, "import not allowed")
  assert string.contains(text, "gleam/io")
  assert string.contains(text, "[bytes 0-14]")
  assert string.contains(text, "cap/report")
  assert string.contains(text, "submit it again")
  let assert Some(json.Object(fields)) = outcome.details
    as "a rejection must carry structured details"
  assert list.contains(fields, #("status", json.String("vetting_rejected")))
  assert list.contains(fields, #(
    "rejections",
    json.Array([
      json.Object([
        #("rule", json.String("import_not_allowed")),
        #("detail", json.String("`gleam/io` is not an allowed import")),
        #("start", json.Int(0)),
        #("end", json.Int(14)),
      ]),
    ]),
  ))
  assert list.contains(fields, #(
    "allowed_imports",
    json.Array(list.map(list.sort(allowlist, string.compare), json.String)),
  ))
}

pub fn every_violation_is_listed_in_one_pass_test() {
  // Vetting collects every violation rather than stopping at the first,
  // and the tool must not throw the rest away: one round trip per rule is
  // exactly what in-band repair exists to avoid.
  let outcome =
    call(
      scripted(codemode.Execution(
        result: codemode.VetRejected([
          codemode.Rejection(
            rule: codemode.ImportNotAllowed,
            detail: "`gleam/io` is not an allowed import",
            location: codemode.Unlocated,
          ),
          codemode.Rejection(
            rule: codemode.NoForeignInterface,
            detail: "an attribute on the function `escape`",
            location: codemode.SourceSpan(start: 40, end: 61),
          ),
        ]),
        enforcement: nothing_ran(),
      )),
      [#("program", json.String("..."))],
    )
  let text = text_of(outcome)
  assert string.contains(text, "2 rules were broken")
  assert string.contains(text, "gleam/io")
  assert string.contains(text, "foreign interface")
  assert string.contains(text, "escape")
  // An unlocated rejection names no offsets rather than inventing them.
  assert !string.contains(text, "[bytes ]")
}

pub fn a_parse_error_points_at_a_byte_test() {
  let outcome =
    call(
      scripted(codemode.Execution(
        result: codemode.VetRejected([
          codemode.Rejection(
            rule: codemode.Unparseable,
            detail: "unexpected token",
            location: codemode.SourcePoint(byte_offset: 12),
          ),
        ]),
        enforcement: nothing_ran(),
      )),
      [#("program", json.String("pub fn main( {"))],
    )
  assert string.contains(text_of(outcome), "does not parse")
  assert string.contains(text_of(outcome), "[byte 12]")
  // Nothing about a malformed program is an allowlist problem, so the
  // allowlist is not pasted into the answer.
  assert !string.contains(text_of(outcome), "the imports a program may use")
}

// --- a program that did not compile ----------------------------------------

pub fn a_compile_error_comes_back_as_readable_text_test() {
  let diagnostics =
    "error: Type mismatch\n  ┌─ src/loom_program.gleam:5:20\n  │\n"
    <> "5 │   proc.run(proc.command(\"not-an-argv\"))\n"
    <> "Expected type:\n    List(String)\nFound type:\n    String\n"
  let outcome =
    call(
      scripted(codemode.Execution(
        result: codemode.CompileFailed(codemode.BuildRejected(diagnostics:)),
        enforcement: codemode.Enforcement(
          build: codemode.Enforced(
            applied: ["bwrap"],
            skipped: [],
            degraded: False,
          ),
          node: codemode.Unreported("the program did not compile"),
        ),
      )),
      [#("program", json.String("..."))],
    )
  assert outcome.is_error
  // The compiler's own words, verbatim: the cheapest precise signal in
  // the pipeline, and the model can act on it directly.
  assert string.contains(text_of(outcome), "Type mismatch")
  assert string.contains(text_of(outcome), "List(String)")
  let assert Some(json.Object(fields)) = outcome.details
    as "a compile failure must carry structured details"
  assert list.contains(fields, #("status", json.String("compile_failed")))
  assert list.contains(fields, #("kind", json.String("build_rejected")))
  assert list.contains(fields, #("detail", json.String(diagnostics)))
}

pub fn a_build_that_could_not_run_is_not_blamed_on_the_program_test() {
  let outcome =
    call(
      scripted(codemode.Execution(
        result: codemode.CompileFailed(codemode.BuildUnavailable(
          reason: "the helper pool is empty",
        )),
        enforcement: nothing_ran(),
      )),
      [#("program", json.String("..."))],
    )
  assert outcome.is_error
  assert string.contains(text_of(outcome), "could not run")
  assert string.contains(text_of(outcome), "the helper pool is empty")
  assert !string.contains(text_of(outcome), "did not compile")
}

// --- a program that ran out of road ----------------------------------------

pub fn a_deadline_says_what_died_and_how_to_fix_it_test() {
  let outcome =
    call(
      scripted(codemode.Execution(
        result: codemode.RunFailed(codemode.DeadlineExceeded),
        enforcement: codemode.Enforcement(
          build: enforced(),
          node: codemode.Enforced(
            applied: ["bwrap"],
            skipped: [],
            degraded: False,
          ),
        ),
      )),
      [#("program", json.String("..."))],
    )
  assert outcome.is_error
  assert string.contains(text_of(outcome), "wall budget")
  assert string.contains(text_of(outcome), "within_ms")
  let assert Some(json.Object(fields)) = outcome.details
    as "a run failure must carry structured details"
  assert list.contains(fields, #("status", json.String("run_failed")))
  assert list.contains(fields, #("kind", json.String("deadline_exceeded")))
}

// --- what actually ran -----------------------------------------------------

pub fn an_unreported_jail_is_never_implied_test() {
  // The result must not read as though the program was confined when no
  // helper said so.
  let outcome =
    call(
      scripted(codemode.Execution(
        result: codemode.Ran(
          outcome: codemode.Completed(msgpack.StringValue("done")),
          manifest_hash: "sha256-abc",
        ),
        enforcement: nothing_ran(),
      )),
      [#("program", json.String("..."))],
    )
  let text = text_of(outcome)
  // Neither stage is passed over in silence, and neither reads as
  // confined: each says it made no report, and why.
  assert string.contains(text, "the hermetic build made NO enforcement report")
  assert string.contains(text, "the satellite node made NO enforcement report")
  assert string.contains(text, "not a claim that it was confined")
  assert !string.contains(text, "enforced [")
  let assert Some(json.Object(fields)) = outcome.details
    as "a run must carry structured details"
  assert list.contains(fields, #(
    "sandbox",
    json.Object([
      #(
        "build",
        json.Object([
          #("reported", json.Bool(False)),
          #("reason", json.String("nothing was dispatched")),
        ]),
      ),
      #(
        "node",
        json.Object([
          #("reported", json.Bool(False)),
          #("reason", json.String("nothing was dispatched")),
        ]),
      ),
    ]),
  ))
}

pub fn a_healthy_run_names_both_jailed_stages_test() {
  // Issue #5's acceptance, at the seam the model reads: a run that went
  // all the way through says what confined the build *and* what confined
  // the node. Neither is inferred from the other's silence.
  let outcome =
    call(scripted(ran(codemode.Completed(msgpack.StringValue("done")))), [
      #("program", json.String("...")),
    ])
  let text = text_of(outcome)
  assert string.contains(
    text,
    "the hermetic build enforced [bwrap, seccomp-net]",
  )
  assert string.contains(
    text,
    "the satellite node enforced [bwrap, seccomp-net]",
  )
  assert !string.contains(text, "NO enforcement report")
}

pub fn a_degraded_stage_says_so_test() {
  let outcome =
    call(
      scripted(codemode.Execution(
        result: codemode.Ran(
          outcome: codemode.Completed(msgpack.StringValue("done")),
          manifest_hash: "sha256-abc",
        ),
        enforcement: codemode.Enforcement(
          build: enforced(),
          node: codemode.Enforced(
            applied: ["bwrap"],
            skipped: ["landlock: unavailable"],
            degraded: True,
          ),
        ),
      )),
      [#("program", json.String("..."))],
    )
  let text = text_of(outcome)
  assert string.contains(text, "the satellite node enforced [bwrap]")
  assert string.contains(text, "DEGRADED")
  // A layer the kernel skipped is named as skipped. It must never appear
  // inside the list of layers that were enforced — the reader would take
  // it for one.
  assert string.contains(text, "SKIPPED [landlock: unavailable]")
  assert !string.contains(text, "enforced [bwrap, landlock")
  let assert Some(json.Object(fields)) = outcome.details
    as "a run must carry structured details"
  assert list.contains(fields, #(
    "sandbox",
    json.Object([
      #(
        "build",
        json.Object([
          #("reported", json.Bool(True)),
          #(
            "enforced",
            json.Array([json.String("bwrap"), json.String("seccomp-net")]),
          ),
          #("skipped", json.Array([])),
          #("degraded", json.Bool(False)),
        ]),
      ),
      #(
        "node",
        json.Object([
          #("reported", json.Bool(True)),
          #("enforced", json.Array([json.String("bwrap")])),
          #("skipped", json.Array([json.String("landlock: unavailable")])),
          #("degraded", json.Bool(True)),
        ]),
      ),
    ]),
  ))
}

// --- identity and arguments ------------------------------------------------

pub fn the_execution_runs_under_the_callers_coordinates_test() {
  // The whole point: the pipeline is handed the driver's own `{op_id,
  // step_id}`, which is the identity the broker pools budget under. A
  // freshly minted one would mint a second budget and put the execution
  // beyond the reach of the operation's abort.
  let ctx = ctx_for("turn-9:tools")
  let outcome =
    codemode.tool_for(echoing()).run(
      ctx,
      json.Object([#("program", json.String("pub fn main() { todo }"))]),
    )
  let assert Some(json.Object(fields)) = outcome.details
    as "the echoing seam must answer with a value"
  let assert Ok(json.Object(echoed)) = list.key_find(fields, "value")
    as "the echo must be a map"
  assert list.contains(echoed, #(
    "op",
    json.String(ids.op_id_to_string(ctx.op_id)),
  ))
  assert list.contains(echoed, #("step", json.String("turn-9:tools")))
  assert list.contains(echoed, #("strand", json.String("main")))
  assert list.contains(echoed, #("workspace", json.String(ctx.workspace)))
  // And the program crossed unaltered.
  assert list.contains(echoed, #(
    "source",
    json.String("pub fn main() { todo }"),
  ))
}

pub fn the_budget_defaults_and_clamps_test() {
  let assert Ok(json.Object(defaulted)) =
    echoed_value([
      #("program", json.String("...")),
    ])
    as "the echo must be a map"
  assert list.contains(defaulted, #("within_ms", json.Int(300_000)))
  let assert Ok(json.Object(clamped)) =
    echoed_value([
      #("program", json.String("...")),
      #("within_ms", json.Int(99_000_000)),
    ])
    as "the echo must be a map"
  assert list.contains(clamped, #("within_ms", json.Int(900_000)))
  let assert Ok(json.Object(floored)) =
    echoed_value([
      #("program", json.String("...")),
      #("within_ms", json.Int(-1)),
    ])
    as "the echo must be a map"
  assert list.contains(floored, #("within_ms", json.Int(1)))
}

fn echoed_value(args: List(#(String, json.JsonValue))) {
  let outcome = call(echoing(), args)
  let assert Some(json.Object(fields)) = outcome.details
    as "the echoing seam must answer with a value"
  list.key_find(fields, "value")
}

pub fn an_empty_program_never_reaches_the_seam_test() {
  // A seam that would crash if called proves the refusal happens here.
  let exploding =
    codemode.CodeMode(
      ..scripted(ran(codemode.Completed(msgpack.NilValue))),
      execute: fn(_request) {
        panic as "an empty program must not reach the pipeline"
      },
    )
  let outcome = call(exploding, [#("program", json.String("   \n  "))])
  assert outcome.is_error
  assert string.contains(text_of(outcome), "must not be empty")
}

pub fn bad_arguments_are_an_in_band_refusal_test() {
  let outcome = call(echoing(), [#("within_ms", json.Int(5))])
  assert outcome.is_error
  assert string.contains(text_of(outcome), "`program` is required")
}

// --- the tool's own contract -----------------------------------------------

pub fn the_tool_is_replay_never_and_exclusive_test() {
  // Both are load-bearing. A program's capability calls are arbitrary
  // external effects with no minted identifier to reconcile onto, so a
  // crash must synthesize an interrupted result rather than run it twice;
  // and the broker pools budget per `{op_id, step_id}`, so a concurrent
  // call in the same step would open that ledger with its own budget —
  // and a satellite needs two outstanding effects to exist at all.
  let made = codemode.tool_for(echoing())
  assert made.name == codemode.tool_name
  assert made.replay == tool.Never
  assert made.execution_mode == tool.Exclusive
}

pub fn the_description_states_the_real_allowlist_test() {
  // Read off the seam rather than copied, so the sentence the model is
  // charged for on every request cannot drift from the policy the program
  // is judged against.
  let described = codemode.description(echoing())
  list.each(allowlist, fn(module) {
    assert string.contains(described, module)
  })
  assert string.contains(described, "proc.run")
  assert string.contains(described, "report.Outcome")
}

pub fn the_requirements_ask_for_the_workspace_and_the_toolchain_test() {
  let wanted = codemode.requirements("/work")
  assert wanted.writable_roots == ["/work"]
  // The Gleam and Erlang toolchains live outside the workspace.
  assert wanted.readable_roots == ["/"]
  assert wanted.network == policy.NetworkOff
}
