---
name: beam-memory-review
description: Review Loom changes for reachable BEAM allocation, copying, and retention costs. Use optionally after substantive memory-relevant work, or when asked to investigate memory growth; produce an evidence-ranked report without changing production code.
---

# BEAM memory review

Review the requested diff and its ownership paths. This is an optional review,
not a gate on every change. Report opportunities; do not automatically edit
source, add dependencies, lint rules or hooks, install, restart, or hotpatch.
A review with no actionable findings is a valid result.

Invoke with `/beam-memory-review` and a base/head or working-tree scope, for
example: `/beam-memory-review eadc0587..HEAD, include uncommitted changes`.
If no range is given, establish the intended diff from the current task and
state it. Do not silently turn a local review into a repository-wide audit.

## Establish the claim

Read [execution guidance](../../docs/execution.md), the affected package's
`CLAUDE.md`, and the latest sections of
[daemon memory evidence](../../docs/design-notes/daemon-memory.md).
The September 16 corrections supersede earlier descriptions of all post-GC
process memory as “live” or “reachable.” Historical measurements are evidence
for their recorded builds and workloads, not current daemon measurements.

For each candidate, trace a real caller to the allocation or retained value:

- Name the process or table that owns it, the source field or closure slot,
  and each spawn, message, ETS, supervisor restart, or socket boundary.
- Separate **allocation/copy cost** (bytes or words per operation, multiplied
  by frequency and recipients) from **retention** (what stays reachable, by
  whom, until which release event). A short-lived copy can be expensive; a
  large state can be necessary. Identify the actual workload that makes it matter.
- Check admission, cancellation, drain, restart and disconnect paths before
  proposing a shorter lifetime. Preserve authorization checks and custody.
- Dismiss unreachable paths, small bounded handles, and unmeasured speculative
  costs with a reason. Keep plausible but unmeasured candidates separate from
  confirmed findings.

## Inspect the relevant shapes

**Project closure inputs before constructing the closure.** Wrapping a hook
with `fn(op) { hooks.run_start(op) }` can retain the entire `hooks` record.
Binding `let run_start = hooks.run_start` first retains the needed slot.
Follow composed hooks, provider config, request/prepare facades, and nested
wrappers through their actual process transfers. Merely boxing a record or
putting it behind another closure does not make it shared across processes.

PR #438, merged at `eadc0587`, supplies concrete precedents:

| Boundary | Source and regression to read |
|---|---|
| Hook/tool sibling capture | [extension/hooks.gleam](../../packages/client/src/client/extension/hooks.gleam), `wire`; [hooks_test.gleam](../../packages/client/test/client/extension/hooks_test.gleam), `extension_wrappers_do_not_copy_sibling_slots_test` |
| Provider facade composition | [provider_relay.gleam](../../packages/client/src/client/provider_relay.gleam), `preparation` and `observed_surface`; [gateway_test.gleam](../../packages/client/test/client/gateway_test.gleam), `provider_wrappers_have_linear_copy_cost_test` |
| Supervisor init/restart inputs | [runtime/api.gleam](../../packages/runtime/src/runtime/api.gleam), `open_published`; [supervisor.gleam](../../packages/runtime/src/runtime/supervisor.gleam), `start_published`; [api_test.gleam](../../packages/runtime/test/runtime/api_test.gleam), `supervisor_restart_inputs_do_not_multiply_writer_options_test` |
| Route/attachment retained by socket and hub | [session_socket.gleam](../../packages/client/src/client/daemon/session_socket.gleam), `upgrade` and `Authorization`; [session_socket_test.gleam](../../packages/client/test/client/session_socket_test.gleam), `authenticated_socket_does_not_retain_resident_effects_test` |

Supervisor child-start closures can remain as restart specifications long after
initialization. Socket handlers and authorization callbacks can retain a resolved
runtime after routing ends. Prefer projecting required identities/capabilities;
never replace repeated authorization with a cached answer to save memory.
Provider projection must preserve prepare/begin timing, cancellation and drain.

Use [R12's implementation](../../packages/lint/src/lint/scan.gleam) and
[severity contract](../../packages/lint/src/lint/finding.gleam) as a search aid.
R12 flags outer bindings used only through direct field accesses in returned,
assigned or constructor-held closures. It lacks types and lifetimes, omits
ordinary callback arguments, and suppresses bare uses and record updates.
Warnings are candidates, and silence is not proof of safety. The
[prior inventory](../../docs/review/closure-retention.md) records dismissals
as well as confirmed sites; do not mechanically clear its warnings.

**Check copying and binary ownership separately.** The ordinary BEAM loses
subterm sharing through sends, spawn arguments and ETS storage. Refcounted
binary payloads and literals are exceptions to ordinary same-node copying;
remote messages add serialization. `erts_debug:size/1` counts shared term
structure, while `erts_debug:flat_size/1` ignores sharing. Both report words;
use the measured VM's word size. An RPC/state copy may already have destroyed
sharing. These are diagnostic term metrics, not total process or binary bytes.
See the official [process efficiency guide](https://www.erlang.org/doc/system/eff_guide_processes.html#loss-of-sharing).

A small subbinary can retain a large backing binary. Compare `byte_size/1` with
[`binary:referenced_byte_size/1`](https://www.erlang.org/doc/apps/stdlib/binary.html#referenced_byte_size/1)
and trace other owners before proposing a selective copy. Copying every slice
can increase memory while other references still retain the backing allocation.
The [binary guide](https://www.erlang.org/doc/system/binaryhandling.html#how-binaries-are-implemented)
explains heap versus refcounted binaries; its implementation description carries
an OTP 27 rewrite caveat, so verify version-sensitive details on the target OTP.
Do not sum per-process binary references as if each were unique payload memory.

## Measure the property

Compare baseline and head using the same fixture or replay, input size, model
catalogue, session/connection counts, concurrency, OTP/compiler build, VM flags,
and observation cuts. Record exact SHAs and dirty-tree scope. Separate startup,
admitted, active, idle and released states. Prefer deterministic offline inputs;
model-backed runs with differing tool sequences are only comparable workloads.
State repetitions, variation, units and any skipped measurements.

Use distinct counters rather than calling all of them “memory usage”:

- [`process_info/2`](https://www.erlang.org/doc/apps/erts/erlang.html#process_info/2):
  allocated process bytes, heap words, mailbox length and GC information.
  Queue length alone does not measure queued bytes or prove a leak.
- [`erlang:memory/0`](https://www.erlang.org/doc/apps/erts/erlang.html#memory/0):
  VM allocation categories, including process capacity, binaries and ETS.
  Sampling is not atomic and does not account for every OS allocation.
- [Per-process GC](https://www.erlang.org/doc/apps/erts/garbagecollection.html):
  distinguish collectable garbage, reachable terms, unused heap capacity and
  off-heap binary references. Even after full GC, allocated bytes are not an
  exact reachable-term size.
- OS RSS/footprint and [allocator carriers](https://www.erlang.org/doc/apps/erts/erts_alloc.html):
  distinguish resident pages, reserved address space, allocated blocks and
  carrier capacity. An RSS/VM gap alone does not prove a leak or its owner.
  Record unavailable instrumentation instead of treating it as zero.

Check what an inspection API exposes before treating it as the process's full
reachable state. In pinned `weft/actor`, `handle_system` passes `self.state` to
`sys.handle`; `sys:get_state` therefore omits the loop's handler, shutdown
callback, selector, timer state and other roots. A small returned application
state does not prove that the rest of a large heap is garbage. Trace those
retained closures in the actual dependency version, or report them as unmeasured.

Start with aggregate counters, then inspect one selected owner with bounded
time and memory. State/closure walks and RPC copies allocate too; run them after
comparable census cuts, not between cuts used to claim a reduction. Never emit
cookies, credentials, provider config values, transcript contents, process
dictionaries, or complete closure environments. Report sizes, shapes and code
locations; do not dump secrets and rely on later redaction.

### Repository tools

Run from the repository root. These source-inspection commands need no daemon:

```sh
git diff --stat
rg -n 'R12|closure_captures' packages/lint/src
rg -n 'flat_words|copy_cost|retain' packages/client/test/client/gateway_test.gleam packages/runtime/test/runtime/api_test.gleam
```

For an offline fixture with toolchain/dependencies available, use the bounded
runner from `docs/execution.md`; it errors on an unmatched filter. Run one build
at a time per checkout, inspect the fixture first, and capture the command's
own exit status. For example:

```sh
LOOM_TEST_TIMEOUT_SECONDS=120 bash scripts/test.sh client --match provider_wrappers_have_linear_copy_cost
LOOM_TEST_TIMEOUT_SECONDS=120 bash scripts/test.sh runtime --match supervisor_restart_inputs_do_not_multiply_writer_options
```

`bash scripts/lint.sh packages/client/src` runs the existing source census;
review R12 output without promoting it to an error. Do not use `gleam test
--match`, which the repository entry point does not honor.

Read [mem_report.erl](../../scripts/mem_report.erl),
[mem_dig.erl](../../scripts/mem_dig.erl) and
[daemon_memory_probe.sh](../../scripts/daemon_memory_probe.sh) before use.
The shell probe starts a release, admits sessions, **always forces full GC**,
and optionally runs a target-side walk with `DIG=1`. It is not a read-only
shortcut. `mem_report` has separate observe/collect modes and retrieves process
dictionaries for attribution; `mem_dig` loads probe code into the target.
Use approved isolated fixtures and protect diagnostic credentials. Do not force
GC, restart, hotpatch or load probe modules without authorization. Ordinary
observation and explicitly authorized collection belong in separate results.
Do not use the installed daemon or a live session store as a test fixture.

## Return a report, not a patch

Rank reachable findings by measured impact, frequency and lifetime, with
confidence stated separately. For each finding give:

1. The claim and `file:line`, concrete owner, copy boundary, workload and release event.
2. Measured baseline/head values and method, or an explicit inference with the
   missing measurement. A flat-size improvement alone is not an RSS claim.
3. The smallest proposed fix, preserved behavior, and a regression measurement.

For capture regressions, vary an unrelated payload and assert bounded copy-cost
growth while proving the payload still exists through its intended slot. Test
wrapper-depth growth and real owner state where relevant. Propose a negative
control that restores the broad capture in an isolated fixture; do not edit
production as part of this review.

Prefer slot projection or a narrower retained value before extra processes,
boxing, GC tuning or shared storage. ETS still copies ordinary terms, and
[`persistent_term`](https://www.erlang.org/doc/apps/erts/persistent_term.html)
updates/deletes can impose global collection costs. Either needs a measured
benefit and an explicit ownership, lifetime and update-cost argument.

End with dismissed candidates, unmeasured limits and the next useful experiment.
If nothing actionable is established, say so and name the scope checked.
