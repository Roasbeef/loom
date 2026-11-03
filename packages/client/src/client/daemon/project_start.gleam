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
//// 4. `start_worker` makes a worker session in a clone of the project's
////    checkout. The registration is reserved first and bound to its
////    assignment second, and only then opened, so the session's builder reads
////    its standing before it builds.
//// 5. `reopen` runs at boot. It starts each active project's actor, then
////    opens its router and the sessions of its live assignments.
////
//// ## Why a clone is named from the ticket
////
//// A session's id is minted when its registration is reserved, and its
//// workspace is part of that reservation, so the clone has to exist before the
//// id does. The clone is therefore named from the ticket and the assignment,
//// and its branch is `loom/<ticket>-<seq>`.
////
//// ## Why a worker never has the owner's repository
////
//// A worker's workspace is a clone made by the host under the state root, not
//// a linked worktree of the owner's checkout (`client/project_repo`). A linked
//// worktree's session policy would have to make the checkout's `.git`
//// writable, and a worker fed hostile text could plant a hook there that the
//// owner's next Git command runs. Everything the host decides afterwards, the
//// diff, the check and the push, reads the host repository, which no worker
//// can write. `seat` also refuses to build a worker session on a clone whose
//// `.git` is not a directory, because the session policy would otherwise
//// widen to the Git directory that file names.

import broker/policy
import client/daemon/manager
import client/daemon/project_book.{type Book}
import client/daemon/project_host
import client/goalcheck
import client/goalstate
import client/install
import client/internal/ffi_os
import client/peer_mail
import client/project_jail
import client/project_judge
import client/project_judge_session
import client/project_packs
import client/project_poller
import client/project_publish
import client/project_repo
import client/project_scan
import client/project_standing
import client/project_template
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
import project/model
import project/policy as project_policy
import storage/catalogue
import storage/domain
import telemetry/field
import telemetry/log.{type Logger}
import weft/poll

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
    /// What a project does with a worker's finished work: its check, its
    /// protected paths and whether it may publish. It comes from `[project]`
    /// and is the owner's alone.
    policy: project_host.Policy,
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
    /// The judge a live verdict of a project runs: how a scratch session of its
    /// router's prompt and model decides a trial, and what bounds the run. It
    /// is asked for only when a live verdict is, and answers a sentence when
    /// the router's model cannot be resolved.
    judge: fn(String) -> Result(project_judge.Judge, String),
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

/// The judge a live verdict of a project runs. It reads the router
/// registration's settings the way the router's own session would be opened
/// with them (`settings_of`, which the daemon supplies because only it holds
/// the session defaults), and builds a scratch session's ground from them. The
/// router is not opened or touched: its registration is only read.
///
/// ## Examples
///
/// ```gleam
/// // project_start.judge(env, settings_of, "p-0123456789ab")
/// ```
pub fn judge(
  env: Env,
  settings_of: fn(catalogue.Registration, domain.Domain) ->
    Result(serve.Settings, String),
  project: String,
) -> Result(project_judge.Judge, String) {
  use handle <- result.try(
    project_book.get(env.book, project)
    |> result.map_error(fn(_) { "project " <> project <> " is not running" }),
  )
  use view <- result.try(
    manager.get(env.registry, handle.router_session)
    |> result.map_error(fn(error) { string.inspect(error) }),
  )
  use selected <- result.try(
    manager.session_domain(env.registry, handle.router_session)
    |> result.map_error(fn(error) { string.inspect(error) }),
  )
  use settings <- result.try(settings_of(view.registration, selected))
  use ground <- result.map(project_judge_session.ground_of(settings))
  project_judge_session.judge_for(
    ground,
    project_judge.Limits(
      concurrency: project_judge.default_concurrency,
      wall_ms: project_judge.default_wall_ms,
    ),
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
  //
  // A new actor starts under the book's supervisor, never linked to this
  // caller: the caller is a control request's handler or the boot that reopens
  // projects, and either may end abnormally while the project goes on.
  case project_book.get(env.book, project.id) {
    Ok(running) -> Ok(running)
    Error(Nil) ->
      project_book.launch(
        env.book,
        project_host.Config(
          project: project.id,
          workspace: project.workspace,
          router_session: project.router_session,
          ledger_path: project.ledger_path,
          max_workers: env.max_workers,
          tick_ms: 2000,
          router_turn_ms: 120_000,
          policy: env.policy,
          ports: fn() { ports_for(env, project) },
        ),
      )
      |> result.map(fn(started) {
        pin_router(env, project, started)
        started
      })
  }
}

/// Tells a project's actor which router prompt and model it runs, so a verdict
/// can be pinned to them. A prompt revision is the digest of the router's pack.
/// The model is the one the router's registration names, by profile and model
/// key, because the model a `[roles]` chain resolves to is chosen when the
/// session opens and is not visible here. A change to that chain alone does not
/// move this pin, and the verdict's words say what it is pinned to.
fn pin_router(
  env: Env,
  project: catalogue.Project,
  started: project_host.Handle,
) -> Nil {
  let revision =
    crypto.hash(crypto.Sha256, bit_array.from_string(project_packs.router()))
    |> bit_array.base16_encode
    |> string.lowercase

  // A router the registry cannot name is pinned as unknown, which differs
  // from any named model, so a verdict never carries over to it.
  let router_model = case manager.get(env.registry, project.router_session) {
    Ok(found) ->
      "profile:"
      <> option.unwrap(found.registration.profile, "default")
      <> " model:"
      <> option.unwrap(found.registration.model, "default")
    Error(_) -> "unknown"
  }

  project_host.pin_router(started, "sha256:" <> revision, router_model)
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

  let layout =
    project_repo.Layout(
      state_root: env.state_root,
      project: project.id,
      owner: project.workspace,
    )

  // The sandboxed Git is started once, here, in the actor's own process, and
  // the host repository is made and its remote pinned on the same occasion. A
  // project whose host repository cannot be made has no ports that work.
  let trees =
    env.worktrees_for(tree_workspace)
    |> result.try(fn(found) {
      project_repo.ensure_host(found, layout) |> result.replace(found)
    })
  let seed = seed_of(env)
  project_host.Ports(
    now_ms: env.now_ms,
    start_session: fn(request) {
      use trees <- result.try(trees)
      start_worker(env, project, layout, trees, request, seed)
    },
    remember_mandate: fn(ticket, mandate) {
      project_book.remember(env.book, project.id, ticket, mandate)
    },
    open_session: fn(session) { open_and_wait(env.registry, session) },
    stop_session: fn(session) {
      manager.stop_session(env.registry, session)
      |> result.replace(Nil)
      |> result.map_error(fn(error) { string.inspect(error) })
    },
    release_worktree: fn(request) {
      use trees <- result.try(trees)
      release_tree(layout, trees, request)
    },
    endpoint_of: fn(session) {
      case manager.resolve(env.registry, session) {
        Ok(resident) -> Ok(resident.peer)
        Error(_) -> Error(peer_mail.NotOpen)
      }
    },
    observe_head: fn(request) {
      use trees <- result.try(trees)
      observe(layout, trees, request)
    },
    run_check: fn(request) {
      run_check_from(env.now_ms, layout, trees, seed, request)
    },
    build_template: fn(request) {
      case trees {
        Ok(found) -> project_template.build(found, layout, request)
        Error(reason) ->
          project_template.Failed(project_template.Failure(
            project_template.Cutting,
            reason,
          ))
      }
    },
    publish: fn(request) { published(layout, request) },
    gh_runner: fn() { project_poller.runner(project_publish.tools()) },
    remote_url: fn() { option.from_result(project_repo.pinned_url(layout)) },
    logger: env.logger,
  )
}

/// Where the project's trees get their files. A project with no `setup` has no
/// template and is cold, as it was before templates. One with it is warm: every
/// worker clone and check tree is a copy of the template, made with `git-cow`
/// when a binary is found and by a plain copy otherwise. Each copy logs which.
fn seed_of(env: Env) -> project_repo.Seed {
  case env.policy.setup {
    None -> project_repo.Cold
    Some(_) ->
      project_repo.Warm(
        project_repo.Copier(
          program: option.from_result(install.git_cow()),
          report: fn(method, elapsed_ms) {
            report_copy(env.logger, method, elapsed_ms)
          },
        ),
      )
  }
}

/// Logs how a template was copied, so an operator can see whether `git-cow`
/// ran or the plain copy stood in for it, and why.
fn report_copy(
  logger: Logger,
  method: project_repo.Method,
  elapsed_ms: Int,
) -> Nil {
  case method {
    project_repo.CopyOnWrite(program:) ->
      log.info(logger, "project.template_copied", [
        field.ident(key: "method", value: "git-cow"),
        field.text(key: "program", value: program),
        field.count(key: "elapsed_ms", value: elapsed_ms),
      ])
    project_repo.PlainCopy(why:) ->
      log.info(logger, "project.template_copied", [
        field.ident(key: "method", value: "plain"),
        field.text(key: "why", value: why),
        field.count(key: "elapsed_ms", value: elapsed_ms),
      ])
  }
}

/// How long an open may take to settle before its caller stops waiting, in
/// milliseconds. A session that is slow to build is still opening afterwards,
/// and the caller's next attempt finds it.
const open_wait_ms = 5000

/// Opens a saved session and waits until the open settles. The registry's open
/// answers when it has accepted the request, and a build that fails afterwards,
/// such as one that finds the session file's writer lease still held, is told
/// only to whoever asks about that operation. Waiting here is what turns the
/// registry's account of the failure into the error of the open, so the
/// caller's retry has a reason to log, and a worker that never opens can be
/// failed with it. A session that is already resident settles at once.
///
/// ## Examples
///
/// ```gleam
/// // project_start.open_and_wait(registry, session)
/// ```
pub fn open_and_wait(
  registry: manager.Manager(serve.Resident),
  session: String,
) -> Result(Nil, String) {
  case manager.open(registry, session) {
    Error(error) -> Error(string.inspect(error))
    Ok(manager.Resident(_)) -> Ok(Nil)
    Ok(manager.Opening(operation)) -> settled(registry, session, operation)
    Ok(other) -> Error("the session did not open: " <> string.inspect(other))
  }
}

/// Polls one opening operation until it is resident or its build has failed.
fn settled(
  registry: manager.Manager(serve.Resident),
  session: String,
  operation: String,
) -> Result(Nil, String) {
  let waited =
    poll.until(within: open_wait_ms, every: 25, attempt: fn() {
      case manager.operation(registry, session, operation) {
        Ok(manager.View(status: manager.Resident(_), ..)) -> poll.Done(Nil)
        Ok(manager.View(status: manager.Opening(_), ..)) -> poll.Retry

        // The registry keeps the words a refused build ended with, and an
        // operation it no longer holds ended some other way.
        Error(manager.StartFailed(reason)) -> poll.Fail(reason)
        Error(error) -> poll.Fail(string.inspect(error))
        Ok(manager.View(status: other, ..)) ->
          poll.Fail("the session did not open: " <> string.inspect(other))
      }
    })

  // A wait that ran out is not a refusal, and says so, since the session may
  // be resident by the caller's next attempt.
  case waited {
    poll.Answered(Nil) -> Ok(Nil)
    poll.Failed(reason) -> Error(reason)
    poll.Expired -> Error("the session was still opening after the wait")
  }
}

// --- finishing work ----------------------------------------------------------

/// Takes the head of an assignment's clone into the project's host repository
/// and reads the paths its branch changed there (`project_repo.intake`). The
/// clone is the worker's, so every Git command reads it in the sandbox, and the
/// diff, the check and the push all come from the host repository afterwards.
/// A commit the host repository refuses is `NotTaken`, and the engine sends
/// the ticket to a person.
///
/// ## Examples
///
/// ```gleam
/// // project_start.observe(layout, trees, request)
/// ```
pub fn observe(
  layout: project_repo.Layout,
  trees: Worktrees,
  request: project_host.ObserveRequest,
) -> Result(project_host.Intake, String) {
  use taken <- result.map(project_repo.intake(
    trees,
    layout,
    request.ticket,
    tree_name(request.ticket, request.seq),
  ))

  // The repository module's answer becomes the actor's, one for one.
  case taken {
    project_repo.Accepted(commit:, changed:) ->
      project_host.Taken(project_host.Observed(commit:, changed:))
    project_repo.Withheld(commit:, reason:) ->
      project_host.Withheld(commit:, reason: case reason {
        project_repo.NoCommits -> model.NoCommits
        project_repo.UncommittedChanges -> model.UncommittedChanges
      })
    project_repo.Declined(commit:, why:) -> project_host.NotTaken(commit:, why:)
  }
}

/// Runs the project's check at a commit. The tree is cut fresh from the host
/// repository at the commit, named from the ticket and the commit so a repeat
/// replaces it, and removed afterwards whatever the check left in it. The
/// command runs through `client/goalcheck` over the checking Git's broker: a
/// process with its own helper and its own policy, reached by nothing the
/// worker holds. The wall is the project's, and the output is the tail
/// `goalcheck` keeps.
///
/// A check that could not be started is `DidNotFinish` with the reason, which
/// the host reads as no verdict on the work.
///
/// ## Examples
///
/// ```gleam
/// // project_start.run_check(clock, layout, trees, request)
/// ```
pub fn run_check(
  now_ms: fn() -> Int,
  layout: project_repo.Layout,
  trees: Result(Worktrees, String),
  request: project_host.CheckRequest,
) -> goalstate.CheckResult {
  run_check_from(now_ms, layout, trees, project_repo.Cold, request)
}

/// Runs the project's check like `run_check`, in a tree cut from the seed
/// given. A warm seed makes the tree a copy of the template moved to the
/// commit, so the offline check finds the dependencies `setup` fetched.
///
/// ## Examples
///
/// ```gleam
/// // project_start.run_check_from(clock, layout, trees, project_repo.Cold, request)
/// ```
pub fn run_check_from(
  now_ms: fn() -> Int,
  layout: project_repo.Layout,
  trees: Result(Worktrees, String),
  seed: project_repo.Seed,
  request: project_host.CheckRequest,
) -> goalstate.CheckResult {
  let unfinished = fn(reason) {
    goalstate.CheckResult(
      command: request.command,
      ending: goalstate.DidNotFinish(reason:),
      output: "",
      ran_at_ms: now_ms(),
    )
  }

  // The commit comes from Git's own answer, and is checked once more before it
  // becomes part of a command line.
  case trees, project_repo.commit_name(request.commit) {
    Error(reason), _ | _, Error(reason) -> unfinished(reason)
    Ok(trees), Ok(Nil) ->
      // Without a tree there is nothing to check; with one, the tree goes
      // whatever the check does.
      case
        project_repo.check_tree_from(
          trees,
          layout,
          request.ticket,
          request.commit,
          seed,
        )
      {
        Error(reason) -> unfinished("the check's tree was not made: " <> reason)
        Ok(path) -> {
          // A runner that cannot be built is a check that never started.
          let outcome = case worktrees.check_runner(trees, path) {
            Error(reason) -> unfinished(reason)
            Ok(runner) ->
              { goalcheck.wiring(runner, timeout_ms: request.wall_ms) }.run(
                request.command,
              )
          }

          let _removed =
            project_repo.force_remove(
              trees,
              project_repo.checks_path(layout),
              path,
            )
          outcome
        }
      }
  }
}

/// Pushes a verified commit and opens its pull request, with the daemon's own
/// credentials. The push is from the host repository to the URL pinned when
/// the project was created. The title and body arrive built, and the commit is
/// checked once more before it becomes part of a command line.
fn published(
  layout: project_repo.Layout,
  request: project_host.PublishRequest,
) -> project_host.Published {
  case
    project_repo.commit_name(request.commit),
    project_repo.pinned_url(layout)
  {
    Error(reason), _ -> project_host.Unavailable(reason)
    Ok(Nil), Error(Nil) ->
      project_host.Unavailable(
        "the owner's checkout had no usable origin remote when the project was created",
      )
    Ok(Nil), Ok(url) ->
      case
        project_publish.publish(
          project_publish.tools(),
          project_publish.Repository(
            directory: project_repo.host_path(layout),
            url:,
          ),
          request.branch,
          request.commit,
          request.title,
          request.body,
        )
      {
        Ok(url) -> project_host.Opened(url)
        Error(project_publish.Unavailable(why)) -> project_host.Unavailable(why)
        Error(project_publish.Failed(why)) -> project_host.PublishFailed(why)
      }
  }
}

/// A worker session in a clone of the project's checkout. Cloning twice adopts
/// the clone, reserving twice finds the registration, binding twice is refused
/// as a conflict that is accepted when the standing already is this assignment,
/// and creating twice finds the session. A restart anywhere in the sequence
/// therefore ends with one session and one clone.
fn start_worker(
  env: Env,
  project: catalogue.Project,
  layout: project_repo.Layout,
  trees: Worktrees,
  request: project_host.StartRequest,
  seed: project_repo.Seed,
) -> Result(String, String) {
  use clone <- result.try(worker_clone_from(trees, layout, request, seed))
  let creation =
    manager.Creation(
      request_key: request.key,
      workspace: clone,
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

/// Makes the clone an assignment's worker works in, or adopts the one an
/// earlier start made. A ticket with a recorded head begins where its earlier
/// assignment left off, and one without begins at the owner's checkout. The
/// recorded head is a commit the host repository took in before the ticket
/// recorded it, which is why `project_repo.clone` reads it from there. A
/// ticket resumed after a merge or a close, and a retry after a crash or a
/// failed start, are both such tickets.
///
/// ## Examples
///
/// ```gleam
/// // project_start.worker_clone(trees, layout, request)
/// ```
pub fn worker_clone(
  trees: Worktrees,
  layout: project_repo.Layout,
  request: project_host.StartRequest,
) -> Result(String, String) {
  worker_clone_from(trees, layout, request, project_repo.Cold)
}

/// Makes the clone like `worker_clone`, from the seed given.
///
/// ## Examples
///
/// ```gleam
/// // project_start.worker_clone_from(trees, layout, request, project_repo.Cold)
/// ```
pub fn worker_clone_from(
  trees: Worktrees,
  layout: project_repo.Layout,
  request: project_host.StartRequest,
  seed: project_repo.Seed,
) -> Result(String, String) {
  // A recorded head is a commit the host repository holds. No head means the
  // ticket has produced nothing, and the owner's checkout is the right start.
  let start = case request.head {
    Some(commit) -> project_repo.FromCommit(commit)
    None -> project_repo.FromOwner
  }

  project_repo.clone_from(
    trees,
    layout,
    tree_name(request.ticket, request.seq),
    start,
    seed,
  )
}

/// Closes an assignment's clone under the rule for a project worker: it goes
/// unless it holds changes, or any ref naming an object the host repository
/// lacks (`project_repo.release`). A kept clone is reported with its path, so
/// the board can send a person to it. The person should fetch from the ticket's
/// refs in the host repository and treat the clone itself as untrusted.
fn release_tree(
  layout: project_repo.Layout,
  trees: Worktrees,
  request: project_host.ReleaseRequest,
) -> Result(project_host.Released, String) {
  let name = tree_name(request.ticket, request.seq)

  // A kept clone is reported with the path a person would look in.
  case project_repo.release(trees, layout, name) {
    worktrees.Removed -> Ok(project_host.Removed)
    worktrees.Kept(reason:) ->
      Ok(project_host.Kept(path: project_repo.clone_path(layout, name), reason:))
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
/// The registry's end bell is installed first, so a worker session that ends
/// while the projects come back is reported to its project. The bell only casts
/// to the project table, because it rings inside the registry's own turn, and
/// the registry rings nothing while the daemon shuts down.
///
/// ## Examples
///
/// ```gleam
/// // project_start.reopen(env)
/// ```
pub fn reopen(env: Env) -> Nil {
  manager.on_session_ended(env.registry, fn(session, why) {
    project_book.session_ended(env.book, session, why)
  })

  // A catalogue that cannot be read leaves every project as it was and says so.
  // Otherwise each active project comes back, oldest first.
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
      list.each(live, fn(session) { reopen_worker(env, handle, session) })
    }
  }
}

/// Opens one live worker's session at boot. A session that cannot be opened
/// stays closed, and the board still shows its ticket, except when the registry
/// has no registration for it at all. A worker the ledger calls live whose
/// session was deleted while the daemon was down will never run again, and no
/// bell rings for a session that was not resident, so the project is told here,
/// with the same call the registry's end bell makes. Any other refusal may pass,
/// such as a busy registry or an archived session, and is left to the board.
fn reopen_worker(
  env: Env,
  handle: project_host.Handle,
  session: String,
) -> Nil {
  case manager.open(env.registry, session) {
    Error(manager.Catalogue(catalogue.Missing)) ->
      project_host.session_gone(handle, session, "the session no longer exists")
    Ok(_) | Error(_) -> Nil
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
  owner: policy.SandboxPolicy,
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
    Some(project) -> {
      use Nil <- result.try(sound_workspace(registry, standing, session))

      // The project's handle is what carries the session's tools.
      case project_book.get(book, project) {
        Ok(handle) -> {
          use jail <- result.map(jail_of(book, standing, owner))
          Some(project_standing.Seat(
            standing:,
            seam: projectseam.seam(handle, session),
            feed: scan_feed(standing, handle, session),
            run_ended: router_signal(standing, handle),
            workspace: handle.workspace,
            jail:,
          ))
        }
        Error(Nil) -> Error("project " <> project <> " is not running")
      }
    }
  }
}

/// A worker's jail, derived from the Mandate its ticket holds. The project's
/// actor told the book that Mandate from its ledger, and the jail is derived on
/// every build of the session and never read back from what the session stored,
/// so a boot reopen, a resume and a retry all get the policy the ledger's
/// Mandate gives. A ticket the book has no Mandate for is an error and no
/// session is built: a worker with no Mandate has no policy to run under.
fn jail_of(
  book: Book,
  standing: project_standing.Standing,
  owner: policy.SandboxPolicy,
) -> Result(Option(project_jail.Jail), String) {
  case standing {
    project_standing.Worker(project:, ticket:, ..) ->
      project_book.recall(book, project, ticket)
      |> result.map_error(fn(_) {
        "project " <> project <> " has no mandate for ticket " <> ticket
      })
      |> result.map(fn(mandate) {
        Some(project_jail.jail_for(project_policy.for_mandate(mandate), owner))
      })
    project_standing.Router(..) | project_standing.Ordinary -> Ok(None)
  }
}

/// A worker's clone must have a real `.git` directory when its session is
/// built. The session policy widens its writable roots to the Git directory a
/// `.git` file names (`workspace_policy.widening_linked_worktree`), and the
/// worker's jail can write its own workspace, so a worker that replaced the
/// directory with such a file would be given the owner's repository at its next
/// start. Refusing to build the session closes that door without a second
/// policy rule for ordinary sessions. Routers and ordinary sessions are not
/// the host's clones and are not examined.
fn sound_workspace(
  registry: manager.Manager(serve.Resident),
  standing: project_standing.Standing,
  session: String,
) -> Result(Nil, String) {
  // Only a worker's workspace is a clone the host made.
  case standing {
    project_standing.Worker(..) -> {
      use view <- result.try(
        manager.get(registry, session)
        |> result.map_error(fn(error) { string.inspect(error) }),
      )
      project_repo.sound_clone(view.registration.workspace)
    }
    project_standing.Router(..) | project_standing.Ordinary -> Ok(Nil)
  }
}

/// What a router's run end tells its project, stamped with the time it
/// happened so that the project can tell the end of the run that answered its
/// current batch from the late end of an earlier one.
fn router_signal(
  standing: project_standing.Standing,
  handle: project_host.Handle,
) -> Option(fn() -> Nil) {
  case standing {
    project_standing.Router(..) ->
      Some(fn() {
        project_host.router_run_ended(handle, ffi_os.system_time_ms())
      })
    project_standing.Worker(..) | project_standing.Ordinary -> None
  }
}

/// The sessions among `ids` that belong to a project, with what each is to it,
/// read in one registry turn. A session that belongs to none is left out, as is
/// every session when the registry does not answer: a listing that cannot say
/// is shown whole, and never hides what it could not check.
///
/// ## Examples
///
/// ```gleam
/// // project_start.standings(registry, ["0198..."])
/// //   == [#("0198...", project_standing.Router("p-1"))]
/// ```
pub fn standings(
  registry: manager.Manager(instance),
  ids: List(String),
) -> List(#(String, project_standing.Standing)) {
  let read = fn(store) {
    list.filter_map(ids, fn(id) {
      case catalogue.project_standing(store, id) {
        Ok(found) ->
          case project_standing.from_catalogue(found) {
            project_standing.Ordinary -> Error(Nil)
            held -> Ok(#(id, held))
          }
        Error(_) -> Error(Nil)
      }
    })
  }

  // An unanswering registry reports nothing, which hides nothing.
  case manager.with_catalogue(registry, read) {
    Ok(found) -> found
    Error(_) -> []
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
