# Developer experience fixes

Status: PR #340 merged as `93d50830` on September 9, 2026 after all 16
checks passed, including exact-head Linux signoff. Its head was `107b3851`.
Explicit support-tree mounts passed jailed Go, Apple Git and ripgrep in a
disposable follow-up session. The owner's configuration is unchanged; generic
access without naming directories remains a broader host-read policy decision. The rendering follow-up is documented in
[the performance guide](../performance.md#reuse-settled-transcript-layout).

The accepted review compared the September 9 Loom, Claude, and Codex terminal
recordings. It covered controls, environment setup, transcript inspection,
notes, code mode, editing recovery, and resource observations. The original
recorded session was inspected read-only; all mutating terminal probes used
separate state directories, workspaces, and local scripted providers.

## Implemented behavior

Steer now transfers to a priority host queue before cancelling the observed
operation. Ordinary queued prompts wait for their turn. Escape stops current
work and preserves queued input. A newly arriving prompt joins existing host
custody even if runtime retirement precedes its commit notification. Delayed
abort requests retain the original operation identity through retries.

Provider requests carry separate stream identities, including their end
markers. The terminal never uses an unequal preview identity as evidence that
it is newer. An exact captured last result clears retained fragments when a
relay failure omitted the optional end observation. The last-result register
is latest-wins: an absent or unrelated result cannot prove retirement across
arbitrarily skipped operations. Protocols 021 and 022 record these boundaries.

Consecutive tool calls have compact, identity-matched outcomes, failure counts,
and expanded detail. Current action comes from the captured operation's pending
batch. `/diff` displays successful edits in the retained history and works in
the same panel at narrow widths. `/notes` reads current values with revisions,
excerpt markers and omitted counts. Tool availability distinguishes host
registration, strand selection, and an actual discovery failure. Protocol 023
records the additional observations.

File reads and successful edits expose digests in model-visible text. A stale
edit still refuses without writing and directs recovery toward current content
and anchors. Code-mode guidance includes independent batches as well as
programs whose steps depend on one another. The jail inherits the host PATH
without enumerating installations.

## Verification

`LOOM_TEST_PARALLEL=8 make check` passed on the reviewed source tree. This
included all 1,515 client tests and 272 TUI tests. Lint reported zero errors and
641 advisory warnings. Dependency compilation emitted the existing empty-module
warnings from etui's browser and node backend placeholders.

One independent review found old-preview resurrection, normal-input admission
ahead of held input, and missing-end stream retention. Each was verified and
fixed. Restoring the old production behavior made the corresponding regressions
fail; restoring the fixes passed. The queue regression withholds commit hints
from before initial admission, so a previously queued hint cannot invalidate
its schedule. The reviewer rechecked the fixes and test construction.

A rebuilt release was driven through a real 160-by-48 tmux terminal and a local
Anthropic SSE fixture. It read and edited a file, wrote and displayed a current
note, ran a real jailed code-mode program, and displayed `/diff`. Escape stopped
a slow stream and completed the queued turn in 183 ms. Steer preempted another
slow stream and drained the normal queued turn in 245 ms. These timings include
terminal capture and fixture overhead. The earlier probe's saved database also
confirmed the actual prompt order, a null current operation, and empty pending
input after completion.

The final Linux enforcement and shipped matrix must be checked through the
`signoff/linux` status for the exact pushed head. A local package gate does not
substitute for that status or establish general release readiness.

## Measurements and limits

The comparison used an exact `eb0bbe60` release baseline and the reviewed source
committed through `0a8e385d`, the same machine, and isolated state. The saved
history driver was identical on both revisions and did not print private input.

| Measurement | Baseline | Reviewed source |
|---|---:|---:|
| Saved history entries | 512 | 512 |
| Wrapped transcript rows | 1,605 | 454 |
| Initial layout, median of three runs | 106.5 ms | 54.7 ms |
| Per-key render work, median of three run medians | 1.75 ms | 3.54 ms |
| Per-key render work, median of three p95s | 4.31 ms | 3.93 ms |
| Idle real-terminal key-to-paint median upper bound | 16.4 ms | 14.2 ms |
| Streaming real-terminal key-to-paint median upper bound | 14.9 ms | 14.7 ms |
| Idle TUI CPU, ten-second sample | 1.7% | 1.8% |
| Streaming TUI CPU, repeated ten-second sample | 7.5% | 7.5% |
| Daemon BEAM memory after admission and 15 seconds idle | 219.5 MiB | 218.3 MiB |

The terminal measurements include tmux command and capture overhead. The
streaming workload emits thinking deltas at 20 Hz; it does not reproduce the
original session's model latency, tool execution, or CPU load. An earlier CPU
sample showed a reduction that the repeat did not reproduce. There is no claim
of a sustained CPU or daemon memory reduction.

The memory census admitted two sessions and stopped one. After forced GC,
BEAM-accounted totals remained about 209 MiB on both revisions. The reviewed
process heaps accounted for about 149 MiB, primarily static supervisors,
Weft actors, and state machines; this is a process-class census, not attribution
to a particular application payload. Release builds omit `instrument`, so no
carrier ownership claim is made. The measurements do not establish a leak.

## Original-session replay and profile

The native `loom replay <recording.jsonl>` command consumes terminal recordings
created with `--record`. No such recording was found for the original session.
We reconstructed 534 replay events from its 532 durable transcript entries,
plus terminal dimensions and an initial snapshot. The native replay driver ran
those events without reopening the session or executing providers and tools.
The reconstruction cannot recover original keystrokes, streamed deltas, or
model and tool timing.

**Measurement correction, September 9:** the original reconstruction used v2
wire envelopes in legacy `incoming` recording events, whose reducer expects
v1. Its initial snapshot also contained an invalid null `live_op`. The earlier
10.10/9.63-second timings, 565/544-MiB peaks, and 22.2% sanitizer attribution
measured rejected frames, not admitted conversation history. Those figures are
withdrawn as original-session evidence. Matching frame counts did not detect
the error; checking final admitted records did.

The follow-up fixes both fixture shapes and requires 532 admitted records and
no failure notices before accepting a measurement. All 537 frames match
byte-for-byte across its baseline and optimization. The performance guide
records the valid comparison against the merged PR #340 source.

We combined unsafe-codepoint replacement with the existing escape-sequence
pass, removing a second decode and the allocation of one-character strings.
Against an archived copy of the old sanitizer, output matched for every
1,112,064 Unicode scalar value, 10,000 seeded mixed-control strings, and all
9,127 extracted session text values. The median of five direct passes over
those text values fell from 79.3 ms to 21.4 ms. Existing hostile-terminal and
Markdown tests passed, and the independent reviewer checked the small delta.

The sanitizer equivalence checks and direct text timings above did not use the
invalid wire reconstruction and remain valid. They establish reduced sanitizer
work, independently of the later layout-cache optimization.

## Remaining decision

Ripgrep runs in the real developer jail after PATH inheritance. Go and Apple's
Git launcher are found but cannot read their installed support trees under the
current minimal-root policy. The observed failures were Go's missing `testing`
standard package and `xcode-select` reporting no developer tools. Downloading
another compiler is not the remedy implemented here.

Explicit `[workspace].mounts` can grant read access to installed support trees
under the existing policy; [the distribution guide](../distribution.md#installed-tool-support-trees)
gives an example. The rendering follow-up verified all three tools in a
disposable real-terminal session with Go's GOROOT and the complete Xcode app
mounted read-only, plus a writable workspace-local Go cache. Mounting only
Xcode's `Contents/Developer` was insufficient: the launcher also reads its
Info.plist and sibling shared frameworks. No owner configuration was changed.

Support without enumerating tool or dependency directories requires choosing whether
local owner-only sessions receive broad host reads, while preserving restricted
writes and shared-session confinement. This changes the boundary recorded in
protocol 020. No broader read policy has been inferred or enabled.

The separate survey of large source files is report-only. It does not authorize
module splitting as part of this implementation.

## Acceptance still open from the video review

PR #340 is a substantial implementation of the review, not completion of every
item in it. The initial note explicitly requested a persistent diff pane at
sufficient width. `/diff` currently replaces the transcript at every width and
shows captured successful edits in history order; it has neither the responsive
right-hand pane nor a changed-file navigator or consolidated worktree diff.

Pending inputs now have reliable host custody and visible delivery state, but
editing an already queued message is not implemented. The terminal also lacks
the proposed explicit completion summary tying changes and validation to
remaining work and running jobs. Existing scrollback and selection mechanisms
were preserved; the full reading/selection-under-output acceptance exercise was
not repeated across all of the proposed layouts.

The configured Go/Git/search probe passed. The representative cgo/SDK test,
generic access without naming support directories, and a single actionable
missing-dependency diagnostic remain outside that proof. Control regressions
cover skipped state transitions and stream identities, and real streaming
Escape/steer passed; they are not the entire joined reconnect/held-tool/multiple
queue scenario described by the original acceptance note.

Resource work has measured replay and sampled real-terminal behavior, but the
full short/long, idle/streaming command-to-ack distributions and owner-attributed
daemon memory plateau are still unproven. The proposed 50 ms paint and 100 ms
control budgets have not been accepted as end-to-end guarantees. Keep these
items open instead of inferring completion from green tests for implemented
behavior.
