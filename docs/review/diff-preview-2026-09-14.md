# Diff previews

Based on main `b2a07936`, this change adds file line numbers to unified diff
presentation and raises compact patch previews from 24 to 60 lines. Removed
rows use old-file coordinates; additions and context use new-file coordinates.
Ctrl+G still exposes the full stored patch. Stored tool results are unchanged.

The parser follows each hunk's ranges and stops assigning coordinates when
its counts are exhausted or input is unfamiliar. Non-unified apply_patch
input remains unnumbered. Wrapped source repeats its coordinate; when the
whole gutter would consume the pane, source wraps without a gutter.

Validation passed: the full TUI gate (494 tests), TUI lint, formatting, and
documentation checks. Independent review found the narrow-pane gutter case;
the fix and six-column regression were rechecked with no further findings.
Tests cover multiple hunks, omitted counts, zero-length ranges, no-newline
markers, malformed ranges, header-like source, Unicode cell wrapping, and
compact expansion through actual transcript rendering.

A pre-existing producer limitation remains: nearby hashline edits can include
context removed by an earlier hunk, yielding a negative later new-file start.
The renderer leaves such a hunk unnumbered instead of guessing. This change
does not repair the producer or change the stored patch.

Hosted CI and Linux signoff remain required before merge. The earlier remote
signoff approval question remains unanswered; this branch does not retry it.
The user's installed client and daemon are unchanged.
