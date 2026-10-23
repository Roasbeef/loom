# Current handoff

This is a scoped profiling handoff, checked October 22, 2026 against
`3cf6bdc09c281e39dd126d5b7daa6c9d7eb4308d` plus the local terminal optimization
commits `4e8417fbf` and `0e7b74a2f`. It records this task's measurements and validation, not a fresh
whole-repository or hosted-CI audit. Rewrite it after the next body of work.

The [previous reconnect handoff](next-2026-10-22-before-live-profile.md) is
preserved. Its pending-merge instructions are outdated: GitHub now confirms
[PR #1069](https://github.com/Roasbeef/loom/pull/1069) merged at `68034bd1a`.
The installed server and client both identify `3cf6bdc09`, which contains that
merge. The rest of the previous handoff's detailed validation is historical
and was not repeated here.

## Where the tree is

| Work | Verified state |
| --- | --- |
| Live terminal | Pickglass census, CPU and cumulative allocation captured from PID 28061 on OTP 29. The user reported Ctrl+G CPU spikes during the switch. |
| Terminal patch | Layout avoids unused activity labels. Image discovery rejects ordinary text before grapheme conversion and measures span widths only after finding a marker. |
| Fixture evidence | The 120-column Ctrl+G fixture uses about 18% fewer reductions and 12% fewer heap words with identical expanded/collapsed cells. Forty ordinary styled rows use 94% fewer reductions and 97% fewer words for image discovery alone. These are disposable fixture measurements. |
| Validation | Full TUI gate exited zero with 1,563 tests. Independent source review found no actionable issue. No hosted CI was run for this patch. |
| Live daemon | Native observation averaged 5.71% of one core over 30.138 seconds; RSS ranged 542–579 MiB. No function-level attribution was obtained. |
| Daemon Pickglass access | Updated Pickglass supports TLS. The observed local ledger has no tool grant; local authority and attach files were absent. Known-peer checks found no usable verified authority access. |
| Delivery | Local commits only. Both installed processes remain on their original code; live savings are unmeasured. |

The [resource report](review/loom-resource-profile-2026-10-22.md) records
provenance, ownership paths, repeated measurements, limitations and local
artifact names. The image regression checks both protocols after wide and
combining text and a marker prefix followed by ordinary text.

## What to do next

1. Complete daemon profiling. **Exit:** locate the deployment authority or an
   existing supported tool grant, enroll through `loomd distribution attach-file`
   if needed, then obtain a Pickglass census and CPU sample before choosing
   daemon code to change. Updating Pickglass supplies transport support, not
   a new deployment grant. Do not infer a memory leak from the native cuts.
2. Publish or install the terminal patch when requested. **Exit:** validate
   hosted CI for the exact published head, and compare the same live Ctrl+G
   workload after an authorized client update. Local fixture improvements
   alone are not installed CPU or RSS savings.
3. Revisit remaining transition work only with a matched measurement.
   **Exit:** distinguish transcript projection, JSON previews, buffer painting
   and terminal diff costs before introducing retained caches or other
   machinery. These paths were sampled and left unchanged.

## Rulings retained

**Measure distinct memory properties.** Cumulative heap allocation, process
capacity, binary memory, RSS and physical footprint answer different questions.
The resource report and `skills/beam-memory-review/SKILL.md` describe the cuts.

**Use the deployment's supported tool identity.** Protocol 096 defines the TLS
attachment and revocation path. No alternate trust path was introduced.

**Render only the text a caller needs.** A liveness check reads a phase; a
visible activity label retains its full formatting. Image recognition still
validates complete marker spans and their terminal-cell positions.

## How to verify

```sh
bash scripts/check.sh tui
make doc-check
bash scripts/tui_perf.sh . candidate render 120 40
```

The full package gate needs process inspection and loopback networking. The
sandboxed run failed five bootstrap/process-identity tests because `/bin/ps`
was blocked; the unrestricted rerun passed all tests. The standalone Ctrl+G
comparison advances the fixture clock by 50 ms before each toggle, otherwise
frame pacing can reuse a stale frame. Gate exit codes and artifact names are
recorded in the report. See `docs/execution.md` for the remaining hazards.
