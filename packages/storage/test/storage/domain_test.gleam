//// Domain policy is durable metadata, not a side effect of opening a session.
//// Impossible source/destination paths prove these operations need no store I/O.

import core/clock
import core/ids
import gleam/dynamic/decode
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import parrot/dev
import simplifile
import storage/catalogue
import storage/domain
import storage/sql
import support/fixtures

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
    profile: option.None,
    model: option.None,
    executor: "",
    pool: "",
    subtitle: option.None,
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
  let path = fixtures.scratch("domain-restore") <> "/catalogue.db"
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

pub fn a_registered_session_holds_only_a_session_only_domain_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let record =
    catalogue.Registration(
      ..registration(6),
      workspace: "loom-checkout",
      executor: "build-box",
      pool: "",
    )

  // The workspace aggregate is keyed by the workspace text alone, and two
  // executors may register the same name, so a name cannot key one.
  let aggregate_by_name =
    domain.Domain(
      ..aggregate(),
      id: domain.key(domain.WorkspacePrivate, "loom-checkout", ""),
      workspace: "loom-checkout",
    )
  let assert Error(catalogue.Invalid(_)) =
    domain.reserve_session(store, record, aggregate_by_name)
    as "a registered name is not a path"
  assert catalogue.get(store, record.id) == Error(catalogue.Missing)

  // A session-only domain keeps the name beside its own destinations.
  let own = isolated(record)
  assert domain.reserve_session(store, record, own) == Ok(record)
  assert domain.for_session(store, record.id) == Ok(own)
  assert catalogue.close(store) == Ok(Nil)
}

// --- importing a session another orchestrator handed over --------------------

const import_op = "0192f3c1-7b0e-7d2a-9c11-4f5a6b7c8d9e"

const import_other_op = "0192f3c1-7b0e-7d2a-9c11-4f5a6b7c8d9f"

// A session registered on an executor, with its session-only domain, as an
// importing orchestrator builds them from a manifest.
fn handed_over(seed) -> #(catalogue.Registration, domain.Domain) {
  let base = registration(seed)
  let record =
    catalogue.Registration(
      ..base,
      workspace: "repo",
      configuration: "",
      executor: "box",
    )
  let mapping =
    domain.Domain(
      domain.key(domain.SessionOnly, "repo", record.id),
      domain.SessionOnly,
      "repo",
      "",
      "/never-opened-domain/" <> record.id <> "-memory.db",
      "/never-opened-domain/" <> record.id <> "-search.db",
    )
  #(record, mapping)
}

pub fn a_first_import_registers_confirms_and_records_the_session_together_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let #(record, mapping) = handed_over(50)
  let imported = catalogue.Imported(op: import_op, from: "desk")
  assert domain.import_session(
      store,
      record,
      mapping,
      op: import_op,
      from: "desk",
    )
    == Ok(imported)

  // The registration is saved and not reserved, since the file behind it was
  // verified, its mapping is bound, and the import row names its source.
  assert catalogue.get(store, record.id)
    == Ok(catalogue.Registration(..record, state: catalogue.Saved))
  assert domain.for_session(store, record.id) == Ok(mapping)
  assert catalogue.custody(store, record.id) == Ok(imported)

  // A repeat of the same move answers the stored custody and writes nothing.
  let assert Ok(before) = catalogue.page(store, after: "")
  assert domain.import_session(
      store,
      record,
      mapping,
      op: import_op,
      from: "desk",
    )
    == Ok(imported)
  let assert Ok(after) = catalogue.page(store, after: "")
  assert after.revision == before.revision
}

pub fn a_refused_import_leaves_no_registration_behind_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let #(record, mapping) = handed_over(51)

  // A malformed op fails the custody step, after the registration and the
  // mapping were staged. Nothing of either remains.
  let assert Error(catalogue.Invalid(_)) =
    domain.import_session(store, record, mapping, op: "a b", from: "desk")
  assert catalogue.get(store, record.id) == Error(catalogue.Missing)
  assert domain.for_session(store, record.id) == Error(catalogue.Missing)

  // The same registration imports cleanly afterwards.
  let assert Ok(_) =
    domain.import_session(store, record, mapping, op: import_op, from: "desk")
  assert catalogue.get(store, record.id)
    == Ok(catalogue.Registration(..record, state: catalogue.Saved))
}

pub fn a_session_that_comes_back_keeps_its_registration_and_mapping_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let #(record, mapping) = handed_over(52)
  let assert Ok(saved) = catalogue.reserve(store, record)
  let assert Ok(_) = domain.bind(store, saved.id, mapping)
  let assert Ok(_) = catalogue.confirm(store, saved.id)
  let assert Ok(_) =
    catalogue.begin_move(store, saved.id, op: import_op, to: "desk")
  let assert Ok(_) = catalogue.finish_move(store, saved.id, op: import_op)

  // The record and mapping the caller passes are not applied: the ones the
  // catalogue kept from before the session left are. Only the row changes,
  // and the move that gave the session up cannot bring it back.
  let different =
    catalogue.Registration(..record, name: "built from a manifest")
  assert domain.import_session(
      store,
      different,
      mapping,
      op: import_op,
      from: "desk",
    )
    == Error(catalogue.Conflict)
  let imported = catalogue.Imported(op: import_other_op, from: "desk")
  assert domain.import_session(
      store,
      different,
      mapping,
      op: import_other_op,
      from: "desk",
    )
    == Ok(imported)
  let assert Ok(kept) = catalogue.get(store, record.id)
  assert kept.name == record.name
  assert catalogue.custody(store, record.id) == Ok(imported)
}

/// Source projection returns the same validated metadata as fresh point reads.
pub fn source_records_preserve_validation_display_and_fresh_paths_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let first = registration(90)
  let second = registration(91)
  let shared = aggregate()
  assert domain.reserve_session(store, first, shared) == Ok(first)
  assert domain.reserve_session(store, second, shared) == Ok(second)
  let assert Ok(_) = catalogue.confirm(store, first.id)
    as "first source is saved"
  assert domain.source_records(store, shared.id, after: "")
    == catalogue.get(store, first.id) |> result.map(fn(record) { [record] })
  let assert Ok(_) = catalogue.rename(store, first.id, "Current display")
    as "the display layer changes independently of creation metadata"
  let assert Ok(_) =
    catalogue.seed_subtitle(store, first.id, "Current subtitle")
    as "the subtitle layer is seeded independently"
  assert domain.source_records(store, shared.id, after: "")
    == catalogue.get(store, first.id) |> result.map(fn(record) { [record] })

  // A following read must observe a changed path without reopening the domain.
  assert replace_field(store, first.id, "path", "/changed-source.db") == Ok(Nil)
  let assert Ok([changed]) = domain.source_records(store, shared.id, after: "")
    as "one saved source remains"
  assert changed.path == "/changed-source.db"
  assert changed.name == "Current display"
  assert changed.subtitle == option.Some("Current subtitle")
  assert domain.sources(store, shared.id, after: "") == Ok([first.id])

  // Unconfirmed sources remain excluded even when their metadata is corrupt.
  assert replace_field(store, second.id, "profile", "INVALID") == Ok(Nil)
  assert domain.source_records(store, shared.id, after: "") == Ok([changed])
  assert catalogue.delete(store, first.id) == Ok(changed)
  assert domain.source_records(store, shared.id, after: "") == Ok([])
  assert catalogue.close(store) == Ok(Nil)
}

/// Joined source rows still cross the complete registration and domain checks.
pub fn source_records_refuse_corrupt_registration_and_wrong_domain_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let record = registration(92)
  let shared = aggregate()
  assert domain.reserve_session(store, record, shared) == Ok(record)
  let assert Ok(_) = catalogue.confirm(store, record.id)
    as "the source is saved"

  list.each(
    [
      #("profile", "INVALID", ""),
      #("path", "relative.db", record.path),
      #("executor", "INVALID", ""),
    ],
    fn(change) {
      let #(field, corrupt, restore) = change
      assert replace_field(store, record.id, field, corrupt) == Ok(Nil)
      let assert Error(expected) = catalogue.get(store, record.id)
        as "the ordinary registration boundary refuses corruption"
      assert domain.source_records(store, shared.id, after: "")
        == Error(expected)
      assert replace_field(store, record.id, field, restore) == Ok(Nil)
    },
  )

  // A valid registration for another workspace cannot become this domain's
  // source merely because a stored mapping points at it.
  assert replace_field(store, record.id, "workspace", "/other-workspace")
    == Ok(Nil)
  assert domain.source_records(store, shared.id, after: "")
    == Error(catalogue.Invalid("domain scope does not match registration"))
  assert domain.source_records(store, "workspace:/missing", after: "")
    == Error(catalogue.Missing)
  assert catalogue.close(store) == Ok(Nil)
}

/// Full pages advance in identity order, without treating a page as a total cap.
pub fn source_records_keep_the_hundred_row_page_boundary_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let shared = aggregate()
  let expected =
    list.index_map(list.repeat(Nil, 101), fn(_, index) {
      let record = registration(10_000 + index)
      assert domain.reserve_session(store, record, shared) == Ok(record)
      let assert Ok(saved) = catalogue.confirm(store, record.id)
        as "every source is explicitly initialized"
      saved
    })
    |> list.sort(fn(left, right) { string.compare(left.id, right.id) })
  let assert Ok(first) = domain.source_records(store, shared.id, after: "")
    as "the first page succeeds"
  assert first == list.take(expected, 100)
  let assert Ok(last) = list.last(first) as "the first page is full"
  assert domain.source_records(store, shared.id, after: last.id)
    == Ok(list.drop(expected, 100))
  assert catalogue.close(store) == Ok(Nil)
}

/// Changes fixture metadata through the existing catalogue connection only.
fn replace_field(
  store: catalogue.Catalogue,
  id: String,
  field: String,
  value: String,
) -> Result(Nil, catalogue.Error) {
  catalogue.query(store, #(
    "UPDATE catalogue_sessions SET " <> field <> " = ? WHERE session_id = ?",
    [dev.ParamString(value), dev.ParamString(id)],
    decode.success(Nil),
  ))
  |> result.replace(Nil)
}

/// A malformed domain is refused before even an empty source page is returned.
pub fn source_records_validate_the_domain_once_even_without_saved_sources_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let record = registration(93)
  let shared = aggregate()
  assert domain.reserve_session(store, record, shared) == Ok(record)
  let assert Ok(_) =
    catalogue.query(store, #(
      "UPDATE catalogue_domains SET memory_path = ? WHERE domain_id = ?",
      [dev.ParamString("relative.db"), dev.ParamString(shared.id)],
      decode.success(Nil),
    ))
    as "the fixture corrupts stored domain metadata"
  let assert Error(expected) = domain.get(store, shared.id)
    as "the persisted domain is invalid"
  assert domain.source_records(store, shared.id, after: "") == Error(expected)
  assert catalogue.close(store) == Ok(Nil)
}
