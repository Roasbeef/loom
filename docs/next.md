# Current handoff

This edition covers the governed self-extension implementation for
[#807](https://github.com/Roasbeef/loom/issues/807), on
`runtime/self-extension` in `.worktrees/self-extension`. Its pinned base is
`45218983064f1ddb462a4c6d27b01e2a31ac90ea` (the #805 merge). GitHub `main`
was `5ef1e52b44917c67aa68c1fe4efc38ca9ccf6769` when checked on 2026-10-04;
this topic is not represented as landed. The previous handoff's #768 baseline
and hosted-run snapshots were older than the branch this work started from.

## Work in flight

The accepted release scenario is concrete: an agent authors an extension;
real jailed checks produce durable evidence; an operator approves it; the same
running session serves its selected behavior; rollback restores the previous
version without losing the conversation or leaking native workers.

The implementation also includes named executable workspace programs and
exact-model prompt profiles. Model-facing proposal and evaluation never convey
approval authority. Native operators can inspect, approve, select, revoke,
rollback, admit independent task fixtures and mark settled outcomes through
`loom evolution` or `loomd evolution`. These commands attach to an already
resident authenticated session. The source, authority and retirement boundaries
are in [evolution](architecture/evolution.md) and
[protocol-change 068](../protocol-change/068-runtime-evolution.md).

The implementation PR and final exact-head gates are still being prepared.
Focused provider checks passed all 261 tests, and the code-mode package passed
all 355. All three real lifecycle fixtures passed against scripted HTTP and
actual production tools, including repeated extension replacement, native helper
retirement and the protected-source read regression. Astra's independent review
found five reachable issues: trial policy inheritance, unknown attempt spend,
durable selection deduplication, cleanup continuation ownership and the advertised
prompt-evaluation schema. Corrections and fresh validation are in progress.
These are local results, not platform signoff or measured model-quality evidence.

## Rulings to retain

Authored execution stays outside the trusted harness VM. The resident-loader
proposal in #30–#32 is superseded by #807; #100's pi-compatibility scope was
closed. The native core and capability backends still change through ordinary
reviewed releases. Existing TCB freeze tests remain gates.

Candidates retain immutable source and native provenance. The catalogue uses
existing generated SQL storage transactions and reserved FactCustom namespaces;
there is no handwritten SQL or new storage schema. Whole source and evidence
inspection is paged within the existing control frame. Callable discovery keeps
complete schemas and exact candidate/generation tokens.

Selection is a full generation-fenced CAS, including approval and revocation
sequences. Its central commit is irreversible; the separate session adoption
audit is idempotent and recoverable. A queued receipt is not publication. Once
selection commits, an expired caller wait cannot discard the selected version.
The exact request ID resolves a missing acknowledgement.

One live owner serializes the promoted hook/tool fold with replacement. Native
executor/helper retirement, rather than a BEAM exit or satellite report, is the
publication boundary. Unconfirmed cleanup retains custody and blocks further
allocation. Legacy session teardown has one physical host owner and reports its
actual result; an exited host cannot fabricate a successful retry. Daemon
sessions keep their existing custody owner.

New sessions pin selected prompt maps. Resumed sessions keep those immutable
bytes. Profiles compose after the actual provider/model/API resolves on every
attempt, with the unchanged base request on retries. Independent evaluation
runs ordinary coding operations in fresh native fixtures, with admitted exact
file criteria scored after retirement. Scripted responses exercise mechanics;
they do not certify model improvement, noise handling or holdout quality.

## Finish this lane

Verify all three real lifecycle fixtures with the runtime compiler and an
offline seed built by that same compiler:

```sh
PATH=/Users/roasbeef/.local/lib/loom/server/bin:$PATH make codemode-seed
PATH=/Users/roasbeef/.local/lib/loom/server/bin:$PATH make e2e-evolution
LOOM_EVOLUTION_E2E=1 make check
make doc-check
```

Capture each command's own exit status. The seed fingerprint must match the
runtime compiler; a cold dependency rebuild under a private HOME must not reach
Hex. The loopback tests and native scratch paths require the usual permitted
host test environment. Inspect the skip census and obtain Linux signoff on the
exact pushed head; a local macOS pass cannot establish Linux kernel enforcement.

Run the independent Astra adversarial review, disposition reachable findings,
and create one PR with the actual validation record. Attach it to the task.
Do not merge on the user's behalf. Rewrite this handoff with that PR and the
final exact-head results before delivering the work.

## Deliberate limits and next work

[#236](https://github.com/Roasbeef/loom/issues/236) remains open. The trace door,
operator outcomes, fixed paired evaluation and durable evidence are implemented;
multiple-candidate search, GEPA/Pareto selection, noise handling and holdouts
need live model evaluation and their own design. No automatic promotion,
family-wide profile inference, runtime dependency download or implicit extension
state migration is introduced. Rollback restores implementation selection, not
external filesystem or network effects.

The catalogue's retained-envelope budget does not cap its append-only lifecycle
journal. Trace scrubbing is heuristic and can retain short unlabelled secrets or
private prose. Failed legacy native retirement conservatively refuses; resumable
multi-phase retirement after that host exits remains unsupported. These limits
must remain explicit in the implementation PR and architecture documentation.

The pre-existing terminal, web workspace, executor and release work remains in
its own architecture pages and issues. Refresh GitHub before choosing the next
lane instead of carrying forward the previous handoff's dated open-PR and CI
lists. The repository owner cuts the public release.
