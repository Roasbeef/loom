//// Where the real-helper suites put their on-disk state.
////
//// Two hazards meet in this one path, and both have already cost a real
//// debugging session, so the choice lives here rather than being spelled
//// out again at each call site.
////
//// The first is the length of an AF_UNIX bind address. A cap socket path
//// longer than the kernel's `sun_path` limit — 104 bytes on macOS, 108 on
//// Linux — fails `bind` with `einval`, which reads as a kernel fault when
//// the real cause is a checkout sitting deeper than a socket path allows.
//// That is why these suites prefer a shallow directory under `HOME` over
//// one under the package's own `build/`, and why the per-checkout
//// component below is a twelve-character digest rather than the checkout
//// path itself. `/tmp` is not an option: the production jail replaces it
//// with the scratch tmpfs and correctly refuses a cap socket hidden there.
////
//// The second is collision between two checkouts of this repository on one
//// machine. Every suite here deletes its root before use, so a single
//// shared `HOME` directory means one checkout's rig can delete another
//// checkout's live workspace, cap socket and token directory while an
//// execution is still running against them. That was observed as a
//// code-mode end-to-end failure where a rebuild of the same source
//// produced a different `manifest_hash`, because the second build compiled
//// against a tree the other checkout had re-seeded underneath it. Keying
//// the base on the running checkout's own directory removes the sharing,
//// which is why the digest is part of the path and must stay there.

import gleam/bit_array
import gleam/string
import simplifile
import support/internal/ffi_peer
import tools/blob

/// How many hex characters of the checkout digest go into the path. Twelve
/// is far more than enough to separate the handful of checkouts one machine
/// carries, and it is short enough to leave the socket path well inside the
/// `sun_path` bound.
pub const tag_length = 12

/// The most bytes a cap socket path may occupy. The launcher enforces the
/// same budget, chosen below the smaller of the two kernel limits so a path
/// that fits here fits on both platforms.
pub const socket_path_budget = 100

/// The scratch base for the current checkout: `LOOM_TEST_SCRATCH` when it
/// is set, otherwise a per-checkout directory under `HOME`, otherwise the
/// package's own `build/` tree.
///
/// ## Examples
///
/// ```gleam
/// let dir = scratch.base() <> "/e2e-happy"
/// ```
///
pub fn base() -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner must have a working directory"

  base_for(
    configured: ffi_peer.get_env("LOOM_TEST_SCRATCH"),
    home: ffi_peer.get_env("HOME"),
    checkout: here,
  )
}

/// The pure choice `base` makes, with the environment passed in so the
/// decision can be tested without one.
///
/// An explicitly configured scratch root is taken as given: whoever set it
/// accepted responsibility for both its length and its uniqueness. The
/// `HOME` branch is the one that must not be shared, so it carries the
/// checkout digest. The last branch stays inside the checkout already and
/// so needs no digest; it is also the branch most likely to overflow the
/// socket bound, which the launcher's own guard reports by name.
///
/// ## Examples
///
/// ```gleam
/// let base =
///   scratch.base_for(
///     configured: Error(Nil),
///     home: Ok("/Users/me"),
///     checkout: "/src/loom/packages/codemode",
///   )
/// assert string.starts_with(base, "/Users/me/.loom-cmtest/")
/// ```
///
pub fn base_for(
  configured configured: Result(String, Nil),
  home home: Result(String, Nil),
  checkout checkout: String,
) -> String {
  case configured, home {
    Ok(scratch), _ -> scratch
    Error(Nil), Ok(home) -> home <> "/.loom-cmtest/" <> tag(checkout)
    Error(Nil), Error(Nil) -> checkout <> "/build/e2e-codemode"
  }
}

/// The short, stable identifier for a checkout directory: the first
/// `tag_length` hex characters of its SHA-256 digest.
///
/// The digest is what keeps the path short. Embedding the checkout path
/// itself would identify the checkout just as well and would push the cap
/// socket straight through the `sun_path` limit, which is the failure this
/// module exists to avoid.
///
/// ## Examples
///
/// ```gleam
/// assert scratch.tag("/a") != scratch.tag("/b")
/// ```
///
pub fn tag(checkout: String) -> String {
  checkout
  |> bit_array.from_string
  |> blob.ref_for
  |> string.drop_start(string.length("sha256-"))
  |> string.slice(at_index: 0, length: tag_length)
}

/// A fresh directory named `name` under the current checkout's scratch
/// base, with any state left by a previous run removed.
///
/// ## Examples
///
/// ```gleam
/// let dir = scratch.fresh("launch-happy")
/// ```
///
pub fn fresh(name: String) -> String {
  let dir = base() <> "/" <> name
  let _cleared = simplifile.delete(dir)
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
    as "the scratch directory must be creatable"

  dir
}
