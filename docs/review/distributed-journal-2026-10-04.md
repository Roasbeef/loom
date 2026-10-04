# Distributed admission journal review

This review covers the SQLite adapter over the admission reducer from #756.
It does not establish remote execution, native restart recovery or result
payload retention. The adapter stores exact request/result digests and custody
transitions; the later native/transport adapter owns those remaining duties.

## Independent review and disposition

The independent review found one material bounded-decoding defect. SQLite
integer affinity permits a blob in a numeric column. The metadata query
bounded the binding blob but returned capacity, version and byte count without
a SQL type guard, allowing a corrupted value to allocate before decode.int
rejected it. An empty journal accepted a one-megabyte capacity blob with all
schema checks enabled.

The query now projects those columns only when typeof reports integer. Other
types become NULL before crossing into the result decoder. Tests cover the
schema-permitted capacity blob and corrupted version/byte-count values. These
tests prove semantic rejection; the allocation bound follows from the guarded
SQL projection, not from a memory-profile measurement.

The review found no confirmed duplicate-launch, cross-open serialization,
receipt/custody, closure or fresh/recovery reset defect in the intended API
paths. The root also changed the SQLite fixture's macOS-specific temporary path
to /tmp so Linux can run the same tests. No jail uses this fixture directory.

## Validation

The root reran the real SQLite suite after the repair: 17 tests passed with
exit zero. The suite covers reopen at each custody phase, independent concurrent
opens, exact duplicates, retained capacity, malformed history, refusal
provenance, and append/head-update/COMMIT failure. The package built warning-free
and the changed journal files passed format checking. Package lint passed;
existing and concurrently developed unrelated helper warnings remain visible.
The documentation gate returned zero errors with pre-existing staleness and
citation warnings.

The worker also ran the existing 20 admission reducer tests and a targeted
mutation. The mutant returned Launch without persisting intent; the reopen
regression then returned a second Launch and failed. The worker restored the
source before the root's validation. This mutation is evidence for that
specific restart invariant, not a proof of all storage failures.

Full-tree CI, platform signoff and the real remote-workspace fixture are
separate gates. Journal tests use actual SQLite files and two independent
connections in one BEAM VM. They do not inject power loss or establish an exact
physical disk quota for SQLite pages and WAL files. An active database needs a
consistent SQLite backup cut for transfer.
