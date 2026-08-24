import core/json
import core/message
import gleam/erlang/process
import gleam/list
import gleam/option.{Some}
import gleam/string
import simplifile
import support/fake_broker
import support/memory_fs
import tools/fs
import tools/hashline
import tools/tool

// --- fixtures ------------------------------------------------------------

const workspace = "/work"

fn memory_ctx() -> #(tool.Ctx, tool.FileSystem) {
  let filesystem = memory_fs.filesystem(memory_fs.start())
  let recorded = process.new_subject()
  let ctx =
    fake_broker.ctx(workspace:, filesystem:, now: 1000, script: [], recorded:)
  #(ctx, filesystem)
}

// A fresh real temp directory under the package build dir, with a ctx
// rooted in it.
fn real_ctx(name: String) -> #(tool.Ctx, tool.FileSystem) {
  let assert Ok(here) = simplifile.current_directory()
  let root = here <> "/build/fs_test/" <> name
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  let filesystem = fs.real_filesystem()
  let recorded = process.new_subject()
  let ctx =
    fake_broker.ctx(
      workspace: root,
      filesystem:,
      now: 1000,
      script: [],
      recorded:,
    )
  #(ctx, filesystem)
}

fn write_file(ctx: tool.Ctx, relative: String, content: String) -> Nil {
  let filesystem = ctx.filesystem
  let assert Ok(resolved) =
    fs.resolve_path(workspace: ctx.workspace, path: relative)
  let assert Ok(Nil) = filesystem.write(resolved, <<content:utf8>>)
  Nil
}

fn args(fields: List(#(String, json.JsonValue))) -> json.JsonValue {
  json.Object(fields)
}

fn first_text(outcome: tool.ToolOutcome) -> String {
  let assert [message.ToolResultText(text:, text_signature: _)] =
    outcome.content
    as "expected a single text block"
  text
}

// --- resolve_path --------------------------------------------------------

pub fn resolve_relative_test() {
  assert fs.resolve_path(workspace: "/work", path: "src/a.gleam")
    == Ok("/work/src/a.gleam")
}

pub fn resolve_absolute_inside_test() {
  assert fs.resolve_path(workspace: "/work", path: "/work/a.txt")
    == Ok("/work/a.txt")
}

pub fn resolve_workspace_itself_test() {
  assert fs.resolve_path(workspace: "/work", path: "/work") == Ok("/work")
}

pub fn resolve_normalizes_dot_segments_test() {
  assert fs.resolve_path(workspace: "/work", path: "a/./b/../c")
    == Ok("/work/a/c")
}

pub fn resolve_rejects_parent_escape_test() {
  assert fs.resolve_path(workspace: "/work", path: "../etc/passwd")
    == Error(fs.EscapesWorkspace("../etc/passwd"))
}

pub fn resolve_rejects_deep_escape_test() {
  assert fs.resolve_path(workspace: "/work", path: "a/../../etc")
    == Error(fs.EscapesWorkspace("a/../../etc"))
}

pub fn resolve_rejects_absolute_outside_test() {
  assert fs.resolve_path(workspace: "/work", path: "/etc/passwd")
    == Error(fs.EscapesWorkspace("/etc/passwd"))
}

pub fn resolve_rejects_prefix_sibling_test() {
  // "/workspace" is not under "/work" even though it shares a prefix.
  assert fs.resolve_path(workspace: "/work", path: "/workspace/a")
    == Error(fs.EscapesWorkspace("/workspace/a"))
}

pub fn resolve_rejects_absolute_escape_via_dotdot_test() {
  assert fs.resolve_path(workspace: "/work", path: "/work/../etc")
    == Error(fs.EscapesWorkspace("/work/../etc"))
}

pub fn resolve_rejects_empty_test() {
  assert fs.resolve_path(workspace: "/work", path: "") == Error(fs.EmptyPath)
}

pub fn resolve_workspace_trailing_slash_test() {
  assert fs.resolve_path(workspace: "/work/", path: "a") == Ok("/work/a")
}

// --- fs_read -------------------------------------------------------------

pub fn read_renders_anchored_lines_test() {
  let #(ctx, _filesystem) = memory_ctx()
  write_file(ctx, "a.txt", "alpha\nbeta\n")
  let tool_value = fs.read_tool()
  let outcome = tool_value.run(ctx, args([#("path", json.String("a.txt"))]))
  assert outcome.is_error == False
  assert first_text(outcome)
    == "1:"
    <> hashline.anchor("alpha")
    <> "|alpha\n2:"
    <> hashline.anchor("beta")
    <> "|beta"
  let assert Some(json.Object(fields)) = outcome.details
  assert list.key_find(fields, "total_lines") == Ok(json.Int(2))
  assert list.key_find(fields, "has_more") == Ok(json.Bool(False))
  assert list.key_find(fields, "trailing_newline") == Ok(json.Bool(True))
  assert list.key_find(fields, "anchor_version")
    == Ok(json.Int(hashline.anchor_version))
}

pub fn read_window_test() {
  let #(ctx, _filesystem) = memory_ctx()
  write_file(ctx, "a.txt", "l1\nl2\nl3\nl4\nl5")
  let outcome =
    fs.read_tool().run(
      ctx,
      args([
        #("path", json.String("a.txt")),
        #("offset", json.Int(2)),
        #("limit", json.Int(2)),
      ]),
    )
  assert outcome.is_error == False
  assert string.contains(first_text(outcome), "2:")
  assert string.contains(first_text(outcome), "|l2")
  assert string.contains(first_text(outcome), "|l3")
  assert !string.contains(first_text(outcome), "|l4")
  let assert Some(json.Object(fields)) = outcome.details
  assert list.key_find(fields, "has_more") == Ok(json.Bool(True))
  assert list.key_find(fields, "total_lines") == Ok(json.Int(5))
}

pub fn read_missing_file_test() {
  let #(ctx, _filesystem) = memory_ctx()
  let outcome =
    fs.read_tool().run(ctx, args([#("path", json.String("no.txt"))]))
  assert outcome.is_error
  assert string.contains(first_text(outcome), "not found")
}

pub fn read_escape_rejected_test() {
  let #(ctx, _filesystem) = memory_ctx()
  let outcome =
    fs.read_tool().run(ctx, args([#("path", json.String("../secrets"))]))
  assert outcome.is_error
  assert string.contains(first_text(outcome), "outside the workspace")
}

pub fn read_binary_rejected_test() {
  let #(ctx, _filesystem) = memory_ctx()
  let filesystem = ctx.filesystem
  let assert Ok(Nil) = filesystem.write("/work/bin.dat", <<0xFF, 0xFE, 0x00>>)
  let outcome =
    fs.read_tool().run(ctx, args([#("path", json.String("bin.dat"))]))
  assert outcome.is_error
  assert string.contains(first_text(outcome), "not valid UTF-8")
}

pub fn read_large_file_guard_test() {
  let #(ctx, _filesystem) = memory_ctx()
  let filesystem = ctx.filesystem
  let size = fs.max_read_bytes + 1
  let assert Ok(Nil) =
    filesystem.write("/work/big.txt", <<0:size(size)-unit(8)>>)
  let outcome =
    fs.read_tool().run(ctx, args([#("path", json.String("big.txt"))]))
  assert outcome.is_error
  assert string.contains(first_text(outcome), "larger than")
}

pub fn read_empty_file_test() {
  let #(ctx, _filesystem) = memory_ctx()
  write_file(ctx, "empty.txt", "")
  let outcome =
    fs.read_tool().run(ctx, args([#("path", json.String("empty.txt"))]))
  assert outcome.is_error == False
  assert first_text(outcome) == "(empty file)"
}

pub fn read_invalid_offset_test() {
  let #(ctx, _filesystem) = memory_ctx()
  let outcome =
    fs.read_tool().run(
      ctx,
      args([#("path", json.String("a")), #("offset", json.Int(0))]),
    )
  assert outcome.is_error
}

// --- fs_write ------------------------------------------------------------

pub fn write_then_read_roundtrip_test() {
  let #(ctx, _filesystem) = memory_ctx()
  let outcome =
    fs.write_tool().run(
      ctx,
      args([
        #("path", json.String("out.txt")),
        #("content", json.String("hello\nworld\n")),
      ]),
    )
  assert outcome.is_error == False
  let read = fs.read_tool().run(ctx, args([#("path", json.String("out.txt"))]))
  assert string.contains(first_text(read), "|hello")
  assert string.contains(first_text(read), "|world")
}

pub fn write_escape_rejected_test() {
  let #(ctx, _filesystem) = memory_ctx()
  let outcome =
    fs.write_tool().run(
      ctx,
      args([
        #("path", json.String("/etc/passwd")),
        #("content", json.String("nope")),
      ]),
    )
  assert outcome.is_error
  assert string.contains(first_text(outcome), "outside the workspace")
}

pub fn write_missing_content_test() {
  let #(ctx, _filesystem) = memory_ctx()
  let outcome =
    fs.write_tool().run(ctx, args([#("path", json.String("a.txt"))]))
  assert outcome.is_error
  assert string.contains(first_text(outcome), "content")
}

// --- fs_edit -------------------------------------------------------------

fn anchor_ref(content: String, line: Int) -> json.JsonValue {
  let assert Ok(anchored) =
    list.find(hashline.annotate(content), fn(anchored) { anchored.line == line })
  json.Object([
    #("line", json.Int(line)),
    #("anchor", json.String(anchored.anchor)),
  ])
}

pub fn edit_replace_roundtrip_test() {
  let #(ctx, _filesystem) = memory_ctx()
  let content = "one\ntwo\nthree\n"
  write_file(ctx, "e.txt", content)
  let outcome =
    fs.edit_tool().run(
      ctx,
      args([
        #("path", json.String("e.txt")),
        #(
          "hunks",
          json.Array([
            json.Object([
              #("op", json.String("replace")),
              #("from", anchor_ref(content, 2)),
              #("to", anchor_ref(content, 2)),
              #("lines", json.Array([json.String("TWO")])),
            ]),
          ]),
        ),
      ]),
    )
  assert outcome.is_error == False
  let filesystem = ctx.filesystem
  let assert Ok(bytes) = filesystem.read("/work/e.txt")
  assert bytes == <<"one\nTWO\nthree\n":utf8>>
}

pub fn edit_multi_hunk_test() {
  let #(ctx, _filesystem) = memory_ctx()
  let content = "a\nb\nc\nd\n"
  write_file(ctx, "m.txt", content)
  let outcome =
    fs.edit_tool().run(
      ctx,
      args([
        #("path", json.String("m.txt")),
        #(
          "hunks",
          json.Array([
            json.Object([
              #("op", json.String("delete")),
              #("from", anchor_ref(content, 4)),
              #("to", anchor_ref(content, 4)),
            ]),
            json.Object([
              #("op", json.String("insert_after")),
              #("at", anchor_ref(content, 1)),
              #("lines", json.Array([json.String("a2")])),
            ]),
          ]),
        ),
      ]),
    )
  assert outcome.is_error == False
  let filesystem = ctx.filesystem
  let assert Ok(bytes) = filesystem.read("/work/m.txt")
  assert bytes == <<"a\na2\nb\nc\n":utf8>>
}

pub fn edit_stale_anchor_structured_rejection_test() {
  let #(ctx, _filesystem) = memory_ctx()
  let original = "one\ntwo\nthree\n"
  // The plan was made against `original`, but the file has changed.
  write_file(ctx, "s.txt", "one\ntwo CHANGED\nthree\n")
  let outcome =
    fs.edit_tool().run(
      ctx,
      args([
        #("path", json.String("s.txt")),
        #(
          "hunks",
          json.Array([
            json.Object([
              #("op", json.String("replace")),
              #("from", anchor_ref(original, 2)),
              #("to", anchor_ref(original, 2)),
              #("lines", json.Array([json.String("TWO")])),
            ]),
          ]),
        ),
      ]),
    )
  assert outcome.is_error
  assert string.contains(first_text(outcome), "stale anchors")
  // Details carry the fresh anchors for the stale region.
  let assert Some(json.Object(fields)) = outcome.details
  assert list.key_find(fields, "error") == Ok(json.String("stale_anchors"))
  let assert Ok(json.Array([json.Object(stale_fields)])) =
    list.key_find(fields, "stale")
  assert list.key_find(stale_fields, "line") == Ok(json.Int(2))
  let assert Ok(json.Array(fresh)) = list.key_find(stale_fields, "fresh")
  let fresh_texts =
    list.filter_map(fresh, fn(entry) {
      case entry {
        json.Object(entry_fields) ->
          case list.key_find(entry_fields, "text") {
            Ok(json.String(text)) -> Ok(text)
            _ -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    })
  assert list.contains(fresh_texts, "two CHANGED")
  // And the file was not modified.
  let filesystem = ctx.filesystem
  let assert Ok(bytes) = filesystem.read("/work/s.txt")
  assert bytes == <<"one\ntwo CHANGED\nthree\n":utf8>>
}

pub fn edit_unknown_op_test() {
  let #(ctx, _filesystem) = memory_ctx()
  write_file(ctx, "x.txt", "a\n")
  let outcome =
    fs.edit_tool().run(
      ctx,
      args([
        #("path", json.String("x.txt")),
        #("hunks", json.Array([json.Object([#("op", json.String("mangle"))])])),
      ]),
    )
  assert outcome.is_error
  assert string.contains(first_text(outcome), "unknown hunk op")
}

pub fn edit_empty_hunks_test() {
  let #(ctx, _filesystem) = memory_ctx()
  let outcome =
    fs.edit_tool().run(
      ctx,
      args([#("path", json.String("x.txt")), #("hunks", json.Array([]))]),
    )
  assert outcome.is_error
}

pub fn edit_escape_rejected_test() {
  let #(ctx, _filesystem) = memory_ctx()
  let outcome =
    fs.edit_tool().run(
      ctx,
      args([
        #("path", json.String("../../etc/passwd")),
        #(
          "hunks",
          json.Array([
            json.Object([
              #("op", json.String("insert_at_start")),
              #("lines", json.Array([json.String("x")])),
            ]),
          ]),
        ),
      ]),
    )
  assert outcome.is_error
  assert string.contains(first_text(outcome), "outside the workspace")
}

// --- against a real disk -------------------------------------------------

pub fn real_disk_write_read_edit_roundtrip_test() {
  let #(ctx, _filesystem) = real_ctx("roundtrip")
  let written =
    fs.write_tool().run(
      ctx,
      args([
        #("path", json.String("nested/dir/file.txt")),
        #("content", json.String("first\nsecond\n")),
      ]),
    )
  assert written.is_error == False
  let read =
    fs.read_tool().run(
      ctx,
      args([#("path", json.String("nested/dir/file.txt"))]),
    )
  assert read.is_error == False
  assert string.contains(first_text(read), "|first")
  let content = "first\nsecond\n"
  let edited =
    fs.edit_tool().run(
      ctx,
      args([
        #("path", json.String("nested/dir/file.txt")),
        #(
          "hunks",
          json.Array([
            json.Object([
              #("op", json.String("replace")),
              #("from", anchor_ref(content, 1)),
              #("to", anchor_ref(content, 1)),
              #("lines", json.Array([json.String("FIRST")])),
            ]),
          ]),
        ),
      ]),
    )
  assert edited.is_error == False
  let assert Ok(final) =
    simplifile.read(ctx.workspace <> "/nested/dir/file.txt")
  assert final == "FIRST\nsecond\n"
}

pub fn real_disk_missing_file_test() {
  let #(ctx, _filesystem) = real_ctx("missing")
  let outcome =
    fs.read_tool().run(ctx, args([#("path", json.String("absent.txt"))]))
  assert outcome.is_error
  assert string.contains(first_text(outcome), "not found")
}

pub fn real_filesystem_maps_enoent_test() {
  let filesystem = fs.real_filesystem()
  let assert Error(tool.FsNotFound(path: _)) =
    filesystem.read("/definitely/not/here/loom")
}

// --- replay and mode flags ----------------------------------------------

pub fn fs_tool_flags_test() {
  assert fs.read_tool().replay == tool.Safe
  assert fs.read_tool().execution_mode == tool.Concurrent
  assert fs.write_tool().replay == tool.Safe
  assert fs.write_tool().execution_mode == tool.Exclusive
  assert fs.edit_tool().replay == tool.Safe
  assert fs.edit_tool().execution_mode == tool.Exclusive
}

pub fn fs_requirements_shape_test() {
  let read_requirements = fs.read_tool().requirements("/w")
  assert read_requirements.writable_roots == []
  assert read_requirements.readable_roots == ["/w"]
  let write_requirements = fs.write_tool().requirements("/w")
  assert write_requirements.writable_roots == ["/w"]
}

pub fn read_oversized_window_refused_test() {
  let #(ctx, _filesystem) = memory_ctx()
  // 1000 lines of ~100 bytes each renders well past the 64 KiB inline
  // ceiling; an anchored read must ask for a smaller window instead of
  // overflowing anchors into a blob.
  let line = string.repeat("y", 100)
  let content = string.repeat(line <> "\n", 1000)
  write_file(ctx, "wide.txt", content)
  let outcome =
    fs.read_tool().run(ctx, args([#("path", json.String("wide.txt"))]))
  assert outcome.is_error
  assert string.contains(first_text(outcome), "smaller window")
}
