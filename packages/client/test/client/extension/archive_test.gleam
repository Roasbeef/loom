//// Tests for the extension archive reader.
////
//// The tars are built here, byte by byte, rather than shelled out to a
//// `tar` binary. That is what lets a test assert on a bad checksum, a
//// lone zero block or a `..` path at all: a real `tar` will not write
//// most of them, and the archives this reader exists to refuse are
//// exactly the ones no honest writer produces.

import client/extension/archive
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile

// --- a small tar writer ----------------------------------------------------

const block = 512

const regular = "0"

const directory = "5"

const pax_extended = "x"

const pax_global = "g"

/// One tar entry: a checksummed ustar header, the body, and the padding
/// that rounds the body up to a whole block.
fn entry(name: String, kind: String, body: BitArray) -> BitArray {
  let size = bit_array.byte_size(body)

  bit_array.concat([header(name, kind, size), body, padding(size)])
}

/// A header whose stated size is not the body that follows it, for the
/// truncation tests.
fn header(name: String, kind: String, size: Int) -> BitArray {
  let unchecked =
    bit_array.concat([
      text_field(name, 100),
      octal_field(0o644, 8),
      octal_field(0, 8),
      octal_field(0, 8),
      octal_field(size, 12),
      octal_field(0, 12),
      <<"        ":utf8>>,
      text_field(kind, 1),
      text_field("", 100),
      <<"ustar":utf8, 0>>,
      <<"00":utf8>>,
      text_field("", 32),
      text_field("", 32),
      octal_field(0, 8),
      octal_field(0, 8),
      text_field("", 155),
      text_field("", 12),
    ])

  patch_checksum(unchecked, sum(unchecked, 0))
}

/// Replaces the eight-byte checksum field with the header's own sum,
/// which is what makes the header well formed.
fn patch_checksum(unchecked: BitArray, value: Int) -> BitArray {
  let assert <<head:bytes-size(148), _blank:bytes-size(8), tail:bits>> =
    unchecked
    as "a tar header is 512 bytes with its checksum at offset 148"

  bit_array.concat([head, octal_field(value, 8), tail])
}

fn sum(bytes: BitArray, total: Int) -> Int {
  case bytes {
    <<value:int-size(8), rest:bits>> -> sum(rest, total + value)

    _empty -> total
  }
}

fn text_field(text: String, width: Int) -> BitArray {
  let bytes = bit_array.from_string(text)

  bit_array.concat([bytes, zeros(width - bit_array.byte_size(bytes))])
}

/// An octal field is `width - 1` zero-padded digits and a NUL, which is
/// the form every tar writer emits.
fn octal_field(value: Int, width: Int) -> BitArray {
  let padded = string.pad_start(int.to_base8(value), width - 1, "0")

  bit_array.concat([bit_array.from_string(padded), <<0>>])
}

fn padding(size: Int) -> BitArray {
  zeros({ { size + block - 1 } / block * block } - size)
}

fn zeros(count: Int) -> BitArray {
  <<0:size(count * 8)>>
}

/// The two zero blocks that end a tar.
fn end_marker() -> BitArray {
  zeros(block * 2)
}

fn tarball(entries: List(BitArray)) -> BitArray {
  gzip(bit_array.concat(list.append(entries, [end_marker()])))
}

@external(erlang, "client_test_ffi", "gzip")
fn gzip(bytes: BitArray) -> BitArray

fn utf8(text: String) -> BitArray {
  bit_array.from_string(text)
}

/// A pax record body: `"<len> <key>=<value>\n"` with the length
/// counting itself.
fn pax_record(key: String, value: String) -> BitArray {
  let payload = key <> "=" <> value <> "\n"

  utf8(pax_length(payload, string.byte_size(payload) + 2) <> " " <> payload)
}

/// The length prefix has to count its own digits, so it is grown until
/// it stops changing width.
fn pax_length(payload: String, guess: Int) -> String {
  let rendered = int.to_string(guess)
  let total = string.byte_size(payload) + 1 + string.byte_size(rendered)

  case total == guess {
    True -> rendered

    False -> pax_length(payload, total)
  }
}

// --- extraction ------------------------------------------------------------

pub fn extract_two_files_with_pax_commit_test() {
  let bytes =
    tarball([
      entry("pax_global_header", pax_global, pax_record("comment", "deadbeef")),
      entry("repo-1/", directory, <<>>),
      entry("repo-1/src/", directory, <<>>),
      entry("repo-1/src/main.gleam", regular, utf8("pub fn main() { Nil }")),
      entry("repo-1/gleam.toml", regular, utf8("name = \"hello\"")),
    ])

  let assert Ok(tree) = archive.extract(bytes, archive.default_caps())
    as "a well-formed archive extracts"

  assert tree.root == "repo-1"
  assert tree.commit == Some("deadbeef")
  assert list.map(tree.files, fn(file) { file.path })
    == ["gleam.toml", "src/main.gleam"]
}

pub fn extract_carries_file_bytes_test() {
  let bytes =
    tarball([
      entry("repo/", directory, <<>>),
      entry("repo/a.txt", regular, utf8("hello")),
    ])

  let assert Ok(tree) = archive.extract(bytes, archive.default_caps())
    as "a one-file archive extracts"
  let assert [file] = tree.files as "one file in, one file out"

  assert file.bytes == utf8("hello")
}

pub fn extract_long_pax_path_test() {
  let long = string.repeat("deep/", 30) <> "leaf.gleam"
  let bytes =
    tarball([
      entry("repo/", directory, <<>>),
      entry("repo/short", pax_extended, pax_record("path", "repo/" <> long)),
      entry("repo/short", regular, utf8("x")),
    ])

  let assert Ok(tree) = archive.extract(bytes, archive.default_caps())
    as "a pax path override extracts"
  let assert [file] = tree.files as "the override replaces the header name"

  assert file.path == long
}

pub fn refused_typeflags_test() {
  let kinds = [
    #("1", "a hard link"),
    #("2", "a symbolic link"),
    #("3", "a character device"),
    #("4", "a block device"),
    #("6", "a fifo"),
    #("L", "a GNU long name extension"),
    #("K", "a GNU long link name extension"),
    #("Z", "an entry of unknown type 90"),
  ]

  list.each(kinds, fn(pair) {
    let #(flag, described) = pair
    let bytes =
      tarball([entry("repo/", directory, <<>>), entry("repo/x", flag, <<>>)])

    assert archive.extract(bytes, archive.default_caps())
      == Error(archive.UnsupportedEntry(entry: "repo/x", kind: described))
  })
}

pub fn dot_dot_path_test() {
  let bytes =
    tarball([
      entry("repo/", directory, <<>>),
      entry("repo/../escape", regular, utf8("x")),
    ])

  let assert Error(archive.IllegalPath(path:, reason:)) =
    archive.extract(bytes, archive.default_caps())
    as "a .. component is refused"

  assert path == "repo/../escape"
  assert string.contains(reason, "..")
}

pub fn absolute_path_test() {
  let bytes = tarball([entry("/etc/passwd", regular, utf8("x"))])

  let assert Error(archive.IllegalPath(path: "/etc/passwd", reason:)) =
    archive.extract(bytes, archive.default_caps())
    as "a leading slash is an empty first component"

  assert string.contains(reason, "empty component")
}

pub fn control_character_path_test() {
  let bytes =
    tarball([
      entry("repo/", directory, <<>>),
      entry("repo/bell\u{0007}", regular, utf8("x")),
    ])

  let assert Error(archive.IllegalPath(reason:, ..)) =
    archive.extract(bytes, archive.default_caps())
    as "a control character is outside the path subset"

  assert string.contains(reason, "printable subset")
}

pub fn bidi_override_path_test() {
  let bytes =
    tarball([
      entry("repo/", directory, <<>>),
      entry("repo/gleam\u{202E}lmot.toml", regular, utf8("x")),
    ])

  let assert Error(archive.IllegalPath(..)) =
    archive.extract(bytes, archive.default_caps())
    as "an invisible bidi override is outside the path subset"
}

pub fn two_top_level_directories_test() {
  let bytes =
    tarball([
      entry("one/", directory, <<>>),
      entry("one/a", regular, utf8("x")),
      entry("two/", directory, <<>>),
    ])

  assert archive.extract(bytes, archive.default_caps())
    == Error(archive.MultipleRoots(first: "one", second: "two"))
}

pub fn file_at_the_root_test() {
  let bytes = tarball([entry("README.md", regular, utf8("x"))])

  let assert Error(archive.IllegalPath(path: "README.md", reason:)) =
    archive.extract(bytes, archive.default_caps())
    as "a file with no directory above it is refused"

  assert string.contains(reason, "top-level directory")
}

pub fn duplicate_path_test() {
  let bytes =
    tarball([
      entry("repo/", directory, <<>>),
      entry("repo/a", regular, utf8("first")),
      entry("repo/a", regular, utf8("second")),
    ])

  assert archive.extract(bytes, archive.default_caps())
    == Error(archive.DuplicatePath(path: "a"))
}

pub fn truncated_archive_test() {
  let bytes =
    gzip(
      bit_array.concat([
        entry("repo/", directory, <<>>),
        entry("repo/a", regular, utf8("x")),
      ]),
    )

  let assert Error(archive.TruncatedArchive(..)) =
    archive.extract(bytes, archive.default_caps())
    as "an archive with no end marker is refused"
}

pub fn one_zero_block_is_truncated_test() {
  let bytes =
    gzip(bit_array.concat([entry("repo/", directory, <<>>), zeros(block)]))

  let assert Error(archive.TruncatedArchive(..)) =
    archive.extract(bytes, archive.default_caps())
    as "a lone zero block is half a terminator"
}

pub fn truncated_body_test() {
  let bytes =
    gzip(
      bit_array.concat([
        entry("repo/", directory, <<>>),
        header("repo/a", regular, 4096),
        zeros(block),
        end_marker(),
      ]),
    )

  let assert Error(archive.TruncatedArchive(..)) =
    archive.extract(bytes, archive.default_caps())
    as "a body shorter than its header states is refused"
}

pub fn bad_checksum_test() {
  let assert <<head:bytes-size(148), _sum:bytes-size(8), tail:bits>> =
    header("repo/", directory, 0)
    as "a tar header is 512 bytes"

  let corrupt = bit_array.concat([head, octal_field(1, 8), tail])
  let bytes = gzip(bit_array.concat([corrupt, end_marker()]))

  let assert Error(archive.BadChecksum(at: 0, stated: 1, computed:)) =
    archive.extract(bytes, archive.default_caps())
    as "a header whose bytes do not sum to its field is refused"

  assert computed != 1
}

pub fn not_gzip_test() {
  assert archive.extract(utf8("this is not compressed"), archive.default_caps())
    == Error(archive.NotGzip)
}

pub fn malformed_header_test() {
  let bytes =
    gzip(
      bit_array.concat([
        patch_checksum(
          bit_array.concat([
            text_field("repo/", 100),
            text_field("99999999", 8),
            text_field("", 384),
            text_field("", 12),
          ]),
          0,
        ),
        end_marker(),
      ]),
    )

  let assert Error(archive.MalformedHeader(at: 0, field:)) =
    archive.extract(bytes, archive.default_caps())
    as "a non-octal mode is refused"

  assert field == "mode"
}

pub fn malformed_pax_header_test() {
  let bytes =
    tarball([
      entry("repo/", directory, <<>>),
      entry("repo/x", pax_extended, utf8("not a pax record at all\n")),
      entry("repo/x", regular, utf8("x")),
    ])

  assert archive.extract(bytes, archive.default_caps())
    == Error(archive.MalformedPaxHeader(entry: "repo/x"))
}

/// A negative pax size is not a large number a cap catches: it would
/// slice backwards into bytes the reader has already passed.
pub fn negative_pax_size_test() {
  let bytes =
    tarball([
      entry("repo/", directory, <<>>),
      entry("repo/x", pax_extended, pax_record("size", "-5")),
      entry("repo/x", regular, utf8("hello")),
    ])

  assert archive.extract(bytes, archive.default_caps())
    == Error(archive.MalformedPaxHeader(entry: "repo/x"))
}

/// A `size` record that is not a number refuses the header rather than
/// falling back to the header's own size, so a crafted record cannot
/// choose which of the two the reader used.
pub fn unparseable_pax_size_test() {
  let bytes =
    tarball([
      entry("repo/", directory, <<>>),
      entry("repo/x", pax_extended, pax_record("size", "abc")),
      entry("repo/x", regular, utf8("hello")),
    ])

  assert archive.extract(bytes, archive.default_caps())
    == Error(archive.MalformedPaxHeader(entry: "repo/x"))
}

pub fn pax_size_override_test() {
  let bytes =
    tarball([
      entry("repo/", directory, <<>>),
      entry("repo/x", pax_extended, pax_record("size", "3")),
      entry("repo/x", regular, utf8("hello")),
    ])

  let assert Ok(tree) = archive.extract(bytes, archive.default_caps())
    as "a pax size override is honoured"
  let assert [file] = tree.files as "one file in, one file out"

  assert file.bytes == utf8("hel")
}

// --- the caps --------------------------------------------------------------

pub fn entry_cap_test() {
  let files =
    ["a", "b", "c", "d", "e", "f", "g", "h"]
    |> list.map(fn(name) { entry("repo/" <> name, regular, utf8("x")) })

  let bytes = tarball([entry("repo/", directory, <<>>), ..files])
  let caps = archive.Caps(..archive.default_caps(), max_entries: 4)

  assert archive.extract(bytes, caps) == Error(archive.TooManyEntries(cap: 4))
}

pub fn per_file_cap_test() {
  let bytes =
    tarball([
      entry("repo/", directory, <<>>),
      entry("repo/big", regular, zeros(2048)),
    ])

  let caps = archive.Caps(..archive.default_caps(), max_file_bytes: 1024)

  assert archive.extract(bytes, caps)
    == Error(archive.FileTooLarge(path: "repo/big", size: 2048, cap: 1024))
}

/// A megabyte of zeros compresses to about a kilobyte, so the archive is
/// small and the extraction is not: this is the bomb the bounded
/// inflation exists for, and it must never be materialised.
///
/// The illegal path in front of the bomb is what makes the assertion
/// mean that. If the inflation were unbounded, the tar reader would run
/// and refuse `repo/../escape` first, so the answer would be
/// `IllegalPath`; `TotalBytesExceeded` can only come from a stream that
/// was abandoned before any of it reached the reader.
pub fn total_cap_bomb_test() {
  let bytes =
    tarball([
      entry("repo/", directory, <<>>),
      entry("repo/../escape", regular, utf8("x")),
      entry("repo/bomb", regular, zeros(1024 * 1024)),
    ])

  let caps =
    archive.Caps(
      ..archive.default_caps(),
      max_file_bytes: 4 * 1024 * 1024,
      max_total_bytes: 64 * 1024,
    )

  assert bit_array.byte_size(bytes) < 64 * 1024
  assert archive.extract(bytes, caps)
    == Error(archive.TotalBytesExceeded(cap: 64 * 1024))
}

// --- the digest ------------------------------------------------------------

fn sample_tree(root: String, commit: option.Option(String)) -> archive.Tree {
  archive.Tree(
    root:,
    files: [
      archive.File(path: "a.txt", bytes: utf8("alpha")),
      archive.File(path: "b/c.txt", bytes: utf8("beta")),
    ],
    commit:,
  )
}

pub fn digest_is_lowercase_hex_test() {
  let rendered = archive.digest(sample_tree("repo", None))

  assert string.length(rendered) == 64
  assert string.lowercase(rendered) == rendered
}

pub fn digest_ignores_root_and_commit_test() {
  assert archive.digest(sample_tree("repo-1", None))
    == archive.digest(sample_tree("somewhere-else", Some("deadbeef")))
}

pub fn digest_ignores_file_order_test() {
  let tree = sample_tree("repo", None)
  let shuffled = archive.Tree(..tree, files: list.reverse(tree.files))

  assert archive.digest(tree) == archive.digest(shuffled)
}

pub fn digest_changes_with_one_byte_test() {
  let tree = sample_tree("repo", None)
  let changed =
    archive.Tree(..tree, files: [
      archive.File(path: "a.txt", bytes: utf8("alphb")),
      archive.File(path: "b/c.txt", bytes: utf8("beta")),
    ])

  assert archive.digest(tree) != archive.digest(changed)
}

/// Length prefixes rather than separators: moving a byte from a path
/// into the next field must not produce the same encoding.
pub fn digest_separates_path_from_content_test() {
  let left =
    archive.Tree(
      root: "r",
      files: [archive.File(path: "ab", bytes: utf8("c"))],
      commit: None,
    )
  let right =
    archive.Tree(
      root: "r",
      files: [archive.File(path: "a", bytes: utf8("bc"))],
      commit: None,
    )

  assert archive.digest(left) != archive.digest(right)
}

// --- the local directory ---------------------------------------------------

/// A directory beneath the package's own build output, never `/tmp`:
/// code mode replaces `/tmp` with the jail's scratch tmpfs, so a test
/// fixture there is not the directory the test thinks it is.
fn scratch(name: String) -> String {
  let path = "build/extension-archive-test/" <> name

  let _ = simplifile.delete(path)
  let assert Ok(Nil) = simplifile.create_directory_all(path)
    as "the test scratch directory is creatable"

  path
}

fn write(path: String, contents: String) -> Nil {
  let assert Ok(Nil) = simplifile.write(to: path, contents: contents)
    as "the test fixture is writable"

  Nil
}

pub fn from_directory_reads_tree_test() {
  let root = scratch("plain")
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/src")
    as "the fixture has a src directory"

  write(root <> "/gleam.toml", "name = \"hello\"")
  write(root <> "/src/hello.gleam", "pub fn main() { Nil }")

  let assert Ok(tree) = archive.from_directory(root, archive.default_caps())
    as "a plain directory reads"

  assert tree.root == "plain"
  assert tree.commit == None
  assert list.map(tree.files, fn(file) { file.path })
    == ["gleam.toml", "src/hello.gleam"]
}

pub fn from_directory_digest_matches_archive_test() {
  let root = scratch("digest")

  write(root <> "/a.txt", "alpha")

  let assert Ok(tree) = archive.from_directory(root, archive.default_caps())
    as "the fixture reads"

  let bytes =
    tarball([
      entry("repo-9/", directory, <<>>),
      entry("repo-9/a.txt", regular, utf8("alpha")),
    ])

  let assert Ok(extracted) = archive.extract(bytes, archive.default_caps())
    as "the equivalent archive extracts"

  assert archive.digest(tree) == archive.digest(extracted)
}

pub fn from_directory_refuses_symlink_test() {
  let root = scratch("symlink")

  write(root <> "/real.txt", "alpha")

  let assert Ok(Nil) =
    simplifile.create_symlink(to: "real.txt", from: root <> "/link.txt")
    as "the fixture has a symlink"

  assert archive.from_directory(root, archive.default_caps())
    == Error(archive.UnsupportedEntry(
      entry: "symlink/link.txt",
      kind: "a symbolic link",
    ))
}

pub fn from_directory_skips_git_test() {
  let root = scratch("checkout")
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/.git")
    as "the fixture looks like a working checkout"

  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/.github")
    as "the fixture carries a .github directory too"

  write(root <> "/.git/HEAD", "ref: refs/heads/main\n")
  write(root <> "/.github/workflow.yml", "on: push\n")
  write(root <> "/gleam.toml", "name = \"hello\"")

  let assert Ok(tree) = archive.from_directory(root, archive.default_caps())
    as "a working checkout reads as its export"

  // The object store is pruned and nothing else is: `.github` is an
  // ordinary directory to the reader.
  assert list.map(tree.files, fn(file) { file.path })
    == [".github/workflow.yml", "gleam.toml"]
}

/// The root is lstat'd like every entry beneath it, so a symlink handed
/// straight to `from_directory` is refused rather than followed.
pub fn from_directory_refuses_a_symlinked_root_test() {
  let root = scratch("linked-root")

  write(root <> "/a.txt", "alpha")

  let link = "build/extension-archive-test/linked-root-alias"
  let _ = simplifile.delete(link)
  let assert Ok(Nil) = simplifile.create_symlink(to: "linked-root", from: link)
    as "the fixture has a symlinked root"

  assert archive.from_directory(link, archive.default_caps())
    == Error(archive.UnsupportedEntry(
      entry: "linked-root-alias",
      kind: "a symbolic link",
    ))
}

pub fn from_directory_refuses_a_file_as_a_root_test() {
  let root = scratch("file-root")

  write(root <> "/a.txt", "alpha")

  let assert Error(archive.DirectoryUnreadable(reason:, ..)) =
    archive.from_directory(root <> "/a.txt", archive.default_caps())
    as "a file is not a source tree"

  assert string.contains(reason, "not a directory")
}

pub fn from_directory_missing_test() {
  let assert Error(archive.DirectoryUnreadable(..)) =
    archive.from_directory("build/no-such-directory", archive.default_caps())
    as "a directory that is not there is refused"
}

pub fn from_directory_total_cap_test() {
  let root = scratch("total")

  write(root <> "/a.txt", string.repeat("a", 2048))
  write(root <> "/b.txt", string.repeat("b", 2048))

  let caps = archive.Caps(..archive.default_caps(), max_total_bytes: 3000)

  assert archive.from_directory(root, caps)
    == Error(archive.TotalBytesExceeded(cap: 3000))
}

pub fn describe_names_the_entry_test() {
  let rendered =
    archive.describe(archive.UnsupportedEntry(
      entry: "repo/link",
      kind: "a symbolic link",
    ))

  assert string.contains(rendered, "repo/link")
  assert string.contains(rendered, "a symbolic link")
}
