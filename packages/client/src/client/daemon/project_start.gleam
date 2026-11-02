//// Starting projects: the daemon's half of project mode that creates rows,
//// sessions and actors.
////
//// `client/daemon/project_host` is the actor and knows nothing of the
//// catalogue or the registry. This module is what fills its `Ports` from them
//// and what creates a project, starts the actors of the projects that exist,
//// and reopens their sessions at boot.
////
//// ## Flow
////
//// `create` → `ensure_running` → `ports_for` → `start_worker` → `reopen`
////
//// 1. `create` makes a project for a workspace: its private directory, the
////    router's registration, the catalogue row, the actor, and last the
////    router session's open. The project id is a function of the workspace,
////    so creating twice is the same project.
//// 2. `ensure_running` starts a project's actor once and records it in the
////    table, so a session built afterwards can find its handle.
//// 3. `ports_for` builds the closures the actor performs effects with.
//// 4. `start_worker` makes a worker session in a linked worktree of the
////    project's checkout. The registration is reserved first and bound to its
////    assignment second, and only then opened, so the session's builder reads
////    its standing before it builds.
//// 5. `reopen` runs at boot. It starts each active project's actor, then
////    opens its router and the sessions of its live assignments.
////
//// ## Why a worktree is named from the ticket
////
//// A session's id is minted when its registration is reserved, and its
//// workspace is part of that reservation, so the tree has to exist before the
//// id does. The tree is therefore named from the ticket and the assignment
//// (`worktrees.open` takes any safe name where it would take a session id),
//// and its branch is `loom/<ticket>-<seq>`.

import client/daemon/manager
import client/daemon/project_book.{type Book}
import client/daemon/project_host
import client/peer_mail
import client/project_scan
import client/project_standing
import client/projectseam
import client/serve
import client/workspaces
import client/worktrees.{type Worktrees}
import core/ids
import gleam/bit_array
import gleam/crypto
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import storage/catalogue
import storage/domain
import telemetry/field
import telemetry/log.{type Logger}

/// Everything project startup needs from the daemon.
pub type Env {
  Env(
    /// The table of running projects.
    book: Book,
    /// The session registry.
    registry: manager.Manager(serve.Resident),
    /// The private directory sessions' stores live in.
    sessions: String,
    /// The daemon's state root; projects live under `projects/`.
    state_root: String,
    /// A fresh id generator.
    generator: fn() -> ids.Generator,
    /// The captured domain configuration reference for new sessions.
    domain_configuration: String,
    /// Builds the worktree service over a project's checkout, or says why it
    /// cannot (the sandbox helper is missing, say).
    worktrees_for: fn(workspaces.Workspace) -> Result(Worktrees, String),
    /// The system clock in Unix milliseconds.
    now_ms: fn() -> Int,
    /// General worker slots per project.
    max_workers: Int,
    /// Where startup reports.
    logger: Logger,
  )
}

/// What the control commands may ask of project mode: the running projects and
/// the creation of a new one. The daemon builds it once the registry is ready.
pub type Control {
  Control(
    /// The running projects.
    book: Book,
    /// Creates a project for a workspace and a name, or finds the existing one.
    create: fn(String, String) -> Result(Created, String),
  )
}

/// A created project, for the control reply.
pub type Created {
  Created(
    /// The project's id.
    project: String,
    /// The workspace it is bound to.
    workspace: String,
    /// The router's session id.
    router_session: String,
  )
}

/// The project id for a canonical workspace: `p-` and twelve hex digits of
/// the path's SHA-256. The id is a function of the workspace, so creating a
/// project twice finds the first one.
///
/// ## Examples
///
/// ```gleam
/// assert project_start.project_id("/work/repo") == project_start.project_id("/work/repo")
/// ```
pub fn project_id(workspace: String) -> String {
  let digest =
    crypto.hash(crypto.Sha256, bit_array.from_string(workspace))
    |> bit_array.base16_encode
    |> string.lowercase
  "p-" <> string.slice(digest, 0, 12)
}

/// Creates the project for a workspace, or finds the one it has, and makes
/// sure its actor and router session are running.
///
/// ## Examples
///
/// ```gleam
/// // project_start.create(env, "/work/repo", "repo")
/// ```
pub fn create(
  env: Env,
  workspace: String,
  name: String,
) -> Result(Created, String) {
  use canonical <- result.try(
    bootstrap.canonical_directory(workspace)
    |> result.replace_error("the workspace is not a directory"),
  )
  let id = project_id(canonical)
  use existing <- result.try(
    in_catalogue(env, fn(store) {
      catalogue.project_of_workspace(store, canonical)
    })
    |> result.map_error(catalogue_text),
  )

  // A workspace that already has a project keeps it.
  use found <- result.try(case existing {
    Some(found) -> Ok(found)
    None -> make_project(env, id, canonical, name)
  })

  use handle <- result.try(ensure_running(env, found))
  use Nil <- result.map(open_router(env, found))
  Created(
    project: handle.project,
    workspace: found.workspace,
    router_session: found.router_session,
  )
}

/// The router's registration is reserved and the row written before the actor
/// starts, and the session is opened last: the session's builder looks up the
/// project's handle and its standing as it builds.
fn make_project(
  env: Env,
  id: String,
  workspace: String,
  name: String,
) -> Result(catalogue.Project, String) {
  let directory = env.state_root <> "/projects/" <> id
  use Nil <- result.try(
    bootstrap.ensure_private_directory(env.state_root <> "/projects")
    |> result.try(fn(_) { bootstrap.ensure_private_directory(directory) })
    |> result.map_error(fn(reason) {
      "the project directory was not made: " <> string.inspect(reason)
    }),
  )
  use registration <- result.try(
    manager.reserve(
      env.registry,
      manager.Creation(
        request_key: "project-router:" <> id,
        workspace:,
        name: "project " <> name,
        configuration: "",
        profile: None,
        model: None,
        executor: "",
        pool: "",
      ),
      directory: env.sessions,
      generator: env.generator(),
      scope: domain.WorkspacePrivate,
      configuration: env.domain_configuration,
    )
    |> result.map_error(fn(error) { string.inspect(error) }),
  )
  let row =
    catalogue.Project(
      id:,
      workspace:,
      router_session: registration.id,
      ledger_path: directory <> "/ledger.db",
      state: catalogue.ProjectActive,
      created_ms: env.now_ms(),
    )
  use Nil <- result.map(
    in_catalogue(env, fn(store) { catalogue.create_project(store, row) })
    |> result.map_error(catalogue_text),
  )
  row
}

/// Starts a project's actor if it is not running and records its handle.
///
/// ## Examples
///
/// ```gleam
/// // project_start.ensure_running(env, project)
/// ```
pub fn ensure_running(
  env: Env,
  project: catalogue.Project,
) -> Result(project_host.Handle, String) {
  // A project already in the table keeps its actor. Starting a second one
  // would put two writers on one ledger.
  case project_book.get(env.book, project.id) {
    Ok(running) -> Ok(running)
    Error(Nil) -> {
      use started <- result.map(
        project_host.start(
          project_host.Config(
            project: project.id,
            workspace: project.workspace,
            router_session: project.router_session,
            ledger_path: project.ledger_path,
            max_workers: env.max_workers,
            tick_ms: 2000,
            router_turn_ms: 120_000,
            ports: fn() { ports_for(env, project) },
          ),
        ),
      )
      project_book.put(env.book, started)
      started
    }
  }
}

/// Opens the project's router session. The request key reserves the session
/// when the project is created, so this resumes it and never makes another.
fn open_router(env: Env, project: catalogue.Project) -> Result(Nil, String) {
  use found <- result.try(
    manager.get(env.registry, project.router_session)
    |> result.map_error(fn(error) { string.inspect(error) }),
  )

  // Creating under the reserving request key opens the router, and repeating
  // it finds the registration it made. A repeat must carry what the
  // reservation carried, the name `make_project` gave it included, or the
  // registry refuses it as a conflicting request.
  manager.create_scoped(
    env.registry,
    manager.Creation(
      request_key: "project-router:" <> project.id,
      workspace: project.workspace,
      name: found.registration.name,
      configuration: "",
      profile: None,
      model: None,
      executor: "",
      pool: "",
    ),
    directory: env.sessions,
    generator: env.generator(),
    scope: domain.WorkspacePrivate,
    configuration: env.domain_configuration,
  )
  |> result.replace(Nil)
  |> result.map_error(fn(error) { string.inspect(error) })
}

// --- ports -------------------------------------------------------------------

/// The daemon's side of one project: how its actor reads the clock, creates
/// and opens sessions, and reaches a session's peer endpoint. They are
/// closures over the registry, so the actor holds no reference to a session.
fn ports_for(env: Env, project: catalogue.Project) -> project_host.Ports {
  let tree_workspace =
    workspaces.Workspace(
      name: project.id,
      root: project.workspace,
      mode: workspaces.Worktree(workspaces.default_base),
    )

  // The worktree service is started once, here, in the actor's own process.
  let trees = env.worktrees_for(tree_workspace)
  project_host.Ports(
    now_ms: env.now_ms,
    start_session: fn(request) {
      use trees <- result.try(trees)
      start_worker(env, project, tree_workspace, trees, request)
    },
    open_session: fn(session) {
      manager.open(env.registry, session)
      |> result.replace(Nil)
      |> result.map_error(fn(error) { string.inspect(error) })
    },
    stop_session: fn(session) {
      manager.stop_session(env.registry, session)
      |> result.replace(Nil)
      |> result.map_error(fn(error) { string.inspect(error) })
    },
    release_worktree: fn(request) {
      use trees <- result.try(trees)
      release_tree(env, tree_workspace, trees, request)
    },
    endpoint_of: fn(session) {
      case manager.resolve(env.registry, session) {
        Ok(resident) -> Ok(resident.peer)
        Error(_) -> Error(peer_mail.NotOpen)
      }
    },
    logger: env.logger,
  )
}

/// A worker session in a linked worktree. Creating the tree twice adopts it,
/// reserving twice finds the registration, binding twice is refused as a
/// conflict that is accepted when the standing already is this assignment, and
/// creating twice finds the session. A restart anywhere in the sequence
/// therefore ends with one session and one tree.
fn start_worker(
  env: Env,
  project: catalogue.Project,
  tree_workspace: workspaces.Workspace,
  trees: Worktrees,
  request: project_host.StartRequest,
) -> Result(String, String) {
  let name = tree_name(request.ticket, request.seq)
  use tree <- result.try(worktrees.open(trees, tree_workspace, name))
  let creation =
    manager.Creation(
      request_key: request.key,
      workspace: tree.path,
      name: request.title,
      configuration: "",
      profile: None,
      model: None,
      executor: "",
      pool: "",
    )
  use registration <- result.try(
    manager.reserve(
      env.registry,
      creation,
      directory: env.sessions,
      generator: env.generator(),
      scope: domain.WorkspacePrivate,
      configuration: env.domain_configuration,
    )
    |> result.map_error(fn(error) { string.inspect(error) }),
  )
  let worker =
    catalogue.ProjectWorker(
      session_id: registration.id,
      project: project.id,
      ticket: request.ticket,
      seq: request.seq,
    )
  use Nil <- result.try(bind(env, worker))
  use _opened <- result.map(
    manager.create_scoped(
      env.registry,
      creation,
      directory: env.sessions,
      generator: env.generator(),
      scope: domain.WorkspacePrivate,
      configuration: env.domain_configuration,
    )
    |> result.map_error(fn(error) { string.inspect(error) }),
  )
  registration.id
}

/// Closes an assignment's tree under the rule for a project worker: it goes
/// unless it holds changes or commits its base lacks. A kept tree is reported
/// with its path, which is derived the way `worktrees` derives it, so the board
/// can send a person to it.
fn release_tree(
  env: Env,
  tree_workspace: workspaces.Workspace,
  trees: Worktrees,
  request: project_host.ReleaseRequest,
) -> Result(project_host.Released, String) {
  let name = tree_name(request.ticket, request.seq)

  // A kept tree is reported with the path a person would look in.
  case worktrees.close_guarding_commits(trees, tree_workspace, name) {
    worktrees.Removed -> Ok(project_host.Removed)
    worktrees.Kept(reason:) ->
      Ok(project_host.Kept(
        path: worktrees.tree_path(env.state_root, tree_workspace.name, name),
        reason:,
      ))
  }
}

/// Binding is refused as a conflict when the session already has a standing, so
/// a repeat after a restart reads the standing and accepts it when it is this
/// very assignment.
fn bind(env: Env, worker: catalogue.ProjectWorker) -> Result(Nil, String) {
  let bound =
    in_catalogue(env, fn(store) { catalogue.bind_worker(store, worker) })

  // The first bind of a session succeeds. A refusal may be a repeat after a
  // restart, which the standing on record settles.
  case bound {
    Ok(Nil) -> Ok(Nil)
    Error(first) -> {
      let standing =
        in_catalogue(env, fn(store) {
          catalogue.project_standing(store, worker.session_id)
        })

      // Only a standing that is exactly this assignment excuses the refusal.
      // Any other standing, or an unreadable one, reports the original error.
      case standing {
        Ok(catalogue.WorkerOf(project:, ticket:, seq:))
          if project == worker.project
          && ticket == worker.ticket
          && seq == worker.seq
        -> Ok(Nil)
        Ok(_) | Error(_) -> Error(catalogue_text(first))
      }
    }
  }
}

/// The directory name of an assignment's tree: the ticket, a hyphen and the
/// assignment number. The ticket id is already a safe component.
///
/// ## Examples
///
/// ```gleam
/// assert project_start.tree_name("t-c1", 2) == "t-c1-2"
/// ```
pub fn tree_name(ticket: String, seq: Int) -> String {
  ticket <> "-" <> int.to_string(seq)
}

// --- boot --------------------------------------------------------------------

/// Starts every active project's actor, then opens its router and the
/// sessions of its live assignments, oldest first, until the registry's
/// capacity is spent. Only rows the owner wrote open sessions here: a model's
/// message still cannot.
///
/// ## Examples
///
/// ```gleam
/// // project_start.reopen(env)
/// ```
pub fn reopen(env: Env) -> Nil {
  case in_catalogue(env, catalogue.projects) {
    Error(error) ->
      log.warn(env.logger, "project.reopen_failed", [
        field.text(key: "reason", value: catalogue_text(error)),
      ])
    Ok(all) ->
      all
      |> list.filter(fn(each) { each.state == catalogue.ProjectActive })
      |> list.sort(fn(a, b) { int.compare(a.created_ms, b.created_ms) })
      |> list.each(reopen_one(env, _))
  }
}

/// Brings one project back. The router and each live worker are opened on a
/// best-effort basis: a session that cannot open stays closed, and the board
/// still shows its ticket.
fn reopen_one(env: Env, project: catalogue.Project) -> Nil {
  // A project whose actor will not start is logged and skipped, so one
  // damaged ledger does not stop the others from reopening.
  case ensure_running(env, project) {
    Error(reason) ->
      log.warn(env.logger, "project.start_failed", [
        field.ident(key: "project", value: project.id),
        field.text(key: "reason", value: reason),
      ])
    Ok(handle) -> {
      let _router = open_router(env, project)
      let live = result.unwrap(project_host.live_sessions(handle), [])
      list.each(live, fn(session) {
        let _opened = manager.open(env.registry, session)
        Nil
      })
    }
  }
}

// --- helpers -----------------------------------------------------------------

/// Runs a catalogue operation in the registry's own turn, because the
/// catalogue's connection belongs to the registry. A registry that does not
/// answer is an error of the operation.
fn in_catalogue(
  env: Env,
  run: fn(catalogue.Catalogue) -> Result(a, catalogue.Error),
) -> Result(a, catalogue.Error) {
  case manager.with_catalogue(env.registry, run) {
    Ok(answer) -> answer
    Error(_) ->
      Error(catalogue.Invalid("the session registry is not answering"))
  }
}

fn catalogue_text(error: catalogue.Error) -> String {
  string.inspect(error)
}

/// The standing of a session as `project_standing` reads it, with the
/// project's handle, for the session builder. An ordinary session answers
/// `Ok(None)`. A router or a worker whose project is not running is an error,
/// because building it without its tools would give it a registry it must not
/// have.
///
/// ## Examples
///
/// ```gleam
/// // project_start.seat(registry, book, session_id)
/// ```
pub fn seat(
  registry: manager.Manager(serve.Resident),
  book: Book,
  session: String,
) -> Result(Option(project_standing.Seat), String) {
  // The catalogue is read in the registry's own turn, and an unanswering
  // registry is a failure of the read, not an ordinary session.
  use found <- result.try(
    case
      manager.with_catalogue(registry, fn(store) {
        catalogue.project_standing(store, session)
      })
    {
      Ok(answer) -> answer |> result.map_error(catalogue_text)
      Error(_) -> Error("the session registry is not answering")
    },
  )

  let standing = project_standing.from_catalogue(found)

  // A session with no project is ordinary and gets no seat. One with a
  // project needs that project's handle to carry its tools.
  case project_standing.project_of(standing) {
    None -> Ok(None)
    Some(project) ->
      case project_book.get(book, project) {
        Ok(handle) ->
          Ok(
            Some(project_standing.Seat(
              standing:,
              seam: projectseam.seam(handle, session),
              feed: scan_feed(standing, handle, session),
            )),
          )
        Error(Nil) -> Error("project " <> project <> " is not running")
      }
  }
}

/// Only a worker has a log the project reads. A router's conversation is
/// with the project through its tools, and an ordinary session is not the
/// project's at all.
fn scan_feed(
  standing: project_standing.Standing,
  handle: project_host.Handle,
  session: String,
) -> Option(project_scan.Feed) {
  case standing {
    project_standing.Worker(..) -> Some(projectseam.feed(handle, session))
    project_standing.Router(..) | project_standing.Ordinary -> None
  }
}
