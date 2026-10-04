# Compile outcome custody review

The existing executor resource journal now retains native associations and exact
Compile completions. Format 2 reserves their maximum capacity before the first
preparation claim. New association requires the actual admitted native request;
new completion requires its exact terminal payload and committed terminal
evidence. Historical reads grant no launch or preparation permission.

Independent adversarial review found no actionable production defect. It found
two test coverage gaps. The oversized-row fixtures could fail on semantic
corruption even if a size guard disappeared, and the network-widening fixture also
widened writable roots. That second failure could mask a missing network check.

The corrected tests query the generated header and body decoders directly and
require the error to name the guarded column. Network and writable-root widening
now have separate fixtures. One added test brings the focused journal suite from
27 to 28 tests; all original tests remain. A test-only mutation removes one
header-size predicate from the generated query text, compiles successfully, and
fails the intended assertion on a 131,073-byte Prepared value. The exact test
source was restored afterward. Production source remained unchanged.

Root independently ran the full executor gate before that test-only correction:
202 tests passed in 96.358 seconds. The internal compiler factory's 14 focused
tests also passed. After correction, root independently ran all 28 focused
journal tests, which passed in 2.108 seconds. Frozen hashes matched the reviewed
production source and the corrected test manifest.

The initial full gate also exposed an existing host-lifetime assertion. It waited
for the host's DOWN message and immediately asserted that the service was dead.
The corrected test monitors the service before stopping the host, then waits for
the service's own DOWN witness. No assertion or test was removed. The original
failure and focused reproduction remain separate from passing evidence.

Four production mutations compiled and failed their intended custody controls:
fabricated admission from Request alone, settlement before the native terminal
commit, a false Before-native result after Ready, and acceptance of a conflicting
completion retry. The additional query mutation checks the new coverage
assertion, not every generated bound.

The combined integration tree then passed all 206 executor tests and all 409
code-mode tests, with no reported skips. The package gates exited zero in 96.703
and 51.395 seconds; documentation checks also passed. An initial sandboxed attempt
stopped before tests because the pinned Go toolchain could not verify its module
over the network. The fresh permitted run supplied the passing results above.

The [architecture guide](../architecture/remote-compilation.md) explains the
record ownership and required production sequence. Live cancellation/admission
ordering, the physical Compile/Launch services and separate-host acceptance are
still integration work. This review does not establish a working remote product.
