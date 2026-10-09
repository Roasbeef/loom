-- Static catalogue queries. Keep ASCII-only for parrot's byte slicing.

-- name: InitializeCatalogueRevision :exec
INSERT INTO catalogue_meta (singleton, revision) VALUES (1, 0);

-- name: FindRegistrations :many
SELECT session_id, path, workspace, name, configuration, created_at, request_key, state, profile, model, executor, pool
FROM catalogue_sessions
WHERE session_id = ? OR request_key = ? OR path = ?;

-- name: InsertRegistration :exec
INSERT INTO catalogue_sessions
  (session_id, path, workspace, name, configuration, created_at, request_key, state, profile, model, executor, pool)
VALUES (?, ?, ?, ?, ?, ?, ?, 'reserved', ?, ?, ?, ?);

-- name: SeedRegistrationExecutor :exec
UPDATE catalogue_sessions SET executor = ?
WHERE session_id = ? AND pool != '' AND executor = '';

-- name: ConfirmRegistration :exec
UPDATE catalogue_sessions SET state = 'saved' WHERE session_id = ?;

-- name: RegistrationDisplayName :many
SELECT name FROM catalogue_session_names WHERE session_id = ?;

-- name: RegistrationSubtitle :many
SELECT subtitle FROM catalogue_session_subtitles WHERE session_id = ?;

-- name: InsertRegistrationSubtitle :exec
INSERT INTO catalogue_session_subtitles (session_id, subtitle) VALUES (?, ?)
ON CONFLICT(session_id) DO NOTHING;

-- name: DeleteSessionSubtitle :exec
DELETE FROM catalogue_session_subtitles WHERE session_id = ?;

-- name: SetRegistrationDisplayName :exec
INSERT INTO catalogue_session_names (session_id, name) VALUES (?, ?)
ON CONFLICT(session_id) DO UPDATE SET name = excluded.name;

-- name: RegistrationPage :many
SELECT s.session_id, s.path, s.workspace, CAST(COALESCE(n.name, s.name) AS TEXT) AS name,
       s.configuration, s.created_at, s.request_key, s.state, s.profile, s.model, s.executor, s.pool, t.subtitle
FROM catalogue_sessions AS s
LEFT JOIN catalogue_session_names AS n ON n.session_id = s.session_id
LEFT JOIN catalogue_session_subtitles AS t ON t.session_id = s.session_id
WHERE s.session_id > @after
  AND EXISTS (SELECT 1 FROM catalogue_session_archives AS a
              WHERE a.session_id = s.session_id) = CAST(@archived AS INTEGER)
ORDER BY s.session_id
LIMIT 100;

-- name: CatalogueRevision :one
SELECT revision FROM catalogue_meta WHERE singleton = 1;

-- name: MemberRegistrationPage :many
SELECT s.session_id, s.path, s.workspace, CAST(COALESCE(n.name, s.name) AS TEXT) AS name, s.configuration,
       s.created_at, s.request_key, s.state, s.profile, s.model, s.executor, s.pool, t.subtitle
FROM access_memberships AS m
JOIN catalogue_sessions AS s ON s.session_id = m.session_id
LEFT JOIN catalogue_session_names AS n ON n.session_id = s.session_id
LEFT JOIN catalogue_session_subtitles AS t ON t.session_id = s.session_id
WHERE m.principal_id = ? AND s.session_id > ?
  AND m.role IN ('operator', 'observer')
  AND NOT EXISTS (SELECT 1 FROM catalogue_session_archives AS a
                  WHERE a.session_id = s.session_id)
ORDER BY s.session_id
LIMIT 100;

-- name: IncrementCatalogueRevision :exec
UPDATE catalogue_meta SET revision = revision + 1 WHERE singleton = 1;

-- name: WorkspaceDefault :many
SELECT session_id FROM catalogue_defaults WHERE workspace = ?;

-- name: SetWorkspaceDefault :exec
INSERT INTO catalogue_defaults (workspace, session_id) VALUES (?, ?)
ON CONFLICT(workspace) DO UPDATE SET session_id = excluded.session_id;

-- name: DeleteSessionDefault :exec
DELETE FROM catalogue_defaults WHERE session_id = ?;

-- name: DeleteSessionMemberships :exec
DELETE FROM access_memberships WHERE session_id = ?;

-- name: DeleteSessionDomain :exec
DELETE FROM catalogue_domain_sessions WHERE session_id = ?;

-- name: DeleteSessionDisplayName :exec
DELETE FROM catalogue_session_names WHERE session_id = ?;

-- name: DeleteRegistration :exec
DELETE FROM catalogue_sessions WHERE session_id = ?;

-- name: SessionArchive :many
SELECT session_id FROM catalogue_session_archives WHERE session_id = ?;

-- name: ArchiveSession :exec
INSERT INTO catalogue_session_archives (session_id) VALUES (?);

-- name: RestoreSession :exec
DELETE FROM catalogue_session_archives WHERE session_id = ?;

-- name: RecentFolders :many
SELECT seq, workspace FROM catalogue_recent_folders ORDER BY seq DESC;

-- name: InsertRecentFolder :exec
INSERT INTO catalogue_recent_folders (workspace) VALUES (?);

-- name: DeleteRecentFolder :exec
DELETE FROM catalogue_recent_folders WHERE workspace = ?;

-- name: ForgetRecentFolder :exec
DELETE FROM catalogue_recent_folders WHERE seq = ?;

-- name: TrimRecentFolders :exec
DELETE FROM catalogue_recent_folders
WHERE seq NOT IN (SELECT seq FROM catalogue_recent_folders ORDER BY seq DESC LIMIT ?);

-- name: SessionMove :many
SELECT op, peer, state FROM catalogue_session_moves WHERE session_id = ?;

-- name: InsertSessionMove :exec
INSERT INTO catalogue_session_moves (session_id, op, peer, state) VALUES (?, ?, ?, ?);

-- name: FinishSessionMove :exec
UPDATE catalogue_session_moves SET state = 'moved'
WHERE session_id = ? AND op = ? AND state = 'moving';

-- name: AbortSessionMove :exec
DELETE FROM catalogue_session_moves
WHERE session_id = ? AND op = ? AND state = 'moving';

-- name: DeleteSessionMove :exec
DELETE FROM catalogue_session_moves WHERE session_id = ?;

-- name: MovingSessions :many
SELECT session_id, op, peer FROM catalogue_session_moves
WHERE state = 'moving' ORDER BY session_id;
