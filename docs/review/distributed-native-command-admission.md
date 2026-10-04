# Native command admission review

The native service now requires the original Compile preparation claim to obtain
an exact resource association before native launch intent. The same engine still
handles ordinary native requests. Command contexts add the complete physical
service identity to challenges, admission and historical control.

The [architecture guide](../architecture/remote-compilation.md) explains the
ownership and transaction order. Protocol 067 records the interface obligations.
This component provides the native endpoint API. The command listener, whole
Compile owner and registered deployment remain separate assembly work.

## Reviewed source and disposition

The independent Astra high pass reviewed the working diff against `7632e6e58`,
including the complete untracked regression module. Its source manifest was
`82b18230231d892b863af7e4408f43146b90188d3c2486d11c6d47573d54de87`.
All eleven listed implementation, test, documentation and prerequisite hashes
matched before and after review. The review proposed no correction.

The pass traced original Claim and endpoint binding, admission before resource
association, exact permit validation before launch, and the unchanged deadline
checks. It also inspected every historical control, both duplicate Submit paths,
closed challenge routing and tests that could fail outside the test process.
These were source and recorded-evidence checks; the reviewer ran no tests.

A duplicate submission can inspect the native inventory before checking its
resource association to distinguish existing from new work. It cannot expose
that evidence before the exact reference, key and digest check. Historical
contexts refuse Challenge and Submit, but can control an exact retained
association. They do not manufacture a live claim from Ready data.

## Independent execution

The root reran `make check-executor` on the frozen component source. Its actual
exit was zero: 234 tests passed in 95.980 seconds with no skips. After integrating
the component above the physical command routing branch, the same gate passed
241 tests in 98.922 seconds with no skips. The difference is the seven routing
tests already present on the integration branch. The owned source hashes were
unchanged after that run.

The integration documentation gate also exited zero. Full logs were checked for
hidden assertions and detached peer errors. The only exception report was the
existing deliberate workspace observer panic test; it reported and checked that
injected failure. Warning-free executor compilation and formatting passed.

The sixteen new cases use real SQLite actors and the native service. The positive
compiler witness requires a generated BEAM artifact and successful terminal
evidence. Its checkout hook observes the committed resource association, retained
request/authority and actual native LaunchIntent before helper checkout. Lost
Submit replies, exact duplicates and historical recovery cause no extra checkout.

A second fixture holds one compiler live while another service presents its own
reference with that compiler's native key. Query, Cancel, Stdin and DurableReceipt
all refuse. The target's retained bytes and state remain unchanged, and its own
compiler subsequently finishes successfully.

## Mutations and limits

Both targeted mutants compiled successfully and failed their intended reached
assertions. Skipping resource association changed the fenced request's actual
native phase from Admitted to LaunchIntent. Skipping control binding exposed the
other service's retained output. Passing controls preceded the mutations, and the
exact production source was restored before the full gate.

This proves the component's admission and control boundaries on the tested host.
It does not prove source preparation ownership, whole-service admission, listener
reply custody, allocation cleanup, owner approval/budgets or a separate-host
workflow. Gleam claim and permit values are copyable; trusted service assembly
must retain the original continuation and never recreate it during recovery.
