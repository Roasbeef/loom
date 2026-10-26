//// Tests for the miner's git layer: shell quoting, candidate selection,
//// splitting a diff, and reverting one line of a fix.

import client/secrets
import eval/git.{Delete, Insert, PatchSplit, Replace, Revert}
import gleam/list
import gleam/result
import gleam/string
import qcheck

const quote_seed = 33

/// Characters the shell treats specially, so the property spends its cases
/// on exactly the strings a careless quote would break on. The set is ASCII
/// on purpose: under `scripts/test.sh` the emulator's native file-name
/// encoding is not UTF-8, so the host runner double-encodes a non-ASCII
/// argument, which is a property of that FFI rather than of the quoting.
const hostile = [
  "'", "\"", "\\", "$", "`", " ", "\n", ";", "&", "|", "*", "!", "a", "b", "%",
]

fn hostile_text() -> qcheck.Generator(String) {
  qcheck.bounded_int(from: 0, to: list.length(hostile) - 1)
  |> qcheck.list_from
  |> qcheck.map(fn(indexes) {
    indexes
    |> list.map(fn(index) {
      list.drop(hostile, index) |> list.first |> result.unwrap("")
    })
    |> string.concat
  })
}

pub fn shell_quote_round_trips_test() {
  qcheck.run(
    qcheck.default_config()
      |> qcheck.with_test_count(60)
      |> qcheck.with_seed(qcheck.seed(quote_seed)),
    hostile_text(),
    fn(text) {
      let argv = ["bash", "-c", "printf %s " <> git.shell_quote(text)]

      assert secrets.host_runner()(argv, 10_000)
        == Ok(secrets.Capture(status: 0, output: text))
    },
  )
}

pub fn in_dir_folds_stderr_and_quotes_test() {
  assert git.in_dir("/w x", ["git", "a'b"])
    == ["bash", "-c", "cd '/w x' && 'git' 'a'\\''b' 2>&1"]
}

const log =
  "commit aaa fix: narrow
\nM\tpackages/core/src/core/a.gleam
M\tpackages/core/test/core/a_test.gleam
M\tpackages/core/CLAUDE.md
commit bbb feature: two packages
\nM\tpackages/core/src/core/a.gleam
M\tpackages/machine/test/machine/a_test.gleam
commit ccc docs sneak
\nM\tpackages/core/src/core/a.gleam
M\tpackages/core/test/core/a_test.gleam
M\tdocs/next.md
commit ddd deletes
\nD\tpackages/core/src/core/a.gleam
M\tpackages/core/test/core/a_test.gleam
commit eee too many
\nM\tpackages/core/src/core/a.gleam
M\tpackages/core/src/core/b.gleam
M\tpackages/core/src/core/c.gleam
M\tpackages/core/test/core/a_test.gleam
commit fff support files
\nM\tpackages/machine/src/machine/p.gleam
M\tpackages/machine/test/machine/p_test.gleam
A\tpackages/machine/test/support/rig.gleam
"

pub fn candidates_keep_only_the_narrow_shape_test() {
  let found = git.parse_candidates(log, [])

  assert list.map(found, fn(candidate) { candidate.commit }) == ["aaa", "fff"]
  assert list.map(found, fn(candidate) { candidate.package })
    == ["core", "machine"]
  assert git.parse_candidates(log, ["machine"]) |> list.length == 1
  assert git.parse_candidates(log, ["lint"]) == []
}

pub fn test_module_names_follow_eunit_test() {
  assert git.test_module("packages/machine/test/machine/failure_test.gleam")
    == Ok("machine@failure_test")
  assert git.test_module("packages/lint/test/lint_test.gleam")
    == Ok("lint_test")
  assert git.test_module("packages/lint/src/lint.gleam") == Error(Nil)
}

const diff =
  "diff --git a/docs/notes.md b/docs/notes.md
--- a/docs/notes.md
+++ b/docs/notes.md
@@ -1 +1 @@
-a
+b
diff --git a/packages/core/CLAUDE.md b/packages/core/CLAUDE.md
--- a/packages/core/CLAUDE.md
+++ b/packages/core/CLAUDE.md
@@ -1 +1 @@
-a
+b
diff --git a/packages/core/AGENTS.md b/packages/core/AGENTS.md
--- a/packages/core/AGENTS.md
+++ b/packages/core/AGENTS.md
@@ -1 +1 @@
-a
+b
diff --git a/packages/core/src/core/a.gleam b/packages/core/src/core/a.gleam
--- a/packages/core/src/core/a.gleam
+++ b/packages/core/src/core/a.gleam
@@ -1,2 +1,2 @@
 keep
-old
+new
diff --git a/packages/core/test/core/a_test.gleam b/packages/core/test/core/a_test.gleam
--- a/packages/core/test/core/a_test.gleam
+++ b/packages/core/test/core/a_test.gleam
@@ -1 +1 @@
-x
+y
"

pub fn diff_split_excludes_docs_test() {
  let assert Ok(PatchSplit(tests:, src:, test_paths:, src_paths:)) =
    git.split_patch(diff)

  assert test_paths == ["packages/core/test/core/a_test.gleam"]
  assert src_paths == ["packages/core/src/core/a.gleam"]
  assert !string.contains(src, "notes.md")
  assert !string.contains(src, "CLAUDE.md")
  assert !string.contains(src, "AGENTS.md")
  assert !string.contains(tests, "src/core/a.gleam")
  assert string.ends_with(tests, "-x\n+y\n")
  assert git.split_patch("stray text\n") |> result_is_error
}

fn result_is_error(outcome: Result(a, b)) -> Bool {
  case outcome {
    Ok(_) -> False
    Error(_) -> True
  }
}

pub fn first_revert_restores_a_modified_line_test() {
  let assert Ok(split) = git.split_patch(diff)

  assert git.first_revert(split.src)
    == Ok(Revert("packages/core/src/core/a.gleam", Replace(2, "new", "old")))
}

pub fn first_revert_deletes_an_added_line_and_skips_blanks_test() {
  let patch = "+++ b/f.gleam\n@@ -1,2 +1,4 @@\n a\n+\n+added\n b\n"

  assert git.first_revert(patch) == Ok(Revert("f.gleam", Delete(3, "added")))
  assert git.first_revert("+++ b/f.gleam\n@@ -1 +1,2 @@\n a\n+\n") == Error(Nil)
}

pub fn first_revert_pairs_past_a_blank_removal_test() {
  let patch = "+++ b/f.gleam\n@@ -1,2 +1,2 @@\n a\n-\n+text\n"

  assert git.first_revert(patch)
    == Ok(Revert("f.gleam", Replace(2, "text", "")))
}

pub fn first_revert_skips_comments_and_imports_test() {
  let patch =
    "+++ b/f.gleam\n@@ -1,1 +1,5 @@\n a\n+import x\n+/// doc\n+//// mod\n+// note\n+code\n"

  assert git.first_revert(patch) == Ok(Revert("f.gleam", Delete(6, "code")))
  assert git.first_revert(
      "+++ b/f.gleam\n@@ -1 +1,3 @@\n a\n+import x\n+// c\n",
    )
    == Error(Nil)
}

pub fn first_revert_reinserts_a_removed_line_test() {
  let patch = "+++ b/f.gleam\n@@ -1,3 +1,2 @@\n a\n-gone\n b\n"

  assert git.first_revert(patch) == Ok(Revert("f.gleam", Insert(2, "gone")))
}

pub fn apply_edit_checks_the_line_it_expects_test() {
  assert git.apply_edit("a\nnew\nb", Replace(2, "new", "old"))
    == Ok("a\nold\nb")
  assert git.apply_edit("a\nadded\nb", Delete(2, "added")) == Ok("a\nb")
  assert git.apply_edit("a\nb", Insert(2, "gone")) == Ok("a\ngone\nb")
  assert git.apply_edit("a\nother\nb", Delete(2, "added")) == Error(Nil)
  assert git.apply_edit("a\nother\nb", Replace(2, "new", "old")) == Error(Nil)
}

pub fn message_parts_split_subject_and_body_test() {
  assert git.message_parts("fix: a\n\nWhy.\nMore.\n")
    == #("fix: a", "Why.\nMore.")
  assert git.message_parts("only\n") == #("only", "")
}
