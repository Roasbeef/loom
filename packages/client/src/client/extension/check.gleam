//// `loom ext check`: a profile extension proving itself against its own
//// fixture, through the jail a session would give its server (ADR-014
//// §5).
////
//// A profile is data an operator approved: a command, the files it
//// claims, and the roots and environment its jail grants. Whether that
//// data is *enough* is a fact about a server, which only running the
//// server answers. So a check runs the profile the way a session would
//// and asks it the profile's own `[[check]]` questions:
////
//// ```
//// installed.verified → write the fixture → helper pool + broker → probe
////   → manager over [server] → profile_check through the door → stop → rm
//// ```
////
//// Every piece of that path is the session's own. The profile is the one
//// the install record approved, with its `~/` and `<cache>/` roots
//// expanded by `serve.lsp_server_roots` against the daemon's places
//// (`serve.lsp_places`); the server is started by `client/lsp/manager`'s
//// production backend, after its enforcement probe, under the operator's
//// demand; and each question goes through `manager.door`, so symbol
//// resolution, the readiness wait and the gate on what a server names are
//// all part of what a check proves. A check that bypassed any of them
//// would prove a server works, not that Loom can use it.
////
//// # Where the fixture runs, and why not in `/tmp`
////
//// The fixture is written into a fresh scratch workspace under the
//// extensions root's staging area, `<root>/.staging/check-<token>/work`.
//// Three things decide that place. The jail replaces `/tmp` with a tmpfs
//// of its own, so a workspace there would be empty to the server; the
//// scratch's real path is what is judged, so a root reached through a
//// link into `/tmp`, or macOS's `/private/tmp`, is refused as `/tmp` is.
//// A profile's project may be writable (`gleam lsp` writes `build/`), and
//// the installed tree must stay byte-for-byte what its digest says, or the
//// next load refuses it; so the server gets a copy. And the staging area
//// is already where the extension CLI keeps scratch state, which an
//// install cleans up the same way this does: the whole directory goes on
//// every path out.
////
//// # The fixture comes from the verified tree, not the disk
////
//// The copy is written from the bytes `installed.verified` read and
//// digested, never copied from the installed directory again. The walk
//// that computed the digest refuses links and skips `.git`; a copy from
//// disk follows both. So a link planted in a fixture after install — a
//// `.git` pointing anywhere on the host — would have put files no digest
//// covered in front of the server, and the check would have proved the
//// profile against something the operator never approved.
////
//// # What is printed
////
//// A heading per server, the jail line (what the probe's helper reported
//// it enforced, as `loom ext install` prints its build's), and one line
//// per check, `ok` or `FAIL`. A failed check prints both sets. The verb
//// exits 1 when any check failed, and the lines still say which.

import broker/broker
import broker/exec.{type EnforcementDemand}
import client/extension/archive
import client/extension/installed
import client/extension/manifest.{type Check, type Manifest}
import client/extension/record.{type Record, type Root}
import client/lsp/jail
import client/lsp/leases
import client/lsp/manager
import client/lsp/profile.{type LspServer, type Places}
import client/lsp/profile_check.{type CheckOutcome}
import client/serve
import codemode/enforcement
import core/clock.{type Clock}
import filepath
import gleam/int
import gleam/list
import gleam/option.{type Option, None}
import gleam/result
import gleam/string
import host/bootstrap
import simplifile
import tools/tool
import weft/poll

/// What a check needs from the host it runs on: where the helper is, the
/// demand the server clears under, and the daemon's environment.
pub type Setup {
  Setup(
    /// The `--helper` flag, or `None` for the boot's own ladder.
    helper: Option(String),
    /// The operator's demand: platform enforcement unless they passed
    /// `--best-effort`, exactly as an install's build clears.
    demand: EnforcementDemand,
    /// The daemon's `HOME` and cache directory (`serve.lsp_places`), which
    /// expand a profile's `~/` and `<cache>/` roots and are the server's
    /// `HOME`.
    places: Places,
    /// The daemon's environment, read for `PATH` and the profile's `env`
    /// names, as a session's store reads it.
    reading: fn(String) -> Result(String, Nil),
    /// The clock budget deadlines are measured on.
    clock: Clock,
    /// Where the scratch directory's token and the language servers'
    /// operation id come from.
    entropy: fn() -> Int,
  )
}

/// One server's checks against one fixture, and how they came out.
pub type Run {
  Run(
    /// The `[lsp.<name>]` server the checks queried.
    server: String,
    /// The fixture directory in the extension's tree they ran against.
    fixture: String,
    /// What the server's enforcement probe reported the helper enforced,
    /// or why there is no such report.
    enforcement: enforcement.Report,
    /// Every check of this server and fixture, in file order.
    outcomes: List(#(Check, CheckOutcome)),
  )
}

/// A whole `loom ext check`: the extension, and one `Run` per server and
/// fixture its checks name, in the order the checks first name them.
pub type Report {
  Report(name: String, version: String, runs: List(Run))
}

/// How long a stopped server has to give its helper lease back before
/// the check tears the plane down under it: the manager's stop grace plus
/// the relay's own close and abort waits, with room to spare.
pub const release_wait_ms = 15_000

/// Loads the installed extension `name` from `root`, refuses one that
/// cannot be checked, and runs every check it declares.
///
/// The refusals come before anything is started, so each costs nothing:
/// an extension that does not load (its reason, as `verify` gives it), a
/// jailed extension, which has no profiles to prove, and a profile that
/// declares no `[[check]]`. After that an `Error` is a setup failure — no
/// helper, a scratch workspace that cannot be made — and a check that ran
/// and failed is a `Report` whose outcomes say so.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(report) = check.run(root, "lsp_go", setup)
/// // check.failed(report) == 0
/// ```
///
pub fn run(root: Root, name: String, setup: Setup) -> Result(Report, String) {
  use #(written, decoded, tree) <- result.try(checkable(root, name))
  use runs <- result.try(
    groups(decoded.checks)
    |> list.try_map(fn(group) {
      let #(#(server_name, fixture), checks) = group
      use server <- result.try(approved(written, server_name))
      run_group(root, tree, server, fixture, checks, setup)
    }),
  )
  Ok(Report(name: written.name, version: written.version, runs:))
}

/// How many checks failed, over every run.
///
/// ## Examples
///
/// ```gleam
/// assert check.failed(check.Report("lsp_go", "0.1.0", [])) == 0
/// ```
///
pub fn failed(report: Report) -> Int {
  list.fold(report.runs, 0, fn(count, run) {
    count
    + list.count(run.outcomes, fn(entry) { !profile_check.passed(entry.1) })
  })
}

/// How many checks ran, over every run.
///
/// ## Examples
///
/// ```gleam
/// assert check.total(check.Report("lsp_go", "0.1.0", [])) == 0
/// ```
///
pub fn total(report: Report) -> Int {
  list.fold(report.runs, 0, fn(count, run) { count + list.length(run.outcomes) })
}

/// The lines `loom ext check` prints: a heading, then per server its jail
/// line and one line per check.
///
/// ## Examples
///
/// ```gleam
/// // check.lines(report)
/// // -> ["checked lsp_go 0.1.0: 2 of 2 checks passed",
/// //     "  lsp.go against fixture",
/// //     "    jail:  the language server's probe enforced [...]",
/// //     "    ok    definition util.Greet", ...]
/// ```
///
pub fn lines(report: Report) -> List(String) {
  let passed = total(report) - failed(report)
  let heading =
    "checked "
    <> report.name
    <> " "
    <> report.version
    <> ": "
    <> int.to_string(passed)
    <> " of "
    <> int.to_string(total(report))
    <> " checks passed"
  [
    heading,
    ..list.flat_map(report.runs, fn(run) {
      [
        "  lsp." <> run.server <> " against " <> run.fixture,
        "    jail:  " <> enforcement_line(run.enforcement),
        ..list.map(run.outcomes, fn(entry) {
          "    " <> profile_check.describe(entry.0, entry.1)
        })
      ]
    })
  ]
}

/// What the probe's helper enforced, in the shape `loom ext install`
/// prints its build's jail in: the layers applied, any skipped, and
/// `DEGRADED` when the helper said so. A report that does not exist says
/// why rather than being left out, since silence would read as a jail.
///
/// ## Examples
///
/// ```gleam
/// assert check.enforcement_line(enforcement.Unreported("no helper"))
///   == "the language server's probe made NO enforcement report: no helper"
/// ```
///
pub fn enforcement_line(report: enforcement.Report) -> String {
  case report {
    enforcement.Unreported(reason:) ->
      "the language server's probe made NO enforcement report: " <> reason
    enforcement.Reported(entries: _, degraded:) -> {
      let #(applied, skipped) = enforcement.layers(report)
      "the language server's probe enforced ["
      <> string.join(applied, ", ")
      <> "]"
      <> case skipped {
        [] -> ""
        missing -> ", SKIPPED [" <> string.join(missing, ", ") <> "]"
      }
      <> case degraded {
        True -> " (DEGRADED)"
        False -> ""
      }
    }
  }
}

// --- what can be checked ----------------------------------------------------

// The three refusals, each by name and each before anything runs. The
// record's own profiles are what is proved, because they are what the
// operator approved; `installed.verified` has already refused a manifest
// whose profiles differ from them. The tree comes back with them, and it
// is the only source a fixture is written from.
fn checkable(
  root: Root,
  name: String,
) -> Result(#(Record, Manifest, archive.Tree), String) {
  case installed.verified(root, name) {
    Error(reason) -> Error(name <> ": " <> reason)
    Ok(installed.Verified(
      record: written,
      manifest: decoded,
      artifact: _,
      tree:,
    )) ->
      case written.tier, decoded.checks {
        manifest.Jailed, _ ->
          Error(
            name
            <> " is a jailed extension; only a profile extension "
            <> "(tier = \"profile\") has language profiles to check",
          )
        manifest.Profile, [] ->
          Error(
            name
            <> " declares no [[check]], so there is nothing to run; a "
            <> "profile proves itself with checks against a fixture "
            <> "(ADR-014 §5)",
          )
        manifest.Profile, [_, ..] -> Ok(#(written, decoded, tree))
      }
  }
}

fn approved(written: Record, name: String) -> Result(LspServer, String) {
  list.find(written.lsp, fn(server) { server.name == name })
  |> result.map_error(fn(_absent) {
    "a check names lsp." <> name <> ", which the install record does not hold"
  })
}

// The checks grouped by the server and fixture they run against, in the
// order the manifest first names each pair. One group is one server start
// over one copy of one fixture, so checks that share both share a start.
fn groups(checks: List(Check)) -> List(#(#(String, String), List(Check))) {
  let keys =
    list.map(checks, fn(check) { #(check.server, check.fixture) })
    |> list.unique
  list.map(keys, fn(key) {
    #(
      key,
      list.filter(checks, fn(check) { #(check.server, check.fixture) == key }),
    )
  })
}

// --- one server over one fixture ---------------------------------------------

// The scratch directory is removed on every path out, the setup failures
// included, because a check that failed must not leave a copy of a
// fixture and a helper's temporary files under the operator's root.
fn run_group(
  root: Root,
  tree: archive.Tree,
  server: LspServer,
  fixture: String,
  checks: List(Check),
  setup: Setup,
) -> Result(Run, String) {
  // The clock's reading beside the entropy, because the entropy is unique
  // only within one VM and two operators' checks on one root are two VMs.
  let #(now, _clock) = clock.read(setup.clock)
  let scratch =
    record.staging(
      root,
      "check-" <> int.to_string(now) <> "-" <> int.to_string(setup.entropy()),
    )
  let ran = {
    use real <- result.try(prepared(tree, fixture, scratch))
    use expanded <- result.try(serve.lsp_server_roots(server, setup.places))
    use plane <- result.try(serve.start_check_plane(
      helper: setup.helper,
      workspace: real <> "/work",
      state_root: filepath.directory_name(record.path(root)),
      tmp_dir: real <> "/tmp",
      clock: setup.clock,
    ))
    let ran = on_plane(plane, real <> "/work", expanded, fixture, checks, setup)
    serve.stop_check_plane(plane)
    ran
  }
  let _removed = simplifile.delete_all([scratch])
  ran
}

// The scratch layout: `work` is the workspace, holding the fixture's copy
// at its root so a server's workspace-relative paths are the fixture's own
// and meet `expect` unchanged; `tmp` is the helper's temporary directory,
// outside the workspace so nothing the helper leaves there is in the
// server's project. Answers the scratch directory's real path, which is
// what the jail is given, so the path the guard judged is the path bound.
//
// The `/tmp` guard is judged on that real path, after the directory is
// made, because the text of the root says nothing about where it leads: a
// `--home` that is a link into `/tmp`, or macOS's `/tmp`, which is a link
// to `/private/tmp`, lands the workspace in the tmpfs the jail replaces,
// and the server would find an empty project. The one real-path reader the
// tree has is `host/bootstrap.canonical_directory`.
fn prepared(
  tree: archive.Tree,
  fixture: String,
  scratch: String,
) -> Result(String, String) {
  let made = fn(outcome, what) {
    result.map_error(outcome, fn(error) {
      "could not " <> what <> ": " <> simplifile.describe_error(error)
    })
  }
  use Nil <- result.try(made(
    simplifile.create_directory_all(scratch <> "/tmp"),
    "make " <> scratch <> "/tmp",
  ))
  use real <- result.try(
    bootstrap.canonical_directory(scratch)
    |> result.map_error(fn(reason) {
      "could not resolve " <> scratch <> ": " <> reason
    }),
  )
  use Nil <- result.try(outside_tmp(real))
  use Nil <- result.try(written_fixture(tree, fixture, real <> "/work"))
  Ok(real)
}

fn outside_tmp(real: String) -> Result(Nil, String) {
  let under = fn(directory) {
    real == directory || string.starts_with(real, directory <> "/")
  }
  case under("/tmp") || under("/private/tmp") {
    False -> Ok(Nil)
    True ->
      Error(
        "the check's scratch workspace would be "
        <> real
        <> "/work, under /tmp, which the jail replaces with its own; put the "
        <> "extensions root outside /tmp (--home)",
      )
  }
}

// Every file of the tree beneath `fixture/`, written at its path below
// the fixture, from the bytes that were digested. The tree's paths already
// passed `archive`'s component rules (no `..`, no empty or `.` component),
// so each lands under `workspace` and nowhere else, and the workspace is
// a directory this check just made, so nothing in it is a link to follow.
fn written_fixture(
  tree: archive.Tree,
  fixture: String,
  workspace: String,
) -> Result(Nil, String) {
  let prefix = fixture <> "/"
  let failed = fn(what, error) {
    "could not write the fixture "
    <> fixture
    <> " into "
    <> workspace
    <> " ("
    <> what
    <> "): "
    <> simplifile.describe_error(error)
  }
  use Nil <- result.try(
    simplifile.create_directory_all(workspace)
    |> result.map_error(failed(workspace, _)),
  )
  list.try_each(tree.files, fn(file) {
    case string.starts_with(file.path, prefix) {
      False -> Ok(Nil)
      True -> {
        let target =
          workspace
          <> "/"
          <> string.drop_start(file.path, string.length(prefix))
        use Nil <- result.try(
          simplifile.create_directory_all(filepath.directory_name(target))
          |> result.map_error(failed(file.path, _)),
        )
        simplifile.write_bits(to: target, bits: file.bytes)
        |> result.map_error(failed(file.path, _))
      }
    }
  })
}

// The plane is up: count its leases, build the session's jailed backend
// over it, report what the probe enforced, then start the manager with
// this one server and ask every check through its door. The manager is
// stopped and its lease waited back before the plane is, so the server
// exits on its own `shutdown` rather than under a torn-down helper.
fn on_plane(
  plane: serve.CheckPlane,
  workspace: String,
  server: LspServer,
  fixture: String,
  checks: List(Check),
  setup: Setup,
) -> Result(Run, String) {
  use counter <- result.try(
    leases.start(plane.size)
    |> result.map_error(fn(error) {
      "the helper-lease counter would not start: " <> string.inspect(error)
    }),
  )
  let op_id = jail.operation(setup.clock, seed: setup.entropy())
  let timing = manager.default_timing()
  let broker_actor = plane.broker
  let jailed =
    manager.Jailed(
      workspace:,
      session_base: plane.base_policy,
      demand: setup.demand,
      // No code-mode toolchain: a bare `gleam` is looked up on the
      // daemon's `PATH`, as a session's is when code mode located none.
      // A check must run where no build seed exists, as a profile install
      // does, and the `gleam` on `PATH` is the one an operator runs.
      toolchain: None,
      places: setup.places,
      reading: setup.reading,
      run: tool.broker_runner(
        broker: broker_actor,
        waiting: jail.clearance_wait_ms,
      ),
      abort_step: fn(step_id) {
        broker.abort_step(broker_actor, op_id, step_id:)
      },
      leases: counter,
      op_id:,
      clock: setup.clock,
      exec_ms: timing.exec_ms,
    )

  // The probe is cleared over the workspace, which is the fixture's root
  // and so the project root a profile's markers find there. What the
  // helper enforces depends on the policy's layers and the demand, not on
  // which directory is the working one, so this is the jail the server
  // gets. The manager clears its own probe again before the start; this
  // one exists to be printed.
  let enforced = case manager.probe_server(jailed, server, workspace) {
    Ok(settled) -> enforcement.of_call(settled)
    Error(reason) -> enforcement.Unreported(reason)
  }
  let outcome =
    manager.start(manager.Config(
      workspace:,
      servers: [server],
      backend: manager.jailed(jailed),
      timing:,
    ))
  let ran = case outcome {
    Error(reason) ->
      Error("the language-server manager would not start: " <> reason)
    Ok(running) -> {
      let outcomes = profile_check.run_all(manager.door(running), checks)
      manager.stop(running)
      released(counter)
      Ok(Run(server: server.name, fixture:, enforcement: enforced, outcomes:))
    }
  }
  broker.abort(broker_actor, op_id)
  leases.stop(counter)
  ran
}

// The keeper stops the server after `manager.stop` returns, and the lease
// coming back is the witness that it has. A server that outlives the wait
// is aborted with the rest of the operation by the caller.
fn released(counter: leases.Leases) -> Nil {
  let _settled =
    poll.until(within: release_wait_ms, every: 50, attempt: fn() {
      case leases.held(counter, waiting: 1000) {
        Ok(0) -> poll.Done(Nil)
        Ok(_held) | Error(Nil) -> poll.Retry
      }
    })
  Nil
}
