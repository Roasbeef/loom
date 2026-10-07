//// The Go caches a session's jailed tools use, kept outside the checkout.
////
//// A jailed tool's `HOME` is a directory under the workspace, so Go's
//// default caches (`$HOME/Library/Caches/go-build` on macOS,
//// `$HOME/.cache/go-build` elsewhere, and `$HOME/go/pkg/mod`) landed inside
//// the operator's checkout. One checkout measured 20 GB of build cache and
//// 2.4 GB of module cache there. They bloated the repository (a Docker
//// build context reached 23 GB), nothing ever trimmed them by size, and
//// every module was downloaded again although the operator's host module
//// cache already held it.
////
//// This module moves them. Each workspace gets one directory, `root`, at
//// `<cache>/loom/workspace/<digest>`, where `<cache>` is the per-user cache
//// directory the language-server caches use (`profile.cache_place`) and
//// `<digest>` is the SHA-256 of the workspace path. Sessions in one
//// workspace share it and different workspaces never do. The jail's
//// `GOCACHE`, `GOMODCACHE` and `GOLANGCI_LINT_CACHE` point beneath it, and
//// the directory is a writable root of the session base, granted the way a
//// linked worktree's git directories are.
////
//// ## The build cache is never the host's
////
//// `go build` trusts what it finds in `GOCACHE`: an entry is keyed by a
//// hash of its inputs, and nothing re-verifies that the stored output
//// matches them. A jailed tool that can write the operator's own build
//// cache can therefore plant an object file that the operator's next
//// unjailed `go build` links into a binary. The jail's cache is private for
//// the same reason the language servers' caches are (ADR-016). The module
//// cache is safer, since downloaded modules are checked against `go.sum`,
//// but it is private too, so one rule covers both and the host's module
//// directory stays read-only.
////
//// ## The host module cache as a mirror
////
//// `go_module_mirror` names the operator's module cache. Its
//// `cache/download` directory is already laid out as a module proxy, so it
//// is mounted read-only and named first in `GOPROXY` as a `file://` URL,
//// with the public proxy after it. Go falls through to the next entry when
//// a module is not found. A module taken from the mirror is still verified
//// against `go.sum` and the checksum database, and is extracted into the
//// private module cache. The mirror is never writable from the jail.
////
//// ## Trimming
////
//// Go removes build-cache entries unused for about five days and has no size
//// limit, so a busy workspace grows without bound. When a session starts,
//// a weft task measures the build cache and, over the configured limit,
//// renames it out of `root` to `<root>.trash-<unique>`, a sibling in the
//// parent directory, creates an empty replacement and deletes the renamed
//// tree.
////
//// The rename is the point. Another session in the same workspace may be
//// building against the cache while it is retired. Deleting the directory
//// in place would make that build fail on entries disappearing in the
//// middle of its work. A rename is one atomic operation on the same
//// filesystem: a process that opens a path afterwards sees the empty
//// replacement, and a process that already holds a file open keeps reading
//// it, since the unlinked data lives until the last descriptor closes. The
//// replacement is a bare directory that Go fills in at its next open, made
//// with a non-recursive `mkdir` so a link planted at that path is not
//// followed. A build that held the old cache open, or that wrote an entry
//// before the rename and reads it back by path after it, finds nothing
//// there. It fails once with a missing-file error and a retry clears it.
//// The trim runs only when the cache is already over its limit at a session
//// start, which keeps the case rare.
////
//// Deletion is the slow part (a large cache is hundreds of thousands of
//// files), so it runs in a weft task off the session's critical path. It is
//// resumable by construction: a task cut short leaves a `<digest>.trash-`
//// directory that the next session's sweep removes.
////
//// The retired tree leaves `root` before anything deletes it, because
//// `root` is writable from the jail and `file:del_dir_r` is path based: it
//// checks an entry, lists it and recurses by joined path, so a jailed
//// process could swap a directory for a link between the check and the
//// listing and the unjailed daemon would delete the link's target. The
//// parent of `root` is not writable from the jail, so a tree renamed there
//// is out of the jail's reach, and the sweep lists the parent and never
//// reads inside `root`. `rename(2)` moves a planted link instead of
//// following it. One residual remains: a jailed process that held a
//// directory descriptor inside `go-build` across the rename can still
//// modify the retired tree while it is deleted, which can fail or skip
//// part of the deletion but cannot redirect it, since the tree is no longer
//// reachable through any path the jail can write. Only the build cache is
//// trimmed: module-cache files are read-only by Go's design,
//// the set is bounded by the dependency graph, and the mirror refills it.

import broker/policy
import client/internal/ffi_os
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import simplifile
import telemetry/field
import telemetry/log.{type Logger}
import weft

/// One workspace's private Go caches.
pub type GoCaches {
  GoCaches(
    /// The workspace's directory, `<cache>/loom/workspace/<digest>`, a
    /// writable root of the session base.
    root: String,
    /// The operator's module cache, validated at boot by `mirror_fault`.
    mirror: Option(String),
    /// The build cache size, in KiB, above which `trim` retires it.
    limit_kib: Int,
  )
}

/// What a trim decided.
pub type Trimmed {
  /// The build cache is at or below the limit and was left alone.
  Within(
    /// The measured size in KiB.
    size_kib: Int,
  )

  /// The build cache was over the limit, renamed away and replaced.
  Retired(
    /// The measured size in KiB before the rename.
    size_kib: Int,
    /// Where the old tree now waits for deletion.
    trash: String,
  )
}

/// The public proxy chain `GOPROXY` falls back to after the mirror.
pub const fallback_proxy = "https://proxy.golang.org,direct"

/// The infix of a retired build cache's directory name: the sibling of
/// `root` named `<digest>.trash-<unique>`.
const trash_infix = ".trash-"

/// How long the whole maintenance task may run before weft cancels it. A
/// cancelled sweep resumes at the next session start, so this bounds a
/// wedged disk rather than a slow delete.
const maintenance_deadline_ms = 900_000

/// How long one `du` may run before it is killed.
const measure_timeout_ms = 300_000

/// Locates the caches of `workspace`, or `None` when the daemon has no
/// per-user cache directory to put them in. In that case the jail keeps
/// the old behaviour and Go writes under the tool `HOME`.
///
/// The workspace path is hashed without a trailing slash, so the two
/// spellings of one directory share one root. The digest is the same
/// SHA-256 hex `serve.workspace_data_root` computes.
///
/// `None` also when the workspace covers the cache place (a workspace of
/// `$HOME`, or an `XDG_CACHE_HOME` under it). The root would then sit inside
/// a tree the jail writes, so the jail could replace it with a link and
/// the daemon's host-side operations on it would follow. Such a session
/// keeps the old behaviour.
///
/// ## Examples
///
/// ```gleam
/// let assert Some(caches) =
///   gocache.locate(Some("/home/o/.cache"), "/work", None, 10_240)
/// assert string.starts_with(caches.root, "/home/o/.cache/loom/workspace/")
/// ```
///
pub fn locate(
  cache: Option(String),
  workspace: String,
  mirror: Option(String),
  limit_mib: Int,
) -> Option(GoCaches) {
  let workspace = strip_trailing_slash(workspace)
  option.map(cache, strip_trailing_slash)
  |> option.then(fn(place) {
    case policy.covers(root: workspace, path: place) {
      True -> None
      False ->
        Some(GoCaches(
          root: place <> "/loom/workspace/" <> workspace_digest(workspace),
          mirror:,
          limit_kib: limit_mib * 1024,
        ))
    }
  })
}

fn strip_trailing_slash(path: String) -> String {
  case string.ends_with(path, "/") {
    True -> strip_trailing_slash(string.drop_end(path, 1))
    False -> path
  }
}

/// The lowercase hex SHA-256 of a workspace path.
///
/// ## Examples
///
/// ```gleam
/// assert gocache.workspace_digest("/a") != gocache.workspace_digest("/b")
/// ```
///
pub fn workspace_digest(workspace: String) -> String {
  <<workspace:utf8>>
  |> bootstrap.sha256
  |> bit_array.base16_encode
  |> string.lowercase
}

/// The Go build cache directory, `GOCACHE`.
///
/// ## Examples
///
/// ```gleam
/// assert gocache.build_cache(caches) == caches.root <> "/go-build"
/// ```
///
pub fn build_cache(caches: GoCaches) -> String {
  caches.root <> "/go-build"
}

/// The Go module cache directory, `GOMODCACHE`.
///
/// ## Examples
///
/// ```gleam
/// assert gocache.module_cache(caches) == caches.root <> "/gomod"
/// ```
///
pub fn module_cache(caches: GoCaches) -> String {
  caches.root <> "/gomod"
}

/// The golangci-lint cache directory, `GOLANGCI_LINT_CACHE`. Its default
/// lives under the cache directory of `HOME`, so it leaves the checkout by
/// the same mechanism and is not trimmed here: the tool bounds it itself.
///
/// ## Examples
///
/// ```gleam
/// assert gocache.lint_cache(caches) == caches.root <> "/golangci-lint"
/// ```
///
pub fn lint_cache(caches: GoCaches) -> String {
  caches.root <> "/golangci-lint"
}

/// The directories a session creates before its first jail starts. A
/// writable root that does not exist cannot be bound on Linux.
///
/// ## Examples
///
/// ```gleam
/// assert list.length(gocache.directories(caches)) == 3
/// ```
///
pub fn directories(caches: GoCaches) -> List(String) {
  [build_cache(caches), module_cache(caches), lint_cache(caches)]
}

/// The mirror's `cache/download` directory, which is a module proxy tree.
///
/// ## Examples
///
/// ```gleam
/// assert gocache.mirror_download("/m") == "/m/cache/download"
/// ```
///
pub fn mirror_download(mirror: String) -> String {
  mirror <> "/cache/download"
}

/// The environment names the server owns when the caches are in use, in
/// the order `environment` emits them. `GOPROXY` is listed only when a
/// mirror is configured, because an operator without one may set it.
///
/// ## Examples
///
/// ```gleam
/// assert gocache.environment_names(caches)
///   == ["GOCACHE", "GOMODCACHE", "GOLANGCI_LINT_CACHE"]
/// ```
///
pub fn environment_names(caches: GoCaches) -> List(String) {
  list.map(environment(caches), fn(pair) { pair.0 })
}

/// The variables a jailed Go tool runs with.
///
/// ## Examples
///
/// ```gleam
/// assert gocache.environment(GoCaches(root: "/c/r", mirror: Some("/m"), limit_kib: 1))
///   == [
///     #("GOCACHE", "/c/r/go-build"),
///     #("GOMODCACHE", "/c/r/gomod"),
///     #("GOLANGCI_LINT_CACHE", "/c/r/golangci-lint"),
///     #("GOPROXY", "file:///m/cache/download,https://proxy.golang.org,direct"),
///   ]
/// ```
///
pub fn environment(caches: GoCaches) -> List(#(String, String)) {
  let base = [
    #("GOCACHE", build_cache(caches)),
    #("GOMODCACHE", module_cache(caches)),
    #("GOLANGCI_LINT_CACHE", lint_cache(caches)),
  ]
  case caches.mirror {
    None -> base
    Some(mirror) ->
      list.append(base, [
        #(
          "GOPROXY",
          "file://" <> mirror_download(mirror) <> "," <> fallback_proxy,
        ),
      ])
  }
}

/// The session base with the caches granted: the root writable, the
/// environment names allowed, and the mirror's download directory mounted
/// read-only.
///
/// The mount is optional. A mirror that vanished after boot leaves Go to
/// fall through to the public proxy, which is a slower build and not a
/// refused one. With no caches the base is returned unchanged.
///
/// ## Examples
///
/// ```gleam
/// // gocache.admitting(base, Some(caches)).writable_roots contains caches.root
/// ```
///
pub fn admitting(
  base: policy.SandboxPolicy,
  caches: Option(GoCaches),
) -> policy.SandboxPolicy {
  case caches {
    None -> base
    Some(caches) ->
      policy.SandboxPolicy(
        ..base,
        writable_roots: list.unique(
          list.append(base.writable_roots, [caches.root]),
        ),
        env_allow: list.unique(list.append(
          base.env_allow,
          environment_names(caches),
        )),
        mounts: list.append(base.mounts, mirror_mounts(caches)),
      )
  }
}

fn mirror_mounts(caches: GoCaches) -> List(policy.Mount) {
  case caches.mirror {
    None -> []
    Some(mirror) -> [
      policy.Mount(
        path: mirror_download(mirror),
        access: policy.MountReadOnly,
        requirement: policy.MountOptional,
      ),
    ]
  }
}

/// Why the caches cannot be used under this session, or `Ok(Nil)`.
///
/// Checked at boot, against the composed base, because only there are the
/// masked paths known. Every message names the `loom.toml` line to edit.
/// The mirror must be a directory holding `cache/download`, and it must not
/// overlap the workspace, a protected path or the private root, in either
/// direction: a mirror above the workspace would mount the checkout
/// read-only, and one below a masked path would be both bound and hidden.
/// `[tools]` may not set a name the server now owns, since two owners for
/// one variable are decided by order and an operator reading the file
/// cannot tell which wins.
///
/// ## Examples
///
/// ```gleam
/// // gocache.fault(caches, "/work", [], tools_naming: ["GOCACHE"])
/// // -> Error("[tools] names GOCACHE, which the server sets ...")
/// ```
///
pub fn fault(
  caches: GoCaches,
  workspace: String,
  protected: List(String),
  mounts: List(policy.Mount),
  tools_naming names: List(String),
) -> Result(Nil, String) {
  use Nil <- result.try(owned_name_fault(caches, names))
  use Nil <- result.try(writable_mount_fault(caches, mounts))
  case caches.mirror {
    None -> Ok(Nil)
    Some(mirror) -> mirror_fault(caches, mirror, workspace, protected)
  }
}

// A read-write mount covering `<cache>/loom/workspace`, the parent of the
// root, would make the directory holding the retired trees writable from
// the jail again, which is what retiring them out of the root avoids.
fn writable_mount_fault(
  caches: GoCaches,
  mounts: List(policy.Mount),
) -> Result(Nil, String) {
  let parent = parent_directory(caches.root)
  let covering =
    list.find(mounts, fn(mount) {
      mount.access == policy.MountReadWrite
      && policy.covers(root: mount.path, path: parent)
    })
  case covering {
    Error(Nil) -> Ok(Nil)
    Ok(mount) ->
      Error(
        "[workspace] mounts names the read-write mount "
        <> mount.path
        <> ", which covers "
        <> parent
        <> ", the directory the Go cache root and its retired trees live in."
        <> " Mount a narrower directory or make it read-only",
      )
  }
}

fn owned_name_fault(
  caches: GoCaches,
  names: List(String),
) -> Result(Nil, String) {
  case list.find(names, list.contains(environment_names(caches), _)) {
    Error(Nil) -> Ok(Nil)
    Ok(name) ->
      Error(
        "[tools] names "
        <> name
        <> ", which the server sets to a private per-workspace Go cache"
        <> " (and GOPROXY only when [workspace] go_module_mirror is set);"
        <> " remove it from [tools] env and [tools.set]",
      )
  }
}

fn mirror_fault(
  caches: GoCaches,
  mirror: String,
  workspace: String,
  protected: List(String),
) -> Result(Nil, String) {
  let line = "[workspace] go_module_mirror = \"" <> mirror <> "\""
  use Nil <- result.try(is_directory(line, mirror, "does not exist"))
  use Nil <- result.try(is_directory(
    line,
    mirror_download(mirror),
    "has no cache/download directory; name the directory `go env GOMODCACHE` prints",
  ))
  let others =
    list.flatten([
      [#("the workspace", workspace), #("the private Go cache", caches.root)],
      list.map(protected, fn(path) { #("the protected path", path) }),
    ])
  list.try_each(others, fn(other) {
    case overlaps(mirror, other.1) {
      False -> Ok(Nil)
      True ->
        Error(
          line
          <> " overlaps "
          <> other.0
          <> " "
          <> other.1
          <> ". The mirror is mounted read-only into the jail, so it must be a"
          <> " directory apart from everything the jail writes or hides",
        )
    }
  })
}

fn is_directory(
  line: String,
  path: String,
  otherwise: String,
) -> Result(Nil, String) {
  case simplifile.is_directory(path) {
    Ok(True) -> Ok(Nil)
    Ok(False) | Error(_) -> Error(line <> ": " <> path <> " " <> otherwise)
  }
}

fn overlaps(left: String, right: String) -> Bool {
  policy.covers(root: left, path: right)
  || policy.covers(root: right, path: left)
}

/// Retires the build cache when it is over the limit.
///
/// `measure` answers the size of a directory in KiB. It is a parameter so
/// a test can claim any size without writing it, and so production's `du`
/// stays outside the decision. `unique` names the trash directory and must
/// not repeat within one root.
///
/// ## Examples
///
/// ```gleam
/// // gocache.trim(caches, measuring: fn(_) { Ok(20_000_000) }, unique: "1")
/// // -> Ok(Retired(20_000_000, root <> ".trash-1"))
/// ```
///
pub fn trim(
  caches: GoCaches,
  measuring measure: fn(String) -> Result(Int, String),
  unique unique: String,
) -> Result(Trimmed, String) {
  use size_kib <- result.try(measure(build_cache(caches)))
  case size_kib > caches.limit_kib {
    False -> Ok(Within(size_kib:))
    True -> retire(caches, size_kib, unique)
  }
}

// The rename comes first and the replacement second, and nothing runs
// between them that could fail on its own account: a failed rename leaves
// the cache where it was, and a failed replacement leaves Go to create the
// directory itself at its next open, which it does.
fn retire(
  caches: GoCaches,
  size_kib: Int,
  unique: String,
) -> Result(Trimmed, String) {
  let build = build_cache(caches)
  let trash = caches.root <> trash_infix <> unique
  use Nil <- result.try(
    simplifile.rename(build, trash)
    |> result.map_error(fn(error) {
      "could not rename "
      <> build
      <> " to "
      <> trash
      <> ": "
      <> string.inspect(error)
    }),
  )
  use Nil <- result.try(open_fresh(build))
  Ok(Retired(size_kib:, trash:))
}

// The replacement is one plain, non-recursive `mkdir`. A recursive create
// would follow a link the jail planted at the path between the rename and
// this call and create directories through it. An existing entry, a planted
// link included, is left alone, and Go creates its own tree at its next
// open. A build that held the old cache open fails once and a retry clears
// it.
fn open_fresh(build: String) -> Result(Nil, String) {
  case simplifile.create_directory(build) {
    Ok(Nil) | Error(simplifile.Eexist) -> Ok(Nil)
    Error(error) ->
      Error("could not create " <> build <> ": " <> string.inspect(error))
  }
}

/// Deletes every retired build cache of this workspace and returns how
/// many. The parent of `root` is listed and only entries named
/// `<digest>.trash-*` are touched. Nothing inside `root` is read or
/// recursed into, whatever a jail wrote there.
///
/// ## Examples
///
/// ```gleam
/// // gocache.sweep(caches) == Ok(1) after one `trim` retired a cache
/// ```
///
pub fn sweep(caches: GoCaches) -> Result(Int, String) {
  let parent = parent_directory(caches.root)
  let prefix = last_segment(caches.root) <> trash_infix
  use names <- result.try(
    simplifile.read_directory(parent)
    |> result.map_error(fn(error) {
      "could not list " <> parent <> ": " <> string.inspect(error)
    }),
  )
  list.filter(names, string.starts_with(_, prefix))
  |> list.try_fold(0, fn(count, name) {
    let path = parent <> "/" <> name
    use Nil <- result.try(
      simplifile.delete(path)
      |> result.map_error(fn(error) {
        "could not delete " <> path <> ": " <> string.inspect(error)
      }),
    )
    Ok(count + 1)
  })
}

fn parent_directory(path: String) -> String {
  case string.split(path, "/") |> list.reverse {
    [_last, ..rest] -> string.join(list.reverse(rest), "/")
    [] -> path
  }
}

fn last_segment(path: String) -> String {
  case string.split(path, "/") |> list.reverse {
    [last, ..] -> last
    [] -> path
  }
}

/// The size of a directory in KiB, from the host's `du -sk`.
///
/// `du` rather than a walk in Gleam because a large build cache is
/// hundreds of thousands of files and `du` is the tool that measures it
/// quickly on both macOS and Linux. It does not follow links, so a link
/// planted at the cache path measures as the link.
///
/// ## Examples
///
/// ```gleam
/// // gocache.du_kib("/home/o/.cache/loom/workspace/ab/go-build") == Ok(1_048_576)
/// ```
///
pub fn du_kib(path: String) -> Result(Int, String) {
  use du <- result.try(
    ffi_os.find_executable("du")
    |> result.replace_error("`du` is not on PATH"),
  )
  use #(status, output) <- result.try(ffi_os.run_capture(
    du,
    ["-sk", path],
    measure_timeout_ms,
  ))
  case status {
    0 -> parse_du(output)
    other ->
      Error("`du` exited " <> int.to_string(other) <> " measuring " <> path)
  }
}

/// The size in KiB from `du -sk` output, `<kib><tab><path>`.
///
/// ## Examples
///
/// ```gleam
/// assert gocache.parse_du("2048\t/x\n") == Ok(2048)
/// ```
///
pub fn parse_du(output: String) -> Result(Int, String) {
  case string.split(string.trim(output), "\t") {
    [size, ..] ->
      int.parse(string.trim(size))
      |> result.map_error(fn(_) { "`du` printed " <> string.inspect(output) })
    [] -> Error("`du` printed nothing")
  }
}

/// Starts the session's cache maintenance: trim, then sweep, in one weft
/// task that holds no session state.
///
/// It runs beside the session rather than before it, so a large cache costs
/// the first prompt nothing. The handle is for a caller that wants to
/// cancel at shutdown; a task cut short is finished by the next start.
///
/// ## Examples
///
/// ```gleam
/// // let _maintenance = gocache.start_maintenance(caches, logger)
/// ```
///
pub fn start_maintenance(caches: GoCaches, logger: Logger) -> weft.Witnessed {
  weft.new([fn() { Ok(maintain(caches, logger)) }])
  |> weft.deadline(maintenance_deadline_ms)
  |> weft.start_witnessed
}

fn maintain(caches: GoCaches, logger: Logger) -> Nil {
  let unique =
    int.to_string(ffi_os.system_time_ms())
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
  case trim(caches, measuring: du_kib, unique:) {
    Ok(Within(size_kib:)) ->
      log.debug(logger, "go_cache.within_limit", [
        field.count(key: "size_kib", value: size_kib),
      ])
    Ok(Retired(size_kib:, trash:)) ->
      log.info(logger, "go_cache.retired", [
        field.count(key: "size_kib", value: size_kib),
        field.text(key: "trash", value: trash),
      ])
    Error(reason) ->
      log.warn(logger, "go_cache.trim_failed", [
        field.text(key: "reason", value: reason),
      ])
  }
  case sweep(caches) {
    Ok(removed) ->
      log.debug(logger, "go_cache.swept", [
        field.count(key: "removed", value: removed),
      ])
    Error(reason) ->
      log.warn(logger, "go_cache.sweep_failed", [
        field.text(key: "reason", value: reason),
      ])
  }
}
