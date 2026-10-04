# Startup time and resident memory

Status: **measured and partly repaired** on the `perf/startup-memory` branch,
2026-10-04, from `origin/main` at `63d5f1991`. Two larger savings are left for
the owner because each needs a decision this work should not make alone; they
are described at the end with their evidence.

## The bench

`make bench-startup-memory DB=<a session .db>` rebuilds both self-contained
releases and drives them through six scenarios, each from a fresh private
state root under its own `HOME`, with the smoke catalogue whose only model is
an unreachable loopback port:

| | Scenario | Time measured |
|---|---|---|
| a | daemon cold boot | `loomd` start until its listening line |
| b | client cold start | `loom` with no daemon running, until its first frame; the client starts the daemon |
| c | client attach | `loom` against a running daemon, until its first frame |
| d | one-shot command | `loom sessions list` against a running daemon |
| e | session growth | one admission over the control socket; memory is the daemon's growth per session from one to ten |
| f | long session | `loom --session` reopening a copy of a real session whose search index is built, until the first frame and until the transcript is drawn |

The first frame is the end of the first synchronised update after the client
opens the alternate screen. The client runs under a 120x40 pseudo-terminal
that answers the primary device attributes query, so the graphics probe ends
on the reply rather than its 200 ms timeout. Peak RSS is `wait4`'s
`ru_maxrss` for every process the bench starts; the daemon a client starts in
scenario b is sampled with `ps` instead. The `erlang:memory/0` breakdown comes
from one extra `--profile` run per scenario through the release's own
`loom-profile`.

Scenario f times a reopen, not a first open. The first time a session's
history enters its workspace domain the daemon indexes every entry for search
(about two seconds at two cores for the bench session), and that index
persists, so a person returning to a long session paid it once.

A comparison across minutes is only as good as the machine was quiet in both
windows, and on a host shared with other sessions it was not: two baselines
of one commit differed by 30 to 60 percent. `--snapshot NAME` keeps a build's
releases, and `--against NAME` runs each scenario once against the snapshot
and once against the new build, flipping the order every run. An A/A run of
one release against its own copy agreed within about 7 percent on medians at
four runs; every result below is interleaved.

`scripts/stack_sampler.erl` is the profiler the work used. A release carries
no OTP `tools` application, so it samples busy stacks, reads `call_time`, and
names the callers of a function from outside the node. Per-call tracing
inflates tiny functions badly, so its `calls` mode answers which functions are
reached and how often; it is not a timing.

## What landed

| Commit | Change | Effect, interleaved against the build before it |
|---|---|---|
| `a496f1408` | the gateway reads each entry once when it pulls | long session drawn -12%, its daemon's RSS -9% |
| `833b8be27` | the launcher skips the profile reader for a config that cannot ask | daemon ready -34%, cold client -18% |
| `d45a9289b` | the launchers cache the release code path | daemon -12%, cold client -15%, attach -14%, one-shot -9% |
| `b3d2ab015` | a session socket wakes its reader at once for a reply | long session drawn -31% |
| `61abf85a2` | the launchers size the process and port tables | every process's RSS -28% to -35% on a host with a high open-file limit |
| `20c391f72` | the client runs on four schedulers | client RSS -14% to -20%, attach -10%, one-shot -14% |
| `066e0228d` | the JSON parser cuts a string run with one binary match | parse 19% faster; end to end within the noise |

The profile reader was a second emulator boot (about 150 ms) on every daemon
start with a readable `loom.toml`, run to answer whether `[daemon] profile`
is set. The table sizes matter most where the open-file limit is high: the
emulator sizes its port table at the larger of 65,536 and that limit, so on a
host with the common soft limit of 256 the saving is the process table's
11 MiB per emulator.

Two candidates measured and dropped: parsing durable payloads straight from
bytes to skip a whole-document UTF-8 pass (validation of all 9.5 MB of the
bench session's entries costs 20 ms, so the pass was not where the time
was), and scanning an object's own fields for a repeated key instead of
building a dict (no change). Fewer dirty schedulers in the daemon saved
1-2 MiB; halving its schedulers (`+S 8`) saves about 6 MiB but halves the
parallelism a daemon running many sessions uses, so it is a trade-off and was
left.

## Results

`origin/main` (`63d5f1991`) against the branch's final build, alternating run
by run in one window, ten runs per scenario (ten admissions per run for e),
on a 16-core macOS arm64 host whose open-file limit is 1,048,576. Times in
ms, RSS in MiB; the RSS of b's daemon is a `ps` sample at the first frame.

| Scenario, process | Time median | Time p95 | RSS median | RSS max |
|---|---:|---:|---:|---:|
| a daemon cold boot | 455 → 260 (-43%) | 520 → 275 (-47%) | 102.9 → 73.5 (-29%) | 108.6 → 77.8 (-28%) |
| b client cold start | 833 → 549 (-34%) | 886 → 560 (-37%) | 103.1 → 60.3 (-41%) | 106.5 → 62.8 (-41%) |
| b daemon it started | | | 103.6 → 74.4 (-28%) | 111.4 → 78.8 (-29%) |
| c client attach | 348 → 268 (-23%) | 391 → 302 (-23%) | 103.3 → 60.3 (-42%) | 105.5 → 62.8 (-40%) |
| c daemon | | | 103.9 → 75.2 (-28%) | 106.6 → 78.3 (-27%) |
| d one-shot command | 242 → 186 (-23%) | 254 → 202 (-20%) | 95.6 → 52.7 (-45%) | 97.8 → 54.5 (-44%) |
| e one admission; daemon with ten sessions | 209 → 208 (0%) | 342 → 300 (-12%) | 234.5 → 201.9 (-14%) | 246.0 → 214.3 (-13%) |
| e growth per session | | | 11.1 → 11.1 (0%) | 11.5 → 12.0 (+4%) |
| f client first frame | 345 → 263 (-24%) | 383 → 285 (-25%) | 110.6 → 69.3 (-37%) | 114.9 → 77.3 (-33%) |
| f long session drawn | 1,797 → 983 (-45%) | 1,839 → 1,006 (-45%) | | |
| f daemon serving it | | | 211.5 → 168.7 (-20%) | 219.0 → 176.2 (-20%) |

`erlang:memory/0` at the census point fell from 56.7 to 28.9 MiB for an idle
daemon and from 58.5 to 22.3 MiB for an attached client. The per-session
growth did not move, which is the subject of the next section.

## What is left

**Per-session memory is the tool registry, copied.** A daemon with one
session holds 29 copies of the session's tool registry, 294 KiB each, which
is about 8.3 MiB of the 10.8 MiB a session costs. 27 of the copies sit in one
closure: the `run` slot of `client/wiring.build_effects`, which captures the
whole wiring `Config` to call `run_tool`. `Effects` is copied into every
process and supervisor child spec that holds the session's runtime, and the
BEAM drops sharing when it copies, so each holder gets its own registry. Of a
copy, 136 KiB is the code-mode `Config` twice: `codemode.seam` and
`async_codemode.seam` each capture it, and `tools/codemode.CodeMode` has two
closure slots, so no client-side arrangement can hold it once.

The repair that removes the copies keeps the registry in one per-session
process and gives `run` that process's address: a tool run fetches the
configuration when it runs, at the cost of one message copy per call. That
process has to live exactly as long as the session and be stopped in order,
which means a new kind in `client/internal/instance_owner`'s custody set and a
place in its cleanup ordering, the part of session teardown that guards the
lease. That is the owner's call. The code-mode duplicate needs `CodeMode` to
carry one closure where it carries two.

**A reopen decodes every entry once: repaired.** The gateway primes itself at
open by pulling above a high-water of zero, which built the entry-to-strand
attribution cache from every entry in the session: 2,438 entries and 9.5 MB for
the bench session, most of the 650 ms between the open request and resident.
The cache needs each entry's id, seq and parent, never its payload.
[protocol-change/066](../../protocol-change/066-entry-heads-scan.md) adds
`scan_entry_heads` to the storage interface, and the prime now reads heads and
shares one attribution function with the decoding pull. Scenario f, ten
alternating runs against the same window's baseline: the transcript is drawn at
734 ms against 1040 ms (-29%), and the daemon's peak RSS is 129.8 MiB against
172.4 MiB (-25%), since the decoded entries are no longer allocated. Time to the
first frame is unchanged, as it was never waiting on the prime.

Two costs the bench sees are its own. The bench model is unreachable, so the
on-boot distillation pass never advances its cursor and re-reads the first
512 entries of a session on every boot; a working install reads only what is
new. And scenario f deliberately excludes the one-time search indexing of a
session's first open.
