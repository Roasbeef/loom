import core/clock
import core/entry
import core/ids
import core/message
import gleam/option.{type Option, None, Some}
import runtime/projection

// Entries with a parent chain and increasing seqs, the shape a branch has.
fn message(seq: Int, parent: Option(ids.EntryId)) -> entry.Entry {
  entry.MessageEntry(
    id: id_of(seq),
    parent:,
    seq:,
    ts: seq,
    message: message.UserMessage(
      content: [message.UserText(text: "m", text_signature: None)],
      timestamp: seq,
      origin: None,
    ),
    terminate: False,
  )
}

fn id_of(seq: Int) -> ids.EntryId {
  let #(id, _) =
    ids.mint_entry(ids.generator(clock.fixed(at: seq * 1000), seed: seq))
  id
}

fn compaction(seq: Int, parent: Option(ids.EntryId)) -> entry.Entry {
  entry.CompactionEntry(
    id: id_of(seq),
    parent:,
    seq:,
    ts: seq,
    summary: "s",
    retained_tail: [],
    tokens_before: 0,
    from_hook: False,
    usage: None,
  )
}

// A cache made from leaf 2 over entries 1..2, and a branch that grew by
// entries 3..4 whose oldest names leaf 2 as its parent.
fn grown() -> #(projection.Cached, List(entry.Entry)) {
  let e1 = message(1, None)
  let e2 = message(2, Some(e1.id))
  let e3 = message(3, Some(e2.id))
  let e4 = message(4, Some(e3.id))
  #(projection.Cached(leaf: e2.id, newest_first: [e2, e1]), [e3, e4])
}

pub fn an_append_continues_the_cache_newest_first_test() {
  let #(cached, added) = grown()
  let assert Some([e4, e3, e2, e1]) = projection.join(cached, added)
  assert e4.seq == 4 && e3.seq == 3 && e2.seq == 2 && e1.seq == 1
}

// A leaf that moved off the cached line: the oldest new entry's parent is
// an ancestor of the cached leaf, not the cached leaf.
pub fn a_fork_below_the_cached_leaf_is_a_rescan_test() {
  let #(cached, _added) = grown()
  let assert [_, e1] = cached.newest_first
  let forked = message(5, Some(e1.id))
  assert projection.join(cached, [forked]) == None
}

pub fn a_leaf_with_nothing_past_the_cache_is_a_rescan_test() {
  let #(cached, _added) = grown()
  assert projection.join(cached, []) == None
}

pub fn a_compaction_among_the_new_entries_is_a_rescan_test() {
  let #(cached, added) = grown()
  let assert [e3, e4] = added
  let compacted = compaction(5, Some(e4.id))
  assert projection.join(cached, [e3, e4, compacted]) == None
}

pub fn an_empty_cache_is_never_continued_test() {
  let #(cached, added) = grown()
  let empty = projection.Cached(..cached, newest_first: [])
  assert projection.join(empty, added) == None
}
