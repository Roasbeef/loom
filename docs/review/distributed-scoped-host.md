# Scoped native host review

The native host now borrows the shared TLS BEAM endpoint. Its lifetime closes
one registered row without stopping sibling scopes or the node's rendezvous.
The host orders Register and Fence from the same process, then keeps service
producers alive until the original row's transport obligations drain.

## Reviewed behavior

A close attempt fences the original row, quiesces new service admission, observes
actual transport drain, requests the service's original native-close disposition
and joins the owned service. Cleanup still runs after an earlier failure. Journal
release requires success at every boundary. A failed durable confirmation after
successful native close retains the original proof for retry; a dead service
without that proof cannot be repaired by independently closing its pool again.

Astra found no actionable findings. Its source-only rebuild included a freshly
built native helper and passed all seventeen controls across actual TLS BEAM
nodes. The nine original host tests retain their behavioral assertions. Eight
new controls cover shared sibling effects, a lost Register acknowledgement,
busy-row expiry, owner death, row capacity and retained physical-close evidence.
Five exact-source compiled mutations failed intended assertions. They remove
the fence, skip cleanup after quiesce failure, stop the shared endpoint, repeat
native close, or suppress the positive drain witness. The last is a progress
control; it is not a safety proof. The endpoint-stop mutation fails the closing
scope's assertion before reaching its sibling assertion.

The worker's full executor gate passed 314 tests with no skips. Root's combined
integration replay also exited zero with all 314 tests and no skips. These are component
controls on independent local VMs, not separate-host deployment acceptance.

## Limits

The host owns native service retirement. It does not yet assemble whole Compile,
workspace cleanup, remote Launch or the production daemon. A brutal process kill
can lose an in-memory native-close witness; retained uncertainty is intentional.
TLS BEAM membership remains full-node trust. The tests establish neither hostile
peer mailbox bounds nor kernel power-loss durability.
