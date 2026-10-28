# Responses completion and returned identity

Source: `6a2d8f4b4`, based on main `e4fb0b5e5`, October 27, 2026.
Issue: [#1139](https://github.com/Roasbeef/loom/issues/1139).

## What failed

The old argument witness required `.done.arguments` to equal concatenated
deltas. A complete snapshot at sequence 3, after created, in-progress and item
addition, therefore failed when no argument delta had arrived. The new fold
requires the snapshot to start with the previously emitted bytes, emits only
the missing suffix, and records the text closure. Equal snapshots emit nothing.
Shortened or conflicting snapshots still fail with `arguments_done_witness`.
Item identity, canonical item closure and the terminal response remain required.

Subscription request bodies also sent configured `access_programs` overrides.
The issue reports repeated standard-access responses when an explicit Daybreak
selection was supplied, and Daybreak responses when omitted. Subscription bodies
now always omit the override. Existing configuration is accepted, while API-key
Responses bodies retain their explicit selections.

## Comparison with the native parser

The comparison used [openai/codex at
727283cea5ba30e8cf8bbac6b68a03a4d91cf1b7](https://github.com/openai/codex/blob/727283cea5ba30e8cf8bbac6b68a03a4d91cf1b7/codex-rs/codex-api/src/sse/responses.rs).
The fetched file's blob is `7f076a139c2a9b1aaf6ea29649427d010d83439f`.

The native parser ignores function-argument delta/done events and emits the
parsed canonical item from `response.output_item.done`. It does not require an
argument delta before completion. The [official streaming
schema](https://developers.openai.com/api/reference/resources/responses/streaming-events#response.function_call_arguments.done)
defines `.done.arguments` as the finalized argument string. Loom reconciles that
snapshot while retaining its existing cross-event consistency checks.

The native parser obtains the served model from `openai-model` HTTP or event
headers, rather than the envelope's `model`, which can echo an alias. Loom now
follows those header conventions: case-insensitive names, string or first
array-string values, response-local headers before top-level event headers,
and the latest valid event observation after HTTP headers. Observations must
be nonempty and at most 256 bytes. With no valid header, Loom retains the
envelope model. This observation cannot replace the envelope identity witness.

The comparison does not justify adopting the native parser's broad tolerance
for unhandled events or dropped item decodes. Loom still rejects unknown
content-bearing events and conflicting completion witnesses.

## Returned access observation

`AssistantMessage.model` retains the configured identity, and `response_model`
holds the served-model observation. The terminal response's
`access_programs.cyber` is retained under
`diagnostics["loom.openai-responses.v1"].access_programs.cyber` when it is a
nonempty token of at most 64 lowercase ASCII letters, digits, underscores or
hyphens. Future identifiers in this alphabet remain observable. Invalid or
absent optional metadata is omitted without invalidating verified content.

These fields survive the existing message codec. Replay restores only its
allowlisted item projection and cannot turn observations into request options.
Missing metadata cannot prove the served model behind an echoed alias or the
access program. Failed streams have no settled message carrying observations.
No frozen interface, retry bound or credential path changes.

## Verification

The original 56 Responses tests passed. The added no-delta and prefix tests
failed under the old equality check, and the served-header test failed before
header capture was added. The resulting 62-test Responses suite and the
137-test client catalogue suite passed.

Eight deliberate mutations failed under their intended semantic assertions:
restoring equality-only completion, accepting conflicting prefixes, repeating
the whole snapshot as a suffix, forwarding subscription access, dropping the
access observation, exceeding its bound, ignoring served-model headers, and
exceeding the model-header bound. The restored scratch source passed again.
The mutants ran in a disposable copy, leaving the reviewed source unchanged.

One independent adversarial review found no actionable invariant,
simplification or nearby variant findings. The same reviewer rechecked the
served-model addition and found none. Other text-completion witnesses remain
strict; this issue supplies no evidence to relax them.

The final standalone provider format/build/test gate passed all 343 tests.
House-rule lint and the documentation gate passed. The broader local affected
run exposed a separate macOS fixture defect: the historical miner read
`/proc/self/environ`. The fixture now uses the existing portable home-directory
lookup. It fails before the change and executes its unchanged before/after
and provenance assertions after it. Its worktree remains outside `/tmp`.

The original hosted macOS client shard reported a UI response-head deadline
and an evolution acceptance deadline. Each test passed five isolated local
runs and an independent rerun. The evolution fixture uses Anthropic rather
than Responses. Neither deadline nor any assertion was changed.

The owner approved assigning the real eval verifier proofs to Linux and
checking production refusal on macOS. Three named EUnit generators retain
all 22 original proof bodies: nineteen verifier cases, one gold/null admission
proof and two mined trial cases. Their original deadlines remain in place.
On Darwin, each group instead runs the real production jail-opening path
and requires refusal of the missing process-lifecycle guarantee. Coverage
notes state which proofs were selected; they do not claim Linux proofs ran
on macOS. Pure checks and the portable historical mining regression still
run on both platforms. Production enforcement and skip declarations are
unchanged. Focused real-proof runs now select the module or its generator;
the original case names remain in Linux EUnit output.

The resulting macOS eval gate passed all 234 tests with zero skips in both
the implementation run and an independent rerun. Each focused module and
generator ran its refusal check. A same-reader review of the platform split
found no actionable findings; Linux execution of all 22 proofs remains part
of the final hosted and fresh-container gates.

A cache-free hosted run exposed a separate remote-subagent fixture race. The
80-by-24 terminal gives a peek half its transcript area; the renderer clips
leading rows when the loaded page exceeds that area. The header fits while
loading but can disappear before the test samples it. The fixture now resizes
to 120 by 40 before opening the visible transcript, matching the existing TUI
framing test. Its header, brief, tool and footer assertions and all deadlines
remain unchanged. Independent review confirmed this observation race; the
fixture does not claim complete framing fits every smaller terminal.

A separate directory failure exposed a lost coverage request during local
creation. The server requests lookup-hint coverage after receiving an opening
operation; a sweep can run before assembly confirms the reserved registration.
The old census omitted that row, reported success and consumed the request,
so later ticks never published its hint. A barrier-controlled regression
reproduced the missing hint on the old code and passed after the fix.

The registry now refuses a complete local census while an unconfirmed local
registration has an active waiting or building slot. The existing transient
error keeps the coverage request pending for a later sweep. It still excludes
reserved records from publication; remote reservations and failed or inactive
local reservations do not block confirmed sessions. The regression observes
publication after confirmation without issuing another coverage request.
Boundary tests cover waiting assembly and nonblocking failed reservations.
No interface shape, production deadline or skip declaration changes.

The PR's own macOS package checks disable the optional package caches. A
537 MB restore took 12m49s and exhausted the job budget, while the same full
check completed cold. The compiler binary remains content-addressed and
verified. This setting belongs in the PR workflow: a manual head run does
not replace the PR merge-commit checks. All tests and bounds remain in place.

The exact final head's hosted checks and configured Linux signoff remain merge
gates. The subscription endpoint was not called with a live OAuth grant; no
provider entitlement claim is established by these deterministic fixtures.
