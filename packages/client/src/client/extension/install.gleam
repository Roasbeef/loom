//// The install pipeline: from a source an operator typed to a directory
//// the server will read at boot.
////
//// Six steps, each returning a typed failure that names the layer it
//// came from — `Fetch`, `Extract`, `Manifest`, `Vetting`, `Compile`,
//// `Record`. Naming the layer is the whole point of the type: an
//// extension is somebody else's repository, and "the install failed" is
//// a bug report nobody can act on, while "vetting refused
//// src/weather/nif.gleam: @external is not permitted" is one the author
//// can fix in a minute.
////
//// ```
//// source → fetch or copy → extract → manifest → vetting → compile → record
//// ```
////
//// # The install is the one network-bound step, and it runs unjailed
////
//// So it gets the treatment Decision 2 of the extension ruling gives an
//// extension's own egress. There is no git client: a source is a local
//// path, an `https://` `.tar.gz`, or a GitHub repository URL, and the
//// fetch is one policed `GET` against exactly the URL's own host. The
//// fetch itself is injected (`Fetcher`) rather than performed here, so
//// this module holds no HTTP client and a test drives the whole pipeline
//// with a function that was never called.
////
//// # The compile is offline and jailed
////
//// It is the same `codemode/build` a code-mode program is built by: an
//// ordinary `broker.clear_call` whose requirements set `NetworkOff`,
//// against the same pre-seeded package cache. The extension's own
//// `gleam.toml` never reaches the compiler — the build root's is
//// generated from `compile.default_dependencies()` — so a dependency an
//// author named would fail the build rather than enter it, and vetting
//// refuses it before that anyway.
////
//// Vetting runs on the source *before* the compiler sees it, so the
//// compiler is never the first thing to touch a hostile file.
////
//// # Staging, and why the record is written last
////
//// Everything happens under `<root>/.staging/<random>/`, and the tree is
//// renamed into `<root>/<name>` only after the record exists inside it.
//// So a directory under the root is either a complete install or absent,
//// and there is no state in which a half-installed extension is
//// discoverable. Every failure removes its staging directory, including
//// the ones that happen after the build has written megabytes into it.
////
//// # The generated entry module
////
//// The build root gets one module the extension did not write:
////
//// ```gleam
//// import ext/runtime
//// import weather/forecast as ext_entry_0
////
//// pub fn main() -> Nil {
////   runtime.serve([#("weather", ext_entry_0.run)])
//// }
//// ```
////
//// Each `[[tool]]`'s `entry` module must expose `pub fn run` of type
//// `ext.Tool`; the aliases are positional so two tools whose entry
//// modules share a last segment cannot collide. A wrong signature is a
//// compile error naming the module, which is the earliest and clearest
//// place that mistake can be caught.

import client/extension/archive.{type Caps, type Tree}
import client/extension/manifest.{type Manifest}
import client/extension/record.{type Record, type Root}
import client/extension/source.{type Source}
import codemode/compile
import codemode/vet
import codemode/vet/package.{type VettedPackage}
import codemode/vet/policy as vet_policy
import core/clock.{type Clock}
import gleam/bit_array
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile

/// The largest archive a fetch will accept: 32 MiB, the cap the ruling
/// names. An extension is source and a schema or two; a response at this
/// bound is not one.
pub const max_archive_bytes = 33_554_432

/// The function every `[[tool]]`'s entry module must expose.
pub const entry_function = "run"

/// The HTTP fetch, injected.
///
/// A function value rather than a client, so this module holds no
/// transport and a test can drive the whole pipeline with a fetcher that
/// asserts it was never called. The orchestrator wires `broker/egress`
/// here.
pub type Fetcher =
  fn(String, Int) -> Result(BitArray, String)

/// The jailed build, injected: given a prepared build root, run the
/// offline build and say what came out.
///
/// The same seam `codemode/compile.Builder` is, with the phase identity
/// already closed over — an install has one build and the caller is the
/// party that minted its coordinates.
pub type Build =
  fn(String) -> compile.Built

/// Everything the pipeline needs that is not the source.
pub type Config {
  Config(
    /// Where installs live.
    root: Root,
    /// The extraction bounds.
    caps: Caps,
    /// The injected fetch.
    fetch: Fetcher,
    /// The injected jailed build.
    build: Build,
    /// The clock the approval is timestamped from.
    clock: Clock,
    /// Randomness for the staging directory's name.
    entropy: fn() -> Int,
    /// Who is approving: the `USER` environment, or `unknown`.
    approved_by: String,
  )
}

/// Which layer refused, and why.
pub type Failure {
  /// The tree could not be fetched.
  Fetch(reason: String)

  /// The bytes were not a tree this install would accept.
  Extract(reason: String)

  /// `extension.toml` did not decode, or promised something the tree does
  /// not hold.
  Manifest(reason: String)

  /// One or more files failed the extension seam's vetting.
  Vetting(refusals: List(#(String, package.Rejection)))

  /// The jailed build refused, failed, or produced nothing usable.
  Compile(reason: String)

  /// The staging directory, the record, or the rename into place failed.
  Record(reason: String)
}

/// What an install produced.
pub type Installed {
  Installed(record: Record, manifest: Manifest, directory: String)
}

/// Installs `from`, at `rev` when the source names one.
///
/// Total: every failure is a `Failure` naming its layer, and every
/// failure removes the staging directory it was using.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(installed) =
///   install.run(config, source.LocalPath("./weather"), rev: None)
/// assert installed.record.revision == "local"
/// ```
///
pub fn run(
  config: Config,
  from: Source,
  rev rev: Option(String),
) -> Result(Installed, Failure) {
  use tree <- result.try(acquire(config, from, rev))
  use files <- result.try(text_files(tree))
  use decoded <- result.try(read_manifest(files))
  use vetted <- result.try(vet_source(files))
  stage(config, from, rev, tree, decoded, vetted)
}

/// Renders a failure as the sentence an operator reads, layer first.
///
/// ## Examples
///
/// ```gleam
/// assert install.describe(install.Fetch("no route"))
///   == "fetch: no route"
/// ```
///
pub fn describe(failure: Failure) -> String {
  case failure {
    Fetch(reason:) -> "fetch: " <> reason
    Extract(reason:) -> "extract: " <> reason
    Manifest(reason:) -> "manifest: " <> reason
    Vetting(refusals:) ->
      "vetting: " <> string.join(refusal_lines(refusals), "; ")
    Compile(reason:) -> "compile: " <> reason
    Record(reason:) -> "record: " <> reason
  }
}

/// One line per refused file, each naming the file. Public so `loom ext
/// verify` prints the same shape the install refused with.
///
/// ## Examples
///
/// ```gleam
/// assert install.refusal_lines([]) == []
/// ```
///
pub fn refusal_lines(
  refusals: List(#(String, package.Rejection)),
) -> List(String) {
  list.map(refusals, fn(entry) { entry.0 <> ": " <> package.describe(entry.1) })
}

/// The allowlist an extension's source is judged against: the extension
/// seam's module names.
///
/// Recorded at install and compared at every load, so a widened seam
/// shows up as a record that no longer matches rather than as an
/// extension quietly gaining reach.
///
/// ## Examples
///
/// ```gleam
/// assert list.contains(install.allowlist(), "cap/ext")
/// ```
///
pub fn allowlist() -> List(String) {
  vet_policy.allowed_imports(vet_policy.for_seam(vet_policy.ExtensionSeam))
}

// --- step 1: the tree -----------------------------------------------------

fn acquire(
  config: Config,
  from: Source,
  rev: Option(String),
) -> Result(Tree, Failure) {
  case from {
    source.LocalPath(path:) ->
      archive.from_directory(path, config.caps)
      |> result.map_error(fn(error) { Extract(archive.describe(error)) })
    source.ArchiveUrl(..) | source.GitHub(..) -> fetched(config, from, rev)
  }
}

fn fetched(
  config: Config,
  from: Source,
  rev: Option(String),
) -> Result(Tree, Failure) {
  use url <- result.try(
    source.archive_url(from, rev) |> result.map_error(Fetch),
  )
  use bytes <- result.try(
    config.fetch(url, max_archive_bytes) |> result.map_error(Fetch),
  )
  archive.extract(bytes, config.caps)
  |> result.map_error(fn(error) { Extract(archive.describe(error)) })
}

// The tree as text. A file whose bytes are not UTF-8 is dropped rather
// than refused: it cannot be a Gleam module, a manifest or a schema, and
// the layout check in `vet_package` is what decides whether a file that
// is none of those may be here at all.
fn text_files(tree: Tree) -> Result(List(#(String, String)), Failure) {
  Ok(
    list.filter_map(tree.files, fn(file) {
      use text <- result.map(bit_array.to_string(file.bytes))
      #(file.path, text)
    }),
  )
}

// --- step 2: the manifest -------------------------------------------------

fn read_manifest(files: List(#(String, String))) -> Result(Manifest, Failure) {
  use text <- result.try(
    list.key_find(files, manifest_file)
    |> result.map_error(fn(_nil) {
      Manifest("the tree holds no " <> manifest_file)
    }),
  )
  use decoded <- result.try(
    manifest.decode(text, surroundings(files)) |> result.map_error(Manifest),
  )
  case decoded.hooks {
    [] -> Ok(decoded)

    // Decoded, then refused. The vocabulary is fixed by the ruling and an
    // author's event name is worth checking, but the harness cannot call
    // into a satellite until phase 3 adds the reverse frame — so an
    // extension carrying a hook would install and never fire it.
    [_, ..] ->
      Error(Manifest(
        "this extension registers a [[hook]]; hooks arrive in phase 3, when "
        <> "the harness can call into a satellite",
      ))
  }
}

const manifest_file = "extension.toml"

fn surroundings(files: List(#(String, String))) -> manifest.Surroundings {
  manifest.Surroundings(files:, modules: module_names(files))
}

fn module_names(files: List(#(String, String))) -> List(String) {
  files
  |> list.map(fn(file) { file.0 })
  |> list.filter(fn(path) {
    string.starts_with(path, package.source_directory)
    && string.ends_with(path, ".gleam")
  })
  |> list.map(module_of)
}

fn module_of(path: String) -> String {
  path
  |> string.drop_start(string.length(package.source_directory))
  |> string.drop_end(string.length(".gleam"))
}

// --- step 3: vetting ------------------------------------------------------

fn vet_source(
  files: List(#(String, String)),
) -> Result(VettedPackage, Failure) {
  package.vet_package(files, vet_policy.for_seam(vet_policy.ExtensionSeam))
  |> result.map_error(Vetting)
}

// --- steps 4 to 6: staging, the build, the record -------------------------

// Everything from here writes to disk, so it all happens under one
// staging directory that is removed on every path out but the last.
fn stage(
  config: Config,
  from: Source,
  rev: Option(String),
  tree: Tree,
  decoded: Manifest,
  vetted: VettedPackage,
) -> Result(Installed, Failure) {
  let staging = record.staging(config.root, token(config))
  case build_and_record(config, from, rev, tree, decoded, vetted, staging) {
    Ok(installed) -> Ok(installed)
    Error(failure) -> {
      let _removed = simplifile.delete_all([staging])
      Error(failure)
    }
  }
}

fn build_and_record(
  config: Config,
  from: Source,
  rev: Option(String),
  tree: Tree,
  decoded: Manifest,
  vetted: VettedPackage,
  staging: String,
) -> Result(Installed, Failure) {
  use Nil <- result.try(fresh(staging))
  use Nil <- result.try(write_tree(
    staging <> "/" <> record.source_directory,
    tree,
  ))
  use artifact <- result.try(compiled(config, decoded, vetted, staging))
  let written =
    record.for_install(
      decoded,
      from:,
      revision: revision(tree, rev),
      tree_digest: archive.digest(tree),
      manifest_hash: artifact.manifest_hash,
      allowlist: allowlist(),
      approved_at: now(config),
      approved_by: config.approved_by,
      artifact: record.artifact_directory,
    )
  use Nil <- result.try(write_record(staging, written))
  use directory <- result.try(promote(config.root, decoded.name, staging))
  Ok(Installed(record: written, manifest: decoded, directory:))
}

// The revision the record pins. An archive that carried one wins; a
// `--rev` the operator gave is next; a local path has neither and says
// so, because "local" is a fact about the install rather than a missing
// value.
fn revision(tree: Tree, rev: Option(String)) -> String {
  case tree.commit, rev {
    Some(commit), _ -> commit
    None, Some(named) -> named
    None, None -> record.local_revision
  }
}

fn compiled(
  config: Config,
  decoded: Manifest,
  vetted: VettedPackage,
  staging: String,
) -> Result(compile.Artifact, Failure) {
  let build_root = staging <> "/build"
  use Nil <- result.try(prepare_build(build_root, decoded, vetted))
  let compile.Built(result: built, enforcement: _) = config.build(build_root)
  use products <- result.try(
    result.map_error(built, fn(error) { Compile(compile_reason(error)) }),
  )
  use Nil <- result.try(copy_artifact(
    products.beam_dir,
    staging <> "/" <> record.artifact_directory,
  ))
  Ok(compile.Artifact(
    build_root:,
    beam_dir: staging <> "/" <> record.artifact_directory,
    entry_module: compile.entry_module,
    manifest_hash: products.manifest_hash,
  ))
}

// The build root: the vetted modules under their own names, the generated
// entry beside them, and a `gleam.toml` that pins exactly what every
// hermetic build pins. The extension's own project file is not copied —
// that is what makes a dependency it named unable to enter the build.
fn prepare_build(
  build_root: String,
  decoded: Manifest,
  vetted: VettedPackage,
) -> Result(Nil, Failure) {
  use Nil <- result.try(fresh(build_root <> "/src"))
  use Nil <- result.try(fresh(build_root <> "/tmp"))
  use Nil <- result.try(
    list.try_each(package.modules(vetted), fn(module) {
      write(
        build_root <> "/src/" <> module.0 <> ".gleam",
        vet.vetted_source(module.1),
      )
    }),
  )
  use Nil <- result.try(write(
    build_root <> "/src/" <> compile.entry_module <> ".gleam",
    entry_source(decoded.tools),
  ))
  write(
    build_root <> "/gleam.toml",
    compile.project_toml(compile.default_dependencies()),
  )
}

/// The generated satellite entry module for a manifest's tools.
///
/// Public so a test can read it rather than infer it from a build
/// failure: the aliases are positional, and that is the property worth
/// pinning — two entry modules whose last segment matches would otherwise
/// collide, and the collision would surface as a confusing compile error
/// in generated code.
///
/// ## Examples
///
/// ```gleam
/// assert string.contains(install.entry_source(tools), "runtime.serve")
/// ```
///
pub fn entry_source(tools: List(manifest.Tool)) -> String {
  // Aliased per distinct *module*, not per tool: two tools may share one
  // entry module, and importing it twice is a compile error in generated
  // code — the worst place for one, since nobody wrote the file.
  let aliases =
    tools
    |> list.map(fn(tool) { tool.entry })
    |> list.unique
    |> list.index_map(fn(module, index) { #(module, alias(index)) })
  let imports =
    list.map(aliases, fn(entry) { "import " <> entry.0 <> " as " <> entry.1 })
  let served =
    list.map(tools, fn(tool) {
      "    #(\""
      <> tool.name
      <> "\", "
      <> named_alias(aliases, tool.entry)
      <> "."
      <> entry_function
      <> "),"
    })
  "//// Generated by client/extension/install. Do not edit.\n"
  <> "//// The extension satellite's entry: serve this manifest's tools.\n\n"
  <> "import ext/runtime\n"
  <> string.join(list.sort(imports, string.compare), "\n")
  <> "\n\npub fn main() -> Nil {\n"
  <> "  runtime.serve([\n"
  <> string.join(served, "\n")
  <> "\n  ])\n}\n"
}

// The install's one timestamp. `clock.read` hands back an advanced clock
// the caller is meant to thread; an install reads the wall exactly once,
// so the successor is deliberately dropped here rather than plumbed
// through six functions that have nothing to say about time.
fn now(config: Config) -> Int {
  let #(at_ms, _advanced) = clock.read(config.clock)
  at_ms
}

// Unreachable with a name that is not in the table: the table is built
// from these very tools. The fallback is the module's own name, which is
// what an unaliased import would have been.
fn named_alias(aliases: List(#(String, String)), module: String) -> String {
  result.unwrap(list.key_find(aliases, module), module)
}

fn alias(index: Int) -> String {
  "ext_entry_" <> int.to_string(index)
}

fn compile_reason(error: compile.CompileError) -> String {
  case error {
    compile.WorkspaceSetupFailed(reason:) -> reason
    compile.BuildRejected(diagnostics:) ->
      "the jailed build refused the extension's source: " <> diagnostics
    compile.BuildUnavailable(reason:) -> reason
    compile.ArtifactIncomplete(reason:) -> reason
  }
}

// --- the filesystem -------------------------------------------------------

// The *whole* tree, bytes and all, not just the files that decoded as
// text. The record's digest is over every file the source held, and
// `installed.discover` re-digests what was written — so dropping a byte
// here would make every install refuse itself at the next load.
fn write_tree(into: String, tree: Tree) -> Result(Nil, Failure) {
  list.try_each(tree.files, fn(file) {
    write_bytes(into <> "/" <> file.path, file.bytes)
  })
}

fn write_record(staging: String, written: Record) -> Result(Nil, Failure) {
  write(
    staging <> "/" <> record.record_file,
    json.to_string(record.encode(written)),
  )
}

// The one step that is not undoable, and it is last. A name already
// taken is a refusal rather than an overwrite: replacing an install is
// `remove` then `install`, so an operator never loses a working
// extension to a failed reinstall.
fn promote(
  root: Root,
  name: String,
  staging: String,
) -> Result(String, Failure) {
  let destination = record.directory(root, name)
  case simplifile.is_directory(destination) {
    Ok(True) ->
      Error(Record(
        name <> " is already installed; `loom ext remove " <> name <> "` first",
      ))
    _ ->
      simplifile.rename(at: staging, to: destination)
      |> result.replace(destination)
      |> result.map_error(fn(error) {
        Record(
          "could not move the staged install into place: "
          <> simplifile.describe_error(error),
        )
      })
  }
}

fn copy_artifact(beam_dir: String, into: String) -> Result(Nil, Failure) {
  use Nil <- result.try(fresh(into))
  simplifile.copy_directory(at: beam_dir, to: into)
  |> result.map_error(fn(error) {
    Compile(
      "the compiled artifact could not be copied: "
      <> simplifile.describe_error(error),
    )
  })
}

fn fresh(directory: String) -> Result(Nil, Failure) {
  simplifile.create_directory_all(directory)
  |> result.map_error(fn(error) {
    Record(
      "could not create "
      <> directory
      <> ": "
      <> simplifile.describe_error(error),
    )
  })
}

fn write_bytes(path: String, bytes: BitArray) -> Result(Nil, Failure) {
  use Nil <- result.try(fresh(directory_of(path)))
  simplifile.write_bits(to: path, bits: bytes)
  |> result.map_error(fn(error) {
    Record(
      "could not write " <> path <> ": " <> simplifile.describe_error(error),
    )
  })
}

fn write(path: String, contents: String) -> Result(Nil, Failure) {
  use Nil <- result.try(fresh(directory_of(path)))
  simplifile.write(to: path, contents: contents)
  |> result.map_error(fn(error) {
    Record(
      "could not write " <> path <> ": " <> simplifile.describe_error(error),
    )
  })
}

fn directory_of(path: String) -> String {
  case string.split(path, "/") {
    [] -> "."
    parts ->
      parts
      |> list.take(list.length(parts) - 1)
      |> string.join("/")
  }
}

// A staging name nobody can predict and nothing collides with. Two draws
// rather than one because the seam behind it mixes a monotonic counter
// with randomness, and a single draw of it is unique but not
// unguessable; the staging root is a shared directory under the
// operator's home, so both properties are wanted.
fn token(config: Config) -> String {
  int.to_base16(int.absolute_value(config.entropy()))
  <> int.to_base16(int.absolute_value(config.entropy()))
}
