//// The sandbox policy, environment and directory layout a session's workspace
//// runs under, computed from plain values.
////
//// These functions began in `serve`, which assembles a whole session. The
//// workspace half of a session (its helper pool, broker, tools and language
//// servers) is built by `workspace_plane`, and that module cannot import
//// `serve` without a cycle, so the policy composition moved here. Nothing in
//// this module reads a session handle, a database or a mailbox: each function
//// takes a workspace path, the `[tools]` configuration, the Go caches or the
//// owner's protected files, and returns a policy, an environment or a list of
//// directories. That is what lets one composition run on the machine that owns
//// a session and on an executor that holds only the workspace.
////
//// A session's policy is built in layers, and the order is part of the
//// result. The base starts from the workspace default and the readable scope.
//// The daemon masks its own state root. The session then masks its search
//// index and memory store, grants the tool temporary directory and the
//// imported-hook variables, applies the `[tools]` table, widens for a linked
//// git worktree and the Go caches, admits the code-mode toolchain, and merges
//// duplicate mounts last. `base_policy_fault` refuses the result before any
//// process is spawned, so a mask the jail cannot honour is a boot error and
//// not a failure of the first tool call.
////
//// ## Flow
////
//// `base_policy_for` → `protecting_state_root` → `session_base` → `base_policy_fault` → `prepare_directories` → `tool_environment`
////
//// 1. `base_policy_for` builds the starting policy from a workspace path and a
////    read scope, and `admitting_config_mounts` adds the operator's mounts.
//// 2. `protecting_state_root` masks the daemon's state root, so a jailed tool
////    cannot read the catalogue or the other sessions' files.
//// 3. `session_base` composes the rest, in the order the layers above
////    describe, and `session_toolchain` asks the same composition whether the
////    discovered toolchain may be mounted without shadowing a writable root.
//// 4. `base_policy_fault` and `go_cache_fault` refuse a composed policy that
////    the jail or the Go caches cannot honour, before any directory is made.
//// 5. `prepare_directories` creates the workspace, blob, scratch and tool
////    directories, and writes the ignore files that keep them out of
////    `git status`.
//// 6. `tool_environment` builds the environment every jailed child inherits,
////    from the shell, the toolchain `PATH` and the `[tools]` table.

import broker/exec.{type Pool}
import broker/policy
import client/catalog
import client/codemode as codemode_wiring
import client/extension/installed
import client/git_identity
import client/gocache
import client/internal/ffi_os
import client/lsp/profile
import filepath
import gleam/dict.{type Dict}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import provider/secret
import simplifile
import tom

/// The files an owner keeps beside its session that a jailed process must
/// never write: the search index, and the memory store with the digest
/// sidecar rendered from it.
///
/// Plain paths, because masking a file needs only its name. A workspace
/// whose owner is on another machine is given none, since those files do
/// not exist on its filesystem and there is nothing there to protect.
pub type OwnerFiles {
  OwnerFiles(
    /// The absolute path of the search index.
    index: String,
    /// The absolute path of the memory store.
    memory_store: String,
    /// The absolute path of the memory digest sidecar.
    memory_digest: String,
  )
}

/// What the session base is composed from, apart from the files its
/// owner protects: the starting policy, the workspace it widens for, the
/// `[tools]` table and the Go caches.
///
/// A record because `session_base`, `session_toolchain` and
/// `go_cache_fault` read the same four values, and every one of them is
/// plain data a remote executor can hold. The session's `Settings` is not
/// plain data in that sense, so none of these takes it.
pub type Basis {
  Basis(
    /// The policy the session starts from, before any protection or
    /// widening below applies.
    base_policy: policy.SandboxPolicy,
    /// The workspace root every widening is judged against.
    workspace: String,
    /// The `[tools]` table: environment names to pass, set and refuse, and
    /// the network the tools may reach.
    tools: catalog.ToolsConfig,
    /// The Go caches, when the session has them.
    go_caches: Option(gocache.GoCaches),
  )
}

/// The environment variable `name` as this machine sees it, through the
/// provider secret store's env lookup rather than a second environment
/// FFI: it is the injected lookup seam this tree already has, and these
/// values are configuration, not durable state.
///
/// Public because a workspace reads its own machine's variables here, and
/// `serve` reads the owner's through the same function.
///
/// ## Examples
///
/// ```gleam
/// assert workspace_policy.env_text("LOOM_NO_SUCH_VARIABLE") == Error(Nil)
/// ```
pub fn env_text(name: String) -> Result(String, Nil) {
  secret.lookup(secret.env(), name)
}

/// The environment a session's jailed children inherit: the shell the
/// `bash` tool runs, a satellite, a hook host.
///
/// Allowlist-constructed and shared by the tool path and the hook path,
/// so a host launched by whichever came first is the same host. Five
/// names, each earned by a failure a live drive produced:
///
/// - `PATH` is the toolchain's when code mode found one, so `gleam` and
///   `erl` resolve in the shell exactly as they do for the compiler. On a
///   Homebrew Mac the system directories alone hide both, and a model
///   that cannot run the project's tests falls back to `find /`.
/// - `HOME` is a directory under the workspace, so it is writable and
///   empty. `bash -l` sources the dotfiles under `$HOME`, and with the
///   name unset it read the operator's profile against an empty home and
///   failed every line that mentioned it. It was the workspace itself for
///   a while, and macOS answered by creating `Library/Caches` in the
///   operator's checkout — an untracked directory in every `git status`
///   the model ran. A home of its own keeps what a toolchain writes to
///   `$HOME` off the tree.
/// - `GIT_CONFIG_GLOBAL` names the identity-only configuration prepared by
///   `git_identity`. Repository overrides still win; absent identity refuses a
///   commit instead of using the host name. Imported operator hooks retain
///   their normal HOME and global configuration.
/// - `TMPDIR` is a writable directory under the workspace. It remains
///   the fallback when no private scratch is available. Code mode pins
///   its compiler's `TMPDIR` to the build root, independently of scratch.
/// - `LOOM_SCRATCH_DIR` reserves the helper-owned scratch name. The empty
///   value carries the name through each tool's environment allowlist;
///   the helper replaces it with its actual scratch path, or omits it
///   when no scratch exists. `TMPDIR` remains the writable fallback.
///
/// When `go_caches` is set the environment also carries `GOCACHE`,
/// `GOMODCACHE` and `GOLANGCI_LINT_CACHE`, which point at the workspace's
/// private directory outside the checkout, and `GOPROXY` when a module
/// mirror is configured. Without them Go would write both caches under the
/// `HOME` above, inside the operator's tree. `client/gocache` says why the
/// build cache is never the host's.
///
/// ## Examples
///
/// ```gleam
/// // With go_caches rooted at /c/loom/workspace/ab, the list ends:
/// //   #("GOCACHE", "/c/loom/workspace/ab/go-build"),
/// //   #("GOMODCACHE", "/c/loom/workspace/ab/gomod"),
/// //   #("GOLANGCI_LINT_CACHE", "/c/loom/workspace/ab/golangci-lint"),
/// ```
///
/// ```gleam
/// assert workspace_policy.session_environment("/work", option.None, option.None)
///   == [
///     #("PATH", "/usr/local/bin:/usr/bin:/bin"),
///     #("HOME", "/work/.codemode/home"),
///     #("GIT_CONFIG_GLOBAL", "/work/.codemode/home/gitconfig"),
///     #("TMPDIR", "/work/.codemode/tmp"),
///     #("LOOM_SCRATCH_DIR", ""),
///   ]
/// ```
///
@internal
pub fn session_environment(
  workspace: String,
  toolchain_path: Option(String),
  go_caches: Option(gocache.GoCaches),
) -> List(#(String, String)) {
  let go = option.map(go_caches, gocache.environment) |> option.unwrap([])
  list.append(
    [
      #("PATH", option.unwrap(toolchain_path, "/usr/local/bin:/usr/bin:/bin")),
      #("HOME", tool_home_directory(workspace)),
      #(
        git_identity.environment_name,
        tool_home_directory(workspace) <> "/gitconfig",
      ),
      #("TMPDIR", tool_tmp_directory(workspace)),
      #("LOOM_SCRATCH_DIR", ""),
    ],
    go,
  )
}

/// Where a jailed tool's `HOME` points: a directory of its own beneath
/// the code-mode work directory, beside `TMPDIR`, for the same reason —
/// the workspace gains no second dot-directory, and nothing a tool
/// writes to its home lands in the operator's tree.
///
/// ## Examples
///
/// ```gleam
/// assert workspace_policy.tool_home_directory("/work") == "/work/.codemode/home"
/// ```
///
@internal
pub fn tool_home_directory(workspace: String) -> String {
  workspace <> "/" <> codemode_wiring.work_directory <> "/home"
}

/// The whole environment a jailed tool shell of this session runs under:
/// the five names the server owns, then whatever the `[tools]` table
/// added.
///
/// The order is the guarantee. `session_environment`'s five names come
/// first and nothing after them may repeat one. The server selects the
/// workspace and toolchain paths, and the helper supplies actual scratch;
/// configuration cannot replace either owner's choice.
/// `client/catalog.parse_tools` refuses a table that names one, so the
/// order here is the second lock rather than the only one.
///
/// A configured name the host environment does not set is **skipped**,
/// and the skipped names come back beside the environment rather than
/// being logged from in here — this stays a decision about values, and
/// the caller owns the warning line. Skipping rather than refusing is
/// deliberate: an operator who lists `GH_TOKEN` on a machine that has
/// none has a `gh` that will not authenticate, and that is a better
/// thing to learn from one warned line and an in-band tool failure than
/// from a server that would not start.
///
/// ## Examples
///
/// ```gleam
/// // workspace_policy.tool_environment("/work", None, tools, reading: env_text)
/// // -> #([#("PATH", ..), #("HOME", ..), #("TMPDIR", ..), #("GH_TOKEN", ..)], [])
/// ```
///
@internal
pub fn tool_environment(
  workspace: String,
  toolchain_path: Option(String),
  go_caches: Option(gocache.GoCaches),
  tools: catalog.ToolsConfig,
  reading reading: fn(String) -> Result(String, Nil),
) -> #(List(#(String, String)), List(String)) {
  // Installation discovery is the host shell's responsibility. Carry its
  // search path as a whole instead of guessing which language managers the
  // owner installed. This changes lookup only; filesystem access remains a
  // separate sandbox decision. Empty components do not grant cwd precedence.
  let inherited_path =
    reading("PATH")
    |> result.map(string.split(_, ":"))
    |> result.unwrap([])
    |> list.filter(fn(path) { path != "" })
  let owned =
    session_environment(workspace, toolchain_path, go_caches)
    |> extending_path(list.append(tools.path, inherited_path))

  // A pass-through name settles one of two ways, so the fold carries
  // both answers: the pairs that were found, and the names that were not.
  let #(passed, unset) =
    list.fold(tools.env, #([], []), fn(state, name) {
      let #(found, missing) = state
      case reading(name) {
        Ok(value) -> #([#(name, value), ..found], missing)
        Error(Nil) -> #(found, [name, ..missing])
      }
    })

  // The literals come last, after the host reads, because a name cannot
  // be in both lists and the file's own order is the one an operator
  // reading it back expects.
  #(list.flatten([owned, list.reverse(passed), tools.set]), list.reverse(unset))
}

/// Where a jailed tool's `TMPDIR` points: beneath the code-mode work
/// directory the server already owns inside the workspace, so the
/// workspace gains no second dot-directory for it.
///
/// ## Examples
///
/// ```gleam
/// assert workspace_policy.tool_tmp_directory("/work") == "/work/.codemode/tmp"
/// ```
///
@internal
pub fn tool_tmp_directory(workspace: String) -> String {
  workspace <> "/" <> codemode_wiring.work_directory <> "/tmp"
}

/// The base policy widened for a workspace that is a linked git
/// worktree: the directories git keeps for it outside the tree become
/// writable roots, so `git commit` works there as it does in a primary
/// checkout.
///
/// A primary checkout holds its metadata in `<workspace>/.git`, inside
/// the one root the jail lets a tool write, and committing needs nothing
/// more. A worktree made by `git worktree add` holds a `.git` *file*
/// instead, naming a directory under the main repository's
/// `.git/worktrees/<name>`, and that directory's `commondir` names the
/// main repository's `.git` where objects and refs live. Both are outside
/// the workspace, so under the default base a jailed `git commit` died
/// on the index lock with "Operation not permitted" and the model
/// concluded, correctly and uselessly, that it could not commit.
///
/// The widening is the same trust a primary checkout already extends: a
/// model that can write `<workspace>/.git` can already plant a hook or
/// rewrite a ref there, and the main repository's `.git` is the same
/// kind of place for the same operator. A workspace that is not a
/// worktree, or whose `.git` file cannot be read, is left exactly as it
/// was.
///
/// ## Examples
///
/// ```gleam
/// // With /work/.git reading `gitdir: /repo/.git/worktrees/work` and
/// // /repo/.git/worktrees/work/commondir reading `../..`:
/// // workspace_policy.widening_linked_worktree(base, "/work").writable_roots
/// //   == ["/work", "/repo/.git/worktrees/work", "/repo/.git"]
/// ```
///
@internal
pub fn widening_linked_worktree(
  base: policy.SandboxPolicy,
  workspace: String,
) -> policy.SandboxPolicy {
  case linked_git_directories(workspace) {
    [] -> base
    outside ->
      policy.SandboxPolicy(
        ..base,
        writable_roots: list.unique(list.append(base.writable_roots, outside)),
      )
  }
}

/// The discovered toolchain, or the reason this base cannot carry it: one
/// of its read-only mounts would sit at or above one of the base's
/// writable roots (`codemode.clear_of`).
///
/// A separate step from `admitting_codemode`, and ahead of it, because
/// the answer has two readers. The base must not carry the mount — the
/// helper and `broker/policy.validate` both refuse a read-only mount over
/// a writable root (`protocol-change/057`), so admitting it would refuse
/// the boot — and `code_mode_seam` must not register a tool whose every
/// launch the meet would then refuse. Turning the discovery into an
/// `Error` is what tells both, in the words `discover` uses for a host
/// with no toolchain at all.
///
/// Only `base.writable_roots` is read. The session assembly asks a base
/// built with the toolchain already in it, which is the same answer,
/// because admitting the toolchain changes the mounts and no root.
///
/// ## Examples
///
/// ```gleam
/// // With `erl` found at /bin/erl, so its prefix is `/`:
/// // workspace_policy.admissible_toolchain(Ok(toolchain), policy.workspace_default("/w"))
/// //   == Error("code mode would mount / read-only …")
/// ```
///
@internal
pub fn admissible_toolchain(
  discovered: Result(codemode_wiring.Toolchain, String),
  base: policy.SandboxPolicy,
) -> Result(codemode_wiring.Toolchain, String) {
  use toolchain <- result.try(discovered)
  codemode_wiring.clear_of(toolchain, writable_roots: base.writable_roots)
}

/// The base policy with the code-mode toolchain admitted as explicit
/// mounts: the `erl` install prefix, the `gleam` prefix, and the prepared
/// build seed, each read-only and required.
///
/// This is the base half of one statement whose other half is
/// `codemode/launch.node_requirements`. Mounts compose as the meet by
/// path, so a mount survives into the policy a satellite runs under only
/// when both sides carry it: the base says what code mode may reach, the
/// launcher says what it needs, and a launcher asking for anything else is
/// refused in band naming the path. Both halves read the same
/// `codemode.toolchain_mounts` value, so there is nothing for them to
/// drift apart on.
///
/// A host with no toolchain is left exactly as it was. It registers no
/// `code_mode` tool, so no satellite will ever be launched on it, and a
/// mount nothing needs is a region granted for nothing.
///
/// The toolchain handed here should already have passed
/// `admissible_toolchain` against this base. This step does not refuse on
/// its own, because it returns a policy and the refusal has to reach the
/// tool registration too; a toolchain that skipped admission and shadows
/// a writable root leaves a base `base_policy_fault` refuses.
///
/// ## Examples
///
/// ```gleam
/// // workspace_policy.admitting_codemode(base, Error("no gleam on PATH")) == base
/// ```
///
@internal
pub fn admitting_codemode(
  base: policy.SandboxPolicy,
  discovered: Result(codemode_wiring.Toolchain, String),
) -> policy.SandboxPolicy {
  case discovered {
    Error(_reason) -> base
    Ok(toolchain) ->
      // Merged rather than appended, so a base that already carries the
      // toolchain (the build plane admits it itself, and a fixture may
      // admit it again on top) ends with one entry per path. Applying
      // this step twice is then the same as applying it once, and the
      // duplicate-mount refusal in `policy.validate` stays unreachable
      // from any assembly order.
      policy.SandboxPolicy(
        ..base,
        mounts: merged_mounts(list.append(
          base.mounts,
          codemode_wiring.toolchain_mounts(toolchain),
        )),
      )
  }
}

// A region a mask already covers, in either direction: the mask over the
// region and the region over the mask are both the contradiction
// `broker/policy.validate` refuses.
fn masked(path: String, protected: List(String)) -> Bool {
  list.any(protected, fn(entry) {
    policy.covers(root: entry, path:) || policy.covers(root: path, path: entry)
  })
}

// `masked`, and a line on stderr naming what it cost. A derived mount
// dropped for a mask is silent otherwise, and the build that then fails
// inside the jail reports a missing directory rather than the mask that
// removed it. Explicit mounts instead fail validation so the operator can
// correct a configuration that contradicts a protected path.
//
// Stderr rather than the `Logger`: both callers are pure derivations in
// the base-policy pipe and neither is handed a logger, and threading one
// through two `admitting_*` steps to carry a boot-time note would be a
// wider change than the note is worth.
fn dropped_for_mask(path: String, protected: List(String)) -> Bool {
  case masked(path, protected) {
    False -> False
    True -> {
      io.println_error(
        "loomd: not mounting " <> path <> "; a protected path covers it",
      )
      True
    }
  }
}

/// The operator's home directory as the harness reads it, or `None` when
/// `HOME` is unset.
///
/// Tool configuration uses this value to expand an operator's `~` paths.
///
/// ## Examples
///
/// ```gleam
/// // workspace_policy.home_directory() == Some("/home/o")
/// ```
///
pub fn home_directory() -> Option(String) {
  option.from_result(env_text("HOME"))
}

/// The base policy widened for the sibling checkouts this workspace's
/// own manifests name: every `path = "..."` dependency in a `gleam.toml`
/// that resolves outside the workspace, read-only.
///
/// Derived, not configured, and for the reason
/// `widening_linked_worktree` is: the fact is already written down in a
/// file the workspace owns, so asking an operator to write it a second
/// time in `loom.toml` would be asking them to keep two copies in step.
/// A `path = "../weft"` line is the same shape as a linked worktree's
/// git directory and is handled the same way — read the manifest,
/// canonicalize, mount.
///
/// Read-only, and `MountOptional`. A path dependency whose directory is
/// missing is a build the compiler refuses on its own terms with a
/// better sentence than a jail could produce, and read-write would hand
/// a session write access to a checkout the operator did not open it on.
/// Read-write to a sibling comes only from an explicit `[workspace]
/// mounts` line.
///
/// Every failure reads as "nothing to widen": an unreadable manifest, a
/// document that does not parse, a `path` that is not a string. The
/// monorepo case is covered by reading `packages/*/gleam.toml` as well,
/// because loom's own layout puts the manifests there and a dependency
/// on a sibling checkout is written in one of them.
///
/// ## Examples
///
/// ```gleam
/// // With /work/gleam.toml naming `weft = { path = "../weft" }`:
/// // workspace_policy.widening_path_dependencies(base, "/work").mounts
/// //   |> list.map(fn(m) { m.path }) == ["/weft"]
/// ```
///
@internal
pub fn widening_path_dependencies(
  base: policy.SandboxPolicy,
  workspace: String,
) -> policy.SandboxPolicy {
  let wanted =
    path_dependencies(workspace)
    |> list.filter(fn(path) { !policy.covers(root: workspace, path:) })
    |> list.filter(fn(path) { !dropped_for_mask(path, base.protected) })
    |> list.filter(fn(path) {
      !list.any(base.mounts, fn(mount) { mount.path == path })
    })
    |> list.unique
  policy.SandboxPolicy(
    ..base,
    mounts: list.append(
      base.mounts,
      list.map(wanted, fn(path) {
        policy.Mount(
          path:,
          access: policy.MountReadOnly,
          requirement: policy.MountOptional,
        )
      }),
    ),
  )
}

/// Every `path = "..."` dependency this workspace's manifests name, made
/// absolute against the manifest that stated it.
///
/// The manifests are the workspace's own `gleam.toml` and one per
/// `packages/<name>` directory, which is the monorepo layout loom itself
/// has. Deeper nesting is deliberately not walked: a recursive scan of a
/// workspace is unbounded work at every session boot, and a checkout
/// that keeps its packages somewhere else states the sibling in
/// `[workspace] mounts` instead.
///
/// ## Examples
///
/// ```gleam
/// // workspace_policy.path_dependencies("/not/a/gleam/project") == []
/// ```
///
@internal
pub fn path_dependencies(workspace: String) -> List(String) {
  let manifests = [
    workspace <> "/gleam.toml",
    ..list.map(package_directories(workspace), fn(directory) {
      directory <> "/gleam.toml"
    })
  ]
  list.flat_map(manifests, manifest_paths)
}

// The `packages/<name>` directories of a monorepo checkout, or nothing.
fn package_directories(workspace: String) -> List(String) {
  let root = workspace <> "/packages"
  simplifile.read_directory(root)
  |> result.unwrap([])
  |> list.map(fn(entry) { root <> "/" <> entry })
  |> list.filter(fn(path) { simplifile.is_directory(path) == Ok(True) })
}

// The path dependencies of one manifest, absolute. Relative paths
// resolve against the manifest's own directory, which is how the Gleam
// compiler reads them.
fn manifest_paths(manifest: String) -> List(String) {
  let directory = filepath.directory_name(manifest)
  let parsed = {
    use text <- result.try(result.replace_error(simplifile.read(manifest), Nil))
    use document <- result.try(result.replace_error(tom.parse(text), Nil))
    Ok(
      list.flat_map(["dependencies", "dev-dependencies"], fn(table) {
        dependency_paths(document, table)
      }),
    )
  }
  result.unwrap(parsed, [])
  |> list.filter_map(fn(path) { absolute_path(path, against: directory) })
}

// The `path` value of every dependency in one table. A dependency stated
// as a bare version string carries no path and contributes nothing.
fn dependency_paths(
  document: Dict(String, tom.Toml),
  table: String,
) -> List(String) {
  case dict.get(document, table) {
    Ok(tom.Table(entries)) | Ok(tom.InlineTable(entries)) ->
      dict.values(entries)
      |> list.filter_map(fn(entry) {
        case entry {
          tom.Table(fields) | tom.InlineTable(fields) ->
            case dict.get(fields, "path") {
              Ok(tom.String(path)) -> Ok(path)
              Ok(_other) | Error(Nil) -> Error(Nil)
            }
          _other -> Error(Nil)
        }
      })
    Ok(_other) | Error(Nil) -> []
  }
}

/// The base policy with an operator's `[workspace] mounts` entries
/// admitted, each `MountRequired` at the access the line states.
///
/// Required rather than optional, because this is the one list nothing
/// derives: an operator who writes a path down has said the session
/// needs it, and a typo that silently mounted nothing would surface as a
/// build failing for an unrelated-looking reason. A missing source
/// refuses the execution naming the path instead.
///
/// An entry that overlaps a mask is not filtered out the way a derived
/// one is. It is left in, so that `base_policy_fault` refuses the boot
/// naming both the mount and the masked region: a derived entry is a
/// convenience the harness can drop silently, and a written one is a
/// statement the operator has to be told the server will not honour.
///
/// ## Examples
///
/// ```gleam
/// // workspace_policy.admitting_config_mounts(base, []) == base
/// ```
///
@internal
pub fn admitting_config_mounts(
  base: policy.SandboxPolicy,
  configured: List(catalog.WorkspaceMount),
) -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    ..base,
    mounts: merged_mounts(list.append(
      base.mounts,
      list.map(configured, fn(entry) {
        policy.Mount(
          path: entry.path,
          access: entry.access,
          requirement: policy.MountRequired,
        )
      }),
    )),
  )
}

/// Collapse the assembled mount list so that each host path appears once.
///
/// Every `admitting_*` and `widening_*` step names the regions its own
/// question is about, and two of them can land on the same directory
/// without either being wrong. `admitting_codemode` emits the directory
/// holding `gleam`, which on a Homebrew host resolves to the `/opt/homebrew`
/// prefix the shared toolchain set also names, and on a Linux host to
/// `~/.local/bin`, which the per-user set names too. `broker/policy.validate`
/// refuses a repeated path, so before this step the collision was a boot
/// failure on ordinary developer machines rather than a misconfiguration.
///
/// Merging here is what keeps the assembled base inside the wire-level
/// invariant; `validate` keeps refusing duplicates, because a policy that
/// reaches the helper with two answers for one region has no rule for
/// picking between them.
///
/// The two fields merge in opposite directions, and both directions are
/// the safe one. `requirement` takes `MountRequired` whenever either entry
/// carries it, because a step that asks to fail closed on a missing source
/// must not lose that by sharing a path with one that does not. `access`
/// takes `MountReadOnly` whenever either entry carries it: every toolchain
/// region is read-only, so a read-write entry from the user set at exactly
/// a toolchain path would widen the toolchain, which nothing asked for. A
/// build that genuinely needs to write there names a directory of its own
/// under the region instead.
///
/// Nesting is not a duplicate and is left alone. `.cargo/bin` beside
/// `.cargo/registry` is two binds with different access on purpose, and
/// collapsing a child into its parent would give the wider access to the
/// narrower region.
///
/// ## Examples
///
/// ```gleam
/// // workspace_policy.merging_mounts(base).mounts |> list.map(fn(m) { m.path })
/// //   == ["/opt/homebrew"]
/// ```
///
@internal
pub fn merging_mounts(base: policy.SandboxPolicy) -> policy.SandboxPolicy {
  policy.SandboxPolicy(..base, mounts: merged_mounts(base.mounts))
}

// The first entry for a path keeps its position, so the order the
// assembly chain produced survives the merge and the encoding stays
// deterministic. A base carries a handful of mounts, so the quadratic
// scan costs nothing worth avoiding.
fn merged_mounts(mounts: List(policy.Mount)) -> List(policy.Mount) {
  mounts
  |> list.fold([], fn(kept: List(policy.Mount), mount) {
    case list.any(kept, fn(other) { other.path == mount.path }) {
      True ->
        list.map(kept, fn(other) {
          case other.path == mount.path {
            True -> merged_mount(other, mount)
            False -> other
          }
        })
      False -> [mount, ..kept]
    }
  })
  |> list.reverse
}

// Two entries for one region become the entry neither step would object
// to: read-only if either side is read-only, required if either side is
// required.
fn merged_mount(kept: policy.Mount, later: policy.Mount) -> policy.Mount {
  let access = case kept.access, later.access {
    policy.MountReadWrite, policy.MountReadWrite -> policy.MountReadWrite
    policy.MountReadWrite, policy.MountReadOnly -> policy.MountReadOnly
    policy.MountReadOnly, policy.MountReadWrite -> policy.MountReadOnly
    policy.MountReadOnly, policy.MountReadOnly -> policy.MountReadOnly
  }
  let requirement = case kept.requirement, later.requirement {
    policy.MountRequired, policy.MountRequired -> policy.MountRequired
    policy.MountRequired, policy.MountOptional -> policy.MountRequired
    policy.MountOptional, policy.MountRequired -> policy.MountRequired
    policy.MountOptional, policy.MountOptional -> policy.MountOptional
  }
  policy.Mount(path: kept.path, access:, requirement:)
}

/// The directories a linked worktree's git metadata lives in, outside
/// the workspace: the worktree's own git directory first, then the main
/// repository's `.git` its `commondir` names. Empty for a primary
/// checkout, for a directory that is not a repository, and for a `.git`
/// file that does not parse — every failure reads as "nothing to widen".
///
/// ## Examples
///
/// ```gleam
/// // workspace_policy.linked_git_directories("/not/a/worktree") == []
/// ```
///
@internal
pub fn linked_git_directories(workspace: String) -> List(String) {
  let directories = {
    use text <- result.try(result.replace_error(
      simplifile.read(workspace <> "/.git"),
      Nil,
    ))
    use gitdir_text <- result.try(gitdir_line(text))
    use gitdir <- result.try(absolute_path(gitdir_text, against: workspace))

    // A worktree without a readable commondir is a worktree git itself
    // cannot use, so the main repository is simply not added.
    let common =
      simplifile.read(gitdir <> "/commondir")
      |> result.replace_error(Nil)
      |> result.try(absolute_path(_, against: gitdir))
      |> result.map(list.wrap)
      |> result.unwrap([])
    Ok([gitdir, ..common])
  }
  result.unwrap(directories, [])
}

// The one line a linked worktree's `.git` file carries, without its
// prefix and trailing newline.
fn gitdir_line(text: String) -> Result(String, Nil) {
  case text {
    "gitdir: " <> rest -> Ok(string.trim(rest))
    _other -> Error(Nil)
  }
}

// A path from a git metadata file made absolute and free of `..`
// segments, since a writable root is compared by prefix and `a/b/../c`
// would cover nothing. Relative paths resolve against the file's own
// directory, which is how git reads them.
fn absolute_path(path: String, against base: String) -> Result(String, Nil) {
  let trimmed = string.trim(path)
  case filepath.is_absolute(trimmed) {
    True -> filepath.expand(trimmed)
    False -> filepath.expand(filepath.join(base, trimmed))
  }
}

/// The whole session base, composed: every protection, every widening,
/// and every environment name a jailed process of this session is
/// allowed to carry, in the order they apply.
///
/// It is one named function rather than a pipeline inlined in
/// `assemble_in` because the composition *is* a decision about a value,
/// and the steps are not independent — `policy.meet` intersects
/// `env_allow` against this result, so a step left out is not a missing
/// convenience but every call that wanted the name refused. A test that
/// can read this back is what notices a step going missing;
/// `base_policy_fault` is the same argument one table further on.
///
/// ## Examples
///
/// ```gleam
/// // workspace_policy.session_base(basis, Some(files), toolchain)
/// //   .env_allow  // contains "TMPDIR" and "CLAUDE_PROJECT_DIR"
/// ```
///
@internal
pub fn session_base(
  basis: Basis,
  files: Option(OwnerFiles),
  toolchain: Result(codemode_wiring.Toolchain, String),
) -> policy.SandboxPolicy {
  protecting_owner_files(basis.base_policy, files)
  |> allowing_tool_tmpdir
  |> allowing_imported_hook_env
  |> under_tools_config(basis.tools)
  |> widening_linked_worktree(basis.workspace)
  |> gocache.admitting(basis.go_caches)
  |> admitting_codemode(toolchain)
  |> merging_mounts
}

/// The discovered toolchain as this session may use it: the same value,
/// or an `Error` when one of its mounts would shadow a writable root of
/// the assembled session base (`admissible_toolchain`).
///
/// The roots are read off `session_base` itself rather than restated,
/// so a step that widens the writable roots — a linked worktree's git
/// directories today — is judged against without anyone remembering to
/// add it here. That base is assembled with the unadmitted toolchain in
/// it, which gives the same roots, because `admitting_codemode` touches
/// the mounts and nothing else; only the roots are read.
///
/// ## Examples
///
/// ```gleam
/// // With `erl` found at /bin/erl:
/// // workspace_policy.session_toolchain(Ok(found), basis, Some(files))
/// //   == Error("code mode would mount / read-only …")
/// ```
///
@internal
pub fn session_toolchain(
  discovered: Result(codemode_wiring.Toolchain, String),
  basis: Basis,
  files: Option(OwnerFiles),
) -> Result(codemode_wiring.Toolchain, String) {
  let assembled = session_base(basis, files, discovered)
  admissible_toolchain(discovered, assembled)
}

// The two masks for an owner's files, or none when the workspace has no
// owner beside it. The index is masked first and the memory store second,
// the order the composition has always applied them in.
fn protecting_owner_files(
  base: policy.SandboxPolicy,
  files: Option(OwnerFiles),
) -> policy.SandboxPolicy {
  case files {
    None -> base
    Some(OwnerFiles(index:, memory_store:, memory_digest:)) ->
      protecting_index(base, index)
      |> protecting_memory(memory_store, memory_digest)
  }
}

/// The policy meet keeps only the environment names the session base
/// allows, and the base allows `PATH` and `HOME` but not `TMPDIR`. The
/// bash tool passes `TMPDIR` (see `session_environment`), so the name is
/// granted on the session base here — the same move the code-mode
/// builder makes on its own derived base, for the same variable. The
/// helper-owned `LOOM_SCRATCH_DIR` travels through the same allowlists;
/// reserving it here lets the helper expose its private directory.
///
/// Public to this package for the reason `under_tools_config` is: the
/// composed allowlist is a value a test should be able to read back.
///
/// ## Examples
///
/// ```gleam
/// // workspace_policy.allowing_tool_tmpdir(base).env_allow  // contains "TMPDIR"
/// ```
///
@internal
pub fn allowing_tool_tmpdir(
  base: policy.SandboxPolicy,
) -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    ..base,
    env_allow: list.unique(
      list.append(base.env_allow, [
        "TMPDIR",
        "LOOM_SCRATCH_DIR",
        git_identity.environment_name,
      ]),
    ),
  )
}

/// `CLAUDE_PROJECT_DIR` granted on the session base, for the same
/// reason `allowing_tool_tmpdir` grants `TMPDIR`.
///
/// An imported hook's process is cleared with `RefuseNarrowed`, and its
/// requirements name exactly the keys of the environment
/// `with_imported_hooks` composes — which carries `CLAUDE_PROJECT_DIR`
/// because the contract's payload and scripts both expect it. A name in
/// that environment and not on the base's allowlist is not a missing
/// variable, it is a refusal of the whole call: `policy.meet` intersects
/// `env_allow`, `shortfall` reports the narrowing, and the broker turns
/// that into `PolicyRefused` before any process exists. Granting it here
/// is what keeps the hook runner's ask a subset of the base.
///
/// ## Examples
///
/// ```gleam
/// // workspace_policy.allowing_imported_hook_env(base).env_allow
/// //   // contains "CLAUDE_PROJECT_DIR"
/// ```
///
@internal
pub fn allowing_imported_hook_env(
  base: policy.SandboxPolicy,
) -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    ..base,
    env_allow: list.unique(list.append(base.env_allow, ["CLAUDE_PROJECT_DIR"])),
  )
}

// Keep the discovered Loom toolchain first, then operator and host tools,
// then system fallbacks. Putting system launchers ahead of the operator's
// installed Git and Python made an explicit PATH addition ineffective.
fn extending_path(
  environment: List(#(String, String)),
  extra: List(String),
) -> List(#(String, String)) {
  case extra {
    [] -> environment
    dirs ->
      list.map(environment, fn(pair) {
        case pair {
          #("PATH", value) -> {
            let current = string.split(value, ":")
            let fallback = ["/usr/local/bin", "/usr/bin", "/bin"]
            let bundled =
              list.filter(current, fn(path) { !list.contains(fallback, path) })
            let ordered =
              list.flatten([bundled, dirs, current])
              |> list.filter(fn(path) { filepath.is_absolute(path) })
              |> list.unique
            #("PATH", string.join(ordered, ":"))
          }
          other -> other
        }
      })
  }
}

/// The operator's `[tools]` table applied to the session base: the
/// network posture they chose, and every name their two lists mention
/// added to the environment allowlist.
///
/// The second half is what makes the first half reach a shell, and it is
/// exactly `allowing_tool_tmpdir`'s argument one table further on.
/// `policy.meet` intersects `env_allow`, and a jailed tool asks for
/// precisely the names in `Ctx.env` — so a variable that is in the
/// environment and not on the base's allowlist is a narrowing refusal
/// rather than a variable.
///
/// Public to this package for the reason `base_policy_fault` is: this is
/// a decision about a value, and it should be testable as one rather than
/// through a boot that has nowhere to hand its composed policy back.
///
/// ## Examples
///
/// ```gleam
/// // workspace_policy.under_tools_config(base, tools).network == policy.NetworkFull
/// ```
///
@internal
pub fn under_tools_config(
  base: policy.SandboxPolicy,
  tools: catalog.ToolsConfig,
) -> policy.SandboxPolicy {
  let configured =
    list.append(tools.env, list.map(tools.set, fn(pair) { pair.0 }))
  policy.SandboxPolicy(
    ..base,
    network: configured_network(tools.network),
    env_allow: list.unique(list.append(base.env_allow, configured)),
  )
}

// The catalogue's two-word posture as the policy lattice's own value.
// `NetworkProxy` is deliberately unreachable from here: the broker
// downgrades it to `NetworkOff` in phase 1 (`broker/policy`'s module
// doc), so a config word for it would promise host filtering that nothing
// on this path enforces.
fn configured_network(network: catalog.ToolNetwork) -> policy.NetworkPolicy {
  case network {
    catalog.ToolNetworkOff -> policy.NetworkOff
    catalog.ToolNetworkFull -> policy.NetworkFull
  }
}

/// The Go caches' boot refusals against the composed base, so the masked
/// paths of this session are all known. Absent caches have nothing to
/// refuse.
///
/// ## Examples
///
/// ```gleam
/// assert workspace_policy.go_cache_fault(basis_with_no_caches, base) == Ok(Nil)
/// ```
///
pub fn go_cache_fault(
  basis: Basis,
  base: policy.SandboxPolicy,
) -> Result(Nil, String) {
  case basis.go_caches {
    None -> Ok(Nil)
    Some(caches) ->
      gocache.fault(
        caches,
        basis.workspace,
        base.protected,
        base.mounts,
        tools_naming: list.append(
          basis.tools.env,
          list.map(basis.tools.set, fn(pair) { pair.0 }),
        ),
      )
  }
}

/// Makes the directories a workspace half needs before it starts, and
/// keeps the harness's own two out of the repository's `git status`.
///
/// `owner_directory` is the directory the owner keeps its session file in,
/// when the owner shares this machine; a workspace whose owner is elsewhere
/// passes `None`. The rest are the workspace itself, the blob overflow
/// directory, the helper scratch directory and the tool directories. The
/// first that cannot be created refuses the lot, naming it.
///
/// ## Examples
///
/// ```gleam
/// // workspace_policy.prepare_directories(None, "/work", "/work/.blobs", "/s.tmp", [])
/// // -> Ok(Nil)
/// ```
///
pub fn prepare_directories(
  owner_directory: Option(String),
  workspace: String,
  blob_root: String,
  tmp_dir: String,
  tool_dirs: List(String),
) -> Result(Nil, String) {
  let wanted = [
    owner_directory,
    Some(workspace),
    Some(blob_root),
    Some(tmp_dir),
  ]
  let directories = list.append(option.values(wanted), tool_dirs)
  use Nil <- result.try(create_directories(directories))

  // Both workspace directories are the harness's, not the operator's,
  // and without this they sit in every `git status` of the repository a
  // session works in, and every `rg` walks the module caches beneath
  // the tool home.
  list.each(
    [
      blob_root,
      workspace <> "/" <> codemode_wiring.work_directory,
    ],
    ignore_directory,
  )
  Ok(Nil)
}

/// The ignore file a harness-owned workspace directory carries: one
/// pattern that ignores every entry, the file included, so the directory
/// drops out of `git status` without touching the repository's own
/// ignore files or resolving where a linked worktree keeps its metadata.
@internal
pub const ignore_everything =
  "# Written by loom: this directory is harness state.\n*\n"

// Writes the ignore file only where none exists, so an operator who
// replaced it with rules of their own keeps them. A write that fails is
// ignored: the file keeps `git status` tidy and nothing reads it, so a
// directory left unwritable by an earlier container run must not cost the
// session its boot.
fn ignore_directory(directory: String) -> Nil {
  let path = directory <> "/.gitignore"
  case simplifile.is_file(path) {
    Ok(True) -> Nil
    Ok(False) | Error(_) -> {
      let _hygiene = simplifile.write(path, ignore_everything)
      Nil
    }
  }
}

/// Creates each directory with its parents, stopping at the first that
/// cannot be made and naming it in the refusal.
///
/// ## Examples
///
/// ```gleam
/// assert workspace_policy.create_directories([]) == Ok(Nil)
/// ```
///
pub fn create_directories(directories: List(String)) -> Result(Nil, String) {
  list.try_each(directories, fn(directory) {
    simplifile.create_directory_all(directory)
    |> result.map_error(fn(error) {
      "could not create " <> directory <> ": " <> string.inspect(error)
    })
  })
}

/// The directory a path sits in, or `None` for a bare file name.
///
/// ## Examples
///
/// ```gleam
/// assert workspace_policy.parent_directory("/data/session.db")
///   == Some("/data")
/// assert workspace_policy.parent_directory("session.db") == None
/// ```
///
pub fn parent_directory(path: String) -> Option(String) {
  case list.reverse(string.split(path, "/")) {
    [_file, ..rest] if rest != [] -> Some(string.join(list.reverse(rest), "/"))
    _ -> None
  }
}

// --- the search index ------------------------------------------------------

/// The base policy with the search index protected: never writable, by
/// any jailed process or by the harness's own write tools.
///
/// This is a security property rather than hygiene, and it is the same
/// argument the blob store's protection rests on one step further along.
/// Search snippets are read back into *future* sessions' contexts, so an
/// index a model can write is a channel from one execution's output into
/// a later execution's input — prompt injection with a persistence
/// layer. Writing is the whole of the poisoning path: `protected` bars
/// writes and leaves reads alone, which is exactly the asymmetry wanted,
/// since the harness's own indexing never goes through `resolve_writable`
/// and a model reading the file learns nothing it could not ask
/// `history_search` for.
///
/// ## Examples
///
/// ```gleam
/// // workspace_policy.protecting_index(base, "/data/loom-search.db").protected
/// ```
///
pub fn protecting_index(
  base: policy.SandboxPolicy,
  index_path: String,
) -> policy.SandboxPolicy {
  // The whole SQLite file family, not the database alone (see
  // `sqlite_side_files`), enumerated rather than protected as a
  // directory because the index sits beside the session file, where a
  // protected directory would swallow paths the operator owns. The
  // database itself is always protected: the boot's probe creates it.
  // The side files are conditional, on the argument `protecting` states.
  protecting(
    base,
    always: [index_path],
    where_maskable: sqlite_side_files(index_path),
  )
}

/// The base policy with this repository's memory protected: the digest
/// sidecar the server injects at every run start, and the store the
/// digest is rendered from.
///
/// The same argument `protecting_index` makes, one step further along
/// and one degree more direct. A search snippet reaches a later session
/// only if a model searches for it; the memory digest is injected into
/// **every** run of every session on this repository, unasked. A
/// model-writable digest would therefore be the cleanest prompt-injection
/// channel in the tree.
///
/// Both files are conditional, and unlike the index this is not a
/// refinement but a requirement: neither exists until a distillation run
/// has happened, and the jail refuses to mask a *missing* protected path
/// under a read-only parent — the failure that once turned the index's
/// side-file list into a refusal of every jailed call. So the mask
/// arrives with the file. Until then there is nothing to protect: a
/// digest that does not exist injects nothing, and under a read-only
/// parent the jail makes it uncreatable.
///
/// The wrapper is the other half of this bargain and does not depend on
/// it: `client/memory.wrapped` builds the fence and the attribution at
/// injection time, so even a digest somebody managed to write cannot
/// claim to be operator text.
///
/// ## Examples
///
/// ```gleam
/// // workspace_policy.protecting_memory(base, "/d/loom-memory.db", "/d/loom-memory.digest")
/// ```
///
pub fn protecting_memory(
  base: policy.SandboxPolicy,
  store_path: String,
  digest_path: String,
) -> policy.SandboxPolicy {
  protecting(base, always: [], where_maskable: [
    store_path,
    digest_path,
    ..sqlite_side_files(store_path)
  ])
}

/// Every path under the daemon's state root that must stay masked from
/// every jail, as a function of that root.
///
/// This is the candidate list rather than the effective one. What a
/// given session gets is `protecting_state_root`'s output, where the
/// lazily created half is filtered by whether the jail can be handed the
/// mask at all; read that function before concluding an entry here is
/// live for a particular policy.
///
/// The list exists because the state root as a whole must not be the
/// mask. Masking `~/.loom` wholesale reads as prudence and is a bug: an
/// operator who opens a session *on* the state root — to edit
/// `loom.toml`, which is a reasonable thing to want Loom's help with —
/// gets a Seatbelt profile denying reads over the jail's own working
/// directory, and every jailed call comes back
/// `getcwd: cannot access parent directories`. The workspace was
/// legitimate; the grain was wrong.
///
/// So each entry is decided on one question: could a jailed process
/// reading or writing it obtain a credential, another session's data, or
/// the daemon's control? What the state root holds that answers no —
/// the `loom*.toml` catalogues (they name environment variables, they do
/// not carry secrets), `extensions/`, `logs/` and `daemon.log` — is left
/// alone, because masking it buys nothing and costs the operator a
/// directory they may want to work in.
///
/// The blob store is masked too, one layer up rather than here:
/// `base_policy` protects `<workspace>/.blobs` for every workspace, so a
/// session whose workspace *is* the state root already has it, and a
/// second entry naming the same path would be a duplicate mask.
///
/// ## Examples
///
/// ```gleam
/// // workspace_policy.state_root_mask_candidates("/home/o/.loom") |> list.contains("/home/o/.loom/owner.token")
/// ```
///
pub fn state_root_mask_candidates(state_root: String) -> List(String) {
  list.append(established_masks(state_root), lazy_masks(state_root))
}

/// The base policy with the daemon's state-root secrets masked, in place
/// of the state root itself.
///
/// The split between the two halves of the list is `protecting`'s
/// `always`/`where_maskable` distinction and it is load-bearing here for
/// the reason that comment gives: the jail refuses to mask a *missing*
/// protected path whose parent is read-only, and a refusal at that layer
/// is a refusal of every jailed call in the session. So only the entries
/// the daemon root has necessarily created before it admits any session
/// are unconditional; the lazily created ones are masked once they
/// exist, or before that where a writable root reaches them and the jail
/// can build the mask anyway. Neither half turns on whether the model
/// could write the entry — every one of these is a secret to read as
/// much as a file to forge.
///
/// ## Examples
///
/// ```gleam
/// // workspace_policy.protecting_state_root(base, "/home/o/.loom")
/// ```
///
pub fn protecting_state_root(
  base: policy.SandboxPolicy,
  state_root: String,
) -> policy.SandboxPolicy {
  protecting(
    base,
    always: established_masks(state_root),
    where_maskable: lazy_masks(state_root),
  )
}

// The masked entries `client/daemon/root.directories` and the startup
// that follows it have certainly created by the time any session policy
// is built, so masking them costs no existence question.
fn established_masks(state_root: String) -> List(String) {
  [
    // The daemon's owner credential in plaintext. A jailed process that
    // read it would hold `/v2/control` — every session on the host, and
    // the authority to create more.
    state_root <> "/owner.token",

    // The catalogue: registrations, workspaces and the digests the
    // daemon authenticates principals against. Reading it enumerates
    // every other session; writing it forges an admission record.
    state_root <> "/catalogue.db",

    // Every session's conversation database, this one's included. One
    // session's jail reading another's transcript is the confinement gap
    // issue #242 exists for, and a directory mask is the whole answer
    // for the sessions that live here.
    state_root <> "/sessions",

    // The root's lifetime lock. It carries no secret; it is the daemon's
    // singleton fence, and a jailed process that could unlink or rewrite
    // it could induce a second daemon over the same catalogue.
    state_root <> "/daemon.lock",

    // The code-mode socket root. Each directory under it holds one
    // execution's cap socket, and only that execution's satellite is
    // given its directory back (`client/codemode.reaching_socket`). The
    // mask stops every other jail listing it on both platforms, and
    // stops connecting under bubblewrap. Seatbelt allows unix-socket
    // connects by path regardless, so on macOS the unlisted digest name
    // is what keeps another jail from the socket.
    state_root <> "/" <> codemode_wiring.runtime_directory,
  ]
}

// The masked entries created lazily — by a launcher, by the first
// session on a workspace, or by the daemon after it is already serving.
// Every one of them is masked once it is on disk, which on a host that
// has run a launcher or a second session is all of them. The condition
// exists for the window before that: `protecting` cannot hand the jail a
// path which neither exists nor has a writable parent, because the jail
// refuses such a mask and the refusal takes the whole session with it.
fn lazy_masks(state_root: String) -> List(String) {
  list.flatten([
    // The catalogue runs in WAL mode, so a write to `-wal` is the same
    // forgery one filename to the right. Conditional for the reason
    // `protecting_index`'s side files are: `-journal` exists only after
    // a failed WAL pragma.
    sqlite_side_files(state_root <> "/catalogue.db"),
    [
      // The key every browser login is signed and verified under, created by
      // the first daemon started with `--ui` (protocol-change/065). A jailed
      // process that read it could mint a login for any principal, the owner
      // included, and one that rewrote it would end every login in the daemon.
      state_root <> "/browser.key",

      // The launcher's per-endpoint bearer tokens. Credentials, plainly:
      // one of these attaches to the session it names.
      state_root <> "/tokens",

      // The launcher's per-endpoint locks, on `daemon.lock`'s argument:
      // the daemon's exclusion, not the model's to take or break.
      state_root <> "/locks",

      // Per-workspace domain state — the memory store and search index
      // every session on that workspace injects from. `protecting_memory`
      // states why a model-writable digest is the cleanest injection
      // channel in the tree; this is the same door for *other*
      // workspaces.
      state_root <> "/workspaces",

      // The session-scoped half of the same domain state.
      state_root <> "/domains",

      // The endpoint records, and the one the daemon publishes. They
      // carry no secret — `host/endpoint`'s schema deliberately holds no
      // credential, workspace or session path — but a launcher adopts a
      // running daemon by the PID and birth marker it reads here, so a
      // jailed rewrite points the operator's next launch at a process of
      // the model's choosing. Masked as control, not as confidentiality.
      state_root <> "/endpoints",
      state_root <> "/daemon.endpoint",

      // The launcher's startup lock, on `daemon.lock`'s argument.
      state_root <> "/launch.lock",
    ],
  ])
}

// The whole SQLite file family beside a database: it runs in WAL mode,
// so `-wal` and `-shm` live beside it and a write to either is the same
// poisoning door one filename to the right — WAL frame checksums are not
// cryptographic, so a crafted `-wal` is served as content on the next
// read. `-journal` covers the rollback fallback a failed WAL pragma
// leaves.
fn sqlite_side_files(path: String) -> List(String) {
  [path <> "-wal", path <> "-shm", path <> "-journal"]
}

// The one conditional-protection mechanism, shared by the index, by
// memory and by the daemon's state-root masks rather than copied for
// each.
//
// `always` is for paths that certainly exist by the time a jail is
// built — the index database, which the boot's probe creates, and the
// four entries the daemon root writes before it admits a session —
// because masking an existing file needs nothing from its parent.
//
// `where_maskable` is for everything else, and the condition is the
// jail's own refusal rather than a threat model: a protected path that
// neither exists nor sits under a writable parent is one the jail
// declines to mask, and that decline is a refusal of every jailed call
// in the session. So an entry survives the filter when it is there to be
// masked, or when a writable root reaches it and the jail can therefore
// create the mask under a parent it may write. An entry that fails both
// is one no jail could be handed at all, not one whose exposure was
// judged acceptable — masking has nothing to do with whether the model
// could write it, only with whether the mask can be built.
//
// The residual is stated rather than hidden: an entry that has not been
// created yet, under a read-only parent, is unmasked until it appears,
// and a session that began before it appeared keeps the policy it
// booted with.
fn protecting(
  base: policy.SandboxPolicy,
  always always: List(String),
  where_maskable conditional: List(String),
) -> policy.SandboxPolicy {
  let maskable =
    list.filter(conditional, fn(path) {
      exists(path) || writable_touches(base, path)
    })
  policy.SandboxPolicy(
    ..base,
    protected: list.flatten([
      always,
      maskable,
      base.protected,
    ]),
  )
}

// Whether a path is on disk, as a file or as a directory — the first
// half of `protecting`'s condition, and the half that decides the
// ordinary case, since a workspace outside the state root grants no
// writable root over it while every one of the daemon's lazily created
// entries is already there by the time a second session boots.
//
// An unreadable answer counts as absent. That is the conservative side
// of the missing-path refusal: a mask nothing needed costs one entry,
// while a mask the jail declines costs the whole session.
fn exists(path: String) -> Bool {
  result.unwrap(simplifile.is_file(path), False)
  || result.unwrap(simplifile.is_directory(path), False)
}

// Whether a jailed or harness-side write could reach `path` at all —
// the second half of `protecting`'s condition, and the one that lets a
// path which does not exist yet still be masked, because the jail can
// build a mask over a writable parent.
//
// Two ways it can, and only the first was once asked. A writable root
// may cover the path's *parent*, which is how a file gets created beside
// its siblings. Or a writable root may lie *inside* the path, which is
// how a directory entry like the state root's `tokens/` becomes
// writable without anything covering `~/.loom` itself. Asking only the
// first left such an entry unmasked *and* unrefused, so a workspace
// nested inside a secret directory would have quietly worked.
fn writable_touches(base: policy.SandboxPolicy, path: String) -> Bool {
  list.any(base.writable_roots, fn(root) {
    policy.covers(root: root, path: parent_of(path))
    || policy.covers(root: path, path: root)
  })
}

// The directory holding a path: everything before the last slash. The
// index path is absolute by construction (`index_path` resolves it), so
// there is always a slash to find.
fn parent_of(path: String) -> String {
  case string.split(path, "/") |> list.reverse {
    [_leaf, ..parents] -> parents |> list.reverse |> string.join("/")
    [] -> path
  }
}

/// How long the boot waits on the helper it spawns to ask whether this
/// host can confine anything. Above the pool's own handshake timeout, so
/// the helper actor has always settled into ready or dead by the time the
/// answer is due and the call cannot outrun it.
pub const helper_probe_ms = 15_000

/// Whether this host's helper advertises degraded enforcement, asked once
/// at session open by borrowing a helper from the pool the session will
/// use anyway. The system prompt has no other source for it: the
/// per-layer `skip:` report lives inside an `ExecResult`, which is after
/// a run, and the `ENFORCED`/`SKIPPED` table is a separate `--self-test`
/// process invocation.
///
/// A helper that will not spawn, or will not finish its handshake, is
/// reported as degraded — which is what it behaves as: under
/// `FullEnforcement` every jailed execution against it fails, and the
/// pack's degraded fragment says exactly that.
///
/// ## Examples
///
/// ```gleam
/// // workspace_policy.degraded(pool) == False   // a healthy loom-exec
/// ```
///
pub fn degraded(pool: Pool) -> Bool {
  case exec.checkout(pool, waiting: helper_probe_ms) {
    Error(_unavailable) -> True
    Ok(helper) -> {
      let answer = case exec.await_ready(helper, waiting: helper_probe_ms) {
        Ok(features) -> list.contains(features, "degraded")
        Error(_dead) -> True
      }
      exec.checkin(pool, helper)
      answer
    }
  }
}

/// The shell every jailed command runs under, and the shell the system
/// prompt tells the agent about. One constant so the two cannot drift:
/// a prompt that named a shell the helper does not use would be a lie
/// the agent could only discover by writing a broken command.
pub const shell_path = "/bin/sh"

/// The default development policy permits host reads and ordinary network
/// access, with writes confined to the workspace. Protected harness data
/// remains masked regardless of the readable scope.
///
/// Installed tools can live anywhere on the host; the policy does not guess
/// language managers, SDK directories, or package-cache locations.
///
/// ## Examples
///
/// ```gleam
/// assert workspace_policy.base_policy("/work").readable_roots == ["/"]
/// ```
pub fn base_policy(workspace: String) -> policy.SandboxPolicy {
  base_policy_for(workspace, catalog.HostReads)
}

/// Selects host or workspace reads without changing the write boundary.
/// Additional restricted-mode resources come from explicit workspace mounts.
///
/// ## Examples
///
/// ```gleam
/// assert workspace_policy.base_policy_for("/work", catalog.WorkspaceReads).readable_roots
///   == ["/work"]
/// ```
@internal
pub fn base_policy_for(
  workspace: String,
  scope: catalog.ReadScope,
) -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    ..policy.workspace_default(workspace),
    readable_roots: case scope {
      catalog.HostReads -> ["/"]
      catalog.WorkspaceReads -> [workspace]
    },
    network: policy.NetworkFull,
    // Content-addressed artifacts are written only by their harness owner.
    // Broad reads must never let a jailed tool replace one behind its hash.
    protected: [workspace <> "/" <> codemode_wiring.blob_directory],
  )
}

/// The base policy an install's build plane runs under: the staging root
/// writable, network off, and the daemon's state root masked where the
/// jail can build the mask. The toolchain reaches it as explicit mounts,
/// which `start_build_plane` admits once discovery has said where the
/// toolchain is.
///
/// Separate from `base_policy` because the blob mask is the one thing a
/// build plane must not inherit. A session's blob store exists — `boot`
/// creates it before it spawns a jail — and a session's jails are
/// writable in the workspace that holds it, so the mask is both
/// buildable and load-bearing there. An install has no blob store at
/// all: nothing under the extensions root is content-addressed, no
/// jailed step here emits a blob, and `codemode/build.build_requirements`
/// narrows the one writable root down to the build directory. The
/// inherited entry was therefore a mask over a path that did not exist,
/// under a parent the composed policy no longer let anyone write, which
/// is precisely the shape bwrap declines to build — and its refusal took
/// every jailed compile with it. Not constructing the entry is what
/// keeps that state out of reach; dropping it later would leave the same
/// mistake one composition step away.
///
/// The state root is the other half of that lesson applied the other
/// way. A build step is a jailed compile of code an operator fetched
/// from somewhere, and the state root sits one directory above the
/// extensions root it writes, so without a mask it can read
/// `<state_root>/owner.token` exactly as a session's jail once could.
/// Every entry goes in conditionally rather than unconditionally,
/// because the extensions root is `<state_root>/extensions` by default
/// and an install may be the first thing that ever runs on a host: a
/// daemon that has never started has written no token, and a mask over a
/// missing path under a read-only parent is the refusal this function's
/// first paragraph is about.
///
/// ## Examples
///
/// ```gleam
/// // workspace_policy.build_plane_policy("/home/o/.loom/extensions", "/home/o/.loom")
/// ```
///
pub fn build_plane_policy(
  writable: String,
  state_root: String,
) -> policy.SandboxPolicy {
  let base = policy.workspace_default(writable)
  protecting(
    base,
    always: [],
    where_maskable: list.flatten([
      established_masks(state_root),
      lazy_masks(state_root),
    ]),
  )
}

/// Why this server will not boot on the base policy it was given, worded
/// for the operator who wrote it.
///
/// `Settings.base_policy` is a *field*, so a host may serve any policy
/// value it can construct — and a policy the effect plane cannot
/// enforce is one this server must refuse to start on rather than start
/// and enforce differently in different places. The three checks are
/// `broker/policy.validate`'s, which is also the check every composed
/// policy passes immediately before dispatch, so what is refused here is
/// exactly what would be refused there.
///
/// A **relative `protected` entry** is the one worth naming. It reaches
/// the jail as `RelativePath` and refuses the clearance, loudly; it
/// reaches `tools/fs.resolve_writable` as a list nothing can be judged
/// against, which now refuses in band rather than covering nothing. Two
/// enforcement points agreeing to refuse is correct and still the wrong
/// place to learn about it — the operator finds out from the first tool
/// call of a live session, having been told nothing at boot. So the
/// value is checked once, before anything is spawned, and the server
/// does not come up.
///
/// A **workspace inside a mask** is the second refusal, and it is not
/// one `policy.validate` could make: the policy is perfectly
/// enforceable, and enforcing it shadows the session's own working
/// directory. `masked_workspace_fault` says what that cost, and
/// `state_root_mask_candidates` says why the daemon no longer causes it.
///
/// Pure, and separate from `boot` for that reason: this is a decision
/// about a value, and it should be testable as one.
///
/// ## Examples
///
/// ```gleam
/// assert workspace_policy.base_policy_fault(workspace_policy.base_policy("/work")) == Ok(Nil)
/// ```
///
pub fn base_policy_fault(base: policy.SandboxPolicy) -> Result(Nil, String) {
  use Nil <- result.try(
    policy.validate(base)
    |> result.map_error(fn(error) {
      "the session base policy is not one the sandbox can enforce: "
      <> policy_fault_text(error)
    }),
  )

  // The second refusal is about the *shape* of an enforceable policy
  // rather than its values, which is why `policy.validate` does not make
  // it: a workspace inside a mask is a policy the sandbox enforces
  // perfectly and the operator cannot use.
  masked_workspace_fault(base)
}

// Why a workspace this policy makes unusable is a refusal rather than a
// live session.
//
// `protected` is the policy's only subtractive verb and no grant carves
// a hole in one, so a writable root that is a masked entry or sits under
// one is shadowed by the mask whatever the grant says. That session
// comes up, and then every jailed call fails on its own working
// directory — the measured failure was `getcwd: cannot access parent
// directories` out of every `bash`, with `ls` printing nothing and the
// code-mode satellite unable to open `.`. The operator learns about it
// from the first tool call, having been told nothing at boot, so the
// value is judged once instead.
fn masked_workspace_fault(base: policy.SandboxPolicy) -> Result(Nil, String) {
  let shadowed =
    list.flat_map(base.protected, fn(entry) {
      list.filter_map(base.writable_roots, fn(root) {
        case policy.covers(root: entry, path: root) {
          True -> Ok(#(entry, root))
          False -> Error(Nil)
        }
      })
    })
  case shadowed {
    [] -> Ok(Nil)
    [#(entry, root), ..] ->
      Error(
        "the workspace `"
        <> root
        <> "` is the protected entry `"
        <> entry
        <> "`, or lies under it. Every jail masks that entry, so the "
        <> "session's own working directory would be unreadable and "
        <> "every tool call would fail on it. Choose another directory "
        <> "for the workspace",
      )
  }
}

fn policy_fault_text(error: policy.PolicyError) -> String {
  case error {
    policy.RelativePath(path:) ->
      "the path `"
      <> path
      <> "` is not absolute. Every writable root, readable root and "
      <> "protected entry must start with `/` — a relative protected "
      <> "entry is refused by the jail and covers nothing in the "
      <> "harness's own path checks, so it would protect nothing while "
      <> "looking as though it did"
    policy.NegativeLimit(field:, value:) ->
      "the limit `"
      <> policy.limit_field_name(field)
      <> "` is "
      <> int.to_string(value)
      <> ", and a resource ceiling cannot be negative (use 0 for "
      <> "unlimited)"
    policy.ScratchIsRoot ->
      "scratch names the host root `/`. Landlock has no deny rules, so a "
      <> "host-path scratch of `/` grants read-write over the whole "
      <> "filesystem at that layer whatever the mount layer does"
    policy.MountOverlapsProtected(mount:, protected:) ->
      "the mount `"
      <> mount
      <> "` overlaps the protected entry `"
      <> protected
      <> "`. No jail can carry out both: on Linux the mask and the bind "
      <> "fight over the same region and bubblewrap exits with a bare "
      <> "`Read-only file system`, and on Darwin the deny wins and the "
      <> "mount does nothing. Move the mount outside the protected "
      <> "region, or stop protecting it"
    policy.DuplicateMount(path:) ->
      "the mount path `"
      <> path
      <> "` appears twice, and the two entries have no agreed access. "
      <> "State the region once, at the access it should have"
    policy.MountPathTrailingSlash(path:) ->
      "the mount path `"
      <> path
      <> "` ends in a slash. Nothing on either side of the wire "
      <> "canonicalizes a mount path, so this would be a second name for "
      <> "a region already named without it"
    policy.MountPathParentSegment(path:) ->
      "the mount path `"
      <> path
      <> "` contains a `..` segment. Mount paths are compared by "
      <> "component against protected entries and roots before anything "
      <> "resolves them, so this would claim one region and bind another"
    policy.MountShadowsWritableRoot(mount:, writable_root:) ->
      "the read-only mount `"
      <> mount
      <> "` covers the writable root `"
      <> writable_root
      <> "`. On Linux every explicit mount is applied after the roots, so "
      <> "the jail would see that root read-only and every write under it "
      <> "would fail; on Darwin it would stay writable. Mount a directory "
      <> "beside the writable root rather than above it, or make the mount "
      <> "read-write"
  }
}

/// One server with its `readable` and `writable` roots resolved to
/// absolute paths, once, at load. The jail resolves them again at every
/// start and would refuse the same way; refusing here instead is what
/// makes the refusal an operator-visible boot line rather than a
/// `no_server` answer the model meets on its first query.
///
/// A root that resolves into Loom's private cache, `<cache>/loom`, or a
/// writable one that holds it, is refused here too
/// (`profile.private_cache_fault`): the decoder can refuse one written
/// `<cache>/loom` but not an absolute or `~/` root, which only these
/// places can put there.
///
/// The private caches `cache_env` names are resolved here for the same
/// refusal and then left as written: their host paths are the jail's to
/// derive (`profile.cache_env_paths`), and the directories are made by the
/// manager just before a jail binds them, not here, so a server nobody
/// queries creates nothing.
///
/// Public because `loom ext check` starts a server exactly as a session
/// would, and a second expansion there would be a second answer to where
/// a profile's `~/` and `<cache>/` roots are.
///
/// ## Examples
///
/// ```gleam
/// // workspace_policy.lsp_server_roots(go, workspace_policy.lsp_places())
/// // -> Ok(LspServer(..go, readable: [AbsolutePath("/home/o/go/pkg/mod")], ..))
/// ```
///
pub fn lsp_server_roots(
  server: profile.LspServer,
  places: profile.Places,
) -> Result(profile.LspServer, String) {
  let absolute = fn(paths) {
    list.try_map(paths, fn(path) {
      profile.expand_path(path, places) |> result.map(profile.AbsolutePath)
    })
  }
  use readable <- result.try(absolute(server.readable))
  use writable <- result.try(absolute(server.writable))

  // Only here are the daemon's places known, so only here can an absolute
  // or `~/` root be found to land in Loom's private cache; the decoder
  // has already refused one written `<cache>/loom`.
  use Nil <- result.try(profile.private_cache_fault(server, places))
  use _caches <- result.try(
    list.try_map(profile.cache_env_paths(server), fn(entry) {
      profile.expand_path(entry.1, places)
    }),
  )
  Ok(profile.LspServer(..server, readable:, writable:))
}

/// The two places a language profile's roots are written against, read
/// from the daemon's own environment once per boot: `HOME` for `~/`, and
/// the per-user cache directory for `<cache>/`. Which directory that is
/// depends on the platform, and `profile.cache_place` decides it purely
/// from what is read here.
///
/// Public for `loom ext check`, which expands a profile's roots the way a
/// session does, from the same environment.
///
/// ## Examples
///
/// ```gleam
/// // workspace_policy.lsp_places()
/// // -> profile.Places(home: Some("/home/o"), cache: Some("/home/o/.cache"))
/// ```
///
pub fn lsp_places() -> profile.Places {
  let home = home_directory()
  let #(os, _architecture) = ffi_os.platform()
  profile.Places(
    home:,
    cache: profile.cache_place(
      os,
      home,
      option.from_result(env_text("XDG_CACHE_HOME")),
    ),
  )
}

/// The language profiles the loaded profile extensions approved, each
/// paired with its extension's name for a refusal to cite. Read from the
/// install record rather than the manifest beside it: discovery has
/// already refused any extension whose manifest's profiles differ from the
/// record's, and the record is the operator's yes. A jailed extension's
/// record holds none.
///
/// ## Examples
///
/// ```gleam
/// assert workspace_policy.installed_profiles([]) == []
/// ```
///
pub fn installed_profiles(
  discovered: List(installed.Discovered),
) -> List(#(String, profile.LspServer)) {
  list.flat_map(discovered, fn(found) {
    case found {
      installed.Ready(record: written, manifest: _, artifact: _) ->
        list.map(written.lsp, fn(server) { #(written.name, server) })
      installed.Refused(..) -> []
    }
  })
}
