//// The review pane's read of a worktree (protocol-change/123): files ordered
//// for reading, hunks read out of each patch, every bound holding and saying
//// how much it cut, and a decoder that is total.

import core/json
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import qcheck
import session_view/diff_view
import session_view/worktree_view
import web_view/review_feed.{Cut, Whole}

const seed = 20_261_123

fn observed(
  path: String,
  status: #(String, String),
  patch: String,
) -> worktree_view.File {
  worktree_view.File(
    path:,
    index_status: status.0,
    worktree_status: status.1,
    patch:,
    kind: "text",
    extent: "complete",
  )
}

fn board(files: List(worktree_view.File)) -> worktree_view.Board {
  worktree_view.Board(
    request_id: 0,
    observed_at_ms: 1_763_400_000_000,
    repository: "head",
    files:,
    total: list.length(files),
    omitted: 0,
    extent: "complete",
    committed: worktree_view.Committed("", "", "complete"),
  )
}

const one_hunk =
  "diff --git a/src/a.gleam b/src/a.gleam
index 1111111..2222222 100644
--- a/src/a.gleam
+++ b/src/a.gleam
@@ -1,3 +1,3 @@ pub fn a() {
 keep
-old
+new
 tail
"

// A patch of `hunks` hunks, each of `lines` added lines of `width` bytes.
fn patch_of(hunks: Int, lines: Int, width: Int) -> String {
  upto(hunks)
  |> list.map(fn(index) {
    let header = "@@ -" <> int.to_string(index) <> " +" <> int.to_string(index)
    let body =
      list.repeat("+" <> string.repeat("x", width), lines)
      |> string.join("\n")
    case lines {
      0 -> header <> " @@"
      _ -> header <> " @@\n" <> body
    }
  })
  |> string.join("\n")
}

// The numbers 1 to `count`.
fn upto(count: Int) -> List(Int) {
  list.repeat(Nil, count) |> list.index_map(fn(_, index) { index + 1 })
}

fn paths(review: review_feed.Review) -> List(String) {
  list.map(review.files, fn(file) { file.path })
}

// A file is read in one of three piles, and the piles are read source, tests,
// docs, with the path deciding inside a pile.
pub fn files_are_ordered_source_then_tests_then_docs_test() {
  let review =
    board([
      observed("docs/next.md", #(" ", "M"), ""),
      observed("src/b_test.gleam", #(" ", "M"), ""),
      observed("src/b.gleam", #(" ", "M"), ""),
      observed("test/a.gleam", #("A", " "), ""),
      observed("README.md", #(" ", "M"), ""),
      observed("src/a.gleam", #(" ", "M"), ""),
    ])
    |> review_feed.of_board

  assert paths(review)
    == [
      "src/a.gleam",
      "src/b.gleam",
      "src/b_test.gleam",
      "test/a.gleam",
      "README.md",
      "docs/next.md",
    ]
}

// A document is decided before a test, a test directory before a plain name,
// and an unknown file is source.
pub fn the_pile_of_a_path_is_decided_by_where_it_lives_and_what_it_is_test() {
  assert review_feed.section_of("tests/README.md") == review_feed.Docs
  assert review_feed.section_of("docs/diagram.svg") == review_feed.Docs
  assert review_feed.section_of("pkg/test/helper.gleam") == review_feed.Tests
  assert review_feed.section_of("pkg/login.test.ts") == review_feed.Tests
  assert review_feed.section_of("pkg/test_login.py") == review_feed.Tests
  assert review_feed.section_of("pkg/latest.gleam") == review_feed.Source
  assert review_feed.section_of("Makefile") == review_feed.Source
}

// Whatever mix of paths arrives, ordering keeps every file exactly once and
// never reads a test before a source file or a document before a test.
pub fn ordering_is_a_permutation_in_pile_order_test() {
  let pool = [
    "src/a.gleam", "src/b_test.gleam", "docs/x.md", "test/t.gleam", "z.gleam",
    "README.md", "pkg/spec/s.gleam", "pkg/m.gleam",
  ]
  let pick = qcheck.bounded_int(from: 0, to: 7)
  let config =
    qcheck.default_config()
    |> qcheck.with_test_count(300)
    |> qcheck.with_seed(qcheck.seed(seed))

  qcheck.run(
    config,
    qcheck.map3(pick, pick, pick, fn(a, b, c) { [a, b, c] }),
    fn(picks) {
      let chosen = list.filter_map(picks, fn(index) { list_at(pool, index) })
      let files =
        board(list.map(chosen, observed(_, #(" ", "M"), "")))
        |> review_feed.of_board
        |> fn(review) { review.files }
      let ranks =
        list.map(files, fn(file) {
          case file.section {
            review_feed.Source -> 0
            review_feed.Tests -> 1
            review_feed.Docs -> 2
          }
        })

      assert list.sort(list.map(files, fn(file) { file.path }), string.compare)
        == list.sort(chosen, string.compare)
      assert ranks == list.sort(ranks, int.compare)
    },
  )
}

fn list_at(items: List(a), index: Int) -> Result(a, Nil) {
  list.drop(items, index) |> list.first
}

// A patch is read into hunks with the line numbers the header gave, and the
// stat counts the lines that changed.
pub fn a_patch_is_read_into_hunks_and_counted_test() {
  let review =
    board([observed("src/a.gleam", #(" ", "M"), one_hunk)])
    |> review_feed.of_board

  assert review.stat == review_feed.Stat(1, 1, 1)
  assert review.extent == Whole
  let assert [file] = review.files
  assert file.change == review_feed.Modified
  assert file.content == review_feed.Text
  assert file.added == 1
  assert file.removed == 1
  assert file.extent == Whole
  let assert [hunk] = file.hunks
  assert hunk.header == "@@ -1,3 +1,3 @@ pub fn a() {"
  assert hunk.lines
    == [
      diff_view.Line(diff_view.Context, Some(1), Some(1), "keep"),
      diff_view.Line(diff_view.Removed, Some(2), None, "old"),
      diff_view.Line(diff_view.Added, None, Some(2), "new"),
      diff_view.Line(diff_view.Context, Some(3), Some(3), "tail"),
    ]
}

// An untracked or staged-new file is added, a removed one is deleted, and a
// file added and then removed is deleted.
pub fn status_letters_name_the_change_test() {
  let review =
    board([
      observed("a", #("?", "?"), ""),
      observed("b", #("A", " "), ""),
      observed("c", #(" ", "D"), ""),
      observed("d", #("A", "D"), ""),
      observed("e", #("M", " "), ""),
    ])
    |> review_feed.of_board

  assert list.map(review.files, fn(file) { file.change })
    == [
      review_feed.Added,
      review_feed.Added,
      review_feed.Deleted,
      review_feed.Deleted,
      review_feed.Modified,
    ]
}

// A binary file is named and shows nothing, and counts as a file in the stat.
pub fn a_binary_file_is_named_and_not_shown_test() {
  let binary =
    worktree_view.File(
      ..observed("assets/logo.png", #("A", " "), "Binary files differ"),
      kind: "binary",
    )
  let review = board([binary]) |> review_feed.of_board
  let assert [file] = review.files

  assert file.content == review_feed.Binary
  assert file.hunks == []
  assert file.added == 0
  assert review.stat == review_feed.Stat(1, 0, 0)
}

// The observation does not detect renames, so a moved file is the old path
// removed and the new path added, and both are reviewed.
pub fn a_renamed_file_is_a_removal_and_an_addition_test() {
  let review =
    board([
      observed("src/new_name.gleam", #("?", "?"), "@@ -0,0 +1 @@\n+hello"),
      observed("src/old_name.gleam", #(" ", "D"), "@@ -1 +0,0 @@\n-hello"),
    ])
    |> review_feed.of_board

  assert list.map(review.files, fn(file) { #(file.path, file.change) })
    == [
      #("src/new_name.gleam", review_feed.Added),
      #("src/old_name.gleam", review_feed.Deleted),
    ]
  assert review.stat == review_feed.Stat(2, 1, 1)
}

// A tree with nothing changed is an empty review that is whole, and a
// workspace that is not a checkout says so.
pub fn an_empty_diff_is_a_whole_empty_review_test() {
  let review = board([]) |> review_feed.of_board

  assert review.files == []
  assert review.stat == review_feed.Stat(0, 0, 0)
  assert review.extent == Whole
  assert review.repository == review_feed.Head

  let elsewhere =
    review_feed.of_board(
      worktree_view.Board(..board([]), repository: "not_repository"),
    )
  assert elsewhere.repository == review_feed.NotRepository
}

// A path that is absolute or climbs out of the workspace is not a workspace
// path: its file is left out and counted, never named.
pub fn a_path_outside_the_workspace_is_left_out_and_counted_test() {
  let review =
    board([
      observed("/etc/passwd", #(" ", "M"), one_hunk),
      observed("../up.gleam", #(" ", "M"), one_hunk),
      observed("a/../../b", #(" ", "M"), one_hunk),
      observed("src/ok.gleam", #(" ", "M"), one_hunk),
    ])
    |> review_feed.of_board

  assert paths(review) == ["src/ok.gleam"]
  assert review.omitted == 3
  assert review.extent == Cut
  assert review.stat.files == 4
}

// What the observation omitted, or cut inside a patch, is carried as a cut.
pub fn the_observations_own_limits_are_carried_test() {
  let limited =
    worktree_view.File(
      ..observed("a", #(" ", "M"), one_hunk),
      extent: "limited",
    )
  let review =
    worktree_view.Board(
      ..board([limited]),
      total: 30,
      omitted: 29,
      extent: "limited",
    )
    |> review_feed.of_board
  let assert [file] = review.files

  assert file.extent == Cut
  assert review.extent == Cut
  assert review.omitted == 29
  assert review.stat.files == 30
}

// One file just past each per-file bound shows the cut and counts it. These
// fit the byte bound, so unlike the property below they cannot be emptied by it.
fn single(hunks: Int, lines: Int, width: Int) -> review_feed.File {
  let review =
    board([observed("src/a.gleam", #(" ", "M"), patch_of(hunks, lines, width))])
    |> review_feed.of_board
  let assert [file] = review.files
  assert review.omitted == 0
  assert review.extent == Cut
  assert file.extent == Cut
  file
}

pub fn thirteen_hunks_leave_one_out_and_say_so_test() {
  let file = single(13, 1, 10)

  assert file.hunks_omitted == 1
  assert list.length(file.hunks) == 12
}

pub fn eighty_one_lines_leave_one_out_of_the_hunk_test() {
  let file = single(1, 81, 10)
  let assert [hunk] = file.hunks

  assert hunk.omitted == 1
  assert list.length(hunk.lines) == 80
}

pub fn a_line_past_the_byte_bound_is_cut_and_counted_test() {
  let file = single(1, 1, 401)
  let assert [hunk] = file.hunks
  let assert [line] = hunk.lines

  assert hunk.shortened == 1
  assert string.byte_size(line.text) == 400
}

// A board with more files than the bound is cut to it, and the rest counted,
// whatever decoded the board.
pub fn files_past_the_file_bound_are_counted_test() {
  let files =
    upto(30)
    |> list.map(fn(index) {
      observed("src/f" <> int.to_string(index) <> ".gleam", #(" ", "M"), "")
    })
  let review = review_feed.of_board(board(files))

  assert list.length(review.files) == review_feed.max_files
  assert review.omitted == 6
  assert review.extent == Cut
}

// No patch, however many hunks, lines or bytes it has, makes a review past a
// bound, and every line it cut is counted.
pub fn every_bound_holds_and_every_cut_is_counted_test() {
  let config =
    qcheck.default_config()
    |> qcheck.with_test_count(40)
    |> qcheck.with_seed(qcheck.seed(seed))
  let shapes =
    qcheck.map3(
      qcheck.bounded_int(from: 0, to: 30),
      qcheck.bounded_int(from: 0, to: 200),
      qcheck.bounded_int(from: 0, to: 900),
      fn(hunks, lines, width) { #(hunks, lines, width) },
    )

  qcheck.run(config, shapes, fn(shape) {
    let #(hunks, lines, width) = shape
    let files =
      upto(26)
      |> list.map(fn(index) {
        observed(
          "src/f" <> int.to_string(index) <> ".gleam",
          #(" ", "M"),
          patch_of(hunks, lines, width),
        )
      })
    let review = review_feed.of_board(board(files))
    let size = json.to_string(review_feed.encode(review)) |> string.byte_size

    assert size <= review_feed.max_bytes
    assert review.omitted == 26 - list.length(review.files)
    assert list.all(review.files, fn(file) {
      list.all(file.hunks, fn(hunk) {
        hunk.omitted == int.max(0, lines - review_feed.max_hunk_lines)
        && list.all(hunk.lines, fn(line) {
          string.byte_size(line.text) <= review_feed.max_line_bytes
        })
      })
      && list.drop(file.hunks, review_feed.max_hunks) == []
      && file.hunks_omitted == int.max(0, hunks - review_feed.max_hunks)
    })

    // A file that was cut anywhere says so.
    let cut_by_shape =
      hunks > review_feed.max_hunks
      || { hunks > 0 && lines > review_feed.max_hunk_lines }
      || { hunks > 0 && lines > 0 && width > review_feed.max_line_bytes }
    assert case review.files, cut_by_shape {
      [], _ | _, False -> True
      [file, ..], True -> file.extent == Cut
    }
  })
}

// A review too large for its byte bound loses whole files from the end, which
// are the docs, and counts them, with the stat still saying what was read.
pub fn a_review_over_the_byte_bound_drops_the_last_files_test() {
  let heavy = patch_of(12, 80, 390)
  let files =
    list.append(
      upto(20)
        |> list.map(fn(index) {
          observed(
            "src/f" <> int.to_string(index) <> ".gleam",
            #(" ", "M"),
            heavy,
          )
        }),
      [observed("docs/last.md", #(" ", "M"), heavy)],
    )
  let review = review_feed.of_board(board(files))

  assert review.omitted > 0
  assert review.extent == Cut
  assert review.stat.files == 21
  assert !list.contains(paths(review), "docs/last.md")
}

// A review travels and arrives the same.
pub fn a_review_round_trips_through_its_encoding_test() {
  let review =
    board([
      observed("src/a.gleam", #(" ", "M"), one_hunk),
      observed("docs/n.md", #("?", "?"), "@@ -0,0 +1 @@\n+λ\n\\ No newline"),
    ])
    |> review_feed.of_board

  assert review_feed.decode(review_feed.encode(review)) == Ok(review)
}

fn encoded_with(
  review: review_feed.Review,
  edit: fn(List(#(String, json.JsonValue))) -> List(#(String, json.JsonValue)),
) -> json.JsonValue {
  let assert json.Object(fields) = review_feed.encode(review)
  json.Object(edit(fields))
}

fn first_review() -> review_feed.Review {
  board([
    observed("src/a.gleam", #(" ", "M"), one_hunk),
    observed("src/b.gleam", #(" ", "M"), one_hunk),
  ])
  |> review_feed.of_board
}

// A damaged whole is no review; a damaged file is a file left out, counted.
pub fn the_decoder_is_total_and_loses_one_file_at_a_time_test() {
  let review = first_review()

  assert review_feed.decode(json.Null) == Error(Nil)
  assert review_feed.decode(json.Array([])) == Error(Nil)
  assert review_feed.decode(
      encoded_with(review, fn(fields) {
        list.key_set(fields, "repository", json.String("moon"))
      }),
    )
    == Error(Nil)
  assert review_feed.decode(
      encoded_with(review, fn(fields) {
        list.key_set(fields, "omitted", json.Int(-1))
      }),
    )
    == Error(Nil)

  let damaged =
    encoded_with(review, fn(fields) {
      list.key_set(
        fields,
        "files",
        json.Array([json.String("nope"), ..files_of(review)]),
      )
    })
  let assert Ok(decoded) = review_feed.decode(damaged)

  assert paths(decoded) == ["src/a.gleam", "src/b.gleam"]
  assert decoded.omitted == 1
  assert decoded.extent == Cut
}

fn files_of(review: review_feed.Review) -> List(json.JsonValue) {
  let assert json.Object(fields) = review_feed.encode(review)
  let assert Ok(json.Array(files)) = list.key_find(fields, "files")
  files
}

// The decoder holds the paths and the bounds as the builder does, whatever
// sent the value.
pub fn the_decoder_refuses_a_foreign_path_and_cuts_to_the_bounds_test() {
  let review = first_review()
  let assert [first, ..rest] = files_of(review)
  let assert json.Object(first_fields) = first
  let escaped =
    json.Object(list.key_set(first_fields, "path", json.String("../x")))

  let assert Ok(decoded) =
    review_feed.decode(
      encoded_with(review, fn(fields) {
        list.key_set(fields, "files", json.Array([escaped, ..rest]))
      }),
    )
  assert paths(decoded) == ["src/b.gleam"]
  assert decoded.omitted == 1

  let long_line =
    json.Object([
      #("k", json.String("+")),
      #("n", json.Int(1)),
      #("t", json.String(string.repeat("λ", 1000))),
    ])
  let hunk =
    json.Object([
      #("header", json.String("@@")),
      #("omitted", json.Int(0)),
      #("shortened", json.Int(0)),
      #("lines", json.Array(list.repeat(long_line, 200))),
    ])
  let json.Object(second_fields) = first
  let crowded =
    json.Object(list.key_set(
      second_fields,
      "hunks",
      json.Array(list.repeat(hunk, 40)),
    ))
  let assert Ok(bounded) =
    review_feed.decode(
      encoded_with(review, fn(fields) {
        list.key_set(fields, "files", json.Array([crowded]))
      }),
    )
  let assert [file] = bounded.files
  let assert [kept, ..] = file.hunks

  assert list.drop(file.hunks, review_feed.max_hunks) == []
  assert list.drop(kept.lines, review_feed.max_hunk_lines) == []
  assert list.all(kept.lines, fn(line) {
    string.byte_size(line.text) <= review_feed.max_line_bytes
    && line.old == None
  })
}
