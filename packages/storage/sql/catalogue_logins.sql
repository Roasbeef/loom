-- Catalogue v7: a login's own expiry, and the fingerprint of the login whose device link made it.
ALTER TABLE access_credentials ADD COLUMN expires_at_ms INTEGER;
ALTER TABLE access_credentials ADD COLUMN issued_by TEXT
  CHECK(issued_by IS NULL OR (length(issued_by) = 16 AND issued_by NOT GLOB '*[^0-9a-f]*'));
