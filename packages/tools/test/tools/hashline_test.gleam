import gleam/int
import gleam/list
import gleam/string
import support/generate
import tools/hashline.{
  type Ref, AnchoredLine, Delete, InsertAfter, InsertAtStart, MalformedPlan,
  OverlappingHunks, Plan, Ref, Replace, Split, StaleAnchors,
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
  let seeds = generate.seed(11)
  let #(contents, _seed) =
    generate.list_of(seeds, 50, fn(seed) {
      let #(count, seed) = generate.int_between(seed, 0, 12)
      generate.content(seed, count)
    })
  list.each(contents, fn(content) {
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

pub fn apply_single_replace_test() {
  let content = "one\ntwo\nthree\n"
  let plan =
    Plan([Replace(ref_to(content, 2), ref_to(content, 2), ["TWO", "extra"])])
  assert hashline.apply(content, plan) == Ok("one\nTWO\nextra\nthree\n")
}

pub fn apply_range_replace_test() {
  let content = "a\nb\nc\nd"
  let plan = Plan([Replace(ref_to(content, 2), ref_to(content, 3), ["X"])])
  assert hashline.apply(content, plan) == Ok("a\nX\nd")
}

pub fn apply_delete_test() {
  let content = "a\nb\nc\n"
  let plan = Plan([Delete(ref_to(content, 2), ref_to(content, 2))])
  assert hashline.apply(content, plan) == Ok("a\nc\n")
}

pub fn apply_insert_after_test() {
  let content = "a\nc\n"
  let plan = Plan([InsertAfter(ref_to(content, 1), ["b"])])
  assert hashline.apply(content, plan) == Ok("a\nb\nc\n")
}

pub fn apply_insert_at_start_test() {
  let content = "b\n"
  let plan = Plan([InsertAtStart(["a"])])
  assert hashline.apply(content, plan) == Ok("a\nb\n")
}

pub fn apply_insert_into_empty_file_test() {
  let plan = Plan([InsertAtStart(["only"])])
  assert hashline.apply("", plan) == Ok("only\n")
}

pub fn apply_multi_hunk_test() {
  let content = "one\ntwo\nthree\nfour\nfive\n"
  let plan =
    Plan([
      Delete(ref_to(content, 4), ref_to(content, 4)),
      Replace(ref_to(content, 1), ref_to(content, 1), ["ONE"]),
      InsertAfter(ref_to(content, 2), ["two-and-a-half"]),
    ])
  assert hashline.apply(content, plan)
    == Ok("ONE\ntwo\ntwo-and-a-half\nthree\nfive\n")
}

pub fn apply_preserves_no_trailing_newline_test() {
  let content = "a\nb"
  let plan = Plan([Replace(ref_to(content, 1), ref_to(content, 1), ["A"])])
  assert hashline.apply(content, plan) == Ok("A\nb")
}

pub fn apply_preserves_crlf_bytes_test() {
  // Only line 2 is touched; line 1 keeps its \r byte exactly.
  let content = "a\r\nb\r\n"
  let plan = Plan([Replace(ref_to(content, 2), ref_to(content, 2), ["B\r"])])
  assert hashline.apply(content, plan) == Ok("a\r\nB\r\n")
}

pub fn apply_unicode_lines_test() {
  let content = "日本語\n🦀\n"
  let plan = Plan([Replace(ref_to(content, 2), ref_to(content, 2), ["🦞"])])
  assert hashline.apply(content, plan) == Ok("日本語\n🦞\n")
}

// --- apply: rejections ---------------------------------------------------

pub fn apply_stale_anchor_rejected_test() {
  let content = "one\ntwo\nthree\n"
  let plan = Plan([Replace(ref_to(content, 2), ref_to(content, 2), ["TWO"])])
  // The file changed between read and edit.
  let modified = "one\ntwo changed\nthree\n"
  let assert Error(StaleAnchors(stale: [stale])) =
    hashline.apply(modified, plan)
  assert stale.line == 2
  assert stale.expected == hashline.anchor("two")
}

pub fn apply_stale_carries_fresh_anchors_test() {
  let content = "one\ntwo\nthree\nfour\nfive\n"
  let plan = Plan([Replace(ref_to(content, 3), ref_to(content, 3), ["THREE"])])
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
    Plan([
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
    hashline.apply(content, Plan([good, bad]))
  // And nothing was applied: content is untouched by a rejection (apply
  // is pure, but the invariant worth stating is that no partial result
  // is ever returned).
}

pub fn apply_overlapping_ranges_rejected_test() {
  let content = "a\nb\nc\nd\n"
  let plan =
    Plan([
      Replace(ref_to(content, 1), ref_to(content, 3), ["x"]),
      Delete(ref_to(content, 3), ref_to(content, 4)),
    ])
  let assert Error(OverlappingHunks(line: 3)) = hashline.apply(content, plan)
}

pub fn apply_insert_inside_replaced_range_rejected_test() {
  let content = "a\nb\nc\n"
  let plan =
    Plan([
      Replace(ref_to(content, 1), ref_to(content, 2), ["x"]),
      InsertAfter(ref_to(content, 2), ["y"]),
    ])
  let assert Error(OverlappingHunks(line: 2)) = hashline.apply(content, plan)
}

pub fn apply_duplicate_insert_point_rejected_test() {
  let content = "a\nb\n"
  let plan =
    Plan([
      InsertAfter(ref_to(content, 1), ["x"]),
      InsertAfter(ref_to(content, 1), ["y"]),
    ])
  let assert Error(OverlappingHunks(line: 1)) = hashline.apply(content, plan)
}

pub fn apply_adjacent_hunks_are_legal_test() {
  let content = "a\nb\nc\nd\n"
  let plan =
    Plan([
      Replace(ref_to(content, 1), ref_to(content, 2), ["AB"]),
      Replace(ref_to(content, 3), ref_to(content, 4), ["CD"]),
    ])
  assert hashline.apply(content, plan) == Ok("AB\nCD\n")
}

pub fn apply_inverted_range_malformed_test() {
  let content = "a\nb\n"
  let plan = Plan([Replace(ref_to(content, 2), ref_to(content, 1), ["x"])])
  let assert Error(MalformedPlan(reason: _)) = hashline.apply(content, plan)
}

pub fn apply_line_zero_malformed_test() {
  let plan =
    Plan([
      Delete(Ref(line: 0, anchor: "cbf29ce4"), Ref(line: 0, anchor: "cbf29ce4")),
    ])
  let assert Error(MalformedPlan(reason: _)) = hashline.apply("a\n", plan)
}

pub fn apply_newline_in_replacement_malformed_test() {
  let content = "a\n"
  let plan = Plan([Replace(ref_to(content, 1), ref_to(content, 1), ["x\ny"])])
  let assert Error(MalformedPlan(reason: _)) = hashline.apply(content, plan)
}

pub fn apply_empty_plan_is_identity_test() {
  assert hashline.apply("a\nb", Plan([])) == Ok("a\nb")
}

// --- apply: properties ---------------------------------------------------

// A plan built from a document's real anchors applies, deterministically.
pub fn apply_deterministic_property_test() {
  list.each(generate.list_of(generate.seed(23), 30, generate.next).0, fn(n) {
    let #(content, seed) = generate.content(generate.seed(n), 8)
    let total = list.length(hashline.split_lines(content).lines)
    case total >= 4 {
      False -> Nil
      True -> {
        let #(replacement, _seed) = generate.line(seed)
        let plan =
          Plan([
            Replace(ref_to(content, 2), ref_to(content, 2), [replacement]),
            Delete(ref_to(content, 4), ref_to(content, 4)),
          ])
        let first = hashline.apply(content, plan)
        let second = hashline.apply(content, plan)
        let assert Ok(_) = first as "a plan from real anchors must apply"
        assert first == second
      }
    }
  })
}

// Editing after a concurrent modification of a referenced line is
// always rejected.
pub fn apply_concurrent_modification_property_test() {
  list.each(generate.list_of(generate.seed(31), 30, generate.next).0, fn(n) {
    let #(content, _seed) = generate.content(generate.seed(n), 6)
    let split = hashline.split_lines(content)
    case list.length(split.lines) >= 3 {
      False -> Nil
      True -> {
        let plan =
          Plan([Replace(ref_to(content, 2), ref_to(content, 2), ["edited"])])
        // Mutate exactly the referenced line.
        let modified_lines =
          list.index_map(split.lines, fn(line, index) {
            case index == 1 {
              True -> line <> "!concurrent!"
              False -> line
            }
          })
        let modified =
          hashline.join_lines(Split(..split, lines: modified_lines))
        let assert Error(StaleAnchors(stale: [stale])) =
          hashline.apply(modified, plan)
        assert stale.line == 2
      }
    }
  })
}

// Anchors are content hashes: editing some lines never changes the
// anchors of untouched lines.
pub fn anchors_stable_under_unrelated_edits_property_test() {
  list.each(generate.list_of(generate.seed(47), 30, generate.next).0, fn(n) {
    let #(content, _seed) = generate.content(generate.seed(n), 6)
    let total = list.length(hashline.split_lines(content).lines)
    case total >= 3 {
      False -> Nil
      True -> {
        let plan =
          Plan([Replace(ref_to(content, 1), ref_to(content, 1), ["changed"])])
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
      }
    }
  })
}

// Applied edits are byte-exact: reconstructing the expected output by
// hand equals the applied output.
pub fn apply_byte_exact_property_test() {
  list.each(generate.list_of(generate.seed(59), 30, generate.next).0, fn(n) {
    let #(content, seed) = generate.content(generate.seed(n), 7)
    let split = hashline.split_lines(content)
    let total = list.length(split.lines)
    case total >= 2 {
      False -> Nil
      True -> {
        let #(index, seed) = generate.int_between(seed, 1, total)
        let #(replacement, _seed) = generate.line(seed)
        let plan =
          Plan([
            Replace(ref_to(content, index), ref_to(content, index), [
              replacement,
            ]),
          ])
        let expected_lines =
          list.index_map(split.lines, fn(line, position) {
            case position == index - 1 {
              True -> replacement
              False -> line
            }
          })
        let expected =
          hashline.join_lines(Split(..split, lines: expected_lines))
        assert hashline.apply(content, plan) == Ok(expected)
      }
    }
  })
}

pub fn reapply_after_success_is_rejected_test() {
  // The anchor-idempotency argument behind fs_edit's replay safety: a
  // plan applied once cannot apply again, because it consumed the
  // content its anchors named.
  let content = "one\ntwo\nthree\n"
  let plan = Plan([Replace(ref_to(content, 2), ref_to(content, 2), ["TWO"])])
  let assert Ok(edited) = hashline.apply(content, plan)
  let assert Error(StaleAnchors(stale: _)) = hashline.apply(edited, plan)
}

pub fn identical_lines_disambiguated_by_line_number_test() {
  // Two identical lines share an anchor; the line number picks one.
  let content = "same\nsame\n"
  let plan = Plan([Replace(ref_to(content, 2), ref_to(content, 2), ["other"])])
  assert hashline.apply(content, plan) == Ok("same\nother\n")
}

pub fn fresh_context_constant_is_reported_width_test() {
  let content =
    generate.list_of(generate.seed(3), 9, generate.line).0
    |> string.join(with: "\n")
  let plan =
    Plan([
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
