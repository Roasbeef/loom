//// Durable daemon registrations, separate from every conversation database.
////
//// The daemon's catalogue owner serializes these calls while holding the state
//// directory's lifetime lock. Opening this connection and listing records never
//// opens a session, acquires its writer lease, or starts recovered work. Creation
//// first reserves an identity and path; completion records that initialization
//// succeeded. A retry with the same request key returns the original reservation.
////
//// This module owns SQLite transactions and total row decoding. The daemon owns
//// path canonicalization, authorization, capacity and runtime liveness. A saved
//// record is not evidence of a resident runtime. Reserved records survive a crash
//// so reconciliation can check the original file instead of creating another.

import core/ids
import gleam/dynamic/decode
import gleam/list
import gleam/result
import gleam/string
import parrot/dev
import sqlight
import storage/sql
import storage/sql_schema
import storage/sqlite_policy

/// Metadata initialization, independent of runtime residency.
pub type State {
  /// The creation request owns this identity and path but may not have a file.
  Reserved

  /// The file's canonical identity has been verified by the daemon.
  Saved
}

/// A registration contains no provider credentials or conversation contents.
pub type Registration {
  Registration(
    /// The canonical conversation identity, also reserved before file creation.
    id: String,
    /// The host-validated canonical database path.
    path: String,
    /// The host-validated canonical working directory.
    workspace: String,
    /// A display label, never a routing or authorization identity.
    name: String,
    /// The host configuration reference, not its secret values.
    configuration: String,
    /// Creation time in Unix milliseconds.
    created_at: Int,
    /// The immutable creation request key.
    request_key: String,
    /// Whether database initialization has been confirmed.
    state: State,
  )
}

/// An open metadata connection, owned by the daemon's catalogue lifetime.
pub opaque type Catalogue {
  Catalogue(connection: sqlight.Connection)
}

/// Catalogue failures never authorize modifying the conversation file.
pub type Error {
  /// An unsupported or unrelated database was supplied as the catalogue.
  Unsupported

  /// Input metadata or a persisted record failed validation.
  Invalid(reason: String)

  /// A unique key conflicts, or a default selects another workspace's session.
  Conflict

  /// No registration has this identity.
  Missing

  /// SQLite could not complete the operation.
  Database(reason: String)
}

/// A bounded page and the revision against which it was read.
pub type Page {
  Page(
    /// Changes to durable registrations increment this revision.
    revision: Int,
    /// At most `page_limit` records, sorted by canonical identity.
    records: List(Registration),
  )
}

/// The largest list response; callers continue after the last returned ID.
pub const page_limit = 100

/// Opens only the metadata database, initializing an empty file or refusing it.
///
/// The parent directory must already be private and protected from model writes.
/// The caller holds the daemon lifetime lock until this connection is closed.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.open(state_root <> "/catalogue.db")
/// ```
pub fn open(path: String) -> Result(Catalogue, Error) {
  use connection <- result.try(
    sqlight.open(path) |> result.map_error(sql_error),
  )
  case initialize(connection) {
    Ok(Nil) -> Ok(Catalogue(connection))
    Error(error) -> {
      let _closed = sqlight.close(connection)
      Error(error)
    }
  }
}

fn initialize(connection: sqlight.Connection) -> Result(Nil, Error) {
  let defaults = sqlite_policy.defaults()
  let options =
    sqlite_policy.Options(..defaults, foreign_keys: sqlite_policy.Enabled)
  use Nil <- result.try(
    sqlite_policy.configure_connection(connection, options)
    |> result.map_error(sql_error),
  )
  use Nil <- result.try(initialize_schema(connection))
  sqlite_policy.configure_database(connection, options)
  |> result.map_error(sql_error)
}

// Journal configuration follows schema validation, so an unrelated file is
// refused before any persistent tuning can change its header.
fn initialize_schema(connection: sqlight.Connection) -> Result(Nil, Error) {
  use found <- result.try(number(connection, "PRAGMA application_id"))
  use version <- result.try(number(connection, "PRAGMA user_version"))
  case found, version {
    1_281_253_197, 1 -> {
      use _revision <- result.try(revision(Catalogue(connection)))
      Ok(Nil)
    }
    0, 0 -> {
      use tables <- result.try(number(connection, "PRAGMA schema_version"))
      case tables {
        0 ->
          transaction(connection, fn() {
            use Nil <- result.try(execute(connection, sql_schema.schema))
            use Nil <- result.try(statement(
              Catalogue(connection),
              sql.initialize_catalogue_revision(),
            ))
            execute(
              connection,
              "PRAGMA application_id=1281253197; PRAGMA user_version=1",
            )
          })
        _ -> Error(Unsupported)
      }
    }
    _, _ -> Error(Unsupported)
  }
}

/// Reserves a creation exactly once without touching its conversation file.
///
/// Retrying the same key and metadata returns the stored record, including a
/// completed state. A conflicting key or a second identity for one path fails.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.reserve(catalogue, record)
/// ```
pub fn reserve(
  catalogue: Catalogue,
  record: Registration,
) -> Result(Registration, Error) {
  transaction(catalogue.connection, fn() {
    reserve_in_transaction(catalogue, record)
  })
}

/// Reserves metadata inside the caller's existing immediate transaction.
///
/// Domain creation uses this seam so a registration and its mapping commit
/// together. It must never be called outside an enclosing catalogue transaction.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.atomic(store, fn() { catalogue.reserve_in_transaction(store, record) })
/// ```
@internal
pub fn reserve_in_transaction(
  catalogue: Catalogue,
  record: Registration,
) -> Result(Registration, Error) {
  use Nil <- result.try(validate(record))
  use existing <- result.try(find(catalogue, "", record.request_key, ""))
  reserve_record(catalogue, record, existing)
}

fn reserve_record(
  catalogue: Catalogue,
  record: Registration,
  existing: List(Registration),
) {
  case existing {
    [old] -> {
      case
        Registration(..old, state: Reserved)
        == Registration(..record, state: Reserved)
      {
        True -> Ok(old)
        False -> Error(Conflict)
      }
    }
    [] -> {
      use conflicts <- result.try(find(catalogue, record.id, "", record.path))
      case conflicts {
        [] -> insert(catalogue, Registration(..record, state: Reserved))
        [_, ..] -> Error(Conflict)
      }
    }
    [_, _, ..] -> Error(Invalid("duplicate creation key"))
  }
}

fn insert(
  catalogue: Catalogue,
  record: Registration,
) -> Result(Registration, Error) {
  use Nil <- result.try(statement(
    catalogue,
    sql.insert_registration(
      session_id: record.id,
      path: record.path,
      workspace: record.workspace,
      name: record.name,
      configuration: record.configuration,
      created_at: record.created_at,
      request_key: record.request_key,
    ),
  ))
  use Nil <- result.try(statement(catalogue, sql.increment_catalogue_revision()))
  Ok(record)
}

/// Confirms that the daemon verified the reserved file's canonical identity.
///
/// A repeated confirmation is a no-op and does not invalidate list cursors.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.confirm(catalogue, session_id)
/// ```
pub fn confirm(
  catalogue: Catalogue,
  id: String,
) -> Result(Registration, Error) {
  transaction(catalogue.connection, fn() {
    use record <- result.try(get(catalogue, id))
    case record.state {
      Saved -> Ok(record)
      Reserved -> {
        use Nil <- result.try(statement(catalogue, sql.confirm_registration(id)))
        use Nil <- result.try(statement(
          catalogue,
          sql.increment_catalogue_revision(),
        ))
        Ok(Registration(..record, state: Saved))
      }
    }
  })
}

/// Looks up metadata without opening the referenced database.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.get(catalogue, session_id)
/// ```
pub fn get(catalogue: Catalogue, id: String) -> Result(Registration, Error) {
  use found <- result.try(find(catalogue, id, "", ""))
  case found {
    [record] -> Ok(record)
    [] -> Error(Missing)
    [_, _, ..] -> Error(Invalid("duplicate session identity"))
  }
}

/// Recovers the original reservation before a creation retry mints anything.
///
/// The daemon compares caller-supplied metadata with this record, then reuses
/// its identity, path and creation time. `Missing` alone permits a fresh
/// reservation; a decode or database error must not trigger another creation.
/// This lookup never opens the registered conversation file.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.by_request_key(catalogue, request_key)
/// ```
pub fn by_request_key(
  catalogue: Catalogue,
  request_key: String,
) -> Result(Registration, Error) {
  use found <- result.try(find(catalogue, "", request_key, ""))
  case found {
    [record] -> Ok(record)
    [] -> Error(Missing)
    [_, _, ..] -> Error(Invalid("duplicate creation key"))
  }
}

/// Reads the workspace's durable default without opening its conversation.
///
/// Missing mappings return `Missing`. A dangling mapping or a registration from
/// another workspace is invalid metadata, never a candidate to start. A reserved
/// registration remains reserved; the default does not claim initialization.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.workspace_default(catalogue, workspace)
/// ```
pub fn workspace_default(
  catalogue: Catalogue,
  workspace: String,
) -> Result(Registration, Error) {
  snapshot(catalogue.connection, fn() {
    use id <- result.try(default_identity(catalogue, workspace))
    use record <- result.try(
      get(catalogue, id)
      |> result.map_error(fn(error) {
        case error {
          Missing -> Invalid("workspace default refers to a missing session")
          other -> other
        }
      }),
    )
    case record.workspace == workspace {
      True -> Ok(record)
      False -> Error(Invalid("workspace default refers to another workspace"))
    }
  })
}

/// Selects a registered session in this workspace as its durable default.
///
/// The mapping and revision update commit together. Selecting the current
/// identity writes nothing and leaves pagination revisions unchanged. Neither
/// selection nor validation opens a conversation or changes runtime residency.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.set_workspace_default(catalogue, workspace, session_id)
/// ```
pub fn set_workspace_default(
  catalogue: Catalogue,
  workspace: String,
  id: String,
) -> Result(Registration, Error) {
  transaction(catalogue.connection, fn() {
    use record <- result.try(get(catalogue, id))
    use Nil <- result.try(case record.workspace == workspace {
      True -> Ok(Nil)
      False -> Error(Conflict)
    })
    case default_identity(catalogue, workspace) {
      Ok(current) if current == id -> Ok(record)
      Ok(_) | Error(Missing) -> {
        use Nil <- result.try(statement(
          catalogue,
          sql.set_workspace_default(workspace, id),
        ))
        use Nil <- result.try(statement(
          catalogue,
          sql.increment_catalogue_revision(),
        ))
        Ok(record)
      }
      Error(error) -> Error(error)
    }
  })
}

fn default_identity(
  catalogue: Catalogue,
  workspace: String,
) -> Result(String, Error) {
  use rows <- result.try(query(catalogue, sql.workspace_default(workspace)))
  case rows {
    [sql.WorkspaceDefault(id)] -> Ok(id)
    [] -> Error(Missing)
    [_, _, ..] -> Error(Invalid("duplicate workspace default"))
  }
}

/// Lists one identity-ordered metadata page from a coherent SQLite snapshot.
///
/// Use an empty `after` for the first page. Restart pagination if a subsequent
/// page has a different revision. No page scan opens conversation databases.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.page(catalogue, after: "")
/// ```
pub fn page(catalogue: Catalogue, after after: String) -> Result(Page, Error) {
  snapshot(catalogue.connection, fn() {
    use revision <- result.try(revision(catalogue))
    use rows <- result.try(query(catalogue, sql.registration_page(after)))
    use records <- result.try(
      list.try_map(rows, fn(row) {
        decoded(
          Registration(
            id: row.session_id,
            path: row.path,
            workspace: row.workspace,
            name: row.name,
            configuration: row.configuration,
            created_at: row.created_at,
            request_key: row.request_key,
            state: Reserved,
          ),
          row.state,
        )
      }),
    )
    Ok(Page(revision:, records:))
  })
}

fn revision(catalogue: Catalogue) -> Result(Int, Error) {
  use rows <- result.try(query(catalogue, sql.catalogue_revision()))
  case rows {
    [sql.CatalogueRevision(revision)] -> Ok(revision)
    [] | [_, _, ..] -> Error(Invalid("expected one catalogue revision"))
  }
}

/// Lists only registrations with a valid membership for this principal.
///
/// Authorization precedes pagination in SQL, so neither an empty filtered page
/// nor its continuation identity reveals an unrelated registration. This is an
/// internal read capability; the daemon authenticates the credential on each
/// page. The global revision can reveal metadata activity, not hidden identities.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.member_page(store, principal.id, after: "")
/// ```
@internal
pub fn member_page(
  catalogue: Catalogue,
  principal_id: String,
  after after: String,
) -> Result(Page, Error) {
  snapshot(catalogue.connection, fn() {
    use revision <- result.try(revision(catalogue))
    use rows <- result.try(query(
      catalogue,
      sql.member_registration_page(principal_id, after),
    ))
    use records <- result.try(
      list.try_map(rows, fn(row) {
        decoded(
          Registration(
            id: row.session_id,
            path: row.path,
            workspace: row.workspace,
            name: row.name,
            configuration: row.configuration,
            created_at: row.created_at,
            request_key: row.request_key,
            state: Reserved,
          ),
          row.state,
        )
      }),
    )
    Ok(Page(revision:, records:))
  })
}

/// Closes the metadata connection without stopping or opening any session.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.close(catalogue)
/// ```
pub fn close(catalogue: Catalogue) -> Result(Nil, Error) {
  sqlight.close(catalogue.connection) |> result.map_error(sql_error)
}

// The three unique keys share a generated row type. Empty arguments exclude
// unused keys because valid registrations cannot contain an empty key or path.
fn find(catalogue: Catalogue, id: String, request_key: String, path: String) {
  use rows <- result.try(query(
    catalogue,
    sql.find_registrations(id, request_key, path),
  ))
  list.try_map(rows, fn(row) {
    decoded(
      Registration(
        id: row.session_id,
        path: row.path,
        workspace: row.workspace,
        name: row.name,
        configuration: row.configuration,
        created_at: row.created_at,
        request_key: row.request_key,
        state: Reserved,
      ),
      row.state,
    )
  })
}

fn decoded(record: Registration, state: String) -> Result(Registration, Error) {
  use Nil <- result.try(validate(record))
  case state {
    "reserved" -> Ok(record)
    "saved" -> Ok(Registration(..record, state: Saved))
    _ -> Error(Invalid("unknown registration state"))
  }
}

/// Runs a generated internal query on the catalogue's existing connection.
/// The daemon still owns serialization; this creates no second connection.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.query(store, sql.access_owner())
/// ```
@internal
pub fn query(
  catalogue: Catalogue,
  generated: #(String, List(dev.Param), decode.Decoder(a)),
) {
  let #(text, params, decoder) = generated
  use arguments <- result.try(list.try_map(params, parameter))
  sqlight.query(
    text,
    on: catalogue.connection,
    with: arguments,
    expecting: decoder,
  )
  |> result.map_error(sql_error)
}

/// Runs a generated internal statement under the catalogue's current owner.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.statement(store, sql.revoke_access_credential(digest))
/// ```
@internal
pub fn statement(catalogue: Catalogue, generated: #(String, List(dev.Param))) {
  let #(text, params) = generated
  query(catalogue, #(text, params, decode.success(Nil))) |> result.replace(Nil)
}

// These queries use only non-null strings and integers. A future generator
// change must add an explicit conversion instead of silently binding NULL.
fn parameter(param: dev.Param) -> Result(sqlight.Value, Error) {
  case param {
    dev.ParamInt(value) -> Ok(sqlight.int(value))
    dev.ParamString(value) -> Ok(sqlight.text(value))
    dev.ParamFloat(_)
    | dev.ParamBool(_)
    | dev.ParamBitArray(_)
    | dev.ParamTimestamp(_)
    | dev.ParamDate(_)
    | dev.ParamList(_)
    | dev.ParamDynamic(_)
    | dev.ParamNullable(_) ->
      Error(Invalid("unsupported generated catalogue parameter"))
  }
}

fn validate(record: Registration) -> Result(Nil, Error) {
  use _id <- result.try(
    ids.parse_session_id(record.id)
    |> result.replace_error(Invalid("invalid canonical session ID")),
  )
  case
    string.starts_with(record.path, "/")
    && string.starts_with(record.workspace, "/")
    && record.request_key != ""
    && record.created_at >= 0
  {
    True -> Ok(Nil)
    False ->
      Error(Invalid(
        "registration needs absolute paths, a request key and a nonnegative creation time",
      ))
  }
}

fn number(connection: sqlight.Connection, sql: String) -> Result(Int, Error) {
  use values <- result.try(
    sqlight.query(
      sql,
      on: connection,
      with: [],
      expecting: decode.at([0], decode.int),
    )
    |> result.map_error(sql_error),
  )
  case values {
    [value] -> Ok(value)
    [] | [_, _, ..] -> Error(Invalid("expected one catalogue metadata row"))
  }
}

fn transaction(
  connection: sqlight.Connection,
  run: fn() -> Result(a, Error),
) -> Result(a, Error) {
  transact(connection, Write, run)
}

// Generated query cardinality is not transaction intent: writes may return rows.
// Read-only compound reads take a coherent snapshot without reserving the writer.
type Intent {
  Read
  Write
}

fn snapshot(
  connection: sqlight.Connection,
  run: fn() -> Result(a, Error),
) -> Result(a, Error) {
  transact(connection, Read, run)
}

fn transact(
  connection: sqlight.Connection,
  intent: Intent,
  run: fn() -> Result(a, Error),
) -> Result(a, Error) {
  let begin = case intent {
    Read -> "BEGIN DEFERRED"
    Write -> "BEGIN IMMEDIATE"
  }
  use Nil <- result.try(execute(connection, begin))
  let outcome =
    run()
    |> result.try(fn(value) {
      execute(connection, "COMMIT") |> result.replace(value)
    })
  case outcome {
    Ok(value) -> Ok(value)
    Error(error) -> {
      let _rolled_back = execute(connection, "ROLLBACK")
      Error(error)
    }
  }
}

/// Groups internal catalogue changes in one immediate transaction.
/// Callers must not nest this within another catalogue transaction.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.atomic(store, fn() { rotate_credential_rows(store) })
/// ```
@internal
pub fn atomic(
  catalogue: Catalogue,
  run: fn() -> Result(a, Error),
) -> Result(a, Error) {
  transaction(catalogue.connection, run)
}

fn execute(connection: sqlight.Connection, sql: String) -> Result(Nil, Error) {
  sqlight.exec(sql, on: connection) |> result.map_error(sql_error)
}

fn sql_error(error: sqlight.Error) -> Error {
  Database(string.inspect(error))
}
