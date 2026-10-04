import core/ids
import core/workspace as core_workspace
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import tools/fs
import tools/hashline
import tools/search
import tools/tool
import tools/workspace

fn registered_scope(
  session: String,
  session_epoch: Int,
  workspace_epoch: Int,
) -> core_workspace.Scope {
  let assert Ok(scope) =
    core_workspace.scope_from_fields(
      session,
      "loom",
      "linux",
      session_epoch,
      workspace_epoch,
    )
  scope
}

fn operation() -> ids.OpId {
  let assert Ok(op) = ids.parse_op_id("00000000-0000-7000-8000-000000000002")
  op
}

fn request_id(text: String) -> ids.EntryId {
  let assert Ok(id) = ids.parse_entry_id(text)
  id
}

fn invocation(request: workspace.Request) -> workspace.Invocation {
  let scope = registered_scope("00000000-0000-7000-8000-000000000001", 2, 3)
  let assert Ok(step) = core_workspace.step("job/j1:build")
  let assert Ok(origin) = workspace.tool_origin(4, <<1:size(256)>>)
  workspace.invocation(
    scope,
    operation(),
    step,
    workspace.Tool(origin),
    request_id("00000000-0000-7000-8000-000000000003"),
    request,
  )
}

pub fn invocation_retains_exact_stable_owner_coordinates_and_request_test() {
  let invocation = invocation(workspace.Initialize)
  let #(scope, op, step, origin, id) = workspace.invocation_identity(invocation)
  let assert workspace.Tool(tool_origin) = origin
  assert workspace.tool_origin_fields(tool_origin) == #(4, <<1:size(256)>>)
  assert core_workspace.step_string(step) == "job/j1:build"
  assert op == operation()
  assert ids.entry_id_to_string(id) == "00000000-0000-7000-8000-000000000003"
  let #(session, bound) = core_workspace.scope_fields(scope)
  assert ids.session_id_to_string(session)
    == "00000000-0000-7000-8000-000000000001"
  let #(selector, workspace_epoch, session_epoch) =
    core_workspace.binding_fields(bound)
  assert core_workspace.selector_fields(selector) == #("linux", "loom")
  assert workspace_epoch == 3
  assert session_epoch == 2
  assert workspace.request(invocation) == workspace.Initialize
}

pub fn siblings_and_changed_scope_or_content_are_distinct_invocations_test() {
  let original = invocation(workspace.Initialize)
  let #(scope, op, step, origin, id) = workspace.invocation_identity(original)
  let sibling_id = request_id("00000000-0000-7000-8000-000000000004")
  assert workspace.invocation(
      scope,
      op,
      step,
      origin,
      sibling_id,
      workspace.Initialize,
    )
    != original
  assert workspace.invocation(scope, op, step, origin, id, workspace.Guidance)
    != original
  let changed_scope =
    registered_scope("00000000-0000-7000-8000-000000000001", 3, 3)
  assert workspace.invocation(
      changed_scope,
      op,
      step,
      origin,
      id,
      workspace.Initialize,
    )
    != original
}

pub fn tool_origin_boundaries_refuse_without_clamping_or_truncating_test() {
  let digest = <<0:size(256)>>
  assert workspace.tool_origin(0, digest) |> result.is_ok
  assert workspace.tool_origin(2_147_483_647, digest) |> result.is_ok
  assert workspace.tool_origin(-1, digest) == Error(workspace.SourceIndexRange)
  assert workspace.tool_origin(2_147_483_648, digest)
    == Error(workspace.SourceIndexRange)
  assert workspace.tool_origin(0, <<>>) == Error(workspace.ArgumentsDigestSize)
  assert workspace.tool_origin(0, <<0:size(255)>>)
    == Error(workspace.ArgumentsDigestSize)
  assert workspace.tool_origin(0, <<0:size(264)>>)
    == Error(workspace.ArgumentsDigestSize)
}

pub fn system_origin_requires_no_manufactured_tool_index_test() {
  let #(scope, op, step, _, id) =
    workspace.invocation_identity(invocation(workspace.Initialize))
  let origin = workspace.System(workspace.WorkspaceAdministration)
  let call =
    workspace.invocation(scope, op, step, origin, id, workspace.Initialize)
  let #(_, _, _, actual_origin, _) = workspace.invocation_identity(call)
  assert actual_origin == origin
}

pub fn semantic_response_shapes_cover_every_request_and_reject_cross_operation_results_test() {
  let path = core_workspace.root()
  let listing = search.GlobQuery("*", 10, search.SkipHidden, [])
  let query = search.GrepQuery("a", [], 0, 10, search.SkipHidden, [])
  let plan = hashline.Plan(hashline.digest("a"), [])
  let error = tool.FsNotFound("missing")
  let pairs = [
    #(
      workspace.Read(path, workspace.Text),
      workspace.ReadCompleted(
        Error(workspace.FileReadFailed(fs.ReadFailed(error))),
      ),
    ),
    #(workspace.Write(path, "text"), workspace.WriteCompleted(Error(error))),
    #(
      workspace.AnchoredEdit(path, plan),
      workspace.EditCompleted(Error(fs.LandUnwritten(error))),
    ),
    #(
      workspace.ListEntries(path, listing),
      workspace.ListingCompleted(Error(search.Backend(error))),
    ),
    #(
      workspace.Search(path, query),
      workspace.SearchCompleted(Error(search.Backend(error))),
    ),
    #(
      workspace.Stat(path),
      workspace.StatCompleted(Error(search.Backend(error))),
    ),
    #(
      workspace.Git(workspace.Status),
      workspace.GitCompleted(Error(workspace.InvalidObservation)),
    ),
    #(workspace.Guidance, workspace.GuidanceCompleted(Error(error))),
    #(workspace.Initialize, workspace.InitializationCompleted(Error(error))),
  ]

  // Every same-operation pair matches, and every other pair is rejected.
  list.index_map(pairs, fn(pair, index) {
    let #(request, response) = pair
    assert workspace.response_matches(request, response)
    list.index_map(pairs, fn(other, other_index) {
      let #(_, other_response) = other
      assert workspace.response_matches(request, other_response)
        == { index == other_index }
    })
  })
}

pub fn read_projection_and_git_observation_mismatches_are_refused_test() {
  let path = core_workspace.root()
  let text = workspace.ReadCompleted(Ok(workspace.TextRead("a")))
  let anchored =
    workspace.ReadCompleted(
      Ok(workspace.AnchoredRead(
        hashline.digest("a"),
        hashline.window("a", offset: 1, limit: 1),
      )),
    )
  let image =
    workspace.ReadCompleted(Ok(workspace.ImageRead(<<0>>, workspace.Png)))
  let lines =
    workspace.ReadCompleted(Ok(workspace.LinesRead(search.Lines("a", 1, 1, 1))))
  assert workspace.response_matches(workspace.Read(path, workspace.Text), text)
  assert !workspace.response_matches(
    workspace.Read(path, workspace.Text),
    image,
  )
  assert workspace.response_matches(
    workspace.Read(path, workspace.Native(1, 1)),
    anchored,
  )
  assert workspace.response_matches(
    workspace.Read(path, workspace.Native(1, 1)),
    image,
  )
  assert !workspace.response_matches(
    workspace.Read(path, workspace.Native(1, 1)),
    text,
  )
  assert workspace.response_matches(
    workspace.Read(path, workspace.Lines(1, 1)),
    lines,
  )
  assert !workspace.response_matches(
    workspace.Read(path, workspace.Lines(1, 1)),
    anchored,
  )
  let file_error =
    workspace.ReadCompleted(Error(workspace.FileReadFailed(fs.NotText)))
  let line_error =
    workspace.ReadCompleted(
      Error(workspace.LinesReadFailed(search.Missing("a"))),
    )
  assert !workspace.response_matches(
    workspace.Read(path, workspace.Lines(1, 1)),
    file_error,
  )
  assert !workspace.response_matches(
    workspace.Read(path, workspace.Text),
    line_error,
  )
  assert workspace.response_matches(
    workspace.Read(path, workspace.Lines(1, 1)),
    line_error,
  )
  let git_pairs = [
    #(workspace.CurrentBranch, workspace.BranchObserved("main")),
    #(workspace.CurrentRevision, workspace.RevisionObserved(None)),
    #(workspace.Status, workspace.StatusObserved([])),
    #(workspace.Diff(workspace.Staged), workspace.DiffObserved("diff")),
    #(workspace.Log(10), workspace.LogObserved([])),
  ]
  list.index_map(git_pairs, fn(pair, index) {
    let #(query, result) = pair
    assert workspace.response_matches(
      workspace.Git(query),
      workspace.GitCompleted(Ok(result)),
    )
    list.index_map(git_pairs, fn(other, other_index) {
      let #(_, other_result) = other
      assert workspace.response_matches(
          workspace.Git(query),
          workspace.GitCompleted(Ok(other_result)),
        )
        == { index == other_index }
    })
  })
}

pub fn stale_edit_result_keeps_current_text_and_fresh_anchors_test() {
  let path = core_workspace.root()
  let plan = hashline.Plan(hashline.digest("before"), [])
  let fresh = hashline.annotate("after")
  let rejected =
    fs.LandRejected(
      hashline.StaleContent(hashline.digest("after"), fresh),
      "after",
    )
  let response = workspace.EditCompleted(Error(rejected))
  assert workspace.response_matches(
    workspace.AnchoredEdit(path, plan),
    response,
  )
  let assert workspace.EditCompleted(Error(fs.LandRejected(error, current))) =
    response
  assert current == "after"
  assert error == hashline.StaleContent(hashline.digest("after"), fresh)
}

pub fn git_revision_is_bounded_hex_and_cannot_carry_options_or_expressions_test() {
  list.each([string.repeat("a", 40), string.repeat("0A", 32)], fn(text) {
    let assert Ok(revision) = workspace.revision(text)
    assert workspace.revision_string(revision) == text
    assert workspace.response_matches(
      workspace.Git(workspace.Diff(workspace.SinceRevision(revision))),
      workspace.GitCompleted(Ok(workspace.DiffObserved("patch"))),
    )
  })
  list.each(
    [
      "HEAD",
      "HEAD~2",
      "--output=/secret",
      string.repeat("a", 39),
      string.repeat("a", 65),
      string.repeat("z", 40),
      string.repeat("a", 39) <> "\n",
    ],
    fn(text) {
      assert workspace.revision(text) == Error(workspace.InvalidRevision)
    },
  )
}
