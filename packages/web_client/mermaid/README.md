# Isolated Mermaid renderer

`renderer.js` and the pinned Mermaid dependency run only in the opaque,
script-only `/ui/assets/mermaid.html` frame. They are not imported by the
session page's client bundle. The frame accepts bounded source as JSON data,
uses fixed strict settings, and reports only revisioned status and dimensions.
Source never reaches a renderer service, URL or browser storage.

Run `make gen-client` from the repository root. It installs the lock with
`npm ci --ignore-scripts`, reuses the Bun version pinned and verified by
`lustre_dev_tools`, and creates `packages/web_client/build/mermaid.js` as one
classic IIFE. The stamped release copy is
`packages/web_view/priv/static/mermaid.js`. `licenses.py` gathers each locked
dependency's shipped license files into the neighboring
`mermaid-licenses.txt`; a dependency with no notice fails generation.
`make client-check` checks inputs and generated bodies offline, without npm,
Bun or an installed dependency tree. The renderer is about 5.3 MB uncompressed;
its separate bundle does not enlarge the session page's client bundle.

`renderer_test.mjs` exercises the adapter with controlled vendor promises and
a minimal DOM fixture. It needs no npm packages and runs as part of
`make test-web_client`. It does not prove vendor behavior or browser policy
enforcement. `scripts/web_mermaid_check.sh` drives the actual streamed
Markdown response through a disposable daemon and a real browser.

See [protocol-change/091](../../../protocol-change/091-isolated-mermaid-diagrams.md)
for the accepted boundary, its restrictions and the source fallback.
