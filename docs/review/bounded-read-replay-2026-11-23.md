# Bounded inbox and snapshot read replay

The November 23 live profile and follow-up source inspection identified work
in inbox fitting, gateway snapshot assembly and SQLite snapshot reads. This
replay measures three
changes against `99d2430b7fab36e2c204ad483210393b91f639aa` using identical
inputs and complete result comparisons. The target was a tenfold reduction in
latency and allocated heap words under load.

## Changes and correctness checks

- The escalation transfer builds the local and relayed register keys once per
  requested ID. The replay extracts the actual missing-ID expression from
  baseline and candidate gateway BEAMs. Cases include empty cuts, local and
  remote matches, misses and changed cell order. The returned missing IDs
  keep request order.
- The inbox starts with the exact encoded size of the empty row, including
  counts and the waiting time. It fits newest prefixes in ask, stuck and find
  order. When the next item doesn't fit, dropping the older tail and every
  lower-priority section is equivalent to the existing reverse eviction
  order. The row accounts for each inter-item comma. A row with up to three
  items can return directly after one size check. The replay compares 256
  complete rows, including escaped text, UTF-8 and optional fields. Existing
  generated tests also check fit, maximality, priority and the original counts.
- SQLite accounts for the same complete header budget before reading values.
  Within the same deferred transaction it joins up to 256 admitted
  namespace, key and sequence identities at a time. The input ordinals
  preserve the previous decode order. The query plan searches the register
  primary-key index. A single header uses the previous point read. The replay
  compares complete cuts from zero through 1,024 cells, including 256 and 257,
  and checks legacy text, a bad SQLite type, an earlier corrupt payload, and
  large text containing NUL. The batch copies BLOBs and delegates other
  stored types to the point decoder in header order. SQLite counts only the
  text before a NUL for header admission, so the fallback also avoids copying
  multiple oversized malformed values before reporting the first fault.
  The memory backend walks the same header order.

## Matched results

The replay uses one disposable BEAM VM on Darwin arm64 and OTP 29, with one
normal scheduler. Six alternating untraced timing rounds report the median.
A separate root-only call-memory trace measures cumulative heap words. The
snapshot cases use a real SQLite connection and the production capture
transaction. The escalation case measures only missing-ID selection, and the
inbox case measures only row fitting. Heap words are cumulative allocation
for the measured operation. The replay leaves live memory and end-to-end
client latency unmeasured.

| Fixture | Before µs/op | After µs/op | Speedup | Before heap words/op | After heap words/op |
| --- | ---: | ---: | ---: | ---: | ---: |
| Inbox, three items | 6.51 | 6.61 | 0.99× | 1,154 | 1,160 |
| Inbox, 40 finds | 2,583.51 | 48.71 | 53.04× | 407,356 | 9,553 |
| Inbox, 32 asks, 30 stuck, 40 finds | 19,510.73 | 52.65 | 370.60× | 2,466,168 | 8,871 |
| Inbox, 40 items per section | 26,369.98 | 57.21 | 460.95× | 3,408,826 | 8,872 |
| Escalation lookup, mixed | 8.35 | 3.01 | 2.77× | 1,578 | 534 |
| Escalation lookup, all missing | 20.33 | 3.87 | 5.26× | 3,822 | 574 |
| SQLite capture, 0 cells | 367.21 | 345.68 | 1.06× | 7,555 | 7,549 |
| SQLite capture, 1 cell | 357.01 | 359.70 | 0.99× | 8,515 | 8,512 |
| SQLite capture, 16 cells | 1,064.65 | 683.60 | 1.56× | 23,330 | 22,898 |
| SQLite capture, 64 cells | 4,424.67 | 3,042.97 | 1.45× | 71,339 | 69,371 |
| SQLite capture, 256 cells | 23,307.13 | 13,472.00 | 1.73× | 262,364 | 254,252 |
| SQLite capture, 257 cells | 21,680.70 | 11,815.70 | 1.83× | 263,361 | 255,802 |
| SQLite capture, 1,024 cells | 48,163.60 | 25,849.07 | 1.86× | 1,099,582 | 1,074,997 |

The crowded inbox cleared 10× on both metrics, with 42.6× to 384.2× fewer
allocated words. The sparse inbox took 0.09 µs more and allocated six more
words. The escalation expression allocated 66% to 85% fewer words.
SQLite queries fell from 69 to 6 for 64 cells and from 1,029 to 9 for
1,024 cells. Complete cuts still return and validate every selected value.
At 1,024 cells, latency fell 46% and allocated words fell 2.2%. Empty and
single-cell captures used the same number of queries and allocated within
0.1% of baseline.

## Reproduce

Save these BEAMs from a baseline client or storage build into one directory:
`client@attention_feed.beam`, `client@gateway.beam`,
`storage@snapshot.beam` and `storage@internal@snapshot_sqlite.beam`.
Build candidate client, then run
`bash scripts/bounded_read_replay.sh /path/to/baseline-beams`.
The harness verifies complete results before timing all workloads and requires
a tenfold query reduction for captures of 64 or more cells. The recorded run
used the unchanged production paths on each side and synthetic, disposable
SQLite stores.
