-- Catalogue v5: a credential's kind, so a login's row can never stand in for a bearer.
ALTER TABLE access_credentials ADD COLUMN kind TEXT NOT NULL DEFAULT 'bearer'
  CHECK(kind IN ('bearer', 'browser'));
ALTER TABLE access_credentials ADD COLUMN issued_at_ms INTEGER;
ALTER TABLE access_credentials ADD COLUMN last_resumed_ms INTEGER;
