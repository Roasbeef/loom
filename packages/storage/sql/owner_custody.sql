-- Owner custody is a separate per-session database. The session schema is frozen.
CREATE TABLE owner_custody_meta (
  singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
  session_id TEXT NOT NULL,
  tool_limit INTEGER NOT NULL,
  child_limit INTEGER NOT NULL,
  byte_limit INTEGER NOT NULL,
  payload_limit INTEGER NOT NULL
);
CREATE TABLE owner_custody_tools (
  address TEXT PRIMARY KEY NOT NULL,
  identity BLOB NOT NULL,
  result_entry TEXT NOT NULL UNIQUE,
  arguments BLOB NOT NULL,
  request BLOB NOT NULL,
  outcome BLOB,
  final_profile TEXT NOT NULL CHECK(final_profile IN ('ordinary', 'code_mode_report_v1')),
  final_allowance INTEGER NOT NULL CHECK(final_allowance > 0),
  report BLOB,
  report_digest TEXT,
  run_custody TEXT NOT NULL CHECK(run_custody IN ('unreleased', 'released')),
  state TEXT NOT NULL CHECK(state IN ('retained', 'frozen')),
  reserved_bytes INTEGER NOT NULL CHECK(reserved_bytes >= 0)
);
CREATE TABLE owner_custody_children (
  origin TEXT PRIMARY KEY NOT NULL,
  parent TEXT NOT NULL,
  request_id TEXT UNIQUE,
  request BLOB NOT NULL,
  terminal BLOB,
  state TEXT NOT NULL CHECK(state IN ('retained', 'frozen', 'cancelled')),
  reserved_bytes INTEGER NOT NULL CHECK(reserved_bytes >= 0)
);
CREATE INDEX owner_custody_child_parent ON owner_custody_children(parent, origin);
-- Offers retain complete immutable service proposals, never partial native requests.
CREATE TABLE owner_custody_command_offers (
  address TEXT PRIMARY KEY NOT NULL,
  parent TEXT NOT NULL,
  service_origin TEXT NOT NULL,
  service_id TEXT NOT NULL,
  identity BLOB NOT NULL,
  native_origin TEXT NOT NULL UNIQUE,
  offer_digest TEXT NOT NULL,
  offer BLOB NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('retained', 'cancelled', 'frozen')),
  reserved_bytes INTEGER NOT NULL CHECK(reserved_bytes >= 0)
);
CREATE INDEX owner_command_offer_parent ON owner_custody_command_offers(parent, address);
CREATE INDEX owner_command_offer_service ON owner_custody_command_offers(service_origin, address);
-- Released histories never enter the index used by the startup existence probe.
CREATE INDEX owner_tool_run_custody ON owner_custody_tools(run_custody, address)
WHERE run_custody != 'released';
