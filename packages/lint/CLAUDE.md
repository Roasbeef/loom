# lint

## Purpose

Loom's own lint: the house rules `gleam check` and `gleam format` do not
know about. Gleam ships no lint command — the compiler checks types and
the formatter arranges bytes, and neither has an opinion about whether an
eagerly-evaluated fallback is expensive, how deep a `case` may nest, or
whether `panic` belongs in `src/`. Those rules were enforced by review
alone until the de-nesting wave violated one of them and shipped a
quadratic JSON parser whose every unit test passed (`08cdbce`).

A pure analysis over `glance`'s AST, plus four `glexer` token scans for
the questions where a parser miss would be a policy hole rather than a
missed suggestion, plus one line scan of a `gleam.toml` and one line
classification of every source. Five of the twelve rules gate — R0, R2, R4, R6 and R10 — and each of
their censuses must stay zero; the other seven report. See **Staging** below before wiring anything else to the exit
code.

Three of the twelve are not questions about the AST at all. R10 and R11
ask how the source was *laid out* — where the blank lines and comments
are — which `glance` throws away entirely, so `lint/layout` reads the tree
for where each sibling begins and the file's own line table for what was
written between them.

A run is two passes over the sources, not one: R1's structural half needs
every `use`-compatible combinator the run can see before it can judge any
one call site, because a combinator defined in `tools/tool` is called from
sixteen other modules.

`codemode/vet` is the shape this follows — a policy, a set of rules, and
a finding type that carries the reason — for a different purpose. `vet`
decides whether hostile source may run; `lint` advises about source we
wrote ourselves. Nothing here is a security control.

## Key Types

- `lint.check(path, code, policy) -> List(Finding)` — the whole library
  API for a source. Pure, total given `glance` returns, and the only
  entry point anything outside the package should need.
- `lint.check_with(path, code, policy, combinators)` and
  `lint.exported_combinators(path, code) -> List(Eager)` — the same for a
  run that has read more than one file. `exported_combinators` is the
  first pass: the `use`-compatible combinators a source *exports*, keyed
  under its own module path, which is exactly what a qualified call in
  another file resolves to. `check` is `check_with(…, [])` and is what a
  single-file caller — a test, a doctest — should keep using.
- `lint.check_manifest(path, code) -> List(Finding)` — the same for a
  `gleam.toml`. Only R6 has anything to say about one.
- `lint.package_of(path) -> Option(String)` — which package a path
  belongs to, which is the judgement R6 rests on and the census prints
  rows by.
- `lint/finding.{Rule, Finding, id, name, parse, render, rules,
  error_by_default}` — the vocabulary. `Rule` is `Unparseable |
  EagerFallback | NestingDepth | CatchAll | PanicInSource |
  BoundedLength | PortablePurity | AssertWithoutMessage |
  LoneCallerArity | NakedBool | CommentStanza | DenseStanza`, printed as
  `R0`..`R11`.
  `error_by_default` is the staging decision as data — `[Unparseable,
  NestingDepth, PanicInSource, PortablePurity]` — and its doc comment
  carries one census and one argument per rule, which is what a reader
  who has just been failed by one of them needs. `gate(findings, errors)`
  is the `#(errors, warnings)` split `lint/cli` prints as its last line
  and `scripts/lint.sh` turns into an exit code; it is public because a
  promotion is only real if it moves that number, and a test that asserts
  a rule *fires* has not tested the gate.
  `Finding` carries the rule, the path, the **line**, the enclosing
  function and a one-line detail phrased so a reader can act on it.
- `lint/portable.{externals, imports, manifest}` — R6, and the whole
  argument for it: what the portable subset protects, why the rule names
  no target, and why "portable" does not mean the harness runs in a
  browser. Read its module doc before touching the rule; the three
  findings it emits carry that argument into the report.
- `lint/policy.{Policy, default, for_tests, for_tests_like, for_package,
  harness_packages, Eager, eager_combinators, Counted, counted_calls,
  portable_packages, BeamOnly, beam_only_dependencies}` —
  what the rules are tuned with: the R2 nesting threshold (3), whether
  `panic` is allowed (it is, in `test/` — and in the `src/` of a package
  `harness_packages` names, which `for_package` keys off and `lint.check`
  applies from the path), and whether R3 looks at multi-subject `case`s
  (it does not). `assert_message` (R7, off for tests
  alongside `allow_panic` — `for_tests_like` is the one place that decides
  what a test source is exempt from), `lone_caller_arity` (R8's
  threshold, 7) and `dense_stanza_run` (R11's, 8 statements).
  `counted_calls` is R5's table: the two counting calls it
  watches and, per call, the bounded question to suggest instead, because
  the advice for a string is not `list.drop`. `eager_combinators` is R1's
  hand-curated table — module, function, the *label* of the eagerly
  evaluated argument, its positional index, and the lazy counterpart to
  suggest — for the six stdlib combinators plus the rare locally-defined
  one the structural check below cannot reach on its own (`tools/fs`'s
  `require`, which takes no continuation at all).
- `lint/scan.{Raw, module, cheap, exported_eager_rows}` — the AST walk. `Raw` is a finding
  before it has a line: a rule, a **byte offset**, a function name and a
  detail. `cheap` is R1's trivially-cheap predicate, public because it is
  the single judgement the rule rests on and it must be testable alone.
  `module` also takes the file's own module path now (`lint.module_path`
  derives it from the source path), which is what lets a call to a
  locally-defined combinator resolve at all and what R1's structural
  half keys a file's synthesized `Eager` rows under. `module` also takes
  the rows the run collected from every *other* file
  (`exported_eager_rows`, public functions only), and drops any keyed
  under its own path so a combinator called where it is defined is one
  finding rather than two.
- `lint/layout.{Block, Step, Weight, blocks, offsets, findings}` — R10 and
  R11, which are the only rules about how a file was *written* rather than
  what it parses to. `blocks` walks the tree for every list of
  siblings — `Statements` of a body, `Branches` of a `case`, `Variants` of
  a custom type — and reports
  where each one begins, in offsets; `offsets` is what
  `source.line_map` resolves in one merged pass; `findings` then judges in
  line numbers against `source.classify`'s table. `Weight` is the R11
  narrowing as a type: a `use` binding carries a run across without
  lengthening it, because a `use`-chained decoder is a table of fields and
  not a paragraph of steps.
- `lint/source.{line_starts, lines_of, line_of, keyword_offsets,
  Keywords, external_offsets, variant_offsets, LineKind, Lines, classify,
  kind_of, offset_of, line_map}` — byte offsets to lines, the four token
  scans (R4's backstop, R6's `@external` half, the comment scan `classify`
  rests on, and `variant_offsets` for the variant heads `glance` gives no
  span for), and the line classification the layout rules index.
  `classify` reads comments from `glexer`'s tokens rather than from the
  text, so a line of a multi-line string beginning `//` is code.
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
Each source is read once and parsed twice: once by
`lint.exported_combinators` to collect R1's cross-module table, once by
`lint.check_with` to lint it against the whole table. Over sixteen
packages the second parse costs about a second. Each source is also
*classified* once — `source.classify` lexes it for comment tokens and
indexes its lines — which is what R10 and R11 read; a whole run is under
two seconds.
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
  finds this tree's own `or_fault` lineage —
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
  flags and the report does not flood across the whole lineage.
  A last parameter that is `fn(…)` is not enough on its own: it must be a
  **continuation**, meaning it produces the function's own return type,
  the way `or_fault(result, then: fn(a) -> Action) -> Action` does. A
  function that merely takes a closure last is doing something else with
  it — `call.try_call(subject, waiting:, sending: fn(reply) -> message)`
  builds a request with `sending:` and uses `waiting:` unconditionally —
  and while the table was built one file at a time this stayed implicit,
  because such a function had to sit beside its own call sites to be seen
  at all. Reading the whole tree's exports made it load-bearing: the first
  row the cross-module pass added was `try_call`'s, and it was wrong.
  The **body** is read as well as the signature (issue #73, C): the
  combinator must branch on its own subject — the leading `case`'s
  subject, or the leading `use <- guard(…)`'s first argument — and a
  parameter named in that decision is not reported, because the callee has
  already used it by the time it chooses. A signature alone got that wrong
  nine times in thirty-three: `session.read_cell`'s `key:` goes straight
  into the register read, and `claimed_effect`'s `key:` drives the claim
  check itself. Both halves are decidable without types, and both fail
  conservatively — a body shape the walk does not recognize drops its rows
  rather than inventing them. Neither *proves* the argument is wasted, so
  the rule still reports rather than gates.
  The rows are collected across the whole run (issue #73, D). A row is
  keyed under the module that defines the combinator, which is exactly
  what a qualified call resolves to, so nothing in the lookup changed —
  only where the rows come from: `lint/cli` reads every source once,
  collects `lint.exported_combinators` over all of them, and hands that
  table to each file. Before it, `tool.or_outcome`'s nineteen call sites
  were visible only in the three that share its file. The pass added
  exactly one finding across the tree, the `try_call` false positive
  above; with the continuation narrowing in place R1's census is
  unchanged — which is the result, since those sixteen were clean by luck
  and are now clean by coverage.
- **R2 `nesting-depth`** — a function whose `case` expressions nest
  deeper than the threshold. Measured on the AST, never on indentation:
  `client/protocol.gleam` and `machine/codec.gleam` look deep to a column
  counter and are wide literals the formatter broke one argument per
  line. That distinction is the whole reason this tool parses.
- **R3 `catch-all`** — a final arm in a single-subject `case` that matches
  regardless of the subject, where the other arms are flat constructor
  patterns. **Both spellings**: `_ ->` and a bare variable, `other ->`,
  which is a catch-all whatever it is called (gleam-style Part III) and
  which the rule was blind to until issue #73 — seventy-three arms, which
  is R3 from 134 to 206 on its own, including every one of the serious
  ones the baseline review found and all nine of `core`'s. The finding says which spelling it found and, for
  a named one, whether the arm reads the binding: a `_ ->` can often be
  deleted and the variants written in its place, while an `other ->` whose
  arm reads `other` means every enumerated arm has to name the value.
  (In a tree that compiles warning-free the second is the only kind there
  is — an unread binding is a compiler warning, and would be spelled
  `_other` — so the census is 73 named and 0 unread. The rule still asks,
  because a linter reads sources the compiler has not accepted yet.)
  Three narrowings keep it from drowning the report, all decidable without
  types: a `case` where any pattern anywhere matches a literal is skipped
  (no enumeration of `Int` exists, so `_ ->` is mandatory); a `case` whose
  arms match *combinations* — `Ok(Some(Cell(..)))` — is skipped, because
  `_ ->` there stands for the remaining combinations rather than for a
  sibling variant; and a `case` **any** of whose arms carries a guard is
  skipped, because a guarded arm cannot be exhaustive on its own, so the
  final arm is mandatory and a finding about it is always wrong (twelve of
  them in the first census). **R3 still over-reports and cannot stop**:
  see below.
- **R4 `panic-in-src`** — `panic` or `let assert` outside `test/`, and
  outside the `src/` of a package `policy.harness_packages` names.
  Loom policy forbids both; nothing else enforced it. The exemption is
  `conformance`, a test harness that compiles as a library, and it is
  about *presence* only: Part IV rule 3 also demands an `as "message"` on
  every admitted `let assert`, none of those ninety carries one, and no
  rule checks it yet (issue #73, item F).
- **R5 `bounded-length`** — a count compared against anything that is not
  another count. Two counts, from `policy.counted_calls`: `list.length`
  and `string.length`. The bound need not be a literal:
  `list.length(xs) > max_results` walks the whole list to answer a
  question settled at `max_results`, and in this tree that is the
  commoner spelling. This was the other half of the `core/json` bug —
  `excerpt` ended with `list.length(rest) > 24`, which is what made a
  hot-path error construction quadratic rather than merely wasteful. The
  string spelling was invisible until issue #73 and hid ten sites, two of
  them hot: `core/corruption.bound`, on every corruption report the tree
  builds, and `telemetry/field.secret_shaped`, once per token of every
  scrubbed log line including OTP report lines. The finding names the
  bounded question for the thing that was counted — `list.drop(xs, k)`
  against `[]`, `string.drop_start(text, k)` against `""` — because the
  advice for a string is not the advice for a list.
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
- **R7 `assert-without-message`** — a `let assert` in `src/` with no
  `as "…"`. R4's other half rather than a second opinion about R4's
  question: R4 asks whether the construct belongs in this file at all and
  `harness_packages` answers "here, yes", after which Part IV rule 3 asks
  what the crash report will say. A bare `let assert Ok(x) = …` answers
  with a pattern and a line number, which is the whole of what an operator
  gets. So the rule reaches the harness R4 exempts — where every one of
  its findings is — and goes off for `test/`, where the test's own name is
  the message. Its census is 84 and it warns; see **Staging**.
- **R8 `lone-caller-arity`** — a private function with more than
  `lone_caller_arity` parameters (7) and exactly one caller, where a
  caller is another function in the same module whose body mentions the
  name. Not a hazard: a census, like R3. What it measures is the thing a
  nesting metric rewards and never charges for — a block lifted out of its
  caller with the caller's locals re-declared as a signature, which reads
  shallower, threads the same state by hand, and is checked by nothing but
  the argument order. It over-reports by construction (some of these grow
  a second caller next week), under-reports where a name is shadowed, and
  does not see a reference from a constant. It would have named
  `reconcile_orphaned_poll` — thirteen parameters, one caller — on the
  commit that introduced it.
- **R9 `naked-bool`** — a `Bool` in a function parameter or a record
  field. `Bool` is the one type in the language carrying no domain
  meaning: `render(document, True)` names nothing at the call site, and a
  field declared `retry: Bool` makes every reader carry the polarity of
  the name and makes `Retry | GiveUp` a change to every construction site
  rather than to one declaration. gleam-style has said "replace booleans
  with two-variant custom types" since it was written; nothing enforced
  it, and the tree holds 223. **Return position is deliberately outside
  the rule**: `is_empty(xs) -> Bool` is the predicate `case`, `&&` and
  `bool.guard` are built to consume, and flagging those would flag the
  language. The search descends through type parameters and tuples —
  `Option(Bool)` in a field is the same hazard with a third state on it —
  and stops at a `fn(…)`, because a predicate *passed* to a function is
  that same legitimate `is_*` arriving as an argument. That boundary is
  the rule's one narrowing and it is decidable from the annotation alone.
  Type aliases and constants are not searched.
- **R10 `comment-stanza`** — a `//` comment between two siblings, with
  code on the line directly above it. A comment welded to the line above
  reads as that line's footnote; the blank line is what makes it the
  heading of the stanza below, and that is the difference between prose a
  reader can find and prose they cannot (`CLAUDE.md`, "Literate code").
  Siblings are of three kinds: the statements of a body, the **arms of a
  `case`** — the reasoning for an arm is the commonest place this repo
  writes prose inside a function — and the **variants of a custom type**,
  which is where most of the tree's `///` prose lives and which was 720 of
  the original 1137. A variant head is found by token scan rather than by
  the AST, because `glance.Variant` carries no `Span` at all
  (`source.variant_offsets`); the enclosing `CustomType` does, which is
  what keeps that scan from having to recognize a type on its own.

  **Three exemptions, and every one of them is the formatter's decision
  rather than the rule's.** A comment that is the **first line of a
  block** is exempt because `gleam format` deletes a blank line at the top
  of a function body or a `case`. A comment between two **fields of a
  constructor** is exempt because the formatter deletes that blank line
  too — and this is the sharp one, since the formatter *preserves* it
  between two variants of the same type, so the rule reaches variants and
  not fields. A comment **inside a wrapped literal** is invisible, because
  it annotates an element of a data structure rather than opening a
  stanza; that one is R2's "a wrapped literal is not depth" in the layout
  register, and without it the rule would flood every encoder in the tree.
  The first two are checked facts, not guesses: `gleam format --stdin`
  over each shape says so, and the whole-tree sweep passing
  `gleam format --check` is the standing proof.
- **R11 `dense-stanza`** — a function whose longest run of statements with
  nothing between any two of them exceeds `dense_stanza_run` (8). A body
  with no paragraphs has nowhere to put the prose R10 is about, so density
  and silence arrive together; `runtime/supervisor.start` was ten `let`s
  in a wall and reads as three stanzas once broken. Counted in
  **statements, never lines**, for R2's reason: a thirty-line
  `json.Object([…])` the formatter wrapped is one step. And a `use`
  binding is weightless — it carries a run across without lengthening it —
  because a `use`-chained decoder is a table of fields written down the
  page and not a paragraph of steps. That narrowing is what took the
  census from 57 to 17; `core/codec.decode_assistant_message` is nineteen
  `use field <- result.try(…)` lines and is exactly right. One finding per
  function, at the function, the way R2's is: what a reader does about it
  is re-read the body and decide where its paragraphs are.
- **R0 `unparseable`** — not a house rule. A file `glance` could not
  parse is reported, so a parse failure is never silence.

## Staging

**R0, R2, R4, R6 and R10 gate; R1, R3, R5, R7, R8, R9 and R11 warn.**
`make lint` and `make check` fail on any of the five. The warning default is deliberate
and it is the `scripts/doc_check.sh` precedent (D2,
`docs/design-notes/four-decisions.md`): a check earns the error tier by
producing a census that is zero, decidable, and argued — not by being
written. A lint that fails correct code gets disabled.

R6 met that bar on the day it was written rather than later, which was
the whole of its case. Its census is **zero**, it is decidable without
types (an attribute is present or it is not; a module path is under a
prefix or it is not; a key is in a manifest or it is not), and keeping
that zero is the entire point. A rule whose job is to hold a door open
cannot do it from inside a report of two hundred and sixty warnings;
shipping it as a warning would be the failure it exists to prevent, in a
milder costume.

The other three arrived at that same condition by measurement, once the
baseline was triaged (issue #73). Each has its own census and its own
reason to stay at zero, and `finding.error_by_default`'s doc comment
carries both — that is what a reader who has just been failed by one of
them needs in order to tell whether their case is the exception worth
arguing.

- **R0** is zero because `glance` 7 parses every file in the tree, and it
  is decidable in the strictest sense available here: the parser returned
  a module or it did not. What promotion protects is *the rest of this
  list*. Every rule but R6's token half is silent about a file that will
  not parse, so an unparseable file is the linter switched off for that
  file — and at warning level nobody decided to switch it off, which is
  the difference between an exception and an accident.
- **R2** is zero at threshold 3 across all sixteen packages: no function
  nests `case` more than three deep. That is the de-nesting sweep's one
  verifiable result rather than a rule nothing has tested — thirty-seven
  functions sit at exactly 3, so the threshold is a boundary the tree
  leans on and not a ceiling far overhead. Decidable on the AST, so a
  wide literal the formatter wrapped is not depth. Promotion protects a
  property that is only ever lost one `case` at a time, each of which
  reads as reasonable on the day it lands.
- **R4** is zero once `policy.harness_packages` exempts `conformance`,
  whose `src/` is a test harness that has to compile as a library — the
  ninety findings it held were a third of the census and none was signal.
  `panic` and `let assert` are syntax, so the rule is decidable, and the
  token backstop means a construct the parser dropped is reported rather
  than assumed inert. This is the one rule `CLAUDE.md` and gleam-style
  Part IV state in as many words, and until the promotion the distance
  between a stated rule and an enforced one was exactly this flag. The
  missing `as "message"` is R7's, not R4's.

Promotion of the remaining five is per rule and costs one flag,
`scripts/lint.sh --error=R5` — except R3 and R8, which can never be
promoted at all. The census over `packages/*/src` reads (after the
`conformance` exemption, R1's body check and its cross-module pass, R3's
two spellings and its guard narrowing, R5's string spelling and the four
fixes in `core`, `telemetry` and `lint` that followed it; see `git log`
for the censuses this superseded):

| rule | findings | disposition |
| --- | --- | --- |
| R0 unparseable | 0 | **error level**; `glance` 7 parses the whole tree |
| R1 eager-fallback | 20 | real, and all performance-only on cold paths; promotable once they are fixed |
| R2 nesting-depth | 0 at threshold 3 | **error level**; a regression guard, promotable precisely because it finds nothing |
| R3 catch-all | 195 | **stays a warning**; undecidable without types |
| R4 panic-in-src | 0 | **error level**; `conformance/src` is exempt by package and was the whole census |
| R5 bounded-length | 6, in `cap`, `client`, `prompt`, `provider` and `tools` | precise; promotable once those five are fixed |
| R6 portable-purity | 0 | **error level**; zero is the invariant, not the starting point |
| R7 assert-without-message | 84, all in `conformance/src` | Part IV rule 3 at nothing per cent; a rule cannot gate on a census it has never been at zero for |
| R8 lone-caller-arity | 3, and moving | **stays a warning**; a shape, never a verdict |
| R9 naked-bool | 223 | decidable; promotable once the sweep lands and the four irreducible sites are the census rather than 2% of it |
| R10 comment-stanza | 0, swept from 1137 | **error level**; zero in `src/` and `test/` alike, and the sweep is formatter-verified |
| R11 dense-stanza | 17 at threshold 8 | precise, but the threshold is a judgement; treat the number as a reading |

R1's twenty are what the triage left after the body check removed nine
false positives: every one is a real eager argument, none of them
recurses (both reviewers checked the whole `or_fault` lineage), and the
cost is a wasted allocation on a cold path. Promoting a rule the same
season its predicate changed is how a linter starts failing correct code,
so R1 warns until its census is zero and stays there.

R5's six are what is left of ten after the four in packages this change
owned — `core/corruption.bound`, `telemetry/field`'s two, and this tool's
own census padding — were fixed. The remaining files (`cap/git`,
`client/agency`, `provider`'s two adapters, `tools/agent`; `prompt/summary`
was one until the summarizer it served was removed) are the same one-line
shape and the same promotion is waiting on them.

R7 is not R4 with a longer message, and inheriting R4's exemption would
make it report nothing at all: every one of its eighty-four is in the
harness `harness_packages` admits the construct in. Ninety `let assert`s
that name no invariant is a house rule at nothing per cent a full sweep
after it was written, which is worth a number even though — especially
though — fixing it is a separate change from counting it.

R8 is R3's kind of rule and reaches the error tier never. "More than
seven parameters and one caller" is a shape worth looking at, not a
defect: a helper grows a second caller, a wide signature is sometimes
the honest one, and the caller count is over-approximated by a name
match. Its number moves under the reader: it was 49 when issue #73
measured it, 40 of them in `machine/planner.gleam`, and 10 when this
change landed the rule — the planner rewrite is removing the population
it was written to measure, which is the rule working rather than the rule
failing. Do not tune the threshold to make the number look better; 7 is
where the tree's own signatures stop being readable at a glance.

R10 is the newest gating rule, and it met the bar the way R6 did rather
than the way R2 did: by being driven to zero in the change that wrote it.
The census was **1137** across the eighteen packages and it is **zero**
now, in `src/` and in `test/` alike. It is decidable without types — a
line is blank or it is not — and the fix is one blank line, never a change
to what the code does.

What makes that promotion safe rather than brave is that the sweep was
verified against the only authority that could contradict the rule.
`gleam format --check` passes on all eighteen packages after 1137
insertions, so no finding ever asked for a blank line the formatter would
take away — the failure mode that would have made the rule unsatisfiable.
The two exemptions exist for precisely that reason: a comment opening a
block and a comment between two fields of a constructor are both places
`gleam format` deletes a blank line. **Never add a third sibling kind to
`lint/layout` without checking the formatter first**; the check is one
`gleam format --stdin` and it is the difference between a rule and a trap.

The property is also worth a gate. It is lost the way R2's is — one
comment at a time, each reasonable on the day it lands — and it is
invisible in review, because a welded comment reads fine inside a diff
hunk that begins above it.

R9 and R11 warn, which is the ordinary staging, and R9 is decidable enough
that the question of promotion is worth answering rather than deferring.

R9's 223 are every one decidable — an annotation says `Bool` or it does
not — and what stops promotion is that they are not *fixable* in one
change. Two hundred declarations is a sweep in its own right, and some are
not this repository's to make: `terminate: Bool` and `from_hook: Bool` are
fields of frozen Part-1 contracts, so replacing them costs a
`protocol-change/NNN.md` rather than an edit. Four more are irreducible
and always will be — `core/json`'s `Bool(value: Bool)`, `core/msgpack`'s
`BoolValue`, `cap/wire`'s `bool` encoder and `core/codec`'s
`encode_default_false` are code *about* booleans. A rule with four
permanent exceptions can still gate, the way R4 gates with a whole package
exempted, but only once the exceptions are the census rather than 2% of
it.

R11's 17 are precise, but its *threshold* is a judgement rather than a
fact. Eight statements is where this tree's own bodies stop having
paragraphs, measured — but "eight" is not decidable the way "blank or not"
is, and a rule whose census moves when somebody argues about a number
should not be able to fail a build. Do not tune it to make the number look
better, and read it as R8's kind of measurement.

R3 is the doc-check `symbol absent from file` case: deciding whether an
arm *could* have been exhaustive needs the subject's type, and `glance`
resolves no types. The three narrowings above remove the classes that are
decidably not exhaustive-able; what is left mixes genuine variant
dispatch with idiomatic two-arm predicates, and the finding text says
which shape it is rather than pretending the distinction is not there.
An undecidable finding stays a warning forever, and says why.

The staging lives in `finding.error_by_default`, not in
`scripts/lint.sh`, so a promotion needs no flag, no `Makefile` change and
no wrapper edit — and `finding.gate` is the `#(errors, warnings)` split
that decision produces, which is what the tests assert against. A test
that a rule *fires* is not a test that it gates.

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
- **R10's census is zero across the whole tree and must stay zero.** It
  gates, so a welded comment fails `make check`. The fix is always one
  blank line above the comment, never a change to the code, and the two
  places the rule does not reach — the top of a block, and between a
  constructor's fields — are the two places `gleam format` deletes a blank
  line. If a finding ever appears that cannot be fixed that way, the
  formatter has changed and the exemptions are what to re-derive; do not
  demote the rule.
- **The tool passes its own R10 and R11.** `make lint-lint` reports zero
  of each. Its R9 census is 13 and is part of the tree-wide sweep the rule
  schedules, which is a different change from the one that counts them.
- **Every gating rule's census is zero and stays zero.** R0, R2, R4 and
  R6 are wired to the exit code by default. If a finding appears the
  answer is to fix the source, not to demote the rule: an exception needs
  the argument in `finding.error_by_default` — and, for R6, in
  `lint/portable` — answered rather than sidestepped. The one legitimate
  way to widen R4 is to add a package to `policy.harness_packages`, which
  is a decision that has to be written down in that package's own
  `CLAUDE.md` as well: a tree exempted silently is a tree nobody knows is
  exempted.
- **Every `case` over a `glance` type is exhaustive.** No `_ ->` over an
  AST node: when `glance` adds a syntax node, this package must fail to
  compile rather than silently stop seeing it. (The catch-alls this
  package's own R3 reports are over *its own* small types, not over
  `glance`'s.)
- **Every rule has a positive and a negative test, and every gating rule
  has a test that it gates.** A rule that cannot fail is worse than no
  rule — it reads as coverage and provides none; and a promoted rule
  tested only by "does it fire" is tested at the tier it was already at,
  since it fired before the promotion too. The gating tests go through
  `finding.gate`, the same `#(errors, warnings)` split `scripts/lint.sh`
  turns into an exit code, and R4's pair runs the same source under
  `core` (gates) and under `conformance` (silent), which is the exemption
  itself under test.
  R3's guard narrowing is tested from both sides — the same `case` with
  and without a guarded sibling — so removing the check fails a test
  rather than silently restoring twelve false positives, and R8's four
  conditions (private, over the threshold, exactly one caller, recursion
  not counted) each have a negative case.
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
  The layout rules' negative cases are the narrowings: R10's are the
  formatter-forced exemptions (a comment opening a body, a comment above
  the first `case` arm) and the wrapped-literal case, and R11's are the
  `use` chain, the wrapped literal, and the same body broken by a blank
  line and by a comment. Each of those is a class the rule would flood on
  if the narrowing were removed, so removing one fails a test rather than
  quietly costing the census its meaning.
- **A finding is reported once.** R1's table now reaches a file from two
  directions — its own rows and the run's collected ones — and a
  combinator called in the file that defines it is in both. `scan.module`
  drops the imported rows keyed under its own path; a test pins that one
  call site produces one finding, because a duplicated warning is how a
  census stops being read.
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
- `lint/layout` module doc — R10 and R11 in full: why a rule about blank
  lines exists, why layout cannot live in `lint/scan`, why the walk emits
  offsets and asks about lines afterwards, and what the two rules
  deliberately do not look at. `Weight`'s doc comment is where the `use`
  narrowing is argued.
- `lint/source` module doc — why the R4 backstop scans tokens rather
  than text, and why the line classification lives beside the offsets.
- `scripts/lint.sh` — the wrapper, the `# <errors> <warnings>` contract,
  and how to promote a rule.
