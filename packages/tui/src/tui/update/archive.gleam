//// The release writer emits only canonical ustar files, directories and
//// sibling executable aliases. This reader admits that exact subset before
//// staging any path. Extension archives retain their separate source-tree
//// contract, including their unconditional refusal of links.

import gleam/bit_array
import gleam/bool
import gleam/dict
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import host/internal/ffi_zlib
import tui/update/manifest

/// File permissions needed by the published release.
pub type Mode {
  /// Ordinary read-only installation data.
  Data

  /// A launcher or native executable.
  Executable
}

/// A fully checked entry relative to the manifest's expected root.
pub type Entry {
  /// File bytes and executable intent, without privileged permission bits.
  File(
    /// Relative path below the verified archive root.
    path: String,
    /// A slice of the bounded inflated archive.
    bytes: BitArray,
    /// Whether the published file needs executable permission.
    mode: Mode,
  )

  /// A directory, including empty directories.
  Directory(
    /// Relative path, with the empty string representing the root.
    path: String,
  )

  /// A relative alias of a regular file in the same directory.
  Alias(
    /// Relative location of the symlink below the archive root.
    path: String,
    /// A basename identifying a regular sibling in the same archive.
    target: String,
  )
}

/// Validates a complete release before allowing any filesystem writes.
///
/// Inflation is capped at 512 MiB, individual files at 128 MiB, and headers
/// at 30,000 entries. The returned file slices share the bounded tar binary.
///
/// ## Examples
///
/// ```gleam
/// // archive.decode(bytes, "loom-0.2.0-linux-arm64")
/// ```
pub fn decode(bytes: BitArray, root: String) -> Result(List(Entry), String) {
  use inflated <- result.try(
    ffi_zlib.inflate_gzip(bytes, 536_870_912)
    |> result.map_error(fn(_) { "release gzip is invalid or exceeds 512 MiB" }),
  )
  use entries <- result.try(read(inflated, root, 0, []))
  use <- bool.guard(list.is_empty(entries), Error("release archive is empty"))
  use Nil <- result.try(validate_tree(entries))
  Ok(entries)
}

fn read(bytes, root, count, entries) {
  use <- bool.guard(
    count > 30_000,
    Error("release archive has too many entries"),
  )
  case bytes {
    <<0:size(8192), rest:bits>> -> {
      use <- bool.guard(!zeroes(rest), Error("release has trailing tar data"))
      Ok(list.reverse(entries))
    }
    <<header:bytes-size(512), rest:bits>> -> {
      use #(entry, remaining) <- result.try(read_entry(header, rest, root))
      read(remaining, root, count + 1, [entry, ..entries])
    }
    _ -> Error("release tar is truncated")
  }
}

fn zeroes(bytes) {
  case bytes {
    <<>> -> True
    <<0:size(8192), rest:bits>> -> zeroes(rest)
    <<0, rest:bits>> -> zeroes(rest)
    _ -> False
  }
}

fn read_entry(header, body, root) {
  use expected <- result.try(octal(header, 148, 8))
  use <- bool.guard(
    checksum(header, 0, 0) != expected,
    Error("release tar checksum mismatch"),
  )
  use magic <- result.try(field(header, 257, 6))
  use <- bool.guard(magic != "ustar", Error("release must use canonical ustar"))
  use name <- result.try(field(header, 0, 100))
  use prefix <- result.try(field(header, 345, 155))
  let name = case prefix {
    "" -> name
    prefix -> prefix <> "/" <> name
  }
  use path <- result.try(relative_path(name, root))
  use size <- result.try(octal(header, 124, 12))
  use mode <- result.try(octal(header, 100, 8))
  use kind <- result.try(field(header, 156, 1))
  use target <- result.try(field(header, 157, 100))
  use <- bool.guard(
    size < 0 || size > 134_217_728,
    Error("release file exceeds 128 MiB"),
  )
  let padded = { { size + 511 } / 512 } * 512
  use contents <- result.try(slice(body, 0, size))
  use remaining <- result.try(slice(
    body,
    padded,
    bit_array.byte_size(body) - padded,
  ))
  use entry <- result.try(classify(kind, path, target, contents, mode))
  Ok(#(entry, remaining))
}

fn classify(kind, path, target, contents, mode) {
  case kind {
    "0" | "" -> {
      use <- bool.guard(path == "", Error("release root must be a directory"))
      let permissions = case
        mode % 2 == 1 || { mode / 8 } % 2 == 1 || { mode / 64 } % 2 == 1
      {
        True -> Executable
        False -> Data
      }
      Ok(File(path, contents, permissions))
    }
    "5" -> {
      use <- bool.guard(contents != <<>>, Error("release directory has data"))
      Ok(Directory(path))
    }
    "2" -> {
      use <- bool.guard(
        path == "" || contents != <<>> || !component_name(target),
        Error("release alias must name a regular sibling"),
      )
      Ok(Alias(path, target))
    }
    _ -> Error("unsupported release tar entry")
  }
}

// Gleam's generated BEAM names use @ as a module separator. Admission
// substitutes it only while checking the alphabet; staged names stay exact.
fn component_name(name) {
  manifest.basename(string.replace(name, "@", "_"))
}

fn relative_path(name, root) {
  let name = trim_end_matches(name, "/")
  let parts = string.split(name, "/")
  use <- bool.guard(
    !list.all(parts, component_name),
    Error("invalid release archive path"),
  )
  case parts {
    [found, ..rest] if found == root -> Ok(string.join(rest, "/"))
    _ -> Error("release archive root differs from manifest")
  }
}

fn validate_tree(entries: List(Entry)) {
  let paths = list.map(entries, fn(entry) { #(entry.path, entry) })
  let by_path = dict.from_list(paths)
  use <- bool.guard(
    dict.size(by_path) != list.length(entries),
    Error("duplicate release archive path"),
  )
  use _ <- result.try(
    list.try_map(entries, fn(entry) {
      use Nil <- result.try(parents(entry.path, by_path))
      case entry {
        File(_, _, _) | Directory(_) -> Ok(Nil)
        Alias(path, target) -> {
          let parent = parent(path)
          let target = case parent {
            "" -> target
            _ -> parent <> "/" <> target
          }
          case dict.get(by_path, target) {
            Ok(File(_, _, _)) -> Ok(Nil)
            _ -> Error("release alias target is not a regular sibling")
          }
        }
      }
    }),
  )
  Ok(Nil)
}

fn parents(path, entries) {
  case path {
    "" -> Ok(Nil)
    _ -> {
      let parent = parent(path)
      use Nil <- result.try(case dict.get(entries, parent) {
        Ok(Directory(_)) -> Ok(Nil)
        _ -> Error("release entry parent must be an explicit directory")
      })
      parents(parent, entries)
    }
  }
}

fn parent(path) {
  path
  |> string.split("/")
  |> list.reverse
  |> list.drop(1)
  |> list.reverse
  |> string.join("/")
}

fn slice(bytes, offset, length) {
  bit_array.slice(bytes, offset, length)
  |> result.map_error(fn(_) { "release tar is truncated" })
}

fn field(bytes, offset, length) {
  use bytes <- result.try(slice(bytes, offset, length))
  use text <- result.try(
    bit_array.to_string(bytes)
    |> result.map_error(fn(_) { "release tar field is not UTF-8" }),
  )
  Ok(trim_end_matches(text, "\u{0}"))
}

fn octal(bytes, offset, length) {
  use text <- result.try(field(bytes, offset, length))
  int.base_parse(trim_end_matches(string.trim(text), "\u{0}"), 8)
  |> result.map_error(fn(_) { "release tar number is invalid" })
}

fn trim_end_matches(text, suffix) {
  case string.ends_with(text, suffix) {
    True -> trim_end_matches(string.drop_end(text, 1), suffix)
    False -> text
  }
}

fn checksum(bytes, offset, total) {
  case bytes {
    <<>> -> total
    <<byte, rest:bits>> -> {
      let value = case offset >= 148 && offset < 156 {
        True -> 32
        False -> byte
      }
      checksum(rest, offset + 1, total + value)
    }
    _ -> -1
  }
}
