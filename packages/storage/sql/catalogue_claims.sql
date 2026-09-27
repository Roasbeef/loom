-- Catalogue v4: single-use claim tokens, stored only as digests, that bind one credential.
CREATE TABLE access_claims(
  digest TEXT NOT NULL PRIMARY KEY
    CHECK(length(digest) = 64 AND digest NOT GLOB '*[^0-9a-f]*'),
  principal_id TEXT NOT NULL REFERENCES access_principals(principal_id),
  expires_at_ms INTEGER NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('open', 'claimed', 'void')),
  credential_digest TEXT REFERENCES access_credentials(digest),
  claimed_at_ms INTEGER,
  CHECK((state = 'claimed') = (credential_digest IS NOT NULL)),
  CHECK((state = 'claimed') = (claimed_at_ms IS NOT NULL)),
  CHECK(credential_digest IS NULL OR credential_digest != digest)
);
CREATE UNIQUE INDEX access_one_open_claim
  ON access_claims(principal_id) WHERE state = 'open';
