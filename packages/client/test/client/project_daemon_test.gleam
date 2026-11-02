//// Project mode end to end, through a real daemon root: real sessions
//// assembled by `client/serve`, a real catalogue, a real project ledger, real
//// Git worktrees under the sandbox helper, and the control commands over a
//// real socket. Only the model is scripted.
////
//// The script stands in for the three kinds of conversation. The router, asked
//// about a candidate, routes it. A worker for the first ticket reports that it
//// is waiting with a question. A worker for the second first calls a tool it
//// was never given, and then reports progress. Nothing else is faked: a claim
//// about which tools a model was offered is made on the tools the request
//// advertised, and a claim about the worktrees is made with Git.
////
//// The scenario is one test on purpose. Booting a daemon with sessions costs
//// seconds, and the interesting facts are about one run's state surviving a
//// restart: the board before and after, the sessions that did not multiply, and
//// the recovery note that reached each worker.

import client/catalog
import client/daemon/domain as domain_service
import client/daemon/limits
import client/daemon/main
import client/daemon/manager
import client/daemon/project_book
import client/daemon/project_host
import client/daemon/project_start
import client/daemon/root
import client/daemon/server
import client/daemon/session_socket
import client/daemon_server_test as wire
import client/deployment
import client/history
import client/internal/ffi_os
import client/internal/instance_owner as custody
import client/internal/shared_history
import client/owned_assembly_test
import client/peer_mail
import client/project_records
import client/project_repo
import client/project_standing
import client/roster
import client/serve
import client/session_directory
import client/session_movers
import client/workspace_policy
import client/worktrees
import core/clock
import core/ids
import core/json.{type JsonValue}
import filepath
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import machine/strand
import mist
import project/event
import project/model as project_model
import provider/http
import provider/model
import provider/secret
import simplifile
import sqlight
import storage/catalogue
import storage/domain as storage_domain
import storage/exec_ledger
import storage/project_ledger
import support/internal/ffi_ws
import support/project_rig
import support/provider as provider_test
import support/worktree_rig
import telemetry/log
import tools/project as tools
import weft/poll

const router_model = "router-1"

const worker_model = "worker-1"

/// What the scripted model saw or was asked, in the order it happened.
type Seen {
  /// A request to a model, with the names of the tools it advertised.
  Advertised(model: String, tools: List(String))

  /// The result a worker was handed back for a tool it was not given.
  Refused(result: String)

  /// A worker was handed the harness's recovery note.
  Recovered(ticket: String)
}

type Daemon {
  Daemon(
    root: root.Root(serve.Resident),
    ready: root.Ready(serve.Resident),
    book: project_book.Book,
    env: project_start.Env,
    port: Int,
    credential: String,
    listener: process.Pid,
  )
}

pub fn a_project_runs_two_tickets_and_survives_a_restart_test() {
  // Every worker's worktree is made by the sandbox helper. Without the built
  // binary no worker ever starts, the board stays at its first state, and the
  // run ends as a timeout in `await_tickets` that says nothing about the
  // helper. Naming the missing file here turns that into an immediate failure.
  let helper = here() <> "/../sandbox/loom-exec"
  let assert Ok(True) = simplifile.is_file(helper)
    as "packages/sandbox/loom-exec is missing: run make sandbox"

  process.trap_exits(True)
  let scratch = scratch("project-daemon")
  let repository = worktree_rig.repository(scratch <> "/repo")
  let owners = project_rig.digest(repository)
  let seen = process.new_subject()
  let daemon = boot(scratch <> "/state", seen)

  // Create the project and post twice, each command on a connection of its own.
  // The project's actor must outlive the connection that created it.
  let created =
    command(daemon, "projects.create", [
      #("workspace", json.String(repository)),
      #("name", json.String("repo")),
    ])
  let project = text_of(created, "project")
  let router = text_of(created, "router_session")
  let _ = post(daemon, project, "a", "fix a")
  let _ = post(daemon, project, "b", "fix b")

  // The router routes both, two workers start, and the scripted workers report.
  let before =
    await_tickets(daemon, project, fn(tickets) {
      stage_of(tickets, "fix a") == "person/answer"
      && stage_of(tickets, "fix b") == "working"
    })
  assert ticket_titles(before) == ["fix a", "fix b"]

  // The workers are in clones of their own under the daemon's state root, on
  // different branches, and neither is a worktree of the owner's repository:
  // Git lists none, each has a real `.git` directory, and the owner's
  // configuration, hooks and refs are what they were.
  let sessions = ticket_sessions(before)
  let assert [first, second] = sessions
  let first_tree = workspace_of(daemon, first)
  let second_tree = workspace_of(daemon, second)
  assert first_tree != second_tree
  let tickets = daemon.ready.state_root <> "/projects/" <> project <> "/tickets"
  assert first_tree == tickets <> "/t-a-1"
  assert second_tree == tickets <> "/t-b-1"
  assert !string.contains(
    worktree_rig.git(repository, ["worktree", "list"]),
    "t-a-1",
  )
  assert project_repo.sound_clone(first_tree) == Ok(Nil)
  assert project_repo.sound_clone(second_tree) == Ok(Nil)
  assert worktree_rig.git(first_tree, ["rev-parse", "--abbrev-ref", "HEAD"])
    == "loom/t-a-1"
  assert worktree_rig.git(second_tree, ["rev-parse", "--abbrev-ref", "HEAD"])
    == "loom/t-b-1"
  assert project_rig.moved(owners, project_rig.digest(repository)) == ""

  // The router offers exactly its three tools, and a worker was never given
  // them. The worker that tried to route was told so.
  let evidence = drain(seen)
  assert advertised(evidence, router_model)
    == [["project_read", "reply", "route"]]
  let offered = advertised(evidence, worker_model)
  assert offered != []
  assert list.all(offered, fn(names) {
    list.contains(names, "project_report")
    && list.contains(names, "project_handback")
    && !list.contains(names, "route")
    && !list.contains(names, "project_read")
    && !list.contains(names, "reply")
  })
  let assert [refusal] = refusals(evidence)
  assert string.contains(refusal, "\"is_error\":true")

  // The router cannot be given `bash` or `code_mode` by `set_config`.
  refuses_tools(daemon, router, ["bash"])
  refuses_tools(daemon, router, ["code_mode"])

  // The router and the workers say what they are to the project, so a list
  // can leave them out, and a session that belongs to none says nothing. The
  // workers' clones are no folder to start a session in again.
  let held =
    project_start.standings(daemon.ready.registry, [router, first, second])
  assert list.length(held) == 3
  assert list.key_find(held, router) == Ok(project_standing.Router(project))
  assert list.key_find(held, first)
    == Ok(project_standing.Worker(project, "t-a", 1))
  assert project_start.standings(daemon.ready.registry, ["no-such-session"])
    == []
  assert project_repo.is_clone_path(first_tree)

  // Stop the daemon. While it is down, a trigger the gate did not admit as
  // explicit arrives in the ledger, as a source would deliver it.
  let ledger = ledger_path(daemon, project)
  stop(daemon)
  deliver_unadmitted(ledger)

  // The restarted daemon holds every session saved, and a peer message to one
  // is refused as not open: the peer path never opens a project session.
  let restarted = boot(scratch <> "/state", seen)
  let peers =
    main.peer_directory(restarted.ready.registry, fn(resident: serve.Resident) {
      resident.peer
    })
  assert peers.resolve(first) == Error(peer_mail.NotOpen)
  assert peers.resolve(router) == Error(peer_mail.NotOpen)

  // Reopening is the owner's act. The board is what it was, no third worker
  // exists, and each running worker was told that the harness restarted.
  project_start.reopen(restarted.env)
  let after =
    await_tickets(restarted, project, fn(tickets) { tickets == before })
  assert after == before
  assert session_count(restarted) == 3
  let told = recovered(seen, [])
  assert list.sort(told, string.compare) == ["t-a", "t-b"]

  // The router cannot accept what the gate never admitted.
  let assert Ok(handle) = project_book.get(restarted.book, project)
  let assert Ok([tools.Declined(_)]) =
    project_host.route(handle, [
      tools.Item(
        trigger: project_model.TriggerId("inferred-1"),
        action: tools.Accept(project_model.title("take it")),
        holds: [],
        related: [],
        prior_hand_back: None,
      ),
    ])

  // A worker's session stopped from outside the project, with no report, is a
  // lost worker. The registry's end bell tells the project, and the ticket
  // reads failed while the other ticket is untouched.
  let assert Ok(_) = manager.stop_session(restarted.ready.registry, second)
  let lost =
    await_tickets(restarted, project, fn(tickets) {
      stage_of(tickets, "fix b") == "person/failed"
    })
  assert stage_of(lost, "fix a") == "person/answer"
  stop(restarted)

  // The daemon stopping its own sessions loses none of them. The third boot
  // finds the first ticket where it was, and the second still failed: the
  // shutdown of the daemon with the bell installed recorded no loss.
  let third = boot(scratch <> "/state", seen)
  project_start.reopen(third.env)
  let settled =
    await_tickets(third, project, fn(tickets) {
      stage_of(tickets, "fix b") == "person/failed"
      && stage_of(tickets, "fix a") == "person/answer"
    })
  assert ticket_titles(settled) == ["fix a", "fix b"]
  stop(third)
  assert project_rig.moved(owners, project_rig.digest(repository)) == ""
  process.trap_exits(False)
}

// A daemon killed with `kill -9` runs no release, so every session file it held
// keeps a writer lease until it expires, and a daemon restarted inside that
// window cannot open the sessions. The project must wait the lease out without
// a person: the workers come back and are told, the router comes back, nothing
// is made twice, and no ticket reads failed on the way. A lease that has not
// expired still refuses a second writer.
pub fn a_killed_daemons_lease_delays_the_reopen_without_failing_a_worker_test() {
  let helper = here() <> "/../sandbox/loom-exec"
  let assert Ok(True) = simplifile.is_file(helper)
    as "packages/sandbox/loom-exec is missing: run make sandbox"

  process.trap_exits(True)
  let scratch = scratch("project-lease")
  let repository = worktree_rig.repository(scratch <> "/repo")
  let seen = process.new_subject()
  let daemon = boot(scratch <> "/state", seen)
  let created =
    command(daemon, "projects.create", [
      #("workspace", json.String(repository)),
      #("name", json.String("repo")),
    ])
  let project = text_of(created, "project")
  let router = text_of(created, "router_session")
  let _ = post(daemon, project, "a", "fix a")
  let _ = post(daemon, project, "b", "fix b")
  let before =
    await_tickets(daemon, project, fn(tickets) {
      stage_of(tickets, "fix a") == "person/answer"
      && stage_of(tickets, "fix b") == "working"
    })
  let assert [first, second] = ticket_sessions(before)
  let held = [router, first, second]
  let files = list.map(held, session_file(daemon, _))
  let _ = drain(seen)
  stop(daemon)

  // The previous daemon is gone and its leases are not. They run out six
  // seconds from now.
  list.each(files, plant_lease(_, ffi_os.system_time_ms() + 6000))
  let restarted = boot(scratch <> "/state", seen)
  project_start.reopen(restarted.env)

  // The leases are real: neither worker is resident yet.
  assert !is_resident(session_status(restarted, first))
  assert !is_resident(session_status(restarted, second))

  // Nobody tells the project anything. Once the leases run out the workers are
  // reopened and told that the harness restarted, and the router is open again.
  // The board never shows a ticket as failed while it waits.
  let told = watch_recovery(restarted, project, seen, [], 120)
  assert list.sort(told, string.compare) == ["t-a", "t-b"]
  let after = tickets_of(restarted, project)
  assert ticket_titles(after) == ["fix a", "fix b"]
  assert ticket_sessions(after) == [first, second]
  assert session_count(restarted) == 3
  assert poll.until(within: 20_000, every: 100, attempt: fn() {
      case session_status(restarted, router) {
        manager.Resident(_) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    == poll.Answered(Nil)
  stop(restarted)

  // A lease that has not run out still refuses a writer, and the project does
  // not call the worker lost for it. When the other writer lets go, it opens.
  let assert [_, first_file, _] = files
  plant_lease(first_file, ffi_os.system_time_ms() + 600_000)
  let third = boot(scratch <> "/state", seen)
  project_start.reopen(third.env)

  // A refused open is the end of an attempt and not of a session, so the
  // registry's end bell stays quiet for it. The bell here records what it is
  // told, in place of the project's.
  let rings = process.new_subject()
  manager.on_session_ended(third.ready.registry, fn(session, why) {
    process.send(rings, #(session, why))
  })
  let assert Error(refusal) =
    project_start.open_and_wait(third.ready.registry, first)
  assert string.contains(refusal, "another writer holds this session's lease")
  process.sleep(3000)
  assert !is_resident(session_status(third, first))
  assert process.receive(rings, 0) == Error(Nil)
  assert stage_of(tickets_of(third, project), "fix a") == "person/answer"

  // Once the other writer lets go the session opens, and stopping a session
  // that ran does ring.
  clear_lease(first_file)
  assert project_start.open_and_wait(third.ready.registry, first) == Ok(Nil)
  let assert Ok(_) = manager.stop_session(third.ready.registry, first)
  assert process.receive(rings, 10_000)
    == Ok(#(first, "the session was stopped"))
  stop(third)
  process.trap_exits(False)
}

// A graceful stop reaches the registry while the project actors are still
// alive, as it does in a real process, and a client may be attached to a worker
// when it does. The existing restart test kills the actors first, so a bell
// rung during the stop reached no one. Here it can reach them, and the test says
// whether any ticket reads failed on the other side.
pub fn a_graceful_stop_with_a_client_attached_fails_no_worker_test() {
  let helper = here() <> "/../sandbox/loom-exec"
  let assert Ok(True) = simplifile.is_file(helper)
    as "packages/sandbox/loom-exec is missing: run make sandbox"

  process.trap_exits(True)
  let scratch = scratch("project-graceful")
  let repository = worktree_rig.repository(scratch <> "/repo")
  let seen = process.new_subject()
  let daemon = boot(scratch <> "/state", seen)
  let created =
    command(daemon, "projects.create", [
      #("workspace", json.String(repository)),
      #("name", json.String("repo")),
    ])
  let project = text_of(created, "project")
  let _ = post(daemon, project, "a", "fix a")
  let _ = post(daemon, project, "b", "fix b")
  let before =
    await_tickets(daemon, project, fn(tickets) {
      stage_of(tickets, "fix a") == "person/answer"
      && stage_of(tickets, "fix b") == "working"
    })
  let assert [first, second] = ticket_sessions(before)

  // A terminal is attached to each worker, as `loom` attaches to a session.
  let #(socket_a, _) =
    wire.connect(
      daemon.port,
      daemon.credential,
      "/v2/sessions/" <> first <> "/ws",
    )
  let _ = wire.subscribe(socket_a, 1, first, within_ms: 10_000)
  let #(socket_b, _) =
    wire.connect(
      daemon.port,
      daemon.credential,
      "/v2/sessions/" <> second <> "/ws",
    )
  let _ = wire.subscribe(socket_b, 1, second, within_ms: 10_000)

  // The daemon stops with its project actors alive and its terminals attached.
  assert root.shutdown(daemon.root, within: 20_000) == Ok(Nil)
  let ledger = ledger_path(daemon, project)
  list.each(project_book.all(daemon.env.book), fn(handle) {
    case process.subject_owner(handle.commands) {
      Ok(pid) -> {
        process.unlink(pid)
        process.kill(pid)
      }
      Error(Nil) -> Nil
    }
  })
  process.kill(daemon.listener)
  let _ = ffi_ws.tcp_close(socket_a)
  let _ = ffi_ws.tcp_close(socket_b)
  process.sleep(200)

  // Nothing was recorded as lost, and the next daemon finds both tickets as
  // they were.
  let assert Ok(opened) = project_ledger.open(ledger)
  let assert Ok(lines) = project_ledger.replay(opened, 0, 500)
  let assert Ok(Nil) = project_ledger.close(opened)
  let recorded = string.inspect(lines)
  assert string.contains(recorded, "session_bound")
    as "the ledger holds the assignments"
  assert !string.contains(recorded, "worker_failed")
  process.trap_exits(False)
}

// Follows the board until every worker has been told of the restart, and fails
// the moment a ticket reads failed. A worker's note arrives when its session
// opens and the worker answers, so this waits on the scripted model's record.
fn watch_recovery(
  daemon: Daemon,
  project: String,
  seen: Subject(Seen),
  found: List(String),
  turns: Int,
) -> List(String) {
  let failed =
    list.filter(tickets_of(daemon, project), fn(each) {
      text_of(each, "stage") == "person/failed"
    })
  assert failed == [] as "no ticket reads failed while the lease runs out"

  case list.length(list.unique(found)) >= 2 || turns == 0 {
    True -> list.unique(found)
    False ->
      case process.receive(seen, 250) {
        Ok(Recovered(ticket)) ->
          watch_recovery(daemon, project, seen, [ticket, ..found], turns - 1)
        Ok(Advertised(..)) | Ok(Refused(_)) | Error(Nil) ->
          watch_recovery(daemon, project, seen, found, turns - 1)
      }
  }
}

fn session_file(daemon: Daemon, session: String) -> String {
  let assert Ok(manager.View(registration, _)) =
    manager.get(daemon.ready.registry, session)
    as "the session is registered"
  registration.path
}

fn is_resident(status: manager.Status) -> Bool {
  case status {
    manager.Resident(_) -> True
    manager.Reserved
    | manager.FailedStart(..)
    | manager.Saved
    | manager.Opening(_)
    | manager.Stopping(_)
    | manager.RecoveryBlocked(_) -> False
  }
}

fn session_status(daemon: Daemon, session: String) -> manager.Status {
  let assert Ok(manager.View(_, status)) =
    manager.get(daemon.ready.registry, session)
    as "the session is registered"
  status
}

// Leaves a writer lease in a session file as a daemon that was killed leaves
// it: held by an owner that no longer exists, until `expires_ms`.
fn plant_lease(path: String, expires_ms: Int) -> Nil {
  let assert Ok(connection) = sqlight.open(path) as "the session file opens"
  let assert Ok(Nil) =
    sqlight.exec(
      "DELETE FROM writer_lease; INSERT INTO writer_lease(owner_id, fence, expires_at_ms) VALUES ('loomd-killed', 1, "
        <> int.to_string(expires_ms)
        <> ")",
      on: connection,
    )
    as "the stale lease is written"
  let assert Ok(Nil) = sqlight.close(connection)
  Nil
}

fn clear_lease(path: String) -> Nil {
  let assert Ok(connection) = sqlight.open(path) as "the session file opens"
  let assert Ok(Nil) = sqlight.exec("DELETE FROM writer_lease", on: connection)
    as "the lease is released"
  let assert Ok(Nil) = sqlight.close(connection)
  Nil
}

// --- the daemon ---------------------------------------------------------------

fn boot(state: String, seen: Subject(Seen)) -> Daemon {
  let assert Ok(Nil) = simplifile.create_directory_all(state)
    as "the daemon's state directory exists"
  let assert Ok(book) = project_book.start() as "the project table starts"
  let settings = settings(seen)
  let assert Ok(daemon) =
    root.start(
      root.Config(state, "Owner", 8, limits.defaults),
      manager.Assembly(
        domain_build: domain,
        build: assemble(book, settings),
        drain: serve.drain_resident,
        fatal: serve.resident_children,
      ),
    )
    as "the daemon root starts"
  let assert Ok(ready) = root.ready(daemon, within: 10_000)
    as "the daemon is ready"
  let assert Ok(credential) = root.listener_credential(daemon)
    as "the owner's credential is issued"
  let assert Ok(ledger) = worktrees_ledger(ready.state_root)
    as "the execution ledger exists"
  let env =
    project_start.Env(
      book:,
      registry: ready.registry,
      sessions: ready.sessions_directory,
      state_root: ready.state_root,
      generator: fn() {
        ids.generator(
          clock.from_function(ffi_os.system_time_ms),
          ffi_os.unique_positive_integer(),
        )
      },
      domain_configuration: "",
      worktrees_for: fn(workspace) {
        worktrees.start(
          worktrees.Config(
            state_root: ready.state_root,
            ledger_path: ledger,
            helper_path: here() <> "/../sandbox/loom-exec",
            credentials: [],
            demand: settings.demand,
            logger: log.discard(),
          ),
          [workspace],
        )
      },
      now_ms: ffi_os.system_time_ms,
      max_workers: 2,
      policy: project_host.idle_policy,
      logger: log.discard(),
    )
  let control =
    project_start.Control(
      book:,
      create: fn(workspace, name) { project_start.create(env, workspace, name) },
      judge: fn(_) { Error("not used") },
    )
  let config =
    server.Config(
      peer_endpoint: fn(resident: serve.Resident) { Some(resident.peer) },
      daemon:,
      domain_configuration: "",
      executors: roster.fixed([]),
      pools: [],
      directory: session_directory.none(),
      movers: session_movers.idle(),
      deployment: deployment.alone("nonode@nohost"),
      ledger: None,
      generator: fn() { ids.generator(clock.fixed(1_700_000_000_000), 123) },
      session_upgrade: fn(
        request,
        attachment: server.Attachment(serve.Resident),
      ) {
        session_socket.upgrade(
          daemon,
          request,
          attachment,
          attachment.instance.gateway,
        )
      },
      ui: None,
      projects: Some(control),
    )
  let ports = process.new_subject()
  let assert Ok(listener) =
    mist.new(fn(request) { server.handle(config, request) })
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(ports, port) })
    |> mist.start
    as "the listener starts"
  process.unlink(listener.pid)
  let assert Ok(port) = process.receive(ports, 2000) as "the port is known"
  Daemon(
    root: daemon,
    ready:,
    book:,
    env:,
    port:,
    credential:,
    listener: listener.pid,
  )
}

// Ends the daemon the way a restart ends it: the sessions drain, the listener
// goes, and so do the project actors, which an operating-system process would
// have taken with it.
fn stop(daemon: Daemon) -> Nil {
  list.each(project_book.all(daemon.env.book), fn(handle) {
    case process.subject_owner(handle.commands) {
      Ok(pid) -> {
        process.unlink(pid)
        process.kill(pid)
      }
      Error(Nil) -> Nil
    }
  })
  assert root.shutdown(daemon.root, within: 20_000) == Ok(Nil)
  process.kill(daemon.listener)
  Nil
}

fn domain(
  selected: storage_domain.Domain,
  sources: fn() -> Result(List(shared_history.Source), String),
  owner: custody.Owner,
) -> Result(domain_service.Services, String) {
  let assert Ok(Nil) =
    bootstrap.ensure_private_directory(filepath.directory_name(
      selected.index_path,
    ))
    as "the domain owns its projection directory"
  domain_service.build(
    domain_service.Config(history: history.SharedConfig(
      selected.index_path,
      sources,
      5000,
      100,
    )),
    owner,
  )
}

// A session's builder: the ordinary one, then seated for a project session so
// that its tools, prompt and model follow from its standing.
fn assemble(
  book: project_book.Book,
  base: serve.Settings,
) -> fn(
  catalogue.Registration,
  storage_domain.Domain,
  domain_service.Services,
  custody.Owner,
  manager.Manager(serve.Resident),
) -> Result(serve.Resident, String) {
  fn(
    record: catalogue.Registration,
    selected: storage_domain.Domain,
    services: domain_service.Services,
    owner: custody.Owner,
    directory: manager.Manager(serve.Resident),
  ) {
    use identity <- result.try(
      ids.parse_session_id(record.id)
      |> result.replace_error("the reserved identity is not canonical"),
    )
    let settings =
      serve.Settings(
        ..base,
        peer_directory: Some(
          main.peer_directory(directory, fn(resident: serve.Resident) {
            resident.peer
          }),
        ),
        session_path: record.path,
        session_id: record.id,
        workspace: record.workspace,
        domain_paths: Some(serve.DomainPaths(
          selected.memory_path,
          selected.index_path,
        )),
        base_policy: workspace_policy.base_policy(record.workspace),
      )
    use seat <- result.try(project_start.seat(
      directory,
      book,
      record.id,
      settings.base_policy,
    ))
    let seated = case seat {
      Some(found) -> serve.seat_project(settings, found)
      None -> settings
    }
    serve.assemble_in_domain(seated, identity, log.discard(), owner, services)
    |> result.map(serve.resident)
  }
}

// The execution ledger the worktree service records its trees in, created once
// and reopened by name at a restart.
fn worktrees_ledger(state_root: String) -> Result(String, String) {
  let path = state_root <> "/exec-ledger.db"
  use ledger <- result.try(
    exec_ledger.open(path) |> result.map_error(string.inspect),
  )
  use Nil <- result.map(
    exec_ledger.close(ledger) |> result.map_error(string.inspect),
  )
  path
}

fn settings(seen: Subject(Seen)) -> serve.Settings {
  let base = owned_assembly_test.settings()
  let catalogue = scripted_catalog()
  serve.Settings(
    ..base,
    catalog: catalogue,
    model: strand.ModelIdentity(provider: "worker", model_id: worker_model),
    gateway: catalog.gateway(
      catalogue,
      transport: provider_test.transport(fn(request, events) {
        let reply = respond(request.body, seen)
        process.send(
          events,
          http.ResponseStatus(200, [#("content-type", "text/event-stream")]),
        )
        process.send(events, http.ResponseChunk(bit_array.from_string(reply)))
        process.send(events, http.ResponseEnd)
      }),
      secrets: secret.from_list([
        #("ROUTER_KEY", "fixture-key"),
        #("WORKER_KEY", "fixture-key"),
      ]),
      clock: clock.fixed(at: 0),
    ),
  )
}

fn scripted_catalog() -> catalog.Catalog {
  catalog.Catalog(
    models: [
      entry("worker", worker_model, "WORKER_KEY"),
      entry("router", router_model, "ROUTER_KEY"),
    ],
    roles: [
      #(model.Main, ["worker"]),
      #(catalog.router_role, ["router"]),
    ],
    profiles: [],
    mcp_servers: [],
    lsp_servers: [],
  )
}

fn entry(name: String, model_id: String, key: String) -> catalog.CatalogModel {
  catalog.CatalogModel(
    name:,
    dialect: catalog.Anthropic,
    base_url: "https://" <> name <> ".test",
    api_key_env: key,
    model_id:,
    context_window: 100_000,
    max_output_tokens: 4096,
    thinking: model.ThinkingOff,
    pricing: None,
    vision: catalog.TextOnly,
    max_images: 8,
    cyber_access: None,
    service_tier: None,
  )
}

// --- the scripted model ---------------------------------------------------------

type Request {
  Request(
    model: String,
    tools: List(String),
    transcript: String,
    last_text: String,
    last_was_result: Bool,
    results: Int,
    last_raw: String,
  )
}

// Answers one provider request. The router routes the candidate it was shown.
// The worker for the first ticket reports it is waiting with a question. The
// worker for the second first calls `route`, which is not among its tools, and
// then reports progress. Every other turn ends with a word.
fn respond(body: String, seen: Subject(Seen)) -> String {
  let request = read(body)
  process.send(seen, Advertised(request.model, request.tools))
  case request.model == router_model {
    True -> route_turn(request)
    False -> worker_turn(request, seen)
  }
}

fn route_turn(request: Request) -> String {
  let items =
    ["a", "b"]
    |> list.filter(fn(letter) {
      string.contains(request.last_text, "fix " <> letter)
    })
    |> list.map(fn(letter) {
      json.Object([
        #("trigger", json.String(letter)),
        #("action", json.String("accept")),
        #("title", json.String("fix " <> letter)),
      ])
    })

  // The last message can be a tool result and a new candidate together. The
  // second post may be admitted while the router is between its `route` call
  // and the result, and the session then folds the trigger into the message
  // that carries the result. Deciding by "the last message is a result" alone
  // answered "routed." to that message and never routed the second candidate:
  // the engine kept it offered, the board stayed at one ticket, and the test
  // waited out its deadline. A message that shows a candidate is routed
  // whether or not it also carries a result.
  case items, request.last_was_result {
    [], True -> text_turn("routed.")
    _, _ ->
      tool_turn(
        "route-" <> string.inspect(request.results),
        "route",
        json.Object([#("items", json.Array(items))]),
      )
  }
}

fn worker_turn(request: Request, seen: Subject(Seen)) -> String {
  let second = string.contains(request.transcript, "fix b")
  let ticket = case second {
    True -> "t-b"
    False -> "t-a"
  }
  case
    string.contains(request.last_text, "check your worktree and the source")
  {
    True -> process.send(seen, Recovered(ticket))
    False -> Nil
  }

  // The count of tool results so far is the worker's place in its script.
  case second, request.results {
    False, 0 ->
      tool_turn(
        "report-a",
        "project_report",
        json.Object([
          #("status", json.String("waiting")),
          #("question", json.String("which database?")),
        ]),
      )
    True, 0 -> tool_turn("misroute-b", "route", json.Object([]))
    True, 1 -> {
      process.send(seen, Refused(request.last_raw))
      tool_turn(
        "report-b",
        "project_report",
        json.Object([#("status", json.String("progress"))]),
      )
    }
    False, _ | True, _ -> text_turn("done.")
  }
}

fn read(body: String) -> Request {
  let assert Ok(parsed) = json.parse(body) as "the provider request is JSON"
  let messages = case field(parsed, "messages") {
    json.Array(items) -> items
    _ -> []
  }
  let tool_names = case field(parsed, "tools") {
    json.Array(items) ->
      list.filter_map(items, fn(item) {
        case field(item, "name") {
          json.String(name) -> Ok(name)
          _ -> Error(Nil)
        }
      })
    _ -> []
  }
  let blocks = list.map(messages, blocks_of)
  let last = list.last(blocks) |> result.unwrap([])
  Request(
    model: case field(parsed, "model") {
      json.String(name) -> name
      _ -> ""
    },
    tools: list.sort(tool_names, string.compare),
    transcript: blocks
      |> list.flatten
      |> list.map(block_text)
      |> string.join("\n"),
    last_text: last |> list.map(block_text) |> string.join("\n"),
    last_was_result: list.any(last, is_result),
    results: blocks |> list.flatten |> list.count(is_result),
    last_raw: last |> list.map(json.to_string) |> string.join(""),
  )
}

fn blocks_of(message: JsonValue) -> List(JsonValue) {
  case field(message, "content") {
    json.Array(items) -> items
    json.String(text) -> [json.Object([#("text", json.String(text))])]
    _ -> []
  }
}

fn block_text(block: JsonValue) -> String {
  case field(block, "text") {
    json.String(text) -> text
    _ -> ""
  }
}

fn is_result(block: JsonValue) -> Bool {
  field(block, "type") == json.String("tool_result")
}

fn field(value: JsonValue, key: String) -> JsonValue {
  case value {
    json.Object(fields) ->
      list.key_find(fields, key) |> result.unwrap(json.Null)
    _ -> json.Null
  }
}

fn text_turn(text: String) -> String {
  started()
  <> sse(
    "content_block_start",
    "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
  )
  <> sse(
    "content_block_delta",
    "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":"
      <> json.to_string(json.String(text))
      <> "}}",
  )
  <> sse("content_block_stop", "{\"type\":\"content_block_stop\",\"index\":0}")
  <> stopped("end_turn")
}

fn tool_turn(id: String, name: String, arguments: JsonValue) -> String {
  started()
  <> sse(
    "content_block_start",
    "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\""
      <> id
      <> "\",\"name\":\""
      <> name
      <> "\",\"input\":{}}}",
  )
  <> sse(
    "content_block_delta",
    "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":"
      <> json.to_string(json.String(json.to_string(arguments)))
      <> "}}",
  )
  <> sse("content_block_stop", "{\"type\":\"content_block_stop\",\"index\":0}")
  <> stopped("tool_use")
}

fn started() -> String {
  sse(
    "message_start",
    "{\"type\":\"message_start\",\"message\":{\"id\":\"scripted\",\"model\":\"scripted\",\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}",
  )
}

fn stopped(reason: String) -> String {
  sse(
    "message_delta",
    "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\""
      <> reason
      <> "\"},\"usage\":{\"output_tokens\":1}}",
  )
  <> sse("message_stop", "{\"type\":\"message_stop\"}")
}

fn sse(event: String, data: String) -> String {
  "event: " <> event <> "\ndata: " <> data <> "\n\n"
}

// --- the control socket ----------------------------------------------------------

// One command on a connection of its own, answered with the reply's body.
fn command(
  daemon: Daemon,
  name: String,
  fields: List(#(String, JsonValue)),
) -> JsonValue {
  let #(socket, upgrade) =
    wire.connect(daemon.port, daemon.credential, "/v2/control")
  assert string.contains(upgrade, "101 Switching Protocols")
  let _hello = wire.frame(socket, within_ms: 5000)
  let answer =
    wire.reply(socket, 1, name, json.Object(fields), within_ms: 30_000)
  let _ = ffi_ws.tcp_close(socket)
  field(answer, "body")
}

fn post(daemon: Daemon, project: String, request: String, text: String) {
  command(daemon, "projects.post", [
    #("project", json.String(project)),
    #("request_id", json.String(request)),
    #("text", json.String(text)),
  ])
}

fn text_of(value: JsonValue, key: String) -> String {
  case field(value, key) {
    json.String(text) -> text
    other -> panic as { "no text at " <> key <> ": " <> json.to_string(other) }
  }
}

// --- the board ----------------------------------------------------------------------

fn tickets_of(daemon: Daemon, project: String) -> List(JsonValue) {
  let board =
    command(daemon, "projects.board", [#("project", json.String(project))])
  case field(board, "tickets") {
    json.Array(items) -> items
    _ -> []
  }
}

// Waits until the board's tickets satisfy `ready`, and answers them.
fn await_tickets(
  daemon: Daemon,
  project: String,
  ready: fn(List(JsonValue)) -> Bool,
) -> List(JsonValue) {
  let outcome =
    poll.until(within: 60_000, every: 250, attempt: fn() {
      let tickets = tickets_of(daemon, project)
      case ready(tickets) {
        True -> poll.Done(tickets)
        False -> poll.Retry
      }
    })
  let assert poll.Answered(tickets) = outcome
    as "the board reaches the expected state"
  tickets
}

fn stage_of(tickets: List(JsonValue), title: String) -> String {
  list.find(tickets, fn(each) { field(each, "title") == json.String(title) })
  |> result.map(text_of(_, "stage"))
  |> result.unwrap("")
}

fn ticket_titles(tickets: List(JsonValue)) -> List(String) {
  list.map(tickets, text_of(_, "title")) |> list.sort(string.compare)
}

// The session ids of the tickets, in ticket-id order.
fn ticket_sessions(tickets: List(JsonValue)) -> List(String) {
  tickets
  |> list.sort(fn(a, b) { string.compare(text_of(a, "id"), text_of(b, "id")) })
  |> list.map(text_of(_, "session"))
}

fn workspace_of(daemon: Daemon, session: String) -> String {
  let assert Ok(manager.View(registration, _)) =
    manager.get(daemon.ready.registry, session)
    as "the session is registered"
  registration.workspace
}

fn session_count(daemon: Daemon) -> Int {
  let assert Ok(#(_revision, views)) =
    manager.page(daemon.ready.registry, after: "")
    as "the registry lists its sessions"
  list.length(views)
}

// --- what the model was shown -----------------------------------------------------------

fn drain(seen: Subject(Seen)) -> List(Seen) {
  case process.receive(seen, 0) {
    Ok(one) -> [one, ..drain(seen)]
    Error(Nil) -> []
  }
}

// The distinct tool lists a model was advertised, so a model offered one list
// every time reads as one entry.
fn advertised(evidence: List(Seen), model_id: String) -> List(List(String)) {
  evidence
  |> list.filter_map(fn(each) {
    case each {
      Advertised(model:, tools:) if model == model_id -> Ok(tools)
      Advertised(..) | Refused(_) | Recovered(_) -> Error(Nil)
    }
  })
  |> list.unique
}

fn refusals(evidence: List(Seen)) -> List(String) {
  list.filter_map(evidence, fn(each) {
    case each {
      Refused(result:) -> Ok(result)
      Advertised(..) | Recovered(_) -> Error(Nil)
    }
  })
}

// The tickets whose workers were told of the restart. Workers answer the note
// on their own time, so this waits for both.
fn recovered(seen: Subject(Seen), found: List(String)) -> List(String) {
  case list.length(list.unique(found)) >= 2 {
    True -> list.unique(found)
    False ->
      case process.receive(seen, 20_000) {
        Ok(Recovered(ticket)) -> recovered(seen, [ticket, ..found])
        Ok(Advertised(..)) | Ok(Refused(_)) -> recovered(seen, found)
        Error(Nil) -> list.unique(found)
      }
  }
}

// --- the router's configuration ---------------------------------------------------------

// A client of the router's session asks `set_config` for tools above the
// router's three, and is refused.
fn refuses_tools(daemon: Daemon, router: String, names: List(String)) -> Nil {
  let #(socket, upgrade) =
    wire.connect(
      daemon.port,
      daemon.credential,
      "/v2/sessions/" <> router <> "/ws",
    )
  assert string.contains(upgrade, "101 Switching Protocols")
  let _joined = wire.subscribe(socket, 1, router, within_ms: 10_000)
  let answer =
    wire.reply(
      socket,
      2,
      "set_config",
      json.Object([
        #("strand", json.String("main")),
        #(
          "config",
          json.Object([
            #("active_tools", json.Array(list.map(names, json.String))),
          ]),
        ),
      ]),
      within_ms: 10_000,
    )
  let _ = ffi_ws.tcp_close(socket)

  // The router's tools cannot be widened, by `set_config` or any other way.
  assert field(answer, "event") == json.String("error")
  assert text_of(field(answer, "body"), "code") == "bad_request"
}

// --- a trigger the gate does not admit ------------------------------------------------------

fn ledger_path(daemon: Daemon, project: String) -> String {
  daemon.ready.state_root <> "/projects/" <> project <> "/ledger.db"
}

// Appends to the project's ledger the way a source's delivery would: the host's
// record of the text, then the engine's event for a message from someone the
// project does not list. It must run while no actor holds the ledger.
fn deliver_unadmitted(path: String) -> Nil {
  let assert Ok(ledger) = project_ledger.open(path) as "the ledger opens"
  let arrived =
    project_model.Trigger(
      id: project_model.TriggerId("inferred-1"),
      source: project_model.SourceId("github"),
      thread: project_model.ThreadId("gh-1"),
      actor: project_model.ActorId("stranger"),
      inputs: project_model.Inputs(
        sender: project_model.Unlisted,
        addressing: project_model.Unaddressed,
        rule: None,
      ),
      generation: 0,
      at_ms: ffi_os.system_time_ms(),
    )
  let assert Ok(_) =
    project_ledger.append(
      ledger,
      project_records_text("inferred-1", "take it"),
      ffi_os.system_time_ms(),
    )
    as "the text is recorded"
  let assert Ok(_) =
    project_ledger.append(
      ledger,
      project_events_arrival(arrived),
      ffi_os.system_time_ms(),
    )
    as "the trigger is recorded"
  let assert Ok(Nil) = project_ledger.close(ledger) as "the ledger closes"
  Nil
}

// --- scratch ------------------------------------------------------------------------------------

fn scratch(name: String) -> String {
  let directory =
    here()
    <> "/build/"
    <> name
    <> "-"
    <> int.to_string(ffi_os.system_time_ms())
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
    as "the scratch directory is made"
  directory
}

fn here() -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner has a working directory"
  here
}

fn project_records_text(trigger: String, body: String) -> String {
  project_records.encode_record(project_records.TriggerText(
    trigger,
    "github",
    "stranger",
    body,
  ))
}

fn project_events_arrival(arrived: project_model.Trigger) -> String {
  project_records.encode_event(event.TriggerArrived(
    arrived,
    project_model.ActorId("loom"),
  ))
}
