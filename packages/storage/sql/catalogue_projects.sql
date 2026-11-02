-- Catalogue v20: project mode's two catalogue tables (protocol-change/106,
-- "Durable state"). A project is one workspace, one router session and one
-- ledger file. The first version binds exactly one workspace, so workspace is
-- unique: a second project over the same workspace is refused by the schema and
-- not by a check in the caller. The router session is unique and references
-- catalogue_sessions, so a session is the router of at most one project and a
-- registration cannot be deleted while a project names it. ledger_path is the
-- project's SQLite ledger file, which the catalogue names and never opens. The
-- state is the owner's word: an archived project keeps its row and its ledger.
-- Times are Unix milliseconds read from the system clock.
CREATE TABLE catalogue_projects(
  project_id TEXT NOT NULL PRIMARY KEY CHECK(length(CAST(project_id AS BLOB)) BETWEEN 1 AND 64),
  workspace TEXT NOT NULL UNIQUE CHECK(length(CAST(workspace AS BLOB)) >= 1),
  router_session TEXT NOT NULL UNIQUE REFERENCES catalogue_sessions(session_id),
  ledger_path TEXT NOT NULL CHECK(length(CAST(ledger_path AS BLOB)) >= 1),
  state TEXT NOT NULL CHECK(state IN ('active', 'archived')),
  created_ms INTEGER NOT NULL CHECK(created_ms >= 0)
);

-- One row per worker session. The worker's request key derives from
-- (ticket, assignment_seq), so the unique triple below is the catalogue's side
-- of that idempotence: a ticket's n-th assignment binds at most one session.
CREATE TABLE catalogue_project_workers(
  session_id TEXT NOT NULL PRIMARY KEY REFERENCES catalogue_sessions(session_id),
  project_id TEXT NOT NULL REFERENCES catalogue_projects(project_id),
  ticket_id TEXT NOT NULL CHECK(length(CAST(ticket_id AS BLOB)) BETWEEN 1 AND 128),
  assignment_seq INTEGER NOT NULL CHECK(assignment_seq >= 0),
  UNIQUE(project_id, ticket_id, assignment_seq)
);
