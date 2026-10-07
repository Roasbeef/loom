# Current handoff

This edition covers the context-inventory CPU optimization and configured
terminal profiling on `perf/context-profile-config`, isolated under
`.worktrees/perf-context-profile-20261006`. The original checkout and its
unrelated files remain untouched. The branch rebases without conflicts onto
`3ffb0bf522e037dcf8f973e64e3ab5e12c254ced` (#911, signoff log access), with
the context control unchanged. The branch started after merged
[PR #903](https://github.com/Roasbeef/loom/pull/903); its previous handoff's
pending-publication and merge claims are now obsolete. No Darwin skip waiver
was approved or added by this work.

Read [the context CPU report](review/beam-context-cpu-2026-10-06.md) for the
live attribution, matched fixtures and measurement limits. The previous
[snapshot report](review/beam-transfer-cpu-2026-10-06.md) and
[render report](review/beam-render-2026-10-06.md) retain their historical results.
GitHub carries the final exact-head publication verdict; a local component
pass cannot certify an untested later commit.

## Where the tree is

| Body of work | Verified state |
| --- | --- |
| Context inventory | A leaf memo depends on items and omitted count. Usage, headings and action handlers remain outside it. All 868 web-view tests pass. |
| Work reduction | Four alternating fresh OTP 29 VMs repeat the same reductions/allocation counts: stable inventory redraw reductions fall 98.89% to 98.92%, allocated words 97.97% to 97.99%. Changing inventory on every draw has no meaningful gain. |
| Regression controls | Main's context module fails the zero-work redraw assertion after passing the warm positive assertion. Initial HTML differs only by an invisible 20-byte memo marker. Forty concurrent regressions leave trace-session ownership unchanged. |
| Client profiling | Existing `[daemon] profile = true` applies to long-lived terminal clients. Both shipments carry the approved existing `tom` parser. Explicit `--profile` takes precedence. |
| Launch validation | Real parser and launcher regressions cover true, false, wrong type, malformed TOML, quoted keys, precedence and exit-only commands. A bundled synthetic demo client accepts Pickglass attachment from config alone and removes its credential directory on exit. |
| Startup cost | Ten fresh bundled-reader runs take a median 140.44 ms, ranging from 136.99 to 152.21 ms. Files that cannot name the key avoid the reader VM. No sampler or tracer starts merely because a client is named. |
| Terminal gate | All 1,242 TUI tests pass. The bundled runtime builds and boots without host Erlang on PATH; its existing smoke now also checks reader true/false behavior. |
| Independent review | The fresh reader found and verified a test counter-boundary gap and the short-lived UI command classification. Both are corrected. The final client slice and independent escalated launcher regressions pass with no outstanding finding. |
| Full affected gate | Static checks and server preparation pass; the first Mac full lane returns 124 at the unchanged 20-second aggregate Python deadline in upstream signoff fixtures on a host without `flock`. Its skip census passes. Final rebased and remote gates belong in the PR. |
| Installation | No application was installed, updated, restarted or hotpatched. Installed CPU/RSS savings remain unmeasured. |

The observed live daemon and terminal ran installed revision
`3644b079059570cf7cc3c7fe98add693bb6adbcc`, before #903. Their untraced
10.10-second workload interval used 114.5% and 36.6% CPU respectively. Pickglass
identified context-label normalization in the daemon. The terminal was unnamed;
native samples show GC and text work without resolving application JIT callers.
The synthetic demo proves the new launcher's attachability, not attribution of
that earlier user workload.

## Rulings already made

**Context ownership.** Keep the memo at the leaf. Project items and omitted
count before creating the callback; capture no board, handlers or transport.
Lustre drops nested cache entries on an outer hit, so nested memo machinery
would change the ownership argument. The tests count construction and cache
processing together, including the first redraw.

**Profiling configuration.** Reuse `[daemon] profile`; introduce no new schema.
The terminal reads only the typed profiling key before VM startup; the daemon
retains whole-catalogue validation. The existing parser preserves Unicode
escapes in keys literally, and the client matches that conservative behavior.
Help, version, `ui`/`--ui` link commands and other exit-only commands bypass
profiling setup. Cookies remain owner-only, exit-cleaned and loopback-bound.
A cookie holder has full access to the profiled VM.

**Measurement boundaries.** Reductions, allocation, retained heap, process
capacity, RSS and physical footprint are different measures. A matched source
fixture proves removed work; cumulative allocation and an old-build live cut
prove neither installed savings nor leak closure. No forced GC or conversation
state walk was used. [Issue #454](https://github.com/Roasbeef/loom/issues/454)
remains for coordinated installed memory measurements.

**Signoff ownership.** [Execution](execution.md) owns the gate. Publish the
exact commit and request the restricted Gilgamesh signoff. Its installed driver
posts the verdict; never hand-post a status or substitute an old head's result.
A red signoff can be inspected through its restricted `logs <sha> [lane]`
request. Hosted CI, local gates, review and signoff remain separate evidence.

## What to do next

1. Finish this PR's current-head review, hosted CI and restricted Linux signoff.
   Exit: record each verdict and any concrete platform limitation in the PR.
   The user requested a reviewable PR; this new PR has no merge authorization.
2. Follow [updating](updating.md) for a separately authorized installation.
   Exit: verify installed revisions and compare the same active, idle and
   released workload before and after. Config-driven profiling applies on the
   next launch of the updated client.
3. Profile a named client during a matched active fast-reasoning workload.
   Exit: bounded caller evidence identifies reachable remaining CPU work.
   SQLite bursts and control-heavy serialization remain outside this change.

Working-directory and LSP intent remains in
[protocol-change/068](../protocol-change/068-working-directories-and-lsp-scope.md).
Other issue and branch states were not audited by this performance pass.
