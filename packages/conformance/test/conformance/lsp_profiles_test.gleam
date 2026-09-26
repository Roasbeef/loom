//// The first-party language profiles (ADR-014 §6) proving themselves, the
//// way `loom ext check` proves them: installed from the repository's own
//// `extensions/` directory, then each profile's `[[check]]`s asked of its
//// real server through the session's jailed manager.
////
//// Nothing here is a second path. The install is `install.run` with a
//// build seam that fails the test if it is called, because a profile
//// compiles nothing (ADR-014 §3). The run is `client/extension/check.run`,
//// the function the CLI verb calls: the same scratch workspace under the
//// extensions root's staging area, the same helper pool and broker over
//// the build plane's base, the same enforcement probe, and the same
//// `client/lsp/profile_check` runner through `manager.door`. A profile
//// that passes here passes `loom ext check` on the same host.
////
//// ## Prerequisites, and skipping visibly
////
//// Each profile needs the sandbox helper, its server, and `rg`, which a
//// bare-name question searches the project with. Where one is missing the
//// test prints `SKIP lsp profile <name>: <what is missing>` and passes,
//// and CI's skip census decides whether that skip was allowed on that
//// lane. The jailed Linux lane installs all three servers and allows none.
////
//// ## Why `BestEffort`
////
//// For the reason `conformance/lsp_e2e_test` gives: the ordinary runner's
//// helper cannot apply every layer `PlatformEnforcement` demands, and the
//// manager's probe would then refuse every server before a question was
//// asked. The server still runs inside the helper's jail, with its mounts
//// and its network off, which is what a profile's roots are a claim about.
////
//// ## The examples and the profiles are one table
////
//// `docs/examples/loom.toml` keeps its `[lsp.gleam]` and `[lsp.go]` tables
//// as the operator's template, and names `extensions/lsp_gleam` and
//// `extensions/lsp_go` as their maintained versions. The last test holds
//// the two to decoding to the same servers, hint included, so an edit to
//// one that the other did not follow fails here rather than leaving an
//// operator to copy a stale table.

import broker/exec
import client/catalog
import client/extension/archive
import client/extension/check
import client/extension/install
import client/extension/record
import client/extension/source
import client/lsp/profile
import client/serve
import core/clock
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import provider/secret
import simplifile
import support/internal/ffi_shell
import support/jail

/// One profile's budget: a cold server in the jail, which for
/// `rust-analyzer` includes loading the standard library, then its checks.
/// Well under this where measured; the headroom is for a slow runner.
const test_timeout_seconds = 300

/// gleeunit runs eunit with `ScaleTimeouts(10)`, and that scale multiplies
/// a generator's own timeout too, so the number handed to eunit is the
/// number wanted divided by ten.
const gleeunit_timeout_scale = 10

/// eunit's `{timeout, Seconds, Body}`, built as a Gleam constructor so a
/// `*_test_` generator can ask for more than eunit's default.
pub type EunitTest {
  Timeout(seconds: Int, body: fn() -> Nil)
}

// --- the three profiles ------------------------------------------------------

/// `gleam lsp`: a qualified definition and references across two modules.
pub fn lsp_profile_gleam_test_() -> EunitTest {
  profile_test("lsp_gleam", fn() {
    use _gleam <- result.try(on_path("gleam"))
    Ok(Nil)
  })
}

/// `gopls`, which shells out to `go`, so both are prerequisites. The
/// profile's command is a bare `gopls`, looked up on the daemon's `PATH`,
/// so `gopls` must be there and not merely in `~/go/bin`.
pub fn lsp_profile_go_test_() -> EunitTest {
  profile_test("lsp_go", fn() {
    use _gopls <- result.try(on_path("gopls"))
    use _go <- result.try(on_path("go"))
    readable_goroot()
  })
}

// The `go` that `gopls` runs must itself run in the jail, so its GOROOT
// has to lie in the jail's read-only system view: `/usr` or `/opt` on
// Linux, `/usr` or `/opt/homebrew` on macOS. A Go installed anywhere else
// (a macOS runner's tool cache under `/Users`) is a host the profile's
// README says it cannot serve as shipped, and that is a prerequisite this
// host lacks rather than a profile that failed.
fn readable_goroot() -> Result(Nil, String) {
  let goroot = string.trim(ffi_shell.os_cmd("go env GOROOT"))
  let system = case string.trim(ffi_shell.os_cmd("uname -s")) {
    "Darwin" -> ["/usr/", "/opt/homebrew/"]
    _linux -> ["/usr/", "/opt/"]
  }
  case list.any(system, string.starts_with(goroot, _)) {
    True -> Ok(Nil)
    False ->
      Error(
        "go's GOROOT "
        <> goroot
        <> " is outside the jail's system view ("
        <> string.join(system, ", ")
        <> "), so the profile cannot run it as shipped",
      )
  }
}

/// `rust-analyzer`, whose `::` qualifiers are what the profile's
/// `qualifier_separators` exist for. rustup installs a `rust-analyzer`
/// link whether or not the component is installed, and the link then
/// fails at its first use, so the server is asked for its version rather
/// than merely looked up: the component missing is a missing server.
pub fn lsp_profile_rust_test_() -> EunitTest {
  profile_test("lsp_rust", fn() {
    use _analyzer <- result.try(on_path("rust-analyzer"))
    case
      string.starts_with(
        ffi_shell.os_cmd("rust-analyzer --version 2>&1"),
        "rust-analyzer ",
      )
    {
      True -> Ok(Nil)
      False ->
        Error(
          "rust-analyzer does not run (rustup component add rust-analyzer "
          <> "rust-src)",
        )
    }
  })
}

// One profile, installed and checked. The helper and `rg` are every
// profile's prerequisites; `server` names what this one adds.
fn profile_test(
  name: String,
  server: fn() -> Result(Nil, String),
) -> EunitTest {
  Timeout(test_timeout_seconds / gleeunit_timeout_scale, fn() {
    let ready = {
      use helper <- result.try(jail.build_helper())
      use _rg <- result.try(
        on_path("rg")
        |> result.replace_error("ripgrep (rg) is not on PATH"),
      )
      use Nil <- result.try(server())
      Ok(helper)
    }
    case ready {
      Error(reason) ->
        io.println_error("SKIP lsp profile " <> name <> ": " <> reason)
      Ok(helper) -> run_profile(name, helper)
    }
  })
}

fn run_profile(name: String, helper: String) -> Nil {
  let root = installed(name)
  let setup =
    check.Setup(
      helper: option.Some(helper),
      demand: exec.BestEffort,
      places: serve.lsp_places(),
      reading: fn(variable) { secret.lookup(secret.env(), variable) },
      // A stepping clock, as the session end-to-ends use: every deadline
      // here is measured from a reading, and the readings only need to
      // move forward.
      clock: clock.stepping(from: 1_700_000_300_000, by: 11),
      entropy: ffi_shell.unique_integer,
    )
  let assert Ok(report) = check.run(root, name, setup)
    as "the profile's checks must be able to run"

  // Printed whole before the assertion reads it, so a failure on a lane
  // whose jail differs from a developer's names its own cause.
  list.each(check.lines(report), fn(line) {
    io.println_error("lsp profile " <> name <> ": " <> line)
  })
  assert check.total(report) > 0
  assert check.failed(report) == 0
  let _cleared = simplifile.delete_all([home_of(root)])
  Nil
}

// --- the examples --------------------------------------------------------------

/// `docs/examples/loom.toml`'s two tables decode to exactly the servers
/// the `lsp_gleam` and `lsp_go` profiles approve, hint included.
pub fn the_examples_are_the_profiles_test() {
  let assert Ok(text) = simplifile.read("../../docs/examples/loom.toml")
    as "the committed example catalogue must be readable"
  let assert Ok(parsed) = catalog.parse(text)
    as "the committed example catalogue must parse"
  let approved =
    list.flat_map(["lsp_gleam", "lsp_go"], fn(name) {
      approved_servers(installed(name), name)
    })
  let named = fn(servers: List(profile.LspServer)) {
    list.sort(servers, fn(a, b) { string.compare(a.name, b.name) })
  }
  assert list.map(approved, fn(server) { server.name }) == ["gleam", "go"]
  assert named(parsed.lsp_servers) == named(approved)
}

// --- helpers -------------------------------------------------------------------

// A profile installed from the repository's own tree into a fresh
// extensions root under the package's `build/`, never `/tmp`, which the
// jail replaces. The build seam fails the test if it is called: a profile
// install that reached for the compiler would need a toolchain it never
// uses.
fn installed(name: String) -> record.Root {
  let assert Ok(here) = simplifile.current_directory()
    as "the test process must know where it is"
  let home =
    here
    <> "/build/lsp-profiles/"
    <> name
    <> "-"
    <> int.to_string(ffi_shell.unique_integer())
  let _cleared = simplifile.delete_all([home])
  let root = record.root_for(home)
  let config =
    install.Config(
      root:,
      caps: archive.default_caps(),
      fetch: fn(_url, _max) { panic as "a local profile install fetched a URL" },
      build: fn(_build_root) { panic as "a profile install called the build" },
      clock: clock.fixed(at: 1_700_000_000_000),
      entropy: ffi_shell.unique_integer,
      approved_by: "conformance",
    )
  let assert Ok(_done) =
    install.run(
      config,
      source.LocalPath(path: here <> "/../../extensions/" <> name),
      rev: None,
    )
    as "a first-party profile must install"
  root
}

fn approved_servers(
  root: record.Root,
  name: String,
) -> List(profile.LspServer) {
  let assert Ok(text) = simplifile.read(record.file(root, name))
    as "the install record must be readable"
  let assert Ok(written) = record.readable(text)
    as "the install record must decode"
  let _cleared = simplifile.delete_all([home_of(root)])
  written.lsp
}

// The directory `installed` made, which holds `.loom/extensions`.
fn home_of(root: record.Root) -> String {
  string.replace(record.path(root), "/.loom/extensions", "")
}

fn on_path(name: String) -> Result(String, String) {
  ffi_shell.find_executable(name)
  |> result.replace_error(name <> " is not on PATH")
}
