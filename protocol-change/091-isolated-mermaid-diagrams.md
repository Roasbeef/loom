# protocol-change/091: isolate Markdown diagram rendering

**Status**: ACCEPTED 2026-10-18 · **Affects**: protocol-change/051 web assets and browser content policy · **Implemented**: web_view, web_client, client

## Problem

A `mermaid` Markdown fence currently draws its source in a code box. Rendering
that source requires Mermaid's browser DOM and SVG generation, which cannot
run under 051's rule that session content is always a text node in the session
page. Adding a renderer to that page would also require its inline styles and
HTML parsing primitives, contrary to the existing client binding's gate.

## Proposal

The server continues to send only escaped source text. Exactly the `mermaid`
language chooses one fixed client element:

```html
<loom-mermaid><pre class="mermaid-source">escaped source</pre></loom-mermaid>
```

The browser element retains that source in its default slot and creates a
fixed-address frame. No source is placed in a URL, attribute or storage item.
The frame has `sandbox="allow-scripts"`, without `allow-same-origin`, and its
HTTP content policy also applies that sandbox on direct navigation.

The fixed asset table gains `mermaid.html` and `mermaid.js`. The session page's
policy adds only `frame-src 'self'`. The frame gets a separate policy allowing
its own bundled script and inline styles, but no connections, images, fonts,
forms, child frames or base URL. It may be framed only by this origin. The
frame response must replace the ordinary page policy, not append a second
policy whose `frame-ancestors 'none'` would prevent it from loading.

The internal frame protocol uses JSON strings:

```text
child -> parent: {kind: "ready"}
parent -> child: {source: String, theme: "dark" | "default", revision: Int}
child -> parent: {kind: "rendered", revision: Int, height: Int}
child -> parent: {kind: "failed", revision: Int}
```

The parent checks `event.source` against its exact frame window before
parsing a message. An opaque origin's `"null"` string is not an identity.
Only the current revision may publish a result, and heights are limited to
120 through 2000 pixels. SVG, source echoes and vendor errors never return to
the parent. The child accepts requests only from its parent, serializes
renderer calls and discards superseded results.

The renderer receives at most 32,000 UTF-16 code units, has a 250-edge limit,
and uses fixed strict security settings with HTML labels disabled. Session
configuration directives, frontmatter configuration and navigation directives
are refused rather than allowed to reconfigure it. Source remains available
when a diagram is unsupported, invalid, too large or unfinished. The parent
waits for a 350 ms quiet interval and stops waiting after ten seconds. That
waiting limit is not a hard CPU deadline for synchronous vendor code.

## What was considered

Rendering SVG in the session page was rejected because vendor sanitization
would then protect credentials, approval controls and session content. A CDN
or external diagram service was rejected because session text must not leave
the browser for rendering. Rendering on the daemon was rejected because
model-influenced code does not run in the harness VM, and introducing a jailed
headless browser service would add a separate execution lifetime to a display
feature.

The frame deliberately has no network-backed fonts, remote images, links or
interactive callbacks. This reduces the supported Mermaid surface, but keeps
session content from making browser requests or triggering application actions.

## Impact

`web_view/markdown_view` selects the new client element without changing the
portable Markdown tree or transcript format. `web_client/mermaid` owns the
source disclosure, explicit clipboard action and revision lifecycle. The frame
program is the separate JavaScript-target package `web_mermaid`, whose
`bundle/` directory holds the vendor bootstrap and npm lock; none of it enters
the session page bundle or its `internal/dom.mjs` binding. Its generated bundle and source lock are covered by the offline
asset digest gate. Regenerate both browser bundles with `make gen-client`.

A release carries two more fixed static assets and the Mermaid dependency's
license notices. No daemon or session protocol version changes. The TUI keeps
rendering source; its PNG graphics path is not changed by this proposal.

## Decision

**Accepted.** The owner approved web-first rendering with a locally pinned
dependency and source fallback. Keeping vendor DOM generation in an opaque,
network-disabled frame preserves the session page's text-only boundary without
relaxing its script or stylesheet policy.
