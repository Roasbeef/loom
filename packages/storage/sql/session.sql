
CREATE TABLE IF NOT EXISTS entries(
  id TEXT PRIMARY KEY, parent_id TEXT, seq INTEGER, type TEXT,
  custom_type TEXT, ts INTEGER, payload BLOB) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS ix_entry_parent ON entries(parent_id);
CREATE INDEX IF NOT EXISTS ix_entry_seq ON entries(seq, type);
CREATE TABLE IF NOT EXISTS registers(
  ns TEXT NOT NULL, key TEXT NOT NULL, seq INTEGER NOT NULL,
  value BLOB NOT NULL, PRIMARY KEY(ns, key));
CREATE TABLE IF NOT EXISTS usage_ledger(
  id TEXT PRIMARY KEY, seq INTEGER, entry_id TEXT, adjustment INTEGER,
  usage BLOB, details BLOB) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS ix_usage_seq ON usage_ledger(seq);
CREATE TABLE IF NOT EXISTS branch_entries(
  branch_id TEXT, entry_id TEXT, entry_seq INTEGER, entry_type TEXT,
  PRIMARY KEY(branch_id, entry_id)) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS ix_be_seq
  ON branch_entries(branch_id, entry_seq, entry_id, entry_type);
CREATE INDEX IF NOT EXISTS ix_be_type
  ON branch_entries(branch_id, entry_type, entry_seq, entry_id);
CREATE INDEX IF NOT EXISTS ix_be_entry ON branch_entries(entry_id);
CREATE TABLE IF NOT EXISTS branch_meta(
  branch_id TEXT PRIMARY KEY, tip_entry_id TEXT, tip_seq INTEGER,
  base_branch_id TEXT, base_seq INTEGER);
CREATE UNIQUE INDEX IF NOT EXISTS ix_bm_tip ON branch_meta(tip_entry_id);
CREATE TABLE IF NOT EXISTS session(
  created_at INTEGER, parent_session_id TEXT, storage_version INTEGER,
  metadata BLOB, message_count INTEGER, usage_payload BLOB, next_seq INTEGER);
CREATE TABLE IF NOT EXISTS writer_lease(
  owner_id TEXT, fence INTEGER, expires_at_ms INTEGER);
