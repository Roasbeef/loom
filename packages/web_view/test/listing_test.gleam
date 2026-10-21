//// How the sidebar groups, tags and filters sessions (`web_view/listing`).
////
//// These tests pin the rules the sidebar and the composer share: which group a
//// session is in by what it needs, how the placement tag is worded for a folder, a
//// worktree and an executor's workspace, which pills are offered and what they
//// count, that a filter keeps the session on screen, and that a name no pill
//// carries is never a filter.

import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import web_view/listing
import web_view/sessions.{type Entry, Entry, Live, Saved}

fn entry(
  id: String,
  workspace: String,
  created_at: Int,
  residency: sessions.Residency,
) -> Entry {
  Entry(
    id:,
    name: "session " <> id,
    workspace:,
    created_at:,
    residency:,
    subtitle: None,
    role: None,
    project: None,
    executor: None,
  )
}

fn on(entry: Entry, executor: String) -> Entry {
  Entry(..entry, executor: Some(executor))
}

fn ids(rows: List(listing.Row)) -> List(String) {
  list.map(rows, fn(row) { row.entry.id })
}

// A running session is in the group its activity names, a running session the
// read has not named is idle, and a session nothing runs is saved whatever the
// read says.
pub fn a_session_is_grouped_by_what_it_needs_test() {
  let rows = [
    entry("A", "/w/a", 5, Live),
    entry("B", "/w/b", 4, Live),
    entry("C", "/w/c", 3, Live),
    entry("D", "/w/d", 2, Live),
    entry("E", "/w/e", 1, Saved),
  ]
  let activity =
    dict.from_list([
      #("A", sessions.NeedsYou),
      #("B", sessions.Working),
      #("C", sessions.Failed),
      #("E", sessions.Working),
    ])
  let sorted = listing.sorted(rows, activity, "laptop", listing.Everywhere, "")

  assert ids(sorted.needs) == ["A"]
  assert ids(sorted.working) == ["B"]

  // A failed run waits on nothing but a new message, and an unnamed session has
  // no evidence of work.
  assert ids(sorted.idle) == ["C", "D"]
  assert ids(sorted.saved) == ["E"]
}

// Each group is newest first, whatever order the groups of the page arrive in.
pub fn the_entries_of_every_group_are_newest_first_test() {
  let groups =
    sessions.grouped([
      entry("A", "/w/a", 1, Live),
      entry("B", "/w/b", 3, Live),
      entry("C", "/w/a", 2, Live),
    ])

  assert list.map(listing.entries(groups), fn(each) { each.id })
    == ["B", "C", "A"]
}

// The tag says the machine that runs the agent and where the code is: a folder as
// its last two directories, a worktree by its repository and its name, and a
// workspace on an executor by both names.
pub fn the_tag_words_name_the_agent_and_the_code_test() {
  let folder = entry("A", "/Users/o/src/loom", 1, Live)
  assert listing.place(folder, "laptop")
    == listing.Place("laptop", listing.Folder("/Users/o/src/loom"))
  assert listing.code_words(listing.Folder("/Users/o/src/loom")) == "…/src/loom"
  assert listing.short_path("/a/b") == "/a/b"

  let remote = on(entry("B", "repo", 1, Live), "exec")
  assert listing.place(remote, "laptop").code
    == listing.Registered("exec", "repo")
  assert listing.entry_words(remote, listing.place(remote, "laptop"))
    == "exec · repo"

  let tree =
    Entry(
      ..entry("C", "/src/btcd/.claude/worktrees/calm", 1, Live),
      project: Some("/src/btcd"),
    )
  assert listing.entry_words(tree, listing.place(tree, "laptop"))
    == "btcd · calm"
}

// A pill filters by the machine an agent or its code is on. The daemon's own
// pill would match every row, so it is left out, and a list that uses one machine
// has no pill at all.
pub fn the_pills_are_the_machines_that_tell_rows_apart_test() {
  assert listing.pills([], "laptop") == []

  let local = [entry("A", "/w/a", 1, Live), entry("B", "/w/b", 2, Live)]
  assert listing.pills(local, "laptop") == []

  let mixed = [
    entry("A", "/w/a", 1, Live),
    on(entry("B", "repo", 2, Live), "exec"),
    on(entry("C", "app", 3, Live), "exec"),
    on(entry("D", "app", 4, Live), "gpu"),
  ]
  assert listing.pills(mixed, "laptop")
    == [listing.Pill("exec", 2), listing.Pill("gpu", 1)]
}

// A filter keeps the rows that touch the machine, and the session on screen stays
// listed whatever the filter says, so a person always sees where they are.
pub fn a_filter_keeps_the_session_on_screen_test() {
  let rows = [
    on(entry("B", "repo", 2, Live), "exec"),
    entry("A", "/w/a", 1, Live),
  ]
  let narrowed =
    listing.sorted(rows, dict.new(), "laptop", listing.On("exec"), "")
  assert ids(narrowed.idle) == ["B"]

  let held = listing.sorted(rows, dict.new(), "laptop", listing.On("exec"), "A")
  assert ids(held.idle) == ["B", "A"]
}

// The session on screen is among the running ones even when nothing runs it, and
// its own row still says it is saved.
pub fn a_saved_session_on_screen_is_listed_above_the_fold_test() {
  let rows = [entry("A", "/w/a", 1, Saved), entry("B", "/w/b", 2, Saved)]
  let sorted =
    listing.sorted(rows, dict.new(), "laptop", listing.Everywhere, "A")

  assert ids(sorted.idle) == ["A"]
  assert ids(sorted.saved) == ["B"]
}

// A press names a machine the server drew, and the page accepts it only if the
// list it holds offers a pill by that name, so a forged name is no filter.
pub fn a_name_no_pill_carries_is_not_a_filter_test() {
  let rows = [
    on(entry("A", "repo", 1, Live), "exec"),
    entry("B", "/w", 2, Live),
  ]

  assert listing.chosen(rows, "laptop", "exec") == Ok(listing.On("exec"))
  assert listing.chosen(rows, "laptop", "box") == Error(Nil)
  assert listing.chosen(rows, "laptop", "") == Error(Nil)

  // The daemon's own name has no pill when it would match every row.
  assert listing.chosen(rows, "laptop", "laptop") == Error(Nil)
}

// The sessions waiting on an approval are the ones the phone counts.
pub fn the_waiting_sessions_are_those_needing_an_approval_test() {
  let rows = [entry("A", "/w/a", 1, Live), entry("B", "/w/b", 2, Live)]
  let activity =
    dict.from_list([#("A", sessions.NeedsYou), #("B", sessions.Working)])

  assert list.map(listing.waiting(rows, activity), fn(each) { each.id })
    == ["A"]
  assert listing.waiting(rows, dict.new()) == []
}
