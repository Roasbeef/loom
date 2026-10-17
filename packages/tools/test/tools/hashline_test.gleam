import gleam/bool
import gleam/int
import gleam/list
import gleam/string
import qcheck
import support/gen
import tools/hashline.{
  type Ref, AnchoredLine, Delete, InsertAfter, InsertAtStart, MalformedPlan,
  OverlappingHunks, Plan, Ref, Region, Replace, Split, StaleAnchors,
  StaleContent, UnreachableEnding,
}

// --- generated properties --------------------------------------------------
//
// Every property below draws its inputs from `support/gen` through qcheck on
// a fixed seed, so the gate is deterministic and a failure arrives already
// shrunk: fewer and emptier lines, positions pulled toward the first line.

/// How many cases each property is checked over, and the qcheck seed they
/// are drawn from. The cheap properties share both; the two sweeps below
/// set their own counts.
const property_count = 100

const property_seed = 53

fn property_config(count: Int) -> qcheck.Config {
  qcheck.default_config()
  |> qcheck.with_test_count(count)
  |> qcheck.with_seed(qcheck.seed(property_seed))
}

fn property(generator: qcheck.Generator(a), check: fn(a) -> Nil) -> Nil {
  qcheck.run(property_config(property_count), generator, check)
}

// --- golden anchor vectors ----------------------------------------------
// First 8 hex characters of the canonical FNV-1a 64 test vectors
// (draft-eastlake-fnv): "" -> cbf29ce484222325, "a" -> af63dc4c8601ec8c,
// "foobar" -> 85944171f73967e8.

pub fn anchor_golden_empty_test() {
  assert hashline.anchor("") == "cbf29ce4"
}

pub fn anchor_golden_a_test() {
  assert hashline.anchor("a") == "af63dc4c"
}

pub fn anchor_golden_foobar_test() {
  assert hashline.anchor("foobar") == "85944171"
}

pub fn anchor_is_8_lowercase_hex_test() {
  let anchor = hashline.anchor("some line")
  assert string.length(anchor) == 8
  assert anchor == string.lowercase(anchor)
}

pub fn anchor_unicode_differs_from_ascii_test() {
  // The hash runs over UTF-8 bytes, so distinct text hashes distinctly.
  assert hashline.anchor("münchen") != hashline.anchor("munchen")
}

pub fn anchor_depends_only_on_content_test() {
  assert hashline.anchor("same") == hashline.anchor("same")
}

// --- split / join --------------------------------------------------------

pub fn split_empty_test() {
  assert hashline.split_lines("") == Split(lines: [], trailing_newline: False)
}

pub fn split_single_newline_test() {
  assert hashline.split_lines("\n")
    == Split(lines: [""], trailing_newline: True)
}

pub fn split_no_trailing_newline_test() {
  assert hashline.split_lines("a\nb")
    == Split(lines: ["a", "b"], trailing_newline: False)
}

pub fn split_trailing_newline_test() {
  assert hashline.split_lines("a\nb\n")
    == Split(lines: ["a", "b"], trailing_newline: True)
}

pub fn split_keeps_crlf_carriage_returns_test() {
  assert hashline.split_lines("a\r\nb\r\n")
    == Split(lines: ["a\r", "b\r"], trailing_newline: True)
}

pub fn join_roundtrip_fixed_cases_test() {
  let cases = ["", "\n", "a", "a\n", "a\nb", "a\r\nb\r\n", "\n\n", "🦀\né\n"]
  list.each(cases, fn(content) {
    assert hashline.join_lines(hashline.split_lines(content)) == content
  })
}

pub fn join_roundtrip_property_test() {
  property(gen.content(min_lines: 0, max_lines: 12), fn(content) {
    assert hashline.join_lines(hashline.split_lines(content)) == content
  })
}

// --- annotate / window ---------------------------------------------------

pub fn annotate_numbers_lines_from_one_test() {
  let assert [first, second] = hashline.annotate("alpha\nbeta")
  assert first
    == AnchoredLine(line: 1, anchor: hashline.anchor("alpha"), text: "alpha")
  assert second.line == 2
}

pub fn window_basic_test() {
  let window = hashline.window("a\nb\nc\nd", offset: 2, limit: 2)
  assert list.map(window.lines, fn(anchored) { anchored.text }) == ["b", "c"]
  assert window.total_lines == 4
  assert window.offset == 2
  assert window.has_more == True
}

pub fn window_to_end_has_no_more_test() {
  let window = hashline.window("a\nb\nc", offset: 2, limit: 10)
  assert window.has_more == False
  assert list.length(window.lines) == 2
}

pub fn window_offset_clamps_to_one_test() {
  let window = hashline.window("a\nb", offset: -3, limit: 1)
  assert window.offset == 1
  assert list.map(window.lines, fn(anchored) { anchored.text }) == ["a"]
}

pub fn window_past_end_is_empty_test() {
  let window = hashline.window("a\nb", offset: 10, limit: 5)
  assert window.lines == []
  assert window.total_lines == 2
  assert window.has_more == False
}

pub fn render_format_test() {
  let window = hashline.window("hi", offset: 1, limit: 1)
  assert hashline.render(window) == "1:" <> hashline.anchor("hi") <> "|hi"
}

// --- apply: golden cases -------------------------------------------------

fn ref_to(content: String, line: Int) -> Ref {
  let assert Ok(anchored) =
    list.find(hashline.annotate(content), fn(anchored) { anchored.line == line })
    as "test referenced a line that does not exist"
  Ref(line:, anchor: anchored.anchor)
}

// A plan bound to the content it is built against, as `fs_edit` builds
// one from a read.
fn plan(content: String, hunks: List(hashline.Hunk)) -> hashline.Plan {
  Plan(digest: hashline.digest(content), hunks:)
}

pub fn apply_single_replace_test() {
  let content = "one\ntwo\nthree\n"
  let plan =
    plan(content, [
      Replace(ref_to(content, 2), ref_to(content, 2), ["TWO", "extra"]),
    ])
  assert hashline.apply(content, plan) == Ok("one\nTWO\nextra\nthree\n")
}

pub fn apply_range_replace_test() {
  let content = "a\nb\nc\nd"
  let plan =
    plan(content, [Replace(ref_to(content, 2), ref_to(content, 3), ["X"])])
  assert hashline.apply(content, plan) == Ok("a\nX\nd")
}

pub fn apply_delete_test() {
  let content = "a\nb\nc\n"
  let plan = plan(content, [Delete(ref_to(content, 2), ref_to(content, 2))])
  assert hashline.apply(content, plan) == Ok("a\nc\n")
}

pub fn apply_insert_after_test() {
  let content = "a\nc\n"
  let plan = plan(content, [InsertAfter(ref_to(content, 1), ["b"])])
  assert hashline.apply(content, plan) == Ok("a\nb\nc\n")
}

pub fn apply_insert_at_start_test() {
  let content = "b\n"
  let plan = plan(content, [InsertAtStart(["a"])])
  assert hashline.apply(content, plan) == Ok("a\nb\n")
}

pub fn apply_insert_into_empty_file_test() {
  let plan = plan("", [InsertAtStart(["only"])])
  assert hashline.apply("", plan) == Ok("only\n")
}

pub fn apply_multi_hunk_test() {
  let content = "one\ntwo\nthree\nfour\nfive\n"
  let plan =
    plan(content, [
      Delete(ref_to(content, 4), ref_to(content, 4)),
      Replace(ref_to(content, 1), ref_to(content, 1), ["ONE"]),
      InsertAfter(ref_to(content, 2), ["two-and-a-half"]),
    ])
  assert hashline.apply(content, plan)
    == Ok("ONE\ntwo\ntwo-and-a-half\nthree\nfive\n")
}

pub fn apply_preserves_no_trailing_newline_test() {
  let content = "a\nb"
  let plan =
    plan(content, [Replace(ref_to(content, 1), ref_to(content, 1), ["A"])])
  assert hashline.apply(content, plan) == Ok("A\nb")
}

pub fn apply_preserves_crlf_bytes_test() {
  // Only line 2 is touched; line 1 keeps its \r byte exactly.
  let content = "a\r\nb\r\n"
  let plan =
    plan(content, [Replace(ref_to(content, 2), ref_to(content, 2), ["B\r"])])
  assert hashline.apply(content, plan) == Ok("a\r\nB\r\n")
}

pub fn apply_unicode_lines_test() {
  let content = "日本語\n🦀\n"
  let plan =
    plan(content, [Replace(ref_to(content, 2), ref_to(content, 2), ["🦞"])])
  assert hashline.apply(content, plan) == Ok("日本語\n🦞\n")
}

// --- apply: rejections ---------------------------------------------------

pub fn apply_stale_anchor_rejected_test() {
  let content = "one\ntwo\nthree\n"
  let plan =
    plan(content, [Replace(ref_to(content, 2), ref_to(content, 2), ["TWO"])])
  // The file changed between read and edit.
  let modified = "one\ntwo changed\nthree\n"
  let assert Error(StaleAnchors(stale: [stale])) =
    hashline.apply(modified, plan)
  assert stale.line == 2
  assert stale.expected == hashline.anchor("two")
}

pub fn apply_stale_carries_fresh_anchors_test() {
  let content = "one\ntwo\nthree\nfour\nfive\n"
  let plan =
    plan(content, [Replace(ref_to(content, 3), ref_to(content, 3), ["THREE"])])
  let modified = "one\ntwo\nTHREE!\nfour\nfive\n"
  let assert Error(StaleAnchors(stale: [stale])) =
    hashline.apply(modified, plan)
  // Fresh anchors cover the stale region of the *current* content.
  assert list.map(stale.fresh, fn(anchored) { anchored.text })
    == ["one", "two", "THREE!", "four", "five"]
  let assert Ok(fresh_three) =
    list.find(stale.fresh, fn(anchored) { anchored.line == 3 })
  assert fresh_three.anchor == hashline.anchor("THREE!")
}

pub fn apply_reference_past_end_is_stale_test() {
  let content = "a\nb\n"
  let plan =
    plan(content, [
      Delete(Ref(line: 9, anchor: "00000000"), Ref(line: 9, anchor: "00000000")),
    ])
  let assert Error(StaleAnchors(stale: [stale])) = hashline.apply(content, plan)
  assert stale.line == 9
  // The fresh region clamps to the end of the file.
  assert list.map(stale.fresh, fn(anchored) { anchored.text }) == ["a", "b"]
}

pub fn apply_any_stale_rejects_whole_plan_test() {
  let content = "one\ntwo\nthree\n"
  let good = Replace(ref_to(content, 1), ref_to(content, 1), ["ONE"])
  let bad =
    Replace(Ref(line: 2, anchor: "deadbeef"), Ref(line: 2, anchor: "deadbeef"), [
      "TWO",
    ])
  let assert Error(StaleAnchors(stale: [_])) =
    hashline.apply(content, plan(content, [good, bad]))
  // And nothing was applied: content is untouched by a rejection (apply
  // is pure, but the invariant worth stating is that no partial result
  // is ever returned).
}

pub fn apply_overlapping_ranges_rejected_test() {
  let content = "a\nb\nc\nd\n"
  let plan =
    plan(content, [
      Replace(ref_to(content, 1), ref_to(content, 3), ["x"]),
      Delete(ref_to(content, 3), ref_to(content, 4)),
    ])
  let assert Error(OverlappingHunks(line: 3)) = hashline.apply(content, plan)
}

pub fn apply_insert_inside_replaced_range_rejected_test() {
  let content = "a\nb\nc\n"
  let plan =
    plan(content, [
      Replace(ref_to(content, 1), ref_to(content, 2), ["x"]),
      InsertAfter(ref_to(content, 2), ["y"]),
    ])
  let assert Error(OverlappingHunks(line: 2)) = hashline.apply(content, plan)
}

pub fn apply_duplicate_insert_point_rejected_test() {
  let content = "a\nb\n"
  let plan =
    plan(content, [
      InsertAfter(ref_to(content, 1), ["x"]),
      InsertAfter(ref_to(content, 1), ["y"]),
    ])
  let assert Error(OverlappingHunks(line: 1)) = hashline.apply(content, plan)
}

pub fn apply_adjacent_hunks_are_legal_test() {
  let content = "a\nb\nc\nd\n"
  let plan =
    plan(content, [
      Replace(ref_to(content, 1), ref_to(content, 2), ["AB"]),
      Replace(ref_to(content, 3), ref_to(content, 4), ["CD"]),
    ])
  assert hashline.apply(content, plan) == Ok("AB\nCD\n")
}

pub fn apply_inverted_range_malformed_test() {
  let content = "a\nb\n"
  let plan =
    plan(content, [Replace(ref_to(content, 2), ref_to(content, 1), ["x"])])
  let assert Error(MalformedPlan(reason: _)) = hashline.apply(content, plan)
}

pub fn apply_line_zero_malformed_test() {
  let plan =
    plan("a\n", [
      Delete(Ref(line: 0, anchor: "cbf29ce4"), Ref(line: 0, anchor: "cbf29ce4")),
    ])
  let assert Error(MalformedPlan(reason: _)) = hashline.apply("a\n", plan)
}

pub fn apply_newline_in_replacement_malformed_test() {
  let content = "a\n"
  let plan =
    plan(content, [Replace(ref_to(content, 1), ref_to(content, 1), ["x\ny"])])
  let assert Error(MalformedPlan(reason: _)) = hashline.apply(content, plan)
}

pub fn apply_empty_plan_is_identity_test() {
  assert hashline.apply("a\nb", plan("a\nb", [])) == Ok("a\nb")
}

// --- apply: properties ---------------------------------------------------

// A plan built from a document's real anchors applies, deterministically.
pub fn apply_deterministic_property_test() {
  property(
    qcheck.tuple2(gen.content(min_lines: 4, max_lines: 8), gen.line()),
    fn(drawn) {
      let #(content, replacement) = drawn
      let plan =
        plan(content, [
          Replace(ref_to(content, 2), ref_to(content, 2), [replacement]),
          Delete(ref_to(content, 4), ref_to(content, 4)),
        ])
      let first = hashline.apply(content, plan)
      let second = hashline.apply(content, plan)
      let assert Ok(_) = first as "a plan from real anchors must apply"
      assert first == second
    },
  )
}

// Editing after a concurrent modification of a referenced line is
// always rejected.
pub fn apply_concurrent_modification_property_test() {
  property(gen.content(min_lines: 3, max_lines: 6), fn(content) {
    let split = hashline.split_lines(content)
    let plan =
      plan(content, [
        Replace(ref_to(content, 2), ref_to(content, 2), ["edited"]),
      ])
    // Mutate exactly the referenced line.
    let modified_lines =
      list.index_map(split.lines, fn(line, index) {
        case index == 1 {
          True -> line <> "!concurrent!"
          False -> line
        }
      })
    let modified = hashline.join_lines(Split(..split, lines: modified_lines))
    let assert Error(StaleAnchors(stale: [stale])) =
      hashline.apply(modified, plan)
    assert stale.line == 2
  })
}

// Anchors are content hashes: editing some lines never changes the
// anchors of untouched lines.
pub fn anchors_stable_under_unrelated_edits_property_test() {
  property(gen.content(min_lines: 3, max_lines: 6), fn(content) {
    let plan =
      plan(content, [
        Replace(ref_to(content, 1), ref_to(content, 1), ["changed"]),
      ])
    let assert Ok(edited) = hashline.apply(content, plan)
    let before = hashline.annotate(content)
    let after = hashline.annotate(edited)
    // Every line except the first keeps its anchor (its line number
    // is unchanged here because the replacement is 1-for-1).
    list.each(list.drop(before, 1), fn(anchored) {
      let assert Ok(same_line) =
        list.find(after, fn(candidate) { candidate.line == anchored.line })
      assert same_line.anchor == anchored.anchor
      assert same_line.text == anchored.text
    })
  })
}

// Applied edits are byte-exact: reconstructing the expected output by
// hand equals the applied output.
pub fn apply_byte_exact_property_test() {
  property(
    qcheck.tuple3(
      gen.content(min_lines: 2, max_lines: 7),
      gen.pick(),
      gen.line(),
    ),
    fn(drawn) {
      let #(content, pick, replacement) = drawn
      let split = hashline.split_lines(content)
      let total = list.length(split.lines)
      let index = 1 + gen.wrap(pick, total)
      let plan =
        plan(content, [
          Replace(ref_to(content, index), ref_to(content, index), [replacement]),
        ])
      let expected_lines =
        list.index_map(split.lines, fn(line, position) {
          case position == index - 1 {
            True -> replacement
            False -> line
          }
        })
      let expected = hashline.join_lines(Split(..split, lines: expected_lines))
      assert hashline.apply(content, plan) == Ok(expected)
    },
  )
}

pub fn reapply_after_success_is_rejected_test() {
  // The anchor-idempotency argument behind fs_edit's replay safety: a
  // plan applied once cannot apply again, because it consumed the
  // content its anchors named.
  let content = "one\ntwo\nthree\n"
  let plan =
    plan(content, [Replace(ref_to(content, 2), ref_to(content, 2), ["TWO"])])
  let assert Ok(edited) = hashline.apply(content, plan)
  let assert Error(StaleAnchors(stale: _)) = hashline.apply(edited, plan)
}

pub fn identical_lines_disambiguated_by_line_number_test() {
  // Two identical lines share an anchor; the line number picks one.
  let content = "same\nsame\n"
  let plan =
    plan(content, [Replace(ref_to(content, 2), ref_to(content, 2), ["other"])])
  assert hashline.apply(content, plan) == Ok("same\nother\n")
}

pub fn fresh_context_constant_is_reported_width_test() {
  let content =
    string.join(
      ["let", "case", "fn", "->", "münchen", "日本語", "🦀", "___", "x = y"],
      with: "\n",
    )
  let plan =
    plan(content, [
      Replace(
        Ref(line: 5, anchor: "ffffffff"),
        Ref(line: 5, anchor: "ffffffff"),
        ["x"],
      ),
    ])
  let assert Error(StaleAnchors(stale: [stale])) = hashline.apply(content, plan)
  let lines = list.map(stale.fresh, fn(anchored) { anchored.line })
  assert lines
    == generate_range(
      5 - hashline.fresh_context_lines,
      5 + hashline.fresh_context_lines,
    )
}

fn generate_range(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..generate_range(from + 1, to)]
  }
}

// --- apply: at-most-once (the digest binding, C1/M1) ---------------------

pub fn digest_golden_empty_test() {
  assert hashline.digest("") == "cbf29ce484222325-0"
}

pub fn digest_separates_equal_hash_inputs_by_length_test() {
  // The digest carries the byte length, so shrinking edits (every
  // delete) always change it.
  assert hashline.digest("x\nx\n") != hashline.digest("x\n")
  assert hashline.digest("a") != hashline.digest("a\n")
}

pub fn reapply_delete_of_duplicate_line_rejected_test() {
  // C1 reproduction: deleting line 1 of "x\nx\n" shifts the identical
  // sibling into line 1 with a matching anchor, so per-line checks
  // alone would double-apply on replay. The digest binding rejects.
  let content = "x\nx\n"
  let ref = Ref(line: 1, anchor: hashline.anchor("x"))
  let plan = plan(content, [Delete(ref, ref)])
  let assert Ok(once) = hashline.apply(content, plan)
  assert once == "x\n"
  let assert Error(StaleContent(digest:, fresh: _)) = hashline.apply(once, plan)
  assert digest == hashline.digest("x\n")
}

pub fn replayed_blank_line_delete_rejected_every_time_test() {
  // C1 blank-line variant: a blank-line delete replayed three times
  // must apply exactly once — replays leave the content untouched.
  let content = "a\n\n\n\nb\n"
  let blank = Ref(line: 2, anchor: hashline.anchor(""))
  let plan = plan(content, [Delete(blank, blank)])
  let assert Ok(once) = hashline.apply(content, plan)
  assert once == "a\n\n\nb\n"
  let assert Error(StaleContent(digest: _, fresh: _)) =
    hashline.apply(once, plan)
  let assert Error(StaleContent(digest: _, fresh: _)) =
    hashline.apply(once, plan)
}

pub fn duplicate_shift_defeats_anchors_alone_test() {
  // Witness for why the digest is load-bearing: after the first apply
  // the identical sibling has shifted into the referenced position, so
  // the per-line anchor check is satisfied — a plan re-bound to the new
  // digest applies again. Only the digest distinguishes a replay.
  let content = "x\nx\n"
  let ref = Ref(line: 1, anchor: hashline.anchor("x"))
  let assert Ok(once) =
    hashline.apply(content, plan(content, [Delete(ref, ref)]))
  assert hashline.apply(once, plan(once, [Delete(ref, ref)])) == Ok("\n")
}

pub fn deleting_every_line_of_a_terminated_file_leaves_its_newline_test() {
  // The documented consequence of the line model, not a lost edit: `apply`
  // keeps the file's final-newline state, so a terminated file with every
  // line removed is `"\n"` (`Unplannable`'s doc). For `"\n"`, whose one
  // line is blank, that is the identity; `"x\n"` lands on the same text. The
  // empty file is not a result of deleting, only of never having had lines.
  let blank = Ref(line: 1, anchor: hashline.anchor(""))
  let x = Ref(line: 1, anchor: hashline.anchor("x"))
  assert hashline.apply("\n", plan("\n", [Delete(blank, blank)])) == Ok("\n")
  assert hashline.apply("x\n", plan("x\n", [Delete(x, x)])) == Ok("\n")
  assert hashline.plan_between(base: "x\n", edited: "")
    == Error(hashline.UnreachableEnding)
}

pub fn mid_range_concurrent_modification_rejected_test() {
  // M1: a range hunk carries anchors only for its endpoints; a
  // concurrent edit strictly inside the range must still reject, and
  // the rejection's fresh anchors must cover the modified interior.
  let content = "a\nb\nc\nd\ne\n"
  let plan = plan(content, [Delete(ref_to(content, 2), ref_to(content, 4))])
  let modified = "a\nb\nC!\nd\ne\n"
  let assert Error(StaleContent(digest:, fresh:)) =
    hashline.apply(modified, plan)
  assert digest == hashline.digest(modified)
  assert list.any(fresh, fn(anchored) { anchored.text == "C!" })
}

pub fn mid_range_replace_concurrent_modification_rejected_test() {
  let content = "a\nb\nc\nd\ne\n"
  let plan =
    plan(content, [Replace(ref_to(content, 1), ref_to(content, 5), ["only"])])
  let modified = "a\nb\nc changed\nd\ne\n"
  let assert Error(StaleContent(digest: _, fresh: _)) =
    hashline.apply(modified, plan)
}

// What the at-most-once property does to the chosen line: delete it, or
// replace it with its own text plus a mark, so the edit always changes the
// content. Deletion first, since a shrunk counterexample reads best as the
// plainer edit.
type LineEdit {
  RemoveLine
  MarkLine
}

// For generated contents — plain and duplicate/blank-heavy — and
// content-changing plans, a plan never applies twice: the second apply
// against the first apply's output is always an error.
pub fn at_most_once_property_test() {
  property(
    qcheck.tuple3(
      gen.either_content(min_lines: 2, max_lines: 8),
      gen.pick(),
      qcheck.bounded_int(from: 0, to: 1),
    ),
    fn(drawn) {
      let #(content, pick, edit_kind) = drawn
      let total = list.length(hashline.split_lines(content).lines)
      let index = 1 + gen.wrap(pick, total)
      let edit = case edit_kind {
        0 -> RemoveLine
        _ -> MarkLine
      }
      let hunk = case edit {
        RemoveLine -> Delete(ref_to(content, index), ref_to(content, index))
        MarkLine -> {
          // A replacement that always differs from the original line.
          let assert Ok(anchored) =
            list.find(hashline.annotate(content), fn(anchored) {
              anchored.line == index
            })
          Replace(ref_to(content, index), ref_to(content, index), [
            anchored.text <> "!",
          ])
        }
      }
      let plan = plan(content, [hunk])
      let assert Ok(once) = hashline.apply(content, plan)
      assert once != content
      let assert Error(_) = hashline.apply(once, plan)
      Nil
    },
  )
}

pub fn anchor_version_is_one_test() {
  assert hashline.anchor_version == 1
}

pub fn render_line_format_test() {
  assert hashline.render_line(AnchoredLine(
      line: 3,
      anchor: "aabbccdd",
      text: "x",
    ))
    == "3:aabbccdd|x"
}

pub fn window_int_shapes_test() {
  // Windows never report negative counts.
  let window = hashline.window("", offset: 1, limit: 5)
  assert window.total_lines == 0
  assert window.lines == []
  assert int.max(window.offset, 1) == window.offset
}

// --- render_diff -------------------------------------------------------------

fn ref(line: Int) -> hashline.Ref {
  hashline.Ref(line:, anchor: "unused")
}

pub fn render_diff_shows_context_removals_and_additions_test() {
  let content = "a\nb\nc\nd\ne\nf\ng\nh\ni\n"
  let diff =
    hashline.render_diff(content, [
      hashline.Replace(from: ref(5), to: ref(5), lines: ["E", "E2"]),
    ])
  assert diff == "@@ -2,7 +2,8 @@\n b\n c\n d\n-e\n+E\n+E2\n f\n g\n h"
}

pub fn render_diff_orders_hunks_and_tracks_the_new_side_test() {
  // Given out of order, the sections come back in file order, and the
  // second section's new-side start accounts for the growth above it.
  let content = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\n"
  let diff =
    hashline.render_diff(content, [
      hashline.InsertAfter(at: ref(10), lines: ["x"]),
      hashline.Replace(from: ref(2), to: ref(3), lines: ["B", "C", "C2"]),
    ])
  let assert Ok(#(first, second)) = string.split_once(diff, on: "\n@@ ")
  assert first == "@@ -1,6 +1,7 @@\n a\n-b\n-c\n+B\n+C\n+C2\n d\n e\n f"
  assert "@@ " <> second == "@@ -8,5 +9,6 @@\n h\n i\n j\n+x\n k\n l"
}

pub fn render_diff_handles_the_file_edges_test() {
  let content = "a\nb\n"
  assert hashline.render_diff(content, [hashline.InsertAtStart(lines: ["z"])])
    == "@@ -1,2 +1,3 @@\n+z\n a\n b"
  assert hashline.render_diff(content, [
      hashline.Delete(from: ref(1), to: ref(2)),
    ])
    == "@@ -1,2 +1,0 @@\n-a\n-b"
}

// --- applied_regions ------------------------------------------------------
//
// The arithmetic these pin is the one thing a successful edit's fresh
// anchors rest on: where each hunk landed in the content that was written.
// Every case states the post-image range with its three context lines
// already applied and clamped, because that is what callers render.

fn regions(
  hunks: List(hashline.Hunk),
  edited: String,
) -> List(hashline.Region) {
  hashline.applied_regions(hunks:, edited:)
}

pub fn applied_regions_covers_a_single_replace_test() {
  let edited = "l1\nl2\nl3\nl4\nL5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\n"
  assert regions([Replace(from: ref(5), to: ref(5), lines: ["L5"])], edited)
    == [Region(start: 2, end: 8)]
}

pub fn applied_regions_covers_an_insert_after_its_anchor_test() {
  let edited = "l1\nl2\nl3\nl4\nl5\nX\nl6\nl7\nl8\nl9\nl10\nl11\nl12\n"
  assert regions([InsertAfter(at: ref(5), lines: ["X"])], edited)
    == [Region(start: 3, end: 9)]
}

pub fn applied_regions_covers_a_delete_seam_test() {
  let edited = "l1\nl2\nl3\nl4\nl6\nl7\nl8\nl9\nl10\nl11\nl12\n"
  assert regions([Delete(from: ref(5), to: ref(5))], edited)
    == [Region(start: 2, end: 7)]
}

// The second hunk's anchors must sit at its *shifted* lines: the first
// hunk added two lines, so what was line 11 is line 13 in the result.
pub fn applied_regions_shifts_a_later_hunk_by_an_earlier_ones_delta_test() {
  let edited = "l1\nA\nB\nC\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nL11\nl12\n"
  assert regions(
      [
        Replace(from: ref(2), to: ref(2), lines: ["A", "B", "C"]),
        Replace(from: ref(11), to: ref(11), lines: ["L11"]),
      ],
      edited,
    )
    == [Region(start: 1, end: 7), Region(start: 10, end: 14)]
}

pub fn applied_regions_merges_contexts_that_touch_test() {
  let edited = "l1\nl2\nL3\nl4\nl5\nl6\nL7\nl8\nl9\nl10\nl11\nl12\n"
  assert regions(
      [
        Replace(from: ref(3), to: ref(3), lines: ["L3"]),
        Replace(from: ref(7), to: ref(7), lines: ["L7"]),
      ],
      edited,
    )
    == [Region(start: 1, end: 10)]
}

pub fn applied_regions_clamps_at_both_file_edges_test() {
  let first = "L1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\n"
  assert regions([Replace(from: ref(1), to: ref(1), lines: ["L1"])], first)
    == [Region(start: 1, end: 4)]

  let last = "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nL12\n"
  assert regions([Replace(from: ref(12), to: ref(12), lines: ["L12"])], last)
    == [Region(start: 9, end: 12)]
}

pub fn applied_regions_covers_an_insert_at_start_test() {
  let edited = "Z\nl1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\n"
  assert regions([InsertAtStart(lines: ["Z"])], edited)
    == [Region(start: 1, end: 4)]
}

// A file whose every line went away has nothing left to anchor, and an
// inverted range would be worse than none.
pub fn applied_regions_of_an_emptied_file_is_empty_test() {
  assert regions([Delete(from: ref(1), to: ref(12))], "") == []
}

pub fn applied_regions_handles_content_without_a_trailing_newline_test() {
  let edited = "l1\nl2\nL3"
  assert regions([Replace(from: ref(3), to: ref(3), lines: ["L3"])], edited)
    == [Region(start: 1, end: 3)]
}

// --- applied_regions, swept ----------------------------------------------
//
// The three properties that make the ranges usable as anchors, over a
// generated sweep of non-overlapping hunk sets.

/// How many files the sweep is run over; the one property that draws files
/// of up to forty lines, so it gets its own count.
const sweep_count = 200

pub fn applied_regions_sweep_holds_its_invariants_test() {
  qcheck.run(property_config(sweep_count), sweep_generator(), fn(drawn) {
    let #(hunks, edited, total) = sweep_case(drawn)
    let result = regions(hunks, edited)

    // Every range lies inside the file that was written.
    list.each(result, fn(region) {
      assert region.start >= 1
        && region.start <= region.end
        && region.end <= total
        as "a region left the file"
    })

    // Ranges come out ordered, and adjacency is merged away as well as
    // overlap, so none begins where the previous ended or one line after.
    assert list.sort(result, fn(a, b) { int.compare(a.start, b.start) })
      == result
      as "regions came back out of order"
    assert separated(result) as "regions overlap or touch after merging"

    // The ranges are inside the file, so a window read at each one comes
    // back the full width asked for.
    list.each(result, fn(region) {
      let limit = region.end - region.start + 1
      let window = hashline.window(edited, offset: region.start, limit:)
      assert list.length(window.lines) == limit as "a window came back short"
    })

    // Coverage is the property that actually constrains the arithmetic:
    // every line the hunks wrote has to fall inside some returned range.
    // Without this the sweep passes for ranges that ignore the shift
    // entirely, since unshifted ranges are still inside the file, still
    // ordered and still separated — they simply point at the wrong lines.
    let written =
      list.filter(hashline.annotate(edited), fn(anchored) {
        string.starts_with(anchored.text, sweep_marker)
      })
    assert written != [] as "the sweep generated a case that wrote nothing"
    assert list.all(written, fn(anchored) {
      list.any(result, fn(region) {
        anchored.line >= region.start && anchored.line <= region.end
      })
    })
      as "a written line fell outside every returned region"
  })
}

// A file of four to forty lines and one `#(take, width)` slot for every
// third line, which is the most slots a file that long can use. A slot
// shrinks toward "skip this line", and a taken one toward width zero, a
// deletion, so a failing sweep is reported as a short file with the fewest
// hunks that still break the arithmetic.
fn sweep_generator() -> qcheck.Generator(#(String, List(#(Int, Int)))) {
  let slot =
    qcheck.tuple2(
      qcheck.bounded_int(from: 0, to: 1),
      qcheck.bounded_int(from: 0, to: 3),
    )
  qcheck.tuple2(
    gen.content(min_lines: 4, max_lines: 40),
    qcheck.fixed_length_list_from(slot, 14),
  )
}

// One generated case: a file, a set of non-overlapping single-line hunks
// over it whose replacement lengths vary, and the content applying them
// produces. `apply` does the splicing, so the sweep checks the arithmetic
// against the real post-image rather than a second prediction of it.
fn sweep_case(
  drawn: #(String, List(#(Int, Int))),
) -> #(List(hashline.Hunk), String, Int) {
  let #(content, slots) = drawn

  // The generator's line count is what it was asked for, not necessarily
  // what the content splits into, and a reference past the end would be a
  // bug in the sweep rather than in what it measures.
  let line_count = list.length(hashline.split_lines(content).lines)
  let hunks = sweep_hunks(content, line_count, slots, 1, [])
  let assert Ok(edited) =
    hashline.apply(content, Plan(digest: hashline.digest(content), hunks:))
    as "the sweep built a plan that did not apply"
  #(hunks, edited, list.length(hashline.split_lines(edited).lines))
}

// The prefix every generated replacement line carries, so the coverage
// check can find the written lines in the post-image. No fragment in
// `support/gen`'s alphabet can produce it.
const sweep_marker = "SWEEPWROTE"

// Walks the file forwards taking at most every third line, so the hunks
// cannot overlap however the slots fall. Each slot decides one line.
//
// Line 1 is always a replacement of at least one line. That is what keeps
// the coverage assertion from being vacuous: a case whose every hunk was a
// deletion, or whose every slot said skip, would write nothing and have
// nothing to cover.
fn sweep_hunks(
  content: String,
  line_count: Int,
  slots: List(#(Int, Int)),
  line: Int,
  built: List(hashline.Hunk),
) -> List(hashline.Hunk) {
  use <- bool.guard(line > line_count, built)
  case slots {
    [] -> built
    [#(take, width), ..rest] -> {
      let hunks = case line == 1 || take == 1 {
        False -> built
        True -> [sweep_hunk(content, line, forced_width(line, width)), ..built]
      }
      sweep_hunks(content, line_count, rest, line + 3, hunks)
    }
  }
}

fn forced_width(line: Int, width: Int) -> Int {
  case line == 1 {
    True -> int.max(width, 1)
    False -> width
  }
}

// Width 0 is a deletion, the case with no post-image lines of its own and
// therefore the one worth generating often.
fn sweep_hunk(content: String, line: Int, width: Int) -> hashline.Hunk {
  let reference = ref_to(content, line)
  case width {
    0 -> Delete(from: reference, to: reference)
    _ ->
      Replace(
        from: reference,
        to: reference,
        lines: list.map(upto(width), fn(i) {
          sweep_marker <> " " <> int.to_string(line) <> "." <> int.to_string(i)
        }),
      )
  }
}

// `1..n` inclusive; this stdlib has no `list.range`.
fn upto(n: Int) -> List(Int) {
  upto_loop(n, [])
}

fn upto_loop(n: Int, built: List(Int)) -> List(Int) {
  case n < 1 {
    True -> built
    False -> upto_loop(n - 1, [n, ..built])
  }
}

fn separated(regions: List(hashline.Region)) -> Bool {
  case regions {
    [] | [_] -> True
    [first, second, ..rest] ->
      second.start > first.end + 1 && separated([second, ..rest])
  }
}

// --- plan_between --------------------------------------------------------

// Whether `apply` can reach `edited` from `base` at all: it keeps a
// newline-terminated file terminated, and terminates an empty one it grows.
// This is the refusal's whole specification, restated independently of the
// implementation so the property below checks one against the other.
fn ending_reachable(base: String, edited: String) -> Bool {
  let terminated_base = base == "" || string.ends_with(base, "\n")
  !terminated_base
  || string.ends_with(edited, "\n")
  || { base == "" && edited == "" }
}

// The round trip every plannable pair must make, and the refusal every
// unplannable one must earn.
fn assert_lands(base: String, edited: String) -> Nil {
  case hashline.plan_between(base:, edited:) {
    Ok(plan) -> {
      assert plan.digest == hashline.digest(base)
      assert list.length(plan.hunks) <= 1
      assert hashline.apply(base, plan) == Ok(edited)
    }

    Error(UnreachableEnding) -> {
      assert !ending_reachable(base, edited)
    }
  }
}

pub fn plan_between_fixed_cases_test() {
  let pairs = [
    // An identifier renamed on a middle, first, and last line.
    #("fn foo() {\n  foo()\n}\n", "fn foo() {\n  bar()\n}\n"),
    #("foo\nb\nc\n", "bar\nb\nc\n"),
    #("a\nb\nfoo\n", "a\nb\nbar\n"),
    // No trailing newline, edited at the last line.
    #("a\nb\nfoo", "a\nb\nbar"),
    // CRLF terminators travel with their lines.
    #("a\r\nfoo\r\nc\r\n", "a\r\nbar\r\nc\r\n"),
    #("a\r\nb\r\n", "a\r\nb\r\nc\r\n"),
    // Astral characters, which a language server counts as two units.
    #("let 🦀 = foo\n", "let 🦀 = bar\n"),
    // Pure insertion at the start, the middle, and the end.
    #("b\nc\n", "a\nb\nc\n"),
    #("a\nc\n", "a\nb\nc\n"),
    #("a\nb\n", "a\nb\nc\n"),
    // Pure deletion, of the first line, a middle one, and everything.
    #("a\nb\nc\n", "b\nc\n"),
    #("a\nb\nc\n", "a\nc\n"),
    #("a\nb\n", "\n"),
    #("a\nb", ""),
    // Identical lines around the change, where a prefix and a suffix could
    // claim the same line.
    #("x\nx\nx\n", "x\nx\n"),
    #("x\nx\n", "x\nx\nx\n"),
    // An unterminated file gaining a final newline, and an empty one
    // growing.
    #("a", "a\n"),
    #("", "a\n"),
    #("", "\n"),
    // Equal texts, including the empty one.
    #("same\n", "same\n"),
    #("", ""),
  ]
  list.each(pairs, fn(pair) {
    let #(base, edited) = pair
    let assert Ok(_) = hashline.plan_between(base:, edited:)
      as "every fixed pair is plannable"
    assert_lands(base, edited)
  })
}

pub fn plan_between_equal_texts_plan_nothing_test() {
  // An empty plan still checks the digest, which is how a caller asks
  // whether the file is still what it thinks it is.
  let assert Ok(plan) = hashline.plan_between(base: "a\n", edited: "a\n")
  assert plan.hunks == []
  let assert Error(StaleContent(..)) = hashline.apply("b\n", plan)
}

pub fn plan_between_refuses_unreachable_endings_test() {
  let pairs = [#("a\n", "a"), #("a\n", ""), #("", "a"), #("a\r\n", "a\r")]
  list.each(pairs, fn(pair) {
    let #(base, edited) = pair
    assert hashline.plan_between(base:, edited:) == Error(UnreachableEnding)
  })
}

pub fn plan_between_binds_to_base_not_edited_test() {
  // The plan lands on the base and nothing else: the same plan against a
  // file changed far from the hunk rejects on the digest alone, which is
  // what a rename computed against stale text must do.
  let base = "one\ntwo\nthree\nfour\nfive\n"
  let edited = "one\nTWO\nthree\nfour\nfive\n"
  let other = "one\ntwo\nthree\nfour\nFIVE\n"
  let assert Ok(plan) = hashline.plan_between(base:, edited:)
  assert hashline.apply(base, plan) == Ok(edited)
  let assert Error(StaleContent(digest:, fresh: _)) =
    hashline.apply(other, plan)
  assert digest == hashline.digest(other)
}

// How a generated pair's edited text is made from its base. The splice
// kinds come first so shrinking prefers the ordinary edit.
type EditKind {
  SpliceLines
  FlipFinalNewline
  Unrelated
}

// The recipe for an edit of some base not yet known: positions are picks
// wrapped once the base's length is, a run of fresh lines, and a whole
// unrelated file for the `Unrelated` kind.
type EditRecipe {
  EditRecipe(
    kind: EditKind,
    from_pick: Int,
    span_pick: Int,
    fresh: List(String),
    unrelated: String,
  )
}

fn edit_recipe_generator() -> qcheck.Generator(EditRecipe) {
  let kind =
    qcheck.bounded_int(from: 0, to: 5)
    |> qcheck.map(fn(n) {
      case n {
        4 -> FlipFinalNewline
        5 -> Unrelated
        _ -> SpliceLines
      }
    })
  let fresh =
    qcheck.generic_list(
      elements_from: gen.line(),
      length_from: qcheck.bounded_int(from: 0, to: 3),
    )
  qcheck.map5(
    kind,
    gen.pick(),
    gen.pick(),
    fresh,
    gen.content(min_lines: 2, max_lines: 5),
    fn(kind, from_pick, span_pick, fresh, unrelated) {
      EditRecipe(kind:, from_pick:, span_pick:, fresh:, unrelated:)
    },
  )
}

// An edit of `base` by the recipe: splice a run of fresh lines over a
// range, sometimes flip the final newline, and sometimes throw the whole
// text away for an unrelated one.
fn edit_of(base: String, recipe: EditRecipe) -> String {
  let split = hashline.split_lines(base)
  let total = list.length(split.lines)
  let from = gen.wrap(recipe.from_pick, total + 1)
  let to = from + gen.wrap(recipe.span_pick, total - from + 1)
  let spliced =
    list.flatten([
      list.take(split.lines, from),
      recipe.fresh,
      list.drop(split.lines, to),
    ])

  case recipe.kind {
    Unrelated -> recipe.unrelated
    FlipFinalNewline ->
      hashline.join_lines(Split(
        lines: spliced,
        trailing_newline: !split.trailing_newline,
      ))
    SpliceLines -> hashline.join_lines(Split(..split, lines: spliced))
  }
}

// A concurrent modification of `base`: one line changed, gained, or lost.
// The kinds are picked by index and the position by a wrapped pick.
fn disturb(base: String, kind: Int, at_pick: Int) -> String {
  let split = hashline.split_lines(base)
  let total = list.length(split.lines)
  let at = gen.wrap(at_pick, int.max(total, 1))
  let lines = case kind, split.lines {
    0, [_, ..] ->
      list.index_map(split.lines, fn(line, index) {
        case index == at {
          True -> line <> "!concurrent!"
          False -> line
        }
      })
    1, [_, ..] ->
      list.append(list.take(split.lines, at), list.drop(split.lines, at + 1))
    _, _ ->
      list.flatten([
        list.take(split.lines, at),
        ["inserted"],
        list.drop(split.lines, at),
      ])
  }
  hashline.join_lines(Split(..split, lines:))
}

// A staleness rejection, as opposed to one about the plan's own shape.
fn is_stale(rejection: hashline.ApplyError) -> Bool {
  case rejection {
    StaleAnchors(..) | StaleContent(..) -> True
    MalformedPlan(..) | OverlappingHunks(..) -> False
  }
}

// One generated pair, and the concurrent modification of its base that a
// plan for the pair must refuse to land on.
type PlanCase {
  PlanCase(base: String, edited: String, other: String)
}

// CRLF lines, astral characters, blank runs, with and without a final
// newline, edits at every position. Shrinks toward an empty or one-line
// base, spliced at its first line.
fn plan_case_generator() -> qcheck.Generator(PlanCase) {
  qcheck.map4(
    gen.either_content(min_lines: 0, max_lines: 8),
    edit_recipe_generator(),
    qcheck.bounded_int(from: 0, to: 2),
    gen.pick(),
    fn(base, recipe, disturbance, at_pick) {
      PlanCase(
        base:,
        edited: edit_of(base, recipe),
        other: modified(base, disturbance, at_pick),
      )
    },
  )
}

// A concurrent modification that really modifies. Deleting the only line of
// "\n", a single blank one, leaves "\n" behind, because zero blank lines and
// one terminate the same way; that is not "one line changed, gained, or
// lost", so it is replaced by the insertion, which always changes the text.
fn modified(base: String, kind: Int, at_pick: Int) -> String {
  case disturb(base, kind, at_pick) == base {
    True -> disturb(base, 2, at_pick)
    False -> disturb(base, kind, at_pick)
  }
}

/// How many pairs the plan round trip is checked over.
const plan_case_count = 400

// For many generated pairs the plan lands exactly on the base and on
// nothing else.
pub fn plan_between_round_trip_property_test() {
  qcheck.run(property_config(plan_case_count), plan_case_generator(), fn(drawn) {
    let PlanCase(base:, edited:, other:) = drawn
    assert_lands(base, edited)

    case hashline.plan_between(base:, edited:) {
      Error(UnreachableEnding) -> Nil
      Ok(plan) -> {
        assert other != base
        let assert Error(rejection) = hashline.apply(other, plan)
          as "a plan must never land on text it was not planned against"
        assert is_stale(rejection)
      }
    }
  })
}

// The generator must mostly produce plannable pairs, or the property
// above is checking refusals and little else. `qcheck.run` cannot count
// across cases, so the same draw is made here and tallied directly.
pub fn plan_between_generator_mostly_plans_test() {
  let #(cases, _seed) =
    qcheck.generate(
      plan_case_generator(),
      plan_case_count,
      qcheck.seed(property_seed),
    )
  let planned =
    list.count(cases, fn(drawn) {
      case hashline.plan_between(base: drawn.base, edited: drawn.edited) {
        Ok(_) -> True
        Error(UnreachableEnding) -> False
      }
    })
  assert planned > plan_case_count * 3 / 4
}
