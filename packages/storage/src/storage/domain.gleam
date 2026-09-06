//// Durable memory/history scope without opening any derived store.
////
//// Domain configuration and imported paths are owner metadata selected before
//// admission. A workspace aggregate is private to the owner; a session-only
//// domain can be shared through that session's existing memberships. Isolation
//// changes only the future source/destination mapping and copies no old data.
//// The daemon must establish stopped custody and owner acknowledgement before
//// calling isolate; the DAL supplies atomicity, not process-lifetime proof.

import core/ids
import gleam/list
import gleam/result
import gleam/string
import storage/catalogue.{type Catalogue, type Error, Conflict, Invalid, Missing}
import storage/sql

/// The two supported source/reader policies; workspace membership is not access.
pub type Scope {
  /// Existing workspace aggregates remain owner-private.
  WorkspacePrivate

  /// Only one conversation contributes sources; its members may read them.
  SessionOnly
}

/// A durable domain binding with no runtime owner or opened database handles.
pub type Domain {
  Domain(
    /// Deterministic workspace or canonical session key, independent of opens.
    id: String,
    /// The source and reader policy.
    scope: Scope,
    /// Canonical workspace preserved for imported and new mappings.
    workspace: String,
    /// Captured owner configuration reference; empty explicitly means no file.
    configuration: String,
    /// Canonical memory destination, never a collaborator-supplied wire path.
    memory_path: String,
    /// Canonical index destination, separate from every other domain's files.
    index_path: String,
  )
}

/// Derives stable catalogue identity without hashing, opening, or allocating.
///
/// ## Examples
///
/// ```gleam
/// assert domain.key(domain.WorkspacePrivate, "/work", "unused") == "workspace:/work"
/// ```
pub fn key(scope: Scope, workspace: String, session_id: String) -> String {
  case scope {
    WorkspacePrivate -> "workspace:" <> workspace
    SessionOnly -> "session:" <> session_id
  }
}

/// Reads one validated domain record without touching its stored paths.
///
/// ## Examples
///
/// ```gleam
/// // domain.get(store, "workspace:/work")
/// ```
pub fn get(store: Catalogue, id: String) -> Result(Domain, Error) {
  use rows <- result.try(catalogue.query(store, sql.domain_by_id(id)))
  use row <- result.try(one(rows))
  decode(
    row.domain_id,
    row.scope,
    row.scope_key,
    row.workspace,
    row.configuration,
    row.memory_path,
    row.index_path,
    row.digest_path,
  )
}

/// Reads the exact persisted mapping of a conversation.
///
/// ## Examples
///
/// ```gleam
/// // domain.for_session(store, session_id)
/// ```
pub fn for_session(
  store: Catalogue,
  session_id: String,
) -> Result(Domain, Error) {
  use rows <- result.try(catalogue.query(
    store,
    sql.domain_for_session(session_id),
  ))
  use row <- result.try(one(rows))
  use domain <- result.try(decode(
    row.domain_id,
    row.scope,
    row.scope_key,
    row.workspace,
    row.configuration,
    row.memory_path,
    row.index_path,
    row.digest_path,
  ))
  use record <- result.try(catalogue.get(store, session_id))
  use Nil <- result.try(matches(record, domain))
  Ok(domain)
}

/// Atomically reserves a registration and its first domain mapping.
///
/// ## Examples
///
/// ```gleam
/// // domain.reserve_session(store, registration, domain_record)
/// ```
pub fn reserve_session(
  store: Catalogue,
  record: catalogue.Registration,
  domain: Domain,
) -> Result(catalogue.Registration, Error) {
  catalogue.atomic(store, fn() {
    use saved <- result.try(catalogue.reserve_in_transaction(store, record))
    use _ <- result.try(bind_initial(store, saved, domain))
    Ok(saved)
  })
}

/// Adds an explicit imported mapping to already registered metadata.
///
/// Existing mappings may be repeated exactly, never silently replaced.
///
/// ## Examples
///
/// ```gleam
/// // domain.bind(store, session_id, imported_private_domain)
/// ```
pub fn bind(
  store: Catalogue,
  session_id: String,
  domain: Domain,
) -> Result(Domain, Error) {
  catalogue.atomic(store, fn() {
    use record <- result.try(catalogue.get(store, session_id))
    bind_initial(store, record, domain)
  })
}

fn bind_initial(store, record: catalogue.Registration, domain) {
  use Nil <- result.try(matches(record, domain))
  case for_session(store, record.id) {
    Ok(existing) ->
      case existing == domain {
        True -> Ok(existing)
        False -> Error(Conflict)
      }
    Error(Missing) -> {
      use domain <- result.try(insert_domain(store, domain))
      use Nil <- result.try(catalogue.statement(
        store,
        sql.bind_session_domain(record.id, domain.id),
      ))
      use Nil <- result.try(catalogue.statement(
        store,
        sql.increment_catalogue_revision(),
      ))
      Ok(domain)
    }
    Error(error) -> Error(error)
  }
}

/// Changes a stopped session to fresh destinations without copying aggregate data.
///
/// The daemon proves stopped custody and owner transcript acknowledgement.
/// Repetition returns the original isolated record, even after daemon defaults
/// change; it never rotates paths or resets the isolated stores.
///
/// ## Examples
///
/// ```gleam
/// // domain.isolate(store, session_id, fresh_session_only_domain)
/// ```
pub fn isolate(
  store: Catalogue,
  session_id: String,
  fresh: Domain,
) -> Result(Domain, Error) {
  catalogue.atomic(store, fn() {
    use existing <- result.try(for_session(store, session_id))
    case existing.scope {
      SessionOnly -> Ok(existing)
      WorkspacePrivate -> {
        use record <- result.try(catalogue.get(store, session_id))
        use Nil <- result.try(matches(record, fresh))
        use Nil <- result.try(case fresh.scope {
          SessionOnly -> Ok(Nil)
          WorkspacePrivate ->
            Error(Invalid("isolation requires session-only scope"))
        })
        use fresh <- result.try(insert_domain(store, fresh))
        use Nil <- result.try(catalogue.statement(
          store,
          sql.bind_session_domain(session_id, fresh.id),
        ))
        use Nil <- result.try(catalogue.statement(
          store,
          sql.increment_catalogue_revision(),
        ))
        Ok(fresh)
      }
    }
  })
}

/// Lists at most one metadata page of mapped source identities.
///
/// Callers resolve registered paths separately; arbitrary history locators are
/// not a source capability. This function never inspects conversation contents.
///
/// ## Examples
///
/// ```gleam
/// // domain.sources(store, domain_id, after: "")
/// ```
pub fn sources(
  store: Catalogue,
  id: String,
  after after: String,
) -> Result(List(String), Error) {
  use domain <- result.try(get(store, id))
  use rows <- result.try(catalogue.query(store, sql.domain_sources(id, after)))
  list.try_map(rows, fn(row) {
    use record <- result.try(catalogue.get(store, row.session_id))
    use Nil <- result.try(matches(record, domain))
    Ok(record.id)
  })
}

/// Lists a bounded page of durable domain records for lazy restoration.
///
/// ## Examples
///
/// ```gleam
/// // domain.page(store, after: "")
/// ```
pub fn page(
  store: Catalogue,
  after after: String,
) -> Result(List(Domain), Error) {
  use rows <- result.try(catalogue.query(store, sql.domain_page(after)))
  list.try_map(rows, fn(row) {
    decode(
      row.domain_id,
      row.scope,
      row.scope_key,
      row.workspace,
      row.configuration,
      row.memory_path,
      row.index_path,
      row.digest_path,
    )
  })
}

fn insert_domain(store, domain: Domain) {
  use Nil <- result.try(validate(domain))
  case get(store, domain.id) {
    Ok(existing) ->
      case existing == domain {
        True -> Ok(existing)
        False -> Error(Conflict)
      }
    Error(Missing) -> insert_absent(store, domain)
    Error(error) -> Error(error)
  }
}

fn insert_absent(store, domain: Domain) {
  use conflicts <- result.try(catalogue.query(
    store,
    sql.domain_path_conflicts(
      domain.memory_path,
      domain.index_path,
      digest_beside(domain.memory_path),
    ),
  ))
  use Nil <- result.try(case conflicts {
    [] -> Ok(Nil)
    [_, ..] -> Error(Conflict)
  })
  let #(scope, scope_key) = scope_fields(domain)
  use Nil <- result.try(catalogue.statement(
    store,
    sql.insert_domain(
      domain.id,
      scope,
      scope_key,
      domain.workspace,
      domain.configuration,
      domain.memory_path,
      domain.index_path,
      digest_beside(domain.memory_path),
    ),
  ))
  Ok(domain)
}

fn matches(record: catalogue.Registration, domain: Domain) {
  use Nil <- result.try(validate(domain))
  case
    record.workspace == domain.workspace
    && domain.id == key(domain.scope, record.workspace, record.id)
  {
    True -> Ok(Nil)
    False -> Error(Invalid("domain scope does not match registration"))
  }
}

fn validate(domain: Domain) {
  use Nil <- result.try(absolute(domain.workspace))
  use Nil <- result.try(absolute(domain.memory_path))
  use Nil <- result.try(absolute(domain.index_path))
  use Nil <- result.try(case domain.configuration {
    "" -> Ok(Nil)
    path -> absolute(path)
  })
  let digest = digest_beside(domain.memory_path)
  use Nil <- result.try(absolute(digest))
  use Nil <- result.try(
    case
      domain.memory_path == domain.index_path
      || digest == domain.memory_path
      || digest == domain.index_path
    {
      True -> Error(Invalid("domain destinations must be distinct"))
      False -> Ok(Nil)
    },
  )
  case domain.scope {
    WorkspacePrivate ->
      case domain.id == key(WorkspacePrivate, domain.workspace, "") {
        True -> Ok(Nil)
        False -> Error(Invalid("invalid workspace domain identity"))
      }
    SessionOnly ->
      case domain.id {
        "session:" <> id ->
          ids.parse_session_id(id)
          |> result.replace(Nil)
          |> result.replace_error(Invalid("invalid session domain identity"))
        _other -> Error(Invalid("invalid session domain identity"))
      }
  }
}

fn absolute(path) {
  case
    string.starts_with(path, "/")
    && string.byte_size(path) <= 4096
    && !string.contains(path, "\u{0}")
  {
    True -> Ok(Nil)
    False -> Error(Invalid("expected bounded canonical absolute domain path"))
  }
}

/// Derives the existing fixed sidecar destination beside a memory database.
///
/// The derived path is persisted and collision-checked with every database
/// destination. Distinct imported filenames cannot silently share a sidecar.
///
/// ## Examples
///
/// ```gleam
/// domain.digest_beside("/work/custom.sqlite")
/// // -> "/work/loom-memory.digest"
/// ```
pub fn digest_beside(memory_path: String) -> String {
  let directory =
    memory_path
    |> string.split("/")
    |> list.reverse
    |> list.drop(1)
    |> list.reverse
    |> string.join("/")
  directory <> "/loom-memory.digest"
}

fn scope_fields(domain: Domain) {
  case domain.scope {
    WorkspacePrivate -> #("workspace_private", domain.workspace)
    SessionOnly -> #("session_only", string.drop_start(domain.id, 8))
  }
}

fn decode(
  id,
  scope,
  scope_key,
  workspace,
  configuration,
  memory_path,
  index_path,
  digest_path,
) {
  use scope <- result.try(case scope {
    "workspace_private" -> Ok(WorkspacePrivate)
    "session_only" -> Ok(SessionOnly)
    _other -> Error(Invalid("unknown persisted domain scope"))
  })
  let domain =
    Domain(id, scope, workspace, configuration, memory_path, index_path)
  use Nil <- result.try(validate(domain))
  case
    scope_fields(domain).1 == scope_key
    && digest_path == digest_beside(memory_path)
  {
    True -> Ok(domain)
    False -> Error(Invalid("domain scope key disagrees with identity"))
  }
}

fn one(rows) {
  case rows {
    [row] -> Ok(row)
    [] -> Error(Missing)
    [_, _, ..] -> Error(Invalid("expected one domain record"))
  }
}
