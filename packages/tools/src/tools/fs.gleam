//// The filesystem tools: `fs_read`, `fs_write`, and `fs_edit`, plus
//// the production `FileSystem` seam and workspace path discipline.
////
//// `fs_read` renders hashline-anchored windows (`line:anchor|text`)
//// with the total line count, so edits can reference exact content;
//// `fs_edit` applies a multi-hunk anchor-checked plan and rejects any
//// stale anchor with fresh anchors for the stale regions; `fs_write`
//// creates or replaces a whole file. All three resolve paths under the
//// workspace root and reject escapes (`..`, absolute paths outside the
//// root) as structured errors — defense in depth: these tools run in
//// the harness, not in a jail, so path discipline is their own
//// responsibility.
////
//// ## Replay safety
////
//// All three tools declare `replay: Safe`:
////
//// - `fs_read` is a read.
//// - `fs_write` is idempotent: re-running writes the same bytes to the
////   same path.
//// - `fs_edit` is guarded by its anchors: applying a plan consumes the
////   anchors it referenced (the replaced lines are gone afterwards),
////   so re-executing the same call against the already-edited file is
////   *rejected* as stale rather than applied twice. Re-execution after
////   a crash therefore either repeats an edit that never landed or
////   fails in-band — it can never double-apply.

import broker/policy
import core/json.{type JsonValue}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import simplifile
import tools/blob
import tools/hashline
import tools/tool.{type Ctx, type FileSystem, type FsError, type ToolOutcome}

/// Default number of lines an `fs_read` without `limit` returns.
pub const default_read_lines = 2000

/// Files larger than this many bytes are refused by `fs_read` (the
/// large-file guard): the whole file must be decoded to window it, so
/// unboundedly large files are read with jailed shell tools instead.
pub const max_read_bytes = 8_388_608

/// Why a path was rejected before touching the filesystem.
pub type PathError {
  /// The path argument was empty.
  EmptyPath
  /// The path resolves outside the workspace root.
  EscapesWorkspace(path: String)
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

/// Resolves a tool-supplied path under the workspace root. Relative
/// paths join under the root; absolute paths must already be under it.
/// `.` and `..` segments are normalized lexically (no symlink
/// traversal — the sandbox owns that concern for jailed processes;
/// this is harness-side defense in depth), and any result outside the
/// root is rejected.
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
      <> "hunks must reference.",
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
  case offset < 1 || limit < 1 {
    True -> tool.failure("invalid arguments: offset and limit must be >= 1")
    False ->
      case resolve_path(workspace: ctx.workspace, path:) {
        Error(error) -> path_outcome(error)
        Ok(resolved) ->
          case read_text(ctx, resolved) {
            Error(outcome) -> outcome
            Ok(content) -> read_outcome(path, content, offset, limit)
          }
      }
  }
}

fn read_outcome(
  path: String,
  content: String,
  offset: Int,
  limit: Int,
) -> ToolOutcome {
  let window = hashline.window(content, offset:, limit:)
  let text = case window.lines {
    [] ->
      case window.total_lines {
        0 -> "(empty file)"
        total ->
          "(no lines at offset "
          <> int.to_string(offset)
          <> "; the file has "
          <> int.to_string(total)
          <> " lines)"
      }
    _ -> hashline.render(window)
  }
  // An anchored read must stay inline — anchors in a blob would be
  // useless for planning edits — so an oversized window is refused
  // (spec §3.2 overflow applies to opaque outputs like bash/grep;
  // windowing is fs_read's bounding mechanism).
  case bit_array.byte_size(<<text:utf8>>) > blob.overflow_threshold_bytes {
    True ->
      tool.failure(
        "the requested window renders larger than "
        <> int.to_string(blob.overflow_threshold_bytes)
        <> " bytes; read a smaller window (lower `limit`)",
      )
    False ->
      tool.success(text)
      |> tool.with_details(
        json.Object([
          #("path", json.String(path)),
          #("offset", json.Int(window.offset)),
          #("limit", json.Int(limit)),
          #("total_lines", json.Int(window.total_lines)),
          #("has_more", json.Bool(window.has_more)),
          #("trailing_newline", json.Bool(window.trailing_newline)),
          #("anchor_version", json.Int(hashline.anchor_version)),
        ]),
      )
  }
}

// Reads and decodes a file for the text tools; failures are in-band
// outcomes.
fn read_text(ctx: Ctx, resolved: String) -> Result(String, ToolOutcome) {
  let filesystem = ctx.filesystem
  case filesystem.read(resolved) {
    Error(error) -> Error(fs_error_outcome(error))
    Ok(bytes) ->
      case bit_array.byte_size(bytes) > max_read_bytes {
        True ->
          Error(tool.failure(
            "file is larger than "
            <> int.to_string(max_read_bytes)
            <> " bytes; read it in pieces with the bash tool instead",
          ))
        False ->
          case bit_array.to_string(bytes) {
            Ok(content) -> Ok(content)
            Error(Nil) ->
              Error(tool.failure(
                "file is not valid UTF-8 text; use the bash tool for binary "
                <> "files",
              ))
          }
      }
  }
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
  case resolve_path(workspace: ctx.workspace, path:) {
    Error(error) -> path_outcome(error)
    Ok(resolved) -> {
      let filesystem = ctx.filesystem
      let bytes = <<content:utf8>>
      let written = {
        use Nil <- result.try(
          filesystem.create_directory_all(parent_directory(resolved)),
        )
        filesystem.write(resolved, bytes)
      }
      case written {
        Error(error) -> fs_error_outcome(error)
        Ok(Nil) ->
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
    }
  }
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
    description: "Apply anchored edit hunks to a file. Each hunk references "
      <> "lines by the {line, anchor} pairs from fs_read; a stale anchor "
      <> "rejects the whole edit and returns fresh anchors.",
    schema: edit_schema(),
    replay: tool.Safe,
    execution_mode: tool.Exclusive,
    requirements: workspace_requirements,
    run: run_edit,
  )
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
          #(
            "op",
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
            ]),
          ),
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
          "hunks",
          json.Object([
            #("type", json.String("array")),
            #("items", hunk),
            #(
              "description",
              json.String(
                "edit hunks; all anchors are checked before any "
                <> "hunk is applied",
              ),
            ),
          ]),
        ),
      ]),
    ),
    #("required", json.Array([json.String("path"), json.String("hunks")])),
    #("additionalProperties", json.Bool(False)),
  ])
}

fn run_edit(ctx: Ctx, args: JsonValue) -> ToolOutcome {
  use path <- tool.with_arg(tool.required_string(args, "path"))
  use hunks <- tool.with_arg(decode_hunks(args))
  case resolve_path(workspace: ctx.workspace, path:) {
    Error(error) -> path_outcome(error)
    Ok(resolved) ->
      case read_text(ctx, resolved) {
        Error(outcome) -> outcome
        Ok(content) ->
          case hashline.apply(content, hashline.Plan(hunks:)) {
            Error(error) -> apply_error_outcome(error)
            Ok(edited) -> {
              let filesystem = ctx.filesystem
              case filesystem.write(resolved, <<edited:utf8>>) {
                Error(error) -> fs_error_outcome(error)
                Ok(Nil) -> {
                  let total_lines =
                    list.length(hashline.split_lines(edited).lines)
                  tool.success(
                    "applied "
                    <> int.to_string(list.length(hunks))
                    <> " hunk(s) to "
                    <> path,
                  )
                  |> tool.with_details(
                    json.Object([
                      #("path", json.String(path)),
                      #("hunks_applied", json.Int(list.length(hunks))),
                      #("total_lines", json.Int(total_lines)),
                      #("anchor_version", json.Int(hashline.anchor_version)),
                    ]),
                  )
                }
              }
            }
          }
      }
  }
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
      use line <- result.try(case tool.optional_int(ref_value, "line") {
        Ok(Some(line)) -> Ok(line)
        Ok(None) -> Error("`" <> key <> ".line` is required")
        Error(reason) -> Error(reason)
      })
      use anchor <- result.try(tool.required_string(ref_value, "anchor"))
      Ok(hashline.Ref(line:, anchor:))
    }
  }
}

fn required_lines(value: JsonValue) -> Result(List(String), String) {
  case tool.optional_string_list(value, "lines") {
    Ok(Some(lines)) -> Ok(lines)
    Ok(None) -> Error("`lines` is required for this hunk op")
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
        |> list.map(fn(entry) {
          "line "
          <> int.to_string(entry.line)
          <> " (expected "
          <> entry.expected
          <> "):\n"
          <> {
            entry.fresh
            |> list.map(hashline.render_line)
            |> string.join(with: "\n")
          }
        })
        |> string.join(with: "\n")
      tool.failure(
        "stale anchors: the file changed since it was read; re-plan against "
        <> "these fresh anchors\n"
        <> regions,
      )
      |> tool.with_details(
        json.Object([
          #("error", json.String("stale_anchors")),
          #(
            "stale",
            json.Array(
              list.map(stale, fn(entry) {
                json.Object([
                  #("line", json.Int(entry.line)),
                  #("expected_anchor", json.String(entry.expected)),
                  #(
                    "fresh",
                    json.Array(
                      list.map(entry.fresh, fn(anchored) {
                        json.Object([
                          #("line", json.Int(anchored.line)),
                          #("anchor", json.String(anchored.anchor)),
                          #("text", json.String(anchored.text)),
                        ])
                      }),
                    ),
                  ),
                ])
              }),
            ),
          ),
          #("anchor_version", json.Int(hashline.anchor_version)),
        ]),
      )
    }
  }
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

fn path_outcome(error: PathError) -> ToolOutcome {
  case error {
    EmptyPath -> tool.failure("invalid arguments: `path` must not be empty")
    EscapesWorkspace(path:) ->
      tool.failure("path `" <> path <> "` resolves outside the workspace root")
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
