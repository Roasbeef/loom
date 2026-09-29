# web_client

## Purpose

The browser half of the web view: Lustre client components, written in
Gleam and compiled to JavaScript, registered as custom elements that the
server component (`packages/web_view`) renders like any other tag. The
server component holds every piece of session state and is the only thing
that talks to the session (protocol-change/051); this package holds only
behaviour that changes with nothing the server knows, so the server never
renders again just for it:

- `<loom-elapsed offset="<ms>">` counts an operation's elapsed time once a
  second, on from a duration the server measured.
- `<loom-fold>` opens and closes a turn's folded work with no round trip.
- `<loom-expand>` shows a row compact or in full, as the terminal's `Ctrl+g`
  does. The server draws both forms as children (`slot="compact"` and
  `slot="full"`); the element holds one button and the slot the reader chose,
  with no round trip.
- `<loom-follow>` is the transcript's scroll container: the page's frame is
  pinned and only it scrolls. It scrolls itself to a row that lands below
  its view while the reader is at the bottom; once the reader scrolls up it
  stops and shows a "Jump to latest" button, and scrolling back to the bottom
  or pressing the button resumes it. When the reader presses the lane's
  "Load older" button, it keeps the row they were looking at in place while
  the older rows arrive above it.
- `<loom-composer commands="<json>" returned="<n>">` wraps the operator's
  editor, the server's uncontrolled textarea, which is its default slot.
  It lists the slash commands as the draft grows, sends the draft on
  Command or Control with Enter, and puts a prompt the daemon handed back
  into the editor. These react to text that only the browser has until the
  form is submitted, which is why they are here.

A page that has ended or was refused needs no element here. The server draws
its notice (`web_view/view/ended`, `web_view/page.refusal`), and the shell's
own paragraph inside the component shows while nothing has mounted; this
package only styles them (`.ended-notice`, `.page-note` in `web_client.css`).
A tab that mounted and then lost its socket is the one case no element covers
yet (protocol-change/051, the addendum on an ended page).

It is the client package of Lustre's full-stack layout: `core` and
`session_view` are the shared code, `loomd` with `web_view` is the server,
and this is the client. Unlike the guide's single-page app it is a set of
client components inside a server component, because 051 keeps the session
on the BEAM (`docs/lustre.md`).

The package targets JavaScript only (`target = "javascript"`) and depends on
`lustre == 5.7.1`, `gleam_stdlib` and `gleam_json`. Its only JavaScript is
`src/web_client/internal/dom.mjs`, one DOM call or property read per export
with no logic, declared in `internal/ffi_dom.gleam`; every decision the
components make is Gleam over it (see `internal/ffi_dom` under Key Types).
`make gen-client` bundles it with
`lustre_dev_tools` (a dev dependency here and nowhere else) into
`packages/web_view/priv/static/web_client.mjs`, together with the page's
stylesheet, which Tailwind builds from `src/web_client.css`, and the two
page scripts in `assets/`. The daemon serves those files; nothing at run
time builds anything.

## Key Types

- `web_client.main()`: registers every element, once, when the page loads
  the bundle.
- `elapsed.Model(reading, now, timer)`, `elapsed.Reading(offset, anchor)`
  and `elapsed.Msg` (`OffsetChanged`, `Anchored`, `Connected`,
  `Disconnected`, `Started`, `Ticked`): `offset` is how long the operation
  had run, in milliseconds, by the server (`agent_roster.running_ms`), and
  is the only attribute the element reads; `anchor` is the browser's clock
  when it arrived. The element never subtracts a daemon instant from the
  browser's clock. `duration.format` is the terminal strip's format.
- `fold.Model` (`Closed` | `Opened`) and `fold.Msg` (`Toggled`): the fold's
  shadow root holds one button carrying the `summary` slot and, while open,
  the default slot. Each toggle emits `fold.toggled_event`
  (`loom-fold-toggled`, bubbling and composed, no data).
- `expand_rule.Shown` (`Compact` | `Full`), `expand_rule.toggled`, `slot`,
  `words` and `glyph`, and `expand.Msg` (`Toggled`): the element's shadow
  root holds one button (fixed words, `aria-expanded`) and the named slot for
  the state. It starts `Compact`, and the server never renders the state, so
  a patch leaves the reader's choice alone. Each toggle emits
  `fold.toggled_event`, so `<loom-follow>` hears it as it hears a fold's: it
  sets `Reading`, and expanding the newest row at the bottom does not scroll
  past the button the reader pressed. Collapsing shrinks the lane and the
  browser fits the scroll position, which the follow rule treats as layout,
  never as the reader leaving.
- `follow.Model(reader, watching, anchor)` (`follow_rule.Reader` holds
  position, gap, top, extent and touched, and `follow_rule` moves it),
  `follow_rule.Position` (`Following` | `Reading`) and `follow.Msg` (`Connected`,
  `Disconnected`, `Watched`, `Touched`, `Scrolled(top, extent, at)`,
  `Resized`, `Measured`, `Folded`, `Paged`, `Jumped`, `Held`, `Released`):
  a scroll sets the position from where it ended, which way it moved and who
  moved it (`follow_rule.after_scroll(current, gap, moved, origin)`). Within
  `follow_rule.slack` pixels of the bottom is `Following`. A move up that ends
  further away is `Reading` only when the reader made it; a move down that
  ends further away changes nothing, because that is either the reader
  coming back or the element's own scroll to the bottom reported after more
  rows landed. `follow_rule.origin` tells who made a scroll: `Input` when a
  `wheel`, `touchstart`, `touchmove`, `pointerdown` or `keydown` on the element was heard
  within `follow_rule.touch_window` (`Touched`, passive listeners that read
  nothing from the event), `Steady` when nothing was heard but the
  transcript's `Extent` (content and view height) is what it was at the
  last scroll (find-in-page, a key pressed outside the transcript, a
  scrollbar drag), and `Layout` when nothing
  was heard and the extent changed, which is the browser fitting the scroll
  position to a box that grew or content that shrank. A `Layout` scroll
  never leaves `Following`; the size change that caused it brings `Resized`,
  which scrolls to the bottom. Each `Input` scroll renews `touched`, so a
  slow scrollbar drag stays the reader's. A resize of the transcript or its
  content scrolls to the bottom only while `Following`; a fold's toggle
  event, heard on the slot, sets `Reading`, so opening a fold never scrolls
  past it. A click heard on the slot whose target carries the server's fixed
  `data-loom-older` marker is `Paged`: it sets `Reading` and holds the
  lane's first row and its place on screen (`follow.Anchor`, `None` when
  the page has no lane row); a scroll by the reader measures it again, and
  the first resize after which that row is no longer the lane's first
  scrolls the transcript to put it back and releases it (`follow_rule.keeping`
  over a `follow_rule.Standing`: `Detached`, `Leading`, `Displaced(top)`). The
  watch (`follow.Watching`) is the element, its scroll listener and input
  listeners, a `ResizeObserver` on the element and on each of its
  children, and a `MutationObserver` that keeps those current: the
  element's own box is fixed, so it is the content that changes size when a
  row lands. The shadow root holds the default slot and, while the reader is
  `Reading` more than `slack` pixels from the bottom, one button, "Jump to
  latest" (`Jumped`), whose wrapper has no height and sticks to the
  scroller's bottom edge.
- `composer.Model(entries, draft, selected, palette, returns)` and
  `composer.Msg` (`Configured`, `Returned`, `Typed`, `Moved`, `Accepted`,
  `Picked`, `Dismissed`, `Sent`, `Ignored`): `commands` is the table the
  server built from the terminal's suggestions (`composer_rule.entries` decodes
  it, and decodes to no table if it is not one); `composer_rule.matching(entries,
  draft)` is `command.suggestions`' rule over that table, one-word commands
  by prefix and a word with a closed vocabulary (`/effort `, `/goal `) by
  its argument rows past the space. `composer_rule.intent(key, chord, phase,
  palette)` says what a key does: Command or Control with Enter is `Sent`
  and its default cancelled; while the list shows, the arrows are `Moved`,
  Tab and Enter are `Accepted` and Escape is `Dismissed`; everything else,
  and every key during composition, is the browser's. `Returns` is `Unseen`
  or `Seen(taken)`: the first `returned` count is the baseline, so an editor
  drawn afresh takes none of the returns before it. `composer_rule.hear` turns
  each later count into `Take(after, up_to)` when it is above `taken` and
  advances `taken` in the same turn, so two returns that arrive before one
  frame paints claim disjoint ranges and each prompt is taken once. The
  effect reads the numbered children of the `returned` slot, and
  `composer_rule.taken` picks the ones in the range, oldest first, and
  `composer_rule.joined` puts each in the draft (an empty editor takes it as its
  draft; a typed one keeps its text and takes it after a blank line).
  `composer_rule.revealed` says where the list scrolls to keep the highlighted
  row in view. The shadow root holds the
  list, above one default slot; the list is `role="listbox"` and its rows
  `role="option"`.
- `internal/ffi_dom` and `internal/dom.mjs`: the package's only browser
  API and its only JavaScript. Every function is one DOM call or property
  access: `host`, `as_element`, `same`, `is_connected`, `first_element_child`,
  `children`, `closest`, `query_selector`, `query_selector_all`, `dataset_get`,
  `text_content`, `scroll_top`, `set_scroll_top`, `scroll_by`,
  `scroll_height`, `client_height`, `offset_top`, `offset_height`,
  `bounding_top`, `add_passive_listener`, `remove_listener`,
  `resize_observer`, `observe`, `mutation_observer`, `observe_child_list`,
  `disconnect`, `value`, `set_value`, `utf16_length`, `set_selection_range`,
  `focus`, `request_submit`, `request_submit_with`, `now`, `set_interval` and
  `clear_interval`. Its types are `Element` (an element, or the shadow root
  Lustre hands an `after_paint` effect, which answers queries alike),
  `Listener`, `Observer` and `Timer`. The one decision in `dom.mjs` is
  turning a null or undefined DOM answer into `Error(Nil)`. Add a function
  there only when a component needs a DOM call that is not bound, and keep
  the logic in Gleam. There is no other `.mjs`: the lint gate below fails
  one.

## Tests

What the components decide is in four modules that import neither Lustre nor
`ffi_dom`: `follow_rule` (the scroll rule, `Reader` and its transitions,
`keeping`), `expand_rule` (the two states and the button's words), `composer_rule` (the table, `matching`, `intent`, `hear`, `taken`,
`joined`, `revealed`) and `duration`. `follow`, `composer` and `elapsed` are
the elements over them. The split is enforced, not just conventional: Lustre's
client runtime declares `class LustreEvent extends CustomEvent` at load, Node
18 (the signoff container's) has no global `CustomEvent`, and a test that
imports an element throws before any test runs. `scripts/web_client_test.sh`
walks the imports reachable from `test/` and fails if one reaches `lustre` or
`web_client/internal/`.

`test/` holds gleeunit tests for what the components decide: `follow`'s
scroll rules and the sequences of messages the page sends, `composer`'s
`matching`, `intent`, `hear`, `taken`, `joined` and `revealed`, and
`duration.format`. They run on the JavaScript target, so they need Node,
Bun or Deno: `make test-web_client` (`scripts/web_client_test.sh`, which
`scripts/check.sh` runs after the compile). The container the signoff runs in
installs Node for this; a machine with no runtime prints a `SKIP` line that
`.github/scripts/skip_census.sh` refuses. What the tests do not reach is the
DOM: the listeners, the observers, the scroll events, the caret and focus,
`requestSubmit`, and the way the browser lays the page out. Those run only in
a browser and are checked by hand.

## Relationships

- **Depends on**: `lustre` (client components, `lustre.register`),
  `gleam_stdlib`, `gleam_json` (the fold event's empty payload). Dev only:
  `lustre_dev_tools`, for `make gen-client`, and `gleeunit`, for the tests.
- **Depended on by**: nothing at compile time. `packages/web_view` renders
  its elements by tag name, and `packages/client` serves its bundle from
  `web_view`'s `priv/static` (`ui_http.Client`).

## Traffic

None over the socket. Each element is a Lustre runtime inside the browser:
attribute changes and DOM events reach its `update`; its timers dispatch
messages to it. Nothing here opens a connection. The one element that
looks outside itself is `<loom-follow>`, which reads and sets its own
scroll position, observes the size of itself and its children, and hears
(passively, reading nothing from them, not even the key) the wheel, a finger,
a pointer press and a key pressed inside itself; it reads no content. `<loom-composer>` listens to its own
editor's `input` and `keydown`, and writes the editor's value; the one thing
it sends is the form's submit, which the server already accepts.

## Invariants

- **Only attributes that hold daemon identities or numbers.** An element
  never renders an attribute's value as text unless it is a number it
  computes from, and never takes session text as an attribute. Text inside
  `<loom-fold>` is the server's light-DOM children, projected through slots.
  The one exception in kind is `<loom-composer commands>`, the static table
  of command names and hints written in `session_view`; the returned
  prompts it takes arrive as text-node children, never as attributes.
- **No key handling and no focus near an approval card.** Only
  `<loom-composer>` acts on a key, and only on its own editor, through its
  slot. `<loom-follow>` may note that a key was pressed inside the transcript
  (a passive `keydown` that reads nothing from the event, never cancels it and
  sends nothing), so a keyboard scroll counts as the reader's. It calls `focus` once, on that editor, when the operator chooses
  a row. The approval cards are outside it, in the dock, and no key it
  handles decides one: Command or Control with Enter submits the composer's
  form, which sends a prompt or a command and decides nothing.
- **No raw HTML.** Lustre renders through its virtual DOM; nothing here
  uses `unsafe_raw_html` or `innerHTML`. `scripts/web_client_js_check.sh`, run
  by `make lint` (so by `make lint-web_client` and `make check`), fails if any
  JavaScript file under `src` is not `internal/dom.mjs`, or if one names
  `innerHTML`, `outerHTML`, `insertAdjacentHTML`, `eval`, `new Function`,
  `document.write`, `srcdoc`, `DOMParser`, `createContextualFragment` or a
  dynamic `import(`. It has its own self-test.
- **State the DOM would hold in an expando lives in the model.** The
  returned-prompt bookkeeping (`Seen(taken)`), the scroll bookkeeping (`top`,
  `extent`, `touched`) and the held row are Lustre model fields, never
  properties set on the host element.
- **No state the server needs.** A fold's open state, a clock reading and
  whether the reader follows the tail live only in the browser; the server
  never reads them.
- **The follower never touches an approval card.** `<loom-follow>` wraps
  the lane only, as the scroll container between the pinned header and
  the pinned dock; the cards and the composer are in the dock outside it.
  It scrolls instantly, never smoothly, because a smooth scroll reports
  intermediate positions that read as the reader leaving the tail. The row
  it holds for "Load older" is found by structure (the lane's first
  child), and only its box is read.
- **Only a scroll the reader made leaves the tail.** A browser moves the
  scroll position up by itself when content shrinks or the box grows, and the
  event is heard after the rows that landed since, so by geometry alone it is
  the reader leaving. `follow_rule.origin` refuses that (see `follow.Model`
  above). Keep any change to the follow rule inside `follow_rule.after_scroll` and
  `follow_rule.origin`, and add a sequence to `test/follow_test.gleam`.
- **The committed bundle is generated.** Change this package and run `make
  gen-client`; `make client-check` (part of `make check`) fails on drift,
  by digests, without Node, Bun or a network.

## Deep Docs

- `docs/lustre.md`: server components, client components inside them, the
  security rules, and how the bundle is built and gated.
- `protocol-change/051-web-view-route.md`: the page's threat model.
