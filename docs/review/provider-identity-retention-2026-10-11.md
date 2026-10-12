# Provider identity retention, October 11, 2026

The [JSON allocation comparison](json-decoding-allocation-2026-10-11.md)
left a 96-byte selected string referencing a roughly 1 MiB input. This follow-up
measures the lifetime of that backing binary against PR #949 head
`4c2c0a9821ff341c66f45585b03300f83967811b`. It adds a bounded copy at one
confirmed owner, the OpenAI-compatible response accumulator. Generic JSON
parsing and all other providers retain their existing ownership behavior.
The installed daemon is unchanged.

## Ownership and change

`provider/adapter/openai.handle_sse_data` parses an SSE event document.
`handle_chunk_document` selects `id` and `model` into `Accumulator.response_id`
and `response_model`, while ignoring unknown fields and later choices. Those
identities outlive the event document, surviving until replacement or attempt
release, and enter the settled assistant message. A compatible endpoint can
therefore leave a small identity referencing a large discarded event payload.
The fixture reaches that actual response machine with a large ignored field;
it does not establish how often real endpoints send such events.

Private handlers now carry the event's byte count to `retained_identity`.
A selected identity of 65–256 bytes is materialized only when the document is
at least eight times larger. On the measured OTP 29 runtime, slices through
64 bytes already materialize, so copying them adds no retention benefit. The
256-byte ceiling bounds each field's copy cost; the eightfold ratio avoids
copying an identity that occupies much of a small event. These are conservative
bounds, not thresholds proven optimal for all workloads.

Pure standard-library `string.concat([text, ""])` materializes the selected
field on OTP 29, whereas singleton concatenation can preserve the subbinary.
The implementation adds no FFI, dependency, public interface or wire change.
Missing and wrong-type identities still preserve the previous value. UTF-8
contents, parsing failures, usage processing and settlement order are unchanged.

## Method

`scripts/json_retention_perf.sh` runs a fresh single-scheduler OTP 29 VM with
Gleam 1.19.0 artifacts and eight-byte words. Baseline provider artifacts were
built from the exact baseline source and saved separately. Both final sides
use unchanged core JSON source; the adjacent JSON records source digests.
Three baseline/candidate comparisons ran sequentially in fresh VMs, without
owned repository gates or negative controls overlapping the final comparisons.
Other host activity was uncontrolled.

Each retention case creates its own disposable worker and independently
allocated input documents. The worker validates decoded values, tail-calls
into a holder, performs a full worker GC, and reports unique off-heap binary
allocations from `process_info(binary)`. It then releases every held value,
performs another full worker GC, and reports again. These collections affect
only synthetic workers. No installed process is collected or inspected.

Binary IDs are deduplicated within each worker. Selected backing sizes are
observations about references, not extra allocations to sum with binary bytes.
Process memory counters include allocated heap capacity; neither counter is
RSS, exact reachable-term size, or a live-daemon memory measurement.
[OTP's binary documentation](https://www.erlang.org/doc/apps/stdlib/binary.html#copy/1)
also explains why copying helps only when other owners release the backing input.

## Retention results

All three comparisons produced the same retained off-heap binary totals.
Both identity fields have the listed size; provider cases hold 16 accumulators.
Generic decoder controls hold 32 documents or selected fields.

| Owner and fixture | Before | After |
| --- | ---: | ---: |
| Provider, 96-byte ID and model, 1 MiB ignored payload | 16,781,495 B | 3,072 B |
| Provider, 65-byte ID and model, 1 MiB ignored payload | 16,780,503 B | 2,080 B |
| Provider, 256-byte ID and model, 1 MiB ignored payload | 16,786,615 B | 8,192 B |
| Provider, 257-byte ID and model, 1 MiB ignored payload | 16,786,647 B | 16,786,647 B |
| Provider, 64-byte ID and model, 1 MiB ignored payload | 0 B | 0 B |
| Provider, 96-byte identities, small event | 4,279 B | 4,279 B |
| Generic JSON, selected 96-byte field, 1 MiB sibling | 33,557,815 B | 33,557,815 B |
| Generic JSON, whole document retained | 33,557,815 B | 33,557,815 B |
| Generic JSON, original input still owned | 33,557,815 B | 33,557,815 B |

The eligible 96-byte provider case releases 16,778,423 backing bytes, about
16 MiB, while retaining 3 KiB of identity payload. Both fields reference their
own 96-byte backing allocations. After final release, every case reports zero
off-heap binary bytes. The unchanged cases deliberately retain sharing; this
is not a general fix for selected JSON strings or other provider adapters.

## Overhead

Timing passes trace nothing and exclude fixture construction and retention GC
probes. Provider events warm five calls and measure fifty, while the primitive
comparison warms 1,000 calls and measures 100,000. Medians and ranges below
normalize to one operation; every raw observation is in the adjacent JSON.

| Operation | Baseline median (range) | Candidate median (range) |
| --- | ---: | ---: |
| Small 238-byte provider event | 12.10 µs (10.24–14.72) | 12.46 µs (10.76–41.04) |
| Provider event with 1 MiB ignored payload | 38.75 ms (37.65–60.39) | 37.56 ms (35.60–65.84) |

The small-event reduction count rises from 1,943.42 to 1,951.48 per event,
about 0.4%. Large-event reduction counts are effectively unchanged. Wide
wall-time ranges prevent attributing a provider-event speedup or precise
wall-time overhead to this change on the shared host.

For a standalone 96-byte subbinary, singleton concatenation takes median
0.012 µs per operation and materialization takes about 0.089–0.092 µs across
the two sides. This isolates the copy primitive, including its list argument;
it does not include the provider lookup and size checks. Two eligible fields
copy at most 512 payload bytes per event. That transient copy can occur even
when another owner still retains the input or an escaped identity already
has independent backing. The pure implementation does not inspect backing
allocation sizes, so this is not an unconditional saving.

## Rejected global policy

An earlier experiment applied the same bounds to every singleton JSON string.
Selecting only 32 fields of 96 bytes reduced retained binary payload from
33,557,815 to 3,072 bytes. But retaining the whole document or original source
added 3,072 bytes without releasing the original backing allocation. Arrays of
2,048 retained fields made decoding 17.9% slower at 65 bytes, 21.0% slower at
96 bytes and 9.7% slower at 256 bytes in those separate three-run comparisons.
The final change discards that parser policy and copies only the provider
identities whose longer lifetime is explicit. The JSON retains those experiment
observations separately from final measurements. No global-policy source lands.

## Validation

The provider boundary check passes on the candidate and fails against the old
provider at its 65-byte fixture, with exit 1. It covers the 64/65 and 256/257
boundaries, small versus large events, and both ID and model backing sizes.
A new Gleam regression preserves multibyte identity contents through a later
event omitting identity and through settlement. Its focused run passed.
Independent production and evidence reviews found no actionable issue.
The source is committed at `11b411dba`. The full local
`LOOM_TEST_PARALLEL=8 make check` passed with exit 0, including 163 core,
301 provider, 3,835 client, 1,331 TUI and 98 conformance tests, Go sandbox
tests and zero house-lint errors. `make doc-check` passed with zero errors
and 198 existing warnings. The prior `4c2c0a982` head has green hosted CI and
Linux signoff; current-head validation is separate and recorded in PR #949.

Build core and provider with the same toolchain before comparing:

```sh
bash scripts/json_retention_perf.sh <baseline> baseline <baseline>/packages/provider
bash scripts/json_retention_perf.sh <candidate> candidate <candidate>/packages/provider provider
```

The final `provider` argument enables ownership assertions and must fail against
the old provider. Timing and retention results remain synthetic fixture evidence;
they do not attest to installed-daemon savings, physical-network behavior or
hosted/Linux validation of a different head.
