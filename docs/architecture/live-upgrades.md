# State-preserving component upgrades

A component upgrade changes the code serving an existing actor while retaining
its PID, mailbox and current state. The surrounding session continues running.
An extension counter that reaches seven before an upgrade, then handles three
more increments, must still hold ten after a downgrade. Restoring its old
snapshot would lose acknowledged work.

[Protocol 069](../../protocol-change/069-state-preserving-component-upgrades.md)
defines this contract. The implementation on the runtime evolution branch
provides both upgrade paths below. Its acceptance tests and final verification
record determine which release claims are established. It builds on
[governed runtime evolution](evolution.md), which already retains source,
records author-test evidence and requires native approval before selection.

## Two code-loading boundaries

| Component | Source authority | Execution location | State owner |
| --- | --- | --- | --- |
| Opted-in extension | Captured, vetted source with exact test evidence and native approval. | Existing kernel-jailed satellite. | Extension actor with bounded JSON state. |
| Reviewed scratch implementation | Exact manifest and module digests from a Loom release. | Harness VM. | Existing session scratch actor with a fixed typed ABI. |

An extension approval never authorizes code inside the harness VM. Conversely,
a core upgrade accepts a release identity and manifest digest, not authored
source, an extension candidate ID or a local BEAM path. Both paths use weft's
state and callback migration primitive, but their artifact authorities remain
separate.

Loading a module alone is insufficient. An actor's retained callbacks and state
must move together, and queued messages must still have the meaning expected
by the successor. The component contract therefore fixes the message boundary,
identifies the current state representation and declares supported migrations.
A refused migration leaves the previous state and callbacks installed.

## What weft owns

Weft's actor and state-machine builders can opt into an upgrade callback. While
the process is suspended, the standard system-message handler passes a
`weft/upgrade.Request` and current state to that callback. The callback returns
one migration value containing replacement state, handlers, selector and the
callback for future upgrades. Weft installs that value together.

Migration preparation runs under a bounded managed task. Rejection, a crash or
expiry keeps the old actor configuration. Callbacks must perform pure state
conversion: a timeout can discard a result, but it cannot undo an external
effect. The controller retains responsibility for resuming the process after
both successful and failed preparation. The bound is a scheduling deadline,
not a hard real-time guarantee during VM or operating-system suspension.

Weft preserves the actor's runtime identity and queued traffic. Loom supplies
the code loader, artifact authority, component compatibility checks and
operator receipts. The library's migration tests alone do not establish that
a running Loom session loaded new code.

## Jailed extension transaction

The optional `[live]` manifest table names a live entry point, migration module,
message boundary, state version, accepted source versions and finite pause and
state-size limits. Existing manifests retain their replacement behavior. The
live entry point returns an `ext/live.Definition`; its handlers receive and
return JSON state through a typed extension request and answer boundary.

The installer checks the migration module's transitive import closure for
purity. Native preparation compiles the approved source into the inactive one
of two fixed module namespaces. Reusing a finite set of names bounds module
names across repeated upgrades. Function and constructor atoms need a separate
cumulative budget, checked from the BEAM bytes before loading can intern them.
The satellite admits at most 4,096 distinct names occupying 128 KiB, including
reservations for failed loads. Both readers include atoms nested in compressed
literal tables. Bounded inflation checks actual output against the 8 MiB ceiling
before a pure byte parser walks the terms; no term decoder interns names during
inspection. The host and satellite walkers are byte-identical and gated by a
parity test. The trusted satellite loader verifies module identity and bounds
before an atomic load. It refuses an occupied code slot
rather than force-purging a process that still references it.

Every compilation obtains a fresh execution identity and budget, even when the
session has been running longer than an earlier build deadline. The fixed live
boundary also preserves hook subscriptions and capability policy; an incompatible
change is refused explicitly. Authored definition evaluation, callback results
and migrations are bounded, and every installed state document passes the same
JSON and byte-limit validation.

The extension controller prepares the migration before publishing the selected
generation. During this unpublished interval, ordinary calls cannot reach the
candidate state. If catalogue selection fails, the controller can compensate
with the retained pre-transition state because no new work was admitted.
After publication, rollback instead migrates the current state. Transition
identity and status distinguish a missing acknowledgement from a failed
migration; retrying an unknown outcome must not run the migration twice.

## Reviewed scratch upgrade

The first harness component is the session's scratch key/value store. Reviewed
implementations share its typed message and state ABI, including entry limits,
byte accounting and write order. Diagnostics report implementation identity
and aggregate state counts without revealing stored values.

The builtin implementation remains available. The
[reviewed artifact recipe](../../packages/client/src/client/upgrade/README.md)
shows the fixed exports and manifest used to build a component release. Two additional module slots are
shared across the VM. A native slot owner tracks the actual actor PIDs using
each slot. Multiple sessions may share identical bytes; a different artifact
cannot replace a slot while another actor still uses its implementation. This
prevents an upgrade in one session from silently redirecting another session.

A supervised control actor accepts native owner requests and returns a queued
receipt. Artifact resolution and loading occur before the scratch actor pauses.
A surviving custodian owns suspension and resumption, even if the requesting
CLI disconnects. The operation carries an expected identity, fresh transition
token and absolute deadline so a delayed system request cannot act as a new
upgrade during a later suspension.

The owner commands use the existing authenticated evolution connection:

```sh
loom evolution core_status SESSION
loom evolution core_upgrade SESSION --args upgrade.json
loom evolution core_status SESSION --request-id scratch-upgrade-1
```

`upgrade.json` contains:

```json
{
  "request_id": "scratch-upgrade-1",
  "component": "scratch",
  "expected_version": "builtin",
  "expected_digest": "builtin",
  "target_release": "<reviewed release tag>",
  "manifest_digest": "<exact manifest SHA-256>",
  "pause_ms": 1000
}
```

Use the current observation for the expected fields. A queued receipt confirms
admission; query `core_status` with the same request ID to learn the outcome.
Reusing that ID with different arguments refuses. A control actor retains at
most 64 request records and refuses further admissions once full; existing
receipts remain readable. `pause_ms` accepts 400–1,000 milliseconds. Download
budgets are separate from the component pause. `core_downgrade` uses the
same fields and current-state migration rule. The shipped implementation is
selected with both `target_release` and `manifest_digest` set to `builtin`.
`loomd evolution` exposes the same actions.

## Acceptance evidence

The complete release demonstration must load code compiled after the target starts,
retain a populated actor's PID and session identity, and observe new behavior
through ordinary requests. Another component must answer during the pause,
with an overlapping jailed code-mode job completing. Failure cases cover
migration rejection, crash, timeout and incompatible downgrade.

The downgrade test must first perform work under the upgraded implementation,
then queue additional work during the transition and establish that both are
retained. The trusted controller tests inspect the actual suspended mailbox and
execute real system operations before withholding their acknowledgements. Session retirement must finish with the existing native worker-drain
checks. These observations establish partial component upgrades; they do not
claim arbitrary module replacement or a live Erlang runtime upgrade.

The focused core gate (`scripts/test.sh client --match client@upgrade_`) currently
passes nine tests, including delayed admission and lost-confirmation recovery.
Independent review also exercised an old-token system request during a later
suspension. The served-session fixture passes its seven-candidate matrix with real jailed
compilation, stable actor and helper identity, an independently owned code-mode
job spanning the upgrade, incompatible downgrade refusal, nonterminating
definition refusal, and current-state rollback. Four trusted controller tests cover queued invocation, duplicate control, expiry,
and lost acknowledgements, including work completed after a resume whose reply
was lost. Astra independently verified the production corrections and reran
the focused actor/runtime, parser and client lifecycle gates. The controller
fixtures now explicitly retire both original actors. The full integrated
`LOOM_EVOLUTION_E2E=1 make check` gate passes, as does the four-fixture
`make e2e-evolution` rerun after rebuilding the final seed. Hosted and
independent Linux release checks must still cover the pushed head; use the
PR's final commit-specific results for that verdict. No official scratch artifact has been published, and these
fixtures did not upgrade the installed user daemon.
