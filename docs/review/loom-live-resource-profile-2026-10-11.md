# Live daemon resource profile, October 11, 2026

Pickglass attached to the installed Loom 0.2.0 daemon at commit
`2ff7512acb31f6c52e7a60a4ec5bd2a35535e866`, while four sessions and eight
strands were present. This is main before PR #949, not the worktree candidate.
The daemon was neither restarted nor hotpatched. No forced garbage collection
was requested. Raw captures stay local because they contain live process and
owner identities; the adjacent JSON contains aggregate counters and function
names only.

## Memory observations

| Counter | First snapshot | Later passive snapshot |
| --- | ---: | ---: |
| VM total allocated | 272.60 MiB | 254.51 MiB |
| Process allocation | 199.74 MiB | 180.71 MiB |
| Refcounted binary allocation | 26.36 MiB | 27.26 MiB |
| ETS | 1.78 MiB | 1.78 MiB |

OS RSS at the first observation was 327.75 MiB. The difference from VM
allocation is not a leak measurement. VM memory categories overlap and must
not be summed. Process allocation includes spare heap capacity; neither it
nor `processes_used` establishes reachable retained memory. All 200 detailed
process rows had empty queues at the first cut, out of a node with 500
processes. This does not establish that every node queue was empty.

Total allocation fell by about 18 MiB between passive cuts without a forced
collection. The workload was active and unmatched, so this is natural
variation, not an optimization result or evidence for a particular lifetime.

## CPU sample

The busiest listed processes were selected by reductions per second, excluding
Pickglass agent processes. A ten-second, sixteen-process stack sample completed with 10,000 observations:
297 running, 83 runnable and 9,620 waiting. Percentages below use the 380
running/runnable observations, not wall-clock CPU time or all node processes.
Stacks are depth-limited and sampled at safepoints; long NIFs can be missed.

| Function | Flat observations | Inclusive observations |
| --- | ---: | ---: |
| `esqlite3:fetchall1/2` | 69 | 69 |
| `gleam_erlang_ffi:select/2` | 39 | 48 |
| `string:bin_search_loop/5` | 39 | 54 |
| `string:trim_t/3` | 21 | 115 |
| `string:bin_search_inv_n/3` | 19 | 21 |
| `esqlite3:q/3` | 16 | 85 |

The trim stacks include `web_view@view@fold_row:step_body/4` and
`session_view@step_words:failure_sentence/2`, beneath lane rendering. SQLite
stacks include transcript scans, register reads and snapshot cells. Those
observations support the existing storage work and identify another repeated
rendering cost; they do not measure the candidate's live CPU savings.

A separate four-process call trace for `storage@sqlite` and `core@json` hit its
100,000-event budget after 188 ms. It is a truncated interval, not the requested
five-second window, and is not used to extrapolate a daemon-wide rate.

## Allocation sample

The eight-process allocation probe covered `core@json`,
`web_view@view@fold_row` and `session_view@step_words`, not every module. It completed in 5.119 seconds with 162 matched
functions, 90 called functions and no unread or invalidated counters. On this
64-bit VM it counted 18,338,749 words, or 146,709,992 bytes of cumulative heap
allocation. This is allocation over the interval, not retained memory, RSS,
or total native/binary allocation. Untraced work can be charged to a traced
ancestor; function costs are therefore leads for controlled experiments.

| Function | Calls | Allocated bytes |
| --- | ---: | ---: |
| `core@json:cut/2` | 113,264 | 33,347,536 |
| `core@json:-parse_string_body/2-anonymous-0-/4` | 105,204 | 17,994,456 |
| `web_view@view@fold_row:-line_row/2-anonymous-0-/2` | 52 | 14,444,592 |
| `core@json:skip_whitespace/1` | 131,698 | 10,843,848 |
| `core@json:parse_escape/2` | 57,135 | 7,772,848 |

The complete sanitized function counters are in the adjacent JSON. JSON parsing
is the next allocation lead. Its total-decoding and UTF-8 behavior need a
matched parser fixture before changing representation or slicing. The sample
does not establish that removing one parser allocation saves its entire
attributed cost elsewhere.

## Implemented rendering change

A failed step previously partitioned rows, joined the engine refusal and
trimmed it before visiting the row memos on every web update. Its words and
rows are immutable between unrelated updates. `fold_row.step_body` now draws
the entire failed body inside one leaf memo keyed on those two values. Rows
inside that leaf are drawn directly, preserving Lustre's rule against nested
memos. Successful and pending steps retain their per-line leaves.

The source change is commit `a226609f1`. The real Lustre cache regression counted four OTP `string:trim/2` calls for
one unchanged failed-body patch on baseline `439bb846c`. The candidate counts
zero on each of two successive hits. Changing words alone or rows alone
invalidates the leaf; blank refusals preserve row order, and refusal text stays
escaped in HTML. An empty failed body stays empty, preserving the absence of
an expansion chevron. Independent Astra review checked the actual pure drawing
callback and the absence of nested memos. Its test observation led to isolating
the row-only invalidation case.

These counters prove elimination of repeated trimming for this fixture. Live
CPU and retained-memory savings remain unmeasured until an approved deployment
and a matched capture. The installed daemon is unchanged.

## Reproduction

Use `pickglass attach --state-dir "$HOME/.loom" --once --out before.pgcap` for
a passive cut. The CPU probe is `pickglass profile --state-dir "$HOME/.loom"
--top 16 --seconds 10 --rate 100 --format pgcap --out cpu.pgcap`. The allocation
probe uses `--allocation --top 8 --seconds 5`, with one `--module` for each of
the three modules above. Keep capture outputs private. `pickglass view` opens
a capture and `pickglass compare` compares two; compare matched workloads
and builds before attributing changes. The JSON records UTC snapshot times;
the report date is local Pacific time.

Validation passed: six focused preprocessing tests, the final
`make check-web_view` with 956 tests, and the broader
`LOOM_TEST_PARALLEL=8 make check` with 3,835 client, 1,331 TUI and 98
conformance tests, Go tests and zero house-lint errors. The final web-only
check covers the empty-body regression added during the broader run.
`make doc-check` passed with 198 existing warnings and zero errors.
