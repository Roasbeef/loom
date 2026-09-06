-- Internal access queries. Only credential digests cross this boundary.

-- name: AccessOwner :many
SELECT principal_id, display_name, kind FROM access_principals WHERE kind = 'owner' LIMIT 2;

-- name: AccessPrincipal :many
SELECT principal_id, display_name, kind FROM access_principals WHERE principal_id = ?;

-- name: InsertAccessPrincipal :exec
INSERT INTO access_principals(principal_id, display_name, kind) VALUES (?, ?, ?);

-- name: RenameAccessPrincipal :exec
UPDATE access_principals SET display_name = ? WHERE principal_id = ?;

-- name: AccessCredential :many
SELECT digest, principal_id, state FROM access_credentials WHERE digest = ?;

-- name: InsertAccessCredential :exec
INSERT INTO access_credentials(digest, principal_id, state) VALUES (?, ?, 'active');

-- name: RevokeAccessCredential :exec
UPDATE access_credentials SET state = 'revoked' WHERE digest = ?;

-- name: RevokeMemberCredentials :exec
UPDATE access_credentials SET state = 'revoked' WHERE principal_id = ? AND state = 'active';

-- name: AccessMembership :many
SELECT role FROM access_memberships WHERE principal_id = ? AND session_id = ?;

-- name: GrantAccessMembership :exec
INSERT INTO access_memberships(principal_id, session_id, role) VALUES (?, ?, ?)
ON CONFLICT(principal_id, session_id) DO UPDATE SET role = excluded.role;

-- name: RevokeAccessMembership :exec
DELETE FROM access_memberships WHERE principal_id = ? AND session_id = ?;
