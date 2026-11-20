-- Catalogue v23: a principal's passkeys (protocol-change/127), one row per WebAuthn credential the owner registered from a fresh home.
CREATE TABLE access_passkeys(
  credential_id TEXT NOT NULL PRIMARY KEY
    CHECK(length(credential_id) BETWEEN 16 AND 512 AND credential_id NOT GLOB '*[^A-Za-z0-9_-]*'),
  principal_id TEXT NOT NULL REFERENCES access_principals(principal_id),
  public_key TEXT NOT NULL
    CHECK(length(public_key) = 122 AND public_key NOT GLOB '*[^A-Za-z0-9_-]*'),
  sign_count INTEGER NOT NULL CHECK(sign_count >= 0 AND sign_count <= 4294967295),
  label TEXT NOT NULL CHECK(length(label) BETWEEN 1 AND 32),
  created_at_ms INTEGER NOT NULL,
  last_used_ms INTEGER
);
CREATE INDEX access_passkeys_principal ON access_passkeys(principal_id, created_at_ms);
