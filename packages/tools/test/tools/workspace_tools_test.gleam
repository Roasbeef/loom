//// Semantic native tools preserve evidence and never use owner-local effects.

import core/json
import core/message
import core/workspace as core_workspace
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import support/fake_broker
import support/memory_fs
import tools/blob
import tools/fs
import tools/hashline
import tools/tool
import tools/workspace
import tools/workspace_local
import tools/workspace_tools

fn owner_ctx() -> tool.Ctx {
  let filesystem =
    tool.FileSystem(
      read: fn(_) { panic as "remote tool touched owner read" },
      write: fn(_, _) { panic as "remote tool touched owner write" },
      create_directory_all: fn(_) { panic as "remote tool touched owner mkdir" },
      is_file: fn(_) { panic as "remote tool touched owner stat" },
      read_link: fn(_) { panic as "remote tool touched owner path resolution" },
      rename: fn(_, _) { panic as "remote tool touched owner rename" },
    )
  let base =
    fake_broker.ctx(
      workspace: "/owner/must/not/be/resolved",
      filesystem:,
      now: 1000,
      script: [],
      recorded: process.new_subject(),
    )
  let assert Ok(scope) =
    core_workspace.scope_from_fields(
      "00000000-0000-7000-8000-000000000001",
      "workspace",
      "executor",
      1,
      1,
    )
    as "fixture scope is valid"
  tool.Ctx(..base, workspace: tool.RegisteredWorkspace(scope))
}

fn local_ctx() -> tool.Ctx {
  fake_broker.ctx(
    workspace: "/work",
    filesystem: memory_fs.filesystem(memory_fs.start()),
    now: 1000,
    script: [],
    recorded: process.new_subject(),
  )
}

fn text(outcome: tool.ToolOutcome) -> String {
  let assert [message.ToolResultText(text:, ..), ..] = outcome.content
    as "result has native text"
  text
}

fn args(path: String) -> json.JsonValue {
  json.Object([#("path", json.String(path))])
}

fn edit_args(path: String, digest: String) -> json.JsonValue {
  json.Object([
    #("path", json.String(path)),
    #("digest", json.String(digest)),
    #(
      "hunks",
      json.Array([
        json.Object([
          #("op", json.String("insert_at_start")),
          #("lines", json.Array([json.String("new")])),
        ]),
      ]),
    ),
  ])
}

fn returned(response: workspace.Response) -> workspace_tools.Service {
  fn(_, _) { Ok(workspace_local.Completed(response, None)) }
}

pub fn ordinary_read_keeps_original_ctx_and_never_falls_back_test() {
  let ctx = owner_ctx()
  let recorded = process.new_subject()
  let reader =
    workspace_tools.read_tool(
      fn(received, request) {
        process.send(recorded, #(received, request))
        Ok(workspace_local.Completed(
          workspace.ReadCompleted(
            Ok(workspace.AnchoredRead(
              hashline.digest("a\nb\nc\n"),
              hashline.window("a\nb\nc\n", offset: 2, limit: 1),
            )),
          ),
          None,
        ))
      },
      [],
    )
  let outcome =
    reader.run(
      ctx,
      json.Object([
        #("path", json.String("src/a")),
        #("offset", json.Int(2)),
        #("limit", json.Int(1)),
      ]),
    )
  let assert Ok(#(received, request)) = process.receive(recorded, 1000)
    as "one semantic request was sent"
  let assert Ok(path) = core_workspace.relative_path("src/a")
    as "fixture path is valid"
  assert received == ctx
  assert request == workspace.Read(path, workspace.Native(2, 1))
  assert !outcome.is_error
  assert string.contains(text(outcome), "offset 3")
  assert reader.replay == tool.Never
  assert fs.read_tool().replay == tool.Safe
}

pub fn native_read_projection_matches_local_windows_and_empty_test() {
  let local = local_ctx()
  let owner = owner_ctx()
  let content = "one\ntwo\nlast"
  assert local_workspace(local).filesystem.write("/work/a", <<content:utf8>>)
    == Ok(Nil)
  list.each([#(1, 2), #(2, 1), #(9, 1)], fn(window) {
    let #(offset, limit) = window
    let arguments =
      json.Object([
        #("path", json.String("a")),
        #("offset", json.Int(offset)),
        #("limit", json.Int(limit)),
      ])
    let remote =
      workspace_tools.read_tool(
        returned(
          workspace.ReadCompleted(
            Ok(workspace.AnchoredRead(
              hashline.digest(content),
              hashline.window(content, offset:, limit:),
            )),
          ),
        ),
        [],
      )
    assert remote.run(owner, arguments) == fs.read_tool().run(local, arguments)
  })
  assert local_workspace(local).filesystem.write("/work/a", <<>>) == Ok(Nil)
  let remote =
    workspace_tools.read_tool(
      returned(
        workspace.ReadCompleted(
          Ok(workspace.AnchoredRead(
            hashline.digest(""),
            hashline.window("", offset: 1, limit: 2000),
          )),
        ),
      ),
      [],
    )
  assert remote.run(owner, args("a")) == fs.read_tool().run(local, args("a"))
}

pub fn oversized_retained_read_refuses_complete_looking_anchors_test() {
  let content = string.repeat("x", blob.overflow_threshold_bytes)
  let remote =
    workspace_tools.read_tool(
      returned(
        workspace.ReadCompleted(
          Ok(workspace.AnchoredRead(
            hashline.digest(content),
            hashline.window(content, offset: 1, limit: 1),
          )),
        ),
      ),
      [],
    )
  let outcome = remote.run(owner_ctx(), args("a"))
  assert outcome.is_error
  assert string.contains(text(outcome), "read a smaller window")
}

pub fn image_results_keep_all_native_blocks_test() {
  let owner = owner_ctx()
  let local = local_ctx()
  list.each(
    [
      #(<<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>, workspace.Png),
      #(<<0xFF, 0xD8, 0xFF>>, workspace.Jpeg),
      #(<<"GIF89a">>, workspace.Gif),
      #(<<"RIFF", 0:size(32), "WEBP">>, workspace.Webp),
    ],
    fn(image) {
      let #(bytes, media) = image
      assert local_workspace(local).filesystem.write("/work/a.txt", bytes)
        == Ok(Nil)
      let remote =
        workspace_tools.read_tool(
          returned(
            workspace.ReadCompleted(Ok(workspace.ImageRead(bytes, media))),
          ),
          [],
        )
      let outcome = remote.run(owner, args("a.txt"))
      assert outcome == fs.read_tool().run(local, args("a.txt"))
      assert list.length(outcome.content) == 2
    },
  )
}

pub fn writes_preserve_exact_evidence_diagnostics_and_original_ctx_test() {
  let owner = owner_ctx()
  let local = local_ctx()
  let recorded = process.new_subject()
  let content = "new\nbytes\n"
  let diagnostics = Some("settled compiler diagnostics")
  let anchors = hashline.annotate(content)
  let writer =
    workspace_tools.write_tool(fn(ctx, request) {
      process.send(recorded, #(ctx, request))
      Ok(workspace_local.Completed(
        workspace.WriteCompleted(
          Ok(workspace.Written(
            bit_array.byte_size(<<content:utf8>>),
            hashline.digest(content),
            workspace.Included(anchors),
          )),
        ),
        diagnostics,
      ))
    })
  let arguments =
    json.Object([
      #("path", json.String("a")),
      #("content", json.String(content)),
    ])
  assert writer.run(owner, arguments)
    == fs.write_tool_with(fn(_) { diagnostics }).run(local, arguments)
  let assert Ok(#(received, request)) = process.receive(recorded, 1000)
    as "one whole write was sent"
  let assert Ok(path) = core_workspace.relative_path("a")
    as "fixture path is valid"
  assert received == owner
  assert request == workspace.Write(path, content)
  assert writer.replay == tool.Never
  assert fs.write_tool().replay == tool.Safe
}

pub fn writes_preserve_empty_and_explicitly_omitted_anchors_test() {
  let owner = owner_ctx()
  let local = local_ctx()
  list.each(["", string.repeat("x", fs.max_fresh_anchor_bytes)], fn(content) {
    let anchors = case fs.written_lines(content) {
      Ok(lines) -> workspace.Included(lines)
      Error(Nil) -> workspace.RequiresWindowedRead
    }
    let remote =
      workspace_tools.write_tool(
        returned(
          workspace.WriteCompleted(
            Ok(workspace.Written(
              string.byte_size(content),
              hashline.digest(content),
              anchors,
            )),
          ),
        ),
      )
    let arguments =
      json.Object([
        #("path", json.String("a")),
        #("content", json.String(content)),
      ])
    assert remote.run(owner, arguments) == fs.write_tool().run(local, arguments)
  })
}

pub fn edits_preserve_original_plan_diff_anchors_and_diagnostics_test() {
  let owner = owner_ctx()
  let local = local_ctx()
  let recorded = process.new_subject()
  let before = "old\n"
  let edited = "new\nold\n"
  let plan =
    hashline.Plan(hashline.digest(before), [hashline.InsertAtStart(["new"])])
  assert local_workspace(local).filesystem.write("/work/a", <<before:utf8>>)
    == Ok(Nil)
  let editor =
    workspace_tools.edit_tool(fn(ctx, request) {
      process.send(recorded, #(ctx, request))
      Ok(workspace_local.Completed(
        workspace.EditCompleted(Ok(fs.Landed(before, edited))),
        Some("diagnostics"),
      ))
    })
  let arguments = edit_args("a", plan.digest)
  assert editor.run(owner, arguments)
    == fs.edit_tool_with(fn(_) { Some("diagnostics") }).run(local, arguments)
  let assert Ok(#(received, request)) = process.receive(recorded, 1000)
    as "one original edit was sent"
  let assert Ok(path) = core_workspace.relative_path("a")
    as "fixture path is valid"
  assert received == owner
  assert request == workspace.AnchoredEdit(path, plan)
  assert editor.replay == tool.Never
  assert fs.edit_tool().replay == tool.Safe
}

pub fn stale_edit_retains_fresh_digest_and_anchors_test() {
  let current = "changed\n"
  let error =
    fs.LandRejected(
      hashline.StaleContent(
        hashline.digest(current),
        hashline.annotate(current),
      ),
      current,
    )
  let remote =
    workspace_tools.edit_tool(returned(workspace.EditCompleted(Error(error))))
  let outcome =
    remote.run(owner_ctx(), edit_args("a", hashline.digest("old\n")))
  assert outcome == fs.land_error_outcome(error)
  assert outcome.is_error
  assert string.contains(text(outcome), hashline.digest(current))
}

pub fn virtual_cap_job_and_unknown_schemes_do_not_send_remote_test() {
  let owner = owner_ctx()
  let recorded = process.new_subject()
  let service = fn(_, request) {
    process.send(recorded, request)
    Error(workspace.Unavailable)
  }
  let schemes =
    list.map(["cap", "job"], fn(name) {
      fs.Scheme(name, "virtual namespace", fn(ctx, reference) {
        assert ctx == owner
        Ok("first\n" <> reference <> "\nlast")
      })
    })
  let reader = workspace_tools.read_tool(service, schemes)
  list.each(["cap", "job"], fn(name) {
    let arguments =
      json.Object([
        #("path", json.String(name <> "://reference")),
        #("offset", json.Int(2)),
        #("limit", json.Int(1)),
      ])
    let outcome = reader.run(owner, arguments)
    assert outcome == fs.read_tool_with(schemes).run(owner, arguments)
    assert !outcome.is_error
    assert !string.contains(text(outcome), "digest:")
  })
  assert reader.run(owner, args("other://unknown")).is_error
  assert process.receive(recorded, 0) == Error(Nil)
}

pub fn malformed_arguments_and_paths_refuse_before_semantic_callback_test() {
  let recorded = process.new_subject()
  let service = fn(_, request) {
    process.send(recorded, request)
    Error(workspace.Unavailable)
  }
  let ctx = owner_ctx()
  let reader = workspace_tools.read_tool(service, [])
  list.each(["/absolute", "../escape", "a/../b", "a//b", ""], fn(path) {
    assert reader.run(ctx, args(path)).is_error
    assert workspace_tools.write_tool(service).run(
      ctx,
      json.Object([#("path", json.String(path)), #("content", json.String("a"))]),
    ).is_error
    assert workspace_tools.edit_tool(service).run(
      ctx,
      edit_args(path, "digest"),
    ).is_error
  })
  assert reader.run(ctx, json.Object([#("path", json.Int(7))])).is_error
  assert reader.run(
    ctx,
    json.Object([#("path", json.String("a")), #("offset", json.Int(0))]),
  ).is_error
  assert workspace_tools.write_tool(service).run(ctx, args("a")).is_error
  assert workspace_tools.write_tool(service).run(
    ctx,
    json.Object([
      #("path", json.String("cap://fs")),
      #("content", json.String("a")),
    ]),
  ).is_error
  assert workspace_tools.edit_tool(service).run(
    ctx,
    json.Object([
      #("path", json.String("a")),
      #("digest", json.String("x")),
      #("hunks", json.String("bad")),
    ]),
  ).is_error
  assert process.receive(recorded, 0) == Error(Nil)
}

pub fn mismatched_completions_are_explicit_uncertain_invariants_test() {
  let ctx = owner_ctx()
  let wrong =
    workspace.InitializationCompleted(Ok(workspace.AlreadyInitialized))
  let service = returned(wrong)
  let outcomes = [
    workspace_tools.read_tool(service, []).run(ctx, args("a")),
    workspace_tools.write_tool(service).run(
      ctx,
      json.Object([#("path", json.String("a")), #("content", json.String("x"))]),
    ),
    workspace_tools.edit_tool(service).run(ctx, edit_args("a", "digest")),
  ]
  list.each(outcomes, fn(outcome) {
    assert outcome.is_error
    assert string.contains(text(outcome), "effect may have happened")
    assert string.contains(text(outcome), "original durable workspace request")
  })
  let wrong_read =
    workspace_tools.read_tool(
      returned(workspace.ReadCompleted(Ok(workspace.TextRead("unanchored")))),
      [],
    )
  assert wrong_read.run(ctx, args("a")).is_error
}

pub fn unknown_outcomes_keep_possible_effect_and_original_recovery_test() {
  let service = fn(_, _) { Error(workspace.OutcomeUnknown) }
  let ctx = owner_ctx()
  list.each(
    [
      workspace_tools.read_tool(service, []).run(ctx, args("a")),
      workspace_tools.write_tool(service).run(
        ctx,
        json.Object([
          #("path", json.String("a")),
          #("content", json.String("x")),
        ]),
      ),
      workspace_tools.edit_tool(service).run(ctx, edit_args("a", "digest")),
    ],
    fn(outcome) {
      assert outcome.is_error
      assert string.contains(text(outcome), "effect may have happened")
      assert string.contains(text(outcome), "original identity")
      assert string.contains(text(outcome), "do not submit a fresh invocation")
    },
  )
}

pub fn operation_errors_keep_existing_native_projection_test() {
  let ctx = owner_ctx()
  let read =
    workspace_tools.read_tool(
      returned(
        workspace.ReadCompleted(Error(workspace.FileReadFailed(fs.NotText))),
      ),
      [],
    )
  assert read.run(ctx, args("a")) == fs.read_error_outcome(fs.NotText)
  let write =
    workspace_tools.write_tool(
      returned(workspace.WriteCompleted(Error(tool.FsPermissionDenied("a")))),
    )
  assert write.run(
      ctx,
      json.Object([#("path", json.String("a")), #("content", json.String("x"))]),
    )
    == fs.fs_error_outcome(tool.FsPermissionDenied("a"))
}

// Existing local fixtures expose physical authority explicitly after migration.
fn local_workspace(ctx: tool.Ctx) -> tool.LocalWorkspaceAccess {
  let assert Ok(local) = tool.require_local_workspace(ctx)
    as "fixture requires a local workspace"
  local
}
