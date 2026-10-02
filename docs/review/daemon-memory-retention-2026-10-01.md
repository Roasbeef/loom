# Daemon closure retention, 2026-10-01

Status: source fixes independently reviewed; normal installed-daemon comparison
and full repository gate completed. This note records measurements rather than
an estimate of how much of the operator's footprint a source change must remove.

## Initial live attribution

The installed daemon was PID 86183, built from
`f84842d17bc3230c2a796f136d222b5179b5be28`. Its first observational census,
before retained-state inspection, reported:

| Accounting | Initial measurement |
| --- | ---: |
| BEAM total | 1428.453 MiB |
| BEAM processes | 1380.556 MiB |
| BEAM processes used | 1380.510 MiB |
| BEAM binaries | 7.941 MiB |
| Allocator carriers | 1482.156 MiB |
| OS RSS | 1685872 KiB |

Process heaps dominated. The live-process census attributed 647.813 MiB to
weft actors, 476.870 MiB to static supervisors, 122.202 MiB to state machines,
and 114.779 MiB to factory supervisors. The two largest static supervisors
held 161.449 and 161.246 MiB with empty mailboxes. They were already
hibernated, with no old heap. Those supervisors retained large live graphs;
queued messages, reference-counted binaries and helper RSS did not explain
the measured total.

One supervisor's retained state had a flat-copy size of 364383848 bytes. Its
actual process allocation was 169291248 bytes. These numbers measure different
things: `flat_size` counts repeated references as a copied term graph, while a
process heap can share subterms. Flat-copy measurements identify a copying
hazard; they cannot be subtracted directly from resident memory.

A diagnostic attempt copied a large state into an observer and raised the
process's historical footprint peak to about 2932 MB. That peak is excluded
from the baseline. Later normal-daemon measurements must be compared with
matching resident sessions and workload. No forced collection or restart was
used during initial attribution. The installed comparison below used a graceful
restart to reconstruct the closures from the candidate release.

## Confirmed retained paths and the fix

A large child-specification startup closure retained `Runtime`, whose
`Effects.provider` accounted for 23016192 flat bytes. The tool surface accounted
for 5782360 flat bytes. Provider callbacks retained two unnecessary paths into
the executable tool registry:

```text
static supervisor child specification
  -> serve startup callback
    -> Runtime.effects.provider
      -> request/prepare facade
        -> summary observer -> summary_tap -> wiring.Config -> registry
        -> provider request preparation -> wiring.Config -> registry
```

The summary observer occupied 5754936 flat bytes. Its classifier needed only
the opened session and the existing projected image-classification rule.
`client/serve.gleam:6920` now constructs the callback through the session-only
classifier at `client/wiring.gleam:1193`. The classifier retains the same
operation scan, continuation handling and context-image rule.

Provider request preparation needs routing, the session, the system prompt,
and immutable tool definitions. `client/wiring.gleam:281` and
`client/wiring.gleam:293` express those inputs with private records. The
projection at `client/wiring.gleam:313` retains each tool's name, description
and schema. `Effects.tools.run` continues to own the original executable
registry and policy inputs. Active tool selection still comes from each
request's durable configuration, and definitions remain sorted, deduplicated,
and filtered to registered names.

The changes are commits `938892fdb` and
`3819fec3d4ea999f51c6504b31c4d9b5d68c1501`.

## Regression and independent review evidence

The retention fixture holds tool count and metadata constant while increasing
executor payloads. On this 64-bit BEAM, a word is eight bytes:

| Retained surface | Old light / heavy words | Fixed light / heavy words |
| --- | ---: | ---: |
| Image classifier | 3339 / 109809 | 421 / 421 |
| Provider facade | 6683 / 219623 | 6005 / 6005 |

The fixed registry still grew from 2701 to 109171 words, and its executable
tool surface grew from 3570 to 110040 words. Restoring each old capture caused
its new retention assertion to fail. The held-image batch test exercises the
production classifier through summary observation and preserves admission,
dispatch, continuation and successor-run classification.

The focused wiring suite, client lint and documentation gate passed. With
Gleam 1.19.0-rc2, OTP 29, the prepared code-mode seed and working native sandbox
launches, the complete client gate passed all 2610 tests. The repository-wide
`make check` then passed every package and lint, with zero lint errors and
963 warnings from the warning-tier rules. Shipped-release
fixtures require their explicit launcher environment; the separate release
smoke passed authenticated control, two admissions, metadata-only startup,
shared-domain distillation, helper discovery, bundled code-mode registration,
and clean SIGTERM handling.

A fresh independent review found no introduced correctness or retention
regression. It confirmed an existing metadata-only context callback at
`client/serve.gleam:4238` also retains the executable registry, and an existing
`directories.admin` callback at `client/serve.gleam:4225` retains `Runtime`.
Those paths predate this delta. Their incremental resident costs are unmeasured;
no additional ownership mechanism was added to this fix. The measured code-mode
router wrapper also remains a candidate for a separately scoped capture fix.

## Matched isolated release measurement

The installed baseline and the candidate release used the same offline release
configuration and control-plane probe. Each run used a fresh private HOME,
state root and workspace, admitted two empty sessions, stopped the first, and
left one resident. Both used observational censuses, the same 15-second idle
period, and no forced collection or retained-state walk.

| Cut | Installed BEAM total / processes, MiB | Candidate BEAM total / processes, MiB |
| --- | ---: | ---: |
| Listening, no session | 55.046 / 14.636 | 56.736 / 16.026 |
| Two admitted, one stopped | 96.999 / 48.109 | 83.617 / 34.297 |
| After 15 seconds idle | 89.382 / 40.489 | 77.835 / 28.515 |

At the idle cut, RSS changed from 130560 to 118144 KiB, and macOS `footprint`
reported 119 MB versus 105 MB. The observed BEAM reduction was 11.547 MiB in
total and 11.974 MiB in process memory. This bare fixture has a smaller tool
graph than the operator's daemon. It proves a resident improvement for this
fixture. The normal comparison below exercises the larger operator tool graph.

## Normal installed comparison

The authenticated graceful restart retired baseline PID 86183 and reconstructed
the normal daemon as PID 56416 from candidate commit
`3819fec3d4ea999f51c6504b31c4d9b5d68c1501`. The operator's TUI reattached, and
the same two original resident sessions and four strands were restored. No
forced collection was used on either side.

| Accounting | Before restart | Candidate, settled sample |
| --- | ---: | ---: |
| BEAM total, MiB | 1298.933 | 445.108 |
| BEAM processes, MiB | 1250.005 | 397.183 |
| BEAM binaries, MiB | 8.284 | 8.085 |
| Static-supervisor heaps, MiB | 476.870 | 111.831 |
| Largest static-supervisor heap, MiB | 161.449 | 39.670 |
| OS RSS, KiB | 1366736 | 517920 |

The final candidate RSS sample was collected 2 minutes 57 seconds after start,
after the first post-start census and a further idle observation. Both resident
sessions reported no working strands at that observation. Hooks rearmed after
restart, and the live-process census changed from 233 to 238 processes, so this
is a reconstructed resident-session comparison rather than an otherwise
identical instruction-by-instruction workload. The earlier initial 1428.453 MiB
census remains historical evidence, not the denominator for this comparison.

The settled normal comparison shows 853.825 MiB less BEAM memory, about 65.7%,
with 852.822 MiB of the reduction in process accounting. RSS fell about 62.1%.
The supervisor reduction and nearly unchanged binary accounting support the
measured closure-retention cause. RSS and macOS physical footprint are separate
OS measurements; this normal comparison does not substitute the screenshot's
physical-footprint value for its RSS readings.

No retained-state inspection followed these candidate censuses. The remaining
445.108 MiB has not been assigned entirely to the existing context, admin or
code-mode captures. Those paths remain scoped follow-up candidates rather than
an assumption that another metadata projection will remove the remainder.
