# Current handoff

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

The full local gate, `LOOM_EVOLUTION_E2E=1 make check`, passed at source commit
`b1549f045`, including 2,846 client tests, 1,228 TUI tests, native Go tests and
house lint with zero errors. All three production lifecycle fixtures ran:
extension 7.007 seconds, program 3.903 seconds and prompt 2.260 seconds. These
are whole fixture times with scripted HTTP, not isolated activation latency or
commercial-model cache measurements. Documentation checks also passed.

Astra's independent review found five reachable issues: trial policy inheritance,
unknown attempt spend, durable selection deduplication, cleanup continuation
ownership and the advertised prompt-evaluation schema. Each was verified and
corrected; a fresh correction review found no further source-verified reachable
problems. Generated Erlang also confirms that resident validation and scoped
memory closures now retain only their needed capabilities.

Use [the PR's checks](https://github.com/Roasbeef/loom/pull/824/checks) for current
hosted and exact-head platform verdicts. A local macOS pass cannot establish
Linux kernel enforcement or measured model quality.

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
