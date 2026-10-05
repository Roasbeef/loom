# web_client

`web_client` supplies the browser interactions around Loom's server-rendered
web view. It is a JavaScript-target Gleam package: `web_client.main` registers
nine Lustre client components as custom elements, and the server renders those
elements inside its page. The components handle elapsed time, folding,
scrolling, editor interactions and layout without asking the server to render
again for each browser action.

Session state remains in [`web_view`](../web_view/README.md), which runs on the
BEAM and uses the shared [`session_view`](../session_view/README.md) engine.
The daemon owns browser authentication, page roles and the session gateway.
No component here opens its own session connection or decides page permissions.
Form submission and server-drawn controls still travel through the web view's
existing event handlers and admission checks.

## The elements

| Element | Browser behavior |
|---|---|
| `loom-elapsed` | Counts forward from the daemon's elapsed-duration `offset`, anchored to the browser clock. |
| `loom-fold` | Opens or closes a turn's folded work. |
| `loom-expand` | Opens one row's body behind its server-drawn heading. |
| `loom-follow` | Follows new transcript rows, pauses when the reader scrolls away, and preserves the visible row when older history arrives. |
| `loom-composer` | Suggests slash commands, submits on Command/Control with Enter, and restores returned prompts to the editor. |
| `loom-attach` | Accepts image selection or paste, draws removable chips, and submits the held bytes as one form field. |
| `loom-shell` | Controls side columns, panel tabs, the narrow-screen drawer and theme; stores layout per workspace. |
| `loom-switch` | Navigates to a daemon-issued session or home ticket path after validating its shape. |
| `loom-copy` | Copies a validated invitation or fresh-link command when its button is pressed. |

The server supplies content as child nodes and slots. Folded transcript text
therefore remains server-rendered content; the fold element holds only its
open state. The elapsed element receives a duration, so it never subtracts a
daemon clock reading from a browser clock reading.

The transcript follower keeps the newest row visible while the reader is at
the bottom. A reader who scrolls up gets a “Jump to latest” button. Browser
layout changes do not count as the reader leaving the bottom, and opening
folded content does not move the reader past the control they pressed.

Image admission happens in both places. The attachment element checks declared
media type, size and count before reading a file, including reads in flight.
The daemon checks the actual bytes against its image policy after submission.
A browser check cannot grant an image that the daemon would refuse.

## How the code is divided

Each element module holds a Lustre model, receives attribute changes and DOM
events, then renders its local state. Decision modules such as `follow_rule`,
`composer_rule`, `attach_rule`, `shell_rule` and `layout_rule` contain pure
Gleam rules. The browser bindings are confined to
[`internal/ffi_dom`](src/web_client/internal/ffi_dom.gleam) and
[`dom.mjs`](src/web_client/internal/dom.mjs); component behavior stays in Gleam.

Layout storage holds column visibility and the selected tab under a workspace
digest. Focused strand state is not saved. Theme choice is stored separately
for the browser and applied by the page bootstrap script before first paint.
Missing or blocked storage falls back to the default layout and theme.

The components render through Lustre's virtual DOM, with no raw HTML insertion.
Keyboard rules keep approval cards outside composer shortcuts and shell
navigation. The image and clipboard elements draw text nodes, while session
content is supplied by the server. The JavaScript, CSS and contrast gates
enforce the package's browser bindings and presentation rules.

## Building the served assets

From the repository root:

```sh
make gen-client
make client-check
```

`gen-client` uses the pinned `lustre_dev_tools` to bundle the components and
build the Tailwind stylesheet. It copies the two page bootstrap scripts from
`assets/` alongside those outputs in `packages/web_view/priv/static`. The first
build can download the bundler and Tailwind tools. The daemon serves the
committed files; it performs no bundling at runtime.

`client-check` verifies input and output digests and exercises the drift gate,
without a JavaScript toolchain or network. Edit the sources and regenerate the
assets rather than editing the committed bundle. A README-only edit requires
no asset regeneration.

## Testing

```sh
make check-web_client
make test-web_client
make lint-web_client
```

The package gate checks format, compilation and tests. `test-web_client` runs
the pure decision tests using Node, Bun or Deno. Its import check refuses test
paths that load Lustre's browser runtime or the DOM bindings. A missing runtime
prints a skip that the CI skip census rejects.

The tests cover scroll sequences, editor rules, image limits, layout restoration,
switch-path validation and clipboard text validation. They do not exercise real
DOM listeners, observers, caret movement, focus or browser layout. Those require
a browser check. `lint-web_client` also runs the JavaScript boundary, CSS and
contrast checks; the broader web-view integration tests live in `web_view` and
`client`.

## Reading further

- [`CLAUDE.md`](CLAUDE.md): attributes, messages and browser invariants.
- [Web-view architecture](../../docs/architecture/web-view.md): routes, page
  lifecycle and the server/browser split.
- [Lustre guide](../../docs/lustre.md): server and client components, asset
  generation and the view checklist.
- [Protocol 051](../../protocol-change/051-web-view-route.md): page admission,
  browser events and operator controls.
- [Web design](../../docs/design-notes/web-design.md): layout and presentation
  decisions.
