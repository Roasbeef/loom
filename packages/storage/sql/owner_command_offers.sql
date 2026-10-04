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
