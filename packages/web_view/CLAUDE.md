# web_view

## Purpose

The web view's host and view for one session: a Lustre server component
that drives `session_view`'s lane and draws the session's transcript lines
as HTML, and the documents served around it (the page shell, the ticket
exchange's hand-off page, the stylesheet and the content security policy).
It is phase 4 of issue #530: the same engine the terminal runs, under a
second host, with only the view differing
([ADR-014](../../docs/adr/014-second-runtime.md)).

The daemon serves it only when started with `loomd --ui`
([protocol-change/051](../../protocol-change/051-web-view-route.md)). The
package knows nothing of the daemon: the transport the lane writes through
is handed in by `packages/client`, which owns the routes, the tickets and
the relay into the session's gateway.

## Key Types

- `component.Start(socket)`: what the daemon supplies when it starts a
  component: the session ID, the `snapshot.Expected` attachment every cut
  must match, and a `Transport(socket)`.
- `component.Transport(socket)`: `connect(inbox)`, `transmit(socket,
  frame)`, `shut(socket)` and `now()`, all run in the component's process.
- `component.Msg(socket)`: `Opened`, `Refused`, `TimerArmed`, `Arrived`
  (a frame, filed only) and `Ticked` (reduction).
- `component.Model(socket)` (opaque): the lane, the filed frames, the last
  capture and the connection `Status`.
- `page`: the shell, the exchange page, the assets' names and contents, and
  `content_security_policy(host)`.

## Relationships

- **Depends on**: `session_view` (the lane, `transcript.project`, the line
  types), `core` (JSON, in tests), `lustre == 5.7.1`, `houdini == 1.2.1`,
  `gleam_erlang`.
- **Depended on by**: `client`, whose `client/daemon/ui_socket` starts one
  component per browser connection and whose router serves `page`'s
  documents.

## Traffic

- The component's mailbox receives `connection_event.Message`s from the
  transport (mapped to `Arrived`) and a `Nil` from its own timer every
  250 ms (mapped to `Ticked`). Both selectors are created inside the
  component's process with `effect.select`.
- Outputs leave through the transport only: `Transmit` and `Shut`.

## Invariants

- **No session logic here.** What a frame means, when to catch up and which
  lines a capture becomes are `session_view`'s. Logic that decides
  something about the session belongs there, where the terminal uses it too.
- **Option C.** `Arrived` files and reduces nothing; `Ticked` reduces every
  filed frame in arrival order and then runs the lane's tick.
  `component_test` pins it.
- **Read-only by type.** No message mutates the session, the view attaches
  no event handler, and the component never calls `session_channel.submit`.
  The daemon caps the attachment to observer as well.
- **No inline script or style** in any served document, so the policy can
  refuse both.

## Deep Docs

- `docs/adr/014-second-runtime.md`: one engine, two views, and option C in
  the web host.
- `protocol-change/051-web-view-route.md`: the routes, authentication and
  the relay.
- `docs/lustre.md`: how Lustre 5.7.1 server components work, how they map
  onto this package, `ui_socket` and `ui_relay`, the view's security and
  accessibility rules, and the checklist for a change here.
