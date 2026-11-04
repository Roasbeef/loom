# web_mermaid

## Purpose

The internal browser program that runs only in the opaque Mermaid frame. It
is a JavaScript-target Gleam package, not a general Mermaid library and not a
dependency of `web_client`. The fixed bootstrap in `bundle/renderer.js`
injects the pinned vendor object into `start`; `bundle/` also holds the npm
lock, the notice collector and the frame document `mermaid.html`.
`make gen-client` compiles this program and bundles it with the vendor as the
separate `mermaid.js` asset. The session page's bundle never imports it.

The frame and its HTTP sandbox/CSP are unchanged from
[protocol-change/091](../../protocol-change/091-isolated-mermaid-diagrams.md).
The failure-diagnostic addendum extends the parent reply with bounded plain
text without changing the frame's browser privileges.

## Key types

- `controller.Model` holds the latest revision, current `Phase`, shown revision
  and last viewport width. `Phase` is `Idle` or `Busy(stage, request, queued)`;
  `Stage` distinguishes vendor `Drawing` from SVG `Checking`. The waiting slot
  holds only the newest request, never an unbounded backlog.
- `controller.Input` is `Accepted(Request)`, `Forbidden(revision)` or `Ignored`.
  Total decoding accepts only safe positive revisions, dark/default themes and
  bounded UTF-16 source. Configuration/frontmatter and navigation directives
  produce a refusal without entering the vendor.
- `controller.Msg` carries requests/refusals, vendor `Rendered` results, DOM
  `Published` results and width/height observations. `Effect` is data: `Begin`,
  `Inspect`, `Clear`, `ReplyToParent` or `Measure`. A stale vendor completion
  cannot authorize inspection; a stale inspection cannot authorize a reply.
- `controller.Node` and `Attribute` are a root-first projection of parsed XML.
  `safe_svg` rejects non-SVG roots, parser errors, embedded content, anchors and
  non-fragment references before the runtime attaches a node.
- `internal/ffi_dom` is the package's only FFI declaration module. Its opaque
  `Vendor`, `Element`, `Document`, `Attribute` and `Observer` handles expose
  browser property reads/calls and normalize promise/exception outcomes into
  Results. `internal/dom.mjs` owns no queue, policy or configuration constants.

## Relationships

The package depends on the already-used `gleam_stdlib`, `gleam_json` and pinned
Lustre 5.7.1. Lustre owns the browser message loop and renders only an empty
view into `#controller`, separate from the vendor-owned `#diagram` subtree.
Controller updates never reconcile vendor SVG. Tests import the pure controller
only; lint R20 forbids reaching Lustre or `web_mermaid/internal` transitively.

The npm dependency graph stays in `packages/web_mermaid/bundle`. Its bootstrap
imports this program's compiled entrypoint and injects Mermaid, so no npm
resolution or vendor import is hidden in the FFI. All sources and both Gleam
manifests/locks are included in the renderer's offline asset digest gate.

## Traffic

The document installs its listener before sending `controller.Ready`. Only messages
whose source is the actual parent window are decoded. Input is a JSON string
with source, theme and revision; replies are JSON strings containing status,
revision, bounded height and an optional failure diagnostic. Only a string
exception message crosses, truncated by `reply_json` to 2,000 Unicode code
points. SVG, stacks, exception objects, callbacks and renderer configuration
never cross. The parent independently bounds and renders diagnostics as text.

The pure update returns ordered effects. `web_mermaid.perform` executes those
in one Lustre effect, preserving Clear/Begin/reply order. Vendor completion
becomes `Rendered`; only the current revision enters `Inspect`. XML policy
validation and installation are synchronous, followed by `Published`, whose
revision is checked again before a parent reply. Resize observes width and
publishes only for the current shown revision. The frame's document lifetime
owns the application, message listener and observer; teardown removes them all.

## Invariants

- The frame retains its opaque origin and restrictive HTTP policy. This package
  must not be imported by the session client or granted same-origin access.
- At most one vendor call is active, and at most one newer request waits.
  Refusing newer source clears the waiting request without pretending to cancel
  the in-flight vendor promise.
- All configuration constants, request checks, SVG checks, queue transitions and
  publication decisions live in Gleam. JS is only the fixed bootstrap and FFI.
- Nothing is attached from parsed XML before `safe_svg` accepts its projection.
  This filter supplements the sandbox and CSP; it is not the isolation boundary.
- Test modules cannot import the browser runtime or FFI. `make test-web_mermaid`
  executes controller tests under Node/Bun/Deno, and the FFI checks in
  `bundle/renderer_test.mjs` test exception and promise normalization. Neither
  runs the real vendor; `scripts/web_mermaid_check.sh` is the browser drive.
- The configuration pins `layout: "dagre"` with explicit flowchart `wrappingWidth` (320), `nodeSpacing` (50), `rankSpacing` (80), `padding` (16), and `subGraphTitleMargin` (`{top: 10, bottom: 10}`). ELK, Mermaid 12's flowchart default, fails inside the IIFE bundle (`__require is not defined`); a `flowchart-elk` header still reaches it and falls back to source.
- `controller.normalize_source` escapes non-`<br>` angle brackets inside double-quoted node labels to `&lt;` and `&gt;` before rendering so Mermaid's DOMPurify pass does not strip `<name>` or `<state_root>` as HTML tags while SVG `<tspan>` entity decoding restores `<` and `>`.
- The frame root's `color-scheme` follows the request's theme. A frame whose
  scheme differs from its iframe element's is painted on an opaque backdrop.

## Deep docs

- [Mermaid rendering boundary](../../protocol-change/091-isolated-mermaid-diagrams.md).
- [Web architecture](../../docs/architecture/web-view.md).
- [Validation limits](../../docs/review/mermaid-web-rendering-2026-10-18.md).
