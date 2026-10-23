# Live terminal and daemon resource profile, October 22

The terminal's Ctrl+G transition performs avoidable layout and image-marker
work. Two small changes reduce that work without changing the rendered cells.
This report records live attribution separately from disposable fixture
comparisons. Installed CPU and RSS savings have not been measured.

## Scope and provenance

Both installed launchers identify source commit
`3cf6bdc09c281e39dd126d5b7daa6c9d7eb4308d`, also this checkout's baseline.
The product commits are `4e8417fbf` (activity layout) and `0e7b74a2f`
(image-marker discovery).
The daemon was PID 16613, shipment `server.CgNyw597`; the terminal was PID
28061, shipment `client.jrRCZf8o`. Both used OTP 29 / ERTS 17.0.5. Measurements
were taken on macOS on October 22, America/Chicago. The terminal's profiling
node was already enabled. Pickglass attached with its existing private cookie
file, which was never printed. No live restart, hotpatch, forced collection,
or deployment membership change was performed.

The user identified a CPU spike during the switch to detailed view. A
30-second, 500 Hz Pickglass capture taken for repeated Ctrl+G toggles counted
3,111 running/runnable samples and 11,889 waiting samples. Stack widths are
shares of samples, not CPU percentages. Long BIFs and NIFs are under-sampled,
and the stack depth is limited to eight frames.

## Terminal attribution

A Pickglass census reported 97.7 MiB total BEAM allocation: 51.1 MiB in
processes, 24.1 MiB in binaries, 13.4 MiB in code, and 1.0 MiB in ETS. The
terminal loop, `<0.86.0>`, owned the largest process allocation, 45.7 MiB.
These categories overlap at different levels and are not an RSS census. A
separate native cut reported 162.0 MiB physical footprint, peak 328.4 MiB.
The changing workload and different observation times prevent interpreting
their difference as a leak or an allocator saving.

A five-second allocation count scoped to `tui@*` and `etui@*` in the terminal
loop observed 5.13 seconds. It read 491 called functions, with allocation
counters available for all, and listed the largest 200. Total attributed heap
allocation was 236,122,600 bytes. `layout.running_tool_label` was called 1,234
times and attributed 41,659,840 bytes to that function, including untraced
callees. `buffer.set_string_linked` attributed 106,345,048 bytes. These are
cumulative allocation counters, not retained memory, and are not the whole
VM's allocation rate.

The transition CPU capture found `running_tool_label` in 342 samples. A common
stack reached it through `layout.input_height`, `pending_height`,
`composer_status_lines` and `input_keys`. Those key hints only distinguish
the presence of a live phase, so they now read `active_strand_phase` without
decoding the batch or formatting tool arguments. A wide composer's status
band also checks its width before computing the label it will not display.
The actual activity renderer continues to build the label.

Image detection was another repeated stack: `image_box.found`, `read`,
`marker_of`, `cells_of`, then grapheme conversion. One exact stack accounted
for 157 samples, with other stacks reaching the same work. Ordinary theme
colours are RGB, so the old detector built grapheme lists for ordinary text.
It also measured every preceding span even when a row contained no marker.
The detector now rejects impossible marker prefixes first and computes
preceding widths only after finding a marker. It still validates the whole
span and preserves the first marker's terminal-cell column.

## Disposable comparisons

The same compiled fixture, compiler and OTP build were used on both sides.
Original `tui@layout` and `tui@image_box` beams were saved before modification
and loaded only into isolated comparison VMs. Current beams were used for
the candidate. Each VM ran with one scheduler. None of these comparisons
read the user's session store or changed either installed process.

For Ctrl+G, the six-agent `tui_agents_dev.render_model` was resized and driven
through the normal update and view paths. Its presentation clock advanced
50 ms before each action so frame pacing actually painted the transition.
Ten warmups preceded 60 timed samples; allocation was a separate three-pass
`tprof` measurement. Before/after VMs were alternated twice. Expanded and
collapsed frame hashes differed from each other and matched between revisions
at both widths, including styles, links, continuation cells and cursor.
An earlier run with a frozen clock reused a paced frame; its transition
figures are excluded.

| Fixture action | Before reductions, median | After reductions, median | Before heap words, final pass | After heap words, final pass |
| --- | ---: | ---: | ---: | ---: |
| Expand, 120 columns | 191,202 | 157,294 | 444,474 | 390,752 |
| Collapse, 120 columns | 183,209 | 149,646 | 430,209 | 376,487 |
| Expand, 40 columns | 156,073 | 138,490 | 305,471 | 277,511 |
| Collapse, 40 columns | 147,110 | 129,868 | 283,519 | 255,559 |

The second alternation reproduced the word counts exactly and changed the
120-column reduction medians by fewer than 200. The fixture's active main
strand is in assistant phase, so this comparison measures avoided activity
formatting generally; it does not reproduce the live tool batch's 1,234
label calls. At 120 columns it uses about 18% fewer reductions and 12% fewer
heap words per transition. Wall times varied with other host activity and
are not the basis of the claim.

The existing `scripts/tui_perf.sh . LABEL render 120 40` comparison also
preserved its complete 40-frame scroll witness:
`9E246A7E71A8E3006694DDD557BCFE062058F5B52BDD709A44A76AFA14F53305`.
Paint allocation fell from 349,088 to 328,070 words in the final traced pass;
the forty-scroll sequence fell from 16,665,439 to 14,563,042 words. These are
about 6% and 13%, respectively. This fixture does not exercise image discovery
as the live image-capable terminal does.

A separate image-detection fixture scanned forty ordinary RGB-styled rows,
each containing ASCII, a wide character and combining text. Both versions
returned no image boxes. Across two fresh-VM alternations, median reductions
fell from 50,001 to 3,023 and final-pass allocation from 117,980 to 3,910 words:
94% fewer reductions and 97% fewer words for this scan. This isolates the
detector; it is not a whole-transition or installed RSS claim.

## Daemon observation and access

An independent access investigation confirmed that the installed Pickglass
launcher supports TLS flags and `--attach-dir`. Loom PRs
[#1066](https://github.com/Roasbeef/loom/pull/1066) and
[#1070](https://github.com/Roasbeef/loom/pull/1070), and Pickglass PRs
[#11](https://github.com/Roasbeef/pickglass/pull/11) and
[#12](https://github.com/Roasbeef/pickglass/pull/12), implement transport and
the credential directory. They do not create a tool grant at daemon startup.
[Protocol 096](../../protocol-change/096-tool-members-and-profile-over-tls.md)
requires the deployment authority to enroll the tool.

Read-only decoding of the daemon's local ledger found genesis and four
members, with no tool member. Bounded local searches found no attach
directory. `loomd distribution log --json` reached the operator command and
reported `no authority key is kept under /Users/roasbeef/.loom/authority`.
The default passphrase file was absent. The installed `loom distribution`
client route printed only launcher diagnostics, so it did not establish
operator access. Known-peer SSH checks found no usable verified route to an
authority; host verification was preserved. No enrollment was attempted.

Consequently the daemon has native measurements only. Over 30.138 seconds
it consumed 1.72 CPU seconds, averaging 5.71% of one core. RSS ranged from
542.44 to 578.67 MiB. A native sample reported 504.8 MiB physical footprint,
peak 650.5 MiB; a later `vmmap` cut reported 496.7 MiB. Native stacks do not
identify a Gleam function worth changing. This uncontrolled interval proves
neither growth nor a link to the terminal transition.

The remaining prerequisite is locating the deployment authority or an
existing tool grant from a newer ledger, then using the documented
`loomd distribution attach-file` and `pickglass --attach-dir` path. Replacing
TLS or borrowing another member's identity is not part of this work.

## Validation and artifacts

`bash scripts/check.sh tui` passed all 1,563 tests, formatting, warning-free
compilation and package lint. It ran outside the shell sandbox because an
earlier run failed five process-identity/bootstrap tests when `/bin/ps` was
blocked. The image regression pins both protocols after ordinary RGB text,
wide and combining characters, and a no-break-space prefix followed by text.
Existing whole/clipped, centering and image lifecycle fixtures also passed.

One independent source review found no actionable issue in phase/liveness
equivalence, activity placement, full-span marker validation or first-marker
columns. It noted the detector's stack now follows one visible row's span
count and found no concrete failure requiring further machinery. It did not
independently rerun tests or benchmarks. Hosted CI and installed savings
remain unmeasured.

Local artifacts are under `/private/tmp` and may expire. The principal files
are `loom-client-before.pgcap`, `loom-client-observed-allocation.pgcap`,
`loom-client-details-switch-cpu.json`, `loom-live-cpu-rss.jsonl`,
`loom-details-comparison-final.log`, `loom-image-scan-comparison.log`,
`loom-tui-baseline-render.log`, `loom-tui-final-render.log`,
`loom-tui-final-gate.log`, and `loom-daemon-access-and-profile.md`.
The standalone comparison drivers are `loom_details_perf.erl` and
`loom_image_scan_perf.erl`; original modules are in `loom-layout-before`.

The switch also reprojects detailed transcript content, including JSON
encoding, sanitization and program-result previews. Those paths were sampled
but are left unchanged: the current evidence does not justify a new retained
cache. Buffer painting and terminal diffing remain visible CPU consumers.
