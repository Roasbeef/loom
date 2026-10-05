//// Candidate compilation shares installation's hermetic preparation and seam.
//// Author-owned test modules are compiled beside the exact retained sources,
//// and their entry returns report.Outcome through the ordinary cap runtime.
//// Durable evidence is written only after the native runner proves cleanup.

import client/evolution/record
import client/evolution/retirement
import client/evolution/store
import client/extension/archive
import client/extension/install
import client/extension/manifest
import client/extension/record as extension_record
import client/extension/source
import codemode/compile
import codemode/enforcement
import codemode/satellite
import codemode/vet/package
import codemode/vet/policy
import gleam/bit_array
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import simplifile

/// Stage inputs consumed by the native generation owner.
pub type Prepared {
  Prepared(
    /// The verified immutable source envelope.
    candidate: record.Candidate,
    /// The exact callable contract.
    manifest: manifest.Manifest,
    /// A dispatch recipe, whose authority remains in the central selection.
    record: extension_record.Record,
    /// The disposable generation directory.
    directory: String,
    /// The compiled beam directory.
    artifact: String,
    /// The retained source snapshot materialized for existing dispatch.
    sources: String,
    /// The build's independent enforcement observation.
    enforcement: enforcement.Report,
  )
}

/// A native evaluator result obtained after executor retirement.
pub type Observation {
  Observation(
    /// The candidate's report, distinct from the evaluator's facts.
    outcome: satellite.Outcome,
    /// Bounded JSON host observations including cleanup and enforcement.
    detail: String,
  )
}

/// Compiles a verified source envelope for the generation owner.
///
/// This function creates no approval or selection. The owner rechecks current
/// approval at publication and before accepting subsequent invocations.
///
/// ## Examples
///
/// `prepare(store, id, directory, offline_build)` yields a disposable recipe.
pub fn prepare(
  catalogue: store.Store,
  id: record.CandidateId,
  directory: String,
  build: install.Build,
) -> Result(Prepared, store.Refusal) {
  use candidate <- result.try(store.read_candidate(catalogue, id))
  use Nil <- result.try(current(catalogue, candidate))
  use decoded <- result.try(decode_manifest(candidate))
  use vetted <- result.try(vet(candidate))
  use Nil <- result.try(materialize(directory <> "/sources", candidate.files))
  use Nil <- result.try(
    install.prepare(directory <> "/build", decoded, vetted)
    |> result.map_error(fn(error) { store.TestFailed(install.describe(error)) }),
  )
  let compile.Built(result: products, enforcement:) =
    build(directory <> "/build")
  use products <- result.try(products |> result.map_error(compile_error))
  let tree =
    archive.Tree(
      root: "candidate",
      files: list.map(candidate.files, fn(file) {
        archive.File(file.0, bit_array.from_string(file.1))
      }),
      commit: None,
    )
  let written =
    extension_record.for_install(
      decoded,
      from: source.LocalPath("candidate:" <> record.id_string(id)),
      revision: record.id_string(id),
      tree_digest: archive.digest(tree),
      manifest_hash: products.manifest_hash,
      allowlist: install.allowlist(),
      approved_at: 0,
      approved_by: "central evolution selection",
      artifact: products.beam_dir,
    )
  Ok(Prepared(
    candidate:,
    manifest: decoded,
    record: written,
    directory:,
    artifact: products.beam_dir,
    sources: directory <> "/sources",
    enforcement:,
  ))
}

/// Runs the candidate-owned tests and records their exact host observation.
///
/// The injected production runner owns a dedicated native executor and returns
/// only after its retirement witness. A report of satellite shutdown alone
/// cannot satisfy that contract and must return CleanupUnconfirmed instead.
///
/// ## Examples
///
/// `extension(store,id,directory,build,run)` writes durable author-test evidence.
pub fn extension(
  catalogue: store.Store,
  id: record.CandidateId,
  directory: String,
  build: install.Build,
  run: fn(compile.Artifact) -> Result(Observation, store.Refusal),
) -> Result(record.Evidence, store.Refusal) {
  extension_owned(
    catalogue,
    id,
    directory,
    build,
    run,
    retirement.repeat(fn() { Ok(Nil) }),
  )
}

/// Retires the native evaluation executor on every path before writing evidence.
///
/// The runner borrows this executor and never closes it itself. Compilation,
/// vetting and execution failures therefore share exactly one retirement call,
/// and an unconfirmed cleanup returns its retry witness instead of evidence.
///
/// ## Examples
///
/// `extension_owned(store,id,root,build,run,retire)` is the production evaluator.
pub fn extension_owned(
  catalogue: store.Store,
  id: record.CandidateId,
  directory: String,
  build: install.Build,
  run: fn(compile.Artifact) -> Result(Observation, store.Refusal),
  retire: retirement.Task,
) -> Result(record.Evidence, store.Refusal) {
  let outcome = tested(catalogue, id, directory, build, run)
  use Nil <- result.try(
    retirement.perform(retire)
    |> result.map_error(fn(failure) {
      store.CleanupUnconfirmed(failure.reason, failure.retry)
    }),
  )
  case outcome {
    Ok(#(verdict, observation)) ->
      store.record_evidence(
        catalogue,
        id,
        record.AuthorTests,
        verdict,
        observation,
      )
    Error(store.TestFailed(reason)) ->
      store.record_evidence(
        catalogue,
        id,
        record.AuthorTests,
        record.Failed,
        json.to_string(json.object([#("refusal", json.string(reason))])),
      )
    Error(store.Unavailable(reason)) ->
      store.record_evidence(
        catalogue,
        id,
        record.AuthorTests,
        record.Inconclusive(reason),
        json.to_string(json.object([#("refusal", json.string(reason))])),
      )
    Error(refusal) -> Error(refusal)
  }
}

fn tested(
  catalogue: store.Store,
  id: record.CandidateId,
  directory: String,
  build: install.Build,
  run: fn(compile.Artifact) -> Result(Observation, store.Refusal),
) -> Result(#(record.Verdict, String), store.Refusal) {
  use candidate <- result.try(store.read_candidate(catalogue, id))
  use Nil <- result.try(current(catalogue, candidate))
  use decoded <- result.try(decode_manifest(candidate))
  use vetted <- result.try(vet(candidate))
  use entry <- result.try(case candidate.test_entry {
    Some(entry) -> Ok(entry)
    None -> Error(store.TestFailed("candidate has no author test entry"))
  })
  use Nil <- result.try(
    case list.contains(package.module_names(vetted), entry) {
      True -> Ok(Nil)
      False ->
        Error(store.TestFailed("test entry is absent from vetted sources"))
    },
  )
  use Nil <- result.try(materialize(directory <> "/sources", candidate.files))
  use Nil <- result.try(
    install.prepare(directory, decoded, vetted)
    |> result.map_error(fn(error) { store.TestFailed(install.describe(error)) }),
  )
  use Nil <- result.try(write(
    directory <> "/src/" <> compile.entry_module <> ".gleam",
    test_source(entry),
  ))
  let compile.Built(result: built, enforcement:) = build(directory)
  use products <- result.try(built |> result.map_error(compile_error))
  use observed <- result.try(
    run(compile.Artifact(
      build_root: directory,
      beam_dir: products.beam_dir,
      entry_module: compile.entry_module,
      manifest_hash: products.manifest_hash,
    )),
  )
  let verdict = case observed.outcome {
    satellite.Completed(_) -> record.Passed
    satellite.Errored(_, _) -> record.Failed
  }
  let observation =
    json.to_string(
      json.object([
        #("author_outcome", json.string(string.inspect(observed.outcome))),
        #("host", json.string(observed.detail)),
        #(
          "build_enforcement",
          json.string(install.enforcement_line(enforcement)),
        ),
        #("artifact", json.string(products.manifest_hash)),
        #("test_entry", json.string(entry)),
      ]),
    )
  Ok(#(verdict, observation))
}

/// Renders a test entry without admitting authored runtime wrappers.
///
/// ## Examples
///
/// `test_source("weather_test")` calls only its report-producing main entry.
pub fn test_source(entry: String) -> String {
  "//// Generated candidate-owned test runner.\nimport cap/runtime\nimport "
  <> entry
  <> " as candidate_tests\n\npub fn main() -> Nil {\n  runtime.run(candidate_tests.main)\n}\n"
}

fn decode_manifest(
  candidate: record.Candidate,
) -> Result(manifest.Manifest, store.Refusal) {
  use Nil <- result.try(case candidate.kind {
    record.Extension -> Ok(Nil)
    record.Program | record.Prompt ->
      Error(store.TestFailed(
        "extension evaluator requires an extension candidate",
      ))
  })
  use text <- result.try(
    list.key_find(candidate.files, "extension.toml")
    |> result.replace_error(store.TestFailed("extension.toml absent")),
  )
  manifest.decode(
    text,
    manifest.Surroundings(
      files: candidate.files,
      modules: package.module_names_of(candidate.files),
    ),
  )
  |> result.map_error(store.TestFailed)
}

fn vet(
  candidate: record.Candidate,
) -> Result(package.VettedPackage, store.Refusal) {
  package.vet_candidate(candidate.files, policy.for_seam(policy.ExtensionSeam))
  |> result.map_error(fn(refusals) {
    store.TestFailed(string.join(
      list.map(refusals, fn(refusal) {
        refusal.0 <> ": " <> package.describe(refusal.1)
      }),
      "; ",
    ))
  })
}

fn current(
  catalogue: store.Store,
  candidate: record.Candidate,
) -> Result(Nil, store.Refusal) {
  case candidate.identity == store.identity(catalogue) {
    True -> Ok(Nil)
    False -> Error(store.Changed)
  }
}

fn materialize(
  root: String,
  files: List(#(String, String)),
) -> Result(Nil, store.Refusal) {
  list.try_each(files, fn(file) { write(root <> "/" <> file.0, file.1) })
}

fn write(path: String, text: String) -> Result(Nil, store.Refusal) {
  let parts = string.split(path, "/")
  let parent = string.join(list.take(parts, list.length(parts) - 1), "/")
  use Nil <- result.try(
    simplifile.create_directory_all(parent)
    |> result.map_error(fn(error) {
      store.Unavailable(simplifile.describe_error(error))
    }),
  )
  simplifile.write(path, text)
  |> result.map_error(fn(error) {
    store.Unavailable(simplifile.describe_error(error))
  })
}

fn compile_error(error: compile.CompileError) -> store.Refusal {
  store.TestFailed(string.inspect(error))
}
