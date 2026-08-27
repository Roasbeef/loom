//// Where this Loom is installed, and what ships beside it.
////
//// Every lookup the server performs for a *component of itself* — the
//// sandbox helper, the emulator a satellite is launched with, the Gleam
//// compiler a code-mode program is built with, the build seed that build
//// is cloned from — used to start at `PATH`. `PATH` answers "what has
//// some installation on this machine put in front of me", and the
//// question being asked is "what shipped in the same tree as the code
//// now running".
////
//// ## What `PATH` was already doing, which is not nothing
////
//// This module exists over a fact that has to be stated plainly, because
//// without it the rungs below look like they fix more than they do.
//// **OTP's `erl` start script prepends `$BINDIR:$ROOTDIR/bin` to `PATH`
//// before it execs the emulator.** So inside a release's VM, `PATH`
//// already begins with the release's own `erts-<vsn>/bin` and its own
//// `bin/` — measured: booting the release with `env -i
//// PATH=/usr/bin:/bin` gives an in-VM `PATH` of
//// `<root>/erts-16.4.0.5/bin:<root>/bin:/usr/bin:/bin`.
////
//// Three things follow, and all three are load-bearing here.
////
//// - A release was **not** failing to find `erl`, and would not fail to
////   find a `loom-exec` or a `gleam` placed in its `bin/`. The launcher's
////   `--helper` injection was never doing work, which is why removing it
////   is safe.
//// - The precedence worry — a stray `loom-exec` from an unrelated
////   install outranking the audited one beside the server — does not
////   arise in a release either, because the tree's own `bin` is at the
////   *front* of that `PATH`. It does arise in every non-release run, and
////   nothing here helps there: under an OTP installation root there is no
////   `loom-exec` to find, so a checkout still resolves `PATH` before
////   `./bin`, and an operator who cares passes `--helper`.
//// - A release that works *because a start script rewrites `PATH`* is an
////   accident being relied on. It is undocumented, it is inherited by
////   every process the VM later spawns, and it stops being true the day
////   the launcher execs `beam.smp` directly. Asking OTP where the
////   installation is states the intent instead — and it is the only thing
////   that answers for the build seed at all, since `share/codemode-seed`
////   is not an executable and no `PATH` mechanism will ever find it.
////
//// ## The anchor
////
//// "The directory of the running executable" is the obvious phrasing and
//// it is ambiguous on the BEAM. The thing the operating system executed
//// is `beam.smp`, several directories down inside `erts-<vsn>/bin`; the
//// thing the operator typed is a shell script that has already `exec`ed
//// away. Neither is the release root.
////
//// OTP answers the question itself. `code:root_dir/0` is the `ROOTDIR`
//// the emulator resolved for itself at boot, and it returns:
////
//// | how Loom was started | `code:root_dir()` |
//// |---|---|
//// | an unpacked release, through its launcher | the release root — the directory holding `bin/`, `lib/`, `releases/` and `erts-<vsn>/` |
//// | `gleam run`, the erlang shipment, a dev shell | the OTP installation root the `erl` on `PATH` came from (`/usr/local/otp`, `/usr/lib/erlang`, an asdf or kerl prefix) |
////
//// It is absolute in both cases, it is independent of the working
//// directory, and it survives being reached through a launcher or a
//// symlink, because it is resolved by the emulator rather than by
//// whatever argv said. That is why the ladder is anchored here and not
//// in the launcher shell script: a fix that lived there would be the
//// same defect in a new place.
////
//// ## How it degrades off a release
////
//// The second row is not a failure and nothing here special-cases it.
//// The paths below are simply *probed*, and existence is the whole
//// discriminator:
////
//// - `bin/loom-exec` and `bin/gleam` do not exist under an OTP
////   installation root, so those rungs are skipped and the ladder falls
////   through to `PATH` exactly as it did before. (If a `loom-exec` ever
////   *is* installed there, then that is a Loom installed there and
////   finding it is right.)
//// - `erts-<vsn>/bin/erl` exists under **both**, and under an OTP
////   installation it is the very emulator executing this code. So that
////   rung answers on a development host too, and answers better than
////   `PATH` does — see `erl` below.
//// - `share/codemode-seed` exists only in a release built with the
////   code-mode bundle, so a development tree keeps using its own
////   `build/codemode-seed`.

import client/internal/ffi_os
import gleam/result
import simplifile

/// The root of the installation the harness VM is running out of: the
/// release tree for a release, the OTP installation root otherwise.
/// Absolute, and fixed for the life of the node.
///
/// ## Examples
///
/// ```gleam
/// // install.root() == "/opt/loom-0.1.0-linux-x86_64"
/// ```
///
pub fn root() -> String {
  ffi_os.code_root_dir()
}

/// Where a release keeps the sandbox helper: `<root>/bin/loom-exec`.
/// The path whether or not anything is there, because a lookup that
/// fails has to be able to name where it looked.
///
/// ## Examples
///
/// ```gleam
/// // install.helper() == "/opt/loom-0.1.0-linux-x86_64/bin/loom-exec"
/// ```
///
pub fn helper() -> String {
  root() <> "/bin/" <> helper_name
}

/// The name of the sandbox helper binary, stated once so the ladder's
/// three rungs cannot disagree about it.
pub const helper_name = "loom-exec"

/// Where a release keeps the bundled Gleam compiler: `<root>/bin/gleam`.
///
/// ## Examples
///
/// ```gleam
/// // install.gleam_compiler() == "/opt/loom-0.1.0-linux-x86_64/bin/gleam"
/// ```
///
pub fn gleam_compiler() -> String {
  root() <> "/bin/gleam"
}

/// The emulator of the ERTS this VM is *actually running*:
/// `<root>/erts-<version>/bin/erl`, with the version read from the live
/// system rather than globbed for.
///
/// This one is preferred over `PATH` even on a development host, and the
/// reason is not tidiness. A code-mode satellite loads `.beam` files the
/// hermetic build has just produced, and beam files carry a format
/// version. The emulator running the harness is by construction the one
/// whose OTP the build resolved against, whereas the first `erl` on
/// `PATH` is whichever installation a shell profile happens to point at —
/// which on a machine with two OTPs installed is a coin flip.
///
/// ## Examples
///
/// ```gleam
/// // install.erl() == "/usr/local/otp/erts-16.4.0.5/bin/erl"
/// ```
///
pub fn erl() -> String {
  root() <> "/erts-" <> ffi_os.erts_version() <> "/bin/erl"
}

/// Where a release keeps the bundled code-mode build seed:
/// `<root>/share/codemode-seed`.
///
/// ## Examples
///
/// ```gleam
/// // install.seed() == "/opt/loom-0.1.0-linux-x86_64/share/codemode-seed"
/// ```
///
pub fn seed() -> String {
  root() <> "/" <> seed_directory
}

/// The bundled seed's location relative to the installation root. The
/// release script writes it and this module reads it, so the two are
/// pinned to one constant rather than to two string literals.
pub const seed_directory = "share/codemode-seed"

/// `path` back again when a regular file is there, `Error(Nil)` when
/// anything else is — absent, a directory, or unreadable. Written to sit
/// in a `result.lazy_or` chain, which is what every ladder in this tree
/// is built from.
///
/// ## Examples
///
/// ```gleam
/// // install.existing_file("/bin/sh") == Ok("/bin/sh")
/// ```
///
pub fn existing_file(path: String) -> Result(String, Nil) {
  case simplifile.is_file(path) {
    Ok(True) -> Ok(path)
    Ok(False) | Error(_) -> Error(Nil)
  }
}

/// `path` back again when a directory is there, `Error(Nil)` otherwise.
/// The directory counterpart of `existing_file`; a build seed is a tree,
/// not a file.
///
/// ## Examples
///
/// ```gleam
/// // install.existing_directory("/tmp") == Ok("/tmp")
/// ```
///
pub fn existing_directory(path: String) -> Result(String, Nil) {
  case simplifile.is_directory(path) {
    Ok(True) -> Ok(path)
    Ok(False) | Error(_) -> Error(Nil)
  }
}

/// The sandbox helper shipped in the same tree as the running server, if
/// there is one.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(path) = install.bundled_helper()
/// ```
///
pub fn bundled_helper() -> Result(String, Nil) {
  existing_file(helper())
}

/// The code-mode build seed shipped in the same tree as the running
/// server, if there is one. Only a release built with the code-mode
/// bundle has one; the caller falls back to the workspace's own.
///
/// ## Examples
///
/// ```gleam
/// // let assert Error(Nil) = install.bundled_seed()
/// ```
///
pub fn bundled_seed() -> Result(String, Nil) {
  existing_directory(seed())
}

/// Runs a lookup ladder: the first rung that answers wins, and none of
/// the later ones is evaluated. Each rung is a thunk because every one
/// of them touches the filesystem, and a ladder whose lower rungs `stat`
/// on every call would be paying for answers it already has.
///
/// It exists as a named function so the *order* is a value a test can
/// hold still: precedence is the whole of what these ladders decide, and
/// a test that can only observe the outcome on the host it runs on
/// cannot observe an order at all.
///
/// ## Examples
///
/// ```gleam
/// // install.first_of([fn() { Error(Nil) }, fn() { Ok("b") }]) == Ok("b")
/// ```
///
pub fn first_of(
  rungs: List(fn() -> Result(String, Nil)),
) -> Result(String, Nil) {
  case rungs {
    [] -> Error(Nil)
    [rung, ..rest] -> rung() |> result.lazy_or(fn() { first_of(rest) })
  }
}
