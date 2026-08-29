//// The fixture repository the code-mode migration sample sweeps.
////
//// A tiny stand-in for a real tree: three packages holding a symbol
//// being retired, and three shell entry points under `tools/` that the
//// sample calls the way a model calls a repo's own tooling.
////
//// The scripts are deliberately instrumented, because a green run of the
//// sample would otherwise prove far less than it looks like it proves:
////
//// - `tools/sweep` records the wall time at which it *starts* and at
////   which it *finishes* into two workspace files. Overlapping intervals
////   are what makes the fan-out demonstrably concurrent rather than three
////   sequential runs, and a completion order that is the reverse of the
////   input order is what makes order preservation a real claim instead of
////   a coincidence. The per-package sleeps exist to force that inversion.
//// - `tools/build-thorough` appends a tick every half second. It is the
////   race loser, and the tick count is the evidence that killing it
////   actually stopped the OS process rather than merely abandoning it —
////   a cancelled loser stops ticking at the moment the race is decided,
////   several seconds before the program ends.
////
//// Everything the scripts write lands in the workspace root (the jail's
//// cwd), which the session base policy makes writable.

import filepath
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// Where `tools/sweep` records one line per sweep *start*.
pub const starts_file = ".sweep-starts"

/// Where `tools/sweep` records one line per sweep *completion*.
pub const completions_file = ".sweep-order"

/// Where `tools/build-thorough` appends its ticks.
pub const ticks_file = ".thorough-ticks"

/// The packages the sample sweeps, in the order it reports them. Kept
/// byte-identical to the `packages` constant in
/// `docs/examples/stale_symbol_sweep.gleam`.
pub const swept = ["packages/core", "packages/broker", "packages/runtime"]

/// The symbol the sample looks for.
pub const symbol = "deprecated_decode"

/// Lays the fixture repository out under `workspace`.
///
/// Panics on failure: a fixture that cannot be written is a broken test,
/// not a skip.
pub fn create(workspace: String) -> Nil {
  // packages/core: two files match, one does not.
  write(
    workspace,
    "packages/core/decode.gleam",
    "pub fn " <> symbol <> "() {\n  Nil\n}\n",
  )
  write(
    workspace,
    "packages/core/legacy.gleam",
    "// calls " <> symbol <> " twice\n",
  )
  write(workspace, "packages/core/ids.gleam", "pub fn mint() {\n  Nil\n}\n")
  // packages/broker: one file matches.
  write(
    workspace,
    "packages/broker/policy.gleam",
    "// TODO drop " <> symbol <> "\n",
  )
  write(workspace, "packages/broker/token.gleam", "pub fn mint() {\n  Nil\n}\n")
  // packages/runtime: none match. Named so a substring search for the
  // symbol's *prefix* would still miss — the count must be a real zero.
  write(
    workspace,
    "packages/runtime/strand.gleam",
    "pub fn deprecated() {\n  Nil\n}\n",
  )

  write(workspace, "tools/sweep", sweep_script())
  write(workspace, "tools/build-quick", quick_script())
  write(workspace, "tools/build-thorough", thorough_script())
}

// `tools/sweep <symbol> <dir>` — list the files under `dir` containing
// `symbol`, bracketed by two timestamps.
//
// The per-package sleeps invert completion order relative to input order:
// `packages/core` is swept first and finishes last. Nanosecond stamps are
// what the test compares to prove the three overlapped.
fn sweep_script() -> String {
  "#!/bin/sh\n"
  <> "# Fixture. See packages/codemode/test/support/sample_repo.gleam.\n"
  <> "symbol=\"$1\"\n"
  <> "dir=\"$2\"\n"
  <> "printf '%s %s\\n' \"$dir\" \"$(date +%s%N)\" >> "
  <> starts_file
  <> "\n"
  <> "case \"$dir\" in\n"
  <> "  */core) sleep 3.0 ;;\n"
  <> "  */broker) sleep 1.5 ;;\n"
  <> "  *) sleep 0.5 ;;\n"
  <> "esac\n"
  <> "matches=$(grep -rlF \"$symbol\" \"$dir\" 2>&1)\n"
  <> "grep_status=$?\n"
  <> "printf '%s %s\\n' \"$dir\" \"$(date +%s%N)\" >> "
  <> completions_file
  <> "\n"
  <> "case \"$grep_status\" in\n"
  <> "  0) printf '%s\\n' \"$matches\" ;;\n"
  <> "  1) ;;\n"
  <> "  *) printf '%s\\n' \"$matches\" >&2; exit \"$grep_status\" ;;\n"
  <> "esac\n"
  <> "exit 0\n"
}

// The build strategy that wins the race.
fn quick_script() -> String {
  "#!/bin/sh\n"
  <> "# Fixture. The fast build strategy; wins the race.\n"
  <> "sleep 0.3\n"
  <> "echo quick\n"
}

// The build strategy that loses it, and keeps a running record of how far
// it got before it was killed.
fn thorough_script() -> String {
  "#!/bin/sh\n"
  <> "# Fixture. The slow build strategy; loses the race and must be\n"
  <> "# killed. Each tick is half a second of survival.\n"
  <> "i=0\n"
  <> "while [ $i -lt 60 ]; do\n"
  <> "  printf 'tick\\n' >> "
  <> ticks_file
  <> "\n"
  <> "  sleep 0.5\n"
  <> "  i=$((i + 1))\n"
  <> "done\n"
  <> "echo thorough\n"
}

fn write(workspace: String, relative: String, contents: String) -> Nil {
  let path = workspace <> "/" <> relative
  let assert Ok(Nil) =
    simplifile.create_directory_all(filepath.directory_name(path))
    as "the fixture repository's directories must be creatable"
  let assert Ok(Nil) = simplifile.write(to: path, contents:)
    as "the fixture repository's files must be writable"
  Nil
}

// --- reading the instrumentation back ------------------------------------

/// One recorded `tools/sweep` event: the package, and the nanosecond
/// stamp at which it happened.
pub type Stamp {
  Stamp(dir: String, nanos: Int)
}

/// Reads one of the stamp files. A missing file reads as no stamps, so a
/// caller asserting on the contents gets a clear failure rather than a
/// crash inside the fixture.
pub fn stamps(workspace: String, file: String) -> List(Stamp) {
  case simplifile.read(workspace <> "/" <> file) {
    Error(_reason) -> []
    Ok(contents) ->
      contents
      |> string.split("\n")
      |> list.filter_map(parse_stamp)
  }
}

fn parse_stamp(line: String) -> Result(Stamp, Nil) {
  case string.split(string.trim(line), " ") {
    [dir, nanos] -> int.parse(nanos) |> result.map(Stamp(dir:, nanos: _))
    _ -> Error(Nil)
  }
}

/// How many ticks `tools/build-thorough` managed before it was stopped.
pub fn ticks(workspace: String) -> Int {
  case simplifile.read(workspace <> "/" <> ticks_file) {
    Error(_reason) -> 0
    Ok(contents) ->
      contents
      |> string.split("\n")
      |> list.filter(fn(line) { string.trim(line) != "" })
      |> list.length
  }
}
