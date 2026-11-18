//// The attention inbox's rule (`web_view/inbox_rule`): the group and kind of a
//// session from its report, where the page lands, a thread's head and the
//// headline's words.
////
//// These tests pin the stand-ins phase 0 makes. An idle session that said
//// something is `Waiting` and never an ask; ordering is by name and nothing
//// prints an age; a landing needs something to read or do; and no head is
//// longer than the cap or splits a grapheme.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import qcheck
import web_view/inbox_rule
import web_view/sessions.{type Activity, type Report, Glance, Report}

const seed = 20_261_118

fn report(activity: Activity, message: option.Option(String)) -> Report {
  Report(activity:, last_message: message, glances: [])
}

fn thread(id: String, name: String, report: Report) -> inbox_rule.Thread {
  inbox_rule.Thread(id:, name:, workspace: "", report:)
}

fn activities() -> List(Activity) {
  [sessions.NeedsYou, sessions.Failed, sessions.Working, sessions.Idle]
}

// Every activity with every kind of message: none, only whitespace, and words.
pub fn every_activity_and_message_has_one_group_test() {
  let messages = [None, Some("   \n"), Some("Done.")]

  let found =
    list.flat_map(activities(), fn(activity) {
      list.map(messages, fn(message) {
        #(activity, message, inbox_rule.group(report(activity, message)))
      })
    })

  assert found
    == [
      #(sessions.NeedsYou, None, inbox_rule.NeedsYou),
      #(sessions.NeedsYou, Some("   \n"), inbox_rule.NeedsYou),
      #(sessions.NeedsYou, Some("Done."), inbox_rule.NeedsYou),
      #(sessions.Failed, None, inbox_rule.NeedsYou),
      #(sessions.Failed, Some("   \n"), inbox_rule.NeedsYou),
      #(sessions.Failed, Some("Done."), inbox_rule.NeedsYou),
      #(sessions.Working, None, inbox_rule.Updates),
      #(sessions.Working, Some("   \n"), inbox_rule.Updates),
      #(sessions.Working, Some("Done."), inbox_rule.Updates),
      #(sessions.Idle, None, inbox_rule.Quiet),
      #(sessions.Idle, Some("   \n"), inbox_rule.Quiet),
      #(sessions.Idle, Some("Done."), inbox_rule.Waiting),
    ]
}

pub fn the_kind_comes_from_the_activity_test() {
  assert inbox_rule.kind(report(sessions.NeedsYou, None))
    == inbox_rule.ApprovalPending
  assert inbox_rule.kind(report(sessions.Failed, Some("x")))
    == inbox_rule.Failed
  assert inbox_rule.kind(report(sessions.Working, Some("x")))
    == inbox_rule.Working
  assert inbox_rule.kind(report(sessions.Idle, Some("x"))) == inbox_rule.Idle
  assert inbox_rule.kind(report(sessions.Idle, None)) == inbox_rule.Settled
}

pub fn the_kinds_have_their_words_test() {
  assert list.map(
      [
        inbox_rule.ApprovalPending,
        inbox_rule.Failed,
        inbox_rule.Idle,
        inbox_rule.Working,
        inbox_rule.Settled,
      ],
      inbox_rule.words,
    )
    == ["Approval", "Failed", "Waiting", "Update", "Quiet"]
}

pub fn the_page_lands_on_the_inbox_only_when_something_waits_or_runs_test() {
  assert inbox_rule.landing([]) == inbox_rule.Form
  assert inbox_rule.landing([report(sessions.Idle, None)]) == inbox_rule.Form
  assert inbox_rule.landing([
      report(sessions.Idle, Some("")),
      report(sessions.Idle, None),
    ])
    == inbox_rule.Form

  assert inbox_rule.landing([report(sessions.Idle, Some("Done."))])
    == inbox_rule.Inbox
  assert inbox_rule.landing([report(sessions.Working, None)])
    == inbox_rule.Inbox
  assert inbox_rule.landing([report(sessions.Failed, None)]) == inbox_rule.Inbox
  assert inbox_rule.landing([
      report(sessions.Idle, None),
      report(sessions.NeedsYou, None),
    ])
    == inbox_rule.Inbox
}

// The head is the first line with words, else the newest glance, else the
// kind's words.
pub fn the_head_falls_back_in_order_test() {
  let glances = [
    Glance(strand: "s1", title: "", summary: "newest"),
    Glance(strand: "s2", title: "", summary: "older"),
  ]

  assert inbox_rule.head(report(sessions.Idle, Some("\n  First line  \nSecond")))
    == "First line"

  assert inbox_rule.head(Report(sessions.Working, None, glances)) == "newest"
  assert inbox_rule.head(Report(sessions.Working, Some(" \n "), glances))
    == "newest"

  assert inbox_rule.head(report(sessions.Working, None)) == "Update"
  assert inbox_rule.head(report(sessions.NeedsYou, None)) == "Approval"
  assert inbox_rule.head(report(sessions.Failed, None)) == "Failed"
  assert inbox_rule.head(report(sessions.Idle, None)) == "Quiet"
  assert inbox_rule.head(Report(sessions.Idle, None, [Glance("s", "t", "  ")]))
    == "Quiet"
}

pub fn a_long_head_is_cut_inside_the_cap_test() {
  let exact = string.repeat("a", inbox_rule.head_graphemes)
  assert inbox_rule.head(report(sessions.Idle, Some(exact))) == exact

  let over = string.repeat("a", inbox_rule.head_graphemes + 1)
  let cut = inbox_rule.head(report(sessions.Idle, Some(over)))
  assert string.length(cut) == inbox_rule.head_graphemes
  assert string.ends_with(cut, "…")
}

// A combined character is one grapheme, so the cut keeps or drops all of it.
pub fn the_cut_never_splits_a_grapheme_test() {
  let family = "👨‍👩‍👧"
  let line = string.repeat(family, 200)
  let cut = inbox_rule.head(report(sessions.Idle, Some(line)))

  assert string.length(cut) == inbox_rule.head_graphemes
  assert string.to_graphemes(cut)
    == list.append(list.repeat(family, inbox_rule.head_graphemes - 1), ["…"])
}

pub fn no_head_is_longer_than_the_cap_test() {
  let config =
    qcheck.default_config()
    |> qcheck.with_test_count(200)
    |> qcheck.with_seed(qcheck.seed(seed))

  qcheck.run(config, qcheck.string(), fn(text) {
    let head = inbox_rule.head(report(sessions.Idle, Some(text)))
    assert string.length(head) <= inbox_rule.head_graphemes
    assert !string.contains(head, "\n")
  })
}

pub fn threads_are_grouped_in_order_and_sorted_by_name_test() {
  let threads = [
    thread("1", "zeta", report(sessions.Working, None)),
    thread("2", "beta", report(sessions.Idle, Some("Hi"))),
    thread("3", "alpha", report(sessions.NeedsYou, None)),
    thread("4", "Alpha", report(sessions.Failed, None)),
    thread("5", "quiet one", report(sessions.Idle, None)),
    thread("6", "alpha", report(sessions.NeedsYou, None)),
  ]

  let ids =
    inbox_rule.grouped(threads)
    |> list.map(fn(entry) {
      #(entry.0, list.map(entry.1, fn(each) { each.id }))
    })

  // Same-named threads fall back to the identity, and capitals sort first.
  assert ids
    == [
      #(inbox_rule.NeedsYou, ["4", "3", "6"]),
      #(inbox_rule.Waiting, ["2"]),
      #(inbox_rule.Updates, ["1"]),
      #(inbox_rule.Quiet, ["5"]),
    ]
}

pub fn an_empty_group_is_not_listed_test() {
  assert inbox_rule.grouped([]) == []

  let only = [thread("1", "a", report(sessions.Working, None))]
  assert list.map(inbox_rule.grouped(only), fn(entry) { entry.0 })
    == [inbox_rule.Updates]
}

pub fn the_group_words_test() {
  assert list.map(
      [
        inbox_rule.NeedsYou,
        inbox_rule.Waiting,
        inbox_rule.Updates,
        inbox_rule.Quiet,
      ],
      inbox_rule.group_words,
    )
    == ["Needs you", "Waiting", "Updates", "Quiet"]
}

pub fn the_selection_defaults_to_the_first_thread_and_forgets_stale_choices_test() {
  let groups =
    inbox_rule.grouped([
      thread("w", "work", report(sessions.Working, None)),
      thread("n", "need", report(sessions.NeedsYou, None)),
    ])

  assert inbox_rule.selection(groups, None) == Some("n")
  assert inbox_rule.selection(groups, Some("w")) == Some("w")
  assert inbox_rule.selection(groups, Some("gone")) == Some("n")
  assert inbox_rule.selection([], Some("w")) == None
  assert inbox_rule.selection([], None) == None
}

pub fn the_headline_says_what_it_read_test() {
  let needing = report(sessions.NeedsYou, None)
  let failed = report(sessions.Failed, None)
  let working = report(sessions.Working, None)

  assert inbox_rule.headline([needing, failed, working], 6)
    == "2 need you · in 6 running sessions, 3 answered; saved sessions not checked"
  assert inbox_rule.headline([needing, working], 2)
    == "1 needs you · in 2 running sessions; saved sessions not checked"
  assert inbox_rule.headline([working], 1)
    == "Nothing needs you · in 1 running session; saved sessions not checked"
  assert inbox_rule.headline([], 0)
    == "Nothing needs you · in 0 running sessions; saved sessions not checked"
}

// Whatever the reports, the landing is the inbox exactly when some group other
// than the quiet one is occupied.
pub fn the_landing_agrees_with_the_groups_test() {
  let config =
    qcheck.default_config()
    |> qcheck.with_test_count(200)
    |> qcheck.with_seed(qcheck.seed(seed))

  let generated =
    qcheck.generic_list(
      qcheck.map2(
        qcheck.from_generators(qcheck.return(sessions.Idle), [
          qcheck.return(sessions.Working),
          qcheck.return(sessions.NeedsYou),
          qcheck.return(sessions.Failed),
        ]),
        qcheck.option_from(qcheck.string()),
        report,
      ),
      qcheck.bounded_int(from: 0, to: 8),
    )

  qcheck.run(config, generated, fn(reports) {
    let occupied =
      list.any(reports, fn(each) { inbox_rule.group(each) != inbox_rule.Quiet })

    assert { inbox_rule.landing(reports) == inbox_rule.Inbox } == occupied
  })
}
