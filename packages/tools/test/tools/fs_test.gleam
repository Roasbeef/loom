import broker/policy
import core/json
import core/message
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import simplifile
import support/fake_broker
import support/memory_fs
import tools/directory_access
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

// The same ctx with a session base policy that protects `paths` — the
// never-writable list the kernel jail masks for a spawned process and
// the fs tools must enforce for themselves.
fn with_protected(ctx: tool.Ctx, paths: List(String)) -> tool.Ctx {
  tool.Ctx(
    ..ctx,
    base_policy: policy.SandboxPolicy(..ctx.base_policy, protected: paths),
  )
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

// Exactly the text provider adapters expose to the model, without borrowing
// the presentation-only details that used to hide this edit prerequisite.
fn visible_digest(outcome: tool.ToolOutcome) -> String {
  let assert Ok(line) =
    first_text(outcome)
    |> string.split("\n")
    |> list.find(fn(line) { string.starts_with(line, "digest: ") })
    as "the model-visible result must expose its file digest"
  string.drop_start(line, 8)
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
    == "digest: "
    <> hashline.digest("alpha\nbeta\n")
    <> "\n1:"
    <> hashline.anchor("alpha")
    <> "|alpha\n2:"
    <> hashline.anchor("beta")
    <> "|beta"
  let assert Some(json.Object(fields)) = outcome.details
  assert list.key_find(fields, "total_lines") == Ok(json.Int(2))
  assert list.key_find(fields, "has_more") == Ok(json.Bool(False))
  assert list.key_find(fields, "trailing_newline") == Ok(json.Bool(True))
  assert list.key_find(fields, "digest")
    == Ok(json.String(hashline.digest("alpha\nbeta\n")))
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

// The window notice is the only model-visible statement that a read was
// windowed: `details` carries `has_more`, `total_lines` and `offset`, and
// no provider adapter puts that object on the wire. Without the notice a
// first window is indistinguishable from a whole file, which is what makes
// a model read the same first window again instead of paging on.
fn windowed_read(ctx: tool.Ctx, offset: Int, limit: Int) -> String {
  let outcome =
    fs.read_tool().run(
      ctx,
      args([
        #("path", json.String("a.txt")),
        #("offset", json.Int(offset)),
        #("limit", json.Int(limit)),
      ]),
    )
  assert outcome.is_error == False
  first_text(outcome)
}

pub fn read_first_window_states_continuation_test() {
  let #(ctx, _filesystem) = memory_ctx()
  write_file(ctx, "a.txt", "l1\nl2\nl3\nl4\nl5")
  assert string.ends_with(
    windowed_read(ctx, 1, 2),
    "\n(lines 1-2 of 5; read the rest with offset 3)",
  )
}

pub fn read_middle_window_states_continuation_test() {
  let #(ctx, _filesystem) = memory_ctx()
  write_file(ctx, "a.txt", "l1\nl2\nl3\nl4\nl5")
  assert string.ends_with(
    windowed_read(ctx, 2, 2),
    "\n(lines 2-3 of 5; read the rest with offset 4)",
  )
}

// The last window has nothing after it, so it states the range it covers
// and names no continuing offset.
pub fn read_last_window_states_range_only_test() {
  let #(ctx, _filesystem) = memory_ctx()
  write_file(ctx, "a.txt", "l1\nl2\nl3\nl4\nl5")
  let text = windowed_read(ctx, 4, 2)
  assert string.ends_with(text, "\n(lines 4-5 of 5)")
  assert !string.contains(text, "read the rest with offset")
}

// The whole-file read is the common case and gains nothing from a note
// about lines that do not exist, so it keeps its exact previous text.
pub fn read_complete_file_states_no_window_test() {
  let #(ctx, _filesystem) = memory_ctx()
  write_file(ctx, "a.txt", "l1\nl2\nl3")
  let outcome =
    fs.read_tool().run(
      ctx,
      args([#("path", json.String("a.txt")), #("limit", json.Int(3))]),
    )
  assert outcome.is_error == False
  assert first_text(outcome)
    == "digest: "
    <> hashline.digest("l1\nl2\nl3")
    <> "\n1:"
    <> hashline.anchor("l1")
    <> "|l1\n2:"
    <> hashline.anchor("l2")
    <> "|l2\n3:"
    <> hashline.anchor("l3")
    <> "|l3"
}

// An offset past the end has no lines to name a range over, and
// `empty_window_text` already reports the file's length there.
pub fn read_past_end_states_no_window_test() {
  let #(ctx, _filesystem) = memory_ctx()
  write_file(ctx, "a.txt", "l1\nl2")
  let text = windowed_read(ctx, 9, 1)
  assert text
    == "digest: "
    <> hashline.digest("l1\nl2")
    <> "\n(no lines at offset 9; the file has 2 lines)"
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
  assert first_text(outcome)
    == "digest: " <> hashline.digest("") <> "\n(empty file)"
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

fn digest_of(content: String) -> json.JsonValue {
  json.String(hashline.digest(content))
}

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
  let read = fs.read_tool().run(ctx, args([#("path", json.String("e.txt"))]))
  let outcome =
    fs.edit_tool().run(
      ctx,
      args([
        #("path", json.String("e.txt")),
        #("digest", json.String(visible_digest(read))),
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

  // Providers send content and omit details. Both initial planning and the
  // next edit must obtain their digest through that model-visible surface.
  assert visible_digest(outcome) == hashline.digest("one\nTWO\nthree\n")
  // Success details carry the post-edit digest, so a follow-up edit can
  // chain without re-reading.
  let assert Some(json.Object(fields)) = outcome.details
  assert list.key_find(fields, "digest")
    == Ok(json.String(hashline.digest("one\nTWO\nthree\n")))
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
        #("digest", digest_of(content)),
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
        #("digest", digest_of(original)),
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
  assert visible_digest(outcome) == hashline.digest("one\ntwo CHANGED\nthree\n")
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
        #("digest", digest_of("a\n")),
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
      args([
        #("path", json.String("x.txt")),
        #("digest", digest_of("")),
        #("hunks", json.Array([])),
      ]),
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
        #("digest", digest_of("")),
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

pub fn edit_missing_digest_rejected_test() {
  let #(ctx, _filesystem) = memory_ctx()
  write_file(ctx, "d.txt", "a\n")
  let outcome =
    fs.edit_tool().run(
      ctx,
      args([
        #("path", json.String("d.txt")),
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
  assert string.contains(first_text(outcome), "`digest` is required")
}

pub fn edit_replay_of_duplicate_line_delete_rejected_test() {
  // The C1 crash-replay scenario at tool level: fs_edit is replay-Safe
  // because re-dispatching the identical call after the write landed
  // must reject in-band — even when the deleted line has an identical
  // sibling that shifted into its position.
  let #(ctx, _filesystem) = memory_ctx()
  let content = "x\nx\n"
  write_file(ctx, "r.txt", content)
  let call =
    args([
      #("path", json.String("r.txt")),
      #("digest", digest_of(content)),
      #(
        "hunks",
        json.Array([
          json.Object([
            #("op", json.String("delete")),
            #("from", anchor_ref(content, 1)),
            #("to", anchor_ref(content, 1)),
          ]),
        ]),
      ),
    ])
  let first = fs.edit_tool().run(ctx, call)
  assert first.is_error == False
  let second = fs.edit_tool().run(ctx, call)
  assert second.is_error
  assert string.contains(first_text(second), "stale content")
  let assert Some(json.Object(fields)) = second.details
  assert list.key_find(fields, "error") == Ok(json.String("stale_content"))
  assert list.key_find(fields, "digest")
    == Ok(json.String(hashline.digest("x\n")))
  // The file was edited exactly once.
  let filesystem = ctx.filesystem
  let assert Ok(bytes) = filesystem.read("/work/r.txt")
  assert bytes == <<"x\n":utf8>>
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
        #("digest", digest_of(content)),
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

// --- symlink containment (real filesystem) -------------------------------

// A directory guaranteed to sit outside the given workspace root.
fn outside_dir(root: String) -> String {
  let outside = root <> "_outside"
  let _ = simplifile.delete(outside)
  let assert Ok(Nil) = simplifile.create_directory_all(outside)
  outside
}

pub fn symlink_directory_escape_refused_test() {
  let #(ctx, _filesystem) = real_ctx("h2_dir")
  let outside = outside_dir(ctx.workspace)
  let assert Ok(Nil) = simplifile.write(outside <> "/secret.txt", "secret\n")
  let assert Ok(Nil) =
    simplifile.create_symlink(to: outside, from: ctx.workspace <> "/link")
  // Reading through the link is refused.
  let read =
    fs.read_tool().run(ctx, args([#("path", json.String("link/secret.txt"))]))
  assert read.is_error
  assert string.contains(first_text(read), "outside the workspace")
  // Writing through the link is refused, and nothing lands outside.
  let write =
    fs.write_tool().run(
      ctx,
      args([
        #("path", json.String("link/planted.txt")),
        #("content", json.String("nope")),
      ]),
    )
  assert write.is_error
  assert string.contains(first_text(write), "outside the workspace")
  assert simplifile.is_file(outside <> "/planted.txt") == Ok(False)
}

pub fn symlink_file_escape_refused_test() {
  let #(ctx, _filesystem) = real_ctx("h2_file")
  let outside = outside_dir(ctx.workspace)
  let assert Ok(Nil) = simplifile.write(outside <> "/secret.txt", "secret\n")
  let assert Ok(Nil) =
    simplifile.create_symlink(
      to: outside <> "/secret.txt",
      from: ctx.workspace <> "/alias.txt",
    )
  let read =
    fs.read_tool().run(ctx, args([#("path", json.String("alias.txt"))]))
  assert read.is_error
  assert string.contains(first_text(read), "outside the workspace")
  let write =
    fs.write_tool().run(
      ctx,
      args([
        #("path", json.String("alias.txt")),
        #("content", json.String("clobbered")),
      ]),
    )
  assert write.is_error
  let assert Ok(untouched) = simplifile.read(outside <> "/secret.txt")
  assert untouched == "secret\n"
}

pub fn dangling_symlink_write_refused_test() {
  // A dangling link is the treacherous case: the target does not exist,
  // so a resolver that treats "missing" as "safe suffix" would let the
  // write create the target outside the workspace.
  let #(ctx, _filesystem) = real_ctx("h2_dangling")
  let outside = outside_dir(ctx.workspace)
  let assert Ok(Nil) =
    simplifile.create_symlink(
      to: outside <> "/absent.txt",
      from: ctx.workspace <> "/dangle",
    )
  let write =
    fs.write_tool().run(
      ctx,
      args([
        #("path", json.String("dangle")),
        #("content", json.String("nope")),
      ]),
    )
  assert write.is_error
  assert string.contains(first_text(write), "outside the workspace")
  assert simplifile.is_file(outside <> "/absent.txt") == Ok(False)
}

pub fn symlink_inside_workspace_allowed_test() {
  // Symlinks that stay under the root are legitimate and keep working,
  // absolute and relative targets alike.
  let #(ctx, _filesystem) = real_ctx("h2_inside")
  let assert Ok(Nil) = simplifile.create_directory_all(ctx.workspace <> "/sub")
  let assert Ok(Nil) = simplifile.write(ctx.workspace <> "/sub/f.txt", "hi\n")
  let assert Ok(Nil) =
    simplifile.create_symlink(
      to: ctx.workspace <> "/sub",
      from: ctx.workspace <> "/alias_abs",
    )
  let assert Ok(Nil) =
    simplifile.create_symlink(to: "sub", from: ctx.workspace <> "/alias_rel")
  let via_abs =
    fs.read_tool().run(ctx, args([#("path", json.String("alias_abs/f.txt"))]))
  assert via_abs.is_error == False
  assert string.contains(first_text(via_abs), "|hi")
  let via_rel =
    fs.read_tool().run(ctx, args([#("path", json.String("alias_rel/f.txt"))]))
  assert via_rel.is_error == False
  assert string.contains(first_text(via_rel), "|hi")
}

pub fn symlinked_workspace_root_allowed_test() {
  // The workspace root itself being a symlink must not break the tools:
  // the root resolves once and containment compares resolved to
  // resolved.
  let assert Ok(here) = simplifile.current_directory()
  let base = here <> "/build/fs_test/h2_root"
  let _ = simplifile.delete(base)
  let assert Ok(Nil) = simplifile.create_directory_all(base <> "/real")
  let assert Ok(Nil) =
    simplifile.create_symlink(to: base <> "/real", from: base <> "/rootlink")
  let recorded = process.new_subject()
  let ctx =
    fake_broker.ctx(
      workspace: base <> "/rootlink",
      filesystem: fs.real_filesystem(),
      now: 1000,
      script: [],
      recorded:,
    )
  let write =
    fs.write_tool().run(
      ctx,
      args([
        #("path", json.String("a.txt")),
        #("content", json.String("hi\n")),
      ]),
    )
  assert write.is_error == False
  // The write landed under the resolved root.
  assert simplifile.is_file(base <> "/real/a.txt") == Ok(True)
  let read = fs.read_tool().run(ctx, args([#("path", json.String("a.txt"))]))
  assert read.is_error == False
  assert string.contains(first_text(read), "|hi")
  // Escapes are still refused from a symlinked root.
  let escape =
    fs.read_tool().run(ctx, args([#("path", json.String("../../secret"))]))
  assert escape.is_error
  assert string.contains(first_text(escape), "outside the workspace")
}

pub fn symlink_loop_is_unresolvable_test() {
  let #(ctx, _filesystem) = real_ctx("h2_loop")
  let assert Ok(Nil) =
    simplifile.create_symlink(
      to: ctx.workspace <> "/loop",
      from: ctx.workspace <> "/loop",
    )
  let outcome =
    fs.read_tool().run(ctx, args([#("path", json.String("loop/x.txt"))]))
  assert outcome.is_error
  assert string.contains(first_text(outcome), "could not be resolved")
}

pub fn resolve_real_is_lexical_without_symlinks_test() {
  // Over a filesystem with no symlinks (the in-memory fake reports
  // everything missing), real resolution degrades to the lexical walk.
  let filesystem = memory_fs.filesystem(memory_fs.start())
  assert fs.resolve_real(filesystem:, workspace: "/work", path: "a/./b/../c")
    == Ok("/work/a/c")
  assert fs.resolve_real(filesystem:, workspace: "/work", path: "../etc")
    == Error(fs.EscapesWorkspace("../etc"))
  assert fs.resolve_real(filesystem:, workspace: "/work", path: "")
    == Error(fs.EmptyPath)
}

// --- protected paths -----------------------------------------------------

fn write_call(path: String, content: String) -> json.JsonValue {
  args([#("path", json.String(path)), #("content", json.String(content))])
}

// An `insert_at_start` edit planned against `content` — enough of a plan
// to reach the write path, which is what these tests are about.
fn insert_call(path: String, content: String) -> json.JsonValue {
  args([
    #("path", json.String(path)),
    #("digest", digest_of(content)),
    #(
      "hunks",
      json.Array([
        json.Object([
          #("op", json.String("insert_at_start")),
          #("lines", json.Array([json.String("planted")])),
        ]),
      ]),
    ),
  ])
}

pub fn write_to_protected_git_internals_refused_test() {
  // A git hook written through the harness's own tool is arbitrary code
  // execution outside the jail on the next checkout, and the jail's
  // masks never see this write.
  let #(ctx, _filesystem) = memory_ctx()
  let ctx = with_protected(ctx, ["/work/.git"])
  let outcome =
    fs.write_tool().run(
      ctx,
      write_call(".git/hooks/post-checkout", "#!/bin/sh\nwhoami\n"),
    )
  assert outcome.is_error
  assert string.contains(first_text(outcome), "permission denied")
  assert string.contains(first_text(outcome), "/work/.git")
  let assert Some(json.Object(fields)) = outcome.details
  assert list.key_find(fields, "error") == Ok(json.String("protected_path"))
  assert list.key_find(fields, "protected") == Ok(json.String("/work/.git"))
  let filesystem = ctx.filesystem
  let assert Error(_) = filesystem.read("/work/.git/hooks/post-checkout")
}

pub fn edit_of_protected_path_refused_test() {
  let #(ctx, _filesystem) = memory_ctx()
  write_file(ctx, ".git/config", "[core]\n")
  let ctx = with_protected(ctx, ["/work/.git"])
  let outcome = fs.edit_tool().run(ctx, insert_call(".git/config", "[core]\n"))
  assert outcome.is_error
  assert string.contains(first_text(outcome), "permission denied")
  assert string.contains(first_text(outcome), "/work/.git")
  let filesystem = ctx.filesystem
  let assert Ok(bytes) = filesystem.read("/work/.git/config")
  assert bytes == <<"[core]\n":utf8>>
}

pub fn write_to_protected_file_itself_refused_test() {
  // A protected *entry* is refused as well as everything under it.
  let #(ctx, _filesystem) = memory_ctx()
  let ctx = with_protected(ctx, ["/work/.env"])
  let outcome = fs.write_tool().run(ctx, write_call(".env", "TOKEN=leaked\n"))
  assert outcome.is_error
  assert string.contains(first_text(outcome), "permission denied")
  assert string.contains(first_text(outcome), "/work/.env")
}

pub fn write_outside_protected_paths_still_succeeds_test() {
  let #(ctx, _filesystem) = memory_ctx()
  let ctx = with_protected(ctx, ["/work/.git", "/work/.env"])
  let outcome =
    fs.write_tool().run(ctx, write_call("src/main.gleam", "pub fn main() {}\n"))
  assert outcome.is_error == False
  let filesystem = ctx.filesystem
  let assert Ok(bytes) = filesystem.read("/work/src/main.gleam")
  assert bytes == <<"pub fn main() {}\n":utf8>>
}

pub fn protected_prefix_siblings_not_refused_test() {
  // `.gitx` and `.environment` share a textual prefix with `.git` and
  // `.env` while being under neither: the check compares path
  // components, never string prefixes.
  let #(ctx, _filesystem) = memory_ctx()
  let ctx = with_protected(ctx, ["/work/.git", "/work/.env"])
  let sibling_directory =
    fs.write_tool().run(ctx, write_call(".gitx/notes.txt", "fine\n"))
  assert sibling_directory.is_error == False
  let sibling_file =
    fs.write_tool().run(ctx, write_call(".environment", "fine\n"))
  assert sibling_file.is_error == False
}

pub fn symlink_onto_protected_path_refused_test() {
  // The ordering case: an innocuous-looking workspace-internal symlink
  // whose target is protected. Only the resolved path says so, which is
  // why the check runs after `resolve_real` and not before it.
  let #(ctx, _filesystem) = real_ctx("protected_symlink")
  let assert Ok(Nil) = simplifile.create_directory_all(ctx.workspace <> "/.git")
  let assert Ok(Nil) =
    simplifile.write(ctx.workspace <> "/.git/config", "[core]\n")
  let assert Ok(Nil) =
    simplifile.create_symlink(
      to: ctx.workspace <> "/.git/config",
      from: ctx.workspace <> "/innocent.txt",
    )
  let ctx = with_protected(ctx, [ctx.workspace <> "/.git"])
  let outcome =
    fs.write_tool().run(ctx, write_call("innocent.txt", "clobbered\n"))
  assert outcome.is_error
  assert string.contains(first_text(outcome), "permission denied")
  let assert Ok(untouched) = simplifile.read(ctx.workspace <> "/.git/config")
  assert untouched == "[core]\n"
}

pub fn read_of_protected_path_still_allowed_test() {
  // Deliberate asymmetry with the jail, stated in `resolve_for_write`:
  // `protected` governs writes here, and reading `.git/HEAD` is
  // ordinary work.
  let #(ctx, _filesystem) = memory_ctx()
  write_file(ctx, ".git/HEAD", "ref: refs/heads/main\n")
  let ctx = with_protected(ctx, ["/work/.git"])
  let outcome =
    fs.read_tool().run(ctx, args([#("path", json.String(".git/HEAD"))]))
  assert outcome.is_error == False
  assert string.contains(first_text(outcome), "|ref: refs/heads/main")
}

pub fn a_relative_protected_entry_refuses_every_write_test() {
  // The fail-closed case. A relative entry cannot be interpreted: it
  // normalizes to `/.git`, which is under no workspace and therefore
  // covers nothing, so the list a person wrote to protect `.git` used to
  // protect nothing at all while reading as though it did. The jail
  // refuses the same policy outright (`policy.validate` answers
  // `RelativePath`), and a harness quietly permitting what the jail
  // loudly refuses is the worst of the two behaviours.
  //
  // ANY path, not just the one the entry meant: a misconfigured list
  // cannot be partially honoured, because what it meant to cover is
  // exactly what cannot be recovered from it.
  let #(ctx, _filesystem) = memory_ctx()
  let ctx = with_protected(ctx, [".git"])
  let outcome =
    fs.write_tool().run(ctx, write_call("src/main.gleam", "pub fn main() {}\n"))
  assert outcome.is_error
  assert string.contains(first_text(outcome), "permission denied")
  assert string.contains(first_text(outcome), ".git")
  let assert Some(json.Object(fields)) = outcome.details
  assert list.key_find(fields, "error")
    == Ok(json.String("protection_misconfigured"))
  assert list.key_find(fields, "protected") == Ok(json.String(".git"))
  let filesystem = ctx.filesystem
  let assert Error(_) = filesystem.read("/work/src/main.gleam")
}

pub fn a_relative_protected_entry_refuses_an_edit_too_test() {
  // Both write doors go through `resolve_writable`, so neither can be
  // the one that stays open.
  let #(ctx, _filesystem) = memory_ctx()
  write_file(ctx, "notes.txt", "keep\n")
  let ctx = with_protected(ctx, ["/work/.git", "relative/entry"])
  let outcome = fs.edit_tool().run(ctx, insert_call("notes.txt", "keep\n"))
  assert outcome.is_error
  assert string.contains(first_text(outcome), "relative/entry")
  let filesystem = ctx.filesystem
  let assert Ok(bytes) = filesystem.read("/work/notes.txt")
  assert bytes == <<"keep\n":utf8>>
}

pub fn a_relative_protected_entry_leaves_reads_alone_test() {
  // The refusal is on the write path only, exactly as the protected
  // check itself is: `resolve_real` never consults the list.
  let #(ctx, _filesystem) = memory_ctx()
  write_file(ctx, "notes.txt", "readable\n")
  let ctx = with_protected(ctx, [".git"])
  let outcome =
    fs.read_tool().run(ctx, args([#("path", json.String("notes.txt"))]))
  assert outcome.is_error == False
}

pub fn write_whole_creates_missing_parents_test() {
  // The seam both write doors share: `fs_write`'s description promises
  // parents are created, and the bridge's `fs.write` closure calls this
  // same function so the two cannot disagree.
  let #(ctx, _filesystem) = real_ctx("write_whole_parents")
  let assert Ok(Nil) =
    fs.write_whole(
      filesystem: ctx.filesystem,
      resolved: ctx.workspace <> "/new_dir/deeper/file.txt",
      bytes: <<"landed\n":utf8>>,
    )
    as "a whole-file write creates its parents"
  let assert Ok(text) =
    simplifile.read(ctx.workspace <> "/new_dir/deeper/file.txt")
  assert text == "landed\n"
}

// Magic bytes, including UTF-8-compatible GIF headers, take precedence over
// line rendering. File extensions do not participate in classification.
pub fn read_supported_images_as_image_blocks_test() {
  let #(ctx, filesystem) = memory_ctx()
  list.each(
    [
      #(<<0x89, "PNG", 13, 10, 26, 10, 0, 255>>, "image/png"),
      #(<<255, 216, 255, 0>>, "image/jpeg"),
      #(<<"GIF87a", 0>>, "image/gif"),
      #(<<"GIF89a", 0>>, "image/gif"),
      #(<<"RIFF", 4:size(32), "WEBP", 0>>, "image/webp"),
    ],
    fn(sample) {
      let #(bytes, mime) = sample
      let assert Ok(Nil) = filesystem.write("/work/picture.data", bytes)
        as "the fixture must be writable"
      let outcome =
        fs.read_tool().run(
          ctx,
          args([
            #("path", json.String("picture.data")),
            #("offset", json.Int(200)),
            #("limit", json.Int(1)),
          ]),
        )
      assert !outcome.is_error
      let assert [
        message.ToolResultText(text:, ..),
        message.ToolResultImage(data:, mime_type:),
      ] = outcome.content
        as "an image read must include both its identity and pixels"
      assert string.contains(text, "picture.data")
      assert mime_type == mime
      assert bit_array.base64_decode(data) == Ok(bytes)
      assert outcome.details
        == Some(
          json.Object([
            #("path", json.String("picture.data")),
            #("mime_type", json.String(mime)),
            #("byte_size", json.Int(bit_array.byte_size(bytes))),
          ]),
        )
    },
  )
}

pub fn image_extension_does_not_replace_text_anchors_test() {
  let #(ctx, _) = memory_ctx()
  write_file(ctx, "notes.png", "still text")
  let outcome =
    fs.read_tool().run(ctx, args([#("path", json.String("notes.png"))]))
  assert !outcome.is_error
  assert string.contains(first_text(outcome), "|still text")
  assert visible_digest(outcome) == hashline.digest("still text")
}

pub fn image_read_shares_the_file_size_guard_test() {
  let #(ctx, filesystem) = memory_ctx()
  let payload_size = fs.max_read_bytes - 7
  let assert Ok(Nil) =
    filesystem.write("/work/big.png", <<
      0x89,
      "PNG",
      13,
      10,
      26,
      10,
      0:size(payload_size)-unit(8),
    >>)
    as "the oversized image fixture must be writable"
  let outcome =
    fs.read_tool().run(ctx, args([#("path", json.String("big.png"))]))
  assert outcome.is_error
  assert string.contains(first_text(outcome), "larger than")
}

pub fn image_bytes_do_not_change_the_text_capability_test() {
  let #(ctx, filesystem) = memory_ctx()
  let assert Ok(Nil) =
    filesystem.write("/work/picture.png", <<0x89, "PNG", 13, 10, 26, 10>>)
    as "the fixture must be writable"
  assert fs.read_text_file(ctx.filesystem, "/work/picture.png")
    == Error(fs.NotText)
}

pub fn added_read_directory_does_not_grant_write_test() {
  let #(ctx, filesystem) = memory_ctx()
  let assert Ok(Nil) = filesystem.write("/shared/a", <<"before":utf8>>)
    as "fixture file exists outside workspace"
  let ctx =
    tool.Ctx(..ctx, directory_access: directory_access.Access(["/shared"], []))
  let read =
    fs.read_tool().run(ctx, args([#("path", json.String("/shared/a"))]))
  assert read.is_error == False
  let denied =
    fs.write_tool().run(
      ctx,
      args([
        #("path", json.String("/shared/a")),
        #("content", json.String("after")),
      ]),
    )
  assert denied.is_error == True
  assert filesystem.read("/shared/a") == Ok(<<"before":utf8>>)
}

pub fn added_write_directory_keeps_neighbors_and_protected_paths_closed_test() {
  let #(ctx, filesystem) = memory_ctx()
  let ctx =
    tool.Ctx(
      ..with_protected(ctx, ["/shared/private"]),
      directory_access: directory_access.Access(["/shared"], ["/shared"]),
    )
  let allowed =
    fs.write_tool().run(
      ctx,
      args([
        #("path", json.String("/shared/a")),
        #("content", json.String("written")),
      ]),
    )
  assert allowed.is_error == False
  list.each(["/shared-other/a", "/shared/private/a"], fn(path) {
    let denied =
      fs.write_tool().run(
        ctx,
        args([
          #("path", json.String(path)),
          #("content", json.String("forbidden")),
        ]),
      )
    assert denied.is_error == True
    assert filesystem.read(path) != Ok(<<"forbidden":utf8>>)
  })
}

pub fn native_file_approval_is_call_scoped_and_precedes_write_test() {
  let #(ctx, filesystem) = memory_ctx()
  let asked = process.new_subject()
  let approved =
    tool.Ctx(..ctx, raise_refusal: fn(request: tool.RaisedRefusal) {
      assert filesystem.read("/shared/a") != Ok(<<"written":utf8>>)
      process.send(asked, request.denial.wanted)
      tool.Resume(request.denial.wanted)
    })
  let arguments =
    args([
      #("path", json.String("/shared/a")),
      #("content", json.String("written")),
    ])
  assert fs.write_tool().run(approved, arguments).is_error == False
  let assert Ok(wanted) = process.receive(asked, 1000)
    as "the missing file authority must be shown before writing"
  assert list.contains(wanted, policy.GrantWritableRoot("/shared/a"))
  assert filesystem.read("/shared/a") == Ok(<<"written":utf8>>)
  assert fs.write_tool().run(ctx, arguments).is_error == True
}

// --- a successful edit's fresh anchors -----------------------------------
//
// Every applied hunk shifts the anchors around it, so before this the only
// way to plan a second edit of a region was to read the file again. These
// pin the block a success now carries: the two lines it always opened with,
// unchanged and in order, then the changed regions rendered exactly as
// `fs_read` renders a window.

// The `line:anchor|text` block after the heading, or the empty string when
// the success carried none.
fn fresh_block(outcome: tool.ToolOutcome) -> String {
  case string.split_once(first_text(outcome), "\nFresh anchors:\n") {
    Ok(#(_summary, block)) -> block
    Error(Nil) -> ""
  }
}

fn edit(
  ctx: tool.Ctx,
  path: String,
  digest: String,
  hunks: json.JsonValue,
) -> tool.ToolOutcome {
  fs.edit_tool().run(
    ctx,
    args([
      #("path", json.String(path)),
      #("digest", json.String(digest)),
      #("hunks", hunks),
    ]),
  )
}

fn replace_hunk(
  content: String,
  line: Int,
  lines: List(String),
) -> json.JsonValue {
  json.Array([
    json.Object([
      #("op", json.String("replace")),
      #("from", anchor_ref(content, line)),
      #("to", anchor_ref(content, line)),
      #("lines", json.Array(list.map(lines, json.String))),
    ]),
  ])
}

const ten = "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n"

pub fn edit_success_keeps_its_first_two_lines_test() {
  let #(ctx, _filesystem) = memory_ctx()
  write_file(ctx, "e.txt", ten)
  let outcome =
    edit(ctx, "e.txt", hashline.digest(ten), replace_hunk(ten, 5, ["L5"]))
  assert outcome.is_error == False

  // The summary and the digest line, in that order, are what the model and
  // the terminal already read off a success; the block comes after them.
  let assert [summary, digest_line, heading, ..] =
    string.split(first_text(outcome), "\n")
  assert summary == "applied 1 hunk(s) to e.txt"
  assert digest_line
    == "digest: "
    <> hashline.digest("l1\nl2\nl3\nl4\nL5\nl6\nl7\nl8\nl9\nl10\n")
  assert heading == "Fresh anchors:"
}

pub fn edit_success_echoes_a_replaced_region_test() {
  let #(ctx, _filesystem) = memory_ctx()
  write_file(ctx, "e.txt", ten)
  let outcome =
    edit(ctx, "e.txt", hashline.digest(ten), replace_hunk(ten, 5, ["L5"]))
  let edited = "l1\nl2\nl3\nl4\nL5\nl6\nl7\nl8\nl9\nl10\n"
  assert fresh_block(outcome)
    == hashline.render(hashline.window(edited, offset: 2, limit: 7))
}

pub fn edit_success_echoes_an_insert_only_region_test() {
  let #(ctx, _filesystem) = memory_ctx()
  write_file(ctx, "e.txt", ten)
  let hunks =
    json.Array([
      json.Object([
        #("op", json.String("insert_after")),
        #("at", anchor_ref(ten, 5)),
        #("lines", json.Array([json.String("X")])),
      ]),
    ])
  let outcome = edit(ctx, "e.txt", hashline.digest(ten), hunks)
  assert outcome.is_error == False
  let edited = "l1\nl2\nl3\nl4\nl5\nX\nl6\nl7\nl8\nl9\nl10\n"
  assert fresh_block(outcome)
    == hashline.render(hashline.window(edited, offset: 3, limit: 7))
}

// A deletion produces no lines of its own, so the context around the seam
// is all there is to anchor, and it must still be there.
pub fn edit_success_echoes_a_delete_seam_test() {
  let #(ctx, _filesystem) = memory_ctx()
  write_file(ctx, "e.txt", ten)
  let hunks =
    json.Array([
      json.Object([
        #("op", json.String("delete")),
        #("from", anchor_ref(ten, 5)),
        #("to", anchor_ref(ten, 5)),
      ]),
    ])
  let outcome = edit(ctx, "e.txt", hashline.digest(ten), hunks)
  assert outcome.is_error == False
  let edited = "l1\nl2\nl3\nl4\nl6\nl7\nl8\nl9\nl10\n"
  assert fresh_block(outcome)
    == hashline.render(hashline.window(edited, offset: 2, limit: 6))
}

// The second region's anchors have to be at their shifted lines: the first
// hunk added two lines, so what was line 9 is line 11 in the result.
pub fn edit_success_shifts_a_later_region_test() {
  let #(ctx, _filesystem) = memory_ctx()
  write_file(ctx, "e.txt", ten)
  let hunks =
    json.Array([
      json.Object([
        #("op", json.String("replace")),
        #("from", anchor_ref(ten, 2)),
        #("to", anchor_ref(ten, 2)),
        #(
          "lines",
          json.Array([json.String("A"), json.String("B"), json.String("C")]),
        ),
      ]),
      json.Object([
        #("op", json.String("replace")),
        #("from", anchor_ref(ten, 9)),
        #("to", anchor_ref(ten, 9)),
        #("lines", json.Array([json.String("L9")])),
      ]),
    ])
  let outcome = edit(ctx, "e.txt", hashline.digest(ten), hunks)
  assert outcome.is_error == False
  let edited = "l1\nA\nB\nC\nl3\nl4\nl5\nl6\nl7\nl8\nL9\nl10\n"
  assert fresh_block(outcome)
    == hashline.render(hashline.window(edited, offset: 1, limit: 7))
    <> "\n"
    <> hashline.render(hashline.window(edited, offset: 8, limit: 5))
}

// Two hunks three lines apart have overlapping contexts, so they are one
// stretch rather than two windows repeating the lines between them.
pub fn edit_success_merges_adjacent_regions_test() {
  let #(ctx, _filesystem) = memory_ctx()
  write_file(ctx, "e.txt", ten)
  let hunks =
    json.Array([
      json.Object([
        #("op", json.String("replace")),
        #("from", anchor_ref(ten, 3)),
        #("to", anchor_ref(ten, 3)),
        #("lines", json.Array([json.String("L3")])),
      ]),
      json.Object([
        #("op", json.String("replace")),
        #("from", anchor_ref(ten, 6)),
        #("to", anchor_ref(ten, 6)),
        #("lines", json.Array([json.String("L6")])),
      ]),
    ])
  let outcome = edit(ctx, "e.txt", hashline.digest(ten), hunks)
  assert outcome.is_error == False
  let edited = "l1\nl2\nL3\nl4\nl5\nL6\nl7\nl8\nl9\nl10\n"
  assert fresh_block(outcome)
    == hashline.render(hashline.window(edited, offset: 1, limit: 9))
}

pub fn edit_success_clamps_at_the_file_edges_test() {
  let #(ctx, _filesystem) = memory_ctx()
  write_file(ctx, "e.txt", ten)
  let first =
    edit(ctx, "e.txt", hashline.digest(ten), replace_hunk(ten, 1, ["L1"]))
  let after_first = "L1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n"
  assert fresh_block(first)
    == hashline.render(hashline.window(after_first, offset: 1, limit: 4))

  let last =
    edit(
      ctx,
      "e.txt",
      hashline.digest(after_first),
      replace_hunk(after_first, 10, ["L10"]),
    )
  let after_last = "L1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nL10\n"
  assert fresh_block(last)
    == hashline.render(hashline.window(after_last, offset: 7, limit: 4))
}

pub fn edit_success_handles_no_trailing_newline_test() {
  let #(ctx, _filesystem) = memory_ctx()
  let content = "l1\nl2\nl3"
  write_file(ctx, "e.txt", content)
  let outcome =
    edit(
      ctx,
      "e.txt",
      hashline.digest(content),
      replace_hunk(content, 3, ["L3"]),
    )
  assert outcome.is_error == False
  let edited = "l1\nl2\nL3"
  assert fresh_block(outcome)
    == hashline.render(hashline.window(edited, offset: 1, limit: 3))
  let filesystem = ctx.filesystem
  assert filesystem.read("/work/e.txt") == Ok(<<"l1\nl2\nL3":utf8>>)
}

fn delete_all(content: String, last: Int) -> json.JsonValue {
  json.Array([
    json.Object([
      #("op", json.String("delete")),
      #("from", anchor_ref(content, 1)),
      #("to", anchor_ref(content, last)),
    ]),
  ])
}

// An edit that leaves no lines at all has nothing to anchor, and saying so
// is more use to the model than an empty block.
pub fn edit_success_reports_an_emptied_file_test() {
  let #(ctx, _filesystem) = memory_ctx()
  let content = "l1\nl2"
  write_file(ctx, "e.txt", content)
  let outcome =
    edit(ctx, "e.txt", hashline.digest(content), delete_all(content, 2))
  assert outcome.is_error == False
  assert string.ends_with(first_text(outcome), "\n(the file is now empty)")
  assert fresh_block(outcome) == ""
  let filesystem = ctx.filesystem
  assert filesystem.read("/work/e.txt") == Ok(<<"":utf8>>)
}

// Deleting every line of a newline-terminated file leaves the terminator,
// so one blank line survives — `apply_placed`'s existing behaviour — and
// the block anchors it rather than claiming the file is empty.
pub fn edit_success_anchors_a_surviving_blank_line_test() {
  let #(ctx, _filesystem) = memory_ctx()
  let content = "l1\nl2\n"
  write_file(ctx, "e.txt", content)
  let outcome =
    edit(ctx, "e.txt", hashline.digest(content), delete_all(content, 2))
  assert outcome.is_error == False
  assert fresh_block(outcome)
    == hashline.render(hashline.window("\n", offset: 1, limit: 1))
  let filesystem = ctx.filesystem
  assert filesystem.read("/work/e.txt") == Ok(<<"\n":utf8>>)
}

// Past the cap the offset is worth more than the lines: a read of the
// caller's own choosing is cheaper than echoing most of a file back.
pub fn edit_success_falls_back_to_an_offset_when_oversized_test() {
  let #(ctx, _filesystem) = memory_ctx()
  let wide = string.repeat("x", 200)
  let content =
    list.map(upto_count(200), fn(i) { int.to_string(i) <> wide })
    |> string.join("\n")
  write_file(ctx, "w.txt", content <> "\n")
  // The replacement must be wide as well as long: the cap measures the
  // post-image region, which is what would be echoed.
  let replacement =
    list.map(upto_count(200), fn(i) { "new" <> int.to_string(i) <> wide })
  let hunks =
    json.Array([
      json.Object([
        #("op", json.String("replace")),
        #("from", anchor_ref(content <> "\n", 1)),
        #("to", anchor_ref(content <> "\n", 200)),
        #("lines", json.Array(list.map(replacement, json.String))),
      ]),
    ])
  let outcome = edit(ctx, "w.txt", hashline.digest(content <> "\n"), hunks)
  assert outcome.is_error == False
  assert string.contains(
    first_text(outcome),
    "Fresh anchors: the changed regions are too large to echo; read them "
      <> "with fs_read offset 1",
  )
  assert string.length(first_text(outcome)) < fs.max_fresh_anchor_bytes
}

// Many scattered hunks are the shape the cap was reached by the expensive
// route: one region per hunk, each formerly windowed out of the whole file
// afresh and all of them discarded once the block was measured. The check
// here is the bound and the fallback, not a wall-clock number — the walk
// now stops at the region that crosses the cap, so the rest are never
// rendered at all.
pub fn edit_success_bounds_many_scattered_regions_test() {
  let #(ctx, _filesystem) = memory_ctx()
  let wide = string.repeat("y", 60)
  let line_count = 3000
  let content =
    list.map(upto_count(line_count), fn(i) {
      "line " <> int.to_string(i) <> " " <> wide
    })
    |> string.join("\n")
    <> "\n"
  write_file(ctx, "many.txt", content)
  let hunks =
    list.map(upto_count(100), fn(n) {
      let line = n * 25
      json.Object([
        #("op", json.String("replace")),
        #("from", anchor_ref(content, line)),
        #("to", anchor_ref(content, line)),
        #("lines", json.Array([json.String("replaced " <> int.to_string(n))])),
      ])
    })
  let outcome =
    edit(ctx, "many.txt", hashline.digest(content), json.Array(hunks))
  assert outcome.is_error == False
  assert string.contains(
    first_text(outcome),
    "the changed regions are too large to echo",
  )

  // The whole result, not just the block, stays far under the cap — and so
  // an order of magnitude under the tool-output overflow threshold.
  assert string.byte_size(first_text(outcome)) < fs.max_fresh_anchor_bytes
}

// --- chaining off a success, with no read between ------------------------
//
// The property the whole change exists for. Both cases below chain off a
// first edit that grows the file by five lines, so every line after it has
// moved: a block rendered from the pre-image, or from post-image ranges
// with the shift left out, does not carry the rows these ask for, and the
// chain cannot be completed from it.

const twenty = "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\nl13\nl14\nl15\nl16\nl17\nl18\nl19\nl20\n"

// Replace line 2 with six lines (+5) and line 15 with one. In the result
// `H15` is line 20 and the old line 16 is line 21; the two regions are far
// enough apart not to merge, so only the shifted arithmetic puts either
// row in the block.
fn grow_and_touch() -> json.JsonValue {
  json.Array([
    json.Object([
      #("op", json.String("replace")),
      #("from", anchor_ref(twenty, 2)),
      #("to", anchor_ref(twenty, 2)),
      #(
        "lines",
        json.Array(list.map(["A1", "A2", "A3", "A4", "A5", "A6"], json.String)),
      ),
    ]),
    json.Object([
      #("op", json.String("replace")),
      #("from", anchor_ref(twenty, 15)),
      #("to", anchor_ref(twenty, 15)),
      #("lines", json.Array([json.String("H15")])),
    ]),
  ])
}

// One replace hunk built from a `{line, anchor}` pair parsed out of a
// success block, which is all a chaining caller has.
fn replace_at(
  line: Int,
  anchor: String,
  lines: List(String),
) -> json.JsonValue {
  let reference =
    json.Object([#("line", json.Int(line)), #("anchor", json.String(anchor))])
  json.Array([
    json.Object([
      #("op", json.String("replace")),
      #("from", reference),
      #("to", reference),
      #("lines", json.Array(list.map(lines, json.String))),
    ]),
  ])
}

// The old line 16 is line 21 now. Editing it proves the block numbered the
// context around a later hunk at its shifted position.
pub fn edit_chains_onto_a_line_whose_number_moved_test() {
  let #(ctx, _filesystem) = memory_ctx()
  write_file(ctx, "e.txt", twenty)
  let first = edit(ctx, "e.txt", hashline.digest(twenty), grow_and_touch())
  assert first.is_error == False

  // Everything below comes off the model-visible text of the first edit:
  // the digest line and one anchored row out of the block.
  let assert Ok(#(line, anchor)) = anchored_pair(fresh_block(first), 21)
    as "the success block must carry the moved line 21"
  let second =
    edit(ctx, "e.txt", visible_digest(first), replace_at(line, anchor, ["L16"]))
  assert second.is_error == False
  let filesystem = ctx.filesystem
  let assert Ok(bytes) = filesystem.read("/work/e.txt")
  assert bytes
    == <<
      "l1\nA1\nA2\nA3\nA4\nA5\nA6\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\nl13\nl14\nH15\nL16\nl17\nl18\nl19\nl20\n":utf8,
    >>
}

// Editing a line the first edit itself wrote is the tighter case: `H15`
// exists only in the post-image, at line 20, so no pre-image rendering and
// no unshifted range can supply its row.
pub fn edit_chains_onto_a_just_written_line_test() {
  let #(ctx, _filesystem) = memory_ctx()
  write_file(ctx, "e.txt", twenty)
  let first = edit(ctx, "e.txt", hashline.digest(twenty), grow_and_touch())
  assert first.is_error == False

  let assert Ok(#(line, anchor)) = anchored_pair(fresh_block(first), 20)
    as "the success block must carry the just-written line 20"
  assert anchor == hashline.anchor("H15")
  let second =
    edit(
      ctx,
      "e.txt",
      visible_digest(first),
      replace_at(line, anchor, ["H15b"]),
    )
  assert second.is_error == False
  let filesystem = ctx.filesystem
  let assert Ok(bytes) = filesystem.read("/work/e.txt")
  assert string.contains(
    case bit_array.to_string(bytes) {
      Ok(text) -> text
      Error(Nil) -> ""
    },
    "\nH15b\nl16\n",
  )
}

// --- a successful write's digest and fresh anchors -----------------------
//
// A write knew the exact content at the moment it wrote it, so making the
// caller read the file back before it could edit it was a round trip for
// information the harness already had.

fn write(ctx: tool.Ctx, path: String, content: String) -> tool.ToolOutcome {
  fs.write_tool().run(
    ctx,
    args([#("path", json.String(path)), #("content", json.String(content))]),
  )
}

// The block a write returns must be what an `fs_read` of the file returns,
// since a caller that used to read is now reading this instead.
pub fn write_returns_the_same_anchors_a_read_would_test() {
  let #(ctx, _filesystem) = memory_ctx()
  let content = "l1\nl2\nl3\n"
  let outcome = write(ctx, "w.txt", content)
  assert outcome.is_error == False
  let assert [summary, digest_line, heading, ..] =
    string.split(first_text(outcome), "\n")
  assert summary == "wrote 9 bytes to w.txt"
  assert digest_line == "digest: " <> hashline.digest(content)
  assert heading == "Fresh anchors:"
  assert fresh_block(outcome)
    == hashline.render(hashline.window(content, offset: 1, limit: 3))

  // And byte-identical to the anchored lines of a read of the same file.
  let read = fs.read_tool().run(ctx, args([#("path", json.String("w.txt"))]))
  assert string.contains(first_text(read), fresh_block(outcome))
}

pub fn write_without_a_trailing_newline_anchors_its_last_line_test() {
  let #(ctx, _filesystem) = memory_ctx()
  let content = "l1\nl2\nno newline here"
  let outcome = write(ctx, "w.txt", content)
  assert outcome.is_error == False
  assert fresh_block(outcome)
    == hashline.render(hashline.window(content, offset: 1, limit: 3))
  let filesystem = ctx.filesystem
  assert filesystem.read("/work/w.txt")
    == Ok(<<"l1\nl2\nno newline here":utf8>>)
}

pub fn write_of_an_empty_file_reports_it_test() {
  let #(ctx, _filesystem) = memory_ctx()
  let outcome = write(ctx, "w.txt", "")
  assert outcome.is_error == False
  assert first_text(outcome)
    == "wrote 0 bytes to w.txt\ndigest: "
    <> hashline.digest("")
    <> "\n(the file is now empty)"
}

// An overwrite has to report the content it just wrote, not the content it
// replaced — a stale digest here would reject every following edit.
pub fn write_overwrite_returns_the_new_digest_test() {
  let #(ctx, _filesystem) = memory_ctx()
  let first = write(ctx, "w.txt", "old\n")
  let second = write(ctx, "w.txt", "new content\n")
  assert second.is_error == False
  assert visible_digest(second) == hashline.digest("new content\n")
  assert visible_digest(second) != visible_digest(first)
  assert string.contains(fresh_block(second), "|new content")
}

// The size check answers on its own here: anchored rendering is strictly
// larger than the content, so a file already past the cap is never
// annotated to discover it does not fit.
pub fn write_of_a_large_file_falls_back_to_a_read_test() {
  let #(ctx, _filesystem) = memory_ctx()
  let wide = string.repeat("z", 120)
  let content =
    list.map(upto_count(400), fn(i) { int.to_string(i) <> " " <> wide })
    |> string.join("\n")
    <> "\n"
  let outcome = write(ctx, "big.txt", content)
  assert outcome.is_error == False
  assert string.ends_with(
    first_text(outcome),
    "Fresh anchors: the file is too large to echo; read the region you "
      <> "intend to edit with fs_read, passing offset and limit",
  )
  assert string.byte_size(first_text(outcome)) < fs.max_fresh_anchor_bytes
  assert fresh_block(outcome) == ""
}

// The property the write half exists for: an edit planned from nothing but
// the write's own success text, with no read between them. The target is
// the last line, which is also the case a caller most often wants after
// writing a file.
pub fn write_chains_into_an_edit_of_its_last_line_test() {
  let #(ctx, _filesystem) = memory_ctx()
  let content = "one\ntwo\nthree\n"
  let written = write(ctx, "c.txt", content)
  assert written.is_error == False
  let assert Ok(#(line, anchor)) = anchored_pair(fresh_block(written), 3)
    as "the write block must carry the last line"
  let edited =
    edit(
      ctx,
      "c.txt",
      visible_digest(written),
      replace_at(line, anchor, [
        "THREE",
      ]),
    )
  assert edited.is_error == False
  let filesystem = ctx.filesystem
  assert filesystem.read("/work/c.txt") == Ok(<<"one\ntwo\nTHREE\n":utf8>>)
}

// The same chain over content with no trailing newline, since that is
// where the last line's anchor and the file's ending byte interact.
pub fn write_chains_into_an_edit_without_a_trailing_newline_test() {
  let #(ctx, _filesystem) = memory_ctx()
  let written = write(ctx, "c.txt", "one\ntwo")
  assert written.is_error == False
  let assert Ok(#(line, anchor)) = anchored_pair(fresh_block(written), 2)
    as "the write block must carry the unterminated last line"
  let edited =
    edit(
      ctx,
      "c.txt",
      visible_digest(written),
      replace_at(line, anchor, ["TWO"]),
    )
  assert edited.is_error == False
  let filesystem = ctx.filesystem
  assert filesystem.read("/work/c.txt") == Ok(<<"one\nTWO":utf8>>)
}

// One `line:anchor|text` row of a rendered block, parsed the way a model
// would have to parse it.
fn anchored_pair(block: String, line: Int) -> Result(#(Int, String), Nil) {
  let wanted = int.to_string(line) <> ":"
  use row <- result.try(
    string.split(block, "\n")
    |> list.find(fn(row) { string.starts_with(row, wanted) }),
  )
  use #(_number, rest) <- result.try(string.split_once(row, ":"))
  use #(anchor, _text) <- result.try(string.split_once(rest, "|"))
  Ok(#(line, anchor))
}

fn upto_count(n: Int) -> List(Int) {
  upto_count_loop(n, [])
}

fn upto_count_loop(n: Int, built: List(Int)) -> List(Int) {
  case n < 1 {
    True -> built
    False -> upto_count_loop(n - 1, [n, ..built])
  }
}
