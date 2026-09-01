//// Non-ASCII paths across the bootstrap FFI boundary.
////
//// A Gleam string is a UTF-8 binary, and `binary_to_list/1` turns that binary
//// into one codepoint per byte. Every path the shim converted that way
//// reached `filename`, `file`, `os:getenv` and `open_port` double-encoded:
//// `/tmp/é` arrived as `/tmp/Ã©`, so a `HOME` or a `--workspace` holding an
//// accent failed before any Gleam policy saw it. These tests drive the
//// externals against a directory whose name really is not ASCII, which is the
//// only way to tell a correct conversion from a lucky one.

import filepath
import gleam/bit_array
import gleam/string
import simplifile
import tui/internal/ffi_bootstrap

/// The accented name every case builds its fixture from.
///
/// It mixes an escaped codepoint with a literal one so both source forms are
/// proven to survive the round trip, and it is the shape an operator's own
/// `café` project directory takes.
const accented_name = "caf\u{e9}-é"

pub fn absolute_path_preserves_non_ascii_segments_test() {
  let relative = "build/" <> accented_name

  let assert Ok(absolute) = ffi_bootstrap.absolute_path(relative)
    as "absolute_path must accept a non-ASCII relative path"

  assert string.starts_with(absolute, "/")
  assert string.ends_with(absolute, "/" <> relative)
}

pub fn canonical_directory_resolves_a_non_ascii_directory_test() {
  let root = test_root("canonical")
  let directory = filepath.join(root, accented_name)
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
    as "the accented directory must be creatable"

  // `canonical_directory` hands the path to a `realpath` port, so this covers
  // both the conversion and the port argument encoding behind it.
  let resolved = ffi_bootstrap.canonical_directory(directory)
  let _ = simplifile.delete(root)

  let assert Ok(canonical) = resolved
    as "canonical_directory must resolve a non-ASCII directory"

  assert filepath.base_name(canonical) == accented_name
}

pub fn ensure_private_directory_accepts_a_non_ascii_path_test() {
  let root = test_root("private")
  let directory = filepath.join(root, accented_name)
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
    as "the accented directory must be creatable"

  let outcome = ffi_bootstrap.ensure_private_directory(directory)
  let info = simplifile.file_info(directory)
  let _ = simplifile.delete(root)

  let assert Ok(Nil) = outcome
    as "ensure_private_directory must accept a non-ASCII state root"
  let assert Ok(info) = info as "the accented directory must remain readable"

  assert simplifile.file_info_permissions_octal(info) == 0o700
}

pub fn private_records_round_trip_through_a_non_ascii_path_test() {
  let root = test_root("record")
  let directory = filepath.join(root, accented_name)
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
    as "the accented directory must be creatable"
  let record = filepath.join(directory, accented_name <> ".json")
  let contents = "{\"workspace\":\"" <> accented_name <> "\"}"

  // A launcher record is written, read back, and then discovered by name, so
  // a mangled path anywhere in that chain shows up as a missing file rather
  // than as corrupt bytes.
  let written = ffi_bootstrap.atomic_write_private(record, contents)
  let read = ffi_bootstrap.read_private_bounded(record, 4096)
  let listed = ffi_bootstrap.list_directory_bounded(directory, 16)
  let _ = simplifile.delete(root)

  let assert Ok(Nil) = written
    as "atomic_write_private must accept a non-ASCII path"
  let assert Ok(bytes) = read
    as "read_private_bounded must accept a non-ASCII path"
  let assert Ok(entries) = listed
    as "list_directory_bounded must accept a non-ASCII path"

  assert bit_array.to_string(bytes) == Ok(contents)
  assert entries == [accented_name <> ".json"]
}

pub fn executable_discovery_accepts_a_non_ascii_path_test() {
  let root = test_root("executable")
  let directory = filepath.join(root, accented_name)
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
    as "the accented directory must be creatable"
  let script = filepath.join(directory, accented_name <> ".sh")
  let assert Ok(Nil) = simplifile.write(script, "#!/bin/sh\nexit 0\n")
    as "the accented script must be writable"
  let assert Ok(Nil) = simplifile.set_permissions_octal(script, 0o755)
    as "the accented script must be made executable"

  let found = ffi_bootstrap.find_executable(script)
  let canonical = ffi_bootstrap.canonical_path(script)
  let executable = ffi_bootstrap.is_executable_file(script)
  let exists = ffi_bootstrap.path_exists(script)
  let _ = simplifile.delete(root)

  let assert Ok(found) = found
    as "find_executable must resolve a non-ASCII explicit path"
  let assert Ok(canonical) = canonical
    as "canonical_path must resolve a non-ASCII path"

  let tail = "/" <> accented_name <> "/" <> accented_name <> ".sh"
  assert string.ends_with(found, tail)
  assert string.ends_with(canonical, tail)
  assert executable
  assert exists
}

// Each case owns a fresh root under `build/` so a failed case cannot leave a
// fixture that makes the next run pass for the wrong reason.
fn test_root(name: String) -> String {
  "build/ffi-path-test-"
  <> name
  <> "-"
  <> string.inspect(ffi_bootstrap.system_time_ms())
}
