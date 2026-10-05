//// Executable skills retain source rather than reusable authority or observations.
//// Each exact selected version enters the ordinary current-caller code-mode
//// admission, vetting, compilation and jail pipeline with fresh JSON input.

import client/codemode
import client/evolution/record
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

/// Runs author checks through current code-mode policy and proves executor close.
///
/// A skill's test_entry names a zero-argument function in program.gleam whose
/// result is report.Outcome. Invocation and testing both re-vet and recompile.
///
/// ## Examples
///
/// `test_owned(store,id,host,ctx,retire)` records actual jailed author evidence.
pub fn test_owned(
  catalogue: store.Store,
  id: record.CandidateId,
  host: codemode.Config,
  ctx: tool.Ctx,
  retire: fn() -> Result(Nil, String),
) -> Result(record.Evidence, store.Refusal) {
  test_with(
    catalogue,
    id,
    fn(submitted) {
      Ok(codemode.execute(
        host,
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
        ),
      ))
    },
    retire,
  )
}

/// Runs vetted source through a native owned runner before persisting evidence.
///
/// The runner preserves the caller's capability router while its native owner
/// isolates compiler and satellite artifacts. Retirement still happens once on
/// every outcome, including rejected source and interrupted execution.
///
/// ## Examples
///
/// `test_with(store,id,run,retire)` borrows a dedicated native program executor.
pub fn test_with(
  catalogue: store.Store,
  id: record.CandidateId,
  run: fn(String) -> Result(surface.Execution, store.Refusal),
  retire: fn() -> Result(Nil, String),
) -> Result(record.Evidence, store.Refusal) {
  let observed = test_execution(catalogue, id, run)
  use Nil <- result.try(
    retire()
    |> result.map_error(fn(reason) { store.CleanupUnconfirmed(reason, retire) }),
  )
  use #(verdict, observation) <- result.try(case observed {
    Ok(execution) -> {
      let verdict = case execution.result {
        surface.Ran(surface.Completed(_), _) -> record.Passed
        surface.Ran(surface.Errored(_, _), _)
        | surface.VetRejected(_)
        | surface.CompileFailed(_) -> record.Failed
        surface.RunFailed(_) ->
          record.Inconclusive("jailed skill test did not complete")
      }
      Ok(#(
        verdict,
        json.to_string(
          json.object([
            #("execution", json.string(string.inspect(execution.result))),
            #("enforcement", json.string(string.inspect(execution.enforcement))),
            #("retirement", json.string("native executor close confirmed")),
          ]),
        ),
      ))
    }
    Error(store.TestFailed(reason)) ->
      Ok(#(
        record.Failed,
        json.to_string(json.object([#("refusal", json.string(reason))])),
      ))
    Error(store.Unavailable(reason)) ->
      Ok(#(
        record.Inconclusive(reason),
        json.to_string(json.object([#("refusal", json.string(reason))])),
      ))
    Error(refusal) -> Error(refusal)
  })
  store.record_evidence(catalogue, id, record.AuthorTests, verdict, observation)
}

fn test_execution(
  catalogue: store.Store,
  id: record.CandidateId,
  run: fn(String) -> Result(surface.Execution, store.Refusal),
) -> Result(surface.Execution, store.Refusal) {
  use candidate <- result.try(store.read_candidate(catalogue, id))
  use Nil <- result.try(
    case
      candidate.kind == record.Program
      && candidate.identity == store.identity(catalogue)
    {
      True -> Ok(Nil)
      False -> Error(store.Changed)
    },
  )
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
