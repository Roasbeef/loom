# Live profile and JSON whitespace replay, November 9, 2026

The running daemon and the optimization baseline both identify
`661dca824363f872890eec3235f50b250537673d`. The live process is PID 34725,
running the installed 0.3.2 server on OTP 29 / ERTS 17.0.5. This profile observes
ordinary active work. It creates no model requests and makes no live install,
restart, hotpatch, forced collection or application-state walk.

## Local TLS attachment

The previously enrolled inspector still authenticates the daemon. Its node name
and certificate name `laptop@100.75.241.68`, but that address is no longer on a
local interface; the current Tailscale interface has another address. Pickglass
correctly refuses the old address as nonlocal, and substituting loopback as the
node name fails TLS hostname validation.

The owner approved a temporary inspector-only address resolver. It maps only
that node's transport address to `127.0.0.1`, retaining the original distribution
identity, TLS server name, certificate checks and cookie-file authentication.
The local listener was independently identified by PID and port. The wrapper
verifies the authenticated peer's OS PID before calling Pickglass's existing
profile executor. The resolver stays in the disposable inspector VM; only the
ordinary transient Pickglass agent reaches the daemon. Every successful capture
detached and reported its modules unloaded. No credential, membership ledger,
daemon configuration or network interface was changed.

## Fresh observations

One clean uninstrumented window used 5.40 CPU seconds over 30.019 seconds,
17.99% of one core, ending at 400.45 MiB RSS. A closing uninstrumented window
used 5.01 seconds over 29.980 seconds, 16.71% of one core, ending at 433.91 MiB
RSS. The closing footprint command reported 426 MB. Natural workload and
measurement cuts differ; those observations are not an optimization comparison
or a retained-memory trend.

The closing ordinary OTP census reported 494 processes and 375,518,597 allocated
VM bytes, including 288,374,144 process bytes, 37,461,712 binary bytes and
1,917,888 ETS bytes. The largest listed process allocation was 10,784,072 bytes.
These are allocation/capacity counters, not a measurement of reachable state.
Three Jevelin MCP servers and a code-mode satellite appeared in descendant
cuts. They are separate processes and are not included in the daemon's CPU or
VM allocation figures. No interactive native Loom terminal appeared in the
process inventory.

The 45-second Pickglass CPU probe sampled the busiest 16 listed processes at
62 Hz. It recorded 42,779 samples, 1,920 running/runnable and 40,859 waiting;
two selected targets exited during the probe. SQLite query frames appeared in
1,362 active samples, register point reads in 897 and snapshot SQL reads in
308. Those inclusive counts overlap. Safe-point sampling undercounts long
BIFs/NIFs; sample shares are not percentages of CPU time.

A separate 15-second selected-module allocation trace covered eight busy
processes. All 522 called functions had readings, totaling 34,102,612 heap words
or 272,820,896 bytes. The top-200 table omitted 112,152 bytes. Listed JSON
functions accounted for at least 200,436,112 bytes (73.47%); gateway functions
for 54,924,864 bytes. `json.skip_whitespace` accounted for 23,236,104 bytes over
287,591 calls. A function's count includes untraced callees and excludes traced
callees. The trace measures cumulative selected-process heap allocation,
excluding retained heap, off-heap binary payloads, native memory and RSS.

## Selected change

The only production change is the private `core/json.skip_whitespace` match.
Four literal byte prefixes replace a generic byte/suffix pattern followed by a
guard. A non-whitespace byte can take the fallback without binding its suffix.
The accepted whitespace remains exactly space, tab, LF and CR, and every
consumed byte advances the document-relative cursor once. Syntax, duplicate
rejection, UTF-8 validation, depth limits and complete corruption reports retain
their prior behavior. No API, dependency, cache, SQL read or timer changes.

Gateway lookup allocation was also inspected, but its trace includes untraced
fallback reads and does not establish that replacing a dictionary conversion
would help. The selected parser change has a direct matched allocation proof.

## Fixed replay

`scripts/json_whitespace_replay.sh` runs in a fresh non-distributed VM with one
normal scheduler and eight-byte words. It loads saved baseline and current
parser abstract forms under isolated names, compiling both with identical
options. The saved baseline executable MD5 matches the live module read over TLS
(`0E4EEE1EC555F5E88C8EBBF0350A8B52`). A guard permits only the whitespace function's executable AST to
differ after removing source annotations; function inventories must also match.
The baseline BEAM SHA-256 is
`42f9fe7764995342c9fdefacf00fc6f189ca3730a0d6f76dd2491573d552e1aa`.

The replay reuses the existing 23,004-case parser corpus, including truncations,
raw invalid UTF-8, escapes, duplicates and depth boundaries. It adds 2,630
complete-result comparisons over legal whitespace runs and every one-byte
substitute at document, array, object, colon, comma and closing-token boundaries.
Results include complete `CorruptionReport` records. The added corpus also
compares the normal production candidate with its alias. Counts include repeated
cases; they are not claimed to be unique inputs.

Three isolated semantic mutants are rejected by ordinary result differences:
omitting tab (36 witnesses), accepting vertical tab (9), and failing to advance
source offsets (40). A compilation failure or exception aborts the replay and
does not count as a rejected mutant. The existing output-ownership witness keeps
the same 96-byte result backed by the same 1,048,679-byte input; no retention
improvement is claimed.

Eight timing rounds and four separate root-only `tprof.call_memory` rounds
alternate version order. The parser receives the same immutable input in every
round; setup, corpus generation and tracing are outside the timing window.
Each compact or padded fixture makes 20,000 parse calls; the long-text fixture
makes 100. Allocation readings were identical across all four rounds.

| Fixture | Baseline heap words | Candidate heap words | Fewer words | Median VM CPU ms, before / after |
| --- | ---: | ---: | ---: | ---: |
| Register-shaped JSON | 42,660,000 | 38,960,000 | 8.67% | 68.5 / 61.0 |
| Stream-delta JSON | 38,640,000 | 35,400,000 | 8.39% | 71.5 / 63.5 |
| Mixed array | 40,820,000 | 38,160,000 | 6.52% | 43.5 / 37.5 |
| Whitespace-padded array | 11,640,000 | 11,020,000 | 5.33% | 13.0 / 11.0 |
| Long plain text | 30,000 | 27,800 | 7.33% | 33.5 / 34.5 |

Reduction medians are roughly flat, ranging from 0.42% fewer to 0.03% more in
the compact/padded fixtures. Compact/padded CPU medians are lower in this isolated loop, while long-text
CPU and wall medians are slightly higher. Timing ran on a shared host alongside
downstream fixtures; no end-to-end latency or installed-daemon CPU saving follows. Long text
mostly uses off-heap binary payloads, so its small heap count is not total
allocated memory. These inputs are synthetic shapes, not captured private
transcripts or a matched replay of the live workload.

The new guard requires at least 3% fewer median heap words and at most 2% more
median reductions in each compact/padded shape, plus no additional long-text
heap words. The real comparison passes. Candidate-as-baseline exits 1
specifically at `no_improvement`, testing the combined guard. Existing benchmark
guards and test deadlines are unchanged.

## Verification and reproduction

Three fixed-seed whitespace properties cover legal boundaries, unchanged string
content, exact codepoint offsets, forbidden controls/Unicode whitespace and
generator reach. All 179 native core tests pass. The new properties also pass
against the saved baseline and under Node. The strict JavaScript build exits 1
on 22 warnings in unchanged numeric-range/bit-array code; it generated the
candidate modules used for those targeted Node checks. A full JavaScript suite
pass is not claimed.

All 2,306 selected native tests pass without skip lines: core 179, storage 379,
session 73, machine 106, runtime 217, provider 359, broker 424, code mode 453 and
conformance 116. Code mode and conformance execute the real jailed build,
satellite, capability and helper paths. House lint, format, documentation,
prelude and client static gates pass; documentation has zero errors and 225
advisory warnings. This is focused downstream/end-to-end validation, not a full
local `make check` pass. PR validation records independent review, hosted
outcomes and Linux signoff separately.

Build core at baseline `661dca824` and preserve its `core@json.beam` from
`packages/core/build/dev/erlang/core/ebin`. Build candidate core, then run:

```sh
bash scripts/json_whitespace_replay.sh CHECKOUT BASELINE_CORE_JSON_BEAM --expect-improved
```

The same command with the candidate BEAM as baseline must fail specifically with
`no_improvement`. Raw live captures are under `.notes/profiles/2026-11-09/`;
fixed replay, baseline artifacts, parsed medians and controls are under
`.notes/benchmarks/json-whitespace/` (`final-replay.log`, `final-results.json`,
`final-noop.log` and their direct exit receipts). These files are intentionally untracked.
The live daemon continues to run the unmodified baseline.
