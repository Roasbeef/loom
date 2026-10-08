# Large code-result wrapping

Measured October 8, 2026 on macOS arm64 with Gleam 1.19.0 and OTP 29.
The installed client and daemon identified build `ae262a813`; implementation
`1488a4e7b` changes only the terminal package. The source checkout was preserved
by working in `.worktrees/linear-code-wrapping`.

## Diagnosis

A completed code-mode result carried a scalar value of 1,091,874 characters.
Its longest raw line held 820,929 characters. The shared expanded projection
JSON-quotes the scalar, producing a 1,248,958-character fenced code row. The
model-visible tool text was bounded to 4,213 UTF-8 bytes; that bound does not
apply to the terminal's expanded detail. The session database was inspected
read-only, and no transcript content or session credentials are published here.

A ten-second Pickglass sample found 911 of 1,000 active/runnable client
observations in the grapheme conversion path below `take_span_cell` and
`etui/text.cell_width`. Seven thousand other client observations were waiting.
These are sampled safe-point observations, not percentages of elapsed CPU.
After detaching the profiler, a 10.18-second OS interval measured the client
at 100.55% CPU and the daemon at 0.59%. Both code-mode calls had already
returned, so this does not measure daemon CPU during their execution.

A separate 5.09-second allocation trace, restricted to the two application
modules `tui/markdown` and `etui/text`, counted 382,873,114 allocated words
(3.06 GB with eight-byte words). This is cumulative allocation, not retained
memory. The profiler released its pins and unloaded its agent before the
untraced OS sample. No resident process was restarted or collected.

The old hard wrapper measured the whole remaining span, segmented the whole
remaining string, then concatenated its remaining graphemes back to a string
for every output row. With a fixed terminal width this repeats work over
successively shorter suffixes and is quadratic in the source length.

## Implementation

`CellSpan` holds a style template, its remaining grapheme list and the sum of
those graphemes' cell widths. Original spans are segmented and measured once.
A continuation shares the unconsumed list tail and subtracts the width actually
consumed. Only completed row fragments are concatenated. A positive budget
still consumes at least one grapheme when a two-cell glyph exceeds the budget.
Empty spans, zero-width graphemes, repeated code and line-number gutters,
indentation and styles retain their previous behavior.

The terminal still retains complete expanded output. No output cap, wire or
provider change, dependency, production FFI or compiler flag is introduced.
The existing test-only probe gains an OTP reduction-counter read because pure
Gleam cannot inspect scheduler accounting.

## Measurements and regression proof

Old and new modules ran in separate disposable VMs with the same candidate
dependency closure and an 80-cell width (78 source cells after the gutter).
The old module was loaded from the installed client's BEAM, without changing
that client. Each VM wrapped a 1,000-character warm-up before the measured
sizes. Three old/new pairs ran sequentially; the table gives medians.

| Source characters | Old time | New time | Old reductions | New reductions |
| --- | ---: | ---: | ---: | ---: |
| 10,000 | 48.701 ms | 1.093 ms | 6,886,480 | 229,918 |
| 20,000 | 223.496 ms | 2.371 ms | 27,388,813 | 456,009 |
| 40,000 | 949.959 ms | 4.290 ms | 106,455,023 | 894,949 |

At 40,000 characters this is a 221-fold median wall-clock improvement and
about 119-fold fewer reductions. Host scheduling changes elapsed time; the
reduction counts show the growth independently of unrelated process CPU.
These observations are not a cross-platform latency guarantee.

The committed growth regression wraps 100,000 and 200,000 characters and
requires the larger case to use less than three times the reductions. Injecting
only the old installed wrapper makes that regression fail its assertion:
645,348,904 reductions versus 2,564,579,760 (3.97 times), exit 1 after 25.06
seconds. The candidate passes. This is an executed negative control, rather
than a claim inferred from the code.

The direct million-character regression retained every source character and
style across 12,821 output rows and passed in 0.266 seconds. The wire-to-frame
fixture feeds a million-character scalar through the real wire decoder,
reducer, Ctrl-G transition and rendering cache; it passed in 1.234 seconds and
asserts that the complete value remains cached beyond the visible viewport.
A separate deterministic comparison of 500 small styled fixtures, including
combining sequences, emoji, CJK, tabs, zero-width and empty spans, and widths
from -2 to 17, produced byte-identical serialized row terms under both modules.

The actual private database value was also replayed through `render_detail`
and `wrap_lines` at width 120 in an isolated VM. Rendering and wrapping
completed in 532,840 microseconds and produced 10,588 rows. This is a single
replay observation; the running client has not been replaced, so recovery of
that resident process is not claimed.

## Verification

The focused Markdown suite passed all 50 tests, and the full expanded-result
fixture passed. Static gates passed with zero lint and documentation errors.
The complete affected run returned exit 0 in 452 seconds, including fresh
fixture shipment preparation, the full client and TUI suites, and a skip
census with no undeclared skip. Independent review found no actionable
finding and independently passed all four new regressions. Its additional
888 styled Unicode and boundary fixtures matched the old splitter exactly.

Reproduce the focused proofs with:

```sh
bash scripts/test.sh tui --match markdown_test
bash scripts/test.sh tui --match expanded_million
LOOM_TEST_PARALLEL=8 make check-affected BASE=ae262a81374542b7cdbf63b3983a48c77c5a2e01
```

The repository selector reports `signoff not-required` for this terminal-only
change. Its affected client and TUI gates plus targeted proofs and a
review with dispositioned findings are the documented local acceptance rule.
Hosted CI for the published PR remains a separate gate. The running client
has not been updated, and no merge is authorized by this report.
