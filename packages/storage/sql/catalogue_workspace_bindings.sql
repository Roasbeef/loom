-- Resolved workspace authority is retained before any session startup.
ALTER TABLE catalogue_sessions ADD COLUMN workspace_binding TEXT NULL;
