//// What the linter reports, and how a report reads.
////
//// A `Finding` is one rule firing at one place. Nothing here decides
//// anything; the vocabulary lives apart from the analysis so the rules, the
//// census, and the tests all name a violation the same way.

import gleam/int
import gleam/list
import gleam/string

/// The house rules this linter knows. Each is a separate promotion decision:
/// a rule that over-reports stays a warning forever and says so, exactly as
/// `scripts/doc_check.sh` keeps its undecidable citation findings at warning
/// level (docs/design-notes/four-decisions.md, D2).
pub type Rule {
  /// R0. The file did not parse. Not a house rule — a report that the
  /// linter could say nothing about this file, so a parse failure is never
  /// silence.
  Unparseable
  /// R1. An eager combinator whose eagerly-evaluated argument is not a
  /// trivially cheap value. Gleam evaluates call arguments unconditionally,
  /// so that argument is built on every call whether the fallback is taken
  /// or not. Two ways a call qualifies: it names one of six hand-curated
  /// stdlib combinators (`bool.guard`, `result.replace_error`,
  /// `result.unwrap`, `option.unwrap`, `result.or`, `option.or`, plus the
  /// occasional locally-defined one the structural check below cannot
  /// reach), or it calls a locally-defined function whose *signature* makes
  /// it `use`-compatible the same way — last parameter `fn(…)`, every other
  /// parameter not — which is what finds the `or_fault` lineage by shape
  /// rather than by name.
  EagerFallback
  /// R2. A function whose `case` expressions nest deeper than the policy
  /// threshold. Measured on the AST, so a wide literal that the formatter
  /// wrapped one argument per line does not count as depth.
  NestingDepth
  /// R3. A `_ ->` arm in a `case` whose other arms match constructors — a
  /// place the compiler could have checked exhaustiveness had the arm not
  /// swallowed everything.
  CatchAll
  /// R4. `panic` or `let assert` outside tests. Loom policy forbids both in
  /// `src/` (CLAUDE.md, gleam-style Part IV).
  PanicInSource
  /// R5. A count — `list.length(xs)`, `string.length(text)` — compared
  /// against a bound: an O(n) answer to a question settled by the first
  /// `k+1` elements or graphemes. The bound need not be a literal.
  BoundedLength
  /// R6. `@external`, a BEAM-only import, or a BEAM-only dependency in one
  /// of the three packages held to the portable subset. What that subset is
  /// and what rests on it is argued in `lint/portable`.
  PortablePurity
  /// R7. A `let assert` in `src/` with no `as "message"`. R4 asks whether
  /// the construct is admitted here at all; this asks whether the one that
  /// is admitted says what invariant it rests on, which is the other half
  /// of the same house rule (gleam-style Part IV, rule 3) and the half
  /// nothing checked.
  AssertWithoutMessage
  /// R8. A private function with more than the policy's parameters and
  /// exactly one caller. Not a hazard — a census. It measures what a
  /// depth metric rewards: a block lifted out of its caller with its
  /// locals re-declared as a signature, which reads shallower and is not
  /// simpler.
  LoneCallerArity
}

/// Every rule, in report order.
pub fn rules() -> List(Rule) {
  [
    Unparseable,
    EagerFallback,
    NestingDepth,
    CatchAll,
    PanicInSource,
    BoundedLength,
    PortablePurity,
    AssertWithoutMessage,
    LoneCallerArity,
  ]
}

/// The rules that ship at error level rather than at warning level.
///
/// A rule earns the error tier by a census that is stable, decidable and
/// argued — not by being written; that is `scripts/doc_check.sh`'s staging
/// and the reason the rest warn (docs/design-notes/four-decisions.md, D2).
/// R6 is the one rule whose census was zero on the day it was written and
/// whose entire purpose is to keep it zero, which is precisely the
/// condition under which promotion cannot fail correct code. Shipping it as
/// a warning would file it among two hundred and sixty others and let the
/// door it guards close unnoticed — which is the failure it exists to
/// prevent, not a milder version of it.
///
/// The other three arrived at that same condition by measurement rather
/// than by construction, so each carries its own census and its own reason
/// for staying at zero.
///
/// **R0** is zero because `glance` 7 parses every file in the tree, and it
/// is decidable in the strictest sense available here: the parser either
/// returned a module or it did not. What promotion protects is the rest of
/// this list. Every rule but R6's token half is *silent* about a file that
/// will not parse, so an unparseable file is a linter turned off for that
/// file — and at warning level nobody decided to turn it off, which is the
/// difference between an exception and an accident.
///
/// **R2** is zero at threshold 3 across all sixteen packages: no function
/// nests `case` more than three deep, which is the de-nesting sweep's one
/// verifiable result rather than a rule nothing has tested — thirty-seven
/// functions sit at exactly 3, so the threshold is a boundary the tree
/// leans on and not a ceiling far overhead. It is decidable without types,
/// on the AST, so a wide literal the formatter wrapped is not depth.
/// Promotion protects a property that is only ever lost one `case` at a
/// time, each of which reads as reasonable on the day it lands.
///
/// **R4** is zero once `policy.harness_packages` exempts `conformance`,
/// whose `src/` is a test harness that has to compile as a library; the
/// ninety findings it held were a third of the whole census and none of
/// them was signal. `panic` and `let assert` are syntax, so the rule is
/// decidable, and `lint`'s token backstop means a construct the parser
/// dropped is reported rather than assumed inert — a policy rule that goes
/// quiet on a parse gap is a hole in the policy. This is also the one rule
/// `CLAUDE.md` and gleam-style Part IV state in as many words, and until
/// now the distance between a stated rule and an enforced one was exactly
/// this promotion.
///
/// **R7 and R8 are not here and one of them never will be.** R7's census is
/// ninety, every one of them in the harness `R4` exempts, which is Part IV
/// rule 3 at nothing per cent — a rule cannot gate on a census it has never
/// once been at zero for, and fixing ninety messages is a separate change
/// from the flag that counts them. R8 over-reports by construction, the way
/// R3 does: "more than seven parameters and one caller" is a shape worth
/// looking at, never a verdict, and a linter that fails a build over a
/// shape is a linter somebody turns off.
pub fn error_by_default() -> List(Rule) {
  [Unparseable, NestingDepth, PanicInSource, PortablePurity]
}

/// How a run's findings divide into the ones that fail a build and the ones
/// that only report: `#(errors, warnings)`, which is the `# <errors>
/// <warnings>` line `lint/cli` prints last and `scripts/lint.sh` reads to
/// choose its exit code.
///
/// Public because a promotion is only real if it moves this number. A test
/// that asserts a rule *fires* has not tested the gate — the rule fired
/// before the promotion too, into a report nothing reads — and the
/// difference between an error and a warning is the whole of what
/// `error_by_default` decides.
///
/// ## Examples
///
/// ```gleam
/// let counts = finding.gate(findings, finding.error_by_default())
/// assert counts == #(0, 12)
/// ```
///
pub fn gate(findings: List(Finding), errors: List(Rule)) -> #(Int, Int) {
  let #(gated, warned) =
    list.partition(findings, fn(found) { list.contains(errors, found.rule) })
  #(list.length(gated), list.length(warned))
}

/// The short identifier a report and a `--error` flag both use.
pub fn id(rule: Rule) -> String {
  case rule {
    Unparseable -> "R0"
    EagerFallback -> "R1"
    NestingDepth -> "R2"
    CatchAll -> "R3"
    PanicInSource -> "R4"
    BoundedLength -> "R5"
    PortablePurity -> "R6"
    AssertWithoutMessage -> "R7"
    LoneCallerArity -> "R8"
  }
}

/// The rule's name as the census prints it.
pub fn name(rule: Rule) -> String {
  case rule {
    Unparseable -> "unparseable"
    EagerFallback -> "eager-fallback"
    NestingDepth -> "nesting-depth"
    CatchAll -> "catch-all"
    PanicInSource -> "panic-in-src"
    BoundedLength -> "bounded-length"
    PortablePurity -> "portable-purity"
    AssertWithoutMessage -> "assert-without-message"
    LoneCallerArity -> "lone-caller-arity"
  }
}

/// Parse a rule identifier (`R1`, `r1`, or the rule's name). Total.
pub fn parse(text: String) -> Result(Rule, Nil) {
  let wanted = string.lowercase(string.trim(text))
  case find_rule(rules(), wanted) {
    [rule, ..] -> Ok(rule)
    [] -> Error(Nil)
  }
}

fn find_rule(candidates: List(Rule), wanted: String) -> List(Rule) {
  case candidates {
    [] -> []
    [rule, ..rest] ->
      case string.lowercase(id(rule)) == wanted || name(rule) == wanted {
        True -> [rule]
        False -> find_rule(rest, wanted)
      }
  }
}

/// One rule firing at one place.
pub type Finding {
  Finding(
    rule: Rule,
    path: String,
    line: Int,
    /// The enclosing function's name, or `""` at module level.
    function: String,
    /// What fired and what to do about it, in one line.
    detail: String,
  )
}

/// One finding as a line of report: `path:line: R1 eager-fallback  detail`.
pub fn render(finding: Finding) -> String {
  finding.path
  <> ":"
  <> int.to_string(finding.line)
  <> ": "
  <> id(finding.rule)
  <> " "
  <> name(finding.rule)
  <> "  "
  <> in_function(finding.function)
  <> finding.detail
}

fn in_function(function: String) -> String {
  case function {
    "" -> ""
    named -> "`" <> named <> "`: "
  }
}
