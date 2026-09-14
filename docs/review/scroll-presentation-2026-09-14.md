# Transcript scrolling

The scrolling work separates periodic projection cost from terminal output
volume. Loom PR #401 fixes the former; etui PR #1 implements issue #367 for
the latter. Etui PR #1 is merged into the fork main branch at
`22554e85ecb54e92d3c3afe734f42e0ed2eca5ec`, with its hosted checks passing.
Both changes have independent adversarial review and local regression coverage.

## History refresh

At Loom base `4c266dde`, metadata refreshes and incoming live text rebuilt
source anchors while the reader was looking at frozen history. Each rebuild
projected and sanitized every retained durable message. PR #401 reuses the
anchors under the existing durable-row layout key. Pending records, width,
strand, detail mode, and empty anchors still force rebuilding.

On a captured 600-record transcript at 272×84, metadata refresh fell from
about 51 ms to 9 ms. An eight-second native PTY drive delivered 480 wheel
reports: the baseline had 11 paint-output gaps above 50 ms, and the cache
fix had none. The two reuse regressions fail against unchanged production
code; layout and help transitions are also compared with fresh projection.

## Terminal output

The etui renderer considers vertical shifts from one to eight rows in either
direction when most screen rows changed. It samples cells to select a shift,
then checks every cell when constructing the residual diff. A candidate is
used only when its complete ANSI output is smaller than the ordinary diff.

A static sidebar shares terminal rows with Loom's transcript. Whole-row
identity therefore misses useful movement. The renderer shifts full-width
terminal rows and repairs sidebar cells inside the synchronized update.
Fixed and inline viewports retain ordinary cell diffs because they do not
own the complete terminal width and scroll margins.

The xterm oracle applies the emitted sequences and compares the final screen
with a full repaint. All 102 transitions matched; 92 emitted scroll commands.
Coverage includes both directions, wide characters, colored blank rows,
hyperlink destinations, edits during scrolling, and restored margins.

A paired 120-transition benchmark of the captured transcript emitted
1,068,148 bytes with scroll presentation versus 1,581,204 bytes with ordinary
diffing, a 32% reduction. Median diff time rose from 2.07 ms to 3.25 ms. The
native eight-second wheel drive emitted 4,193,458 bytes versus 5,549,154 bytes,
a 24% reduction. Both drives delivered 480 inputs and had no paint-output
gaps above 50 ms. These are CPU and PTY-output measurements; they do not
measure how quickly the user's terminal emulator paints a frame.

## Validation and continuation

The scroll implementation passed 911 Erlang tests, 862 JavaScript tests,
format checks, and the xterm oracle. Loom's integration passed
`make check-tui` (475 tests), `make check-client` (1,783 tests), and
`make doc-check`. Hosted checks and Linux signoff must be read on the final
PR commits before making merge-readiness claims.

The fork consolidation exposed a Linux/OTP 28 PTY fixture failure: an unset
`TERM` made OTP decline raw-mode setup. The probe now declares its terminal
type and asserts raw-mode flags before sending Ctrl+S. Quit, kill, and SIGINT
restoration pass on macOS and in the Linux reproduction. This fixture change
does not alter the frame presentation benchmark.

Issue #371 remains separate: live-tail markdown caching must satisfy the
retained-memory bound. Issue #345 tracks upstreaming the fork stack; merging
it into the fork's main branch does not upstream it.
