# Compile observation review

The observation adapter connects committed native compiler evidence to the
original physical Compile continuation. It does not make a recovered journal
row executable or establish registered remote-session acceptance.

## Ordering and ownership

`executor/remote/compile_observation.observe` reads the native reducer's
committed settlement before reading immutable output and terminal payloads.
Payload retention alone is insufficient: a writer can retain a terminal before
its reducer transition commits. The adapter also checks the complete original
service, native association, Ready locations, native key and request digest.

Missing association or an uncommitted terminal remains pending. A committed
terminal with missing or inconsistent payload is an error. Ordered output must
have contiguous ordinals; stream reconstruction preserves order and sticky
truncation evidence. The adapter retains exact native bytes independently of its
human-readable outer error.

Only the original continuation calls `finalize`. It uses the existing build
finalizer and fingerprints actual compiler products beneath the original
allocation. The opaque observation is copyable in Gleam; its type alone does
not prove once-only execution. The enclosing service must retain continuation
ownership and commit the outer completion before publishing it.

Outer error text is bounded to 8,000 UTF-8 bytes, including its truncation
marker. The boundary preserves the error variant and never rewrites native
receipt bytes. A byte cutoff removes an incomplete trailing code point rather
than measuring graphemes, which can occupy more than one byte.

## Verification

The reviewed source is integrated as `3e983421d`; package maps follow in
`9020c76e0`. These are unchanged cherry-picks of the reviewed component.
The adapter SHA-256 is
`838bd11709588a16f890a3e3e190dd2f9ba953248e9c8aced21fcd45ccda2dab`.
The independent adversarial review reported no actionable finding and checked
all five frozen files before and after its read-only pass.

| Gate | Actual result |
|---|---|
| Focused observation tests | 11 passed, exit 0, 1.235 seconds. |
| Executor package | 252 passed, exit 0, 79.810 seconds; no skips. |
| Independent root focused rerun | 11 passed, exit 0, 0.846 seconds; source hashes unchanged. |
| Format, lint and rendered documentation | Exit 0; lint had zero errors and 30 existing warnings. |
| Documentation graph | Exit 0; zero errors and 168 warnings. |
| Committed-terminal guard mutation | Compiled successfully; the intended pending-evidence assertion failed. |
| UTF-8 bound mutation | Compiled successfully; the intended byte-bound assertion failed. |
| Restored mutation control | Original source restored exactly; all 11 focused tests passed. |

An earlier fixture failed because it reused a logical address. That failure was
retained, the fixture was given a distinct parent, and the final full gate above
ran on the corrected source. These results are component evidence; later
integration gates must name their own revision.

## Limits

The tests use real SQLite journals and compiler-produced module artifacts, with
synthetic native outcomes. They do not run the compiler through the complete
jailed service. No deterministic between-read COMMIT hook or new uncertain-write
fault injection was added in this slice. Authenticated listener custody, actual
Broker dispatch, owner durable receipt, registered daemon assembly and
separate-host tests remain obligations of the assembled system.

## Combined-main verification

At integration head `bc44d8155b9ec8cc5213232647b74a3ecc2f3c34`, after the
current-main merge and observation commits, the root reran
`bash scripts/check.sh executor`: 274 tests passed, exit 0, 79.401 seconds,
with no skips. The helper and offline seed were already built from this combined
source. The only test-process panic was the intentional workspace effect/crash
fixture. Adapter and test hashes still matched the reviewed freeze. This checks
the merged component; the whole Compile actor and registered consumers remain
outside this head.
