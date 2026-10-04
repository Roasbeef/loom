//// Closed semantic workspace requests for protocol 067.
////
//// The service executes a whole read, write or anchored edit beside the
//// registered checkout. It resolves and checks the path there, then reuses
//// tools/fs and tools/search. No FileSystem callbacks, arbitrary tool names,
//// JSON argument bags or physical host paths cross this contract.
////
//// Invocation keeps the exact scope, operation, step, originating tool and
//// reserved request UUID together. The owner persists that link before send;
//// constructing it here neither journals nor authorizes it. Retries retain
//// the request UUID and exact immutable request. Transport consumers must
//// compare its canonical digest, reserve evidence capacity before mutation,
//// and expose uncertain outcomes rather than retrying with a fresh UUID.
////
//// Existing core EntryId supplies a validated UUIDv7 for a request reservation;
//// this use creates no conversation row. An executor adapter explicitly calls
//// identity.request_id(ids.entry_id_to_string(request_id)); tools cannot import
//// executor without a package cycle. Scope conversion is core/workspace's
//// validated field bridge. ToolKey and child-link persistence stay in wiring.
////
//// Search and edit results reuse the existing typed contracts, including
//// partial search coverage and stale-content errors. Git's cap types live on
//// a different package seam, so only its observation vocabulary is repeated
//// here. Git mutation continues through cleared process calls. This module
//// defines no wire codec, service host, local adapter or remote consumer.

import broker/broker
import broker/exec
import core/ids
import core/workspace as core_workspace
import gleam/option.{type Option}
import gleam/result
import gleam/string
import tools/fs
import tools/hashline
import tools/search
import tools/tool

/// A tool source index paired with the digest of its persisted arguments.
pub opaque type ToolOrigin {
  /// The constructor checks a nonnegative signed-32-bit index and 32 bytes.
  ToolOrigin(
    /// The original source index, never manufactured by the broker.
    source_index: Int,
    /// The adapter's canonical persisted-argument digest, not an anchor hash.
    arguments_digest: BitArray,
  )
}

/// Named broker callers which have no model tool source index.
pub type SystemCaller {
  /// Preparation of the exact command materialization.
  CommandPreparation

  /// Physical source preparation and compilation.
  Compiler

  /// Launch of the jailed satellite and its private resources.
  SatelliteLaunch

  /// A session-owned language-server lease or query.
  LanguageServer

  /// Session/UI Git baseline and workspace-diff observation.
  WorktreeObservation

  /// Administrative workspace setup before ordinary tools start.
  WorkspaceAdministration
}

/// The origin is explicit even when no ToolKey exists.
pub type Origin {
  /// A persisted model tool call, with its original index and arguments.
  Tool(
    /// Validated tool coordinates within the operation and step.
    origin: ToolOrigin,
  )

  /// A named internal caller, with no invented source index.
  System(
    /// The concrete internal service which owns the call.
    caller: SystemCaller,
  )
}

/// Invalid origin coordinates, without retaining rejected input.
pub type OriginError {
  /// The source index was outside 0..2147483647.
  SourceIndexRange

  /// The argument digest was not exactly 32 bytes.
  ArgumentsDigestSize
}

/// An immutable logical request and its durable owner coordinates.
pub opaque type Invocation {
  /// All fields must be persisted as one child link before first send.
  Invocation(
    /// Exact session, registration and both authority epochs.
    scope: core_workspace.Scope,
    /// Core's existing durable operation identity.
    operation: ids.OpId,
    /// An externally bounded spelling of the actual internal step.
    step: core_workspace.Step,
    /// Tool coordinates or an explicitly named system origin.
    origin: Origin,
    /// Caller-reserved UUIDv7, reused across retries and reconnects.
    request_id: ids.EntryId,
    /// The semantic operation; a changed value under this ID conflicts.
    request: Request,
  )
}

/// How a read is projected; virtual owner schemes are outside this service.
pub type ReadView {
  /// Text for code-mode fs.read, retaining the existing UTF-8 requirement.
  Text

  /// Anchored native-tool text, or a supported image identified by its bytes.
  Native(
    /// One-based first line; the service refuses values below one.
    offset: Int,
    /// Positive line count; existing rendered byte caps still apply.
    limit: Int,
  )

  /// The existing structured search.read_lines projection.
  Lines(
    /// One-based first line, checked by the existing implementation.
    first: Int,
    /// Inclusive last line; search.max_line_span remains the ceiling.
    last: Int,
  )
}

/// Git observations are a closed set; arbitrary argv is not an operation.
pub type GitQuery {
  /// Observe the current branch without changing the index or checkout.
  CurrentBranch

  /// Observe the full current commit ID, or an explicitly unborn HEAD.
  CurrentRevision

  /// Observe porcelain status.
  Status

  /// Observe a unified diff for the selected comparison.
  Diff(
    /// Working tree versus index, or index versus HEAD.
    comparison: DiffComparison,
  )

  /// Observe recent commits, newest first.
  Log(
    /// Positive maximum count, bounded by the service's admitted result budget.
    limit: Int,
  )
}

/// The two diff comparisons exposed by the existing Git capability.
pub type DiffComparison {
  /// Working tree changes relative to the index.
  WorkingTree

  /// Staged changes relative to HEAD.
  Staged

  /// Changes since the durable starting revision captured by the session.
  SinceRevision(
    /// A validated full object ID, with no Git option or revision expression.
    revision: Revision,
  )
}

/// A full SHA-1 or SHA-256 Git object ID, with no arbitrary revision syntax.
pub opaque type Revision {
  /// Forty or sixty-four hexadecimal bytes, preserved without normalization.
  Revision(
    /// The exact hexadecimal object identifier.
    value: String,
  )
}

/// A malformed Git object ID; rejected text is never retained.
pub type RevisionError {
  /// The input was not exactly 40 or 64 hexadecimal bytes.
  InvalidRevision
}

/// Every workspace service action. Paths already passed the remote grammar;
/// payload/query bounds, permissions and physical containment are checked by
/// the service before use. Existing local APIs keep their separate path rules.
pub type Request {
  /// Read one file, with the existing text, image or line-window semantics.
  Read(
    /// Canonical path beneath the bound workspace.
    path: core_workspace.RelativePath,
    /// The projection requested by the original consumer.
    view: ReadView,
  )

  /// Create parents and create or replace one complete UTF-8 file.
  Write(
    /// Canonical target path, revalidated for write authority at use.
    path: core_workspace.RelativePath,
    /// Exact replacement text, subject to admitted payload bounds.
    content: String,
  )

  /// Resolve, read, check the digest/anchors and land in one service call.
  AnchoredEdit(
    /// Canonical target path, resolved beside the registered checkout.
    path: core_workspace.RelativePath,
    /// Existing edit plan, including whole-file preimage digest.
    plan: hashline.Plan,
  )

  /// List entries through the existing bounded glob walker.
  ListEntries(
    /// Contained root of the walk; '.' explicitly selects the workspace.
    root: core_workspace.RelativePath,
    /// Existing pattern, entry cap, hidden policy and prune names.
    query: search.GlobQuery,
  )

  /// Search file content with structured coverage and skipped-file counts.
  Search(
    /// Contained root of the scan.
    root: core_workspace.RelativePath,
    /// Existing regex, globs, context, match cap and traversal policy.
    query: search.GrepQuery,
  )

  /// Observe file metadata with the existing lstat semantics.
  Stat(
    /// Canonical path to inspect.
    path: core_workspace.RelativePath,
  )

  /// Observe repository metadata through a cleared executor-local command.
  Git(
    /// Closed observation, never an arbitrary Git subcommand.
    query: GitQuery,
  )

  /// Load workspace guidance beside the checkout using existing precedence.
  Guidance

  /// Perform existing workspace setup, never clone an arbitrary supplied URL.
  Initialize
}

/// Supported native-tool image types, detected from content rather than names.
pub type ImageMedia {
  /// PNG signature.
  Png

  /// JPEG signature.
  Jpeg

  /// GIF87a or GIF89a signature.
  Gif

  /// RIFF/WEBP signature.
  Webp
}

/// The read projection, without a generic JSON or tool-result escape.
pub type ReadResult {
  /// UTF-8 text under the existing fs.max_read_bytes limit.
  TextRead(
    /// File contents verbatim.
    content: String,
  )

  /// Native fs_read's preimage digest and fresh line anchors.
  AnchoredRead(
    /// Existing hashline digest, distinct from the request's journal digest.
    digest: String,
    /// Existing window metadata, including end-of-file and newline status.
    window: hashline.Window,
  )

  /// A signature-detected image, under the same existing file byte bound.
  ImageRead(
    /// Exact image bytes, without a physical resource pathname.
    bytes: BitArray,
    /// The supported format found in those bytes.
    media: ImageMedia,
  )

  /// Existing search.read_lines result.
  LinesRead(
    /// Selected lines and whole-file line count.
    lines: search.Lines,
  )
}

/// Read failures preserve the distinct existing file and line-reader contracts.
pub type ReadFailure {
  /// The existing bounded text/image file read failed.
  FileReadFailed(
    /// Existing not-text, oversize or filesystem refusal.
    error: fs.ReadError,
  )

  /// The existing structured line reader rejected the query or file.
  LinesReadFailed(
    /// Existing span, type, missing-file or backend refusal.
    error: search.SearchError,
  )

  /// Native offset or limit was below one.
  InvalidWindow
}

/// Write observation keeps the digest and the existing bounded fresh anchors.
pub type WriteResult {
  /// The bytes landed before observers or diagnostics may run.
  Written(
    /// Exact UTF-8 byte count written.
    bytes: Int,
    /// Fresh hashline digest of the resulting text.
    digest: String,
    /// Explicitly complete or omitted anchor projection.
    anchors: FreshAnchors,
  )
}

/// Fresh anchors retain the existing inline rendering limit without truncation.
pub type FreshAnchors {
  /// Every line of the written content fits the existing fresh-anchor cap.
  Included(
    /// Complete anchors, in file order.
    lines: List(hashline.AnchoredLine),
  )

  /// The written file requires a subsequent windowed read to obtain anchors.
  RequiresWindowedRead
}

/// A Git result preserves the observation's shape rather than arbitrary JSON.
pub type GitResult {
  /// The current branch label reported by Git.
  BranchObserved(
    /// Verbatim branch name, subject to the service's result byte cap.
    branch: String,
  )

  /// HEAD is an exact commit identity, or absent for a repository with no commits.
  RevisionObserved(
    /// None means unborn HEAD, never a failed observation.
    revision: Option(Revision),
  )

  /// Status entries with the existing two-character porcelain codes.
  StatusObserved(
    /// Entries in Git's reported order.
    entries: List(GitStatusEntry),
  )

  /// Unified diff text.
  DiffObserved(
    /// Exact bounded command output.
    diff: String,
  )

  /// Recent commits, newest first.
  LogObserved(
    /// Parsed commit summaries.
    commits: List(GitCommit),
  )
}

/// One porcelain status entry. Observed paths are data, never path authority.
pub type GitStatusEntry {
  /// Mirrors the existing cap/git record without adding a package edge.
  GitStatusEntry(
    /// Git's two-character status code.
    code: String,
    /// Observed pathname; validate separately before using it in a request.
    path: String,
  )
}

/// One recent commit summary, matching the existing Git observation.
pub type GitCommit {
  /// No mutable repository state or process handle escapes.
  GitCommit(
    /// Git's commit object identifier.
    sha: String,
    /// The commit subject, subject to the service result budget.
    subject: String,
  )
}

/// Git failures preserve clearance, execution and parse boundaries.
pub type GitError {
  /// The owner refused the exact prepared command before execution.
  CommandRefused(
    /// Existing broker denial, without a second approval authority.
    refusal: broker.Refusal,
  )

  /// Execution failed after clearance, with its existing custody meaning.
  ExecutionFailed(
    /// Existing execution loss, timeout or enforcement failure.
    failure: exec.ExecFailure,
  )

  /// Git exited nonzero; the service bounds retained stderr.
  CommandFailed(
    /// Exact process exit code.
    exit_code: Int,
    /// Bounded diagnostic text from Git.
    stderr: String,
  )

  /// A successful command did not produce the expected bounded observation.
  InvalidObservation
}

/// One guidance source selected by the existing workspace precedence rules.
pub type GuidanceFile {
  /// Guidance remains quoted input, without granting authority.
  GuidanceFile(
    /// Validated workspace-relative location of the source.
    path: core_workspace.RelativePath,
    /// Exact bounded source text.
    content: String,
  )
}

/// The selected workspace guidance, in assembly order.
pub type GuidanceResult {
  /// Consumers cannot mistake a partial read for absence of guidance.
  GuidanceLoaded(
    /// Selected sources, ordered by existing precedence.
    files: List(GuidanceFile),
    /// Explicit complete or truncated observation.
    completeness: search.Completeness,
  )
}

/// Workspace setup reports whether existing layout already satisfied it.
pub type Initialization {
  /// Setup landed under the request's durable identity.
  Initialized

  /// Existing setup required no mutation.
  AlreadyInitialized
}

/// Failures at the service boundary, distinct from per-operation fs results.
pub type ServiceError {
  /// The configured registration is currently unavailable.
  Unavailable

  /// The exact scope or either authority epoch no longer matches.
  StaleScope

  /// The binding or operation lacks the required authority.
  PermissionRefused

  /// Physical path resolution rejected the target before use.
  PathRefused(
    /// Existing symlink, containment or protected-path refusal.
    error: fs.PathError,
  )

  /// Semantic arguments failed existing bounds or validation before use.
  InvalidRequest

  /// Evidence, request or result capacity was refused before new work.
  CapacityRefused

  /// The same request UUID was supplied with different immutable content.
  IdentityConflict

  /// A possible submission has no confirmed result; never retry as new work.
  OutcomeUnknown
}

/// Per-operation responses remain closed and retain existing typed errors.
/// A consumer checks that the variant matches the persisted request before
/// accepting it; a future wire decoder must reject mismatches, never coerce.
pub type Response {
  /// Text/image/window success or the existing read refusal.
  ReadCompleted(
    /// Existing reader errors retain not-text, oversize and span meanings.
    result: Result(ReadResult, ReadFailure),
  )

  /// Whole-file write result or existing backend refusal.
  WriteCompleted(
    /// Result is advertised only after the write and evidence commit.
    result: Result(WriteResult, tool.FsError),
  )

  /// Existing landing result and errors, including fresh stale-content evidence.
  EditCompleted(
    /// Same fs.land_plan contract used by native edit and LSP rename.
    result: Result(fs.Landed, fs.LandError),
  )

  /// Bounded entries with explicit completeness.
  ListingCompleted(
    /// Existing listing/error shapes.
    result: Result(search.Listing, search.SearchError),
  )

  /// Structured matches with explicit coverage and skipped-file count.
  SearchCompleted(
    /// Existing found/error shapes.
    result: Result(search.Found, search.SearchError),
  )

  /// Existing file metadata and errors.
  StatCompleted(
    /// Metadata is observation, never a permission grant.
    result: Result(search.Entry, search.SearchError),
  )

  /// Typed Git observation or failure of the cleared command.
  GitCompleted(
    /// No arbitrary command result is admitted.
    result: Result(GitResult, GitError),
  )

  /// Workspace guidance, with no owner-local fallback.
  GuidanceCompleted(
    /// Failed reads retain existing backend semantics.
    result: Result(GuidanceResult, tool.FsError),
  )

  /// Setup status after durable mutation evidence.
  InitializationCompleted(
    /// Backend setup errors are ordinary failures.
    result: Result(Initialization, tool.FsError),
  )
}

/// Validates tool provenance without claiming the digest was computed here.
///
/// ## Examples
///
/// ```gleam
/// assert workspace.tool_origin(-1, <<0:size(256)>>) == Error(workspace.SourceIndexRange)
/// assert workspace.tool_origin(0, <<>>) == Error(workspace.ArgumentsDigestSize)
/// ```
pub fn tool_origin(
  source_index: Int,
  arguments_digest: BitArray,
) -> Result(ToolOrigin, OriginError) {
  use Nil <- result.try(
    case source_index >= 0 && source_index <= 2_147_483_647 {
      True -> Ok(Nil)
      False -> Error(SourceIndexRange)
    },
  )
  use Nil <- result.try(case arguments_digest {
    <<_:size(256)>> -> Ok(Nil)
    _ -> Error(ArgumentsDigestSize)
  })
  Ok(ToolOrigin(source_index:, arguments_digest:))
}

/// Projects the existing source index and canonical persisted argument digest.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(origin) = workspace.tool_origin(2, <<0:size(256)>>)
/// assert workspace.tool_origin_fields(origin) == #(2, <<0:size(256)>>)
/// ```
pub fn tool_origin_fields(origin: ToolOrigin) -> #(Int, BitArray) {
  #(origin.source_index, origin.arguments_digest)
}

/// Constructs the immutable semantic child request after identity reservation.
/// The owner must persist all fields before making it sendable. Each child of
/// a tool gets a different reserved request UUID even when op/step are equal.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(scope) = core_workspace.scope_from_fields(
///   "00000000-0000-7000-8000-000000000001", "loom", "linux", 1, 1,
/// )
/// let assert Ok(op) = ids.parse_op_id("00000000-0000-7000-8000-000000000002")
/// let assert Ok(step) = core_workspace.step("turn:1")
/// let assert Ok(request_id) = ids.parse_entry_id("00000000-0000-7000-8000-000000000003")
/// let invocation = workspace.invocation(scope, op, step,
///   workspace.System(workspace.WorkspaceAdministration), request_id, workspace.Initialize)
/// assert workspace.request(invocation) == workspace.Initialize
/// ```
pub fn invocation(
  scope: core_workspace.Scope,
  operation: ids.OpId,
  step: core_workspace.Step,
  origin: Origin,
  request_id: ids.EntryId,
  request: Request,
) -> Invocation {
  Invocation(scope:, operation:, step:, origin:, request_id:, request:)
}

/// Projects the full persisted linkage in a fixed order for the owner adapter.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(scope) = core_workspace.scope_from_fields(
///   "00000000-0000-7000-8000-000000000001", "loom", "linux", 1, 1,
/// )
/// let assert Ok(op) = ids.parse_op_id("00000000-0000-7000-8000-000000000002")
/// let assert Ok(step) = core_workspace.step("turn:1")
/// let assert Ok(request_id) = ids.parse_entry_id("00000000-0000-7000-8000-000000000003")
/// let origin = workspace.System(workspace.WorkspaceAdministration)
/// let invocation = workspace.invocation(scope, op, step, origin, request_id, workspace.Initialize)
/// assert workspace.invocation_identity(invocation) == #(scope, op, step, origin, request_id)
/// ```
pub fn invocation_identity(
  invocation: Invocation,
) -> #(core_workspace.Scope, ids.OpId, core_workspace.Step, Origin, ids.EntryId) {
  #(
    invocation.scope,
    invocation.operation,
    invocation.step,
    invocation.origin,
    invocation.request_id,
  )
}

/// Projects the semantic request without returning an arbitrary argument bag.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(scope) = core_workspace.scope_from_fields(
///   "00000000-0000-7000-8000-000000000001", "loom", "linux", 1, 1,
/// )
/// let assert Ok(op) = ids.parse_op_id("00000000-0000-7000-8000-000000000002")
/// let assert Ok(step) = core_workspace.step("turn:1")
/// let assert Ok(request_id) = ids.parse_entry_id("00000000-0000-7000-8000-000000000003")
/// let origin = workspace.System(workspace.WorkspaceAdministration)
/// let invocation = workspace.invocation(scope, op, step, origin, request_id, workspace.Initialize)
/// assert workspace.request(invocation) == workspace.Initialize
/// ```
pub fn request(invocation: Invocation) -> Request {
  invocation.request
}

/// Checks response shape against the original immutable request, including read
/// projection and Git observation. A future decoder must perform this check
/// before recording success. Existing operation-specific errors still match.
///
/// ## Examples
///
/// ```gleam
/// assert workspace.response_matches(workspace.Initialize,
///   workspace.InitializationCompleted(Ok(workspace.AlreadyInitialized)))
/// assert !workspace.response_matches(workspace.Guidance,
///   workspace.InitializationCompleted(Ok(workspace.AlreadyInitialized)))
/// ```
pub fn response_matches(request: Request, response: Response) -> Bool {
  case request, response {
    Read(view: Text, ..), ReadCompleted(Ok(TextRead(..))) -> True
    Read(view: Native(..), ..), ReadCompleted(Ok(AnchoredRead(..))) -> True
    Read(view: Native(..), ..), ReadCompleted(Ok(ImageRead(..))) -> True
    Read(view: Lines(..), ..), ReadCompleted(Ok(LinesRead(..))) -> True
    Read(view: Lines(..), ..), ReadCompleted(Error(LinesReadFailed(..))) -> True
    Read(view: Text, ..), ReadCompleted(Error(FileReadFailed(..))) -> True
    Read(view: Native(..), ..), ReadCompleted(Error(FileReadFailed(..))) -> True
    Read(view: Native(..), ..), ReadCompleted(Error(InvalidWindow)) -> True
    Write(..), WriteCompleted(_) -> True
    AnchoredEdit(..), EditCompleted(_) -> True
    ListEntries(..), ListingCompleted(_) -> True
    Search(..), SearchCompleted(_) -> True
    Stat(..), StatCompleted(_) -> True
    Git(CurrentBranch), GitCompleted(Ok(BranchObserved(..))) -> True
    Git(CurrentRevision), GitCompleted(Ok(RevisionObserved(..))) -> True
    Git(Status), GitCompleted(Ok(StatusObserved(..))) -> True
    Git(Diff(..)), GitCompleted(Ok(DiffObserved(..))) -> True
    Git(Log(..)), GitCompleted(Ok(LogObserved(..))) -> True
    Git(..), GitCompleted(Error(_)) -> True
    Guidance, GuidanceCompleted(_) -> True
    Initialize, InitializationCompleted(_) -> True
    _, _ -> False
  }
}

/// Validates the exact object ID used for a session's Git comparison base.
/// It accepts SHA-1 and SHA-256 repositories and never accepts Git options,
/// symbolic revisions or expressions. Administration still owns the checkout.
///
/// ## Examples
///
/// ```gleam
/// assert workspace.revision("--output=/secret") == Error(workspace.InvalidRevision)
/// assert workspace.revision(string.repeat("a", 40)) |> result.is_ok
/// ```
pub fn revision(text: String) -> Result(Revision, RevisionError) {
  let size = string.byte_size(text)
  use Nil <- result.try(case size == 40 || size == 64 {
    True -> Ok(Nil)
    False -> Error(InvalidRevision)
  })
  use Nil <- result.try(validate_revision_loop(<<text:utf8>>))
  Ok(Revision(text))
}

/// Returns the full validated commit identifier for a fixed Git command.
///
/// ## Examples
///
/// ```gleam
/// let text = string.repeat("a", 40)
/// let assert Ok(revision) = workspace.revision(text)
/// assert workspace.revision_string(revision) == text
/// ```
pub fn revision_string(revision: Revision) -> String {
  revision.value
}

fn validate_revision_loop(bytes: BitArray) -> Result(Nil, RevisionError) {
  case bytes {
    <<>> -> Ok(Nil)
    <<byte, rest:bits>>
      if byte >= 48
      && byte <= 57
      || byte >= 65
      && byte <= 70
      || byte >= 97
      && byte <= 102
    -> validate_revision_loop(rest)
    _ -> Error(InvalidRevision)
  }
}
