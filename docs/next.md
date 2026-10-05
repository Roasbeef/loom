# Current handoff

The active follow-on is state-preserving component upgrades under
[protocol 069](../protocol-change/069-state-preserving-component-upgrades.md).
Weft's actor and state-machine migration primitive is merged in
[weft #18](https://github.com/Roasbeef/weft/pull/18), commit
`f076c0661518ce9432cc6ff874b1ece71edbd9b7`. The integrated dependency passed
198 tests, warning-free build, lint and documentation checks; independent
Astra review of the upgrade implementation found one scheduling-dependent
test, corrected and rechecked before merge. Those tests establish callback
migration, not actual loading of new BEAM modules.

Loom now implements two state-preserving upgrade paths: approved authored
extensions inside the existing jailed satellite, and reviewed scratch-component
artifacts inside the harness VM. Both load newly compiled BEAM, retain populated
actors and migrate callbacks with state. Their artifact authorities remain
separate. The implementation and contract are described in
[live upgrades](architecture/live-upgrades.md).

The core scratch slice passes nine focused native tests, independently rerun
with newly compiled BEAM, queued work, current-state downgrade and owner-loss
cleanup. Astra reproduced delayed Arm admission, delayed slot acquisition and
a lost slot confirmation acknowledgement. Token-scoped cleanup now survives
uncertain admission, and confirmation is idempotent without releasing a newer
reservation. All three regressions plus stale-token isolation pass; Astra's
correction recheck found no further core findings and also exercised stale
change-code rejection during a later suspension.

The real jailed-session fixture passes seven separately authored, tested and
approved candidates. It retains the actor PID and original native helper while
observing new behavior, migration refusal and timeout, incompatible downgrade,
nonterminating definition refusal and hook-boundary refusal. A separately owned
code-mode job spans the successful upgrade and failure cases. Current-state
rollback retains all eight increments, and session closure proves native helper
retirement. Four controller tests separately inspect a queued invocation and
exercise real system operations with missing acknowledgements; each explicitly
retires both original fixture actors.

Astra independently verified seven production corrections: fresh compiler
budgets, literal-table atom accounting, callback result bounds, uncertain
catalogue reconciliation, suspension and resumption custody, bounded definition
evaluation, and fixed hook subscriptions. Its focused actor/runtime, parser and
client lifecycle gates pass. A lost resume acknowledgement retries resumption
without applying a second migration over already completed work. The reviewer
also found an overly short test lease and incomplete fixture retirement; both
are corrected, and the full extension gate passes all 49 tests.

The offline seed vendors the merged Weft revision. Its macOS standalone
network-namespace probe is unavailable; actual jailed source compilation runs
in the production fixture. No official scratch release artifact has been
published and no installed user daemon was upgraded by these tests. The full
local `LOOM_EVOLUTION_E2E=1 make check` gate passed with 2,934 client tests,
1,231 TUI tests, conformance, native Go tests and zero house-lint errors. The
fixture-retirement correction passed the full 49-test extension suite afterward.
Formatting and documentation checks pass. After rebuilding the final seed,
`make e2e-evolution` passed all four production fixtures again, including the
seven-candidate live upgrade test in 17.1 seconds. Hosted and independent Linux
release verdicts must still cover the pushed head.

The governed self-extension implementation is in
[PR #824](https://github.com/Roasbeef/loom/pull/824), on `runtime/self-extension`
in `.worktrees/self-extension`. It implements the production loop tracked by
[#807](https://github.com/Roasbeef/loom/issues/807). The topic started at #805
(`45218983064f1ddb462a4c6d27b01e2a31ac90ea`) and incorporates main through
`5ef1e52b44917c67aa68c1fe4efc38ca9ccf6769`, including credential kinds, web
session creation and subtitles. It is not represented as merged or released.
The previous handoff's #768 baseline and hosted-run snapshots were older than
this work's starting tree.

## Delivered behavior

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

The earlier full local gate, `LOOM_EVOLUTION_E2E=1 make check`, passed on the
integrated tree at `c95200351f2b`, including 2,916 client tests, 1,231 TUI tests, native
Go tests and house lint with zero errors. All three production lifecycle
fixtures ran. Documentation checks also passed. These checks used scripted
HTTP; they do not measure commercial-model quality, cache effects or isolated
activation latency. Later documentation and portable test changes require
their own current-head verdicts.

A subsequent real Program fixture opens two production sessions with separate
state and the same canonical workspace catalogue. The second discovers the
first session's selected program, invokes fresh input, and proves its own
stricter protected-directory policy governs effects. Both native retirements
and the helper census are checked.

Linux validation exposed two reachable defects after that local baseline:
Landlock gave valid file roots directory rights, and concurrent catalogue
borrowers could receive an immediate held-lease refusal. The corrections
classify rules in the current jail view and bound pre-open lease admission.
Admitted work and cleanup run once; transition expiry is checked again before
a new CAS, while an exact committed receipt remains recoverable. New kernel
and ownership regressions cover both paths. Do not carry the older local
verdict onto these corrections; use the final exact-head PR checks.

Astra's independent review found five reachable issues: trial policy inheritance,
unknown attempt spend, durable selection deduplication, cleanup continuation
ownership and the advertised prompt-evaluation schema. Each was verified and
corrected; a fresh correction review found no further source-verified reachable
problems. Generated Erlang also confirms that resident validation and scoped
memory closures now retain only their needed capabilities.

Use [the PR's checks](https://github.com/Roasbeef/loom/pull/824/checks) for current
hosted and exact-head platform verdicts. A local macOS pass cannot establish
Linux kernel enforcement or measured model quality.

## Current validation blockers

Hosted run `37257455225` on `c95200351f2b` passed every component job and the
Linux aggregate gate. The macOS aggregate rejected two undeclared helper-test
skips whose evidence readers were Linux-only. The portable correction observes
Darwin process metadata and the original helper port, then tests conservative
retirement refusal and retained pool custody. Linux keeps its descendant-death
and timestamp assertions. The corrected broker gate passes all 400 tests
locally without skips. At `0185cba3954c`, hosted Linux and macOS aggregate
gates both passed, including the corrected broker coverage. The new native
upgrade work requires new exact-head verdicts.

Independent Linux signoff on `c95200351f2b` passed all six test lanes and the
strict skip census. Its shipped `update-release-smoke` check timed out while
the native installer copied the staged server release. The test host's home
filesystem was full, making disk pressure the leading explanation; the cause
is not proven until the fixture is rerun with free space. `signoff/linux` is
therefore red for that old head. A fresh read-only check now finds 206 GB and
ample inodes free; the previous cleanup request is no longer needed and no
directories were deleted by this task. Run independent signoff on the new
pushed head. Do not waive the release check or raise its deadline to obtain a
green verdict.

The evolution architecture now includes the ownership map, activation sequence,
operator payload examples, failure responses and acceptance fixtures. Ten
existing package READMEs explain their part of that boundary. This work adds
modules within existing packages, not a new package.

## Rulings to retain

Authored execution stays outside the trusted harness VM. The resident-loader
proposal in #30–#32 is superseded by #807; #100's pi-compatibility scope was
closed. Native core artifacts still come only from reviewed releases; the new
scratch controller may load those artifacts in place. Agent-authored revisions
never cross that authority boundary. Existing TCB freeze tests remain gates.

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

## Verification and merge boundary

The PR must satisfy the repository's current hosted gates and `signoff/linux`
on its exact head before merge. The owner controls merge and the public release.
Do not carry a green verdict from an older head or treat a queued receipt as a
published generation. The Linux signoff runs the shipped-daemon fixtures and
strict enforcement/skip census as well as these evolution tests.

To reproduce the production fixtures locally, use the runtime compiler and an
offline seed built by that same compiler:

```sh
PATH=/Users/roasbeef/.local/lib/loom/server/bin:$PATH make codemode-seed
PATH=/Users/roasbeef/.local/lib/loom/server/bin:$PATH make e2e-evolution
LOOM_EVOLUTION_E2E=1 PATH=/Users/roasbeef/.local/lib/loom/server/bin:$PATH make check
make doc-check
```

Capture each command's own exit status. The seed fingerprint must match the
runtime compiler; a cold dependency rebuild under a private HOME must not reach
Hex. Protected-content assertions require a successful public read, existing
nonempty native targets, zero protected bytes and the platform's exact mask
outcome. Generic process failures do not count as isolation evidence.

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
