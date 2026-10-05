//// Original owner report COMMIT, final reference and live drain stay independent.
////
//// These controls run the actual custodian and SQLite with host SHA-256.
//// Fixed trusted runners model receipt loss and retention refusal without any
//// production hook, renderer bypass or native-effect claim. `fixture` owns the
//// original actor; `stop` joins it before restart or deliberate disk corruption.
//// `invoke` uses the real immutable request constructor and explicit profile.

import client/remote/custodian
import client/remote/outcome
import client/remote/tool_custody
import core/clock
import core/ids
import core/json
import core/message
import core/msgpack as mp
import core/remote_tool
import core/report_value as rv
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/option.{None, Some}
import gleam/string
import gleam/time/timestamp
import host/bootstrap
import machine/operation
import runtime/effects
import simplifile
import sqlight
import storage/owner_custody as custody
import weft
import weft/poll
import weft/registry

type Fixture {
  Fixture(
    path: String,
    owner: custodian.Handle,
    config: custodian.Config,
    pid: process.Pid,
  )
}

pub fn actual_hash_final_reference_and_restart_never_rerun_body_test() {
  let receipt = process.new_subject()
  let original = report("alpha")
  let f =
    fixture("final", fn(owner, key, _) {
      let assert Ok(reference) = custodian.retain_report(owner, key, original)
        as "Original complete report COMMIT precedes final rendering."
      process.send(receipt, reference)
      final(reference)
    })
  let assert Ok(value) = invoke(f, 0)
    as "Exact final reference commits before reply."

  let assert Ok(reference) = process.receive(receipt, 1000)
    as "Original internal reference."
  assert value == final(reference)
  let digest =
    bootstrap.sha256(rv.bytes(original))
    |> bit_array.base16_encode
    |> string.lowercase
  assert rv.ref_digest(reference) == digest

  released(f)
  let assert Ok(chunk) = custodian.read_report_chunk(f.owner, reference, 0)
    as "Owner-local public chunk door returns the original complete bytes."
  assert chunk.bytes == rv.bytes(original)
  stop(f)

  // The same address reopens exact custody. Retained admission cannot invoke
  // the runner again, and retrieval remains bound to the original owner session.
  let assert Ok(started) = custodian.start(f.owner, f.config)
    as "Original final association validates before republishing."
  let f = Fixture(..f, pid: started.pid)
  let input = invocation(0)
  let assert Ok(custody.FinalOutcome(payload)) =
    custodian.lookup(f.owner, input.key, input.arguments, input.request)
    as "Recovery returns only exact committed final bytes."

  assert effects.decode_tool_outcome(custody.bytes(payload)) == Ok(value)
  let assert Error(_) = invoke(f, 0)
    as "Original effect cannot rerun on retained admission."
  let assert Error(_) = process.receive(receipt, 0)
    as "No second runner receipt exists."
  assert custodian.read_report_chunk(f.owner, reference, 0) == Ok(chunk)

  stop(f)
}

pub fn actual_sha_rejects_same_length_canonical_report_tampering_on_reopen_test() {
  let original = report("alpha")
  let changed = report("omega")
  assert bit_array.byte_size(rv.bytes(original))
    == bit_array.byte_size(rv.bytes(changed))
  let f =
    fixture("tamper", fn(owner, key, _) {
      let assert Ok(reference) = custodian.retain_report(owner, key, original)
        as "Actual original digest is retained."
      final(reference)
    })

  let assert Ok(_) = invoke(f, 0) as "Original final commits."
  released(f)
  stop(f)
  let hex = rv.bytes(changed) |> bit_array.base16_encode

  corrupt(f.path, "UPDATE owner_custody_tools SET report = X'" <> hex <> "'")
  let assert Error(_) = custodian.start(f.owner, f.config)
    as "Canonical same-length changed bytes fail actual SHA-256 before publication."
}

pub fn final_reference_original_call_and_error_polarity_revalidate_before_publication_test() {
  let original = report("alpha")
  let f =
    fixture("association", fn(owner, key, _) {
      let assert Ok(reference) = custodian.retain_report(owner, key, original)
        as "Original report COMMIT."
      final(reference)
    })
  let assert Ok(_) = invoke(f, 0) as "Original final commits."
  released(f)

  stop(f)
  corrupt(
    f.path,
    "UPDATE owner_custody_tools SET outcome = CAST(replace(CAST(outcome AS TEXT), 'result://', 'broken://') AS BLOB)",
  )
  let assert Error(_) = custodian.start(f.owner, f.config)
    as "A valid final codec with a changed reference cannot republish an owner."
}

pub fn failed_report_commit_fences_before_late_generic_failure_and_restart_test() {
  let observed = process.new_subject()
  let f =
    fixture("failed-retain", fn(owner, key, _) {
      let result = custodian.retain_report(owner, key, report("alpha"))
      process.send(observed, result)
      effects.ToolFailed("bounded late diagnostic")
    })
  corrupt(
    f.path,
    "CREATE TRIGGER refuse_report BEFORE UPDATE OF report ON owner_custody_tools BEGIN SELECT RAISE(ABORT, 'report custody unavailable'); END",
  )
  let assert Error(_) = invoke(f, 0)
    as "Retention failure fences the original ticket before generic completion."

  let assert Ok(Error(_)) = process.receive(observed, 1000)
    as "Actual SQLite refusal never issues a reference."
  let input = invocation(0)
  let assert poll.Answered(Nil) =
    poll.until(within: 2000, every: 5, attempt: fn() {
      case
        custodian.lookup(f.owner, input.key, input.arguments, input.request)
      {
        Ok(custody.FinalOutcome(_)) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "The late bounded failure has actually reached the owner."
  assert scalar(f.path, "SELECT run_custody FROM owner_custody_tools")
    == "unreleased"

  assert invoke(f, 1) == Error(custody.Capacity)
  stop(f)
  let assert Ok(started) = custodian.start(f.owner, f.config)
    as "Unreleased final diagnostics reopen recovery-only."
  let f = Fixture(..f, pid: started.pid)

  assert invoke(f, 1) == Error(custody.Capacity)
  stop(f)
}

pub fn retained_report_without_final_and_late_generic_outcome_never_release_test() {
  let receipt = process.new_subject()
  let f =
    fixture("retained-unknown", fn(owner, key, _) {
      let assert Ok(reference) =
        custodian.retain_report(owner, key, report("alpha"))
        as "Original report COMMIT survives without a finalized message."
      process.send(receipt, reference)
      assert custodian.fatal_fence(owner, key) == Ok(Nil)
      effects.ToolFailed("late generic result")
    })
  let assert Error(_) = invoke(f, 0)
    as "A generic outcome cannot acknowledge retained complete report history."
  let assert Ok(reference) = process.receive(receipt, 1000)
    as "Actual retained report receipt."

  let input = invocation(0)
  let assert Ok(request) = custody.payload(limits(), input.request)
    as "Original bounded request."
  let assert Ok(arguments) = custody.payload(limits(), input.arguments)
    as "Original bounded arguments."
  assert custodian.lookup(f.owner, input.key, input.arguments, input.request)
    == Ok(custody.AwaitingFinal(request, arguments, 0))

  let assert Error(_) = custodian.read_report_chunk(f.owner, reference, 0)
    as "No finalized session reference was admitted."
  assert scalar(f.path, "SELECT run_custody FROM owner_custody_tools")
    == "unreleased"
  assert invoke(f, 1) == Error(custody.Capacity)
  stop(f)

  let assert Ok(started) = custodian.start(f.owner, f.config)
    as "Report-only history validates without becoming a final result."
  let f = Fixture(..f, pid: started.pid)
  assert invoke(f, 1) == Error(custody.Capacity)
  let assert Ok(custody.AwaitingFinal(..)) =
    custodian.lookup(f.owner, input.key, input.arguments, input.request)
    as "No final is reconstructed after restart."

  stop(f)
}

pub fn trusted_nonexecution_refusals_are_closed_and_cannot_replace_reports_test() {
  let message =
    message.ToolResultMessage(
      "call",
      "code_mode",
      [message.ToolResultText("refused", None)],
      Some(
        json.Object([
          #("kind", json.String("code_mode_not_run_v1")),
          #("stage", json.String("vet")),
        ]),
      ),
      None,
      None,
      True,
      0,
    )
  assert outcome.validate_final(
      custody.CodeModeReportV1,
      None,
      None,
      effects.ToolCompleted(message, False),
    )
    == Ok(Nil)
  let generic = message.ToolResultMessage(..message, details: None)
  let assert Error(_) =
    outcome.validate_final(
      custody.CodeModeReportV1,
      None,
      None,
      effects.ToolCompleted(generic, False),
    )
    as "A generic report-free ToolCompleted is not trusted nonexecution evidence."

  let changed =
    message.ToolResultMessage(
      ..message,
      details: Some(
        json.Object([
          #("kind", json.String("code_mode_not_run_v1")),
          #("stage", json.String("run")),
        ]),
      ),
    )
  let assert Error(_) =
    outcome.validate_final(
      custody.CodeModeReportV1,
      None,
      None,
      effects.ToolCompleted(changed, False),
    )
    as "An error flag cannot classify an executed program as nonexecution."
  let original = report("alpha")
  let assert Ok(reference) =
    rv.reference(
      session(),
      run(0).result_entry,
      string.repeat("a", 64),
      bit_array.byte_size(rv.bytes(original)),
    )
    as "Syntactic reference has no custody authority."

  let assert Error(_) =
    outcome.validate_final(
      custody.CodeModeReportV1,
      Some(reference),
      Some(rv.outcome(original)),
      effects.ToolCompleted(message, False),
    )
    as "A not-run diagnostic cannot replace a retained report."
  let assert Error(_) =
    outcome.validate_final(
      custody.CodeModeReportV1,
      None,
      None,
      final(reference),
    )
    as "A successful reference without prior report COMMIT refuses."
  let valid =
    message.ToolResultMessage(
      "call",
      "code_mode",
      [message.ToolResultText("preview", None)],
      Some(
        json.Object([
          #("kind", json.String("code_mode_report_v1")),
          #("reference", json.String(rv.ref_to_string(reference))),
        ]),
      ),
      None,
      None,
      False,
      1000,
    )
  let changed = message.ToolResultMessage(..valid, is_error: True)

  let assert Error(_) =
    outcome.validate_final(
      custody.CodeModeReportV1,
      Some(reference),
      Some(rv.outcome(original)),
      effects.ToolCompleted(changed, False),
    )
    as "Completed terminal cannot claim program error."
  let changed = message.ToolResultMessage(..valid, tool_call_id: "another")
  let assert Error(_) =
    outcome.validate_outcome(run(0), effects.ToolCompleted(changed, False))
    as "Original provider identity remains required."
  let changed =
    message.ToolResultMessage(..valid, content: [
      message.ToolResultText(string.repeat("x", 4097), None),
    ])

  let assert Error(_) =
    outcome.validate_final(
      custody.CodeModeReportV1,
      Some(reference),
      Some(rv.outcome(original)),
      effects.ToolCompleted(changed, False),
    )
    as "The first excess preview byte refuses."
}

pub fn owner_crash_after_report_commit_without_final_reopens_unknown_test() {
  let receipt = process.new_subject()
  let hold = process.new_subject()
  let f =
    fixture_with_deadline("crash-after-commit", 1000, fn(owner, key, _) {
      let assert Ok(reference) =
        custodian.retain_report(owner, key, report("alpha"))
        as "The actual owner COMMIT returns its original report receipt."
      process.send(receipt, #(reference, process.self()))

      // The original renderer has not produced a final. Its owner-bound weft
      // worker must be cancelled when the concrete custody actor crashes.
      let assert Ok(Nil) = process.receive(hold, 5000)
        as "Only explicit fixture release could produce a final."
      final(reference)
    })
  let caller =
    weft.new([fn() { invoke(f, 0) }])
    |> weft.deadline(4000)
    |> weft.start_detached
  let assert Ok(#(reference, worker)) = process.receive(receipt, 1000)
    as "Crash happens strictly after actual report COMMIT, before final."
  let owner_watch = process.monitor(f.pid)
  let worker_watch = process.monitor(worker)

  process.unlink(f.pid)
  process.kill(f.pid)
  let assert Ok(process.ProcessDown(reason: process.Killed, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(owner_watch, fn(down) { down })
    |> process.selector_receive(2000)
    as "Original owner death is a crash observation, never retirement proof."
  let assert Ok(process.ProcessDown(..)) =
    process.new_selector()
    |> process.select_specific_monitor(worker_watch, fn(down) { down })
    |> process.selector_receive(2000)
    as "The original owner-bound renderer worker also terminates."

  let assert weft.PulledOutcome(weft.Failed(0, _)) = weft.pull(caller, 2000)
    as "Actual waiting caller receives uncertainty rather than a invented final."
  let assert weft.AllDelivered = weft.pull(caller, 1000)
    as "This test's managed caller is joined independently of durable custody."
  assert scalar(f.path, "SELECT run_custody FROM owner_custody_tools")
    == "unreleased"
  let assert Ok(started) = custodian.start(f.owner, f.config)
    as "The committed report validates after actor crash and database reopen."

  let f = Fixture(..f, pid: started.pid)
  let input = invocation(0)
  let assert Ok(custody.AwaitingFinal(..)) =
    custodian.lookup(f.owner, input.key, input.arguments, input.request)
    as "A retained report alone cannot reconstruct a final result."
  assert invoke(f, 1) == Error(custody.Capacity)

  let assert Error(_) = custodian.read_report_chunk(f.owner, reference, 0)
    as "The report has no final reference admission yet."
  let assert Error(_) = process.receive(receipt, 0)
    as "Restart never invokes a replacement renderer."
  stop(f)
}

pub fn generic_failure_without_report_retains_diagnostic_but_never_discharges_test() {
  let observed = process.new_subject()
  let diagnostic = effects.ToolFailed("original bounded diagnostic")
  let f =
    fixture("generic-no-report", fn(_, _, _) {
      process.send(observed, Nil)
      diagnostic
    })
  let assert Error(_) = invoke(f, 0)
    as "A generic failure provides neither a complete report nor trusted nonexecution evidence."
  assert process.receive(observed, 1000) == Ok(Nil)
  let input = invocation(0)
  let assert Ok(custody.FinalOutcome(payload)) =
    custodian.lookup(f.owner, input.key, input.arguments, input.request)
    as "The original bounded diagnostic remains durable for recovery."

  assert effects.decode_tool_outcome(custody.bytes(payload)) == Ok(diagnostic)
  assert scalar(f.path, "SELECT run_custody FROM owner_custody_tools")
    == "unreleased"
  assert invoke(f, 1) == Error(custody.Capacity)
  stop(f)

  // Reopen may recover the synthetic diagnostic but cannot reinterpret it as
  // proof that code did not run or release the original report allowance.
  let assert Ok(started) = custodian.start(f.owner, f.config)
    as "Report-free generic diagnostics validate only as unresolved history."
  let f = Fixture(..f, pid: started.pid)
  assert custodian.lookup(f.owner, input.key, input.arguments, input.request)
    == Ok(custody.FinalOutcome(payload))
  assert invoke(f, 1) == Error(custody.Capacity)
  let assert Error(_) = process.receive(observed, 0)
    as "Diagnostic recovery never starts a replacement body."
  stop(f)
}

fn session() -> ids.SessionId {
  ids.mint_session(ids.generator(clock.fixed(1000), 77)).0
}

fn run(index: Int) -> effects.ToolRun {
  let original_operation = ids.mint_op(ids.generator(clock.fixed(1000), 77)).0
  let result_entry =
    ids.mint_entry(ids.generator(clock.fixed(1001), index + 10)).0
  let arguments = json.Object([])
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

fn report(text: String) -> rv.CompleteReport {
  let assert Ok(metadata) =
    rv.metadata(
      "sha256-" <> string.repeat("b", 64),
      rv.Enforcement(
        rv.Unreported("not observed"),
        rv.Unreported("not observed"),
      ),
      rv.CallLog(0, 0, 0, 0, 0, 0, []),
    )
    as "Closed owner observations validate."
  let assert Ok(report) =
    rv.from_outcome(rv.Completed(mp.StringValue(text)), metadata)
    as "A complete canonical terminal, not a display conversion."
  report
}

fn final(reference: rv.ReportRef) -> effects.ToolOutcome {
  effects.ToolCompleted(
    message.ToolResultMessage(
      "call",
      "code_mode",
      [message.ToolResultText("preview", None)],
      Some(
        json.Object([
          #("kind", json.String("code_mode_report_v1")),
          #("reference", json.String(rv.ref_to_string(reference))),
        ]),
      ),
      None,
      None,
      False,
      1000,
    ),
    False,
  )
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

fn scalar(path: String, statement: String) -> String {
  let assert Ok(db) = sqlight.open(path) as "Test-only scalar connection."
  let assert Ok([value]) =
    sqlight.query(statement, db, [], decode.at([0], decode.string))
    as "Exactly one bounded run/header result."
  assert sqlight.close(db) == Ok(Nil)
  value
}

fn corrupt(path: String, statement: String) -> Nil {
  let assert Ok(db) = sqlight.open(path) as "Test-only fault connection."
  assert sqlight.exec(statement, db) == Ok(Nil)
  assert sqlight.close(db) == Ok(Nil)
}

fn released(f: Fixture) -> Nil {
  let assert poll.Answered(Nil) =
    poll.until(within: 2000, every: 5, attempt: fn() {
      case scalar(f.path, "SELECT run_custody FROM owner_custody_tools") {
        "released" -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "Original final COMMIT and actual AllDelivered release run custody."
  Nil
}
