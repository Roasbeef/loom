//// Real catalogue rows retain authority independently of default grouping.

import core/clock
import core/ids
import core/json
import core/workspace
import gleam/list
import gleam/option.{Some}
import gleam/result
import simplifile
import sqlight
import storage/catalogue
import storage/domain
import storage/sql
import support/fixtures

fn bound(epoch: Int) -> workspace.Binding {
  let assert Ok(selected) = workspace.selector("linux", "project")
    as "selector is valid"
  let assert Ok(binding) =
    workspace.registered_binding(selected, epoch, epoch + 1)
    as "epochs are valid"
  workspace.Registered(binding)
}

fn record(seed: Int, epoch: Int) -> catalogue.Registration {
  let #(id, _) = ids.mint_session(ids.generator(clock.fixed(1), seed))
  let id = ids.session_id_to_string(id)
  catalogue.Registration(
    id,
    "/never-opened/" <> id <> ".db",
    bound(epoch),
    "Session",
    "",
    1,
    id,
    catalogue.Reserved,
    option.None,
  )
}

fn shared(binding: workspace.Binding) -> domain.Domain {
  let key = workspace.binding_key(binding)
  domain.Domain(
    domain.key(domain.WorkspacePrivate, key, ""),
    domain.WorkspacePrivate,
    key,
    "",
    "/never-opened/memory.db",
    "/never-opened/search.db",
  )
}

pub fn registered_binding_reopens_exact_epochs_and_preserves_defaults_and_domain_identity_test() {
  let path = fixtures.scratch("registered-binding") <> "/catalogue.db"
  let assert Ok(store) = catalogue.open(path) as "catalogue opens"
  let first = record(941, 2)
  let later = record(942, 4)
  let domain = shared(first.workspace)
  assert domain.reserve_session(store, first, domain) == Ok(first)
  assert domain.reserve_session(store, later, domain) == Ok(later)
  let key = workspace.binding_key(first.workspace)
  assert workspace.binding_key(later.workspace) == key
  assert catalogue.set_workspace_default(store, key, first.id) == Ok(first)
  let assert Ok(before) = catalogue.page(store, after: "") as "page loads"
  assert catalogue.reserve(store, first) == Ok(first)
  assert catalogue.page(store, after: "") == Ok(before)
  assert catalogue.reserve(
      store,
      catalogue.Registration(..first, workspace: bound(4)),
    )
    == Error(catalogue.Conflict)
  assert catalogue.close(store) == Ok(Nil)
  let assert Ok(reopened) = catalogue.open(path) as "catalogue reopens"
  assert catalogue.by_request_key(reopened, first.request_key) == Ok(first)
  assert catalogue.workspace_default(reopened, key) == Ok(first)
  assert domain.for_session(reopened, later.id) == Ok(domain)
  let assert Ok(rows) =
    catalogue.query(reopened, sql.find_registrations(first.id, "", ""))
    as "generated row loads"
  let assert [row] = rows as "one row loads"
  assert row.workspace == "registered:linux:project"
  assert row.workspace_binding
    == Some(json.to_string(workspace.encode_binding(first.workspace)))
  assert catalogue.close(reopened) == Ok(Nil)
  assert simplifile.is_file(first.path) == Ok(False)
}

pub fn every_catalogue_reader_refuses_disagreeing_registered_payload_test() {
  let path =
    fixtures.scratch("registered-binding-corruption") <> "/catalogue.db"
  let assert Ok(store) = catalogue.open(path) as "catalogue opens"
  let first = record(943, 2)
  assert catalogue.reserve(store, first) == Ok(first)
  assert catalogue.close(store) == Ok(Nil)
  let assert Ok(raw) = sqlight.open(path) as "corruption fixture opens"
  assert sqlight.exec(
      "UPDATE catalogue_sessions SET workspace = 'registered:other:project'",
      on: raw,
    )
    == Ok(Nil)
  assert sqlight.close(raw) == Ok(Nil)
  let assert Ok(reopened) = catalogue.open(path) as "schema remains valid"
  assert catalogue.get(reopened, first.id) |> result.is_error
  assert catalogue.by_request_key(reopened, first.request_key)
    |> result.is_error
  assert catalogue.page(reopened, after: "") |> result.is_error
  assert catalogue.close(reopened) == Ok(Nil)
}

pub fn null_local_and_registered_payload_combinations_are_checked_test() {
  let path =
    fixtures.scratch("registered-binding-combinations") <> "/catalogue.db"
  let assert Ok(store) = catalogue.open(path) as "catalogue opens"
  let first = record(944, 2)
  assert catalogue.reserve(store, first) == Ok(first)
  assert catalogue.close(store) == Ok(Nil)
  list.each(
    [
      "UPDATE catalogue_sessions SET workspace_binding = NULL",
      "UPDATE catalogue_sessions SET workspace = '/local', workspace_binding = '{}'",
      "UPDATE catalogue_sessions SET workspace = 'registered:linux:project', workspace_binding = '{}'",
      "UPDATE catalogue_sessions SET workspace_binding = ' {\"kind\":\"registered\",\"executor\":\"linux\",\"workspace\":\"project\",\"workspace_epoch\":2,\"session_epoch\":3}'",
    ],
    fn(mutation) {
      let assert Ok(raw) = sqlight.open(path) as "fixture opens"
      assert sqlight.exec(mutation, on: raw) == Ok(Nil)
      assert sqlight.close(raw) == Ok(Nil)
      let assert Ok(reopened) = catalogue.open(path) as "valid schema opens"
      let assert Error(catalogue.Invalid(_)) = catalogue.get(reopened, first.id)
        as "mismatched binding is refused"
      assert catalogue.close(reopened) == Ok(Nil)
    },
  )
}
