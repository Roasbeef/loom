//// Every rule gets a positive and a negative case. A rule that cannot fail
//// is worse than no rule: it reads as coverage and provides none.

import gleam/list
import gleam/string
import gleeunit
import gleeunit/should
import lint
import lint/finding.{type Finding, type Rule}
import lint/policy
import lint/source

pub fn main() {
  gleeunit.main()
}

// --- helpers ----------------------------------------------------------------

fn findings(code: String) -> List(Finding) {
  lint.check("t.gleam", code, policy.default())
}

fn rules_fired(code: String) -> List(Rule) {
  findings(code) |> list.map(fn(found) { found.rule })
}

fn fired(code: String, rule: Rule) -> Bool {
  list.contains(rules_fired(code), rule)
}

/// A module with the four stdlib modules the rules watch already imported.
fn module(body: String) -> String {
  "import gleam/bool
import gleam/list
import gleam/option
import gleam/result

" <> body <> "
"
}

// --- R1: the eager fallback -------------------------------------------------

/// The exact shape that made `core/json` quadratic at `08cdbce`: a guard
/// whose `return:` builds a report, on the happy path, for every character.
pub fn r1_flags_the_json_regression_test() {
  module(
    "fn f(cursor, code) {
  use <- bool.guard(
    when: code < 0x20,
    return: Error(fail(cursor, \"control characters to be escaped\")),
  )
  Ok(cursor)
}",
  )
  |> fired(finding.EagerFallback)
  |> should.be_true
}

pub fn r1_flags_replace_error_over_a_call_test() {
  module(
    "fn f(cursor, code) {
  result.replace_error(codepoint(code), fail(cursor, \"a codepoint\"))
}",
  )
  |> fired(finding.EagerFallback)
  |> should.be_true
}

pub fn r1_flags_a_concatenated_fallback_test() {
  module("fn f(value, name) { option.unwrap(value, \"no \" <> name) }")
  |> fired(finding.EagerFallback)
  |> should.be_true
}

pub fn r1_flags_a_pipeline_fallback_test() {
  module("fn f(value, xs) { result.unwrap(value, xs |> list.reverse) }")
  |> fired(finding.EagerFallback)
  |> should.be_true
}

pub fn r1_flags_the_piped_call_form_test() {
  module("fn f(value, xs) { value |> result.unwrap(list.reverse(xs)) }")
  |> fired(finding.EagerFallback)
  |> should.be_true
}

pub fn r1_flags_through_a_module_alias_test() {
  "import gleam/bool as b

fn f(x, cursor) {
  use <- b.guard(when: x, return: Error(fail(cursor, \"nope\")))
  Ok(x)
}
"
  |> fired(finding.EagerFallback)
  |> should.be_true
}

pub fn r1_flags_an_unqualified_import_test() {
  "import gleam/bool.{guard}

fn f(x, cursor) {
  use <- guard(when: x, return: Error(fail(cursor, \"nope\")))
  Ok(x)
}
"
  |> fired(finding.EagerFallback)
  |> should.be_true
}

/// A literal, a bare variable, a nullary constructor and a constructor over
/// those are values the call would happily compute anyway.
pub fn r1_leaves_trivially_cheap_fallbacks_alone_test() {
  module(
    "fn f(x, value, other, n) {
  let a = bool.guard(when: x, return: Error(Nil))
  let b = option.unwrap(value, \"\")
  let c = result.unwrap(value, other)
  let d = result.replace_error(value, Invalid(n, other))
  let e = option.or(value, None)
  let g = result.unwrap(value, n + 1)
  #(a, b, c, d, e, g)
}",
  )
  |> rules_fired
  |> list.contains(finding.EagerFallback)
  |> should.be_false
}

pub fn r1_leaves_the_lazy_counterparts_alone_test() {
  module(
    "fn f(x, cursor) {
  use <- bool.lazy_guard(when: x, return: fn() { Error(fail(cursor, \"no\")) })
  Ok(x)
}",
  )
  |> rules_fired
  |> list.contains(finding.EagerFallback)
  |> should.be_false
}

/// A closure is O(1) to build, so an eager argument that is one costs
/// nothing — this is why `lazy_guard`'s own argument must not flag.
pub fn r1_leaves_a_closure_argument_alone_test() {
  module("fn f(value) { result.unwrap(value, fn() { expensive() }) }")
  |> rules_fired
  |> list.contains(finding.EagerFallback)
  |> should.be_false
}

/// The label decides, not the position: `bool.guard`'s first argument is the
/// condition and may be as expensive as it likes.
pub fn r1_ignores_the_lazy_position_test() {
  module(
    "fn f(xs) {
  use <- bool.guard(when: list.is_empty(list.reverse(xs)), return: Nil)
  Nil
}",
  )
  |> rules_fired
  |> list.contains(finding.EagerFallback)
  |> should.be_false
}

// --- R2: nesting depth ------------------------------------------------------

pub fn r2_flags_a_pyramid_test() {
  module(
    "fn f(a, b, c, d) {
  case a {
    Ok(x) ->
      case b {
        Ok(y) ->
          case c {
            Ok(z) ->
              case d {
                Ok(w) -> Ok(#(x, y, z, w))
                Error(e) -> Error(e)
              }
            Error(e) -> Error(e)
          }
        Error(e) -> Error(e)
      }
    Error(e) -> Error(e)
  }
}",
  )
  |> fired(finding.NestingDepth)
  |> should.be_true
}

pub fn r2_leaves_the_threshold_depth_alone_test() {
  module(
    "fn f(a, b, c) {
  case a {
    Ok(x) ->
      case b {
        Ok(y) ->
          case c {
            Ok(z) -> Ok(#(x, y, z))
            Error(e) -> Error(e)
          }
        Error(e) -> Error(e)
      }
    Error(e) -> Error(e)
  }
}",
  )
  |> rules_fired
  |> list.contains(finding.NestingDepth)
  |> should.be_false
}

/// The whole reason R2 parses rather than counting columns: a wide literal
/// the formatter broke one argument per line looks deep and is not.
pub fn r2_ignores_a_formatter_wrapped_literal_test() {
  module(
    "fn f(a, b, c, d, e, g, h) {
  Envelope(
    first: a,
    second: b,
    third: c,
    fourth: Nested(
      fifth: d,
      sixth: e,
      seventh: Inner(eighth: g, ninth: h, tenth: Leaf(final: a)),
    ),
  )
}",
  )
  |> rules_fired
  |> list.contains(finding.NestingDepth)
  |> should.be_false
}

// --- R3: catch-all patterns -------------------------------------------------

pub fn r3_flags_a_flat_variant_dispatch_test() {
  module(
    "fn f(status) {
  case status {
    Pending -> Ok(Nil)
    Granted -> Ok(Nil)
    _ -> Error(Nil)
  }
}",
  )
  |> fired(finding.CatchAll)
  |> should.be_true
}

/// No exhaustive enumeration of `Int` exists, so `_ ->` is mandatory.
pub fn r3_leaves_a_primitive_subject_alone_test() {
  module(
    "fn f(code) {
  case code {
    0x20 -> Ok(Nil)
    0x09 -> Ok(Nil)
    _ -> Error(Nil)
  }
}",
  )
  |> rules_fired
  |> list.contains(finding.CatchAll)
  |> should.be_false
}

/// A literal nested inside a list pattern discriminates on `Int` just as
/// surely as a bare one: `[0x22, ..rest]` is not enumerable either.
pub fn r3_leaves_a_nested_literal_subject_alone_test() {
  module(
    "fn f(rest) {
  case rest {
    [0x22, ..tail] -> Ok(tail)
    _ -> Error(Nil)
  }
}",
  )
  |> rules_fired
  |> list.contains(finding.CatchAll)
  |> should.be_false
}

/// `_ ->` over a combination stands for the remaining combinations, not for
/// a sibling variant.
pub fn r3_leaves_a_combination_match_alone_test() {
  module(
    "fn f(value) {
  case value {
    Ok(Some(Cell(seq: seq, value: v))) -> Ok(#(seq, v))
    _ -> Error(Nil)
  }
}",
  )
  |> rules_fired
  |> list.contains(finding.CatchAll)
  |> should.be_false
}

pub fn r3_leaves_a_multi_subject_case_alone_by_default_test() {
  module(
    "fn f(a, b) {
  case a, b {
    Running, Safe -> True
    _, _ -> False
  }
}",
  )
  |> rules_fired
  |> list.contains(finding.CatchAll)
  |> should.be_false
}

pub fn r3_names_the_two_arm_predicate_shape_test() {
  let detail =
    module(
      "fn f(status) {
  case status {
    Pending -> True
    _ -> False
  }
}",
    )
    |> findings
    |> list.filter(fn(found) { found.rule == finding.CatchAll })
    |> list.map(fn(found) { found.detail })
  case detail {
    [only] -> should.be_true(string.contains(only, "two-arm predicate"))
    _ -> should.fail()
  }
}

// --- R4: panic and let assert in src ---------------------------------------

pub fn r4_flags_panic_test() {
  module("fn f(x) { case x { True -> Nil False -> panic as \"no\" } }")
  |> fired(finding.PanicInSource)
  |> should.be_true
}

pub fn r4_flags_let_assert_test() {
  module("fn f(value) { let assert Ok(inner) = value inner }")
  |> fired(finding.PanicInSource)
  |> should.be_true
}

pub fn r4_is_off_for_tests_test() {
  lint.check(
    "t_test.gleam",
    module("fn f(value) { let assert Ok(inner) = value inner }"),
    policy.for_tests(),
  )
  |> list.map(fn(found) { found.rule })
  |> list.contains(finding.PanicInSource)
  |> should.be_false
}

/// The token scan behind R4's fail-closed backstop sees real keywords and
/// not the same words inside a string.
pub fn r4_keyword_scan_reads_tokens_not_text_test() {
  source.keyword_offsets("fn f() { panic }").panics
  |> list.length
  |> should.equal(1)

  source.keyword_offsets("const c = \"panic\"").panics
  |> should.equal([])

  source.keyword_offsets("fn f(v) { let assert Ok(x) = v x }").let_asserts
  |> list.length
  |> should.equal(1)
}

// --- R5: an O(n) answer to a bounded question -------------------------------

pub fn r5_flags_a_literal_bound_test() {
  module("fn f(rest) { list.length(rest) > 24 }")
  |> fired(finding.BoundedLength)
  |> should.be_true
}

pub fn r5_flags_a_named_bound_test() {
  module("fn f(queue, bound) { list.length(queue) < bound }")
  |> fired(finding.BoundedLength)
  |> should.be_true
}

pub fn r5_flags_the_piped_form_test() {
  module("fn f(xs, cap) { { xs |> list.length } >= cap }")
  |> fired(finding.BoundedLength)
  |> should.be_true
}

/// Neither side is a bound the other can stop at.
pub fn r5_leaves_two_counts_alone_test() {
  module("fn f(a, b) { list.length(a) == list.length(b) }")
  |> rules_fired
  |> list.contains(finding.BoundedLength)
  |> should.be_false
}

pub fn r5_leaves_an_uncompared_count_alone_test() {
  module("fn f(xs) { list.length(xs) }")
  |> rules_fired
  |> list.contains(finding.BoundedLength)
  |> should.be_false
}

// --- R0 and totality --------------------------------------------------------

pub fn r0_reports_a_parse_failure_rather_than_crashing_test() {
  case findings("pub fn ( { ") {
    [only] -> should.equal(only.rule, finding.Unparseable)
    _ -> should.fail()
  }
}

pub fn empty_and_odd_input_is_total_test() {
  list.each(
    [
      "", "\n\n\n", "////\n", "// just a comment\n", "import\n",
      "pub fn f() { }\n", "const x = 1\n", "pub type T { A }\n",
    ],
    fn(code) {
      // Any result at all is a pass; the point is that nothing crashes.
      lint.check("t.gleam", code, policy.default())
      |> list.length
      |> should.not_equal(-1)
    },
  )
}

// --- locations --------------------------------------------------------------

pub fn findings_land_on_the_right_line_test() {
  let code =
    "import gleam/list

fn f(xs) {
  let a = 1
  list.length(xs) > 3
}
"
  case findings(code) {
    [only] -> should.equal(only.line, 5)
    _ -> should.fail()
  }
}

pub fn findings_name_the_enclosing_function_test() {
  case findings(module("fn measure(xs) { list.length(xs) > 3 }")) {
    [only] -> should.equal(only.function, "measure")
    _ -> should.fail()
  }
}

pub fn line_index_counts_from_one_test() {
  let starts = source.line_starts("a\nbb\n\nc")
  should.equal(source.lines_of(starts, [0, 2, 5, 6]), [1, 2, 3, 4])
}
