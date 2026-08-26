//// The filesystem tools: `fs_read`, `fs_write`, and `fs_edit`, plus
//// the production `FileSystem` seam and workspace path discipline.
////
//// `fs_read` renders hashline-anchored windows (`line:anchor|text`)
//// with the total line count and the whole-file digest, so edits can
//// reference exact content; `fs_edit` applies a multi-hunk
//// anchor-checked, digest-bound plan and rejects any staleness with
//// fresh anchors for replanning; `fs_write` creates or replaces a
//// whole file. All three resolve paths against the *real* filesystem
//// (`resolve_real`): symlinks are resolved component by component and
//// the resolved path must land under the (equally resolved) workspace
//// root, so neither `..` nor a symlink planted inside the workspace
//// can reach outside it. This is not defense in depth but the sole
//// boundary: these tools run in the harness and never pass through
//// the broker or the kernel jail, so path discipline is entirely
//// their own responsibility.
////
//// ## Replay safety
////
//// All three tools declare `replay: Safe`:
////
//// - `fs_read` is a read.
//// - `fs_write` is idempotent: re-running writes the same bytes to the
////   same path.
//// - `fs_edit` is bound by its digest: the plan carries the digest of
////   the exact content it was planned against, and `hashline.apply`
////   rejects any other content — including the plan's own output, and
////   including content where an identical sibling line shifted into a
////   referenced position (which defeats per-line anchors alone). A
////   crash replay therefore either repeats an edit that never landed
////   (the pre-image is intact, the edit applies exactly as intended)
////   or fails in-band as stale — it cannot double-apply. The residual
////   window is a digest collision between the pre- and post-image,
////   which requires equal byte length and equal FNV-64 (see
////   `tools/hashline`): impossible in practice by accident, and
////   deliberate construction gains nothing — the caller already holds
////   arbitrary write access to the same file through this very tool.

import broker/policy
import core/json.{type JsonValue}
import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import tools/blob
import tools/hashline
import tools/internal/ffi_path
import tools/tool.{type Ctx, type FileSystem, type FsError, type ToolOutcome}

/// Default number of lines an `fs_read` without `limit` returns.
pub const default_read_lines = 2000

/// Files larger than this many bytes are refused by `fs_read` (the
/// large-file guard): the whole file must be decoded to window it, so
/// unboundedly large files are read with jailed shell tools instead.
pub const max_read_bytes = 8_388_608

/// Why a path was rejected before any read or write.
pub type PathError {
  /// The path argument was empty.
  EmptyPath
  /// The path resolves outside the workspace root.
  EscapesWorkspace(path: String)
  /// The path could not be resolved against the real filesystem: an
  /// unreadable component, or a symlink chain longer than the
  /// resolution budget (a loop).
  Unresolvable(path: String, reason: String)
}

/// The production `FileSystem` seam, backed by simplifile.
pub fn real_filesystem() -> FileSystem {
  tool.FileSystem(
    read: fn(path) {
      simplifile.read_bits(path)
      |> result.map_error(map_file_error(path, _))
    },
    write: fn(path, bytes) {
      simplifile.write_bits(path, bytes)
      |> result.map_error(map_file_error(path, _))
    },
    create_directory_all: fn(path) {
      simplifile.create_directory_all(path)
      |> result.map_error(map_file_error(path, _))
    },
    is_file: fn(path) {
      simplifile.is_file(path)
      |> result.map_error(map_file_error(path, _))
    },
    read_link: fn(path) {
      ffi_path.read_link(path)
      |> result.map_error(fn(reason) { tool.FsFailure(path:, reason:) })
    },
  )
}

// simplifile's error vocabulary is the POSIX errno list — genuinely
// open-ended for our purposes, so the catch-all is deliberate.
fn map_file_error(path: String, error: simplifile.FileError) -> FsError {
  case error {
    simplifile.Enoent -> tool.FsNotFound(path:)
    simplifile.Eacces -> tool.FsPermissionDenied(path:)
    other -> tool.FsFailure(path:, reason: simplifile.describe_error(other))
  }
}

/// Resolves a tool-supplied path under the workspace root **lexically**
/// only: relative paths join under the root, `.` and `..` segments
/// collapse textually, and any result outside the root is rejected. No
/// symlink is resolved, so this is *not* a containment boundary on a
/// real filesystem — a symlink inside the workspace can point anywhere.
/// It is sufficient only where symlinks cannot betray it: for paths
/// handed to *jailed* executions (`grep`, where the kernel jail owns
/// containment) and for tests over filesystems without symlinks. The
/// harness-side fs tools use `resolve_real` instead.
///
/// ## Examples
///
/// ```gleam
/// assert fs.resolve_path("/work", "src/main.gleam")
///   == Ok("/work/src/main.gleam")
/// ```
///
/// ```gleam
/// assert fs.resolve_path("/work", "../etc/passwd")
///   == Error(fs.EscapesWorkspace("../etc/passwd"))
/// ```
///
pub fn resolve_path(
  workspace workspace: String,
  path path: String,
) -> Result(String, PathError) {
  let root = strip_trailing_slash(workspace)
  case path {
    "" -> Error(EmptyPath)
    "/" <> _ -> check_under(root, normalize(path), path)
    _ -> check_under(root, normalize(root <> "/" <> path), path)
  }
}

/// How many symlinks one resolution may follow before it is treated as
/// a loop (mirrors the kernel's `ELOOP` discipline).
pub const max_link_follows = 40

/// Resolves a tool-supplied path under the workspace root against the
/// **real** filesystem — the resolution the harness-side fs tools
/// trust, since they run outside every jail. Relative paths join under
/// the root; then both the root and the candidate are walked component
/// by component through `read_link`: symlinks are replaced by their
/// targets (POSIX order — a link is resolved *before* a following
/// `..`), `.`/`..` collapse against the resolved prefix, and
/// components past the deepest existing ancestor are kept verbatim
/// (they cannot be symlinks — nothing exists there). The fully
/// resolved candidate must land under the fully resolved root; the
/// returned path is the resolved one, so subsequent reads and writes
/// traverse no symlink at all. A symlinked workspace root works: the
/// root resolves once and containment compares resolved to resolved.
///
/// This closes the lexical hole: a symlink planted inside the
/// workspace (checked into a repo, or written by a jailed process) and
/// pointing outside it is rejected, dangling symlinks included — a
/// write through `link -> /outside/absent` would land outside, so the
/// link is resolved to its target and the target fails containment.
///
/// ## Examples
///
/// ```gleam
/// // With /work/link -> /etc on disk:
/// assert fs.resolve_real(filesystem, "/work", "link/passwd")
///   == Error(fs.EscapesWorkspace("link/passwd"))
/// ```
///
pub fn resolve_real(
  filesystem filesystem: FileSystem,
  workspace workspace: String,
  path path: String,
) -> Result(String, PathError) {
  let root = strip_trailing_slash(workspace)
  case path {
    "" -> Error(EmptyPath)
    _ -> {
      let joined = case path {
        "/" <> _ -> path
        _ -> root <> "/" <> path
      }
      use real_root <- result.try(
        walk(filesystem, root)
        |> result.map_error(Unresolvable(path:, reason: _)),
      )
      use resolved <- result.try(
        walk(filesystem, joined)
        |> result.map_error(Unresolvable(path:, reason: _)),
      )
      check_under(real_root, resolved, path)
    }
  }
}

// Resolves an absolute path against the real filesystem, component by
// component. The accumulator stack holds resolved components (each
// verified not to be a symlink, or known missing); `..` pops it, which
// is sound exactly because no stack entry is a link. Once a component
// is missing, everything deeper is kept verbatim: nothing can exist —
// or be a symlink — below a missing component.
fn walk(filesystem: FileSystem, path: String) -> Result(String, String) {
  walk_loop(
    filesystem,
    stack: [],
    remaining: string.split(path, on: "/"),
    missing: False,
    budget: max_link_follows,
  )
}

fn walk_loop(
  filesystem: FileSystem,
  stack stack: List(String),
  remaining remaining: List(String),
  missing missing: Bool,
  budget budget: Int,
) -> Result(String, String) {
  case remaining {
    [] -> Ok("/" <> string.join(list.reverse(stack), with: "/"))
    ["", ..rest] | [".", ..rest] ->
      walk_loop(filesystem, stack:, remaining: rest, missing:, budget:)
    ["..", ..rest] -> {
      let stack = case stack {
        [] -> []
        [_, ..parent] -> parent
      }
      walk_loop(filesystem, stack:, remaining: rest, missing:, budget:)
    }
    [segment, ..rest] ->
      walk_segment(filesystem, stack, segment, rest, missing, budget)
  }
}

// Resolves one path segment. Inside an already-missing prefix nothing
// can exist below it — so nothing there can be a symlink either — and
// the segment is kept verbatim; otherwise `read_link` tells a plain
// component from a symlink that must be followed.
fn walk_segment(
  filesystem: FileSystem,
  stack: List(String),
  segment: String,
  rest: List(String),
  missing: Bool,
  budget: Int,
) -> Result(String, String) {
  case missing {
    True ->
      walk_loop(
        filesystem,
        stack: [segment, ..stack],
        remaining: rest,
        missing: True,
        budget:,
      )
    False -> {
      let candidate =
        "/" <> string.join(list.reverse([segment, ..stack]), with: "/")
      case filesystem.read_link(candidate) {
        Error(error) -> Error(fs_error_text(error))
        Ok(tool.NotALink) ->
          walk_loop(
            filesystem,
            stack: [segment, ..stack],
            remaining: rest,
            missing: False,
            budget:,
          )
        Ok(tool.LinkMissing) ->
          walk_loop(
            filesystem,
            stack: [segment, ..stack],
            remaining: rest,
            missing: True,
            budget:,
          )
        Ok(tool.LinkTarget(target:)) ->
          walk_link_target(filesystem, stack, rest, budget, target)
      }
    }
  }
}

// Follows a resolved symlink target, respecting the loop budget
// (mirrors the kernel's `ELOOP`). An absolute target restarts the
// stack at root; a relative one is appended in front of what
// remained. The segment that named the link is not pushed — it is
// replaced by its target, not kept alongside it.
fn walk_link_target(
  filesystem: FileSystem,
  stack: List(String),
  rest: List(String),
  budget: Int,
  target: String,
) -> Result(String, String) {
  case budget < 1 {
    True -> Error("too many symlinks (loop?)")
    False -> {
      let target_segments = string.split(target, on: "/")
      let #(stack, remaining) = case target {
        "/" <> _ -> #([], list.append(target_segments, rest))
        _ -> #(stack, list.append(target_segments, rest))
      }
      walk_loop(
        filesystem,
        stack:,
        remaining:,
        missing: False,
        budget: budget - 1,
      )
    }
  }
}

// A short description of a seam error for `Unresolvable`.
fn fs_error_text(error: FsError) -> String {
  case error {
    tool.FsNotFound(path:) -> "not found: " <> path
    tool.FsPermissionDenied(path:) -> "permission denied: " <> path
    tool.FsFailure(path:, reason:) -> reason <> ": " <> path
  }
}

fn strip_trailing_slash(path: String) -> String {
  case path != "/" && string.ends_with(path, "/") {
    True -> string.drop_end(path, 1)
    False -> path
  }
}

fn check_under(
  root: String,
  candidate: String,
  original: String,
) -> Result(String, PathError) {
  let inside = case root {
    "/" -> True
    _ -> candidate == root || string.starts_with(candidate, root <> "/")
  }
  case inside {
    True -> Ok(candidate)
    False -> Error(EscapesWorkspace(path: original))
  }
}

// Lexical normalization: collapse `.`, empty segments, and `..`
// (popping past the filesystem root stays at the root; the caller's
// under-workspace check rejects the escape).
fn normalize(path: String) -> String {
  let segments =
    string.split(path, on: "/")
    |> list.fold([], fn(stack, segment) {
      case segment {
        "" | "." -> stack
        ".." ->
          case stack {
            [] -> []
            [_, ..rest] -> rest
          }
        _ -> [segment, ..stack]
      }
    })
  "/" <> string.join(list.reverse(segments), with: "/")
}

// --- fs_read -------------------------------------------------------------

/// The `fs_read` tool: hashline-anchored windowed reads.
pub fn read_tool() -> tool.Tool {
  tool.Tool(
    name: "fs_read",
    description: "Read a text file as anchored lines (line:anchor|text). "
      <> "Use offset/limit to window large files; anchors are what fs_edit "
      <> "hunks must reference, and the details carry the file digest "
      <> "fs_edit requires.",
    schema: tool.object_schema(
      [
        #("path", tool.string_property("file path under the workspace root")),
        #(
          "offset",
          tool.integer_property("1-based first line of the window (default 1)"),
        ),
        #(
          "limit",
          tool.integer_property(
            "maximum lines to return (default "
            <> int.to_string(default_read_lines)
            <> ")",
          ),
        ),
      ],
      ["path"],
    ),
    replay: tool.Safe,
    execution_mode: tool.Concurrent,
    requirements: read_only_requirements,
    run: run_read,
  )
}

fn run_read(ctx: Ctx, args: JsonValue) -> ToolOutcome {
  use path <- tool.with_arg(tool.required_string(args, "path"))
  use offset <- tool.with_arg(tool.optional_int(args, "offset"))
  use limit <- tool.with_arg(tool.optional_int(args, "limit"))
  let offset = option.unwrap(offset, 1)
  let limit = option.unwrap(limit, default_read_lines)
  use <- bool.guard(
    when: offset < 1 || limit < 1,
    return: tool.failure("invalid arguments: offset and limit must be >= 1"),
  )
  use resolved <- tool.or_outcome(
    resolve_real(filesystem: ctx.filesystem, workspace: ctx.workspace, path:),
    path_outcome,
  )
  use content <- tool.or_outcome(read_text(ctx, resolved), identity_outcome)
  read_outcome(path, content, offset, limit)
}

fn read_outcome(
  path: String,
  content: String,
  offset: Int,
  limit: Int,
) -> ToolOutcome {
  let window = hashline.window(content, offset:, limit:)
  let text = case window.lines {
    [] -> empty_window_text(window.total_lines, offset)
    _ -> hashline.render(window)
  }
  // An anchored read must stay inline — anchors in a blob would be
  // useless for planning edits — so an oversized window is refused
  // (spec §3.2 overflow applies to opaque outputs like bash/grep;
  // windowing is fs_read's bounding mechanism).
  use <- bool.guard(
    when: bit_array.byte_size(<<text:utf8>>) > blob.overflow_threshold_bytes,
    return: tool.failure(
      "the requested window renders larger than "
      <> int.to_string(blob.overflow_threshold_bytes)
      <> " bytes; read a smaller window (lower `limit`)",
    ),
  )
  tool.success(text)
  |> tool.with_details(
    json.Object([
      #("path", json.String(path)),
      #("offset", json.Int(window.offset)),
      #("limit", json.Int(limit)),
      #("total_lines", json.Int(window.total_lines)),
      #("has_more", json.Bool(window.has_more)),
      #("trailing_newline", json.Bool(window.trailing_newline)),
      #("digest", json.String(hashline.digest(content))),
      #("anchor_version", json.Int(hashline.anchor_version)),
    ]),
  )
}

// The message for a window with no lines in it: an empty file reads
// differently from an offset past the end of a non-empty one.
fn empty_window_text(total_lines: Int, offset: Int) -> String {
  case total_lines {
    0 -> "(empty file)"
    total ->
      "(no lines at offset "
      <> int.to_string(offset)
      <> "; the file has "
      <> int.to_string(total)
      <> " lines)"
  }
}

// `read_text` already renders its failure as a `ToolOutcome`, so
// chaining it through `tool.or_outcome` needs no mapping.
fn identity_outcome(outcome: ToolOutcome) -> ToolOutcome {
  outcome
}

// Reads and decodes a file for the text tools; failures are in-band
// outcomes.
fn read_text(ctx: Ctx, resolved: String) -> Result(String, ToolOutcome) {
  use bytes <- result.try(
    ctx.filesystem.read(resolved) |> result.map_error(fs_error_outcome),
  )
  use <- bool.guard(
    when: bit_array.byte_size(bytes) > max_read_bytes,
    return: Error(tool.failure(
      "file is larger than "
      <> int.to_string(max_read_bytes)
      <> " bytes; read it in pieces with the bash tool instead",
    )),
  )
  bit_array.to_string(bytes)
  |> result.replace_error(tool.failure(
    "file is not valid UTF-8 text; use the bash tool for binary files",
  ))
}

// --- fs_write ------------------------------------------------------------

/// The `fs_write` tool: create or replace a whole file.
pub fn write_tool() -> tool.Tool {
  tool.Tool(
    name: "fs_write",
    description: "Create or overwrite a whole file with the given content. "
      <> "Parent directories are created as needed.",
    schema: tool.object_schema(
      [
        #("path", tool.string_property("file path under the workspace root")),
        #("content", tool.string_property("the complete new file content")),
      ],
      ["path", "content"],
    ),
    replay: tool.Safe,
    execution_mode: tool.Exclusive,
    requirements: workspace_requirements,
    run: run_write,
  )
}

fn run_write(ctx: Ctx, args: JsonValue) -> ToolOutcome {
  use path <- tool.with_arg(tool.required_string(args, "path"))
  use content <- tool.with_arg(tool.required_string(args, "content"))
  use resolved <- tool.or_outcome(
    resolve_real(filesystem: ctx.filesystem, workspace: ctx.workspace, path:),
    path_outcome,
  )
  let bytes = <<content:utf8>>
  use Nil <- tool.or_outcome(
    write_file(ctx.filesystem, resolved, bytes),
    fs_error_outcome,
  )
  write_outcome(path, bytes)
}

// Creates any missing parent directories, then writes the whole file —
// the two-step seam operation `fs_write` needs from a resolved path.
fn write_file(
  filesystem: FileSystem,
  resolved: String,
  bytes: BitArray,
) -> Result(Nil, FsError) {
  use Nil <- result.try(
    filesystem.create_directory_all(parent_directory(resolved)),
  )
  filesystem.write(resolved, bytes)
}

fn write_outcome(path: String, bytes: BitArray) -> ToolOutcome {
  tool.success(
    "wrote "
    <> int.to_string(bit_array.byte_size(bytes))
    <> " bytes to "
    <> path,
  )
  |> tool.with_details(
    json.Object([
      #("path", json.String(path)),
      #("bytes", json.Int(bit_array.byte_size(bytes))),
    ]),
  )
}

// The directory part of an absolute path ("/" for top-level entries).
fn parent_directory(path: String) -> String {
  case string.split(path, on: "/") |> list.reverse {
    [_name, ..rest] ->
      case list.reverse(rest) |> string.join(with: "/") {
        "" -> "/"
        parent -> parent
      }
    [] -> "/"
  }
}

// --- fs_edit -------------------------------------------------------------

/// The `fs_edit` tool: anchor-checked multi-hunk edits.
pub fn edit_tool() -> tool.Tool {
  tool.Tool(
    name: "fs_edit",
    description: "Apply anchored edit hunks to a file. Pass the digest from "
      <> "fs_read's details; each hunk references lines by the {line, anchor} "
      <> "pairs from fs_read. A stale anchor or a changed file rejects the "
      <> "whole edit and returns fresh anchors and the fresh digest.",
    schema: edit_schema(),
    replay: tool.Safe,
    execution_mode: tool.Exclusive,
    requirements: workspace_requirements,
    run: run_edit,
  )
}

// The `op` enum schema, naming the four hunk operations `fs_edit` accepts.
fn hunk_op_schema() -> JsonValue {
  json.Object([
    #("type", json.String("string")),
    #(
      "enum",
      json.Array([
        json.String("replace"),
        json.String("delete"),
        json.String("insert_after"),
        json.String("insert_at_start"),
      ]),
    ),
  ])
}

// The `hunks` array schema: the per-hunk item schema plus the note that
// every hunk is checked before any is applied.
fn hunks_schema(hunk: JsonValue) -> JsonValue {
  json.Object([
    #("type", json.String("array")),
    #("items", hunk),
    #(
      "description",
      json.String(
        "edit hunks; all anchors and the digest are checked before "
        <> "any hunk is applied",
      ),
    ),
  ])
}

fn edit_schema() -> JsonValue {
  let anchor_ref =
    tool.object_schema(
      [
        #("line", tool.integer_property("1-based line number from fs_read")),
        #("anchor", tool.string_property("the line's anchor from fs_read")),
      ],
      ["line", "anchor"],
    )
  let hunk =
    json.Object([
      #("type", json.String("object")),
      #(
        "properties",
        json.Object([
          #("op", hunk_op_schema()),
          #("from", anchor_ref),
          #("to", anchor_ref),
          #("at", anchor_ref),
          #(
            "lines",
            tool.string_array_property("replacement lines, without newlines"),
          ),
        ]),
      ),
      #("required", json.Array([json.String("op")])),
    ])
  json.Object([
    #("type", json.String("object")),
    #(
      "properties",
      json.Object([
        #("path", tool.string_property("file path under the workspace root")),
        #(
          "digest",
          tool.string_property(
            "the file digest from fs_read's details; the edit applies only "
            <> "if the file is still exactly that content",
          ),
        ),
        #("hunks", hunks_schema(hunk)),
      ]),
    ),
    #(
      "required",
      json.Array([
        json.String("path"),
        json.String("digest"),
        json.String("hunks"),
      ]),
    ),
    #("additionalProperties", json.Bool(False)),
  ])
}

fn run_edit(ctx: Ctx, args: JsonValue) -> ToolOutcome {
  use path <- tool.with_arg(tool.required_string(args, "path"))
  use digest <- tool.with_arg(tool.required_string(args, "digest"))
  use hunks <- tool.with_arg(decode_hunks(args))
  use resolved <- tool.or_outcome(
    resolve_real(filesystem: ctx.filesystem, workspace: ctx.workspace, path:),
    path_outcome,
  )
  use content <- tool.or_outcome(read_text(ctx, resolved), identity_outcome)
  use edited <- tool.or_outcome(
    hashline.apply(content, hashline.Plan(digest:, hunks:)),
    apply_error_outcome,
  )
  use Nil <- tool.or_outcome(
    ctx.filesystem.write(resolved, <<edited:utf8>>),
    fs_error_outcome,
  )
  edit_outcome(path, hunks, edited)
}

fn edit_outcome(
  path: String,
  hunks: List(hashline.Hunk),
  edited: String,
) -> ToolOutcome {
  let total_lines = list.length(hashline.split_lines(edited).lines)
  tool.success(
    "applied " <> int.to_string(list.length(hunks)) <> " hunk(s) to " <> path,
  )
  |> tool.with_details(
    json.Object([
      #("path", json.String(path)),
      #("hunks_applied", json.Int(list.length(hunks))),
      #("total_lines", json.Int(total_lines)),
      #("digest", json.String(hashline.digest(edited))),
      #("anchor_version", json.Int(hashline.anchor_version)),
    ]),
  )
}

fn decode_hunks(args: JsonValue) -> Result(List(hashline.Hunk), String) {
  case object_field(args, "hunks") {
    Ok(json.Array(items)) ->
      case items {
        [] -> Error("`hunks` must not be empty")
        _ -> list.try_map(items, decode_hunk)
      }
    Ok(_) -> Error("`hunks` must be an array")
    Error(Nil) -> Error("`hunks` is required")
  }
}

fn decode_hunk(value: JsonValue) -> Result(hashline.Hunk, String) {
  use op <- result.try(tool.required_string(value, "op"))
  case op {
    "replace" -> {
      use from <- result.try(decode_ref(value, "from"))
      use to <- result.try(decode_ref(value, "to"))
      use lines <- result.try(required_lines(value))
      Ok(hashline.Replace(from:, to:, lines:))
    }
    "delete" -> {
      use from <- result.try(decode_ref(value, "from"))
      use to <- result.try(decode_ref(value, "to"))
      Ok(hashline.Delete(from:, to:))
    }
    "insert_after" -> {
      use at <- result.try(decode_ref(value, "at"))
      use lines <- result.try(required_lines(value))
      Ok(hashline.InsertAfter(at:, lines:))
    }
    "insert_at_start" -> {
      use lines <- result.try(required_lines(value))
      Ok(hashline.InsertAtStart(lines:))
    }
    other ->
      Error(
        "unknown hunk op `"
        <> other
        <> "` (expected replace, delete, insert_after, or insert_at_start)",
      )
  }
}

fn decode_ref(value: JsonValue, key: String) -> Result(hashline.Ref, String) {
  case object_field(value, key) {
    Error(Nil) -> Error("`" <> key <> "` is required for this hunk op")
    Ok(ref_value) -> {
      use line <- result.try(require(
        tool.optional_int(ref_value, "line"),
        when_absent: "`" <> key <> ".line` is required",
      ))
      use anchor <- result.try(tool.required_string(ref_value, "anchor"))
      Ok(hashline.Ref(line:, anchor:))
    }
  }
}

fn required_lines(value: JsonValue) -> Result(List(String), String) {
  require(
    tool.optional_string_list(value, "lines"),
    when_absent: "`lines` is required for this hunk op",
  )
}

// Turns "optional, and possibly malformed" into "required, for this
// hunk op" — the shape every `tool.optional_*` decoder returns, and
// the one `decode_ref`'s line field and `required_lines` both need.
fn require(
  optional: Result(Option(a), String),
  when_absent when_absent: String,
) -> Result(a, String) {
  case optional {
    Ok(Some(value)) -> Ok(value)
    Ok(None) -> Error(when_absent)
    Error(reason) -> Error(reason)
  }
}

fn apply_error_outcome(error: hashline.ApplyError) -> ToolOutcome {
  case error {
    hashline.MalformedPlan(reason:) ->
      tool.failure("invalid edit plan: " <> reason)
    hashline.OverlappingHunks(line:) ->
      tool.failure(
        "invalid edit plan: hunks overlap at line " <> int.to_string(line),
      )
    hashline.StaleAnchors(stale:) -> {
      let regions =
        stale
        |> list.map(stale_region_text)
        |> string.join(with: "\n")
      tool.failure(
        "stale anchors: the file changed since it was read; re-plan against "
        <> "these fresh anchors\n"
        <> regions,
      )
      |> tool.with_details(
        json.Object([
          #("error", json.String("stale_anchors")),
          #("stale", json.Array(list.map(stale, encode_stale_entry))),
          #("anchor_version", json.Int(hashline.anchor_version)),
        ]),
      )
    }
    hashline.StaleContent(digest:, fresh:) ->
      tool.failure(
        "stale content: the file is no longer the exact content this edit "
        <> "was planned against (or the edit already applied); re-plan "
        <> "against digest "
        <> digest
        <> " and these fresh anchors\n"
        <> fresh_lines_text(fresh),
      )
      |> tool.with_details(
        json.Object([
          #("error", json.String("stale_content")),
          #("digest", json.String(digest)),
          #("fresh", json.Array(list.map(fresh, encode_anchored_line))),
          #("anchor_version", json.Int(hashline.anchor_version)),
        ]),
      )
  }
}

// The rendered text of one stale hunk's fresh replacement lines,
// shared by the `StaleAnchors` and `StaleContent` repair messages.
fn fresh_lines_text(fresh: List(hashline.AnchoredLine)) -> String {
  fresh
  |> list.map(hashline.render_line)
  |> string.join(with: "\n")
}

// The repair message for one stale hunk: where it was expected, and
// the fresh anchors to re-plan against.
fn stale_region_text(entry: hashline.Stale) -> String {
  "line "
  <> int.to_string(entry.line)
  <> " (expected "
  <> entry.expected
  <> "):\n"
  <> fresh_lines_text(entry.fresh)
}

fn encode_anchored_line(anchored: hashline.AnchoredLine) -> JsonValue {
  json.Object([
    #("line", json.Int(anchored.line)),
    #("anchor", json.String(anchored.anchor)),
    #("text", json.String(anchored.text)),
  ])
}

fn encode_stale_entry(entry: hashline.Stale) -> JsonValue {
  json.Object([
    #("line", json.Int(entry.line)),
    #("expected_anchor", json.String(entry.expected)),
    #("fresh", json.Array(list.map(entry.fresh, encode_anchored_line))),
  ])
}

// --- shared plumbing -----------------------------------------------------

// First occurrence of a field in a JSON object.
fn object_field(value: JsonValue, key: String) -> Result(JsonValue, Nil) {
  case value {
    json.Object(fields:) ->
      list.find_map(fields, fn(entry) {
        case entry.0 == key {
          True -> Ok(entry.1)
          False -> Error(Nil)
        }
      })
    _ -> Error(Nil)
  }
}

/// Renders a `PathError` as the in-band failure result the model reads.
/// Shared with `tools/grep`, whose lexical `resolve_path` fails the same
/// way for the same reasons.
pub fn path_outcome(error: PathError) -> ToolOutcome {
  case error {
    EmptyPath -> tool.failure("invalid arguments: `path` must not be empty")
    EscapesWorkspace(path:) ->
      tool.failure("path `" <> path <> "` resolves outside the workspace root")
    Unresolvable(path:, reason:) ->
      tool.failure("path `" <> path <> "` could not be resolved: " <> reason)
  }
}

fn fs_error_outcome(error: FsError) -> ToolOutcome {
  case error {
    tool.FsNotFound(path:) -> tool.failure("file not found: " <> path)
    tool.FsPermissionDenied(path:) ->
      tool.failure("permission denied: " <> path)
    tool.FsFailure(path:, reason:) ->
      tool.failure("filesystem error on " <> path <> ": " <> reason)
  }
}

// Read-only tools ask for exactly a readable workspace; write tools ask
// for a writable one. The fs tools run harness-side and never dispatch
// through the broker, but the declaration still states their needs in
// the policy vocabulary for uniform inspection.
fn read_only_requirements(workspace: String) -> policy.SandboxPolicy {
  tool.read_requirements(workspace)
}

fn workspace_requirements(workspace: String) -> policy.SandboxPolicy {
  tool.write_requirements(workspace)
}
