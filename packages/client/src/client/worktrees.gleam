//// A Git worktree for each session of a worktree workspace (protocol-change/095).
////
//// A workspace in `mode = "worktree"` gives every session that attaches its own
//// linked worktree of the workspace's repository, on a branch of its own, so two
//// sessions never edit the same files or switch branches under each other. This
//// module owns that tree's whole life on the executor: it creates the tree at a
//// session's first attach, adopts or recreates it at a reopen, removes it at a
//// clean close, and reconciles what a crash left. `client/executor_plane` calls
//// `open` while it builds a session's plane and `close` when the scope retires.
////
//// ## What the ledger records, and why
////
//// The executor removes only what its ledger says it created. Every tree has a
//// `Tree` row (`storage/exec_ledger`) that is written before the command that
//// changes the disk: `Creating` before `git worktree add`, `Removing` before
//// `git worktree remove`. A crash on either side of the command therefore leaves
//// a row that names the directory to look at, and `reconcile` decides from the
//// row and the disk what happened. A directory under `worktrees/` that no row
//// names was not made by Loom, so it is reported and never deleted. The branch
//// is never deleted at all: a removed tree keeps its branch, and the branch is
//// how a reopen gets the session's commits back.
////
//// ## One gate for each workspace
////
//// `git worktree` rewrites files in the repository's `.git` and takes locks
//// there, and two sessions attaching to one workspace at once would race it. All
//// the Git work of one workspace therefore goes through a gate, a process that
//// runs one job at a time and runs the workspace's reconciliation before its
//// first. The gate is what lets the host stay responsive: the plane build runs
//// in a task of its own, waits at the gate, and answers the attach when its
//// checkout lands. Other workspaces have gates of their own and are not delayed.
////
//// ## Where Git runs
////
//// Never in this VM. Every command goes through `client/worktree_git`, which
//// clears it through the broker into the sandbox helper, because the
//// repository's configuration and hooks are files the session's model may have
//// written (Rule Zero).
////
//// ## Closing a tree
////
//// A clean close removes the tree. "Clean" is `git status` with nothing to
//// report once Loom's own `.codemode` directory is excluded: code mode keeps its
//// exec root and the tool Git identity there, so an unfiltered status is never
//// empty for a session that used it. A tree with changes is left exactly as it
//// is, and so is one on a detached HEAD, whose commits no branch holds. If
//// Loom cannot tell, it leaves the tree. Removal is `git worktree remove
//// --force`, which is safe only because the filtered status has just shown that
//// the one thing `--force` will discard is `.codemode` and ignored build output.
////
//// ## Flow
////
//// `start` → `open` → `close` → `reconcile` → `sweep`
////
//// 1. `start` checks every worktree workspace's repository, boots the
////    sandboxed Git and starts a gate for each workspace.
//// 2. `open` runs at a session's attach: it creates, adopts or recreates the
////    tree and answers its path and branch.
//// 3. `close` runs when the scope has retired cleanly and removes the tree or
////    leaves it.
//// 4. `reconcile` runs once for each workspace, ahead of its first job, and
////    finishes whatever a crash interrupted.
//// 5. `sweep` is the operator's release: it settles every tree the executor
////    made, for `loomd executor release --worktrees`.

import broker/exec.{type EnforcementDemand}
import client/remote/protocol
import client/workspaces.{type Workspace}
import client/worktree_git.{type Git, type Output}
import filepath
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import simplifile
import storage/exec_ledger.{type Ledger, type Tree as Row}
import telemetry/field
import telemetry/log.{type Logger}
import weft/actor

/// What the worktrees of one executor are built from.
pub type Config {
  Config(
    /// The daemon's state root. Trees live under `<state root>/worktrees`.
    state_root: String,
    /// The execution ledger's file, whose worktree records the gates keep.
    ledger_path: String,
    /// The `loom-exec` sandbox helper Git runs under.
    helper_path: String,
    /// Enforcement strictness for every Git call.
    demand: EnforcementDemand,
    /// Where reconciliation and closes report.
    logger: Logger,
  )
}

/// The worktrees an executor manages: the sandboxed Git and a gate for each
/// worktree workspace. A configuration with no such workspace holds neither.
pub opaque type Worktrees {
  Worktrees(config: Config, git: Option(Git), gates: List(#(String, Gate)))
}

/// A tree a plane is built on.
pub type Tree {
  Tree(
    /// The tree's directory, which is the session's workspace.
    path: String,
    /// The branch checked out in it.
    branch: String,
  )
}

/// How a close ended.
pub type Closed {
  /// The tree was clean and is gone. Its branch remains.
  Removed

  /// The tree stays, for the reason given: it holds changes, or Loom could not
  /// tell that it does not.
  Kept(reason: String)
}

/// Whether a settle may discard a tree that holds changes.
pub type Force {
  /// Remove the tree only when it is clean.
  Careful

  /// Remove the tree whatever it holds. Only an operator naming the session
  /// asks for this.
  Forced
}

/// One tree an operator's sweep considered.
pub type Swept {
  Swept(
    /// The session the tree belongs to.
    session: String,
    /// The workspace it is a worktree of.
    workspace: String,
    /// Its directory.
    path: String,
    /// What the sweep did.
    closed: Closed,
  )
}

// Whether a recorded directory is on disk. A symbolic link is not a directory
// for this purpose: `simplifile.is_directory` follows links, so a link that
// points at a directory counts as one, and Git's own `worktree list` is what
// the `Creating` rule asks next.
type Disk {
  OnDisk
  Absent
}

fn disk_of(path: String) -> Disk {
  case simplifile.is_directory(path) {
    Ok(True) -> OnDisk
    Ok(False) | Error(_) -> Absent
  }
}

// A gate runs one job at a time, so everything Git does to one repository is
// ordered by the arrival of jobs at its mailbox.
type Gate =
  Subject(Job)

type Job {
  Job(work: fn() -> Nil, refuse: fn(String) -> Nil)
}

// A gate has reconciled its workspace or has not. The first job of a gate runs
// the preparation, and a preparation that fails leaves the gate to try again
// at the next job instead of admitting work onto records it could not settle.
type Phase {
  Unreconciled(prepare: fn() -> Result(Nil, String))
  Reconciled
}

// Everything one job needs, made inside the job so that the ledger connection
// lives and dies in the gate's process.
type Env {
  Env(git: Git, ledger: Ledger, config: Config)
}

// The names and paths one session's tree has.
type Spec {
  Spec(
    session: String,
    workspace: String,
    root: String,
    base: String,
    path: String,
    branch: String,
    parent: String,
  )
}

/// How long a job waits at its gate: thirty minutes, which covers the worst case
/// of one recreation (a prune, a branch check and a checkout, each with its own
/// ceiling) and a close that queues behind another session's checkout. A job that
/// outlives its caller's wait still finishes, and the next attach adopts its tree.
pub const gate_within_ms = 1_800_000

/// How many records a reconciliation settles between two log lines.
pub const reconcile_report_every = 100

/// Checks every worktree workspace's repository, boots the sandboxed Git and
/// starts a gate for each worktree workspace.
///
/// A workspace in shared mode needs nothing here. A worktree workspace whose
/// `root` is not the top of a primary checkout (a `.git` directory beside it) is
/// refused, so the daemon fails to start rather than failing every attach: a
/// linked worktree's `.git` is a file, and the common directory this module
/// writes would be somewhere else.
///
/// ## Examples
///
/// ```gleam
/// // worktrees.start(config, [workspaces.Workspace("repo", "/srv/repo", workspaces.Worktree("HEAD"))])
/// ```
pub fn start(
  config: Config,
  served: List(Workspace),
) -> Result(Worktrees, String) {
  let wanted = list.filter(served, is_worktree)

  // Decide how to handle wanted {.
  case wanted {
    [] -> Ok(Worktrees(config:, git: None, gates: []))
    _ -> {
      use state_root <- result.try(bootstrap.canonical_directory(
        config.state_root,
      ))
      let config = Config(..config, state_root:)
      use Nil <- result.try(list.try_each(wanted, checked))
      use git <- result.try(
        worktree_git.start(worktree_git.Config(
          helper_path: config.helper_path,
          scratch: state_root <> "/git",
          state_root:,
          demand: config.demand,
        )),
      )
      use gates <- result.map(
        list.try_map(wanted, fn(workspace) {
          gate_for(config, git, workspace)
          |> result.map(fn(gate) { #(workspace.name, gate) })
        }),
      )
      Worktrees(config:, git: Some(git), gates:)
    }
  }
}

/// Stops the sandboxed Git. The gates end with the process that started them.
///
/// ## Examples
///
/// ```gleam
/// // worktrees.stop(worktrees)
/// ```
pub fn stop(worktrees: Worktrees) -> Nil {
  // Decide how to handle worktrees.git {.
  case worktrees.git {
    Some(git) -> {
      let _drained = worktree_git.stop(git)
      Nil
    }
    None -> Nil
  }
}

/// Whether a workspace is in worktree mode.
///
/// ## Examples
///
/// ```gleam
/// assert !worktrees.is_worktree(workspaces.shared("repo", "/srv/repo"))
/// ```
pub fn is_worktree(workspace: Workspace) -> Bool {
  case workspace.mode {
    workspaces.Worktree(..) -> True
    workspaces.Shared -> False
  }
}

/// A name that may be a directory component: nonempty, at most 128 bytes, not
/// starting with a dot, and made of letters, digits, `_`, `-` and `.`. Session
/// ids and workspace names reach a path through this, so `..` and `/` never do.
///
/// ## Examples
///
/// ```gleam
/// assert worktrees.safe_component("0198c0de-0000-7000-8000-000000000001")
/// assert !worktrees.safe_component("../etc")
/// ```
pub fn safe_component(name: String) -> Bool {
  name != ""
  && string.byte_size(name) <= 128
  && !string.starts_with(name, ".")
  && list.all(string.to_graphemes(name), fn(each) {
    string.contains(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.",
      each,
    )
  })
}

/// The directory a session's tree has: `<state root>/worktrees/<workspace>/<session>`.
///
/// ## Examples
///
/// ```gleam
/// assert worktrees.tree_path("/s", "repo", "abc") == "/s/worktrees/repo/abc"
/// ```
pub fn tree_path(
  state_root: String,
  workspace: String,
  session: String,
) -> String {
  state_root <> "/" <> directory_name <> "/" <> workspace <> "/" <> session
}

/// The branch a session's tree has: `loom/<session id>`.
///
/// ## Examples
///
/// ```gleam
/// assert worktrees.branch_of("abc") == "loom/abc"
/// ```
pub fn branch_of(session: String) -> String {
  "loom/" <> session
}

/// The state root's directory of trees, which `client/daemon/root` creates
/// private before any session is admitted.
pub const directory_name = "worktrees"

/// Creates, adopts or recreates the session's tree and answers where it is.
///
/// - No record: write `Creating`, run `git worktree add <path> -b <branch>
///   <base>`, write `Present`.
/// - A `Present` or `Kept` record with the directory on disk: run `git worktree
///   repair` and adopt the tree.
/// - A `Removed` record, or a directory that has vanished: prune, then `git
///   worktree add <path> <branch>`, which checks out the session's own commits.
///   A branch that is gone is recreated from the base.
///
/// A command that fails removes the directory the `Creating` record names,
/// prunes, writes `Removed` and answers Git's message cut to the wire's limit,
/// so a half-made directory never makes every later attach fail the same way.
/// The work runs in the workspace's gate, so the caller waits behind any other
/// session's checkout on the same workspace.
///
/// ## Examples
///
/// ```gleam
/// // worktrees.open(worktrees, workspace, "0198c0de-0000-7000-8000-000000000001")
/// ```
pub fn open(
  worktrees: Worktrees,
  workspace: Workspace,
  session: String,
) -> Result(Tree, String) {
  use spec <- result.try(spec_of(worktrees, workspace, session))
  through(worktrees, workspace.name, fn(env) { opened(env, spec) })
}

/// Settles the session's tree after its scope retired cleanly.
///
/// A clean tree is removed with `git worktree remove --force`; a tree with
/// changes, or on a detached HEAD, or one Loom cannot check, is left and its
/// record says `Kept`. A session with no record has nothing to settle and
/// answers `Removed`. Nothing here raises: a close that cannot run answers
/// `Kept` with the reason, because a scope's cleanup has no use for an error.
///
/// ## Examples
///
/// ```gleam
/// // worktrees.close(worktrees, workspace, "0198c0de-0000-7000-8000-000000000001")
/// ```
pub fn close(
  worktrees: Worktrees,
  workspace: Workspace,
  session: String,
) -> Closed {
  let settled = {
    use spec <- result.try(spec_of(worktrees, workspace, session))
    through(worktrees, workspace.name, fn(env) {
      use recorded <- result.try(recorded(env, session))

      // Decide how to handle recorded {.
      case recorded {
        Some(row)
          if row.state == exec_ledger.Present || row.state == exec_ledger.Kept
        -> settle(env, spec, row, Careful)
        Some(_) | None -> Ok(Removed)
      }
    })
  }

  // Decide how to handle settled {.
  case settled {
    Ok(closed) -> closed
    Error(reason) -> {
      log.warn(worktrees.config.logger, "executor.worktree_close_failed", [
        field.ident(key: "session", value: session),
        field.text(key: "reason", value: reason),
      ])
      Kept(reason)
    }
  }
}

/// The operator's sweep: settles every tree the executor made for the given
/// workspaces and answers what happened to each.
///
/// A tree is removed under the rule of a close, so one with changes is kept. A
/// session named in `forced` is removed whatever it holds, because the operator
/// named it. Records in `Removed` are not listed. The executor daemon must not
/// be running: the sweep opens the ledger and removes trees that a live plane
/// could be using, which is the same condition `loomd executor release` states
/// for a scope.
///
/// ## Examples
///
/// ```gleam
/// // worktrees.sweep(worktrees, served, forced: ["0198c0de-0000-7000-8000-000000000001"])
/// ```
pub fn sweep(
  worktrees: Worktrees,
  served: List(Workspace),
  forced forced: List(String),
) -> Result(List(Swept), String) {
  list.filter(served, is_worktree)
  |> list.try_map(fn(workspace) {
    through(worktrees, workspace.name, fn(env) {
      use rows <- result.try(workspace_rows(env, workspace.name))
      list.filter(rows, fn(row) {
        row.state == exec_ledger.Present || row.state == exec_ledger.Kept
      })
      |> list.try_map(fn(row) {
        use spec <- result.try(spec_of(worktrees, workspace, row.session))

        // Decide how to handle let force =  list.contains(forced, row.session) {.
        let force = case list.contains(forced, row.session) {
          True -> Forced
          False -> Careful
        }

        use closed <- result.map(settle(env, spec, row, force))
        Swept(
          session: row.session,
          workspace: workspace.name,
          path: row.path,
          closed:,
        )
      })
    })
  })
  |> result.map(list.flatten)
}

/// How many directories under the worktree workspaces' directories no ledger
/// row names. They were not made by this executor, so nothing removes them; the
/// census reports the count so that an operator can look.
///
/// ## Examples
///
/// ```gleam
/// // worktrees.unrecorded(worktrees, served)
/// ```
pub fn unrecorded(worktrees: Worktrees, served: List(Workspace)) -> Int {
  let config = worktrees.config
  let counted =
    list.filter(served, is_worktree)
    |> list.try_map(fn(workspace) {
      use rows <- result.try(
        with_ledger(config.ledger_path, fn(ledger) {
          exec_ledger.workspace_trees(ledger, workspace.name)
          |> result.map_error(ledger_fault)
        }),
      )
      let recorded = list.map(rows, fn(row) { row.path })
      let directory =
        config.state_root <> "/" <> directory_name <> "/" <> workspace.name
      let present = simplifile.read_directory(directory) |> result.unwrap([])
      Ok(
        list.count(present, fn(entry) {
          let path = directory <> "/" <> entry
          disk_of(path) == OnDisk && !list.contains(recorded, path)
        }),
      )
    })

  // Decide how to handle counted {.
  case counted {
    Ok(each) -> int.sum(each)
    Error(_reason) -> 0
  }
}

// --- the gates ------------------------------------------------------------------

// Starts the gate of one workspace. Its preparation is the workspace's
// reconciliation, and it runs ahead of the gate's first job.

/// Establishes gate for for the caller, keeping its validation and result policy at this boundary.
fn gate_for(
  config: Config,
  git: Git,
  workspace: Workspace,
) -> Result(Gate, String) {
  let prepare = fn() {
    use root <- result.try(canonical_root(workspace))
    with_env(config, git, fn(env) { reconcile(env, workspace, root) })
  }
  actor.new(Unreconciled(prepare))
  |> actor.on_message(run_job)
  |> actor.start
  |> result.map(fn(started) { started.data })
  |> result.map_error(fn(error) {
    "the worktree gate for "
    <> workspace.name
    <> " did not start: "
    <> string.inspect(error)
  })
}

// One job at a time. A job arriving at a gate that has not reconciled runs the
// preparation first; if that fails the job is refused with its reason and the
// gate stays unreconciled, so the next attach tries again.

/// Establishes run job for the caller, keeping its validation and result policy at this boundary.
fn run_job(phase: Phase, job: Job) -> actor.Next(Phase, Job) {
  // Decide how to handle phase {.
  case phase {
    Reconciled -> {
      job.work()
      actor.continue(Reconciled)
    }
    Unreconciled(prepare:) ->
      case prepare() {
        Ok(Nil) -> {
          job.work()
          actor.continue(Reconciled)
        }
        Error(reason) -> {
          job.refuse(reason)
          actor.continue(phase)
        }
      }
  }
}

// Runs `work` in the workspace's gate and waits for its answer. The answer
// travels on a subject only this call holds. A gate that does not answer within
// `gate_within_ms` is reported, and its job may still finish later.

/// Establishes through for the caller, keeping its validation and result policy at this boundary.
fn through(
  worktrees: Worktrees,
  workspace: String,
  work: fn(Env) -> Result(a, String),
) -> Result(a, String) {
  use gate <- result.try(
    list.key_find(worktrees.gates, workspace)
    |> result.map_error(fn(_missing) {
      "the workspace "
      <> workspace
      <> " is not in worktree mode on this executor"
    }),
  )
  use git <- result.try(option.to_result(
    worktrees.git,
    "the sandboxed Git is not running",
  ))
  let reply = process.new_subject()
  let config = worktrees.config
  process.send(
    gate,
    Job(
      work: fn() { process.send(reply, with_env(config, git, work)) },
      refuse: fn(reason) { process.send(reply, Error(reason)) },
    ),
  )

  // Decide how to handle process.receive(reply, gate_within_ms) {.
  case process.receive(reply, gate_within_ms) {
    Ok(answer) -> answer
    Error(Nil) -> Error("the worktree gate did not answer in time")
  }
}

// Opens the job's ledger connection and closes it when the job is over.

/// Establishes with env for the caller, keeping its validation and result policy at this boundary.
fn with_env(
  config: Config,
  git: Git,
  work: fn(Env) -> Result(a, String),
) -> Result(a, String) {
  with_ledger(config.ledger_path, fn(ledger) {
    work(Env(git:, ledger:, config:))
  })
}

/// Establishes with ledger for the caller, keeping its validation and result policy at this boundary.
fn with_ledger(
  path: String,
  work: fn(Ledger) -> Result(a, String),
) -> Result(a, String) {
  use ledger <- result.try(
    exec_ledger.connect(path)
    |> result.map_error(fn(error) {
      "the execution ledger did not open for the worktree records: "
      <> string.inspect(error)
    }),
  )
  let outcome = work(ledger)
  let _closed = exec_ledger.close(ledger)
  outcome
}

fn ledger_fault(error: exec_ledger.Error) -> String {
  "the worktree record could not be read or written: " <> string.inspect(error)
}

// --- checking a configuration ---------------------------------------------------

// A worktree workspace's repository has to be a primary checkout. The shared
// object store, refs and hooks this module writes through are `<root>/.git`, and
// a linked worktree's `.git` is a file that points somewhere else.

/// Establishes checked for the caller, keeping its validation and result policy at this boundary.
fn checked(workspace: Workspace) -> Result(Nil, String) {
  let place = "workspaces." <> workspace.name

  // Decide how to handle use Nil <- result.try( safe_component(workspace.name) {.
  use Nil <- result.try(case safe_component(workspace.name) {
    True -> Ok(Nil)
    False ->
      Error(
        place
        <> " is in worktree mode, so its name becomes a directory name: use "
        <> "letters, digits, _, - and ., not starting with a dot",
      )
  })

  use root <- result.try(
    canonical_root(workspace)
    |> result.map_error(fn(reason) { place <> ".root " <> reason }),
  )

  // Decide how to handle simplifile.is_directory(root <> "/.git") {.
  case simplifile.is_directory(root <> "/.git") {
    Ok(True) -> Ok(Nil)
    Ok(False) | Error(_) ->
      Error(
        place
        <> " is in worktree mode, so root "
        <> root
        <> " must be the top of a non-bare Git checkout whose .git is a "
        <> "directory (a primary checkout, not a linked worktree)",
      )
  }
}

fn canonical_root(workspace: Workspace) -> Result(String, String) {
  bootstrap.canonical_directory(workspace.root)
  |> result.map_error(fn(reason) { "is not a directory: " <> reason })
}

// The names and paths of one session's tree, judged before anything touches
// the disk. The session id arrives from a peer, so it is checked as a path
// component, and the base is the configured one, never the peer's.

/// Establishes spec of for the caller, keeping its validation and result policy at this boundary.
fn spec_of(
  worktrees: Worktrees,
  workspace: Workspace,
  session: String,
) -> Result(Spec, String) {
  // Decide how to handle use base <- result.try( workspace.mode {.
  use base <- result.try(case workspace.mode {
    workspaces.Worktree(base:) -> Ok(base)
    workspaces.Shared ->
      Error("the workspace " <> workspace.name <> " is not in worktree mode")
  })

  // Decide how to handle use Nil <- result.try( safe_component(session) {.
  use Nil <- result.try(case safe_component(session) {
    True -> Ok(Nil)
    False -> Error("the session name is not usable as a directory name")
  })

  use root <- result.try(
    canonical_root(workspace)
    |> result.map_error(fn(reason) {
      "the workspace " <> workspace.name <> " " <> reason
    }),
  )
  let state_root = worktrees.config.state_root
  Ok(Spec(
    session:,
    workspace: workspace.name,
    root:,
    base:,
    path: tree_path(state_root, workspace.name, session),
    branch: branch_of(session),
    parent: state_root <> "/" <> directory_name <> "/" <> workspace.name,
  ))
}

// --- opening a tree -------------------------------------------------------------

/// Establishes opened for the caller, keeping its validation and result policy at this boundary.
fn opened(env: Env, spec: Spec) -> Result(Tree, String) {
  use recorded <- result.try(recorded(env, spec.session))

  // Decide how to handle use Nil <- result.try( recorded {.
  use Nil <- result.try(case recorded {
    None -> create(env, spec)
    Some(row) -> reopen(env, spec, row)
  })

  Ok(Tree(path: spec.path, branch: spec.branch))
}

fn recorded(env: Env, session: String) -> Result(Option(Row), String) {
  exec_ledger.tree(env.ledger, session) |> result.map_error(ledger_fault)
}

fn workspace_rows(env: Env, workspace: String) -> Result(List(Row), String) {
  exec_ledger.workspace_trees(env.ledger, workspace)
  |> result.map_error(ledger_fault)
}

/// Establishes record for the caller, keeping its validation and result policy at this boundary.
fn record(
  env: Env,
  spec: Spec,
  state: exec_ledger.TreeState,
) -> Result(Nil, String) {
  exec_ledger.record_tree(
    env.ledger,
    exec_ledger.Tree(
      session: spec.session,
      workspace: spec.workspace,
      path: spec.path,
      branch: spec.branch,
      state:,
    ),
  )
  |> result.map_error(ledger_fault)
}

// The first attach of a session. The record comes first, so a crash between it
// and the command leaves a row that names the directory to look at.

/// Establishes create for the caller, keeping its validation and result policy at this boundary.
fn create(env: Env, spec: Spec) -> Result(Nil, String) {
  // A first attach has no record, so a directory at the path is not ours: the
  // ledger may have been reset while trees remained. The `Creating` record
  // below would let a failed add delete it, so it is refused instead.
  use Nil <- result.try(case disk_of(spec.path) {
    Absent -> Ok(Nil)
    OnDisk ->
      Error(
        "a directory no worktree record names is at "
        <> spec.path
        <> "; move it away or restore the executor's ledger",
      )
  })

  use Nil <- result.try(record(env, spec, exec_ledger.Creating))
  use Nil <- result.try(parent_directory(spec))
  add(env, spec, ["worktree", "add", spec.path, "-b", spec.branch, spec.base])
}

// A session whose tree was recorded. A tree on disk is adopted after Git
// repairs its links, which also covers a state root that moved. A tree that is
// not on disk, or was removed, is recreated from the session's branch.

/// Establishes reopen for the caller, keeping its validation and result policy at this boundary.
fn reopen(env: Env, spec: Spec, row: Row) -> Result(Nil, String) {
  case row.state, disk_of(spec.path) {
    exec_ledger.Present, OnDisk | exec_ledger.Kept, OnDisk ->
      adopt(env, spec, row)
    exec_ledger.Present, Absent
    | exec_ledger.Kept, Absent
    | exec_ledger.Removed, Absent
    -> recreate(env, spec)

    // The record proves Loom made this directory and had finished with it, so
    // what is there is a leftover and not the session's work.
    exec_ledger.Removed, OnDisk -> {
      use Nil <- result.try(forget_directory(spec))
      recreate(env, spec)
    }
    exec_ledger.Creating, disk | exec_ledger.Removing, disk ->
      interrupted(env, spec, row, disk)
  }
}

// A record left `Creating` or `Removing` while the executor ran: the undo that
// would have closed it failed to write. The reconciliation rule for the state
// settles it, and the session then opens as if the record had been tidy. A rule
// that left the record where it was would be the same refusal again, so that
// case is the error it is.

/// Establishes interrupted for the caller, keeping its validation and result policy at this boundary.
fn interrupted(
  env: Env,
  spec: Spec,
  row: Row,
  disk: Disk,
) -> Result(Nil, String) {
  use Nil <- result.try(reconcile_state(env, spec, row.state, disk))
  use settled <- result.try(recorded(env, spec.session))

  // Decide how to handle settled {.
  case settled {
    Some(next) if next.state != row.state -> reopen(env, spec, next)
    Some(_) | None ->
      Error("the worktree record for this session could not be settled")
  }
}

/// Establishes adopt for the caller, keeping its validation and result policy at this boundary.
fn adopt(env: Env, spec: Spec, row: Row) -> Result(Nil, String) {
  use _repaired <- result.try(
    git_ok(env, spec.root, writing(spec), ["worktree", "repair", spec.path]),
  )

  // Decide how to handle row.state {.
  case row.state {
    exec_ledger.Kept -> record(env, spec, exec_ledger.Present)
    exec_ledger.Present
    | exec_ledger.Creating
    | exec_ledger.Removing
    | exec_ledger.Removed -> Ok(Nil)
  }
}

// The branch is the session's: if it still exists the tree is made from it, so
// the session finds its commits, and if it was deleted the tree starts again
// from the base. Pruning first drops Git's record of the vanished directory,
// without which Git refuses to check the branch out a second time.

/// Establishes recreate for the caller, keeping its validation and result policy at this boundary.
fn recreate(env: Env, spec: Spec) -> Result(Nil, String) {
  use Nil <- result.try(record(env, spec, exec_ledger.Creating))
  use Nil <- result.try(parent_directory(spec))
  use _pruned <- result.try(
    git_ok(env, spec.root, writing(spec), ["worktree", "prune"]),
  )
  use exists <- result.try(branch_exists(env, spec))

  // Decide how to handle exists {.
  case exists {
    True -> add(env, spec, ["worktree", "add", spec.path, spec.branch])
    False -> {
      log.warn(env.config.logger, "executor.worktree_branch_recreated", [
        field.ident(key: "session", value: spec.session),
        field.text(key: "branch", value: spec.branch),
      ])
      add(env, spec, [
        "worktree", "add", spec.path, "-b", spec.branch, spec.base,
      ])
    }
  }
}

// Runs the command that makes the tree and writes `Present` when it works.
// When it fails the directory the `Creating` record names is deleted, Git's
// registration pruned and the record closed as `Removed`, whatever state the
// failure left the disk in.

/// Establishes add for the caller, keeping its validation and result policy at this boundary.
fn add(env: Env, spec: Spec, arguments: List(String)) -> Result(Nil, String) {
  // Decide how to handle git_ok(env, spec.root, writing(spec), arguments) {.
  case git_ok(env, spec.root, writing(spec), arguments) {
    Ok(_output) -> record(env, spec, exec_ledger.Present)
    Error(reason) -> {
      let _undone = undo(env, spec)
      Error(reason)
    }
  }
}

/// Establishes undo for the caller, keeping its validation and result policy at this boundary.
fn undo(env: Env, spec: Spec) -> Result(Nil, String) {
  use Nil <- result.try(parent_directory(spec))
  use Nil <- result.try(forget_directory(spec))
  use _pruned <- result.try(
    git_ok(env, spec.root, writing(spec), ["worktree", "prune"]),
  )
  record(env, spec, exec_ledger.Removed)
}

/// Establishes branch exists for the caller, keeping its validation and result policy at this boundary.
fn branch_exists(env: Env, spec: Spec) -> Result(Bool, String) {
  use output <- result.map(
    git_run(env, spec.root, [], [
      "rev-parse",
      "--verify",
      "--quiet",
      "refs/heads/" <> spec.branch,
    ]),
  )
  output.code == 0
}

// Makes the workspace's directory under `worktrees/`, private, so that the
// writable root the next Git call names exists.
fn parent_directory(spec: Spec) -> Result(Nil, String) {
  ensure_directories(spec.parent)
}

// The state root's `worktrees/` directory is made private at the daemon's
// start, before any session is admitted. It is made here too, with the same
// mode, for a caller that never ran that start, such as the operator's sweep.
fn ensure_directories(workspace_directory: String) -> Result(Nil, String) {
  let worktrees = filepath.directory_name(workspace_directory)
  use Nil <- result.try(bootstrap.ensure_private_directory(worktrees))
  bootstrap.ensure_private_directory(workspace_directory)
}

// Deletes the directory a record names. It is deleted only when it is exactly
// the path the layout gives this session, so a damaged row cannot send the
// deletion anywhere else.

/// Establishes forget directory for the caller, keeping its validation and result policy at this boundary.
fn forget_directory(spec: Spec) -> Result(Nil, String) {
  case simplifile.delete(spec.path) {
    Ok(Nil) | Error(simplifile.Enoent) -> Ok(Nil)
    Error(error) ->
      Error(
        "the directory "
        <> spec.path
        <> " could not be removed: "
        <> simplifile.describe_error(error),
      )
  }
}

// --- closing a tree -------------------------------------------------------------

// Removes the tree, or leaves it, and writes the record that says which.

/// Establishes settle for the caller, keeping its validation and result policy at this boundary.
fn settle(
  env: Env,
  spec: Spec,
  row: Row,
  force: Force,
) -> Result(Closed, String) {
  case force {
    Forced -> remove(env, spec, force)
    Careful ->
      case holds_work(env, spec) {
        Ok(None) -> remove(env, spec, force)
        Ok(Some(reason)) -> keep(env, spec, row, reason)
        Error(reason) ->
          keep(env, spec, row, "it could not be checked: " <> reason)
      }
  }
}

/// Establishes keep for the caller, keeping its validation and result policy at this boundary.
fn keep(
  env: Env,
  spec: Spec,
  row: Row,
  reason: String,
) -> Result(Closed, String) {
  // Decide how to handle use Nil <- result.map( row.state {.
  use Nil <- result.map(case row.state {
    exec_ledger.Kept -> Ok(Nil)
    exec_ledger.Present
    | exec_ledger.Creating
    | exec_ledger.Removing
    | exec_ledger.Removed -> record(env, spec, exec_ledger.Kept)
  })

  Kept(reason)
}

// What a tree holds that removal would lose, or `None` when it holds none.
// The status excludes Loom's own `.codemode` directory, which every code-mode
// session leaves untracked, and a detached HEAD is work too: its commits are
// held by no branch.

/// Establishes holds work for the caller, keeping its validation and result policy at this boundary.
fn holds_work(env: Env, spec: Spec) -> Result(Option(String), String) {
  use status <- result.try(
    git_ok(env, spec.path, [], [
      "status", "--porcelain=v1", "--untracked-files=normal", "--", ".",
      ":(exclude).codemode",
    ]),
  )

  // Decide how to handle string.trim(status.stdout) {.
  case string.trim(status.stdout) {
    "" -> {
      use head <- result.map(
        git_run(env, spec.path, [], ["symbolic-ref", "--quiet", "HEAD"]),
      )

      // Decide how to handle head.code {.
      case head.code {
        0 -> None
        _ -> Some("its HEAD is detached, so its commits belong to no branch")
      }
    }
    _changes -> Ok(Some("it holds changes"))
  }
}

// `removing` is written first so that a crash during the command is finished by
// the next start. A failed command puts the record back to `Present` when the
// directory is still there, because then the tree is as it was.

/// Establishes remove for the caller, keeping its validation and result policy at this boundary.
fn remove(env: Env, spec: Spec, force: Force) -> Result(Closed, String) {
  use Nil <- result.try(record(env, spec, exec_ledger.Removing))

  // Decide how to handle the branch input.
  case
    git_ok(env, spec.root, writing(spec), [
      "worktree", "remove", "--force", spec.path,
    ])
  {
    Ok(_output) -> {
      use Nil <- result.map(record(env, spec, exec_ledger.Removed))
      Removed
    }

    // An operator who named the session wants it gone even when Git no longer
    // recognises the directory (a removal that crashed half way leaves one):
    // the recorded path is deleted, Git's registration pruned.
    Error(_reason) if force == Forced -> {
      use Nil <- result.map(undo(env, spec))
      Removed
    }
    Error(reason) -> {
      let _restored = record(env, spec, exec_ledger.Present)
      Ok(Kept("its removal failed: " <> reason))
    }
  }
}

// --- reconciliation -------------------------------------------------------------

// Settles every record of one workspace against the disk, then prunes Git's
// registrations of directories deleted outside Loom. It is the gate's
// preparation, so no session of the workspace is admitted before it ends, and
// a failure is refused to the session that triggered it and tried again at the
// next attach. A directory with no record is not touched here or anywhere.

/// Establishes reconcile for the caller, keeping its validation and result policy at this boundary.
fn reconcile(
  env: Env,
  workspace: Workspace,
  root: String,
) -> Result(Nil, String) {
  use rows <- result.try(workspace_rows(env, workspace.name))
  let total = list.length(rows)
  use Nil <- result.try(
    list.index_fold(rows, Ok(Nil), fn(settled, row, index) {
      use Nil <- result.try(settled)
      use Nil <- result.map(reconcile_row(env, workspace, root, row))
      report(env, workspace.name, index + 1, total)
    }),
  )
  let directory = workspace_directory(env, workspace)
  use Nil <- result.try(ensure_directories(directory))
  use _pruned <- result.map(
    git_ok(env, root, [root <> "/.git", directory], ["worktree", "prune"]),
  )
  Nil
}

fn workspace_directory(env: Env, workspace: Workspace) -> String {
  env.config.state_root <> "/" <> directory_name <> "/" <> workspace.name
}

/// Establishes report for the caller, keeping its validation and result policy at this boundary.
fn report(env: Env, workspace: String, done: Int, total: Int) -> Nil {
  case done % reconcile_report_every == 0 {
    True ->
      log.info(env.config.logger, "executor.worktree_reconcile", [
        field.ident(key: "workspace", value: workspace),
        field.count(key: "done", value: done),
        field.count(key: "left", value: total - done),
      ])
    False -> Nil
  }
}

/// Establishes reconcile row for the caller, keeping its validation and result policy at this boundary.
fn reconcile_row(
  env: Env,
  workspace: Workspace,
  root: String,
  row: Row,
) -> Result(Nil, String) {
  let state_root = env.config.state_root
  let expected = tree_path(state_root, workspace.name, row.session)

  // Decide how to handle row.path == expected && safe_component(row.session) {.
  case row.path == expected && safe_component(row.session) {
    False -> {
      log.warn(env.config.logger, "executor.worktree_record_skipped", [
        field.ident(key: "session", value: row.session),
        field.text(key: "reason", value: "its path is not the layout's"),
      ])
      Ok(Nil)
    }
    True -> {
      let spec =
        Spec(
          session: row.session,
          workspace: workspace.name,
          root:,
          base: base_of(workspace),
          path: row.path,
          branch: row.branch,
          parent: workspace_directory(env, workspace),
        )
      reconcile_state(env, spec, row.state, disk_of(row.path))
    }
  }
}

fn base_of(workspace: Workspace) -> String {
  case workspace.mode {
    workspaces.Worktree(base:) -> base
    workspaces.Shared -> workspaces.default_base
  }
}

// The rules of protocol-change/095, one arm for each state of the record.

/// Establishes reconcile state for the caller, keeping its validation and result policy at this boundary.
fn reconcile_state(
  env: Env,
  spec: Spec,
  state: exec_ledger.TreeState,
  disk: Disk,
) -> Result(Nil, String) {
  case state, disk {
    // A crash on either side of `git worktree add`: the tree is there and
    // Git lists it, or whatever is on disk is a half-made leftover.
    exec_ledger.Creating, _ -> {
      use listed <- result.try(is_listed(env, spec))

      // Decide how to handle disk, listed {.
      case disk, listed {
        OnDisk, True -> record(env, spec, exec_ledger.Present)
        OnDisk, False | Absent, True | Absent, False -> undo(env, spec)
      }
    }

    // A crash during removal: finish it under the close's own rule.
    exec_ledger.Removing, OnDisk -> {
      let row =
        exec_ledger.Tree(
          session: spec.session,
          workspace: spec.workspace,
          path: spec.path,
          branch: spec.branch,
          state: exec_ledger.Removing,
        )
      use _closed <- result.map(settle(env, spec, row, Careful))
      Nil
    }
    exec_ledger.Removing, Absent -> undo(env, spec)

    // The record says Loom had finished with this directory.
    exec_ledger.Removed, OnDisk -> undo(env, spec)
    exec_ledger.Removed, Absent -> Ok(Nil)

    // A tree deleted by hand since the last run.
    exec_ledger.Present, Absent | exec_ledger.Kept, Absent ->
      record(env, spec, exec_ledger.Removed)
    exec_ledger.Present, OnDisk | exec_ledger.Kept, OnDisk -> Ok(Nil)
  }
}

// Whether `git worktree list` registers the tree's path.

/// Establishes is listed for the caller, keeping its validation and result policy at this boundary.
fn is_listed(env: Env, spec: Spec) -> Result(Bool, String) {
  use output <- result.map(
    git_ok(env, spec.root, [], ["worktree", "list", "--porcelain"]),
  )
  string.split(output.stdout, "\n")
  |> list.any(fn(line) { line == "worktree " <> spec.path })
}

// --- running Git ----------------------------------------------------------------

// The paths a Git call that changes trees may write: the repository's `.git`,
// where worktree administration and branches live, and the workspace's
// directory of trees. Nothing else, so the session trees of other workspaces,
// the ledger and the state root's secrets are out of reach.
fn writing(spec: Spec) -> List(String) {
  [spec.root <> "/.git", spec.parent]
}

/// Establishes git run for the caller, keeping its validation and result policy at this boundary.
fn git_run(
  env: Env,
  directory: String,
  writable: List(String),
  arguments: List(String),
) -> Result(Output, String) {
  // Decide how to handle let within =  writable {.
  let within = case writable {
    [] -> worktree_git.query_within_ms
    _ -> worktree_git.checkout_within_ms
  }

  worktree_git.run(
    env.git,
    worktree_git.Run(directory:, writable:, arguments:),
    within,
  )
}

// Git that must exit zero. A failure answers Git's own message, cut to what the
// wire carries.

/// Establishes git ok for the caller, keeping its validation and result policy at this boundary.
fn git_ok(
  env: Env,
  directory: String,
  writable: List(String),
  arguments: List(String),
) -> Result(Output, String) {
  use output <- result.try(git_run(env, directory, writable, arguments))

  // Decide how to handle output.code {.
  case output.code {
    0 -> Ok(output)
    code -> {
      // Decide how to handle let said =  string.trim(output.stderr) {.
      let said = case string.trim(output.stderr) {
        "" -> output.stdout
        message -> message
      }

      Error(worktree_git.printable(
        "git "
          <> string.join(list.take(arguments, 2), " ")
          <> " exited "
          <> int.to_string(code)
          <> ": "
          <> said,
        protocol.max_worktree_reason,
      ))
    }
  }
}
