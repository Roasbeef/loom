//// Authorization is a query input, never a property of retained index rows.
//// These real-SQLite tests keep every session indexed while varying the current
//// authorized set. Filtering must precede LIMIT, including when higher-ranked
//// results belong to sessions that the caller can no longer read.

import core/ids
import events/search
import gleam/list
import gleam/option.{None}
import storage/storage
import support/fixtures

/// Every subset returns precisely its ranked hits, without spending its limit
/// on unauthorized rows. Empty and duplicate scopes preserve set semantics.
///
/// ## Examples
///
/// The single-session subsets include sessions below the first global hit.
pub fn authorization_filters_before_rank_limit_test() {
  let assert Ok(index) = search.open(":memory:") as "index must open"
  let #(a, ctx) = fixtures.mint_session(fixtures.new_ctx())
  let #(b, ctx) = fixtures.mint_session(ctx)
  let #(c, _ctx) = fixtures.mint_session(ctx)
  index_text(index, a, "migration migration migration")
  index_text(index, b, "migration planning across several modules")
  index_text(index, c, "migration planning across many more unrelated modules")

  // Retained source locators do not authorize either indexed text or snippets.
  let assert Ok(Nil) = search.register_source(index, a, "/retained/a.db")
    as "source locator must register"
  let assert Ok(all) = search.query(index, "migration", 50)
    as "global reference query must succeed"
  assert list.length(all) == 3
  let scopes = [[], [a], [b], [c], [a, b], [a, c], [b, c], [a, b, c]]

  // The unrestricted result supplies ranking, not authorization. Each singleton
  // must still produce a hit with LIMIT 1 even when its global rank is lower.
  list.each(scopes, fn(scope) {
    let names = list.map(scope, ids.session_id_to_string)
    let permitted =
      list.filter(all, fn(hit) { list.contains(names, hit.session) })
    list.each([1, 2, 50], fn(limit) {
      let assert Ok(actual) =
        search.query_authorized(index, scope, "migration", limit)
        as "authorized query must succeed"
      assert actual == list.take(permitted, limit)
    })
  })

  let assert Ok(once) = search.query_authorized(index, [a, c], "migration", 50)
    as "set query must succeed"
  let assert Ok(repeated) =
    search.query_authorized(index, [c, a, c, a], "migration", 50)
    as "repeated identities must remain a set"
  assert repeated == once
  let assert Ok(Nil) = search.close(index) as "index must close"
}

/// The typed boundary refuses SQLite's unbounded negative LIMIT convention and
/// oversized identity inventories, while accepting its exact documented caps.
///
/// ## Examples
///
/// A 512-element scope is accepted; its 513-element extension is refused.
pub fn authorization_query_enforces_inventory_and_result_bounds_test() {
  let assert Ok(index) = search.open(":memory:") as "index must open"
  let #(session, _ctx) = fixtures.mint_session(fixtures.new_ctx())
  index_text(index, session, "migration")

  list.each([-1, 0, 51], fn(limit) {
    let assert Error(search.IndexFault(_)) =
      search.query_authorized(index, [session], "migration", limit)
      as "invalid result limits must be refused"
  })

  let full_scope = list.repeat(session, 512)
  let assert Ok([hit]) =
    search.query_authorized(index, full_scope, "migration", 50)
    as "the exact inventory cap must remain usable"
  assert hit.session == ids.session_id_to_string(session)
  let assert Error(search.IndexFault(_)) =
    search.query_authorized(index, [session, ..full_scope], "migration", 50)
    as "an oversized inventory must be refused, never truncated"
  let assert Ok(Nil) = search.close(index) as "index must close"
}

// Each temporary conversation is closed after indexing. Its retained index row
// must remain searchable only when the query explicitly authorizes its session.
fn index_text(
  index: search.Search,
  session: ids.SessionId,
  text: String,
) -> Nil {
  let store = fixtures.open_store()
  let #(entry, _ctx) = fixtures.message_entry(fixtures.new_ctx(), None, text)
  fixtures.commit_entries(store, [entry])
  let assert Ok(Nil) = search.sync(index, store, session, 0)
    as "fixture text must index"
  let assert Ok(Nil) = storage.close(store) as "fixture conversation must close"
  Nil
}
