import broker/policy
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
  let outcome =
    fs.edit_tool().run(
      ctx,
      args([
        #("path", json.String("e.txt")),
        #("digest", digest_of(content)),
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
