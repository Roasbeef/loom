//// An extension's tree, however it arrived, and the digest that pins it.
////
//// **Placeholder.** This module is the seam the install pipeline is
//// written against; the branch that owns it (`ext/archive`) replaces the
//// whole file with the real total extractor. The signatures here are the
//// agreed ones, so a merge is a wholesale replacement rather than a
//// reconciliation. `from_directory` and `digest` are real, because the
//// local-path install path uses them; `extract` refuses, naming itself.
////
//// # Why a tree is a value
////
//// An archive is untrusted input that arrived over the network, so the
//// pipeline never hands a path to a tar program and looks at the
//// filesystem afterwards. It gets a `Tree`: a list of regular files with
//// their bytes, under one root, with no symlink, no hard link, no device
//// and no `..` in any name — because those are not *files*, and a value
//// that cannot represent them is a whole class of extraction bug the rest
//// of the pipeline never has to think about.
////
//// # Why the digest is over the tree
////
//// The install record stores a digest of the *extracted* tree, not of the
//// archive bytes. Two archives of the same tree — a re-tarred release, a
//// different gzip level, GitHub's own repacking — are the same extension,
//// and an extension is refused at load when its tree stops matching. A
//// digest over the bytes would refuse a reinstall that changed nothing
//// and would say nothing about what is on disk, which is what a load
//// actually reads.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None}
import gleam/order
import gleam/result
import gleam/string
import simplifile
import tools/blob

/// What an extraction is allowed to produce. Every bound is present
/// because the input is hostile: an archive that declares a petabyte, or
/// a hundred thousand entries, must be refused before it is read rather
/// than after.
pub type Caps {
  Caps(
    /// The largest single file, in bytes.
    max_file_bytes: Int,
    /// The largest tree, summed over every file.
    max_total_bytes: Int,
    /// The most files a tree may hold.
    max_entries: Int,
  )
}

/// One regular file. `path` is relative to the tree's root and holds no
/// `..` segment, no leading `/`, and no control character.
pub type File {
  File(path: String, bytes: BitArray)
}

/// An extension's whole tree.
pub type Tree {
  Tree(
    /// The single top-level directory the archive unpacked into, or the
    /// directory a local source was copied from.
    root: String,
    /// Every regular file, sorted by path.
    files: List(File),
    /// The revision the host resolved, when the source named one.
    commit: Option(String),
  )
}

/// Why a tree could not be produced.
pub type ArchiveError {
  /// The bytes were not a readable gzipped tar.
  Unreadable(reason: String)

  /// An entry was something other than a regular file or a directory, or
  /// its name escaped the root.
  EntryRefused(path: String, reason: String)

  /// A cap was exceeded.
  TooLarge(reason: String)

  /// A local source could not be read.
  Unreachable(reason: String)

  /// The archive path is not implemented in this build.
  NotWired(reason: String)
}

/// The caps an install uses: 8 MiB per file, 32 MiB per tree, 4096
/// entries. An extension is source, a JSON schema or two and a README;
/// anything at these bounds is not one.
///
/// ## Examples
///
/// ```gleam
/// assert archive.default_caps().max_total_bytes == 33_554_432
/// ```
///
pub fn default_caps() -> Caps {
  Caps(
    max_file_bytes: 8_388_608,
    max_total_bytes: 33_554_432,
    max_entries: 4096,
  )
}

/// Extracts a gzipped tarball into a tree.
///
/// Not implemented in this build: the total extractor lands with the
/// branch that owns this module. Until then a URL source is refused here
/// rather than half-extracted, which is the one honest answer available.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(archive.NotWired(_)) =
///   archive.extract(<<31, 139>>, archive.default_caps())
/// ```
///
pub fn extract(gzipped: BitArray, caps: Caps) -> Result(Tree, ArchiveError) {
  let _ignored = #(bit_array.byte_size(gzipped), caps.max_entries)
  Error(NotWired(
    reason: "archive extraction is not wired in this build; install from a "
    <> "local path, or rebuild with the extension archive support",
  ))
}

/// Reads a directory on this host into a tree.
///
/// The same caps apply as to an archive. A local path is *not* trusted
/// merely for being local: an operator installing a directory somebody
/// sent them is the ordinary case, and the bounds are what stop a
/// mistyped path from reading a home directory into memory.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(tree) = archive.from_directory("./weather", caps)
/// assert tree.commit == option.None
/// ```
///
pub fn from_directory(path: String, caps: Caps) -> Result(Tree, ArchiveError) {
  use entries <- result.try(
    simplifile.get_files(in: path)
    |> result.map_error(fn(error) {
      Unreachable(
        reason: "could not read "
        <> path
        <> ": "
        <> simplifile.describe_error(error),
      )
    }),
  )
  let root = trim_trailing_slash(path)
  use bounded <- result.try(within_entry_cap(entries, caps))
  use files <- result.try(
    list.try_map(bounded, fn(entry) { read(root, entry, caps) }),
  )
  use _total <- result.try(within_total_cap(files, caps))
  Ok(Tree(root:, files: sorted(files), commit: None))
}

/// A content address over a whole tree: every file's path and the hash of
/// its bytes, sorted, hashed again.
///
/// Path *and* bytes, because a tree where two files swapped names is a
/// different tree, and a digest over the bytes alone would call them
/// equal.
///
/// ## Examples
///
/// ```gleam
/// assert archive.digest(tree) == archive.digest(tree)
/// ```
///
pub fn digest(tree: Tree) -> String {
  tree.files
  |> sorted
  |> list.map(fn(file) { file.path <> " " <> blob.ref_for(file.bytes) })
  |> string.join("\n")
  |> bit_array.from_string
  |> blob.ref_for
}

/// Renders an extraction failure for an operator.
///
/// ## Examples
///
/// ```gleam
/// assert archive.describe(archive.TooLarge("too big")) == "too big"
/// ```
///
pub fn describe(error: ArchiveError) -> String {
  case error {
    Unreadable(reason:) -> reason
    EntryRefused(path:, reason:) -> path <> ": " <> reason
    TooLarge(reason:) -> reason
    Unreachable(reason:) -> reason
    NotWired(reason:) -> reason
  }
}

// --- reading a local directory --------------------------------------------

// `simplifile.get_files` returns host paths; the tree speaks paths
// relative to its root, because that is what the manifest, the vetter and
// the digest all name a file by.
fn relative_to(root: String, entry: String) -> Result(String, ArchiveError) {
  let prefix = root <> "/"
  case string.starts_with(entry, prefix) {
    True -> Ok(string.drop_start(entry, string.length(prefix)))
    False ->
      Error(EntryRefused(
        path: entry,
        reason: "it is not beneath the source directory " <> root,
      ))
  }
}

fn within_entry_cap(
  paths: List(String),
  caps: Caps,
) -> Result(List(String), ArchiveError) {
  case list.length(paths) > caps.max_entries {
    False -> Ok(paths)
    True ->
      Error(TooLarge(
        reason: "the tree holds more than "
        <> int.to_string(caps.max_entries)
        <> " files",
      ))
  }
}

// Reads one file by its host path and names it by its path *relative to
// the root*, which is what the manifest, the vetter and the digest all
// speak. Reading and naming happen together so the two cannot drift.
fn read(root: String, entry: String, caps: Caps) -> Result(File, ArchiveError) {
  use path <- result.try(relative_to(root, entry))
  use bytes <- result.try(
    simplifile.read_bits(from: entry)
    |> result.map_error(fn(error) {
      Unreachable(
        reason: "could not read "
        <> entry
        <> ": "
        <> simplifile.describe_error(error),
      )
    }),
  )
  case bit_array.byte_size(bytes) > caps.max_file_bytes {
    True ->
      Error(TooLarge(
        reason: path
        <> " is larger than "
        <> int.to_string(caps.max_file_bytes)
        <> " bytes",
      ))
    False -> Ok(File(path:, bytes:))
  }
}

fn within_total_cap(
  files: List(File),
  caps: Caps,
) -> Result(Int, ArchiveError) {
  let total =
    list.fold(files, 0, fn(sum, file) { sum + bit_array.byte_size(file.bytes) })
  case total > caps.max_total_bytes {
    False -> Ok(total)
    True ->
      Error(TooLarge(
        reason: "the tree is larger than "
        <> int.to_string(caps.max_total_bytes)
        <> " bytes",
      ))
  }
}

fn sorted(files: List(File)) -> List(File) {
  list.sort(files, fn(left, right) { compare_paths(left.path, right.path) })
}

fn compare_paths(left: String, right: String) -> order.Order {
  string.compare(left, right)
}

fn trim_trailing_slash(path: String) -> String {
  case string.ends_with(path, "/") && string.length(path) > 1 {
    True -> trim_trailing_slash(string.drop_end(path, 1))
    False -> path
  }
}
