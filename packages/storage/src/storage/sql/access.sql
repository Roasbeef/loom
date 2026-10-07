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
SELECT digest, principal_id, state FROM access_credentials WHERE digest = ? AND kind = ?;

-- name: AccessCredentialAnyKind :many
SELECT digest, principal_id, state FROM access_credentials WHERE digest = ?;

-- name: InsertAccessCredential :exec
INSERT INTO access_credentials(digest, principal_id, state, kind) VALUES (?, ?, 'active', ?);

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

-- name: AccessClaim :many
SELECT digest, principal_id, expires_at_ms, state, credential_digest, claimed_at_ms FROM access_claims WHERE digest = ?;

-- name: InsertAccessClaim :exec
INSERT INTO access_claims(digest, principal_id, expires_at_ms, state) VALUES (?, ?, ?, 'open');

-- name: BindAccessClaim :exec
UPDATE access_claims SET state = 'claimed', credential_digest = ?, claimed_at_ms = ? WHERE digest = ? AND state = 'open';

-- name: VoidMemberClaims :exec
UPDATE access_claims SET state = 'void' WHERE principal_id = ? AND state = 'open';

-- name: ActiveMemberCredentials :many
SELECT digest FROM access_credentials WHERE principal_id = ? AND state = 'active' LIMIT 1;

-- name: ClaimMemberships :many
SELECT session_id, role FROM access_memberships WHERE principal_id = ? ORDER BY session_id LIMIT 16;

-- name: PrincipalListing :many
SELECT principal_id, display_name, kind FROM access_principals WHERE principal_id > ? ORDER BY principal_id LIMIT 101;

-- name: PrincipalActiveCredential :many
SELECT c.digest, k.claimed_at_ms FROM access_credentials AS c
LEFT JOIN access_claims AS k ON k.credential_digest = c.digest
WHERE c.principal_id = ? AND c.state = 'active'
  AND (c.kind = 'bearer' OR k.claimed_at_ms IS NOT NULL)
  AND (c.expires_at_ms IS NULL OR c.expires_at_ms > ?)
ORDER BY c.digest LIMIT 1;

-- name: PrincipalOpenClaim :many
SELECT expires_at_ms FROM access_claims WHERE principal_id = ? AND state = 'open' LIMIT 1;

-- name: PrincipalMemberships :many
SELECT m.session_id, CAST(COALESCE(n.name, s.name) AS TEXT) AS name, m.role
FROM access_memberships AS m
JOIN catalogue_sessions AS s ON s.session_id = m.session_id
LEFT JOIN catalogue_session_names AS n ON n.session_id = s.session_id
WHERE m.principal_id = ? AND m.session_id > ?
ORDER BY m.session_id LIMIT 101;

-- Every session that has at least one member of either role
-- (protocol-change/077). One scan answers for all sessions.

-- name: MemberedSessions :many
SELECT DISTINCT session_id FROM access_memberships ORDER BY session_id;

-- Browser logins (protocol-change/065). A login's row is a credential of kind
-- 'browser': these queries name the kind, so none of them can touch a bearer.

-- name: InsertAccessLogin :exec
INSERT INTO access_credentials(digest, principal_id, state, kind, issued_at_ms, expires_at_ms)
VALUES (?, ?, 'active', 'browser', ?, ?);

-- name: InsertAccessLoginFrom :exec
INSERT INTO access_credentials(digest, principal_id, state, kind, issued_at_ms, expires_at_ms, issued_by)
VALUES (?, ?, 'active', 'browser', ?, ?, ?);

-- name: PrincipalLogins :many
SELECT digest, issued_at_ms, last_resumed_ms, expires_at_ms, issued_by FROM access_credentials
WHERE principal_id = ? AND kind = 'browser' AND state = 'active'
  AND (expires_at_ms IS NULL OR expires_at_ms > ?)
  AND substr(digest, 1, 16) > ?
ORDER BY digest LIMIT 101;

-- name: PrincipalLoginCount :one
SELECT COUNT(*) FROM access_credentials
WHERE principal_id = ? AND kind = 'browser' AND state = 'active'
  AND (expires_at_ms IS NULL OR expires_at_ms > ?);

-- name: PrincipalLoginByFingerprint :many
SELECT digest, state FROM access_credentials
WHERE principal_id = ? AND kind = 'browser' AND substr(digest, 1, 16) = ?
LIMIT 2;

-- name: RevokePrincipalLogins :exec
UPDATE access_credentials SET state = 'revoked'
WHERE principal_id = ? AND kind = 'browser' AND state = 'active';

-- name: ActiveLoginCount :one
SELECT COUNT(*) FROM access_credentials WHERE kind = 'browser' AND state = 'active';

-- name: RevokeAllLogins :exec
UPDATE access_credentials SET state = 'revoked' WHERE kind = 'browser' AND state = 'active';

-- name: LoginResumedAt :many
SELECT last_resumed_ms FROM access_credentials WHERE digest = ? AND kind = 'browser';

-- name: StampLoginResumed :exec
UPDATE access_credentials SET last_resumed_ms = ? WHERE digest = ? AND kind = 'browser';

-- name: SessionMembers :many
SELECT m.principal_id, p.display_name, m.role
FROM access_memberships AS m
JOIN access_principals AS p ON p.principal_id = m.principal_id
WHERE m.session_id = ? AND m.principal_id > ?
ORDER BY m.principal_id LIMIT 101;
