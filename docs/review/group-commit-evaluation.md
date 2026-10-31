# Group commit evaluation

Issue: #1152. This is an evaluation, not authorization to implement group
commit.

## Recommendation: defer

There is not yet a representative measurement of concurrent strand appends
on Loom's file-backed SQLite store, nor a measurement of a group-commit
implementation. Defer implementation until the corrected benchmark has run
under suitable host conditions and a runtime workload establishes whether
concurrent commits are common enough to matter. Elapsed time alone cannot
identify sync wait, CPU or device cost; no speedup can be inferred from it.

The first benchmark run used a new root for every message rather than
appending to each strand's prior leaf. Its numbers are therefore superseded,
not evidence for typical strand persistence. Its raw file is
`.codemode/tmp/loom-commit-cost-monotonic.csv` in this worktree. An earlier
exploratory wall-clock run also emitted a transitive-dependency warning; its
raw file is `.codemode/tmp/loom-commit-cost-raw.csv`. Scratch files are local,
not committed fixtures.

The host was reported above load 120 on 16 CPUs during the corrected smoke
run. A full measurement under that load would not support a useful
comparison, so it remains pending. The smoke run is correctness-only; its
timings are not performance results.

## Corrected workload

The corrected benchmark is `packages/runtime/dev/commit_cost_bench.gleam`.
The bounded smoke wrapper is `packages/runtime/dev/commit_cost_bench_smoke.gleam`.
From `packages/runtime`, `gleam format dev/commit_cost_bench.gleam
dev/commit_cost_bench_smoke.gleam && gleam run -m commit_cost_bench_smoke`
exited 0 without warnings. It checked two callers with three commits each on
both backends, including final branch and count assertions. The first compile
exited 1 on the helper's return type; adding an explicit `Nil` fixed it. Smoke
output and compiler stderr are `.codemode/tmp/loom-commit-cost-chain-smoke.csv`
and `.codemode/tmp/loom-commit-cost-chain-smoke-stderr.log`. The full run will use fresh memory and file-backed SQLite stores at 1, 8, 32 and
128 callers, three repetitions each, with 200 commits per caller. Each worker
reads its leaf and commits a message whose parent is that leaf, with a
CAS-guarded leaf update. Workers use Weft deadline-bounded tasks and join
before the case timer stops. After timing, the harness validates each final
leaf, entry and complete branch, and the aggregate message count; each store
closes before its owned directory is deleted. Independent keys avoid conflicts;
this is not an estimate of conflict prevalence.

The monotonic clock has millisecond resolution. Commit samples cover the
storage call, including its mailbox wait and execution, but not the preceding
read. Case elapsed time covers worker startup, reads and commits; it excludes
post-run validation. It excludes the runtime writer, model, tool calls,
subscribers and application scheduling. Cases use fixed backend order and
must disclose warm-up and run-to-run variation. No storage or writer sync
attribution was found in the existing tracing examined.

The related [register-read evaluation](register-read-performance.md) examines
read paths separately; it does not measure commit sync wait.

## Upstream and implementation boundary

The upstream group-commit design coalesces commits accumulated while one
storage call is in flight, retaining logical outcomes and publishing in order
after durability. Its simulated 4 ms round-trip and local SQLite figures are
from different systems and workloads, not estimates for Loom. Its changelog
also reports up to 25% lower in-memory throughput at zero latency. See the
[pinned design](https://github.com/earendil-works/pi/blob/35dfa757/packages/durable/docs/group-commit.md),
[changelog](https://github.com/earendil-works/pi/blob/35dfa757/packages/durable/CHANGELOG.md),
and [group-commit change](https://github.com/earendil-works/pi/commit/e5c6182).

`runtime/writer.gleam` handles each commit in one actor turn, calling storage
before publishing `Committed` and replying. SQLite `do_commit` begins an
immediate transaction, checks and renews the lease, checks expectations,
applies ordered writes, updates session metadata and commits. Each session
owns its own SQLite file.

If later evidence justifies a design, start with a bounded batch of already
queued logical transactions. Preserve actor order, checking each transaction's
expectations against the state left by successful predecessors, and retain
its own write sequences and outcome. A stale expectation leaves that logical
transaction unapplied. Lease loss and database failures must yield outcomes
consistent with what is durable; no successful acknowledgement may precede
the physical commit. Publish each successful result and reply in logical order
after durability, preserving current event ordering.

Define batch failure, partial progress, crash recovery, read interleavings and
publication semantics before choosing between savepoints, a durable prefix or
aborting a whole batch. The frozen storage interface exposes one logical `Tx`;
a batch interface requires a protocol-change proposal before implementation.
Tests must cover inter-batch conflicts, lost leases, failed physical commit,
crash after durable commit before publication, and concurrent reads and
subscribers.

## Independent integration receipt

The primary ran `gleam run -m commit_cost_bench_smoke` against the corrected
append-chain workload on memory and file-backed SQLite (exit 0). Output is
retained in `.codemode/tmp/session-hotpath-primary/commit-smoke.log`. The
complete runtime gate, runtime lint, formatting, documentation and prelude
checks pass; see [the pending-entry record](pending-entry-performance.md) for
the first failed runtime attempt and unchanged clean rerun. Full timing and
a production group-commit decision remain open in #1152. No interface,
durability policy or running daemon was changed.
