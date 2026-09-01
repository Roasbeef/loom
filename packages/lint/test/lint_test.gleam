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

/// What `scripts/lint.sh` would read from a run over this one source:
/// `#(errors, warnings)` under the default staging. The path matters —
/// R4's exemption and R6 both key on the package it names.
fn gate_of(path: String, code: String) -> #(Int, Int) {
  lint.check(path, code, policy.default())
  |> finding.gate(finding.error_by_default())
}

fn catch_all_details(code: String) -> List(String) {
  findings(code)
  |> list.filter(fn(found) { found.rule == finding.CatchAll })
  |> list.map(fn(found) { found.detail })
}

/// A module with the four stdlib modules the rules watch already imported.
fn module(body: String) -> String {
  "import gleam/bool
import gleam/list
import gleam/option
import gleam/result
import gleam/string

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

// --- R1's other half: locally-defined `use`-compatible combinators ---------
//
// Issue #56: R1 knew six stdlib combinators by name and nothing about the
// `or_fault` lineage this tree writes for itself — so `machine/planner`'s
// `or_fault_unless` and `tools/fs`'s `require` both built an eager argument
// on every call, on the exact hazard's happy path, with the census
// reporting the packages clean. These pin both shapes, structurally: the
// first by the "last parameter is `fn(…)`, others are not" signature (any
// locally-defined function of that shape, not `or_fault_unless` by name),
// the second by the hand-curated table row `require` needed because it
// takes no continuation at all.

/// The exact shape `machine/planner.gleam:2377` was: a report built on
/// every staged tool result, whether the fault fires or not.
pub fn r1_flags_a_local_use_combinator_by_signature_test() {
  "fn or_fault_unless(condition: Bool, report: Report, then: fn() -> Action) -> Action {
  case condition {
    True -> then()
    False -> Fault(report:)
  }
}

fn stage_result(ok: Bool, cursor: Cursor) -> Action {
  use <- or_fault_unless(ok, build_report(cursor))
  Continue
}
"
  |> fired(finding.EagerFallback)
  |> should.be_true
}

/// The house pattern itself — subject first, continuation last, nothing
/// between — must never flag: `or_fault`, `or_halt` and `or_key_halt` are
/// exactly this shape everywhere they appear, and their subject is real
/// work the combinator is *supposed* to run, not a discarded fallback.
pub fn r1_leaves_a_two_parameter_local_combinator_alone_test() {
  "fn or_fault(result: Result(a, Report), then: fn(a) -> Action) -> Action {
  case result {
    Error(report) -> Fault(report:)
    Ok(value) -> then(value)
  }
}

fn stage_result(compute_result: fn(Int, Int) -> Result(Int, Report)) -> Action {
  use value <- or_fault(compute_result(1, 2))
  Continue(value)
}
"
  |> rules_fired
  |> list.contains(finding.EagerFallback)
  |> should.be_false
}

/// A local combinator's middle parameter is exactly as cheap-exempt as a
/// stdlib one's — only the shape differs, not the cheapness test.
pub fn r1_leaves_a_cheap_local_combinator_argument_alone_test() {
  "fn or_fault_unless(condition: Bool, report: Report, then: fn() -> Action) -> Action {
  case condition {
    True -> then()
    False -> Fault(report:)
  }
}

fn stage_result(ok: Bool, report: Report) -> Action {
  use <- or_fault_unless(ok, report)
  Continue
}
"
  |> rules_fired
  |> list.contains(finding.EagerFallback)
  |> should.be_false
}

/// A second function-typed parameter disqualifies the shape entirely —
/// `or_fail`'s `to_error: fn(e) -> ProviderError` is not the continuation,
/// and nothing about this signature says which non-last parameter (if
/// either) is the eager one.
pub fn r1_leaves_two_function_parameters_alone_test() {
  "fn or_fail(
  result: Result(a, e),
  to_error: fn(e) -> ProviderError,
  then: fn(a) -> Outcome,
) -> Outcome {
  case result {
    Error(err) -> fail(to_error(err))
    Ok(value) -> then(value)
  }
}

fn f(compute_result: fn() -> Result(Int, Err), describe: fn(Err) -> ProviderError) -> Outcome {
  use value <- or_fail(compute_result(), describe)
  Continue(value)
}
"
  |> rules_fired
  |> list.contains(finding.EagerFallback)
  |> should.be_false
}

/// Issue #73, C: nine of the first census's thirty-three R1 findings were
/// this shape — `session/session.read_cell(session, ns, key, decode)`,
/// whose `key` merely sits between the subject and the continuation while
/// the body hands it straight to the register read. A parameter the
/// combinator has already used by the time it decides anything is not a
/// discarded fallback, and there is nothing to make lazy.
pub fn r1_leaves_a_parameter_used_before_the_decision_alone_test() {
  module(
    "fn read_cell(session, ns, key, decode: fn(a) -> Result(b, c)) {
  use found <- result.try(get_register(session, ns, key))
  case found {
    None -> Ok(None)
    Some(value) -> decode(value)
  }
}

fn op_meta(session, id) {
  read_cell(session, OpMeta, op_id_to_string(id), decode_meta)
}",
  )
  |> rules_fired
  |> list.contains(finding.EagerFallback)
  |> should.be_false
}

/// The same shape once more, in the spelling that produced five of the
/// nine: `claimed_effect(ctl, key, on_claim)`, where `key` is what the
/// guard's own condition is computed from.
pub fn r1_leaves_a_parameter_the_guard_reads_alone_test() {
  module(
    "fn claimed_effect(ctl, key, on_claim: fn() -> Fate) -> Fate {
  use <- bool.guard(when: !claim(ctl, key), return: Ran)
  on_claim()
}

fn effect_fault(ctl, op) {
  use <- claimed_effect(ctl, \"fault:\" <> op)
  Faulted
}",
  )
  |> rules_fired
  |> list.contains(finding.EagerFallback)
  |> should.be_false
}

/// A body that branches on something other than its own subject is not the
/// shape this rule knows, and an unrecognized shape drops its rows rather
/// than guessing at them.
pub fn r1_leaves_a_combinator_that_branches_elsewhere_alone_test() {
  module(
    "fn or_something(subject, report, then: fn() -> Action) -> Action {
  case ambient_state() {
    True -> then()
    False -> Fault(subject, report)
  }
}

fn stage(ok, cursor) {
  use <- or_something(ok, build_report(cursor))
  Continue
}",
  )
  |> rules_fired
  |> list.contains(finding.EagerFallback)
  |> should.be_false
}

/// The exact shape `tools/fs.gleam:773` was, pinned at the path R1's
/// hand-curated `require` row is keyed under — `require` takes no
/// continuation at all, so this is the table half of the fix, not the
/// structural half above.
pub fn r1_flags_the_require_regression_test() {
  lint.check(
    "packages/tools/src/tools/fs.gleam",
    "fn require(optional, when_absent) {
  case optional {
    Ok(Some(value)) -> Ok(value)
    Ok(None) -> Error(when_absent)
    Error(reason) -> Error(reason)
  }
}

fn decode_ref(value, key) {
  require(optional_int(value, \"line\"), when_absent: \"`\" <> key <> \".line` is required\")
}
",
    policy.default(),
  )
  |> list.map(fn(found) { found.rule })
  |> list.contains(finding.EagerFallback)
  |> should.be_true
}

/// The same `require` row must not fire once the call is lazy — and must
/// not fire at all for a same-named, same-shaped function in a *different*
/// file, since the row is keyed by path as well as by name.
pub fn r1_require_row_is_lazy_and_path_scoped_test() {
  let lazy =
    lint.check(
      "packages/tools/src/tools/fs.gleam",
      "fn require(optional, when_absent) {
  case optional {
    Ok(Some(value)) -> Ok(value)
    Ok(None) -> Error(when_absent())
    Error(reason) -> Error(reason)
  }
}

fn decode_ref(value, key) {
  require(optional_int(value, \"line\"), when_absent: fn() {
    \"`\" <> key <> \".line` is required\"
  })
}
",
      policy.default(),
    )
  lazy
  |> list.map(fn(found) { found.rule })
  |> list.contains(finding.EagerFallback)
  |> should.be_false

  let elsewhere =
    lint.check(
      "packages/runtime/src/runtime/escalation.gleam",
      "fn require(optional, when_absent) {
  case optional {
    Ok(Some(value)) -> Ok(value)
    Ok(None) -> Error(when_absent)
    Error(reason) -> Error(reason)
  }
}

fn f(value, key) {
  require(optional_int(value, \"line\"), when_absent: \"`\" <> key <> \"` is required\")
}
",
      policy.default(),
    )
  elsewhere
  |> list.map(fn(found) { found.rule })
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

// --- R1 across module boundaries --------------------------------------------

/// A `use`-compatible combinator, as `tools/tool` exports one.
const exported_combinator: String = "pub fn or_outcome(
  result: Result(a, e),
  failed: Outcome,
  then: fn(a) -> Outcome,
) -> Outcome {
  case result {
    Error(_) -> failed
    Ok(value) -> then(value)
  }
}
"

/// Another module calling it, with an eagerly-built fallback.
const calling_module: String = "import tools/tool

fn run(result, cursor) {
  use value <- tool.or_outcome(result, tool.failure(describe(cursor)))
  value
}
"

fn rows_of(path: String, code: String) -> List(policy.Eager) {
  lint.exported_combinators(path, code)
}

/// Sixteen of `tool.or_outcome`'s nineteen call sites are in other modules,
/// and a table built one file at a time saw none of them: clean by luck
/// rather than by coverage (issue #73, D).
pub fn r1_follows_an_exported_combinator_across_modules_test() {
  let rows = rows_of("packages/tools/src/tools/tool.gleam", exported_combinator)
  lint.check_with(
    "packages/tools/src/tools/bash.gleam",
    calling_module,
    policy.default(),
    rows,
  )
  |> list.map(fn(found) { found.rule })
  |> list.contains(finding.EagerFallback)
  |> should.be_true
}

/// And without the table it is invisible, which is what the second pass
/// buys — the same source, the same rule, no rows.
pub fn r1_is_blind_to_that_call_without_the_table_test() {
  lint.check(
    "packages/tools/src/tools/bash.gleam",
    calling_module,
    policy.default(),
  )
  |> list.map(fn(found) { found.rule })
  |> list.contains(finding.EagerFallback)
  |> should.be_false
}

/// A file's own public combinator reaches it twice — once as its own row,
/// once as a row the run collected from every source including this one —
/// and the same call site must still be one finding, not two. The run
/// passes every file the whole table, so this is every public combinator in
/// the tree and not an edge case.
pub fn a_combinator_called_where_it_is_defined_is_one_finding_test() {
  let path = "packages/tools/src/tools/tool.gleam"
  let code = exported_combinator <> "
fn run(result, cursor) {
  use value <- or_outcome(result, failure(describe(cursor)))
  value
}
"
  lint.check_with(path, code, policy.default(), rows_of(path, code))
  |> list.filter(fn(found) { found.rule == finding.EagerFallback })
  |> list.length
  |> should.equal(1)
}

/// A private combinator is not callable from another module, so it
/// contributes nothing to the table other files are judged against.
pub fn only_public_combinators_are_exported_test() {
  rows_of(
    "packages/tools/src/tools/tool.gleam",
    string.replace(exported_combinator, "pub fn", "fn"),
  )
  |> should.equal([])
}

/// The narrowing the cross-module pass made load-bearing: a function whose
/// last parameter is a closure is not a combinator unless that closure
/// produces the function's own result. `call.try_call`'s `sending:` builds
/// a request message and its `waiting:` is used unconditionally — reading
/// the whole tree's exports, this was the first row the pass added and it
/// was wrong.
pub fn a_callback_is_not_a_continuation_test() {
  let defining =
    "pub fn try_call(
  subject: Subject(message),
  waiting timeout: Int,
  sending make_request: fn(Subject(reply)) -> message,
) -> Result(reply, CallFault) {
  use callee <- or_gone(process.subject_owner(subject))
  answer(callee, timeout, make_request)
}
"
  rows_of("packages/broker/src/broker/internal/call.gleam", defining)
  |> should.equal([])
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

/// A bare variable matches everything a `_` does, so R3 has to see it —
/// it was blind to sixty-eight of them, and the serious catch-alls in the
/// tree were all in that hidden set (issue #73, A).
pub fn r3_flags_a_named_catch_all_test() {
  module(
    "fn f(status) {
  case status {
    Pending -> Ok(Nil)
    Granted -> Ok(Nil)
    other -> Error(describe(other))
  }
}",
  )
  |> fired(finding.CatchAll)
  |> should.be_true
}

/// The two spellings do not read the same to a reviewer: a `_ ->` can often
/// be deleted and the variants written in its place, while an `other ->`
/// whose arm reads `other` means every enumerated arm has to name the value.
/// The finding says which one it found, so the census sorts on it.
pub fn r3_distinguishes_the_two_spellings_test() {
  let named =
    module(
      "fn f(status) {
  case status {
    Pending -> Ok(Nil)
    other -> Error(describe(other))
  }
}",
    )
    |> catch_all_details
  case named {
    [only] -> {
      should.be_true(string.contains(only, "`other ->` is a catch-all"))
      should.be_true(string.contains(only, "the arm reads `other`"))
    }
    _ -> should.fail()
  }

  let discarded =
    module(
      "fn f(status) {
  case status {
    Pending -> Ok(Nil)
    _ -> Error(Nil)
  }
}",
    )
    |> catch_all_details
  case discarded {
    [only] -> {
      should.be_true(string.contains(only, "`_ ->`"))
      should.be_false(string.contains(only, "catch-all with a name"))
    }
    _ -> should.fail()
  }
}

/// A guarded arm cannot be exhaustive on its own, so the compiler *demands*
/// the final arm and a finding about it is always wrong — twelve of them in
/// the first census. Remove the guard check in `scan.case_` and this fails.
pub fn r3_leaves_a_case_with_a_guarded_arm_alone_test() {
  module(
    "fn f(installed, owner) {
  case installed {
    Ok(found) if found == owner -> Ok(Nil)
    Ok(_other) -> Error(Nil)
    _ -> Error(Nil)
  }
}",
  )
  |> rules_fired
  |> list.contains(finding.CatchAll)
  |> should.be_false
}

/// The same `case` without the guard is reported, so the test above is
/// pinning the guard and not some other narrowing.
pub fn r3_flags_that_same_case_without_the_guard_test() {
  module(
    "fn f(installed) {
  case installed {
    Ok(found) -> Ok(found)
    _ -> Error(Nil)
  }
}",
  )
  |> fired(finding.CatchAll)
  |> should.be_true
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

/// The other spelling of the same hazard, and the one that hid two hot
/// sites from the first census (issue #73, E).
pub fn r5_flags_the_string_spelling_test() {
  module("fn f(word) { string.length(word) >= 32 }")
  |> fired(finding.BoundedLength)
  |> should.be_true
}

/// The advice has to be about the thing that was counted: `list.drop` is
/// not a bounded question about a string.
pub fn r5_advice_names_the_right_bounded_question_test() {
  let detail = fn(code) {
    findings(code)
    |> list.filter(fn(found) { found.rule == finding.BoundedLength })
    |> list.map(fn(found) { found.detail })
  }
  case detail(module("fn f(word) { string.length(word) >= 32 }")) {
    [only] -> {
      should.be_true(string.contains(only, "string.drop_start(text, 32)"))
      should.be_true(string.contains(only, "graphemes"))
    }
    _ -> should.fail()
  }
  case detail(module("fn f(xs) { list.length(xs) > 24 }")) {
    [only] -> {
      should.be_true(string.contains(only, "list.drop(xs, 24)"))
      should.be_true(string.contains(only, "elements"))
    }
    _ -> should.fail()
  }
}

/// Two counts compared with each other, in the string spelling: neither
/// side is a bound the other can stop at.
pub fn r5_leaves_two_string_counts_alone_test() {
  module("fn f(a, b) { string.length(a) == string.length(b) }")
  |> rules_fired
  |> list.contains(finding.BoundedLength)
  |> should.be_false
}

/// The table is what the rule claims to watch; a test that did not
/// enumerate it would pass against an empty one.
pub fn the_counted_table_names_both_spellings_test() {
  policy.counted_calls()
  |> list.map(fn(call) { call.module <> "." <> call.function })
  |> should.equal(["gleam/list.length", "gleam/string.length"])
}

// --- R7: an admitted `let assert` still names its invariant -----------------

pub fn r7_flags_an_assert_with_no_message_test() {
  module("fn f(value) { let assert Ok(inner) = value inner }")
  |> fired(finding.AssertWithoutMessage)
  |> should.be_true
}

pub fn r7_is_silent_when_the_invariant_is_named_test() {
  module("fn f(value) { let assert Ok(inner) = value as \"decoded\" inner }")
  |> rules_fired
  |> list.contains(finding.AssertWithoutMessage)
  |> should.be_false
}

/// R7 is R4's other half, not a second opinion about R4's question: where
/// `harness_packages` admits the construct, this still asks what the crash
/// will say. All eighty-four of the census live in exactly that place, so a
/// rule that inherited R4's exemption would report nothing at all.
pub fn r7_reaches_the_harness_package_r4_exempts_test() {
  let rules =
    in_package_at(
      "conformance",
      "conformance/runner",
      module("fn f(value) { let assert Ok(inner) = value inner }"),
    )
    |> list.map(fn(found) { found.rule })
  should.be_false(list.contains(rules, finding.PanicInSource))
  should.be_true(list.contains(rules, finding.AssertWithoutMessage))
}

/// And it is off where `let assert` is the house style: a test that
/// destructures a fixture names the invariant in the test's own name.
pub fn r7_is_off_for_tests_test() {
  lint.check(
    "t_test.gleam",
    module("fn f(value) { let assert Ok(inner) = value inner }"),
    policy.for_tests(),
  )
  |> list.map(fn(found) { found.rule })
  |> list.contains(finding.AssertWithoutMessage)
  |> should.be_false
}

// --- R8: a long signature with exactly one caller ---------------------------

/// Eight parameters threaded by hand into a private helper one place calls.
pub fn r8_flags_a_lone_caller_test() {
  module(
    "fn caller(a) { wide(a, a, a, a, a, a, a, a) }

fn wide(a, b, c, d, e, f, g, h) { #(a, b, c, d, e, f, g, h) }",
  )
  |> fired(finding.LoneCallerArity)
  |> should.be_true
}

/// Two callers is a helper rather than a block that was moved out.
pub fn r8_leaves_a_second_caller_alone_test() {
  module(
    "fn one(a) { wide(a, a, a, a, a, a, a, a) }

fn two(a) { wide(a, a, a, a, a, a, a, a) }

fn wide(a, b, c, d, e, f, g, h) { #(a, b, c, d, e, f, g, h) }",
  )
  |> rules_fired
  |> list.contains(finding.LoneCallerArity)
  |> should.be_false
}

/// A public function's callers are not all in this module, so counting them
/// here answers nothing.
pub fn r8_leaves_a_public_function_alone_test() {
  module(
    "fn caller(a) { wide(a, a, a, a, a, a, a, a) }

pub fn wide(a, b, c, d, e, f, g, h) { #(a, b, c, d, e, f, g, h) }",
  )
  |> rules_fired
  |> list.contains(finding.LoneCallerArity)
  |> should.be_false
}

/// The threshold is a boundary, not a ceiling: seven is silent, eight is
/// not. Change `lone_caller_arity` and this is what moves.
pub fn r8_threshold_is_exclusive_test() {
  module(
    "fn caller(a) { wide(a, a, a, a, a, a, a) }

fn wide(a, b, c, d, e, f, g) { #(a, b, c, d, e, f, g) }",
  )
  |> rules_fired
  |> list.contains(finding.LoneCallerArity)
  |> should.be_false

  should.equal(policy.default().lone_caller_arity, 7)
}

/// Recursion is not a caller: a function that calls itself and is called
/// from one place is the same shape as one that does not.
pub fn r8_does_not_count_recursion_as_a_caller_test() {
  module(
    "fn caller(a) { wide(a, a, a, a, a, a, a, a) }

fn wide(a, b, c, d, e, f, g, h) { wide(a, b, c, d, e, f, g, h) }",
  )
  |> fired(finding.LoneCallerArity)
  |> should.be_true
}

// --- R9: a Bool with nothing on it ------------------------------------------

pub fn r9_flags_a_bool_parameter_test() {
  module("fn render(document, compact: Bool) { #(document, compact) }")
  |> fired(finding.NakedBool)
  |> should.be_true
}

pub fn r9_flags_a_bool_record_field_test() {
  module("pub type Entry { Entry(id: String, revoked: Bool) }")
  |> fired(finding.NakedBool)
  |> should.be_true
}

/// `Option(Bool)` is the same hazard with a third state bolted on, and
/// `Dict(_, Bool)` is a set that never said what membership means. The
/// search descends into type parameters for both.
pub fn r9_flags_a_bool_inside_a_container_test() {
  module("pub type State { State(seen: List(Bool)) }")
  |> fired(finding.NakedBool)
  |> should.be_true
}

/// The narrowing that keeps the rule from flagging the language. A
/// predicate *returns* `Bool` because `case`, `&&` and `bool.guard` consume
/// it, and the stdlib's own `is_*` vocabulary is built that way.
pub fn r9_leaves_a_bool_return_alone_test() {
  module("fn is_empty(xs) -> Bool { xs == [] }")
  |> fired(finding.NakedBool)
  |> should.be_false
}

/// The same narrowing from the other side: a predicate handed *to* a
/// function is that legitimate `is_*` arriving as an argument, so the
/// search stops at a `fn(…)` rather than reading its return type.
pub fn r9_leaves_a_predicate_parameter_alone_test() {
  module("fn keep(xs, ready: fn(Int) -> Bool) { list.filter(xs, ready) }")
  |> fired(finding.NakedBool)
  |> should.be_false
}

pub fn r9_says_which_declaration_it_found_test() {
  case
    module("pub type Entry { Entry(revoked: Bool) }")
    |> findings
    |> list.filter(fn(found) { found.rule == finding.NakedBool })
  {
    [only] -> should.be_true(string.contains(only.detail, "`revoked` field"))
    _ -> should.fail()
  }
}

// --- R10: a comment with no room above it -----------------------------------

pub fn r10_flags_a_comment_welded_to_the_line_above_test() {
  "fn f(x) {
  let a = x + 1
  // Why the next line is what it is.
  let b = a + 1
  b
}
"
  |> fired(finding.CommentStanza)
  |> should.be_true
}

pub fn r10_accepts_a_comment_with_a_blank_line_above_it_test() {
  "fn f(x) {
  let a = x + 1

  // Why the next line is what it is.
  let b = a + 1
  b
}
"
  |> fired(finding.CommentStanza)
  |> should.be_false
}

/// The exemption the formatter forces. `gleam format` deletes a blank line
/// at the top of a block, so a comment opening a body cannot have one above
/// it and a finding about it could never be acted on.
pub fn r10_exempts_a_comment_opening_a_body_test() {
  "fn f(x) {
  // What this function is for.
  let a = x + 1
  a
}
"
  |> fired(finding.CommentStanza)
  |> should.be_false
}

/// A `case` arm is a sibling too: the reasoning for an arm is the commonest
/// place this repo writes prose inside a function.
pub fn r10_flags_a_comment_between_case_arms_test() {
  "fn f(x) {
  case x {
    Ok(value) -> value
    // Why the error arm does what it does.
    Error(_) -> 0
  }
}
"
  |> fired(finding.CommentStanza)
  |> should.be_true
}

pub fn r10_exempts_a_comment_above_the_first_arm_test() {
  "fn f(x) {
  case x {
    // What this dispatch is about.
    Ok(value) -> value
    Error(_) -> 0
  }
}
"
  |> fired(finding.CommentStanza)
  |> should.be_false
}

/// The narrowing that keeps a rule about paragraphs out of a data literal.
/// A comment naming one element of a wrapped constructor annotates that
/// element; it opens no stanza, and no blank line is owed above it. This is
/// R2's "a wrapped literal is not depth" in the layout register, and
/// removing it would flood every encoder in the tree.
pub fn r10_ignores_a_comment_inside_a_wrapped_literal_test() {
  "fn f(x) {
  let a = 1
  wide(
    x,
    // Why this argument is what it is.
    x,
  )
}
"
  |> fired(finding.CommentStanza)
  |> should.be_false
}

/// The variants of a custom type are siblings too, and this is where the
/// tree writes most of its `///` prose. `gleam format` preserves a blank
/// line between two variants, so the rule may ask for one.
pub fn r10_flags_a_comment_between_type_variants_test() {
  "pub type Rule {
  /// The first variant.
  NakedBool
  /// The second, welded to the line above.
  CommentStanza
}
"
  |> fired(finding.CommentStanza)
  |> should.be_true
}

pub fn r10_exempts_the_first_variant_test() {
  "pub type Rule {
  /// The first variant, which has only the brace above it.
  NakedBool

  /// The second.
  CommentStanza
}
"
  |> fired(finding.CommentStanza)
  |> should.be_false
}

/// The formatter decides this one, not the rule. `gleam format` **deletes**
/// a blank line between two fields of a constructor while preserving one
/// between two variants, so a finding here could never be acted on — the
/// same reasoning that exempts the first statement of a body. Fields are
/// not siblings R10 knows about, and removing that would make the linter
/// and the formatter demand opposite things.
pub fn r10_ignores_record_fields_test() {
  "pub type Finding {
  Finding(
    /// Which rule fired.
    rule: Rule,
    /// Where it fired, welded to the line above.
    path: String,
  )
}
"
  |> fired(finding.CommentStanza)
  |> should.be_false
}

/// A variant head is an upper-case name at bracket depth zero. A field's
/// own type is inside the variant's parentheses, so `Int` and a qualified
/// `option.Option` are never mistaken for the next variant.
pub fn variant_offsets_skips_field_types_test() {
  let code = "pub type T {\n  A\n  B(x: Int)\n}\n"
  case source.variant_offsets(code, [#(0, string.byte_size(code))]) {
    [offsets] -> should.equal(list.length(offsets), 2)
    _ -> should.fail()
  }
}

/// A whole comment block moves together, so the finding points at its first
/// line — the one a blank line has to go above — rather than at the last.
pub fn r10_reports_the_top_of_a_comment_block_test() {
  case
    "fn f(x) {
  let a = x + 1
  // First line of the reason.
  // Second line of the reason.
  let b = a + 1
  b
}
"
    |> findings
    |> list.filter(fn(found) { found.rule == finding.CommentStanza })
  {
    [only] -> should.equal(only.line, 3)
    _ -> should.fail()
  }
}

// --- R11: a body written as one block ---------------------------------------

/// Nine statements welded together, one over the default threshold.
pub fn r11_flags_a_body_with_no_paragraphs_test() {
  "fn f(x) {
  let a = x
  let b = a
  let c = b
  let d = c
  let e = d
  let g = e
  let h = g
  let i = h
  i
}
"
  |> fired(finding.DenseStanza)
  |> should.be_true
}

/// The same nine statements with one blank line in them: two paragraphs of
/// five and four, neither over the threshold.
pub fn r11_accepts_the_same_body_broken_into_stanzas_test() {
  "fn f(x) {
  let a = x
  let b = a
  let c = b
  let d = c

  let e = d
  let g = e
  let h = g
  let i = h
  i
}
"
  |> fired(finding.DenseStanza)
  |> should.be_false
}

/// A comment breaks a run exactly as a blank line does — it is a heading,
/// which is the whole point of the rule.
pub fn r11_accepts_a_body_broken_by_a_comment_test() {
  "fn f(x) {
  let a = x
  let b = a
  let c = b
  let d = c

  // What the rest of this does.
  let e = d
  let g = e
  let h = g
  let i = h
  i
}
"
  |> fired(finding.DenseStanza)
  |> should.be_false
}

/// The narrowing the first census forced. A `use`-chained decoder is a
/// table of fields written down the page, not a paragraph of steps, and the
/// only way to satisfy a rule that counted them would be to break the table
/// at an arbitrary field.
pub fn r11_does_not_count_a_use_chain_test() {
  module(
    "fn decode(fields) {
  use a <- result.try(field(fields, 1))
  use b <- result.try(field(fields, 2))
  use c <- result.try(field(fields, 3))
  use d <- result.try(field(fields, 4))
  use e <- result.try(field(fields, 5))
  use g <- result.try(field(fields, 6))
  use h <- result.try(field(fields, 7))
  use i <- result.try(field(fields, 8))
  use j <- result.try(field(fields, 9))
  use k <- result.try(field(fields, 10))
  Ok(#(a, b, c, d, e, g, h, i, j, k))
}",
  )
  |> fired(finding.DenseStanza)
  |> should.be_false
}

/// A `use` carries a run across rather than breaking it: nine `let`s
/// threaded through a decoder chain still read as nine.
pub fn r11_carries_a_run_across_a_use_test() {
  module(
    "fn f(x) {
  let a = x
  let b = a
  let c = b
  let d = c
  use e <- result.try(g(d))
  let h = e
  let i = h
  let j = i
  let k = j
  let l = k
  Ok(l)
}",
  )
  |> fired(finding.DenseStanza)
  |> should.be_true
}

/// Density is counted in statements, never in lines, for the reason R2
/// counts depth on the AST: `gleam format` gives a wide call one argument
/// per line, and a twelve-line literal is one statement.
pub fn r11_does_not_count_a_wrapped_literal_test() {
  "fn f() {
  let rows = [
    1,
    2,
    3,
    4,
    5,
    6,
    7,
    8,
    9,
    10,
  ]
  rows
}
"
  |> fired(finding.DenseStanza)
  |> should.be_false
}

// --- how a file's lines are classified --------------------------------------

pub fn classify_names_the_three_kinds_of_line_test() {
  let lines = source.classify("let x = 1\n\n// why\nlet y = 2\n")
  should.equal(source.kind_of(lines, 1), source.Code)
  should.equal(source.kind_of(lines, 2), source.Blank)
  should.equal(source.kind_of(lines, 3), source.CommentLine)
  should.equal(source.kind_of(lines, 4), source.Code)
}

/// A trailing comment annotates the line it sits on rather than opening a
/// stanza, so the line is code. The house rule forbids the spelling anyway;
/// the classification is what keeps a rule about headings from finding one
/// here.
pub fn classify_reads_a_trailing_comment_as_code_test() {
  source.classify("let x = 1  // and why\n")
  |> source.kind_of(1)
  |> should.equal(source.Code)
}

/// Over tokens, not over text: a line of a multi-line string that begins
/// `//` is a string, and telling its author to put a blank line above it
/// would be advice nobody could act on. The same reason the keyword scan
/// lexes rather than searches.
pub fn classify_ignores_a_comment_inside_a_string_test() {
  source.classify("let s = \"one\n// two\"\n")
  |> source.kind_of(2)
  |> should.equal(source.Code)
}

/// Line 1 begins at 0, which `line_starts` does not report, and every later
/// line begins one byte past the newline before it — the same index
/// `lines_of` walks, so a caller that classified a file need not build it
/// twice.
pub fn classify_agrees_with_the_line_index_test() {
  let code = "a\nbb\n\nc\n"
  should.equal(source.classify(code).starts, source.line_starts(code))
}

// --- R6: the portable subset ------------------------------------------------

/// A source at the path a package's file really has, so the rule can tell
/// which package it is looking at.
fn in_package(package: String, code: String) -> List(Finding) {
  lint.check(
    "packages/" <> package <> "/src/" <> package <> "/thing.gleam",
    code,
    policy.default(),
  )
}

/// The same, for a package whose module path is not `<package>/thing`.
fn in_package_at(
  package: String,
  module_path: String,
  code: String,
) -> List(Finding) {
  lint.check(
    "packages/" <> package <> "/src/" <> module_path <> ".gleam",
    code,
    policy.default(),
  )
}

fn r6_in(package: String, code: String) -> Bool {
  in_package(package, code)
  |> list.map(fn(found) { found.rule })
  |> list.contains(finding.PortablePurity)
}

const erlang_external: String = "@external(erlang, \"erlang\", \"phash2\")
pub fn hash(term: String) -> Int
"

pub fn r6_flags_an_erlang_external_test() {
  r6_in("core", erlang_external)
  |> should.be_true
}

/// The rule names no target on purpose. A JavaScript external keeps the
/// portable half and breaks the BEAM build instead, which is the target Loom
/// actually ships on, and it is still foreign code where the purity claim is.
pub fn r6_flags_a_javascript_external_too_test() {
  r6_in(
    "machine",
    "@external(javascript, \"./ffi.mjs\", \"hash\")
pub fn hash(term: String) -> Int
",
  )
  |> should.be_true
}

/// Elsewhere `@external` is confined, not forbidden; R6 has nothing to say.
pub fn r6_leaves_an_external_outside_the_three_alone_test() {
  r6_in("broker", erlang_external)
  |> should.be_false
}

/// The `@external` half is lexed rather than parsed, so a file `glance`
/// cannot read still reports its externals instead of going quiet at R0. A
/// policy rule that a parse failure silences is a hole in the policy.
pub fn r6_survives_an_unparseable_source_test() {
  let fired =
    in_package("core", erlang_external <> "\npub fn ( { ")
    |> list.map(fn(found) { found.rule })
  should.be_true(list.contains(fired, finding.Unparseable))
  should.be_true(list.contains(fired, finding.PortablePurity))
}

/// Tokens, not text: the word inside a string lexes to a single token that
/// never decomposes into `@` followed by `external`.
pub fn r6_leaves_the_word_in_a_string_alone_test() {
  r6_in("core", "pub const banner = \"@external\"\n")
  |> should.be_false
}

pub fn r6_leaves_the_word_in_a_comment_alone_test() {
  r6_in("core", "// no @external here\npub fn f() { 1 }\n")
  |> should.be_false
}

pub fn r6_flags_a_beam_only_import_test() {
  r6_in("prompt", "import gleam/otp/actor\n\npub fn f() { 1 }\n")
  |> should.be_true
}

/// The package's root module counts as much as anything beneath it.
pub fn r6_flags_the_bare_erlang_module_test() {
  r6_in("core", "import gleam/erlang\n\npub fn f() { 1 }\n")
  |> should.be_true
}

/// A prefix is a path segment, not a substring.
pub fn r6_leaves_a_near_miss_import_alone_test() {
  r6_in("core", "import gleam/erlangish/thing\n\npub fn f() { 1 }\n")
  |> should.be_false
}

pub fn r6_leaves_an_ordinary_portable_source_alone_test() {
  r6_in("machine", "import gleam/list\n\npub fn f(xs) { list.first(xs) }\n")
  |> should.be_false
}

const portable_manifest: String = "name = \"core\"
version = \"0.1.0\"

[dependencies]
gleam_stdlib = \">= 1.0.0 and < 2.0.0\"
gleam_otp = \">= 1.0.0 and < 2.0.0\"

[dev_dependencies]
gleeunit = \">= 1.0.0 and < 2.0.0\"
"

pub fn r6_flags_a_beam_only_dependency_test() {
  case lint.check_manifest("packages/core/gleam.toml", portable_manifest) {
    [only] -> {
      should.equal(only.rule, finding.PortablePurity)
      should.equal(only.line, 6)
    }
    _ -> should.fail()
  }
}

/// A dev dependency counts. It is what makes the package's own suite
/// unrunnable on the other target, which is where a lapsed property would
/// first be noticed — and the line scan could not tell the tables apart
/// without a TOML parser bought for three lines.
pub fn r6_flags_a_beam_only_dev_dependency_test() {
  lint.check_manifest(
    "packages/prompt/gleam.toml",
    "[dev_dependencies]\ngleam_erlang = \">= 1.0.0\"\n",
  )
  |> list.length
  |> should.equal(1)
}

/// A line scan, but keyed on the key: a comment mentioning the name is not a
/// declaration, and neither is a path inside a value.
pub fn r6_leaves_a_commented_dependency_alone_test() {
  lint.check_manifest(
    "packages/core/gleam.toml",
    "[dependencies]\n# gleam_otp = \">= 1.0.0\"\n",
  )
  |> should.equal([])
}

pub fn r6_leaves_another_package_manifest_alone_test() {
  lint.check_manifest("packages/broker/gleam.toml", portable_manifest)
  |> should.equal([])
}

/// A path outside the tree's layout is not a guess at which package it might
/// have been: the doctest snippets every other test here uses must stay
/// silent under R6.
pub fn r6_says_nothing_about_a_pathless_source_test() {
  findings(erlang_external)
  |> list.map(fn(found) { found.rule })
  |> list.contains(finding.PortablePurity)
  |> should.be_false
}

/// The message has to teach. A refusal naming the violation and not the
/// reason leaves the reader no way to judge whether their case is the
/// exception worth arguing, and both properties have to appear or the half
/// that was never written down stays unwritten.
pub fn r6_names_what_it_protects_test() {
  let details =
    list.append(
      in_package("core", erlang_external),
      lint.check_manifest("packages/core/gleam.toml", portable_manifest),
    )
    |> list.filter(fn(found) { found.rule == finding.PortablePurity })
    |> list.map(fn(found) { found.detail })
  should.equal(list.length(details), 2)
  list.each(details, fn(detail) {
    list.each(
      [
        "property-testable without spawning processes", "JavaScript target",
        "never to run the harness", "`core`",
      ],
      fn(phrase) { should.be_true(string.contains(detail, phrase)) },
    )
  })
}

// --- the staging decision ---------------------------------------------------
//
// A rule is promoted when its census is zero, decidable and argued, and the
// promotion is only real if a violation stops a build. `finding.gate` is
// the number `scripts/lint.sh` turns into an exit code, so every test here
// asks for the count of *errors* rather than for the rule firing: the rule
// fired before the promotion too, into a report nothing reads.

/// The staging decision, pinned: R0, R2, R4, R6 and R10 gate; R1, R3, R5,
/// R7, R8, R9 and R11 warn. R3 and R8 can never join them, and R1, R5 and
/// R9 have a census to clear first, so a change here is a change of policy
/// and not of implementation.
pub fn the_gating_rules_are_pinned_test() {
  should.equal(finding.error_by_default(), [
    finding.Unparseable,
    finding.NestingDepth,
    finding.PanicInSource,
    finding.PortablePurity,
    finding.CommentStanza,
  ])
}

/// R10 gates, and the promotion is only real if a welded comment stops a
/// build. Its census was driven to zero across all eighteen packages in the
/// change that wrote it, which is the condition under which promotion
/// cannot fail correct code.
pub fn r10_gates_a_welded_comment_test() {
  gate_of(
    "packages/core/src/core/welded.gleam",
    "fn f(x) {
  let a = x + 1
  // A comment with code directly above it.
  let b = a + 1
  b
}
",
  )
  |> should.equal(#(1, 0))
}

/// The other side of the same promotion: the shape the rule asks for is
/// silent, so a build does not fail for writing prose correctly.
pub fn r10_does_not_gate_a_comment_with_room_test() {
  gate_of(
    "packages/core/src/core/roomy.gleam",
    "fn f(x) {
  let a = x + 1

  // A comment with a blank line above it.
  let b = a + 1
  b
}
",
  )
  |> should.equal(#(0, 0))
}

/// A source `glance` cannot read is a linter switched off for that file.
/// At warning level nobody decided to switch it off, which is the whole
/// distinction promotion buys.
pub fn r0_gates_an_unparseable_source_test() {
  gate_of("packages/core/src/core/broken.gleam", "fn f( {")
  |> should.equal(#(1, 0))
}

pub fn r2_gates_a_pyramid_test() {
  gate_of(
    "packages/core/src/core/deep.gleam",
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
    ),
  )
  |> should.equal(#(1, 0))
}

/// The `as` is there so this pins R4's gate and nothing else: R4 is about
/// the construct being present at all, so it fires on a `let assert` that
/// carries a message, and R7 — which is about the message — does not.
pub fn r4_gates_a_let_assert_in_src_test() {
  gate_of(
    "packages/core/src/core/thing.gleam",
    module("fn f(value) { let assert Ok(inner) = value as \"decoded\" inner }"),
  )
  |> should.equal(#(1, 0))
}

/// The exemption, from both sides: the same source gates under `core` and
/// reports nothing at all under `conformance`, whose `src/` is a test
/// harness that has to compile as a library. Keyed by package, so it is one
/// tree and not a prefix that could grow quietly.
pub fn r4_does_not_reach_the_harness_package_test() {
  let harness =
    module("fn f(value) { let assert Ok(inner) = value as \"fixture\" inner }")
  gate_of("packages/conformance/src/conformance/runner.gleam", harness)
  |> should.equal(#(0, 0))

  should.equal(policy.harness_packages(), ["conformance"])
}

/// The table is what the exemption claims to cover, and a neighbouring
/// package must not inherit it.
pub fn the_harness_exemption_is_one_package_test() {
  let harness =
    module("fn f(value) { let assert Ok(inner) = value as \"fixture\" inner }")
  gate_of("packages/machine/src/machine/planner.gleam", harness)
  |> should.equal(#(1, 0))
}

/// A rule that is not promoted must still only warn — the promotion is per
/// rule, and a run of R5 findings has to leave the exit code alone.
pub fn an_unpromoted_rule_still_only_warns_test() {
  gate_of(
    "packages/core/src/core/json.gleam",
    module("fn f(rest) { list.length(rest) > 24 }"),
  )
  |> should.equal(#(0, 1))
}

/// Neither new rule may touch the exit code. R7's census is eighty-four, in
/// the one tree R4 exempts, so it has never once been at zero; R8 reports a
/// shape rather than a defect and can never be promoted at all.
pub fn the_new_rules_only_warn_test() {
  gate_of(
    "packages/conformance/src/conformance/runner.gleam",
    module("fn f(value) { let assert Ok(inner) = value inner }"),
  )
  |> should.equal(#(0, 1))

  gate_of(
    "packages/core/src/core/wide.gleam",
    module(
      "fn caller(a) { wide(a, a, a, a, a, a, a, a) }

fn wide(a, b, c, d, e, f, g, h) { #(a, b, c, d, e, f, g, h) }",
    ),
  )
  |> should.equal(#(0, 1))
}

/// The table is what the rule claims to cover; a test that did not enumerate
/// it would pass just as well against an empty one.
pub fn the_portable_table_names_the_three_test() {
  should.equal(policy.portable_packages(), ["core", "machine", "prompt"])
}

pub fn the_beam_only_table_names_both_test() {
  policy.beam_only_dependencies()
  |> list.map(fn(dependency) { dependency.package })
  |> should.equal(["gleam_erlang", "gleam_otp"])
}

pub fn external_offsets_finds_the_attribute_test() {
  source.external_offsets(erlang_external)
  |> should.equal([0])
}

pub fn external_offsets_ignores_a_string_test() {
  source.external_offsets("const c = \"@external\"\n")
  |> should.equal([])
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
