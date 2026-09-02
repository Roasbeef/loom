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
//// - the **artifact's content address**, recomputed over the beam set on
////   disk with the very function the build used, so a swapped or deleted
////   `.beam` refuses the extension too. Re-vetting the source proves
////   nothing about the bytes that actually run, and the artifact is the
////   half a dispatch loads;
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
//// # Nothing is pruned here, and that is the point
////
//// The install prunes a repository down to the extension's own tree
//// (`codemode/vet/package.installed_subset`) and writes exactly that. So
//// what sits under `<name>/src/` *is* the installed tree, and this side
//// reads all of it: a file dropped in afterwards changes the digest and
//// refuses the extension, which is the whole guarantee. Pruning again at
//// load would quietly forgive exactly the tampering the digest exists to
//// catch.
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
import codemode/build
import codemode/compile
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
      |> list.filter(manifest.is_legal_name)
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
  case named_extension(name) {
    Error(reason) -> Refused(name:, reason:)
    Ok(Nil) ->
      case check(root, name) {
        Ok(ready) -> ready
        Error(reason) -> Refused(name:, reason:)
      }
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
  use Nil <- result.try(named_extension(name))
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

    // Not there, or there and not a directory. Either way there is
    // nothing here this verb owns.
    Ok(False) | Error(_absent) -> Error(name <> " is not installed")
  }
}

/// Whether a name may be joined to the root as a directory component.
///
/// Every verb that takes a name from an operator goes through this, and
/// the reason is a delete: `record.directory` is string concatenation, so
/// `remove ..` would name the `.loom` directory itself and
/// `simplifile.delete` would take it. The manifest's own grammar
/// (`[a-z][a-z0-9_]*`) admits no `.`, no `/` and no `..`, so gating on it
/// makes a traversal unrepresentable rather than something the joiner has
/// to defend against — and it is the same grammar the install accepted
/// the name under, so a name this refuses is a name nothing could have
/// installed.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(_) = installed.named_extension("..")
/// assert installed.named_extension("weather") == Ok(Nil)
/// ```
///
pub fn named_extension(name: String) -> Result(Nil, String) {
  case manifest.is_legal_name(name) {
    True -> Ok(Nil)
    False ->
      Error(
        "`"
        <> name
        <> "` is not an extension name; a name is [a-z][a-z0-9_]*, which is "
        <> "what an install accepted it under",
      )
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
  use files <- result.try(text_of(tree))
  use decoded <- result.try(remanifest(files))
  use Nil <- result.try(revet(files))
  use Nil <- result.try(allowlist_matches(written))
  let artifact = record.artifact_at(root, name)
  use Nil <- result.try(artifact_matches(artifact, written))
  Ok(Ready(record: written, manifest: decoded, artifact:))
}

// The bytes that actually run. Re-vetting the source says nothing about
// them: an artifact is copied into place beside the source and a dispatch
// loads the artifact, so a swapped `.beam` would sail past every other
// check here. Recomputed with `build.fingerprint_directory`, the same
// function the build used, so the two cannot drift into disagreeing about
// what the address is.
fn artifact_matches(artifact: String, written: Record) -> Result(Nil, String) {
  use Nil <- result.try(
    case
      simplifile.is_file(artifact <> "/" <> compile.entry_module <> ".beam")
    {
      Ok(True) -> Ok(Nil)
      Ok(False) | Error(_absent) ->
        Error(
          "the installed artifact holds no "
          <> compile.entry_module
          <> ".beam, so there is nothing to run",
        )
    },
  )
  use address <- result.try(
    build.fingerprint_directory(artifact)
    |> result.map_error(fn(_error) {
      "the installed artifact is unreadable at " <> artifact
    }),
  )
  case address == written.manifest_hash {
    True -> Ok(Nil)
    False ->
      Error(
        "the installed artifact no longer matches the install record; "
        <> "reinstall it to approve what is there now",
      )
  }
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

// Every file, or a refusal naming the one that is not text. Dropping a
// file here would mean it reached the tree without being vetted and
// without being refused — the exact hole the install's own reader closes,
// and it has to be closed identically on both sides or a tree that
// installed would refuse itself at the next load.
fn text_of(tree: archive.Tree) -> Result(List(#(String, String)), String) {
  list.try_map(tree.files, fn(file) {
    case bit_array.to_string(file.bytes) {
      Ok(text) -> Ok(#(file.path, text))
      Error(Nil) ->
        Error(
          "the installed source holds "
          <> file.path
          <> ", which is not UTF-8 text",
        )
    }
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
  manifest.decode(
    text,
    manifest.Surroundings(files:, modules: package.module_names_of(files)),
  )
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
