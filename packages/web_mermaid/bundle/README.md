# Isolated Mermaid renderer

The fixed `renderer.js` bootstrap imports the pinned vendor and starts the
Gleam program in this package ([`web_mermaid`](../CLAUDE.md)). Both run only in
the opaque, script-only `/ui/assets/mermaid.html` frame, whose fixed document
is `mermaid.html` here. Neither is imported by the session page's client
bundle. Source remains JSON data, never a renderer-service request, URL or
storage item.

`web_mermaid/controller` owns request decoding, UTF-16 limits, fixed strict
configuration, the one-active/latest-queued state machine, SVG policy and
revisioned replies. Its runtime uses a hidden Lustre mount separate from the
vendor-owned diagram DOM. Handwritten JS is limited to the bootstrap and the
frame-only DOM/vendor binding, including promise/exception conversion.

The configuration pins the dagre layout. Mermaid 12 otherwise lays flowcharts
out with ELK, whose browserified bundle needs a CommonJS `require` that Bun's
IIFE output does not define, so every flowchart failed. Do not drop the pin
without a real-browser flowchart drive.

Run `make gen-client` from the repository root. It compiles the Gleam frame
program, installs the npm lock with `npm ci --ignore-scripts`, reuses the Bun
version pinned and verified by `lustre_dev_tools`, and creates
one classic IIFE in the generator's scratch directory. The stamped release
copy is `packages/web_view/priv/static/mermaid.js`. `licenses.py` gathers locked
npm dependencies' license files into the neighboring `mermaid-licenses.txt`;
a dependency with no notice fails generation. The offline digest gate includes
the frame's Gleam sources/manifests as well as npm inputs and the build recipe.
The renderer is about 5.4 MB uncompressed and stays out of the session bundle.

`make test-web_mermaid` runs the pure controller regressions without importing
Lustre or DOM bindings. `renderer_test.mjs`, run by the same target,
checks the small FFI with controlled promises and DOM primitives. The former
JS queue/configuration/SVG-policy regression cases are now Gleam tests, not
removed. Neither suite proves actual browser layout or CSP enforcement.
`scripts/web_mermaid_check.sh` remains the full disposable-daemon browser drive.

See [protocol-change/091](../../../protocol-change/091-isolated-mermaid-diagrams.md)
for the unchanged sandbox and parent message contract.
