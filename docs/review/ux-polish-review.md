# Developer experience polish review

Base: `3ce454e6`. Reviewed: the isolated UX polish working tree, including its
new modules. One independent review covered ownership and cancellation,
operation provenance, history and render retention, developer policy, and
protocol 028 before implementation. A bounded follow-up checked that protocol
and the confirmed fixes. The reviewer changed no code and ran no tests; test
results belong to the acceptance ledger.

The initial review found three P2 issues and no confirmed P1 issue:

| Finding | Correction | Regression |
|---|---|---|
| A valid older history page exceeding eight MiB closed the channel. | Accept the retained suffix and revisit the evicted prefix. Existing sequence/order checks remain. | Nine one-MiB entries pass the credited transfer; history paging reaches evicted ancestors. |
| Patch counting silently truncated at 512 characters. | Count the complete already-bounded patch. | Added/removed rows after the display boundary contribute to totals. |
| Turn totals were calculated from 32 retained display rows and paths. | Accumulate counts before display truncation. | Thirty-three edits followed by thirty-three reads retain all patch totals and the distinct-path count. |

The native fixture also found an initial prompt refused while automatic
worktree inspection occupied the command lane. One immutable unsent prompt
now waits behind an authenticated read. A sent mutation still excludes another
mutation, and lost replies never trigger resubmission. Existing custody and
unknown-outcome tests remain in place.

Protocol critique required a distinct cancellation-received cause, context on
route-stopping attempt outcomes, preservation of outer deadlines through a
graceful inner cancellation, and normalization before the gateway's special
unconfirmed-cancellation branch. All were implemented. Startup refusal also
records cancellation receipt, and lost drain proof preserves prior failure
context. No timer, supervisor, stream event, persistent column, or drain witness
was added.

The follow-up found no remaining production finding. It confirmed the three
P2 corrections, unchanged drain and terminal behavior, bounded/redacted
normalization, and durable context plus retry hints. A misplaced new test
assertion was corrected before the final gates.

An inherited limitation remains outside protocol 028: configured role fallback
can start the next model immediately after a retryable failure, including a
same-provider 429. The new retry-hint guarantee applies to persisted machine
retries. It does not change fallback scheduling.
