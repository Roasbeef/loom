//// Adopts the blobs an earlier release kept inside the workspace.
////
//// Content-addressed artifacts (oversized tool output, code-mode emits and
//// job output) used to live in `<workspace>/.blobs`. The store now sits in
//// the daemon's own state (`client/codemode.blob_directory`), outside every
//// jail, so a workspace that has been used before holds artifacts the
//// transcript still names by id and that the new store does not have.
//// This module copies them across.
////
//// ## Flow
////
//// 1. `adopt_legacy` is called by `client/serve` while a session's
////    directories are prepared, after the new store exists and before any
////    tool can run.
//// 2. `adopt` first looks at `<workspace>/.blobs` itself with `link_info`,
////    which does not follow a link, and goes on only if it is a real
////    directory. `adopt_directory` then lists it and keeps the names
////    `is_address` accepts: `sha256-` and 64 lowercase hex digits, each checked by
////    `is_lower_hex`. Staging files, the old `.gitignore` and anything else
////    a person left there are not addresses and are never touched.
//// 3. `adopting` walks those names one at a time, and `one` skips a name
////    the new store already holds, so a second run copies and hashes
////    nothing.
//// 4. `copy` handles any other name. It must be a regular file of bounded
////    size whose SHA-256 equals its name. Only then are the bytes written to
////    the new store through `tools/blob.write_addressed`, which stages and
////    renames under a name `staging_tag` makes unique to that write.
//// 5. `adopting` stops at the deadline and reports how many names it left.
////    The next session start continues from there.
////
//// The legacy directory is never modified. It stops being protected when
//// the store moves, so a jailed tool can now write into it. That is why the
//// content check is not optional: a name proves nothing about the bytes
//// behind it, and a file whose digest differs from its name is skipped and
//// logged rather than copied. A symbolic link, a FIFO or a device is skipped
//// for the same reason, since reading one could block the session or leak a
//// file that was never an artifact.
////
//// The same writability is why `.blobs` itself is checked. A jailed tool can
//// replace the directory with a link to another workspace's store, whose
//// files hash to their own names and would pass every per-file check. Only
//// a real directory is listed; a link, or anything else, is refused and
//// logged.
////
//// There is no fallback read of the legacy directory after this step. The
//// new store is the only one the harness resolves ids against.

import client/codemode
import client/internal/ffi_os
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import simplifile
import telemetry/field
import telemetry/log.{type Logger}
import tools/blob
import tools/fs
import tools/tool.{type FileSystem}

/// The longest a single adoption pass runs before it stops and leaves the
/// rest for the next session start.
pub const adoption_budget_ms = 5000

/// The largest legacy file this module reads into memory. A blob over this
/// size is skipped and logged, not copied.
pub const max_adopted_bytes = 268_435_456

// The shape of an address, `tools/blob.ref_for`'s output: the label and the
// 64 hex digits of a SHA-256.
const address_prefix = "sha256-"

const address_prefix_length = 7

const digest_length = 64

/// What one adoption pass did.
pub type Report {
  Report(
    /// Names copied into the new store after their content was verified.
    adopted: Int,
    /// Names the new store already held, so nothing was read or written.
    already_present: Int,
    /// Names that were not copied, each with the reason.
    rejected: List(Rejection),
    /// Address-shaped names the pass did not reach before its deadline.
    unfinished: Int,
  )
}

/// One legacy entry that was not adopted.
pub type Rejection {
  Rejection(
    /// The entry's name in the legacy directory.
    name: String,
    /// Why it was left behind.
    reason: String,
  )
}

/// Adopts the legacy blobs of `workspace` into `store`, logging what it
/// did. A workspace with no legacy directory is the ordinary case and logs
/// nothing.
///
/// ## Examples
///
/// ```gleam
/// // blobs.adopt_legacy("/work", "/state/workspaces/ab12/blobs", logger)
/// ```
///
pub fn adopt_legacy(
  workspace workspace: String,
  into store: String,
  logger logger: Logger,
) -> Nil {
  let report =
    adopt(
      legacy: legacy_directory(workspace),
      into: store,
      filesystem: fs.real_filesystem(),
      within_ms: adoption_budget_ms,
      now: ffi_os.system_time_ms,
    )
  report_to(logger, report)
}

/// Where earlier releases kept the blob store for a workspace.
///
/// ## Examples
///
/// ```gleam
/// assert blobs.legacy_directory("/work") == "/work/.blobs"
/// ```
///
pub fn legacy_directory(workspace: String) -> String {
  workspace <> "/" <> codemode.legacy_blob_directory
}

/// Copies every verifiable address-shaped file from `legacy` into `store`,
/// stopping once `within_ms` has elapsed on `now`.
///
/// `now` and `filesystem` are arguments so a test can run the pass against a
/// clock it controls. The pass is idempotent: a name already in `store` is
/// counted, not rewritten.
///
/// ## Examples
///
/// ```gleam
/// // blobs.adopt(legacy:, into: store, filesystem:, within_ms: 5000, now:)
/// //   // -> Report(adopted: 3, already_present: 0, rejected: [], unfinished: 0)
/// ```
///
pub fn adopt(
  legacy legacy: String,
  into store: String,
  filesystem filesystem: FileSystem,
  within_ms budget: Int,
  now now: fn() -> Int,
) -> Report {
  let empty =
    Report(adopted: 0, already_present: 0, rejected: [], unfinished: 0)

  // `link_info` does not follow a link, so a `.blobs` that a jailed tool
  // replaced with a link to somewhere else is seen as a link. An absent
  // directory is the ordinary case and says nothing.
  case simplifile.link_info(legacy) {
    Error(_) -> empty
    Ok(info) ->
      case simplifile.file_info_type(info) {
        simplifile.Directory ->
          adopt_directory(legacy, store, filesystem, budget, now, empty)
        simplifile.File | simplifile.Symlink | simplifile.Other ->
          Report(..empty, rejected: [
            Rejection(
              name: legacy,
              reason: "it is not a real directory, so it was not read",
            ),
          ])
      }
  }
}

fn adopt_directory(
  legacy: String,
  store: String,
  filesystem: FileSystem,
  budget: Int,
  now: fn() -> Int,
  empty: Report,
) -> Report {
  let names = case simplifile.read_directory(legacy) {
    Ok(names) -> list.filter(names, is_address) |> list.sort(string.compare)
    Error(_) -> []
  }
  case names {
    [] -> empty
    _ ->
      case filesystem.create_directory_all(store) {
        Ok(Nil) -> {
          let pass =
            Pass(legacy:, store:, filesystem:, deadline: now() + budget, now:)
          adopting(names, pass, empty)
        }
        Error(error) ->
          Report(
            ..empty,
            rejected: list.map(names, fn(name) {
              Rejection(
                name:,
                reason: "the new store is unusable: " <> fs_text(error),
              )
            }),
          )
      }
  }
}

// What stays fixed while the loop walks the names: both directories, the
// filesystem seam, and the instant the pass must stop at.
type Pass {
  Pass(
    legacy: String,
    store: String,
    filesystem: FileSystem,
    deadline: Int,
    now: fn() -> Int,
  )
}

// One name at a time, with the deadline checked before each. The names that
// remain when it passes are counted rather than examined, because a
// directory of many large blobs on a slow disk is the case the deadline
// exists for.
fn adopting(names: List(String), pass: Pass, report: Report) -> Report {
  case names {
    [] -> report
    [name, ..rest] ->
      case pass.now() >= pass.deadline {
        True -> Report(..report, unfinished: list.length(names))
        False -> adopting(rest, pass, one(name, pass, report))
      }
  }
}

fn one(name: String, pass: Pass, report: Report) -> Report {
  let target = blob.ref_path(pass.store, name)
  case pass.filesystem.is_file(target) {
    Ok(True) -> Report(..report, already_present: report.already_present + 1)
    Ok(False) | Error(_) ->
      case copy(name, target, pass) {
        Ok(Nil) -> Report(..report, adopted: report.adopted + 1)
        Error(reason) ->
          Report(..report, rejected: [
            Rejection(name:, reason:),
            ..report.rejected
          ])
      }
  }
}

// Reads one legacy file, proves it is the content its name claims, and
// writes it through the store's own staged rename.
//
// The type and size are read with `link_info`, which does not follow a
// link, so a planted symbolic link is refused instead of being read. The
// digest comparison is what makes the copy safe: the legacy directory is
// writable by jailed tools now, and only bytes that hash to their own name
// can be an artifact.
fn copy(name: String, target: String, pass: Pass) -> Result(Nil, String) {
  let source = blob.ref_path(pass.legacy, name)
  use info <- result.try(
    simplifile.link_info(source)
    |> result.map_error(fn(error) {
      "unreadable: " <> simplifile.describe_error(error)
    }),
  )
  use Nil <- result.try(regular_and_bounded(info))
  use bytes <- result.try(
    pass.filesystem.read(source)
    |> result.map_error(fn(error) { "unreadable: " <> fs_text(error) }),
  )
  use Nil <- result.try(case blob.ref_for(bytes) == name {
    True -> Ok(Nil)
    False -> Error("its content does not hash to its name")
  })
  blob.write_addressed(
    filesystem: pass.filesystem,
    path: target,
    temporary: blob.temp_path(pass.store, name, staging_tag()),
    bytes:,
  )
  |> result.map_error(fn(error) { "not written: " <> fs_text(error) })
}

fn regular_and_bounded(info: simplifile.FileInfo) -> Result(Nil, String) {
  case simplifile.file_info_type(info) {
    simplifile.File ->
      case info.size > max_adopted_bytes {
        True ->
          Error("larger than " <> int.to_string(max_adopted_bytes) <> " bytes")
        False -> Ok(Nil)
      }
    simplifile.Directory | simplifile.Symlink | simplifile.Other ->
      Error("not a regular file")
  }
}

// A name unique to one staging write, so two sessions adopting the same
// directory at once cannot rename each other's half-written file into
// place.
fn staging_tag() -> String {
  "adopt-"
  <> int.to_string(ffi_os.system_time_ms())
  <> "-"
  <> int.to_string(ffi_os.unique_positive_integer())
}

// Whether a directory entry is shaped like an address: `sha256-` followed
// by exactly 64 lowercase hex digits. Staging names begin with a dot and
// are excluded by the prefix alone.
//
// The length is asked as two bounded questions, since dropping the first
// 63 characters leaves something only if there are at least 64, and
// dropping 64 leaves nothing only if there are at most 64.
fn is_address(name: String) -> Bool {
  let digits = string.drop_start(name, address_prefix_length)
  string.starts_with(name, address_prefix)
  && string.drop_start(digits, digest_length - 1) != ""
  && string.drop_start(digits, digest_length) == ""
  && list.all(string.to_graphemes(digits), is_lower_hex)
}

fn is_lower_hex(character: String) -> Bool {
  string.contains("0123456789abcdef", character)
}

fn fs_text(error: tool.FsError) -> String {
  case error {
    tool.FsNotFound(path:) -> "missing: " <> path
    tool.FsPermissionDenied(path:) -> "permission denied: " <> path
    tool.FsFailure(path:, reason:) -> path <> ": " <> reason
  }
}

fn report_to(logger: Logger, report: Report) -> Nil {
  list.each(report.rejected, fn(rejection) {
    log.warn(logger, "blobs.legacy_skipped", [
      field.text(key: "name", value: rejection.name),
      field.text(key: "reason", value: rejection.reason),
    ])
  })
  case report.adopted > 0 || report.unfinished > 0 {
    True ->
      log.info(logger, "blobs.legacy_adopted", [
        field.count(key: "adopted", value: report.adopted),
        field.count(key: "already_present", value: report.already_present),
        field.count(key: "skipped", value: list.length(report.rejected)),
        field.count(key: "unfinished", value: report.unfinished),
      ])
    False -> Nil
  }
}
