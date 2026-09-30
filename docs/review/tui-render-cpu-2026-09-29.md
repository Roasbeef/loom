# Terminal rendering CPU investigation

Measured on macOS on 2026-09-29 against installed build
`3088ee3ce771d50c82915c2bca93c8c642180dc1`, with Gleam 1.19.0-rc2,
OTP 29.0.5 and etui `c10f6a64`. The change lives on `tui/render-cpu`.
The measurements below precede installation of the changed client.

## Live attribution

The terminal client was the busy process. A native sample of the original
client, observed at roughly 80–98% CPU, attributed about 56–60% of sampled
stacks to dirty scheduler garbage collection. The relaunched `--profile`
client also showed large reduction and allocation rates during activity.
The daemon was around 4% CPU during that comparison.

Bounded OTP `tprof` captures of the client's main process used `call_time`,
`call_memory` and, separately, lower-overhead `call_count`. The broad traces
perturbed execution, so their elapsed times do not establish normal frame
latency. One allocation capture counted 503,542,338 heap words, roughly
3.75 GiB at eight bytes per word. This counts allocation, not retained
memory or RSS. A separate 5,001 ms count capture observed 241 frame builds,
260 ticks, 1,526 layout calls and 17,108 roster line calls.

The repeated work was identifiable in source: layout built and sanitized
the agent strip's text to ask for its height, and transcript padding sent
known spaces through text segmentation and width measurement on every
frame. All live tracing was stopped after each bounded capture; the
profiler registration and process trace flags were checked afterward.

## Changes

Layout now counts eligible strip rows using the existing primary, active
strand and status predicates. The same height thresholds and capacity
rules apply, without constructing text during geometry.

Speaker-colored transcript rows still render their original spans through
the same renderer. The renderer then writes the known-width padding
directly into the buffer with the original first-span style and no link.
Content is painted before padding, preserving the previous ordering for
wide graphemes. The existing dependency and its rendering behavior are
unchanged.

## Reproducible benchmark

The existing `scripts/tui_perf.sh` harness now supports `render`. Its fixture
uses the existing decoded six-agent capture with 100 Unicode paragraphs in
main's update, a dark palette, no overlay and a hidden diff panel. A fresh
VM runs with one scheduler. Each case has ten warmups and 100 measured
samples; setup and forced collection are outside the timed operation.
Allocation uses three separate `tprof` samples and is outside the timing
pass.

`paint` builds one frame. `scroll40` applies forty wheel events with the
fixture clock advancing 50 ms per event: ten up, ten down, then twenty up.
It ends at offset 60 in a 262-row transcript. The clock advance makes each
event eligible for a frame; independent tracing confirmed forty frame
builds. This measures update and frame work for spaced events, not a burst
of queued real input, terminal writes or end-to-end input latency.

Run from a built checkout with the matching compiler on `PATH`:

```sh
bash scripts/tui_perf.sh "$PWD" before render 200 50
```

Use a separate checkout containing the benchmark commit alone for the
baseline, and the complete branch for the candidate. Give each run a
distinct label. The harness writes complete initial and final styled
buffers and cursor state, plus hashes of all forty intermediate frames,
to `packages/tui/build/tui_perf/<label>-<width>x<height>.cells`.
Compare these files across the two checkouts.

At 200×50, three fresh-VM before/after pairs gave these medians of each
VM's sample median:

| Work | Measure | Before | After | Reduction |
| --- | --- | ---: | ---: | ---: |
| One frame | BEAM reductions | 580,705 | 362,091 | 37.6% |
| One frame | Allocated heap words | 1,145,873 | 824,408 | 28.1% |
| One frame | Time | 5.22 ms | 3.16 ms | 39.4% |
| Forty scroll events | BEAM reductions | 29,649,971 | 17,560,925 | 40.8% |
| Forty scroll events | Allocated heap words | 55,523,915 | 38,499,811 | 30.7% |
| Forty scroll events | Time | 178.95 ms | 129.44 ms | 27.7% |

Wall time varied with other work on the machine. Reductions and allocation
support the CPU-work conclusion more consistently. Additional single pairs
at 80×24 reduced frame reductions by 13.8% and scroll reductions by 28.0%;
at 200×100 the reductions were 51.5% and 53.4%. Allocation reductions at
those sizes were respectively 7.9%/19.6% and 37.6%/40.3%.

All five pairs had byte-identical rendering witnesses. SHA-256 values:

| Size | Witness |
| --- | --- |
| 80×24 | `871d12ba079ff5ab42f3b743af1ee8c5e7809c552ce6f64854ef5444c87a112f` |
| 200×50 | `fa227afef596b3c25a23419aafd895e67a30107f6aa7a203293acc9c50963285` |
| 200×100 | `99c581449cf8e23060913fcbb62ee0e39d0f5abd7586dc88d65d881c3f226f64` |

## Verification and remaining measurement

The new padding oracle reproduces the former padded-paragraph rendering
and compares full cells for both repaint phases, widths 4, 9, 40 and 100,
hyperlinks, Unicode continuation cells, alignment, empty and clipped rows.
Roster tests compare the count against actual rendered membership across
statuses and active-strand choices. Strip geometry tests compare height
against the drawn lines across terminal heights.

The focused tests, format checks, `git diff --check` and full `make check`
passed. The full gate's own exit code was zero, with zero lint errors.
Its existing shipped-daemon checks skipped without
`LOOM_BOOTSTRAP_E2E_SERVER`, and jailed extension checks skipped without a
code-mode seed. No Linux or hosted CI result is claimed here.

A fresh Astra adversarial review found no substantive correctness issue.
It confirmed the geometry equivalence, padding ordering, forty actual
frame builds and matching witnesses. Its one comment-spacing finding was
fixed before the full gate completed.

Next, install the reviewed client and repeat the user's CPU-ramp and
scrolling workload with a bounded low-overhead capture. These results do
not establish an equivalent reduction in total live CPU, since event rate,
terminal output and other frame costs remain part of that workload.
