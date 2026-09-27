# web_client

## Purpose

The browser half of the web view: Lustre client components, written in
Gleam and compiled to JavaScript, registered as custom elements that the
server component (`packages/web_view`) renders like any other tag. The
server component holds every piece of session state and is the only thing
that talks to the session (protocol-change/051); this package holds only
behaviour that changes with nothing the server knows, so the server never
renders again just for it:

- `<loom-elapsed since="<unix ms>">` counts an operation's elapsed time
  once a second.
- `<loom-fold>` opens and closes a turn's folded work with no round trip.

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
- `elapsed.Model(since, now, timer)` and `elapsed.Msg` (`SinceChanged`,
  `Connected`, `Disconnected`, `Started`, `Ticked`): `since` is the daemon's
  Unix-millisecond start instant, the only attribute the element reads.
  `elapsed.duration` is the terminal strip's format.
- `fold.Model` (`Closed` | `Opened`) and `fold.Msg` (`Toggled`): the fold's
  shadow root holds one button carrying the `summary` slot and, while open,
  the default slot.
- `internal/ffi_clock`: `now` (`Date.now`), `every` (`setInterval`) and
  `cancel` (`clearInterval`), in `clock.mjs`, the package's only browser
  API.

## Relationships

- **Depends on**: `lustre` (client components, `lustre.register`),
  `gleam_stdlib`. Dev only: `lustre_dev_tools`, for `make gen-client`.
- **Depended on by**: nothing at compile time. `packages/web_view` renders
  its elements by tag name, and `packages/client` serves its bundle from
  `web_view`'s `priv/static` (`ui_http.Client`).

## Traffic

None over the socket. Each element is a Lustre runtime inside the browser:
attribute changes and DOM events reach its `update`; its timers dispatch
messages to it. Nothing here opens a connection or reads the page outside
its own element.

## Invariants

- **Only attributes that hold daemon identities or numbers.** An element
  never renders an attribute's value as text unless it is a number it
  computes from, and never takes session text as an attribute. Text inside
  `<loom-fold>` is the server's light-DOM children, projected through slots.
- **No key handling and no focus near an approval card.** No element
  listens for a key, and none calls `focus`.
- **No raw HTML.** Lustre renders through its virtual DOM; nothing here
  uses `unsafe_raw_html` or `innerHTML`.
- **No state the server needs.** A fold's open state and a clock reading
  live only in the browser; the server never reads them.
- **The committed bundle is generated.** Change this package and run `make
  gen-client`; `make client-check` (part of `make check`) fails on drift,
  by digests, without Node, Bun or a network.

## Deep Docs

- `docs/lustre.md`: server components, client components inside them, the
  security rules, and how the bundle is built and gated.
- `protocol-change/051-web-view-route.md`: the page's threat model.
