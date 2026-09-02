//// The untrusted half of `loom ext install`: a total reader for a
//// gzipped tar, a walker for a local directory held to the same rules,
//// and a content digest over whichever of the two produced the tree.
////
//// ## Why this boundary exists
////
//// `docs/design-notes/extension-architecture.md`, "Hardening the
//// install", makes two rulings this module implements. The first is
//// that **there is no git client**: `git clone` is a large, remotely
//// driven attack surface — a hostile remote chooses the pack, the refs,
//// the attributes and the submodules — and an install needs a tree, not
//// a git session. So a source is a local path, an `https://` URL naming
//// a `.tar.gz`, or a GitHub repository resolved to its archive URL
//// (`client/extension/source` decides which), and what arrives here is
//// a blob of bytes rather than a repository.
////
//// The second is that **the archive is untrusted input**. It arrives
//// over the network, it is read by the operator's own process outside
//// any jail, and it is read *before* anything about it has been vetted.
//// That is why every shape this module cannot understand is a typed
//// refusal rather than a crash, a `let assert`, or a best-effort
//// recovery: the reader is the first thing to touch a hostile file, and
//// the only safe answer to a file it does not understand is to name
//// what it saw and stop. Nothing is written to disk here at all —
//// extraction produces values, and the caller stages them.
////
//// ## What is refused, and why
////
//// A tar can express far more than a source tree needs. Everything
//// beyond a regular file and a directory is refused whole: hard links
//// and symlinks (both escape the extraction root by construction),
//// devices and fifos (nothing an extension needs, and both are a
//// privileged-side hazard), and GNU's long-name extensions (a second
//// name-carrying mechanism is a second chance to disagree with the
//// first, and pax already covers long names). A refusal names the entry
//// and its kind so the operator can see what the archive was trying to
//// do.
////
//// Three caps bound the work before it happens: an entry count, a
//// per-file byte count taken from the header *before* a byte of the
//// body is sliced, and a total byte count that also bounds the
//// inflation itself, so a decompression bomb is abandoned mid-stream
//// rather than materialised and then measured.
////
//// ## The exact path subset
////
//// A path is split on `/` into components, and every component must be
//// non-empty, must not be `.` or `..`, and must consist only of code
//// points in these two ranges:
////
//// - `U+0021`–`U+007E` (printable ASCII), **excluding** `\` (`U+005C`)
////   and excluding the space `U+0020`.
//// - `U+00A0` and above, **excluding** the invisible formatting code
////   points `U+200B`–`U+200F`, `U+2028`, `U+2029`, `U+202A`–`U+202E`,
////   `U+2066`–`U+2069` and `U+FEFF`.
////
//// So a leading `/` is refused (it produces an empty first component),
//// `..` is refused, NUL and every other C0 or C1 control character is
//// refused, and DEL is refused. The two deliberate narrowings past
//// "printable, no controls" are the space and the invisible formatting
//// characters. The space goes because these paths are later handed to a
//// jailed toolchain and to shell-adjacent tooling, and a source tree
//// has no need of one; the bidi and zero-width characters go because
//// they make two different paths render identically to the operator
//// approving the install, which is the whole basis on which the
//// approval is given.
////
//// On top of the per-component rules, an archive must contain exactly
//// one top-level directory with every file beneath it — the shape
//// `git archive` and GitHub's codeload both produce — and no path may
//// appear twice.
////
//// ## What `Tree` means
////
//// `Tree.root` is that single top-level directory, and every
//// `File.path` is relative to it, so the same tree read from an archive
//// and from an unpacked copy of that archive has identical files even
//// though the roots differ. `digest` follows from that: it hashes the
//// files and nothing else, which is what lets an install record be
//// re-verified later against a tree staged under a different name.

import client/internal/ffi_zlib
import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/set.{type Set}
import gleam/string
import simplifile
import tools/blob

/// How much of an archive the reader will look at before refusing it.
///
/// The caps are a budget rather than a description of any real
/// extension: they exist so that a hostile archive costs a bounded
/// amount of work, and the numbers are set where a legitimate source
/// tree is nowhere near them.
pub type Caps {
  Caps(
    /// The largest number of tar entries — regular files, directories
    /// and pax headers alike — the reader will admit.
    max_entries: Int,
    /// The largest a single file may be, judged from its header's size
    /// field before its body is read.
    max_file_bytes: Int,
    /// The largest the extracted tree may be in total. This bounds the
    /// inflation as well, so it is the cap a decompression bomb hits.
    max_total_bytes: Int,
  )
}

/// One regular file of an extracted tree.
pub type File {
  File(
    /// The file's path relative to `Tree.root`, `/`-separated, holding
    /// to the subset this module's documentation states exactly.
    path: String,
    /// The file's contents, exactly as the archive carried them.
    bytes: BitArray,
  )
}

/// An extracted source tree: one top-level directory and the regular
/// files beneath it.
pub type Tree {
  Tree(
    /// The single top-level directory the archive carried, or the name
    /// of the directory `from_directory` walked. It is not part of the
    /// digest.
    root: String,
    /// Every regular file, sorted by path. Directories are not listed
    /// because the paths already imply them; a caller staging the tree
    /// creates the parents it needs.
    files: List(File),
    /// The commit a pax global header named, when the archive carried
    /// one. GitHub's codeload archives put the resolved commit in the
    /// global header's `comment` record, which is what pins an install
    /// whose `--rev` was a branch. It is not part of the digest.
    commit: Option(String),
  )
}

/// Why an archive or a directory was refused.
///
/// Every variant carries what the operator needs to see what the source
/// was trying to do: the entry, the cap, or the byte offset in the
/// inflated stream.
pub type ArchiveError {
  /// The bytes were not a gzip stream zlib would accept.
  NotGzip

  /// The extracted tree, or the inflation producing it, passed
  /// `Caps.max_total_bytes`. A stream that hit this was abandoned
  /// part-way rather than inflated and then measured.
  TotalBytesExceeded(cap: Int)

  /// The archive held more entries than `Caps.max_entries`.
  TooManyEntries(cap: Int)

  /// One file's stated size passed `Caps.max_file_bytes`. The size is
  /// the header's, read before the body was.
  FileTooLarge(path: String, size: Int, cap: Int)

  /// A header field could not be read: a name that is not UTF-8, a size
  /// or mode that is not octal, or a magic that is not `ustar`. `at` is
  /// the header block's byte offset in the inflated stream.
  MalformedHeader(at: Int, field: String)

  /// A header's checksum field did not match the header's bytes, so
  /// something in the block is not what wrote it intended.
  BadChecksum(at: Int, stated: Int, computed: Int)

  /// The stream ran out before the entry at `at` was complete, or it
  /// never reached the pair of zero blocks that ends a tar. A truncated
  /// archive is refused rather than read as far as it goes.
  TruncatedArchive(at: Int)

  /// A pax header's records were not the `"<len> <key>=<value>\n"` form
  /// the format requires.
  MalformedPaxHeader(entry: String)

  /// The archive held an entry that is neither a regular file nor a
  /// directory: a link, a device, a fifo, a GNU long-name extension, or
  /// a typeflag nothing in the format defines.
  UnsupportedEntry(entry: String, kind: String)

  /// A path fell outside the subset this module documents.
  IllegalPath(path: String, reason: String)

  /// The same path appeared twice, so what the tree holds at it would
  /// depend on the order the entries were read in.
  DuplicatePath(path: String)

  /// The archive held more than one top-level directory, so there is no
  /// single root to make paths relative to.
  MultipleRoots(first: String, second: String)

  /// The archive held no entries at all, so there is no root and
  /// nothing to install.
  EmptyArchive

  /// A local source directory could not be walked: it does not exist,
  /// it is not a directory, or a file in it could not be read.
  DirectoryUnreadable(path: String, reason: String)
}

/// The caps an install uses: 4096 entries, 4 MiB per file, 32 MiB
/// extracted.
///
/// The total matches the fetch policy's own 32 MiB response cap from
/// the design note, so an archive that fits through the fetch cannot
/// then fail on a smaller extraction cap for reasons the operator
/// cannot see.
///
/// ## Examples
///
/// ```gleam
/// assert archive.default_caps().max_entries == 4096
/// ```
///
pub fn default_caps() -> Caps {
  Caps(
    max_entries: 4096,
    max_file_bytes: 4 * 1024 * 1024,
    max_total_bytes: 32 * 1024 * 1024,
  )
}

/// Reads a gzipped tar into a tree, refusing anything it does not
/// understand.
///
/// The inflation is bounded by `caps.max_total_bytes` and abandoned the
/// moment it goes over, so a decompression bomb costs the cap and not a
/// byte more. Everything after that is a pure walk of the inflated
/// bytes: nothing is written, nothing is executed, and no path in the
/// archive is ever resolved against the filesystem.
///
/// ## Examples
///
/// ```gleam
/// // archive.extract(<<"not gzip":utf8>>, archive.default_caps())
/// // -> Error(archive.NotGzip)
/// ```
///
pub fn extract(gzipped: BitArray, caps: Caps) -> Result(Tree, ArchiveError) {
  use inflated <- result.try(inflate(gzipped, caps))
  use reading <- result.try(read_entries(inflated, 0, initial(caps)))

  finish(reading.collecting, reading.commit)
}

/// Reads a local directory into a tree, holding it to the same rules an
/// archive is held to.
///
/// A local path is the one source that could carry shapes a tar cannot
/// even express, so the rules are the archive's plus three. A symlink
/// is refused rather than followed, because following one is exactly
/// the escape the archive reader refuses to admit. Anything that is not
/// a regular file or a directory is refused. And any component
/// beginning with `.git` is refused rather than skipped — a source
/// directory is expected to be an export, not a working checkout, and
/// refusing says so where a silent skip would let an operator install a
/// tree whose digest does not describe what they pointed at. Note that
/// this reaches `.github` too.
///
/// `path` must name the directory rather than `.` or `..`, because the
/// last component becomes `Tree.root` and has to be a legal path
/// component like any other.
///
/// ## Examples
///
/// ```gleam
/// // archive.from_directory("/no/such/place", archive.default_caps())
/// // -> Error(archive.DirectoryUnreadable(..))
/// ```
///
pub fn from_directory(path: String, caps: Caps) -> Result(Tree, ArchiveError) {
  let trimmed = trim_trailing_slashes(path)
  let root = last_component(trimmed)

  // The root has to be admitted before the walk so that an unreadable
  // or oddly named directory is one refusal rather than a refusal per
  // file underneath it.
  use state <- result.try(admit_directory(initial(caps), root))
  use state <- result.try(walk_directory(trimmed, root, state))

  finish(state, None)
}

/// The tree's content digest: lowercase hex SHA-256 over a canonical
/// encoding of its files.
///
/// The encoding is a domain tag, then the file count, then for each
/// file its path and its bytes, each length-prefixed as a 64-bit
/// big-endian count:
///
/// ```text
/// "loom-ext-tree-v1" ++ u64(count)
///   ++ for each file: u64(path bytes) ++ path ++ u64(size) ++ bytes
/// ```
///
/// Length prefixes rather than separators, so no path or file content
/// can be crafted to look like a boundary and two different trees
/// cannot encode to the same bytes.
///
/// `Tree.root` and `Tree.commit` are deliberately outside the encoding.
/// That is what makes the digest a statement about the *content* an
/// install carries: the same tree fetched from a codeload URL (rooted
/// at `repo-<sha>`) and copied from a local checkout (rooted at
/// whatever the operator named it) digests identically, so a later load
/// can re-verify a staged tree without knowing where it came from.
///
/// The files are sorted here rather than assumed sorted, so the digest
/// does not depend on a caller having preserved `Tree`'s ordering
/// invariant.
///
/// ## Examples
///
/// ```gleam
/// // string.length(archive.digest(tree)) == 64
/// ```
///
pub fn digest(tree: Tree) -> String {
  let files = list.sort(tree.files, by_path)
  let count = list.length(files)

  let encoded =
    list.map(files, fn(file) {
      let path = bit_array.from_string(file.path)

      bit_array.concat([
        <<bit_array.byte_size(path):size(64)>>,
        path,
        <<bit_array.byte_size(file.bytes):size(64)>>,
        file.bytes,
      ])
    })

  let canonical =
    bit_array.concat([<<digest_tag:utf8>>, <<count:size(64)>>, ..encoded])

  blob.ref_for(canonical)
  |> string.drop_start(string.length(blob_prefix))
}

/// A one-line, operator-facing account of a refusal.
///
/// ## Examples
///
/// ```gleam
/// assert archive.describe(archive.EmptyArchive)
///   == "the archive held no entries at all"
/// ```
///
pub fn describe(error: ArchiveError) -> String {
  case error {
    NotGzip -> "the bytes are not a gzip stream"

    TotalBytesExceeded(cap:) ->
      "the archive extracts to more than the "
      <> int.to_string(cap)
      <> " byte cap on a whole tree"

    TooManyEntries(cap:) ->
      "the archive holds more than the " <> int.to_string(cap) <> " entry cap"

    FileTooLarge(path:, size:, cap:) ->
      "the file "
      <> path
      <> " states a size of "
      <> int.to_string(size)
      <> " bytes, over the per-file cap of "
      <> int.to_string(cap)

    MalformedHeader(at:, field:) ->
      "the tar header at byte "
      <> int.to_string(at)
      <> " has an unreadable "
      <> field
      <> " field"

    BadChecksum(at:, stated:, computed:) ->
      "the tar header at byte "
      <> int.to_string(at)
      <> " states checksum "
      <> int.to_string(stated)
      <> " but its bytes sum to "
      <> int.to_string(computed)

    TruncatedArchive(at:) ->
      "the archive is truncated at byte "
      <> int.to_string(at)
      <> "; it never reaches the two zero blocks that end a tar"

    MalformedPaxHeader(entry:) ->
      "the pax header " <> entry <> " does not hold well-formed records"

    UnsupportedEntry(entry:, kind:) ->
      "the entry " <> entry <> " is " <> kind <> ", which an install refuses"

    IllegalPath(path:, reason:) ->
      "the path " <> path <> " is refused: " <> reason

    DuplicatePath(path:) -> "the path " <> path <> " appears twice"

    MultipleRoots(first:, second:) ->
      "the archive holds more than one top-level directory ("
      <> first
      <> " and "
      <> second
      <> "); an install needs exactly one"

    EmptyArchive -> "the archive held no entries at all"

    DirectoryUnreadable(path:, reason:) ->
      "the directory " <> path <> " could not be read: " <> reason
  }
}

// --- the collector ---------------------------------------------------------
//
// Everything an entry has to satisfy before it joins the tree lives
// here, and both readers push through it. That is deliberate: it is the
// only way "the same confinement rules" can be true of the archive path
// and the local-directory path rather than merely intended of both.

/// The tree being built, and the budget it has left.
type Collecting {
  Collecting(
    caps: Caps,
    root: Option(String),
    entries: Int,
    total: Int,
    seen: Set(String),
    files: List(File),
  )
}

fn initial(caps: Caps) -> Collecting {
  Collecting(
    caps: caps,
    root: None,
    entries: 0,
    total: 0,
    seen: set.new(),
    files: [],
  )
}

/// Charges one entry against the count cap.
fn count_entry(state: Collecting) -> Result(Collecting, ArchiveError) {
  let entries = state.entries + 1

  use <- bool.lazy_guard(when: entries > state.caps.max_entries, return: fn() {
    Error(TooManyEntries(cap: state.caps.max_entries))
  })

  Ok(Collecting(..state, entries:))
}

/// Admits a directory entry: it establishes or confirms the root, and
/// is otherwise dropped, since `File.path` already implies it.
fn admit_directory(
  state: Collecting,
  raw: String,
) -> Result(Collecting, ArchiveError) {
  use state <- result.try(count_entry(state))
  use #(state, _relative) <- result.try(relative_path(state, raw))

  Ok(state)
}

/// Admits a regular file: root, path subset, duplicate and total-bytes
/// cap, in that order.
fn admit_file(
  state: Collecting,
  raw: String,
  bytes: BitArray,
) -> Result(Collecting, ArchiveError) {
  use state <- result.try(count_entry(state))
  use #(state, relative) <- result.try(relative_path(state, raw))

  // An empty relative path means the entry sits at the top level rather
  // than inside the single root directory, which is the one shape the
  // root rule cannot express as a component fault.
  use <- bool.lazy_guard(when: relative == "", return: fn() {
    Error(IllegalPath(
      path: raw,
      reason: "a file at the archive root; every file must live under one top-level directory",
    ))
  })

  use <- bool.lazy_guard(when: set.contains(state.seen, relative), return: fn() {
    Error(DuplicatePath(path: relative))
  })

  let total = state.total + bit_array.byte_size(bytes)

  use <- bool.lazy_guard(when: total > state.caps.max_total_bytes, return: fn() {
    Error(TotalBytesExceeded(cap: state.caps.max_total_bytes))
  })

  Ok(
    Collecting(..state, total:, seen: set.insert(state.seen, relative), files: [
      File(path: relative, bytes:),
      ..state.files
    ]),
  )
}

/// Validates a path, settles the root, and returns the path relative to
/// it.
fn relative_path(
  state: Collecting,
  raw: String,
) -> Result(#(Collecting, String), ArchiveError) {
  use components <- result.try(path_components(raw))

  case components {
    [] ->
      Error(IllegalPath(path: raw, reason: "it names no path component at all"))

    [root, ..rest] -> {
      use state <- result.try(claim_root(state, root))

      Ok(#(state, string.join(rest, "/")))
    }
  }
}

/// The first component of the first entry is the tree's root, and every
/// later entry has to agree with it.
fn claim_root(
  state: Collecting,
  root: String,
) -> Result(Collecting, ArchiveError) {
  case state.root {
    None -> Ok(Collecting(..state, root: Some(root)))

    Some(existing) if existing == root -> Ok(state)

    Some(existing) -> Error(MultipleRoots(first: existing, second: root))
  }
}

/// Splits a path and holds every component to the documented subset.
fn path_components(raw: String) -> Result(List(String), ArchiveError) {
  let components =
    raw
    |> trim_trailing_slashes
    |> string.split("/")

  use <- bool.lazy_guard(when: list.contains(components, ""), return: fn() {
    Error(IllegalPath(
      path: raw,
      reason: "it has an empty component, so it is absolute or holds a doubled separator",
    ))
  })

  use <- bool.lazy_guard(when: list.contains(components, ".."), return: fn() {
    Error(IllegalPath(path: raw, reason: "it climbs out of the tree with .."))
  })

  use <- bool.lazy_guard(when: list.contains(components, "."), return: fn() {
    Error(IllegalPath(path: raw, reason: "it holds a . component"))
  })

  use <- bool.lazy_guard(
    when: !list.all(components, is_legal_component),
    return: fn() {
      Error(IllegalPath(
        path: raw,
        reason: "it holds a character outside the printable subset an install accepts",
      ))
    },
  )

  Ok(components)
}

/// Whether every code point of a component is in the documented subset.
fn is_legal_component(component: String) -> Bool {
  component
  |> string.to_utf_codepoints
  |> list.all(fn(point) {
    is_legal_codepoint(string.utf_codepoint_to_int(point))
  })
}

fn is_legal_codepoint(code: Int) -> Bool {
  let printable_ascii = code >= 0x21 && code <= 0x7E && code != 0x5C
  let beyond_ascii = code >= 0xA0 && !is_invisible_codepoint(code)

  printable_ascii || beyond_ascii
}

/// The zero-width, bidi and byte-order code points, which render as
/// nothing and so let two different paths look identical to the
/// operator approving an install.
fn is_invisible_codepoint(code: Int) -> Bool {
  { code >= 0x200B && code <= 0x200F }
  || { code >= 0x202A && code <= 0x202E }
  || { code >= 0x2066 && code <= 0x2069 }
  || code == 0x2028
  || code == 0x2029
  || code == 0xFEFF
}

/// Turns a finished collection into a tree, or refuses one that never
/// found a root.
fn finish(
  state: Collecting,
  commit: Option(String),
) -> Result(Tree, ArchiveError) {
  case state.root {
    None -> Error(EmptyArchive)

    Some(root) ->
      Ok(Tree(root:, files: list.sort(state.files, by_path), commit:))
  }
}

fn by_path(left: File, right: File) -> order.Order {
  string.compare(left.path, right.path)
}

// --- the tar reader --------------------------------------------------------
//
// A ustar reader over the inflated bytes. It is written here rather
// than shelled out to `tar` because the refusals above are the point:
// a `tar` binary would happily create the symlink we exist to refuse,
// and would do it before we could look.

/// What the reader carries between entries: the tree so far, the pax
/// records that apply to the *next* entry, and the commit a global
/// header named.
type Reading {
  Reading(
    collecting: Collecting,
    pending_path: Option(String),
    pending_size: Option(Int),
    commit: Option(String),
  )
}

/// One header block or one body block; the tar unit.
const block_bytes = 512

const digest_tag = "loom-ext-tree-v1"

const blob_prefix = "sha256-"

fn inflate(gzipped: BitArray, caps: Caps) -> Result(BitArray, ArchiveError) {
  case ffi_zlib.inflate_gzip(gzipped, caps.max_total_bytes) {
    Ok(bytes) -> Ok(bytes)

    Error(ffi_zlib.OutputTooLarge) ->
      Error(TotalBytesExceeded(cap: caps.max_total_bytes))

    Error(ffi_zlib.StreamCorrupt) -> Error(NotGzip)
  }
}

/// Reads the entry whose header block begins at `offset`.
fn read_entries(
  data: BitArray,
  offset: Int,
  state: Collecting,
) -> Result(Reading, ArchiveError) {
  read_from(
    data,
    offset,
    Reading(
      collecting: state,
      pending_path: None,
      pending_size: None,
      commit: None,
    ),
  )
}

fn read_from(
  data: BitArray,
  offset: Int,
  reading: Reading,
) -> Result(Reading, ArchiveError) {
  let remaining = bit_array.byte_size(data) - offset

  // Running out before a whole block is left is the shape a cut-off
  // download takes, and it is refused rather than treated as an end.
  use <- bool.lazy_guard(when: remaining < block_bytes, return: fn() {
    Error(TruncatedArchive(at: offset))
  })

  use block <- or_truncated(
    bit_array.slice(from: data, at: offset, take: block_bytes),
    offset,
  )

  case block == zero_block() {
    True -> read_end_marker(data, offset, reading)

    False -> read_header(data, offset, block, reading)
  }
}

/// A tar ends with two zero blocks. One alone is a stream that stopped
/// in the middle of writing its own terminator.
fn read_end_marker(
  data: BitArray,
  offset: Int,
  reading: Reading,
) -> Result(Reading, ArchiveError) {
  use second <- or_truncated(
    bit_array.slice(from: data, at: offset + block_bytes, take: block_bytes),
    offset,
  )

  case second == zero_block() {
    True -> Ok(reading)

    False -> Error(TruncatedArchive(at: offset))
  }
}

fn read_header(
  data: BitArray,
  offset: Int,
  block: BitArray,
  reading: Reading,
) -> Result(Reading, ArchiveError) {
  use header <- result.try(parse_header(block, offset))

  // The count cap is charged per header block, pax headers included:
  // a pax header is work the reader has to do, so it is work the cap
  // has to bound.
  use counted <- result.try(count_entry(reading.collecting))

  let reading = Reading(..reading, collecting: counted)

  case header.kind {
    // '0' and NUL are both a regular file; the NUL spelling predates
    // ustar and is still what some writers emit.
    0x30 | 0x00 -> read_regular(data, offset, header, reading)

    0x35 -> read_directory(data, offset, header, reading)

    0x78 -> read_pax_extended(data, offset, header, reading)

    0x67 -> read_pax_global(data, offset, header, reading)

    other -> Error(UnsupportedEntry(entry: header.name, kind: kind_name(other)))
  }
}

fn read_regular(
  data: BitArray,
  offset: Int,
  header: Header,
  reading: Reading,
) -> Result(Reading, ArchiveError) {
  let path = option.unwrap(reading.pending_path, header.name)
  let size = option.unwrap(reading.pending_size, header.size)
  let caps = reading.collecting.caps

  // Judged from the header, before a byte of the body is sliced: that
  // is the difference between a cap and a measurement.
  use <- bool.lazy_guard(when: size > caps.max_file_bytes, return: fn() {
    Error(FileTooLarge(path:, size:, cap: caps.max_file_bytes))
  })

  use bytes <- or_truncated(
    bit_array.slice(from: data, at: offset + block_bytes, take: size),
    offset,
  )

  use collecting <- result.try(admit_file(reading.collecting, path, bytes))

  read_from(
    data,
    offset + block_bytes + padded(size),
    clear_pending(Reading(..reading, collecting:)),
  )
}

fn read_directory(
  data: BitArray,
  offset: Int,
  header: Header,
  reading: Reading,
) -> Result(Reading, ArchiveError) {
  let path = option.unwrap(reading.pending_path, header.name)

  use collecting <- result.try(admit_directory(reading.collecting, path))

  // A directory header states a size but carries no body, so the next
  // header follows immediately.
  read_from(
    data,
    offset + block_bytes,
    clear_pending(Reading(..reading, collecting:)),
  )
}

/// A pax extended header ('x') overrides the *next* entry's `path` and
/// `size`, which is how a path longer than the 100-byte name field is
/// carried.
fn read_pax_extended(
  data: BitArray,
  offset: Int,
  header: Header,
  reading: Reading,
) -> Result(Reading, ArchiveError) {
  use records <- result.try(read_pax_body(data, offset, header, reading))

  let pending_path = record(records, "path")
  let pending_size =
    record(records, "size")
    |> option.then(fn(text) { option.from_result(int.parse(text)) })

  read_from(
    data,
    offset + block_bytes + padded(header.size),
    Reading(..reading, pending_path:, pending_size:),
  )
}

/// A pax global header ('g') carries archive-wide records. GitHub's
/// codeload puts the resolved commit in `comment`, and that is the one
/// record an install reads: it is what pins a `--rev` that named a
/// branch to the revision actually fetched.
fn read_pax_global(
  data: BitArray,
  offset: Int,
  header: Header,
  reading: Reading,
) -> Result(Reading, ArchiveError) {
  use records <- result.try(read_pax_body(data, offset, header, reading))

  let commit = option.or(record(records, "comment"), reading.commit)

  read_from(
    data,
    offset + block_bytes + padded(header.size),
    Reading(..reading, commit:),
  )
}

fn read_pax_body(
  data: BitArray,
  offset: Int,
  header: Header,
  reading: Reading,
) -> Result(List(#(String, String)), ArchiveError) {
  let caps = reading.collecting.caps

  // The per-file cap covers a pax body too; it is attacker-chosen input
  // of attacker-chosen length like any other body.
  use <- bool.lazy_guard(when: header.size > caps.max_file_bytes, return: fn() {
    Error(FileTooLarge(
      path: header.name,
      size: header.size,
      cap: caps.max_file_bytes,
    ))
  })

  use body <- or_truncated(
    bit_array.slice(from: data, at: offset + block_bytes, take: header.size),
    offset,
  )

  pax_records(body, 0, [])
  |> result.replace_error(MalformedPaxHeader(entry: header.name))
}

fn clear_pending(reading: Reading) -> Reading {
  Reading(..reading, pending_path: None, pending_size: None)
}

fn record(records: List(#(String, String)), key: String) -> Option(String) {
  records
  |> list.key_find(key)
  |> option.from_result
}

// --- header and field parsing ----------------------------------------------

/// The parts of a ustar header the reader acts on.
type Header {
  Header(
    name: String,
    /// Parsed only to prove the header is well formed. Nothing here
    /// carries a mode onto disk: the caller stages the tree and picks
    /// its own permissions, so an archive cannot ask for a setuid bit.
    mode: Int,
    size: Int,
    kind: Int,
  )
}

fn parse_header(block: BitArray, at: Int) -> Result(Header, ArchiveError) {
  use name <- or_malformed(field_string(block, 0, 100), at, "name")
  use mode <- or_malformed(field_octal(block, 100, 8), at, "mode")
  use size <- or_malformed(field_octal(block, 124, 12), at, "size")
  use stated <- or_malformed(field_octal(block, 148, 8), at, "checksum")
  use kind <- or_malformed(field_byte(block, 156), at, "typeflag")
  use magic <- or_malformed(field_string(block, 257, 5), at, "magic")
  use prefix <- or_malformed(field_string(block, 345, 155), at, "prefix")

  // ustar is the only format an install reads. GNU's own format shares
  // the layout but spells its magic differently, and admitting it would
  // mean admitting the long-name typeflags this reader refuses.
  use <- bool.lazy_guard(when: magic != ustar_magic, return: fn() {
    Error(MalformedHeader(at:, field: "magic"))
  })

  let computed = header_checksum(block)

  use <- bool.lazy_guard(when: computed != stated, return: fn() {
    Error(BadChecksum(at:, stated:, computed:))
  })

  Ok(Header(name: join_prefix(prefix, name), mode:, size:, kind:))
}

const ustar_magic = "ustar"

/// The unsigned sum of the header's bytes with the checksum field read
/// as eight spaces, which is how the field is defined.
///
/// A block that is not exactly 512 bytes cannot be summed, and answers
/// -1 rather than a partial sum: no stated checksum is negative, so the
/// header is refused, which is the answer a malformed block deserves.
fn header_checksum(block: BitArray) -> Int {
  case block {
    <<head:bytes-size(148), _stated:bytes-size(8), tail:bytes-size(356)>> ->
      byte_sum(head, 0) + byte_sum(tail, 0) + 8 * 0x20

    _other -> -1
  }
}

fn byte_sum(bytes: BitArray, total: Int) -> Int {
  case bytes {
    <<value:int-size(8), rest:bits>> -> byte_sum(rest, total + value)

    _empty -> total
  }
}

/// A ustar header splits a long path across `prefix` and `name`, joined
/// by a separator neither of them carries.
fn join_prefix(prefix: String, name: String) -> String {
  case prefix {
    "" -> name

    _present -> prefix <> "/" <> name
  }
}

fn field_string(block: BitArray, at: Int, take: Int) -> Result(String, Nil) {
  use field <- result.try(bit_array.slice(from: block, at:, take:))

  let length =
    field
    |> byte_list([])
    |> list.take_while(fn(byte) { byte != 0 })
    |> list.length

  use text <- result.try(bit_array.slice(from: field, at: 0, take: length))

  bit_array.to_string(text)
}

/// Reads an octal field. NUL and space padding is dropped wherever it
/// sits, which is the leniency every tar reader needs and the only one
/// here: a digit outside `0`-`7` refuses the header.
fn field_octal(block: BitArray, at: Int, take: Int) -> Result(Int, Nil) {
  use field <- result.try(bit_array.slice(from: block, at:, take:))

  field
  |> byte_list([])
  |> list.filter(fn(byte) { byte != 0 && byte != 0x20 })
  |> list.try_fold(0, fn(value, byte) {
    case byte >= 0x30 && byte <= 0x37 {
      True -> Ok(value * 8 + byte - 0x30)

      False -> Error(Nil)
    }
  })
}

fn field_byte(block: BitArray, at: Int) -> Result(Int, Nil) {
  case bit_array.slice(from: block, at:, take: 1) {
    Ok(<<value:int-size(8)>>) -> Ok(value)

    Ok(_wrong_width) -> Error(Nil)

    Error(Nil) -> Error(Nil)
  }
}

fn byte_list(bytes: BitArray, acc: List(Int)) -> List(Int) {
  case bytes {
    <<value:int-size(8), rest:bits>> -> byte_list(rest, [value, ..acc])

    _empty -> list.reverse(acc)
  }
}

/// The name of a typeflag, for a refusal the operator can act on.
fn kind_name(flag: Int) -> String {
  case flag {
    0x31 -> "a hard link"

    0x32 -> "a symbolic link"

    0x33 -> "a character device"

    0x34 -> "a block device"

    0x36 -> "a fifo"

    0x37 -> "a contiguous file"

    0x4c -> "a GNU long name extension"

    0x4b -> "a GNU long link name extension"

    other -> "an entry of unknown type " <> int.to_string(other)
  }
}

// --- pax records -----------------------------------------------------------

/// Reads a pax body as a sequence of `"<len> <key>=<value>\n"` records.
///
/// The length prefix is honoured rather than splitting on newlines,
/// because a pax value may legally contain one: reading by length is
/// what stops a crafted value from forging a record boundary.
fn pax_records(
  body: BitArray,
  offset: Int,
  acc: List(#(String, String)),
) -> Result(List(#(String, String)), Nil) {
  let size = bit_array.byte_size(body)

  use <- bool.lazy_guard(when: offset >= size, return: fn() {
    Ok(list.reverse(acc))
  })

  use #(length, digits) <- result.try(pax_length(body, offset, 0, 0))

  // A record is at minimum its length digits, the space, one byte of
  // `key=value`, and the newline.
  use <- bool.guard(when: length < digits + 3, return: Error(Nil))
  use <- bool.guard(when: offset + length > size, return: Error(Nil))

  use terminator <- result.try(bit_array.slice(
    from: body,
    at: offset + length - 1,
    take: 1,
  ))

  use <- bool.guard(when: terminator != <<0x0a>>, return: Error(Nil))

  use raw <- result.try(bit_array.slice(
    from: body,
    at: offset + digits + 1,
    take: length - digits - 2,
  ))

  use text <- result.try(bit_array.to_string(raw))
  use #(key, value) <- result.try(string.split_once(text, "="))

  pax_records(body, offset + length, [#(key, value), ..acc])
}

/// Reads the decimal length that opens a pax record, returning it and
/// how many digits it took. The digit ceiling keeps a run of `0`s from
/// costing a walk of the body.
fn pax_length(
  body: BitArray,
  offset: Int,
  index: Int,
  value: Int,
) -> Result(#(Int, Int), Nil) {
  use byte <- result.try(bit_array.slice(
    from: body,
    at: offset + index,
    take: 1,
  ))

  case byte {
    <<0x20:int-size(8)>> if index > 0 -> Ok(#(value, index))

    <<digit:int-size(8)>> if digit >= 0x30 && digit <= 0x39 && index < 12 ->
      pax_length(body, offset, index + 1, value * 10 + digit - 0x30)

    _other -> Error(Nil)
  }
}

// --- the local-directory walk ----------------------------------------------

/// Walks `directory`, whose path relative to the tree is `prefix`.
///
/// Depth-first over a sorted listing, so the refusal an operator sees
/// for a directory holding two problems does not depend on the order
/// the filesystem happened to hand back.
fn walk_directory(
  directory: String,
  prefix: String,
  state: Collecting,
) -> Result(Collecting, ArchiveError) {
  use names <- result.try(
    simplifile.read_directory(directory)
    |> result.map_error(fn(error) {
      DirectoryUnreadable(
        path: directory,
        reason: simplifile.describe_error(error),
      )
    }),
  )

  names
  |> list.sort(string.compare)
  |> list.try_fold(state, fn(state, name) {
    walk_entry(directory <> "/" <> name, prefix <> "/" <> name, name, state)
  })
}

fn walk_entry(
  path: String,
  relative: String,
  name: String,
  state: Collecting,
) -> Result(Collecting, ArchiveError) {
  // `.git` goes before the stat, so a repository's object store is
  // never even opened.
  use <- bool.lazy_guard(when: string.starts_with(name, ".git"), return: fn() {
    Error(IllegalPath(
      path: relative,
      reason: "a component beginning with .git; an install takes an export, not a working checkout",
    ))
  })

  // `link_info` is lstat: it describes the link itself, so a symlink is
  // seen as a symlink rather than as whatever it points at.
  use info <- result.try(
    simplifile.link_info(path)
    |> result.map_error(fn(error) {
      DirectoryUnreadable(path:, reason: simplifile.describe_error(error))
    }),
  )

  case simplifile.file_info_type(info) {
    simplifile.Directory -> {
      use state <- result.try(admit_directory(state, relative))

      walk_directory(path, relative, state)
    }

    simplifile.File -> walk_file(path, relative, state)

    simplifile.Symlink ->
      Error(UnsupportedEntry(entry: relative, kind: "a symbolic link"))

    simplifile.Other ->
      Error(UnsupportedEntry(entry: relative, kind: "not a regular file"))
  }
}

fn walk_file(
  path: String,
  relative: String,
  state: Collecting,
) -> Result(Collecting, ArchiveError) {
  let caps = state.caps

  use info <- result.try(
    simplifile.file_info(path)
    |> result.map_error(fn(error) {
      DirectoryUnreadable(path:, reason: simplifile.describe_error(error))
    }),
  )

  // The stat and the read are two syscalls, so a path swapped between
  // them would be read as whatever it became. That is left alone
  // deliberately: the directory is one the operator named on their own
  // machine, an attacker who can rewrite it mid-install can rewrite it
  // before the install instead, and closing the window would cost an
  // open-with-O_NOFOLLOW external for no property the operator does not
  // already have.

  // The archive reader judges a file by its header before reading it,
  // and this is the same judgement made from the same distance.
  use <- bool.lazy_guard(when: info.size > caps.max_file_bytes, return: fn() {
    Error(FileTooLarge(
      path: relative,
      size: info.size,
      cap: caps.max_file_bytes,
    ))
  })

  use bytes <- result.try(
    simplifile.read_bits(path)
    |> result.map_error(fn(error) {
      DirectoryUnreadable(path:, reason: simplifile.describe_error(error))
    }),
  )

  admit_file(state, relative, bytes)
}

// --- small shared helpers --------------------------------------------------

fn or_truncated(
  sliced: Result(a, Nil),
  at: Int,
  then: fn(a) -> Result(b, ArchiveError),
) -> Result(b, ArchiveError) {
  case sliced {
    Error(Nil) -> Error(TruncatedArchive(at:))

    Ok(value) -> then(value)
  }
}

fn or_malformed(
  parsed: Result(a, Nil),
  at: Int,
  field: String,
  then: fn(a) -> Result(b, ArchiveError),
) -> Result(b, ArchiveError) {
  case parsed {
    Error(Nil) -> Error(MalformedHeader(at:, field:))

    Ok(value) -> then(value)
  }
}

fn zero_block() -> BitArray {
  <<0:size(4096)>>
}

/// The bytes an entry of `size` occupies once padded to a whole number
/// of blocks.
fn padded(size: Int) -> Int {
  { size + block_bytes - 1 } / block_bytes * block_bytes
}

fn trim_trailing_slashes(path: String) -> String {
  case string.ends_with(path, "/") {
    True -> trim_trailing_slashes(string.drop_end(path, 1))

    False -> path
  }
}

fn last_component(path: String) -> String {
  path
  |> string.split("/")
  |> list.last
  |> result.unwrap("")
}
