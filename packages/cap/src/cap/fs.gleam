//// `cap/fs` — workspace filesystem access, as typed calls over the
//// broker. Importing this module is the permission: a program with no
//// `import cap/fs` cannot touch the filesystem at all. Every function
//// resolves against the workspace policy the broker composed for this
//// execution; a path outside it comes back as a typed `FsError`, never a
//// silent escape.
////
//// These mirror the harness-side `tools/fs` capabilities (`fs_read`,
//// `fs_write`, `fs_edit`) but as an in-satellite API whose bodies are
//// RPC stubs to the broker.

import cap/internal/channel.{type CallError, Denied, Unreachable}
import cap/internal/dispatch
import cap/internal/wire
import core/msgpack.{type MsgPackValue}
import gleam/list
import gleam/result

/// Why a filesystem call failed. Descriptive variants for the causes a
/// program branches on; `FsFailed` carries any other broker code
/// verbatim; `FsUnavailable` is a transport failure.
pub type FsError {
  /// No such path.
  NotFound(path: String)
  /// The policy does not grant this path (read or write).
  PermissionDenied(path: String)
  /// A `read` target is a directory, or a `write` target's parent is a
  /// file — an operation/kind mismatch.
  WrongKind(path: String, message: String)
  /// An `edit` referenced content that no longer matches; replan.
  StaleContent(path: String, message: String)
  /// A structurally invalid argument (empty path, bad edit).
  InvalidArgument(message: String)
  /// Any other in-band broker refusal, code preserved.
  FsFailed(code: String, message: String)
  /// The capability channel could not carry the call.
  FsUnavailable(reason: String)
}

/// One directory entry from `list`.
pub type DirEntry {
  DirEntry(name: String, is_directory: Bool)
}

/// One find/replace edit for `edit`. `find` is matched as an exact
/// substring and must match **exactly once**: zero matches refuses the
/// whole edit as `StaleContent` — the file no longer contains your text —
/// and more than one refuses it as `InvalidArgument`, because a
/// replacement carries no position to say which occurrence was meant;
/// include enough surrounding text to be unique. There are no anchors and
/// no digest on this wire: staleness here means the find text itself, not
/// a pin.
pub type Replacement {
  Replacement(find: String, replace_with: String)
}

/// Reads a file's contents as text.
///
/// Capability: `fs.read`.
pub fn read(path: String) -> Result(String, FsError) {
  let args = wire.args([#("path", wire.string(path))])
  use value <- result.try(
    dispatch.call("fs.read", args) |> result.map_error(map_error(_, path)),
  )
  wire.string_field(value, "contents")
  |> result.map_error(fn(reason) {
    FsUnavailable("bad fs.read result: " <> reason)
  })
}

/// Writes `contents` to `path`, creating or replacing the whole file.
///
/// Capability: `fs.write`.
pub fn write(path: String, contents: String) -> Result(Nil, FsError) {
  let args =
    wire.args([
      #("path", wire.string(path)),
      #("contents", wire.string(contents)),
    ])
  dispatch.call("fs.write", args)
  |> result.replace(Nil)
  |> result.map_error(map_error(_, path))
}

/// Lists a directory's entries.
///
/// Capability: `fs.list`.
pub fn list(path: String) -> Result(List(DirEntry), FsError) {
  let args = wire.args([#("path", wire.string(path))])
  use value <- result.try(
    dispatch.call("fs.list", args) |> result.map_error(map_error(_, path)),
  )
  wire.array_of(value, "entries", of: decode_entry)
  |> result.map_error(fn(reason) {
    FsUnavailable("bad fs.list result: " <> reason)
  })
}

/// Applies find/replace edits to a file, all-or-nothing: replacements
/// apply in order, each against the text the previous one produced, and
/// any refusal — a `find` that misses (`StaleContent`), one that matches
/// more than once, an empty one — leaves the file untouched. The
/// read-apply-write happens inside one harness-side call, a tighter
/// window than composing `read` and `write` across two calls; a
/// concurrent writer of the same file within the same execution can
/// still interleave, so a program racing itself should serialize its own
/// edits.
///
/// Capability: `fs.edit`.
pub fn edit(
  path: String,
  replacements: List(Replacement),
) -> Result(Nil, FsError) {
  let args =
    wire.args([
      #("path", wire.string(path)),
      #("edits", encode_replacements(replacements)),
    ])
  dispatch.call("fs.edit", args)
  |> result.replace(Nil)
  |> result.map_error(map_error(_, path))
}

fn encode_replacements(replacements: List(Replacement)) -> MsgPackValue {
  msgpack.ArrayValue(
    list.map(replacements, fn(replacement) {
      wire.args([
        #("find", wire.string(replacement.find)),
        #("replace_with", wire.string(replacement.replace_with)),
      ])
    }),
  )
}

fn decode_entry(value: MsgPackValue) -> Result(DirEntry, String) {
  use name <- result.try(wire.string_field(value, "name"))
  use is_directory <- result.try(wire.bool_field(value, "is_dir"))
  Ok(DirEntry(name:, is_directory:))
}

fn map_error(error: CallError, path: String) -> FsError {
  case error {
    Unreachable(reason:) -> FsUnavailable(reason:)
    Denied(code:, message:) ->
      case code {
        "not_found" -> NotFound(path:)
        "denied" | "policy" | "permission_denied" -> PermissionDenied(path:)
        "wrong_kind" | "not_a_directory" | "is_a_directory" ->
          WrongKind(path:, message:)
        "stale" | "stale_anchor" | "stale_content" ->
          StaleContent(path:, message:)
        "invalid_argument" -> InvalidArgument(message:)
        _ -> FsFailed(code:, message:)
      }
  }
}
