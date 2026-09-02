//// Reading the extensions root back: what is installed, and whether it
//// is still what was approved.
////
//// An install record is a claim about a directory. This module is the
//// part that checks the claim, every time, rather than trusting a file
//// the operator approved once and nothing has watched since. Four things
//// are re-derived from what is actually on disk and compared with the
//// record:
////
//// - the **tree digest**, so a byte edited under `src/` refuses the
////   extension rather than being compiled into the next dispatch;
//// - the **manifest**, so an `extension.toml` that stopped decoding —
////   or started naming a schema that is not there — is caught before a
////   tool is registered from it;
//// - the **vetting**, so a file that stops passing refuses the whole
////   extension in band naming the rejection, which is what the ruling
////   asks for ("vetting runs … at install and again at every load");
//// - the **allowlist**, so a seam that has widened since the approval
////   shows up as a record that no longer matches, and an operator is
////   asked rather than quietly given more.
////
//// # Refused is a value, not an absence
////
//// `discover` returns a `Refused` for an extension it will not load, not
//// a shorter list. An operator who installed something and then sees
//// nothing has no way to tell "it is broken" from "I imagined installing
//// it", and the difference is exactly what they need. Phase 2 registers
//// tools from the `Ready` ones and logs the rest.

import client/extension/archive
import client/extension/install
import client/extension/manifest.{type Manifest}
import client/extension/record.{type Record, type Root}
import codemode/vet/package
import codemode/vet/policy as vet_policy
import gleam/bit_array
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// One entry in the extensions root.
pub type Discovered {
  /// The record decoded, the tree still matches it, and every file still
  /// vets. Phase 2 registers this one's tools.
  Ready(record: Record, manifest: Manifest, artifact: String)

  /// Something did not hold. The name comes from the directory, because
  /// the record may be the thing that failed to decode.
  Refused(name: String, reason: String)
}

/// Everything under the root, in name order.
///
/// Total: an unreadable root is an empty list rather than a failure,
/// because "no extensions are installed" and "the directory does not
/// exist yet" are the same fact to a server booting.
///
/// ## Examples
///
/// ```gleam
/// assert installed.discover(record.root_at("/nowhere")) == []
/// ```
///
pub fn discover(root: Root) -> List(Discovered) {
  case simplifile.read_directory(at: record.path(root)) {
    Error(_absent) -> []
    Ok(entries) ->
      entries
      |> list.filter(fn(name) { name != record.staging_directory })
      |> list.sort(string.compare)
      |> list.map(fn(name) { one(root, name) })
  }
}

/// One extension, checked the same way `discover` checks each of them.
/// What `loom ext verify` prints.
///
/// ## Examples
///
/// ```gleam
/// let assert installed.Ready(..) = installed.one(root, "weather")
/// ```
///
pub fn one(root: Root, name: String) -> Discovered {
  case check(root, name) {
    Ok(ready) -> ready
    Error(reason) -> Refused(name:, reason:)
  }
}

/// Removes an installed extension, record and all.
///
/// ## Examples
///
/// ```gleam
/// assert installed.remove(root, "weather") == Ok(Nil)
/// ```
///
pub fn remove(root: Root, name: String) -> Result(Nil, String) {
  let directory = record.directory(root, name)
  case simplifile.is_directory(directory) {
    Ok(True) ->
      simplifile.delete(directory)
      |> result.map_error(fn(error) {
        "could not remove "
        <> directory
        <> ": "
        <> simplifile.describe_error(error)
      })
    _ -> Error(name <> " is not installed")
  }
}

/// The one-line summary `loom ext list` prints per entry.
///
/// ## Examples
///
/// ```gleam
/// assert installed.summarise(installed.Refused("w", "gone"))
///   == "w  REFUSED  gone"
/// ```
///
pub fn summarise(discovered: Discovered) -> String {
  case discovered {
    Ready(record: written, manifest: decoded, artifact: _) ->
      written.name
      <> "  "
      <> written.version
      <> "  "
      <> written.revision
      <> "  tools: "
      <> string.join(list.map(decoded.tools, fn(tool) { tool.name }), ", ")
    Refused(name:, reason:) -> name <> "  REFUSED  " <> reason
  }
}

// --- the four checks ------------------------------------------------------

fn check(root: Root, name: String) -> Result(Discovered, String) {
  use text <- result.try(
    simplifile.read(from: record.file(root, name))
    |> result.map_error(fn(error) {
      "no install record: " <> simplifile.describe_error(error)
    }),
  )
  use written <- result.try(result.try(record.decode(text), record.current))
  use Nil <- result.try(named(written, name))
  use tree <- result.try(read_tree(root, name))
  use Nil <- result.try(digest_matches(tree, written))
  let files = text_of(tree)
  use decoded <- result.try(remanifest(files))
  use Nil <- result.try(revet(files))
  use Nil <- result.try(allowlist_matches(written))
  Ok(Ready(
    record: written,
    manifest: decoded,
    artifact: record.directory(root, name) <> "/" <> record.artifact_directory,
  ))
}

// The directory name is the extension's identity on disk, so a record
// naming something else is a record that was moved — which would let one
// approval stand in for another.
fn named(written: Record, name: String) -> Result(Nil, String) {
  case written.name == name {
    True -> Ok(Nil)
    False ->
      Error(
        "the install record names " <> written.name <> " but sits in " <> name,
      )
  }
}

// Read once. The digest and the re-vet are two questions about the same
// bytes, and reading the tree twice would let them disagree.
fn read_tree(root: Root, name: String) -> Result(archive.Tree, String) {
  archive.from_directory(record.sources(root, name), archive.default_caps())
  |> result.map_error(fn(error) {
    "the installed source is unreadable: " <> archive.describe(error)
  })
}

// A file whose bytes are not UTF-8 is dropped rather than refused here,
// for the reason the install drops one: it cannot be a module, a manifest
// or a schema, and the layout rule in `vet_package` is what decides
// whether it may be in the tree at all.
fn text_of(tree: archive.Tree) -> List(#(String, String)) {
  list.filter_map(tree.files, fn(file) {
    use text <- result.map(bit_array.to_string(file.bytes))
    #(file.path, text)
  })
}

fn digest_matches(tree: archive.Tree, written: Record) -> Result(Nil, String) {
  case archive.digest(tree) == written.tree_digest {
    True -> Ok(Nil)
    False ->
      Error(
        "the installed source no longer matches the install record; "
        <> "reinstall it to approve what is there now",
      )
  }
}

fn remanifest(files: List(#(String, String))) -> Result(Manifest, String) {
  use text <- result.try(
    list.key_find(files, "extension.toml")
    |> result.map_error(fn(_nil) {
      "the installed source holds no extension.toml"
    }),
  )
  manifest.decode(text, manifest.Surroundings(files:, modules: modules(files)))
}

fn modules(files: List(#(String, String))) -> List(String) {
  files
  |> list.map(fn(file) { file.0 })
  |> list.filter(fn(path) {
    string.starts_with(path, package.source_directory)
    && string.ends_with(path, ".gleam")
  })
  |> list.map(fn(path) {
    path
    |> string.drop_start(string.length(package.source_directory))
    |> string.drop_end(string.length(".gleam"))
  })
}

fn revet(files: List(#(String, String))) -> Result(Nil, String) {
  package.vet_package(files, vet_policy.for_seam(vet_policy.ExtensionSeam))
  |> result.replace(Nil)
  |> result.map_error(fn(refusals) {
    "vetting refuses it now: "
    <> string.join(install.refusal_lines(refusals), "; ")
  })
}

// The seam the approval was given against, compared with the seam this
// server has. A widened seam is not a reason to refuse silently *or* to
// widen an old approval: it is a question, and this is where it gets
// asked.
fn allowlist_matches(written: Record) -> Result(Nil, String) {
  case list.sort(written.allowlist, string.compare) == current_allowlist() {
    True -> Ok(Nil)
    False ->
      Error(
        "this server's extension seam differs from the one this extension "
        <> "was approved against; reinstall it to approve the current seam",
      )
  }
}

fn current_allowlist() -> List(String) {
  list.sort(install.allowlist(), string.compare)
}
