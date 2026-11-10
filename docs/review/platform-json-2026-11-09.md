# Platform JSON: compatibility and fixed replay

The selected Erlang decoder builds Loom's ordered JSON values through OTP
callbacks. JavaScript and encoding retain the reference implementation.
`json_codec.Codec` exposes immutable callbacks; production byte boundaries use
the convenience functions. [The package architecture](../../packages/json_codec/README.md)
maps selection and ownership, and [ADR-023](../adr/023-platform-json-keeps-the-portable-contract.md)
records the scoped FFI exception. No external enters pure core.

## Sources and method

The reference source is main `72b8aadd2f8bca1f92c785831c8a5c77be15f966`.
The reviewed codec and byte-boundary implementation is `61b1f5b18`. Later
changes update documentation and the lint package inventories; the codec and
production integrations remain unchanged.
Saved baseline artifacts were copied before integration:

| Artifact | SHA-256 |
| --- | --- |
| `core@json.beam` | `8be399bd827ad04fc0ae14654eaa66a7304de1a3deec27ab9d9cc7b154dd3ce8` |
| `storage@sqlite.beam` | `9138bb2a93f65480abfdc768e0918921af05e73f4b9835df22e00cb852197859` |
| `storage@internal@register_cache.beam` | `49c3dfe23e37d6b847464d90143ea262004b2ba1a345556ebe42d36ee4ed8d52` |

The [committed replay](../../scripts/platform_json_replay.erl) runs in a
non-distributed disposable VM on Darwin arm64, Gleam 1.19.0, OTP 29 and
ERTS 17.0.5, with one normal scheduler. Baseline and candidate run in the same
VM over identical synthetic inputs. Timing is untraced and alternates order
over eight rounds. Four separate allocation rounds trace only operation roots,
charging untraced callees to those roots without double counting descendants.
Tables use medians, including the mean of the middle pair for even samples.

Resident daemons and client validation remained active on the host. These are
fixed-fixture timing results, not a globally quiescent machine or installed
daemon latency measurement. Allocation guards are the reproducible performance
criterion. Heap words exclude refcounted binary payloads, native allocations,
reachable heap, RSS and footprint.

## Complete contract checks

All 25,700 parser comparisons preserve complete results, including ordered
values and every field of `CorruptionReport`. The corpus combines 23,004
existing raw-byte/UTF-8/truncation/depth/duplicate cases with 2,696 whitespace,
numeric and root/nested zero-float cases. Another 1,789 values preserve exact
encoder bytes, covering controls in keys and values, literal backslash-u text,
Unicode, float spelling, large integers and hand-built duplicate fields.

Native success does not use OTP's default maps. Fixed callbacks preserve field
order, reject duplicate decoded keys, check core's depth limit and require an
empty remainder. Native refusals delegate the original input to core. A
call-count witness requires one OTP decode and zero reference parses for an
ordinary successful document; duplicate refusal requires one of each.

Independent review found that OTP loses the sign of exponent-only negative
zero before the float callback. `-0e0`, its array form and its object form
reproduced the mismatch. The adapter now delegates every zero-valued float to
the original-input reference parse. The review independently checked all 27
new root/array/object zero lexemes after the fix; a zero fallback call-count
witness also requires one OTP decode and one reference parse.

Five isolated semantic mutants are rejected by returned-result differences:
omitted duplicate checking, disabled depth bound, ignored trailing bytes,
missing boolean wrapping and missing zero-float fallback. Mutants never edit
the source or a running daemon. Compilation failures or exceptions fail the
harness and do not count as kills.

The ownership witness retains 96 decoded bytes from a 1,048,679-byte input;
both implementations reference that complete backing binary. The adapter
does not establish improved retention.

## Decoder results

Each compact fixture uses 10,000 calls per timing/allocation round; each large
fixture uses 50. Values below come from the final reviewed replay.

| Fixture | Reference µs/call | Selected µs/call | Speedup | Reference words/call | Selected words/call | Fewer words |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Register | 3.965 | 1.303 | 3.04× | 1,948 | 492 | 74.74% |
| Stream delta | 3.997 | 1.347 | 2.97× | 1,770 | 444 | 74.92% |
| Mixed array | 3.787 | 1.183 | 3.20× | 1,908 | 385 | 79.82% |
| Whitespace | 1.112 | 0.675 | 1.65× | 551 | 222 | 59.71% |
| Long plain text | 453.28 | 60.55 | 7.49× | 278 | 223 | 19.78% |
| Escaped text | 1,743.61 | 309.73 | 5.63× | 422,946 | 27,101 | 93.59% |
| Transcript | 8,811.42 | 1,615.80 | 5.45× | 1,482,223 | 124,517 | 91.60% |

Every decoder fixture must allocate at least ten percent fewer words. The
unchanged-candidate control retains all compatibility checks but substitutes
the portable implementation for measurement. It exits one specifically with
`no_improvement`; the positive replay exits zero. The final guard directly
checks the ten-percent condition, which also rejects regressions.

## Real SQLite path

Saved and current SQLite modules are recompiled with identical options into
separate aliases. The saved module selects the saved register-cache helper;
the candidate selects its current helper. Two real actors therefore execute
the existing query, register cache, total typed decode and reply-copy paths.
Each run owns an exclusive fixture directory; each trial uses a fresh database
path. Every returned register payload is checked against its fixture value. GC/state inspection and live-daemon profiling are absent.

| Fixture | Reference wall µs/batch | Selected wall µs/batch | Reference actor words/batch | Selected actor words/batch |
| --- | ---: | ---: | ---: | ---: |
| Warm cached, 1,600 reads | 103,000.5 | 100,613 | 512,000 | 512,000 |
| Oversized, 12 reads | 422,019 | 156,936 | 122,535,174 | 15,182,016 |

Oversized payloads bypass the existing cache and must decode on every read.
Their batch wall time improves 2.69× and actor allocation falls 87.61%; median
actor reductions fall from 26,332,943 to 22,155,562. Cold-read medians improve
from 11,031 to 6,876.5 µs for that fixture. Warm cache hits allocate exactly the
same amount. The fixture exercises decoding and actor copying, not a new cache
policy or reduced query count.

## Encoding decision and proof limits

The experimental OTP encoder preserved exact bytes through a compatibility
scan, but compact object encodes were roughly twelve to thirteen times slower.
Large escaped strings improved. The selected package therefore retains core's
encoder on both targets, preserving spelling by construction and reducing FFI
surface. A compiled-function guard requires `json_codec.to_string` to consist
solely of a direct call to core's unchanged encoder. Encoder timing/allocation
is reported but carries no improvement claim.

A preliminary decode-only replay incorrectly required no measured allocation
increase for unchanged encoding. Binary-builder allocation varies with GC
history, and that run failed on tiny differences. Its failed receipt is
retained; the final structural guard proves unchanged selection and all exact
encoder comparisons remain. The redundant preliminary decoder `C <= B`
assertion was also removed after review: the stronger `C <= 0.9 B` condition
already implies it and gives the negative control its named failure.

The corpora are fixed and broad, not exhaustive. Documents containing
zero-valued floats or native refusals can parse twice. No live installation,
restart, hot patch, GC, state walk or network change was performed. No installed
CPU, RSS, footprint or end-to-end session latency saving is established.

## Reproduction and validation

Build storage on the reference source and save its `core@json.beam`,
`storage@sqlite.beam` and `storage@internal@register_cache.beam` from
`packages/storage/build/dev/erlang/*/ebin` in a private baseline directory.
Build candidate storage and run:

```sh
bash scripts/platform_json_replay.sh "$candidate_checkout" "$baseline_directory" --expect-improved
bash scripts/platform_json_replay.sh "$candidate_checkout" "$baseline_directory" --noop
```

The first command must exit zero; the second must exit one with
`no_improvement`. Neither command connects to Erlang distribution or the daemon.
Raw local receipts are under `.notes/benchmarks/platform-json/`, particularly
`reviewed-replay.log`, `reviewed-noop.log` and the corresponding gate logs.

Final-codec validation passes six properties on Erlang and the same six on
Node, storage's 379 tests and provider's 359 tests. The final server shipment
build succeeds. Final focused client checks report 330 passes across goal,
protocol, gateway, daemon protocol, real TUI, multiplayer and live code-mode
fixtures. Runtime reports 217 passes, code mode 453 and conformance 116. These
selected native gates report 1,860 passes in total. One real-MCP fixture in the
client count prints the existing declared Darwin skip: process-death observation
requires `/proc`. It is not executed coverage. Conformance records Darwin's
actual degraded kernel-enforcement posture.

Final whole-tree static checks exit zero: house lint has zero errors and 2,947
warnings; doc-check has zero errors and 224 warnings; format, prelude and client
asset checks pass. The README's two Mermaid diagrams render. The script suite
passes all 131 tests with normal process visibility; its earlier sandbox run
failed four install-pruning fixtures. No test assertion or deadline changed.
Existing external dependency versions, checksums and git references are
unchanged. One independent review found and closed the signed-zero and
redundant-guard findings.

The earlier broad local run reports 6,372 client passes and one 60-second
`goal_e2e` completion timeout, with additional prerequisite skips. That VM used
the experimental encoder and predates the signed-zero correction; its result
is retained and is not a final full-client or aggregate pass. The unchanged
six-test goal module passes in the final focused run. A full final aggregate,
hosted CI and Linux signoff are not established by these local receipts; their
state is recorded separately in the PR.


## CI inventory follow-up

Hosted Linux fast-lane validation at `6477a5045` found three deterministic lint
inventory failures: the affected-package check order, qualified module roots
and exact expected daemon dependency set omitted `json_codec`. All three
failures reproduced locally before repair. The correction adds the package to
those inventories and extends the existing daemon-signoff assertion to it;
no assertion or deadline is weakened. The full lint package suite passes all
318 tests and house lint retains zero errors and 2,947 warnings. Exact-head
Linux validation and the final merge receipt are recorded in the PR.
