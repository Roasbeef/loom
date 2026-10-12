//// A registry over a real catalogue that holds real registrations, for the tests
//// of what an orchestrator holds (`ledger_holdings_test`, and the live scenario
//// that asks an orchestrator across real distribution). The session assembly is
//// inert: the sessions are rows, which is all a count of them reads.

import client/daemon/domain as domain_service
import client/daemon/manager
import core/clock
import core/ids
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import host/bootstrap
import storage/access
import storage/catalogue
import storage/domain

/// A registry over an in-memory catalogue with an owner, the catalogue, and a
/// scratch directory for the sessions' paths.
///
/// ## Examples
///
/// ```gleam
/// let #(registry, store, directory) = held_catalogue.start()
/// ```
pub fn start() -> #(manager.Manager(String), catalogue.Catalogue, String) {
  let assert Ok(directory) =
    bootstrap.absolute_path("build/ledger-holdings-" <> int.to_string(unique()))
  let assert Ok(store) = catalogue.open(":memory:") as "the catalogue opens"
  let assert Ok(owner) = access.credential_digest(string.repeat("a", 64))
  let assert Ok(_) = access.bootstrap_owner(store, "owner", "Owner", owner)
  let assert Ok(registry) =
    manager.start(
      store,
      manager.Assembly(
        domain_build: fn(_, _, _) { Ok(domain_service.inert()) },
        build: fn(record, _domain, _services, _owner, _directory) {
          Ok(record.id)
        },
        drain: fn(_, _) { Nil },
        fatal: fn(_) { [] },
      ),
      epoch: "holdings-test",
      limit: 2,
    )
    as "the registry starts"
  #(registry, store, directory)
}

@external(erlang, "erlang", "unique_integer")
fn unique_integer(options: List(a)) -> Int

fn unique() -> Int {
  int.absolute_value(unique_integer([]))
}

// Registers and confirms one session placed on `executor` (the empty string for
// a local one) and returns its identity.
fn register(
  store: catalogue.Catalogue,
  directory: String,
  generator: ids.Generator,
  executor: String,
) -> #(String, ids.Generator) {
  let #(id, next) = ids.mint_session(generator)
  let session = ids.session_id_to_string(id)
  let record =
    catalogue.Registration(
      id: session,
      path: directory <> "/sessions/" <> session <> ".db",
      workspace: case executor {
        "" -> directory
        _ -> "repo"
      },
      name: "a session",
      configuration: "",
      profile: None,
      model: None,
      executor:,
      pool: "",
      created_at: 1_700_000_000_000,
      request_key: "key-" <> session,
      state: catalogue.Reserved,
      subtitle: None,
    )
  let selected = manager.session_only_domain(record, "", directory)
  let assert Ok(_) = domain.reserve_session(store, record, selected)
  let assert Ok(_) = catalogue.confirm(store, session)
  #(session, next)
}

fn generator() -> ids.Generator {
  ids.generator(clock.fixed(at: 1_700_000_000_000), seed: unique())
}

/// Registers and confirms `count` sessions placed on the executor named
/// `executor` (the empty string for local ones) and returns their identities.
///
/// ## Examples
///
/// ```gleam
/// let sessions = held_catalogue.registered_n(store, directory, "box", 3)
/// ```
pub fn registered_n(
  store: catalogue.Catalogue,
  directory: String,
  executor: String,
  count: Int,
) -> List(String) {
  list.repeat(Nil, count)
  |> list.fold(#([], generator()), fn(state, _) {
    let #(found, next) = state
    let #(session, next) = register(store, directory, next, executor)
    #([session, ..found], next)
  })
  |> fn(state) { state.0 }
}
