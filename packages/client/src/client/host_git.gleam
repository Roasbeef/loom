//// Which Git executable the server's fixed, jailed Git calls name.
////
//// On macOS, `/usr/bin/git` is not Git. It is Apple's Xcode shim, which runs
//// `xcrun` to find the selected developer directory's `git` and then execs
//// it. `xcrun` keeps a lookup cache in the per-user temporary directory,
//// keyed partly on `HOME`; on a miss it rewrites the whole database through a
//// temporary file and a rename. The cache grows past one megabyte on an
//// ordinary developer machine, while the server's read-only Git calls run
//// under a one-megabyte `RLIMIT_FSIZE`. A cache miss inside the jail is
//// therefore killed by `SIGXFSZ` before Git starts, and every identity query
//// run with a fresh `HOME` failed that way.
////
//// The cache rewrite is `xcrun`'s own work, not Git's, so the fix is to not
//// run `xcrun` inside the jail at all. The server asks `xcrun --find git` once,
//// on the host and outside every jail, when it assembles a session, and the
//// jailed calls name the binary it answers. That query is the operator's own
//// toolchain lookup, of the same kind as resolving `git` against `PATH`, and it
//// runs without the jail's file-size limit. Linux has no shim, and a Git found
//// anywhere other than `/usr/bin/git` is used as found.

import client/internal/ffi_os
import filepath
import gleam/bool
import gleam/list
import gleam/result
import gleam/string
import host/bootstrap

/// The one path macOS installs its Xcode Git shim at. The shims live only in
/// the SIP-protected `/usr/bin`; a Git elsewhere, such as Homebrew's, is a real
/// binary and must not be replaced by the Xcode toolchain's copy.
pub const xcode_shim = "/usr/bin/git"

/// The host family, as far as Git resolution cares.
pub type Platform {
  /// macOS, where `/usr/bin/git` is an `xcrun` shim.
  Darwin

  /// Every other host, where the Git on `PATH` is the binary itself.
  OtherPlatform
}

/// The host queries resolution depends on, injectable so the decision can be
/// tested without a Mac or an Xcode installation.
pub type Probes {
  Probes(
    /// Which host family the server runs on.
    platform: Platform,
    /// Resolves an executable name against the server's own `PATH`.
    find: fn(String) -> Result(String, String),
    /// Asks the host's `xcrun` for the selected toolchain's Git binary.
    xcrun: fn() -> Result(String, Nil),
  )
}

/// Resolves the Git binary for jailed calls from the given host probes.
///
/// The `xcrun` probe runs only when the Git on `PATH` is the Xcode shim on
/// Darwin. When `xcrun` is absent or fails, the found path is kept: the call
/// then behaves exactly as it did before this resolution existed.
///
/// ## Examples
///
/// ```gleam
/// let probes =
///   host_git.Probes(
///     platform: host_git.Darwin,
///     find: fn(_) { Ok("/usr/bin/git") },
///     xcrun: fn() { Ok("/Library/Developer/CommandLineTools/usr/bin/git") },
///   )
/// assert host_git.resolve(probes)
///   == Ok("/Library/Developer/CommandLineTools/usr/bin/git")
/// ```
pub fn resolve(probes: Probes) -> Result(String, String) {
  use found <- result.map(probes.find("git"))
  case probes.platform {
    Darwin if found == xcode_shim -> result.unwrap(probes.xcrun(), found)
    Darwin | OtherPlatform -> found
  }
}

/// The executable name session assembly places in `argv[0]` of every fixed
/// Git call: the host-resolved binary, or the bare name `git` when the server
/// finds none, which leaves the lookup to the jail's `PATH` and lets the call
/// fail there as it always has.
///
/// Call it once per assembly. It runs `xcrun` on a Mac whose `PATH` leads to
/// the shim, and that cost belongs to assembly, not to each Git invocation.
///
/// ## Examples
///
/// ```gleam
/// // host_git.program()
/// // -> "/Applications/Xcode.app/Contents/Developer/usr/bin/git"
/// ```
pub fn program() -> String {
  host_probes()
  |> resolve
  |> result.unwrap("git")
}

/// Places the resolved Git ahead of toolchain shims for subprocess lookup.
///
/// Language servers invoke Git by name rather than receiving an explicit
/// argv. This changes lookup only; the jail's filesystem policy still decides
/// whether that executable can be read. An unresolved shim leaves PATH intact.
///
/// ## Examples
///
/// ```gleam
/// assert host_git.tool_path("/usr/bin:/bin", "/Library/Developer/bin/git")
///   == "/Library/Developer/bin:/usr/bin:/bin"
/// ```
pub fn tool_path(path: String, git: String) -> String {
  case git {
    "/" <> _ if git != xcode_shim ->
      [filepath.directory_name(git), ..string.split(path, ":")]
      |> list.unique
      |> string.join(":")
    _ -> path
  }
}

/// The production probes: `os:type/0`, `os:find_executable/1`, and a bounded
/// run of the host's `/usr/bin/xcrun`.
///
/// ## Examples
///
/// ```gleam
/// // host_git.resolve(host_git.host_probes())
/// ```
pub fn host_probes() -> Probes {
  let platform = case ffi_os.platform() {
    #("darwin", _) -> Darwin
    #(_, _) -> OtherPlatform
  }
  Probes(platform:, find: bootstrap.find_executable, xcrun: xcrun_find)
}

// The absolute `xcrun` path keeps a model-influenced `PATH` from choosing what
// answers. The answer must be an absolute path to an executable file; anything
// else is treated as a failed query, and the caller keeps the shim path.
fn xcrun_find() -> Result(String, Nil) {
  use #(code, output) <- result.try(
    ffi_os.run_capture("/usr/bin/xcrun", ["--find", "git"], 5000)
    |> result.replace_error(Nil),
  )
  let path = string.trim(output)
  use <- bool.guard(
    code != 0
      || !string.starts_with(path, "/")
      || !bootstrap.is_executable_file(path),
    Error(Nil),
  )
  Ok(path)
}
