//// Registered identity cannot be consumed as local filesystem authority.

import broker/exec
import core/json
import core/message
import core/workspace as core_workspace
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import support/fake_broker
import support/memory_fs
import tools/bash
import tools/blob
import tools/codemode
import tools/fs
import tools/grep
import tools/job
import tools/permissions
import tools/tool
import tools/workspace
import tools/workspace_local

fn scope() -> core_workspace.Scope {
  let assert Ok(scope) =
    core_workspace.scope_from_fields(
      "00000000-0000-7000-8000-000000000001",
      "workspace",
      "executor",
      1,
      1,
    )
    as "fixture scope is valid"
  scope
}

fn guarded_filesystem() -> tool.FileSystem {
  tool.FileSystem(
    read: fn(_) { panic as "unexpected owner read" },
    write: fn(_, _) { panic as "unexpected owner write" },
    create_directory_all: fn(_) { panic as "unexpected owner mkdir" },
    is_file: fn(_) { panic as "unexpected owner stat" },
    read_link: fn(_) { panic as "unexpected owner path resolution" },
    rename: fn(_, _) { panic as "unexpected owner rename" },
  )
}

fn registered() -> tool.Ctx {
  let base =
    fake_broker.ctx(
      workspace: "/local-fixture",
      filesystem: guarded_filesystem(),
      now: 1000,
      script: [],
      recorded: process.new_subject(),
    )
  tool.Ctx(
    ..base,
    workspace: tool.RegisteredWorkspace(scope()),
    owner_blobs: tool.OwnerBlobs("/owner/blobs", guarded_filesystem()),
    clear_call: fn(_, _) {
      panic as "registered local operation cleared a broker call"
    },
    raise_refusal: fn(_) { panic as "registered local operation escalated" },
  )
}

fn arguments(path: String) -> json.JsonValue {
  json.Object([#("path", json.String(path))])
}

fn is_local_refusal(outcome: tool.ToolOutcome) -> Bool {
  outcome.is_error
  && outcome.content
  == [
    tool.text_block(
      "this operation requires a local workspace; the registered workspace needs its semantic service adapter",
    ),
  ]
  && outcome.details
  == Some(json.Object([#("error", json.String("local_workspace_required"))]))
}

pub fn local_projection_preserves_exact_root_and_filesystem_test() {
  let filesystem = memory_fs.filesystem(memory_fs.start())
  let ctx =
    fake_broker.ctx(
      workspace: "/physical/workspace",
      filesystem:,
      now: 1000,
      script: [],
      recorded: process.new_subject(),
    )
  assert tool.require_local_workspace(ctx)
    == Ok(tool.LocalWorkspaceAccess("/physical/workspace", filesystem))
  let assert Error(outcome) = tool.require_local_workspace(registered())
    as "registered identity is not local authority"
  assert is_local_refusal(outcome)
}

pub fn registered_native_filesystem_doors_refuse_before_owner_io_test() {
  let ctx = registered()
  assert is_local_refusal(fs.read_tool().run(ctx, arguments("a")))
  assert is_local_refusal(fs.write_tool().run(
    ctx,
    json.Object([
      #("path", json.String("a")),
      #("content", json.String("replacement")),
    ]),
  ))
  assert is_local_refusal(fs.edit_tool().run(
    ctx,
    json.Object([
      #("path", json.String("a")),
      #("digest", json.String("digest")),
      #(
        "hunks",
        json.Array([
          json.Object([
            #("op", json.String("insert_at_start")),
            #("lines", json.Array([json.String("new")])),
          ]),
        ]),
      ),
    ]),
  ))
  let assert Error(read) = fs.read_text(ctx, "source.gleam")
    as "physical source read requires local authority"
  let assert Error(edit) = fs.edit_target(ctx, "a")
    as "edit target requires local authority"
  let assert Error(write) = fs.resolve_for_write(ctx, "a")
    as "write resolution requires local authority"
  assert is_local_refusal(read)
  assert is_local_refusal(edit)
  assert is_local_refusal(write)
}

pub fn registered_virtual_reads_dispatch_without_local_projection_test() {
  let ctx = registered()
  let scheme =
    fs.Scheme("cap", "virtual owner modules", fn(received, reference) {
      assert received == ctx
      Ok(reference)
    })
  assert !fs.read_tool_with([scheme]).run(ctx, arguments("cap://fs")).is_error
  assert fs.read_tool_with([scheme]).run(ctx, arguments("unknown://fs")).is_error
}

pub fn registered_bash_modes_refuse_before_jobs_or_broker_test() {
  let jobs =
    job.Jobs(
      ..job.unavailable(),
      start: fn(_, _, _, _) { panic as "registered local bash started a job" },
      attend: fn(_, _, _) { panic as "registered local bash attended a job" },
    )
  let ctx = registered()
  let default =
    bash.tool(jobs).run(
      ctx,
      json.Object([#("command", json.String("touch a"))]),
    )
  assert is_local_refusal(default)
  list.each(["foreground", "background", "auto"], fn(mode) {
    assert is_local_refusal(bash.tool(jobs).run(
      ctx,
      json.Object([
        #("command", json.String("touch a")),
        #("mode", json.String(mode)),
      ]),
    ))
  })
}

pub fn registered_grep_and_path_permissions_refuse_before_effects_test() {
  let ctx = registered()
  assert is_local_refusal(grep.tool().run(
    ctx,
    json.Object([#("pattern", json.String("secret"))]),
  ))
  let assert Error(outcome) =
    permissions.authorize(
      ctx,
      json.Object([
        #(
          "permissions",
          json.Object([#("readable_roots", json.Array([json.String("a")]))]),
        ),
      ]),
    )
    as "path declarations need local authority"
  assert is_local_refusal(outcome)
  assert permissions.authorize(ctx, json.Object([])) == Ok(ctx)
  let assert Error(native) = permissions.authorize_native(ctx, json.Object([]))
    as "native effects always require local authority"
  assert is_local_refusal(native)
}

fn mode() -> codemode.CodeMode {
  codemode.CodeMode(
    execute: fn(_) { panic as "registered local code-mode executed" },
    background: Some(
      codemode.Background(
        launch: fn(_) { panic as "registered local code-mode launched" },
        interact: fn(_, _, _, _) { Ok(json.String("owner interaction")) },
      ),
    ),
    seams: codemode.one_seam(
      codemode.SeamOffer(codemode.WorkspaceSeam, [], [], []),
    ),
    default_within_ms: 1000,
    max_within_ms: 1000,
  )
}

pub fn registered_codemode_sources_refuse_before_execution_and_io_test() {
  let ctx = registered()
  let definition = codemode.tool_for(mode())
  list.each(["program", "program_path"], fn(source) {
    list.each(["run", "launch"], fn(operation) {
      assert is_local_refusal(definition.run(
        ctx,
        json.Object([
          #(source, json.String("source")),
          #("mode", json.String(operation)),
        ]),
      ))
    })
  })
  let assert Error(outcome) =
    codemode.request(mode(), ctx, "source", None, on: codemode.WorkspaceSeam)
    as "physical request builder requires local authority"
  assert is_local_refusal(outcome)
  assert !definition.run(
    ctx,
    json.Object([
      #("mode", json.String("check")),
      #("handle", json.String("retained-owner-handle")),
    ]),
  ).is_error
}

pub fn registered_workspace_cannot_construct_a_local_host_test() {
  assert workspace_local.new(scope(), registered(), fn(_) {
      panic as "registered local observer ran"
    })
    == Error(workspace.PermissionRefused)
}

pub fn registered_owner_blobs_store_independently_of_workspace_test() {
  let filesystem = memory_fs.filesystem(memory_fs.start())
  let ctx =
    tool.Ctx(
      ..registered(),
      owner_blobs: tool.OwnerBlobs("/owner/result-store", filesystem),
    )
  let content = string.repeat("x", blob.overflow_threshold_bytes + 1)
  let assert Ok(blob.Overflowed(ref:, ..)) = blob.bound(ctx, content)
    as "owner storage is available for remote workspace results"
  assert filesystem.read(blob.ref_path("/owner/result-store", ref))
    == Ok(<<content:utf8>>)
  assert filesystem.is_file("/local-fixture/a") == Ok(False)
  assert ctx.workspace == tool.RegisteredWorkspace(scope())
  let assert Error(outcome) = tool.require_local_workspace(ctx)
    as "owner storage cannot project workspace authority"
  assert is_local_refusal(outcome)
}

pub fn local_bash_spill_recovery_reads_owner_blobs_not_workspace_test() {
  let filesystem = memory_fs.filesystem(memory_fs.start())
  let complete = "complete owner spill\n"
  let ref = blob.ref_for(<<complete:utf8>>)
  assert filesystem.write(blob.ref_path("/owner/result-store", ref), <<
      complete:utf8,
    >>)
    == Ok(Nil)
  let ctx =
    tool.Ctx(
      ..registered(),
      workspace: tool.LocalWorkspace(
        "/executor-workspace",
        guarded_filesystem(),
      ),
      owner_blobs: tool.OwnerBlobs("/owner/result-store", filesystem),
    )
  let result =
    exec.ExecResult(
      code: 0,
      signal: 0,
      stdout_bytes: string.byte_size(complete),
      stderr_bytes: 0,
      stdout_truncated: False,
      stderr_truncated: False,
      enforcement: [],
      degraded: False,
      wall_ms: 1,
      timed_out: False,
      cancelled: False,
    )
  let jobs =
    job.Jobs(
      ..job.unavailable(),
      attend: fn(_, _, _) { Ok(job.Started("retained-job", 10_000, 1000)) },
      poll: fn(_, _, _, _) {
        Ok(job.Polled(
          "retained-job",
          job.Exited(result),
          1,
          10_000,
          job.Streamed(<<"tail">>, string.byte_size(complete), 1),
          job.Streamed(<<>>, 0, 0),
          job.JobSpill(Some(ref), None),
        ))
      },
    )
  let outcome =
    bash.tool(jobs).run(
      ctx,
      json.Object([#("command", json.String("retained command"))]),
    )
  let assert [message.ToolResultText(text:, ..), ..] = outcome.content
    as "native execution preserves model-visible output"
  assert string.contains(text, complete)
  assert !outcome.is_error
}
