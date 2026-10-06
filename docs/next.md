# Current handoff

This edition covers explicit configuration hot reload on
`codex/config-hot-reload`, rebased onto main `92df4a413` after PR #889 merged, on October 6, 2026
(America/Los_Angeles). The original source commits were `453551935`, `a4f09ef29` and `887a2877c`;
rebased source commits are `9682a663f`, `2f69e89f2`, `6e97ed3c2` and `05af94f3e`.
A source-only range comparison verifies the reviewed patches are unchanged.
The original checkout and its unrelated untracked files were preserved.
PR #901 is published. Final-head Linux signoff is the next authorized step.
This feature has not been merged or installed.

The preceding edition described the October 5 CPU integration and PR #873.
Its measurements remain in [the investigation](review/beam-cpu-2026-10-05.md).
Its PR, CI and installation status were not reverified for this feature and
must not be read as current signoff for this branch.

## Where the tree is

A session with an explicitly selected configuration watches the selected real
path. Environment-only startup watches nothing. Initial selection, regular-file
reads and validation are bounded; malformed, missing and oversized saves retain
the last valid publication. Atomic replacement is supported. Original symlinks
cannot retarget the trusted source after selection. The sandbox protects the
same resolved path the watcher reads.

`client/config_reload` owns publication and operation pins. The first
operation-scoped fetch captures a `wiring.ModelRevision`, including routing,
model facts and operation hooks. Provider generations, retries, admission,
compaction and context use that pin until durable completion. Hub listings and
by-name selection read publication; new children independently select their
current model choices. Existing strand identities and thinking selections stay
durable rather than being silently rewritten by file edits.

Model additions and supported facts reload live. Removals, renames and model-id
changes retain the entire preceding model revision and report `models` as
restart-required. Tools, credentials, daemon limits and background service graphs
remain boot-owned. Every accepted save reports changed boot-owned sections in
`config.reloaded.restart_required`; model/role edits report `background-models`.
[Model configuration](architecture/models.md#live-file-edits) gives the behavior
of each setting.

The summarize actor keeps its boot endpoint. Live observation uses the
operation's catalogue and actual summarize descriptor. Stored assistant messages
lack endpoint history, so provider names whose service descriptor changed cannot
admit settled or on-demand summaries until restart, including after a revert.
The configuration holder is a fatal root and retires after runtime drain, before
the tool holder, through the existing custody part.

## Validation

The real HTTP/helper regression in `client/serve_test` passes on `a4f09ef29`:
an active operation makes its later generations and context read under the old
revision, the next operation uses the new endpoint and output ceiling, and
malformed saves, atomic replacement, deletion, restart notices and retirement
are observed through production assembly. Four `config_reload_test` regressions
pass, including validator timeout, operation pins, alias retargeting and a FIFO
with no writer. The live-catalogue selection and summary-history regressions
are included in the client suite.

A fresh independent advisor review found a mutable-alias trust problem and an
unbounded startup read. Both were corrected, independently rechecked and covered
by the focused regressions. The review approved the source subject to execution
of the final gates. Client lint has zero errors. Documentation coverage, mirrors
and citations pass after refreshing source-line citations displaced by this
change; existing warnings remain visible.

Three mutation controls each fail exactly one intended regression while the
other three watcher tests pass: extending the worker deadline, discarding
operation pins and retaining the unresolved source alias. Restoring the source
returns all four tests to green.

The final full `make check` returned its own exit 0 on `887a2877c`: 2,952
client tests, 1,241 TUI tests, 97 conformance tests and every other package,
static and Go gate pass. Final lint has zero errors and 2,176 warnings.
`make doc-check` separately returns 0 with zero errors and 195 warnings before
this evidence commit; the post-commit check must verify this edition as well.

The initial attempt hit the existing 20-second script-test deadline. A later
run exposed two shared-domain diagnostic assertions; the path compatibility
fix is included in the final source. Existing tests and deadlines are preserved.
The Darwin full gate retains its declared prerequisite skips, including the
shipped-server fixtures and unavailable Linux enforcement observations. Hosted
CI and Linux signoff have not run for this unpublished branch.

## Rulings and limits

Read the explicit file once for both initial bytes and source selection; never
assemble from one read and pretend a second read was the same initial revision.
Do not infer operator authority from an implicitly discovered workspace file.
Collect pins from durable `op_state` absence, never from `run_end`, which can
precede the durable completion transaction. A vanished holder refuses dispatch
and shares failure with the session rather than selecting a newer configuration.

Production dispatch still refuses deferred polls and machine-generated
compaction summaries. The resolution hook has no operation identity; supporting
those paths requires extending that boundary before routing them dynamically.
Background actors and executable tools are intentionally not rebuilt in place.
A role edit still obeys role-follows-identity; choosing another main model is an
explicit durable selection, not an implicit rewrite.

## What to do next

A second adversarial review identified remaining startup reads, active context
inspection using publication, a timing-dependent reload regression and stale
role-chain prose. The fixes use bounded reads in daemon and domain startup,
capture active operation metadata with the context cut, wait for publication
before releasing the provider response, and correct role documentation.

Focused validation passes: nine context tests, six daemon diagnostic tests and
the real provider reload test. Compiling mutations fail the new startup and
context assertions, and restored source passes. The bounded adversarial recheck
clears all four findings. PR #901 is published as a draft.

The first Linux signoff was canceled after PR #889 merged and changed the base.
The rebase conflicts were documentation citations and the preceding handoff;
source patches compare identically. Run final-head Linux signoff before marking
PR #901 ready. Preserve the original checkout. Merging and installation remain separate steps.
