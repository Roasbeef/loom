# Async execution and durable collaboration

**Status**: implemented, locally verified · **Date**: 2026-09-21 · **Relates to**: #107, #382

The implementation starts at `543d641afec0fb3563a68cb664f0791c29efc8ae`.
The requested scope is async code mode, peer and cross-session messaging,
and the core workflow lifecycle, with the terminal presentation deferred.

## Boundaries

**Execution ownership, permission to communicate, and workflow dependencies
are separate relationships.** Existing descendant joins remain downward.
A peer grant permits messaging without transferring cancellation, joining,
filesystem access, or the operator's authority.

An async execution retains its launching operation, a distinct execution
step, captured grants and policy, and a fixed deadline. Its launching tool
call may finish while the execution remains alive. Later interactions carry
data, never replacement source, code, authority, or a renewed deadline.
Arbitrary workspace effects remain non-replayable. Recovery reports a lost
volatile execution explicitly instead of restarting its program.

Async execution reuses the jobs lifecycle instead of adding machine phases.
A reserved fact records the execution while a session service manages its live
processes.
The extension satellite is also already persistent, but its per-invocation
token rotation is inappropriate for an execution whose actors stay alive.

Durable workflow steps name their inputs, program version, child operation
and result. Recovery reconciles those operations. It does not journal and
replay arbitrary capability effects: a crash after an effect and before its
journal write would still repeat the effect, and actor scheduling is not
deterministic merely because the source is Gleam.

## Delivery

The recipient's writer commits a message and its deduplication claim in one
transaction. A stable message ID makes a lost acknowledgement recoverable;
reusing that ID for different content is refused. A receipt proves admission,
not model consumption or task completion. A doorbell remains an optional
latency hint.

Cross-session delivery requires an operator-owned directional grant, with
waking idle work a separate permission. It addresses an explicitly exported
strand of a resident session. Saved sessions remain saved. Discovery includes
identity, workspace, observed branch, lifecycle, purpose and activity. A
model-written description is identified as a claim. Provenance is supplied by
the harness rather than parsed from the sending model's text.

## Execution order and acceptance

1. Record the async lifecycle and implement launch, input, inspection, bounded
   join, cancellation and restart loss, including the model and capability
   surfaces. Preserve the default synchronous code-mode path.
2. Give async orchestration children explicit execution custody. Ending the
   launching turn must neither reap them early nor permit later children to
   escape cancellation. Serialize admission so concurrent programs cannot
   exceed the existing live-child bounds.
3. Implement explicit same-session peer communication and resident
   cross-session routing, operator grants, discovery, provenance and receipts.
4. Implement named durable workflow steps and selective recovery over child
   operations. Keep workflow input and source identity explicit.
5. Exercise the production wiring with deterministic providers, real stores
   and real jailed satellites. Test lost doorbells, lost acknowledgement,
   recipient restart, child failure, owner completion and cancellation during
   an effect. Run the required package and complete gates, then independent
   adversarial review and documentation checks.

No terminal redesign, saved-session outbox, cross-machine transport, arbitrary
effect replay, token rebinding, or deadline renewal is part of this change.
The local implementation and regression evidence are recorded below. This
work still requires hosted CI and Linux verification at the proposed head.


## Review corrections

Independent review found two concrete cleanup/publication gaps and one stale
link failure. Original async child operation identity now commits with the
brief, before lineage publication. Reaping a child now fences its delayed
background launches, and enclosing execution settlement includes nested
backgrounds. Launch checks abort-fence absence atomically with record creation.
A deleted peer remains one unavailable roster row without preventing discovery of
other peers; outgoing authority can be removed without reopening the target.

The workflow implementation records named child-operation identities and
reuses existing durable results. Explicit new step names select retries; it
does not attempt deterministic replay of arbitrary capability effects. Git
discovery exposes timestamped activation observations. These are deliberate
limits, not claims of live branch tracking or persisted actor heaps.

## Local validation

The full gate passed through 2,046 client tests and 609 TUI tests, with 306
code-mode tests. It then caught an unmigrated simulation assembly callback;
adding its unused directory argument was the only code correction. The remaining
conformance, lint-package and sandbox stages passed in a resumed gate, including
83 conformance tests and real jailed end-to-end and crash-recovery fixtures.
The final house lint passed with zero errors and 838 warnings. Documentation
checks passed with zero errors and 154 existing warnings.

New regressions exercise real kept-alive typed actors, real jailed named-step
orchestration, two independent SQLite peer sessions through the production
directory, deduplicated delivery, saved-session refusal, grant revocation,
immutable original child identity, restart loss, nested background cancellation,
and atomic launch admission against an operation abort fence. Independent
adversarial review verified the cancellation and publication repairs. The original
full-gate invocation stopped at the callback compile error; the resumed stages
and final lint supply the remaining evidence. Linux execution and hosted CI at
the proposed head remain outstanding.
