# Complete-report custody model review

The existing OwnerDischarge model now distinguishes report retention, final
commitment and collection. The report profile reserves its full allowance before
the wrapper starts. Report bytes alone cannot recover a missing final message;
collection preserves those bytes and their original identity.

## Independent finding and correction

Astra found a reachable missing distinction in the first revision. An arbitrary
integer final on a report-profile row with no report could become released after
wrapper drain. Existing failure cases had fenced the row first, so they did not
exercise this path. An independent counterexample passed the old monitor for
100 schedules; a stronger observation monitor exposed the release on schedule
one. This was a gap in the model's claim, not a finding against shipped code.

The corrected model separates an exact report-reference final from a trusted
no-terminal refusal. An independent producer observes vet or compile refusal,
and the owner matches that original worker pin and stage before committing the
refusal. An ordinary final cannot authorize release on a report-profile row.
A diagnostic can still enter already-unresolved history, without clearing its
fence. This preserves the distinction between useful failure information and
permission to release custody.

Astra's corrected replay found no outstanding actionable defect. Seven focused
normal cases passed 100 schedules each. Four exact reachability probes and two
compiled guard-removal mutations reached their intended assertions on schedule
one. Root changed one assertion string afterward to say wrapper drain rather
than physical and wrapper drain; no transition or predicate changed.

## Root evidence

The complete model replay exited zero for 146 cases and probes: 67 normal
cases, each at 100 schedules, and 79 exact reachability witnesses. Ten new
report-budget, reference, retention and collection mutations compiled and failed
their intended monitors before the isolated refusal correction. On the corrected
model, the two new refusal mutations and all nine existing owner-discharge
mutations compiled and failed their intended monitors. Their controls passed.
The other previously verified mutation families were not rerun for this slice.

The report scenarios include a lost COMMIT acknowledgement followed by restart,
failed COMMIT, a wrong immutable profile, an oversized bundle, changed reference,
missing or changed session commitment, and quota pressure before and after
collection. Positive controls retain a complete maximum-size report and preserve
its charge after restart. Refusal controls admit both genuine stages and reject
unclassified or forged report-free finals.

## Implementation correspondence and limits

The trusted producer event abstracts the host renderer's actual vet/compile
refusal branch. It cannot be supplied by arbitrary program output. Runtime tests
must show that only that branch emits the closed no-terminal schema. RunStart is
the custodian wrapper, so a compiler may already have performed native work when
a compile refusal is produced. That refusal proves no native cleanup.

Report identities, digests and final-message identities are symbolic atoms.
Sizes and the 17,301,648-byte report allowance are concrete. The 34,603,296-byte
quota is a two-report fixture; the production quota separately charges request,
identity and child storage. COMMIT and drain are trusted modeled observations,
not proofs of SQLite synchronization or real managed AllDelivered behavior.

This fixture does not compose the native resource state machines. Its collection
checks establish modeled report, session and wrapper ordering. Native retirement
remains an independent production prerequisite. Canonical parsing, hashing,
authenticated chunk retrieval, physical storage growth and power loss require
separate evidence. The [model guide](../../protocol/models/remote-execution/README.md)
and [report design](../design-notes/distributed-final-results.md) record those
boundaries and the runnable controls.
