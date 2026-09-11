//// A bounded observation of the attached session's Git working tree.
////
//// The host supplies the workspace and its final sandbox policy once. A
//// request supplies neither paths nor commands: every Git process clears
//// through that session's broker, with filesystem grants demoted to reads.
//// Repository configuration therefore never runs a process in the harness VM.
//// The gateway owns authorization and runs this synchronous body in a bounded
//// worker; the broker monitors that worker and cancels its effects on death.
////
//// Status supplies NUL-delimited identities. Each displayed file is compared
//// separately so a quoted patch header can never select a different filename.
//// Twenty-four files, one execution deadline, and an encoded response ceiling
//// bound the observation. The captured HEAD is pinned, but status and file reads
//// are not atomic with concurrent edits; this is an observation, not a commit.

import broker/broker
import broker/budget
import broker/exec
import broker/policy
import client/codemode
import client/daemon/transfer
import core/clock
import core/ids
import core/json
import gleam/bit_array
import gleam/bool
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import tools/tool

/// The shared execution deadline, before the broker's cleanup grace.
pub const capture_timeout_ms = 8000

/// Cleanup may outlive execution; an outer worker must allow this grace.
pub const settlement_grace_ms = 5000

/// The maximum number of displayed files and per-file Git calls.
pub const file_limit = 24

/// The complete encoded board fits below the gateway's response ceiling.
pub const board_byte_limit = 40_960

const status_byte_limit = 262_144

const patch_byte_limit = 16_384

const capture_byte_limit = 524_288

/// Session capabilities captured by `serve`, never supplied by a client frame.
pub type Wiring {
  Wiring(
    /// The attached session's absolute workspace, including a repository subtree.
    workspace: String,
    /// The session's existing effect broker and helper pool.
    broker: broker.Broker,
    /// The assembled policy, including state masks and linked Git metadata.
    base_policy: policy.SandboxPolicy,
    /// The session's injected wall clock.
    clock: clock.Clock,
    /// Production's required kernel enforcement.
    demand: exec.EnforcementDemand,
    /// The assembled environment; only an allowed PATH is retained.
    env: List(#(String, String)),
    /// A fresh operation seed for each observation.
    entropy: fn() -> Int,
  )
}

/// Whether the repository has a committed comparison base.
pub type Repository {
  /// A pinned HEAD commit supplies the original contents.
  Head

  /// No HEAD exists; present files are additions against an empty original.
  Unborn

  /// Git explicitly reported that this workspace is outside a repository.
  NotRepository
}

/// Whether the displayed data includes everything in the bounded observation.
pub type Extent {
  /// Neither file omission nor a patch excerpt was necessary.
  Complete

  /// A file or the remainder of a patch was omitted by a display bound.
  Limited
}

/// The meaning of a file's patch field.
pub type Content {
  /// A unified text patch, possibly an explicitly marked excerpt.
  Text

  /// Git classified the content as binary; the patch is its summary.
  Binary

  /// Index and worktree changes cancel out relative to the captured HEAD.
  NoNetChange

  /// An untracked nested repository is listed without traversing it.
  MetadataOnly
}

/// One exact workspace-relative identity and the observation made for it.
pub type File {
  File(
    /// The literal UTF-8 pathname, never decoded from a display header.
    path: String,
    /// Git's one-character index status, including a space for unchanged.
    index_status: String,
    /// Git's one-character worktree status, including a space for unchanged.
    worktree_status: String,
    /// The captured unified patch or binary summary.
    patch: String,
    /// How to interpret the patch rather than guessing from empty text.
    kind: Content,
    /// Whether this file's patch was cut at its byte ceiling.
    extent: Extent,
  )
}

/// A transient observation, independent of the conversation's durable sequence.
pub type Board {
  Board(
    /// Unix milliseconds at the start of observation, not a filesystem revision.
    observed_at_ms: Int,
    /// Whether HEAD, an empty original, or no repository was observed.
    repository: Repository,
    /// Files retained within both the count and encoded-byte ceilings.
    entries: List(File),
    /// The exact count from the complete bounded status response.
    total: Int,
    /// Status entries absent from `entries`, including byte-bound omissions.
    omitted: Int,
    /// Whether any file or patch content was omitted.
    extent: Extent,
  )
}

/// Failures never masquerade as a clean repository or an exact file census.
pub type Error {
  /// The one deadline was consumed before another execution could begin.
  Deadline

  /// Status or the aggregate process output exceeded its hard bound.
  OutputLimit

  /// Git output was malformed, incomplete, or not representable as UTF-8 paths.
  InvalidOutput

  /// The broker refused clearance without acquiring filesystem authority.
  Refused(reason: String)

  /// The helper failed, timed out, or cancelled the execution.
  ExecutionFailed(reason: String)

  /// No settlement arrived; cancellation was requested before returning.
  NoSettlement

  /// Git returned a real failure, distinct from no-index's differences code.
  GitFailed(code: Int, diagnostic: String)
}

type Capture {
  Capture(
    wiring: Wiring,
    clock: clock.Clock,
    deadline: Int,
    op_id: ids.OpId,
    bytes_left: Int,
  )
}

type Output {
  Output(code: Int, stdout: BitArray, stderr: BitArray, extent: Extent)
}

type Identity {
  Identity(path: String, index_status: String, worktree_status: String)
}

/// Captures the attached workspace under its existing authority.
///
/// Run outside the gateway actor. An execution deadline requests cancellation;
/// the helper's terminal settlement supplies the result. An outer worker's
/// death also cancels through the broker, so timing out does not orphan Git.
///
/// ## Examples
///
/// ```gleam
/// // worktree_diff.capture(session_wiring)
/// ```
pub fn capture(wiring: Wiring) -> Result(Board, Error) {
  let #(observed_at_ms, next_clock) = clock.read(wiring.clock)
  let #(op_id, _) = ids.mint_op(ids.generator(next_clock, wiring.entropy()))
  let capture =
    Capture(
      wiring:,
      clock: next_clock,
      deadline: observed_at_ms + capture_timeout_ms,
      op_id:,
      bytes_left: capture_byte_limit,
    )
  use #(capture, status) <- result.try(run_git(
    capture,
    [
      "status", "--porcelain=v1", "-z", "--untracked-files=no",
      "--ignore-submodules=dirty", "--", ".",
    ],
    status_byte_limit,
  ))

  // Git's explicit diagnostic distinguishes a non-repository from unreadable
  // metadata. Other failures, including protected metadata, remain failures.
  case status.code, diagnostic(status.stderr) {
    128, "fatal: not a git repository" <> _ ->
      Ok(Board(observed_at_ms, NotRepository, [], 0, 0, Complete))
    _, _ -> capture_repository(capture, status, observed_at_ms)
  }
}

fn capture_repository(
  capture: Capture,
  status: Output,
  observed_at_ms: Int,
) -> Result(Board, Error) {
  use Nil <- result.try(successful(status))
  use Nil <- result.try(complete(status))
  use #(capture, prefix) <- result.try(run_git(
    capture,
    ["rev-parse", "--show-prefix"],
    4096,
  ))
  use Nil <- result.try(successful(prefix))
  use Nil <- result.try(complete(prefix))
  use prefix <- result.try(line_value(prefix.stdout))
  use identities <- result.try(parse_status(status.stdout, prefix))
  use #(capture, untracked) <- result.try(capture_untracked(capture, prefix))
  let identities = list.append(identities, untracked)
  use #(capture, head) <- result.try(run_git(
    capture,
    ["rev-parse", "--verify", "--quiet", "HEAD"],
    4096,
  ))
  use Nil <- result.try(complete(head))
  use #(repository, revision) <- result.try(comparison(head))

  // The status count is exact only because an oversized status was refused.
  // Files beyond this prefix are counted, not silently treated as unchanged.
  let total = list.length(identities)
  use files <- result.try(
    capture_files(
      capture,
      list.take(identities, file_limit),
      repository,
      revision,
      [],
    ),
  )
  let board = Board(observed_at_ms, repository, [], total, total, Complete)
  Ok(fit_board(board, files))
}

// Tool homes and build caches belong to Loom's generated directories. Exclude
// only their untracked contents before Git enumerates them: filtering a huge
// status afterwards would already have spent the observation's byte budget.
// Tracked files still come from ordinary status, even under these directories.
fn capture_untracked(capture: Capture, prefix: String) {
  use #(capture, output) <- result.try(run_git(
    capture,
    [
      "ls-files",
      "--others",
      "--exclude-standard",
      "--full-name",
      "-z",
      "--exclude=" <> codemode.work_directory <> "/",
      "--exclude=" <> codemode.blob_directory <> "/",
      "--",
      ".",
    ],
    status_byte_limit,
  ))
  use Nil <- result.try(successful(output))
  use Nil <- result.try(complete(output))
  use text <- result.try(
    bit_array.to_string(output.stdout) |> result.replace_error(InvalidOutput),
  )
  case text {
    "" -> Ok(#(capture, []))
    _ -> {
      use <- bool.guard(!string.ends_with(text, "\u{0}"), Error(InvalidOutput))
      use identities <- result.try(
        text
        |> string.drop_end(1)
        |> string.split("\u{0}")
        |> list.try_map(fn(path) { status_identity("?? " <> path, prefix) }),
      )
      Ok(#(capture, identities))
    }
  }
}

fn comparison(output: Output) -> Result(#(Repository, String), Error) {
  case output.code {
    1 -> Ok(#(Unborn, ""))
    0 -> {
      use revision <- result.try(line_value(output.stdout))
      case valid_revision(revision) {
        True -> Ok(#(Head, revision))
        False -> Error(InvalidOutput)
      }
    }
    code -> Error(GitFailed(code, diagnostic(output.stderr)))
  }
}

fn valid_revision(revision: String) -> Bool {
  { string.byte_size(revision) == 40 || string.byte_size(revision) == 64 }
  && list.all(string.to_graphemes(revision), fn(character) {
    string.contains("0123456789abcdef", character)
  })
}

fn capture_files(
  capture: Capture,
  identities: List(Identity),
  repository: Repository,
  revision: String,
  reversed: List(File),
) -> Result(List(File), Error) {
  case identities {
    [] -> Ok(list.reverse(reversed))
    [identity, ..rest] -> {
      use #(capture, file) <- result.try(capture_file(
        capture,
        identity,
        repository,
        revision,
      ))
      capture_files(capture, rest, repository, revision, [file, ..reversed])
    }
  }
}

fn capture_file(
  capture: Capture,
  identity: Identity,
  repository: Repository,
  revision: String,
) -> Result(#(Capture, File), Error) {
  let empty =
    File(
      identity.path,
      identity.index_status,
      identity.worktree_status,
      "",
      NoNetChange,
      Complete,
    )

  // Porcelain lists an untracked nested repository as one directory. It is
  // an identity in this workspace, not permission to recursively diff it.
  use <- bool.guard(
    string.ends_with(identity.path, "/"),
    Ok(#(capture, File(..empty, kind: MetadataOnly))),
  )
  use <- bool.guard(
    repository == Unborn && identity.worktree_status == "D",
    Ok(#(capture, empty)),
  )
  let addition = repository == Unborn || identity.index_status == "?"
  let arguments = case addition {
    True ->
      list.append(diff_arguments(), [
        "--no-index", "--", "/dev/null", identity.path,
      ])
    False -> list.append(diff_arguments(), [revision, "--", identity.path])
  }
  use #(capture, output) <- result.try(run_git(
    capture,
    arguments,
    patch_byte_limit,
  ))
  use Nil <- result.try(case output.code, addition {
    0, _ | 1, True -> Ok(Nil)
    code, _ -> Error(GitFailed(code, diagnostic(output.stderr)))
  })
  use patch <- result.try(patch_text(output.stdout, output.extent))
  let kind = case patch {
    "" -> NoNetChange
    _ ->
      case string.contains(patch, "\nBinary files ") {
        True -> Binary
        False -> Text
      }
  }
  Ok(#(capture, File(..empty, patch:, kind:, extent: output.extent)))
}

fn diff_arguments() -> List(String) {
  [
    "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames",
    "--relative", "--ignore-submodules=dirty", "--submodule=short",
    "--src-prefix=a/", "--dst-prefix=b/", "--unified=3",
  ]
}

fn run_git(
  capture: Capture,
  arguments: List(String),
  output_limit: Int,
) -> Result(#(Capture, Output), Error) {
  let #(now, next_clock) = clock.read(capture.clock)
  use <- bool.guard(now >= capture.deadline, Error(Deadline))
  use <- bool.guard(capture.bytes_left <= 1, Error(OutputLimit))
  let remaining = capture.deadline - now
  let wiring = capture.wiring
  let base = read_policy(wiring.base_policy)
  let environment = git_environment(wiring.env, base.env_allow)
  let requirements =
    policy.SandboxPolicy(
      ..base,
      env_allow: list.map(environment, fn(pair) { pair.0 }),
      limits: policy.Limits(
        cpu_s: 8,
        wall_s: { remaining + 999 } / 1000,
        mem_bytes: 268_435_456,
        pids: 16,
        fsize_bytes: 1_048_576,
        output_bytes: int.min(output_limit, capture.bytes_left / 2),
      ),
    )
  let events = process.new_subject()
  use call <- result.try(
    broker.clear_call(
      wiring.broker,
      broker.CallSpec(
        op_id: capture.op_id,
        step_id: "worktree-observation",
        base_policy: base,
        requirements:,
        grants: [],
        response: broker.RefuseNarrowed,
        demand: wiring.demand,
        argv: list.append(
          [
            "git", "--no-pager", "--no-optional-locks", "--literal-pathspecs",
            "-c", "core.fsmonitor=false", "-c", "status.renames=false", "-c",
            "core.untrackedCache=false", "-c", "submodule.recurse=false",
          ],
          arguments,
        ),
        env: environment,
        cwd: wiring.workspace,
        budget: budget.Budget(1, capture.deadline),
      ),
      events:,
      waiting: remaining,
    )
    |> result.map_error(fn(error) { Refused(string.inspect(error)) }),
  )

  // No command consumes interactive input. Cancelling on missing settlement
  // requests cleanup; it does not claim that native retirement was observed.
  broker.stdin(wiring.broker, call, data: <<>>, eof: True)
  use collected <- result.try(
    tool.collect_events(events, waiting: remaining + settlement_grace_ms)
    |> result.map_error(fn(_) {
      broker.cancel(wiring.broker, call)
      NoSettlement
    }),
  )
  use output <- result.try(settled(collected))
  let used =
    bit_array.byte_size(output.stdout) + bit_array.byte_size(output.stderr)
  Ok(#(
    Capture(..capture, clock: next_clock, bytes_left: capture.bytes_left - used),
    output,
  ))
}

fn settled(collected: tool.Collected) -> Result(Output, Error) {
  case collected.outcome {
    broker.CallFailed(failure) ->
      Error(ExecutionFailed(string.inspect(failure)))
    broker.CallExited(report) -> {
      use <- bool.guard(
        report.cancelled || report.timed_out,
        Error(ExecutionFailed("Git did not complete before cancellation")),
      )
      let extent = case
        collected.stdout_truncated
        || collected.stderr_truncated
        || report.stdout_truncated
        || report.stderr_truncated
      {
        True -> Limited
        False -> Complete
      }
      Ok(Output(report.code, collected.stdout, collected.stderr, extent))
    }
  }
}

/// Restricts the session's existing filesystem view to reads and scratch.
/// Protected paths and required mounts remain intact. Moving writable roots
/// into readable roots preserves their existing read authority without adding
/// a host path; changing only requirements would lose writable-only roots in
/// the policy's separate read and write intersections.
///
/// ## Examples
///
/// ```gleam
/// assert worktree_diff.read_policy(policy.workspace_default("/work"))
///   .writable_roots == []
/// ```
@internal
pub fn read_policy(base: policy.SandboxPolicy) -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    ..base,
    writable_roots: [],
    readable_roots: list.unique(list.append(
      base.readable_roots,
      base.writable_roots,
    )),
    mounts: list.map(base.mounts, fn(mount) {
      policy.Mount(..mount, access: policy.MountReadOnly)
    }),
    network: policy.NetworkOff,
    scratch: policy.ScratchTmpfs,
  )
}

fn git_environment(
  environment: List(#(String, String)),
  allowed: List(String),
) -> List(#(String, String)) {
  let path =
    list.find(environment, fn(pair) { pair.0 == "PATH" })
    |> result.map(fn(pair) { pair.1 })
    |> result.unwrap("/usr/bin:/bin:/usr/local/bin")

  // No daemon secrets or Git routing variables survive. A nonexistent HOME
  // prevents a tool-owned home from selecting user Git configuration; these
  // constants still require the session's own environment-name permission.
  list.filter(
    [#("PATH", path), #("HOME", "/nonexistent"), #("LANG", "C")],
    fn(pair) { list.contains(allowed, pair.0) },
  )
}

/// Decodes porcelain-v1's NUL framing without interpreting Git's display quoting.
/// Rename detection is disabled at invocation, so each record has one pathname.
/// Non-UTF-8 names refuse the observation rather than changing an identity.
///
/// ## Examples
///
/// ```gleam
/// // worktree_diff.decode_status(<<" M file\u{0}":utf8>>, "")
/// ```
@internal
pub fn decode_status(
  bytes: BitArray,
  prefix: String,
) -> Result(List(File), Error) {
  use identities <- result.map(parse_status(bytes, prefix))
  list.map(identities, fn(identity) {
    File(
      identity.path,
      identity.index_status,
      identity.worktree_status,
      "",
      NoNetChange,
      Complete,
    )
  })
}

fn parse_status(
  bytes: BitArray,
  prefix: String,
) -> Result(List(Identity), Error) {
  use text <- result.try(
    bit_array.to_string(bytes) |> result.replace_error(InvalidOutput),
  )
  case text {
    "" -> Ok([])
    _ -> {
      use <- bool.guard(!string.ends_with(text, "\u{0}"), Error(InvalidOutput))
      text
      |> string.drop_end(1)
      |> string.split("\u{0}")
      |> list.try_map(fn(record) { status_identity(record, prefix) })
    }
  }
}

fn status_identity(record: String, prefix: String) -> Result(Identity, Error) {
  case bit_array.from_string(record) {
    <<index:8, working:8, 32:8, raw_path:bits>> -> {
      use path <- result.try(
        bit_array.to_string(raw_path) |> result.replace_error(InvalidOutput),
      )
      use <- bool.guard(!string.starts_with(path, prefix), Error(InvalidOutput))

      // Path identity is byte-based. A leading combining mark in a filename
      // can join the prefix's final slash into one grapheme, so dropping a
      // grapheme count would silently remove part of the filename.
      use path <- result.try(
        bit_array.slice(
          raw_path,
          string.byte_size(prefix),
          bit_array.byte_size(raw_path) - string.byte_size(prefix),
        )
        |> result.try(bit_array.to_string)
        |> result.replace_error(InvalidOutput),
      )
      use <- bool.guard(!valid_path(path), Error(InvalidOutput))
      use index_status <- result.try(status_character(index))
      use worktree_status <- result.try(status_character(working))
      Ok(Identity(path, index_status, worktree_status))
    }
    _ -> Error(InvalidOutput)
  }
}

fn status_character(byte: Int) -> Result(String, Error) {
  case byte {
    32 -> Ok(" ")
    63 -> Ok("?")
    77 -> Ok("M")
    65 -> Ok("A")
    68 -> Ok("D")
    84 -> Ok("T")
    85 -> Ok("U")
    _ -> Error(InvalidOutput)
  }
}

fn valid_path(path: String) -> Bool {
  path != ""
  && !string.starts_with(path, "/")
  && list.all(string.split(path, "/"), fn(component) {
    component != ".." && component != "."
  })
}

fn line_value(bytes: BitArray) -> Result(String, Error) {
  use text <- result.try(
    bit_array.to_string(bytes) |> result.replace_error(InvalidOutput),
  )
  case string.ends_with(text, "\n") {
    True -> Ok(string.drop_end(text, 1))
    False -> Error(InvalidOutput)
  }
}

fn patch_text(bytes: BitArray, extent: Extent) -> Result(String, Error) {
  case extent {
    Complete ->
      bit_array.to_string(bytes) |> result.replace_error(InvalidOutput)
    Limited -> utf8_prefix(bytes, bit_array.byte_size(bytes), 4)
  }
}

fn utf8_prefix(
  bytes: BitArray,
  size: Int,
  attempts: Int,
) -> Result(String, Error) {
  case attempts {
    0 -> Error(InvalidOutput)
    _ ->
      case bit_array.slice(bytes, 0, size) |> result.try(bit_array.to_string) {
        Ok(text) -> Ok(text)
        Error(_) -> utf8_prefix(bytes, int.max(0, size - 1), attempts - 1)
      }
  }
}

fn successful(output: Output) -> Result(Nil, Error) {
  case output.code {
    0 -> Ok(Nil)
    code -> Error(GitFailed(code, diagnostic(output.stderr)))
  }
}

fn complete(output: Output) -> Result(Nil, Error) {
  case output.extent {
    Complete -> Ok(Nil)
    Limited -> Error(OutputLimit)
  }
}

fn diagnostic(bytes: BitArray) -> String {
  bytes
  |> bit_array.to_string
  |> result.unwrap("Git returned a non-UTF-8 diagnostic")
  |> string.slice(0, 512)
}

fn fit_board(board: Board, files: List(File)) -> Board {
  case files {
    [] -> board_extent(board)
    [file, ..rest] -> {
      let candidate =
        Board(
          ..board,
          entries: list.append(board.entries, [file]),
          omitted: board.omitted - 1,
        )
        |> board_extent
      case transfer.encoded_size(to_json(candidate), board_byte_limit) {
        Ok(_) -> fit_board(candidate, rest)
        Error(_) -> Board(..board, extent: Limited)
      }
    }
  }
}

fn board_extent(board: Board) -> Board {
  let limited =
    board.omitted > 0
    || list.any(board.entries, fn(file) { file.extent == Limited })
  Board(..board, extent: case limited {
    True -> Limited
    False -> Complete
  })
}

/// Encodes the optional `worktree_diff` snapshot field from one observation.
/// Exact paths remain JSON strings; terminal escaping belongs to the renderer.
///
/// ## Examples
///
/// ```gleam
/// // worktree_diff.to_json(board)
/// ```
pub fn to_json(board: Board) -> json.JsonValue {
  json.Object([
    #("source", json.String("git")),
    #("observed_at_ms", json.Int(board.observed_at_ms)),
    #(
      "repository",
      json.String(case board.repository {
        Head -> "head"
        Unborn -> "unborn"
        NotRepository -> "not_repository"
      }),
    ),
    #("entries", json.Array(list.map(board.entries, file_json))),
    #("total", json.Int(board.total)),
    #("omitted", json.Int(board.omitted)),
    #("extent", json.String(extent_text(board.extent))),
  ])
}

fn file_json(file: File) -> json.JsonValue {
  json.Object([
    #("path", json.String(file.path)),
    #("index_status", json.String(file.index_status)),
    #("worktree_status", json.String(file.worktree_status)),
    #("patch", json.String(file.patch)),
    #(
      "kind",
      json.String(case file.kind {
        Text -> "text"
        Binary -> "binary"
        NoNetChange -> "no_net_change"
        MetadataOnly -> "metadata_only"
      }),
    ),
    #("extent", json.String(extent_text(file.extent))),
  ])
}

fn extent_text(extent: Extent) -> String {
  case extent {
    Complete -> "complete"
    Limited -> "limited"
  }
}

/// Describes a classified failure without presenting it as empty changes.
///
/// ## Examples
///
/// ```gleam
/// assert worktree_diff.error_message(worktree_diff.Deadline)
///   == "worktree observation exceeded its shared deadline"
/// ```
pub fn error_message(error: Error) -> String {
  case error {
    Deadline -> "worktree observation exceeded its shared deadline"
    OutputLimit -> "worktree observation exceeded its output budget"
    InvalidOutput ->
      "Git output could not be decoded without changing file identity"
    Refused(reason) -> "worktree observation was refused: " <> reason
    ExecutionFailed(reason) -> "worktree observation failed: " <> reason
    NoSettlement ->
      "worktree observation did not settle; cancellation was requested"
    GitFailed(code, diagnostic) ->
      "Git exited " <> int.to_string(code) <> ": " <> diagnostic
  }
}
