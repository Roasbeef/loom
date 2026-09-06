//// Domain policy is durable metadata, not a side effect of opening a session.
//// Impossible source/destination paths prove these operations need no store I/O.

import core/clock
import core/ids
import gleam/list
import gleam/string
import simplifile
import storage/catalogue
import storage/domain
import storage/sql

pub fn generated_domain_queries_match_sqlc_input_test() {
  let assert Ok(source) = simplifile.read("src/storage/sql/domain.sql")
    as "domain query source exists"
  let generated = [
    sql.domain_by_id("").0,
    sql.domain_for_session("").0,
    sql.domain_path_conflicts("", "", "").0,
    sql.insert_domain("", "", "", "", "", "", "", "").0,
    sql.bind_session_domain("", "").0,
    sql.domain_sources("", "").0,
    sql.domain_page("").0,
  ]
  assert normalize(source) == normalize(string.join(generated, "\n"))
}

fn normalize(source: String) {
  source
  |> string.replace("@memory", "?1")
  |> string.replace("@search", "?2")
  |> string.replace("@digest", "?3")
  |> string.split("\n")
  |> list.map(string.trim)
  |> list.filter(fn(line) { line != "" && !string.starts_with(line, "--") })
  |> list.map(fn(line) {
    case string.ends_with(line, ";") {
      True -> string.drop_end(line, 1)
      False -> line
    }
  })
  |> string.join("\n")
}

fn registration(seed) {
  let #(id, _) = ids.mint_session(ids.generator(clock.fixed(1), seed))
  let id = ids.session_id_to_string(id)
  catalogue.Registration(
    id:,
    path: "/never-opened-domain/" <> id <> ".db",
    workspace: "/workspace",
    name: "Session",
    configuration: "/session-config",
    created_at: 1,
    request_key: id,
    state: catalogue.Reserved,
  )
}

fn aggregate() {
  domain.Domain(
    domain.key(domain.WorkspacePrivate, "/workspace", ""),
    domain.WorkspacePrivate,
    "/workspace",
    "/owner-domain-config",
    "/never-opened-domain/aggregate-memory.db",
    "/never-opened-domain/aggregate-search.db",
  )
}

pub fn derived_sidecar_is_an_exclusive_domain_destination_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let first = registration(40)
  let second = registration(41)
  let shared = aggregate()
  assert domain.reserve_session(store, first, shared) == Ok(first)
  let same_parent =
    domain.Domain(
      ..isolated(second),
      memory_path: "/never-opened-domain/different-memory.sqlite",
    )
  assert domain.reserve_session(store, second, same_parent)
    == Error(catalogue.Conflict)
  let aliases_digest =
    domain.Domain(
      ..isolated(second),
      index_path: domain.digest_beside(shared.memory_path),
    )
  assert domain.reserve_session(store, second, aliases_digest)
    == Error(catalogue.Conflict)
  let self_alias =
    domain.Domain(
      ..isolated(second),
      index_path: domain.digest_beside(isolated(second).memory_path),
    )
  let assert Error(catalogue.Invalid(_)) =
    domain.reserve_session(store, second, self_alias)
    as "a domain cannot overwrite its own sidecar with an index"
  assert catalogue.get(store, second.id) == Error(catalogue.Missing)
  assert catalogue.close(store) == Ok(Nil)
}

fn isolated(record: catalogue.Registration) {
  domain.Domain(
    domain.key(domain.SessionOnly, record.workspace, record.id),
    domain.SessionOnly,
    record.workspace,
    "/owner-domain-config",
    "/never-opened-domain/" <> record.id <> "/memory.db",
    "/never-opened-domain/" <> record.id <> "/search.db",
  )
}

pub fn domains_restore_metadata_and_preserve_selected_config_test() {
  let assert Ok(Nil) = simplifile.create_directory_all("build/test_db")
    as "fixture directory exists"
  let path = "build/test_db/domain-restore.db"
  let _ = simplifile.delete(path)
  let assert Ok(store) = catalogue.open(path) as "catalogue opens"
  let first = registration(1)
  let second = registration(2)
  let shared = aggregate()
  assert domain.reserve_session(store, first, shared) == Ok(first)
  assert domain.reserve_session(store, second, shared) == Ok(second)
  assert domain.sources(store, shared.id, after: "") == Ok([])
  let assert Ok(_) = catalogue.confirm(store, first.id)
    as "only initialized sources are eligible"
  assert domain.sources(store, shared.id, after: "") == Ok([first.id])
  let assert Ok(_) = catalogue.confirm(store, second.id)
    as "second source is initialized explicitly"
  assert domain.for_session(store, second.id) == Ok(shared)
  assert domain.get(store, shared.id) == Ok(shared)
  assert catalogue.close(store) == Ok(Nil)

  // Neither source nor config nor destination exists, including after restart.
  let assert Ok(store) = catalogue.open(path)
    as "metadata-only restart succeeds"
  assert domain.page(store, after: "") == Ok([shared])
  assert domain.sources(store, shared.id, after: "")
    == Ok(list.sort([first.id, second.id], string.compare))
  assert domain.for_session(store, first.id) == Ok(shared)
  let changed = domain.Domain(..shared, configuration: "/new-open-order-config")
  assert domain.bind(store, first.id, changed) == Error(catalogue.Conflict)
  assert domain.for_session(store, second.id) == Ok(shared)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn isolation_is_fresh_metadata_only_and_idempotent_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let record = registration(3)
  let shared = aggregate()
  let fresh = isolated(record)
  assert domain.reserve_session(store, record, shared) == Ok(record)
  let assert Ok(_) = catalogue.confirm(store, record.id)
    as "source is initialized"
  let assert Ok(before) = catalogue.page(store, after: "")
    as "revision can be read"
  assert domain.isolate(store, record.id, fresh) == Ok(fresh)
  let assert Ok(after) = catalogue.page(store, after: "")
    as "mapping change advances revision"
  assert after.revision == before.revision + 1
  assert domain.sources(store, shared.id, after: "") == Ok([])
  assert domain.sources(store, fresh.id, after: "") == Ok([record.id])
  assert domain.get(store, shared.id) == Ok(shared)

  // Retrying cannot rotate paths or import a changed daemon configuration.
  let retry =
    domain.Domain(
      ..fresh,
      configuration: "/changed",
      memory_path: "/changed-memory.db",
    )
  assert domain.isolate(store, record.id, retry) == Ok(fresh)
  let assert Ok(repeated) = catalogue.page(store, after: "")
    as "revision remains stable"
  assert repeated.revision == after.revision
  assert domain.for_session(store, record.id) == Ok(fresh)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn domain_mapping_rejects_aliases_cross_scope_and_rolls_back_reservation_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let first = registration(4)
  let second = registration(5)
  let shared = aggregate()
  assert domain.reserve_session(store, first, shared) == Ok(first)
  let alias = domain.Domain(..isolated(second), memory_path: shared.index_path)
  assert domain.reserve_session(store, second, alias)
    == Error(catalogue.Conflict)
  assert catalogue.get(store, second.id) == Error(catalogue.Missing)
  assert domain.for_session(store, second.id) == Error(catalogue.Missing)
  let other_scope = isolated(first)
  let assert Error(catalogue.Invalid(_)) =
    domain.reserve_session(store, second, other_scope)
    as "one session cannot enroll itself in another session-only domain"
  assert catalogue.get(store, second.id) == Error(catalogue.Missing)
  assert catalogue.close(store) == Ok(Nil)
}
