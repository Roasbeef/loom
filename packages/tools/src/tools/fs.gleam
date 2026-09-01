//// The filesystem tools: `fs_read`, `fs_write`, and `fs_edit`, plus
//// the production `FileSystem` seam and workspace path discipline.
////
//// `fs_read` renders hashline-anchored windows (`line:anchor|text`)
//// with the total line count and the whole-file digest, so edits can
//// reference exact content; `fs_edit` applies a multi-hunk
//// anchor-checked, digest-bound plan and rejects any staleness with
//// fresh anchors for replanning; `fs_write` creates or replaces a
//// whole file. All three resolve paths against the *real* filesystem
//// (`resolve_real`): symlinks are resolved component by component and
//// the resolved path must land under the (equally resolved) workspace
//// root, so neither `..` nor a symlink planted inside the workspace
//// can reach outside it. This is not defense in depth but the sole
//// boundary: these tools run in the harness and never pass through
//// the broker or the kernel jail, so path discipline is entirely
//// their own responsibility. Containment is only half of it: the
//// session base policy's `protected` list — `.git` internals, `.env`,
//// credential files — is enforced for a *jailed* process by bwrap's
//// masks, which these tools never meet, so `fs_write` and `fs_edit`
//// apply it themselves in `resolve_for_write`. Without that, the
//// harness's own tools would hold strictly more filesystem authority
//// than the jail they are supposed to be no wider than, and a written
//// `.git/hooks/post-checkout` is arbitrary code execution outside the
//// jail on the next checkout.
////
//// ## Replay safety
////
//// All three tools declare `replay: Safe`:
////
//// - `fs_read` is a read.
//// - `fs_write` is idempotent: re-running writes the same bytes to the
////   same path.
//// - `fs_edit` is bound by its digest: the plan carries the digest of
////   the exact content it was planned against, and `hashline.apply`
////   rejects any other content — including the plan's own output, and
////   including content where an identical sibling line shifted into a
////   referenced position (which defeats per-line anchors alone). A
////   crash replay therefore either repeats an edit that never landed
////   (the pre-image is intact, the edit applies exactly as intended)
////   or fails in-band as stale — it cannot double-apply. The residual
////   window is a digest collision between the pre- and post-image,
////   which requires equal byte length and equal FNV-64 (see
////   `tools/hashline`): impossible in practice by accident, and
////   deliberate construction gains nothing — the caller already holds
////   arbitrary write access to the same file through this very tool.

import broker/policy
import core/json.{type JsonValue}
import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import tools/blob
import tools/hashline
import tools/internal/ffi_path
import tools/tool.{type Ctx, type FileSystem, type FsError, type ToolOutcome}

/// Default number of lines an `fs_read` without `limit` returns.
pub const default_read_lines = 2000

/// Files larger than this many bytes are refused by `fs_read` (the
/// large-file guard): the whole file must be decoded to window it, so
/// unboundedly large files are read with jailed shell tools instead.
pub const max_read_bytes = 8_388_608

/// Why a path was rejected before any read or write.
pub type PathError {
  /// The path argument was empty.
  EmptyPath

  /// The path resolves outside the workspace root.
  EscapesWorkspace(path: String)

  /// The path could not be resolved against the real filesystem: an
  /// unreadable component, or a symlink chain longer than the
  /// resolution budget (a loop).
  Unresolvable(path: String, reason: String)

  /// The path resolves at or under an entry of the session base
  /// policy's `protected` list, which no write may touch. `protected`
  /// carries the entry that matched.
  ProtectedPath(path: String, protected: String)

  /// The session base policy's `protected` list holds a non-absolute
  /// entry, so this write is refused without being judged at all.
  /// `protected` carries the offending entry.
  ///
  /// A relative entry is a misconfiguration rather than a path, and it
  /// cannot be interpreted: `normalize` would root it at `/`, where it
  /// covers nothing and every write sails past. The jail refuses the
  /// same policy loudly (`broker/policy.validate` answers
  /// `RelativePath`), so the harness must not be the door that quietly
  /// stays open — a `protected` list the jail will not accept must not
  /// be one the harness silently ignores.
  ProtectionMisconfigured(path: String, protected: String)
}

/// The production `FileSystem` seam, backed by simplifile.
pub fn real_filesystem() -> FileSystem {
  tool.FileSystem(
    read: fn(path) {
      simplifile.read_bits(path)
      |> result.map_error(map_file_error(path, _))
    },
    write: fn(path, bytes) {
      simplifile.write_bits(path, bytes)
      |> result.map_error(map_file_error(path, _))
    },
    create_directory_all: fn(path) {
      simplifile.create_directory_all(path)
      |> result.map_error(map_file_error(path, _))
    },
    is_file: fn(path) {
      simplifile.is_file(path)
      |> result.map_error(map_file_error(path, _))
    },
    read_link: fn(path) {
      ffi_path.read_link(path)
      |> result.map_error(fn(reason) { tool.FsFailure(path:, reason:) })
    },
    // `simplifile.rename` is `file:rename/2`, which is `rename(2)`: an
    // atomic replace within one filesystem, and an error rather than a
    // silent copy across two. The error is reported against the
    // destination, which is the path a caller was trying to establish.
    rename: fn(from, to) {
      simplifile.rename(at: from, to:)
      |> result.map_error(map_file_error(to, _))
    },
  )
}

// simplifile's error vocabulary is the POSIX errno list — genuinely
// open-ended for our purposes, so the catch-all is deliberate.
fn map_file_error(path: String, error: simplifile.FileError) -> FsError {
  case error {
    simplifile.Enoent -> tool.FsNotFound(path:)
    simplifile.Eacces -> tool.FsPermissionDenied(path:)
    other -> tool.FsFailure(path:, reason: simplifile.describe_error(other))
  }
}

/// Resolves a tool-supplied path under the workspace root **lexically**
/// only: relative paths join under the root, `.` and `..` segments
/// collapse textually, and any result outside the root is rejected. No
/// symlink is resolved, so this is *not* a containment boundary on a
/// real filesystem — a symlink inside the workspace can point anywhere.
/// It is sufficient only where symlinks cannot betray it: for paths
/// handed to *jailed* executions (`grep`, where the kernel jail owns
/// containment) and for tests over filesystems without symlinks. The
/// harness-side fs tools use `resolve_real` instead.
///
/// ## Examples
///
/// ```gleam
/// assert fs.resolve_path("/work", "src/main.gleam")
///   == Ok("/work/src/main.gleam")
/// ```
///
/// ```gleam
/// assert fs.resolve_path("/work", "../etc/passwd")
///   == Error(fs.EscapesWorkspace("../etc/passwd"))
/// ```
///
pub fn resolve_path(
  workspace workspace: String,
  path path: String,
) -> Result(String, PathError) {
  let root = strip_trailing_slash(workspace)
  case path {
    "" -> Error(EmptyPath)
    "/" <> _ -> check_under(root, normalize(path), path)
    _ -> check_under(root, normalize(root <> "/" <> path), path)
  }
}

/// How many symlinks one resolution may follow before it is treated as
/// a loop (mirrors the kernel's `ELOOP` discipline).
pub const max_link_follows = 40

/// Resolves a tool-supplied path under the workspace root against the
/// **real** filesystem — the resolution the harness-side fs tools
/// trust, since they run outside every jail. Relative paths join under
/// the root; then both the root and the candidate are walked component
/// by component through `read_link`: symlinks are replaced by their
/// targets (POSIX order — a link is resolved *before* a following
/// `..`), `.`/`..` collapse against the resolved prefix, and
/// components past the deepest existing ancestor are kept verbatim
/// (they cannot be symlinks — nothing exists there). The fully
/// resolved candidate must land under the fully resolved root; the
/// returned path is the resolved one, so subsequent reads and writes
/// traverse no symlink at all. A symlinked workspace root works: the
/// root resolves once and containment compares resolved to resolved.
///
/// This closes the lexical hole: a symlink planted inside the
/// workspace (checked into a repo, or written by a jailed process) and
/// pointing outside it is rejected, dangling symlinks included — a
/// write through `link -> /outside/absent` would land outside, so the
/// link is resolved to its target and the target fails containment.
///
/// **Resolution is point-in-time.** What comes back is where the path
/// led when it was walked, and the caller then reads or writes that
/// resolved path — so a mutator running *concurrently* inside the
/// workspace (a jailed `proc.run`, another code-mode program, the user's
/// own editor) can interpose a symlink between the resolve and the
/// write. Returning the resolved path rather than the original narrows
/// the window to a component that was verified not to be a link, which
/// is why every caller writes to the return value and never to its own
/// argument, but it does not close it. The jail does not share this
/// window at all: bwrap's mounts and masks are established before the
/// payload runs and are properties of a namespace rather than of a
/// lookup, so nothing the workspace does afterwards moves them.
///
/// ## Examples
///
/// ```gleam
/// // With /work/link -> /etc on disk:
/// assert fs.resolve_real(filesystem, "/work", "link/passwd")
///   == Error(fs.EscapesWorkspace("link/passwd"))
/// ```
///
pub fn resolve_real(
  filesystem filesystem: FileSystem,
  workspace workspace: String,
  path path: String,
) -> Result(String, PathError) {
  let root = strip_trailing_slash(workspace)
  case path {
    "" -> Error(EmptyPath)
    _ -> {
      let joined = case path {
        "/" <> _ -> path
        _ -> root <> "/" <> path
      }
      use real_root <- result.try(
        walk(filesystem, root)
        |> result.map_error(Unresolvable(path:, reason: _)),
      )
      use resolved <- result.try(
        walk(filesystem, joined)
        |> result.map_error(Unresolvable(path:, reason: _)),
      )
      check_under(real_root, resolved, path)
    }
  }
}

// Resolves an absolute path against the real filesystem, component by
// component. The accumulator stack holds resolved components (each
// verified not to be a symlink, or known missing); `..` pops it, which
// is sound exactly because no stack entry is a link. Once a component
// is missing, everything deeper is kept verbatim: nothing can exist —
// or be a symlink — below a missing component.
fn walk(filesystem: FileSystem, path: String) -> Result(String, String) {
  walk_loop(
    filesystem,
    stack: [],
    remaining: string.split(path, on: "/"),
    missing: False,
    budget: max_link_follows,
  )
}

fn walk_loop(
  filesystem: FileSystem,
  stack stack: List(String),
  remaining remaining: List(String),
  missing missing: Bool,
  budget budget: Int,
) -> Result(String, String) {
  case remaining {
    [] -> Ok("/" <> string.join(list.reverse(stack), with: "/"))
    ["", ..rest] | [".", ..rest] ->
      walk_loop(filesystem, stack:, remaining: rest, missing:, budget:)
    ["..", ..rest] -> {
      let stack = case stack {
        [] -> []
        [_, ..parent] -> parent
      }
      walk_loop(filesystem, stack:, remaining: rest, missing:, budget:)
    }
    [segment, ..rest] ->
      walk_segment(filesystem, stack, segment, rest, missing, budget)
  }
}

// Resolves one path segment. Inside an already-missing prefix nothing
// can exist below it — so nothing there can be a symlink either — and
// the segment is kept verbatim; otherwise `read_link` tells a plain
// component from a symlink that must be followed.
fn walk_segment(
  filesystem: FileSystem,
  stack: List(String),
  segment: String,
  rest: List(String),
  missing: Bool,
  budget: Int,
) -> Result(String, String) {
  case missing {
    True ->
      walk_loop(
        filesystem,
        stack: [segment, ..stack],
        remaining: rest,
        missing: True,
        budget:,
      )
    False -> {
      let candidate =
        "/" <> string.join(list.reverse([segment, ..stack]), with: "/")
      case filesystem.read_link(candidate) {
        Error(error) -> Error(fs_error_text(error))
        Ok(tool.NotALink) ->
          walk_loop(
            filesystem,
            stack: [segment, ..stack],
            remaining: rest,
            missing: False,
            budget:,
          )
        Ok(tool.LinkMissing) ->
          walk_loop(
            filesystem,
            stack: [segment, ..stack],
            remaining: rest,
            missing: True,
            budget:,
          )
        Ok(tool.LinkTarget(target:)) ->
          walk_link_target(filesystem, stack, rest, budget, target)
      }
    }
  }
}

// Follows a resolved symlink target, respecting the loop budget
// (mirrors the kernel's `ELOOP`). An absolute target restarts the
// stack at root; a relative one is appended in front of what
// remained. The segment that named the link is not pushed — it is
// replaced by its target, not kept alongside it.
fn walk_link_target(
  filesystem: FileSystem,
  stack: List(String),
  rest: List(String),
  budget: Int,
  target: String,
) -> Result(String, String) {
  case budget < 1 {
    True -> Error("too many symlinks (loop?)")
    False -> {
      let target_segments = string.split(target, on: "/")
      let #(stack, remaining) = case target {
        "/" <> _ -> #([], list.append(target_segments, rest))
        _ -> #(stack, list.append(target_segments, rest))
      }
      walk_loop(
        filesystem,
        stack:,
        remaining:,
        missing: False,
        budget: budget - 1,
      )
    }
  }
}

// A short description of a seam error for `Unresolvable`.
fn fs_error_text(error: FsError) -> String {
  case error {
    tool.FsNotFound(path:) -> "not found: " <> path
    tool.FsPermissionDenied(path:) -> "permission denied: " <> path
    tool.FsFailure(path:, reason:) -> reason <> ": " <> path
  }
}

fn strip_trailing_slash(path: String) -> String {
  case path != "/" && string.ends_with(path, "/") {
    True -> string.drop_end(path, 1)
    False -> path
  }
}

fn check_under(
  root: String,
  candidate: String,
  original: String,
) -> Result(String, PathError) {
  let inside = case root {
    "/" -> True
    _ -> candidate == root || string.starts_with(candidate, root <> "/")
  }
  case inside {
    True -> Ok(candidate)
    False -> Error(EscapesWorkspace(path: original))
  }
}

// Lexical normalization: collapse `.`, empty segments, and `..`
// (popping past the filesystem root stays at the root; the caller's
// under-workspace check rejects the escape).
fn normalize(path: String) -> String {
  let segments =
    string.split(path, on: "/")
    |> list.fold([], fn(stack, segment) {
      case segment {
        "" | "." -> stack
        ".." ->
          case stack {
            [] -> []
            [_, ..rest] -> rest
          }
        _ -> [segment, ..stack]
      }
    })
  "/" <> string.join(list.reverse(segments), with: "/")
}

// --- protected paths -----------------------------------------------------

/// Resolves a path for a **write**: `resolve_real` for containment, then
/// the session base policy's `protected` list. The single path both
/// `fs_write` and `fs_edit` go through, so neither can acquire authority
/// the other lacks.
///
/// The order is the security property, not a preference. `protected` is
/// checked on the *resolved* path, so a workspace-internal symlink
/// pointing at `.git/config` — checked into a repository, or planted by
/// a jailed process — is caught on what it actually names. Checked
/// before resolution it would be a test of the string the model chose,
/// which is the thing least worth testing.
///
/// **A grant cannot open a protected path.** The escalation vocabulary
/// has no variant for it: `broker/policy.Grant` is
/// `GrantWritableRoot`/`GrantReadableRoot`/`GrantNetwork`/`GrantEnv`/
/// `GrantLimit`/`GrantScratch`, and `apply_grant` never writes the
/// `protected` field. Composition only ever *unions* it
/// (`policy.meet`), so the base list is the whole of it and
/// `Ctx.grants` is deliberately not consulted here.
///
/// **Writes only, deliberately asymmetric with the jail.** bwrap masks a
/// protected path out of the jail's view entirely, so a jailed process
/// cannot read one either; this check refuses writes and leaves
/// `fs_read` alone. Widening it to reads is a larger change than
/// closing the write hole — `fs_read` of `.git/HEAD` is ordinary and
/// useful work, and the harness-side read of a credential file is a
/// disclosure question the base policy's `readable_roots` should answer
/// — so the narrower fix ships first and the asymmetry is stated rather
/// than glossed.
///
/// **The check is point-in-time, exactly as `resolve_real` is.** The
/// protected entry is tested against where the path led when it was
/// walked; a concurrent workspace mutator can interpose a symlink
/// between this answer and the write that follows it. The window is the
/// same one `resolve_real`'s doc describes and the jail's bwrap masks do
/// not share.
///
/// Public so that anything else in the harness holding write authority
/// over the workspace — a capability bridge servicing `fs.write` for a
/// code-mode program, say — resolves through this function instead of
/// reimplementing half of it. A second implementation is how two
/// enforcement points drift.
pub fn resolve_for_write(ctx: Ctx, path: String) -> Result(String, PathError) {
  resolve_writable(
    filesystem: ctx.filesystem,
    workspace: ctx.workspace,
    protected: ctx.base_policy.protected,
    path:,
  )
}

/// The same boundary with its seams spelled out, for a caller holding
/// write authority but no `Ctx` — the capability bridge's `fs.write` and
/// `fs.edit` closures. One implementation behind both doors: everything
/// `resolve_for_write`'s doc promises is promised here, because it *is*
/// this function.
pub fn resolve_writable(
  filesystem filesystem: FileSystem,
  workspace workspace: String,
  protected protected: List(String),
  path path: String,
) -> Result(String, PathError) {
  use _ <- result.try(all_absolute(protected, path))
  use resolved <- result.try(resolve_real(filesystem:, workspace:, path:))
  case list.find(protected, covers_target(filesystem, _, resolved)) {
    Error(Nil) -> Ok(resolved)
    Ok(entry) -> Error(ProtectedPath(path:, protected: entry))
  }
}

// The `protected` list is checked for absoluteness *before* the target is
// resolved, and a relative entry refuses the write outright.
//
// This fails closed on purpose, and the alternative is what was here
// before: `covers_target` normalizes an entry, `normalize` roots a
// relative one at `/`, and `".git"` therefore became `"/.git"` — an entry
// covering nothing inside any workspace, so every write it was meant to
// refuse went through. The jail does not have this hole: the same policy
// reaches `broker/policy.validate` as a `RelativePath` error and the
// clearance is refused. An operator who writes `protected: [".git"]`
// must not get a jail that refuses and a harness that permits.
//
// Refusing the whole write rather than the one entry is the point: a
// misconfigured list cannot be partially honoured, because what it
// *meant* to cover is exactly what cannot be determined from it.
fn all_absolute(
  protected: List(String),
  path: String,
) -> Result(Nil, PathError) {
  case list.find(protected, fn(entry) { !string.starts_with(entry, "/") }) {
    Error(Nil) -> Ok(Nil)
    Ok(entry) -> Error(ProtectionMisconfigured(path:, protected: entry))
  }
}

// Whether one protected entry covers the resolved write target.
//
// The entry is tested in both its lexical and its real-filesystem
// forms. The lexical form is what the policy itself says and what the
// helper is handed; the resolved form is what a bwrap mask actually
// lands on, since mounting follows symlinks — and the target here is
// already resolved, so comparing it against an unresolved entry would
// miss exactly the case `resolve_real` exists for (a symlinked
// workspace root, say). Where the two agree, which is the ordinary
// case, this is one comparison twice.
//
// The comparison itself is `broker/policy.covers` — the same function
// composition judges roots with and `codemode/launch` judges jail
// reachability by, so these enforcement points cannot drift. It matches
// by path component, which is the whole point: `.gitx/file` merely
// shares a textual prefix with `.git` and is not protected by it.
//
// The entry is known absolute here: `resolve_writable` refuses a
// relative one before this is reached, which is what keeps `normalize`
// from silently rooting `.git` at `/`.
fn covers_target(
  filesystem: FileSystem,
  entry: String,
  resolved: String,
) -> Bool {
  let lexical = normalize(entry)
  let real = walk(filesystem, lexical) |> result.unwrap(or: lexical)
  policy.covers(root: lexical, path: resolved)
  || policy.covers(root: real, path: resolved)
}

// --- fs_read -------------------------------------------------------------

/// The `fs_read` tool: hashline-anchored windowed reads.
pub fn read_tool() -> tool.Tool {
  tool.Tool(
    name: "fs_read",
    description: "Read a text file as anchored lines (line:anchor|text). "
      <> "Use offset/limit to window large files; anchors are what fs_edit "
      <> "hunks must reference, and the details carry the file digest "
      <> "fs_edit requires.",
    schema: tool.object_schema(
      [
        #("path", tool.string_property("file path under the workspace root")),
        #(
          "offset",
          tool.integer_property("1-based first line of the window (default 1)"),
        ),
        #(
          "limit",
          tool.integer_property(
            "maximum lines to return (default "
            <> int.to_string(default_read_lines)
            <> ")",
          ),
        ),
      ],
      ["path"],
    ),
    replay: tool.Safe,
    execution_mode: tool.Concurrent,
    requirements: read_only_requirements,
    run: run_read,
  )
}

fn run_read(ctx: Ctx, args: JsonValue) -> ToolOutcome {
  use path <- tool.with_arg(tool.required_string(args, "path"))
  use offset <- tool.with_arg(tool.optional_int(args, "offset"))
  use limit <- tool.with_arg(tool.optional_int(args, "limit"))
  let offset = option.unwrap(offset, 1)
  let limit = option.unwrap(limit, default_read_lines)
  use <- bool.guard(
    when: offset < 1 || limit < 1,
    return: tool.failure("invalid arguments: offset and limit must be >= 1"),
  )
  use resolved <- tool.or_outcome(
    resolve_real(filesystem: ctx.filesystem, workspace: ctx.workspace, path:),
    path_outcome,
  )
  use content <- tool.or_outcome(read_text(ctx, resolved), identity_outcome)
  read_outcome(path, content, offset, limit)
}

fn read_outcome(
  path: String,
  content: String,
  offset: Int,
  limit: Int,
) -> ToolOutcome {
  let window = hashline.window(content, offset:, limit:)
  let text = case window.lines {
    [] -> empty_window_text(window.total_lines, offset)
    _ -> hashline.render(window)
  }

  // An anchored read must stay inline — anchors in a blob would be
  // useless for planning edits — so an oversized window is refused
  // (spec §3.2 overflow applies to opaque outputs like bash/grep;
  // windowing is fs_read's bounding mechanism).
  use <- bool.guard(
    when: bit_array.byte_size(<<text:utf8>>) > blob.overflow_threshold_bytes,
    return: tool.failure(
      "the requested window renders larger than "
      <> int.to_string(blob.overflow_threshold_bytes)
      <> " bytes; read a smaller window (lower `limit`)",
    ),
  )
  tool.success(text)
  |> tool.with_details(
    json.Object([
      #("path", json.String(path)),
      #("offset", json.Int(window.offset)),
      #("limit", json.Int(limit)),
      #("total_lines", json.Int(window.total_lines)),
      #("has_more", json.Bool(window.has_more)),
      #("trailing_newline", json.Bool(window.trailing_newline)),
      #("digest", json.String(hashline.digest(content))),
      #("anchor_version", json.Int(hashline.anchor_version)),
    ]),
  )
}

// The message for a window with no lines in it: an empty file reads
// differently from an offset past the end of a non-empty one.
fn empty_window_text(total_lines: Int, offset: Int) -> String {
  case total_lines {
    0 -> "(empty file)"
    total ->
      "(no lines at offset "
      <> int.to_string(offset)
      <> "; the file has "
      <> int.to_string(total)
      <> " lines)"
  }
}

// `read_text` already renders its failure as a `ToolOutcome`, so
// chaining it through `tool.or_outcome` needs no mapping.
fn identity_outcome(outcome: ToolOutcome) -> ToolOutcome {
  outcome
}

/// Why a resolved path did not yield text. The structured half of what
/// `read_text` renders as prose.
///
/// Split out so a caller that is not a tool — the code-mode capability
/// bridge answering `cap/fs.read`, which owes a program a typed error
/// rather than a sentence — reaches the same three decisions without
/// re-deriving any of them. The tools themselves go on rendering these
/// through `read_error_outcome`, which is where the wording lives.
pub type ReadError {
  /// The `FileSystem` seam refused the read.
  ReadFailed(error: FsError)

  /// The file is larger than `max_read_bytes` (the large-file guard).
  TooLarge(size: Int, limit: Int)

  /// The file's bytes are not valid UTF-8, so there is no text to
  /// return.
  NotText
}

/// Reads a resolved path as text, subject to the large-file guard.
///
/// **`resolved` must already have come out of `resolve_real`.** This
/// function performs no path discipline of its own — it takes a path
/// that has been resolved against the real filesystem and checked under
/// the workspace root, and reads it. Handing it an unresolved path
/// reintroduces exactly the symlink hole `resolve_real` closes, which is
/// why the harness-side callers all pass its output straight through.
///
/// ## Examples
///
/// ```gleam
/// // fs.read_text_file(filesystem, resolved) == Ok("hello\n")
/// ```
///
pub fn read_text_file(
  filesystem filesystem: FileSystem,
  resolved resolved: String,
) -> Result(String, ReadError) {
  use bytes <- result.try(
    filesystem.read(resolved) |> result.map_error(ReadFailed),
  )
  let size = bit_array.byte_size(bytes)
  use <- bool.guard(
    when: size > max_read_bytes,
    return: Error(TooLarge(size:, limit: max_read_bytes)),
  )
  bit_array.to_string(bytes) |> result.replace_error(NotText)
}

// Reads and decodes a file for the text tools; failures are in-band
// outcomes.
fn read_text(ctx: Ctx, resolved: String) -> Result(String, ToolOutcome) {
  read_text_file(filesystem: ctx.filesystem, resolved:)
  |> result.map_error(read_error_outcome)
}

// The prose the text tools have always answered a failed read with, one
// sentence per `ReadError`. Extracting the decision above left the
// wording here, unchanged, so a model reads what it read before.
fn read_error_outcome(error: ReadError) -> ToolOutcome {
  case error {
    ReadFailed(error:) -> fs_error_outcome(error)
    TooLarge(size: _, limit:) ->
      tool.failure(
        "file is larger than "
        <> int.to_string(limit)
        <> " bytes; read it in pieces with the bash tool instead",
      )
    NotText ->
      tool.failure(
        "file is not valid UTF-8 text; use the bash tool for binary files",
      )
  }
}

// --- fs_write ------------------------------------------------------------

/// The `fs_write` tool: create or replace a whole file.
pub fn write_tool() -> tool.Tool {
  tool.Tool(
    name: "fs_write",
    description: "Create or overwrite a whole file with the given content. "
      <> "Parent directories are created as needed.",
    schema: tool.object_schema(
      [
        #("path", tool.string_property("file path under the workspace root")),
        #("content", tool.string_property("the complete new file content")),
      ],
      ["path", "content"],
    ),
    replay: tool.Safe,
    execution_mode: tool.Exclusive,
    requirements: workspace_requirements,
    run: run_write,
  )
}

fn run_write(ctx: Ctx, args: JsonValue) -> ToolOutcome {
  use path <- tool.with_arg(tool.required_string(args, "path"))
  use content <- tool.with_arg(tool.required_string(args, "content"))
  use resolved <- tool.or_outcome(resolve_for_write(ctx, path), path_outcome)
  let bytes = <<content:utf8>>
  use Nil <- tool.or_outcome(
    write_whole(filesystem: ctx.filesystem, resolved:, bytes:),
    fs_error_outcome,
  )
  write_outcome(path, bytes)
}

/// Creates any missing parent directories, then writes the whole file —
/// the two-step seam operation a whole-file write needs from a resolved
/// path.
///
/// **`resolved` must already have come out of `resolve_for_write` or
/// `resolve_writable`.** This performs no path discipline and no
/// protected-path check of its own; it is the write half only.
///
/// Public for the reason `resolve_writable` is: the capability bridge's
/// `fs.write` closure serves the same contract as `fs_write` and must
/// create parents the same way. Two doors onto one workspace that
/// disagree about whether `new_dir/file.txt` needs an existing `new_dir`
/// is a difference a program discovers by failing.
///
/// ## Examples
///
/// ```gleam
/// // fs.write_whole(filesystem:, resolved: "/work/a/b.txt", bytes: <<>>)
/// ```
///
pub fn write_whole(
  filesystem filesystem: FileSystem,
  resolved resolved: String,
  bytes bytes: BitArray,
) -> Result(Nil, FsError) {
  use Nil <- result.try(
    filesystem.create_directory_all(parent_directory(resolved)),
  )
  filesystem.write(resolved, bytes)
}

fn write_outcome(path: String, bytes: BitArray) -> ToolOutcome {
  tool.success(
    "wrote "
    <> int.to_string(bit_array.byte_size(bytes))
    <> " bytes to "
    <> path,
  )
  |> tool.with_details(
    json.Object([
      #("path", json.String(path)),
      #("bytes", json.Int(bit_array.byte_size(bytes))),
    ]),
  )
}

// The directory part of an absolute path ("/" for top-level entries).
fn parent_directory(path: String) -> String {
  case string.split(path, on: "/") |> list.reverse {
    [_name, ..rest] ->
      case list.reverse(rest) |> string.join(with: "/") {
        "" -> "/"
        parent -> parent
      }
    [] -> "/"
  }
}

// --- fs_edit -------------------------------------------------------------

/// The `fs_edit` tool: anchor-checked multi-hunk edits.
pub fn edit_tool() -> tool.Tool {
  tool.Tool(
    name: "fs_edit",
    description: "Apply anchored edit hunks to a file. Pass the digest from "
      <> "fs_read's details; each hunk references lines by the {line, anchor} "
      <> "pairs from fs_read. A stale anchor or a changed file rejects the "
      <> "whole edit and returns fresh anchors and the fresh digest.",
    schema: edit_schema(),
    replay: tool.Safe,
    execution_mode: tool.Exclusive,
    requirements: workspace_requirements,
    run: run_edit,
  )
}

// The `op` enum schema, naming the four hunk operations `fs_edit` accepts.
fn hunk_op_schema() -> JsonValue {
  json.Object([
    #("type", json.String("string")),
    #(
      "enum",
      json.Array([
        json.String("replace"),
        json.String("delete"),
        json.String("insert_after"),
        json.String("insert_at_start"),
      ]),
    ),
  ])
}

// The `hunks` array schema: the per-hunk item schema plus the note that
// every hunk is checked before any is applied.
fn hunks_schema(hunk: JsonValue) -> JsonValue {
  json.Object([
    #("type", json.String("array")),
    #("items", hunk),
    #(
      "description",
      json.String(
        "edit hunks; all anchors and the digest are checked before "
        <> "any hunk is applied",
      ),
    ),
  ])
}

fn edit_schema() -> JsonValue {
  let anchor_ref =
    tool.object_schema(
      [
        #("line", tool.integer_property("1-based line number from fs_read")),
        #("anchor", tool.string_property("the line's anchor from fs_read")),
      ],
      ["line", "anchor"],
    )
  let hunk =
    json.Object([
      #("type", json.String("object")),
      #(
        "properties",
        json.Object([
          #("op", hunk_op_schema()),
          #("from", anchor_ref),
          #("to", anchor_ref),
          #("at", anchor_ref),
          #(
            "lines",
            tool.string_array_property("replacement lines, without newlines"),
          ),
        ]),
      ),
      #("required", json.Array([json.String("op")])),
    ])
  json.Object([
    #("type", json.String("object")),
    #(
      "properties",
      json.Object([
        #("path", tool.string_property("file path under the workspace root")),
        #(
          "digest",
          tool.string_property(
            "the file digest from fs_read's details; the edit applies only "
            <> "if the file is still exactly that content",
          ),
        ),
        #("hunks", hunks_schema(hunk)),
      ]),
    ),
    #(
      "required",
      json.Array([
        json.String("path"),
        json.String("digest"),
        json.String("hunks"),
      ]),
    ),
    #("additionalProperties", json.Bool(False)),
  ])
}

fn run_edit(ctx: Ctx, args: JsonValue) -> ToolOutcome {
  use path <- tool.with_arg(tool.required_string(args, "path"))
  use digest <- tool.with_arg(tool.required_string(args, "digest"))
  use hunks <- tool.with_arg(decode_hunks(args))
  use resolved <- tool.or_outcome(resolve_for_write(ctx, path), path_outcome)
  use content <- tool.or_outcome(read_text(ctx, resolved), identity_outcome)
  use edited <- tool.or_outcome(
    hashline.apply(content, hashline.Plan(digest:, hunks:)),
    apply_error_outcome,
  )
  use Nil <- tool.or_outcome(
    ctx.filesystem.write(resolved, <<edited:utf8>>),
    fs_error_outcome,
  )
  edit_outcome(path, hunks, edited)
}

fn edit_outcome(
  path: String,
  hunks: List(hashline.Hunk),
  edited: String,
) -> ToolOutcome {
  let total_lines = list.length(hashline.split_lines(edited).lines)
  tool.success(
    "applied " <> int.to_string(list.length(hunks)) <> " hunk(s) to " <> path,
  )
  |> tool.with_details(
    json.Object([
      #("path", json.String(path)),
      #("hunks_applied", json.Int(list.length(hunks))),
      #("total_lines", json.Int(total_lines)),
      #("digest", json.String(hashline.digest(edited))),
      #("anchor_version", json.Int(hashline.anchor_version)),
    ]),
  )
}

fn decode_hunks(args: JsonValue) -> Result(List(hashline.Hunk), String) {
  case object_field(args, "hunks") {
    Ok(json.Array(items)) ->
      case items {
        [] -> Error("`hunks` must not be empty")
        _ -> list.try_map(items, decode_hunk)
      }
    Ok(_) -> Error("`hunks` must be an array")
    Error(Nil) -> Error("`hunks` is required")
  }
}

fn decode_hunk(value: JsonValue) -> Result(hashline.Hunk, String) {
  use op <- result.try(tool.required_string(value, "op"))
  case op {
    "replace" -> {
      use from <- result.try(decode_ref(value, "from"))
      use to <- result.try(decode_ref(value, "to"))
      use lines <- result.try(required_lines(value))
      Ok(hashline.Replace(from:, to:, lines:))
    }
    "delete" -> {
      use from <- result.try(decode_ref(value, "from"))
      use to <- result.try(decode_ref(value, "to"))
      Ok(hashline.Delete(from:, to:))
    }
    "insert_after" -> {
      use at <- result.try(decode_ref(value, "at"))
      use lines <- result.try(required_lines(value))
      Ok(hashline.InsertAfter(at:, lines:))
    }
    "insert_at_start" -> {
      use lines <- result.try(required_lines(value))
      Ok(hashline.InsertAtStart(lines:))
    }
    other ->
      Error(
        "unknown hunk op `"
        <> other
        <> "` (expected replace, delete, insert_after, or insert_at_start)",
      )
  }
}

fn decode_ref(value: JsonValue, key: String) -> Result(hashline.Ref, String) {
  case object_field(value, key) {
    Error(Nil) -> Error("`" <> key <> "` is required for this hunk op")
    Ok(ref_value) -> {
      use line <- result.try(
        require(tool.optional_int(ref_value, "line"), when_absent: fn() {
          "`" <> key <> ".line` is required"
        }),
      )
      use anchor <- result.try(tool.required_string(ref_value, "anchor"))
      Ok(hashline.Ref(line:, anchor:))
    }
  }
}

fn required_lines(value: JsonValue) -> Result(List(String), String) {
  require(tool.optional_string_list(value, "lines"), when_absent: fn() {
    "`lines` is required for this hunk op"
  })
}

// Turns "optional, and possibly malformed" into "required, for this
// hunk op" — the shape every `tool.optional_*` decoder returns, and
// the one `decode_ref`'s line field and `required_lines` both need.
//
// `when_absent` is a thunk, not a bare `String`: `decode_ref` calls this
// once per hunk-ref of every `fs_edit`, and an eager `String` would build
// its message on every one of those calls whether the field turned out to
// be absent or not (issue #56, the same hazard R1's `bool.guard`/
// `result.unwrap` table already knows by name). Called only from the one
// branch that needs it.
fn require(
  optional: Result(Option(a), String),
  when_absent when_absent: fn() -> String,
) -> Result(a, String) {
  case optional {
    Ok(Some(value)) -> Ok(value)
    Ok(None) -> Error(when_absent())
    Error(reason) -> Error(reason)
  }
}

fn apply_error_outcome(error: hashline.ApplyError) -> ToolOutcome {
  case error {
    hashline.MalformedPlan(reason:) ->
      tool.failure("invalid edit plan: " <> reason)
    hashline.OverlappingHunks(line:) ->
      tool.failure(
        "invalid edit plan: hunks overlap at line " <> int.to_string(line),
      )
    hashline.StaleAnchors(stale:) -> {
      let regions =
        stale
        |> list.map(stale_region_text)
        |> string.join(with: "\n")
      tool.failure(
        "stale anchors: the file changed since it was read; re-plan against "
        <> "these fresh anchors\n"
        <> regions,
      )
      |> tool.with_details(
        json.Object([
          #("error", json.String("stale_anchors")),
          #("stale", json.Array(list.map(stale, encode_stale_entry))),
          #("anchor_version", json.Int(hashline.anchor_version)),
        ]),
      )
    }
    hashline.StaleContent(digest:, fresh:) ->
      tool.failure(
        "stale content: the file is no longer the exact content this edit "
        <> "was planned against (or the edit already applied); re-plan "
        <> "against digest "
        <> digest
        <> " and these fresh anchors\n"
        <> fresh_lines_text(fresh),
      )
      |> tool.with_details(
        json.Object([
          #("error", json.String("stale_content")),
          #("digest", json.String(digest)),
          #("fresh", json.Array(list.map(fresh, encode_anchored_line))),
          #("anchor_version", json.Int(hashline.anchor_version)),
        ]),
      )
  }
}

// The rendered text of one stale hunk's fresh replacement lines,
// shared by the `StaleAnchors` and `StaleContent` repair messages.
fn fresh_lines_text(fresh: List(hashline.AnchoredLine)) -> String {
  fresh
  |> list.map(hashline.render_line)
  |> string.join(with: "\n")
}

// The repair message for one stale hunk: where it was expected, and
// the fresh anchors to re-plan against.
fn stale_region_text(entry: hashline.Stale) -> String {
  "line "
  <> int.to_string(entry.line)
  <> " (expected "
  <> entry.expected
  <> "):\n"
  <> fresh_lines_text(entry.fresh)
}

fn encode_anchored_line(anchored: hashline.AnchoredLine) -> JsonValue {
  json.Object([
    #("line", json.Int(anchored.line)),
    #("anchor", json.String(anchored.anchor)),
    #("text", json.String(anchored.text)),
  ])
}

fn encode_stale_entry(entry: hashline.Stale) -> JsonValue {
  json.Object([
    #("line", json.Int(entry.line)),
    #("expected_anchor", json.String(entry.expected)),
    #("fresh", json.Array(list.map(entry.fresh, encode_anchored_line))),
  ])
}

// --- shared plumbing -----------------------------------------------------

// First occurrence of a field in a JSON object.
fn object_field(value: JsonValue, key: String) -> Result(JsonValue, Nil) {
  case value {
    json.Object(fields:) ->
      list.find_map(fields, fn(entry) {
        case entry.0 == key {
          True -> Ok(entry.1)
          False -> Error(Nil)
        }
      })
    _ -> Error(Nil)
  }
}

/// Renders a `PathError` as the in-band failure result the model reads.
/// Shared with `tools/grep`, whose lexical `resolve_path` fails the same
/// way for the same reasons (it never produces `ProtectedPath`: only a
/// write path is checked against `protected`).
///
/// A `ProtectedPath` refusal opens with `permission denied:`, the same
/// wording `FsPermissionDenied` carries, so anything mapping these
/// outcomes onto a capability code lands on the policy-denial one; it
/// then names the entry that matched, and repeats both facts in
/// `details` under `error: "protected_path"` so a caller need not parse
/// prose.
pub fn path_outcome(error: PathError) -> ToolOutcome {
  case error {
    EmptyPath -> tool.failure("invalid arguments: `path` must not be empty")
    EscapesWorkspace(path:) ->
      tool.failure("path `" <> path <> "` resolves outside the workspace root")
    Unresolvable(path:, reason:) ->
      tool.failure("path `" <> path <> "` could not be resolved: " <> reason)
    ProtectedPath(path:, protected:) ->
      tool.failure(
        "permission denied: `"
        <> path
        <> "` resolves at or under the protected path `"
        <> protected
        <> "`, which is never writable — no approval or grant widens it",
      )
      |> tool.with_details(
        json.Object([
          #("error", json.String("protected_path")),
          #("path", json.String(path)),
          #("protected", json.String(protected)),
        ]),
      )
    ProtectionMisconfigured(path:, protected:) ->
      tool.failure(
        "permission denied: `"
        <> path
        <> "` was not written because this session's protected-path list "
        <> "is misconfigured — the entry `"
        <> protected
        <> "` is not absolute, so nothing can be judged against it. Ask "
        <> "the operator to fix the session's base policy; no approval or "
        <> "grant widens this.",
      )
      |> tool.with_details(
        json.Object([
          #("error", json.String("protection_misconfigured")),
          #("path", json.String(path)),
          #("protected", json.String(protected)),
        ]),
      )
  }
}

fn fs_error_outcome(error: FsError) -> ToolOutcome {
  case error {
    tool.FsNotFound(path:) -> tool.failure("file not found: " <> path)
    tool.FsPermissionDenied(path:) ->
      tool.failure("permission denied: " <> path)
    tool.FsFailure(path:, reason:) ->
      tool.failure("filesystem error on " <> path <> ": " <> reason)
  }
}

// Read-only tools ask for exactly a readable workspace; write tools ask
// for a writable one. The fs tools run harness-side and never dispatch
// through the broker, but the declaration still states their needs in
// the policy vocabulary for uniform inspection.
fn read_only_requirements(workspace: String) -> policy.SandboxPolicy {
  tool.read_requirements(workspace)
}

fn workspace_requirements(workspace: String) -> policy.SandboxPolicy {
  tool.write_requirements(workspace)
}
