# Current handoff

Baselined October 11, 2026 against main
`4417fdb6a073865660bf029495a9ecf08bc9e315` and the tool-latency source candidate
`a6a1f6598`. Work is on `perf/tool-latency` in the isolated `5086/loom`
worktree. The installed daemon has not been changed.

## What moved

The previous edition described distributed runtime PR #923 as awaiting merge.
It merged as the main baseline above on October 11. Its production boundary is
`runtime/effects.ToolSurface.run`: the orchestrator owns sessions, SQLite,
providers and approvals; the executor owns the whole workspace plane, including
its broker, jailed commands, jobs, LSP and code mode. The optimization below
uses that shared plane rather than a per-command remote broker interface.

The previous latency section was benchmark-only and left full `bash` Auto
completion unmeasured. We now have both benchmark layers:

- `make bench-tool-latency` measures real broker/helper/jail execution with
  platform enforcement, cold/warm commands, response sizes and phase samples.
  The [October 9 report](review/tool-latency-2026-10-09.md) records its two
  macOS runs, with warm medians of 18 to 23 ms.
- `make bench-tool-roundtrip` brackets real shell calls at the scripted
  provider through shipped local and TLS distributed daemons. The
  [October 11 report](review/tool-completion-latency-2026-10-11.md) and its raw
  samples record tiny-call medians of 95 to 51 ms locally and 99 to 52 ms
  distributed; a 200 ms command falls from about 403 to 406 ms to 261 ms.

Production positive waits now use `jobseam.production` and
`jobs.await_completion`. Each watched live job lazily owns one linked weft
actor. Terminal processing attempts the fact write before stopping that
witness. The caller monitors it and rereads the authoritative state on DOWN
or timeout. There are no retained waiter subjects. The shared workspace plane
selects the same constructor on the local daemon and distributed executor.
The injected-clock `door` and `await_job` remain available to simulations.

## Verified scope

The final focused job run passed all 57 tests. It checks ownership, pending
output and cursors, blocked terminal persistence and owner death with a
confirmed subscriber. Both real shipped benchmark workloads passed on local
and TLS placements. A five-second Pickglass capture completed against a
disposable candidate node; sampled processes were predominantly waiting.
Independent review found no reachable correctness defect, and two test-claim
observations were corrected before the focused rerun. Package lint passed;
the documentation citation moved with the source.

Full repository and exact-head hosted/Linux gates are distinct from those
results. Their latest status is on the feature branch/PR and under
`build/signoff/`; do not infer green from an earlier source candidate or this
handoff. Run `make check` and, after pushing, the prescribed
`LOOM_SIGNOFF_HOST=gilgamesh-signoff make signoff-remote` for the current SHA.

## Rulings and limits

No tool schema, frozen interface, distributed protocol, durable job format or
jail enforcement was changed. Completion means the existing runner's weft
outcome was processed. A dead witness is never a successful result. The
existing commit path still updates memory after a failed persistence attempt;
the wake preserves write-attempt ordering, not successful durability during an
owner failure.

The latency table is one Mac with loopback TLS and twenty warm observations
per row. The delayed candidate overlapped the full gate and has a distributed
tail outlier; it is not a production SLO. Linux latency, cross-host RTT,
contention, large transcripts, code-mode compilation and provider inference
remain separate measurement work.

Read [distributed architecture](architecture/distributed.md),
[the setup guide](distributed-setup.md) and
[protocol-change/078](../protocol-change/078-distributed-runtime.md) for the
shipped system. Its earlier handoff recorded limitations around reattachment,
imported-session movement and extension/MCP support. This performance task did
not re-audit or close those limits; consult the current code before treating
those historical notes as an up-to-date issue list.

## Next measurements

Repeat both benchmark layers on Linux and across physical hosts, preserving
all samples and enforcement reports. Attribute any remaining response time on
one clock before changing storage, transport or code-mode startup. Keep
profiling runs separate from timing comparisons, and keep every checkout and
capability socket outside `/tmp`.
