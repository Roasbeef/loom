//// The production report retainer and tool shell share the actual owner journal.
//// These controls inject only pipeline results; commit, final admission, bounded
//// readback and restart use the production custodian and SQLite implementation.

import broker/broker
import broker/exec
import broker/policy
import client/remote/code_reports
import client/remote/custodian
import client/remote/tool_custody
import core/clock
import core/ids
import core/json
import core/message
import core/msgpack as mp
import core/remote_tool
import core/report_value as rv
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import host/bootstrap
import machine/operation
import runtime/effects
import simplifile
import storage/owner_custody as custody
import tools/call_record
import tools/codemode as shell
import tools/directory_access
import tools/tool
import weft/registry

type Fixture {
  Fixture(
    path: String,
    owner: custodian.Handle,
    config: custodian.Config,
    pid: process.Pid,
  )
}

pub fn rendered_reference_recovers_original_bytes_after_owner_restart_test() {
  let executions = process.new_subject()
  let value =
    mp.MapValue([
      #(
        mp.IntValue(42),
        mp.BinaryValue(bit_array.from_string(string.repeat("z", 90_000))),
      ),
    ])
  let f =
    fixture("rendered", fn(owner, key, run) {
      process.send(executions, Nil)
      let assert Ok(tool) =
        shell.retained_tool(mode(value), code_reports.retainer(owner, key))
        as "Actual retained renderer assembles"
      let outcome = tool.run(context(run), run.arguments)
      effects.ToolCompleted(
        tool.to_result_message(outcome, run.call.id, run.call.name, 1000),
        False,
      )
    })
  let assert Ok(final) = invoke(f, 0)
    as "Report COMMIT and exact final reference precede reply"
  assert process.receive(executions, 1000) == Ok(Nil)
  let assert effects.ToolCompleted(
    message.ToolResultMessage(
      details: Some(json.Object([
        #("kind", json.String("code_mode_report_v1")),
        #("reference", json.String(uri)),
      ])),
      ..,
    ),
    False,
  ) = final
    as "Closed renderer reference admitted by real owner"
  let assert Ok(reference) = rv.parse_ref(uri) as "Canonical owner reference"
  let assert Ok(first) = custodian.read_report_chunk(f.owner, reference, 0)
    as "First bounded SQL slice"
  let assert Ok(last) = custodian.read_report_chunk(f.owner, reference, 65_536)
    as "Final bounded SQL slice"
  let bytes = bit_array.concat([first.bytes, last.bytes])
  let assert Ok(report) = rv.decode(bytes) as "Complete retained value decodes"
  assert rv.outcome(report) == rv.Completed(value)
  assert rv.ref_digest(reference)
    == bootstrap.sha256(bytes) |> bit_array.base16_encode |> string.lowercase
  stop(f)

  let assert Ok(started) = custodian.start(f.owner, f.config)
    as "Exact history reopens"
  let f = Fixture(..f, pid: started.pid)
  let input = invocation(0)
  let assert Ok(custody.FinalOutcome(payload)) =
    custodian.lookup(f.owner, input.key, input.arguments, input.request)
    as "Original final survives restart"
  assert effects.decode_tool_outcome(custody.bytes(payload)) == Ok(final)
  assert custodian.read_report_chunk(f.owner, reference, 0) == Ok(first)
  assert process.receive(executions, 0) |> result.is_error
  stop(f)
}

pub fn changed_context_cannot_commit_a_report_under_original_run_test() {
  let observed = process.new_subject()
  let f =
    fixture("wrong-context", fn(owner, key, run) {
      let assert Ok(tool) =
        shell.retained_tool(
          mode(mp.IntValue(1)),
          code_reports.retainer(owner, key),
        )
        as "Actual retained renderer assembles"
      let ctx = context(run)
      let outcome =
        tool.run(
          tool.Ctx(..ctx, source_index: ctx.source_index + 1),
          run.arguments,
        )
      process.send(observed, outcome)
      effects.ToolCompleted(
        tool.to_result_message(outcome, run.call.id, run.call.name, 1000),
        False,
      )
    })
  assert invoke(f, 0) |> result.is_error
  let assert Ok(observed_outcome) = process.receive(observed, 1000)
    as "The test observes the renderer result outside its managed worker."
  assert observed_outcome.is_error
  assert observed_outcome.details == None
  let input = invocation(0)
  let assert Ok(custody.AwaitingFinal(..)) =
    custodian.lookup(f.owner, input.key, input.arguments, input.request)
    as "A generic error cannot fabricate a no-terminal final"
  assert invoke(f, 1) == Error(custody.Capacity)
  stop(f)
}

fn mode(value: mp.MsgPackValue) -> shell.CodeMode {
  shell.CodeMode(
    execute: fn(_) {
      shell.Execution(
        shell.Ran(shell.Completed(value), string.repeat("a", 64)),
        shell.Enforcement(
          shell.Unreported("fixture build"),
          shell.Enforced([], [], True),
        ),
        shell.NothingRefused,
        call_record.empty(),
      )
    },
    background: None,
    seams: shell.one_seam(
      shell.SeamOffer(shell.WorkspaceSeam, ["cap/report"], [], []),
    ),
    default_within_ms: 1000,
    max_within_ms: 1000,
  )
}

fn context(run: effects.ToolRun) -> tool.Ctx {
  let filesystem =
    tool.FileSystem(
      read: fn(path) { Error(tool.FsNotFound(path)) },
      write: fn(path, _) { Error(tool.FsNotFound(path)) },
      create_directory_all: fn(path) { Error(tool.FsNotFound(path)) },
      is_file: fn(_) { Ok(False) },
      read_link: fn(_) { Ok(tool.LinkMissing) },
      rename: fn(path, _) { Error(tool.FsNotFound(path)) },
    )
  tool.Ctx(
    workspace: tool.LocalWorkspace("/nonexistent", filesystem),
    directory_access: directory_access.none(),
    owner_blobs: tool.OwnerBlobs("/nonexistent/blobs", filesystem),
    strand: run.strand,
    op_id: run.operation,
    step_id: run.step_id,
    source_index: run.source_index,
    base_policy: policy.workspace_default("/nonexistent"),
    grants: [],
    demand: exec.FullEnforcement,
    env: [],
    clock: clock.fixed(1000),
    clear_call: fn(_, _) { Error(broker.BrokerUnavailable) },
    raise_refusal: tool.no_raise(),
    observe_output: tool.ignore_output(),
  )
}

fn session() -> ids.SessionId {
  ids.mint_session(ids.generator(clock.fixed(1000), 77)).0
}

fn run(index: Int) -> effects.ToolRun {
  let original_operation = ids.mint_op(ids.generator(clock.fixed(1000), 77)).0
  let result_entry =
    ids.mint_entry(ids.generator(clock.fixed(1001), index + 10)).0
  let arguments = json.Object([#("program", json.String("source"))])
  effects.ToolRun(
    original_operation,
    "reports",
    index,
    result_entry,
    "main",
    message.ToolCall("call", "code_mode", arguments, None, None),
    arguments,
    operation.ReplayNever,
    [],
  )
}

fn limits() -> custody.Limits {
  let assert Ok(value) = custody.limits(8, 32, 32_000_000, 262_144)
    as "Final allowance is reserved under the original finite quota."
  value
}

fn fixture(
  name: String,
  runner: fn(custodian.Handle, remote_tool.ToolKey, effects.ToolRun) ->
    effects.ToolOutcome,
) -> Fixture {
  fixture_with_deadline(name, 5000, runner)
}

fn fixture_with_deadline(
  name: String,
  within: Int,
  runner: fn(custodian.Handle, remote_tool.ToolKey, effects.ToolRun) ->
    effects.ToolOutcome,
) -> Fixture {
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let root =
    "build/report-custody-"
    <> name
    <> "-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  assert simplifile.create_directory_all(root) == Ok(Nil)
  let path = root <> "/owner.db"

  let assert Ok(config) =
    custodian.config_with_reports(
      path,
      session(),
      limits(),
      1,
      within,
      runner,
      bootstrap.sha256,
    )
    as "Actual host SHA-256 is injected through trusted assembly."
  let assert Ok(names) = registry.start()
    as "One independently owned address registry."
  let owner = custodian.new(names, config)
  let assert Ok(started) = custodian.start(owner, config)
    as "Only validated owner history is published."
  Fixture(path, owner, config, started.pid)
}

fn invocation(index: Int) -> tool_custody.Invocation {
  let assert Ok(invocation) =
    tool_custody.invocation(session(), <<"scope":utf8>>, run(index))
    as "Exact original call and scope are retained by the production constructor."
  invocation
}

fn invoke(
  f: Fixture,
  index: Int,
) -> Result(effects.ToolOutcome, custody.Error) {
  let input = invocation(index)
  custodian.execute_with_profile(
    f.owner,
    input.key,
    input.arguments,
    input.request,
    run(index),
    custody.CodeModeReportV1,
  )
}

fn stop(f: Fixture) -> Nil {
  let monitor = process.monitor(f.pid)
  assert custodian.stop(f.owner) == Ok(Nil)
  let assert Ok(process.ProcessDown(_, _, process.Normal)) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(2000)
    as "Original owner closes SQLite before restart; this is no native proof."
  Nil
}
