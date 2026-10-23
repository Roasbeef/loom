//// Native transition metadata never crosses the authored message boundary.
//// A restore document exists only during an unpublished transaction; operator
//// rollback supplies no restore document and migrates the current live state.

import ext/live
import gleam/option.{type Option}

/// A trusted state and callback transition sent through standard sys.
pub type Change {
  Change(
    /// The complete newly loaded callback bundle.
    definition: live.Definition,
    /// The resulting state schema identity.
    version: String,
    /// The already loaded effect-free migration module.
    migration: String,
    /// A temporary compensation document, absent for ordinary migrations.
    restore: Option(String),
  )
}
