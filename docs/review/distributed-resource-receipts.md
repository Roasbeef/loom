# Remote resource receipt review

The receipt slice adds exact Compile and Launch location records to the
[distributed runtime](../design-notes/distributed-runtime.md). It implements
the data boundary in [protocol 067](../../protocol-change/067-remote-workspace-services.md),
not the resource owner or separate-host execution.

Compile locations retain the full original service key and the enrollment's
build allocation. Launch resources additionally retain the producing Compile
key and all three fixed channel paths. The complete original ToolKey must
match across the two services; their physical steps may differ. Path comparison
is literal, so a normalized alias cannot replace the enrolled spelling.

Decoding bounds raw MessagePack before converting embedded service keys through
core's existing total decoder. Constructors recheck enrollment, role, parent
and paths, then canonical re-encoding rejects alternative byte representations.
A decoded receipt grants no creation authority and establishes no live listener,
existing directory, successful compilation or native retirement.

## Validation and independent review

The frozen source and tests passed 13 focused controls and all 373 code-mode
tests, without skips. Root independently reran the full `make check-codemode`
gate: exit 0 in 49.68 seconds, 373 tests, no skips. The preceding restricted
run failed 21 existing tests because its outer sandbox prevented home-directory
scratch creation and Unix socket setup; it was not a passing gate. The permitted
rerun used the same source and the tests' required fixtures. Formatting, targeted
lint and documentation checks passed.

A test-only mutation removed literal path equality. It compiled and failed the
intended path-substitution assertion; the original source was restored exactly.
The tests also cover full parent substitutions, changed roles/scope/contracts,
valid differing physical steps, all Launch handles, hostile/truncated frames,
extra fields and noncanonical MessagePack.

An independent Astra high read-only pass checked the frozen source, tests,
underlying enrollment and key contracts, mutation evidence and start/end hashes.
It found no actionable defect or evidence gap. This review does not establish
production resource custody, a durable successful Compile result, channel
liveness or two-host acceptance. Those remain separate implementation gates.
