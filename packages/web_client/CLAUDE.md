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

It is the client package of Lustre's full-stack layout: `core` and
`session_view` are the shared code, `loomd` with `web_view` is the server,
and this is the client. Unlike the guide's single-page app it is a set of
client components inside a server component, because 051 keeps the session
on the BEAM (`docs/lustre.md`).

The package targets JavaScript only (`target = "javascript"`) and depends on
`lustre == 5.7.1`, `gleam_stdlib` and `gleam_json`. `make gen-client` bundles it with
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
  browser's clock. `elapsed.duration` is the terminal strip's format.
- `fold.Model` (`Closed` | `Opened`) and `fold.Msg` (`Toggled`): the fold's
  shadow root holds one button carrying the `summary` slot and, while open,
  the default slot. Each toggle emits `fold.toggled_event`
  (`loom-fold-toggled`, bubbling and composed, no data).
- `follow.Model(position, gap, watching, anchor)`, `follow.Position`
  (`Following` | `Reading`) and `follow.Msg` (`Connected`, `Disconnected`,
  `Watched`, `Scrolled(gap, moved)`, `Resized`, `Measured(gap)`, `Folded`,
  `Paged`, `Jumped`, `Held(anchor)`, `Released`): a scroll sets the
  position from where it ended and which way it moved
  (`follow.after_scroll`): within `follow.slack` pixels of the bottom is
  `Following`, a move up that ends further away is `Reading`, and a move
  down that ends further away changes nothing, because that is either the
  reader coming back or the element's own scroll to the bottom reported
  after more rows landed. A resize of the transcript or its content
  scrolls to the bottom only while `Following`; a fold's toggle event,
  heard on the slot, sets `Reading`, so opening a fold never scrolls past
  it. A click heard on the slot whose target carries the server's fixed
  `data-loom-older` marker is `Paged`: it sets `Reading` and holds the
  lane's first row and its place on screen (`anchor`); a scroll by the
  reader measures it again, and the first resize after which that row is
  no longer the lane's first scrolls the transcript to put it back and
  releases it. The shadow root holds the default slot and, while the
  reader is `Reading` more than `slack` pixels from the bottom, one
  button, "Jump to latest" (`Jumped`), whose wrapper has no height and
  sticks to the scroller's bottom edge.
- `composer.Model(entries, draft, selected, palette, returns)` and
  `composer.Msg` (`Configured`, `Returned`, `Typed`, `Moved`, `Accepted`,
  `Picked`, `Dismissed`, `Sent`, `Ignored`): `commands` is the table the
  server built from the terminal's suggestions (`composer.entries` decodes
  it, and decodes to no table if it is not one); `composer.matching(entries,
  draft)` is `command.suggestions`' rule over that table, one-word commands
  by prefix and a word with a closed vocabulary (`/effort `, `/goal `) by
  its argument rows past the space. `composer.intent(key, chord, phase,
  palette)` says what a key does: Command or Control with Enter is `Sent`
  and its default cancelled; while the list shows, the arrows are `Moved`,
  Tab and Enter are `Accepted` and Escape is `Dismissed`; everything else,
  and every key during composition, is the browser's. `Returns` is `Unseen`
  or `Seen(baseline, count)`: the first `returned` count is the baseline, an
  editor drawn afresh takes none of the returns before it, and a count that
  rises runs `ffi_composer.restore(baseline)`, which takes each numbered
  child of the `returned` slot once, oldest first. The shadow root holds the
  list, above one default slot; the list is `role="listbox"` and its rows
  `role="option"`.
- `internal/ffi_clock`: `now` (`Date.now`), `every` (`setInterval`) and
  `cancel` (`clearInterval`), in `clock.mjs`.
- `internal/ffi_follow`: `watch` (a passive `scroll` listener on the
  element, and a `ResizeObserver` on the element and on each of its
  children, which a `MutationObserver` keeps current: the element's own box
  is fixed, so it is the content that changes size when a row lands),
  `unwatch`, `measure`, `to_bottom`, and for the held row `hold`,
  `remeasure` and `keep` (`Waiting` | `Restored`), which read the first
  row's box and scroll the element by a distance, in `follow.mjs`.
- `internal/ffi_composer`: `place` (write the editor and focus it, for a
  chosen row), `send` (`requestSubmit` on the form, with its first submit
  button), `restore` (take the numbered returned children into the editor)
  and `reveal` (scroll the list to the highlighted row), in `composer.mjs`.
  With `ffi_clock` and `ffi_follow`, these are the package's only browser
  APIs.

## Relationships

- **Depends on**: `lustre` (client components, `lustre.register`),
  `gleam_stdlib`, `gleam_json` (the fold event's empty payload). Dev only:
  `lustre_dev_tools`, for `make gen-client`.
- **Depended on by**: nothing at compile time. `packages/web_view` renders
  its elements by tag name, and `packages/client` serves its bundle from
  `web_view`'s `priv/static` (`ui_http.Client`).

## Traffic

None over the socket. Each element is a Lustre runtime inside the browser:
attribute changes and DOM events reach its `update`; its timers dispatch
messages to it. Nothing here opens a connection. The one element that
looks outside itself is `<loom-follow>`, which reads and sets its own
scroll position and observes the size of itself and its children; it reads
no content. `<loom-composer>` listens to its own editor's `input` and
`keydown`, and writes the editor's value; the one thing it sends is the
form's submit, which the server already accepts.

## Invariants

- **Only attributes that hold daemon identities or numbers.** An element
  never renders an attribute's value as text unless it is a number it
  computes from, and never takes session text as an attribute. Text inside
  `<loom-fold>` is the server's light-DOM children, projected through slots.
  The one exception in kind is `<loom-composer commands>`, the static table
  of command names and hints written in `session_view`; the returned
  prompts it takes arrive as text-node children, never as attributes.
- **No key handling and no focus near an approval card.** Only
  `<loom-composer>` listens for a key, and only on its own editor, through
  its slot. It calls `focus` once, on that editor, when the operator chooses
  a row. The approval cards are outside it, in the dock, and no key it
  handles decides one: Command or Control with Enter submits the composer's
  form, which sends a prompt or a command and decides nothing.
- **No raw HTML.** Lustre renders through its virtual DOM; nothing here
  uses `unsafe_raw_html` or `innerHTML`.
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
- **The committed bundle is generated.** Change this package and run `make
  gen-client`; `make client-check` (part of `make check`) fails on drift,
  by digests, without Node, Bun or a network.

## Deep Docs

- `docs/lustre.md`: server components, client components inside them, the
  security rules, and how the bundle is built and gated.
- `protocol-change/051-web-view-route.md`: the page's threat model.
