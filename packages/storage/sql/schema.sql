-- Daemon catalogue schema. Conversation storage remains a separate database.
CREATE TABLE catalogue_meta(
  singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
  revision INTEGER NOT NULL
);
CREATE TABLE catalogue_sessions(
  session_id TEXT NOT NULL PRIMARY KEY,
  path TEXT NOT NULL UNIQUE,
  workspace TEXT NOT NULL,
  name TEXT NOT NULL,
  configuration TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  request_key TEXT NOT NULL UNIQUE,
  state TEXT NOT NULL CHECK(state IN ('reserved', 'saved'))
);
CREATE INDEX catalogue_workspace ON catalogue_sessions(workspace, session_id);
CREATE TABLE catalogue_defaults(
  workspace TEXT NOT NULL PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES catalogue_sessions(session_id)
);

-- Stable principals are independent from revocable bearer credentials.
CREATE TABLE access_principals(
  principal_id TEXT NOT NULL PRIMARY KEY,
  display_name TEXT NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('owner', 'member'))
);
CREATE UNIQUE INDEX access_one_owner ON access_principals(kind) WHERE kind = 'owner';
CREATE TABLE access_credentials(
  digest TEXT NOT NULL PRIMARY KEY CHECK(length(digest) = 64 AND digest NOT GLOB '*[^0-9a-f]*'),
  principal_id TEXT NOT NULL REFERENCES access_principals(principal_id),
  state TEXT NOT NULL CHECK(state IN ('active', 'revoked'))
);
CREATE TABLE access_memberships(
  principal_id TEXT NOT NULL REFERENCES access_principals(principal_id),
  session_id TEXT NOT NULL REFERENCES catalogue_sessions(session_id),
  role TEXT NOT NULL CHECK(role IN ('operator', 'observer')),
  PRIMARY KEY(principal_id, session_id)
);

-- Domain metadata never opens its memory, index, or source conversations.
CREATE TABLE catalogue_domains(
  domain_id TEXT NOT NULL PRIMARY KEY,
  scope TEXT NOT NULL CHECK(scope IN ('workspace_private', 'session_only')),
  scope_key TEXT NOT NULL,
  workspace TEXT NOT NULL,
  configuration TEXT NOT NULL,
  memory_path TEXT NOT NULL UNIQUE,
  index_path TEXT NOT NULL UNIQUE,
  digest_path TEXT NOT NULL UNIQUE,
  UNIQUE(scope, scope_key)
);
CREATE TABLE catalogue_domain_sessions(
  session_id TEXT NOT NULL PRIMARY KEY REFERENCES catalogue_sessions(session_id),
  domain_id TEXT NOT NULL REFERENCES catalogue_domains(domain_id)
);
CREATE INDEX catalogue_domain_sources ON catalogue_domain_sessions(domain_id, session_id);
