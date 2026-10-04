# Atomic first Compile admission review

First preparation now inserts the original input and claims it in one SQLite
transaction. Only that insertion can return `FreshClaim`. Every existing row
returns history, including a reservation left by an earlier process. Cancellation
uses the same writer ordering to fence absent, Reserved, Preparing or Ready input
before following any associated native command.

The [architecture guide](../architecture/remote-compilation.md) explains the
transaction order and uncertainty rules. Protocol 067 records the obligations for
the whole Compile service. The earlier component reserve/claim APIs remain
available; their existence does not authorize recovery to recreate a live claim.

## Independent review

The independent Astra high review found no actionable defect. It verified the
six source and documentation hashes and the separate generated SQL hash against
manifest `d358b9374d5bcd40dabddea0ea0f97074fca99bff015e1684fe1b4d364221a0c`.
The reviewer checked the same hashes after review and made no edits or test runs.

The review traced absent-row insertion, complete identity checks on retained
rows, capacity reservation, cancellation in a sealed scope, and failed COMMIT.
A failed COMMIT returns `Uncertain` and poisons the endpoint before any successful
reply. The new named SQL query changes only phase, preserving Ready and native
association. Existing Unknown and Released rows return checked history.

## Controls and mutations

The component's 18 focused tests and 40 existing resource-journal tests passed.
Its full executor gate passed 243 tests in 115.025 seconds, with no skips. An
independent root run of the 18 focused tests also passed in 0.759 seconds.

After integration above native command admission and owner command binding, the
root reran `make check-executor`. It exited zero with 259 tests in 105.751 seconds
and no skips. The 16 additional cases come from native command admission.
The log's crash reports belong to the existing host/ingress failure fixtures and
the deliberate workspace observer panic; no failed test assertion appeared.

The concurrent controls open the actual SQLite database independently. Managed
peers report both outcomes, and the test inspects the committed row afterward.
Ordered controls separately cover cancellation before admission and association
before cancellation. The latter preserves the associated command as potentially
in flight; it does not assert that the process never started.

Deferred foreign-key failures force actual COMMIT errors for both new operations.
The tests also retain pre-existing Ready bytes across a failed fence. Recovery
after an ignored reply reads history and cannot issue another preparation claim.

Both mutations compiled and failed their intended assertions. One incorrectly
granted a fresh claim for retained Reserved input. The other removed phase zero
from the cancellation query, and failed after reaching that generated query.
The source was restored before the full gate, and SQL regeneration reproduced
the committed output byte for byte.

## Limits

The ignored-reply case simulates reply loss. A concurrent run does not prove that
both scheduling orders occurred in that run; the ordered controls cover those
outcomes explicitly. These tests establish journal behavior on the tested host.
Original deadline enforcement, command forwarding, physical resource ownership,
cleanup and separate-host acceptance still require the service assembly.
