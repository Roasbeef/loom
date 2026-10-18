-- Catalogue v17: what a spawner has spent on this daemon (protocol-change/084,
-- phase 2). One row holds the tokens the spawner's children used, and the spawns
-- admitted for it, during one hour. The hour is Unix milliseconds divided by
-- 3,600,000, so a rolling day is the 24 newest hours and needs no clock beyond
-- the one that wrote the rows. The spawner is the key of a [spawners.<name>]
-- table. A row names no session: the spend outlives the delegate sessions it was
-- made in, which is what lets a day cap bind a spawner that opens a fresh
-- session for every parent.
CREATE TABLE catalogue_spawner_spend(
  spawner TEXT NOT NULL CHECK(length(CAST(spawner AS BLOB)) BETWEEN 1 AND 32),
  hour_bucket INTEGER NOT NULL CHECK(hour_bucket >= 0),
  tokens INTEGER NOT NULL CHECK(tokens >= 0),
  spawns INTEGER NOT NULL CHECK(spawns >= 0),
  PRIMARY KEY (spawner, hour_bucket)
);
