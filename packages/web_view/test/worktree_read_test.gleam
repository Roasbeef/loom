//// The Changes tab's read of the workspace's Git tree (protocol-change/051,
//// the addendum on the worktree read).
////
//// The first group draws `view/changes` from an observation, which is the
//// pane's whole contract: the diff drawer, the counts, the bounds it was
//// handed, the commits since the session started, the sentences for a
//// workspace that is not a checkout or a page that may not read it, and every
//// repository string arriving as escaped text. The second group drives the
//// component through its clock and a transport that records its asks, and pins
//// when the page asks: once when it opens, again only after a tool result it
//// has not read since and a quiet interval, never twice at once, and never on
//// an observer's page.

import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lane_fixture
import lustre/element
import page_fixture
import session_view/changes_view
import session_view/worktree_view.{Board, Committed, File}
import web_view/component
import web_view/operator_page
import web_view/view/changes
import web_view/worktrees

const edit = "@@ -1 +1 @@\n-old line\n+new line"

fn patch(body: String) -> String {
  "diff --git a/f b/f\nindex 1..2 100644\n--- a/f\n+++ b/f\n" <> body
}

fn text_file(path: String, body: String) -> worktree_view.File {
  File(path, " ", "M", patch(body), "text", "complete")
}

fn board(
  repository: String,
  files: List(worktree_view.File),
  omitted: Int,
) -> worktree_view.Board {
  Board(
    0,
    5,
    repository,
    files,
    list.length(files) + omitted,
    omitted,
    case omitted {
      0 -> "complete"
      _ -> "limited"
    },
    Committed("2 commits since session start", "", "complete"),
  )
}

fn drawn(read: worktrees.Read) -> String {
  element.to_string(changes.view(
    changes_view.empty(),
    changes.Whole,
    read,
    None,
  ))
}

// A workspace of a Git checkout draws the daemon's observation: the heading
// counts the files, the label says what they are compared against, the first
// file is open, and each diff is the shared red and green drawer.
pub fn an_observed_checkout_draws_the_diff_against_head_test() {
  let html =
    drawn(
      worktrees.Seen(board(
        "head",
        [text_file("src/a.gleam", edit), text_file("notes.md", edit)],
        0,
      )),
    )

  assert string.contains(html, "pane pane-changes")
  assert string.contains(html, " · 2 files")
  assert string.contains(html, "git diff against HEAD")
  assert string.contains(html, "src/a.gleam")
  assert string.contains(html, "modified · +1 -1")
  assert string.contains(html, "diff-row diff-added")
  assert string.contains(html, "diff-row diff-removed")
  assert string.contains(
    html,
    "<details data-lustre-key=\"file:src/a.gleam\" class=\"changes-file\" open>",
  )
  assert string.contains(html, "2 commits since session start")
  assert !string.contains(html, "No edits yet.")
}

// A repository before its first commit says so in the label, and a clean
// workspace says there is nothing uncommitted rather than drawing an empty
// board.
pub fn an_unborn_or_clean_workspace_says_so_test() {
  let unborn = drawn(worktrees.Seen(board("unborn", [], 0)))
  assert string.contains(unborn, "before its first commit")
  assert string.contains(unborn, "No uncommitted changes in the workspace.")
  assert !string.contains(unborn, "changes-file")
}

// The daemon's bounds are drawn and not hidden: files it left out are counted,
// a patch it cut says so under the diff and marks its counts as partial, and a
// binary file, a nested repository and a file with no net change say so in
// fixed words and draw no diff.
pub fn the_bounds_are_drawn_test() {
  let cut = File("big.txt", " ", "M", patch(edit), "text", "limited")
  let binary = File("logo.png", "?", "?", "", "binary", "complete")
  let nested = File("vendor/", "?", "?", "", "metadata_only", "complete")
  let same = File("same.txt", " ", "M", "", "no_net_change", "complete")
  let html =
    drawn(worktrees.Seen(board("head", [cut, binary, nested, same], 3)))

  assert string.contains(html, "This diff is cut at the size limit.")
  assert string.contains(html, "modified · +1+ -1+")
  assert string.contains(html, "> new</span>")
  assert string.contains(html, "Binary file, not shown.")
  assert string.contains(html, "A directory or nested repository, not shown.")
  assert string.contains(html, "No net change.")
  assert string.contains(html, "3 more files not shown")
  assert string.contains(html, " · 7 files")
}

// Commits since the session started are a section of their own, drawn with the
// same drawer, and say when their patches were cut.
pub fn the_commits_since_the_start_are_a_section_test() {
  let observed =
    Board(
      ..board("head", [], 0),
      committed: Committed("1 commit since session start", edit, "limited"),
    )
  let html = drawn(worktrees.Seen(observed))

  assert string.contains(html, "1 commit since session start")
  assert string.contains(html, "diff-row diff-added")
  assert string.contains(html, "The commit patches are cut at the size limit.")
}

// A workspace that is not a checkout, a read the daemon refused and a read it
// could not make each fall back to the agent's own edits with one sentence
// that says why. A page that was never given the read draws no sentence.
pub fn a_read_that_gave_no_board_falls_back_with_a_reason_test() {
  let not_checkout = drawn(worktrees.Seen(board("not_repository", [], 0)))
  assert string.contains(not_checkout, "Not a git checkout")
  assert string.contains(not_checkout, "No edits yet.")
  assert !string.contains(not_checkout, "against HEAD")

  assert string.contains(
    drawn(worktrees.Declined),
    "This page may not read the workspace",
  )
  assert string.contains(
    drawn(worktrees.Unreadable),
    "could not be read just now",
  )

  list.each([worktrees.Withheld, worktrees.Unread], fn(read) {
    let html = drawn(read)
    assert string.contains(html, "No edits yet.")
    assert !string.contains(html, "may not read")
    assert !string.contains(html, "Not a git checkout")
  })
}

// The path and every diff line are repository text, so markup in either is
// escaped text and never an element, an attribute or a class.
pub fn markup_in_a_path_or_a_line_is_escaped_test() {
  let hostile = "<img src=x onerror=alert(1)>"
  let html =
    drawn(
      worktrees.Seen(board(
        "head",
        [
          text_file(
            "dir/" <> hostile <> ".gleam",
            "@@ -1 +1 @@\n-" <> hostile <> "\n+<script>x</script>",
          ),
        ],
        0,
      )),
    )

  assert !string.contains(html, "<img")
  assert !string.contains(html, "<script>")
  assert string.contains(html, "&lt;img src=x onerror=alert(1)&gt;")
  assert string.contains(html, "&lt;script&gt;x&lt;/script&gt;")
}

// A workspace under a hidden directory, where `.git` is a file that points at
// the main checkout's, is observed by the daemon as any checkout is: the pane
// draws the path as given, whatever its segments, and nothing in the page
// filters on a dot.
pub fn a_hidden_directory_path_is_drawn_like_any_other_test() {
  let path = ".claude/worktrees/x/.config/app.toml"
  let html = drawn(worktrees.Seen(board("head", [text_file(path, edit)], 0)))

  assert string.contains(html, path)
  assert string.contains(html, "modified · +1 -1")
}

// --- when the page asks ----------------------------------------------------

type Asks =
  process.Subject(Nil)

// An operator's page, with a clock the test sets, whose transport records each
// ask for the workspace and never answers on its own.
fn page(
  clock: page_fixture.Clock,
  asks: Asks,
) -> component.Model(page_fixture.Wire) {
  let start = page_fixture.start_with(clock)
  component.Start(
    ..start,
    transport: component.Transport(
      ..start.transport,
      worktree: Some(fn(_deliver) { process.send(asks, Nil) }),
      logins: None,
    ),
  )
  |> component.new
}

fn tick(model: component.Model(page_fixture.Wire)) {
  page_fixture.run(model, component.update, [component.Ticked])
}

fn asked(asks: Asks) -> Int {
  case process.receive(asks, 0) {
    Ok(Nil) -> 1 + asked(asks)
    Error(Nil) -> 0
  }
}

// The page asks once when it opens and then waits for the answer: a second
// message while the read is out asks nothing, so a slow observation is never
// doubled.
pub fn the_page_asks_once_when_it_opens_test() {
  let asks = process.new_subject()
  let _ = page(page_fixture.clock(), asks) |> tick |> tick

  assert asked(asks) == 1
}

// After an answer the page asks again only for a tool result it has not read
// since, and only once a quiet interval has passed since its last ask.
pub fn a_new_tool_result_asks_again_after_the_interval_test() {
  let clock = page_fixture.clock()
  let asks = process.new_subject()
  let model =
    page(clock, asks)
    |> component.apply([lane_fixture.edited([#("a.gleam", edit)])])
    |> tick
  assert asked(asks) == 1

  // The answer arrives. Nothing new has run, so nothing is asked, however
  // long the page has been open.
  let model =
    page_fixture.run(model, component.update, [
      component.Worktreed(worktrees.Unreadable),
    ])
  page_fixture.set(clock, worktrees.refresh_ms - 2)
  let model = tick(model)
  assert asked(asks) == 0

  // A second tool result inside the interval since the last ask waits for it.
  let model =
    model
    |> component.apply([
      lane_fixture.edited([#("a.gleam", edit), #("b.gleam", edit)]),
    ])
  page_fixture.set(clock, worktrees.refresh_ms - 1)
  let model = tick(model)
  assert asked(asks) == 0

  // Once the interval has passed, it asks once, and a further tick with
  // nothing new asks nothing.
  page_fixture.set(clock, worktrees.refresh_ms)
  let model = tick(model)
  assert asked(asks) == 1
  let _ = tick(model)
  assert asked(asks) == 0
}

// A read that never answered is lost after `lost_ms` and asked again, so a
// cancelled or crashed run does not leave the tab without a refresh for good.
pub fn a_lost_read_is_asked_again_test() {
  let clock = page_fixture.clock()
  let asks = process.new_subject()
  let model =
    page(clock, asks)
    |> component.apply([lane_fixture.edited([#("a.gleam", edit)])])
    |> tick
  assert asked(asks) == 1

  let model =
    model
    |> component.apply([
      lane_fixture.edited([#("a.gleam", edit), #("b.gleam", edit)]),
    ])
  page_fixture.set(clock, worktrees.lost_ms - 1)
  let model = tick(model)
  assert asked(asks) == 0

  page_fixture.set(clock, worktrees.lost_ms)
  let _ = tick(model)
  assert asked(asks) == 1
}

// A read the allowance refused is not a statement about the workspace, so it
// leaves the drawn diff in place, and the page asks again after the usual
// interval. An authority refusal, by contrast, replaces the diff.
pub fn a_throttled_read_keeps_the_drawn_diff_and_asks_again_test() {
  let clock = page_fixture.clock()
  let asks = process.new_subject()
  let model =
    page(clock, asks)
    |> component.apply([lane_fixture.edited([#("a.gleam", edit)])])
    |> tick
  assert asked(asks) == 1

  let model =
    page_fixture.run(model, component.update, [
      component.Worktreed(
        worktrees.Seen(board("head", [text_file("shell.txt", edit)], 0)),
      ),
      component.Worktreed(worktrees.Throttled),
    ])
  let html = element.to_string(component.view(model))
  assert string.contains(html, "shell.txt")
  assert string.contains(html, "git diff against HEAD")
  assert !string.contains(html, "could not be read")
  assert !string.contains(html, "may not read")

  page_fixture.set(clock, worktrees.refresh_ms)
  let _ = tick(model)
  assert asked(asks) == 1
}

// An observer's transport has no capability, so the page never asks and the
// tab lists the agent's own edits whatever message arrives.
pub fn a_page_without_the_capability_asks_nothing_test() {
  let model =
    page_fixture.start()
    |> component.new
    |> component.apply([lane_fixture.edited([#("a.gleam", edit)])])
    |> tick

  let html = element.to_string(component.view(model))
  assert string.contains(html, "a.gleam")
  assert string.contains(html, "from this session")
  assert !string.contains(html, "against HEAD")
}

// The daemon's answer replaces what both pages draw in the tab, and a later
// refusal replaces the board, so the tab never shows an observation the daemon
// has stopped vouching for.
pub fn the_answer_is_drawn_on_both_pages_and_a_refusal_replaces_it_test() {
  let model =
    page(page_fixture.clock(), process.new_subject())
    |> component.apply([lane_fixture.edited([#("a.gleam", edit)])])
  let seen =
    page_fixture.run(model, component.update, [
      component.Worktreed(
        worktrees.Seen(board("head", [text_file("shell.txt", edit)], 0)),
      ),
    ])

  list.each(
    [
      element.to_string(component.view(seen)),
      element.to_string(operator_page.view(seen)),
    ],
    fn(html) {
      assert string.contains(html, "shell.txt")
      assert string.contains(html, "against HEAD")
      assert !string.contains(html, "from this session")
    },
  )

  let refused =
    page_fixture.run(seen, component.update, [
      component.Worktreed(worktrees.Declined),
    ])
  let html = element.to_string(component.view(refused))
  assert !string.contains(html, "shell.txt")
  assert string.contains(html, "a.gleam")
  assert string.contains(html, "This page may not read the workspace")
}

// A workspace that is not a checkout draws one sentence that already says
// shell changes are not shown, and not the scope line a second time: the empty
// pane is that sentence and "No edits yet.", so the two never contradict.
pub fn a_non_checkout_says_its_scope_once_test() {
  let html = drawn(worktrees.Seen(board("not_repository", [], 0)))

  assert string.contains(html, "shell changes are not shown")
  assert !string.contains(html, "This tab lists edits")
  assert !string.contains(html, "No edits in this session")
}

// The file lines of a whole git diff are not drawn: the row above the diff
// names the file, and the object ids are noise. The hunk header and the lines
// stay, and the empty string a final newline leaves is not a row.
pub fn a_git_diff_draws_no_preamble_and_no_trailing_row_test() {
  let html =
    drawn(worktrees.Seen(board("head", [text_file("f", edit <> "\n")], 0)))

  assert string.contains(html, "diff-row diff-hunk")
  assert string.contains(html, "diff-row diff-added")
  assert !string.contains(html, "diff --git")
  assert !string.contains(html, "index 1..2")
  assert !string.contains(html, "--- a/f")
  assert !string.contains(html, "+++ b/f")
  assert !string.contains(html, "diff-file")
  assert list.length(string.split(html, "diff-row")) == 4
}
