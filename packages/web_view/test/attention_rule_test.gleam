//// What the inbox's attention rule decides (`web_view/attention_rule`): the
//// items a feed holds, how they rank by wait, how an age is worded, and what
//// the headline counts across running and saved sessions.

import core/attention
import gleam/option.{None, Some}
import web_view/attention_feed.{Ask, Find, Row, Section, Stuck}
import web_view/attention_rule.{
  AskItem, FindItem, NotPending, Pending, Running, RunningUnread, SavedCounted,
  SavedUnread, StuckItem,
}
import web_view/saved_attention.{Saved}

fn ask(id: String, at: Int) -> attention_feed.Ask {
  Ask(id:, strand: "main", created_at: at, head: "Which?", questions: 1)
}

fn find(id: String, at: Int) -> attention_feed.Find {
  Find(
    id:,
    strand: "main",
    kind: attention.Bug,
    created_at: at,
    head: "No backoff.",
    path: Some("src/retry.gleam"),
    line: Some(41),
  )
}

fn row(
  asks: List(attention_feed.Ask),
  finds: List(attention_feed.Find),
  stuck: List(attention_feed.Stuck),
) -> attention_feed.Row {
  Row(
    waiting_since: None,
    asks: Section(count: list_length(asks), items: asks),
    finds: Section(count: list_length(finds), items: finds),
    stuck: Section(count: list_length(stuck), items: stuck),
  )
}

fn list_length(items: List(a)) -> Int {
  case items {
    [] -> 0
    [_, ..rest] -> 1 + list_length(rest)
  }
}

pub fn items_flatten_the_rows_in_kind_order_test() {
  let items =
    attention_rule.items([
      #(
        "s1",
        row([ask("ask-1", 10)], [find("find-1", 5)], [
          Stuck(
            strand: "sub:x",
            failed_at: None,
            reason: None,
            retry_after_ms: None,
            parent: None,
            operation: None,
          ),
        ]),
      ),
      #("s2", row([ask("ask-2", 3)], [], [])),
    ])
  assert items
    == [
      AskItem("s1", ask("ask-1", 10)),
      StuckItem(
        "s1",
        Stuck(
          strand: "sub:x",
          failed_at: None,
          reason: None,
          retry_after_ms: None,
          parent: None,
          operation: None,
        ),
      ),
      FindItem("s1", find("find-1", 5)),
      AskItem("s2", ask("ask-2", 3)),
    ]
}

pub fn needs_you_ranks_the_longest_wait_first_and_unknown_last_test() {
  let items =
    attention_rule.items([
      #(
        "b",
        row([ask("ask-b", 200)], [], [
          Stuck(
            strand: "sub:b",
            failed_at: None,
            reason: None,
            retry_after_ms: None,
            parent: None,
            operation: None,
          ),
        ]),
      ),
      #(
        "a",
        row([ask("ask-a", 200)], [], [
          Stuck(
            strand: "sub:a",
            failed_at: Some(50),
            reason: None,
            retry_after_ms: None,
            parent: None,
            operation: None,
          ),
        ]),
      ),
      #("c", row([ask("ask-c", 100)], [find("find-c", 1)], [])),
    ])

  // The stuck strand with a time is oldest, then the ask at 100, then the two
  // at 200 by session, and the one with no time last. Finds are not here.
  assert attention_rule.needs_you(items)
    == [
      StuckItem(
        "a",
        Stuck(
          strand: "sub:a",
          failed_at: Some(50),
          reason: None,
          retry_after_ms: None,
          parent: None,
          operation: None,
        ),
      ),
      AskItem("c", ask("ask-c", 100)),
      AskItem("a", ask("ask-a", 200)),
      AskItem("b", ask("ask-b", 200)),
      StuckItem(
        "b",
        Stuck(
          strand: "sub:b",
          failed_at: None,
          reason: None,
          retry_after_ms: None,
          parent: None,
          operation: None,
        ),
      ),
    ]
  assert attention_rule.finds(items) == [FindItem("c", find("find-c", 1))]
}

pub fn an_age_is_worded_without_claiming_more_than_it_knows_test() {
  assert attention_rule.age_words(since: 0, now: 30_000) == "just now"
  assert attention_rule.age_words(since: 100, now: 0) == "just now"
  assert attention_rule.age_words(since: 0, now: 300_000) == "5 min"
  assert attention_rule.age_words(since: 0, now: 7_200_000) == "2 h"
  assert attention_rule.age_words(since: 0, now: 172_800_000) == "2 d"
}

pub fn the_age_line_says_a_stuck_time_is_a_bound_test() {
  let now = 600_000
  assert attention_rule.age_line(AskItem("s", ask("ask-1", 0)), now)
    == Some("waiting 10 min")
  assert attention_rule.age_line(
      StuckItem(
        "s",
        Stuck(
          strand: "x",
          failed_at: Some(0),
          reason: None,
          retry_after_ms: None,
          parent: None,
          operation: None,
        ),
      ),
      now,
    )
    == Some("stuck since at least 10 min ago")
  assert attention_rule.age_line(
      StuckItem(
        "s",
        Stuck(
          strand: "x",
          failed_at: None,
          reason: None,
          retry_after_ms: None,
          parent: None,
          operation: None,
        ),
      ),
      now,
    )
    == None
}

pub fn a_saved_summary_is_worded_by_its_counts_test() {
  let saved = Saved("s", 1, 2, 0, Some(0), 5)
  assert attention_rule.needing_words(saved) == "1 approval, 2 asks pending"
  assert attention_rule.finding_words(saved) == ""
  assert attention_rule.saved_age(saved, 300_000)
    == Some("oldest open 5 min ago")
  assert attention_rule.saved_age(saved, 30_000) == Some("oldest open just now")
  assert attention_rule.saved_age(Saved("s", 1, 0, 0, None, 5), 300_000) == None
  assert attention_rule.needing_words(Saved("s", 0, 0, 1, None, 5)) == ""
  assert attention_rule.finding_words(Saved("s", 0, 0, 1, None, 5))
    == "1 find open"
}

pub fn just_now_never_takes_an_ago_test() {
  assert attention_rule.age_line(FindItem("s", find("find-1", 0)), 30_000)
    == Some("noticed just now")
  assert attention_rule.age_line(FindItem("s", find("find-1", 0)), 300_000)
    == Some("noticed 5 min ago")
  assert attention_rule.age_line(
      StuckItem(
        "s",
        Stuck(
          strand: "x",
          failed_at: Some(0),
          reason: None,
          retry_after_ms: None,
          parent: None,
          operation: None,
        ),
      ),
      30_000,
    )
    == Some("stuck just now")
  assert attention_rule.age_line(AskItem("s", ask("ask-1", 0)), 30_000)
    == Some("waiting just now")
}

pub fn a_key_names_one_item_and_a_stale_key_names_none_test() {
  let items = attention_rule.items([#("s", row([ask("ask-1", 1)], [], []))])
  let key = attention_rule.key_of(AskItem("s", ask("ask-1", 1)))
  assert attention_rule.find_item(items, key)
    == Some(AskItem("s", ask("ask-1", 1)))

  // The same identity as a stuck strand is not the ask.
  assert attention_rule.find_item(
      items,
      attention_rule.Key(attention_rule.StuckSort, "s", "ask-1"),
    )
    == None
  assert attention_rule.find_item([], key) == None
}

pub fn a_restart_with_an_approval_pending_is_still_counted_test() {
  // After a restart nothing runs: every session is saved, and the catalogue's
  // summary is the only source. An approval and an ask there still count.
  let tally =
    attention_rule.tally([
      SavedCounted(Saved("a", 1, 1, 2, Some(5), 9)),
      SavedCounted(Saved("b", 0, 0, 0, None, 9)),
      SavedUnread,
    ])
  assert tally == attention_rule.Tally(2, 2, 0, 2, 1)
  assert attention_rule.headline(tally)
    == "2 need you · 2 finds · 0 running sessions read live, 2 saved from the catalogue, 1 not checked"
}

pub fn running_sessions_count_their_rows_and_an_activity_approval_test() {
  let tally =
    attention_rule.tally([
      Running(Pending, row([ask("ask-1", 1)], [find("find-1", 1)], [])),
      Running(
        NotPending,
        row([], [], [
          Stuck(
            strand: "x",
            failed_at: None,
            reason: None,
            retry_after_ms: None,
            parent: None,
            operation: None,
          ),
        ]),
      ),
      RunningUnread(Pending),
    ])

  // Two approvals (one with a row, one without), one ask, one stuck strand.
  assert tally == attention_rule.Tally(4, 1, 3, 0, 1)
  assert attention_rule.headline(attention_rule.Tally(0, 0, 1, 0, 0))
    == "Nothing needs you · 1 running session read live, 0 saved from the catalogue"
  assert attention_rule.headline(attention_rule.Tally(1, 1, 1, 0, 0))
    == "1 needs you · 1 find · 1 running session read live, 0 saved from the catalogue"
}
