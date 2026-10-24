//// Executable skills retain source rather than reusable authority or observations.
//// Each exact selected version enters the ordinary current-caller code-mode
//// admission, vetting, compilation and jail pipeline with fresh JSON input.
////
//// `test_with` takes the candidate itself. The orchestrator's wrapper in
//// `machine/local` reads it from the catalogue and checks that it was admitted
//// under the current identity, so the check runs without a catalogue.

import client/codemode
import client/evolution/evaluate
import client/evolution/record
import client/evolution/retirement
import client/evolution/store
import core/json as value
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import tools/codemode as surface
import tools/tool

/// Runs a selected skill through the production code-mode pipeline.
///
/// Skills expose `pub fn run(input: String) -> report.Outcome`; the input string
/// contains JSON. The generated adapter quotes the JSON as a Gleam string, so
/// a fresh input can never inject source or import an additional module.
///
/// ## Examples
///
/// `invoke(store, selection, host, ctx, input)` recompiles retained source.
pub fn invoke(
  catalogue: store.Store,
  selection: record.Selection,
  host: codemode.Config,
  ctx: tool.Ctx,
  input: value.JsonValue,
) -> Result(surface.Execution, store.Refusal) {
  use candidate <- result.try(store.authorized(catalogue, selection))
  use Nil <- result.try(case candidate.kind {
    record.Program -> Ok(Nil)
    record.Extension | record.Prompt ->
      Error(store.Authority("selected artifact is not an executable skill"))
  })
  use source <- result.try(
    list.key_find(candidate.files, "program.gleam")
    |> result.replace_error(store.Corrupt("skill has no program.gleam")),
  )
  let submitted = adapter(source, value.to_string(value.canonical(input)))
  let request =
    surface.Request(
      source: submitted,
      seam: surface.WorkspaceSeam,
      strand: ctx.strand,
      op_id: ctx.op_id,
      step_id: ctx.step_id,
      source_index: ctx.source_index,
      workspace: ctx.workspace,
      base_policy: ctx.base_policy,
      directory_access: ctx.directory_access,
      demand: ctx.demand,
      env: ctx.env,
      within_ms: host.max_within_ms,
      grants: ctx.grants,
      observe_output: ctx.observe_output,
    )
  Ok(codemode.execute(host, request))
}

/// Runs vetted source through a native owned runner and answers its report.
///
/// A skill's test_entry names a zero-argument function in program.gleam whose
/// result is report.Outcome. Invocation and testing both re-vet and recompile.
///
/// The runner preserves the caller's capability router while its native owner
/// isolates compiler and satellite artifacts. Retirement still happens once on
/// every outcome, including rejected source and interrupted execution, and it
/// happens before the report is answered. The caller records the report with
/// `evaluate.record`.
///
/// ## Examples
///
/// `test_with(candidate,run,retire)` borrows a dedicated native program executor.
pub fn test_with(
  candidate: record.Candidate,
  run: fn(String) -> Result(surface.Execution, store.Refusal),
  retire: retirement.Task,
) -> Result(evaluate.Report, store.Refusal) {
  let observed = test_execution(candidate, run)
  use Nil <- result.try(
    retirement.perform(retire)
    |> result.map_error(fn(failure) {
      store.CleanupUnconfirmed(failure.reason, failure.retry)
    }),
  )
  evaluate.report_of(result.map(observed, executed))
}

fn executed(execution: surface.Execution) -> #(record.Verdict, String) {
  let verdict = case execution.result {
    surface.Ran(surface.Completed(_), _) -> record.Passed

    surface.Ran(surface.Errored(_, _), _)
    | surface.VetRejected(_)
    | surface.CompileFailed(_) -> record.Failed

    surface.RunFailed(_) ->
      record.Inconclusive("jailed skill test did not complete")
  }
  #(
    verdict,
    json.to_string(
      json.object([
        #("execution", json.string(string.inspect(execution.result))),
        #("enforcement", json.string(string.inspect(execution.enforcement))),
        #("retirement", json.string("native executor close confirmed")),
      ]),
    ),
  )
}

/// Words a program's execution as the tool outcome its caller sees.
///
/// A completed run is a success and every other result is a failure; both
/// carry the execution's JSON value as text and as details. The outcome is
/// plain data, so a machine on another host can answer the same value.
///
/// ## Examples
///
/// `outcome(execution)` is `tool.success(..)` for a completed run.
pub fn outcome(execution: surface.Execution) -> tool.ToolOutcome {
  let rendered = surface.execution_value(execution)
  let outcome = case execution.result {
    surface.Ran(surface.Completed(_), _) ->
      tool.success(value.to_string(rendered))

    surface.Ran(surface.Errored(_, _), _)
    | surface.VetRejected(_)
    | surface.CompileFailed(_)
    | surface.RunFailed(_) -> tool.failure(value.to_string(rendered))
  }
  tool.with_details(outcome, rendered)
}

fn test_execution(
  candidate: record.Candidate,
  run: fn(String) -> Result(surface.Execution, store.Refusal),
) -> Result(surface.Execution, store.Refusal) {
  use source <- result.try(
    list.key_find(candidate.files, "program.gleam")
    |> result.replace_error(store.Corrupt("skill has no program.gleam")),
  )
  use check <- result.try(case candidate.test_entry {
    Some(check) -> Ok(check)
    None -> Error(store.TestFailed("skill has no author test function"))
  })
  use Nil <- result.try(case legal_function(check) {
    True -> Ok(Nil)
    False -> Error(store.Authority("test function must be an identifier"))
  })
  let submitted = source <> "\n\npub fn main() {\n  " <> check <> "()\n}\n"
  run(submitted)
}

fn legal_function(name: String) -> Bool {
  name != ""
  && string.length(name) <= 64
  && list.all(string.to_graphemes(name), fn(char) {
    string.contains("abcdefghijklmnopqrstuvwxyz0123456789_", char)
  })
}

/// Creates the only generated skill input adapter.
///
/// ## Examples
///
/// `adapter(source, "{}")` passes a JSON string to the retained `run` function.
pub fn adapter(source: String, input: String) -> String {
  source
  <> "\n\npub fn main() {\n  run("
  <> json.to_string(json.string(input))
  <> ")\n}\n"
}
