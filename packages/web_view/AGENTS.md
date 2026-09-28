# web_view

## Purpose

The web view's host and view for one session: two Lustre server components
that drive `session_view`'s lane and draw the session's transcript lines as
HTML, and the documents served around them (the page shell, the ticket
exchange's hand-off page and the content security policy). What the page
loads besides Lustre's server-component runtime is in `priv/static/`, which
a release carries like any application's `priv`: the client components'
bundle, the Tailwind stylesheet and the two bootstrap scripts, all built
from `packages/web_client` by `make gen-client` and gated by `make
client-check`. It is phase 4 of issue #530: the same engine the terminal
runs, under a second host, with only the view differing
([ADR-014](../../docs/adr/014-second-runtime.md)).

The daemon serves it only when started with `loomd --ui`
([protocol-change/051](../../protocol-change/051-web-view-route.md)). The
package knows nothing of the daemon: the transport the lane writes through
is handed in by `packages/client`, which owns the routes, the tickets, the
page keys and nonces, and the relay into the session's gateway.

## Key Types

- `component.Start(socket)`: what the daemon supplies when it starts a
  component: the session ID, the catalogue's `Label(name, workspace)` for
  the heading (or `None`, which only tests pass), the `snapshot.Expected` attachment every cut
  must match, and a `Transport(socket)`. The heading shows the name (or
  `Session` and the ID's first eight characters) with the whole ID in a
  `title`, and the workspace's last segment with the whole path in a
  `title`.
- `component.Transport(socket)`: `connect(inbox, opened)`, which returns at
  once and answers on `opened`; `transmit(socket, frame)`; `shut(socket)`;
  and `now()`. All run in the component's process.
- `component.Msg(socket)`: `Opened`, `Refused`, `TimerArmed`, `Arrived`
  (a batch of up to `arrival_batch` frames, reduced at once) and `Ticked`
  (the deadline timer fired). It holds no command.
- `component.Model(socket)` (opaque): the lane, the filed frames
  (`session_view/inbox`), the last capture, its transcript blocks and the
  turns laid out from them (`turns.Piece`), the agent rows, the roster, the
  cache ledger and its miss notices, the agent `Strip`, the approvals, the
  connection `Status`, the operator `Notice` and the sent-draft count.
- The view, one module per screen region under `web_view/view/`, laid out
  by `component.view` and `operator_page.view`. None of them imports
  `component`, which imports them, so each takes what it draws as its own
  types or plain values. `heading.view(session_id, name, workspace,
  status)` draws the heading; `component.heading(model)` reads those
  values from the model and stays the entry point both pages call.
  `strip.view(strip)` draws the agent strip, memoized on the whole strip;
  `lane.view(pieces)` draws the transcript lane, memoized per line.
- `strip.Strip` and `strip.Chip`: the listed agents (`line`,
  positional `hue`, the `cache` outlook `cache_watch.shown` allows with its
  label, and `running_ms`, how long its operation had run when the strip
  was built), the advisor's chip and the settled count. The component
  builds them and `strip.view` draws them. `strip.hue_class` and
  `strip.ring_class` map a hue and an outlook to literal classes.
  `strip.followed` is the strand the strip marks as current, and
  `component.strand` is defined as it.
- `markdown_view.blocks(tree)`: the elements for an answer's Markdown,
  drawn from `session_view/markdown`'s tree, the tree the terminal's
  `tui/markdown` also draws. `view/lane` uses it for the speakers the
  terminal renders as Markdown (assistant, reasoning, tool detail) and for
  the bodies of the result, nudge and peer cards, which are agent prose
  the terminal draws as tool-detail rows; every other row stays a `pre`.
  The model holds no trees. `lane.view` draws every transcript line and
  card body inside its own `element.memo` keyed on that line or body, with
  no memo around them (`lane.rows`), so a line is parsed and drawn when it
  first appears and Lustre reuses its element after that. Lustre forgets
  memos nested inside a memo that hit and redraws a keyed subtree whose
  key changed, which is why the memos are leaves and why `turns` keys a
  turn's work by its input (`docs/lustre.md`, "A memo inside a memo that
  hit is forgotten"). `lane_memo_test` counts the lines a render draws.
- `component.{submit, decide}`: the two commands, through the engine's
  arms in `session_view/operator`. `Answer` is `AllowOnce | Deny`; a page
  never offers remembering a grant for the session.
- `operator_page.Msg(socket)`: `Observed(component.Msg)`, `Submitted(text,
  delivery)` and `Decided(id, seq, answer)`. `composition(fields)` is the
  total decoder of the composer form's fields.
- `page`: the shell, the exchange page (`enter(next, nonce)`), the asset
  names (`stylesheet_asset`, `enter_asset`, `page_asset`, `client_asset`,
  `runtime_asset`) and where each is on disk (`static_file`,
  `runtime_file`), the keyed paths (`keyed_prefix`, `session_path`) and
  `content_security_policy(host)`.

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
  or `Refused`), `connection_event.Message`s from the transport (the
  mapping drains up to `arrival_batch` waiting frames into one `Arrived`),
  and a `Nil` from its one deadline timer, armed for the lane's
  `session_channel.next_due` (mapped to `Ticked`). Each source is one
  `server_component.select` from `init`, so its subjects belong to the
  component's process. Of the lane's updates,
  `Captured` projects the page, `Auxiliary(UsageChanged)` feeds the cache
  ledger and the roster, and `Submission`, `Acknowledged`,
  `RequestRefused` and `UnknownOutcome` replace the operator's notice, so
  it always states the outcome of the latest command.
- The page renders `web_client`'s custom elements by tag:
  `<loom-elapsed offset>` in each chip, `<loom-fold>` around a settled
  turn's work, and `<loom-follow>` around the lane, which keeps the newest
  row in view while the reader is at the bottom. They run in the browser
  and send the server nothing.
- An operator's page also receives Lustre's `EventFired` for its two
  handlers: a click on an approval button and the composer form's submit.
- Outputs leave through the transport only: `Transmit` and `Shut`, in the
  lane's order, inside one `effect.from`.

## Invariants

- **No session logic here.** What a frame means, when to catch up, which
  lines a capture becomes, how a lane folds into turns, which agents a strip
  lists, what the cache may claim and what an operator's input becomes on
  the wire are `session_view`'s.
- **Derive per capture, never per render or per tick.** A capture is
  projected once into blocks, pieces and the strip, and an idle refresh
  that brings back the capture already drawn projects nothing. A tick
  rebuilds the strip only when a cache label changed; the browser counts
  elapsed time. Logic that decides something about the session
  belongs there, where the terminal uses it too.
- **Event-driven delivery, one render per burst.** `Arrived` files its
  batch and reduces every filed frame in arrival order, then runs the
  lane's tick; there is no periodic tick. Lustre renders once per message
  whatever it changed, so the batching has to happen in the selector's
  mapping, before `update`. After every transition `rearm` cancels the one
  timer and arms it for the lane's `next_due`; `update` performs that
  itself, because the `Timer` handle must stay in the model (ADR-013, the
  addendum on event-driven delivery). `component_test` pins the
  reduction; `delivery_test` counts the renders a burst costs on the real
  runtime and watches the timer fire.
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
  `html.text`; nothing uses `unsafe_raw_html`. Rendered Markdown keeps the
  same rule: a link is its label and its destination as text, never an
  `href`; an image is text and is never loaded; an ordered list's numbers
  and a fence's language are text; classes come from closed types.
- **An approval card is drawn from the record alone** (`approval.presentation`),
  in its own region outside the transcript, directly above the composer in
  the dock, the footer pinned to the viewport's bottom edge. A card
  appearing grows the dock upward and never moves the composer, and the
  region's height is capped so it scrolls on its own. With nothing pending
  the region is `element.none()`, so the composer's path does not change
  when a card appears. The action row carries `arming`: for 600 ms after
  a card is inserted the stylesheet refuses clicks on it and dims the
  buttons, and cards keyed by sequence keep their node so a patch never
  restarts it; reduced motion drops only the dimming. Deny comes first; each button
  names the tool; nothing has `autofocus`; the composer's submit never
  decides an approval; a decision is sent only for the record still pending
  at the drawn sequence (`operator.drawn`).
- **The composer form is decoded totally.** One `draft`, at most one
  `delivery` of `prompt` or `steer`, nothing else; anything more refuses
  the event.
- **No inline script or style** in any served document, so the policy can
  refuse both.
- **Class names are complete literal strings.** Tailwind builds the
  stylesheet from the classes this package's source spells, read as text
  (`packages/web_client/src/web_client.css` names it with `@source`). A
  class built by concatenation is missing from the output. `priv/static` is
  generated: run `make gen-client` after changing a class.

## Deep Docs

- `docs/architecture/web-view.md`: the architecture map: the request path
  from `loom ui` to a live socket, the processes per page, the two
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
