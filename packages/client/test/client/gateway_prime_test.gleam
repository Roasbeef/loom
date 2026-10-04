//// The gateway's prime reads entry heads where a pull decodes entries, and
//// the two must leave the same attribution cache and the same high-water.
////
//// The prime's whole claim is that it is a cheaper way to reach the state a
//// decoding pull at a high-water of zero would reach. These tests hold it
//// to that over generated stores: several strands, entries off every
//// strand's branch, branches that share a prefix, roots with no parent,
//// strands with no leaf, and the same stores through both backends.

import client/gateway
import core/clock
import core/entry.{type Entry, MessageEntry}
import core/ids.{type EntryId}
import core/message
import core/register
import core/tx.{InsertEntry, SetRegister, Tx}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import machine/strand.{ModelIdentity, StrandConfiguration, ThinkingOff}
import session/session.{type Session}
import simplifile
import storage/storage

// A linear congruential generator, so a failing case is reproduced by its
// number alone and the suite needs no property-testing dependency.
fn next(seed: Int) -> Int {
  { seed * 1_103_515_245 + 12_345 } % 2_147_483_648
}

// A value in `0..bound-1` and the generator's next state. The low bits of
// this generator cycle quickly, so the draw uses the high ones.
fn draw(seed: Int, bound: Int) -> #(Int, Int) {
  let seed = next(seed)
  #({ seed / 65_536 } % bound, seed)
}

// The counting numbers up to `last`, for driving a case per seed.
fn numbered(last: Int) -> List(Int) {
  list.repeat(Nil, last) |> list.index_map(fn(_, index) { index + 1 })
}

fn configuration() -> strand.StrandConfiguration {
  StrandConfiguration(
    model: ModelIdentity(provider: "acme", model_id: "loom-1"),
    thinking_level: ThinkingOff,
    active_tool_names: [],
  )
}

fn user_entry(id: EntryId, parent: Option(EntryId), text: String) -> Entry {
  MessageEntry(
    id:,
    parent:,
    seq: 0,
    ts: 0,
    message: message.UserMessage(
      content: [message.UserText(text:, text_signature: None)],
      timestamp: 0,
      origin: None,
    ),
    terminate: False,
  )
}

// The entries of a generated tree, in commit order. Each entry after the
// first is a root one time in eight and otherwise hangs off a uniformly
// chosen earlier entry, so the tree branches and a parent is always
// committed before its child.
fn generated_entries(seed: Int, count: Int) -> #(List(Entry), Int) {
  let generator = ids.generator(clock.fixed(at: 1_700_000_000_000), seed:)
  let #(entries, _generator, seed) =
    list.fold(
      numbered(count),
      #([], generator, seed),
      fn(acc: #(List(Entry), ids.Generator, Int), index) {
        let #(entries, generator, seed) = acc
        let #(id, generator) = ids.mint_entry(generator)
        let #(roll, seed) = draw(seed, 8)
        let #(pick, seed) = draw(seed, int.max(1, list.length(entries)))
        let parent = case entries, roll {
          [], _ | _, 0 -> None
          _, _ ->
            case list.drop(list.reverse(entries), pick) {
              [earlier, ..] -> Some(earlier.id)
              [] -> None
            }
        }
        #(
          [user_entry(id, parent, "entry " <> int.to_string(index)), ..entries],
          generator,
          seed,
        )
      },
    )
  #(list.reverse(entries), seed)
}

// Commits a generated store: one to three strands, each with a leaf on a
// random entry three times in four. A strand without a leaf and entries on
// no leaf's path both occur, which is what drives the completeness pass.
fn populate(store: Session, case_seed: Int) -> Nil {
  let #(count, seed) = draw(case_seed, 40)
  let #(strand_count, seed) = draw(seed, 3)
  let #(entries, seed) = generated_entries(seed, count + 1)
  let names = list.take(["main", "alpha", "beta"], strand_count + 1)
  list.each(names, fn(name) {
    let assert Ok(Nil) = session.ensure_strand(store, name, configuration())
  })
  let assert Ok(_) =
    storage.commit(
      store.store,
      Tx(writes: list.map(entries, InsertEntry), expected: []),
    )
  let leaves =
    list.fold(names, #([], seed), fn(acc, name) {
      let #(leaves, seed) = acc
      let #(roll, seed) = draw(seed, 4)
      let #(pick, seed) = draw(seed, list.length(entries))
      case roll, list.drop(entries, pick) {
        0, _ | _, [] -> #(leaves, seed)
        _, [chosen, ..] -> #(
          [
            SetRegister(
              ns: register.StrandLeaf,
              key: name,
              value: register.leaf_value(Some(chosen.id)),
            ),
            ..leaves
          ],
          seed,
        )
      }
    })
  let assert Ok(_) =
    storage.commit(store.store, Tx(writes: leaves.0, expected: []))
  Nil
}

fn assert_same_history(store: Session, case_seed: Int) -> Nil {
  let by_heads = gateway.entry_history_by_heads(store)
  let by_decoding = gateway.entry_history_by_decoding(store)
  assert by_heads == by_decoding as { "case " <> int.to_string(case_seed) }
  Nil
}

/// Over a few hundred generated stores on the memory backend, the heads
/// prime and the decoding pull agree on every entry's attribution and on
/// the high-water.
pub fn heads_prime_matches_decoding_pull_on_memory_test() {
  list.each(numbered(300), fn(case_seed) {
    let assert Ok(store) = session.open_memory(clock.fixed(at: 1000))
    populate(store, case_seed)
    assert_same_history(store, case_seed)
    let assert Ok(Nil) = session.close(store)
  })
}

/// The same property over SQLite, whose heads come from a separate SQL
/// projection rather than from the decoded entries.
pub fn heads_prime_matches_decoding_pull_on_sqlite_test() {
  let root = "build/test_db/gateway-prime"
  let _stale = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  list.each(numbered(60), fn(case_seed) {
    let assert Ok(store) =
      session.open_sqlite(
        path: root <> "/case-" <> int.to_string(case_seed) <> ".db",
        owner: "gateway-prime-test",
        lease_ttl_ms: 60_000,
        clock: clock.fixed(at: 1000),
      )
    populate(store, case_seed)
    assert_same_history(store, case_seed)
    let assert Ok(Nil) = session.close(store)
  })
}

/// A store that exercises each claim kind at once, written out so the
/// property above cannot pass by every generated case being trivial: two
/// strands share a prefix, one entry lies on neither branch, and the
/// history's greatest seq is the off-branch entry's.
pub fn heads_prime_attributes_shared_and_off_branch_entries_test() {
  let assert Ok(store) = session.open_memory(clock.fixed(at: 1000))
  let generator = ids.generator(clock.fixed(at: 1_700_000_000_000), seed: 7)
  let #(root_id, generator) = ids.mint_entry(generator)
  let #(left_id, generator) = ids.mint_entry(generator)
  let #(right_id, generator) = ids.mint_entry(generator)
  let #(stray_id, _generator) = ids.mint_entry(generator)
  let root = user_entry(root_id, None, "root")
  let left = user_entry(left_id, Some(root_id), "left")
  let right = user_entry(right_id, Some(root_id), "right")
  let stray = user_entry(stray_id, Some(right_id), "stray")
  list.each(["alpha", "main"], fn(name) {
    let assert Ok(Nil) = session.ensure_strand(store, name, configuration())
  })
  let assert Ok(_) =
    storage.commit(
      store.store,
      Tx(
        writes: list.map([root, left, right, stray], InsertEntry),
        expected: [],
      ),
    )
  let assert Ok(_) =
    storage.commit(
      store.store,
      Tx(
        writes: [
          SetRegister(
            ns: register.StrandLeaf,
            key: "alpha",
            value: register.leaf_value(Some(left_id)),
          ),
          SetRegister(
            ns: register.StrandLeaf,
            key: "main",
            value: register.leaf_value(Some(right_id)),
          ),
        ],
        expected: [],
      ),
    )
  let history = gateway.entry_history_by_heads(store)
  assert history == gateway.entry_history_by_decoding(store)
  let label = fn(id) {
    let assert Ok(found) =
      list.key_find(history.attribution, ids.entry_id_to_string(id))
    found
  }
  assert label(root_id) == "shared:alpha"
  assert label(left_id) == "owned:alpha"
  assert label(right_id) == "owned:main"
  assert label(stray_id) == "unverified:main"
  let assert Ok([latest]) =
    storage.scan_entries(
      store.store,
      storage.entry_scan()
        |> storage.entry_order(storage.NewestFirst)
        |> storage.entry_limit(1),
    )
  assert history.high_water == storage.entry_head_of(latest).seq
    as "the off-branch entry's seq is the greatest"
  let assert Ok(Nil) = session.close(store)
}
