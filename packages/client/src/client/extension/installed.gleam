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
//// # A profile extension is checked for what it has
////
//// A `tier = "profile"` extension (ADR-014 §3) has no source to vet, no
//// seam it was vetted against and no artifact, so its load skips those
//// three and asks one question in their place: do the manifest's
//// language profiles still equal the ones the record approved? The
//// record, the directory's name, the tree digest and the re-decoded
//// manifest are checked first exactly as for a jailed extension, and the
//// manifest must name the tier the record approved, so a record edited to
//// say "profile" cannot talk a jailed tree out of its vetting.
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
  /// vets, or for a profile extension its profiles still match the
  /// record's. Phase 2 registers a jailed one's tools; a profile's servers
  /// join the session's language servers. `artifact` is the compiled beam
  /// set's directory, and empty for a profile extension, which has none.
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
  case verified(root, name) {
    Ok(Verified(record: written, manifest: decoded, artifact:, tree: _)) ->
      Ready(record: written, manifest: decoded, artifact:)
    Error(reason) -> Refused(name:, reason:)
  }
}

/// One extension that passed every check `one` makes, with the tree those
/// checks read.
pub type Verified {
  Verified(
    /// The install record, as `Ready` carries it.
    record: Record,
    /// The manifest, decoded again from `tree`.
    manifest: Manifest,
    /// The compiled beam set's directory, empty for a profile extension.
    artifact: String,
    /// The installed source exactly as it was read: every file, its bytes,
    /// and nothing that was not there when the digest was computed over it.
    tree: archive.Tree,
  )
}

/// One extension checked exactly as `one` checks it, answered with the
/// tree the digest was verified over, or the reason it was refused.
///
/// For a caller that goes on to use the installed files. `loom ext check`
/// writes a fixture out of this tree rather than copying it from disk
/// again: a second read would follow whatever a link planted since the
/// check pointed at, and would run the server over files no digest
/// covered.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(installed.Verified(tree:, ..)) = installed.verified(root, "lsp_go")
/// ```
///
pub fn verified(root: Root, name: String) -> Result(Verified, String) {
  use Nil <- result.try(named_extension(name))
  check(root, name)
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

/// The one-line summary `loom ext list` prints per entry: a jailed
/// extension's tools, or a profile extension's servers each with the
/// file extensions it claims.
///
/// ## Examples
///
/// ```gleam
/// assert installed.summarise(installed.Refused("w", "gone"))
///   == "w  REFUSED  gone"
/// ```
///
/// ```gleam
/// installed.summarise(profile_extension)
/// // -> "lsp_go  0.1.0  local  lsp: go (.go)"
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
      <> "  "
      <> contents(decoded)
    Refused(name:, reason:) -> name <> "  REFUSED  " <> reason
  }
}

fn contents(decoded: Manifest) -> String {
  case decoded.tier {
    manifest.Jailed ->
      "tools: "
      <> string.join(list.map(decoded.tools, fn(tool) { tool.name }), ", ")
    manifest.Profile ->
      "lsp: "
      <> string.join(
        list.map(decoded.lsp, fn(server) {
          server.name <> " (" <> string.join(server.extensions, ", ") <> ")"
        }),
        ", ",
      )
  }
}

// --- the four checks ------------------------------------------------------

fn check(root: Root, name: String) -> Result(Verified, String) {
  use text <- result.try(
    simplifile.read(from: record.file(root, name))
    |> result.map_error(fn(error) {
      "no install record: " <> simplifile.describe_error(error)
    }),
  )
  use written <- result.try(record.readable(text))
  use Nil <- result.try(named(written, name))
  use tree <- result.try(read_tree(root, name))
  use Nil <- result.try(digest_matches(tree, written))
  use files <- result.try(text_of(tree))
  use decoded <- result.try(remanifest(files))
  use Nil <- result.try(tier_matches(decoded, written))
  use artifact <- result.try(case written.tier {
    manifest.Jailed -> jailed(root, name, written, files)
    manifest.Profile -> profiled(written, decoded)
  })
  Ok(Verified(record: written, manifest: decoded, artifact:, tree:))
}

// The jailed tier's last three checks: the source still vets, the seam
// is the one approved, and the bytes that run are the ones built. Answers
// the artifact's directory.
fn jailed(
  root: Root,
  name: String,
  written: Record,
  files: List(#(String, String)),
) -> Result(String, String) {
  use Nil <- result.try(revet(files))
  use Nil <- result.try(allowlist_matches(written))
  let artifact = record.artifact_at(root, name)
  use Nil <- result.try(artifact_matches(artifact, written))
  Ok(artifact)
}

// A profile's approval is its profiles, so the one check left is that
// the manifest still says what the record approved. The digest already
// refuses an edited manifest; this refuses the other half, a record whose
// profiles were edited to grant something the manifest never asked for. A
// profile has no artifact, so the directory answered is empty.
fn profiled(written: Record, decoded: Manifest) -> Result(String, String) {
  case decoded.lsp == written.lsp {
    True -> Ok("")
    False ->
      Error(
        "the manifest's language profiles no longer match the install "
        <> "record; reinstall it to approve what is there now",
      )
  }
}

// The tier decides which checks run, so it has to be the one the tree
// itself declares. Without this, a record edited to say `profile` would
// skip the vetting and the artifact check of a tree that is jailed code.
fn tier_matches(decoded: Manifest, written: Record) -> Result(Nil, String) {
  case decoded.tier == written.tier {
    True -> Ok(Nil)
    False ->
      Error(
        "the manifest's tier no longer matches the install record; "
        <> "reinstall it to approve what is there now",
      )
  }
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
