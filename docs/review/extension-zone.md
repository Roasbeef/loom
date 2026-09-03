# Extension zone review — the TCB freeze (#33)

Scope: the claim that nothing an extension can reach crosses into the
trusted computing base, read against `docs/loom-design.md` §7's hard rule
("the trusted computing base is not runtime-extensible … self-improvement
grows the tool and hook surface only") and
`docs/design-notes/extension-architecture.md` Decision 1. Reviewer
stance: hostile, and the charter is the one code mode's own review used —
assume the layer under examination is the last one standing.

The surfaces read: `packages/ext/src/**`, `packages/cap/src/**`,
`packages/codemode/src/codemode/vet/{policy,package,lint}.gleam`,
`packages/codemode/src/codemode/{seed,compile}.gleam`,
`packages/client/src/client/extension/**`, and the freeze test itself,
`packages/client/test/client/extension/freeze_test.gleam`.

Reviewers: **author's pass** (this document as filed) and an
**independent pass (Opus 5, 2026-09-03)**, whose findings are in the
section at the end. Fable's credits were exhausted, so the independent
tier is Opus 5 rather than Fable 5.1; what the pass buys is the fresh
context and not the tier, and it earned it — it rebuilt the seed as a
replica build root and compiled against it rather than reading the
`gleam.toml` files, which is how the first two findings were measured
instead of argued. The author's pass is not the review #33 asks for on
its own; it is the material the independent pass attacks.

## The claim under review

An installed extension is somebody else's source, compiled by us and run
by us. The claim is that no path exists — at compile time or at runtime —
from that source to `StorageWriter`, to broker internals, to the raw
`cap_call` channel, or to any module of a TCB package.

The claim is currently **satisfied by construction** rather than by
enforcement, and that is the whole reason this review exists. Every
extension body in the tree runs in a jailed satellite; nothing is
hot-loaded into the harness VM; there is no loader to get wrong. #33 was
written against a world in which #32 had built one. It has not, and it is
deferred: a survey of roughly 490 pi extensions on 2026-09-03 found none
that needs in-VM residency, and what real extensions want from the
vocabulary is not a tier. So the freeze is proved as a **standing, gated
property of the tree** instead — a property that fails when a future
refactor opens a path, rather than a property that merely holds today.

## The mechanisms

#33's wording is "compile-time visibility + runtime name checks", and it
says both, not either. Both are here.

### Mechanism one — compile-time visibility

An extension's source compiles against a build root the harness lays out,
not against the repository. Three statements, each checked:

- **The package graph.** `packages/ext` names exactly one loom package in
  `[dependencies]`, `cap`; `cap` names exactly one, `core`; `core` names
  none. `core` is the pure shared vocabulary — msgpack, corruption
  reports, the domain types — and is deliberately not part of the base
  being frozen, because a package that can be linked into the jail is not
  part of the harness.
- **The resolved lock file.** `packages/ext/manifest.toml` resolves no
  local package outside `{cap, core, ext}`, which closes the case of a
  dependency arriving transitively rather than by declaration.
- **The build root.** `codemode/seed.default_vendored` is what is
  actually vendored into the offline seed the jailed toolchain builds in:
  `cap`, `core`, `ext`, and no other *loom* package. Whatever a
  `gleam.toml` claims, that is what a loom import can resolve to — and
  only a loom import. `cap` names `gleam_erlang` and `gleam_otp` as
  runtime dependencies, so both resolve into every build root that
  vendors `cap`, and a body importing `gleam/erlang/process` or
  `gleam/otp/actor` compiles (measured on a replica build root, which
  emitted only Gleam's transitive-dependency warning). On the
  standard-library half of the surface the closed vetting allowlist is
  therefore the load-bearing gate, not a second belt behind the graph.

Beneath the graph, the source: no module under `packages/ext/src` or
`packages/cap/src` imports any module of a TCB package. That is checked
by walking both trees at test time, so an import added tomorrow fails the
test without anybody remembering to extend a list.

And for third-party source, `vet/package.allowed_dependencies` — the
closed set an extension's own `gleam.toml` may name — holds no TCB
package either.

### Mechanism two — runtime name checks

Every extension body runs jailed, so "runtime" here means the seam a body
is *admitted* under, and the check is that the seam is a closed allowlist
disjoint from the base. Both seams are held to it, and the disjointness
is taken against the module names the TCB packages actually ship, walked
from the tree rather than written out, so a new module under `storage/`
or `broker/` is covered the day it is committed.

The base for this purpose is every package that ships Gleam into the
harness VM — `events`, `telemetry`, `mcp` and `tui` included, not only
the subsystems §7 names. The walk's whole value is covering the module
nobody has written yet, and a module added under `mcp/` would otherwise
land outside it. `sandbox` is the fourteenth entry and ships no Gleam,
which the test itself pins.

The second seam is new in this change. **`ResidentSeam`** is the seam a
harness-resident hook body *would* be judged under if a loader were ever
built: `ext`, `ext/hook`, and the same standard-library subset the jailed
seam admits, with every module that reaches the broker removed. It is
wired to nothing,
because there is nothing to wire it to. It exists so that the allowlist
is frozen *before* a loader can invent one — the moment at which somebody
is most tempted to be permissive — and so that the freeze test has a
concrete set to pin.

Why no capability at all on that seam: a jailed body reaches the broker
through `cap/*` because the jail is what makes that safe. The token is
scoped to one execution, the broker judges every call, and a kernel
stands behind both. A resident body has none of that, so a capability
stub there is not a request to somebody else — it is a direct call inside
the process that holds the durability plane. A resident hook is therefore
a pure transform over the payload it is handed, and everything else stays
in the jail, where it already works.

`ext/memory` is the case that made "every `cap/*` module removed" too
narrow a rule to state it that way. It is a capability — a broker client
over `ext.remember` and `ext.recall` — carrying the durable cells an
extension owns, and it is spelled like `ext/hook`, which carries no
authority at all. A filter matching on the `cap/` prefix would therefore
have admitted it to the resident seam, where its cells are rows in the
very store the harness VM holds and there is no broker between the body
and the write. So it is **on the extension seam's pinned set and not on
the resident one**, `policy.extension_authority_modules` names the
non-`cap/` capabilities the filter also drops, and the freeze test writes
both sets out so the next `ext/…` capability cannot slip across by
spelling.

## What each test pins

`packages/client/test/client/extension/freeze_test.gleam`:

| Test | What fails when it fails |
|---|---|
| `the_extension_prelude_names_one_loom_dependency` | A `path` dependency added to `packages/ext`. |
| `the_capability_prelude_bottoms_out_in_the_vocabulary` | `cap` growing a dependency past `core`, which would make the first test hollow. |
| `the_resolved_manifest_holds_no_trusted_package` | A local package arriving transitively rather than by declaration. |
| `the_offline_build_root_vendors_three_packages` | A fourth package vendored into the seed, which is the surface an import actually resolves against. |
| `an_extension_may_not_declare_a_trusted_dependency` | `vet/package.allowed_dependencies` widened to a TCB package. |
| `no_prelude_module_imports_the_trusted_computing_base` | An import added to any module of either prelude. Walks both trees. |
| `the_preludes_ship_one_foreign_source` | A second `.erl` added under `packages/{cap,ext}/src`. The import walk reads only `.gleam`, so an Erlang source can name any module by atom with no import line to find; `cap_ffi.erl` is the one that exists and it names no loom module. |
| `no_seam_admits_a_module_of_the_base` | Either allowlist widened to a base module, including one that does not exist yet. Walks the fourteen base packages that ship Gleam. |
| `a_body_reaching_into_the_base_is_refused` | The lint failing to refuse, or refusing without naming the module the author must delete. |
| `a_body_declaring_foreign_code_is_refused` | `@external` admitted, which would make every import check moot. |
| `the_resident_allowlist_is_pinned` / `the_extension_allowlist_is_pinned` | Either seam changing at all. Exact set, difference taken both ways. |

`packages/codemode/test/codemode_test.gleam` additionally pins the
resident seam's *shape*: that it reaches no capability, that it is the
extension seam with the capabilities subtracted and nothing else changed,
and that `for_seam` selects it. The client's own `codemode_test.gleam`
pins the client-side half — `seam_caps(ResidentSeam) == []` and
`tool_seam(ResidentSeam) == Error(Nil)` — so that the two `case` arms
carrying "reaches nothing at all" cannot be made permissive with a green
suite.

## What the compiler emits

A future loader's runtime half would check a compiled module's beam
import table before loading it, so the argument that the import table is
the complete call graph was measured rather than assumed. `packages/ext`
was built with the toolchain and each `.beam` read with
`beam_lib:chunks/2`:

```
ext.beam          gleam@dynamic@decode gleam@list gleam@result
                  gleam@string erlang
ext@hook.beam     gleam@dynamic@decode gleam@json gleam@result
                  erlang maps
ext@memory.beam   cap@internal@dispatch cap@internal@wire gleam@json
                  gleam@result erlang
ext@runtime.beam  cap@report cap@runtime ext@hook gleam@json
                  gleam@list gleam@result gleam@string erlang
```

Three things follow.

1. **The table is a subset of the source imports.** `ext@runtime` imports
   `ext` in source and not in the table, and `ext@memory` imports
   `cap/internal/channel` in source and not in the table, because each
   uses only the other module's constructors and types and never calls
   into it. So an import-table check cannot over-report; and with
   `@external` refused by vetting and no dynamic module dispatch in
   Gleam — no `apply/3`, no `Module:f()` — the table is the complete set
   of modules a body can reach. The same subsetting is why authority is
   derived from the *source* walk rather than from these tables: a module
   holding only a channel's types would read as authority-free here.
2. **The namespace is the same one vetting reasons about**, with `/`
   rewritten to `@`.
3. **The compiler emits native Erlang modules no allowlist names**:
   `erlang` and `maps` above, `lists` elsewhere. A module-level check
   would therefore have to admit `erlang`, which is `erlang:open_port/2`
   and every other escape hatch under one name. **The check has to be
   per-MFA, not per-module.** Across `packages/ext`'s four source
   modules the emitted native MFAs are `erlang:element/2`,
   `erlang:get_module_info/1`, `erlang:get_module_info/2` and
   `maps:to_list/1` — a small, boring set a loader can allowlist by
   triple, and one `ext/memory` did not grow: the fourth module adds a
   table row and no new native call. This is the first of the two findings #32 inherits, and it is
   the reason the loader's cost is not `code:load_binary`. The second is
   module-name shadowing, under "Attack surface considered" below.

## Attack surface considered

- **A body that compiles clean and reaches at runtime.** Not reachable
  today: the body runs in a separate OS process under a kernel jail, and
  the only channel out is `cap_call`, which the broker judges per call
  with a token scoped to one execution. The seam is what decides what
  the body may *name*; the jail is what decides what it may *do*, and
  neither rests on the other. For a resident body this would be the whole
  of the defence, which is why the resident seam admits no capability at
  all and why the per-MFA finding above matters.
- **A manifest that lies.** The manifest is decoded totally, its key
  lists are closed, and a tier it does not know is refused *naming the
  tier* rather than ignored. A manifest cannot widen a seam: the
  allowlist is fixed at install and recorded, and `seam_mcp` deliberately
  gives the extension seam no per-host MCP widening for exactly this
  reason.
- **An archive that carries a beam.** Extraction is total and a
  non-`.gleam` file under `src/` refuses the whole package rather than
  being pruned, because Gleam would compile and link it. The installed
  tree is `src/**/*.gleam`, `schema/**`, `skills/**`, `extension.toml`
  and the docs, so source is not the only thing that crosses: `schema/`
  and `skills/` cross as data. They are checked to be UTF-8 and they
  never reach the compiler or the build root — only `src/**/*.gleam` does
  — so nothing crossing the boundary is executable, and the harness
  compiles the source itself.
- **A `gleam.toml` naming a dependency.** Refused against a closed set of
  four. The seed backs that up only for loom packages — it vendors `cap`,
  `core` and `ext` and no fourth loom package — but not in general:
  `cap`'s own runtime dependencies `gleam_erlang` and `gleam_otp` resolve
  in every build root, so `gleam/erlang/process` and `gleam/otp/actor`
  would compile if the seam admitted them. It does not, and that closed
  allowlist is what carries the weight here.
- **A satellite that holds a token past its invocation.** The token is
  installed per invocation by `cap/runtime` and is the broker's own
  check; a persistent host serves many calls, so the confinement is the
  token's scope rather than the process's lifetime. This is the phase-3
  surface, reviewed here only for whether it opens a *TCB* path — it does
  not, since a stale token buys another capability call, not a module.
- **A hook answer read as policy.** A `tool_call` hook may block a call
  with a reason, and the harness reads its answer. That answer is data,
  decoded totally, and cannot name a module, a capability, or a seam. The
  hook bus drops a host that dies and logs the reason rather than
  treating silence as assent.
- **An extension module named after a harness module.** `vet/package`'s
  `shadow_refusals` refuses a package's own module name only when that
  name is already on the seam's allowlist — the case it was written for,
  where `src/cap/fs.gleam` would become the `cap/fs` a sibling's import
  resolves to. `runtime/writer` is not on any seam, so an extension may
  legally ship `src/runtime/writer.gleam`, and `widen` then admits its
  siblings importing it. That is inert while every body is jailed: the
  satellite is a separate VM holding no harness beams, so the name
  collides with nothing. A resident loader would be putting a beam named
  `runtime@writer` into the harness code server, where a collision is a
  *swap* rather than a refused import. Handed to #32 alongside the
  per-MFA finding; no machinery now, because `codemode` is pure and
  cannot walk the tree to learn which names the harness ships.
- **A future refactor.** The one attack the tree cannot be inspected
  against, and the reason every check above walks the source tree instead
  of comparing against a written list.

## Findings — author's pass

| ID | Sev | Finding | Disposition |
|---|---|---|---|
| Z-F1 | INFO | The freeze is by construction, not by enforcement: with no loader, no code path exists that could violate §7 at runtime. The tests pin the *preconditions* of a future violation, not a violation. | Accepted and stated plainly here and in the design note. It is why the tests walk trees rather than assert behaviour. |
| Z-F2 | LOW | `ResidentSeam` is dead code by design — nothing selects it. A reader may take it for an oversight, and a lint census counting one-caller functions will see it. | Accepted. The alternative is inventing the allowlist inside a loader under deadline pressure, which is the failure this is meant to prevent. The doc comment says so at the definition. |
| Z-F3 | MED | The import walk in the freeze test is syntactic — it reads lines beginning `import `, not an AST. A pathological import Gleam accepts and the walk misreads would be missed. | Accepted, with the reason: the reading errs towards reporting *more* imports than exist, so it fails closed; both prelude trees are small enough to check by eye; and the seam disjointness test, which uses the real lint, does not depend on it. |
| Z-F4 | INFO | `cap` imports `gleam/erlang` and `gleam/otp`. That is correct — `cap` runs in the satellite VM, not the harness — but a reader scanning for process machinery near an extension will stop here. | Accepted; noted in the test's prose so the next reader does not re-derive it. |
| Z-F5 | MED | The per-MFA finding above means #32's "check the import table" is *not* the one-line check the design note implies. A module-level check would have to admit `erlang`. | Recorded here and in the test's `////`, so a loader starts from the measurement rather than the assumption. |

No HIGH findings on the author's pass. That is an expected outcome for a
surface whose defence is that the code does not exist, and it is exactly
why the independent pass below is the part of this review that carries
weight.

## Coordinator's independent review

An independent pass (Opus 5, 2026-09-03) read the same surfaces with no
sight of the author's reasoning, ran both suites with the exit codes
captured directly, rebuilt `packages/ext` and re-read all three import
tables with `beam_lib`, and built a replica build root from
`compile.default_dependencies()` to compile against. **No HIGH.** The two
MEDs are claim accuracy rather than reach: nothing in the diff is
exploitable today.

| ID | Sev | Finding | Status |
|---|---|---|---|
| Z-I1 | MED | The build root is not three packages. `cap` names `gleam_erlang` and `gleam_otp` under `[dependencies]`, so both resolve in every build root that vendors `cap`; a replica build compiled `gleam/erlang/process` and `gleam/otp/actor` with only a transitive-dependency warning. Mechanism one bounds the *loom* surface; the seam is the gate for the rest. | **Fixed in this PR.** The two sentences here and the one in the test's prose now say so, and both names are refusal fixtures. |
| Z-I2 | MED | The `gleam/erlang` fixture named a module gleam_erlang has never shipped; the reachable names are `gleam/erlang/process`, `/atom`, `/port`. It was refused for the right rule but was not the adversarial name a reader would take it for. | **Fixed in this PR** by the same fixture edit. |
| Z-I3 | LOW | The prelude source walk reads only `.gleam`, so `packages/cap/src/cap_ffi.erl` — the one file in the extension-facing packages that can name an Erlang module by atom — sits outside every test. It names no loom module today. | **Fixed in this PR**: `the_preludes_ship_one_foreign_source` pins the non-Gleam set under both trees as exactly `["cap_ffi.erl"]`, so a second shim forces a decision. |
| Z-I4 | LOW | The base omitted `events`, `telemetry`, `mcp` and `tui`, all of which ship Gleam and run in the harness VM, so a future TCB module landing in one of them was outside the disjointness walk. | **Fixed in this PR**: both constants are now every package that ships Gleam into the harness VM, and the doc comment says why `core`, `conformance`, `lint` and `prompt` are not. |
| Z-I5 | LOW | The three new `ResidentSeam` arms in `client/codemode.gleam` were asserted nowhere; "reaches nothing at all" rested on them and any of the three could be widened with a green suite. | **Fixed in this PR**: `seam_caps(ResidentSeam) == []` and `tool_seam(ResidentSeam) == Error(Nil)` beside the seam assertions. |
| Z-I6 | LOW | `shadow_refusals` refuses a package's own module name only when it is already on the seam, so an extension may ship `src/runtime/writer.gleam`. Inert in the jail; a resident loader would be loading `runtime@writer` into the harness code server, where a collision is a swap. | **Recorded for #32**, under "Attack surface considered". No code change: `codemode` is pure and cannot walk the tree, and a written list of harness names is the failure this review is about. |
| Z-I7 | INFO | The resident seam bounds names, not time or memory: an in-VM body has no jail, rlimit or deadline behind a `json.parse` or a recursion. "Pure transform" is not "bounded". | **Fixed in this PR**: a sentence in `policy.resident()`'s doc saying a loader owes the call a bound of its own. |
| Z-I8 | INFO | "Walks all ten packages" — it walked nine; `sandbox` ships no Gleam, as the test itself pins. | **Wording**, corrected with Z-I4: it now walks the fourteen base packages that ship Gleam. |
| Z-I9 | INFO | "Nothing but source crosses the install boundary" — `schema/**` and `skills/**` cross as installed data. Neither is compiled, so the property holds; the sentence overstated it. | **Wording**, corrected in this PR. |
| Z-I10 | INFO | The beam import tables recorded in the test's `////` and above reproduce exactly against a fresh build, and the four native MFAs with them. Z-F5 confirmed independently. Re-measured when `ext/memory` made the package four modules: one new table row, no new native MFA. | No action. |

The pass also attacked and could not break: the no-dynamic-dispatch claim
(none of the twenty allowlisted stdlib modules exposes a way out of
`Dynamic` into a callable, and `gleam/function` has no `@external` at
all); a `.beam` or `.erl` in the archive (`classify` refuses a non-Gleam
file under `src/` and the UTF-8 check catches anything that survived
elsewhere, so a binary cannot reach the staged tree); unjudged
`dev_dependencies` (`test/` is pruned first and the extension's
`gleam.toml` never reaches the compiler); a vacuous walk (both walks
assert on the directory read and every test carries a non-vacuity
assertion); and the reload path (`installed.gleam` re-vets, re-digests
and compares the recorded allowlist at every load, so the freeze survives
a seam widened after install).

## Reproduction

```
cd packages/client && gleam test          # the freeze test
cd packages/codemode && gleam test        # the resident seam's shape
cd packages/ext && gleam build            # then, for the import tables:
erl -noshell -eval '{ok,{_,[{imports,I}]}} =
  beam_lib:chunks("build/dev/erlang/ext/ebin/ext@runtime.beam",[imports]),
  io:format("~p~n",[lists:usort(I)]), halt(0).'
```
