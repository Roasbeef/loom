# Peer compatibility for issue #1137

Source baseline: `1dcb195052ac06b5d0dc992ae9991ffa5705eb77`. The owner approved
versioned peer dispatch and launch preflight on October 29, 2026 for code and
isolated tests. This record covers the first part; TLS launch preflight is the
next slice. No live upgrade or deployment is authorized.

The new `loom_peer_v1` service keeps a permanent outer Exchange message and
versioned bounded JSON. The page relay negotiates exact operation revisions and
serving epoch, then dispatches only through that endpoint. The existing TopHost
retains policy, capacity and sequence checks. Missing endpoint is unsupported;
loss after dispatch stays uncertain. A later negotiation failure cannot retract
an earlier unanswered mutation. Protocol 105 records the exact wire, byte
ceilings, initial migration cost and unchanged per-call budget.

Primary verification passes 107 focused tests: peer compatibility 12, relay 27,
UI top 33, TopHost 32 and three individual UI route checks. There are no skip
diagnostics. The old-source actor witness fails because an unknown legacy
placements message kills an actual old-shape actor. The fixed caller leaves it
alive. An epoch-check mutation compiles and fails the ordered replacement test
at the expected Stale assertion; the restored source passes. Correlation, byte
and revision limits, invalid bodies, escaped sends, oversized replies and lost
creation followed by unsupported negotiation are covered. The real TopHost
rejection test requires UnknownSpawner after positive discovery.

These are same-VM actor fixtures, not separate released binaries. The deadline
test gives dispatch only the time remaining after the feature answer. The
independent reader checked the pinned Weft implementation: its local send worker
is joined before returning, so missing local names cannot crash the caller or
leave a detached sender. No actionable correctness or simplification finding
was returned in the single report-only pass. The reader did not execute tests.

The operation byte ceiling limits the emitted envelope. Encoding a very large
valid offers value can allocate more before producing the bounded error; it is
not a transport or intermediate-allocation limit. Fully trusted enrolled VMs
retain their existing distribution privileges, and reply ownership supplies
attribution rather than a new proof of the sender's identity.

## Shipped and mixed-version transport

A further primary regression starts the freshly shipped daemon and a separate
pinned TLS probe VM using the production relay. It requires the configured
profile/model offers, an attributed UnknownSpawner for a different pinned
identity, and the retained legacy placements response. The existing fixture
owns private homes and credentials and retires its native processes by recorded
PID and birth even after failure. The independent reader checked this test
delta and found no actionable issue. It adds one test to the 107 focused checks.

The primary also ran two temporary mixed-version substitutions through that
same fixture, restoring both files in a finally block. Against the existing
shipment at baseline 1dcb19505, the new caller reports Unsupported and then a
legacy placements request succeeds on the same running target. In the reverse
direction, the probe explicitly loads the old production top_relay BEAM before
calling the new shipped receiver. The fixture asserts its loaded path and
SHA-256 `86372cc024cc33e6b06689fa0ad62bddd6a308e9e0c3145c15abacba864d2146`,
then requires both configured offers and the attributed refusal. Both runs and
the restored current/current run exit 0 without skips. The old module runs in
the probe; the old daemon's web component is not exercised.

The full formatting, lint, documentation, prelude and generated-client gate
exits 0, with 2,671 lint warnings and 228 documentation warnings, zero errors.
Broad affected gates, exact-head hosted CI and required Linux signoff remain
open. Issue-level fleet acceptance remains open, as do repository custody,
movement and full page relay. These isolated native tests are not a live upgrade.
