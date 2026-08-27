# lint

## Purpose

Loom's own lint: the house rules `gleam check` and `gleam format` do not
know about. Gleam ships no lint command — the compiler checks types and
the formatter arranges bytes, and neither has an opinion about whether an
eagerly-evaluated fallback is expensive, how deep a `case` may nest, or
whether `panic` belongs in `src/`. Those rules were enforced by review
alone until the de-nesting wave violated one of them and shipped a
quadratic JSON parser whose every unit test passed (`08cdbce`).

A pure analysis over `glance`'s AST, plus two `glexer` token scans for
the rules where a parser miss would be a policy hole rather than a missed
suggestion, plus one line scan of a `gleam.toml`. It is a *reporting*
tool with one exception: R6 gates, and its census must stay zero. See
**Staging** below before wiring anything else to the exit code.

`codemode/vet` is the shape this follows — a policy, a set of rules, and
a finding type that carries the reason — for a different purpose. `vet`
decides whether hostile source may run; `lint` advises about source we
wrote ourselves. Nothing here is a security control.

## Key Types

- `lint.check(path, code, policy) -> List(Finding)` — the whole library
  API for a source. Pure, total given `glance` returns, and the only
  entry point anything outside the package should need.
- `lint.check_manifest(path, code) -> List(Finding)` — the same for a
  `gleam.toml`. Only R6 has anything to say about one.
- `lint.package_of(path) -> Option(String)` — which package a path
  belongs to, which is the judgement R6 rests on and the census prints
  rows by.
- `lint/finding.{Rule, Finding, id, name, parse, render, rules,
  error_by_default}` — the vocabulary. `Rule` is `Unparseable |
  EagerFallback | NestingDepth | CatchAll | PanicInSource |
  BoundedLength | PortablePurity`, printed as `R0`..`R6`.
  `error_by_default` is the staging decision as data: `[PortablePurity]`,
  and the doc comment argues why that one and not the others.
  `Finding` carries the rule, the path, the **line**, the enclosing
  function and a one-line detail phrased so a reader can act on it.
- `lint/portable.{externals, imports, manifest}` — R6, and the whole
  argument for it: what the portable subset protects, why the rule names
  no target, and why "portable" does not mean the harness runs in a
  browser. Read its module doc before touching the rule; the three
  findings it emits carry that argument into the report.
- `lint/policy.{Policy, default, for_tests, Eager, eager_combinators,
  portable_packages, BeamOnly, beam_only_dependencies}` —
  what the rules are tuned with: the R2 nesting threshold (3), whether
  `panic` is allowed (it is, in `test/`), and whether R3 looks at
  multi-subject `case`s (it does not). `eager_combinators` is R1's
  hand-curated table — module, function, the *label* of the eagerly
  evaluated argument, its positional index, and the lazy counterpart to
  suggest — for the six stdlib combinators plus the rare locally-defined
  one the structural check below cannot reach on its own (`tools/fs`'s
  `require`, which takes no continuation at all).
- `lint/scan.{Raw, module, cheap}` — the AST walk. `Raw` is a finding
  before it has a line: a rule, a **byte offset**, a function name and a
  detail. `cheap` is R1's trivially-cheap predicate, public because it is
  the single judgement the rule rests on and it must be testable alone.
  `module` also takes the file's own module path now (`lint.module_path`
  derives it from the source path), which is what lets a call to a
  locally-defined combinator resolve at all and what R1's structural
  half — `scan.local_eager_rows` — keys a file's own synthesized `Eager`
  rows under, so they can only ever match calls inside the file that
  defines them.
- `lint/source.{line_starts, lines_of, line_of, keyword_offsets,
  Keywords, external_offsets}` — byte offsets to lines, and the two
  token scans: R4's backstop and R6's `@external` half.
- `lint/cli.main` — argument parsing, file discovery, the report and the
  census. The only module here that does I/O.

## Relationships

- **Depends on**: `glance` (>= 7, for an AST that carries a `Span` on
  every expression and pattern), `glexer` (the R4 backstop and R6's
  `@external` scan), `simplifile` (file and manifest discovery), `argv`. **No Loom package**, in either direction —
  `lint` is a developer tool, not part of any plane, and nothing in the
  harness may call it.
- **Depended on by**: nothing. `scripts/lint.sh` runs it, `make lint`
  and `scripts/check.sh` call that.
- **FFI**: none.
- **Note on `glance` versions**: `codemode` pins `glance` 1.x because
  `vet`'s rules and its `Vetted` token are written against that AST.
  `lint` needs 7.x: 1.x cannot parse label shorthand in patterns
  (`Int(value:)`), which appears throughout this tree, and 7.x is what
  puts a `Span` on every node. The two packages build independently, so
  the pins do not interact — but do not "unify" them without reading
  `codemode/vet` first.

## Traffic

No actors, no registers, no wire messages. `lint/cli` reads files with
`simplifile` and writes to stdout; everything else is a pure function.
It reads `gleam.toml` as well as `.gleam`: the manifests are *derived*
from the sources a run touched (the package root above each `/src/` or
`/test/`) rather than named, because `make lint` points at
`packages/*/src` and R6's other half would otherwise never be reached.
The last line of a run is `# <errors> <warnings>`, which is the contract
`scripts/lint.sh` reads to decide its exit code — the same shape
`scripts/doc_check.sh` uses.

## The rules

- **R1 `eager-fallback`** — an eager combinator whose eagerly evaluated
  argument is not *trivially cheap*. Gleam evaluates call arguments
  unconditionally, so an eager guard's `return:` is constructed on every
  call, taken or not. This is a correctness hazard when the argument
  recurses and a performance hazard when it is merely expensive;
  `core/json` was the second kind, and the cost was paid entirely on the
  happy path, which is why every test stayed green. Trivially cheap means
  a literal, a bare variable (also how a nullary constructor is spelled),
  a record-field read, a tuple index, a closure, or a constructor applied
  only to those. A call, a `<>`, a pipeline, a block, a `case` — all flag.
  Arithmetic and comparison over cheap operands stay cheap; `<>` does
  not, because it allocates in proportion to its operands.

  A call qualifies two ways. The **hand-curated** half is
  `bool.guard`, `result.replace_error`, `result.unwrap`, `option.unwrap`,
  `result.or`, `option.or` plus the odd locally-defined row
  (`policy.eager_combinators`) — known by name. The **structural** half
  (`scan.local_eager_rows`) finds this tree's own `or_fault` lineage —
  `or_fault`, `or_fault_unless`, `or_fail`, `or_outcome`, `or_reply`,
  `or_continue`, `or_halt`, `or_key_halt`, and whatever the next file
  adds — by *signature* rather than by name: a locally-defined function
  whose last parameter is `fn(…)` and whose other parameters are not is
  `use`-compatible the same way `bool.guard` is, per the style guide's
  own house pattern ("the fallible subject first, the continuation
  last"). The subject at position 0 is exempt — it is meant to run
  unconditionally, not a discarded fallback — so only a parameter
  *between* the subject and the continuation is checked, which is why a
  two-parameter combinator (`or_fault`, `or_halt`, `or_key_halt`) never
  flags and the report does not flood across the whole lineage. It still
  over-reports the way R3 does, and for the same reason: telling a
  genuinely-wasted-on-success fallback apart from a parameter the
  combinator's own body uses unconditionally (`claimed_effect`'s `key:`
  drives the claim check itself) needs dataflow `glance` does not give
  this walk, so a structural match is reported regardless of which one it
  is — a false positive here is a parameter that merely sits between the
  subject and the continuation, not a fabricated call site.
- **R2 `nesting-depth`** — a function whose `case` expressions nest
  deeper than the threshold. Measured on the AST, never on indentation:
  `client/protocol.gleam` and `machine/codec.gleam` look deep to a column
  counter and are wide literals the formatter broke one argument per
  line. That distinction is the whole reason this tool parses.
- **R3 `catch-all`** — a `_ ->` arm in a single-subject `case` whose
  other arms are flat constructor patterns. Two narrowings keep it from
  drowning the report, both decidable without types: a `case` where any
  pattern anywhere matches a literal is skipped (no enumeration of `Int`
  exists, so `_ ->` is mandatory), and a `case` whose arms match
  *combinations* — `Ok(Some(Cell(..)))` — is skipped, because `_ ->`
  there stands for the remaining combinations rather than for a sibling
  variant. **R3 still over-reports and cannot stop**: see below.
- **R4 `panic-in-src`** — `panic` or `let assert` outside `test/`.
  Loom policy forbids both; nothing else enforced it.
- **R5 `bounded-length`** — `list.length(xs)` compared against anything
  that is not another count. The bound need not be a literal:
  `list.length(xs) > max_results` walks the whole list to answer a
  question settled at `max_results`, and in this tree that is the
  commoner spelling. This was the other half of the `core/json` bug —
  `excerpt` ended with `list.length(rest) > 24`, which is what made a
  hot-path error construction quadratic rather than merely wasteful.
- **R6 `portable-purity`** — an `@external`, a BEAM-only import, or a
  BEAM-only dependency in `core`, `machine` or `prompt`. Those three hold
  none of the three today, by rule rather than by coincidence, and two
  properties rest on that: the operation state space stays
  property-testable without spawning processes (the reason `machine`'s
  doc always gave), and the three stay compilable to the JavaScript
  target (the reason nothing gave until issue #92). The rule names **no
  target**: an Erlang external ends the portability, a JavaScript one
  breaks the BEAM build Loom ships on, and a matched pair still puts
  trusted-unchecked foreign code where the purity claim is. The
  `@external` half reads tokens rather than the AST so that an external
  in a file `glance` cannot parse is still reported rather than reduced
  to an R0 warning; the import half reads the AST, where a module path is
  one string; the `gleam.toml` half is a line scan, because the question
  is only whether a name appears as a key and a TOML parser would be a
  dependency bought for three lines. `lint/portable`'s module doc carries
  the argument, and every finding carries enough of it that a reader can
  tell whether their case is the exception worth arguing.
- **R0 `unparseable`** — not a house rule. A file `glance` could not
  parse is reported, so a parse failure is never silence.

## Staging

**Every rule ships at warning level except R6, and `make check` gates on
R6 alone.** The warning default is deliberate, and it is the
`scripts/doc_check.sh` precedent (D2,
`docs/design-notes/four-decisions.md`): a check earns the error tier by
producing a census that is stable, decidable, and argued — not by being
written. A lint that fails correct code gets disabled.

R6 meets that bar on the day it was written rather than later, which is
the whole of its case. Its census is **zero**, it is decidable without
types (an attribute is present or it is not; a module path is under a
prefix or it is not; a key is in a manifest or it is not), and keeping
that zero is the entire point — R2 is the precedent, promotable as a
regression guard precisely because it finds nothing. A rule whose job is
to hold a door open cannot do it from inside a report of two hundred and
sixty warnings; shipping it as a warning would be the failure it exists
to prevent, in a milder costume. The staging lives in
`finding.error_by_default`, not in `scripts/lint.sh`, so the wrapper
needs no flag and `make lint` gates without a `Makefile` change.

Promotion of the other five is per rule and costs one flag:
`scripts/lint.sh --error=R4`.
The census over `packages/*/src` reads (after R1's structural half and
R5's three real fixes; see `git log` for the census this superseded):

| rule | findings | disposition |
| --- | --- | --- |
| R0 unparseable | 0 | `glance` 7 parses the whole tree |
| R1 eager-fallback | 33 | precise; promote after they are triaged |
| R2 nesting-depth | 0 at threshold 3 | promotable today as a regression guard (37 functions sit at exactly 3) |
| R3 catch-all | 135 | **stays a warning**; undecidable without types |
| R4 panic-in-src | 90, all in `conformance/src` | promotable once `conformance` is exempted; 0 elsewhere |
| R5 bounded-length | 6 | precise; the rest bounded and harmless (a fixed-width hex string, a list already capped by a fetch limit) |
| R6 portable-purity | 0 | **error level**; zero is the invariant, not the starting point |

R3 is the doc-check `symbol absent from file` case: deciding whether an
arm *could* have been exhaustive needs the subject's type, and `glance`
resolves no types. The two narrowings above remove the classes that are
decidably not exhaustive-able; what is left mixes genuine variant
dispatch with idiomatic two-arm predicates, and the finding text says
which shape it is rather than pretending the distinction is not there.
An undecidable finding stays a warning forever, and says why.

## Invariants

- **Total, given `glance` returns.** A file that will not parse is one
  `R0` finding, never a crash; an expression the walker does not model
  contributes nothing rather than an error. The one residual is inside
  the parser: `glance` carries hard `panic`s ("parser bug, expression not
  full reduced") on paths no fuzzing has reached, and one would propagate
  out of `glance.module`. This is exactly the claim `codemode/vet` makes
  about the same parser and it is **no stronger** — do not upgrade the
  wording without a `rescue` at the boundary to back it.
- **No `panic`, no `let assert` in `src/`.** The tool passes its own R4;
  `make lint` says so.
- **R6's census is zero and stays zero.** It is the one rule wired to the
  exit code by default. If a finding ever appears, the answer is to
  remove the external or the dependency, not to demote the rule; an
  exception needs the argument in `lint/portable` answered, not
  sidestepped.
- **Every `case` over a `glance` type is exhaustive.** No `_ ->` over an
  AST node: when `glance` adds a syntax node, this package must fail to
  compile rather than silently stop seeing it. (The catch-alls this
  package's own R3 reports are over *its own* small types, not over
  `glance`'s.)
- **Every rule has a positive and a negative test.** A rule that cannot
  fail is worse than no rule — it reads as coverage and provides none.
  `test/lint_test.gleam` also carries the `core/json` regression shape
  verbatim, so R1 is pinned to the bug that motivated it — and, for R1's
  structural half, the `or_fault_unless`/`require` shapes issue #56 found
  invisible, one pinned by signature and one by the hand-curated table
  row, each with a negative case proving the row is lazy and path-scoped
  rather than merely absent. R6's negative cases are the ones that pin
  the *shape* of the check: a `@external` inside a string and inside a
  comment (proving the scan is over tokens, not text), a
  `gleam/erlangish/thing` import (proving a prefix is a path segment),
  and a commented-out dependency line (proving the manifest scan keys on
  the key rather than on the substring).
- **The walk never reports a line.** `lint/scan` emits byte offsets;
  `lint` converts them in one merged pass over the file's line index.
  Keeping the conversion out of the walk is what keeps the walk pure of
  string handling and linear rather than quadratic.
- **`lint/cli` is the only module that does I/O.** `lint`, `lint/scan`,
  `lint/policy`, `lint/finding` and `lint/source` are pure functions of
  their arguments.
- **Findings are advice, never authority.** Nothing in the harness may
  import this package, and no rule here may be cited as a security
  control; `codemode/vet` is the security control.

## Deep Docs

- `lint` module doc — why the tool exists, the staging decision, and the
  totality claim in full.
- `lint/scan` module doc — the walk, and `cheap`'s doc comment, which is
  where R1's predicate is argued.
- `lint/portable` module doc — R6 in full: the two properties, what
  portable does not mean, why the rule names no target, and why each half
  looks where it does.
- `lint/source` module doc — why the R4 backstop scans tokens rather
  than text.
- `scripts/lint.sh` — the wrapper, the `# <errors> <warnings>` contract,
  and how to promote a rule.
