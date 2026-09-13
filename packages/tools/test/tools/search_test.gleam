//// Tests for the search engine.
////
//// The glob matcher is pure and is tested as a table of strings. The
//// four filesystem entry points are tested against real trees built
//// under `build/searchtest/`, never under `/tmp`: code mode replaces
//// `/tmp` with the jail's scratch tmpfs, so a test that writes there
//// passes for reasons that do not survive contact with the sandbox.
//// Real trees are also the only way to test the property that matters
//// most here — that a symlink is reported and not followed — since an
//// in-memory fake would be testing the fake's idea of `lstat`.

import gleam/int
import gleam/list
import gleam/string
import simplifile
import tools/fs
import tools/search.{
  type Entry, type GlobQuery, type GrepQuery, Complete, Directory, Entry,
  Exhaustive, File, Found, GlobQuery, GrepQuery, IncludeHidden, InvalidQuery,
  Lines, Listing, Match, MatchesCapped, Missing, NotADirectory, NotAFile,
  SkipHidden, Symlink, Truncated,
}

// --- the glob matcher -------------------------------------------------------

// One row of the matcher table: pattern, subject, and whether the two
// should match. Kept as a type rather than a tuple so a failing row
// prints which is which.
type Row {
  Row(pattern: String, path: String, matches: Bool)
}

fn check_rows(rows: List(Row)) -> Nil {
  list.each(rows, fn(row) {
    let assert Ok(compiled) = search.compile_glob(row.pattern)
      as { "the table's patterns must compile: " <> row.pattern }
    assert search.glob_matches(compiled, row.path) == row.matches
  })
}

pub fn glob_without_a_slash_matches_the_basename_at_any_depth_test() {
  check_rows([
    Row(pattern: "*.gleam", path: "app.gleam", matches: True),
    Row(pattern: "*.gleam", path: "src/app.gleam", matches: True),
    Row(pattern: "*.gleam", path: "a/b/c/d/app.gleam", matches: True),
    Row(pattern: "*.gleam", path: "src/app.erl", matches: False),
    Row(pattern: "*.gleam", path: "src/gleam", matches: False),
    Row(pattern: "app.gleam", path: "src/app.gleam", matches: True),
    Row(pattern: "app.gleam", path: "src/other.gleam", matches: False),
  ])
}

pub fn glob_with_a_slash_matches_the_root_relative_path_test() {
  check_rows([
    Row(pattern: "src/*.gleam", path: "src/app.gleam", matches: True),
    Row(pattern: "src/*.gleam", path: "src/deep/app.gleam", matches: False),
    Row(pattern: "src/*.gleam", path: "test/app.gleam", matches: False),
    Row(pattern: "src/**/*.gleam", path: "src/a/app.gleam", matches: True),
    Row(pattern: "src/**/*.gleam", path: "src/a/b/app.gleam", matches: True),
    // `**` matches zero segments, so the pattern still finds a file
    // sitting directly in `src`.
    Row(pattern: "src/**/*.gleam", path: "src/app.gleam", matches: True),
    Row(pattern: "src/**/*.gleam", path: "test/a/app.gleam", matches: False),
  ])
}

pub fn double_star_alone_matches_every_path_test() {
  check_rows([
    Row(pattern: "**", path: "a", matches: True),
    Row(pattern: "**", path: "a/b/c", matches: True),
  ])
}

pub fn double_star_alone_is_a_whole_path_pattern_test() {
  // `**` carries no `/`, so it is a basename question — and a basename
  // is always one segment, which `**` matches.
  let assert Ok(compiled) = search.compile_glob("**")
    as "`**` alone must compile"
  assert search.glob_matches(compiled, "deep/down/here.txt")
}

pub fn question_mark_matches_exactly_one_character_test() {
  check_rows([
    Row(pattern: "a?c", path: "abc", matches: True),
    Row(pattern: "a?c", path: "ac", matches: False),
    Row(pattern: "a?c", path: "abbc", matches: False),
    // `?` is a character within a segment and never eats a separator.
    Row(pattern: "a?c", path: "a/c", matches: False),
  ])
}

pub fn star_never_crosses_a_segment_boundary_test() {
  check_rows([
    Row(pattern: "src/*", path: "src/app.gleam", matches: True),
    Row(pattern: "src/*", path: "src/deep/app.gleam", matches: False),
  ])
}

pub fn brackets_and_braces_are_literal_test() {
  check_rows([
    Row(pattern: "a[bc]d", path: "a[bc]d", matches: True),
    Row(pattern: "a[bc]d", path: "abd", matches: False),
    Row(pattern: "x{a,b}y", path: "x{a,b}y", matches: True),
    Row(pattern: "x{a,b}y", path: "xay", matches: False),
  ])
}

pub fn a_leading_dot_slash_is_stripped_from_both_sides_test() {
  check_rows([
    Row(pattern: "./src/app.gleam", path: "src/app.gleam", matches: True),
    Row(pattern: "src/app.gleam", path: "./src/app.gleam", matches: True),
    Row(pattern: "./*.gleam", path: "src/app.gleam", matches: True),
  ])
}

pub fn matching_is_case_sensitive_test() {
  check_rows([
    Row(pattern: "*.gleam", path: "App.GLEAM", matches: False),
    Row(pattern: "App.gleam", path: "app.gleam", matches: False),
  ])
}

pub fn a_pattern_at_the_length_cap_compiles_test() {
  let at_cap = string.repeat("a", search.max_pattern_length)
  assert search.compile_glob(at_cap) |> is_ok()
}

pub fn a_pattern_one_grapheme_over_the_cap_is_refused_test() {
  let over_cap = string.repeat("a", search.max_pattern_length + 1)
  let assert Error(message) = search.compile_glob(over_cap)
    as "a pattern past the length cap must be refused"
  assert string.contains(message, "longer than")
}

pub fn double_star_inside_a_segment_is_refused_test() {
  let assert Error(message) = search.compile_glob("a**b")
    as "`**` inside a segment must be refused"
  assert string.contains(message, "whole path segment")
}

pub fn an_empty_pattern_is_refused_test() {
  assert search.compile_glob("") |> is_error()
  assert search.compile_glob("./") |> is_error()
  assert search.compile_glob("src//app") |> is_error()
}

// --- glob over a real tree --------------------------------------------------

pub fn glob_returns_sorted_entries_test() {
  let root = fresh_dir("glob-sorted")
  write(root <> "/b.txt", "b")
  write(root <> "/a.txt", "a")
  make_dir(root <> "/sub")
  write(root <> "/sub/c.txt", "c")

  let assert Ok(Listing(entries:, completeness:)) =
    search.glob(workspace: root, root: root, query: pattern_query("*.txt"))
    as "a glob over a plain tree must succeed"

  assert completeness == Complete
  assert paths(entries) == ["a.txt", "b.txt", "sub/c.txt"]
}

pub fn glob_reports_directories_with_their_kind_test() {
  let root = fresh_dir("glob-directories")
  make_dir(root <> "/sub")

  let assert Ok(Listing(entries:, completeness: _)) =
    search.glob(workspace: root, root: root, query: pattern_query("sub"))
    as "a glob may match a directory"

  let assert [Entry(path:, kind:, size: _, mtime_seconds: _)] = entries
    as "exactly one entry must match"
  assert path == "sub"
  assert kind == Directory
}

pub fn glob_skips_hidden_entries_by_default_test() {
  let root = fresh_dir("glob-hidden-skipped")
  write(root <> "/visible.txt", "v")
  write(root <> "/.secret.txt", "s")
  make_dir(root <> "/.hidden")
  write(root <> "/.hidden/inside.txt", "i")

  let assert Ok(Listing(entries:, completeness: _)) =
    search.glob(workspace: root, root: root, query: pattern_query("*.txt"))
    as "the default walk must succeed"

  assert paths(entries) == ["visible.txt"]
}

pub fn glob_includes_hidden_entries_on_request_test() {
  let root = fresh_dir("glob-hidden-included")
  write(root <> "/visible.txt", "v")
  write(root <> "/.secret.txt", "s")
  make_dir(root <> "/.hidden")
  write(root <> "/.hidden/inside.txt", "i")

  let query = GlobQuery(..pattern_query("*.txt"), hidden: IncludeHidden)
  let assert Ok(Listing(entries:, completeness: _)) =
    search.glob(workspace: root, root: root, query:)
    as "an include-hidden walk must succeed"

  assert paths(entries) == [".hidden/inside.txt", ".secret.txt", "visible.txt"]
}

pub fn glob_does_not_descend_into_a_pruned_directory_test() {
  let root = fresh_dir("glob-pruned")
  write(root <> "/kept.txt", "k")
  make_dir(root <> "/node_modules")
  write(root <> "/node_modules/buried.txt", "b")

  let assert Ok(Listing(entries:, completeness: _)) =
    search.glob(workspace: root, root: root, query: pattern_query("*.txt"))
    as "a pruned walk must succeed"

  assert paths(entries) == ["kept.txt"]
}

pub fn an_empty_prune_list_descends_everything_test() {
  let root = fresh_dir("glob-unpruned")
  write(root <> "/kept.txt", "k")
  make_dir(root <> "/node_modules")
  write(root <> "/node_modules/buried.txt", "b")

  let query = GlobQuery(..pattern_query("*.txt"), prune: [])
  let assert Ok(Listing(entries:, completeness: _)) =
    search.glob(workspace: root, root: root, query:)
    as "an unpruned walk must succeed"

  assert paths(entries) == ["kept.txt", "node_modules/buried.txt"]
}

pub fn glob_reports_a_symlinked_directory_and_never_descends_it_test() {
  let root = fresh_dir("glob-symlink")
  make_dir(root <> "/real")
  write(root <> "/real/behind.txt", "behind")
  symlink(to: "real", from: root <> "/link")

  let query = GlobQuery(..pattern_query("**"), prune: [])
  let assert Ok(Listing(entries:, completeness: _)) =
    search.glob(workspace: root, root: root, query:)
    as "a walk over a tree with a symlink must succeed"

  // The link is reported with its stored target, unresolved.
  let assert Ok(Entry(path: _, kind:, size: _, mtime_seconds: _)) =
    list.find(entries, fn(entry) { entry.path == "link" })
    as "the symlink itself must be reported"
  assert kind == Symlink(target: "real")

  // The file behind it is reachable through the real directory and only
  // through it: `link/behind.txt` would mean the walk followed the link.
  assert list.contains(paths(entries), "real/behind.txt")
  assert !list.contains(paths(entries), "link/behind.txt")
}

pub fn glob_truncates_at_max_entries_with_exactly_that_many_test() {
  let root = fresh_dir("glob-truncated")
  list.each([1, 2, 3, 4, 5], fn(n) {
    write(root <> "/f" <> int.to_string(n) <> ".txt", "x")
  })

  let query = GlobQuery(..pattern_query("*.txt"), max_entries: 3)
  let assert Ok(Listing(entries:, completeness:)) =
    search.glob(workspace: root, root: root, query:)
    as "a bounded walk must succeed"

  assert completeness == Truncated
  assert paths(entries) == ["f1.txt", "f2.txt", "f3.txt"]
}

pub fn glob_that_fills_max_entries_exactly_is_complete_test() {
  // The pair of the test above, and the reason the walk looks one entry
  // past its bound. A tree holding exactly as many matches as the caller
  // asked for has nothing beyond them, and reporting `Truncated` would
  // tell a program it missed entries when it missed none — which a model
  // acts on by asking again for a wider window that answers the same.
  let root = fresh_dir("glob-exact-fit")
  list.each([1, 2, 3], fn(n) {
    write(root <> "/f" <> int.to_string(n) <> ".txt", "x")
  })

  let query = GlobQuery(..pattern_query("*.txt"), max_entries: 3)
  let assert Ok(Listing(entries:, completeness:)) =
    search.glob(workspace: root, root: root, query:)
    as "a walk that fills its bound exactly must succeed"

  assert completeness == Complete
  assert paths(entries) == ["f1.txt", "f2.txt", "f3.txt"]
}

pub fn glob_with_one_match_past_the_bound_is_truncated_test() {
  // One more match than the bound, which is the smallest tree that must
  // answer `Truncated` — and it must still answer exactly `max_entries`
  // entries, never the overflow the walk looked at to find out.
  let root = fresh_dir("glob-one-over")
  list.each([1, 2, 3, 4], fn(n) {
    write(root <> "/f" <> int.to_string(n) <> ".txt", "x")
  })

  let query = GlobQuery(..pattern_query("*.txt"), max_entries: 3)
  let assert Ok(Listing(entries:, completeness:)) =
    search.glob(workspace: root, root: root, query:)
    as "a walk one match past its bound must succeed"

  assert completeness == Truncated
  assert paths(entries) == ["f1.txt", "f2.txt", "f3.txt"]
}

pub fn glob_is_complete_when_max_entries_is_never_reached_test() {
  let root = fresh_dir("glob-untruncated")
  list.each([1, 2, 3], fn(n) {
    write(root <> "/f" <> int.to_string(n) <> ".txt", "x")
  })

  let query = GlobQuery(..pattern_query("*.txt"), max_entries: 4)
  let assert Ok(Listing(entries:, completeness:)) =
    search.glob(workspace: root, root: root, query:)
    as "an unbounded-in-practice walk must succeed"

  assert completeness == Complete
  assert paths(entries) == ["f1.txt", "f2.txt", "f3.txt"]
}

pub fn max_entries_at_the_ceiling_is_accepted_test() {
  let root = fresh_dir("glob-ceiling-ok")
  write(root <> "/one.txt", "x")

  let query =
    GlobQuery(..pattern_query("*.txt"), max_entries: search.max_entries_ceiling)
  assert search.glob(workspace: root, root: root, query:) |> is_ok()
}

pub fn max_entries_past_the_ceiling_is_refused_rather_than_clamped_test() {
  let root = fresh_dir("glob-ceiling-over")
  write(root <> "/one.txt", "x")

  let query =
    GlobQuery(
      ..pattern_query("*.txt"),
      max_entries: search.max_entries_ceiling + 1,
    )
  let assert Error(InvalidQuery(message:)) =
    search.glob(workspace: root, root: root, query:)
    as "a bound past its ceiling must be refused"
  assert string.contains(message, "max_entries")
}

pub fn max_entries_below_one_is_refused_test() {
  let root = fresh_dir("glob-ceiling-zero")
  write(root <> "/one.txt", "x")

  let query = GlobQuery(..pattern_query("*.txt"), max_entries: 0)
  assert search.glob(workspace: root, root: root, query:) |> is_error()
}

pub fn a_bad_glob_refuses_the_whole_call_test() {
  let root = fresh_dir("glob-bad-pattern")
  let assert Error(InvalidQuery(message:)) =
    search.glob(workspace: root, root: root, query: pattern_query("a**b"))
    as "an uncompilable glob must refuse the call"
  assert string.contains(message, "whole path segment")
}

pub fn a_glob_root_that_is_a_file_is_not_a_directory_test() {
  let root = fresh_dir("glob-root-file")
  let file = root <> "/plain.txt"
  write(file, "x")

  let assert Error(NotADirectory(path:)) =
    search.glob(workspace: root, root: file, query: pattern_query("*"))
    as "a file root must answer NotADirectory"
  assert path == file
}

pub fn glob_renders_paths_relative_to_the_workspace_not_the_root_test() {
  let workspace = fresh_dir("glob-workspace-relative")
  make_dir(workspace <> "/src/inner")
  write(workspace <> "/src/inner/app.gleam", "x")

  let assert Ok(Listing(entries:, completeness: _)) =
    search.glob(
      workspace:,
      root: workspace <> "/src",
      query: pattern_query("*.gleam"),
    )
    as "a walk under a sub-root must succeed"

  assert paths(entries) == ["src/inner/app.gleam"]
}

// --- grep -------------------------------------------------------------------

pub fn grep_reports_line_column_and_text_test() {
  let root = fresh_dir("grep-basic")
  write(root <> "/a.txt", "first\nsecond needle here\nthird\n")

  let assert Ok(Found(matches:, files_scanned:, files_skipped:, coverage:)) =
    search.grep(workspace: root, root: root, query: regex_query("needle"))
    as "a plain grep must succeed"

  assert coverage == Exhaustive
  assert files_scanned == 1
  assert files_skipped == 0
  assert matches
    == [
      Match(
        path: "a.txt",
        line: 2,
        column: 8,
        text: "second needle here",
        before: [],
        after: [],
      ),
    ]
}

pub fn grep_columns_count_graphemes_not_bytes_test() {
  let root = fresh_dir("grep-column-graphemes")
  write(root <> "/a.txt", "héllo needle\n")

  let assert Ok(Found(matches:, ..)) =
    search.grep(workspace: root, root: root, query: regex_query("needle"))
    as "a grep over non-ASCII text must succeed"

  let assert [found] = matches as "exactly one match"
  assert found.column == 7
}

pub fn grep_returns_context_on_both_sides_test() {
  let root = fresh_dir("grep-context")
  write(root <> "/a.txt", "one\ntwo\nneedle\nfour\nfive\n")

  let query = GrepQuery(..regex_query("needle"), context: 1)
  let assert Ok(Found(matches:, ..)) =
    search.grep(workspace: root, root: root, query:)
    as "a grep with context must succeed"

  let assert [found] = matches as "exactly one match"
  assert found.before == ["two"]
  assert found.after == ["four"]
}

pub fn grep_context_is_clipped_at_the_edges_of_a_file_test() {
  let root = fresh_dir("grep-context-edges")
  write(root <> "/a.txt", "needle\nmiddle\nneedle\n")

  let query = GrepQuery(..regex_query("needle"), context: 2)
  let assert Ok(Found(matches:, ..)) =
    search.grep(workspace: root, root: root, query:)
    as "a grep at the file edges must succeed"

  let assert [first, last] = matches as "two matches"
  assert first.before == []
  assert first.after == ["middle", "needle"]
  assert last.before == ["needle", "middle"]
  assert last.after == []
}

pub fn context_at_the_cap_is_accepted_and_one_over_is_refused_test() {
  let root = fresh_dir("grep-context-cap")
  write(root <> "/a.txt", "needle\n")

  let at_cap =
    GrepQuery(..regex_query("needle"), context: search.max_context_lines)
  assert search.grep(workspace: root, root: root, query: at_cap) |> is_ok()

  let over_cap =
    GrepQuery(..regex_query("needle"), context: search.max_context_lines + 1)
  assert search.grep(workspace: root, root: root, query: over_cap) |> is_error()
}

pub fn grep_caps_the_match_list_and_says_so_test() {
  let root = fresh_dir("grep-capped")
  write(root <> "/a.txt", "needle\nneedle\nneedle\nneedle\n")

  let query = GrepQuery(..regex_query("needle"), max_matches: 2)
  let assert Ok(Found(matches:, coverage:, ..)) =
    search.grep(workspace: root, root: root, query:)
    as "a capped grep must succeed"

  assert coverage == MatchesCapped
  assert list.map(matches, fn(found) { found.line }) == [1, 2]
}

pub fn grep_is_exhaustive_when_the_matches_fill_the_cap_exactly_test() {
  let root = fresh_dir("grep-exact-fill")
  write(root <> "/a.txt", "needle\nneedle\nhay\n")

  // Two matches against a cap of two: the scan looked past the second
  // match and found nothing, so the answer is the whole truth. A scan
  // that reported the cap here would tell a program it missed matches
  // that do not exist.
  let query = GrepQuery(..regex_query("needle"), max_matches: 2)
  let assert Ok(Found(matches:, coverage:, ..)) =
    search.grep(workspace: root, root: root, query:)
    as "an exactly filled grep must succeed"

  assert coverage == Exhaustive
  assert list.map(matches, fn(found) { found.line }) == [1, 2]
}

pub fn grep_is_exhaustive_when_the_cap_is_never_reached_test() {
  let root = fresh_dir("grep-uncapped")
  write(root <> "/a.txt", "needle\nneedle\n")

  let query = GrepQuery(..regex_query("needle"), max_matches: 3)
  let assert Ok(Found(matches:, coverage:, ..)) =
    search.grep(workspace: root, root: root, query:)
    as "an uncapped grep must succeed"

  assert coverage == Exhaustive
  assert list.map(matches, fn(found) { found.line }) == [1, 2]
}

pub fn max_matches_past_the_ceiling_is_refused_test() {
  let root = fresh_dir("grep-ceiling")
  write(root <> "/a.txt", "needle\n")

  let at_cap =
    GrepQuery(..regex_query("needle"), max_matches: search.max_matches_ceiling)
  assert search.grep(workspace: root, root: root, query: at_cap) |> is_ok()

  let over_cap =
    GrepQuery(
      ..regex_query("needle"),
      max_matches: search.max_matches_ceiling + 1,
    )
  assert search.grep(workspace: root, root: root, query: over_cap) |> is_error()
}

pub fn grep_globs_choose_which_files_are_read_test() {
  let root = fresh_dir("grep-globs")
  write(root <> "/a.gleam", "needle\n")
  write(root <> "/b.txt", "needle\n")

  let query = GrepQuery(..regex_query("needle"), globs: ["*.gleam"])
  let assert Ok(Found(matches:, files_scanned:, ..)) =
    search.grep(workspace: root, root: root, query:)
    as "a filtered grep must succeed"

  assert files_scanned == 1
  assert list.map(matches, fn(found) { found.path }) == ["a.gleam"]
}

pub fn grep_counts_a_non_utf8_file_as_skipped_test() {
  let root = fresh_dir("grep-not-text")
  write(root <> "/good.txt", "needle\n")
  write_bytes(root <> "/binary.bin", <<0xff, 0xfe, 0x00>>)

  let assert Ok(Found(files_scanned:, files_skipped:, ..)) =
    search.grep(workspace: root, root: root, query: regex_query("needle"))
    as "a grep over a tree with binary must succeed"

  assert files_scanned == 1
  assert files_skipped == 1
}

pub fn grep_counts_an_oversized_file_as_skipped_test() {
  let root = fresh_dir("grep-too-large")
  write(root <> "/good.txt", "needle\n")

  // One byte past the shared large-file guard, so the guard's boundary
  // is what this test is pinned to rather than a number of its own.
  write(root <> "/huge.txt", string.repeat("x", fs.max_read_bytes + 1))

  let assert Ok(Found(files_scanned:, files_skipped:, ..)) =
    search.grep(workspace: root, root: root, query: regex_query("needle"))
    as "a grep over a tree with an oversized file must succeed"

  assert files_scanned == 1
  assert files_skipped == 1
}

pub fn grep_never_reads_through_a_symlinked_file_test() {
  let root = fresh_dir("grep-symlink-file")
  write(root <> "/real.txt", "needle\n")
  symlink(to: "real.txt", from: root <> "/link.txt")

  let assert Ok(Found(matches:, files_scanned:, ..)) =
    search.grep(workspace: root, root: root, query: regex_query("needle"))
    as "a grep over a tree with a symlinked file must succeed"

  assert files_scanned == 1
  assert list.map(matches, fn(found) { found.path }) == ["real.txt"]
}

pub fn an_invalid_regex_carries_the_engine_message_test() {
  let root = fresh_dir("grep-bad-regex")
  let assert Error(InvalidQuery(message:)) =
    search.grep(workspace: root, root: root, query: regex_query("("))
    as "an uncompilable regex must refuse the call"
  assert message != ""
}

pub fn a_grep_root_that_is_a_file_is_not_a_directory_test() {
  let root = fresh_dir("grep-root-file")
  let file = root <> "/plain.txt"
  write(file, "needle\n")

  let assert Error(NotADirectory(path:)) =
    search.grep(workspace: root, root: file, query: regex_query("needle"))
    as "a file root must answer NotADirectory"
  assert path == file
}

// --- stat -------------------------------------------------------------------

pub fn stat_reports_a_file_test() {
  let root = fresh_dir("stat-file")
  write(root <> "/a.txt", "hello")

  let assert Ok(Entry(path:, kind:, size:, mtime_seconds:)) =
    search.stat(path: root <> "/a.txt", display: "a.txt")
    as "stat on a file must succeed"

  assert path == "a.txt"
  assert kind == File
  assert size == 5
  assert mtime_seconds > 0
}

pub fn stat_reports_a_directory_test() {
  let root = fresh_dir("stat-directory")
  make_dir(root <> "/sub")

  let assert Ok(Entry(kind:, ..)) =
    search.stat(path: root <> "/sub", display: "sub")
    as "stat on a directory must succeed"
  assert kind == Directory
}

pub fn stat_reports_a_symlink_verbatim_and_does_not_follow_it_test() {
  let root = fresh_dir("stat-symlink")
  write(root <> "/real.txt", "hello there")
  symlink(to: "real.txt", from: root <> "/link.txt")

  let assert Ok(Entry(kind:, size:, ..)) =
    search.stat(path: root <> "/link.txt", display: "link.txt")
    as "stat on a symlink must succeed"

  // The target is the stored string, and the size is the link's own,
  // not the eleven bytes of the file it points at.
  assert kind == Symlink(target: "real.txt")
  assert size != 11
}

pub fn stat_on_a_dangling_symlink_still_reports_the_link_test() {
  let root = fresh_dir("stat-dangling")
  symlink(to: "nowhere.txt", from: root <> "/link.txt")

  let assert Ok(Entry(kind:, ..)) =
    search.stat(path: root <> "/link.txt", display: "link.txt")
    as "stat on a dangling symlink must still report the link"
  assert kind == Symlink(target: "nowhere.txt")
}

pub fn stat_on_nothing_is_missing_test() {
  let root = fresh_dir("stat-missing")
  let assert Error(Missing(path:)) =
    search.stat(path: root <> "/absent.txt", display: "absent.txt")
    as "stat on a missing path must answer Missing"
  assert path == root <> "/absent.txt"
}

// --- read_lines -------------------------------------------------------------

pub fn read_lines_returns_the_window_inside_the_file_test() {
  let root = fresh_dir("lines-window")
  write(root <> "/a.txt", "one\ntwo\nthree\nfour\nfive\n")

  let assert Ok(Lines(text:, first:, last:, total:)) =
    search.read_lines(path: root <> "/a.txt", from: 2, to: 4)
    as "a window inside the file must succeed"

  assert text == "two\nthree\nfour"
  assert first == 2
  assert last == 4
  assert total == 5
}

pub fn read_lines_counts_a_final_newline_as_a_terminator_test() {
  let root = fresh_dir("lines-terminator")
  write(root <> "/with.txt", "one\ntwo\n")
  write(root <> "/without.txt", "one\ntwo")

  let assert Ok(with_newline) =
    search.read_lines(path: root <> "/with.txt", from: 1, to: 10)
    as "a newline-terminated file must read"
  let assert Ok(without_newline) =
    search.read_lines(path: root <> "/without.txt", from: 1, to: 10)
    as "an unterminated file must read"

  assert with_newline.total == 2
  assert without_newline.total == 2
}

pub fn read_lines_clamps_a_window_past_the_end_and_reports_it_test() {
  let root = fresh_dir("lines-clamped")
  write(root <> "/a.txt", "one\ntwo\nthree\n")

  let assert Ok(Lines(text:, first:, last:, total:)) =
    search.read_lines(path: root <> "/a.txt", from: 2, to: 900)
    as "a window past the end must clamp rather than refuse"

  assert text == "two\nthree"
  assert first == 2
  assert last == 3
  assert total == 3
}

pub fn read_lines_refuses_a_reversed_window_test() {
  let root = fresh_dir("lines-reversed")
  write(root <> "/a.txt", "one\ntwo\n")
  assert search.read_lines(path: root <> "/a.txt", from: 2, to: 1) |> is_error()
}

pub fn read_lines_refuses_a_window_starting_below_one_test() {
  let root = fresh_dir("lines-zero")
  write(root <> "/a.txt", "one\ntwo\n")
  assert search.read_lines(path: root <> "/a.txt", from: 0, to: 1) |> is_error()
}

pub fn a_span_at_the_cap_is_accepted_and_one_over_is_refused_test() {
  let root = fresh_dir("lines-span-cap")
  write(root <> "/a.txt", "one\ntwo\n")

  let at_cap =
    search.read_lines(path: root <> "/a.txt", from: 1, to: search.max_line_span)
  assert at_cap |> is_ok()

  let over_cap =
    search.read_lines(
      path: root <> "/a.txt",
      from: 1,
      to: search.max_line_span + 1,
    )
  let assert Error(InvalidQuery(message:)) = over_cap
    as "a span past the cap must be refused"
  assert string.contains(message, "at most")
}

pub fn read_lines_on_a_directory_is_not_a_file_test() {
  let root = fresh_dir("lines-directory")
  make_dir(root <> "/sub")

  let assert Error(NotAFile(path:)) =
    search.read_lines(path: root <> "/sub", from: 1, to: 1)
    as "read_lines on a directory must answer NotAFile"
  assert path == root <> "/sub"
}

pub fn read_lines_on_nothing_is_missing_test() {
  let root = fresh_dir("lines-missing")
  let assert Error(Missing(path:)) =
    search.read_lines(path: root <> "/absent.txt", from: 1, to: 1)
    as "read_lines on a missing path must answer Missing"
  assert path == root <> "/absent.txt"
}

pub fn read_lines_refuses_an_oversized_file_test() {
  let root = fresh_dir("lines-too-large")
  let path = root <> "/huge.txt"
  write(path, string.repeat("x", fs.max_read_bytes + 1))

  let assert Error(search.TooLarge(path: reported, size:)) =
    search.read_lines(path:, from: 1, to: 1)
    as "read_lines on an oversized file must answer TooLarge"
  assert reported == path
  assert size == fs.max_read_bytes + 1
}

pub fn read_lines_refuses_a_non_utf8_file_test() {
  let root = fresh_dir("lines-not-text")
  let path = root <> "/binary.bin"
  write_bytes(path, <<0xff, 0xfe, 0x00>>)

  let assert Error(search.NotText(path: reported)) =
    search.read_lines(path:, from: 1, to: 1)
    as "read_lines on a binary file must answer NotText"
  assert reported == path
}

// --- support ----------------------------------------------------------------

// The default query shapes, so a test that cares about one field says so
// with a record update and stays silent about the rest.
fn pattern_query(pattern: String) -> GlobQuery {
  GlobQuery(
    pattern:,
    max_entries: search.default_max_entries,
    hidden: SkipHidden,
    prune: search.default_prune,
  )
}

fn regex_query(pattern: String) -> GrepQuery {
  GrepQuery(
    pattern:,
    globs: [],
    context: 0,
    max_matches: search.default_max_matches,
    hidden: SkipHidden,
    prune: search.default_prune,
  )
}

fn paths(entries: List(Entry)) -> List(String) {
  list.map(entries, fn(entry) { entry.path })
}

fn is_ok(result: Result(a, b)) -> Bool {
  case result {
    Ok(_value) -> True
    Error(_reason) -> False
  }
}

fn is_error(result: Result(a, b)) -> Bool {
  !is_ok(result)
}

// A test tree under the package's own build directory. Never `/tmp`:
// code mode replaces `/tmp` with the jail's scratch tmpfs, so a test
// rooted there is testing a path the sandbox does not have.
fn fresh_dir(name: String) -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner must have a working directory"
  let dir = here <> "/build/searchtest/" <> name
  let _cleared = simplifile.delete(dir)
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
    as "the test directory must be creatable"
  dir
}

fn make_dir(path: String) -> Nil {
  let assert Ok(Nil) = simplifile.create_directory_all(path)
    as { "the test directory must be creatable: " <> path }
  Nil
}

fn write(path: String, content: String) -> Nil {
  let assert Ok(Nil) = simplifile.write(to: path, contents: content)
    as { "the test file must be writable: " <> path }
  Nil
}

fn write_bytes(path: String, bytes: BitArray) -> Nil {
  let assert Ok(Nil) = simplifile.write_bits(to: path, bits: bytes)
    as { "the test file must be writable: " <> path }
  Nil
}

// The target is stored relative to the link's own directory, which is
// what makes these links resolve wherever the build tree happens to sit.
fn symlink(to target: String, from link: String) -> Nil {
  let assert Ok(Nil) = simplifile.create_symlink(to: target, from: link)
    as { "the test symlink must be creatable: " <> link }
  Nil
}
