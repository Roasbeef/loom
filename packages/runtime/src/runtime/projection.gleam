//// A strand's branch scan kept between driver steps, and the rule for
//// extending it with the entries appended since.
////
//// A driver projects its strand's branch on every step: once for the
//// planner's compaction threshold and once for the request. The branch is
//// write-once and grows at its leaf, so a scan made from one leaf stays a
//// correct prefix of the scan from any later leaf on the same line, and
//// the step only has to read the entries past the one it already holds.
//// Before this the whole branch was read and decoded three times per
//// step, and on a 1,200-entry branch that was most of the server's CPU
//// (issue #359).
////
//// The join is pure so that its edge cases can be tested without a driver:
//// what makes a rewind or a fork a full rescan rather than a wrong join is
//// the parent check below, and a compaction among the new entries restarts
//// the projection at itself, which is what the full scan's
//// stop-at-compaction already expresses.

import core/entry.{type Entry}
import core/ids.{type EntryId}
import gleam/list
import gleam/option.{type Option, None, Some}

/// A branch scan and the leaf it was made from. `newest_first` is exactly
/// what `storage.scan_branch` returns for a scan from `leaf` that stops at
/// the newest compaction.
pub type Cached {
  Cached(leaf: EntryId, newest_first: List(Entry))
}

/// Joins the entries appended since the cache, or answers `None` when the
/// branch has to be rescanned from its new leaf.
///
/// `added` is the scan from the new leaf with a cursor at the cached
/// leaf's seq, oldest first. It continues the cache only when its oldest
/// entry names the cached leaf as its parent: a leaf that moved anywhere
/// but forward from the cached one yields new entries rooted elsewhere, or
/// none at all under a leaf that differs, and both read as `None`. A
/// compaction among the new entries also reads as `None`, since the
/// projection restarts at it, and so does a cache holding no entries.
///
/// ## Examples
///
/// ```gleam
/// // projection.join(cached, added_oldest_first)
/// // Some(newest_first) when added continues the cached leaf
/// ```
pub fn join(cached: Cached, added: List(Entry)) -> Option(List(Entry)) {
  case cached.newest_first, added {
    // A cache with a leaf and no entries cannot occur, since a leaf names
    // at least the entry it is; it is refused rather than trusted.
    [], _ -> None
    _, [] -> None
    _, [oldest, ..] ->
      case
        oldest.parent == Some(cached.leaf) && !list.any(added, is_compaction)
      {
        True -> Some(list.append(list.reverse(added), cached.newest_first))
        False -> None
      }
  }
}

/// Whether an entry is a compaction, the one kind a projection restarts at.
///
/// ## Examples
///
/// ```gleam
/// // assert !projection.is_compaction(message_entry)
/// ```
pub fn is_compaction(entry: Entry) -> Bool {
  case entry {
    entry.CompactionEntry(..) -> True
    entry.MessageEntry(..)
    | entry.BranchSummaryEntry(..)
    | entry.CustomEntry(..) -> False
  }
}
