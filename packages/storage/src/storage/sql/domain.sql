-- Domain paths/configuration are owner metadata, never collaborator wire fields.

-- name: DomainById :many
SELECT domain_id, scope, scope_key, workspace, configuration, memory_path, index_path, digest_path
FROM catalogue_domains WHERE domain_id = ?;

-- name: DomainForSession :many
SELECT d.domain_id, d.scope, d.scope_key, d.workspace, d.configuration, d.memory_path, d.index_path, d.digest_path
FROM catalogue_domain_sessions AS s JOIN catalogue_domains AS d ON d.domain_id = s.domain_id
WHERE s.session_id = ?;

-- name: DomainPathConflicts :many
SELECT domain_id FROM catalogue_domains
WHERE memory_path IN (@memory, @search, @digest)
OR index_path IN (@memory, @search, @digest)
OR digest_path IN (@memory, @search, @digest) LIMIT 2;

-- name: InsertDomain :exec
INSERT INTO catalogue_domains(domain_id, scope, scope_key, workspace, configuration, memory_path, index_path, digest_path)
VALUES (?, ?, ?, ?, ?, ?, ?, ?);

-- name: BindSessionDomain :exec
INSERT INTO catalogue_domain_sessions(session_id, domain_id) VALUES (?, ?)
ON CONFLICT(session_id) DO UPDATE SET domain_id = excluded.domain_id;

-- name: DomainSources :many
SELECT s.session_id FROM catalogue_domain_sessions AS s
JOIN catalogue_sessions AS r ON r.session_id = s.session_id
WHERE s.domain_id = ? AND s.session_id > ? AND r.state = 'saved'
ORDER BY s.session_id LIMIT 100;

-- name: DomainPage :many
SELECT domain_id, scope, scope_key, workspace, configuration, memory_path, index_path, digest_path
FROM catalogue_domains WHERE domain_id > ? ORDER BY domain_id LIMIT 100;
