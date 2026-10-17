//// The gateway's prime reads entry heads where a pull decodes entries, and
//// the two must leave the same attribution cache and the same high-water.
////
//// The prime's whole claim is that it is a cheaper way to reach the state a
//// decoding pull at a high-water of zero would reach. These tests hold it
//// to that over generated stores: several strands, entries off every
//// strand's branch, branches that share a prefix, roots with no parent,
//// strands with no leaf, and the same stores through both backends.
////
//// A store is drawn as a plan from qcheck on a fixed seed, so the gate is
//// deterministic and a disagreement arrives already shrunk: fewer entries,
//// each pulled toward a root or the first entry as its parent, fewer
//// strands, and every leaf pulled toward absent.

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
import qcheck
import session/session.{type Session}
import simplifile
import storage/storage

/// How many stores each backend is checked over, and the seed they are drawn
/// from. SQLite pays for a file per store, so it takes fewer.
const memory_count = 300

const sqlite_count = 60

const plan_seed = 1

fn config(count: Int) -> qcheck.Config {
  qcheck.default_config()
  |> qcheck.with_test_count(count)
  |> qcheck.with_seed(qcheck.seed(plan_seed))
}

// A store drawn as numbers and nothing else. `parents` has one draw per
// entry and `leaves` one per possible strand, both as a pair of an
// occasion and a position, so that shrinking pulls each toward the
// plainest reading: a root, the first entry, no leaf.
type Plan {
  Plan(strands: Int, parents: List(#(Int, Int)), leaves: List(#(Int, Int)))
}

// Up to forty entries and one to three strands. The position is drawn wide
// and reduced modulo the entries available, so the same draw stays valid
// whatever length the list shrinks to.
fn plan_generator() -> qcheck.Generator(Plan) {
  let draw =
    qcheck.tuple2(
      qcheck.bounded_int(from: 0, to: 7),
      qcheck.bounded_int(from: 0, to: 1_000_000),
    )
  let leaf =
    qcheck.tuple2(
      qcheck.bounded_int(from: 0, to: 3),
      qcheck.bounded_int(from: 0, to: 1_000_000),
    )

  qcheck.map3(
    qcheck.bounded_int(from: 1, to: 3),
    qcheck.generic_list(
      elements_from: draw,
      length_from: qcheck.bounded_int(from: 1, to: 40),
    ),
    qcheck.fixed_length_list_from(leaf, 3),
    fn(strands, parents, leaves) { Plan(strands:, parents:, leaves:) },
  )
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

// The entries of a planned tree, in commit order. Each entry after the
// first is a root when its occasion is zero (one time in eight) and
// otherwise hangs off an earlier entry its position picks, so the tree
// branches and a parent is always committed before its child.
fn planned_entries(parents: List(#(Int, Int))) -> List(Entry) {
  let generator =
    ids.generator(clock.fixed(at: 1_700_000_000_000), seed: plan_seed)
  let #(entries, _generator) =
    list.index_fold(
      parents,
      #([], generator),
      fn(acc: #(List(Entry), ids.Generator), draw, index) {
        let #(entries, generator) = acc
        let #(id, generator) = ids.mint_entry(generator)
        let parent = case entries, draw.0 {
          [], _ | _, 0 -> None
          _, _ ->
            case
              list.drop(list.reverse(entries), draw.1 % list.length(entries))
            {
              [earlier, ..] -> Some(earlier.id)
              [] -> None
            }
        }
        #(
          [user_entry(id, parent, "entry " <> int.to_string(index)), ..entries],
          generator,
        )
      },
    )
  list.reverse(entries)
}

// Commits a planned store: one to three strands, each with a leaf on a
// chosen entry three times in four. A strand without a leaf and entries on
// no leaf's path both occur, which is what drives the completeness pass.
fn populate(store: Session, plan: Plan) -> Nil {
  let entries = planned_entries(plan.parents)
  let names = list.take(["main", "alpha", "beta"], plan.strands)
  list.each(names, fn(name) {
    let assert Ok(Nil) = session.ensure_strand(store, name, configuration())
  })
  let assert Ok(_) =
    storage.commit(
      store.store,
      Tx(writes: list.map(entries, InsertEntry), expected: []),
    )
  let leaves =
    list.zip(names, plan.leaves)
    |> list.filter_map(fn(named) {
      let #(name, #(roll, pick)) = named
      case roll, list.drop(entries, pick % list.length(entries)) {
        0, _ | _, [] -> Error(Nil)
        _, [chosen, ..] ->
          Ok(SetRegister(
            ns: register.StrandLeaf,
            key: name,
            value: register.leaf_value(Some(chosen.id)),
          ))
      }
    })
  let assert Ok(_) =
    storage.commit(store.store, Tx(writes: leaves, expected: []))
  Nil
}

fn assert_same_history(store: Session) -> Nil {
  let by_heads = gateway.entry_history_by_heads(store)
  let by_decoding = gateway.entry_history_by_decoding(store)
  assert by_heads == by_decoding as "the prime and the decoding pull disagree"
  Nil
}

/// Over a few hundred generated stores on the memory backend, the heads
/// prime and the decoding pull agree on every entry's attribution and on
/// the high-water.
pub fn heads_prime_matches_decoding_pull_on_memory_test() {
  qcheck.run(config(memory_count), plan_generator(), fn(plan) {
    let assert Ok(store) = session.open_memory(clock.fixed(at: 1000))
    populate(store, plan)
    assert_same_history(store)
    let assert Ok(Nil) = session.close(store)
    Nil
  })
}

/// The same property over SQLite, whose heads come from a separate SQL
/// projection rather than from the decoded entries.
pub fn heads_prime_matches_decoding_pull_on_sqlite_test() {
  let root = "build/test_db/gateway-prime"
  let path = root <> "/case.db"
  let _stale = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  qcheck.run(config(sqlite_count), plan_generator(), fn(plan) {
    // Each case opens a fresh file: the property is about one store, and a
    // database left by the previous case would be a second one's history.
    list.each([path, path <> "-wal", path <> "-shm"], fn(file) {
      let _absent = simplifile.delete(file)
    })
    let assert Ok(store) =
      session.open_sqlite(
        path:,
        owner: "gateway-prime-test",
        lease_ttl_ms: 60_000,
        clock: clock.fixed(at: 1000),
      )
    populate(store, plan)
    assert_same_history(store)
    let assert Ok(Nil) = session.close(store)
    Nil
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
