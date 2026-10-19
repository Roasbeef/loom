# Mermaid in terminal graphics

**Status:** Partly implemented. The TUI draws a text subset in-process; the PNG path below remains unexplored.
**Date:** 2026-10-18, updated with the text renderer.

[Protocol-change 091](../../protocol-change/091-isolated-mermaid-diagrams.md) accepts web-first Mermaid rendering: the transcript keeps source text, and an isolated browser frame renders it. That boundary is unchanged for the web view.

## What the TUI does now

The TUI draws flowcharts (`flowchart` and `graph`, all four directions) and sequence diagrams as box-drawing text, in process, as pure Gleam (`tui/mermaid` and `tui/mermaid/*`; `tui/CLAUDE.md`, "Mermaid diagrams"). It needs no graphics probe, no converter, no isolated execution and no image cache, because the output is ordinary styled text that scrolls, wraps and replays like any other transcript row, and plain and `NO_COLOR` palettes get it unstyled. The renderer is bounded rather than isolated: source 16 KiB, 32 nodes, 48 edges, 40 cells per label line and a 64K-cell canvas, with a bounded search for edge routes. Model-influenced source never executes; it is parsed by a total reader.

Anything outside that subset, such as subgraphs, styling, directives and every other diagram type, is a typed refusal, and the transcript shows the source with a line naming the reason. A diagram too wide for the pane is drawn in the transposed direction or refused. Settled rows draw the diagram; the live tail shows the fence as source until the answer settles, because a diagram is the costliest block to draw again on every delta.

The sections below are the earlier exploration of drawing a rasterised diagram through the PNG path. It is still not proposed, and it would only matter for diagram types or fidelity the text subset cannot reach.

## Existing image path

The TUI already draws transcript PNGs through etui. `tui/image_support` probes once before the interactive loop and selects `KittyPlaceholders`, `Iterm2Inline`, or `TextOnly`; plain palettes, non-empty `NO_COLOR`, and an unanswered/unsupported probe use `TextOnly`. The probe result remains fixed for the process lifetime.

`tui/image_box` keeps the placeholder unless support, media type, size, and geometry checks pass. Kitty/Ghostty use U+10EEEE placeholder cells, which scroll and clip with transcript text. `tui/image_plan.settle` inspects the visible transcript window after the frame cache is refreshed, then reconciles it through `tui/image_shown`. Kitty/Ghostty upload, place, and remove images as boxes enter, move within, and leave the viewport. iTerm2 uses OSC 1337 and blank cells; the image is drawn after its frame and erased or redrawn when the frame or viewport changes. Quit removes uploaded Kitty images before leaving the alternate screen.

The current Kitty path accepts PNG only and caps decoded image data at 4 MiB (`image_box.max_bytes`). Image boxes are height-limited against the terminal viewport. Image identity is a stateless 24-bit hash of the image fingerprint (`image_box.id_of`); collisions are possible. The render cache and shown-image fits track viewport dimensions, but any new generated-image cache would need its own invalidation rules. Source references: `packages/tui/src/tui/image_support.gleam`, `image_box.gleam`, `image_plan.gleam`, `image_shown.gleam`, and `tui/CLAUDE.md`, “Drawn images.”

## Possible future contract

If terminal diagrams are pursued, reuse this PNG path rather than adding a second Kitty renderer. A conversion boundary would need to accept Mermaid source and return a bounded PNG, or a typed refusal that leaves source visible. Keep conversion outside the harness VM: model-influenced source must not execute there. The browser implementation in protocol-change/091 does not provide a TUI SVG-to-PNG API, and it must not be treated as one.

A future source-to-SVG-to-PNG converter needs an explicit isolated execution contract before implementation. It must pin the renderer, disable HTML labels and external resource loading, reject configuration and navigation directives, bound source length, graph edges, output dimensions and work, and return only raster bytes. The protocol-change/091 browser restrictions are useful precedent, but its browser wait limit is not a hard CPU deadline; a terminal converter needs an execution boundary with an actual deadline and resource limits.

Keep the source fallback visible whenever probing fails, conversion refuses or fails, output exceeds limits, or a diagram is folded. Before drawing, verify all of these gates:

- **Capability:** only draw after the existing positive graphics probe; retain source in replay, scrollback, plain palettes, and unsupported terminals.
- **Viewport and redraw:** draw only complete visible boxes. Reconcile on scroll and frame changes; handle overlays and resize without stale placements.
- **Fold:** source-folding behavior must not make a failed or unsupported diagram disappear. Define whether expanded source and image are mutually exclusive.
- **Identity:** avoid relying on the existing 24-bit content fingerprint as a collision-free artifact ID. Define stable per-diagram IDs and removal behavior.
- **Budgets:** cap source bytes, output bytes, pixel count, dimensions, and conversion time independently. The existing 4 MiB byte limit alone does not bound decoded pixel memory.
- **Cache:** key output by source and renderer version, and invalidate on source edits, theme/config changes that affect rendering, and renderer changes. Bound retained cache size and tie uploaded-image lifetime to viewport membership.

Kitty’s [graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/) documents image transmission, placements, Unicode placeholders, and deletion. Loom already uses placeholders for Kitty/Ghostty; this exploration recommends reuse of that path, not new Kitty protocol machinery. iTerm2 remains a separate post-frame drawing path. No renderer, converter API, dependency, or TUI behavior is proposed as settled here.
