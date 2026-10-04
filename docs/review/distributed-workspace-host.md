# Executor-local workspace host review

This component places complete filesystem operations beside one registered
checkout. The immutable invocation retains the full session/workspace scope,
physical operation and step, original tool or system provenance and reserved
request identity. It compares the complete configured scope before any path
probe, callback or mutation.

The host reuses the existing filesystem resolver, protected-path checks,
hashline landing, bounded native rendering and search implementation. Shared
read-window and fresh-anchor helpers keep local and remote projections aligned.
Stat resolves the parent and preserves the final symlink for lstat. A successful
write or edit calls the existing diagnostic observer only after landing; the
response and its diagnostic block are both part of the eventual durable result.
Unbound Git, guidance and initialization callbacks explicitly refuse service.

Independent adversarial review found no actionable defect in scope fencing,
identity propagation, filesystem semantics, diagnostics ordering or callback
projection checks. The root verification passed all 18 host tests and all 99
existing filesystem tests. The host tests include altered session, executor,
workspace and both authority epochs across every operation, with no effects
before rejection. Formatting and package lint passed.

This is a semantic host, not a custody journal or network service. The outer
service must reserve result capacity, persist exact immutable input before
mutation, retain exact response bytes before acknowledgement and reconcile
using the original identity. Existing point-in-time path and concurrent-writer
limits remain. No executor-to-owner fallback or remote FileSystem callbacks
are introduced. Remote transport and whole-system E2E remain separate gates.
