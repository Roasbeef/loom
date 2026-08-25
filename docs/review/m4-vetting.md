# M4 adversarial review — code-mode vetting lint (layer one)

Scope: `packages/codemode/src/codemode/vet.gleam` and
`packages/codemode/src/codemode/vet/policy.gleam`, read against
`docs/architecture/code-mode.md` §"Layer one: vetting" and the three-adversary
list. Reviewer stance: hostile. Assume the kernel jail (layer two) may fail;
any way a hostile program passes vetting while reaching a capability its
imports do not admit is a finding.

Every claim below was traced through the source and, where a concrete program
is cited, **reproduced** against the compiled lint (`gleam build`, then the
`vet/2` beam driven directly from `erl` — no source modified). Repro inputs are
given verbatim so triage can re-run them.

## Bottom line

**No capability bypass was found.** I could not construct a program that passes
vetting yet names an `@external`, imports a non-allowlisted module, or otherwise
reaches an effect its import list does not admit. The three motivating
adversaries (nested-dep FFI, unicode lookalike, prelude shadowing) are all
correctly defeated — see "Attacks that correctly fail".

What I did find is **one confirmed correctness defect (MED)** that rejects
legitimate programs, one **architectural trust gap (MED)** that layer one
structurally cannot close on its own, and three **LOW/robustness** items. None
is a capability escape; the strongest is a usability/over-rejection bug and a
documented-invariant gap. Details and fixes follow.

---

## Findings

### F1 — MED (correctness / over-rejection): the `@external` string backstop fires on the literal appearing in a string or comment

`external_backstop` (vet.gleam:249) rejects whenever the AST surfaced no
`external` attribute **and** `string.contains(source, "@external")` is true. The
substring test runs over the **raw source**, which still contains the bytes of
string literals and comments (glance discards comments before the AST, but the
backstop reads the original string, not the token stream).

Reproduced — all three are legitimate, effect-free programs, all **rejected**:

```gleam
// (a) the literal in a string
import cap/fs
pub fn main() { "@external" }

// (b) the literal in a comment
import cap/fs
// @external here
pub fn main() { 1 }

// (c) the realistic case: a coding agent grepping a codebase for FFI
import cap/fs
import gleam/string
pub fn scan(s) { string.contains(s, "@external") }
```

Case (c) is the one that bites: searching source for `@external` is exactly the
kind of task a coding agent writes, and the lint refuses to run it. The failure
is fail-closed (safe), so this is not a security hole, but it degrades the
product and will train the model that the word is radioactive.

Why the backstop exists at all: glance drops a *dangling* attribute (one that
precedes no definition), so a dangling `@external` would vanish from the AST.
The backstop is meant to catch that. But a dangling `@external` binds no
function and is inert, and the real `gleam` compiler rejects an unattached
attribute outright — so the backstop's true job is already covered by compile
failure, while its collateral damage (F1) is real.

**Fix.** Do not scan raw source. glance is built on `glexer`, which already
tokenizes comments and strings as distinct tokens. Lex the source once
(`glexer.new |> discard_whitespace |> discard_comments |> lex`) and scan the
token list for the pair `At` followed by `Name("external")`. That is
string-literal- and comment-proof (a `String`/comment token never decomposes
into `At,Name`), it is parser-attach-independent (it sees the token whether or
not glance attaches it to a definition), and it *also* closes F2 and F5 below.
This replaces both `external_backstop` and, arguably, makes
`module_has_external_attribute` redundant.

### F2 — LOW (defense-in-depth gap, not exploitable): whitespace/comment-separated `@ external` evades the substring backstop

Because the backstop matches the contiguous bytes `@external`, an attribute
written with a gap between `@` and the name is not caught by it:

```gleam
@ external(erlang, "os", "cmd")          // dangling: vet => Passed
@//c
external(erlang, "os", "cmd")            // dangling: vet => Passed
```

Both **passed** vetting (reproduced). This looks alarming but is **not
exploitable**: glexer discards whitespace and comments, so these lex to
`[At, Name("external"), ...]` — an attribute named `external`. When such an
attribute is attached to a definition it *is* caught by the AST sweep (verified:
`@ external(...)\npub fn run(c) -> String` is **rejected**). The only forms that
slip through are *dangling* ones with no following definition, which are inert
and additionally fail real compilation. So no function is ever bound to foreign
code.

The token-scan fix in F1 closes this gap too (it matches `At,Name("external")`
regardless of spacing), which is worth doing so the backstop's guarantee no
longer silently depends on lexical adjacency.

### F3 — MED (architectural trust gap): vetting parses with `glance`, the harness compiles with `gleam`; soundness assumes the two never disagree

The whole lint reasons about a `glance` AST. The compile service (per
code-mode.md) then compiles the *same source string* with the real `gleam`
compiler. Layer one is sound only if, for **every** input, glance and the gleam
front-end agree on the set of imports and attributes present. glance is a
third-party, deliberately *lenient* tooling parser pinned at a version; it is
not the compiler's front-end. Any input on which glance **under-reports** an
import or an `@external` that gleam then honors is a full layer-one bypass, with
only the jail (assumed failed, per this review's charter) behind it.

I could not exhibit a concrete divergence from inside this environment (I have
no gleamc-parse-to-AST to diff against), so this is a **structural risk, not a
demonstrated exploit**. It is partly mitigated for the specific `@external`
case, because the raw-source backstop (F1) is parser-independent — but there is
**no analogous backstop for imports**. An import that glance fails to surface as
a `Definition(Import)` (e.g. a syntactic form glance mis-parses or tolerates
differently) would never reach `import_rejections`, and nothing else re-checks.

The design doc already names "a bug in the parser" as a reason layer two exists;
this finding sharpens that into an actionable: the risk is materially larger
because vetting uses a *different* parser than the one that compiles.

**Fix / mitigation, in order of strength.** (a) Parse for vetting with the same
front-end that compiles — ideally the gleam compiler's own parser — so there is
one grammar of record. (b) If glance must stay, add a differential/fuzz gate in
CI that parses the corpus (and random programs) with both glance and gleamc and
asserts identical import/attribute sets; pin the glance version and gate
upgrades behind that gate. (c) Add an import backstop analogous to the
`@external` one: independently lex the token stream and confirm every `import`
keyword occurrence produced an allowlisted, glance-surfaced import — so a
glance-dropped import fails closed rather than passing silently.

### F4 — LOW (robustness / totality claim): `vet`'s "never panics" guarantee is stronger than the parser can honor

vet.gleam's module doc states vetting is total: "A program that fails to *parse*
is a `Rejected`, never a crash or a panic." That holds for glance's *typed*
error path (`glance.module` returns `Result`, and `parse_rejection` handles both
`Error` constructors). But glance contains a hard `panic` — `glance.gleam:944`,
`panic as "parser bug, expression not full reduced"` in `handle_operator`. If
any input reaches it, the panic propagates out of `glance.module` and crashes
`vet`, violating the stated guarantee.

I fuzzed the obvious operator-arity triggers (trailing operator, leading
operator, doubled operator, empty pipe, malformed bit-string, 200 000-deep
nesting) and **could not reach the panic** — all settled as `Rejected` or
`Passed` with no crash. So this is an unproven latent path, not a live one.

Impact if reached: a crash never yields a `Vetted`, so it is **not** a capability
bypass — it is availability. vet runs in the trusted harness VM on
model-controlled input; a model that discovered a glance-panicking input could
crash the vetting process at will (DoS of the vetting stage / the owning strand,
depending on supervision).

**Fix.** Either (a) soften the docstring to "never returns a spurious `Passed`;
a parser fault fails closed", or better (b) make the guarantee real: run
`glance.module` behind a fail-closed boundary that converts any unexpected
process exit into `Rejected(Unparseable)` (a small erlang `try/catch` FFI
confined per Loom FFI policy, or an isolated task whose crash maps to a
rejection). Fail-closed on parser faults is the security-correct behavior
regardless.

### F5 — LOW (documented-invariant gap): non-`@external` dangling attributes are silently dropped, contradicting "fail closed on the whole attribute class"

Both vet.gleam's doc and the `Rule.NoForeignInterface` comment claim vetting
fails closed on *every* attribute ("no attribute at all"). That holds only for
attributes glance attaches to a definition (the AST sweep rejects all of them).
A **dangling** attribute of any other name is dropped by glance and caught by
nothing — the backstop only looks for `@external`.

Reproduced — **passed** vetting:

```gleam
pub fn main() { 1 }
@deprecated("x")
```

Not exploitable (inert; also a real-compiler error), but it is a genuine gap
between the stated invariant and behavior, and a maintainer relying on "no
attribute survives vetting" would be wrong. The token-scan approach in F1,
generalized to reject any `At` token whose following `Name`/`UpperName` is an
attribute name, would make the whole-class claim actually true.

---

## Attacks that correctly fail (verified defenses)

These are the things I tried to break and could not; recorded so triage knows
what was actually exercised.

- **Adversary 1 — hidden FFI via nested dependency.** No submitted-source route:
  `@external` on any definition kind (function, custom type, type alias,
  constant, import), public or private, stacked with other attributes, erlang
  or javascript target, and even whitespace-separated `@ external` **on a
  function**, are all rejected by the AST attribute sweep (`attribute_rejections`
  rejects *every* attribute, not just `external`). The nested-package path is
  shut by the allowlist (rule 2/3) plus the compile service's pinned deps, which
  is outside this file's remit. Confirmed the AST sweep covers all five `Module`
  attribute-bearing fields — and those are the *only* fields in which glance's
  `Definition(attributes, _)` ever appears, so no AST-surfaced attribute site is
  missed (there are no per-variant or per-record-field attributes in the
  grammar).

- **Adversary 2 — unicode-lookalike imports.** glexer emits
  `UnexpectedGrapheme` for any non-ASCII byte, so a homoglyph / fullwidth / ZWJ
  / combining-mark module name never becomes a `Name` token and the import never
  reaches the AST — it is `Rejected(Unparseable)` before the allowlist runs.
  Independently, `policy.is_legal_module_name` rejects every such name by the
  ASCII grammar gate, so the defense still holds if a future parser surfaced the
  name. Both paths verified (existing corpus + reasoning over the lexer).

- **Adversary 3 — prelude shadowing / self-naming.** Verified from the AST type
  that `glance.Module` has **no module-name field**: the submitted module's own
  name is genuinely not present in the source glance parses. vet correctly does
  **not** attempt to catch a self-declared `cap/fs`; it relies on the compile
  service pinning the name, which is the right division. A program declaring its
  own `fs`/`Report`/`proc` binding carries no import and no `@external`, so it
  passes — and grants nothing.

- **Import allowlist laundering.** Aliased forbidden import (`import gleam/io as
  safe`), unqualified pull from a forbidden module
  (`import gleam/erlang/atom.{create_from_string}`), forbidden re-export via type
  alias, and one forbidden import mixed among allowed ones are all rejected on
  the module name — which is the unit that carries the capability. Aliasing an
  *allowed* module to a cap-looking name (`import gleam/list as fs`) passes and
  correctly grants nothing (it still resolves to the pure module).

- **Grammar-gate path tricks.** `cap//fs`, `cap/../net`, leading/trailing slash,
  empty name, empty segment, uppercase, dot-separator, dash — all rejected by
  `is_legal_module_name`, and none can even be produced by glance's
  `module_name` (segments are lexed `Name` tokens, so no empty/`..` segment can
  arise; a stray slash leaves residual tokens that make `slurp` fail closed).

- **`Vetted` unforgeability.** `pub opaque type Vetted` with no public
  constructor; `vetted_source`/`vetted_module` are read-only accessors; `vet` is
  the sole producer. There is no API to fabricate or mutate one, and the compile
  service taking `Vetted` (not `String`) makes un-vetted source untypeable at the
  boundary. Confirmed the carried `source` is the exact input, so the compiler
  compiles what was vetted.

- **Totality under stress.** 200 000-deep bracket nesting, and a battery of
  malformed expressions, all returned a `VetResult` with no crash (see F4 for
  the one unproven latent panic path in glance).

---

## Suggested priority

1. **F1** — fix the false-positive; it breaks a plausible, common agent task.
   The token-scan replacement is small and also closes F2 and F5.
2. **F3** — at minimum document the glance/gleamc trust dependency and add a
   differential test; it is the only structural way layer one leaks, and the
   charter's "assume the jail fails" stance makes it the highest-consequence
   item even though unproven.
3. **F4** — make totality fail-closed for real (or soften the claim).
4. **F5**, **F2** — subsumed by the F1 fix.

## Reproduction

```
cd packages/codemode && gleam build
# then drive codemode@vet:vet/2 from erl with the ebin paths under
# build/dev/erlang/*/ebin ; inputs above reproduce verbatim.
```
