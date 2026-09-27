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
- `<loom-follow>` wraps the lane and scrolls the page to a row that lands
  below the viewport while the reader is at the bottom; once the reader
  scrolls up it stops, and scrolling back to the bottom resumes it.

It is the client package of Lustre's full-stack layout: `core` and
`session_view` are the shared code, `loomd` with `web_view` is the server,
and this is the client. Unlike the guide's single-page app it is a set of
client components inside a server component, because 051 keeps the session
on the BEAM (`docs/lustre.md`).

The package targets JavaScript only (`target = "javascript"`) and depends on
`lustre == 5.7.1` and `gleam_stdlib`. `make gen-client` bundles it with
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
  the default slot.
- `follow.Model(position, watching)`, `follow.Position` (`Following` |
  `Reading`) and `follow.Msg` (`Connected`, `Disconnected`, `Watched`,
  `Scrolled(gap)`, `Resized`): a scroll sets the position from the gap
  between the viewport's bottom and the page's (`follow.position`, within
  `follow.slack` pixels is `Following`); a resize of the lane scrolls to
  the bottom only while `Following`. The shadow root holds one default
  slot.
- `internal/ffi_clock`: `now` (`Date.now`), `every` (`setInterval`) and
  `cancel` (`clearInterval`), in `clock.mjs`.
- `internal/ffi_follow`: `watch` (a passive `scroll` listener on the window
  and a `ResizeObserver` on the element), `unwatch` and `to_bottom`, in
  `follow.mjs`. With `ffi_clock`, these are the package's only browser
  APIs.

## Relationships

- **Depends on**: `lustre` (client components, `lustre.register`),
  `gleam_stdlib`. Dev only: `lustre_dev_tools`, for `make gen-client`.
- **Depended on by**: nothing at compile time. `packages/web_view` renders
  its elements by tag name, and `packages/client` serves its bundle from
  `web_view`'s `priv/static` (`ui_http.Client`).

## Traffic

None over the socket. Each element is a Lustre runtime inside the browser:
attribute changes and DOM events reach its `update`; its timers dispatch
messages to it. Nothing here opens a connection. The one element that
looks outside itself is `<loom-follow>`, which reads and sets the page's
scroll position and observes its own size; it reads no content.

## Invariants

- **Only attributes that hold daemon identities or numbers.** An element
  never renders an attribute's value as text unless it is a number it
  computes from, and never takes session text as an attribute. Text inside
  `<loom-fold>` is the server's light-DOM children, projected through slots.
- **No key handling and no focus near an approval card.** No element
  listens for a key, and none calls `focus`.
- **No raw HTML.** Lustre renders through its virtual DOM; nothing here
  uses `unsafe_raw_html` or `innerHTML`.
- **No state the server needs.** A fold's open state, a clock reading and
  whether the reader follows the tail live only in the browser; the server
  never reads them.
- **The follower never touches an approval card.** `<loom-follow>` wraps
  the lane only; the cards and the composer are in the dock outside it.
  It scrolls instantly, never smoothly, because a smooth scroll reports
  intermediate positions that read as the reader leaving the tail.
- **The committed bundle is generated.** Change this package and run `make
  gen-client`; `make client-check` (part of `make check`) fails on drift,
  by digests, without Node, Bun or a network.

## Deep Docs

- `docs/lustre.md`: server components, client components inside them, the
  security rules, and how the bundle is built and gated.
- `protocol-change/051-web-view-route.md`: the page's threat model.
