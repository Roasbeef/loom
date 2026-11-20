//// The review's reading of a session's committed work
//// (`web_view/committed_patch`, merged into the review by
//// `web_view/review_feed.of_board`, protocol-change/123's addendum): the files a
//// stream of commits touched, their hunks and counts, text that only looks like
//// a patch, a stream cut in a hunk, and the bounds a review keeps whatever the
//// stream holds.

import core/json
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import qcheck
import session_view/diff_view
import session_view/worktree_view
import web_view/committed_patch
import web_view/review_feed

/// The qcheck seed every property here is drawn from, fixed so the gate is
/// deterministic.
const seed = 20_261_124

const two_commits =
  "commit bbbb222
Fix the second thing

diff --git a/src/b.gleam b/src/b.gleam
index 1111111..2222222 100644
--- a/src/b.gleam
+++ b/src/b.gleam
@@ -4,2 +4,3 @@ pub fn b() {
 keep
+added later
 tail
diff --git a/docs/n.md b/docs/n.md
deleted file mode 100644
index 3333333..0000000
--- a/docs/n.md
+++ /dev/null
@@ -1,2 +0,0 @@
-one
-two
commit aaaa111
Start the first thing

diff --git a/src/b.gleam b/src/b.gleam
new file mode 100644
index 0000000..1111111
--- /dev/null
+++ b/src/b.gleam
@@ -0,0 +1,2 @@
+pub fn b() {
+  keep
"

fn board(committed: String, extent: String) -> worktree_view.Board {
  worktree_view.Board(
    request_id: 0,
    observed_at_ms: 1_763_400_000_000,
    repository: "head",
    files: [],
    total: 0,
    omitted: 0,
    extent: "complete",
    committed: worktree_view.Committed("Commits", committed, extent),
  )
}

fn counts(entry: committed_patch.Entry) -> #(Int, Int) {
  #(
    list.count(entry.lines, fn(line) { line.kind == diff_view.Added }),
    list.count(entry.lines, fn(line) { line.kind == diff_view.Removed }),
  )
}

pub fn an_empty_stream_has_no_files_test() {
  let parsed = committed_patch.parse("")

  assert parsed.entries == []
  assert parsed.skipped == 0
  assert parsed.last == None
}

pub fn commits_are_joined_by_path_oldest_first_test() {
  let parsed = committed_patch.parse(two_commits)

  // The path touched by both commits appears once, at its oldest section.
  assert list.map(parsed.entries, fn(entry) { entry.path })
    == ["src/b.gleam", "docs/n.md"]
  let assert [b, notes] = parsed.entries

  // Created by the oldest commit and changed by the newest, so it is created,
  // and its lines are the oldest commit's then the newest's.
  assert b.status == committed_patch.Created
  assert b.body == committed_patch.TextBody
  assert counts(b) == #(3, 0)
  assert list.map(list.take(b.lines, 1), fn(line) { line.kind })
    == [diff_view.Hunk]
  assert notes.status == committed_patch.Removed
  assert counts(notes) == #(0, 2)
  assert parsed.skipped == 0
  assert parsed.last == Some("src/b.gleam")
}

pub fn a_subject_that_reads_like_a_patch_is_not_one_test() {
  let stream =
    "commit cccc333
diff --git a/evil.sh b/evil.sh

diff --git a/src/a.gleam b/src/a.gleam
index 1111111..2222222 100644
--- a/src/a.gleam
+++ b/src/a.gleam
@@ -1,1 +1,2 @@
 keep
+diff --git a/also/evil b/also/evil
"
  let parsed = committed_patch.parse(stream)

  // The subject line is dropped with its commit line, and a line inside a hunk
  // is a hunk line whatever it says.
  assert list.map(parsed.entries, fn(entry) { entry.path }) == ["src/a.gleam"]
  assert parsed.skipped == 0
}

pub fn a_binary_file_and_a_mode_change_have_no_text_test() {
  let stream =
    "commit dddd444
Binary and mode

diff --git a/logo.png b/logo.png
index 1111111..2222222 100644
Binary files a/logo.png and b/logo.png differ
diff --git a/run.sh b/run.sh
old mode 100644
new mode 100755
"
  let assert [logo, run] = committed_patch.parse(stream).entries

  assert logo.body == committed_patch.BinaryBody
  assert logo.lines == []
  assert run.body == committed_patch.ModeBody
}

pub fn a_path_with_a_space_and_a_quoted_path_are_told_apart_test() {
  let stream =
    "commit eeee555
Names

diff --git a/my file.txt b/my file.txt
index 1111111..2222222 100644
--- a/my file.txt
+++ b/my file.txt
@@ -1,1 +1,1 @@
-a
+b
diff --git \"a/caf\\303\\251.txt\" \"b/caf\\303\\251.txt\"
index 1111111..2222222 100644
@@ -1,1 +1,1 @@
-a
+b
"
  let parsed = committed_patch.parse(stream)

  assert list.map(parsed.entries, fn(entry) { entry.path }) == ["my file.txt"]
  assert parsed.skipped == 1
}

pub fn a_stream_cut_in_a_hunk_keeps_the_lines_it_has_test() {
  let stream =
    "commit ffff666
Cut

diff --git a/src/a.gleam b/src/a.gleam
index 1111111..2222222 100644
--- a/src/a.gleam
+++ b/src/a.gleam
@@ -1,9 +1,9 @@
 one
-two
+TWO
 thr"
  let assert [entry] = committed_patch.parse(stream).entries

  assert counts(entry) == #(1, 1)
}

pub fn the_review_carries_committed_files_and_marks_a_cut_stream_test() {
  let review = review_feed.of_board(board(two_commits, "limited"))

  assert list.map(review.files, fn(file) { file.path })
    == ["src/b.gleam", "docs/n.md"]
  assert review.stat.files == 2
  assert review.stat.added == 3
  assert review.stat.removed == 2
  assert review.extent == review_feed.Cut

  let assert [b, notes] = review.files
  assert b.change == review_feed.Added
  assert b.extent == review_feed.Cut
  assert notes.change == review_feed.Deleted
  assert notes.extent == review_feed.Whole
}

pub fn a_file_in_both_shows_the_working_tree_over_the_committed_hunks_test() {
  let working =
    worktree_view.File(
      path: "src/b.gleam",
      index_status: " ",
      worktree_status: "M",
      patch: "diff --git a/src/b.gleam b/src/b.gleam
--- a/src/b.gleam
+++ b/src/b.gleam
@@ -1,1 +1,1 @@
-WORKING-OLD
+WORKING-NEW
",
      kind: "text",
      extent: "complete",
    )
  let base = board(two_commits, "complete")
  let review =
    review_feed.of_board(
      worktree_view.Board(..base, files: [working], total: 1),
    )
  let assert Ok(file) =
    list.find(review.files, fn(each) { each.path == "src/b.gleam" })

  // One file, a working change, with the working hunk first.
  assert review.stat.files == 2
  assert file.change == review_feed.Modified
  let assert [first, ..rest] = file.hunks
  assert list.any(first.lines, fn(line) { line.text == "WORKING-NEW" })
  assert rest != []
  assert file.added == 4
  assert file.removed == 1
}

// A stream of commits that touch up to ten paths, each with up to three hunks.
// A hunk has one context line, some removed lines and some added lines, so the
// counts a stream should be read as are known from the numbers that made it.
type Made {
  Made(path: Int, hunks: List(#(Int, Int, Int)))
}

fn made() -> qcheck.Generator(List(Made)) {
  let hunk =
    qcheck.map3(
      qcheck.bounded_int(from: 0, to: 4),
      qcheck.bounded_int(from: 0, to: 6),
      qcheck.bounded_int(from: 1, to: 600),
      fn(removed, added, width) { #(removed, added, width) },
    )
  let file =
    qcheck.map2(
      qcheck.bounded_int(from: 0, to: 9),
      qcheck.generic_list(hunk, qcheck.bounded_int(from: 1, to: 3)),
      fn(path, hunks) { Made(path:, hunks:) },
    )

  qcheck.generic_list(file, qcheck.bounded_int(from: 1, to: 6))
}

fn stream_of(files: List(Made)) -> String {
  files
  |> list.index_map(fn(file, commit) {
    let name = "src/f" <> int.to_string(file.path) <> ".gleam"
    "commit "
    <> string.pad_start(int.to_string(commit + 4096), 7, "a")
    <> "\nSubject "
    <> int.to_string(commit)
    <> "\n\ndiff --git a/"
    <> name
    <> " b/"
    <> name
    <> "\nindex 1111111..2222222 100644\n--- a/"
    <> name
    <> "\n+++ b/"
    <> name
    <> "\n"
    <> string.join(list.map(file.hunks, hunk_of), "\n")
    <> "\n"
  })
  |> string.join("")
}

fn hunk_of(hunk: #(Int, Int, Int)) -> String {
  let #(removed, added, width) = hunk
  let line = fn(mark) { mark <> string.repeat("x", width) }
  let body =
    list.flatten([
      [" context"],
      list.repeat(line("-"), removed),
      list.repeat(line("+"), added),
    ])

  "@@ -1,"
  <> int.to_string(1 + removed)
  <> " +1,"
  <> int.to_string(1 + added)
  <> " @@\n"
  <> string.join(body, "\n")
}

pub fn a_stream_is_read_back_to_the_counts_that_made_it_test() {
  qcheck.default_config()
  |> qcheck.with_test_count(150)
  |> qcheck.with_seed(qcheck.seed(seed))
  |> qcheck.run(made(), fn(files) {
    let parsed = committed_patch.parse(stream_of(files))
    let expected = fn(of_path) {
      list.filter(files, fn(file) { file.path == of_path })
      |> list.flat_map(fn(file) { file.hunks })
      |> list.fold(#(0, 0), fn(sum, hunk) { #(sum.0 + hunk.1, sum.1 + hunk.0) })
    }

    // Every path made is one entry, with the sums of its hunks' lines.
    assert parsed.skipped == 0
    assert list.length(parsed.entries)
      == list.length(list.unique(list.map(files, fn(file) { file.path })))
    assert list.all(parsed.entries, fn(entry) {
      let of_path =
        entry.path
        |> string.drop_start(string.length("src/f"))
        |> string.drop_end(string.length(".gleam"))
        |> int.parse
      case of_path {
        Ok(number) -> counts(entry) == expected(number)
        Error(Nil) -> False
      }
    })
  })
}

pub fn a_review_keeps_every_bound_whatever_the_commits_hold_test() {
  qcheck.default_config()
  |> qcheck.with_test_count(100)
  |> qcheck.with_seed(qcheck.seed(seed))
  |> qcheck.run(made(), fn(files) {
    let review = review_feed.of_board(board(stream_of(files), "complete"))

    assert list.length(review.files) <= review_feed.max_files
    assert string.byte_size(json.to_string(review_feed.encode(review)))
      <= review_feed.max_bytes
    assert list.all(review.files, fn(file) {
      list.length(file.hunks) <= review_feed.max_hunks
      && list.all(file.hunks, fn(hunk) {
        list.length(hunk.lines) <= review_feed.max_hunk_lines
        && list.all(hunk.lines, fn(line) {
          string.byte_size(line.text) <= review_feed.max_line_bytes
        })
      })
    })
  })
}

pub fn text_that_is_not_a_patch_never_breaks_the_reader_test() {
  let lines =
    qcheck.generic_list(
      qcheck.from_generators(qcheck.return("x"), [
        qcheck.return("commit abcd123"),
        qcheck.return("diff --git a/x b/x"),
        qcheck.return("@@ -1,5 +1,5 @@"),
        qcheck.return("+added"),
        qcheck.return("-gone"),
        qcheck.return(" same"),
        qcheck.return(""),
        qcheck.return("\\ No newline at end of file"),
      ]),
      qcheck.bounded_int(from: 0, to: 40),
    )

  qcheck.default_config()
  |> qcheck.with_test_count(200)
  |> qcheck.with_seed(qcheck.seed(seed))
  |> qcheck.run(lines, fn(text) {
    let parsed = committed_patch.parse(string.join(text, "\n"))

    // However the lines fall, the reader returns, and it invents no line: a
    // file's lines never outnumber the stream's.
    assert list.all(parsed.entries, fn(entry) {
      list.length(entry.lines) <= list.length(text)
    })
  })
}
