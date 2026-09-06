-- Static catalogue queries. Keep ASCII-only for parrot's byte slicing.

-- name: InitializeCatalogueRevision :exec
INSERT INTO catalogue_meta (singleton, revision) VALUES (1, 0);

-- name: FindRegistrations :many
SELECT session_id, path, workspace, name, configuration, created_at, request_key, state
FROM catalogue_sessions
WHERE session_id = ? OR request_key = ? OR path = ?;

-- name: InsertRegistration :exec
INSERT INTO catalogue_sessions
  (session_id, path, workspace, name, configuration, created_at, request_key, state)
VALUES (?, ?, ?, ?, ?, ?, ?, 'reserved');

-- name: ConfirmRegistration :exec
UPDATE catalogue_sessions SET state = 'saved' WHERE session_id = ?;

-- name: RegistrationPage :many
SELECT session_id, path, workspace, name, configuration, created_at, request_key, state
FROM catalogue_sessions
WHERE session_id > ?
ORDER BY session_id
LIMIT 100;

-- name: CatalogueRevision :one
SELECT revision FROM catalogue_meta WHERE singleton = 1;

-- name: MemberRegistrationPage :many
SELECT s.session_id, s.path, s.workspace, s.name, s.configuration,
       s.created_at, s.request_key, s.state
FROM access_memberships AS m
JOIN catalogue_sessions AS s ON s.session_id = m.session_id
WHERE m.principal_id = ? AND s.session_id > ?
  AND m.role IN ('operator', 'observer')
ORDER BY s.session_id
LIMIT 100;

-- name: IncrementCatalogueRevision :exec
UPDATE catalogue_meta SET revision = revision + 1 WHERE singleton = 1;

-- name: WorkspaceDefault :many
SELECT session_id FROM catalogue_defaults WHERE workspace = ?;

-- name: SetWorkspaceDefault :exec
INSERT INTO catalogue_defaults (workspace, session_id) VALUES (?, ?)
ON CONFLICT(workspace) DO UPDATE SET session_id = excluded.session_id;
