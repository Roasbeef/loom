# Physical command routing review

The owner dispatcher now retains the complete physical command reference through
each native exchange, including detached cancellation. Canonical framing and
exact reply matching prevent a plain native response or another service's
response from satisfying that exchange. The
[architecture guide](../architecture/remote-compilation.md) explains the two
identities and the remaining server admission work.

## Independent finding and correction

Astra found one actionable test defect. The cancellation peer published its
decoded request before replying, and the test could finish before the peer's
response assertion. A full-gate log contained `Error(Closed)` from that peer
despite reporting 213 passing tests.

The corrected test retains the early decoded-route assertion and runs the peer
under a managed outcome. It waits for successful response completion before
releasing the dispatch and closing the listener. A peer failure now reaches the
test. Root independently ran all seven routing tests after this correction:
exit zero in 1.651 seconds, with all frozen source hashes unchanged.

The reviewer found no additional actionable production defect. The review
covered all six frozen files, canonical framing, complete-reference matching,
aggregate limits and route propagation. The reviewer inspected tests and logs;
root performed the independent runtime check.

## Controls and proof boundary

The seven controls exercise canonical encoding, scope and operation mismatch,
unchanged Prepared limits, malformed framing, pinned TLS reply matching,
ordered output and receipt, stdin and detached cancellation. Test peers drive
the real connection and dispatcher. They do not constitute the production
Compile server or prove its association checks.

Both targeted mutations compiled and failed the intended controls. Removing
reply-reference matching failed the TLS reply check. Dropping the detached
Cancel route failed the independently decoded command-frame assertion. The
latter was rerun after the managed-peer correction in a private source copy;
the restored control passed and the live production source remained unchanged.

The corrected worker gate initially passed all 213 executor tests. A subsequent
full run passed all seven routing controls but failed the existing host-close
test: journal readback returned `Uncertain` where the test expected `Closed`.
These are separate runs; the earlier pass does not erase the later failure.
The isolated host control passed on its single rerun. Root's combined executor
gate then passed all 225 tests in 101.988 seconds, including the twelve live
association controls from the preceding layer.

Root traced the intermittent failure to `journal.release`: it acknowledges the
closed SQLite connection before its actor exits. A subsequent request can find
an already-dead actor and return `Closed`, or observe actor death after its
liveness check and return `Uncertain`. The test now accepts either refusal while
preserving its actual native-retirement, actor-death and listener-close checks.
No production behavior changed, and an `Ok` readback still fails the test.
The full executor gate after this correction passed all 225 tests, exit zero,
in 97.312 seconds. Format and documentation gates passed. The log contains no
undeclared skips or assertion failures; existing crash-injection fixtures still
produce their expected crash reports.

The corrected test SHA-256 is
`c670675cbfb4747362ec226ce3f1a261dfc323613d1f65a91be8e80e07efcfec`.
The three production files and package documentation remained byte-identical
to the independently reviewed freeze. Server command routing, native live
admission and separate-host product acceptance remain later integration gates.
