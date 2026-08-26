//// Loom's own lint: the house rules `gleam check` and `gleam format` do not
//// know about.
////
//// # Why this exists
////
//// Gleam ships no lint command. `gleam check` is a typechecker and
//// `gleam format` is a layout tool; neither has an opinion about whether an
//// eagerly-evaluated fallback is expensive, how deep a `case` may nest, or
//// whether `panic` belongs in `src/`. Those rules were enforced by review
//// alone until a repo-wide de-nesting wave violated one of them and shipped
//// a quadratic JSON parser whose every unit test passed (`08cdbce`). R1 is
//// the rule that would have caught it, and R5 is the rule that would have
//// caught the other half of the same bug.
////
//// # Staging
////
//// Every rule ships at **warning** level. A lint that fails correct code
//// gets disabled, and the false-positive rate of these five rules on this
//// corpus is a thing to measure before gating on it — the same staging
//// `scripts/doc_check.sh` went through, and for the same reason
//// (docs/design-notes/four-decisions.md, D2). Promotion is per rule, via
//// `lint/cli`'s `--error`, and the census is the argument for or against.
////
//// # Totality
////
//// `lint` is total *given `glance` returns*. Every input maps to a list of
//// findings: a file that will not parse is one `R0` finding, never a crash,
//// and an expression the walker does not model contributes nothing rather
//// than an error. The one residual is inside the parser itself — `glance`
//// carries hard `panic`s ("parser bug, expression not full reduced") on
//// paths no fuzzing has reached. If some input ever reaches one, the panic
//// propagates out of `glance.module` and crashes the linter. This is the
//// same claim `codemode/vet` makes about the same parser, and it is no
//// stronger.
////
//// This module does no I/O; `lint/cli` reads files and prints.

import glance
import gleam/int
import gleam/list
import gleam/string
import glexer/token
import lint/finding.{type Finding, Finding}
import lint/policy.{type Policy}
import lint/scan.{type Raw, Raw}
import lint/source

/// Lint one source. `path` is used only to label findings.
///
/// ## Examples
///
/// ```gleam
/// let code = "import gleam/bool
/// pub fn f(x) {
///   use <- bool.guard(when: x, return: Error(report(x)))
///   Ok(x)
/// }
/// "
/// let assert [found] = lint.check("f.gleam", code, policy.default())
/// assert found.rule == finding.EagerFallback
/// ```
///
pub fn check(path: String, code: String, policy: Policy) -> List(Finding) {
  case glance.module(code) {
    Error(error) -> [parse_finding(path, code, error)]
    Ok(module) -> {
      let found = scan.module(module, policy)
      let all = list.append(found, backstop(found, code, policy))
      let ordered = list.sort(all, fn(a, b) { int.compare(a.offset, b.offset) })
      let lines =
        source.lines_of(
          source.line_starts(code),
          list.map(ordered, fn(raw) { raw.offset }),
        )
      list.map2(ordered, lines, fn(raw, line) {
        Finding(
          rule: raw.rule,
          path:,
          line:,
          function: raw.function,
          detail: raw.detail,
        )
      })
    }
  }
}

/// A fail-closed backstop for R4 alone.
///
/// R4 is a policy rule, so a `panic` the parser dropped would be a hole in
/// the policy rather than a missed suggestion. The token stream is scanned
/// independently of the AST; if it holds more of the two forbidden keywords
/// than the walk surfaced, the surplus is reported rather than assumed inert.
/// No divergence has been exhibited on this corpus — this exists so that if
/// one ever appears it fails closed. Equal counts report nothing, so a mere
/// difference in offset conventions between the two parsers cannot invent a
/// finding.
fn backstop(found: List(Raw), code: String, policy: Policy) -> List(Raw) {
  case policy.allow_panic {
    True -> []
    False -> {
      let keywords = source.keyword_offsets(code)
      let lexed = list.append(keywords.panics, keywords.let_asserts)
      let seen =
        list.filter_map(found, fn(raw) {
          case raw.rule == finding.PanicInSource {
            True -> Ok(raw.offset)
            False -> Error(Nil)
          }
        })
      case list.length(lexed) == list.length(seen) {
        True -> []
        False ->
          lexed
          |> list.filter(fn(offset) { !list.contains(seen, offset) })
          |> list.map(fn(offset) {
            Raw(
              rule: finding.PanicInSource,
              offset:,
              function: "",
              detail: "`panic` or `let assert` appears here in the token "
                <> "stream but not in the parsed module; reported fail-closed "
                <> "rather than assumed inert",
            )
          })
      }
    }
  }
}

fn parse_finding(path: String, code: String, error: glance.Error) -> Finding {
  let starts = source.line_starts(code)
  let #(offset, detail) = case error {
    glance.UnexpectedEndOfInput -> #(
      string.byte_size(code),
      "the source ends unexpectedly; nothing in this file was linted",
    )
    glance.UnexpectedToken(token:, position:) -> #(
      position.byte_offset,
      "the source could not be parsed near `"
        <> token.to_source(token)
        <> "`; nothing in this file was linted",
    )
  }
  Finding(
    rule: finding.Unparseable,
    path:,
    line: source.line_of(starts, offset),
    function: "",
    detail:,
  )
}
