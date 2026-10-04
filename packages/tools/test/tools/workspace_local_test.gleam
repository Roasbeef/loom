//// Real-disk semantic host tests, with one package-build directory per case.
//// The finite scope matrix covers every closed request before any effect.
//// These tests establish local semantics, not durable admission or transport.

import broker/policy
import core/ids
import core/workspace as core_workspace
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile
import support/fake_broker
import tools/fs
import tools/hashline
import tools/search
import tools/tool
import tools/workspace
import tools/workspace_local

pub fn read_projections_share_local_semantics_test() {
  let local = fixture("read_projections")
  let assert Ok(Nil) =
    simplifile.write(local_workspace(local).root <> "/a.txt", "a\nb\nc\n")
  let host = unobserved(local)

  assert run(host, workspace.Read(path("a.txt"), workspace.Text))
    == workspace_local.Completed(
      workspace.ReadCompleted(Ok(workspace.TextRead("a\nb\nc\n"))),
      None,
    )
  let expected = hashline.window("a\nb\nc\n", 2, 1)
  assert run(host, workspace.Read(path("a.txt"), workspace.Native(2, 1)))
    == workspace_local.Completed(
      workspace.ReadCompleted(
        Ok(workspace.AnchoredRead(hashline.digest("a\nb\nc\n"), expected)),
      ),
      None,
    )
  assert run(host, workspace.Read(path("a.txt"), workspace.Lines(2, 20)))
    == workspace_local.Completed(
      workspace.ReadCompleted(
        Ok(
          workspace.LinesRead(search.Lines(
            text: "b\nc",
            first: 2,
            last: 3,
            total: 3,
          )),
        ),
      ),
      None,
    )
}

pub fn native_images_use_signatures_and_text_refuses_binary_test() {
  let local = fixture("images")
  let host = unobserved(local)
  let images = [
    #(<<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>, workspace.Png),
    #(<<0xFF, 0xD8, 0xFF>>, workspace.Jpeg),
    #(<<"GIF89a">>, workspace.Gif),
    #(<<"RIFF", 0:size(32), "WEBP">>, workspace.Webp),
  ]
  list.each(images, fn(image) {
    let assert Ok(Nil) =
      simplifile.write_bits(
        local_workspace(local).root <> "/bytes.txt",
        image.0,
      )
    assert run(host, workspace.Read(path("bytes.txt"), workspace.Native(1, 1)))
      == workspace_local.Completed(
        workspace.ReadCompleted(Ok(workspace.ImageRead(image.0, image.1))),
        None,
      )
  })

  let assert Ok(Nil) =
    simplifile.write_bits(local_workspace(local).root <> "/bytes.png", <<255>>)
  assert run(host, workspace.Read(path("bytes.png"), workspace.Text)).response
    == workspace.ReadCompleted(Error(workspace.FileReadFailed(fs.NotText)))
  assert run(host, workspace.Read(path("bytes.png"), workspace.Native(1, 1))).response
    == workspace.ReadCompleted(Error(workspace.FileReadFailed(fs.NotText)))
}

pub fn write_edit_observer_reads_landed_bytes_before_return_test() {
  let local = fixture("write_edit_order")
  let seen = process.new_subject()
  let host =
    local_host(scope(), local, fn(resolved) {
      let observed = simplifile.read(resolved)
      process.send(seen, #(resolved, observed))
      Some("settled diagnostics")
    })
  let written = run(host, workspace.Write(path("new/deep/a.txt"), "a\nb\n"))
  assert written.diagnostics == Some("settled diagnostics")
  assert written.response
    == workspace.WriteCompleted(
      Ok(workspace.Written(
        4,
        hashline.digest("a\nb\n"),
        workspace.Included(hashline.annotate("a\nb\n")),
      )),
    )
  assert process.receive(seen, 0)
    == Ok(#(local_workspace(local).root <> "/new/deep/a.txt", Ok("a\nb\n")))

  let plan = replace_first("a\nb\n", "A")
  let edited = run(host, workspace.AnchoredEdit(path("new/deep/a.txt"), plan))
  assert edited.response
    == workspace.EditCompleted(Ok(fs.Landed("a\nb\n", "A\nb\n")))
  assert edited.diagnostics == Some("settled diagnostics")
  assert process.receive(seen, 0)
    == Ok(#(local_workspace(local).root <> "/new/deep/a.txt", Ok("A\nb\n")))
  assert process.receive(seen, 0) == Error(Nil)
}

pub fn stale_digest_and_anchor_leave_disk_and_observer_untouched_test() {
  let local = fixture("stale_edit")
  let seen = process.new_subject()
  let host =
    local_host(scope(), local, fn(resolved) {
      process.send(seen, resolved)
      None
    })
  let assert Ok(Nil) =
    simplifile.write(local_workspace(local).root <> "/a.txt", "a\nnew\n")

  // The referenced first line still matches; the digest binds the unreferenced
  // sibling line too. Checking anchors alone would overwrite this new text.
  let stale =
    run(
      host,
      workspace.AnchoredEdit(path("a.txt"), replace_first("a\nold\n", "A")),
    )
  let assert workspace.EditCompleted(Error(fs.LandRejected(
    hashline.StaleContent(digest, fresh),
    "a\nnew\n",
  ))) = stale.response
  assert digest == hashline.digest("a\nnew\n")
  assert fresh == hashline.annotate("a\nnew\n")
  assert stale.diagnostics == None

  let anchored =
    run(
      host,
      workspace.AnchoredEdit(
        path("a.txt"),
        hashline.Plan(hashline.digest("a\nnew\n"), [
          hashline.Replace(hashline.Ref(1, "wrong"), hashline.Ref(1, "wrong"), [
            "A",
          ]),
        ]),
      ),
    )
  let assert workspace.EditCompleted(Error(fs.LandRejected(
    hashline.StaleAnchors([_]),
    _,
  ))) = anchored.response
  assert simplifile.read(local_workspace(local).root <> "/a.txt")
    == Ok("a\nnew\n")
  assert process.receive(seen, 0) == Error(Nil)
}

pub fn backend_write_failure_never_calls_observer_test() {
  let local = fixture("write_failed")
  let seen = process.new_subject()
  let filesystem =
    tool.FileSystem(
      ..local_workspace(local).filesystem,
      write: fn(resolved, _bytes) { Error(tool.FsPermissionDenied(resolved)) },
    )
  let host =
    local_host(
      scope(),
      tool.Ctx(
        ..local,
        workspace: tool.LocalWorkspace(local_workspace(local).root, filesystem),
      ),
      fn(resolved) {
        process.send(seen, resolved)
        None
      },
    )
  assert run(host, workspace.Write(path("a.txt"), "text")).response
    == workspace.WriteCompleted(
      Error(tool.FsPermissionDenied(local_workspace(local).root <> "/a.txt")),
    )
  let assert Ok(Nil) =
    simplifile.write(local_workspace(local).root <> "/a.txt", "a\n")
  assert run(
      host,
      workspace.AnchoredEdit(path("a.txt"), replace_first("a\n", "A")),
    ).response
    == workspace.EditCompleted(
      Error(
        fs.LandUnwritten(tool.FsPermissionDenied(
          local_workspace(local).root <> "/a.txt",
        )),
      ),
    )
  assert simplifile.read(local_workspace(local).root <> "/a.txt") == Ok("a\n")
  assert process.receive(seen, 0) == Error(Nil)
}

pub fn symlink_escape_refused_but_stat_preserves_lstat_test() {
  let local = fixture("symlink_escape")
  let outside = local_workspace(local).root <> "-outside"
  let _ = simplifile.delete(outside)
  let assert Ok(Nil) = simplifile.create_directory_all(outside)
  let assert Ok(Nil) = simplifile.write(outside <> "/a.txt", "secret\n")
  let assert Ok(Nil) =
    simplifile.create_symlink(
      to: outside,
      from: local_workspace(local).root <> "/escape",
    )
  let host = unobserved(local)
  let operations = [
    workspace.Read(path("escape/a.txt"), workspace.Text),
    workspace.Read(path("escape/a.txt"), workspace.Lines(1, 1)),
    workspace.Write(path("escape/a.txt"), "changed"),
    workspace.AnchoredEdit(
      path("escape/a.txt"),
      replace_first("secret\n", "changed"),
    ),
    workspace.ListEntries(path("escape"), listing_query(4)),
    workspace.Search(path("escape"), search_query(4)),
    workspace.Stat(path("escape/a.txt")),
  ]
  list.each(operations, fn(request) {
    let assert Error(workspace.PathRefused(fs.EscapesWorkspace(_))) =
      workspace_local.run(host, invocation(scope(), request))
  })
  assert simplifile.read(outside <> "/a.txt") == Ok("secret\n")

  // lstat observes the final link itself without accessing its target. A
  // link in a parent position remains refused by the containment resolver.
  let assert workspace.StatCompleted(Ok(entry)) =
    run(host, workspace.Stat(path("escape"))).response
  assert entry.path == "escape"
  assert entry.kind == search.Symlink(outside)
}

pub fn protected_target_and_alias_refuse_write_and_edit_test() {
  let local = fixture("protected_alias")
  let protected = local_workspace(local).root <> "/.git"
  let assert Ok(Nil) = simplifile.create_directory_all(protected)
  let assert Ok(Nil) = simplifile.write(protected <> "/config", "a\n")
  let assert Ok(Nil) =
    simplifile.create_symlink(
      to: ".git/config",
      from: local_workspace(local).root <> "/alias",
    )
  let local =
    tool.Ctx(
      ..local,
      base_policy: policy.SandboxPolicy(..local.base_policy, protected: [
        protected,
      ]),
    )
  let host = unobserved(local)
  list.each([".git/config", "alias"], fn(name) {
    list.each(
      [
        workspace.Write(path(name), "changed"),
        workspace.AnchoredEdit(path(name), replace_first("a\n", "A")),
      ],
      fn(request) {
        let assert Error(workspace.PathRefused(fs.ProtectedPath(
          _,
          protected: refused,
        ))) = workspace_local.run(host, invocation(scope(), request))
        assert refused == protected
      },
    )
  })
  assert simplifile.read(protected <> "/config") == Ok("a\n")

  // Existing native semantics allow a read of protected metadata. Protection
  // is a write boundary, and the semantic host preserves that distinction.
  assert run(host, workspace.Read(path("alias"), workspace.Text)).response
    == workspace.ReadCompleted(Ok(workspace.TextRead("a\n")))
}

pub fn contained_symlink_reads_and_writes_share_target_test() {
  let local = fixture("contained_link")
  let assert Ok(Nil) =
    simplifile.write(local_workspace(local).root <> "/a.txt", "a\n")
  let assert Ok(Nil) =
    simplifile.create_symlink(
      to: "a.txt",
      from: local_workspace(local).root <> "/alias",
    )
  let host = unobserved(local)
  assert run(host, workspace.Read(path("alias"), workspace.Text)).response
    == workspace.ReadCompleted(Ok(workspace.TextRead("a\n")))
  let _ = run(host, workspace.Write(path("alias"), "b\n"))
  assert simplifile.read(local_workspace(local).root <> "/a.txt") == Ok("b\n")
  let assert workspace.StatCompleted(Ok(entry)) =
    run(host, workspace.Stat(path("alias"))).response
  assert entry.kind == search.Symlink("a.txt")
}

pub fn bounded_listing_and_search_keep_partial_coverage_test() {
  let local = fixture("bounded_search")
  let assert Ok(Nil) =
    simplifile.write(
      local_workspace(local).root <> "/a.txt",
      "needle\nneedle\n",
    )
  let assert Ok(Nil) =
    simplifile.write(local_workspace(local).root <> "/b.txt", "needle\n")
  let host = unobserved(local)
  let assert workspace.ListingCompleted(Ok(listing)) =
    run(host, workspace.ListEntries(path("."), listing_query(1))).response
  assert list.length(listing.entries) == 1
  assert listing.completeness == search.Truncated
  let assert workspace.SearchCompleted(Ok(found)) =
    run(host, workspace.Search(path("."), search_query(1))).response
  assert list.length(found.matches) == 1
  assert found.coverage == search.MatchesCapped

  let assert Ok(Nil) =
    simplifile.write_bits(local_workspace(local).root <> "/c.txt", <<255>>)
  let assert workspace.SearchCompleted(Ok(found)) =
    run(host, workspace.Search(path("."), search_query(10))).response
  assert list.length(found.matches) == 3
  assert found.coverage == search.Exhaustive
  assert found.files_skipped == 1
  assert found.files_scanned == 2
  let assert workspace.SearchCompleted(Error(search.InvalidQuery(_))) =
    run(
      host,
      workspace.Search(path("."), search_query(search.max_matches_ceiling + 1)),
    ).response
}

pub fn native_inline_byte_cap_and_read_span_fail_explicitly_test() {
  let local = fixture("native_bounds")
  let assert Ok(Nil) =
    simplifile.write(
      local_workspace(local).root <> "/large.txt",
      string.repeat("x", 65_536),
    )
  let host = unobserved(local)
  assert workspace_local.run(
      host,
      invocation(
        scope(),
        workspace.Read(path("large.txt"), workspace.Native(1, 1)),
      ),
    )
    == Error(workspace.CapacityRefused)
  assert run(host, workspace.Read(path("large.txt"), workspace.Text)).response
    == workspace.ReadCompleted(
      Ok(workspace.TextRead(string.repeat("x", 65_536))),
    )
  let assert workspace.ReadCompleted(Error(workspace.LinesReadFailed(search.InvalidQuery(
    _,
  )))) =
    run(
      host,
      workspace.Read(
        path("large.txt"),
        workspace.Lines(1, search.max_line_span + 1),
      ),
    ).response
  assert run(host, workspace.Read(path("absent"), workspace.Native(0, 1))).response
    == workspace.ReadCompleted(Error(workspace.InvalidWindow))
}

pub fn whole_file_byte_bound_is_retained_test() {
  let local = fixture("whole_file_bound")
  let assert Ok(Nil) =
    simplifile.write(
      local_workspace(local).root <> "/large.txt",
      string.repeat("x", fs.max_read_bytes + 1),
    )
  let host = unobserved(local)
  list.each([workspace.Text, workspace.Native(1, 1)], fn(view) {
    assert run(host, workspace.Read(path("large.txt"), view)).response
      == workspace.ReadCompleted(
        Error(
          workspace.FileReadFailed(fs.TooLarge(
            fs.max_read_bytes + 1,
            fs.max_read_bytes,
          )),
        ),
      )
  })
}

pub fn fresh_write_anchors_are_complete_or_explicitly_omitted_test() {
  let local = fixture("write_anchor_bounds")
  let host = unobserved(local)
  let content = string.repeat("x\n", 1200)
  let assert workspace.WriteCompleted(Ok(workspace.Written(
    bytes,
    digest,
    anchors,
  ))) = run(host, workspace.Write(path("many_lines.txt"), content)).response
  assert bytes == string.byte_size(content)
  assert digest == hashline.digest(content)
  assert anchors == workspace.RequiresWindowedRead
  assert simplifile.read(local_workspace(local).root <> "/many_lines.txt")
    == Ok(content)
  assert run(host, workspace.Write(path("empty"), "")).response
    == workspace.WriteCompleted(
      Ok(workspace.Written(0, hashline.digest(""), workspace.Included([]))),
    )
}

pub fn mutation_capacity_refusal_precedes_all_filesystem_work_test() {
  let local = fixture("mutation_capacity")
  let effects = process.new_subject()
  let local = instrument(local, effects)
  let host = unobserved(local)
  assert workspace_local.run(
      host,
      invocation(
        scope(),
        workspace.Write(
          path("new/file"),
          string.repeat("x", workspace_local.max_request_bytes + 1),
        ),
      ),
    )
    == Error(workspace.CapacityRefused)
  let plan =
    hashline.Plan(
      "unused",
      list.repeat(
        hashline.InsertAtStart(["x"]),
        workspace_local.max_edit_hunks + 1,
      ),
    )
  assert workspace_local.run(
      host,
      invocation(scope(), workspace.AnchoredEdit(path("new/file"), plan)),
    )
    == Error(workspace.CapacityRefused)
  assert process.receive(effects, 0) == Error(Nil)
  assert simplifile.is_directory(local_workspace(local).root <> "/new")
    == Ok(False)
}

pub fn every_scope_coordinate_fences_every_closed_request_test() {
  let local = fixture("scope_matrix")
  let effects = process.new_subject()
  let local = instrument(local, effects)
  let host =
    local_host(scope(), local, fn(_resolved) {
      process.send(effects, "observer")
      None
    })
    |> workspace_local.with_git(fn(_ctx, _invocation, _query) {
      process.send(effects, "git")
      Ok(workspace.BranchObserved("main"))
    })
    |> workspace_local.with_guidance(fn(_ctx, _invocation) {
      process.send(effects, "guidance")
      Ok(workspace.GuidanceLoaded([], search.Complete))
    })
    |> workspace_local.with_initialization(fn(_ctx, _invocation) {
      process.send(effects, "initialization")
      Ok(workspace.Initialized)
    })
  let mismatches = [
    scope_fields(
      "00000000-0000-7000-8000-000000000002",
      "checkout",
      "executor",
      1,
      1,
    ),
    scope_fields(session(), "other", "executor", 1, 1),
    scope_fields(session(), "checkout", "other", 1, 1),
    scope_fields(session(), "checkout", "executor", 2, 1),
    scope_fields(session(), "checkout", "executor", 1, 2),
  ]
  let requests = [
    workspace.Read(path("a"), workspace.Text),
    workspace.Read(path("a"), workspace.Native(1, 1)),
    workspace.Read(path("a"), workspace.Lines(1, 1)),
    workspace.Write(path("a"), "land"),
    workspace.AnchoredEdit(path("a"), replace_first("a\n", "A")),
    workspace.ListEntries(path("."), listing_query(1)),
    workspace.Search(path("."), search_query(1)),
    workspace.Stat(path("a")),
    workspace.Git(workspace.CurrentBranch),
    workspace.Guidance,
    workspace.Initialize,
  ]

  // Five independent authority coordinates times eleven request projections.
  // Instrumented path probes, reads, writes, hooks and callbacks remain empty.
  list.each(mismatches, fn(stale_scope) {
    list.each(requests, fn(request) {
      assert workspace_local.run(host, invocation(stale_scope, request))
        == Error(workspace.StaleScope)
    })
  })
  assert process.receive(effects, 0) == Error(Nil)
  assert simplifile.is_file(local_workspace(local).root <> "/a") == Ok(False)
}

pub fn unbound_callbacks_return_unavailable_test() {
  let host = unobserved(fixture("unavailable"))
  list.each(
    [
      workspace.Git(workspace.CurrentBranch),
      workspace.Guidance,
      workspace.Initialize,
    ],
    fn(request) {
      assert workspace_local.run(host, invocation(scope(), request))
        == Error(workspace.Unavailable)
    },
  )
}

pub fn git_callback_wrong_projection_is_refused_test() {
  let host =
    unobserved(fixture("git_wrong_projection"))
    |> workspace_local.with_git(fn(_ctx, _called, _query) {
      Ok(workspace.BranchObserved("main"))
    })
  assert workspace_local.run(
      host,
      invocation(scope(), workspace.Git(workspace.CurrentRevision)),
    )
    == Error(workspace.InvalidRequest)
}

pub fn git_log_bounds_precede_callback_clearance_test() {
  let called = process.new_subject()
  let host =
    unobserved(fixture("git_log_bounds"))
    |> workspace_local.with_git(fn(_ctx, _invocation, query) {
      process.send(called, query)
      Ok(workspace.LogObserved([]))
    })
  list.each([0, -1, workspace_local.max_git_log_entries + 1], fn(limit) {
    assert workspace_local.run(
        host,
        invocation(scope(), workspace.Git(workspace.Log(limit))),
      )
      == Error(workspace.InvalidRequest)
  })
  assert process.receive(called, 0) == Error(Nil)
  let _ = run(host, workspace.Git(workspace.Log(1)))
  assert process.receive(called, 0) == Ok(workspace.Log(1))
}

pub fn typed_callbacks_retain_exact_invocation_and_local_context_test() {
  let local = fixture("callbacks")
  let calls = process.new_subject()
  let host =
    unobserved(local)
    |> workspace_local.with_git(fn(ctx, called, query) {
      process.send(calls, #(
        local_workspace(ctx).root,
        ctx.op_id,
        ctx.step_id,
        ctx.source_index,
        called,
        query,
      ))
      Ok(workspace.BranchObserved("topic"))
    })
  let assert Ok(origin) = workspace.tool_origin(7, <<0:size(256)>>)
  let assert Ok(operation) =
    ids.parse_op_id("00000000-0000-7000-8000-000000000007")
  let assert Ok(step) = core_workspace.step("turn:7")
  let assert Ok(request_id) =
    ids.parse_entry_id("00000000-0000-7000-8000-000000000008")
  let call =
    workspace.invocation(
      scope(),
      operation,
      step,
      workspace.Tool(origin),
      request_id,
      workspace.Git(workspace.CurrentBranch),
    )
  assert workspace_local.run(host, call)
    == Ok(workspace_local.Completed(
      workspace.GitCompleted(Ok(workspace.BranchObserved("topic"))),
      None,
    ))
  assert process.receive(calls, 0)
    == Ok(#(
      local_workspace(local).root,
      operation,
      "turn:7",
      7,
      call,
      workspace.CurrentBranch,
    ))

  let host =
    host
    |> workspace_local.with_guidance(fn(_ctx, called) {
      assert workspace.request(called) == workspace.Guidance
      Ok(workspace.GuidanceLoaded(
        [workspace.GuidanceFile(path("AGENTS.md"), "rules")],
        search.Truncated,
      ))
    })
    |> workspace_local.with_initialization(fn(_ctx, called) {
      assert workspace.request(called) == workspace.Initialize
      Error(tool.FsPermissionDenied(local_workspace(local).root))
    })
  assert run(host, workspace.Guidance).response
    == workspace.GuidanceCompleted(
      Ok(workspace.GuidanceLoaded(
        [workspace.GuidanceFile(path("AGENTS.md"), "rules")],
        search.Truncated,
      )),
    )
  assert run(host, workspace.Initialize).response
    == workspace.InitializationCompleted(
      Error(tool.FsPermissionDenied(local_workspace(local).root)),
    )
}

fn fixture(name: String) -> tool.Ctx {
  let assert Ok(here) = simplifile.current_directory()
  let root = here <> "/build/workspace_local_test/" <> name
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  fake_broker.ctx(root, fs.real_filesystem(), 1000, [], process.new_subject())
}

fn unobserved(local: tool.Ctx) -> workspace_local.Host {
  local_host(scope(), local, fn(_resolved) { None })
}

fn session() -> String {
  "00000000-0000-7000-8000-000000000001"
}

fn scope() -> core_workspace.Scope {
  scope_fields(session(), "checkout", "executor", 1, 1)
}

fn scope_fields(
  session: String,
  checkout: String,
  executor: String,
  owner_epoch: Int,
  workspace_epoch: Int,
) -> core_workspace.Scope {
  let assert Ok(scope) =
    core_workspace.scope_from_fields(
      session,
      checkout,
      executor,
      owner_epoch,
      workspace_epoch,
    )
  scope
}

fn path(value: String) -> core_workspace.RelativePath {
  let assert Ok(path) = core_workspace.relative_path(value)
  path
}

fn invocation(
  scope: core_workspace.Scope,
  request: workspace.Request,
) -> workspace.Invocation {
  let assert Ok(operation) =
    ids.parse_op_id("00000000-0000-7000-8000-000000000003")
  let assert Ok(step) = core_workspace.step("turn:1")
  let assert Ok(request_id) =
    ids.parse_entry_id("00000000-0000-7000-8000-000000000004")
  workspace.invocation(
    scope,
    operation,
    step,
    workspace.System(workspace.WorkspaceAdministration),
    request_id,
    request,
  )
}

fn run(
  host: workspace_local.Host,
  request: workspace.Request,
) -> workspace_local.Completed {
  let assert Ok(completed) =
    workspace_local.run(host, invocation(scope(), request))
  assert workspace.response_matches(request, completed.response)
  completed
}

fn replace_first(content: String, line: String) -> hashline.Plan {
  let assert [first, ..] = hashline.annotate(content)
  let reference = hashline.Ref(first.line, first.anchor)
  hashline.Plan(hashline.digest(content), [
    hashline.Replace(reference, reference, [line]),
  ])
}

fn listing_query(limit: Int) -> search.GlobQuery {
  search.GlobQuery("**", limit, search.SkipHidden, search.default_prune)
}

fn search_query(limit: Int) -> search.GrepQuery {
  search.GrepQuery(
    "needle",
    [],
    0,
    limit,
    search.SkipHidden,
    search.default_prune,
  )
}

fn instrument(local: tool.Ctx, effects: process.Subject(String)) -> tool.Ctx {
  let filesystem = local_workspace(local).filesystem
  tool.Ctx(
    ..local,
    workspace: tool.LocalWorkspace(
      local_workspace(local).root,
      tool.FileSystem(
        read: fn(path) {
          process.send(effects, "read")
          filesystem.read(path)
        },
        write: fn(path, bytes) {
          process.send(effects, "write")
          filesystem.write(path, bytes)
        },
        create_directory_all: fn(path) {
          process.send(effects, "mkdir")
          filesystem.create_directory_all(path)
        },
        is_file: fn(path) {
          process.send(effects, "is_file")
          filesystem.is_file(path)
        },
        read_link: fn(path) {
          process.send(effects, "read_link")
          filesystem.read_link(path)
        },
        rename: fn(from, to) {
          process.send(effects, "rename")
          filesystem.rename(from, to)
        },
      ),
    ),
  )
}

// Existing local fixtures expose physical authority explicitly after migration.
fn local_workspace(ctx: tool.Ctx) -> tool.LocalWorkspaceAccess {
  let assert Ok(local) = tool.require_local_workspace(ctx)
    as "fixture requires a local workspace"
  local
}

// A registered context cannot construct the executor-local host.
fn local_host(
  scope: core_workspace.Scope,
  ctx: tool.Ctx,
  observer: fn(String) -> option.Option(String),
) -> workspace_local.Host {
  let assert Ok(host) = workspace_local.new(scope, ctx, observer)
    as "fixture must have local authority"
  host
}
