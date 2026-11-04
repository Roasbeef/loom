//// The catalogue's two project tables (protocol-change/106, catalogue version
//// 20) and the wrappers over them.
////
//// Two kinds of test sit here, on purpose. The wrappers answer a refusal as
//// `Conflict`, and those tests prove the answer. The raw statements go around
//// the wrappers to the connection, because a wrapper that checks first would
//// hide a constraint the schema had lost; those tests are the ones that fail
//// when a UNIQUE or a REFERENCES is removed from `sql/catalogue_projects.sql`.

import core/clock
import core/ids
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import sqlight
import storage/catalogue
import support/fixtures

fn registration(seed: Int) -> catalogue.Registration {
  let #(id, _) = ids.mint_session(ids.generator(clock.fixed(2000 + seed), seed))
  let id = ids.session_id_to_string(id)
  catalogue.Registration(
    id:,
    path: "/never-opened-project/" <> id <> ".db",
    workspace: "/workspace",
    name: "Project session " <> int.to_string(seed),
    configuration: "",
    created_at: 2000 + seed,
    request_key: "project-test-" <> int.to_string(seed),
    state: catalogue.Reserved,
    profile: None,
    model: None,
    executor: "",
    pool: "",
    subtitle: None,
  )
}

// A catalogue holding registrations for the given seeds, and their ids.
fn catalogue_with(name: String, seeds: List(Int)) {
  let path = fixtures.scratch(name) <> "/catalogue.db"
  let assert Ok(store) = catalogue.open(path) as "the catalogue opens"
  let ids =
    seeds
    |> list.map(fn(seed) {
      let record = registration(seed)
      let assert Ok(_) = catalogue.reserve(store, record)
        as "the registration is reserved"
      record.id
    })
  #(path, store, ids)
}

fn project(id: String, workspace: String, router: String) -> catalogue.Project {
  catalogue.Project(
    id:,
    workspace:,
    router_session: router,
    ledger_path: workspace <> "/.loom/ledger.db",
    state: catalogue.ProjectActive,
    created_ms: 1_700_000_000_000,
  )
}

fn worker(
  session: String,
  project: String,
  ticket: String,
  seq: Int,
) -> catalogue.ProjectWorker {
  catalogue.ProjectWorker(session_id: session, project:, ticket:, seq:)
}

fn raw(path: String, statements: String) -> Result(Nil, sqlight.Error) {
  let assert Ok(connection) = sqlight.open(path) as "the raw connection opens"
  let outcome =
    sqlight.exec("PRAGMA foreign_keys=ON; " <> statements, on: connection)
  let assert Ok(Nil) = sqlight.close(connection) as "the raw connection closes"
  outcome
}

fn refused(outcome: Result(Nil, sqlight.Error)) -> Bool {
  case outcome {
    Error(sqlight.SqlightError(code:, ..)) ->
      int.bitwise_and(sqlight.error_code_to_int(code), 255) == 19
    Ok(Nil) -> False
  }
}

fn user_version(path: String) -> List(Int) {
  let assert Ok(connection) = sqlight.open(path) as "the version probe opens"
  let versions =
    sqlight.query(
      "PRAGMA user_version",
      on: connection,
      with: [],
      expecting: decode.at([0], decode.int),
    )
  let assert Ok(Nil) = sqlight.close(connection) as "the version probe closes"
  result.unwrap(versions, [])
}

pub fn the_catalogue_is_at_version_twenty_test() {
  assert catalogue.current_version == 20
  let #(path, store, _) = catalogue_with("project-version", [])
  assert catalogue.close(store) == Ok(Nil)
  assert user_version(path) == [20]
}

pub fn version_nineteen_catalogue_gains_the_project_tables_test() {
  let assert #(path, store, [router, session]) =
    catalogue_with("project-migration", [1, 2])
  let assert Ok(_) = catalogue.rename(store, session, "kept name")
    as "a name predates the migration"
  assert catalogue.close(store) == Ok(Nil)

  // A version-nineteen file is the current one without the project tables.
  let assert Ok(Nil) =
    raw(
      path,
      "DROP TABLE catalogue_project_workers; DROP TABLE catalogue_projects; PRAGMA user_version=19",
    )
    |> result.replace_error(Nil)
  assert user_version(path) == [19]

  // One open adds the tables and stamps the version, and the data it held is
  // as it was.
  let assert Ok(migrated) = catalogue.open(path) as "version nineteen migrates"
  assert catalogue.get(migrated, session) |> result.map(fn(r) { r.name })
    == Ok("kept name")
  assert catalogue.projects(migrated) == Ok([])
  let made = project("p1", "/work/repo", router)
  assert catalogue.atomic(migrated, fn() {
      catalogue.create_project(migrated, made)
    })
    == Ok(Nil)
  assert catalogue.close(migrated) == Ok(Nil)
  assert user_version(path) == [20]
}

pub fn the_schema_refuses_what_the_wrappers_would_also_refuse_test() {
  let assert #(path, store, [router_a, router_b, orphan_free]) =
    catalogue_with("project-constraints", [1, 2, 3])
  let made = project("p1", "/work/repo", router_a)
  let assert Ok(Nil) =
    catalogue.atomic(store, fn() { catalogue.create_project(store, made) })
  assert catalogue.close(store) == Ok(Nil)

  // A second project over the same workspace.
  assert refused(raw(
    path,
    "INSERT INTO catalogue_projects VALUES('p2', '/work/repo', '"
      <> router_b
      <> "', '/l', 'active', 0)",
  ))
    as "workspace is unique"

  // A second project for the same router session.
  assert refused(raw(
    path,
    "INSERT INTO catalogue_projects VALUES('p2', '/work/other', '"
      <> router_a
      <> "', '/l', 'active', 0)",
  ))
    as "router session is unique"

  // A router that is not a registered session.
  assert refused(raw(
    path,
    "INSERT INTO catalogue_projects VALUES('p2', '/work/other', 'no-such-session', '/l', 'active', 0)",
  ))
    as "router session references the catalogue"

  // A state outside the two words.
  assert refused(raw(
    path,
    "INSERT INTO catalogue_projects VALUES('p2', '/work/other', '"
      <> orphan_free
      <> "', '/l', 'paused', 0)",
  ))
    as "state is one of two words"

  // A worker for a project that does not exist, and for a session that does
  // not exist.
  assert refused(raw(
    path,
    "INSERT INTO catalogue_project_workers VALUES('"
      <> router_b
      <> "', 'no-such-project', 't1', 0)",
  ))
    as "worker references a project"
  assert refused(raw(
    path,
    "INSERT INTO catalogue_project_workers VALUES('no-such-session', 'p1', 't1', 0)",
  ))
    as "worker references a session"

  // The same assignment bound to two sessions.
  assert raw(
      path,
      "INSERT INTO catalogue_project_workers VALUES('"
        <> router_b
        <> "', 'p1', 't1', 0)",
    )
    == Ok(Nil)
  assert refused(raw(
    path,
    "INSERT INTO catalogue_project_workers VALUES('"
      <> orphan_free
      <> "', 'p1', 't1', 0)",
  ))
    as "an assignment binds one session"

  // The same session bound twice.
  assert refused(raw(
    path,
    "INSERT INTO catalogue_project_workers VALUES('"
      <> router_b
      <> "', 'p1', 't2', 0)",
  ))
    as "a session is one worker"

  // A registration cannot be removed while a project names it.
  assert refused(raw(
    path,
    "DELETE FROM catalogue_sessions WHERE session_id = '" <> router_a <> "'",
  ))
    as "a router registration is held by its project"
}

pub fn the_wrappers_answer_a_refusal_as_conflict_test() {
  let assert #(_path, store, [router_a, router_b, worker_a, worker_b]) =
    catalogue_with("project-conflicts", [1, 2, 3, 4])
  let first = project("p1", "/work/repo", router_a)
  let create = fn(made) {
    catalogue.atomic(store, fn() { catalogue.create_project(store, made) })
  }
  let bind = fn(w) {
    catalogue.atomic(store, fn() { catalogue.bind_worker(store, w) })
  }
  assert create(first) == Ok(Nil)

  // Id, workspace and router are each taken by the first project.
  assert create(project("p1", "/work/other", router_b))
    == Error(catalogue.Conflict)
  assert create(project("p2", "/work/repo", router_b))
    == Error(catalogue.Conflict)
  assert create(project("p2", "/work/other", router_a))
    == Error(catalogue.Conflict)

  // A router that is not registered.
  let ghost =
    ids.session_id_to_string(
      ids.mint_session(ids.generator(clock.fixed(9), 99)).0,
    )
  assert create(project("p2", "/work/other", ghost))
    == Error(catalogue.Conflict)

  // A refused create wrote nothing.
  assert catalogue.projects(store) == Ok([first])

  // Workers: one binding per session and per assignment, and a router is not
  // one.
  assert bind(worker(worker_a, "p1", "t1", 0)) == Ok(Nil)
  assert bind(worker(worker_a, "p1", "t2", 0)) == Error(catalogue.Conflict)
  assert bind(worker(worker_b, "p1", "t1", 0)) == Error(catalogue.Conflict)
  assert bind(worker(router_a, "p1", "t3", 0)) == Error(catalogue.Conflict)
  assert bind(worker(worker_b, "p9", "t1", 1)) == Error(catalogue.Conflict)
  assert bind(worker(worker_b, "p1", "t1", 1)) == Ok(Nil)

  // A session that is a worker cannot become a router.
  assert create(project("p3", "/work/third", worker_a))
    == Error(catalogue.Conflict)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn malformed_fields_are_invalid_and_write_nothing_test() {
  let assert #(_path, store, [router, session]) =
    catalogue_with("project-invalid", [1, 2])
  let create = fn(made) {
    catalogue.atomic(store, fn() { catalogue.create_project(store, made) })
  }
  let ok = project("p1", "/work/repo", router)
  let invalid = Error(catalogue.Invalid("invalid project metadata"))
  assert create(catalogue.Project(..ok, id: "")) == invalid
  assert create(catalogue.Project(..ok, id: "bad\nid")) == invalid
  assert create(catalogue.Project(..ok, workspace: "")) == invalid
  assert create(catalogue.Project(..ok, ledger_path: "")) == invalid
  assert create(catalogue.Project(..ok, router_session: "not-a-session"))
    == invalid
  assert create(catalogue.Project(..ok, created_ms: -1)) == invalid
  let bad_worker = Error(catalogue.Invalid("invalid project worker metadata"))
  assert catalogue.bind_worker(store, worker(session, "p1", "", 0))
    == bad_worker
  assert catalogue.bind_worker(store, worker(session, "p1", "t", -1))
    == bad_worker
  assert catalogue.projects(store) == Ok([])
  assert catalogue.close(store) == Ok(Nil)
}

pub fn project_standing_has_three_answers_test() {
  let assert #(path, store, [router, session, plain]) =
    catalogue_with("project-standing", [1, 2, 3])
  let assert Ok(Nil) =
    catalogue.atomic(store, fn() {
      use Nil <- result.try(catalogue.create_project(
        store,
        project("p1", "/work/repo", router),
      ))
      catalogue.bind_worker(store, worker(session, "p1", "ticket-7", 3))
    })
  assert catalogue.project_standing(store, router)
    == Ok(catalogue.RouterOf("p1"))
  assert catalogue.project_standing(store, session)
    == Ok(catalogue.WorkerOf("p1", "ticket-7", 3))
  assert catalogue.project_standing(store, plain) == Ok(catalogue.NotProject)
  assert catalogue.project_standing(store, "unregistered")
    == Ok(catalogue.NotProject)

  // A catalogue that says a session is both is damaged, and the lookup says so
  // and does not pick one.
  let assert Ok(Nil) =
    raw(
      path,
      "PRAGMA foreign_keys=OFF; INSERT INTO catalogue_project_workers VALUES('"
        <> router
        <> "', 'p1', 't9', 0)",
    )
    |> result.replace_error(Nil)
  assert catalogue.project_standing(store, router)
    == Error(catalogue.Invalid("duplicate project standing"))
  assert catalogue.close(store) == Ok(Nil)
}

pub fn projects_read_back_and_archive_once_test() {
  let assert #(_path, store, [router_a, router_b]) =
    catalogue_with("project-reads", [1, 2])
  let a = project("alpha", "/work/a", router_a)
  let b = project("beta", "/work/b", router_b)
  let assert Ok(Nil) =
    catalogue.atomic(store, fn() {
      use Nil <- result.try(catalogue.create_project(store, b))
      catalogue.create_project(store, a)
    })
  assert catalogue.project(store, "alpha") == Ok(Some(a))
  assert catalogue.project(store, "gamma") == Ok(None)
  assert catalogue.project_of_workspace(store, "/work/b") == Ok(Some(b))
  assert catalogue.project_of_workspace(store, "/work/c") == Ok(None)
  assert catalogue.projects(store) == Ok([a, b])

  // Archiving is idempotent and keeps the row.
  assert catalogue.archive_project(store, "alpha") == Ok(Nil)
  assert catalogue.archive_project(store, "alpha") == Ok(Nil)
  let archived = catalogue.Project(..a, state: catalogue.ProjectArchived)
  assert catalogue.projects(store) == Ok([archived, b])
  assert catalogue.archive_project(store, "gamma") == Error(catalogue.Missing)

  assert catalogue.close(store) == Ok(Nil)
}

pub fn a_damaged_project_row_is_invalid_not_absent_test() {
  let assert #(path, store, [router]) = catalogue_with("project-damaged", [1])
  let assert Ok(Nil) =
    catalogue.atomic(store, fn() {
      catalogue.create_project(store, project("p1", "/work/repo", router))
    })

  // A state word this build does not know, written past the CHECK.
  let assert Ok(Nil) =
    raw(
      path,
      "PRAGMA ignore_check_constraints=ON; UPDATE catalogue_projects SET state = 'paused'",
    )
    |> result.replace_error(Nil)
  assert catalogue.project(store, "p1")
    == Error(catalogue.Invalid("unknown project state"))
  assert catalogue.projects(store)
    == Error(catalogue.Invalid("unknown project state"))
  assert catalogue.close(store) == Ok(Nil)
}
