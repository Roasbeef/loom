//// Executor-resident semantic workspace operations for protocol 067.
////
//// A Host binds an administratively supplied scope to an executor-local Ctx.
//// `run` compares the complete scope, including both epochs, before any path
//// resolution, filesystem access, observer or callback. Every file request
//// then uses the existing fs/search/hashline boundary beside that checkout.
//// An edit resolves, reads, verifies and lands within one synchronous call.
//// This is not a remote implementation of tool.FileSystem.
////
//// Git, guidance and initialization have narrow typed bindings because their
//// existing hosts live above this package. An absent binding is Unavailable.
//// A Git binding must clear its exact command through the owner's broker;
//// this module starts no process and grants no independent native authority.
//// The invocation remains intact across that callback, including its origin.
////
//// This host is below durable admission. Before calling it, the service MUST
//// retain the exact immutable request and reserve bounded result capacity.
//// It MUST retain the exact Completed bytes, including diagnostics, before
//// acknowledgment. Lost replies require reconciliation under that identity.
//// There is no request ledger here and no exactly-once mutation guarantee.
//// Resolution and edit landing retain fs's documented point-in-time races
//// against independent shell/editor writers; neither is an atomic snapshot.

import core/workspace as core_workspace
import gleam/bit_array
import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tools/fs
import tools/hashline
import tools/search
import tools/tool
import tools/workspace

/// A local registration whose scope cannot be changed by a request.
pub opaque type Host {
  /// Construction performs no I/O; exact scope comparison precedes effects.
  Host(
    /// Administrative session, executor, workspace and authority epochs.
    scope: core_workspace.Scope,
    /// Existing executor-local authority and local filesystem implementation.
    local: tool.Ctx,
    /// Existing post-write diagnostics hook, called only after landing.
    observer: fs.WriteObserver,
    /// Optional existing cleared Git host, never arbitrary argv or JSON.
    git: Option(GitHost),
    /// Optional existing client-specific guidance precedence implementation.
    guidance: Option(GuidanceHost),
    /// Optional existing administrative initialization implementation.
    initialize: Option(InitializationHost),
  )
}

/// A closed Git host retaining the exact invocation for owner clearance.
/// The supplied Ctx has the invocation's operation and step; system provenance
/// comes from Invocation, never from Ctx.source_index.
pub type GitHost =
  fn(tool.Ctx, workspace.Invocation, workspace.GitQuery) ->
    Result(workspace.GitResult, workspace.GitError)

/// Existing executor-local guidance assembly, with explicit partial coverage.
pub type GuidanceHost =
  fn(tool.Ctx, workspace.Invocation) ->
    Result(workspace.GuidanceResult, tool.FsError)

/// Existing administrative setup, below the caller's durable mutation fence.
pub type InitializationHost =
  fn(tool.Ctx, workspace.Invocation) ->
    Result(workspace.Initialization, tool.FsError)

/// A response together with the existing observer's settled diagnostic block.
/// Diagnostics are separate because workspace.Response is a closed contract.
pub type Completed {
  /// Both fields belong to the retained final result before acknowledgment.
  Completed(
    /// Exact semantic result, including operation-specific typed errors.
    response: workspace.Response,
    /// None means no observer block, never a dropped or failed observation.
    diagnostics: Option(String),
  )
}

/// Remote replacement payload ceiling; whole-file reads use the same bound.
/// Result reservation must also cover an edit's preimage and postimage.
pub const max_request_bytes = fs.max_read_bytes

/// Bounds the pairwise overlap work in the existing hashline planner.
/// This is a service admission bound; native tool plans remain unchanged.
pub const max_edit_hunks = 256

/// Maximum recent commits admitted to the existing cleared Git host.
/// Its command-output byte budget still applies independently of this count.
pub const max_git_log_entries = 1000

/// Binds local authority to one exact administrative registration.
/// The filesystem and observer must run beside the registered checkout. No
/// registration, epoch or physical root is inferred from peer-supplied paths.
///
/// ## Examples
///
/// ```gleam
/// // let host = workspace_local.new(scope, local_ctx, after_write)
/// // An unbound workspace.Git request returns Error(workspace.Unavailable).
/// ```
pub fn new(
  scope: core_workspace.Scope,
  local: tool.Ctx,
  observer: fs.WriteObserver,
) -> Host {
  Host(scope:, local:, observer:, git: None, guidance: None, initialize: None)
}

/// Reads the immutable administrative scope without exposing local authority.
///
/// ## Examples
///
/// `scope(host)` must equal the durable journal scope before a service starts.
pub fn scope(host: Host) -> core_workspace.Scope {
  host.scope
}

/// Binds the existing Git host which owns exact-command owner clearance.
/// Successful results and stderr must be bounded by that host before return.
///
/// ## Examples
///
/// ```gleam
/// // host |> workspace_local.with_git(cleared_git_host)
/// ```
pub fn with_git(host: Host, git: GitHost) -> Host {
  Host(..host, git: Some(git))
}

/// Binds existing executor-local guidance selection and byte budgets.
///
/// ## Examples
///
/// ```gleam
/// // host |> workspace_local.with_guidance(workspace_guidance)
/// ```
pub fn with_guidance(host: Host, guidance: GuidanceHost) -> Host {
  Host(..host, guidance: Some(guidance))
}

/// Binds existing administrative initialization under durable admission.
///
/// ## Examples
///
/// ```gleam
/// // host |> workspace_local.with_initialization(initialize_workspace)
/// ```
pub fn with_initialization(host: Host, initialize: InitializationHost) -> Host {
  Host(..host, initialize: Some(initialize))
}

/// Executes one whole semantic invocation beside the bound checkout.
/// Scope mismatch has zero effect, including no path probes or callbacks.
/// Mutations require the caller's durable request/result ordering described
/// in the module documentation; returning Completed supplies no receipt.
///
/// ## Examples
///
/// ```gleam
/// // workspace_local.run(host, stale_invocation)
/// // -> Error(workspace.StaleScope), before any filesystem access.
/// ```
pub fn run(
  host: Host,
  invocation: workspace.Invocation,
) -> Result(Completed, workspace.ServiceError) {
  let #(scope, operation, step, origin, _) =
    workspace.invocation_identity(invocation)
  use <- bool.guard(scope != host.scope, Error(workspace.StaleScope))

  // Ctx is administrative authority; provenance stays with the invocation.
  // Only a model tool has a source index to project into the native context.
  let index = case origin {
    workspace.Tool(origin) -> workspace.tool_origin_fields(origin).0
    workspace.System(_) -> host.local.source_index
  }
  let local =
    tool.Ctx(
      ..host.local,
      op_id: operation,
      step_id: core_workspace.step_string(step),
      source_index: index,
    )
  let request = workspace.request(invocation)
  use completed <- result.try(execute(Host(..host, local:), invocation, request))

  // Typed callbacks still return Git's several observation shapes. A host
  // returning the wrong projection cannot become retained success evidence.
  use <- bool.guard(
    !workspace.response_matches(request, completed.response),
    Error(workspace.InvalidRequest),
  )
  Ok(completed)
}

fn execute(
  host: Host,
  invocation: workspace.Invocation,
  request: workspace.Request,
) -> Result(Completed, workspace.ServiceError) {
  case request {
    workspace.Read(path, view) -> read(host.local, path, view)
    workspace.Write(path, content) -> write(host, path, content)
    workspace.AnchoredEdit(path, plan) -> edit(host, path, plan)
    workspace.ListEntries(root, query) -> {
      use #(workspace_root, resolved) <- result.try(search_root(
        host.local,
        root,
      ))
      Ok(
        completed(
          workspace.ListingCompleted(search.glob(
            workspace_root,
            resolved,
            query,
          )),
        ),
      )
    }
    workspace.Search(root, query) -> {
      use #(workspace_root, resolved) <- result.try(search_root(
        host.local,
        root,
      ))
      Ok(
        completed(
          workspace.SearchCompleted(search.grep(workspace_root, resolved, query)),
        ),
      )
    }
    workspace.Stat(path) -> {
      use resolved <- result.try(
        fs.resolve_relative_leaf(
          host.local.filesystem,
          host.local.workspace,
          path,
        )
        |> result.map_error(workspace.PathRefused),
      )
      Ok(
        completed(
          workspace.StatCompleted(search.stat(
            resolved,
            core_workspace.path_string(path),
          )),
        ),
      )
    }
    workspace.Git(query) -> {
      let valid = case query {
        workspace.Log(limit) -> limit >= 1 && limit <= max_git_log_entries
        workspace.CurrentBranch
        | workspace.CurrentRevision
        | workspace.Status
        | workspace.Diff(_) -> True
      }
      use <- bool.guard(!valid, Error(workspace.InvalidRequest))
      use callback <- result.try(option.to_result(
        host.git,
        workspace.Unavailable,
      ))
      Ok(
        completed(
          workspace.GitCompleted(callback(host.local, invocation, query)),
        ),
      )
    }
    workspace.Guidance -> {
      use callback <- result.try(option.to_result(
        host.guidance,
        workspace.Unavailable,
      ))
      Ok(
        completed(workspace.GuidanceCompleted(callback(host.local, invocation))),
      )
    }
    workspace.Initialize -> {
      use callback <- result.try(option.to_result(
        host.initialize,
        workspace.Unavailable,
      ))
      Ok(
        completed(
          workspace.InitializationCompleted(callback(host.local, invocation)),
        ),
      )
    }
  }
}

fn read(
  local: tool.Ctx,
  path: core_workspace.RelativePath,
  view: workspace.ReadView,
) -> Result(Completed, workspace.ServiceError) {
  // Invalid native windows are refused before even resolving the pathname.
  use <- bool.lazy_guard(invalid_window(view), fn() {
    Ok(completed(workspace.ReadCompleted(Error(workspace.InvalidWindow))))
  })
  use resolved <- result.try(resolve_read(local, path))
  case view {
    workspace.Text ->
      Ok(
        completed(workspace.ReadCompleted(
          fs.read_text_file(local.filesystem, resolved)
          |> result.map(workspace.TextRead)
          |> result.map_error(workspace.FileReadFailed),
        )),
      )
    workspace.Lines(first, last) ->
      Ok(
        completed(workspace.ReadCompleted(
          search.read_lines(resolved, first, last)
          |> result.map(workspace.LinesRead)
          |> result.map_error(workspace.LinesReadFailed),
        )),
      )
    workspace.Native(offset, limit) ->
      native_read(local, resolved, offset, limit)
  }
}

fn invalid_window(view: workspace.ReadView) -> Bool {
  case view {
    workspace.Native(offset, limit) -> offset < 1 || limit < 1
    workspace.Text | workspace.Lines(_, _) -> False
  }
}

fn native_read(
  local: tool.Ctx,
  resolved: String,
  offset: Int,
  limit: Int,
) -> Result(Completed, workspace.ServiceError) {
  // File errors remain in-band read failures. Inline projection exhaustion
  // is a service capacity refusal, never a success with omitted anchors.
  use bytes <- or_read_failure(fs.read_bytes(local.filesystem, resolved))
  case fs.image_media_type(bytes) {
    Some(media) -> {
      use media <- result.try(image_media(media))
      Ok(
        completed(
          workspace.ReadCompleted(Ok(workspace.ImageRead(bytes, media))),
        ),
      )
    }
    None -> {
      use content <- or_read_failure(
        bit_array.to_string(bytes) |> result.replace_error(fs.NotText),
      )
      use projection <- result.try(
        fs.read_window(content, offset, limit)
        |> result.replace_error(workspace.CapacityRefused),
      )
      Ok(
        completed(
          workspace.ReadCompleted(
            Ok(workspace.AnchoredRead(projection.digest, projection.window)),
          ),
        ),
      )
    }
  }
}

fn or_read_failure(
  value: Result(a, fs.ReadError),
  then: fn(a) -> Result(Completed, workspace.ServiceError),
) -> Result(Completed, workspace.ServiceError) {
  case value {
    Ok(value) -> then(value)
    Error(error) ->
      Ok(
        completed(
          workspace.ReadCompleted(Error(workspace.FileReadFailed(error))),
        ),
      )
  }
}

fn image_media(
  media: String,
) -> Result(workspace.ImageMedia, workspace.ServiceError) {
  case media {
    "image/png" -> Ok(workspace.Png)
    "image/jpeg" -> Ok(workspace.Jpeg)
    "image/gif" -> Ok(workspace.Gif)
    "image/webp" -> Ok(workspace.Webp)
    _ -> Error(workspace.InvalidRequest)
  }
}

fn write(
  host: Host,
  path: core_workspace.RelativePath,
  content: String,
) -> Result(Completed, workspace.ServiceError) {
  use <- bool.guard(
    string.byte_size(content) > max_request_bytes,
    Error(workspace.CapacityRefused),
  )
  use target <- result.try(write_target(host.local, path))
  let resolved = fs.target_path(target)
  let bytes = <<content:utf8>>
  let landed = fs.write_whole(host.local.filesystem, resolved, bytes)

  // The existing hook observes landed bytes before the final result is built.
  // A backend refusal never notifies a language server of nonexistent text.
  Ok(
    observe(landed, host.observer, resolved, fn(value) {
      workspace.WriteCompleted(
        result.map(value, fn(_nil) {
          workspace.Written(
            bit_array.byte_size(bytes),
            hashline.digest(content),
            fresh_anchors(content),
          )
        }),
      )
    }),
  )
}

fn fresh_anchors(content: String) -> workspace.FreshAnchors {
  case fs.written_lines(content) {
    Ok(lines) -> workspace.Included(lines)
    Error(Nil) -> workspace.RequiresWindowedRead
  }
}

fn edit(
  host: Host,
  path: core_workspace.RelativePath,
  plan: hashline.Plan,
) -> Result(Completed, workspace.ServiceError) {
  use <- bool.guard(
    list.drop(plan.hunks, max_edit_hunks) != []
      || edit_bytes(plan) > max_request_bytes,
    Error(workspace.CapacityRefused),
  )
  use target <- result.try(write_target(host.local, path))
  let landed = fs.land_plan(host.local.filesystem, target, plan)

  // No split read/verify/write crosses the host boundary. A stale digest or
  // anchor returns fs's original typed refusal without a write or observer.
  Ok(observe(
    landed,
    host.observer,
    fs.target_path(target),
    workspace.EditCompleted,
  ))
}

fn edit_bytes(plan: hashline.Plan) -> Int {
  string.byte_size(plan.digest)
  + list.fold(plan.hunks, 0, fn(size, hunk) {
    let #(references, lines) = case hunk {
      hashline.Replace(from, to, lines) -> #([from, to], lines)
      hashline.Delete(from, to) -> #([from, to], [])
      hashline.InsertAfter(at, lines) -> #([at], lines)
      hashline.InsertAtStart(lines) -> #([], lines)
    }
    let refs =
      list.fold(references, 0, fn(bytes, ref) {
        bytes + string.byte_size(ref.anchor) + 1
      })
    size
    + refs
    + list.fold(lines, 0, fn(bytes, line) { bytes + string.byte_size(line) + 1 })
  })
}

fn observe(
  landed: Result(a, e),
  observer: fs.WriteObserver,
  resolved: String,
  response: fn(Result(a, e)) -> workspace.Response,
) -> Completed {
  case landed {
    Error(error) -> completed(response(Error(error)))
    Ok(value) -> {
      let diagnostics = observer(resolved)
      Completed(response(Ok(value)), diagnostics)
    }
  }
}

fn resolve_read(
  local: tool.Ctx,
  path: core_workspace.RelativePath,
) -> Result(String, workspace.ServiceError) {
  fs.resolve_real(
    local.filesystem,
    local.workspace,
    core_workspace.path_string(path),
  )
  |> result.map_error(workspace.PathRefused)
}

fn write_target(
  local: tool.Ctx,
  path: core_workspace.RelativePath,
) -> Result(fs.WriteTarget, workspace.ServiceError) {
  // This remote contract names only the bound workspace. Explicit sibling
  // roots in a local Ctx cannot turn a workspace symlink into remote authority.
  fs.write_target(
    local.filesystem,
    local.workspace,
    [],
    local.base_policy.protected,
    core_workspace.path_string(path),
  )
  |> result.map_error(workspace.PathRefused)
}

fn search_root(
  local: tool.Ctx,
  root: core_workspace.RelativePath,
) -> Result(#(String, String), workspace.ServiceError) {
  use workspace_root <- result.try(
    fs.resolve_real(local.filesystem, local.workspace, ".")
    |> result.map_error(workspace.PathRefused),
  )
  use resolved <- result.try(resolve_read(local, root))
  Ok(#(workspace_root, resolved))
}

fn completed(response: workspace.Response) -> Completed {
  Completed(response, None)
}
