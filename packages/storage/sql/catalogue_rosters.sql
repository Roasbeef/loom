-- Catalogue v4: a session's tool roster is creation metadata, not a label.
-- The empty word means the session inherits the daemon's configured default,
-- which is what every registration written before this column said.
ALTER TABLE catalogue_sessions
  ADD COLUMN roster TEXT NOT NULL DEFAULT '' CHECK(roster IN ('', 'minimal', 'full'));
