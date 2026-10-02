//// R17 (`flow-order`) and R18 (`unnamed-helper`) are censuses over the same
//// in-module call graph, so they are tested together: each clause of each
//// rule has a case that fires and a case that stays silent, and the graph's
//// own edges (recursion, publicity, constants) are pinned through `lint/calls`.

import glance
import gleam/list
import gleam/string
import gleeunit/should
import lint
import lint/calls
import lint/finding.{type Finding, type Rule}
import lint/policy

// --- helpers ----------------------------------------------------------------

/// Small thresholds, so a test module does not need ten helpers: two helpers
/// are enough to judge, and a helper "is short" at three lines.
fn small() -> policy.Policy {
  policy.Policy(
    ..policy.default(),
    flow_order_min_helpers: 2,
    flow_order_percent: 50,
    unnamed_helper_lines: 3,
  )
}

fn of_rule(code: String, rule: Rule, with: policy.Policy) -> List(Finding) {
  lint.check("t.gleam", code, with)
  |> list.filter(fn(found) { found.rule == rule })
}

fn flow(code: String) -> List(Finding) {
  of_rule(code, finding.FlowOrder, small())
}

fn unnamed(code: String) -> List(Finding) {
  of_rule(code, finding.UnnamedHelper, small())
}

fn functions(code: String) -> glance.Module {
  let assert Ok(module) = glance.module(code) as "test source must parse"
  module
}

fn caller_names(code: String, of name: String) -> List(String) {
  functions(code)
  |> calls.callers_of(name)
  |> list.map(fn(definition) { definition.definition.name })
}

// --- calls: the shared graph ------------------------------------------------

pub fn callers_are_other_functions_that_mention_the_name_test() {
  caller_names("fn a() { c() }\nfn b() { c() }\nfn c() { 1 }\n", "c")
  |> should.equal(["a", "b"])
}

pub fn recursion_is_not_a_caller_test() {
  caller_names("fn f(n) { f(n - 1) }\n", "f")
  |> should.equal([])
}

pub fn a_constant_is_not_a_caller_test() {
  // The documented blind spot: a function reached only from a constant has
  // no caller as far as the census can tell.
  caller_names("const table = [helper]\nfn helper() { 1 }\n", "helper")
  |> should.equal([])
}

pub fn private_helpers_exclude_public_and_unreferenced_test() {
  let module =
    functions(
      "pub fn a() { b() + c() }\nfn b() { 1 }\npub fn c() { 2 }\nfn d() { 3 }\n",
    )
  calls.private_helpers(module)
  |> list.map(fn(helper) { helper.function.name })
  |> should.equal(["b"])
}

// --- R17 flow-order ---------------------------------------------------------

const helpers_first =
  "fn one() { 1 }
fn two() { 2 }
pub fn run() { one() + two() }
"

const entry_first =
  "pub fn run() { one() + two() }
fn one() { 1 }
fn two() { 2 }
"

pub fn flow_order_fires_when_helpers_precede_their_caller_test() {
  let assert [found] = flow(helpers_first)
  found.function |> should.equal("")
  found.line |> should.equal(1)
  string.contains(
    found.detail,
    "2 of 2 private helpers are defined above their first caller (100%)",
  )
  |> should.be_true
  string.contains(found.detail, "`one` above `run`") |> should.be_true
}

pub fn flow_order_is_silent_for_call_flow_order_test() {
  flow(entry_first) |> should.equal([])
}

pub fn flow_order_needs_the_minimum_helper_count_test() {
  // One helper, above its caller: under the floor of two, so no verdict.
  flow("fn one() { 1 }\npub fn run() { one() }\n") |> should.equal([])
}

pub fn flow_order_percent_is_strictly_greater_test() {
  // Exactly half (one of two) is not "more than 50 per cent".
  flow(
    "fn one() { 1 }
pub fn run() { one() + two() }
fn two() { 2 }
",
  )
  |> should.equal([])
}

pub fn flow_order_judges_against_the_earliest_caller_test() {
  // `shared` sits between its two callers: above the second, but after the
  // first, so it is not above its *first* caller.
  flow(
    "pub fn a() { shared() + other() }
fn shared() { 1 }
pub fn b() { shared() }
fn other() { 2 }
",
  )
  |> should.equal([])
}

pub fn flow_order_does_not_count_public_helpers_test() {
  // Two public functions above their caller are entry points, not helpers.
  flow(
    "pub fn one() { 1 }
pub fn two() { 2 }
pub fn run() { one() + two() }
",
  )
  |> should.equal([])
}

pub fn flow_order_does_not_count_recursion_test() {
  // `loop` calls only itself, so it has no caller and is not a helper; with
  // one real helper the module is under the floor.
  flow(
    "fn loop(n) { loop(n) }
fn one() { 1 }
pub fn run() { one() }
",
  )
  |> should.equal([])
}

pub fn flow_order_names_at_most_three_examples_test() {
  let assert [found] =
    flow(
      "fn a() { 1 }
fn b() { 2 }
fn c() { 3 }
fn d() { 4 }
pub fn run() { a() + b() + c() + d() }
",
    )
  string.contains(found.detail, "4 of 4") |> should.be_true
  string.contains(found.detail, "`c` above `run`") |> should.be_true
  string.contains(found.detail, "`d` above `run`") |> should.be_false
}

pub fn flow_order_default_floor_is_ten_helpers_test() {
  of_rule(helpers_first, finding.FlowOrder, policy.default())
  |> should.equal([])
}

// --- R18 unnamed-helper -----------------------------------------------------

const one_caller =
  "pub fn run() { do_thing() }
fn do_thing() { 1 }
"

pub fn unnamed_helper_fires_on_a_short_one_caller_helper_test() {
  let assert [found] = unnamed(one_caller)
  found.function |> should.equal("do_thing")
  found.line |> should.equal(2)
  found.detail
  |> should.equal(
    "`do_thing` has one caller (`run`), spans 1 lines, and the module doc "
    <> "never names it; if it does not name a domain operation, inline it "
    <> "into `run`",
  )
}

pub fn unnamed_helper_is_silent_when_the_module_doc_names_it_test() {
  unnamed("//// Entry is `run`, which calls do_thing.\n\n" <> one_caller)
  |> should.equal([])
}

pub fn unnamed_helper_matches_whole_words_only_test() {
  // `do_thing_else` in the doc is a different word from `do_thing`.
  unnamed("//// Mentions do_thing_else only.\n\n" <> one_caller)
  |> list.length
  |> should.equal(1)
}

pub fn unnamed_helper_reads_comment_tokens_not_text_test() {
  // A `////` line inside a multi-line string is a string, not module doc.
  unnamed(
    "pub fn run() { do_thing() }
fn do_thing() { 1 }
const text = \"
//// do_thing
\"
",
  )
  |> list.length
  |> should.equal(1)
}

pub fn unnamed_helper_ignores_ordinary_and_item_docs_test() {
  unnamed(
    "pub fn run() { do_thing() }
/// do_thing does a thing.
// do_thing again
fn do_thing() { 1 }
",
  )
  |> list.length
  |> should.equal(1)
}

pub fn unnamed_helper_is_silent_with_two_callers_test() {
  unnamed(
    "pub fn run() { do_thing() }
pub fn walk() { do_thing() }
fn do_thing() { 1 }
",
  )
  |> should.equal([])
}

pub fn unnamed_helper_is_silent_with_no_caller_test() {
  unnamed("pub fn run() { 1 }\nfn orphan() { 1 }\n") |> should.equal([])
}

pub fn unnamed_helper_is_silent_for_a_long_helper_test() {
  // Four lines against a limit of three.
  unnamed(
    "pub fn run() { do_thing() }
fn do_thing() {
  let x = 1
  x
}
",
  )
  |> should.equal([])
}

pub fn unnamed_helper_limit_is_inclusive_and_skips_doc_comments_test() {
  // Exactly three lines from `fn` to `}`, with a two-line doc comment above
  // that does not count.
  let assert [found] =
    unnamed(
      "pub fn run() { do_thing() }
/// One.
/// Two.
fn do_thing() {
  1
}
",
    )
  string.contains(found.detail, "spans 3 lines") |> should.be_true
}

pub fn unnamed_helper_is_silent_for_a_public_function_test() {
  unnamed("pub fn run() { do_thing() }\npub fn do_thing() { 1 }\n")
  |> should.equal([])
}

pub fn unnamed_helper_does_not_count_recursion_as_a_caller_test() {
  // `do_thing` calls itself and `run` calls it: one caller, still a finding.
  unnamed(
    "pub fn run() { do_thing(1) }
fn do_thing(n) { do_thing(n) }
",
  )
  |> list.length
  |> should.equal(1)
}

pub fn unnamed_helper_default_limit_is_six_lines_test() {
  let long =
    "pub fn run() { do_thing() }
fn do_thing() {
  let a = 1
  let b = 2
  let c = 3
  let d = 4
  a + b + c + d
}
"
  of_rule(long, finding.UnnamedHelper, policy.default())
  |> should.equal([])
}
