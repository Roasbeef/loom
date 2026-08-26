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
  /// R1. An eager combinator (`bool.guard`, `result.replace_error`,
  /// `result.unwrap`, `option.unwrap`, `result.or`, `option.or`) whose
  /// eagerly-evaluated argument is not a trivially cheap value. Gleam
  /// evaluates call arguments unconditionally, so that argument is built on
  /// every call whether the fallback is taken or not.
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
  ]
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
