# Fresh catalogue reads and ASCII profile validation

The October 29 [live profile](live-profile-2026-10-29.md) found repeated source
registration reads and profile-name validation allocating in the daemon's
catalogue owner. In this change, we remove the duplicate source lookup and
replace the profile validator's grapheme lists with a bounded ASCII walk.
No installed daemon, native child or live configuration was changed.

## What the code preserves

`domain.sources` keeps its published identity-list contract. Its internal
`source_records` read gets the current domain and at most 100 saved
registrations, including the display layers, in two SQL statements. Every
registration passes the existing complete row validation and must match the
validated domain's workspace and derived scope identity. The domain's paths
are validated once per page because the value is immutable during that turn.
Nothing caches membership or bypasses invalid persisted metadata.

The manager receives `DomainSources`, then projects canonical identities and
paths in that same catalogue-owner turn. The separate identity and path
requests no longer permit a mutation between membership checking and path
projection. The caller still advances after the last identity, yields between
pages, and refuses more than 511 sources rather than returning a prefix.
The full page limit remains 100. Display name/subtitle decoding stays in the
joined read even though those fields do not authorize a source.

`catalogue.is_profile_name` checks the string's byte length, requires an ASCII
lowercase first byte, and scans at most 31 suffix bytes for lowercase letters,
digits, underscore or hyphen. Accepted ASCII has the same byte and grapheme
length, so Unicode cannot change the bound. Executor and pool names continue
to delegate to the same grammar. No frozen interface, wire field, schema
version, dependency, cache, actor or timer was introduced.

## Matched benchmark

`scripts/catalogue_perf.sh` runs isolated in-memory catalogues in one disposable
OTP 29 VM, ERTS 17.0.5, with eight-byte words and one normal scheduler. The
baseline BEAMs are from unchanged source at
`678aefa489da9d4bd9fa5c633b7a072097a7821c`, saved before either optimization,
with a revision file and SHA-256 checksums. Their abstract forms are renamed
and compiled into separate baseline modules; the original inline attributes
are retained. Both versions run in the same VM and order alternates across
five rounds. Fixture setup and warmup are outside timing.

The source fixture performs the original two-stage read for the baseline:
`domain.sources`, followed by `catalogue.get` per path. The candidate uses the
production `domain.source_records` page. Each iteration checks the complete
identity/path result. Registry mailbox transit is deliberately excluded; the
real registry suite separately checks the integration. Source sizes are zero,
one, 25, 100, 250 and the allowed maximum of 511, with a valid configured
profile in every registration.

Wall time and VM runtime CPU are measured without tracing. Caller reductions
are sampled separately. A separate root-only `tprof.call_memory` pass measures
caller heap allocation including its untraced callees, and an independent
`call_count` pass counts SQL statements. Allocation excludes SQLite-worker
heaps, off-heap binaries, ETS and native/NIF memory. VM runtime CPU includes
fixture VM work and is not installed-daemon OS CPU. Timing is reported rather
than used as a flaky gate. `--expect-improved` gates exact query counts and at
least a 50% allocation reduction for every populated source and validator case.

Source-walk measurements include both the joined read and the shared ASCII
validator improvement. Their CPU/allocation percentages are not attributed
solely to fewer SQL statements. The validator also has an isolated case.

Initial matched medians per complete source enumeration:

| Sources | Queries, before/after | Wall time, before/after | VM CPU, before/after | Caller heap bytes, before/after |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 8 / 2 | 172.62 / 73.30 us | 0.200 / 0.100 ms | 161512 / 32352 |
| 25 | 152 / 2 | 4175.55 / 407.35 us | 4.100 / 0.350 ms | 3699160 / 469584 |
| 100 | 604 / 4 | 14589.00 / 1904.88 us | 16.125 / 1.250 ms | 14768864 / 1850240 |
| 250 | 1506 / 6 | 44109.33 / 3643.67 us | 41.000 / 2.667 ms | 36898992 / 4602208 |
| 511 | 3078 / 12 | 66586.00 / 6881.00 us | 74.000 / 5.500 ms | 75434024 / 9487024 |

An exact full page needs a final empty continuation page, hence four statements
for 100 sources. The source query count is `2 * pages` rather than
`2 * pages + 6 * sources`. Empty domains keep two statements, add four caller
heap words per enumeration, and can pay a small fixed join-preparation cost;
that case is measured separately rather than claimed as a win.

For a valid 32-character name, the initial median is 55.18 us and
199256 allocated bytes per call before, versus about 0.10 us and 40 bytes
after. The fixed driver overhead is included. Short valid names and invalid
inputs are separate benchmark cases. CPU timing has millisecond resolution,
so the candidate's tiny validator batches are not a precise CPU percentage;
reductions fall from about 10042 to 40 per maximum-length call.

The initial capture above overlaps a lint build. Later repetitions without a
concurrent repository build and final verification receipts are recorded on
[PR #1148](https://github.com/Roasbeef/loom/pull/1148); this table retains the
initial observation rather than overwriting it with a different timing cut.
Heap capacity after an untraced batch is also recorded. It does not move
uniformly: less allocation can delay a collection, and some candidate cuts
have a larger heap than baseline. These results establish less CPU work and
allocation, not a retained-heap or RSS reduction. The installed daemon still
predates the separate callback-memory fix in #1138.

### Reproducing

Build the baseline storage package in a clean checkout at the baseline commit,
then save its three BEAMs using the candidate's benchmark launcher:

```sh
/path/to/candidate/scripts/catalogue_perf.sh /path/to/baseline --save-baseline /private/tmp/catalogue-baseline
```

Build the candidate storage package and run:

```sh
scripts/catalogue_perf.sh "$PWD" /private/tmp/catalogue-baseline --expect-improved
```

Both storage builds must use the same OTP/compiler and dependencies. The
launcher rejects a baseline whose storage sources differ from its HEAD.
Baseline files and logs are local artifacts; they do not enter the PR.

## Correctness and negative controls

The original grapheme validator is preserved as a test oracle. Both original
and candidate pass 5000 generated mixed-Unicode strings, every ASCII byte in
first/middle/final positions, the 32/33-byte boundary, Unicode and combining
suffixes, and a 100000-character invalid name. No test depends on timing.

Storage tests compare projected records with ordinary point reads, cover
renames/subtitles and fresh path changes, exclude unconfirmed corrupt rows,
observe deletion, refuse malformed profile/path/executor fields and wrong-domain
bindings, refuse an invalid domain even with no saved sources, and page 101
records without truncation. The registry suite retains cross-page enumeration
and the oversized-domain refusal, and now proves corrupt later metadata cannot
return an authorized prefix.

Eight isolated BEAM mutants compiled and were rejected at runtime: uppercase
first letters, Unicode suffix bytes, a 33-byte limit, a dot in place of hyphen,
bypassed registration validation, bypassed scope matching, a 99-row page and
admission of reserved rows. Mutants were loaded only into disposable test VMs.
The first validation-bypass control attempt failed compilation due to an
unqualified Erlang BIF and is not counted; the corrected control compiled and
failed the intended runtime assertions.

## Validation record

The unchanged baseline storage gate passed 351 tests. The candidate storage
suite passes 357 tests; the real daemon-manager suite passes all 53 tests.
Scoped lint reports zero errors and 823 advisory warnings. Independent review
found no actionable issues in the implementation, boundary preservation or
benchmark accounting. A subsequent test-only strengthening sorts the fixture
records before corrupting the second, ensuring a valid SQL-ordered prefix
precedes the refused row.

Full local gate outcomes, later benchmark repetitions and hosted/Linux signoff
are recorded on [PR #1148](https://github.com/Roasbeef/loom/pull/1148). Those
receipts must name the final head; the focused counts above alone do not claim
hosted readiness. The unchanged-candidate negative control compiles and fails
at the allocation-improvement assertion, so the benchmark's gate rejects a
candidate that did not improve.

Local evidence is saved under `/private/tmp/loom-catalogue-*`: the baseline
BEAM directory, baseline/after/final benchmark logs, mutation log, storage and
registry logs, scoped lint and the full-check log. Later head changes require
fresh exact-head validation; none of these fixture numbers proves installed
RSS savings.
