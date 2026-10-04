//// Native filesystem tools over the semantic workspace boundary.
////
//// Argument decoding and virtual reads stay in tools/fs. Ordinary paths pass
//// the remote path grammar before one whole operation reaches the trusted
//// service. The original Ctx travels unchanged: this module neither resolves
//// its workspace as a physical directory nor invokes its FileSystem.
////
//// Owner assembly reserves and recovers the original durable workspace child.
//// Remote tools declare Never, including reads. A lost observation can follow
//// an effect; it needs original-child reconciliation rather than a fresh tool
//// invocation. Retained evidence supplies native anchors, images and diagnostics.

import core/json
import core/workspace as core_workspace
import tools/fs
import tools/hashline
import tools/tool
import tools/workspace
import tools/workspace_local

/// Trusted assembly preserving the original tool and durable child identity.
/// A possible submission without completion answers OutcomeUnknown, which
/// grants no authority to repeat the operation with a new identity.
pub type Service =
  fn(tool.Ctx, workspace.Request) ->
    Result(workspace_local.Completed, workspace.ServiceError)

/// Builds semantic fs_read retaining owner-provided virtual namespaces.
/// Ordinary paths never reach the owner's filesystem or path resolver.
///
/// ## Examples
///
/// ```gleam
/// assert workspace_tools.read_tool(fn(_, _) { Error(workspace.Unavailable) }, []).replay == tool.Never
/// ```
pub fn read_tool(service: Service, schemes: List(fs.Scheme)) -> tool.Tool {
  let reader =
    fs.read_tool_using(schemes, fn(ctx, path, offset, limit) {
      read(service, ctx, path, offset, limit)
    })
  tool.Tool(..reader, replay: tool.Never)
}

/// Builds one whole semantic fs_write with native decoding and rendering.
/// Successful receipts supply their own anchors and settled diagnostics.
///
/// ## Examples
///
/// ```gleam
/// assert workspace_tools.write_tool(fn(_, _) { Error(workspace.Unavailable) }).replay == tool.Never
/// ```
pub fn write_tool(service: Service) -> tool.Tool {
  let writer =
    fs.write_tool_using(fn(ctx, path, content) {
      write(service, ctx, path, content)
    })
  tool.Tool(..writer, replay: tool.Never)
}

/// Builds one semantic digest-bound edit preserving the original hunk plan.
/// Retained preimage and postimage supply diffs and fresh anchors without I/O.
///
/// ## Examples
///
/// ```gleam
/// assert workspace_tools.edit_tool(fn(_, _) { Error(workspace.Unavailable) }).replay == tool.Never
/// ```
pub fn edit_tool(service: Service) -> tool.Tool {
  let editor =
    fs.edit_tool_using(fn(ctx, path, plan) { edit(service, ctx, path, plan) })
  tool.Tool(..editor, replay: tool.Never)
}

fn read(
  service: Service,
  ctx: tool.Ctx,
  path: String,
  offset: Int,
  limit: Int,
) -> tool.ToolOutcome {
  use relative <- tool.or_outcome(
    core_workspace.relative_path(path),
    invalid_path,
  )
  use completed <- tool.or_outcome(
    service(ctx, workspace.Read(relative, workspace.Native(offset:, limit:))),
    service_error,
  )

  // Only native evidence for this operation may satisfy its retained request.
  case completed.response {
    workspace.ReadCompleted(Ok(workspace.AnchoredRead(digest:, window:))) ->
      fs.native_read_outcome(path, digest, window, limit)
    workspace.ReadCompleted(Ok(workspace.ImageRead(bytes:, media:))) ->
      fs.image_outcome(path, bytes, mime_type(media))
    workspace.ReadCompleted(Error(workspace.FileReadFailed(error:))) ->
      fs.read_error_outcome(error)
    workspace.ReadCompleted(Error(workspace.InvalidWindow)) ->
      tool.failure("invalid arguments: offset and limit must be >= 1")
    _ -> mismatched_response()
  }
}

fn write(
  service: Service,
  ctx: tool.Ctx,
  path: String,
  content: String,
) -> tool.ToolOutcome {
  use relative <- tool.or_outcome(
    core_workspace.relative_path(path),
    invalid_path,
  )
  use completed <- tool.or_outcome(
    service(ctx, workspace.Write(relative, content)),
    service_error,
  )

  // Only native evidence for this operation may satisfy its retained request.
  case completed.response {
    workspace.WriteCompleted(Ok(workspace.Written(bytes:, digest:, anchors:))) -> {
      let anchors = case anchors {
        workspace.Included(lines) -> Ok(lines)
        workspace.RequiresWindowedRead -> Error(Nil)
      }
      fs.write_result_outcome(
        path,
        bytes,
        digest,
        anchors,
        completed.diagnostics,
      )
    }
    workspace.WriteCompleted(Error(error)) -> fs.fs_error_outcome(error)
    _ -> mismatched_response()
  }
}

fn edit(
  service: Service,
  ctx: tool.Ctx,
  path: String,
  plan: hashline.Plan,
) -> tool.ToolOutcome {
  use relative <- tool.or_outcome(
    core_workspace.relative_path(path),
    invalid_path,
  )
  use completed <- tool.or_outcome(
    service(ctx, workspace.AnchoredEdit(relative, plan)),
    service_error,
  )

  // Only native evidence for this operation may satisfy its retained request.
  case completed.response {
    workspace.EditCompleted(Ok(landed)) ->
      fs.edit_outcome(
        path,
        landed.before,
        plan.hunks,
        landed.edited,
        completed.diagnostics,
      )
    workspace.EditCompleted(Error(error)) -> fs.land_error_outcome(error)
    _ -> mismatched_response()
  }
}

fn mime_type(media: workspace.ImageMedia) -> String {
  case media {
    workspace.Png -> "image/png"
    workspace.Jpeg -> "image/jpeg"
    workspace.Gif -> "image/gif"
    workspace.Webp -> "image/webp"
  }
}

fn invalid_path(_error: core_workspace.InputError) -> tool.ToolOutcome {
  refused(
    "invalid_workspace_path",
    "remote workspace paths must be canonical relative paths beneath the bound workspace",
  )
}

// A mismatched trusted completion is not proof of a refused effect. Its
// original child still needs reconciliation before the caller can proceed.
fn mismatched_response() -> tool.ToolOutcome {
  refused(
    "invalid_workspace_completion",
    "workspace completion does not match the requested operation; an effect may have happened. Recover the original durable workspace request before proceeding",
  )
}

fn service_error(error: workspace.ServiceError) -> tool.ToolOutcome {
  case error {
    workspace.PathRefused(error) -> fs.path_outcome(error)
    workspace.OutcomeUnknown ->
      refused(
        "workspace_outcome_unknown",
        "workspace outcome is unknown; an effect may have happened. Recover the original durable workspace request under its original identity; do not submit a fresh invocation",
      )
    workspace.Unavailable ->
      refused("workspace_unavailable", "workspace service is unavailable")
    workspace.StaleScope ->
      refused("workspace_stale_scope", "workspace binding is stale")
    workspace.PermissionRefused ->
      refused(
        "workspace_permission_refused",
        "workspace authority refused the operation",
      )
    workspace.InvalidRequest ->
      refused(
        "workspace_invalid_request",
        "workspace service refused invalid arguments",
      )
    workspace.CapacityRefused ->
      refused(
        "workspace_capacity_refused",
        "workspace service refused capacity",
      )
    workspace.IdentityConflict ->
      refused(
        "workspace_identity_conflict",
        "workspace request identity conflicts with retained content; recover the original request",
      )
  }
}

fn refused(code: String, text: String) -> tool.ToolOutcome {
  tool.failure(text)
  |> tool.with_details(json.Object([#("error", json.String(code))]))
}
