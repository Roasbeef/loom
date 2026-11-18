//// The rule that turns the attention feed into the inbox's threads: which
//// items need the owner, which are finds, how they rank by how long they have
//// waited, what the headline counts, and how an age is worded
//// (protocol-change/120 and 122, the attention inbox's phase 1).
////
//// The module is pure. It imports no Lustre and reads no clock: the page hands
//// it the time it read the list at, so a test states every decision without
//// drawing a page. `web_view/view/attention_thread` draws what this module
//// decides and decides nothing itself.
////
//// Three sources feed it. A running session answers a feed row
//// (`attention_feed.Row`) of open asks, finds and stuck strands, and an
//// activity report that says whether an approval is pending. A session that is
//// saved and not running answers nothing live, so the catalogue's summary row
//// (`saved_attention.Saved`) stands in for it, and the headline says that the
//// count came from the catalogue. A session whose custody is moving, blocked
//// or failed to start is left out of every count: its records are not the
//// page's to read.
////
//// Every head, strand name and path in an item is untrusted model text. The
//// rule measures nothing in it and the view draws it as text nodes.
////
//// ## Flow
////
//// `items` → `ranked` → `needs_you` / `finds`; `tally` → `headline`
////
//// 1. `items` flattens the feed rows of every session into one list of items.
//// 2. `ranked` orders them by how long they have waited, oldest first, an item
////    with no known time last.
//// 3. `needs_you` and `finds` split the ranked list into the two groups the
////    inbox draws.
//// 4. `tally` counts what needs the owner across running and saved sessions,
////    and `headline` words the count with what it did and did not read.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/string
import web_view/attention_feed.{type Ask, type Find, type Row, type Stuck}
import web_view/saved_attention.{type Saved}

/// One open thing in a session that a person can act on: an ask to answer, a
/// find to close, or a strand that stopped on a failure. The session is the
/// catalogue's identity and the rest is the feed's.
pub type Item {
  /// An open ask routed to the owner.
  AskItem(session: String, ask: Ask)

  /// An open find.
  FindItem(session: String, find: Find)

  /// A strand that stopped on a failed run.
  StuckItem(session: String, stuck: Stuck)
}

/// Where a session stands as the page's counts read it.
pub type Standing {
  /// The session runs, and its live feed row was read.
  Running(approval: Approval, row: Row)

  /// The session runs and the feed has no row for it yet: it was slow, or the
  /// row did not decode. It is counted as not checked.
  RunningUnread(approval: Approval)

  /// The session is saved, and the catalogue has a summary row for it.
  SavedCounted(saved: Saved)

  /// The session is saved and the catalogue has no row for it.
  SavedUnread
}

/// Whether the session's activity read says an approval is pending.
pub type Approval {
  /// An escalation is waiting for a decision.
  Pending

  /// None is.
  NotPending
}

/// What the headline counts.
pub type Tally {
  Tally(
    /// Approvals, asks and stuck strands that need the owner.
    needing: Int,
    /// Open finds, which wait on no one but are worth a look.
    finds: Int,
    /// How many running sessions the counts read live.
    running: Int,
    /// How many saved sessions the counts took from the catalogue's summary.
    from_catalogue: Int,
    /// How many sessions, running or saved, no source answered for.
    unread: Int,
  )
}

/// The longest wait, in milliseconds, a page words as minutes. A wait longer
/// than a day is words in days.
const day_ms = 86_400_000

/// Every item the rows hold, in the order the rows came and, within a row,
/// asks then stuck strands then finds.
///
/// ## Examples
///
/// ```gleam
/// assert attention_rule.items([]) == []
/// ```
pub fn items(rows: List(#(String, Row))) -> List(Item) {
  list.flat_map(rows, fn(entry) {
    let #(session, row) = entry

    list.flatten([
      list.map(row.asks.items, AskItem(session, _)),
      list.map(row.stuck.items, StuckItem(session, _)),
      list.map(row.finds.items, FindItem(session, _)),
    ])
  })
}

/// Whether an item waits on the owner. An ask and a stuck strand do. A find
/// does not stop anything, so it is not under "Needs you".
///
/// ## Examples
///
/// ```gleam
/// assert attention_rule.needs_you_item(attention_rule.StuckItem("s", stuck)) == True
/// ```
pub fn needs_you_item(item: Item) -> Bool {
  case item {
    AskItem(..) | StuckItem(..) -> True
    FindItem(..) -> False
  }
}

/// When the item began to wait, in Unix milliseconds, or nothing when the feed
/// does not say. A stuck strand carries only a lower bound, the time of its
/// last entry, so its age is "since at least".
///
/// ## Examples
///
/// ```gleam
/// assert attention_rule.since(attention_rule.StuckItem("s", feed_stuck)) == None
/// ```
pub fn since(item: Item) -> Option(Int) {
  case item {
    AskItem(ask:, ..) -> Some(ask.created_at)
    FindItem(find:, ..) -> Some(find.created_at)
    StuckItem(stuck:, ..) -> stuck.failed_at
  }
}

/// The items ordered by wait time: the longest wait first, an item whose time
/// is not known last, and a tie by session and then by the item's own identity,
/// so two reads of the same rows list the same order.
///
/// ## Examples
///
/// ```gleam
/// assert attention_rule.ranked([]) == []
/// ```
pub fn ranked(items: List(Item)) -> List(Item) {
  list.sort(items, by_wait)
}

/// The ranked items that wait on the owner.
///
/// ## Examples
///
/// ```gleam
/// assert attention_rule.needs_you([]) == []
/// ```
pub fn needs_you(items: List(Item)) -> List(Item) {
  items |> list.filter(needs_you_item) |> ranked
}

/// The ranked finds.
///
/// ## Examples
///
/// ```gleam
/// assert attention_rule.finds([]) == []
/// ```
pub fn finds(items: List(Item)) -> List(Item) {
  items |> list.filter(fn(item) { !needs_you_item(item) }) |> ranked
}

/// The words for how long something has waited, counted from `since` to `now`
/// in Unix milliseconds. A time in the future, which a skewed clock can make,
/// reads as "just now", and a wait under a minute does too, so the page never
/// prints a negative or a falsely exact age.
///
/// ## Examples
///
/// ```gleam
/// assert attention_rule.age_words(since: 0, now: 300_000) == "5 min"
/// assert attention_rule.age_words(since: 0, now: 30_000) == "just now"
/// ```
pub fn age_words(since since: Int, now now: Int) -> String {
  let wait = now - since
  let minutes = wait / 60_000

  // Under a minute, and a time that has not happened yet, are both "just now".
  case wait < 60_000, wait < 3_600_000, wait < day_ms {
    True, _, _ -> "just now"
    False, True, _ -> int.to_string(minutes) <> " min"
    False, False, True -> int.to_string(wait / 3_600_000) <> " h"
    False, False, False -> int.to_string(wait / day_ms) <> " d"
  }
}

/// The age an item's row says: how long it has waited, "since at least" for a
/// stuck strand whose time is only a bound, and nothing for an item with no
/// time.
///
/// ## Examples
///
/// ```gleam
/// assert attention_rule.age_line(item, 300_000) == Some("waiting 5 min")
/// ```
pub fn age_line(item: Item, now: Int) -> Option(String) {
  case item, since(item) {
    StuckItem(..), Some(at) ->
      Some(case age_words(since: at, now:) {
        "just now" -> "stuck just now"
        words -> "stuck since at least " <> words <> " ago"
      })
    AskItem(..), Some(at) -> Some("waiting " <> age_words(since: at, now:))
    FindItem(..), Some(at) ->
      Some(case age_words(since: at, now:) {
        "just now" -> "noticed just now"
        words -> "noticed " <> words <> " ago"
      })
    _, None -> None
  }
}

/// A saved session whose catalogue summary holds something open, as the thread
/// the inbox draws for it: the headline counts that summary, so a count the page
/// states is a row the person can act on. The name is the catalogue's, which
/// the owner wrote, and is drawn as a text node.
pub type SavedThread {
  SavedThread(
    /// The session's identity, which its one action opens.
    session: String,
    /// The display name the page shows for it.
    name: String,
    /// The catalogue's summary of its open work.
    saved: Saved,
  )
}

/// The saved sessions whose summary holds a pending approval or an open ask:
/// the ones the headline counts as needing the owner. The order given is kept.
///
/// ## Examples
///
/// ```gleam
/// assert attention_rule.saved_needing([]) == []
/// ```
pub fn saved_needing(threads: List(SavedThread)) -> List(SavedThread) {
  list.filter(threads, fn(each) {
    each.saved.pending_approvals + each.saved.open_asks > 0
  })
}

/// The saved sessions whose summary holds open finds. A session that also
/// needs the owner is drawn there as well, since each count is its own.
///
/// ## Examples
///
/// ```gleam
/// assert attention_rule.saved_finding([]) == []
/// ```
pub fn saved_finding(threads: List(SavedThread)) -> List(SavedThread) {
  list.filter(threads, fn(each) { each.saved.open_finds > 0 })
}

/// What a saved session's summary says needs the owner, as "1 approval, 1 ask
/// pending", or nothing when no approval or ask is open.
///
/// ## Examples
///
/// ```gleam
/// assert attention_rule.needing_words(saved) == "1 approval, 2 asks pending"
/// ```
pub fn needing_words(saved: Saved) -> String {
  let parts =
    list.flatten([
      counted(saved.pending_approvals, "approval", "approvals"),
      counted(saved.open_asks, "ask", "asks"),
    ])

  case parts {
    [] -> ""
    [_, ..] -> string.join(parts, ", ") <> " pending"
  }
}

/// What a saved session's summary says about its finds, as "2 finds open".
///
/// ## Examples
///
/// ```gleam
/// assert attention_rule.finding_words(saved) == "2 finds open"
/// ```
pub fn finding_words(saved: Saved) -> String {
  case counted(saved.open_finds, "find", "finds") {
    [] -> ""
    [words, ..] -> words <> " open"
  }
}

/// How long the summary's oldest open ask or find has been open, when the
/// summary has a time: "oldest open 5 min ago", and "oldest open just now" for
/// a wait under a minute. Approvals carry no raise time, so a session with only
/// an approval has none.
///
/// ## Examples
///
/// ```gleam
/// assert attention_rule.saved_age(saved, 300_000) == Some("oldest open 5 min ago")
/// ```
pub fn saved_age(saved: Saved, now: Int) -> Option(String) {
  option.map(saved.oldest_open_at, fn(at) {
    case age_words(since: at, now:) {
      "just now" -> "oldest open just now"
      words -> "oldest open " <> words <> " ago"
    }
  })
}

/// A count and its noun, or nothing for none.
fn counted(count: Int, one: String, many: String) -> List(String) {
  case count {
    0 -> []
    1 -> ["1 " <> one]
    _ -> [int.to_string(count) <> " " <> many]
  }
}

/// The counts the headline reads, from what each listed session is known by.
/// A running session with a row counts its asks and stuck strands live, and an
/// approval counts one when the activity read says it is pending. A saved
/// session counts its summary's approvals and asks. Finds are counted apart.
///
/// ## Examples
///
/// ```gleam
/// assert attention_rule.tally([]) == attention_rule.Tally(0, 0, 0, 0, 0)
/// ```
pub fn tally(standings: List(Standing)) -> Tally {
  list.fold(standings, Tally(0, 0, 0, 0, 0), fn(sum, standing) {
    case standing {
      Running(approval:, row:) ->
        Tally(
          ..sum,
          needing: sum.needing
            + approvals(approval)
            + row.asks.count
            + row.stuck.count,
          finds: sum.finds + row.finds.count,
          running: sum.running + 1,
        )
      RunningUnread(approval:) ->
        Tally(
          ..sum,
          needing: sum.needing + approvals(approval),
          running: sum.running + 1,
          unread: sum.unread + 1,
        )
      SavedCounted(saved:) ->
        Tally(
          ..sum,
          needing: sum.needing + saved.pending_approvals + saved.open_asks,
          finds: sum.finds + saved.open_finds,
          from_catalogue: sum.from_catalogue + 1,
        )
      SavedUnread -> Tally(..sum, unread: sum.unread + 1)
    }
  })
}

/// The headline over the inbox. It says how many things need the owner, how
/// many finds are open, and what the count read, so it never claims more than
/// it looked at: the running sessions read live, the saved sessions taken from
/// the catalogue's summary, and the sessions no source answered for.
///
/// ## Examples
///
/// ```gleam
/// assert attention_rule.headline(attention_rule.Tally(1, 2, 3, 4, 0))
///   == "1 needs you · 2 finds · 3 running sessions read live, 4 saved from the catalogue"
/// ```
pub fn headline(tally: Tally) -> String {
  // The count is worded for none, one and many.
  let first = case tally.needing {
    0 -> "Nothing needs you"
    1 -> "1 needs you"
    many -> int.to_string(many) <> " need you"
  }

  // Finds are worded the same way, and none says nothing.
  let finds = case tally.finds {
    0 -> ""
    1 -> " · 1 find"
    many -> " · " <> int.to_string(many) <> " finds"
  }

  let read =
    " · "
    <> int.to_string(tally.running)
    <> plural(tally.running, " running session", " running sessions")
    <> " read live, "
    <> int.to_string(tally.from_catalogue)
    <> " saved from the catalogue"

  // Sessions that no source answered for are said last.
  let unread = case tally.unread {
    0 -> ""
    many -> ", " <> int.to_string(many) <> " not checked"
  }

  string.concat([first, finds, read, unread])
}

/// One for a pending approval and none otherwise.
fn approvals(approval: Approval) -> Int {
  case approval {
    Pending -> 1
    NotPending -> 0
  }
}

/// The singular for one and the plural for any other count.
fn plural(count: Int, one: String, many: String) -> String {
  case count {
    1 -> one
    _ -> many
  }
}

/// Orders two items by wait: the older time first, a known time before an
/// unknown one, then by session and by identity.
fn by_wait(left: Item, right: Item) -> order.Order {
  // A known time ranks before an unknown one, and the older of two known times first.
  let times = case since(left), since(right) {
    Some(a), Some(b) -> int.compare(a, b)
    Some(_), None -> order.Lt
    None, Some(_) -> order.Gt
    None, None -> order.Eq
  }

  // A tie in time falls to the session and then the identity, so two reads agree.
  case times {
    order.Eq ->
      case string.compare(session_of(left), session_of(right)) {
        order.Eq -> string.compare(identity(left), identity(right))
        other -> other
      }
    other -> other
  }
}

/// The session an item belongs to.
///
/// ## Examples
///
/// ```gleam
/// assert attention_rule.session_of(attention_rule.StuckItem("s", stuck)) == "s"
/// ```
pub fn session_of(item: Item) -> String {
  case item {
    AskItem(session:, ..) | FindItem(session:, ..) | StuckItem(session:, ..) ->
      session
  }
}

/// The item's identity within its session: an ask's or a find's identifier,
/// and a stuck strand's name. It is a comparison key and is never an attribute.
///
/// ## Examples
///
/// ```gleam
/// assert attention_rule.identity(attention_rule.StuckItem("s", stuck)) == stuck.strand
/// ```
pub fn identity(item: Item) -> String {
  case item {
    AskItem(ask:, ..) -> ask.id
    FindItem(find:, ..) -> find.id
    StuckItem(stuck:, ..) -> stuck.strand
  }
}

/// Which sort of item a key names, so an ask and a stuck strand that share a
/// text can never be taken for each other.
pub type Sort {
  /// An ask.
  AskSort

  /// A find.
  FindSort

  /// A stuck strand.
  StuckSort
}

/// What selects an item's thread: its sort, session and identity. It is held
/// by the page and compared, never drawn into an attribute.
pub type Key {
  Key(sort: Sort, session: String, id: String)
}

/// The key of an item.
///
/// ## Examples
///
/// ```gleam
/// assert attention_rule.key_of(attention_rule.StuckItem("s", stuck))
///   == attention_rule.Key(attention_rule.StuckSort, "s", stuck.strand)
/// ```
pub fn key_of(item: Item) -> Key {
  Key(
    sort: case item {
      AskItem(..) -> AskSort
      FindItem(..) -> FindSort
      StuckItem(..) -> StuckSort
    },
    session: session_of(item),
    id: identity(item),
  )
}

/// The item a key names among `items`, or nothing when the last read no longer
/// holds it, which is how an answered ask or a closed find leaves its pane.
///
/// ## Examples
///
/// ```gleam
/// assert attention_rule.find_item([], key) == None
/// ```
pub fn find_item(items: List(Item), key: Key) -> Option(Item) {
  items
  |> list.find(fn(item) { key_of(item) == key })
  |> option.from_result
}
