# web_view

## Purpose

The web view's host and view for one session: two Lustre server components
that drive `session_view`'s lane and draw the session's transcript lines as
HTML, and the documents served around them (the page shell, the ticket
exchange's hand-off page, the two scripts, the stylesheet and the content
security policy). It is phase 4 of issue #530: the same engine the terminal
runs, under a second host, with only the view differing
([ADR-014](../../docs/adr/014-second-runtime.md)).

The daemon serves it only when started with `loomd --ui`
([protocol-change/051](../../protocol-change/051-web-view-route.md)). The
package knows nothing of the daemon: the transport the lane writes through
is handed in by `packages/client`, which owns the routes, the tickets, the
page keys and nonces, and the relay into the session's gateway.

## Key Types

- `component.Start(socket)`: what the daemon supplies when it starts a
  component: the session ID, the `snapshot.Expected` attachment every cut
  must match, and a `Transport(socket)`.
- `component.Transport(socket)`: `connect(inbox, opened)`, which returns at
  once and answers on `opened`; `transmit(socket, frame)`; `shut(socket)`;
  and `now()`. All run in the component's process.
- `component.Msg(socket)`: `Opened`, `Refused`, `TimerArmed`, `Arrived` (a
  frame, filed only) and `Ticked` (reduction). It holds no command.
- `component.Model(socket)` (opaque): the lane, the filed frames
  (`session_view/inbox`), the last capture, its projected keyed rows
  (`transcript.Row`) and approvals, the connection `Status`, the operator
  `Notice` and the sent-draft count.
- `component.{submit, decide}`: the two commands, through the engine's
  arms in `session_view/operator`. `Answer` is `AllowOnce | Deny`; a page
  never offers remembering a grant for the session.
- `operator_page.Msg(socket)`: `Observed(component.Msg)`, `Submitted(text,
  delivery)` and `Decided(id, seq, answer)`. `composition(fields)` is the
  total decoder of the composer form's fields.
- `page`: the shell, the exchange page (`enter(next, nonce)`), the enter
  and page scripts, the stylesheet, the keyed paths (`keyed_prefix`,
  `session_path`) and `content_security_policy(host)`.

## Relationships

- **Depends on**: `session_view` (the lane, the inbox, the operator arms,
  `transcript.project_rows`, `approval`, the line types), `core` (the
  origin label; JSON in tests), `lustre == 5.7.1`, `houdini == 1.2.1`,
  `gleam_erlang`.
- **Depended on by**: `client`, whose `client/daemon/ui_socket` starts one
  component per browser connection and whose router serves `page`'s
  documents.

## Traffic

- The component's mailbox receives the open's outcome (mapped to `Opened`
  or `Refused`), `connection_event.Message`s from the transport (mapped to
  `Arrived`), and a `Nil` from its own timer every 250 ms (mapped to
  `Ticked`). Each source is one `server_component.select` from `init`, so
  its subjects belong to the component's process.
- An operator's page also receives Lustre's `EventFired` for its two
  handlers: a click on an approval button and the composer form's submit.
- Outputs leave through the transport only: `Transmit` and `Shut`, in the
  lane's order, inside one `effect.from`.

## Invariants

- **No session logic here.** What a frame means, when to catch up, which
  lines a capture becomes and what an operator's input becomes on the wire
  are `session_view`'s. Logic that decides something about the session
  belongs there, where the terminal uses it too.
- **Option C, waking on awaited replies.** `Arrived` files its frame;
  `Ticked` reduces every filed frame in arrival order and then runs the
  lane's tick. While the lane has a request out, an arrival runs that same
  reduction at once, without re-arming the timer (ADR-014, the addendum on
  waking). A push to an idle lane waits for the tick. `component_test` pins
  both.
- **One ordered effect.** The lane's outputs are performed in one
  `effect.from`, never split across `effect.batch`, which does not order.
- **Which application runs is which commands exist.** An observer's page is
  `component.app()`, whose message type holds no command and whose view
  attaches no handler; its bar is a fixed text node. An operator's page is
  `operator_page.app()`. The daemon's gateway refuses an observer's
  mutation independently, and the engine refuses one on an observer's
  attachment as a third layer.
- **No handler or attribute from session text.** Button messages carry the
  daemon's escalation identity and sequence; cards are keyed by sequence
  (every storage write takes its own), rows by the engine's `transcript.Row` key. Text is only ever
  `html.text`; nothing uses `unsafe_raw_html`.
- **An approval card is drawn from the record alone** (`approval.presentation`),
  in its own region outside the transcript and after the composer, so a
  card appearing never moves the composer. Deny comes first; each button
  names the tool; nothing has `autofocus`; the composer's submit never
  decides an approval; a decision is sent only for the record still pending
  at the drawn sequence (`operator.drawn`).
- **The composer form is decoded totally.** One `draft`, at most one
  `delivery` of `prompt` or `steer`, nothing else; anything more refuses
  the event.
- **No inline script or style** in any served document, so the policy can
  refuse both.

## Deep Docs

- `docs/architecture/web-view.md`: the architecture map: the request path
  from `loom --ui` to a live socket, the processes per page, the two
  components, and the security layers.
- `docs/design-notes/web-ui.md`: the working spec for where the page is
  going (an exploration, not a commitment).
- `docs/adr/014-second-runtime.md`: one engine, two views, and option C in
  the web host.
- `protocol-change/051-web-view-route.md`: the routes, authentication, the
  relay, and the operator addendum (page keys, nonces, ceilings, cards).
- `docs/lustre.md`: how Lustre 5.7.1 server components work, how they map
  onto this package, `ui_socket` and `ui_relay`, the view's security and
  accessibility rules, and the checklist for a change here.
