# Explicit live jobs observations

Status: proposed implementation of the approved live background-job roster.
Affects the client command and snapshot surface in Part 1.6.

## Problem

A completed conversation turn can leave a background job running. A terminal
summary needs that current job state without loading historical job registers on
every snapshot or confusing the operation that started a job with the operation
currently active on its strand.

## Decision

The `live_jobs` command accepts `body: {strand: String}`. A subscribed attachment
may request it as a read-only operation. The host injects a query capability
backed by the session's jobs actor. No ordinary transcript snapshot or metadata
capture invokes the query.

The jobs actor folds its existing in-memory dictionary and retains only records
owned by the requested strand for which `jobstate.is_terminal` is false. It
performs no durable prefix scan and maintains no second active-job index. It
visits historical records already held by the actor but materializes at most
`jobs.max_jobs_per_strand` rows, currently four. `total` counts all matching live
records, and `omitted` reports any excess rather than silently asserting that the
returned rows are complete.

The command returns a `snapshot` event with `mode: "live_jobs"` and `board`:

```text
{strand, observed_at_ms, jobs: [
  {id, state, started_by, command_excerpt, age_ms, deadline_ms}
], total, omitted}
```

`id` and `started_by` are strings identifying the job and its originating
operation. The state vocabulary is `starting`, `running`, and `draining`.
`age_ms` is nonnegative; `deadline_ms` is a non-null absolute session-clock
instant. A command excerpt contains at most 512 UTF-8 bytes. Clients sanitize
terminal controls when displaying it. The board is a transient observation,
not a durable job record or a claim that the job still runs when rendered.

The production capability waits at most one second for the jobs actor. A missing,
restarting, or unresponsive actor returns an `unavailable` error, never an empty
successful roster. An empty successful board is evidence that the actor observed
no live jobs owned by the strand at that instant.

## Alternatives and cost

Calling the model-facing historical listing would materialize finished jobs and
omit command and operation attribution. Reading durable history inside each
snapshot couples transcript paging to unrelated retained job history. A second
live-job index adds synchronization and recovery obligations for a maximum of
four rows per strand. The explicit dictionary fold keeps the existing actor as
the single owner of lifecycle state.
