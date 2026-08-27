//// What the linter reports, and how a report reads.
////
//// A `Finding` is one rule firing at one place. Nothing here decides
//// anything; the vocabulary lives apart from the analysis so the rules, the
//// census, and the tests all name a violation the same way.

import gleam/int
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
  /// R5. `list.length(xs)` compared against a literal — an O(n) answer to a
  /// question that only needs the first `k+1` elements.
  BoundedLength
  /// R6. `@external`, a BEAM-only import, or a BEAM-only dependency in one
  /// of the three packages held to the portable subset. What that subset is
  /// and what rests on it is argued in `lint/portable`.
  PortablePurity
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
  ]
}

/// The rules that ship at error level rather than at warning level.
///
/// A rule earns the error tier by a census that is stable, decidable and
/// argued — not by being written; that is `scripts/doc_check.sh`'s staging
/// and the reason the other five warn (docs/design-notes/four-decisions.md,
/// D2). R6 is the one rule whose census was zero on the day it was written
/// and whose entire purpose is to keep it zero, which is precisely the
/// condition under which promotion cannot fail correct code. Shipping it as
/// a warning would file it among two hundred and sixty others and let the
/// door it guards close unnoticed — which is the failure it exists to
/// prevent, not a milder version of it.
pub fn error_by_default() -> List(Rule) {
  [PortablePurity]
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
