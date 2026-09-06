# Single-daemon invariant mutation checks

On 2026-09-06, six focused tests rejected deliberately broken lifecycle
protections at `a72b3d704441a6e7bf094d26528ea063d695e8d8`. Each original test
passed before its mutation, failed with the mutation, and passed after exact
source restoration. All mutations compiled. None was counted from a build
error or a watchdog timeout, and none is included in the branch.

These checks supply the six named mutation examples requested by the
[acceptance drive](../design-notes/single-daemon.md#the-acceptance-drive).
They do not establish every crash interleaving, complete resource isolation,
or final acceptance of the shipping artifact. The independent production
review fixes still need verification on their integrated head.

## Method and results

Each test ran in a separate BEAM VM with a 60-second outer deadline:

```sh
LOOM_TEST_TIMEOUT_SECONDS=60 bash scripts/test.sh client --match TEST_FILTER
```

Only one production mutation was present at a time. The drain mutation also
used a fresh database directory, so its intentionally admitted replacement
writer could not leave a lease in the restored test's fixture. Assertions and
clocks were unchanged. The original source and test paths were restored before
the final pass; the worktree was clean afterwards.

The elapsed times below include the focused build and test command. Each
negative exited 1, and each baseline and restored run exited 0.

| Protection | Baseline | Mutation | Restored |
|---|---:|---:|---:|
| Publish before execute | 0.53 s | 0.86 s | 0.86 s |
| Incarnation identity | 0.49 s | 0.87 s | 0.88 s |
| Duplicate-open reservation | 0.48 s | 0.84 s | 0.86 s |
| Snapshot reconciliation boundary | 0.60 s | 1.29 s | 1.25 s |
| Aggregate connection charge | 0.48 s | 0.87 s | 0.79 s |
| Runtime drain before storage release | 0.49 s | 1.09 s | 1.01 s |

### Publish before execute

In [instance_host.gleam](../../packages/client/src/client/internal/instance_host.gleam),
the mutation sent `Begin(owner)` from the successful `custody.start` arm in
`prepare`, before returning the prepared host. The filter was
`prepared_host_does_no_work_and_begins_only_once`.

The test received `Ok(Nil)` on its acquisition subject before the caller
released the builder; it expected `Error(Nil)`. The assertion at
`instance_host_test.gleam:33` failed. Its absence check uses a 20-millisecond
window, so this observed kill is not a scheduling-independent proof that the
test detects every eager-start schedule.

### Incarnation identity

In [manager.gleam](../../packages/client/src/client/daemon/manager.gleam),
the mutation removed the operation/incarnation comparison from the
`ResolveIncarnation` handler. The filter was
`stopping_retains_capacity_until_original_custody_retires`.

After reopening the session, resolution through the retired incarnation
returned `Ok(session_id)` instead of `Error(StaleOperation)`. The assertion
at `daemon_manager_test.gleam:632` failed.

### Duplicate-open reservation

In `manager.admit`, the mutation replaced the existing `WaitingForDomain`
and `Building` result with `new_slot(book, id)`. The filter was
`blocked_builder_preserves_listing_and_other_session_admission`.

The repeated open returned operation daemon-test:2 instead of the retained
daemon-test:1. The assertion at `daemon_manager_test.gleam:562` failed
before a duplicate reservation could be mistaken for a successful join.

### Snapshot reconciliation boundary

In [transfer.gleam](../../packages/client/src/client/daemon/transfer.gleam),
the mutation changed the `Reconcile` lower bound from `from_seq - 1` to
`from_seq`. The filter was
`writes_during_transfer_wait_for_credited_reconciliation`.

The record committed exactly at the previous cut's `next_seq` was absent
from catch-up. Its fragment collection was empty, so `decoded_record` failed
to parse a JSON value at `session_socket_test.gleam:284`. The test did not
time out. This mutant checks the first unseen record, not every possible
violation of a coherent snapshot cut.

### Aggregate connection charge

In [root.gleam](../../packages/client/src/client/daemon/root.gleam),
the mutation removed the `max_reserved_message_bytes` comparison from
`acquire_slot`, retaining the connection-count and duplicate-owner checks.
The filter was `transferred_weight_survives_http_death_and_late_release`.

Another operator received `Ok(Permit(...))` while a live socket retained its
40 MiB charge. The capacity-refusal assertion at `daemon_root_test.gleam:362`
failed. A connection-count cap alone did not satisfy the byte budget.

### Runtime drain before storage release

In [instance_owner.gleam](../../packages/client/src/client/internal/instance_owner.gleam),
the mutation moved `Storage` ahead of `Runtime` in `clean`'s dependency order.
The filter was `real_sqlite_lease_remains_held_until_owned_drain_finishes`.

A replacement writer opened the real SQLite database while the original
runtime cleanup remained blocked. The expected `LeaseHeld` assertion at
`instance_owner_test.gleam:85` failed. Restoring the cleanup order preserved
the lease until runtime retirement, then allowed the replacement open.

## Evidence and remaining work

The dedicated `make e2e-multiplayer` target passed locally in 13.88 seconds
after rebuilding the helper. It ran all five selected fixture modules through
the existing runner. `make soak-daemon` passed in 17.18 seconds with the
per-cycle paired latency assertion unchanged. These target runs used the
same production code as the mutation baseline; neither verifies the pending
production fixes or resolves the earlier macOS CI timing failure.

The local logs are `/private/tmp/loom-mutation-NAME-negative.log` and
`/private/tmp/loom-mutation-NAME-restored.log`, where `NAME` is `publish`,
`incarnation`, `duplicate`, `snapshot`, `resource`, or `drain`. Baseline logs
use `/private/tmp/loom-mutation-baseline-TEST_FILTER.log`. These paths locate
the local run evidence; the mutations and test filters above are the
reproduction instructions after those temporary logs disappear.

Recheck affected mutants after integrating the production review fixes.
The broader acceptance drive still requires the final platform artifacts,
SQLite repair adoption, and the separately unfinished confinement work.
Neither these six examples nor the existing fixture suite establishes a
crash-at-every-publication-step sweep.
