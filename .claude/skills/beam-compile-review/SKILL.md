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

Existing precedents in [tui.gleam](../../../packages/tui/src/tui.gleam):

- `f09bf1cf` separated `update` dispatch from `settle_update`. The recorded
  package compile fell from roughly 75 seconds to 6 seconds.
- `55432a73` added the same boundary between `update_tick` and `settle_tick`.
  Recorded `core_inline_module` time fell from 51.445 seconds to 1.632 seconds
  in an equivalent generated-code experiment; the Gleam rebuild took 7.80
  seconds. The earlier `settle_update` boundary had remained intact.

Those are historical measurements, not current budgets. Exporting a callee,
flattening calls into pipes, or hiding only the expensive expression behind
another local call did not fix the earlier case. A parameter boundary or a
cross-module boundary can change expansion; prefer the smaller measured repair.
Do not disable optimization or raise `inline_effort` as the default remedy.

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
