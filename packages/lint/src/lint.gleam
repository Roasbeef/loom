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
//// A rule ships at **warning** level until its census argues it onto the
//// error tier: zero findings, decidable without types, and a reason
//// promotion protects something. A lint that fails correct code gets
//// disabled, so the false-positive rate on this corpus is a thing to
//// measure before gating on it — the same staging `scripts/doc_check.sh`
//// went through, and for the same reason
//// (docs/design-notes/four-decisions.md, D2). R0, R2, R4 and R6 have made
//// that argument and gate; R1 and R5 have a census to clear first; R3
//// over-reports by construction and warns forever. The decision is data,
//// in `finding.error_by_default`, which is where each argument is written
//// down; `lint/cli`'s `--error` promotes one for a single run.
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
import gleam/option.{type Option, None, Some}
import gleam/string
import glexer/token
import lint/finding.{type Finding, Finding}
import lint/policy.{type Policy}
import lint/portable
import lint/scan.{type Raw, Raw}
import lint/source

/// Lint one source. `path` labels findings, and also — via `module_path`
/// below — gives R1's structural half something to key a locally-defined
/// combinator's synthesized rows under, so a call resolves to `#(own_path,
/// name)` exactly as an imported one resolves to `#(module, name)`.
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
  let package = package_of(path)
  // R4 asks whether a file is a test by asking where it sits, and one
  // package's `src/` is a test harness that has to compile as a library.
  // `policy.for_package` is where that exemption is named, and applying it
  // here rather than in `lint/cli` is what makes it the library's answer
  // about a path rather than the command line's.
  let policy = policy.for_package(policy, package)
  // R6's `@external` half is lexed rather than parsed, so it survives a file
  // `glance` cannot read: a policy rule that goes quiet on a parse failure is
  // a hole in the policy, not a missed suggestion (`lint/portable`).
  let foreign = portable.externals(package, source.external_offsets(code))
  case glance.module(code) {
    Error(error) -> [
      parse_finding(path, code, error),
      ..locate(path, code, foreign)
    ]
    Ok(module) -> {
      let found = scan.module(module, policy, module_path(path))
      let all =
        found
        |> list.append(backstop(found, code, policy))
        |> list.append(foreign)
        |> list.append(portable.imports(package, module))
      locate(path, code, all)
    }
  }
}

/// Lint a package manifest. R6 is the only rule with anything to say about
/// one, and only for the packages `policy.portable_packages` names; every
/// other manifest yields nothing.
///
/// ## Examples
///
/// ```gleam
/// let toml = "[dependencies]\ngleam_otp = \">= 1.0.0\"\n"
/// let assert [found] = lint.check_manifest("packages/core/gleam.toml", toml)
/// assert found.line == 2
/// ```
///
pub fn check_manifest(path: String, code: String) -> List(Finding) {
  locate(path, code, portable.manifest(package_of(path), code))
}

/// Turn offset-carrying violations into findings, in offset order.
///
/// One merged pass over the file's line index: the cost is the file, not the
/// file once per finding, which is why the walk never learns what a line is.
fn locate(path: String, code: String, raw: List(Raw)) -> List(Finding) {
  let ordered = list.sort(raw, fn(a, b) { int.compare(a.offset, b.offset) })
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

/// The package a path belongs to — `core` for anything under
/// `packages/core/`, manifest or source. `None` when the path names no
/// package: a doctest snippet, a scratch file, anything outside the tree's
/// layout.
pub fn package_of(path: String) -> Option(String) {
  case string.split_once(path, "packages/") {
    Error(Nil) -> None
    Ok(#(_, rest)) -> first_segment(rest)
  }
}

fn first_segment(rest: String) -> Option(String) {
  case string.split(rest, "/") {
    [name, _, ..] -> Some(name)
    _ -> None
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

/// A source path's own module path — `tools/fs` for anything ending
/// `.../src/tools/fs.gleam`, whatever came before `src/` — the same shape
/// `policy.eager_combinators`' `module` field names an imported module
/// with. Falls back to the path as given when it holds no `src/` segment
/// (a bare filename in a doctest, a `test/` source, which R1's structural
/// half has no local combinators to key under anyway).
fn module_path(path: String) -> String {
  let after_src = case string.split_once(path, "/src/") {
    Ok(#(_, rest)) -> rest
    Error(Nil) -> path
  }
  case string.ends_with(after_src, ".gleam") {
    True -> string.drop_end(after_src, 6)
    False -> after_src
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
