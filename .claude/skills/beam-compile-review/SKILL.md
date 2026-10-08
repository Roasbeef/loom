---
name: beam-compile-review
description: Review Loom/Gleam changes for BEAM compiler regressions. Use proactively when extending local transformation chains around large dispatch, drain, or rendering expressions, or when compilation slows or CI appears to hang. Produce measured findings and small structural recommendations.
---

# BEAM compile review

Review the requested diff for compile-time costs. Like the BEAM memory review,
this is optional and evidence-ranked, not a mandatory gate on every change.
Use it while changing a vulnerable call chain, before treating a slow build as
ordinary package growth. A new local step is a reason to inspect and measure,
not proof of a regression.

Invoke with `/beam-compile-review BASE..HEAD` or an explicit working-tree scope.
If omitted, establish the intended range from the task. Report findings by
default; implementation, publishing, new compiler flags, and new CI gates follow
the user's authorized scope. No actionable findings is a valid outcome.

## Locate the cost

Read [execution guidance](../../../docs/execution.md), the affected package's
`CLAUDE.md`, and its generated Erlang. Start with the exact revision, dirty-tree
scope, Gleam and OTP versions, build mode, and command that was slow.

Separate dependency resolution, Gleam compilation, Erlang compiler phases,
release assembly, and tests. A `Compiled in` line is broader than one compiler
phase. A cached no-op build measures neither a package rebuild nor a clean
build. Do not attribute a deadline to a test until checking what it was doing.

Compare baseline and head with the same toolchain, mode, dependencies, compiler
options, and rebuild scope. Run one build/profile at a time; concurrent compiler
jobs distort comparisons and may race on generated files. Repeat when noise
could change the conclusion. Keep the raw log and the command's own exit code.

If fresh generated sources are needed, build within an isolated checkout or
use the repository's package gate. Preserve dirty work and existing caches;
do not delete build directories merely to obtain a timing. Confirm generated
sources match the source revision before using them as evidence.

## Recognize the inliner failure shape

Gleam-generated Erlang enables `inline`. A large expression followed by several
local transformations can be repeatedly expanded when the inliner abandons
attempts at its effort limit. The abandoned attempt restores its expression
cache; later attempts can repeat the work. Depth and call shape matter more
than line count. Verify this behavior on the actual OTP/compiler version.

Inspect changed handlers for this shape:

```gleam
let changed = expensive_dispatch(event, model)
let changed = first_step(changed)
let changed = second_step(changed)
third_step(changed)
```

The useful boundary takes the expensive result as a parameter:

```gleam
let changed = expensive_dispatch(event, model)
settle(model, changed)

fn settle(before: Model, changed: Model) -> Model {
  changed |> first_step |> second_step |> third_step
}
```

These fragments show the call shape, not a recommendation to ignore `before`.
Keep original state where comparisons, time accounting, authorization, or
ownership need it. For ordinary value-to-value helpers, use a pipeline for
readability; `use` requires a callback-taking API. Changing syntax alone does
not establish the parameter boundary. Preserve evaluation order, arguments,
exceptions, and effects.
Do not move an effect into a callback that may run later or more than once.

Treat a nested-call-to-pipeline rewrite as a change to verify, not a performance
guarantee. Retain the expensive-result parameter boundary and the exact service
order, then compare rebuilt package time and `core_inline_module` time against
the nested version under the same toolchain. Run the affected package tests.
If either compile measurement regresses beyond normal variation, investigate
before accepting the rewrite; a faster no-op build is not evidence. Inspect
generated Erlang to confirm the pipeline adds no callback or repeated work.

Existing precedents in the TUI client. `settle_update` lives in
[tui.gleam](../../../packages/tui/src/tui.gleam) and `update_tick` and `settle_tick` in
[tui/tick.gleam](../../../packages/tui/src/tui/tick.gleam):

- `f09bf1cf` separated `update` dispatch from `settle_update`. The recorded
  package compile fell from roughly 75 seconds to 6 seconds.
- `55432a73` added the same boundary between `update_tick` and `settle_tick`.
  Recorded `core_inline_module` time fell from 51.445 seconds to 1.632 seconds
  in an equivalent generated-code experiment; the Gleam rebuild took 7.80
  seconds. The earlier `settle_update` boundary had remained intact.
- Issue #374 split the 15,500-line `tui.gleam` into modules under `tui/`, so
  most steps on both chains became cross-module calls, which the inliner never
  attempts. Both parameter boundaries were kept for the local steps that remain.
  A rebuild after a change to `tui.gleam` fell from about 9.7 seconds to about
  1.6 seconds, and `erlc +time` on the generated `tui` module from 11.6 seconds
  to 0.5 seconds.

Those are historical measurements, not current budgets. Exporting a callee,
flattening calls into pipes, or hiding only the expensive expression behind
another local call did not fix the earlier case. A parameter boundary or a
cross-module boundary can change expansion; prefer the smaller measured repair.
Do not disable optimization or raise `inline_effort` as the default remedy.

## Recognize the wide-record failure shape

Gleam compiles `Record(..value, field: x)` to a tuple that reads every
untouched field with its own `element/2`. On a record with tens of fields, each
update expression is a few hundred generated expressions, and erlc's SSA passes
(`beam_ssa_opt`, `beam_ssa_pre_codegen`) take roughly 10 ms for each. Nothing
looks wrong in any one function, because the cost is the number of sites rather
than their shape, so a per-function ablation shows the time spread evenly
across every handler that updates the record.

Check the width of a record that handlers update often, then count its update
sites with grep for `Type(..` in the package and its tests. The
field-heavy records in Loom are `View` and `Shared`. A setter per field, in one
module (`tui/view_set`, `session_view/shared_set`), expands the record once per
field; callers pipe the record through setters. The measured effect on the
`tui` package, in erlc CPU: sources 5.9 s to 3.2 s, test modules 8.6 s to
3.9 s, `session_view` 3.1 s to 2.5 s. Prefer narrowing the record to adding
setters when the fields group naturally; setters were the smaller diff here.
A setter costs about as much to compile as two call sites, so give a field one
only when several sites set it.

## Profile and test the hypothesis

Use [profile_module.py](../../../skills/beam-compile-review/scripts/profile_module.py) after generating the desired
revision. From the repository root:

```sh
python3 skills/beam-compile-review/scripts/profile_module.py packages/tui tui --mode dev --timeout 120
```

The helper runs `erlc +time` on the existing generated module, supplies its
include directory and dependency code paths, and writes the log, metadata, and
BEAM into a fresh temporary directory. It does not rebuild sources, modify
tracked code, overwrite the package's BEAM, or load code into a running daemon.
It returns the compiler's failure status, 124 on timeout, or 130 on interruption.
Timeout and interruption terminate and reap the compiler's process group.
Inspect `profile.log`; an absent completed phase on timeout is unknown, not zero.
The helper measures one generated module, not the whole Gleam package.

Gleam 1.19 writes each module as Erlang abstract forms
(`_gleam_artefacts/<module>.abstr`) and leaves no `.erl` file for a Gleam
module, so the helper above finds nothing to read. [profile_package.escript](../../../skills/beam-compile-review/scripts/profile_package.escript)
ranks a built package's modules by erlc CPU (`modules`), prints the functions
that expand the most (`sizes`), and measures what each of the largest saves
when stubbed (`ablate`). It reads existing build output and writes nothing.
CPU time from `erlang:statistics(runtime)` is steady on a loaded host where a
`Compiled in` wall time is not; interleave runs and report medians anyway.
A missing or empty abstract-form directory fails with exit 2. Never treat
zero discovered modules as a compile-time measurement; confirm the compiler
version and rebuild the intended mode first.

If `core_inline_module` dominates, test a focused ablation or equivalent helper
extraction in a temporary copy of generated Erlang. Retain the original and its
hash. Keep compiler options identical and record every experimental change.
Removing an effect can locate cost but is not a behavior-preserving fix. Do not
commit generated experiments or benchmark against them as production source.

When a fix is authorized, make it in Gleam and measure the actual rebuild after
regeneration. Run the affected package gate and applicable lint/docs checks;
confirm original/drained state roles and exact call order by reviewing the diff.
A fast generated-code experiment alone does not validate the Gleam repair.
Compiler-flag experiments may aid diagnosis but do not authorize flag changes.

## Report

For each actionable finding give the changed path, the expensive expression
and transformation chain, measured baseline/head values with units and scope,
and confidence. Distinguish phase time, package time, and total command time.
Name the smallest structural repair and the behavior it must preserve. Include
command exit status, validation performed, and unavailable measurements.

Dismiss chains with no demonstrated cost rather than splitting every function.
Recommend a new regression guard only with a repeatable measurement and a
justified budget; adding a timing gate or static lint rule is a separate change.
