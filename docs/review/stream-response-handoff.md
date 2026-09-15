# Stream response handoff

The completion gap is reproduced on the unchanged terminal: the provider end
observation removes the live answer before the durable response capture arrives.
The long-answer fixture loses its text at that intermediate state. It passes
when the terminal retains the existing bounded fragments until the response
entry reserved by the effect intent is present.

Protocol 036 records the accepted internal request addition. Tests cover exact
entry replacement, unrelated equal-text entries, stale idle captures, late
fragments, preview-only attachment, and legacy request identities. The long
answer spans 80 paragraphs; ending the provider request leaves rendered and
revealed row counts unchanged. The gateway test verifies that its observations
carry the runtime request's reserved response identity.

Independent review found the preview-only attachment case: a client attaching
near completion can receive a captured preview and then end without a pushed
delta. The fix transfers that exact preview into the bounded stream region
before applying end. It does so only when no pushed region exists, preventing
a second copy of the streamed answer.

After rebasing onto main ebcda151, the local gates passed 135 runtime tests,
1,800 client tests, 82 conformance tests, and 488 TUI tests. Lint passed with
zero errors. The stream bound benchmark processed 20,000 deltas, retained
97,672 binary bytes under the 131,072-byte bound, and measured 3,908 deltas per
second against a 2,000-per-second floor. This is a local fixture measurement,
not a latency claim about a live provider or terminal multiplexer.

Hosted CI and Linux signoff remain required for this branch. The broader
scroll-region renderer is independent; this change addresses completion's
transfer from live fragments to a durable entry.
