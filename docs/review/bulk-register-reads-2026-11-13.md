# Bounded register reads: November 13 follow-up

The owner approved an additive exact-key read after the initial point-read
measurements exposed the wide-owned tradeoff. [Protocol 114](../../protocol-change/114-bounded-register-reads.md)
records the frozen-interface decision. The implementation and benchmark source
are pinned at `3e28c16f491ac9c473d3967aadbbfd70a51b27c5`, based on upstream
`fb6024e4b6ab7d4d0243ab8cff3aa0f344a60abe`.

## Read boundary

`storage.get_registers(store, namespace, keys)` accepts at most 128 raw key
occurrences and returns existing cells with their sequences. Missing keys are
omitted, duplicates collapse, and oversized requests fail explicitly before
backend admission. A valid empty call still checks whether the handle is closed.
Both backends answer one accepted call in one actor turn. SQLite uses one
parameterized statement through the namespace/key index, selecting current keys,
sequences and bytes before applying its existing decode cache.

`writer.get_registers_batched` deduplicates a captured set and reads consecutive
128-key slices. Run admission supplies captured next-run IDs; the driver supplies
all three inbox queues and staged ready tool-result IDs. Empty sets send no
request. Each call has a snapshot, but separate batches and control reads do
not share one. Live pending payloads remain immutable until their guarded
placement/deletion, and the existing state-sequence expectations are unchanged.

## Measurements

Two independent invocations of the same committed program completed with exit 0:

```sh
cd packages/runtime
HOME=/Users/roasbeef gleam run -m pending_read_bench
```

Each invocation contains 72 cases: memory and SQLite `:memory:`, unrelated
backlogs 0/100/1000, owned widths 0/1/32/128, and scan/point/bulk methods. Every
case retains seven samples of 50 loads. The [data artifact](data/bulk-register-reads-2026-11-13.json)
contains all 1,008 samples, exit codes, source revision and host receipts. The
complete Cartesian products, sample counts and load counts were independently
validated before calculating medians.

The table reports median elapsed milliseconds per 50 read-and-decode loads.
Each cell is first invocation / independent rerun, not a confidence interval.

| Backend | Unrelated | Owned | Namespace scan | Individual points | Scoped bulk |
|---|---:|---:|---:|---:|---:|
| Memory | 0 | 32 | 1 / 2 | 6 / 9 | 2 / 3 |
| Memory | 0 | 128 | 5 / 8 | 24 / 32 | 6 / 7 |
| Memory | 1000 | 32 | 58 / 61 | 7 / 7 | 2 / 2 |
| Memory | 1000 | 128 | 68 / 69 | 23 / 25 | 6 / 7 |
| SQLite `:memory:` | 0 | 32 | 9 / 12 | 25 / 41 | 10 / 18 |
| SQLite `:memory:` | 0 | 128 | 25 / 76 | 94 / 158 | 30 / 35 |
| SQLite `:memory:` | 1000 | 32 | 320 / 292 | 27 / 22 | 11 / 11 |
| SQLite `:memory:` | 1000 | 128 | 267 / 249 | 98 / 107 | 34 / 37 |

Bulk reads reduce the measured wide-owned cost relative to individual points
in both invocations while keeping unrelated payloads outside the read. They are
not uniformly faster than namespace scans: the first SQLite 128-owned/no-unrelated
case is 30 ms bulk versus 25 ms scan, and both 32-owned/no-unrelated cases still
favour scans. A scan is not an acceptable fallback because it restores the
unrelated-corruption failure. No adaptive crossover or new cache is selected.

These are loaded-host synthetic measurements on Darwin arm64 with Gleam 1.19.2.
Observed one-minute load ranged from 13.69 to 17.35; the independent rerun
started below the first invocation, but individual case timings still varied.
A separate Erlang probe reported OTP 29 and 16 schedulers for its own VM, not
for each benchmark VM. No isolated CPU, RSS, complete admission/turn latency,
file-backed read result or installed-daemon improvement is established.

All cells use the same roughly 1 KiB encoded pending payload, so this fixture
allows decode-cache reuse and does not model diverse payloads or cache pressure.
Each method includes typed decoding, dictionary construction and a complete
expected-key/payload assertion in every load. Fixture setup and acknowledged
writer teardown are outside the timer. Methods share one seeded store in fixed
scan/point/bulk order; there is no per-method cold reset or randomized order.
The clock resolves whole milliseconds, so zero samples do not mean zero work.

## Correctness and negative controls

The shared backend suite compares complete bulk dictionaries, including every
sequence, with 128 point reads. It checks empty/single/full requests, input
order, duplicates counted before the limit, missing keys, namespace isolation,
updates, deletion and close. SQLite tests use the actual shared query builder
for indexed-plan/parameter-shape checks, malformed selected versus unrelated
bytes, and fresh rows after external value/sequence changes or deletion. The
one-statement invocation count is verified by source inspection, not a runtime
SQL trace.

Runtime tests retain the existing normal, failure-drain, abort and recovery
placement coverage, instrument pending batch reads without point/list fallback,
and exercise 130-item captured next-run and live inbox queues. The direct
writer test requests 260 keys plus duplicates and missing cells. The shared
benchmark smoke uses 129 owned keys on both backends and all three methods.

Three focused semantic controls were rejected after successful compilation:
raising the accepted limit to 129 returned a value instead of the expected
refusal on both backends; truncating SQLite selection to 127 keys failed the
complete point-read dictionary comparison; advancing runtime chunks by 256
instead of 128 returned 132 cells instead of 260. Every mutation was restored
byte-for-byte, the restored files were touched, and focused baselines passed.

## Verification receipts

Primary reruns at the committed source completed as follows:

| Command | Exit | Reported result |
|---|---:|---|
| `make check-storage` | 0 | 383 passed entries |
| `make check-runtime` | 0 | 232 passed entries |
| `make check-session` | 0 | 73 passed entries |
| `make check-conformance` | 0 | 116 passed entries, with prerequisite skips |
| Four changed-package lint targets | 0 | No errors; 18/65/4/84 warnings respectively |
| `make fmt-check`, `make doc-check`, `make prelude-check` | 0 | Static gates passed |

The conformance runner emitted nine existing real-helper/LSP prerequisite skip
diagnostics under the enclosing Seatbelt jail. Its successful exit is not a
receipt for exercising those lanes. The independent source/test review found
no actionable finding across invariants, simplification and nearby variants;
it ran no gates and does not replace their exit codes.

The broader `make check-client` receipt is **not green**. Make exited 2 after
552 seconds; its test command ended with exit -24 (`SIGXCPU`) before an EUnit
summary. The log contains 130 observed failed markers, not final pass/fail/cancel
totals. Many failures occur at fixture directory creation (`EPERM`/`ENOENT`)
before the changed read path. Other observed failures include resident/advisor
poll expiry and hook output mismatches; those are not all proved to be
environmental or ruled out as regressions by this local run. No client assertions,
timeouts, fixtures or test selections were changed to obtain a pass.

A hosted full gate and real-helper signoff are therefore required acceptance
evidence on the final PR. No local full-repository or installed-daemon green
status is claimed. Earlier failed development receipts are retained locally:
a query-decoder/plan assertion error and a 127-versus-128 conformance fixture
error were corrected before the successful primary package reruns.

## Deliberately separate

The [November 4 record](session-hotpaths-2026-11-04.md) remains historical evidence
for the original point-read decision, not the source or timings of this bulk
implementation. General typed control polling remains unchanged. The existing
[group-commit evaluation](group-commit-evaluation.md) still recommends deferring
production batching; this read change adds no write batching or durability
policy. Issues #1150, #1151 and #1152 retain their distinct scopes. No live
daemon was upgraded or restarted.
