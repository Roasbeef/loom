-- Catalogue v18: why a creation's start failed. A reservation that never
-- finished is the only registration that can hold a row, and the row leaves
-- when a retry begins, when the file is confirmed, or with the registration.
-- The reason is one bounded line the registry cleaned before it was written,
-- and the time is Unix milliseconds.
CREATE TABLE catalogue_start_failures(
  session_id TEXT NOT NULL PRIMARY KEY REFERENCES catalogue_sessions(session_id),
  reason TEXT NOT NULL CHECK(length(CAST(reason AS BLOB)) BETWEEN 1 AND 512),
  failed_at INTEGER NOT NULL CHECK(failed_at >= 0)
);
